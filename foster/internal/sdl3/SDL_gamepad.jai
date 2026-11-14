// SDL_gamepad.h — subset used by the input provider

SDL_Gamepad :: void;

#if OS != .WASM {
    SDL_IsGamepad :: (instance_id: SDL_JoystickID) -> bool #foreign SDL3;
    SDL_OpenGamepad :: (instance_id: SDL_JoystickID) -> *SDL_Gamepad #foreign SDL3;
    SDL_CloseGamepad :: (gamepad: *SDL_Gamepad) #foreign SDL3;
    SDL_GetGamepadFromID :: (instance_id: SDL_JoystickID) -> *SDL_Gamepad #foreign SDL3;
    SDL_GetGamepadName :: (gamepad: *SDL_Gamepad) -> *u8 #foreign SDL3;
    SDL_GetGamepadType :: (gamepad: *SDL_Gamepad) -> s32 #foreign SDL3;
    SDL_GetGamepadVendor :: (gamepad: *SDL_Gamepad) -> u16 #foreign SDL3;
    SDL_GetGamepadProduct :: (gamepad: *SDL_Gamepad) -> u16 #foreign SDL3;
    SDL_GetGamepadProductVersion :: (gamepad: *SDL_Gamepad) -> u16 #foreign SDL3;
    SDL_RumbleGamepad :: (gamepad: *SDL_Gamepad, low_frequency_rumble: u16, high_frequency_rumble: u16, duration_ms: u32) -> bool #foreign SDL3;
    SDL_AddGamepadMapping :: (mapping_string: *u8) -> s32 #foreign SDL3;
}
