// SDL_clipboard.h

#if OS != .WASM {
    SDL_GetClipboardText :: () -> *u8 #foreign SDL3; // result must be SDL_free'd
    SDL_SetClipboardText :: (text: *u8) -> bool #foreign SDL3;
}
