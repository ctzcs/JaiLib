// SDL_events.h — event types, event structs, SDL_Event union and the pump/poll/watch API.
// Struct layouts transcribed from SDL 3.4.12 SDL_events.h (every event starts with
// type(u32) + reserved(u32) + timestamp(u64)).

using SDL_EventType :: enum u32 {
    SDL_EVENT_FIRST :: 0;
    SDL_EVENT_QUIT :: 0x100;
    SDL_EVENT_TERMINATING;
    SDL_EVENT_LOW_MEMORY;
    SDL_EVENT_WILL_ENTER_BACKGROUND;
    SDL_EVENT_DID_ENTER_BACKGROUND;
    SDL_EVENT_WILL_ENTER_FOREGROUND;
    SDL_EVENT_DID_ENTER_FOREGROUND;
    SDL_EVENT_LOCALE_CHANGED;
    SDL_EVENT_SYSTEM_THEME_CHANGED;

    SDL_EVENT_DISPLAY_ORIENTATION :: 0x151;
    SDL_EVENT_DISPLAY_ADDED;
    SDL_EVENT_DISPLAY_REMOVED;
    SDL_EVENT_DISPLAY_MOVED;
    SDL_EVENT_DISPLAY_DESKTOP_MODE_CHANGED;
    SDL_EVENT_DISPLAY_CURRENT_MODE_CHANGED;
    SDL_EVENT_DISPLAY_CONTENT_SCALE_CHANGED;
    SDL_EVENT_DISPLAY_USABLE_BOUNDS_CHANGED;

    SDL_EVENT_WINDOW_SHOWN :: 0x202;
    SDL_EVENT_WINDOW_HIDDEN;
    SDL_EVENT_WINDOW_EXPOSED;
    SDL_EVENT_WINDOW_MOVED;
    SDL_EVENT_WINDOW_RESIZED;
    SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
    SDL_EVENT_WINDOW_METAL_VIEW_RESIZED;
    SDL_EVENT_WINDOW_MINIMIZED;
    SDL_EVENT_WINDOW_MAXIMIZED;
    SDL_EVENT_WINDOW_RESTORED;
    SDL_EVENT_WINDOW_MOUSE_ENTER;
    SDL_EVENT_WINDOW_MOUSE_LEAVE;
    SDL_EVENT_WINDOW_FOCUS_GAINED;
    SDL_EVENT_WINDOW_FOCUS_LOST;
    SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    SDL_EVENT_WINDOW_HIT_TEST;
    SDL_EVENT_WINDOW_ICCPROF_CHANGED;
    SDL_EVENT_WINDOW_DISPLAY_CHANGED;
    SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED;
    SDL_EVENT_WINDOW_SAFE_AREA_CHANGED;
    SDL_EVENT_WINDOW_OCCLUDED;
    SDL_EVENT_WINDOW_ENTER_FULLSCREEN;
    SDL_EVENT_WINDOW_LEAVE_FULLSCREEN;
    SDL_EVENT_WINDOW_DESTROYED;
    SDL_EVENT_WINDOW_HDR_STATE_CHANGED;

    SDL_EVENT_KEY_DOWN :: 0x300;
    SDL_EVENT_KEY_UP;
    SDL_EVENT_TEXT_EDITING;
    SDL_EVENT_TEXT_INPUT;
    SDL_EVENT_KEYMAP_CHANGED;
    SDL_EVENT_KEYBOARD_ADDED;
    SDL_EVENT_KEYBOARD_REMOVED;
    SDL_EVENT_TEXT_EDITING_CANDIDATES;
    SDL_EVENT_SCREEN_KEYBOARD_SHOWN;
    SDL_EVENT_SCREEN_KEYBOARD_HIDDEN;

    SDL_EVENT_MOUSE_MOTION :: 0x400;
    SDL_EVENT_MOUSE_BUTTON_DOWN;
    SDL_EVENT_MOUSE_BUTTON_UP;
    SDL_EVENT_MOUSE_WHEEL;
    SDL_EVENT_MOUSE_ADDED;
    SDL_EVENT_MOUSE_REMOVED;

    SDL_EVENT_JOYSTICK_AXIS_MOTION :: 0x600;
    SDL_EVENT_JOYSTICK_BALL_MOTION;
    SDL_EVENT_JOYSTICK_HAT_MOTION;
    SDL_EVENT_JOYSTICK_BUTTON_DOWN;
    SDL_EVENT_JOYSTICK_BUTTON_UP;
    SDL_EVENT_JOYSTICK_ADDED;
    SDL_EVENT_JOYSTICK_REMOVED;
    SDL_EVENT_JOYSTICK_BATTERY_UPDATED;
    SDL_EVENT_JOYSTICK_UPDATE_COMPLETE;

    SDL_EVENT_GAMEPAD_AXIS_MOTION :: 0x650;
    SDL_EVENT_GAMEPAD_BUTTON_DOWN;
    SDL_EVENT_GAMEPAD_BUTTON_UP;
    SDL_EVENT_GAMEPAD_ADDED;
    SDL_EVENT_GAMEPAD_REMOVED;
    SDL_EVENT_GAMEPAD_REMAPPED;
    SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN;
    SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION;
    SDL_EVENT_GAMEPAD_TOUCHPAD_UP;
    SDL_EVENT_GAMEPAD_SENSOR_UPDATE;
    SDL_EVENT_GAMEPAD_UPDATE_COMPLETE;
    SDL_EVENT_GAMEPAD_STEAM_HANDLE_UPDATED;

    SDL_EVENT_FINGER_DOWN :: 0x700;
    SDL_EVENT_FINGER_UP;
    SDL_EVENT_FINGER_MOTION;
    SDL_EVENT_FINGER_CANCELED;

    SDL_EVENT_PINCH_BEGIN :: 0x710;
    SDL_EVENT_PINCH_UPDATE;
    SDL_EVENT_PINCH_END;

    SDL_EVENT_CLIPBOARD_UPDATE :: 0x900;

    SDL_EVENT_DROP_FILE :: 0x1000;
    SDL_EVENT_DROP_TEXT;
    SDL_EVENT_DROP_BEGIN;
    SDL_EVENT_DROP_COMPLETE;
    SDL_EVENT_DROP_POSITION;

    SDL_EVENT_AUDIO_DEVICE_ADDED :: 0x1100;
    SDL_EVENT_AUDIO_DEVICE_REMOVED;
    SDL_EVENT_AUDIO_DEVICE_FORMAT_CHANGED;

    SDL_EVENT_SENSOR_UPDATE :: 0x1200;

    SDL_EVENT_PEN_PROXIMITY_IN :: 0x1300;
    SDL_EVENT_PEN_PROXIMITY_OUT;
    SDL_EVENT_PEN_DOWN;
    SDL_EVENT_PEN_UP;
    SDL_EVENT_PEN_BUTTON_DOWN;
    SDL_EVENT_PEN_BUTTON_UP;
    SDL_EVENT_PEN_MOTION;
    SDL_EVENT_PEN_AXIS;

    SDL_EVENT_CAMERA_DEVICE_ADDED :: 0x1400;
    SDL_EVENT_CAMERA_DEVICE_REMOVED;
    SDL_EVENT_CAMERA_DEVICE_APPROVED;
    SDL_EVENT_CAMERA_DEVICE_DENIED;

    SDL_EVENT_RENDER_TARGETS_RESET :: 0x2000;
    SDL_EVENT_RENDER_DEVICE_RESET;
    SDL_EVENT_RENDER_DEVICE_LOST;

    SDL_EVENT_PRIVATE0 :: 0x4000;
    SDL_EVENT_PRIVATE1;
    SDL_EVENT_PRIVATE2;
    SDL_EVENT_PRIVATE3;

    SDL_EVENT_POLL_SENTINEL :: 0x7F00;
    SDL_EVENT_USER    :: 0x8000;
    SDL_EVENT_LAST    :: 0xFFFF;
}

SDL_CommonEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;    // nanoseconds
}

SDL_WindowEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    windowID: SDL_WindowID;
    data1: s32;
    data2: s32;
}

SDL_KeyboardDeviceEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    which: SDL_KeyboardID;
}

SDL_KeyboardEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    windowID: SDL_WindowID;
    which: SDL_KeyboardID;
    scancode: SDL_Scancode;
    key: SDL_Keycode;
    mod: SDL_Keymod;
    raw: u16;
    down: bool;
    repeat: bool;
}

SDL_TextEditingEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    windowID: SDL_WindowID;
    text: *u8;
    start: s32;
    length: s32;
}

SDL_TextInputEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    windowID: SDL_WindowID;
    text: *u8;         // UTF-8
}

SDL_MouseDeviceEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    which: SDL_MouseID;
}

SDL_MouseMotionEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    windowID: SDL_WindowID;
    which: SDL_MouseID;
    state: SDL_MouseButtonFlags;
    x: float;
    y: float;
    xrel: float;
    yrel: float;
}

SDL_MouseButtonEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    windowID: SDL_WindowID;
    which: SDL_MouseID;
    button: u8;
    down: bool;
    clicks: u8;
    padding: u8;
    x: float;
    y: float;
}

SDL_MouseWheelEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    windowID: SDL_WindowID;
    which: SDL_MouseID;
    x: float;
    y: float;
    direction: SDL_MouseWheelDirection;
    mouse_x: float;
    mouse_y: float;
    integer_x: s32;
    integer_y: s32;
}

SDL_JoyAxisEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    which: SDL_JoystickID;
    axis: u8;
    padding1: u8;
    padding2: u8;
    padding3: u8;
    value: s16;
    padding4: u16;
}

SDL_JoyButtonEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    which: SDL_JoystickID;
    button: u8;
    down: bool;
    padding1: u8;
    padding2: u8;
}

SDL_JoyDeviceEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    which: SDL_JoystickID;
}

SDL_GamepadAxisEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    which: SDL_JoystickID;
    axis: u8;
    padding1: u8;
    padding2: u8;
    padding3: u8;
    value: s16;
    padding4: u16;
}

SDL_GamepadButtonEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    which: SDL_JoystickID;
    button: u8;
    down: bool;
    padding1: u8;
    padding2: u8;
}

SDL_GamepadDeviceEvent :: struct {
    type: SDL_EventType;
    reserved: u32;
    timestamp: u64;
    which: SDL_JoystickID;
}

SDL_UserEvent :: struct {
    type: u32;
    reserved: u32;
    timestamp: u64;
    windowID: SDL_WindowID;
    code: s32;
    data1: *void;
    data2: *void;
}

// Mirrors the C union including its explicit padding member (forces 128 bytes
// so MSVC and GCC agree on the ABI). `type` is declared as SDL_EventType
// (enum u32) rather than u32 so `if event.type == { case ...; }` works
// directly — same choice as Jai's bundled SDL2 module; user-event values
// outside the enum still round-trip since the backing type is u32.
SDL_Event :: union {
    type: SDL_EventType;
    common:  SDL_CommonEvent;
    window:  SDL_WindowEvent;
    kdevice: SDL_KeyboardDeviceEvent;
    key:     SDL_KeyboardEvent;
    edit:    SDL_TextEditingEvent;
    text:    SDL_TextInputEvent;
    mdevice: SDL_MouseDeviceEvent;
    motion:  SDL_MouseMotionEvent;
    button:  SDL_MouseButtonEvent;
    wheel:   SDL_MouseWheelEvent;
    jdevice: SDL_JoyDeviceEvent;
    jaxis:   SDL_JoyAxisEvent;
    jbutton: SDL_JoyButtonEvent;
    gdevice: SDL_GamepadDeviceEvent;
    gaxis:   SDL_GamepadAxisEvent;
    gbutton: SDL_GamepadButtonEvent;
    user:    SDL_UserEvent;
    padding: [128] u8;
}

SDL_EventFilter :: #type (userdata: *void, event: *SDL_Event) -> bool #c_call;

#if OS != .WASM {
SDL_PumpEvents      :: () #foreign SDL3;
SDL_PollEvent       :: (event: *SDL_Event) -> bool #foreign SDL3;
SDL_PushEvent       :: (event: *SDL_Event) -> bool #foreign SDL3;
SDL_AddEventWatch   :: (filter: SDL_EventFilter, userdata: *void) -> bool #foreign SDL3;
SDL_RemoveEventWatch :: (filter: SDL_EventFilter, userdata: *void) #foreign SDL3;
}
