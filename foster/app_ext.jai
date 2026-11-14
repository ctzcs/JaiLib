#scope_module
using Basic; // module-private
using Math;
#scope_export

// olib extensions to the App / Window layer — NOT part of upstream Foster.
//
// Every block below is a jfoster port of a capability that exists only in
// olib's Odin port (<olib>/foster/olib_ext.odin) and is registered in
// <olib>/foster/docs/LOCAL_CHANGES.md. The registration number is repeated at
// each block so the two codebases can be diffed item by item when Foster
// upstream is synced.
//
//   L-004  app_set_user_data / app_get_user_data / app_get_user_data_as
//   L-020  App_Flags.LOGICAL_SIZE (member lives in app.jai, applied by app_run
//          through window_apply_logical_size below)
//   L-023  logical_to_window_size / window_set_logical_size /
//          window_apply_logical_size
//
// L-022 (SetTextInputArea) is a Window method in olib, so its port lives in
// window.jai (window_set_text_input_area) next to Start/StopTextInput.
//
// The procedures themselves stay here; the only edits outside this file are the
// two that cannot be avoided once the behavior is wired in: the App_Flags
// member in app.jai (L-020) and the SDL_SetTextInputArea binding (L-022).

//
// [olib L-004] Framework / App — user data
//
// Foster's C# App holds no game state (games subclass App there); olib's port
// gives the single App a `UserData` pointer plus a typed getter, so the
// per-frame callbacks don't each hand-write `cast(^World)`.
//
// jfoster's App_State (app.jai) has no UserData field and app.jai must stay a
// 1:1 port, so the slot lives here. App is a module-global singleton
// (`App: App_State`), so a tiny side table keyed by the App pointer is enough:
// one entry per App instance, no allocation, no lock (App state is main-thread
// data, exactly like the fields it stands in for).
//
// Semantics copied from olib: no type checking, `T` must be the type that was
// passed to app_set_user_data, and the getter returns null when nothing was
// set (or when this App is not the one holding the slot).
//

APP_EXT_USER_DATA_SLOTS :: 8;

App_Ext_User_Data :: struct {
    owner: *App_State; // null == free slot
    data: *void;
}

app_ext_user_data: [APP_EXT_USER_DATA_SLOTS] App_Ext_User_Data;

// Finds the slot owned by `app` (create = true takes a free one, or recycles
// slot 0 when all are taken and says so in the log).
app_ext_user_data_slot :: (app: *App_State, create: bool) -> *App_Ext_User_Data {
    first_slot: *App_Ext_User_Data;
    free_slot: *App_Ext_User_Data;
    for *app_ext_user_data {
        if first_slot == null first_slot = it;
        if it.owner == app return it;
        if it.owner == null && free_slot == null free_slot = it;
    }
    if !create return null;
    if free_slot == null {
        log_warning(tprint("app_set_user_data: all % slots are taken, reusing the first one",
                           APP_EXT_USER_DATA_SLOTS));
        free_slot = first_slot;
    }
    free_slot.owner = app;
    free_slot.data = null;
    return free_slot;
}

// olib: AppSetUserData. Attaches `data` (pass null to clear) to `app`.
app_set_user_data :: (app: *App_State, data: *void) {
    if app == null return; // olib ignores a nil app the same way
    slot := app_ext_user_data_slot(app, create = true);
    slot.data = data;
}

// olib: AppGetUserData. null when `app` is null or holds nothing.
app_get_user_data :: (app: *App_State) -> *void {
    if app == null return null;
    slot := app_ext_user_data_slot(app, create = false);
    if slot == null return null;
    return slot.data;
}

// [olib L-004] The point of the extension: get the state back as its real
// type, so callbacks don't cast. No type check (same as olib) — `T` must be
// the type of the pointer handed to app_set_user_data.
//
//     world := app_get_user_data_as(World);        // the module-global App
//     world := app_get_user_data_as(World, *app);  // an explicit App pointer
app_get_user_data_as :: ($T: Type) -> *T {
    return cast(*T) app_get_user_data(*App);
}

app_get_user_data_as :: ($T: Type, app: *App_State) -> *T {
    return cast(*T) app_get_user_data(app);
}

//
// [olib L-023] Framework / Window — logical size
//
// On Windows SDL3 window coordinates are physical pixels, so a 960x720 design
// only fills 2/3 of the screen at 150% scale. olib converts logical units with
// display_scale / pixel_density before handing them to SDL, at creation and at
// runtime. Upstream Foster has no equivalent: App.cs passes Width/Height
// straight to SDL.
//

// olib's SDL_WINDOWPOS_CENTERED_DISPLAY macro (SDL_video.h), which jfoster's
// SDL bindings do not carry: 0x2FFF0000 | display id.
SDL_WINDOWPOS_CENTERED_MASK :: 0x2FFF0000;

sdl_windowpos_centered_display :: (display: SDL_DisplayID) -> s32 {
    return cast(s32) (SDL_WINDOWPOS_CENTERED_MASK | cast(u32) display);
}

// jfoster's SDL_video.jai binds only the subset Foster itself calls and does
// not bind SDL_GetDisplayUsableBounds (SDL_video.h). The logical-size
// conversion needs it to clamp to the usable desktop area (taskbar/dock
// excluded), so it is declared here. If SDL_video.jai ever grows the same
// declaration, delete this line.
//
// [W1] Desktop-only: there is no SDL3 to import on the web target. The two
// procedures below that need it are branched at the bottom of this file.
#if OS != .WASM {
    SDL_GetDisplayUsableBounds :: (displayID: SDL_DisplayID, rect: *SDL_Rect) -> bool #foreign SDL3;
}

// olib keeps `math.is_nan` / `math.is_inf` guards; Jai's Math has no `round`
// and the NaN/inf helpers are spelled differently, so both are done with plain
// comparisons here:
//   NaN  fails every comparison        -> `v > 0` is false
//   +inf is greater than any finite f64 -> `v <= 1e308` is false
// (1e308 is below DBL_MAX, so no finite input is rejected.)
logical_is_finite_positive :: (v: float64) -> bool {
    return v > 0 && v <= 1.0e308;
}

// Round half away from zero, like Odin's math.round. Both inputs are strictly
// positive here, so floor(x + 0.5) is exact for our use.
logical_round :: (v: float64) -> float64 {
    return floor(v + 0.5);
}

SDL_INT_MAX :: 2147483647.0; // max(c.int) in olib's Odin version

// [olib L-023] Pure conversion: logical units * display scale / pixel density,
// rounded to SDL window coordinates.
//
// `usable_size`'s 0 component means "this axis is unlimited"; a positive
// component clamps that axis on its own (the aspect ratio is NOT preserved),
// a negative one is rejected. The value must be positive on both axes and
// scale/density must be finite and positive; a negative bound or a size that
// does not fit in SDL's int returns the zero Point2 and false.
//
// No window, no SDL call, no state: safe to unit-test with literals.
logical_to_window_size :: (value: Point2, display_scale: float, pixel_density: float,
                           usable_size := Point2_Zero) -> (Point2, bool) {
    if value.x <= 0 || value.y <= 0 || usable_size.x < 0 || usable_size.y < 0 {
        return Point2_Zero, false;
    }
    if !logical_is_finite_positive(cast(float64) display_scale) ||
       !logical_is_finite_positive(cast(float64) pixel_density) {
        return Point2_Zero, false;
    }

    factor := cast(float64) display_scale / cast(float64) pixel_density;
    w := logical_round(cast(float64) value.x * factor);
    h := logical_round(cast(float64) value.y * factor);
    if w < 1.0 w = 1.0; // a positive logical size never collapses to 0
    if h < 1.0 h = 1.0;

    if usable_size.x > 0 w = min(w, cast(float64) usable_size.x);
    if usable_size.y > 0 h = min(h, cast(float64) usable_size.y);

    // Cast has a runtime range check in Jai: verify before converting.
    if w > SDL_INT_MAX || h > SDL_INT_MAX return Point2_Zero, false;

    return .{ cast(s32) w, cast(s32) h }, true;
}

// [olib L-023] Runtime logical resize: converts with the *current* display's
// scale/density and usable bounds on every call. It does not reuse the last
// window size and does not center (a runtime resize moves nothing); the caller
// is responsible for leaving fullscreen first and for calling it at a safe
// time. false when the window is closed/null, fullscreen, the input is invalid
// or SDL rejects the request — true only means SDL accepted it (the window
// system may still adjust the final size asynchronously).
#if OS != .WASM {
    window_set_logical_size :: (w: *Window, value: Point2) -> bool {
        if w == null || w.handle == null || window_fullscreen(w) return false;

        display := SDL_GetDisplayForWindow(w.handle);
        usable: SDL_Rect;
        bounds := Point2_Zero;
        if SDL_GetDisplayUsableBounds(display, *usable) {
            // A negative usable size means "the platform did not report one"; it
            // must not become a clamp of 0, so it is dropped here (olib: max(0, w)).
            bw := usable.w;
            bh := usable.h;
            if bw < 0 bw = 0;
            if bh < 0 bh = 0;
            bounds = .{ bw, bh };
        }

        size, ok := logical_to_window_size(value, SDL_GetWindowDisplayScale(w.handle),
                                           SDL_GetWindowPixelDensity(w.handle), bounds);
        if !ok return false;
        return SDL_SetWindowSize(w.handle, size.x, size.y);
    }
} else {
    // [W1] Web: there is no OS window to resize and no display to query, so the
    // logical size is applied to the framework's own window record. The conversion
    // itself is the same pure `logical_to_window_size`, fed with the canvas'
    // device-pixel ratio (web_pixel_ratio, the role SDL_GetWindowDisplayScale plays
    // on desktop) and with no usable-area clamp — a canvas is not constrained by a
    // taskbar. The real CSS resize is W2.
    window_set_logical_size :: (w: *Window, value: Point2) -> bool {
        if w == null || w.handle == null || window_fullscreen(w) return false;

        ratio := web_pixel_ratio;
        if ratio <= 0 ratio = 1.0;

        size, ok := logical_to_window_size(value, ratio, 1.0, Point2_Zero);
        if !ok return false;
        window_set_size(w, size);
        return true;
    }
}

// [olib L-023] Creation path: same conversion as the runtime resize, plus the
// one thing only creation does — centering on the window's display. Designed
// for a window that is still hidden (App.running false -> window_create sets
// SDL_WINDOW_HIDDEN), which is how olib applies it in window_init.
//
// Creation path. Two ways in, and both keep this procedure unchanged:
//   * [olib L-020] `config.flags & .LOGICAL_SIZE` — app_run calls this right
//     after window_create, while the window is still hidden. This is the olib
//     behavior, and the only difference from olib is where the flag is read:
//     olib reads it inside window_apply_logical_size (called unconditionally by
//     its window_init), jfoster reads it at the app_run call site, so a direct
//     call below still means "apply it".
//   * Calling it yourself once the window exists and before it is shown, e.g.
//
//         App.startup = () { window_apply_logical_size(App.window, config); };
//
// `config.fullscreen` disables it, like olib's AppConfig.Fullscreen check.
#if OS != .WASM {
    window_apply_logical_size :: (w: *Window, config: App_Config) -> bool {
        if config.fullscreen return false;
        if !window_set_logical_size(w, .{ config.width, config.height }) return false;

        display := SDL_GetDisplayForWindow(w.handle);
        center := sdl_windowpos_centered_display(display);
        return SDL_SetWindowPosition(w.handle, center, center);
    }
} else {
    // [W1] Web: the conversion happens (window_set_logical_size above), centering
    // does not — the canvas is positioned by CSS, which is the page author's call, not
    // the engine's. Returning the resize result keeps the contract ("true means the
    // size was applied").
    window_apply_logical_size :: (w: *Window, config: App_Config) -> bool {
        if config.fullscreen return false;
        return window_set_logical_size(w, .{ config.width, config.height });
    }
}
