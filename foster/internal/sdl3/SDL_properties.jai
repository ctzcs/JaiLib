// SDL_properties.h

SDL_PropertiesID :: u32;

#if OS != .WASM {
SDL_CreateProperties  :: () -> SDL_PropertiesID #foreign SDL3;
SDL_DestroyProperties :: (props: SDL_PropertiesID) #foreign SDL3;
SDL_SetStringProperty :: (props: SDL_PropertiesID, name: *u8, value: *u8) -> bool #foreign SDL3;
SDL_GetPointerProperty :: (props: SDL_PropertiesID, name: *u8, default_value: *void) -> *void #foreign SDL3;
}
