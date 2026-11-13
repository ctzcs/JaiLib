#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Input/Enums/{Keys, Buttons, Axes, MouseButtons,
// GamepadTypes, GamepadProviders}.cs. Keys values match SDL scancodes
// (same as Foster); Buttons/Axes match SDL_GamepadButton/Axis order.

Keys :: enum u32 {
    UNKNOWN :: 0;
    A :: 4;
    B :: 5;
    C :: 6;
    D :: 7;
    E :: 8;
    F :: 9;
    G :: 10;
    H :: 11;
    I :: 12;
    J :: 13;
    K :: 14;
    L :: 15;
    M :: 16;
    N :: 17;
    O :: 18;
    P :: 19;
    Q :: 20;
    R :: 21;
    S :: 22;
    T :: 23;
    U :: 24;
    V :: 25;
    W :: 26;
    X :: 27;
    Y :: 28;
    Z :: 29;
    NUM_1 :: 30;
    NUM_2 :: 31;
    NUM_3 :: 32;
    NUM_4 :: 33;
    NUM_5 :: 34;
    NUM_6 :: 35;
    NUM_7 :: 36;
    NUM_8 :: 37;
    NUM_9 :: 38;
    NUM_0 :: 39;
    RETURN :: 40;
    ESCAPE :: 41;
    BACKSPACE :: 42;
    TAB :: 43;
    SPACE :: 44;
    MINUS :: 45;
    EQUALS :: 46;
    LEFT_BRACKET :: 47;
    RIGHT_BRACKET :: 48;
    BACKSLASH :: 49;
    SEMICOLON :: 51;
    APOSTROPHE :: 52;
    GRAVE :: 53;
    COMMA :: 54;
    PERIOD :: 55;
    SLASH :: 56;
    CAPS_LOCK :: 57;
    F1 :: 58;
    F2 :: 59;
    F3 :: 60;
    F4 :: 61;
    F5 :: 62;
    F6 :: 63;
    F7 :: 64;
    F8 :: 65;
    F9 :: 66;
    F10 :: 67;
    F11 :: 68;
    F12 :: 69;
    PRINT_SCREEN :: 70;
    SCROLL_LOCK :: 71;
    PAUSE :: 72;
    INSERT :: 73;
    HOME :: 74;
    PAGE_UP :: 75;
    DELETE :: 76;
    END :: 77;
    PAGE_DOWN :: 78;
    RIGHT :: 79;
    LEFT :: 80;
    DOWN :: 81;
    UP :: 82;
    NUM_LOCK :: 83;
    KP_DIVIDE :: 84;
    KP_MULTIPLY :: 85;
    KP_MINUS :: 86;
    KP_PLUS :: 87;
    KP_ENTER :: 88;
    KP_1 :: 89;
    KP_2 :: 90;
    KP_3 :: 91;
    KP_4 :: 92;
    KP_5 :: 93;
    KP_6 :: 94;
    KP_7 :: 95;
    KP_8 :: 96;
    KP_9 :: 97;
    KP_0 :: 98;
    KP_PERIOD :: 99;
    LEFT_CONTROL :: 224;
    LEFT_SHIFT :: 225;
    LEFT_ALT :: 226;
    LEFT_OS :: 227;
    RIGHT_CONTROL :: 228;
    RIGHT_SHIFT :: 229;
    RIGHT_ALT :: 230;
    RIGHT_OS :: 231;
}

Mouse_Buttons :: enum u32 {
    NONE  :: 0;
    LEFT  :: 1;
    MIDDLE :: 2;
    RIGHT :: 3;
    X1    :: 4;
    X2    :: 5;
}

Buttons :: enum u32 {
    NONE :: 0xFFFFFFFF;
    SOUTH :: 0;
    EAST :: 1;
    WEST :: 2;
    NORTH :: 3;
    BACK :: 4;
    SELECT :: 5;
    START :: 6;
    GUIDE :: 7;
    LEFT_STICK :: 8;
    RIGHT_STICK :: 9;
    LEFT_SHOULDER :: 10;
    RIGHT_SHOULDER :: 11;
    DPAD_UP :: 12;
    DPAD_DOWN :: 13;
    DPAD_LEFT :: 14;
    DPAD_RIGHT :: 15;
    MISC_1 :: 16;
    RIGHT_PADDLE_1 :: 17;
    LEFT_PADDLE_1 :: 18;
    RIGHT_PADDLE_2 :: 19;
    LEFT_PADDLE_2 :: 20;
}

Axes :: enum u32 {
    NONE :: 0xFFFFFFFF;
    LEFT_X :: 0;
    LEFT_Y :: 1;
    RIGHT_X :: 2;
    RIGHT_Y :: 3;
    LEFT_TRIGGER :: 4;
    RIGHT_TRIGGER :: 5;
}

// maps a SDL_Scancode to a Keys value (identity — Keys values ARE SDL scancodes)
key_from_sdl :: (scancode: SDL_Scancode) -> Keys {
    return cast(Keys) scancode;
}

mouse_button_from_sdl :: (button: u8) -> Mouse_Buttons {
    if button >= SDL_BUTTON_LEFT && button <= SDL_BUTTON_X2 {
        return cast(Mouse_Buttons) button;
    }
    return .NONE;
}
