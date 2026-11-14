#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Input/Bindings/{Binding, BindingState,
// BindingAxisOverlap, KeyboardKeyBinding, MouseButtonBinding,
// MouseMotionBinding, ControllerAxisBinding, ControllerButtonBinding}.cs
//
// HOW THE C# INHERITANCE IS EXPRESSED
// -----------------------------------
// C# has `abstract class Binding` with five sealed subclasses that only differ
// by their data + their GetState/Descriptor overrides. Here that becomes a
// **kind-tagged struct with an untagged union payload** (same shape as
// `Drawable_Target` in graphics/draw_command.jai, and as SDL_Event):
//
//     Binding :: struct { Kind: Binding_Kind; Data: union { ... } }
//
// * each C# subclass is a plain struct of the same name
//   (Keyboard_Key_Binding ...) holding exactly the C# properties;
// * `Kind` is the type tag (instead of the C# vtable);
// * `binding_get_state` / `binding_descriptor` are the C# virtual calls,
//   dispatched with `if Kind == { case ... }`;
// * there is no proc-pointer table - the dispatch is a plain branch on the
//   tag, so the binding stays a value type with no allocation and no
//   lifetime to manage.
//
// The per-variant procs (`keyboard_key_binding_get_state` etc.) are the C#
// overrides themselves, so they can be called directly when the concrete type
// is already known.
//
// Deliberate deviations from C# (documented per case):
//   * Timestamp is `float64` seconds, not `TimeSpan` (matches utility/time.jai
//     and every other jfoster timestamp).
//   * Indexing a controller by an out-of-range `device` returns an empty
//     Binding_State instead of throwing IndexOutOfRange (Jai arrays have no
//     runtime exception).
//   * Descriptors print the *jfoster* enum member names (e.g. "Key NUM_1"),
//     since Keys/Buttons were named after SDL there instead of after C#.

//
// BindingState
//

// A single frame of state of a Binding.
//   Pressed  - Value is > 0 after being 0 on the last frame
//   Released - Value is 0 after being > 0 on the last frame
//   Down     - Value is currently > 0
//   Value    - current state (0 = unpressed, 1 = fully pressed)
//   Timestamp - when last pressed, in seconds
Binding_State :: struct {
    Pressed: bool;
    Released: bool;
    Down: bool;
    Value: float;
    Timestamp: float64;
}

//
// BindingAxisOverlap
//

// How to handle Input Bindings Axis that overlap.
Binding_Axis_Overlap :: enum {
    TAKE_NEWER; // whichever input was pressed most recently
    TAKE_OLDER; // whichever input was pressed longest ago
    CANCEL_OUT; // inputs cancel each other out
}

// Foster: BindingAxisOverlapExt.Resolve(this BindingAxisOverlap, in BindingState, in BindingState)
binding_axis_overlap_resolve :: (overlap: Binding_Axis_Overlap, negative: Binding_State, positive: Binding_State) -> float {
    if overlap == .CANCEL_OUT {
        return calc_clamp(positive.Value - negative.Value, -1, 1);
    } else if overlap == .TAKE_NEWER {
        if positive.Down && negative.Down {
            return ifx negative.Timestamp > positive.Timestamp then -negative.Value else positive.Value;
        } else if positive.Down {
            return positive.Value;
        } else if negative.Down {
            return -negative.Value;
        }
    } else if overlap == .TAKE_OLDER {
        if positive.Down && negative.Down {
            return ifx negative.Timestamp < positive.Timestamp then -negative.Value else positive.Value;
        } else if positive.Down {
            return positive.Value;
        } else if negative.Down {
            return -negative.Value;
        }
    }
    return 0;
}

//
// Binding variants (the C# sealed subclasses)
//

// An Input Binding mapped to a Keyboard Key.
Keyboard_Key_Binding :: struct {
    Key: Keys;
}

// An Input Binding mapped to a Mouse Button.
Mouse_Button_Binding :: struct {
    Button: Mouse_Buttons;
}

// An Input Binding mapped to Mouse Motion along an axis.
Mouse_Motion_Binding :: struct {
    Axis: Vector2; // axis of mouse motion to track
    Sign: s32; // sign of the mouse motion to track
    Min: float; // minimum distance before the motion is tracked
    Max: float; // maximum distance before the motion is clamped
}

// An Input Binding mapped to a Controller Axis.
Controller_Axis_Binding :: struct {
    Axis: Axes;
    Sign: s32;
    Deadzone: float;
}

// An Input Binding mapped to a Controller Button.
Controller_Button_Binding :: struct {
    Button: Buttons;
}

Binding_Kind :: enum {
    KEYBOARD_KEY;
    MOUSE_BUTTON;
    MOUSE_MOTION;
    CONTROLLER_AXIS;
    CONTROLLER_BUTTON;
}

// Represents an Input Binding/Mapping (C#: abstract class Binding).
// `Kind` selects which member of `Data` is live; only touch the member that
// matches Kind (same contract as a C# downcast).
Binding :: struct {
    Kind: Binding_Kind = .KEYBOARD_KEY;
    Data: union {
        Keyboard: Keyboard_Key_Binding;
        MouseButton: Mouse_Button_Binding;
        MouseMotion: Mouse_Motion_Binding;
        ControllerAxis: Controller_Axis_Binding;
        ControllerButton: Controller_Button_Binding;
    }
}

//
// constructors (the C# `new XBinding(...)` overloads + wrapping into Binding)
//

keyboard_key_binding_create :: (key: Keys) -> Keyboard_Key_Binding {
    return .{ Key = key };
}

mouse_button_binding_create :: (button: Mouse_Buttons) -> Mouse_Button_Binding {
    return .{ Button = button };
}

mouse_motion_binding_create :: (axis: Vector2, sign: s32, min_value: float, max_value: float) -> Mouse_Motion_Binding {
    return .{ Axis = axis, Sign = sign, Min = min_value, Max = max_value };
}

controller_axis_binding_create :: (axis: Axes, sign: s32, deadzone: float) -> Controller_Axis_Binding {
    return .{ Axis = axis, Sign = sign, Deadzone = deadzone };
}

controller_button_binding_create :: (button: Buttons) -> Controller_Button_Binding {
    return .{ Button = button };
}

binding_from_keyboard_key :: (key: Keys) -> Binding {
    return .{ Kind = .KEYBOARD_KEY, Data = .{ Keyboard = keyboard_key_binding_create(key) } };
}

binding_from_mouse_button :: (button: Mouse_Buttons) -> Binding {
    return .{ Kind = .MOUSE_BUTTON, Data = .{ MouseButton = mouse_button_binding_create(button) } };
}

binding_from_mouse_motion :: (axis: Vector2, sign: s32, min_value: float, max_value: float) -> Binding {
    return .{ Kind = .MOUSE_MOTION, Data = .{ MouseMotion = mouse_motion_binding_create(axis, sign, min_value, max_value) } };
}

binding_from_controller_axis :: (axis: Axes, sign: s32, deadzone: float) -> Binding {
    return .{ Kind = .CONTROLLER_AXIS, Data = .{ ControllerAxis = controller_axis_binding_create(axis, sign, deadzone) } };
}

binding_from_controller_button :: (button: Buttons) -> Binding {
    return .{ Kind = .CONTROLLER_BUTTON, Data = .{ ControllerButton = controller_button_binding_create(button) } };
}

// Wraps an already-built variant into a Binding (the C# implicit upcast).
binding_from_keyboard_key_binding :: (value: Keyboard_Key_Binding) -> Binding {
    return .{ Kind = .KEYBOARD_KEY, Data = .{ Keyboard = value } };
}

binding_from_mouse_button_binding :: (value: Mouse_Button_Binding) -> Binding {
    return .{ Kind = .MOUSE_BUTTON, Data = .{ MouseButton = value } };
}

binding_from_mouse_motion_binding :: (value: Mouse_Motion_Binding) -> Binding {
    return .{ Kind = .MOUSE_MOTION, Data = .{ MouseMotion = value } };
}

binding_from_controller_axis_binding :: (value: Controller_Axis_Binding) -> Binding {
    return .{ Kind = .CONTROLLER_AXIS, Data = .{ ControllerAxis = value } };
}

binding_from_controller_button_binding :: (value: Controller_Button_Binding) -> Binding {
    return .{ Kind = .CONTROLLER_BUTTON, Data = .{ ControllerButton = value } };
}

//
// KeyboardKeyBinding
//

// Foster: KeyboardKeyBinding.GetState
keyboard_key_binding_get_state :: (binding: Keyboard_Key_Binding, input: *Input, device: s32) -> Binding_State {
    k := *input.State.Keyboard;
    down := keyboard_down(k, binding.Key);
    return .{
        Pressed = keyboard_pressed(k, binding.Key),
        Released = keyboard_released(k, binding.Key),
        Down = down,
        Value = ifx down then 1.0 else 0.0,
        Timestamp = keyboard_timestamp(k, binding.Key),
    };
}

// Foster: KeyboardKeyBinding.Descriptor
keyboard_key_binding_descriptor :: (binding: Keyboard_Key_Binding) -> string {
    return tprint("Key %", binding.Key);
}

//
// MouseButtonBinding
//

// Foster: MouseButtonBinding.GetState
mouse_button_binding_get_state :: (binding: Mouse_Button_Binding, input: *Input, device: s32) -> Binding_State {
    m := *input.State.Mouse;
    down := mouse_down(m, binding.Button);
    return .{
        Pressed = mouse_pressed(m, binding.Button),
        Released = mouse_released(m, binding.Button),
        Down = down,
        Value = ifx down then 1.0 else 0.0,
        Timestamp = mouse_pressed_timestamp(m, binding.Button),
    };
}

// Foster: MouseButtonBinding.Descriptor
mouse_button_binding_descriptor :: (binding: Mouse_Button_Binding) -> string {
    return tprint("Mouse Button %", binding.Button);
}

//
// MouseMotionBinding
//

// Foster: MouseMotionBinding.GetValue (the private helper behind GetState)
mouse_motion_binding_value :: (binding: Mouse_Motion_Binding, mouse: *Mouse_State) -> float {
    value := dot(binding.Axis, mouse.Delta);
    return calc_clamped_map(
        value,
        cast(float) binding.Sign * binding.Min,
        cast(float) binding.Sign * binding.Max,
        0, 1,
    );
}

// Foster: MouseMotionBinding.GetState
mouse_motion_binding_get_state :: (binding: Mouse_Motion_Binding, input: *Input, device: s32) -> Binding_State {
    // C# calls GetValue() four times; it is pure, so computing it twice is
    // equivalent (and matches the "state vs last state" reading).
    value := mouse_motion_binding_value(binding, *input.State.Mouse);
    prev := mouse_motion_binding_value(binding, *input.LastState.Mouse);
    return .{
        Pressed = value > 0 && prev <= 0,
        Released = value <= 0 && prev > 0,
        Down = value > 0,
        Value = value,
        Timestamp = mouse_motion_timestamp(*input.State.Mouse),
    };
}

// Foster: MouseMotionBinding.Descriptor
mouse_motion_binding_descriptor :: (binding: Mouse_Motion_Binding) -> string {
    return tprint("Mouse Motion %%, %-%",
        binding.Axis,
        ifx binding.Sign > 0 then "+" else "-",
        binding.Min,
        binding.Max);
}

//
// ControllerAxisBinding
//

// Foster: ControllerAxisBinding.GetValue (the private helper behind GetState)
controller_axis_binding_value :: (binding: Controller_Axis_Binding, state: *Controller_State) -> float {
    return calc_clamped_map(
        controller_axis(state, binding.Axis),
        cast(float) binding.Sign * binding.Deadzone,
        cast(float) binding.Sign,
        0, 1,
    );
}

// Foster: ControllerAxisBinding.GetState
// `device` is the Controller slot index into input.State.Controllers (same
// meaning as `input.Controllers[device]` in C#).
controller_axis_binding_get_state :: (binding: Controller_Axis_Binding, input: *Input, device: s32) -> Binding_State {
    if device < 0 || device >= CONTROLLER_MAX return .{};

    value := controller_axis_binding_value(binding, *input.State.Controllers[device]);
    prev := controller_axis_binding_value(binding, *input.LastState.Controllers[device]);
    return .{
        Pressed = value > 0 && prev <= 0,
        Released = value <= 0 && prev > 0,
        Down = value > 0,
        Value = value,
        Timestamp = input.State.Controllers[device].axis_timestamp[cast(s32) binding.Axis],
    };
}

// Foster: ControllerAxisBinding.Descriptor
controller_axis_binding_descriptor :: (binding: Controller_Axis_Binding) -> string {
    return tprint("Axis %%, >=%",
        binding.Axis,
        ifx binding.Sign > 0 then "+" else "-",
        binding.Deadzone);
}

//
// ControllerButtonBinding
//

// Foster: ControllerButtonBinding.GetState
controller_button_binding_get_state :: (binding: Controller_Button_Binding, input: *Input, device: s32) -> Binding_State {
    if device < 0 || device >= CONTROLLER_MAX return .{};

    c := *input.State.Controllers[device];
    down := controller_down(c, binding.Button);
    index := cast(s32) binding.Button;
    // C# ControllerState.Timestamp(Buttons) bounds-checks (Buttons.None is out
    // of range); down/up_pressed do not.
    stamp := ifx index >= 0 && index < CONTROLLER_MAX_BUTTONS then c.timestamp[index] else 0;
    return .{
        Pressed = controller_pressed(c, binding.Button),
        Released = controller_released(c, binding.Button),
        Down = down,
        Value = ifx down then 1.0 else 0.0,
        Timestamp = stamp,
    };
}

// Foster: ControllerButtonBinding.Descriptor
controller_button_binding_descriptor :: (binding: Controller_Button_Binding) -> string {
    return tprint("Gamepad Button %", binding.Button);
}

//
// Binding (the virtual entry points)
//

// Foster: Binding.GetState - the C# virtual call.
binding_get_state :: (binding: Binding, input: *Input, device: s32) -> Binding_State {
    if binding.Kind == {
        case .KEYBOARD_KEY; return keyboard_key_binding_get_state(binding.Data.Keyboard, input, device);
        case .MOUSE_BUTTON; return mouse_button_binding_get_state(binding.Data.MouseButton, input, device);
        case .MOUSE_MOTION; return mouse_motion_binding_get_state(binding.Data.MouseMotion, input, device);
        case .CONTROLLER_AXIS; return controller_axis_binding_get_state(binding.Data.ControllerAxis, input, device);
        case .CONTROLLER_BUTTON; return controller_button_binding_get_state(binding.Data.ControllerButton, input, device);
    }
    return .{};
}

// Foster: Binding.Descriptor - the C# virtual property.
binding_descriptor :: (binding: Binding) -> string {
    if binding.Kind == {
        case .KEYBOARD_KEY; return keyboard_key_binding_descriptor(binding.Data.Keyboard);
        case .MOUSE_BUTTON; return mouse_button_binding_descriptor(binding.Data.MouseButton);
        case .MOUSE_MOTION; return mouse_motion_binding_descriptor(binding.Data.MouseMotion);
        case .CONTROLLER_AXIS; return controller_axis_binding_descriptor(binding.Data.ControllerAxis);
        case .CONTROLLER_BUTTON; return controller_button_binding_descriptor(binding.Data.ControllerButton);
    }
    return "";
}

// The discriminator Binding.cs assigns to each subclass through
// [JsonDerivedType] ("Key", "Axis", "Button", "MouseButton", "MouseMotion").
// Useful for writing/reading binding tables.
binding_type_discriminator :: (binding: Binding) -> string {
    if binding.Kind == {
        case .KEYBOARD_KEY; return "Key";
        case .MOUSE_BUTTON; return "MouseButton";
        case .MOUSE_MOTION; return "MouseMotion";
        case .CONTROLLER_AXIS; return "Axis";
        case .CONTROLLER_BUTTON; return "Button";
    }
    return "";
}
