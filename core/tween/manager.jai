// tween:manager —— 节点池与帧推进（tween 系统的总入口）。
//
// manager 持有全部运行时节点（Tween / Sequence 统一为 Tween_Node），负责
// 推进时间、按 vtable 分发 update、执行自动清理。具体插值与序列组装见
// 同包的 tween.jai / managed_tween.jai / managed_sequence.jai。
// 一比一移植自 olib core/tween/manager.odin。
//
// Jai 侧差异（语义不变，逐条对位）：
//   - `import ha "olib:core/handle/array"` → `HA :: #import "core/handle/array"`，
//     过程名同名（add / remove_handle / clear / delete / get / begin / next）；
//   - `Tween_Handle :: distinct ha.Handle` → 独立结构体，字段 idx / gen 与
//     handle/array.Handle 同形，所以 HA.Pool(Tween_Node, Tween_Handle) 直接可用，
//     同时保留了 olib 想要的“与其他系统的 Handle 类型隔离”；
//   - ha.add 在 Jai 侧返回 (句柄, bool)（对应 olib 的 err），失败返回 TWEEN_HANDLE_NONE；
//   - ha.remove 在 Jai 侧叫 remove_handle（remove 是 Jai 关键字）；
//   - manager_reset 用 ha.clear（保留槽位代数历史）而不是 handle/array 的 reset：
//     reset 会丢弃代数，让重置前的旧句柄重新变成有效句柄，与 olib 重置语义不符
//     （见 Tests/core/tween/tween_test.jai::manager_reset_keeps_previous_handles_invalid）；
//   - Jai 的运算符按词法解析：本文件给 Tween_Handle 声明的 operator == 只在本包内
//     可见，外部模块（含测试）按仓库惯例具名重声明一次；这是相对 olib 的扩展；
//   - Jai 没有 @(private)：olib 的私有过程（recount_stats / call_callback /
//     update_node / cleanup_finished / destroy_node / manager_remove_node_internal）
//     在本移植里仍是公开的，名字保持 olib 原样。
#import "Basic";

HA :: #import "core/handle/array";

//@region 类型 —— 句柄/状态机/节点/回调/配置

// 对外暴露的节点句柄。
// olib 用 distinct 做类型隔离，Jai 用同形的独立结构体达到同样效果。
Tween_Handle :: struct {
    idx: u32;
    gen: u32;
}

operator == :: (a: Tween_Handle, b: Tween_Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

TWEEN_HANDLE_NONE :: Tween_Handle.{ };

// 用于把节点分组，方便批量 Pause/Kill。
Tween_Group_Id :: u32;

// 播放状态机。
// manager 在 update 时主要依据这个状态决定节点是否推进。
Playback_State :: enum u8 {
    Idle;
    Delayed;
    Playing;
    Paused;
    Completed;
    Killed;
}

// manager 顶层统一管理的运行时节点类型。
// 按更接近 DOTween 的分层，这里只保留真正可播放的顶层对象。
Node_Kind :: enum u8 {
    Tween;
    Sequence;
}

// Sequence 内部时间轴条目类型。
// Callback/Interval 属于 sequence 的内部步骤，不属于 manager 顶层节点。
Sequence_Step_Kind :: enum u8 {
    Tween;
    Callback;
    Interval;
}

// 循环配置。
// count = -1 表示无限循环，mode 复用已有 Repeat_Mode。
Loop_Config :: struct {
    count: s32; // -1 表示无限循环
    mode:  Repeat_Mode;
}

// 生命周期回调签名。
// 这里只传节点句柄，避免 manager 层直接暴露具体 payload 类型。
Tween_Callback_Proc :: #type (handle: Tween_Handle);
Sequence_Callback_Proc :: #type ();

// 节点生命周期回调集合。
Tween_Callbacks :: struct {
    on_start:         Tween_Callback_Proc;
    on_update:        Tween_Callback_Proc;
    on_step_complete: Tween_Callback_Proc;
    on_complete:      Tween_Callback_Proc;
    on_kill:          Tween_Callback_Proc;
}

// 纯时间数据。
// 把时间相关字段集中起来，后面 Sequence/Interval 也能复用。
Tween_Timing :: struct {
    created_at: float32; // 创建时刻
    start_at:   float32; // 真正开始播放的时刻（包含 delay 后）
    delay:      float32; // 启动前等待时间
    duration:   float32; // 单次播放时长
    elapsed:    float32; // 当前已经推进的本地时间
    time_scale: float32; // 节点级时间缩放
}

// 运行控制信息。
Tween_Control :: struct {
    state:                 Playback_State; // 当前播放状态
    started:               bool;           // on_start 是否已经触发过
    loops_done:            s32;            // 已完成循环次数
    auto_kill:             bool;           // 完成后是否自动销毁
    use_manager_auto_kill: bool;           // 是否沿用 manager 的全局自动清理策略
    is_relative:           bool;           // 目标值是否按相对量解释
    independent_update:    bool;           // 是否忽略 manager 的全局时间缩放
}

// 类型擦除后的行为入口。
// manager 不直接依赖具体 Tween(T) 类型，而是通过这些函数指针驱动节点。
Tween_Node_Update_Proc    :: #type (node: *Tween_Node, dt: float32);
Tween_Node_Reset_Proc     :: #type (node: *Tween_Node);
Tween_Node_Kill_Proc      :: #type (node: *Tween_Node);
Tween_Node_Set_Loops_Proc :: #type (node: *Tween_Node, count: s32, mode: Repeat_Mode);

// 每种节点自己的“虚表”。
Tween_Node_VTable :: struct {
    update:    Tween_Node_Update_Proc;
    reset:     Tween_Node_Reset_Proc;
    kill:      Tween_Node_Kill_Proc;
    set_loops: Tween_Node_Set_Loops_Proc;
}

// manager 内部统一管理的运行时节点。
Tween_Node :: struct {
    handle: Tween_Handle; // 节点自己的稳定句柄
    kind:   Node_Kind;

    group: Tween_Group_Id;
    tag:   string; // 便于按语义批量控制，如 "ui" / "camera"

    active: bool;
    parent: Tween_Handle; // 如果属于某个 Sequence，则指向父节点

    timing:    Tween_Timing;
    loops:     Loop_Config;
    control:   Tween_Control;
    callbacks: Tween_Callbacks;

    payload: *void;          // 指向真实 tween/sequence 数据
    vtable:  Tween_Node_VTable;
}

// Sequence 中的一条时间轴步骤。
// Tween/Callback/Interval 都通过同一种 entry 排到 sequence 本地时间线上。
Sequence_Entry :: struct {
    kind:      Sequence_Step_Kind;
    child:     Tween_Handle;
    callback:  Sequence_Callback_Proc;
    start_at:  float32; // 在 sequence 本地时间轴中的起始位置
    duration:  float32; // 该步骤占用时长；callback 通常为 0
    triggered: bool;    // callback 是否已经触发过
}

// Sequence 的运行时数据。
Sequence_Runtime :: struct {
    cursor:   float32;
    duration: float32;
    entries:  [..] Sequence_Entry;
}

// manager 的全局配置。
Tween_Manager_Config :: struct {
    default_time_scale: float32;
    auto_kill_finished: bool;
    auto_compact:       bool;
}

// 运行时统计信息，主要用于调试和观察系统状态。
Tween_Manager_Stats :: struct {
    total_nodes:     int;
    active_nodes:    int;
    playing_nodes:   int;
    paused_nodes:    int;
    completed_nodes: int;
    killed_nodes:    int;
}

// Tween 系统总入口。
// 负责持有所有节点、推进时间、分发 update、清理已完成节点。
Tween_Manager :: struct {
    now:        float32;
    delta_time: float32;
    time_scale: float32;

    nodes: HA.Pool(Tween_Node, Tween_Handle);
    _cleanup_scratch: [..] Tween_Handle;

    config: Tween_Manager_Config;
    stats:  Tween_Manager_Stats;
}
//@endregion

//@region 节点池管理 —— make / add / remove / reset / delete

manager_make :: () -> Tween_Manager {
    result: Tween_Manager;
    result.time_scale = 1;
    result.config = Tween_Manager_Config.{
        default_time_scale = 1,
        auto_kill_finished = true,
        auto_compact       = true,
    };
    return result;
}

manager_get_node_ptr :: (manager: Tween_Manager, handle: Tween_Handle) -> *Tween_Node {
    return HA.get(manager.nodes, handle);
}

manager_is_handle_valid :: (manager: Tween_Manager, handle: Tween_Handle) -> bool {
    return manager_get_node_ptr(manager, handle) != null;
}

recount_stats :: (manager: *Tween_Manager) {
    stats: Tween_Manager_Stats;
    stats.total_nodes = manager.nodes.num;

    it := HA.begin(*manager.nodes);
    while true {
        node, _, ok := HA.next(*it);
        if !ok break;
        if node.active {
            stats.active_nodes += 1;
        }
        if node.control.state == {
            case .Playing;   stats.playing_nodes += 1;
            case .Paused;    stats.paused_nodes += 1;
            case .Completed; stats.completed_nodes += 1;
            case .Killed;    stats.killed_nodes += 1;
            case;            // .Idle / .Delayed 不计数（对应 olib 的空 case）
        }
    }

    manager.stats = stats;
}

manager_add_node :: (manager: *Tween_Manager, node_in: Tween_Node) -> Tween_Handle {
    node := node_in;
    if node.timing.time_scale == 0 {
        node.timing.time_scale = manager.config.default_time_scale;
        if node.timing.time_scale == 0 {
            node.timing.time_scale = 1;
        }
    }
    if node.control.state == .Idle {
        if node.timing.delay > 0 {
            node.control.state = .Delayed;
        } else {
            node.control.state = .Playing;
        }
    }
    // olib 的这两行是自赋值（无操作），照抄以保持逐行对位。
    if node.parent == TWEEN_HANDLE_NONE node.parent = TWEEN_HANDLE_NONE;
    if node.handle == TWEEN_HANDLE_NONE node.handle = TWEEN_HANDLE_NONE;
    // olib: if !node.active do node.active = true —— 加入 manager 的节点一律激活。
    if !node.active node.active = true;
    node.control.use_manager_auto_kill = true;
    node.timing.created_at = manager.now;
    node.timing.start_at = manager.now + node.timing.delay;

    handle, ok := HA.add(*manager.nodes, node);
    if !ok {
        // olib 侧 add 失败视为分配错误；Jai 侧 add 返回 (零句柄, false)。
        return TWEEN_HANDLE_NONE;
    }
    node_ptr := HA.get(manager.nodes, handle);
    if node_ptr != null {
        node_ptr.handle = handle;
    }
    recount_stats(manager);
    return handle;
}

destroy_node :: (node: *Tween_Node) {
    if node.vtable.kill != null {
        node.vtable.kill(node);
    }
    <<node = Tween_Node.{ };
}

manager_remove_node_internal :: (manager: *Tween_Manager, handle: Tween_Handle, refresh_stats: bool) -> bool {
    if !manager_is_handle_valid(<<manager, handle) {
        return false;
    }
    HA.remove_handle(*manager.nodes, handle, destroy_node);
    if refresh_stats {
        recount_stats(manager);
    }
    return true;
}

manager_remove_node :: (manager: *Tween_Manager, handle: Tween_Handle) -> bool {
    return manager_remove_node_internal(manager, handle, true);
}

manager_reset :: (manager: *Tween_Manager) {
    // olib: ha.clear(&manager.nodes, destroy_node)。槽位与代数历史保留，
    // 重置前的旧句柄全部失效（见文件头说明）。
    HA.clear(*manager.nodes, destroy_node);
    array_reset_keeping_memory(*manager._cleanup_scratch);
    manager.now = 0;
    manager.delta_time = 0;
    manager.stats = Tween_Manager_Stats.{ };
}

manager_delete :: (manager: *Tween_Manager) {
    HA.delete(*manager.nodes, destroy_node);
    array_free(manager._cleanup_scratch);
    <<manager = Tween_Manager.{ };
}
//@endregion

//@region 播放控制 —— play / pause

call_callback :: (callback: Tween_Callback_Proc, handle: Tween_Handle) {
    if callback != null {
        callback(handle);
    }
}

manager_play :: (manager: *Tween_Manager, handle: Tween_Handle) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    if node.control.state == .Killed || node.control.state == .Completed {
        return false;
    }
    if node.timing.delay > 0 && node.timing.elapsed <= 0 {
        node.control.state = .Delayed;
        node.timing.start_at = manager.now + node.timing.delay;
    } else {
        node.control.state = .Playing;
    }
    node.active = true;
    recount_stats(manager);
    return true;
}

manager_pause :: (manager: *Tween_Manager, handle: Tween_Handle) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    if node.control.state == .Killed || node.control.state == .Completed {
        return false;
    }
    node.control.state = .Paused;
    recount_stats(manager);
    return true;
}
//@endregion

//@region 回调注册 —— set_callbacks / on_* / clear_callbacks

manager_set_callbacks :: (manager: *Tween_Manager, handle: Tween_Handle, callbacks: Tween_Callbacks) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.callbacks = callbacks;
    return true;
}

manager_on_start :: (manager: *Tween_Manager, handle: Tween_Handle, callback: Tween_Callback_Proc) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.callbacks.on_start = callback;
    return true;
}

manager_on_update :: (manager: *Tween_Manager, handle: Tween_Handle, callback: Tween_Callback_Proc) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.callbacks.on_update = callback;
    return true;
}

manager_on_step_complete :: (manager: *Tween_Manager, handle: Tween_Handle, callback: Tween_Callback_Proc) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.callbacks.on_step_complete = callback;
    return true;
}

manager_on_complete :: (manager: *Tween_Manager, handle: Tween_Handle, callback: Tween_Callback_Proc) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.callbacks.on_complete = callback;
    return true;
}

manager_on_kill :: (manager: *Tween_Manager, handle: Tween_Handle, callback: Tween_Callback_Proc) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.callbacks.on_kill = callback;
    return true;
}

manager_clear_callbacks :: (manager: *Tween_Manager, handle: Tween_Handle) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.callbacks = Tween_Callbacks.{ };
    return true;
}
//@endregion

//@region 循环与生命周期 —— set_loops / rewind / restart / complete / kill

manager_set_loops :: (manager: *Tween_Manager, handle: Tween_Handle, count: s32, mode: Repeat_Mode) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.loops.count = count;
    node.loops.mode = mode;
    node.control.use_manager_auto_kill = false;
    node.control.auto_kill = count > 0;
    if node.vtable.set_loops != null {
        node.vtable.set_loops(node, count, mode);
    }
    recount_stats(manager);
    return true;
}

manager_set_auto_kill :: (manager: *Tween_Manager, handle: Tween_Handle, enabled: bool) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.control.use_manager_auto_kill = false;
    node.control.auto_kill = enabled;
    recount_stats(manager);
    return true;
}

manager_rewind :: (manager: *Tween_Manager, handle: Tween_Handle) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    if node.vtable.reset != null {
        node.vtable.reset(node);
    }
    node.timing.elapsed = 0;
    node.control.started = false;
    node.control.loops_done = 0;
    node.control.state = .Paused;
    node.active = false;
    node.timing.start_at = manager.now + node.timing.delay;
    recount_stats(manager);
    return true;
}

manager_restart :: (manager: *Tween_Manager, handle: Tween_Handle) -> bool {
    if !manager_rewind(manager, handle) {
        return false;
    }
    return manager_play(manager, handle);
}

manager_complete :: (manager: *Tween_Manager, handle: Tween_Handle) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    node.timing.elapsed = node.timing.duration;
    node.control.state = .Completed;
    node.active = false;
    call_callback(node.callbacks.on_complete, node.handle);
    recount_stats(manager);
    return true;
}

manager_kill :: (manager: *Tween_Manager, handle: Tween_Handle) -> bool {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null {
        return false;
    }
    if node.control.state == .Killed {
        return false;
    }
    node.control.state = .Killed;
    node.active = false;
    call_callback(node.callbacks.on_kill, node.handle);
    recount_stats(manager);
    return true;
}
//@endregion

//@region 帧推进 —— manager_update / 自动清理

update_node :: (manager: *Tween_Manager, node: *Tween_Node, dt: float32) {
    if !node.active {
        return;
    }

    play_dt := dt;

    if node.control.state == .Paused || node.control.state == .Completed || node.control.state == .Killed {
        return;
    } else if node.control.state == .Delayed {
        if manager.now < node.timing.start_at {
            return;
        }
        play_dt = manager.now - node.timing.start_at;
        if play_dt < 0 {
            play_dt = 0;
        }
        node.control.state = .Playing;
    } else if node.control.state == .Idle {
        node.control.state = .Playing;
    }

    if !node.control.started {
        node.control.started = true;
        call_callback(node.callbacks.on_start, node.handle);
    }

    local_dt := play_dt * node.timing.time_scale;
    prev_elapsed := node.timing.elapsed;
    new_elapsed := prev_elapsed + local_dt;

    if node.timing.duration > 0 {
        prev_loop := cast(s32) (prev_elapsed / node.timing.duration);
        curr_loop := cast(s32) (new_elapsed / node.timing.duration);
        crossed := curr_loop - prev_loop;
        if crossed > 0 {
            node.control.loops_done += crossed;
            if node.callbacks.on_step_complete != null {
                i: s32 = 0;
                while i < crossed {
                    call_callback(node.callbacks.on_step_complete, node.handle);
                    i += 1;
                }
            }
        }
        if node.loops.count > 0 && node.control.loops_done >= node.loops.count {
            max_elapsed := (cast(float32) node.loops.count) * node.timing.duration;
            if new_elapsed > max_elapsed {
                new_elapsed = max_elapsed;
            }
        }
    }

    applied_dt := new_elapsed - prev_elapsed;
    if applied_dt < 0 {
        applied_dt = 0;
    }
    node.timing.elapsed = new_elapsed;
    if node.vtable.update != null {
        node.vtable.update(node, applied_dt);
    }
    call_callback(node.callbacks.on_update, node.handle);
    if node.loops.count > 0 && node.control.loops_done >= node.loops.count {
        node.control.state = .Completed;
        node.active = false;
        call_callback(node.callbacks.on_complete, node.handle);
    }
}

cleanup_finished :: (manager: *Tween_Manager) {
    array_reset_keeping_memory(*manager._cleanup_scratch);

    it := HA.begin(*manager.nodes);
    while true {
        node, handle, ok := HA.next(*it);
        if !ok break;
        if node.parent != TWEEN_HANDLE_NONE {
            continue;
        }
        if node.control.state == .Killed {
            array_add(*manager._cleanup_scratch, handle);
            continue;
        }
        should_auto_kill := node.control.auto_kill;
        if node.control.use_manager_auto_kill {
            should_auto_kill = manager.config.auto_kill_finished;
        }
        if node.control.state == .Completed && should_auto_kill {
            array_add(*manager._cleanup_scratch, handle);
        }
    }

    i := 0;
    while i < manager._cleanup_scratch.count {
        _ = manager_remove_node_internal(manager, manager._cleanup_scratch[i], false);
        i += 1;
    }
}

manager_update :: (manager: *Tween_Manager, dt: float32) {
    manager.delta_time = dt;
    manager.now += dt * manager.time_scale;

    it := HA.begin(*manager.nodes);
    while true {
        node, _, ok := HA.next(*it);
        if !ok break;
        if node.parent != TWEEN_HANDLE_NONE {
            continue;
        }
        local_dt := dt;
        if !node.control.independent_update {
            local_dt *= manager.time_scale;
        }
        update_node(manager, node, local_dt);
    }

    cleanup_finished(manager);
    recount_stats(manager);
}
//@endregion
