#scope_module
using Basic; // module-private
using Math;
#scope_export

// Port of Foster Framework/App.cs.
// The Application is a global singleton (`App`) with lifecycle callbacks,
// set before calling app_run(config):

//     App.startup = my_startup;
//     App.update  = my_update;
//     App.render  = my_render;
//     app_run(.{ application_name = "MyGame" });

App_Events :: enum {
    ENTER_BACKGROUND;
    ENTER_FOREGROUND;
}

App_Flags :: enum_flags u32 {
    NONE :: 0;
    // Enables graphics debugging properties and validation
    GRAPHICS_DEBUGGING :: 1 << 0;
    // Enables multi-sampling of the back buffer
    MULTI_SAMPLED_BACK_BUFFER :: 1 << 1;
    // Doesn't log the jfoster header (version, SDL version, platform)
    NO_HEADER_LOG :: 1 << 2;
    // Does not activate the window when it is shown (Foster: NoWindowFocus).
    NO_WINDOW_FOCUS :: 1 << 3;
    // [olib L-020] `config.width`/`config.height` are logical units: right
    // after SDL creates the window (still hidden) they are scaled by
    // display scale / pixel density, clamped to the display's usable area and
    // centered (app_ext.jai / window_apply_logical_size). Off by default, so
    // the window is created with exactly the configured size, like Foster.
    LOGICAL_SIZE :: 1 << 4;
}

App_Config :: struct {
    application_name: string;
    window_title: string;
    width: s32 = 1280;
    height: s32 = 720;
    fullscreen: bool = false;
    resizable: bool = true;
    update_mode: Update_Mode;
    preferred_graphics_driver: Graphics_Driver = .NONE;
    flags: App_Flags;
}

Main_Thread_Action :: struct {
    proc: (data: *void) = null;
    data: *void = null;
}

App_State :: struct {
    name: string;

    time: Time;
    now: float64; // real elapsed seconds since app_run started
    update_mode: Update_Mode;

    window: *Window; // the main window
    windows: [..] *Window;

    input: *Input;
    device: *Graphics_Device;
    // file_system: *FileSystem   (M7)

    running: bool;
    exiting: bool;
    disposed: bool;

    // lifecycle callbacks (Foster: abstract Startup/Shutdown/Update/Render)
    startup: () = null;
    shutdown: () = null;
    update: () = null;
    render: () = null;

    // Application events (background/foreground); may fire from any thread
    on_event: (ev: App_Events) = null;
    // If null when the OS requests quit, the default behavior calls app_exit()
    on_exit_requested: () = null;

    // internals
    timer_start: float64;
    last_update_time: float64;
    fixed_accumulator: float64;
    main_thread_id: u32;
    main_thread_mutex: Mutex;
    main_thread_queue: [..] Main_Thread_Action;
    window_destroy_queue: [..] *Window;
}

App: App_State;

//
// UpdateMode is ported in utility/update_mode.jai (Foster UpdateMode.cs)
//

//
// App lifecycle
//

app_run :: (config: App_Config) {
    assert(config.application_name.count > 0, "Invalid Application Name");
    assert(!App.disposed, "The Application is Disposed");
    assert(!App.running, "Application is already running");
    assert(!App.exiting, "Application is still exiting");

    App.name = config.application_name;

    if !(config.flags & .NO_HEADER_LOG) {
        sdlv := SDL_GetVersion();
        log_info(tprint("jfoster: v% (Foster port, SDL %.%.%)",
            JFOSTER_VERSION, sdlv / 1000000, (sdlv / 1000) % 1000, sdlv % 1000));
        log_info(tprint("Platform: %", OS));
    }

    App.main_thread_id = current_thread_id();
    mutex_init(*App.main_thread_mutex);

    // route SDL logs into jfoster's Log
    SDL_SetLogOutputFunction(sdl_log_handler, null);

    // by default allow controller presses while unfocused; the game decides
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    if config.flags & .NO_WINDOW_FOCUS {
        SDL_SetHint(SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "0");
    }

    init_flags: SDL_InitFlags = .SDL_INIT_VIDEO | .SDL_INIT_EVENTS |
                                .SDL_INIT_JOYSTICK | .SDL_INIT_GAMEPAD;
    if !SDL_Init(init_flags) {
        log_error(app_sdl_error_message("SDL_Init"));
        assert(false, "SDL_Init failed");
    }

    SDL_AddEventWatch(app_event_watcher, null);

    // create modules
    App.update_mode = config.update_mode;
    if App.update_mode.Mode == .NONE {
        App.update_mode = update_mode_fixed_step(60);
    }

    App.input = input_create();
    App.device = graphics_device_create(config.preferred_graphics_driver, config.flags);
    App.window = window_create(config.window_title, config.width, config.height, config.fullscreen, config.resizable);

    // [olib L-020] App_Flags.LOGICAL_SIZE: the configured width/height were
    // logical units, so the window is resized to the logical-to-window
    // conversion and centered now, while it is still hidden (App.running is
    // false here, which is what made window_create pass SDL_WINDOW_HIDDEN) and
    // before anyone can see it. This mirrors olib's window_init, where
    // window_apply_logical_size runs right after SDL_CreateWindow; with the
    // flag off nothing happens, exactly like olib.
    if config.flags & .LOGICAL_SIZE {
        if !window_apply_logical_size(App.window, config) {
            log_warning("app_run: LOGICAL_SIZE was requested but the window could not be resized to the logical size; keeping the configured size");
        }
    }

    // ---- run ----
    App.running = true;
    App.time = .{};
    App.last_update_time = 0;
    App.fixed_accumulator = 0;
    App.timer_start = platform_time_seconds();

    // poll events once so input has controller state before startup
    app_poll_events();
    input_update(App.input, App.time);

    for w: App.windows {
        window_show(w);
    }

    if App.startup != null App.startup();

    while !App.exiting app_tick();

    // make sure all queued main thread actions have run
    app_drain_main_thread_queue();

    if App.shutdown != null App.shutdown();
    for w: App.windows {
        window_hide(w);
    }
    input_close_devices(App.input);

    App.running = false;
    App.exiting = false;
}

// Disposes application resources. Call after app_run returns.
app_destroy :: () {
    if App.disposed return;
    assert(!App.running, "Cannot dispose App while running");

    for i: 0..App.windows.count - 1 {
        window_destroy(App.windows[App.windows.count - 1 - i]);
    }
    app_destroy_waiting_windows();

    if App.device != null {
        graphics_device_shutdown(App.device);
        graphics_device_destroy_device(App.device);
    }
    input_close_devices(App.input);
    array_reset(*App.main_thread_queue);

    SDL_Quit();
    App.disposed = true;
}

// Notifies the application to exit; it may finish the current frame first.
app_exit :: () {
    if App.running {
        App.exiting = true;
    }
}

app_is_main_thread :: () -> bool {
    return current_thread_id() == App.main_thread_id;
}

// Queues an action to run on the main thread; runs immediately if already there.
// Jai closures can't capture locals, so actions carry an optional userdata pointer.
app_run_on_main_thread :: (action: (data: *void), data: *void = null) {
    if App.running && app_is_main_thread() {
        action(data);
    } else {
        mutex_lock(*App.main_thread_mutex);
        array_add(*App.main_thread_queue, .{ proc = action, data = data });
        mutex_unlock(*App.main_thread_mutex);
    }
}

app_user_path :: () -> string {
    // lazily cached; calling this may create a directory
    if App.main_thread_id == 0 return "";
    if !app_user_path_cached {
        org := to_cstr("");
        name := to_cstr(App.name);
        path := SDL_GetPrefPath(org, name);
        free(org);
        free(name);
        app_cached_user_path = copy_string(cstr_to_string(path));
        SDL_free(path);
        app_user_path_cached = true;
    }
    return app_cached_user_path;
}

app_user_path_cached: bool;
app_cached_user_path: string;

//
// internals
//

JFOSTER_VERSION :: "0.1.0";

app_tick :: () {
    update := App.update_mode;
    current_time := platform_time_seconds() - App.timer_start;
    delta_time := current_time - App.last_update_time;
    App.last_update_time = current_time;

    if update.Mode == {
        case .FIXED;
            App.fixed_accumulator += delta_time;

            // do not run too fast
            if update.FixedWaitEnabled {
                while App.fixed_accumulator < update.FixedTargetTime {
                    ms := cast(s32) ((update.FixedTargetTime - App.fixed_accumulator) * 1000);
                    sleep_ms(ms);

                    current_time = platform_time_seconds() - App.timer_start;
                    delta_time = current_time - App.last_update_time;
                    App.last_update_time = current_time;
                    App.fixed_accumulator += delta_time;
                }
            }

            // do not allow any update to take longer than the max
            if App.fixed_accumulator > update.FixedMaxTime {
                App.time = time_advance(App.time, App.fixed_accumulator - update.FixedMaxTime);
                App.fixed_accumulator = update.FixedMaxTime;
            }

            // as many fixed updates as we can
            while App.fixed_accumulator >= update.FixedTargetTime {
                App.fixed_accumulator -= update.FixedTargetTime;
                app_step(update.FixedTargetTime);
                if App.exiting {
                    break;
                }
            }

        case .UNLOCKED;
            app_step(delta_time);
    }

    // render
    {
        App.time = time_advance_render_frame(App.time);
        if App.render != null App.render();
        if App.device != null graphics_device_present(App.device);
    }

    app_destroy_waiting_windows();
}

app_step :: (delta: float64) {
    App.time = time_advance(App.time, delta);

    // warp mouse to window center when relative mode is on
    if App.window != null && App.window.handle != null {
        if SDL_GetWindowRelativeMouseMode(App.window.handle) && window_focused(App.window) {
            size := window_size(App.window);
            SDL_WarpMouseInWindow(App.window.handle, cast(float) (size.x / 2), cast(float) (size.y / 2));
        }
    }

    app_poll_events();
    input_update(App.input, App.time);
    // FramePool.NextFrame() lands with the Pool port (M6)

    app_drain_main_thread_queue();

    if App.update != null App.update();
}

app_is_input_event :: (t: SDL_EventType) -> bool {
    if t == .SDL_EVENT_MOUSE_BUTTON_DOWN || t == .SDL_EVENT_MOUSE_BUTTON_UP ||
       t == .SDL_EVENT_MOUSE_WHEEL || t == .SDL_EVENT_KEY_DOWN ||
       t == .SDL_EVENT_KEY_UP || t == .SDL_EVENT_TEXT_INPUT ||
       t == .SDL_EVENT_JOYSTICK_ADDED || t == .SDL_EVENT_JOYSTICK_REMOVED ||
       t == .SDL_EVENT_JOYSTICK_BUTTON_DOWN || t == .SDL_EVENT_JOYSTICK_BUTTON_UP ||
       t == .SDL_EVENT_JOYSTICK_AXIS_MOTION || t == .SDL_EVENT_GAMEPAD_ADDED ||
       t == .SDL_EVENT_GAMEPAD_REMOVED || t == .SDL_EVENT_GAMEPAD_BUTTON_DOWN ||
       t == .SDL_EVENT_GAMEPAD_BUTTON_UP || t == .SDL_EVENT_GAMEPAD_AXIS_MOTION {
        return true;
    }
    return false;
}

app_is_window_event :: (t: SDL_EventType) -> bool {
    if t == .SDL_EVENT_WINDOW_FOCUS_GAINED || t == .SDL_EVENT_WINDOW_FOCUS_LOST ||
       t == .SDL_EVENT_WINDOW_MOUSE_ENTER || t == .SDL_EVENT_WINDOW_MOUSE_LEAVE ||
       t == .SDL_EVENT_WINDOW_RESIZED || t == .SDL_EVENT_WINDOW_RESTORED ||
       t == .SDL_EVENT_WINDOW_MAXIMIZED || t == .SDL_EVENT_WINDOW_MINIMIZED ||
       t == .SDL_EVENT_WINDOW_ENTER_FULLSCREEN || t == .SDL_EVENT_WINDOW_LEAVE_FULLSCREEN ||
       t == .SDL_EVENT_WINDOW_CLOSE_REQUESTED {
        return true;
    }
    return false;
}

app_poll_events :: () {
    SDL_PumpEvents();

    ev: SDL_Event;
    while SDL_PollEvent(*ev) && ev.type != .SDL_EVENT_POLL_SENTINEL {
        t := ev.type;

        if t == .SDL_EVENT_QUIT {
            if App.running && !App.exiting {
                if App.on_exit_requested != null App.on_exit_requested();
                else app_exit();
            }
        } else if app_is_input_event(t) {
            input_on_event(App.input, ev);
        } else if app_is_window_event(t) {
            for w: App.windows {
                if w.id == ev.window.windowID {
                    window_on_event(w, t);
                    break;
                }
            }
        }
    }
}

app_event_watcher :: (userdata: *void, event: *SDL_Event) -> bool #c_call {
    type := event.type;

    push_context { // SDL may call us on any thread, without a Jai context
        if type == .SDL_EVENT_DID_ENTER_FOREGROUND || type == .SDL_EVENT_WILL_ENTER_FOREGROUND ||
           type == .SDL_EVENT_DID_ENTER_BACKGROUND || type == .SDL_EVENT_WILL_ENTER_BACKGROUND {
            if App.device != null graphics_device_on_event(App.device, type);
        }

        if type == .SDL_EVENT_DID_ENTER_FOREGROUND {
            if App.on_event != null App.on_event(.ENTER_FOREGROUND);
        }
        if type == .SDL_EVENT_WILL_ENTER_BACKGROUND {
            if App.on_event != null App.on_event(.ENTER_BACKGROUND);
        }
    }

    return true;
}

sdl_log_handler :: (userdata: *void, category: s32, priority: SDL_LogPriority, message: *u8) #c_call {
    push_context {
        if priority == .SDL_LOG_PRIORITY_VERBOSE || priority == .SDL_LOG_PRIORITY_DEBUG ||
           priority == .SDL_LOG_PRIORITY_INFO {
            log_info_cstr(message);
        } else if priority == .SDL_LOG_PRIORITY_WARN {
            log_warning_cstr(message);
        } else if priority == .SDL_LOG_PRIORITY_ERROR || priority == .SDL_LOG_PRIORITY_CRITICAL {
            log_error_cstr(message);
        }
    }
}

app_window_created :: (w: *Window) {
    array_add(*App.windows, w);
    if App.device != null graphics_device_window_created(App.device, w);
}

app_window_marked_for_destruction :: (w: *Window) {
    if !w.is_destroyed {
        for q: App.window_destroy_queue {
            if q == w return;
        }
        array_add(*App.window_destroy_queue, w);
        array_unordered_remove_by_value(*App.windows, w, true);
    }
}

app_destroy_waiting_windows :: () {
    while App.window_destroy_queue.count > 0 {
        w := pop(*App.window_destroy_queue);
        if App.device != null graphics_device_window_destroyed(App.device, w);
        if w.handle != null SDL_DestroyWindow(w.handle);
        window_destroyed(w);
    }
}

app_drain_main_thread_queue :: () {
    while true {
        mutex_lock(*App.main_thread_mutex);
        action: Main_Thread_Action;
        if App.main_thread_queue.count > 0 {
            action = App.main_thread_queue[0];
            array_unordered_remove_by_index(*App.main_thread_queue, 0);
        }
        mutex_unlock(*App.main_thread_mutex);

        if action.proc == null break;
        action.proc(action.data);
    }
}

app_sdl_error_message :: (sdl_method: string, foster_info := "") -> string {
    if foster_info != "" {
        return tprint("%. % failed: %", foster_info, sdl_method, cstr_to_string(SDL_GetError()));
    }
    return tprint("% failed: %", sdl_method, cstr_to_string(SDL_GetError()));
}
