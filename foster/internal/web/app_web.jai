#scope_module
using Basic;   // module-private
using Math;
#scope_export

// jfoster — App, web (wasm64) implementation. W1 skeleton.
//
// ===========================================================================
// The one real difference from desktop
// ===========================================================================
// On desktop `app_run` owns the loop: it blocks in `while !App.exiting app_tick()`
// until the game asks to quit. A browser tab cannot be blocked like that — the
// host drives frames from `requestAnimationFrame` — so the split is:
//
//     app_run(config)        setup + startup(); returns with App.running == true
//     app_web_frame(dt)      one frame: app_tick()  <- called from fw_step
//     app_web_frame          返回 false 时宿主停止 rAF（app_exit() / 关窗口）
//
// Everything else — App_State's fields, the update modes, the fixed-step
// accumulator, the main-thread action queue — is the desktop code, because none
// of it is SDL-specific. `App` stays a module-global singleton with the same
// fields, so kit code that reads `App.window` / `App.device` / `App.time` compiles
// unchanged.
//
// ===========================================================================
// W1 limits
// ===========================================================================
// `app_poll_events` drains an (empty until W2) queue that the DOM bridge fills;
// `app_user_path` returns "" because there is no filesystem (IndexedDB is W2);
// `app_sdl_error_message` has no SDL to ask, so it reports the method name.

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
    // after the window is created they are scaled by display scale / pixel
    // density, clamped to the display's usable area and centered.
    LOGICAL_SIZE :: 1 << 4;
}

App_Config :: struct {
    application_name: string;
    window_title:     string;
    width:            s32 = 1280;
    height:           s32 = 720;
    fullscreen:       bool = false;
    resizable:        bool = true;
    update_mode:      Update_Mode;
    preferred_graphics_driver: Graphics_Driver = .NONE;
    flags:            App_Flags;
}

Main_Thread_Action :: struct {
    proc: (data: *void) = null;
    data: *void = null;
}

App_State :: struct {
    name: string;

    time:        Time;
    now:         float64;    // real elapsed seconds since app_run started
    update_mode: Update_Mode;

    window:  *Window;    // the main window
    windows: [..] *Window;

    input:  *Input;
    device: *Graphics_Device;

    running:  bool;
    exiting:  bool;
    disposed: bool;

    // lifecycle callbacks (Foster: abstract Startup/Shutdown/Update/Render)
    startup:  () = null;
    shutdown: () = null;
    update:   () = null;
    render:   () = null;

    // Application events (background/foreground); may fire from any thread
    on_event: (ev: App_Events) = null;
    // If null when the OS requests quit, the default behavior calls app_exit()
    on_exit_requested: () = null;

    // internals
    timer_start:        float64;
    last_update_time:   float64;
    fixed_accumulator:  float64;
    main_thread_id:     u32;
    main_thread_mutex:  Mutex;
    main_thread_queue:  [..] Main_Thread_Action;
    window_destroy_queue: [..] *Window;
}

App: App_State;

JFOSTER_VERSION :: "0.1.0";

//
// App lifecycle
//

app_run :: (config: App_Config) {
    assert(config.application_name.count > 0, "Invalid Application Name");
    assert(!App.disposed, "The Application is Disposed");
    assert(!App.running,  "Application is already running");
    assert(!App.exiting,  "Application is still exiting");

    App.name = config.application_name;

    if !(config.flags & .NO_HEADER_LOG) {
        // No SDL_GetVersion on this target; the WebGL2/JS shell version is a W3
        // concern, so the header just says what it is.
        log_info(tprint("jfoster: v% (Foster port, wasm64/WebGL2 shell)", JFOSTER_VERSION));
        log_info(tprint("Platform: %", OS));
    }

    App.main_thread_id = current_thread_id();
    mutex_init(*App.main_thread_mutex);

    // create modules — same order as app.jai, so a game that inspects
    // App.input/App.window/App.device during startup sees the same world.
    App.update_mode = config.update_mode;
    if App.update_mode.Mode == .NONE {
        App.update_mode = update_mode_fixed_step(60);
    }
    // The "do not run too fast" sleep loop in app_tick exists to pace a native
    // thread. requestAnimationFrame already paces us, and sleep_ms is a no-op
    // here, so leaving the flag on would only burn a core inside a busy loop.
    App.update_mode.FixedWaitEnabled = false;

    App.input = input_create();
    App.device = graphics_device_create(config.preferred_graphics_driver, config.flags);
    App.window = window_create(config.window_title, config.width, config.height, config.fullscreen, config.resizable);

    if config.flags & .LOGICAL_SIZE {
        if !window_apply_logical_size(App.window, config) {
            log_warning("app_run: LOGICAL_SIZE 在当前 web 后端下无法应用，保留配置尺寸");
        }
    }

    // ---- run ----
    App.running = true;
    App.time = .{};
    App.last_update_time = 0;
    App.fixed_accumulator = 0;
    App.timer_start = platform_time_seconds();

    app_poll_events();
    input_update(App.input, App.time);

    for w: App.windows { window_show(w); }

    if App.startup != null App.startup();

    // 关键差异：不阻塞。宿主现在拥有帧循环，见 app_web_frame 的注释。
    log_info("app_run: web 目标下 app_run 直接返回，帧由宿主调 fw_step → app_web_frame 驱动");
}

// One frame. Returns false when the host should stop requesting frames.
//
// This is the `while !App.exiting app_tick();` body of app.jai, one iteration at
// a time. `dt` is accepted for symmetry with the bridge but ignored: app_tick
// measures elapsed time itself with platform_time_seconds(), exactly like
// desktop, so a dropped or duplicated frame cannot corrupt Update_Mode.
app_web_frame :: (dt: float64) -> bool {
    if !App.running || App.disposed return false;
    // 虚拟时钟跟着宿主喂的 dt 走（见 utility/platform.jai 的 WASM 分支）：
    // app_tick 用 platform_time_seconds() 算 delta，固定步长才能正常吐 update。
    web_advance_clock(dt);
    app_tick();
    return App.running && !App.exiting;
}

// The teardown half of app.jai's app_run tail: after the loop ends, hide the
// windows and close the input devices. app_web_stop is what fw_step calls when
// App.exiting becomes true, so app_run's desktop tail keeps an equivalent here.
app_web_stop :: () {
    if !App.running return;

    app_drain_main_thread_queue();

    if App.shutdown != null App.shutdown();
    for w: App.windows { window_hide(w); }
    input_close_devices(App.input);

    App.running = false;
    App.exiting = false;
}

// Disposes application resources. Call after the frame loop has stopped.
app_destroy :: () {
    if App.disposed return;
    if App.running {
        log_warning("app_destroy: 帧循环还在跑，先 app_web_stop()");
        app_web_stop();
    }

    for i: 0..App.windows.count-1 {
        window_destroy(App.windows[App.windows.count - 1 - i]);
    }
    app_destroy_waiting_windows();

    if App.device != null {
        graphics_device_shutdown(App.device);
        graphics_device_destroy_device(App.device);
    }
    input_close_devices(App.input);
    array_reset(*App.main_thread_queue);

    App.disposed = true;
}

// Notifies the application to exit; it may finish the current frame first.
app_exit :: () {
    if App.running { App.exiting = true; }
}

app_is_main_thread :: () -> bool {
    return current_thread_id() == App.main_thread_id;
}

// Queues an action to run on the main thread; runs immediately if already there.
// There is only one thread here, so the queue still exists (kit code and the
// window-title path both go through it) but it always drains inline.
app_run_on_main_thread :: (action: (data: *void), data: *void = null) {
    if App.running && app_is_main_thread() {
        action(data);
    } else {
        mutex_lock(*App.main_thread_mutex);
        array_add(*App.main_thread_queue, .{ proc = action, data = data });
        mutex_unlock(*App.main_thread_mutex);
    }
}

// Save-data root.
//
// 桌面返回 SDL_GetPrefPath 给的目录，读写是真的文件。浏览器里没有这个目录，
// 但有 localStorage / OPFS，于是我们用**虚拟根** "/save/"：它是一个键前缀，
// 由 internal/web/storage_web.jai 映射到（内存 + localStorage + OPFS 镜像）。
//
// 于是 `storage_read_all_text(directory_storage_create(app_user_path()), "slot1.json")`
// 这条桌面代码在 web 上一字不改就能用 —— 路径拼出来的 "/save/slot1.json" 就是
// 键名（storage_web.jai 会吃掉前导 '/'）。
WEB_USER_PATH :: "/save/";

app_user_path :: () -> string {
    if App.main_thread_id == 0 return "";
    return WEB_USER_PATH;
}

//
// internals
//

app_tick :: () {
    update  := App.update_mode;
    current_time := platform_time_seconds() - App.timer_start;
    delta_time := current_time - App.last_update_time;
    App.last_update_time = current_time;

    if update.Mode == {
        case .FIXED;
            App.fixed_accumulator += delta_time;

            // FixedWaitEnabled is forced off in app_run on this target (see the
            // comment there); the branch stays so Update_Mode keeps its meaning.
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

            if App.fixed_accumulator > update.FixedMaxTime {
                App.time = time_advance(App.time, App.fixed_accumulator - update.FixedMaxTime);
                App.fixed_accumulator = update.FixedMaxTime;
            }

            while App.fixed_accumulator >= update.FixedTargetTime {
                App.fixed_accumulator -= update.FixedTargetTime;
                app_step(update.FixedTargetTime);
                if App.exiting { break; }
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

    // Desktop warps the OS cursor to the window centre while relative mode is on
    // (which also generates the movement delta the next frame reads). The web
    // equivalent is pointer lock, which gives movementX/movementY directly, so
    // there is nothing to do here — see window_set_mouse_relative_mode.

    app_poll_events();
    input_update(App.input, App.time);

    app_drain_main_thread_queue();

    if App.update != null App.update();
}

app_is_input_event :: (t: SDL_EventType) -> bool {
    if t == .SDL_EVENT_MOUSE_BUTTON_DOWN    || t == .SDL_EVENT_MOUSE_BUTTON_UP   ||
       t == .SDL_EVENT_MOUSE_WHEEL          || t == .SDL_EVENT_KEY_DOWN          ||
       t == .SDL_EVENT_KEY_UP               || t == .SDL_EVENT_TEXT_INPUT        ||
       t == .SDL_EVENT_JOYSTICK_ADDED       || t == .SDL_EVENT_JOYSTICK_REMOVED  ||
       t == .SDL_EVENT_JOYSTICK_BUTTON_DOWN || t == .SDL_EVENT_JOYSTICK_BUTTON_UP ||
       t == .SDL_EVENT_JOYSTICK_AXIS_MOTION || t == .SDL_EVENT_GAMEPAD_ADDED     ||
       t == .SDL_EVENT_GAMEPAD_REMOVED      || t == .SDL_EVENT_GAMEPAD_BUTTON_DOWN ||
       t == .SDL_EVENT_GAMEPAD_BUTTON_UP    || t == .SDL_EVENT_GAMEPAD_AXIS_MOTION {
        return true;
    }
    return false;
}

app_is_window_event :: (t: SDL_EventType) -> bool {
    if t == .SDL_EVENT_WINDOW_FOCUS_GAINED   || t == .SDL_EVENT_WINDOW_FOCUS_LOST  ||
       t == .SDL_EVENT_WINDOW_MOUSE_ENTER    || t == .SDL_EVENT_WINDOW_MOUSE_LEAVE ||
       t == .SDL_EVENT_WINDOW_RESIZED        || t == .SDL_EVENT_WINDOW_RESTORED    ||
       t == .SDL_EVENT_WINDOW_MAXIMIZED      || t == .SDL_EVENT_WINDOW_MINIMIZED   ||
       t == .SDL_EVENT_WINDOW_ENTER_FULLSCREEN || t == .SDL_EVENT_WINDOW_LEAVE_FULLSCREEN ||
       t == .SDL_EVENT_WINDOW_CLOSE_REQUESTED {
        return true;
    }
    return false;
}

// Desktop pumps SDL and drains SDL's own queue. Here the queue is ours: the DOM
// bridge pushes `Web_Event`s (input_web.jai) and this is the single drain point,
// so the ordering App.update sees is the same as on desktop.
app_poll_events :: () {
    for *ev: web_poll_events() {
        t := ev.type;

        if t == .SDL_EVENT_QUIT {
            if App.running && !App.exiting {
                if App.on_exit_requested != null App.on_exit_requested();
                else app_exit();
            }
        } else if app_is_input_event(t) {
            input_on_web_event(App.input, ev);
        } else if app_is_window_event(t) {
            // One canvas == one window; the id check keeps the desktop shape for
            // anything that opens a second one (and will matter once off-screen
            // canvases arrive).
            for w: App.windows {
                if w.id == ev.window_id {
                    window_on_event(w, t);
                    break;
                }
            }
        }
    }
}

// Kept for API parity: on desktop SDL calls this from any thread to report
// foreground/background. The web side reaches the same two callbacks from the
// DOM visibilitychange handler (W2) by calling app_web_on_visibility.
app_event_watcher :: (userdata: *void, event: *SDL_Event) -> bool #c_call {
    return true;
}

// `document.visibilitychange` lands here in W2. Wired now so the callback path
// is testable and the App.on_event contract is not a stub sitting in a comment.
app_web_on_visibility :: (visible: bool) {
    // The device's in_background flag is what pauses rendering; it is the same
    // thing app.jai's watcher flips for SDL_EVENT_WILL_ENTER_BACKGROUND.
    if App.device != null {
        App.device.in_background = !visible;
    }
    if !visible {
        if App.on_event != null App.on_event(.ENTER_BACKGROUND);
    } else {
        if App.on_event != null App.on_event(.ENTER_FOREGROUND);
    }
}

// Desktop routes SDL's own log function into jfoster's logger. There is no SDL
// here, but the signature is kept so code that hands out the callback (and the
// handbook's list of #c_call entry points) stays the same shape.
sdl_log_handler :: (userdata: *void, category: s32, priority: SDL_LogPriority, message: *u8) #c_call {
    if message == null return;
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
        // No SDL_DestroyWindow: dropping the handle is the whole teardown for a
        // canvas-backed window (W2 releases the canvas + GL context here).
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

// Desktop appends SDL_GetError(). There is no SDL error queue on this target, so
// the message names the call that failed and nothing else — callers only use the
// string for a log line.
app_sdl_error_message :: (sdl_method: string, foster_info := "") -> string {
    if foster_info != "" {
        return tprint("%. % failed (web target: no SDL error string)", foster_info, sdl_method);
    }
    return tprint("% failed (web target: no SDL error string)", sdl_method);
}
