// SDL_keycode.h — key code / modifier types used by the keyboard event struct.

SDL_Keycode :: u32; // virtual key code
SDL_KeyboardID :: u32;
SDL_MouseID :: u32;
SDL_JoystickID :: u32;

using SDL_Keymod :: enum_flags u16 {
    SDL_KMOD_NONE :: 0x0000;
    SDL_KMOD_LSHIFT :: 0x0001;
    SDL_KMOD_RSHIFT :: 0x0002;
    SDL_KMOD_LEVEL5 :: 0x0004;
    SDL_KMOD_LCTRL :: 0x0040;
    SDL_KMOD_RCTRL :: 0x0080;
    SDL_KMOD_LALT :: 0x0100;
    SDL_KMOD_RALT :: 0x0200;
    SDL_KMOD_LGUI :: 0x0400;
    SDL_KMOD_RGUI :: 0x0800;
    SDL_KMOD_NUM :: 0x1000;
    SDL_KMOD_CAPS :: 0x2000;
    SDL_KMOD_MODE :: 0x4000;
    SDL_KMOD_SCROLL :: 0x8000;
    SDL_KMOD_CTRL :: (SDL_KMOD_LCTRL | SDL_KMOD_RCTRL);
    SDL_KMOD_SHIFT :: (SDL_KMOD_LSHIFT | SDL_KMOD_RSHIFT);
    SDL_KMOD_ALT :: (SDL_KMOD_LALT | SDL_KMOD_RALT);
    SDL_KMOD_GUI :: (SDL_KMOD_LGUI | SDL_KMOD_RGUI);
}
