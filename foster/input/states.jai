#scope_module
using Basic;

SB :: #import "Basic";

using Math;
using Hash_Table;
#scope_export

// Port of Foster Framework/Input/{KeyboardState, MouseState, ControllerState,
// InputState}.cs — triple-buffered input states (Last/Current/Next) with
// pressed/down/released semantics + timestamps, text, wheel, controllers.

KEYBOARD_MAX_KEYS :: 512;
MOUSE_MAX_BUTTONS :: 6; // Mouse_Buttons values run 0(NONE)..5(X2); arrays must hold index 5
CONTROLLER_MAX :: 32;
CONTROLLER_MAX_BUTTONS :: 64;
CONTROLLER_MAX_AXES :: 64;

Input_Enabled_Flags :: enum_flags u32 {
    NONE :: 0;
    KEYBOARD_KEYS :: 1 << 0;
    TEXT :: 1 << 1;
    CONTROLLER_BUTTONS :: 1 << 2;
    CONTROLLER_AXIS :: 1 << 3;
    MOUSE_BUTTONS :: 1 << 4;
    MOUSE_MOTION :: 1 << 5;
    MOUSE_WHEEL :: 1 << 6;
    ALL :: 0xFFFFFFFF;
}

// global repeat settings (Foster: Input.RepeatDelay / RepeatInterval)
Input_RepeatDelay: float = 0.4;
Input_RepeatInterval: float = 0.03;

//
// KeyboardState
//

Keyboard_State :: struct {
    pressed: [KEYBOARD_MAX_KEYS] bool;
    down: [KEYBOARD_MAX_KEYS] bool;
    released: [KEYBOARD_MAX_KEYS] bool;
    timestamp: [KEYBOARD_MAX_KEYS] float64; // elapsed seconds at press
    time: Time;

    Text: String_Builder; // UTF-8 text this frame
    InputTimestamp: float64; // elapsed seconds of last key event
}

keyboard_state_clear :: (k: *Keyboard_State) {
    for *p, i: k.pressed p.* = false;
    for *d, i: k.down d.* = false;
    for *r, i: k.released r.* = false;
    for *t, i: k.timestamp t.* = 0;
    SB.reset(*k.Text);
    k.InputTimestamp = 0;
}

keyboard_state_copy :: (from: *Keyboard_State, to: *Keyboard_State) {
    for i: 0..KEYBOARD_MAX_KEYS - 1 {
        to.pressed[i] = from.pressed[i];
        to.down[i] = from.down[i];
        to.released[i] = from.released[i];
        to.timestamp[i] = from.timestamp[i];
    }
    SB.reset(*to.Text);
    SB.append(*to.Text, builder_to_string(*from.Text));
    to.time = from.time;
    to.InputTimestamp = from.InputTimestamp;
}

keyboard_state_step :: (k: *Keyboard_State, time: Time) {
    for *p, i: k.pressed p.* = false;
    for *r, i: k.released r.* = false;
    SB.reset(*k.Text);
    k.time = time;
}

keyboard_state_on_key :: (k: *Keyboard_State, key_index: s32, key_pressed: bool, elapsed: float64) {
    if key_index >= 0 && key_index < KEYBOARD_MAX_KEYS {
        if key_pressed {
            k.down[key_index] = true;
            k.pressed[key_index] = true;
            k.timestamp[key_index] = elapsed;
            k.InputTimestamp = elapsed;
        } else {
            k.down[key_index] = false;
            k.released[key_index] = true;
        }
    }
}

keyboard_pressed :: (k: *Keyboard_State, key: Keys) -> bool {
    return k.pressed[cast(s32) key];
}

keyboard_pressed2 :: (k: *Keyboard_State, a: Keys, b: Keys) -> bool {
    return k.pressed[cast(s32) a] || k.pressed[cast(s32) b];
}

keyboard_pressed3 :: (k: *Keyboard_State, a: Keys, b: Keys, c: Keys) -> bool {
    return k.pressed[cast(s32) a] || k.pressed[cast(s32) b] || k.pressed[cast(s32) c];
}

keyboard_down :: (k: *Keyboard_State, key: Keys) -> bool {
    return k.down[cast(s32) key];
}

keyboard_down2 :: (k: *Keyboard_State, a: Keys, b: Keys) -> bool {
    return k.down[cast(s32) a] || k.down[cast(s32) b];
}

keyboard_down3 :: (k: *Keyboard_State, a: Keys, b: Keys, c: Keys) -> bool {
    return k.down[cast(s32) a] || k.down[cast(s32) b] || k.down[cast(s32) c];
}

keyboard_released :: (k: *Keyboard_State, key: Keys) -> bool {
    return k.released[cast(s32) key];
}

keyboard_released2 :: (k: *Keyboard_State, a: Keys, b: Keys) -> bool {
    return k.released[cast(s32) a] || k.released[cast(s32) b];
}

keyboard_released3 :: (k: *Keyboard_State, a: Keys, b: Keys, c: Keys) -> bool {
    return k.released[cast(s32) a] || k.released[cast(s32) b] || k.released[cast(s32) c];
}

keyboard_repeated :: (k: *Keyboard_State, key: Keys, delay: float = -1, interval: float = -1) -> bool {
    if delay < 0 delay = Input_RepeatDelay;
    if interval < 0 interval = Input_RepeatInterval;
    if keyboard_pressed(k, key) return true;
    stamp := k.timestamp[cast(s32) key];
    if !keyboard_down(k, key) return false;
    if k.time.elapsed - stamp <= delay return false;
    // OnInterval(interval, stamp)
    delta := k.time.elapsed - k.time.previous;
    return floor((k.time.elapsed - interval_offset(stamp, interval)) / interval) > floor((k.time.previous - interval_offset(stamp, interval)) / interval);
}

// maps the interval grid so the first repeat fires one interval after (stamp+delay)
interval_offset :: (stamp: float64, interval: float64) -> float64 {
    return 0;
}

keyboard_pressed_or_repeated :: (k: *Keyboard_State, key: Keys) -> bool {
    return keyboard_pressed(k, key) || keyboard_repeated(k, key);
}

keyboard_timestamp :: (k: *Keyboard_State, key: Keys) -> float64 {
    return k.timestamp[cast(s32) key];
}

keyboard_first_down :: (k: *Keyboard_State) -> s32 {
    for i: 0..KEYBOARD_MAX_KEYS - 1 if k.down[i] return cast(s32) i;
    return -1;
}

keyboard_first_pressed :: (k: *Keyboard_State) -> s32 {
    for i: 0..KEYBOARD_MAX_KEYS - 1 if k.pressed[i] return cast(s32) i;
    return -1;
}

keyboard_first_released :: (k: *Keyboard_State) -> s32 {
    for i: 0..KEYBOARD_MAX_KEYS - 1 if k.released[i] return cast(s32) i;
    return -1;
}

keyboard_ctrl :: (k: *Keyboard_State) -> bool {
    return keyboard_down2(k, .LEFT_CONTROL, .RIGHT_CONTROL);
}

keyboard_alt :: (k: *Keyboard_State) -> bool {
    return keyboard_down2(k, .LEFT_ALT, .RIGHT_ALT);
}

keyboard_shift :: (k: *Keyboard_State) -> bool {
    return keyboard_down2(k, .LEFT_SHIFT, .RIGHT_SHIFT);
}

//
// MouseState
//

Mouse_State :: struct {
    Position: Vector2;
    Delta: Vector2;
    WheelValue: Vector2;

    pressed: [MOUSE_MAX_BUTTONS] bool;
    down: [MOUSE_MAX_BUTTONS] bool;
    released: [MOUSE_MAX_BUTTONS] bool;
    timestamp: [MOUSE_MAX_BUTTONS] float64;

    motion_timestamp: float64;
    time: Time;
    InputTimestamp: float64;
}

mouse_state_clear :: (m: *Mouse_State) {
    for *p, i: m.pressed p.* = false;
    for *d, i: m.down d.* = false;
    for *r, i: m.released r.* = false;
    for *t, i: m.timestamp t.* = 0;
    m.Position = .{ 0, 0 };
    m.Delta = .{ 0, 0 };
    m.WheelValue = .{ 0, 0 };
    m.motion_timestamp = 0;
    m.InputTimestamp = 0;
}

mouse_state_copy :: (from: *Mouse_State, to: *Mouse_State) {
    for i: 0..MOUSE_MAX_BUTTONS - 1 {
        to.pressed[i] = from.pressed[i];
        to.down[i] = from.down[i];
        to.released[i] = from.released[i];
        to.timestamp[i] = from.timestamp[i];
    }
    to.Position = from.Position;
    to.Delta = from.Delta;
    to.WheelValue = from.WheelValue;
    to.time = from.time;
    to.motion_timestamp = from.motion_timestamp;
    to.InputTimestamp = from.InputTimestamp;
}

mouse_state_step :: (m: *Mouse_State, time: Time) {
    for *p, i: m.pressed p.* = false;
    for *r, i: m.released r.* = false;
    m.WheelValue = .{ 0, 0 };
    m.Delta = .{ 0, 0 };
    m.time = time;
}

mouse_state_on_button :: (m: *Mouse_State, button_index: s32, button_pressed: bool, elapsed: float64) {
    if button_index >= 0 && button_index < MOUSE_MAX_BUTTONS {
        if button_pressed {
            m.down[button_index] = true;
            m.pressed[button_index] = true;
            m.timestamp[button_index] = elapsed;
            m.InputTimestamp = elapsed;
        } else {
            m.down[button_index] = false;
            m.released[button_index] = true;
        }
    }
}

mouse_state_on_motion :: (m: *Mouse_State, position: Vector2, delta: Vector2, elapsed: float64) {
    m.Position = position;
    m.Delta = delta;
    m.motion_timestamp = elapsed;
    m.InputTimestamp = elapsed;
}

mouse_state_on_wheel :: (m: *Mouse_State, value: Vector2) {
    m.WheelValue = value;
}

mouse_pressed :: (m: *Mouse_State, button: Mouse_Buttons) -> bool {
    return m.pressed[cast(s32) button];
}

mouse_down :: (m: *Mouse_State, button: Mouse_Buttons) -> bool {
    return m.down[cast(s32) button];
}

mouse_released :: (m: *Mouse_State, button: Mouse_Buttons) -> bool {
    return m.released[cast(s32) button];
}

mouse_pressed_timestamp :: (m: *Mouse_State, button: Mouse_Buttons) -> float64 {
    return m.timestamp[cast(s32) button];
}

mouse_motion_timestamp :: (m: *Mouse_State) -> float64 {
    return m.motion_timestamp;
}

mouse_wheel :: (m: *Mouse_State) -> Vector2 {
    return m.WheelValue;
}

//
// ControllerState
//

Controller_ID :: u32; // SDL joystick instance id

Gamepad_Types :: enum u32 {
    UNKNOWN :: 0;
    XBOX_360;
    XBOX_ONE;
    PS4;
    PS5;
    SWITCH_PRO;
    SWITCH_JOYCON_LEFT;
    SWITCH_JOYCON_RIGHT;
    VIRTUAL;
}

Controller_State :: struct {
    Index: s32; // slot 0..31
    Connected: bool;

    ID: Controller_ID;
    Name: string;
    IsGamepad: bool;
    GamepadType: Gamepad_Types;
    Vendor: u16;
    Product: u16;
    Version: u16;

    pressed: [CONTROLLER_MAX_BUTTONS] bool;
    down: [CONTROLLER_MAX_BUTTONS] bool;
    released: [CONTROLLER_MAX_BUTTONS] bool;
    timestamp: [CONTROLLER_MAX_BUTTONS] float64;

    axis: [CONTROLLER_MAX_AXES] float;
    axis_timestamp: [CONTROLLER_MAX_AXES] float64;

    Buttons: s32; // count
    Axes: s32; // count
    InputTimestamp: float64;
    time: Time;
}

controller_state_clear :: (c: *Controller_State) {
    c.Connected = false;
    c.ID = 0;
    c.Name = "Unknown";
    c.IsGamepad = false;
    c.GamepadType = .UNKNOWN;
    c.Vendor = 0;
    c.Product = 0;
    c.Version = 0;
    for *p, i: c.pressed p.* = false;
    for *d, i: c.down d.* = false;
    for *r, i: c.released r.* = false;
    for *t, i: c.timestamp t.* = 0;
    for *a, i: c.axis a.* = 0;
    for *t, i: c.axis_timestamp t.* = 0;
    c.Buttons = 0;
    c.Axes = 0;
    c.InputTimestamp = 0;
}

controller_state_connect :: (c: *Controller_State, id: Controller_ID, name: string,
                             button_count: s32, axis_count: s32, is_gamepad: bool,
                             gamepad_type: Gamepad_Types, vendor: u16, product: u16, version: u16) {
    controller_state_clear(c);
    c.Connected = true;
    c.ID = id;
    c.Name = name;
    c.Buttons = button_count;
    c.Axes = axis_count;
    c.IsGamepad = is_gamepad;
    c.GamepadType = gamepad_type;
    c.Vendor = vendor;
    c.Product = product;
    c.Version = version;
}

controller_state_copy :: (from: *Controller_State, to: *Controller_State) {
    index := to.Index;
    memcpy(to, from, size_of(Controller_State));
    to.Index = index;
}

controller_state_step :: (c: *Controller_State, time: Time) {
    for *p, i: c.pressed p.* = false;
    for *r, i: c.released r.* = false;
    c.time = time;
}

controller_state_on_button :: (c: *Controller_State, button_index: s32, button_pressed: bool, elapsed: float64) {
    if button_index >= 0 && button_index < CONTROLLER_MAX_BUTTONS {
        if button_pressed {
            c.down[button_index] = true;
            c.pressed[button_index] = true;
            c.timestamp[button_index] = elapsed;
            c.InputTimestamp = elapsed;
        } else {
            c.down[button_index] = false;
            c.released[button_index] = true;
        }
    }
}

controller_state_on_axis :: (c: *Controller_State, axis_index: s32, value: float, elapsed: float64) {
    if axis_index >= 0 && axis_index < CONTROLLER_MAX_AXES {
        c.axis[axis_index] = value;
        // Foster: bump InputTimestamp only when the axis is meaningfully engaged
        if abs(value) > 0.5 {
            c.axis_timestamp[axis_index] = elapsed;
            c.InputTimestamp = elapsed;
        }
    }
}

controller_pressed :: (c: *Controller_State, button: Buttons) -> bool {
    return c.pressed[cast(s32) button];
}

controller_down :: (c: *Controller_State, button: Buttons) -> bool {
    return c.down[cast(s32) button];
}

controller_released :: (c: *Controller_State, button: Buttons) -> bool {
    return c.released[cast(s32) button];
}

controller_axis :: (c: *Controller_State, axis: Axes) -> float {
    return c.axis[cast(s32) axis];
}

// normalized -1..1 with y-down, matching SDL gamepad axis orientation
controller_left_stick :: (c: *Controller_State, deadzone := 0.0) -> Vector2 {
    x := controller_axis(c, .LEFT_X);
    y := controller_axis(c, .LEFT_Y);
    return .{ x, y };
}

controller_right_stick :: (c: *Controller_State, deadzone := 0.0) -> Vector2 {
    x := controller_axis(c, .RIGHT_X);
    y := controller_axis(c, .RIGHT_Y);
    return .{ x, y };
}

//
// InputState (container)
//

Input_State :: struct {
    Keyboard: Keyboard_State;
    Mouse: Mouse_State;
    Controllers: [CONTROLLER_MAX] Controller_State;
}

input_state_clear :: (s: *Input_State) {
    keyboard_state_clear(*s.Keyboard);
    mouse_state_clear(*s.Mouse);
    for *c, i: s.Controllers {
        idx := c.Index;
        controller_state_clear(c);
        c.Index = idx;
    }
}

input_state_copy :: (from: *Input_State, to: *Input_State) {
    keyboard_state_copy(*from.Keyboard, *to.Keyboard);
    mouse_state_copy(*from.Mouse, *to.Mouse);
    for i: 0..CONTROLLER_MAX - 1 controller_state_copy(*from.Controllers[i], *to.Controllers[i]);
}

input_state_step :: (s: *Input_State, time: Time) {
    keyboard_state_step(*s.Keyboard, time);
    mouse_state_step(*s.Mouse, time);
    for *c, i: s.Controllers controller_state_step(c, time);
}

input_state_get_controller :: (s: *Input_State, id: Controller_ID) -> *Controller_State {
    for *c, i: s.Controllers if c.Connected && c.ID == id return c;
    return null;
}
