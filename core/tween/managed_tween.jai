// 托管 tween：把 Tween(T) 注册进 manager 变成可统一调度的节点。
// setter 版写回调、指针版直接写目标、属性版从 getter 现取起点。
// 一比一移植自 olib core/tween/managed_tween.odin。
//
// Jai 侧差异（行为不变）：
//   - olib 的 payload 是 rawptr，Jai 侧用 *void（cast 写法见下）；
//   - Tween 的插值器字段在 Jai 侧要写 data.tween.value.finish（无 using 提升）；
//   - olib 的 @(private) 辅助过程在 Jai 侧无等价物，名字带 managed_tween_ 前缀。
#import "Basic";

//@region 数据类型 —— setter 版 / 指针版 payload

Managed_Tween_Data :: struct(T: Type) {
    tween: Tween(T);
    initial_tween: Tween(T);
    setter: (value: T);
}

Managed_Ptr_Tween_Data :: struct(T: Type) {
    tween: Tween(T);
    initial_tween: Tween(T);
    target: *T;
}
//@endregion

//@region 内部工具 —— 时长/终值/归一化/节点构造

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

managed_tween_make_node :: (
    payload: *void,
    tween: Tween($T),
    update_fn: Tween_Node_Update_Proc,
    reset_fn: Tween_Node_Reset_Proc,
    kill_fn: Tween_Node_Kill_Proc,
    set_loops_fn: Tween_Node_Set_Loops_Proc,
) -> Tween_Node {
    result: Tween_Node;
    result.kind = .Tween;
    result.active = true;
    result.parent = TWEEN_HANDLE_NONE;
    result.timing = Tween_Timing.{
        delay = tween.delay,
        duration = managed_tween_get_duration(tween),
        time_scale = 1,
    };
    result.loops = Loop_Config.{
        count = managed_tween_loop_count(tween.repeat_mode),
        mode = tween.repeat_mode,
    };
    result.control = Tween_Control.{
        state = .Idle,
        auto_kill = tween.repeat_mode == .Once,
    };
    result.payload = payload;
    result.vtable = Tween_Node_VTable.{
        update = update_fn,
        reset = reset_fn,
        kill = kill_fn,
        set_loops = set_loops_fn,
    };
    return result;
}
//@endregion

//@region 注册 —— manager_add_tween / manager_add_tween_to / manager_add_property_tween

manager_add_tween :: (manager: *Tween_Manager, tween: Tween($T), setter: (value: T)) -> Tween_Handle {
    data := New(Managed_Tween_Data(T));
    <<data = .{
        tween = tween,
        initial_tween = tween,
        setter = setter,
    };

    // manager 负责 delay，所以这里把 tween 的内部起始时间和 delay 归一化。
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

    // 注册后先把起始值推一次，避免等到第一帧 update 才生效。
    data.setter(data.tween.value.start);

    return manager_add_node(manager, node);
}

// 便捷属性绑定：直接把 tween 结果写入目标指针，不再需要额外定义 contextless setter。
manager_add_tween_to :: (manager: *Tween_Manager, tween: Tween($T), target: *T) -> Tween_Handle {
    data := New(Managed_Ptr_Tween_Data(T));
    <<data = .{
        tween = tween,
        initial_tween = tween,
        target = target,
    };

    // manager 负责 delay，所以这里把 tween 的内部起始时间和 delay 归一化。
    managed_tween_normalize(*data.tween, *data.initial_tween);

    update_proc :: (node: *Tween_Node, dt: float32) {
        _ = dt;
        data := cast(*Managed_Ptr_Tween_Data(T)) node.payload;
        if data == null || data.target == null {
            return;
        }

        if node.loops.count > 0 && node.control.loops_done >= node.loops.count {
            <<data.target = managed_tween_terminal_value(
                data.tween.value.start, data.tween.value.finish, data.tween.repeat_mode, node.loops.count);
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

    // 注册后先把起始值写入目标，避免等到第一帧 update 才生效。
    if data.target != null {
        <<data.target = data.tween.value.start;
    }

    return manager_add_node(manager, node);
}

// 属性绑定版本：通过 getter 读取当前值，再通过 setter 写回目标。
manager_add_property_tween :: (
    manager: *Tween_Manager,
    getter: () -> $T,
    setter: (value: T),
    finish: T,
    config: Tween_Config,
    lerp: (a: T, b: T, ratio: float32) -> T,
) -> Tween_Handle {
    start := getter();
    tween := make_ex(start, finish, 0, config, lerp);
    return manager_add_tween(manager, tween, setter);
}
//@endregion
