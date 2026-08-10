// managed_tween.jai
// Port of Ascension/tlib/tween/managed_tween.odin
// Type-erased managed tweens: payload data + vtable of per-type procedures.
//
// The Odin original embedded Interpolated via `using`, so tween fields are
// accessed as data.tween.value.* here.

#import "Basic";
#import "tween/tween";
#import "tween/manager";

Managed_Tween_Data :: struct(T: Type) {
    tween:         Tween(T);
    initial_tween: Tween(T);
    setter:        (value: T);
}

Managed_Ptr_Tween_Data :: struct(T: Type) {
    tween:         Tween(T);
    initial_tween: Tween(T);
    target:        *T;
}

managed_tween_get_duration :: (tween: Tween($T)) -> float32 {
    if tween.value.speed >= 1.0e20 {
        return 1.0e-30;
    }
    return 1.0 / tween.value.speed;
}

managed_tween_terminal_value :: (start: $T, finish: T, repeat_mode: Repeat_Mode, loop_count: s32) -> T {
    if repeat_mode == .Once || repeat_mode == .Loop {
        return finish;
    } else if repeat_mode == .PingPong {
        if loop_count % 2 == 0 {
            return start;
        }
        return finish;
    }
    return finish;
}

managed_tween_normalize :: (tween: *Tween($T), initial_tween: *Tween(T)) {
    tween.value.start_time = 0;
    tween.delay = 0;
    initial_tween.value.start_time = 0;
    initial_tween.delay = 0;
}

managed_tween_loop_count :: (repeat_mode: Repeat_Mode) -> s32 {
    if repeat_mode == .Once {
        return 1;
    }
    return -1;
}

managed_tween_make_node :: (payload: *void, tween: Tween($T), update_fn: Tween_Node_Update_Proc, reset_fn: Tween_Node_Reset_Proc, kill_fn: Tween_Node_Kill_Proc, set_loops_fn: Tween_Node_Set_Loops_Proc) -> Tween_Node {
    result: Tween_Node;
    result.kind = .Tween;
    result.active = true;
    result.parent = TWEEN_HANDLE_NONE;
    result.timing = .{ delay = tween.delay, duration = managed_tween_get_duration(tween), time_scale = 1 };
    result.loops = .{ count = managed_tween_loop_count(tween.repeat_mode), mode = tween.repeat_mode };
    result.control = .{ state = .Idle, auto_kill = tween.repeat_mode == .Once };
    result.payload = payload;
    result.vtable = .{ update = update_fn, reset = reset_fn, kill = kill_fn, set_loops = set_loops_fn };
    return result;
}

manager_add_tween :: (manager: *Tween_Manager, tween: Tween($T), setter: (value: T)) -> Tween_Handle {
    data := New(Managed_Tween_Data(T));
    <<data = .{ tween = tween, initial_tween = tween, setter = setter };

    // The manager owns the delay, so normalize the tween's internal start
    // time and delay.
    managed_tween_normalize(*data.tween, *data.initial_tween);

    update_proc :: (node: *Tween_Node, dt: float32) {
        _ = dt;
        data := cast(*Managed_Tween_Data(T)) node.payload;
        if data == null {
            return;
        }

        if node.loops.count > 0 && node.control.loops_done >= node.loops.count {
            if data.tween.repeat_mode == .Once || data.tween.repeat_mode == .Loop {
                data.setter(data.tween.value.finish);
            } else if data.tween.repeat_mode == .PingPong {
                if node.loops.count % 2 == 0 {
                    data.setter(data.tween.value.start);
                } else {
                    data.setter(data.tween.value.finish);
                }
            }
            return;
        }

        value := tween_get_value(*data.tween, node.timing.elapsed);
        data.setter(value);
    }

    reset_proc :: (node: *Tween_Node) {
        data := cast(*Managed_Tween_Data(T)) node.payload;
        if data == null {
            return;
        }
        data.tween = data.initial_tween;
        data.setter(data.tween.value.start);
    }

    set_loops_proc :: (node: *Tween_Node, count: s32, mode: Repeat_Mode) {
        _ = count;
        data := cast(*Managed_Tween_Data(T)) node.payload;
        if data == null {
            return;
        }
        data.tween.repeat_mode = mode;
        data.initial_tween.repeat_mode = mode;
    }

    kill_proc :: (node: *Tween_Node) {
        data := cast(*Managed_Tween_Data(T)) node.payload;
        if data != null {
            free(data);
        }
        node.payload = null;
    }

    node := managed_tween_make_node(cast(*void) data, tween, update_proc, reset_proc, kill_proc, set_loops_proc);

    // Push the start value immediately so it applies before the first update.
    data.setter(data.tween.value.start);

    return manager_add_node(manager, node);
}

// Convenience property binding: write tween results straight into a target
// pointer instead of defining a contextless setter.
manager_add_tween_to :: (manager: *Tween_Manager, tween: Tween($T), target: *T) -> Tween_Handle {
    data := New(Managed_Ptr_Tween_Data(T));
    <<data = .{ tween = tween, initial_tween = tween, target = target };

    managed_tween_normalize(*data.tween, *data.initial_tween);

    update_proc :: (node: *Tween_Node, dt: float32) {
        _ = dt;
        data := cast(*Managed_Ptr_Tween_Data(T)) node.payload;
        if data == null || data.target == null {
            return;
        }

        if node.loops.count > 0 && node.control.loops_done >= node.loops.count {
            <<data.target = managed_tween_terminal_value(data.tween.value.start, data.tween.value.finish, data.tween.repeat_mode, node.loops.count);
            return;
        }

        value := tween_get_value(*data.tween, node.timing.elapsed);
        <<data.target = value;
    }

    reset_proc :: (node: *Tween_Node) {
        data := cast(*Managed_Ptr_Tween_Data(T)) node.payload;
        if data == null {
            return;
        }
        data.tween = data.initial_tween;
        if data.target != null {
            <<data.target = data.tween.value.start;
        }
    }

    set_loops_proc :: (node: *Tween_Node, count: s32, mode: Repeat_Mode) {
        _ = count;
        data := cast(*Managed_Ptr_Tween_Data(T)) node.payload;
        if data == null {
            return;
        }
        data.tween.repeat_mode = mode;
        data.initial_tween.repeat_mode = mode;
    }

    kill_proc :: (node: *Tween_Node) {
        data := cast(*Managed_Ptr_Tween_Data(T)) node.payload;
        if data != null {
            free(data);
        }
        node.payload = null;
    }

    node := managed_tween_make_node(cast(*void) data, tween, update_proc, reset_proc, kill_proc, set_loops_proc);

    // Write the start value into the target immediately.
    if data.target != null {
        <<data.target = data.tween.value.start;
    }

    return manager_add_node(manager, node);
}

// Property-binding version: read the current value via getter, write via setter.
manager_add_property_tween :: (manager: *Tween_Manager, getter: () -> $T, setter: (value: T), finish: T, config: Tween_Config, lerp: (a: T, b: T, ratio: float32) -> T) -> Tween_Handle {
    start := getter();
    tween := make_ex(start, finish, 0, config, lerp);
    return manager_add_tween(manager, tween, setter);
}
