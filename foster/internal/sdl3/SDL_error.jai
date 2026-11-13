// SDL_error.h

#if OS != .WASM {
SDL_GetError   :: () -> *u8 #foreign SDL3;
SDL_ClearError :: () -> bool #foreign SDL3;
}
