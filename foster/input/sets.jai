#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Input/Sets/{ActionBindingSet, AxisBindingSet,
// StickBindingSet}.cs
//
// HOW THE C# COLLECTIONS ARE EXPRESSED
// ------------------------------------
//   List<ActionBindingSet.ActionEntry>  ->  [..] Action_Binding_Entry
//   List<AxisBindingSet.AxisEntry>      ->  [..] Axis_Binding_Entry
//   List<StickBindingSet.StickEntry>    ->  [..] Stick_Binding_Entry
//   string[]? Masks  (`null` == "no masks") -> [] string (`count == 0`)
//   HashSet<string> Input.BindingFilters    -> [..] string binding_filters (linear scan)
//
// None of the eight C# types uses a Dictionary, so no `Table` is involved here
// (where one is needed elsewhere in the port the repo convention is
// `map_get` from utility/table_compat.jai, never `table_find`).
//
// NESTED CLASSES
// --------------
// C# nests `ActionEntry` / `AxisEntry` / `StickEntry` inside their set class;
// Jai has no nested types, so they are top-level with the parent as a prefix.
//
// OVERLOADS / FLUENT `Add`
// ------------------------
// C# resolves the many `Add` overloads by argument type and returns `this` so
// calls can be chained. Jai has neither overloading nor chaining, so:
//   * every overload becomes its own procedure, suffixed `_masked` when the C#
//     version takes `in ReadOnlySpan<string> masks` as its first argument
//     (same parameter order as C#);
//   * the procedures mutate the set in place and take it as a `*` (the `set.*
//     method(...)` spelling of C#'s `set.Add(...)`); the returned `this` is
//     dropped because nothing in the C# codebase depends on it beyond chaining.
//
// DEVIATIONS FROM C#
// ------------------
//   * No `JsonConverter`/`JsonSerializerContext` port: Foster's converters are
//     thin wrappers around System.Text.Json source generation. The data model
//     (Entries + Masks + Binding) is public and plain, so utility/json.jai can
//     serialize it directly if that is ever needed.
//   * `Input.BindingFilters` lives here as the module-global `binding_filters`
//     array, because input/input.jai is frozen and has no slot for it. One
//     global set of filters is what single-`Input` apps had anyway.
//   * C# throws IndexOutOfRange for a bad controller index inside the gamepad
//     bindings; Jai has no exceptions (bindings.jai already returns an empty
//     Binding_State instead), so `device` out of range is simply "no input".
//   * Lifetime: the C# sets are GC'd. Here `*_destroy` frees the entry array.
//   * `action_binding_set_is_down` / `_was_pressed` / `_was_released` are
//     conveniences with no C# counterpart: they are `GetState(...).Down` /
//     `.Pressed` / `.Released` (C# reads those fields straight off the
//     Binding_State that VirtualAction stores).

// MathF.Sign as C# uses it: -1 / 0 / +1 (Math has no `sign` for floats).
binding_sign_f32 :: (v: float) -> s32 {
    if v > 0 return 1;
    if v < 0 return -1;
    return 0;
}

//
// Binding filters (Foster: Input.BindingFilters + Input.IsIncluded)
//

// Masks named here are the only ones allowed through; when this is empty every
// binding is included, exactly like C#'s `BindingFilters == null`.
binding_filters: [..] string;

// Foster: Input.BindingFilters.Add (HashSet: adding twice keeps one)
binding_filter_add :: (filter: string) {
    for it: binding_filters if it == filter return;
    array_add(*binding_filters, filter);
}

binding_filter_remove :: (filter: string) {
    for it, index: binding_filters {
        if it == filter {
            array_ordered_remove_by_index(*binding_filters, index);
            return;
        }
    }
}

binding_filter_clear :: () {
    array_reset(*binding_filters);
}

binding_filter_count :: () -> s32 {
    return cast(s32) binding_filters.count;
}

binding_filter_has :: (filter: string) -> bool {
    for it: binding_filters if it == filter return true;
    return false;
}

// Foster: Input.IsIncluded - if this binding should be used given the masks it
// carries. No masks (or no filters configured) always means "included".
input_is_included :: (masks: [] string) -> bool {
    if binding_filters.count <= 0 return true;
    if masks.count <= 0 return true;
    for it: masks if binding_filter_has(it) return true;
    return false;
}

//
// ActionBindingSet
//

// Holds a singular Action binding (Foster: ActionBindingSet.ActionEntry)
Action_Binding_Entry :: struct {
    Bind: Binding;         // the Binding to check (C# `Binding`, renamed: the field would shadow the type)
    Masks:   [] string;    // optional masks to filter the binding by (empty == none)
}

// Serializable object that holds bindings for a single Action
// (Foster: ActionBindingSet)
Action_Binding_Set :: struct {
    Entries: [..] Action_Binding_Entry;
}

action_binding_set_create :: () -> Action_Binding_Set {
    return .{};
}

// Frees the entry array (C# relied on the GC).
action_binding_set_destroy :: (set: *Action_Binding_Set) {
    array_free(set.Entries);
}

// Drops every entry but keeps the allocated storage.
action_binding_set_clear :: (set: *Action_Binding_Set) {
    array_reset(*set.Entries);
}

action_binding_set_entries :: (set: *Action_Binding_Set) -> [] Action_Binding_Entry {
    return set.Entries;
}

action_binding_set_count :: (set: *Action_Binding_Set) -> s32 {
    return cast(s32) set.Entries.count;
}

// Foster: ActionBindingSet.ActionEntry ctor
action_binding_set_add_entry :: (set: *Action_Binding_Set, binding: Binding, masks: [] string = .[]) {
    entry := Action_Binding_Entry.{ Bind = binding, Masks = masks };
    array_add(*set.Entries, entry);
}

// Foster: ActionBindingSet(params ReadOnlySpan<Binding>)
action_binding_set_add_bindings :: (set: *Action_Binding_Set, bindings: [] Binding) {
    for it: bindings action_binding_set_add_entry(set, it);
}

// Foster: Add(params ReadOnlySpan<Keys>)
action_binding_set_add_keys :: (set: *Action_Binding_Set, keys: [] Keys) {
    for it: keys action_binding_set_add_entry(set, binding_from_keyboard_key(it));
}

// Foster: Add(in ReadOnlySpan<string> masks, params ReadOnlySpan<Keys>)
action_binding_set_add_keys_masked :: (set: *Action_Binding_Set, masks: [] string, keys: [] Keys) {
    for it: keys action_binding_set_add_entry(set, binding_from_keyboard_key(it), masks);
}

// Foster: Add(params ReadOnlySpan<Buttons>)
action_binding_set_add_buttons :: (set: *Action_Binding_Set, buttons: [] Buttons) {
    for it: buttons action_binding_set_add_entry(set, binding_from_controller_button(it));
}

// Foster: Add(in ReadOnlySpan<string> masks, params ReadOnlySpan<Buttons>)
action_binding_set_add_buttons_masked :: (set: *Action_Binding_Set, masks: [] string, buttons: [] Buttons) {
    for it: buttons action_binding_set_add_entry(set, binding_from_controller_button(it), masks);
}

// Foster: Add(params ReadOnlySpan<MouseButtons>)
action_binding_set_add_mouse_buttons :: (set: *Action_Binding_Set, buttons: [] Mouse_Buttons) {
    for it: buttons action_binding_set_add_entry(set, binding_from_mouse_button(it));
}

// Foster: Add(in ReadOnlySpan<string> masks, params ReadOnlySpan<MouseButtons>)
action_binding_set_add_mouse_buttons_masked :: (set: *Action_Binding_Set, masks: [] string, buttons: [] Mouse_Buttons) {
    for it: buttons action_binding_set_add_entry(set, binding_from_mouse_button(it), masks);
}

// Foster: Add(Axes axes, int sign, float deadzone = 0)
action_binding_set_add_axis :: (set: *Action_Binding_Set, axis: Axes, sign: s32, deadzone: float = 0) {
    action_binding_set_add_entry(set, binding_from_controller_axis(axis, sign, deadzone));
}

// Foster: Add(in ReadOnlySpan<string> masks, Axes axes, int sign, float deadzone = 0)
action_binding_set_add_axis_masked :: (set: *Action_Binding_Set, masks: [] string, axis: Axes, sign: s32, deadzone: float = 0) {
    action_binding_set_add_entry(set, binding_from_controller_axis(axis, sign, deadzone), masks);
}

// Foster: AddLeftJoystickLeft / AddLeftJoystickRight / AddLeftJoystickUp /
// AddLeftJoystickDown / AddRightJoystick* (each with a masked overload).
action_binding_set_add_left_joystick_left          :: (set: *Action_Binding_Set, deadzone: float = 0) { action_binding_set_add_axis(set, .LEFT_X, -1, deadzone); }
action_binding_set_add_left_joystick_right         :: (set: *Action_Binding_Set, deadzone: float = 0) { action_binding_set_add_axis(set, .LEFT_X,  1, deadzone); }
action_binding_set_add_left_joystick_up            :: (set: *Action_Binding_Set, deadzone: float = 0) { action_binding_set_add_axis(set, .LEFT_Y, -1, deadzone); }
action_binding_set_add_left_joystick_down          :: (set: *Action_Binding_Set, deadzone: float = 0) { action_binding_set_add_axis(set, .LEFT_Y,  1, deadzone); }
action_binding_set_add_right_joystick_left         :: (set: *Action_Binding_Set, deadzone: float = 0) { action_binding_set_add_axis(set, .RIGHT_X, -1, deadzone); }
action_binding_set_add_right_joystick_right        :: (set: *Action_Binding_Set, deadzone: float = 0) { action_binding_set_add_axis(set, .RIGHT_X,  1, deadzone); }
action_binding_set_add_right_joystick_up           :: (set: *Action_Binding_Set, deadzone: float = 0) { action_binding_set_add_axis(set, .RIGHT_Y, -1, deadzone); }
action_binding_set_add_right_joystick_down         :: (set: *Action_Binding_Set, deadzone: float = 0) { action_binding_set_add_axis(set, .RIGHT_Y,  1, deadzone); }

action_binding_set_add_left_joystick_left_masked   :: (set: *Action_Binding_Set, masks: [] string, deadzone: float = 0) { action_binding_set_add_axis_masked(set, masks, .LEFT_X, -1, deadzone); }
action_binding_set_add_left_joystick_right_masked  :: (set: *Action_Binding_Set, masks: [] string, deadzone: float = 0) { action_binding_set_add_axis_masked(set, masks, .LEFT_X,  1, deadzone); }
action_binding_set_add_left_joystick_up_masked     :: (set: *Action_Binding_Set, masks: [] string, deadzone: float = 0) { action_binding_set_add_axis_masked(set, masks, .LEFT_Y, -1, deadzone); }
action_binding_set_add_left_joystick_down_masked   :: (set: *Action_Binding_Set, masks: [] string, deadzone: float = 0) { action_binding_set_add_axis_masked(set, masks, .LEFT_Y,  1, deadzone); }
action_binding_set_add_right_joystick_left_masked  :: (set: *Action_Binding_Set, masks: [] string, deadzone: float = 0) { action_binding_set_add_axis_masked(set, masks, .RIGHT_X, -1, deadzone); }
action_binding_set_add_right_joystick_right_masked :: (set: *Action_Binding_Set, masks: [] string, deadzone: float = 0) { action_binding_set_add_axis_masked(set, masks, .RIGHT_X,  1, deadzone); }
action_binding_set_add_right_joystick_up_masked    :: (set: *Action_Binding_Set, masks: [] string, deadzone: float = 0) { action_binding_set_add_axis_masked(set, masks, .RIGHT_Y, -1, deadzone); }
action_binding_set_add_right_joystick_down_masked  :: (set: *Action_Binding_Set, masks: [] string, deadzone: float = 0) { action_binding_set_add_axis_masked(set, masks, .RIGHT_Y,  1, deadzone); }

// Foster: ActionBindingSet.GetState
//
// Every included entry is folded together: Pressed/Released/Down OR'd, Value
// takes the maximum, Timestamp the newest.
action_binding_set_get_state :: (set: *Action_Binding_Set, input: *Input, device: s32) -> Binding_State {
    result: Binding_State;
    for *entry: set.Entries {
        if !input_is_included(entry.Masks) continue;

        state := binding_get_state(entry.Bind, input, device);
        if state.Pressed  result.Pressed  = true;
        if state.Released result.Released = true;
        if state.Down     result.Down     = true;
        if state.Value > result.Value result.Value = state.Value;
        if state.Timestamp > result.Timestamp result.Timestamp = state.Timestamp;
    }
    return result;
}

// Is the Action held this frame (C#: `set.GetState(input, device).Down`).
action_binding_set_is_down :: (set: *Action_Binding_Set, input: *Input, device: s32) -> bool {
    return action_binding_set_get_state(set, input, device).Down;
}

// Was the Action pressed this frame (C#: `...GetState(...).Pressed`).
action_binding_set_was_pressed :: (set: *Action_Binding_Set, input: *Input, device: s32) -> bool {
    return action_binding_set_get_state(set, input, device).Pressed;
}

// Was the Action released this frame (C#: `...GetState(...).Released`).
action_binding_set_was_released :: (set: *Action_Binding_Set, input: *Input, device: s32) -> bool {
    return action_binding_set_get_state(set, input, device).Released;
}

//
// AxisBindingSet
//

// Holds a singular axis binding pair (Foster: AxisBindingSet.AxisEntry)
Axis_Binding_Entry :: struct {
    Overlap:  Binding_Axis_Overlap;   // how to resolve negative/positive overlap
    Negative: Binding;
    Positive: Binding;
    Masks:    [] string;
}

// Serializable object that holds bindings for an Axis (Foster: AxisBindingSet)
Axis_Binding_Set :: struct {
    Entries: [..] Axis_Binding_Entry;
}

axis_binding_set_create :: () -> Axis_Binding_Set {
    return .{};
}

axis_binding_set_destroy :: (set: *Axis_Binding_Set) {
    array_free(set.Entries);
}

axis_binding_set_clear :: (set: *Axis_Binding_Set) {
    array_reset(*set.Entries);
}

axis_binding_set_entries :: (set: *Axis_Binding_Set) -> [] Axis_Binding_Entry {
    return set.Entries;
}

axis_binding_set_count :: (set: *Axis_Binding_Set) -> s32 {
    return cast(s32) set.Entries.count;
}

// Foster: AxisBindingSet.AxisEntry ctor
axis_binding_set_add_entry :: (set: *Axis_Binding_Set, negative: Binding, positive: Binding,
                               overlap: Binding_Axis_Overlap = .TAKE_NEWER, masks: [] string = .[]) {
    entry := Axis_Binding_Entry.{
        Overlap  = overlap,
        Negative = negative,
        Positive = positive,
        Masks    = masks,
    };
    array_add(*set.Entries, entry);
}

// Foster: AxisBindingSet(params ReadOnlySpan<(Binding, Binding)>)
axis_binding_set_add_pairs :: (set: *Axis_Binding_Set, pairs: [] Axis_Binding_Pair) {
    for it: pairs axis_binding_set_add_entry(set, it.Negative, it.Positive);
}

// The C# tuple `(Binding Negative, Binding Positive)`.
Axis_Binding_Pair :: struct {
    Negative: Binding;
    Positive: Binding;
}

// Foster: Add(Keys negative, Keys positive, BindingAxisOverlap overlap = default)
axis_binding_set_add_keys :: (set: *Axis_Binding_Set, negative: Keys, positive: Keys,
                              overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    axis_binding_set_add_entry(set,
        binding_from_keyboard_key(negative),
        binding_from_keyboard_key(positive),
        overlap);
}

// Foster: Add(in ReadOnlySpan<string> masks, Keys negative, Keys positive, ...)
axis_binding_set_add_keys_masked :: (set: *Axis_Binding_Set, masks: [] string, negative: Keys, positive: Keys,
                                     overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    axis_binding_set_add_entry(set,
        binding_from_keyboard_key(negative),
        binding_from_keyboard_key(positive),
        overlap,
        masks);
}

// Foster: Add(Buttons negative, Buttons positive, BindingAxisOverlap overlap = default)
axis_binding_set_add_buttons :: (set: *Axis_Binding_Set, negative: Buttons, positive: Buttons,
                                 overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    axis_binding_set_add_entry(set,
        binding_from_controller_button(negative),
        binding_from_controller_button(positive),
        overlap);
}

// Foster: Add(in ReadOnlySpan<string> masks, Buttons negative, Buttons positive, ...)
axis_binding_set_add_buttons_masked :: (set: *Axis_Binding_Set, masks: [] string, negative: Buttons, positive: Buttons,
                                        overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    axis_binding_set_add_entry(set,
        binding_from_controller_button(negative),
        binding_from_controller_button(positive),
        overlap,
        masks);
}

// Foster: Add(Axes axis, float deadzone = 0) - one controller axis, both signs
axis_binding_set_add_axis :: (set: *Axis_Binding_Set, axis: Axes, deadzone: float = 0) {
    axis_binding_set_add_entry(set,
        binding_from_controller_axis(axis, -1, deadzone),
        binding_from_controller_axis(axis, 1, deadzone));
}

// Foster: Add(in ReadOnlySpan<string> masks, Axes axis, float deadzone = 0)
axis_binding_set_add_axis_masked :: (set: *Axis_Binding_Set, masks: [] string, axis: Axes, deadzone: float = 0) {
    axis_binding_set_add_entry(set,
        binding_from_controller_axis(axis, -1, deadzone),
        binding_from_controller_axis(axis, 1, deadzone),
        .TAKE_NEWER,
        masks);
}

// Foster: AxisBindingSet.Value
//
// The binding pair with the largest absolute value wins.
axis_binding_set_value :: (set: *Axis_Binding_Set, input: *Input, device: s32) -> float {
    value: float = 0;
    for *entry: set.Entries {
        if !input_is_included(entry.Masks) continue;

        negative := binding_get_state(entry.Negative, input, device);
        positive := binding_get_state(entry.Positive, input, device);
        next_value := binding_axis_overlap_resolve(entry.Overlap, negative, positive);
        if abs(next_value) > abs(value) value = next_value;
    }
    return value;
}

// Foster: AxisBindingSet.PressedSign
//
// Like Value, but only entries whose negative/positive binding was *pressed*
// this frame count. Returns -1 / 0 / +1.
axis_binding_set_pressed_sign :: (set: *Axis_Binding_Set, input: *Input, device: s32) -> s32 {
    value: float = 0;
    for *entry: set.Entries {
        if !input_is_included(entry.Masks) continue;

        negative := binding_get_state(entry.Negative, input, device);
        positive := binding_get_state(entry.Positive, input, device);

        if !negative.Pressed negative = .{};
        if !positive.Pressed positive = .{};

        next_value := binding_axis_overlap_resolve(entry.Overlap, negative, positive);
        if abs(next_value) > abs(value) value = next_value;
    }
    return binding_sign_f32(value);
}

//
// StickBindingSet
//

// Holds a singular stick binding quad (Foster: StickBindingSet.StickEntry)
Stick_Binding_Entry :: struct {
    CircularDeadzone: float;               // circular deadzone applied to the final value
    Overlap:          Binding_Axis_Overlap; // how to resolve overlapping negative/positive inputs
    Left:             Binding;
    Right:            Binding;
    Up:               Binding;
    Down:             Binding;
    Masks:            [] string;
}

// An Input binding that represents a 2D Axis/Stick (Foster: StickBindingSet)
Stick_Binding_Set :: struct {
    Entries: [..] Stick_Binding_Entry;
}

stick_binding_set_create :: () -> Stick_Binding_Set {
    return .{};
}

stick_binding_set_destroy :: (set: *Stick_Binding_Set) {
    array_free(set.Entries);
}

stick_binding_set_clear :: (set: *Stick_Binding_Set) {
    array_reset(*set.Entries);
}

stick_binding_set_entries :: (set: *Stick_Binding_Set) -> [] Stick_Binding_Entry {
    return set.Entries;
}

stick_binding_set_count :: (set: *Stick_Binding_Set) -> s32 {
    return cast(s32) set.Entries.count;
}

// Foster: StickBindingSet.StickEntry ctor
stick_binding_set_add_entry :: (set: *Stick_Binding_Set,
                                left: Binding, right: Binding, up: Binding, down: Binding,
                                circular_deadzone: float = 0,
                                overlap: Binding_Axis_Overlap = .TAKE_NEWER,
                                masks: [] string = .[]) {
    entry := Stick_Binding_Entry.{
        CircularDeadzone = circular_deadzone,
        Overlap          = overlap,
        Left             = left,
        Right            = right,
        Up               = up,
        Down             = down,
        Masks            = masks,
    };
    array_add(*set.Entries, entry);
}

// Foster: Add(Keys left, Keys right, Keys up, Keys down, BindingAxisOverlap overlap = default)
stick_binding_set_add_keys :: (set: *Stick_Binding_Set, left: Keys, right: Keys, up: Keys, down: Keys,
                               overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_entry(set,
        binding_from_keyboard_key(left),
        binding_from_keyboard_key(right),
        binding_from_keyboard_key(up),
        binding_from_keyboard_key(down),
        0,
        overlap);
}

// Foster: Add(in ReadOnlySpan<string> masks, Keys left, Keys right, Keys up, Keys down, ...)
stick_binding_set_add_keys_masked :: (set: *Stick_Binding_Set, masks: [] string,
                                      left: Keys, right: Keys, up: Keys, down: Keys,
                                      overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_entry(set,
        binding_from_keyboard_key(left),
        binding_from_keyboard_key(right),
        binding_from_keyboard_key(up),
        binding_from_keyboard_key(down),
        0,
        overlap,
        masks);
}

// Foster: Add(Buttons left, Buttons right, Buttons up, Buttons down, ...)
stick_binding_set_add_buttons :: (set: *Stick_Binding_Set, left: Buttons, right: Buttons, up: Buttons, down: Buttons,
                                  overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_entry(set,
        binding_from_controller_button(left),
        binding_from_controller_button(right),
        binding_from_controller_button(up),
        binding_from_controller_button(down),
        0,
        overlap);
}

// Foster: Add(in ReadOnlySpan<string> masks, Buttons left, Buttons right, Buttons up, Buttons down, ...)
stick_binding_set_add_buttons_masked :: (set: *Stick_Binding_Set, masks: [] string,
                                         left: Buttons, right: Buttons, up: Buttons, down: Buttons,
                                         overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_entry(set,
        binding_from_controller_button(left),
        binding_from_controller_button(right),
        binding_from_controller_button(up),
        binding_from_controller_button(down),
        0,
        overlap,
        masks);
}

// Foster: Add(Axes x, Axes y, float circularDeadzone, BindingAxisOverlap overlap = default)
stick_binding_set_add_axes :: (set: *Stick_Binding_Set, x: Axes, y: Axes, circular_deadzone: float,
                               overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_entry(set,
        binding_from_controller_axis(x, -1, 0),
        binding_from_controller_axis(x, 1, 0),
        binding_from_controller_axis(y, -1, 0),
        binding_from_controller_axis(y, 1, 0),
        circular_deadzone,
        overlap);
}

// Foster: Add(in ReadOnlySpan<string> masks, Axes x, Axes y, float circularDeadzone, ...)
stick_binding_set_add_axes_masked :: (set: *Stick_Binding_Set, masks: [] string, x: Axes, y: Axes, circular_deadzone: float,
                                      overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_entry(set,
        binding_from_controller_axis(x, -1, 0),
        binding_from_controller_axis(x, 1, 0),
        binding_from_controller_axis(y, -1, 0),
        binding_from_controller_axis(y, 1, 0),
        circular_deadzone,
        overlap,
        masks);
}

// Foster: Add(Axes x, float xDeadzone, Axes y, float yDeadzone, float circularDeadzone, ...)
stick_binding_set_add_axes_deadzones :: (set: *Stick_Binding_Set,
                                         x: Axes, x_deadzone: float, y: Axes, y_deadzone: float,
                                         circular_deadzone: float,
                                         overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_entry(set,
        binding_from_controller_axis(x, -1, x_deadzone),
        binding_from_controller_axis(x, 1, x_deadzone),
        binding_from_controller_axis(y, -1, y_deadzone),
        binding_from_controller_axis(y, 1, y_deadzone),
        circular_deadzone,
        overlap);
}

// Foster: Add(in ReadOnlySpan<string> masks, Axes x, float xDeadzone, Axes y, float yDeadzone, ...)
stick_binding_set_add_axes_deadzones_masked :: (set: *Stick_Binding_Set, masks: [] string,
                                                x: Axes, x_deadzone: float, y: Axes, y_deadzone: float,
                                                circular_deadzone: float,
                                                overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_entry(set,
        binding_from_controller_axis(x, -1, x_deadzone),
        binding_from_controller_axis(x, 1, x_deadzone),
        binding_from_controller_axis(y, -1, y_deadzone),
        binding_from_controller_axis(y, 1, y_deadzone),
        circular_deadzone,
        overlap,
        masks);
}

// Foster: AddMouseMotion(float maxMotion = 25)
stick_binding_set_add_mouse_motion :: (set: *Stick_Binding_Set, max_motion: float = 25) {
    stick_binding_set_add_entry(set,
        binding_from_mouse_motion(.{ 1, 0 }, -1, 0, max_motion),
        binding_from_mouse_motion(.{ 1, 0 },  1, 0, max_motion),
        binding_from_mouse_motion(.{ 0, 1 }, -1, 0, max_motion),
        binding_from_mouse_motion(.{ 0, 1 },  1, 0, max_motion));
}

// Foster: AddMouseMotion(in ReadOnlySpan<string> masks, float maxMotion = 25)
stick_binding_set_add_mouse_motion_masked :: (set: *Stick_Binding_Set, masks: [] string, max_motion: float = 25) {
    stick_binding_set_add_entry(set,
        binding_from_mouse_motion(.{ 1, 0 }, -1, 0, max_motion),
        binding_from_mouse_motion(.{ 1, 0 },  1, 0, max_motion),
        binding_from_mouse_motion(.{ 0, 1 }, -1, 0, max_motion),
        binding_from_mouse_motion(.{ 0, 1 },  1, 0, max_motion),
        0,
        .TAKE_NEWER,
        masks);
}

// Foster: AddArrowKeys (both overloads)
stick_binding_set_add_arrow_keys :: (set: *Stick_Binding_Set, overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_keys(set, .LEFT, .RIGHT, .UP, .DOWN, overlap);
}
stick_binding_set_add_arrow_keys_masked :: (set: *Stick_Binding_Set, masks: [] string, overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_keys_masked(set, masks, .LEFT, .RIGHT, .UP, .DOWN, overlap);
}

// Foster: AddWasd (both overloads)
stick_binding_set_add_wasd :: (set: *Stick_Binding_Set, overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_keys(set, .A, .D, .W, .S, overlap);
}
stick_binding_set_add_wasd_masked :: (set: *Stick_Binding_Set, masks: [] string, overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_keys_masked(set, masks, .A, .D, .W, .S, overlap);
}

// Foster: AddLeftJoystick / AddRightJoystick (both overloads)
stick_binding_set_add_left_joystick :: (set: *Stick_Binding_Set, deadzone: float) {
    stick_binding_set_add_axes(set, .LEFT_X, .LEFT_Y, deadzone);
}
stick_binding_set_add_left_joystick_masked :: (set: *Stick_Binding_Set, masks: [] string, deadzone: float) {
    stick_binding_set_add_axes_masked(set, masks, .LEFT_X, .LEFT_Y, deadzone);
}
stick_binding_set_add_right_joystick :: (set: *Stick_Binding_Set, deadzone: float) {
    stick_binding_set_add_axes(set, .RIGHT_X, .RIGHT_Y, deadzone);
}
stick_binding_set_add_right_joystick_masked :: (set: *Stick_Binding_Set, masks: [] string, deadzone: float) {
    stick_binding_set_add_axes_masked(set, masks, .RIGHT_X, .RIGHT_Y, deadzone);
}

// Foster: AddDPad (both overloads)
stick_binding_set_add_dpad :: (set: *Stick_Binding_Set, overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_buttons(set, .DPAD_LEFT, .DPAD_RIGHT, .DPAD_UP, .DPAD_DOWN, overlap);
}
stick_binding_set_add_dpad_masked :: (set: *Stick_Binding_Set, masks: [] string, overlap: Binding_Axis_Overlap = .TAKE_NEWER) {
    stick_binding_set_add_buttons_masked(set, masks, .DPAD_LEFT, .DPAD_RIGHT, .DPAD_UP, .DPAD_DOWN, overlap);
}

// Squared length; Foster compares Vector2.LengthSquared, never the length.
stick_length_squared :: (v: Vector2) -> float {
    return v.x * v.x + v.y * v.y;
}

// Foster: StickBindingSet.Value
//
// Every included entry becomes a candidate vector; entries inside their
// circular deadzone are skipped, and the longest candidate wins.
stick_binding_set_value :: (set: *Stick_Binding_Set, input: *Input, device: s32) -> Vector2 {
    value := Vector2.{ 0, 0 };
    for *entry: set.Entries {
        if !input_is_included(entry.Masks) continue;

        left  := binding_get_state(entry.Left,  input, device);
        right := binding_get_state(entry.Right, input, device);
        up    := binding_get_state(entry.Up,    input, device);
        down  := binding_get_state(entry.Down,  input, device);

        next_value := Vector2.{
            binding_axis_overlap_resolve(entry.Overlap, left, right),
            binding_axis_overlap_resolve(entry.Overlap, up, down),
        };

        if entry.CircularDeadzone > 0 &&
           stick_length_squared(next_value) < entry.CircularDeadzone * entry.CircularDeadzone
            continue;

        if stick_length_squared(next_value) > stick_length_squared(value) value = next_value;
    }
    return value;
}
