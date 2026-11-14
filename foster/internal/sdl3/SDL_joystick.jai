// SDL_joystick.h — subset used by the input provider

SDL_Joystick :: void;

#if OS != .WASM {
    SDL_OpenJoystick :: (instance_id: SDL_JoystickID) -> *SDL_Joystick #foreign SDL3;
    SDL_CloseJoystick :: (joystick: *SDL_Joystick) #foreign SDL3;
    SDL_GetJoystickFromID :: (instance_id: SDL_JoystickID) -> *SDL_Joystick #foreign SDL3;
    SDL_GetJoystickName :: (joystick: *SDL_Joystick) -> *u8 #foreign SDL3;
    SDL_GetJoystickVendor :: (joystick: *SDL_Joystick) -> u16 #foreign SDL3;
    SDL_GetJoystickProduct :: (joystick: *SDL_Joystick) -> u16 #foreign SDL3;
    SDL_GetJoystickProductVersion :: (joystick: *SDL_Joystick) -> u16 #foreign SDL3;
    SDL_GetNumJoystickButtons :: (joystick: *SDL_Joystick) -> s32 #foreign SDL3;
    SDL_GetNumJoystickAxes :: (joystick: *SDL_Joystick) -> s32 #foreign SDL3;
    SDL_RumbleJoystick :: (joystick: *SDL_Joystick, low_frequency_rumble: u16, high_frequency_rumble: u16, duration_ms: u32) -> bool #foreign SDL3;
}
