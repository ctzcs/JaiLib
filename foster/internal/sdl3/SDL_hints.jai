// SDL_hints.h — only what Foster uses.

SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS :: "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS";
SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN :: "SDL_WINDOW_ACTIVATE_WHEN_SHOWN";

#if OS != .WASM {
    SDL_SetHint :: (name: *u8, value: *u8) -> bool #foreign SDL3;
    SDL_GetHint :: (name: *u8) -> *u8 #foreign SDL3;
}
