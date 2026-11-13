#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Input/Virtual/{VirtualInput, VirtualAction,
// VirtualAxis, VirtualStick, VirtualDevice}.cs
//
// HOW THE C# CLASS HIERARCHY IS EXPRESSED
// ---------------------------------------
// C# has `abstract class VirtualInput` with a vtable and four subclasses
// (VirtualAction, VirtualAxis, VirtualStick, VirtualDevice). Here it becomes a
// **kind-tagged handle with a union payload** — the same shape input/bindings.jai
// uses for `Binding`:
//
//     Virtual_Input :: struct { Kind: Virtual_Input_Kind; Manager/Name/ControllerIndex/
//                               Active/IsDisposed; Data: union { Action; Axis; Stick; Device } }
//
//   * `*Virtual_Input` is the C# `VirtualInput` reference. Like a C# base-class
//     reference it must be downcast before touching payload fields; the
//     `virtual_<kind>_*` procedures do that for you, and each is the C# method
//     or property of the same name (`action.Pressed` -> virtual_action_pressed(v)`).
//   * `Kind` is the type tag (instead of the vtable); `virtual_input_update`
//     switches on it exactly like a virtual `Update` call.
//   * VirtualDevice's child list is `[..] *Virtual_Input` (C#:
//     ReadOnlyCollection<VirtualInput>), so devices can hold heterogeneous
//     children while every handle stays a single pointer type.
//   * Child inputs are heap-allocated by `virtual_device_add_*`, which mirrors
//     the C# constructor's `new`; `virtual_input_destroy` is `Dispose()`.
//
// `Set` is a `*` to the caller's binding set (C# holds a reference), so a set can
// be shared by an action, an axis, a stick and a device. The `*_create_empty`
// variants allocate an empty set for you and free it in `virtual_input_destroy`,
// which is what C#'s `new VirtualAction(input, name, controllerIndex, buffer)`
// did by calling `: this(..., new(), ...)`.
//
// WHERE C# USED THE `Input` OBJECT
// --------------------------------
// Foster's `VirtualInput` ctor calls `Input.AddVirtualInput(this)` and
// `Input.Step` drives every registered input. The registry is a module-global
// array here (`virtual_inputs`) instead of a field on `Input`, because each
// Virtual_Input already carries `Manager` (the `Input` it belongs to, C#
// `Input` parameter) and the update loop filters on it — the same per-Input
// scoping C# got from one list per Input, without touching the `Input` layout.
//
// The per-frame drive is wired up, not manual: `input_update()` ends with
// `virtual_inputs_update(i, time)` (Foster: the `foreach ... virtualInput.Update`
// tail of `Input.Step`), after the keyboard/mouse/controller state has been
// published into `State`, so applications only call `input_update`:
//
//     input_update(App.input, App.time);   // also updates every virtual input
//
// The controller notifications are wired the same way: input_connect_controller
// / input_disconnect_controller call `virtual_inputs_notify_controller_connected`
// / `_disconnected` with the slot the controller landed in (Foster's
// `Input.ConnectController` / `DisconnectController` loop over virtualDevices),
// so a device's `on_controller_connected` / `on_controller_disconnected` hooks
// fire from the normal input path. They stay public for a caller that drives an
// `Input` outside App.
//
// DEVIATIONS FROM C#
// ------------------
//   * Timestamps are `float64` seconds instead of `TimeSpan` (matches
//     input/bindings.jai and utility/time.jai).
//   * `Active` defaults to true like C#, but Jai zero-initialization would give
//     false, so the create procedures set it explicitly.
//   * C# throws for "device disposed" / "ControllerIndex is automatic" and for
//     an out-of-range `ControllerIndex` read; Jai has no exceptions, so those
//     paths log via log_error and return false/null instead.
//   * `VirtualInput.Dispose` is `virtual_input_destroy` (no finalizers/GC).
//   * `VirtualAction.ValueNoDeadzone` is declared by C# but never assigned, so it
//     stays 0 there; the port keeps the field and the same (always-0) behaviour
//     rather than inventing a value.
//   * C#'s `protected virtual Controller*Changed()` hooks are optional
//     procedure-pointer callbacks on Virtual_Device (`on_*` + `callbacks_data`).
//   * There are no weak references: `virtual_inputs` holds raw pointers, so
//     destroy an input exactly once, and destroy a device rather than one of its
//     children (the device's child list would otherwise keep a dangling
//     pointer). Likewise do not destroy inputs from inside
//     `virtual_inputs_update` — the registry array is being walked there.

//
// Types
//

Virtual_Input_Kind :: enum {
    ACTION;
    AXIS;
    STICK;
    DEVICE;
}

// Foster: VirtualDevice.IndexModes
Virtual_Device_Index_Mode :: enum {
    MANUAL;             // ControllerIndex is assigned by hand
    AUTOMATIC_LATEST;   // follow the most recently used controller
}

// Foster: VirtualAction
Virtual_Action :: struct {
    Set:      *Action_Binding_Set;
    Set_Owned: bool;              // Set was allocated by virtual_action_create_empty

    RepeatDelay:    float;        // seconds before the first repeat
    RepeatInterval: float;        // seconds between repeats
    Buffer:         float;        // input buffer, in seconds

    Pressed:        bool;         // pressed this frame (or still inside the buffer)
    PressConsumed:  bool;
    Down:           bool;         // currently held
    Released:       bool;         // released this frame
    Repeated:       bool;         // repeated this frame

    Value:           float;       // 0..1
    ValueNoDeadzone: float;       // C# declares it and never writes it: always 0
    LastPressTimestamp: float64;  // seconds of the last real press
}

// Foster: VirtualAxis
Virtual_Axis :: struct {
    Set:      *Axis_Binding_Set;
    Set_Owned: bool;

    RepeatDelay:    float;
    RepeatInterval: float;

    Value:      float;   // -1..1
    IntValue:   s32;     // sign of Value
    PressedSign: s32;    // sign of the press this frame (0 if none)

    Repeated: bool;      // a repeat produced a press this frame
    LastPressTimestamp: float64;
    last_down_sign: s32; // private repeat bookkeeping
}

// Foster: VirtualStick
Virtual_Stick :: struct {
    Set:      *Stick_Binding_Set;
    Set_Owned: bool;

    Value:    Vector2;
    IntValue: Point2;    // sign of Value per axis
    PressedLeft:  bool;
    PressedRight: bool;
    PressedUp:    bool;
    PressedDown:  bool;
}

// Foster: VirtualDevice
Virtual_Device :: struct {
    IndexMode: Virtual_Device_Index_Mode;
    Inputs:    [..] *Virtual_Input;   // C#: ReadOnlyCollection<VirtualInput>

    // C#: the protected virtual Controller*Changed() hooks
    on_controller_index_changed: (data: *void, device: *Virtual_Input) = null;
    on_controller_connected:     (data: *void, device: *Virtual_Input) = null;
    on_controller_disconnected:  (data: *void, device: *Virtual_Input) = null;
    callbacks_data: *void = null;
}

// Foster: VirtualInput (the abstract base class)
Virtual_Input :: struct {
    Kind:            Virtual_Input_Kind;
    Manager:         *Input;      // the input manager we belong to (C# `Input`, renamed: the field would shadow the type)
    Name:            string;
    ControllerIndex: s32;         // which controller we are subscribed to
    Active:          bool = true; // Update is only called when true
    IsDisposed:      bool;

    Data: union {
        Action: Virtual_Action;
        Axis:   Virtual_Axis;
        Stick:  Virtual_Stick;
        Device: Virtual_Device;
    }
}

// C#: Input.virtualInputs (a list of weak references there; plain pointers here,
// because Jai has no GC and `virtual_input_destroy` unregisters explicitly).
virtual_inputs: [..] *Virtual_Input;

//
// registration (Foster: Input.AddVirtualInput / RemoveVirtualInput)
//

virtual_input_register :: (v: *Virtual_Input) {
    array_add(*virtual_inputs, v);
}

virtual_input_unregister :: (v: *Virtual_Input) {
    for it, index: virtual_inputs {
        if it == v {
            array_ordered_remove_by_index(*virtual_inputs, index);
            return;
        }
    }
}

virtual_inputs_count :: () -> s32 {
    return cast(s32) virtual_inputs.count;
}

// C#: VirtualInput(Input input, string name, int controllerIndex) — the base
// constructor every subclass chains into.
virtual_input_create :: (kind: Virtual_Input_Kind, input: *Input, name: string, controller_index: s32) -> *Virtual_Input {
    v := New(Virtual_Input);
    v.* = .{
        Kind            = kind,
        Manager         = input,
        Name            = name,
        ControllerIndex = controller_index,
    };
    v.Active = true;
    virtual_input_register(v);
    return v;
}

//
// VirtualInput (shared behaviour)
//

virtual_input_name :: (v: *Virtual_Input) -> string {
    if v == null return "";
    return v.Name;
}

virtual_input_is_disposed :: (v: *Virtual_Input) -> bool {
    if v == null return true;
    return v.IsDisposed;
}

// C#: `virtualInput.ControllerIndex = value` (throws for a device in
// AutomaticLatest mode). Returns false when the assignment was refused.
virtual_input_set_controller_index :: (v: *Virtual_Input, index: s32) -> bool {
    if v == null || v.IsDisposed return false;
    if v.Kind == .DEVICE return virtual_device_set_controller_index(v, index);
    v.ControllerIndex = index;
    return true;
}

// Foster: VirtualInput.Update — the C# virtual call.
virtual_input_update :: (v: *Virtual_Input, time: Time) {
    if v == null || v.IsDisposed return;
    if v.Kind == {
        case .ACTION; virtual_action_update(v, time);
        case .AXIS;   virtual_axis_update(v, time);
        case .STICK;  virtual_stick_update(v, time);
        case .DEVICE; virtual_device_update(v, time);
    }
}

// Foster: the `foreach (var virtualInput in virtualInputs) ... Update` loop in
// Input.Step. Called by input_update() at the end of the frame, so an
// application never calls this itself; it stays public so a caller that drives
// its own `Input` outside App (tests, tools) can step one by hand.
virtual_inputs_update :: (input: *Input, time: Time) {
    for i: 0..virtual_inputs.count-1 {
        v := virtual_inputs[i];
        if v == null || v.IsDisposed continue;
        if v.Manager != input continue;         // C# kept a registry per Input
        if v.Active virtual_input_update(v, time);
    }
}

// Foster: VirtualInput.Dispose
virtual_input_destroy :: (v: *Virtual_Input) {
    if v == null || v.IsDisposed return;

    if v.Kind == .DEVICE {
        d := *v.Data.Device;
        // children first, like VirtualDevice.Dispose(bool)
        for i: 0..d.Inputs.count-1 {
            child := d.Inputs[i];
            if child != null virtual_input_destroy(child);
        }
        array_free(d.Inputs);
    } else if v.Kind == .ACTION {
        a := *v.Data.Action;
        if a.Set_Owned && a.Set != null {
            action_binding_set_destroy(a.Set);
            free(a.Set);
        }
    } else if v.Kind == .AXIS {
        a := *v.Data.Axis;
        if a.Set_Owned && a.Set != null {
            axis_binding_set_destroy(a.Set);
            free(a.Set);
        }
    } else if v.Kind == .STICK {
        s := *v.Data.Stick;
        if s.Set_Owned && s.Set != null {
            stick_binding_set_destroy(s.Set);
            free(s.Set);
        }
    }

    virtual_input_unregister(v);
    v.IsDisposed = true;
    free(v);
}

// C#: Calc.OnInterval(X, delta, interval) with X = (elapsed - last) - repeatDelay.
// time_on_interval(t, interval, offset) is the same test with offset folded in:
//   X == elapsed - (last + repeatDelay)
virtual_input_repeat_due :: (time: Time, last_press: float64, repeat_delay: float, interval: float) -> bool {
    offset := last_press + cast(float64) repeat_delay;
    return time_on_interval(time, cast(float64) interval, cast(float) offset);
}

//
// VirtualAction
//

virtual_action_create :: (input: *Input, name: string, set: *Action_Binding_Set,
                          controller_index: s32 = 0, buffer: float = 0) -> *Virtual_Input {
    v := virtual_input_create(.ACTION, input, name, controller_index);
    a := *v.Data.Action;
    a.Set    = set;
    a.Buffer = buffer;
    return v;
}

// C#: `new VirtualAction(input, name, controllerIndex, buffer)` (empty set)
virtual_action_create_empty :: (input: *Input, name: string, controller_index: s32 = 0, buffer: float = 0) -> *Virtual_Input {
    set := New(Action_Binding_Set);
    set.* = .{};
    v := virtual_action_create(input, name, set, controller_index, buffer);
    a := *v.Data.Action;
    a.Set_Owned = true;
    return v;
}

virtual_action_set :: (v: *Virtual_Input) -> *Action_Binding_Set {
    if v == null || v.Kind != .ACTION return null;
    return (*v.Data.Action).Set;
}

virtual_action_entries :: (v: *Virtual_Input) -> [] Action_Binding_Entry {
    set := virtual_action_set(v);
    if set == null return .[];
    return set.Entries;
}

// Foster: VirtualAction.Update
virtual_action_update :: (v: *Virtual_Input, time: Time) {
    if v == null || v.Kind != .ACTION return;
    a := *v.Data.Action;
    if a.Set == null return;

    state := action_binding_set_get_state(a.Set, v.Manager, v.ControllerIndex);

    a.Pressed  = state.Pressed;
    a.Released = state.Released;
    a.Down     = state.Down;
    a.Value    = state.Value;
    a.Repeated = false;

    if a.Pressed {
        a.PressConsumed = false;
        a.LastPressTimestamp = time.elapsed;
    } else if !a.PressConsumed && a.LastPressTimestamp > 0 &&
              (time.elapsed - a.LastPressTimestamp) < cast(float64) a.Buffer {
        a.Pressed = true;   // still inside the input buffer
    }

    // repeating logic
    if !a.Pressed && a.Down && a.RepeatInterval > 0 &&
       (time.elapsed - a.LastPressTimestamp) > cast(float64) a.RepeatDelay {
        if virtual_input_repeat_due(time, a.LastPressTimestamp, a.RepeatDelay, a.RepeatInterval) {
            a.Pressed  = true;
            a.Repeated = true;
        }
    }
}

// Foster: VirtualAction.ManualUpdate(in Time time, bool down)
virtual_action_manual_update :: (v: *Virtual_Input, time: Time, down: bool) {
    if v == null || v.Kind != .ACTION return;
    a := *v.Data.Action;

    a.Pressed = down && !a.Down;
    if a.Pressed {
        a.PressConsumed = false;
        a.LastPressTimestamp = time.elapsed;
    } else if !a.PressConsumed && a.LastPressTimestamp > 0 &&
              (time.elapsed - a.LastPressTimestamp) < cast(float64) a.Buffer {
        a.Pressed = true;
    }

    a.Released = !down && a.Down;
    a.Down     = down;

    // repeating logic
    if !a.Pressed && down && a.RepeatInterval > 0 &&
       (time.elapsed - a.LastPressTimestamp) > cast(float64) a.RepeatDelay {
        if virtual_input_repeat_due(time, a.LastPressTimestamp, a.RepeatDelay, a.RepeatInterval) {
            a.Pressed  = true;
            a.Repeated = true;
        }
    }
}

// Foster: VirtualAction.ConsumePress
virtual_action_consume_press :: (v: *Virtual_Input) -> bool {
    if v == null || v.Kind != .ACTION return false;
    a := *v.Data.Action;
    if a.Pressed {
        a.Pressed = false;
        a.PressConsumed = true;
        return true;
    }
    return false;
}

// Foster: VirtualAction.Clear
virtual_action_clear :: (v: *Virtual_Input) {
    if v == null || v.Kind != .ACTION return;
    a := *v.Data.Action;
    a.Pressed       = false;
    a.Released      = false;
    a.PressConsumed = true;
    a.Down          = false;
    a.Repeated      = false;
    a.Value         = 0;
}

// Foster: the VirtualAction properties
virtual_action_pressed   :: (v: *Virtual_Input) -> bool { if v == null || v.Kind != .ACTION return false; return (*v.Data.Action).Pressed; }
virtual_action_down      :: (v: *Virtual_Input) -> bool { if v == null || v.Kind != .ACTION return false; return (*v.Data.Action).Down; }
virtual_action_released  :: (v: *Virtual_Input) -> bool { if v == null || v.Kind != .ACTION return false; return (*v.Data.Action).Released; }
virtual_action_repeated  :: (v: *Virtual_Input) -> bool { if v == null || v.Kind != .ACTION return false; return (*v.Data.Action).Repeated; }
virtual_action_value     :: (v: *Virtual_Input) -> float { if v == null || v.Kind != .ACTION return 0; return (*v.Data.Action).Value; }
virtual_action_value_no_deadzone :: (v: *Virtual_Input) -> float { if v == null || v.Kind != .ACTION return 0; return (*v.Data.Action).ValueNoDeadzone; }
virtual_action_press_consumed :: (v: *Virtual_Input) -> bool { if v == null || v.Kind != .ACTION return false; return (*v.Data.Action).PressConsumed; }
virtual_action_last_press_timestamp :: (v: *Virtual_Input) -> float64 { if v == null || v.Kind != .ACTION return 0; return (*v.Data.Action).LastPressTimestamp; }

//
// VirtualAxis
//

virtual_axis_create :: (input: *Input, name: string, set: *Axis_Binding_Set,
                        controller_index: s32 = 0) -> *Virtual_Input {
    v := virtual_input_create(.AXIS, input, name, controller_index);
    a := *v.Data.Axis;
    a.Set = set;
    return v;
}

// C#: `new VirtualAxis(input, name, controllerIndex)` (empty set)
virtual_axis_create_empty :: (input: *Input, name: string, controller_index: s32 = 0) -> *Virtual_Input {
    set := New(Axis_Binding_Set);
    set.* = .{};
    v := virtual_axis_create(input, name, set, controller_index);
    a := *v.Data.Axis;
    a.Set_Owned = true;
    return v;
}

virtual_axis_set :: (v: *Virtual_Input) -> *Axis_Binding_Set {
    if v == null || v.Kind != .AXIS return null;
    return (*v.Data.Axis).Set;
}

virtual_axis_entries :: (v: *Virtual_Input) -> [] Axis_Binding_Entry {
    set := virtual_axis_set(v);
    if set == null return .[];
    return set.Entries;
}

// Foster: VirtualAxis.Update
virtual_axis_update :: (v: *Virtual_Input, time: Time) {
    if v == null || v.Kind != .AXIS return;
    a := *v.Data.Axis;
    if a.Set == null return;

    a.Value       = axis_binding_set_value(a.Set, v.Manager, v.ControllerIndex);
    a.IntValue    = binding_sign_f32(a.Value);
    a.PressedSign = axis_binding_set_pressed_sign(a.Set, v.Manager, v.ControllerIndex);

    // repeating logic
    // (the last branch is C#'s `lastDownSign == IntValue && PressedSign == 0 &&
    //  lastDownSign != 0 && ...`; `PressedSign == 0` is implied by reaching it)
    a.Repeated = false;
    if a.IntValue == 0 {
        a.last_down_sign = 0;
    } else if a.PressedSign != 0 {
        a.last_down_sign = a.PressedSign;
        a.LastPressTimestamp = time.elapsed;
    } else if a.last_down_sign == a.IntValue && a.last_down_sign != 0 &&
              a.RepeatInterval > 0 &&
              (time.elapsed - a.LastPressTimestamp) > cast(float64) a.RepeatDelay {
        if virtual_input_repeat_due(time, a.LastPressTimestamp, a.RepeatDelay, a.RepeatInterval) {
            a.PressedSign = a.last_down_sign;
            a.Repeated    = true;
        }
    }
}

// Foster: VirtualAxis.ManualUpdate(in Time time, float value)
virtual_axis_manual_update :: (v: *Virtual_Input, time: Time, value: float) {
    if v == null || v.Kind != .AXIS return;
    a := *v.Data.Axis;

    prev_int_value := a.IntValue;

    a.Value    = value;
    a.IntValue = binding_sign_f32(a.Value);

    if a.IntValue != 0 && a.IntValue != prev_int_value a.PressedSign = a.IntValue;
    else a.PressedSign = 0;

    // repeating logic
    a.Repeated = false;
    if a.IntValue == 0 {
        a.last_down_sign = 0;
    } else if a.PressedSign != 0 {
        a.last_down_sign = a.PressedSign;
        a.LastPressTimestamp = time.elapsed;
    } else if a.last_down_sign == a.IntValue && a.last_down_sign != 0 &&
              a.RepeatInterval > 0 &&
              (time.elapsed - a.LastPressTimestamp) > cast(float64) a.RepeatDelay {
        if virtual_input_repeat_due(time, a.LastPressTimestamp, a.RepeatDelay, a.RepeatInterval) {
            a.PressedSign = a.last_down_sign;
            a.Repeated    = true;
        }
    }
}

// Foster: VirtualAxis.Clear
virtual_axis_clear :: (v: *Virtual_Input) {
    if v == null || v.Kind != .AXIS return;
    a := *v.Data.Axis;
    a.Value       = 0;
    a.IntValue    = 0;
    a.PressedSign = 0;
}

// Foster: the VirtualAxis properties
virtual_axis_value            :: (v: *Virtual_Input) -> float { if v == null || v.Kind != .AXIS return 0; return (*v.Data.Axis).Value; }
virtual_axis_int_value        :: (v: *Virtual_Input) -> s32   { if v == null || v.Kind != .AXIS return 0; return (*v.Data.Axis).IntValue; }
virtual_axis_pressed_sign     :: (v: *Virtual_Input) -> s32   { if v == null || v.Kind != .AXIS return 0; return (*v.Data.Axis).PressedSign; }
virtual_axis_pressed          :: (v: *Virtual_Input) -> bool  { return virtual_axis_pressed_sign(v) != 0; }
virtual_axis_pressed_negative :: (v: *Virtual_Input) -> bool  { return virtual_axis_pressed_sign(v) < 0; }
virtual_axis_pressed_positive :: (v: *Virtual_Input) -> bool  { return virtual_axis_pressed_sign(v) > 0; }
virtual_axis_repeated         :: (v: *Virtual_Input) -> bool  { if v == null || v.Kind != .AXIS return false; return (*v.Data.Axis).Repeated; }
virtual_axis_last_press_timestamp :: (v: *Virtual_Input) -> float64 { if v == null || v.Kind != .AXIS return 0; return (*v.Data.Axis).LastPressTimestamp; }

//
// VirtualStick
//

virtual_stick_create :: (input: *Input, name: string, set: *Stick_Binding_Set,
                         controller_index: s32 = 0) -> *Virtual_Input {
    v := virtual_input_create(.STICK, input, name, controller_index);
    s := *v.Data.Stick;
    s.Set = set;
    return v;
}

// C#: `new VirtualStick(input, name, controllerIndex)` (empty set)
virtual_stick_create_empty :: (input: *Input, name: string, controller_index: s32 = 0) -> *Virtual_Input {
    set := New(Stick_Binding_Set);
    set.* = .{};
    v := virtual_stick_create(input, name, set, controller_index);
    s := *v.Data.Stick;
    s.Set_Owned = true;
    return v;
}

virtual_stick_set :: (v: *Virtual_Input) -> *Stick_Binding_Set {
    if v == null || v.Kind != .STICK return null;
    return (*v.Data.Stick).Set;
}

virtual_stick_entries :: (v: *Virtual_Input) -> [] Stick_Binding_Entry {
    set := virtual_stick_set(v);
    if set == null return .[];
    return set.Entries;
}

// Foster: VirtualStick.Update
//
// Value comes from the set; the four Pressed* flags are the OR of the pressed
// state of every included entry's directional binding.
virtual_stick_update :: (v: *Virtual_Input, time: Time) {
    if v == null || v.Kind != .STICK return;
    s := *v.Data.Stick;
    if s.Set == null return;

    s.Value    = stick_binding_set_value(s.Set, v.Manager, v.ControllerIndex);
    s.IntValue = Point2.{ binding_sign_f32(s.Value.x), binding_sign_f32(s.Value.y) };
    s.PressedLeft  = false;
    s.PressedRight = false;
    s.PressedUp    = false;
    s.PressedDown  = false;

    for *entry: s.Set.Entries {
        if !input_is_included(entry.Masks) continue;
        if binding_get_state(entry.Left,  v.Manager, v.ControllerIndex).Pressed s.PressedLeft  = true;
        if binding_get_state(entry.Right, v.Manager, v.ControllerIndex).Pressed s.PressedRight = true;
        if binding_get_state(entry.Up,    v.Manager, v.ControllerIndex).Pressed s.PressedUp    = true;
        if binding_get_state(entry.Down,  v.Manager, v.ControllerIndex).Pressed s.PressedDown  = true;
    }
}

// Foster: VirtualStick.ManualUpdate(in Time time, Vector2 value)
virtual_stick_manual_update :: (v: *Virtual_Input, time: Time, value: Vector2) {
    if v == null || v.Kind != .STICK return;
    s := *v.Data.Stick;

    prev := s.IntValue;

    s.Value    = value;
    s.IntValue = Point2.{ binding_sign_f32(s.Value.x), binding_sign_f32(s.Value.y) };
    s.PressedLeft  = s.IntValue.x < 0 && prev.x >= 0;
    s.PressedRight = s.IntValue.x > 0 && prev.x <= 0;
    s.PressedUp    = s.IntValue.y < 0 && prev.y >= 0;
    s.PressedDown  = s.IntValue.y > 0 && prev.y <= 0;
}

// Foster: VirtualStick.Clear
virtual_stick_clear :: (v: *Virtual_Input) {
    if v == null || v.Kind != .STICK return;
    s := *v.Data.Stick;
    s.Value       = Vector2.{ 0, 0 };
    s.IntValue    = Point2.{ 0, 0 };
    s.PressedLeft  = false;
    s.PressedRight = false;
    s.PressedUp    = false;
    s.PressedDown  = false;
}

// Foster: the VirtualStick properties
virtual_stick_value        :: (v: *Virtual_Input) -> Vector2 { if v == null || v.Kind != .STICK return Vector2.{ 0, 0 }; return (*v.Data.Stick).Value; }
virtual_stick_int_value    :: (v: *Virtual_Input) -> Point2  { if v == null || v.Kind != .STICK return Point2.{ 0, 0 }; return (*v.Data.Stick).IntValue; }
virtual_stick_pressed_left :: (v: *Virtual_Input) -> bool   { if v == null || v.Kind != .STICK return false; return (*v.Data.Stick).PressedLeft; }
virtual_stick_pressed_right :: (v: *Virtual_Input) -> bool  { if v == null || v.Kind != .STICK return false; return (*v.Data.Stick).PressedRight; }
virtual_stick_pressed_up   :: (v: *Virtual_Input) -> bool   { if v == null || v.Kind != .STICK return false; return (*v.Data.Stick).PressedUp; }
virtual_stick_pressed_down :: (v: *Virtual_Input) -> bool   { if v == null || v.Kind != .STICK return false; return (*v.Data.Stick).PressedDown; }

//
// VirtualDevice
//

virtual_device_create :: (input: *Input, name: string, controller_index: s32 = 0) -> *Virtual_Input {
    v := virtual_input_create(.DEVICE, input, name, controller_index);
    d := *v.Data.Device;
    d.IndexMode = .MANUAL;
    return v;
}

virtual_device_inputs :: (v: *Virtual_Input) -> [] *Virtual_Input {
    if v == null || v.Kind != .DEVICE return .[];
    return (*v.Data.Device).Inputs;
}

virtual_device_input_count :: (v: *Virtual_Input) -> s32 {
    if v == null || v.Kind != .DEVICE return 0;
    return cast(s32) (*v.Data.Device).Inputs.count;
}

// Foster: VirtualDevice.GetByInputName (case sensitive, first match wins)
virtual_device_get_by_input_name :: (v: *Virtual_Input, name: string) -> *Virtual_Input {
    if v == null || v.Kind != .DEVICE return null;
    d := *v.Data.Device;
    for i: 0..d.Inputs.count-1 {
        child := d.Inputs[i];
        if child == null continue;
        if child.Name == name return child;
    }
    return null;
}

// Foster: VirtualDevice.ControllerIndexChanged (the protected virtual hook)
virtual_device_controller_index_changed :: (v: *Virtual_Input) {
    d := *v.Data.Device;
    if d.on_controller_index_changed != null d.on_controller_index_changed(d.callbacks_data, v);
}

// Foster: the private UpdateControllerIndex: push the new index down to children.
virtual_device_force_controller_index :: (v: *Virtual_Input, index: s32) {
    if v.ControllerIndex == index return;

    v.ControllerIndex = index;
    d := *v.Data.Device;
    for i: 0..d.Inputs.count-1 {
        child := d.Inputs[i];
        if child == null continue;
        child.ControllerIndex = index;
    }
    virtual_device_controller_index_changed(v);
}

// Foster: the `ControllerIndex` property of VirtualDevice.
// Returns false when the device follows the latest controller (C# threw).
virtual_device_set_controller_index :: (v: *Virtual_Input, index: s32) -> bool {
    if v == null || v.Kind != .DEVICE return false;
    d := *v.Data.Device;
    if d.IndexMode == .AUTOMATIC_LATEST {
        log_error("VirtualDevice: ControllerIndex is automatically updated; switch to IndexMode.Manual");
        return false;
    }
    virtual_device_force_controller_index(v, index);
    return true;
}

// Foster: VirtualDevice.IsGamepadLatest
virtual_device_is_gamepad_latest :: (v: *Virtual_Input) -> bool {
    if (v == null || v.Kind != .DEVICE) return false;
    if (v.ControllerIndex < 0 || v.ControllerIndex >= CONTROLLER_MAX) return false;
    c := *v.Manager.State.Controllers[v.ControllerIndex];
    return c.IsGamepad && c.InputTimestamp > v.Manager.State.Keyboard.InputTimestamp;
}

// Foster: VirtualDevice.Update (AutomaticLatest picks the most recent gamepad)
virtual_device_update :: (v: *Virtual_Input, time: Time) {
    if v == null || v.Kind != .DEVICE return;
    d := *v.Data.Device;
    if d.IndexMode != .AUTOMATIC_LATEST return;

    latest: s32 = 0;
    base := *v.Manager.State.Controllers[latest];
    for i: 1..CONTROLLER_MAX-1 {
        c := *v.Manager.State.Controllers[i];
        if c.IsGamepad && c.InputTimestamp > base.InputTimestamp {
            latest = cast(s32) i;
            base = c;
        }
    }
    virtual_device_force_controller_index(v, latest);
}

// Foster: VirtualDevice.AddAction
virtual_device_add_action :: (v: *Virtual_Input, name: string, set: *Action_Binding_Set, buffer: float = 0) -> *Virtual_Input {
    if !virtual_device_can_add(v) return null;
    action := virtual_action_create(v.Manager, name, set, v.ControllerIndex, buffer);
    d := *v.Data.Device;
    array_add(*d.Inputs, action);
    return action;
}

// Foster: VirtualDevice.AddAction(name, buffer) (empty set)
virtual_device_add_action_empty :: (v: *Virtual_Input, name: string, buffer: float = 0) -> *Virtual_Input {
    if !virtual_device_can_add(v) return null;
    action := virtual_action_create_empty(v.Manager, name, v.ControllerIndex, buffer);
    d := *v.Data.Device;
    array_add(*d.Inputs, action);
    return action;
}

// Foster: VirtualDevice.AddAxis
virtual_device_add_axis :: (v: *Virtual_Input, name: string, set: *Axis_Binding_Set) -> *Virtual_Input {
    if !virtual_device_can_add(v) return null;
    axis := virtual_axis_create(v.Manager, name, set, v.ControllerIndex);
    d := *v.Data.Device;
    array_add(*d.Inputs, axis);
    return axis;
}

// Foster: VirtualDevice.AddAxis(name) (empty set)
virtual_device_add_axis_empty :: (v: *Virtual_Input, name: string) -> *Virtual_Input {
    if !virtual_device_can_add(v) return null;
    axis := virtual_axis_create_empty(v.Manager, name, v.ControllerIndex);
    d := *v.Data.Device;
    array_add(*d.Inputs, axis);
    return axis;
}

// Foster: VirtualDevice.AddStick
virtual_device_add_stick :: (v: *Virtual_Input, name: string, set: *Stick_Binding_Set) -> *Virtual_Input {
    if !virtual_device_can_add(v) return null;
    stick := virtual_stick_create(v.Manager, name, set, v.ControllerIndex);
    d := *v.Data.Device;
    array_add(*d.Inputs, stick);
    return stick;
}

// Foster: VirtualDevice.AddStick(name) (empty set)
virtual_device_add_stick_empty :: (v: *Virtual_Input, name: string) -> *Virtual_Input {
    if !virtual_device_can_add(v) return null;
    stick := virtual_stick_create_empty(v.Manager, name, v.ControllerIndex);
    d := *v.Data.Device;
    array_add(*d.Inputs, stick);
    return stick;
}

// C#: `if (IsDisposed) throw new Exception("Virtual Device is disposed");`
virtual_device_can_add :: (v: *Virtual_Input) -> bool {
    if v == null || v.Kind != .DEVICE return false;
    if v.IsDisposed {
        log_error("VirtualDevice: device is disposed");
        return false;
    }
    return true;
}

//
// controller notifications (Foster: the VirtualDevice.Controller* hooks called
// from Input.ConnectController / DisconnectController)
//

// Foster: Input.ConnectController -> `device.ControllerConnected()` for every
// device sitting on slot `controller_index`.
virtual_inputs_notify_controller_connected :: (input: *Input, controller_index: s32) {
    for i: 0..virtual_inputs.count-1 {
        v := virtual_inputs[i];
        if v == null || v.IsDisposed || v.Kind != .DEVICE continue;
        if v.Manager != input || v.ControllerIndex != controller_index continue;
        d := *v.Data.Device;
        if d.on_controller_connected != null d.on_controller_connected(d.callbacks_data, v);
    }
}

// Foster: Input.DisconnectController -> `device.ControllerDisconnected()`
virtual_inputs_notify_controller_disconnected :: (input: *Input, controller_index: s32) {
    for i: 0..virtual_inputs.count-1 {
        v := virtual_inputs[i];
        if v == null || v.IsDisposed || v.Kind != .DEVICE continue;
        if v.Manager != input || v.ControllerIndex != controller_index continue;
        d := *v.Data.Device;
        if d.on_controller_disconnected != null d.on_controller_disconnected(d.callbacks_data, v);
    }
}
