using Basic;
using Math;
using Hash_Table;

// Input manager + SDL event provider. Replaces the M1 stub; wires App's
// input polling into the state machines from states.jai.

Input :: struct {
    State: Input_State;      // current
    LastState: Input_State;  // previous
    NextState: Input_State;  // accumulating

    Enabled: Input_Enabled_Flags = .ALL;

    on_text_event: (text: string, window: *Window) = null;
    on_controller_connected:    (id: Controller_ID) = null;
    on_controller_disconnected: (id: Controller_ID) = null;

    // provider internals
    last_mouse: Vector2;
    open_joysticks: [..] struct { id: u32; ptr: *SDL_Joystick; };
    open_gamepads:  [..] struct { id: u32; ptr: *SDL_Gamepad; };
}

input_create :: () -> *Input {
    i := New(Input);
    for *c, idx: i.State.Controllers      c.Index = cast(s32) idx;
    for *c, idx: i.LastState.Controllers  c.Index = cast(s32) idx;
    for *c, idx: i.NextState.Controllers  c.Index = cast(s32) idx;
    return i;
}

input_destroy :: (i: *Input) {
    free(i);
}

// convenience accessors on the CURRENT state
input_keyboard            :: (i: *Input) -> *Keyboard_State   { return *i.State.Keyboard; }
input_mouse               :: (i: *Input) -> *Mouse_State      { return *i.State.Mouse; }
input_controllers         :: (i: *Input) -> [] Controller_State { return i.State.Controllers; }
input_get_controller      :: (i: *Input, id: Controller_ID) -> *Controller_State { return input_state_get_controller(*i.State, id); }

input_clear :: (i: *Input) {
    input_state_clear(*i.State);
    input_state_clear(*i.NextState);
}

input_clipboard_set :: (i: *Input, value: string) {
    c := to_cstr(value);
    SDL_SetClipboardText(c);
    free(c);
}

input_clipboard_get :: (i: *Input) -> string {
    return cstr_to_string(SDL_GetClipboardText());
}

input_rumble :: (i: *Input, id: Controller_ID, low_intensity: float, high_intensity: float, duration: float) {
    it := input_get_controller(i, id);
    if it == null || !it.Connected return;

    high := cast(u16) (clamp(high_intensity, 0, 1) * 0xFFFF);
    low  := cast(u16) (clamp(low_intensity, 0, 1) * 0xFFFF);
    ms   := cast(u32) (duration * 1000);

    if it.IsGamepad {
        ptr := SDL_GetGamepadFromID(id);
        if ptr != null SDL_RumbleGamepad(ptr, low, high, ms);
    } else {
        ptr := SDL_GetJoystickFromID(id);
        if ptr != null SDL_RumbleJoystick(ptr, low, high, ms);
    }
}

// called by App.step — advances the state buffers
input_update :: (i: *Input, time: Time) {
    // mouse position/delta follows the window each step (Foster: provider.Update)
    if App.window != null && App.window.handle != null {
        mouse := window_mouse_position(App.window);
        delta := mouse - i.last_mouse;
        if SDL_GetWindowRelativeMouseMode(App.window.handle) {
            dx, dy: float;
            SDL_GetRelativeMouseState(*dx, *dy);
            size := window_size(App.window);
            psize := window_size_in_pixels(App.window);
            delta = .{
                dx / cast(float) size.x * cast(float) psize.x,
                dy / cast(float) size.y * cast(float) psize.y,
            };
        }
        if i.last_mouse.x != mouse.x || i.last_mouse.y != mouse.y || delta.x != 0 || delta.y != 0 {
            i.last_mouse = mouse;
            input_mouse_motion(i, mouse, delta, time.elapsed);
        }
    }

    // step the triple buffer
    input_state_copy(*i.State, *i.LastState);
    input_state_copy(*i.NextState, *i.State);
    input_state_step(*i.NextState, time);

    // virtual inputs (Foster: the `foreach (var virtualInput in virtualInputs)
    // virtualInput.Update(time);` tail of Input.Step)
    //
    // Position matters, and this is the one olib/Foster use: it runs *after*
    // the keyboard/mouse/controller state above has been published into
    // `i.State`, so an action/axis/stick binding in this frame is evaluated
    // against this frame's keys, and *before* App.update/App.render, so the
    // virtual state is already current wherever the game queries it
    // (virtual_action_pressed / virtual_axis_value / virtual_stick_value).
    //
    // It is driven from here on purpose: applications no longer have to call
    // virtual_inputs_update(App.input, App.time) by hand every frame, and the
    // registry walk uses `i` (Virtual_Input.Manager) as its filter, so inputs
    // built for another Input instance are left alone.
    virtual_inputs_update(i, time);
}

input_close_devices :: (i: *Input) {
    for it: i.open_joysticks SDL_CloseJoystick(it.ptr);
    for it: i.open_gamepads  SDL_CloseGamepad(it.ptr);
    array_reset(*i.open_joysticks);
    array_reset(*i.open_gamepads);
}

//
// event feed (called from App's poll loop)
//

input_text :: (i: *Input, text: string, window: *Window) {
    if (i.Enabled & .TEXT) != 0 {
        SB.append(*i.NextState.Keyboard.Text, text);
    }
    if i.on_text_event != null i.on_text_event(text, window);
}

input_key :: (i: *Input, key_index: s32, key_pressed: bool, elapsed: float64) {
    if (i.Enabled & .KEYBOARD_KEYS) != 0 {
        keyboard_state_on_key(*i.NextState.Keyboard, key_index, key_pressed, elapsed);
    }
}

input_mouse_button :: (i: *Input, button_index: s32, button_pressed: bool, elapsed: float64) {
    if (i.Enabled & .MOUSE_BUTTONS) != 0 {
        mouse_state_on_button(*i.NextState.Mouse, button_index, button_pressed, elapsed);
    }
}

input_mouse_motion :: (i: *Input, position: Vector2, delta: Vector2, elapsed: float64) {
    if (i.Enabled & .MOUSE_MOTION) != 0 {
        mouse_state_on_motion(*i.NextState.Mouse, position, delta, elapsed);
    }
}

input_mouse_wheel :: (i: *Input, value: Vector2) {
    if (i.Enabled & .MOUSE_WHEEL) != 0 {
        mouse_state_on_wheel(*i.NextState.Mouse, value);
    }
}

input_connect_controller :: (i: *Input, id: Controller_ID, name: string,
                             button_count: s32, axis_count: s32, is_gamepad: bool,
                             gamepad_type: Gamepad_Types, vendor: u16, product: u16, version: u16) {
    for *c, idx: i.NextState.Controllers {
        if c.Connected continue;
        controller_state_connect(c, id, name, button_count, axis_count, is_gamepad,
                                 gamepad_type, vendor, product, version);
        // Foster: ConnectController notifies the virtual devices sitting on this
        // slot (`device.ControllerConnected()`) before the general consumer
        // callback. `idx` is the slot the controller landed in, which is what a
        // VirtualDevice's ControllerIndex refers to.
        virtual_inputs_notify_controller_connected(i, cast(s32) idx);
        if i.on_controller_connected != null i.on_controller_connected(id);
        return;
    }
}

input_disconnect_controller :: (i: *Input, id: Controller_ID) {
    for *c, idx: i.NextState.Controllers {
        if c.ID != id continue;
        c.Connected = false;
        virtual_inputs_notify_controller_disconnected(i, cast(s32) idx);
        if i.on_controller_disconnected != null i.on_controller_disconnected(id);
    }
}

input_controller_button :: (i: *Input, id: Controller_ID, button: s32, pressed: bool, elapsed: float64) {
    if (i.Enabled & .CONTROLLER_BUTTONS) == 0 return;
    c := input_state_get_controller(*i.NextState, id);
    if c != null controller_state_on_button(c, button, pressed, elapsed);
}

input_controller_axis :: (i: *Input, id: Controller_ID, axis: s32, value: float, elapsed: float64) {
    if (i.Enabled & .CONTROLLER_AXIS) == 0 return;
    c := input_state_get_controller(*i.NextState, id);
    if c != null controller_state_on_axis(c, axis, value, elapsed);
}

//
// SDL event dispatch (the InputProviderSDL.OnEvent port)
//

input_on_event :: (i: *Input, ev: SDL_Event) {
    t := ev.type;

    if t == .SDL_EVENT_MOUSE_BUTTON_DOWN {
        input_mouse_button(i, cast(s32) mouse_button_from_sdl(ev.button.button), true, App.time.elapsed);
    } else if t == .SDL_EVENT_MOUSE_BUTTON_UP {
        input_mouse_button(i, cast(s32) mouse_button_from_sdl(ev.button.button), false, App.time.elapsed);
    } else if t == .SDL_EVENT_MOUSE_WHEEL {
        input_mouse_wheel(i, .{ ev.wheel.x, ev.wheel.y });
    } else if t == .SDL_EVENT_KEY_DOWN {
        if !ev.key.repeat input_key(i, cast(s32) key_from_sdl(ev.key.scancode), true, App.time.elapsed);
    } else if t == .SDL_EVENT_KEY_UP {
        if !ev.key.repeat input_key(i, cast(s32) key_from_sdl(ev.key.scancode), false, App.time.elapsed);
    } else if t == .SDL_EVENT_TEXT_INPUT {
        input_text(i, cstr_to_string(ev.text.text), App.window);
    } else if t == .SDL_EVENT_JOYSTICK_ADDED {
        id := ev.jdevice.which;
        if !SDL_IsGamepad(id) {
            ptr := SDL_OpenJoystick(id);
            array_add(*i.open_joysticks, .{ id = id, ptr = ptr });
            input_connect_controller(i, id, cstr_to_string(SDL_GetJoystickName(ptr)),
                SDL_GetNumJoystickButtons(ptr), SDL_GetNumJoystickAxes(ptr),
                false, .UNKNOWN,
                SDL_GetJoystickVendor(ptr), SDL_GetJoystickProduct(ptr), SDL_GetJoystickProductVersion(ptr));
        }
    } else if t == .SDL_EVENT_JOYSTICK_REMOVED {
        id := ev.jdevice.which;
        if !SDL_IsGamepad(id) {
            for *it, idx: i.open_joysticks {
                if it.id == id {
                    SDL_CloseJoystick(it.ptr);
                    array_unordered_remove_by_index(*i.open_joysticks, idx);
                    break;
                }
            }
            input_disconnect_controller(i, id);
        }
    } else if t == .SDL_EVENT_JOYSTICK_BUTTON_DOWN {
        id := ev.jbutton.which;
        if !SDL_IsGamepad(id) {
            input_controller_button(i, id, ev.jbutton.button, true, App.time.elapsed);
        }
    } else if t == .SDL_EVENT_JOYSTICK_BUTTON_UP {
        id := ev.jbutton.which;
        if !SDL_IsGamepad(id) {
            input_controller_button(i, id, ev.jbutton.button, false, App.time.elapsed);
        }
    } else if t == .SDL_EVENT_JOYSTICK_AXIS_MOTION {
        id := ev.jaxis.which;
        if !SDL_IsGamepad(id) {
            value := ifx ev.jaxis.value >= 0
                then cast(float) ev.jaxis.value / 32767.0
                else cast(float) ev.jaxis.value / 32768.0;
            input_controller_axis(i, id, ev.jaxis.axis, value, App.time.elapsed);
        }
    } else if t == .SDL_EVENT_GAMEPAD_ADDED {
        id := ev.gdevice.which;
        ptr := SDL_OpenGamepad(id);
        array_add(*i.open_gamepads, .{ id = id, ptr = ptr });
        input_connect_controller(i, id, cstr_to_string(SDL_GetGamepadName(ptr)),
            15, 6, true, cast(Gamepad_Types) SDL_GetGamepadType(ptr),
            SDL_GetGamepadVendor(ptr), SDL_GetGamepadProduct(ptr), SDL_GetGamepadProductVersion(ptr));
    } else if t == .SDL_EVENT_GAMEPAD_REMOVED {
        id := ev.gdevice.which;
        for *it, idx: i.open_gamepads {
            if it.id == id {
                SDL_CloseGamepad(it.ptr);
                array_unordered_remove_by_index(*i.open_gamepads, idx);
                break;
            }
        }
        input_disconnect_controller(i, id);
    } else if t == .SDL_EVENT_GAMEPAD_BUTTON_DOWN {
        input_controller_button(i, ev.gbutton.which, ev.gbutton.button, true, App.time.elapsed);
    } else if t == .SDL_EVENT_GAMEPAD_BUTTON_UP {
        input_controller_button(i, ev.gbutton.which, ev.gbutton.button, false, App.time.elapsed);
    } else if t == .SDL_EVENT_GAMEPAD_AXIS_MOTION {
        value := ifx ev.gaxis.value >= 0
            then cast(float) ev.gaxis.value / 32767.0
            else cast(float) ev.gaxis.value / 32768.0;
        input_controller_axis(i, ev.gaxis.which, ev.gaxis.axis, value, App.time.elapsed);
    }
}
