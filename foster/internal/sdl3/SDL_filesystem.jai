// SDL_filesystem.h + SDL_free (from SDL_stdinc.h)

#if OS != .WASM {
SDL_GetPrefPath :: (org: *u8, app: *u8) -> *u8 #foreign SDL3;   // result must be SDL_free'd
SDL_free        :: (mem: *void) #foreign SDL3;
}
