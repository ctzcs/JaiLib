// SDL_init.h

using SDL_InitFlags :: enum_flags u32 {
    SDL_INIT_AUDIO    :: 0x00000010;
    SDL_INIT_VIDEO    :: 0x00000020;
    SDL_INIT_JOYSTICK :: 0x00000200;
    SDL_INIT_HAPTIC   :: 0x00001000;
    SDL_INIT_GAMEPAD  :: 0x00002000;
    SDL_INIT_EVENTS   :: 0x00004000;
    SDL_INIT_SENSOR   :: 0x00008000;
    SDL_INIT_CAMERA   :: 0x00010000;
}

#if OS != .WASM {
SDL_Init         :: (flags: SDL_InitFlags) -> bool #foreign SDL3;
SDL_InitSubSystem :: (flags: SDL_InitFlags) -> bool #foreign SDL3;
SDL_QuitSubSystem :: (flags: SDL_InitFlags) #foreign SDL3;
SDL_WasInit      :: (flags: SDL_InitFlags) -> SDL_InitFlags #foreign SDL3;
SDL_Quit         :: () #foreign SDL3;
}
