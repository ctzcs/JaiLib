// SDL_video.h — window/display subset used by Foster.
// Note: SDL3 window flags are Uint64 (unlike SDL2's Uint32).

SDL_Window :: void;

SDL_DisplayID :: u32; // also declared in SDL_events.h context
SDL_WindowID :: u32;

using SDL_WindowFlags :: enum_flags u64 {
    SDL_WINDOW_FULLSCREEN :: 0x0000000000000001;
    SDL_WINDOW_OPENGL :: 0x0000000000000002;
    SDL_WINDOW_OCCLUDED :: 0x0000000000000004;
    SDL_WINDOW_HIDDEN :: 0x0000000000000008;
    SDL_WINDOW_BORDERLESS :: 0x0000000000000010;
    SDL_WINDOW_RESIZABLE :: 0x0000000000000020;
    SDL_WINDOW_MINIMIZED :: 0x0000000000000040;
    SDL_WINDOW_MAXIMIZED :: 0x0000000000000080;
    SDL_WINDOW_MOUSE_GRABBED :: 0x0000000000000100;
    SDL_WINDOW_INPUT_FOCUS :: 0x0000000000000200;
    SDL_WINDOW_MOUSE_FOCUS :: 0x0000000000000400;
    SDL_WINDOW_EXTERNAL :: 0x0000000000000800;
    SDL_WINDOW_MODAL :: 0x0000000000001000;
    SDL_WINDOW_HIGH_PIXEL_DENSITY :: 0x0000000000002000;
    SDL_WINDOW_MOUSE_CAPTURE :: 0x0000000000004000;
    SDL_WINDOW_MOUSE_RELATIVE_MODE :: 0x0000000000008000;
    SDL_WINDOW_ALWAYS_ON_TOP :: 0x0000000000010000;
    SDL_WINDOW_UTILITY :: 0x0000000000020000;
    SDL_WINDOW_TOOLTIP :: 0x0000000000040000;
    SDL_WINDOW_POPUP_MENU :: 0x0000000000080000;
    SDL_WINDOW_KEYBOARD_GRABBED :: 0x0000000000100000;
    SDL_WINDOW_VULKAN :: 0x0000000010000000;
    SDL_WINDOW_METAL :: 0x0000000020000000;
    SDL_WINDOW_TRANSPARENT :: 0x0000000040000000;
    SDL_WINDOW_NOT_FOCUSABLE :: 0x0000000080000000;
}

SDL_DisplayModeData :: void;

SDL_DisplayMode :: struct {
    displayID: SDL_DisplayID; // the display this mode is associated with
    format: u32; // SDL_PixelFormat (kept as u32 until the pixels binding lands)
    w: s32;
    h: s32;
    pixel_density: float; // scale converting size to pixels
    refresh_rate: float; // refresh rate (or 0.0f for unspecified)
    refresh_rate_numerator: s32;
    refresh_rate_denominator: s32;
    internal: *SDL_DisplayModeData; // private
}

#if OS != .WASM {
    SDL_CreateWindow :: (title: *u8, w: s32, h: s32, flags: SDL_WindowFlags) -> *SDL_Window #foreign SDL3;
    SDL_DestroyWindow :: (window: *SDL_Window) #foreign SDL3;
    SDL_ShowWindow :: (window: *SDL_Window) -> bool #foreign SDL3;
    SDL_HideWindow :: (window: *SDL_Window) -> bool #foreign SDL3;
    SDL_RaiseWindow :: (window: *SDL_Window) -> bool #foreign SDL3;
    SDL_MaximizeWindow :: (window: *SDL_Window) -> bool #foreign SDL3;
    SDL_MinimizeWindow :: (window: *SDL_Window) -> bool #foreign SDL3;
    SDL_RestoreWindow :: (window: *SDL_Window) -> bool #foreign SDL3;

    SDL_SetWindowBordered :: (window: *SDL_Window, bordered: bool) -> bool #foreign SDL3;
    SDL_SetWindowResizable :: (window: *SDL_Window, resizable: bool) -> bool #foreign SDL3;
    SDL_SetWindowFullscreen :: (window: *SDL_Window, fullscreen: bool) -> bool #foreign SDL3;
    SDL_SetWindowFullscreenMode :: (window: *SDL_Window, mode: *SDL_DisplayMode) -> bool #foreign SDL3;
    SDL_SetWindowPosition :: (window: *SDL_Window, x: s32, y: s32) -> bool #foreign SDL3;
    SDL_SetWindowSize :: (window: *SDL_Window, w: s32, h: s32) -> bool #foreign SDL3;
    SDL_SetWindowTitle :: (window: *SDL_Window, title: *u8) -> bool #foreign SDL3;

    SDL_GetWindowID :: (window: *SDL_Window) -> SDL_WindowID #foreign SDL3;
    SDL_GetWindowFromID :: (id: SDL_WindowID) -> *SDL_Window #foreign SDL3;
    SDL_GetWindowFlags :: (window: *SDL_Window) -> SDL_WindowFlags #foreign SDL3;
    SDL_GetWindowTitle :: (window: *SDL_Window) -> *u8 #foreign SDL3;
    SDL_GetWindowPosition :: (window: *SDL_Window, x: *s32, y: *s32) -> bool #foreign SDL3;
    SDL_GetWindowSize :: (window: *SDL_Window, w: *s32, h: *s32) -> bool #foreign SDL3;
    SDL_GetWindowSizeInPixels :: (window: *SDL_Window, w: *s32, h: *s32) -> bool #foreign SDL3;
    SDL_GetWindowDisplayScale :: (window: *SDL_Window) -> float #foreign SDL3;
    SDL_GetWindowPixelDensity :: (window: *SDL_Window) -> float #foreign SDL3;

    SDL_GetDisplayForWindow :: (window: *SDL_Window) -> SDL_DisplayID #foreign SDL3;
    SDL_GetCurrentDisplayMode :: (displayID: SDL_DisplayID) -> *SDL_DisplayMode #foreign SDL3;
    SDL_GetDesktopDisplayMode :: (displayID: SDL_DisplayID) -> *SDL_DisplayMode #foreign SDL3;
    SDL_GetPrimaryDisplay :: () -> SDL_DisplayID #foreign SDL3;
    SDL_GetDisplayName :: (displayID: SDL_DisplayID) -> *u8 #foreign SDL3;

    // SDL_SetTextInputArea (added for olib L-022 / window_set_text_input_area).
    // SDL3 declares this in SDL_keyboard.h next to SDL_StartTextInput /
    // SDL_StopTextInput (bound in SDL_keyboard.jai); it sits here because the area
    // is expressed in the window coordinates the rest of this file deals with, and
    // the two files share one scope anyway.
    // `rect` is in window coordinates (pixels / SDL_GetWindowPixelDensity), not
    // render pixels; `cursor` is the byte offset of the caret inside the current
    // editing text (-1 or 0 when there is no IME text). Returns false if the window
    // is invalid (SDL sets the error string).
    SDL_SetTextInputArea :: (window: *SDL_Window, rect: *SDL_Rect, cursor: s32) -> bool #foreign SDL3;
}
