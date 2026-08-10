// managed_sequence.jai
// Port of Ascension/tlib/tween/managed_sequence.odin
// Sequence timeline: append/join/insert/prepend tween nodes, callbacks and
// intervals on a local timeline.

#import "Basic";
#import "tween/tween";
#import "tween/manager";
#import "tween/managed_tween";

Managed_Sequence_Data :: struct {
    manager: *Tween_Manager;
    runtime: Sequence_Runtime;
}

Sequence_Attach_Proc :: #type (manager: *Tween_Manager, seq: Tween_Handle, child: Tween_Handle) -> bool;

sequence_get_data :: (node: *Tween_Node) -> *Managed_Sequence_Data {
    if node == null || node.kind != .Sequence || node.payload == null {
        return null;
    }
    return cast(*Managed_Sequence_Data) node.payload;
}

sequence_get_data_by_handle :: (manager: *Tween_Manager, handle: Tween_Handle) -> *Managed_Sequence_Data {
    node := manager_get_node_ptr(<<manager, handle);
    if node == null || node.kind != .Sequence {
        return null;
    }
    return sequence_get_data(node);
}

sequence_is_ancestor :: (manager: *Tween_Manager, ancestor: Tween_Handle, child: Tween_Handle) -> bool {
    current := child;
    while !(current == TWEEN_HANDLE_NONE) {
        if current == ancestor {
            return true;
        }
        node := manager_get_node_ptr(<<manager, current);
        if node == null {
            return false;
        }
        current = node.parent;
    }
    return false;
}

sequence_recompute_duration :: (data: *Managed_Sequence_Data) -> float32 {
    if data == null {
        return 0;
    }

    duration: float32 = 0;
    i := 0;
    while i < data.runtime.entries.count {
        entry := data.runtime.entries[cast(s64) i];
        end_at := entry.start_at + entry.duration;
        if end_at > duration {
            duration = end_at;
        }
        i += 1;
    }
    data.runtime.duration = duration;
    return duration;
}

sequence_sync_duration :: (manager: *Tween_Manager, seq: Tween_Handle, data: *Managed_Sequence_Data) {
    if data == null {
        return;
    }
    seq_node := manager_get_node_ptr(<<manager, seq);
    if seq_node == null {
        return;
    }

    duration := sequence_recompute_duration(data);
    seq_node.timing.duration = duration;

    if seq_node.parent == TWEEN_HANDLE_NONE {
        return;
    }

    parent_data := sequence_get_data_by_handle(manager, seq_node.parent);
    if parent_data == null {
        return;
    }

    i := 0;
    while i < parent_data.runtime.entries.count {
        entry := *parent_data.runtime.entries[cast(s64) i];
        if entry.kind == .Tween && entry.child == seq {
            entry.duration = duration;
            break;
        }
        i += 1;
    }

    sequence_sync_duration(manager, seq_node.parent, parent_data);
}

sequence_child_total_duration :: (node: *Tween_Node) -> (duration: float32, ok: bool) {
    if node == null {
        return 0, false;
    }

    if node.loops.count < 0 {
        return 0, false;
    }

    loop_count: s32 = 1;
    if node.loops.count > 0 {
        loop_count = node.loops.count;
    }

    return node.timing.delay + node.timing.duration * cast(float32) loop_count, true;
}

sequence_prepare_child :: (manager: *Tween_Manager, seq: Tween_Handle, child: Tween_Handle) -> bool {
    node := manager_get_node_ptr(<<manager, child);
    if node == null {
        return false;
    }
    if child == seq {
        return false;
    }
    if node.parent != TWEEN_HANDLE_NONE {
        return false;
    }
    if sequence_is_ancestor(manager, child, seq) {
        return false;
    }

    _ = manager_rewind(manager, child);

    node.parent = seq;
    node.active = false;
    node.control.use_manager_auto_kill = false;
    node.control.auto_kill = false;
    return true;
}

sequence_attach_created_handle :: (manager: *Tween_Manager, seq: Tween_Handle, handle: Tween_Handle, attach: Sequence_Attach_Proc) -> (Tween_Handle, bool) {
    if !attach(manager, seq, handle) {
        _ = manager_remove_node(manager, handle);
        return TWEEN_HANDLE_NONE, false;
    }
    return handle, true;
}

sequence_attach_created_handle_at :: (manager: *Tween_Manager, seq: Tween_Handle, at: float32, handle: Tween_Handle) -> (Tween_Handle, bool) {
    if !sequence_insert(manager, seq, at, handle) {
        _ = manager_remove_node(manager, handle);
        return TWEEN_HANDLE_NONE, false;
    }
    return handle, true;
}

sequence_update_proc :: (node: *Tween_Node, dt: float32) {
    _ = dt;

    data := sequence_get_data(node);
    if data == null || data.manager == null {
        return;
    }

    manager := data.manager;
    prev_cursor := data.runtime.cursor;
    curr_cursor := node.timing.elapsed;

    i := 0;
    while i < data.runtime.entries.count {
        entry := *data.runtime.entries[cast(s64) i];

        if entry.kind == .Tween {
            if curr_cursor < entry.start_at {
                i += 1;
                continue;
            }

            child := manager_get_node_ptr(<<manager, entry.child);
            if child == null {
                i += 1;
                continue;
            }

            if !child.active {
                child.active = true;
                if child.timing.delay > 0 {
                    child.control.state = .Delayed;
                    child.timing.start_at = manager.now + child.timing.delay;
                } else {
                    child.control.state = .Idle;
                }
            }

            child_prev := prev_cursor;
            if child_prev < entry.start_at {
                child_prev = entry.start_at;
            }

            child_curr := curr_cursor;
            child_end := entry.start_at + entry.duration;
            if child_curr > child_end {
                child_curr = child_end;
            }

            child_dt := child_curr - child_prev;
            if child_dt > 0 {
                update_node(manager, child, child_dt);
            }
        } else if entry.kind == .Callback {
            if !entry.triggered && curr_cursor >= entry.start_at {
                if entry.callback != null {
                    entry.callback();
                }
                entry.triggered = true;
            }
        }

        i += 1;
    }

    data.runtime.cursor = curr_cursor;
    data.runtime.duration = node.timing.duration;
}

sequence_reset_proc :: (node: *Tween_Node) {
    data := sequence_get_data(node);
    if data == null || data.manager == null {
        return;
    }

    data.runtime.cursor = 0;

    i := 0;
    while i < data.runtime.entries.count {
        entry := *data.runtime.entries[cast(s64) i];
        entry.triggered = false;

        if entry.kind == .Tween {
            _ = manager_rewind(data.manager, entry.child);
        }
        i += 1;
    }
}

sequence_kill_proc :: (node: *Tween_Node) {
    data := sequence_get_data(node);
    if data == null {
        return;
    }

    if data.manager != null {
        i := 0;
        while i < data.runtime.entries.count {
            entry := data.runtime.entries[cast(s64) i];
            if entry.kind == .Tween {
                child := manager_get_node_ptr(<<data.manager, entry.child);
                if child != null {
                    child.parent = TWEEN_HANDLE_NONE;
                    _ = manager_kill(data.manager, entry.child);
                }
            }
            i += 1;
        }
    }

    array_free(data.runtime.entries);
    free(data);
    node.payload = null;
}

// Sequence creation entry point. The returned sequence node can be grown with
// Append/Join/Insert/Prepend.
manager_add_sequence :: (manager: *Tween_Manager) -> Tween_Handle {
    data := New(Managed_Sequence_Data);
    <<data = .{ manager = manager };

    node: Tween_Node;
    node.kind = .Sequence;
    node.active = true;
    node.parent = TWEEN_HANDLE_NONE;
    node.timing = .{ duration = 0, time_scale = 1 };
    node.loops = .{ count = 1, mode = .Once };
    node.control = .{ state = .Idle, auto_kill = true };
    node.payload = cast(*void) data;
    node.vtable = .{ update = sequence_update_proc, reset = sequence_reset_proc, kill = sequence_kill_proc };

    return manager_add_node(manager, node);
}

// Appends an already-registered child node to the end of the sequence.
sequence_append :: (manager: *Tween_Manager, seq: Tween_Handle, child: Tween_Handle) -> bool {
    data := sequence_get_data_by_handle(manager, seq);
    if data == null {
        return false;
    }

    child_node := manager_get_node_ptr(<<manager, child);
    if child_node == null {
        return false;
    }

    duration, ok := sequence_child_total_duration(child_node);
    if !ok {
        return false;
    }
    if !sequence_prepare_child(manager, seq, child) {
        return false;
    }

    entry := Sequence_Entry.{ kind = .Tween, child = child, start_at = data.runtime.duration, duration = duration };
    array_add(*data.runtime.entries, entry);

    sequence_sync_duration(manager, seq, data);

    return true;
}

// Convenience: creates a tween node internally and appends it.
sequence_append_tween :: (manager: *Tween_Manager, seq: Tween_Handle, tween: Tween($T), setter: (value: T)) -> (Tween_Handle, bool) {
    handle := manager_add_tween(manager, tween, setter);
    result, ok := sequence_attach_created_handle(manager, seq, handle, sequence_append);
    return result, ok;
}

// Convenience property binding: appends a tween writing into a target pointer.
sequence_append_tween_to :: (manager: *Tween_Manager, seq: Tween_Handle, tween: Tween($T), target: *T) -> (Tween_Handle, bool) {
    handle := manager_add_tween_to(manager, tween, target);
    result, ok := sequence_attach_created_handle(manager, seq, handle, sequence_append);
    return result, ok;
}

sequence_append_property_tween :: (manager: *Tween_Manager, seq: Tween_Handle, getter: () -> $T, setter: (value: T), finish: T, config: Tween_Config, lerp: (a: T, b: T, ratio: float32) -> T) -> (Tween_Handle, bool) {
    start := getter();
    tween := make_ex(start, finish, 0, config, lerp);
    return sequence_append_tween(manager, seq, tween, setter);
}

// Joins a child node at the start time of the current last step.
sequence_join :: (manager: *Tween_Manager, seq: Tween_Handle, child: Tween_Handle) -> bool {
    data := sequence_get_data_by_handle(manager, seq);
    if data == null {
        return false;
    }

    child_node := manager_get_node_ptr(<<manager, child);
    if child_node == null {
        return false;
    }

    duration, ok := sequence_child_total_duration(child_node);
    if !ok {
        return false;
    }
    if !sequence_prepare_child(manager, seq, child) {
        return false;
    }

    start_at: float32 = 0;
    if data.runtime.entries.count > 0 {
        start_at = data.runtime.entries[data.runtime.entries.count - 1].start_at;
    }

    entry := Sequence_Entry.{ kind = .Tween, child = child, start_at = start_at, duration = duration };
    array_add(*data.runtime.entries, entry);

    sequence_sync_duration(manager, seq, data);

    return true;
}

sequence_join_tween :: (manager: *Tween_Manager, seq: Tween_Handle, tween: Tween($T), setter: (value: T)) -> (Tween_Handle, bool) {
    handle := manager_add_tween(manager, tween, setter);
    result, ok := sequence_attach_created_handle(manager, seq, handle, sequence_join);
    return result, ok;
}

sequence_join_tween_to :: (manager: *Tween_Manager, seq: Tween_Handle, tween: Tween($T), target: *T) -> (Tween_Handle, bool) {
    handle := manager_add_tween_to(manager, tween, target);
    result, ok := sequence_attach_created_handle(manager, seq, handle, sequence_join);
    return result, ok;
}

sequence_join_property_tween :: (manager: *Tween_Manager, seq: Tween_Handle, getter: () -> $T, setter: (value: T), finish: T, config: Tween_Config, lerp: (a: T, b: T, ratio: float32) -> T) -> (Tween_Handle, bool) {
    start := getter();
    tween := make_ex(start, finish, 0, config, lerp);
    return sequence_join_tween(manager, seq, tween, setter);
}

// Inserts a child node at a specific position on the sequence timeline.
sequence_insert :: (manager: *Tween_Manager, seq: Tween_Handle, at: float32, child: Tween_Handle) -> bool {
    data := sequence_get_data_by_handle(manager, seq);
    if data == null {
        return false;
    }
    if at < 0 {
        return false;
    }

    child_node := manager_get_node_ptr(<<manager, child);
    if child_node == null {
        return false;
    }

    duration, ok := sequence_child_total_duration(child_node);
    if !ok {
        return false;
    }
    if !sequence_prepare_child(manager, seq, child) {
        return false;
    }

    entry := Sequence_Entry.{ kind = .Tween, child = child, start_at = at, duration = duration };
    array_add(*data.runtime.entries, entry);
    sequence_sync_duration(manager, seq, data);
    return true;
}

sequence_insert_tween :: (manager: *Tween_Manager, seq: Tween_Handle, at: float32, tween: Tween($T), setter: (value: T)) -> (Tween_Handle, bool) {
    handle := manager_add_tween(manager, tween, setter);
    result, ok := sequence_attach_created_handle_at(manager, seq, at, handle);
    return result, ok;
}

sequence_insert_tween_to :: (manager: *Tween_Manager, seq: Tween_Handle, at: float32, tween: Tween($T), target: *T) -> (Tween_Handle, bool) {
    handle := manager_add_tween_to(manager, tween, target);
    result, ok := sequence_attach_created_handle_at(manager, seq, at, handle);
    return result, ok;
}

sequence_insert_property_tween :: (manager: *Tween_Manager, seq: Tween_Handle, at: float32, getter: () -> $T, setter: (value: T), finish: T, config: Tween_Config, lerp: (a: T, b: T, ratio: float32) -> T) -> (Tween_Handle, bool) {
    start := getter();
    tween := make_ex(start, finish, 0, config, lerp);
    return sequence_insert_tween(manager, seq, at, tween, setter);
}

// Prepends a child node to the sequence start, shifting the existing timeline.
sequence_prepend :: (manager: *Tween_Manager, seq: Tween_Handle, child: Tween_Handle) -> bool {
    data := sequence_get_data_by_handle(manager, seq);
    if data == null {
        return false;
    }

    child_node := manager_get_node_ptr(<<manager, child);
    if child_node == null {
        return false;
    }

    duration, ok := sequence_child_total_duration(child_node);
    if !ok {
        return false;
    }
    if !sequence_prepare_child(manager, seq, child) {
        return false;
    }

    i := 0;
    while i < data.runtime.entries.count {
        data.runtime.entries[cast(s64) i].start_at += duration;
        i += 1;
    }

    entry := Sequence_Entry.{ kind = .Tween, child = child, start_at = 0, duration = duration };
    array_add(*data.runtime.entries, entry);
    sequence_sync_duration(manager, seq, data);
    return true;
}

sequence_prepend_tween :: (manager: *Tween_Manager, seq: Tween_Handle, tween: Tween($T), setter: (value: T)) -> (Tween_Handle, bool) {
    handle := manager_add_tween(manager, tween, setter);
    result, ok := sequence_attach_created_handle(manager, seq, handle, sequence_prepend);
    return result, ok;
}

sequence_prepend_tween_to :: (manager: *Tween_Manager, seq: Tween_Handle, tween: Tween($T), target: *T) -> (Tween_Handle, bool) {
    handle := manager_add_tween_to(manager, tween, target);
    result, ok := sequence_attach_created_handle(manager, seq, handle, sequence_prepend);
    return result, ok;
}

sequence_prepend_property_tween :: (manager: *Tween_Manager, seq: Tween_Handle, getter: () -> $T, setter: (value: T), finish: T, config: Tween_Config, lerp: (a: T, b: T, ratio: float32) -> T) -> (Tween_Handle, bool) {
    start := getter();
    tween := make_ex(start, finish, 0, config, lerp);
    return sequence_prepend_tween(manager, seq, tween, setter);
}

// Appends a callback step at the end of the sequence.
sequence_append_callback :: (manager: *Tween_Manager, seq: Tween_Handle, callback: Sequence_Callback_Proc) -> bool {
    data := sequence_get_data_by_handle(manager, seq);
    if data == null {
        return false;
    }

    entry := Sequence_Entry.{ kind = .Callback, callback = callback, start_at = data.runtime.duration, duration = 0 };
    array_add(*data.runtime.entries, entry);

    sequence_sync_duration(manager, seq, data);

    return true;
}

// Appends a pure wait (interval) step at the end of the sequence.
sequence_append_interval :: (manager: *Tween_Manager, seq: Tween_Handle, interval: float32) -> bool {
    data := sequence_get_data_by_handle(manager, seq);
    if data == null {
        return false;
    }
    if interval < 0 {
        return false;
    }

    entry := Sequence_Entry.{ kind = .Interval, start_at = data.runtime.duration, duration = interval };
    array_add(*data.runtime.entries, entry);

    sequence_sync_duration(manager, seq, data);

    return true;
}
