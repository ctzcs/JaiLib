// SDL_keyboard.h — text input control (per-window in SDL3).

#if OS != .WASM {
    SDL_StartTextInput :: (window: *SDL_Window) -> bool #foreign SDL3;
    SDL_StopTextInput :: (window: *SDL_Window) -> bool #foreign SDL3;
    SDL_TextInputActive :: (window: *SDL_Window) -> bool #foreign SDL3;
}
