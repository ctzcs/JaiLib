#scope_module
using Basic;   // module-private
using Math;
#scope_export

// Port of Foster Framework/Window.cs.
// A window wraps an SDL3 window; properties are exposed via window_* procs
// (Jai has no properties). Callback fields mirror the C# events.

Window :: struct {
    handle:       *SDL_Window;   // null once destroyed
    id:           u32;
    title:        string;
    is_destroyed: bool;

    // callbacks (Foster: OnFocusGain etc.)
    on_focus_gain:      () = null;
    on_focus_lost:      () = null;
    on_mouse_enter:     () = null;
    on_mouse_leave:     () = null;
    on_resize:          () = null;
    on_restore:         () = null;
    on_maximize:        () = null;
    on_minimize:        () = null;
    on_fullscreen_enter: () = null;
    on_fullscreen_exit: () = null;

    // If null when close is requested: App.Exit() on the main window,
    // window_destroy() on any other window. (Foster: OnCloseRequested)
    on_close_requested: () = null;
}

window_create :: (title: string, width: s32, height: s32, fullscreen := false, resizable := true) -> *Window {
    w := New(Window);
    w.title = title;

    flags: SDL_WindowFlags = .SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if !App.running { flags |= .SDL_WINDOW_HIDDEN; }
    if fullscreen   { flags |= .SDL_WINDOW_FULLSCREEN; }
    if resizable    { flags |= .SDL_WINDOW_RESIZABLE; }

    title_c := to_cstr(title);
    w.handle = SDL_CreateWindow(title_c, width, height, flags);
    free(title_c);

    if w.handle == null {
        log_error(app_sdl_error_message("SDL_CreateWindow"));
        assert(false, "SDL_CreateWindow failed");
    }

    w.id = SDL_GetWindowID(w.handle);
    app_window_created(w);
    return w;
}

// Destroys the Window. If this is the main App window, this calls app_exit().
window_destroy :: (w: *Window) {
    if !w.is_destroyed {
        app_window_marked_for_destruction(w);
        if App.window == w app_exit();
        w.is_destroyed = true;
    }
}

window_title :: (w: *Window) -> string {
    return w.title;
}

window_set_title :: (w: *Window, title: string) {
    if w.title == title return;
    w.title = title;
    if app_is_main_thread() {
        window_apply_title(w);
    } else {
        // title copy must outlive the queue drain
        action := New(Title_Action);
        action.w = w;
        action.title = copy_string(title);
        app_run_on_main_thread(window_apply_title_action, action);
    }
}

Title_Action :: struct {
    w: *Window;
    title: string;
}

window_apply_title_action :: (data: *void) {
    action := cast(*Title_Action) data;
    action.w.title = action.title;
    window_apply_title(action.w);
    free(action);
}

window_position :: (w: *Window) -> Point2 {
    assert(w.handle != null, "The Window has been Closed");
    x, y: s32;
    SDL_GetWindowPosition(w.handle, *x, *y);
    return .{ x, y };
}

window_set_position :: (w: *Window, position: Point2) {
    assert(w.handle != null, "The Window has been Closed");
    SDL_SetWindowPosition(w.handle, position.x, position.y);
}

window_size :: (w: *Window) -> Point2 {
    assert(w.handle != null, "The Window has been Closed");
    width, height: s32;
    SDL_GetWindowSize(w.handle, *width, *height);
    return .{ width, height };
}

window_set_size :: (w: *Window, size: Point2) {
    assert(w.handle != null, "The Window has been Closed");
    SDL_SetWindowSize(w.handle, size.x, size.y);
}

window_width  :: (w: *Window) -> s32 { return window_size(w).x; }
window_height :: (w: *Window) -> s32 { return window_size(w).y; }

window_set_width  :: (w: *Window, width: s32)  { s := window_size(w); window_set_size(w, .{ width, s.y }); }
window_set_height :: (w: *Window, height: s32) { s := window_size(w); window_set_size(w, .{ s.x, height }); }

window_size_in_pixels :: (w: *Window) -> Point2 {
    assert(w.handle != null, "The Window has been Closed");
    width, height: s32;
    SDL_GetWindowSizeInPixels(w.handle, *width, *height);
    return .{ width, height };
}

window_width_in_pixels  :: (w: *Window) -> s32 { return window_size_in_pixels(w).x; }
window_height_in_pixels :: (w: *Window) -> s32 { return window_size_in_pixels(w).y; }

// Size of the display the window is currently in.
window_display_size :: (w: *Window) -> Point2 {
    assert(w.handle != null, "The Window has been Closed");
    display := SDL_GetDisplayForWindow(w.handle);
    mode := SDL_GetCurrentDisplayMode(display);
    if mode == null return Point2_Zero;
    return .{ mode.w, mode.h };
}

window_content_scale :: (w: *Window) -> Vector2 {
    assert(w.handle != null, "The Window has been Closed");
    scale := SDL_GetWindowDisplayScale(w.handle);
    if scale <= 0 {
        log_error(tprint("SDL_GetWindowDisplayScale failed: %s", SDL_GetError()));
        return .{
            cast(float) window_width_in_pixels(w) / cast(float) window_width(w),
            cast(float) window_height_in_pixels(w) / cast(float) window_height(w),
        };
    }
    return .{ scale, scale };
}

// Mouse position relative to the window, in pixel coordinates.
window_mouse_position :: (w: *Window) -> Vector2 {
    mx, my: float;
    SDL_GetGlobalMouseState(*mx, *my);
    pos := window_position(w);
    size := window_size(w);
    psize := window_size_in_pixels(w);
    return .{
        (mx - cast(float) pos.x) / cast(float) size.x * cast(float) psize.x,
        (my - cast(float) pos.y) / cast(float) size.y * cast(float) psize.y,
    };
}

window_fullscreen :: (w: *Window) -> bool {
    assert(w.handle != null, "The Window has been Closed");
    return (SDL_GetWindowFlags(w.handle) & .SDL_WINDOW_FULLSCREEN) != 0;
}

window_set_fullscreen :: (w: *Window, fullscreen: bool) {
    assert(w.handle != null, "The Window has been Closed");
    SDL_SetWindowFullscreen(w.handle, fullscreen);
}

window_resizable :: (w: *Window) -> bool {
    assert(w.handle != null, "The Window has been Closed");
    return (SDL_GetWindowFlags(w.handle) & .SDL_WINDOW_RESIZABLE) != 0;
}

window_set_resizable :: (w: *Window, resizable: bool) {
    assert(w.handle != null, "The Window has been Closed");
    SDL_SetWindowResizable(w.handle, resizable);
}

window_maximized :: (w: *Window) -> bool {
    assert(w.handle != null, "The Window has been Closed");
    return (SDL_GetWindowFlags(w.handle) & .SDL_WINDOW_MAXIMIZED) != 0;
}

window_set_maximized :: (w: *Window, maximized: bool) {
    assert(w.handle != null, "The Window has been Closed");
    if maximized && !window_maximized(w)      SDL_MaximizeWindow(w.handle);
    else if !maximized && window_maximized(w) SDL_RestoreWindow(w.handle);
}

window_focused :: (w: *Window) -> bool {
    assert(w.handle != null, "The Window has been Closed");
    flags: SDL_WindowFlags = .SDL_WINDOW_INPUT_FOCUS | .SDL_WINDOW_MOUSE_FOCUS;
    return (SDL_GetWindowFlags(w.handle) & flags) != 0;
}

// Sets whether the mouse is in Relative Mode.
window_set_mouse_relative_mode :: (w: *Window, enabled: bool) {
    if enabled == SDL_GetWindowRelativeMouseMode(w.handle) return;
    if !SDL_SetWindowRelativeMouseMode(w.handle, enabled) {
        log_warning(tprint("Failed to set Mouse Relative Mode: %s", SDL_GetError()));
    }
    size := window_size(w);
    SDL_WarpMouseInWindow(w.handle, cast(float) (size.x / 2), cast(float) (size.y / 2));
}

// Sets the mouse position within the window, in pixel coordinates.
window_set_mouse_position :: (w: *Window, position: Vector2) {
    size  := window_size(w);
    psize := window_size_in_pixels(w);
    SDL_WarpMouseInWindow(
        w.handle,
        position.x * (cast(float) size.x / cast(float) psize.x),
        position.y * (cast(float) size.y / cast(float) psize.y),
    );
}

// Enables/disables text input for this window (populates KeyboardState.text).
window_set_text_input :: (w: *Window, enabled: bool) {
    if enabled window_start_text_input(w);
    else       window_stop_text_input(w);
}

window_start_text_input :: (w: *Window) {
    if app_is_main_thread() {
        if !SDL_TextInputActive(w.handle) SDL_StartTextInput(w.handle);
    } else {
        app_run_on_main_thread(window_start_text_input_mt, w);
    }
}

window_stop_text_input :: (w: *Window) {
    if app_is_main_thread() {
        if SDL_TextInputActive(w.handle) SDL_StopTextInput(w.handle);
    } else {
        app_run_on_main_thread(window_stop_text_input_mt, w);
    }
}

window_start_text_input_mt :: (data: *void) { window_start_text_input(cast(*Window) data); }
window_stop_text_input_mt  :: (data: *void) { window_stop_text_input(cast(*Window) data); }

// [olib L-022] Tells the OS where the caret is, so an IME candidate window /
// the on-screen keyboard follows it. `rect` is in render-target pixels — the
// same space as window_size_in_pixels and Foster's SpriteBatch coordinates —
// and is converted to SDL window coordinates here (the inverse of the mapping
// window_mouse_position / window_set_mouse_position already use).
//
// Call it after window_set_text_input(w, true) and again whenever the caret
// moves or the window is resized; there is no automatic tracking, exactly like
// olib's SetTextInputArea. `cursor` is passed as 0 (no IME editing text) and the
// value is not exposed yet.
//
// false when the window is null/closed (no assert: a caret update during
// teardown must not kill the app) or when SDL rejects the area.
//
// It is a direct SDL call, not queued through app_run_on_main_thread like
// Start/StopTextInput: those are guarded because a window can be opened/closed
// from a worker, while the caret rect only makes sense from the thread that owns
// the UI. Call it from the main thread.
window_set_text_input_area :: (w: *Window, rect: Rect) -> bool {
    if w == null || w.handle == null return false;

    size   := window_size(w);
    pixels := window_size_in_pixels(w);

    // A zero pixel size means SDL has not reported one yet -> scale 1 (no
    // resize) instead of dividing by zero and handing SDL an inf/NaN box.
    sx: float = 1;
    sy: float = 1;
    if pixels.x > 0 sx = cast(float) size.x / cast(float) pixels.x;
    if pixels.y > 0 sy = cast(float) size.y / cast(float) pixels.y;

    // SDL wants a real box: an empty caret rect still gets 1x1, like olib's
    // max(round(...), 1).
    area := SDL_Rect.{
        x = text_input_area_coord(rect.x, sx),
        y = text_input_area_coord(rect.y, sy),
        w = max(text_input_area_coord(rect.w, sx), 1),
        h = max(text_input_area_coord(rect.h, sy), 1),
    };
    return SDL_SetTextInputArea(w.handle, *area, 0);
}

// Rounds and converts one scaled coordinate for SDL_SetTextInputArea.
//
// Jai's `cast` range-checks at run time, and this value comes straight from the
// application, so NaN / inf / a wild caret position would panic inside a plain
// cast. They are clamped to a band no real window coordinate can exceed.
text_input_area_coord :: (value: float, scale: float) -> s32 {
    v := cast(float64) value * cast(float64) scale;
    if v != v return 0;                   // NaN never equals itself
    if v < -32768.0 return -32768;
    if v >  32767.0 return  32767;
    return cast(s32) floor(v + 0.5);      // round half up, like olib's math.round
}

window_focus :: (w: *Window) {
    SDL_RaiseWindow(w.handle);
}

//
// internal
//

window_on_event :: (w: *Window, ev: SDL_EventType) {
    if ev == {
        case .SDL_EVENT_WINDOW_FOCUS_GAINED;
            if w.on_focus_gain != null w.on_focus_gain();
        case .SDL_EVENT_WINDOW_FOCUS_LOST;
            if w.on_focus_lost != null w.on_focus_lost();
        case .SDL_EVENT_WINDOW_MOUSE_ENTER;
            if w.on_mouse_enter != null w.on_mouse_enter();
        case .SDL_EVENT_WINDOW_MOUSE_LEAVE;
            if w.on_mouse_leave != null w.on_mouse_leave();
        case .SDL_EVENT_WINDOW_RESIZED;
            if w.on_resize != null w.on_resize();
        case .SDL_EVENT_WINDOW_RESTORED;
            if w.on_restore != null w.on_restore();
        case .SDL_EVENT_WINDOW_MAXIMIZED;
            if w.on_maximize != null w.on_maximize();
        case .SDL_EVENT_WINDOW_MINIMIZED;
            if w.on_minimize != null w.on_minimize();
        case .SDL_EVENT_WINDOW_ENTER_FULLSCREEN;
            if w.on_fullscreen_enter != null w.on_fullscreen_enter();
        case .SDL_EVENT_WINDOW_LEAVE_FULLSCREEN;
            if w.on_fullscreen_exit != null w.on_fullscreen_exit();
        case .SDL_EVENT_WINDOW_CLOSE_REQUESTED;
            if w.on_close_requested != null {
                w.on_close_requested();
            } else if App.window == w {
                app_exit();
            } else {
                window_destroy(w);
            }
    }
}

window_show :: (w: *Window) {
    SDL_ShowWindow(w.handle);
    SDL_SetWindowFullscreenMode(w.handle, null);
    SDL_SetWindowBordered(w.handle, true);
    SDL_RaiseWindow(w.handle);
}

window_hide :: (w: *Window) {
    SDL_HideWindow(w.handle);
}

window_destroyed :: (w: *Window) {
    w.handle = null;
}

window_apply_title :: (w: *Window) {
    if w.handle != null {
        title := to_cstr(w.title);
        SDL_SetWindowTitle(w.handle, title);
        free(title);
    }
}
