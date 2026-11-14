// SDL_mouse.h

SDL_MouseButtonFlags :: u32;

SDL_BUTTON_LEFT :: 1; // button indices
SDL_BUTTON_MIDDLE :: 2;
SDL_BUTTON_RIGHT :: 3;
SDL_BUTTON_X1 :: 4;
SDL_BUTTON_X2 :: 5;

// SDL_BUTTON_MASK(X) == 1 << (X-1)
SDL_BUTTON_LMASK :: 0x0001; // 1 << (SDL_BUTTON_LEFT  - 1)
SDL_BUTTON_MMASK :: 0x0002; // 1 << (SDL_BUTTON_MIDDLE- 1)
SDL_BUTTON_RMASK :: 0x0004; // 1 << (SDL_BUTTON_RIGHT - 1)
SDL_BUTTON_X1MASK :: 0x0008; // 1 << (SDL_BUTTON_X1    - 1)
SDL_BUTTON_X2MASK :: 0x0010; // 1 << (SDL_BUTTON_X2    - 1)

using SDL_MouseWheelDirection :: enum u32 {
    SDL_MOUSEWHEEL_NORMAL; // 0
    SDL_MOUSEWHEEL_FLIPPED;
}

#if OS != .WASM {
    SDL_GetMouseState :: (x: *float, y: *float) -> SDL_MouseButtonFlags #foreign SDL3;
    SDL_GetGlobalMouseState :: (x: *float, y: *float) -> SDL_MouseButtonFlags #foreign SDL3;
    SDL_GetRelativeMouseState :: (x: *float, y: *float) -> SDL_MouseButtonFlags #foreign SDL3;
    SDL_WarpMouseInWindow :: (window: *SDL_Window, x: float, y: float) #foreign SDL3;
    SDL_WarpMouseGlobal :: (x: float, y: float) -> bool #foreign SDL3;
    SDL_SetWindowRelativeMouseMode :: (window: *SDL_Window, enabled: bool) -> bool #foreign SDL3;
    SDL_GetWindowRelativeMouseMode :: (window: *SDL_Window) -> bool #foreign SDL3;
}
