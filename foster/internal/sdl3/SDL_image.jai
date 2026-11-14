// SDL_iostream.h + SDL_pixels.h + SDL_surface.h — PNG decode/encode via SDL3.

SDL_IOStream :: void;

SDL_IOStatus :: enum u32 {
    READY;
    EOF;
    ERROR;
    NOT_READY;
    // values continue; only used as return info
}

SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER :: "SDL.iostream.dynamic.memory";

#if OS != .WASM {
    SDL_IOFromConstMem :: (mem: *void, size: u64) -> *SDL_IOStream #foreign SDL3;
    SDL_IOFromDynamicMem :: () -> *SDL_IOStream #foreign SDL3;
    SDL_GetIOSize :: (ctx: *SDL_IOStream) -> u64 #foreign SDL3;
    SDL_GetIOProperties :: (ctx: *SDL_IOStream) -> SDL_PropertiesID #foreign SDL3;
    SDL_CloseIO :: (ctx: *SDL_IOStream) -> bool #foreign SDL3;

    SDL_LoadPNG_IO :: (src: *SDL_IOStream, close_src := false) -> *SDL_Surface #foreign SDL3;
    SDL_SavePNG_IO :: (surface: *SDL_Surface, dst: *SDL_IOStream, close_dst := false) -> bool #foreign SDL3;
}

// SDL_pixels.h (subset)
using SDL_PixelFormat :: enum u32 {
    UNKNOWN :: 0;
    // SDL's byte-array aliases on the supported little-endian platforms.
    RGBA32 :: 0x16762004; // ABGR8888
    BGRA32 :: 0x16362004; // ARGB8888
};

// SDL_surface.h
SDL_Surface :: struct {
    flags: u32;
    format: SDL_PixelFormat;
    w: s32;
    h: s32;
    pitch: s32;
    pixels: *void;
    refcount: s32;
}

#if OS != .WASM {
    SDL_CreateSurfaceFrom :: (width: s32, height: s32, format: SDL_PixelFormat, pixels: *void, pitch: s32) -> *SDL_Surface #foreign SDL3;
    SDL_ConvertSurface :: (surface: *SDL_Surface, format: SDL_PixelFormat) -> *SDL_Surface #foreign SDL3;
    SDL_DestroySurface :: (surface: *SDL_Surface) #foreign SDL3;
}
