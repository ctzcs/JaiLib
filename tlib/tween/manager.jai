// manager.jai
// Port of Ascension/tlib/tween/manager.odin
// Tween system entry point: owns all nodes, advances time, dispatches updates,
// and cleans up finished nodes.
//
// Note: Tween_Handle is an alias of the handle_array Handle (Jai has no
// distinct types here); bare == on handles needs a local operator ==.

#import "Basic";
#import "tween/tween";

HA :: #import "handle/handle_array/handle_array";

operator == :: inline (a: HA.Handle, b: HA.Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// Node handle exposed to the outside world.
Tween_Handle :: HA.Handle;
TWEEN_HANDLE_NONE :: Tween_Handle.{};

// Groups nodes together for batch Pause/Kill.
Tween_Group_Id :: u32;

// Playback state machine. The manager advances a node based on this state.
Playback_State :: enum u8 {
    Idle;
    Delayed;
    Playing;
    Paused;
    Completed;
    Killed;
}

// Top-level runtime node kinds managed by the manager.
Node_Kind :: enum u8 {
    Tween;
    Sequence;
}

// Sequence timeline entry kinds (internal steps, not manager-level nodes).
Sequence_Step_Kind :: enum u8 {
    Tween;
    Callback;
    Interval;
}

// Loop configuration. count = -1 means infinite.
Loop_Config :: struct {
    count: s32; // -1 means infinite
    mode:  Repeat_Mode;
}

// Lifecycle callback signatures. Only the node handle is passed, so the
// manager layer never exposes concrete payload types.
Tween_Callback_Proc :: #type (handle: Tween_Handle);
Sequence_Callback_Proc :: #type ();

// Node lifecycle callback set.
Tween_Callbacks :: struct {
    on_start:         Tween_Callback_Proc;
    on_update:        Tween_Callback_Proc;
    on_step_complete: Tween_Callback_Proc;
    on_complete:      Tween_Callback_Proc;
    on_kill:          Tween_Callback_Proc;
}

// Pure time data, shared by Sequence/Interval too.
Tween_Timing :: struct {
    created_at: float32; // creation time
    start_at:   float32; // real play start (after delay)
    delay:      float32; // wait before starting
    duration:   float32; // single play duration
    elapsed:    float32; // local time already advanced
    time_scale: float32; // node-level time scale
}

// Runtime control info.
Tween_Control :: struct {
    state:                 Playback_State;
    started:               bool; // on_start fired?
    loops_done:            s32;
    auto_kill:             bool;
    use_manager_auto_kill: bool;
    is_relative:           bool;
    independent_update:    bool;
}

// Type-erased behavior entry points.
Tween_Node_Update_Proc    :: #type (node: *Tween_Node, dt: float32);
Tween_Node_Reset_Proc     :: #type (node: *Tween_Node);
Tween_Node_Kill_Proc      :: #type (node: *Tween_Node);
Tween_Node_Set_Loops_Proc :: #type (node: *Tween_Node, count: s32, mode: Repeat_Mode);

// Per-node virtual table.
Tween_Node_VTable :: struct {
    update:    Tween_Node_Update_Proc;
    reset:     Tween_Node_Reset_Proc;
    kill:      Tween_Node_Kill_Proc;
    set_loops: Tween_Node_Set_Loops_Proc;
}

// Runtime node managed by the manager.
Tween_Node :: struct {
    handle: Tween_Handle; // stable handle of this node
    kind:   Node_Kind;

    group: Tween_Group_Id;
    tag:   string; // e.g. "ui" / "camera"

    active: bool;
    parent: Tween_Handle; // parent sequence, if any

    timing:    Tween_Timing;
    loops:     Loop_Config;
    control:   Tween_Control;
    callbacks: Tween_Callbacks;

    payload: *void;          // points at the real tween/sequence data
    vtable:  Tween_Node_VTable;
}

// One timeline step in a Sequence. Tween/Callback/Interval share one entry.
Sequence_Entry :: struct {
    kind:      Sequence_Step_Kind;
    child:     Tween_Handle;
    callback:  Sequence_Callback_Proc;
    start_at:  float32; // position on the sequence-local timeline
    duration:  float32; // step duration; 0 for callbacks
    triggered: bool;    // callback already fired?
}

// Runtime data of a Sequence.
Sequence_Runtime :: struct {
    cursor:   float32;
    duration: float32;
    entries:  [..] Sequence_Entry;
}

// Manager global configuration.
Tween_Manager_Config :: struct {
    default_time_scale: float32;
    auto_kill_finished: bool;
    auto_compact:       bool;
}

// Runtime statistics, mainly for debugging.
Tween_Manager_Stats :: struct {
    total_nodes:     int;
    active_nodes:    int;
    playing_nodes:   int;
    paused_nodes:    int;
    completed_nodes: int;
    killed_nodes:    int;
}

// Tween system entry point.
Tween_Manager :: struct {
    now:        float32;
    delta_time: float32;
    time_scale: float32;

    nodes: HA.Pool(Tween_Node, Tween_Handle);
    _cleanup_scratch: [..] Tween_Handle;

    config: Tween_Manager_Config;
    stats:  Tween_Manager_Stats;
}

manager_make :: () -> Tween_Manager {
    result: Tween_Manager;
    result.time_scale = 1;
    result.config = .{ default_time_scale = 1, auto_kill_finished = true, auto_compact = true };
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
        if node.control.state == .Playing {
            stats.playing_nodes += 1;
        } else if node.control.state == .Paused {
            stats.paused_nodes += 1;
        } else if node.control.state == .Completed {
            stats.completed_nodes += 1;
        } else if node.control.state == .Killed {
            stats.killed_nodes += 1;
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
    node.control.use_manager_auto_kill = true;
    node.timing.created_at = manager.now;
    node.timing.start_at = manager.now + node.timing.delay;

    handle := HA.add(*manager.nodes, node);
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
    <<node = Tween_Node.{};
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
    HA.reset(*manager.nodes, destroy_node);
    array_reset_keeping_memory(*manager._cleanup_scratch);
    manager.now = 0;
    manager.delta_time = 0;
    manager.stats = Tween_Manager_Stats.{};
}

manager_delete :: (manager: *Tween_Manager) {
    HA.delete(*manager.nodes, destroy_node);
    array_free(manager._cleanup_scratch);
    <<manager = Tween_Manager.{};
}

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
    node.callbacks = Tween_Callbacks.{};
    return true;
}

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
                i := 0;
                while i < crossed {
                    call_callback(node.callbacks.on_step_complete, node.handle);
                    i += 1;
                }
            }
        }
        if node.loops.count > 0 && node.control.loops_done >= node.loops.count {
            max_elapsed := cast(float32) node.loops.count * node.timing.duration;
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
        _ = manager_remove_node_internal(manager, manager._cleanup_scratch[cast(s64) i], false);
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
