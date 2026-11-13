// SDL_version.h
// SDL 3.4: SDL_GetVersion() returns the linked version packed via SDL_VERSIONNUM (major*10000 + minor*100 + micro).

#if OS != .WASM {
SDL_GetVersion  :: () -> s32 #foreign SDL3;
SDL_GetRevision :: () -> *u8 #foreign SDL3;
}
