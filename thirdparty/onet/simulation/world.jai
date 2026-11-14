#scope_file
transport :: #import "thirdparty/onet/transport";
#scope_export

//@region 世界调度与回放类型

System_Id :: #type,distinct u32;

World_Event :: enum {
    Reconcile;
    Replay_Starting;
    Replay_Completed;
    Corrected;
    Full_Reset;
    Missing_Input;
    Result_Mismatch;
}

World_Config :: struct {
    authority: bool;

    local_owner: transport.Connection_Id;

    fixed_dt: float64;

    capacity, max_replay_ticks, max_future_ticks: int;
}

World_Callbacks :: struct {
    user: *void;

    physics: #type (user: *void, world: *Simulation_World, tick: Tick, dt: float64, replay: bool);

    event: #type (user: *void, world: *Simulation_World, event: World_Event, system: System_Id, tick: Tick);

    replay_mode: #type (user: *void, enabled: bool);
}

System_Callbacks :: struct {
    user: *void;

    capture: #type (user: *void, dst: [] u8);

    restore: #type (user: *void, state: [] u8);

    validate_state: #type (user: *void, state: [] u8, tick: Tick) -> bool;

    validate_input: #type (user: *void, input: [] u8, tick: Tick) -> bool;

    sample_input: #type (user: *void, dst: [] u8, tick: Tick);

    early, late: #type (user: *void, step: *World_Step);

    hold: #type (user: *void, enabled: bool);

    equal: #type (user: *void, predicted, authority: [] u8) -> bool;

    // 可选：sample_input 专用的userdata（本地按键、手柄等全局输入源）；nil时用user。

    input_user: *void;
}

System_Config :: struct {
    id: System_Id;

    schema: u32;

    owner: transport.Connection_Id;

    incarnation: u64;

    state_size, input_size: int;

    observer_prediction: bool;

    defaults, carry_mask: [] u8;
    // 借用输入；注册时复制。mask每字节0/1，按成员编码范围设置。

    callbacks: System_Callbacks;
}

World_System :: struct {
    config: System_Config;

    state_offset, input_offset: int;

    last_tick: Tick;
}

World_Meta :: struct {
    controller_tick, last_tick: Tick;

    owner: transport.Connection_Id;

    missing, estimated, predicted: bool;
}

World_Frame :: struct {
    tick: Tick;

    valid: bool;

    state, input, last: [] u8;

    meta: [] World_Meta;
}

World_Step :: struct {
    world: *Simulation_World;

    system: System_Id;

    tick, controller_tick, last_tick: Tick;

    dt: float64;

    missing, estimated, replay: bool;

    input, last, defaults, carry_mask: [] u8;
}

Input_Key :: struct {
    tick: Tick;
    system: System_Id;
}

World_Input :: struct {
    owner: transport.Connection_Id;
    incarnation: u64;
    data: [] u8;
}

Simulation_World :: struct {
    config: World_Config;

    callbacks: World_Callbacks;

    allocator: Allocator;

    systems: [..] *World_System;
    // 按ID稳定排序，所有Early先于任何Late。

    history: [] World_Frame;

    storage, current_input, last_input: [] u8;

    steps: [] World_Step;

    queued: H.Table(Input_Key, World_Input, hash_Input_Key, equal_Input_Key);

    state_size, input_size: int;

    layout: u32;

    tick, applied_tick, snapshot_sequence, received_sequence, correction_serial: u64;

    pending: World_Frame;

    pending_sequence, pending_correction: u64;

    initialized, busy, needs_full: bool;

    // Borrowed runtime driver identity; only one Runtime may bind this world.

    binding: *void;
}

MAX_WORLD_SYSTEMS :: 256;
MAX_WORLD_BYTES :: 1024 * 1024;
//@endregion
//@region 注册、存储与生命周期

world_init :: (w: *Simulation_World, config: World_Config, callbacks: World_Callbacks = .{
}, allocator := context.allocator) -> Status {
    if w.initialized || !finite(config.fixed_dt) || config.fixed_dt <= 0 {
        return .Invalid_Config;
    }

    cfg := config;
    if cfg.capacity == 0 {
        cfg.capacity = 64;
    }

    if cfg.max_replay_ticks == 0 {
        cfg.max_replay_ticks = cfg.capacity - 1;
    }

    if cfg.max_future_ticks == 0 {
        cfg.max_future_ticks = cfg.capacity - 1;
    }

    if cfg.capacity < 2 || cfg.capacity > MAX_HISTORY || cfg.max_replay_ticks < 1 || cfg.max_replay_ticks >= cfg.capacity || cfg.max_future_ticks < 1 || cfg.max_future_ticks >= cfg.capacity {
        return .Invalid_Config;
    }

    w.* = Simulation_World.{
        config = cfg, callbacks = callbacks, allocator = allocator, initialized = true, needs_full = !cfg.authority,
    };

    w.systems = new_dynamic(*World_System, allocator);
    w.queued = new_table(Input_Key, World_Input, allocator, hash_function = hash_Input_Key, compare_function = equal_Input_Key);
    world_rebuild(w);
    return .Ok;
}

world_notify :: (w: *Simulation_World, event: World_Event, id: System_Id = 0, tick: Tick = 0) {
    {
        cb := w.callbacks.event;
        if
        cb != null {
            cb(w.callbacks.user, w, event, id, tick);
        }
    }
}

world_find :: (w: *Simulation_World, id: System_Id) -> (*World_System, int) {
    for s, i: w.systems {
        if s.config.id == id {
            return s, i;
        }
    }

    return null, -1;
}

world_clear_inputs :: (w: *Simulation_World, owner: transport.Connection_Id = 0, all := true) {
    for value, key: w.queued {
        if all || value.owner == owner {
            release(value.data, w.allocator);
            H.table_remove(*w.queued, key);
        }
    }
}

world_release_storage :: (w: *Simulation_World) {
    for f: w.history {
        release(f.meta, w.allocator);
    }

    release(w.history, w.allocator);
    release(w.storage, w.allocator);
    release(w.current_input, w.allocator);
    release(w.last_input, w.allocator);
    release(w.steps, w.allocator);
    w.history, w.storage, w.current_input, w.last_input, w.steps = .[], .[], .[], .[], .[];
    world_frame_destroy(w, *w.pending);
}

world_destroy :: (w: *Simulation_World) {
    if !w.initialized {
        return;
    }

    world_clear_inputs(w);
    world_release_storage(w);
    for s: w.systems {
        release(s.config.defaults, w.allocator);
        release(s.config.carry_mask, w.allocator);
        free(s, w.allocator);
    }

    release(w.systems);
    release(w.queued);
    w.* = .{
    };
}

world_register :: (w: *Simulation_World, config: System_Config) -> Status {
    if !w.initialized || w.busy || config.id == 0 || config.schema == 0 || config.state_size <= 0 || config.state_size > MAX_PAYLOAD || config.input_size < 0 || config.input_size > MAX_PAYLOAD || (w.systems).count >= MAX_WORLD_SYSTEMS {
        return .Invalid_Config;
    }

    {
        s, _ := world_find(w, config.id);
        if
        s != null {
            return .Invalid_Config;
        }
    }

    cb := config.callbacks;
    if cb.capture == null || cb.restore == null || cb.validate_state == null || (config.input_size > 0 && cb.validate_input == null) ||
    ((config.defaults).count != 0 && (config.defaults).count != config.input_size) || ((config.carry_mask).count != 0 && (config.carry_mask).count != config.input_size) {
        return .Invalid_Config;
    }

    for b: config.carry_mask {
        if b > 1 {
            return .Invalid_Config;
        }
    }

    state_size, input_size := w.state_size + config.state_size, w.input_size + config.input_size;
    if state_size + input_size * 2 > MAX_WORLD_BYTES || (state_size + input_size * 2) * w.config.capacity > MAX_STORAGE {
        return .Too_Large;
    }

    s := new_one(World_System, w.allocator);
    s.config = config;
    if s.config.incarnation == 0 {
        s.config.incarnation = 1;
    }

    s.config.defaults = new_slice(u8, config.input_size, w.allocator);
    s.config.carry_mask = new_slice(u8, config.input_size, w.allocator);
    copy_samples(s.config.defaults, config.defaults);
    copy_samples(s.config.carry_mask, config.carry_mask);
    array_add(*w.systems, s);
    {
        i := 1;
        while i < (w.systems).count {
            defer i += 1;
            {
                j := i;
                while j > 0 && w.systems[j].config.id < w.systems[j - 1].config.id {
                    defer j -= 1;
                    w.systems[j], w.systems[j - 1] = w.systems[j - 1], w.systems[j];
                }
            }
        }
    };

    world_rebuild(w);
    return .Ok;
}

world_unregister :: (w: *Simulation_World, id: System_Id) -> bool {
    if !w.initialized || w.busy {
        return false;
    }

    s, index := world_find(w, id);
    if s == null {
        return false;
    }

    release(s.config.defaults, w.allocator);
    release(s.config.carry_mask, w.allocator);
    free(s, w.allocator);
    {
        i := index + 1;
        while i < (w.systems).count {
            defer i += 1;
            w.systems[i - 1] = w.systems[i];
        }
    }

    array_resize(*w.systems, (w.systems).count - 1);
    world_rebuild(w);
    return true;
}

world_set_owner :: (w: *Simulation_World, id: System_Id, owner: transport.Connection_Id, incarnation: u64) -> bool {
    if !w.initialized || w.busy || incarnation == 0 {
        return false;
    }

    s, _ := world_find(w, id);
    if s == null || incarnation < s.config.incarnation {
        return false;
    }

    if s.config.owner == owner && s.config.incarnation == incarnation {
        return true;
    }

    if incarnation == s.config.incarnation {
        return false;
    }

    s.config.owner, s.config.incarnation = owner, incarnation;
    world_rebuild(w);
    return true;
}

// Changing observer strategy invalidates replay dependencies, not authority.

world_set_observer_prediction :: (w: *Simulation_World, id: System_Id, enabled: bool) -> bool {
    if !w.initialized || w.busy {
        return false;
    }

    s, _ := world_find(w, id);
    if s == null {
        return false;
    }

    if s.config.observer_prediction == enabled {
        return true;
    }

    s.config.observer_prediction = enabled;
    world_rebuild(w);
    return true;
}

world_rebuild :: (w: *Simulation_World) {
    world_clear_inputs(w);
    world_release_storage(w);
    w.state_size, w.input_size = 0, 0;
    h := (cast, trunc(u32)(2166136261));
    for s: w.systems {
        s.state_offset, s.input_offset = w.state_size, w.input_size;
        w.state_size += s.config.state_size;
        w.input_size += s.config.input_size;
        for n: (u64.[(cast, trunc(u64)(s.config.id)), (cast, trunc(u64)(s.config.schema)), s.config.incarnation, (cast, trunc(u64)(s.config.state_size)), (cast, trunc(u64)(s.config.input_size))]) {
            {
                i := 0;
                while i < 8 {
                    defer i += 1;
                    h = (h ^ (cast, trunc(u32)((cast, trunc(u8)(n >> (cast, trunc(u64)(i * 8))))))) * 16777619;
                }
            }
        }
    }

    w.layout = (ifx h == 0 then 1 else h);
    w.history = new_slice(World_Frame, w.config.capacity, w.allocator);
    stride := w.state_size + w.input_size * 2;
    w.storage = new_slice(u8, stride * w.config.capacity, w.allocator);
    w.current_input = new_slice(u8, w.input_size, w.allocator);
    w.last_input = new_slice(u8, w.input_size, w.allocator);
    w.steps = new_slice(World_Step, (w.systems).count, w.allocator);
    for *f, i: w.history {
        start := i * stride;
        f.*.state = view(w.storage, start, start + w.state_size);
        f.*.input = view(w.storage, start + w.state_size, start + w.state_size + w.input_size);
        f.*.last = view(w.storage, start + w.state_size + w.input_size, start + stride);
        f.*.meta = new_slice(World_Meta, (w.systems).count, w.allocator);
    }

    for s: w.systems {
        copy_samples(view(w.last_input, s.input_offset, s.input_offset + s.config.input_size), s.config.defaults);
        s.last_tick = 0;
    }

    w.needs_full = !w.config.authority;
    world_capture_frame(w, w.tick);
}

world_frame :: (w: *Simulation_World, tick: Tick) -> *World_Frame {
    if (w.history).count == 0 {
        return null;
    }

    f := *w.history[tick % (cast, trunc(u64)((w.history).count))];
    return (ifx f.valid && f.tick == tick then f else null);
}

world_predicted :: (w: *Simulation_World, s: *World_System) -> bool {
    return w.config.authority || (w.config.local_owner != 0 && s.config.owner == w.config.local_owner) || s.config.observer_prediction;
}

world_capture_frame :: (w: *Simulation_World, tick: Tick) -> *World_Frame {
    f := *w.history[tick % (cast, trunc(u64)((w.history).count))];
    f.tick, f.valid = tick, true;
    copy_samples(f.input, w.current_input);
    copy_samples(f.last, w.last_input);
    for s, i: w.systems {
        s.config.callbacks.capture(s.config.callbacks.user, view(f.state, s.state_offset, s.state_offset + s.config.state_size));
        f.meta[i] = .{
            controller_tick = tick, last_tick = s.last_tick, owner = s.config.owner, predicted = world_predicted(w, s),
        };
    }

    return f;
}

world_frame_destroy :: (w: *Simulation_World, f: *World_Frame) {
    release(f.state, w.allocator);
    release(f.input, w.allocator);
    release(f.last, w.allocator);
    release(f.meta, w.allocator);
    f.* = .{
    };
}

//@endregion
//@region 每tick输入与全部系统的固定阶段

world_queue_input :: (w: *Simulation_World, owner: transport.Connection_Id, id: System_Id, tick: Tick, incarnation: u64, input: [] u8) -> Status {
    if !w.initialized || w.busy {
        return .Not_Ready;
    }

    s, _ := world_find(w, id);
    if s == null || s.config.owner != owner || s.config.incarnation != incarnation || (input).count != s.config.input_size || (s.config.input_size > 0 && !s.config.callbacks.validate_input(s.config.callbacks.user, input, tick)) {
        return .Invalid_Data;
    }

    if tick <= w.tick {
        return .Stale;
    }

    if tick - w.tick > (cast, trunc(u64)(w.config.max_future_ticks)) {
        return .Out_Of_Order;
    }

    key := Input_Key.{
        tick, id,
    };

    {
        _, exists := table_get(*w.queued, key);
        if
        exists {
            return .Duplicate;
        }
    }

    if (w.queued).count >= w.config.capacity * max(1, (w.systems).count) {
        return .Queue_Full;
    }

    data := new_slice(u8, (input).count, w.allocator);
    copy_samples(data, input);
    H.table_set(*w.queued, key, .{
        owner, incarnation, data,
    });

    return .Ok;
}

// 仅在missing tick主动调用时重用上次真实输入；默认不重复jump等一次性字段。

world_try_last_state :: (step: *World_Step, include_not_carried := false) -> (Tick, bool) {
    if !step.missing || step.last_tick == 0 {
        return 0, false;
    }

    for _, i: step.input {
        step.input[i] = (ifx (include_not_carried || step.carry_mask[i] != 0) then step.last[i] else step.defaults[i]);
    }

    return step.last_tick, true;
}

world_step :: (w: *Simulation_World) -> Status {
    if !w.initialized || w.busy || (w.history).count == 0 {
        return .Not_Ready;
    }

    if w.needs_full {
        return .Need_Resync;
    }

    if !w.config.authority && w.tick >= w.applied_tick && w.tick - w.applied_tick >= (cast, trunc(u64)(w.config.capacity - 1)) {
        w.needs_full = true;
        return .Need_Resync;
    }

    if w.tick >= MAX_TICK - 1 {
        return .Exhausted;
    }

    w.busy = true;
    defer w.busy = false;
    next := w.tick + 1;
    f := *w.history[next % (cast, trunc(u64)((w.history).count))];
    for s, i: w.systems {
        cfg := *s.config;
        input := view(w.current_input, s.input_offset, s.input_offset + cfg.input_size);
        last := view(w.last_input, s.input_offset, s.input_offset + cfg.input_size);
        copy_samples(input, cfg.defaults);
        missing := cfg.owner != 0;
        key := Input_Key.{
            next, cfg.id,
        };

        {
            q, found := table_get(*w.queued, key);
            if
            found && q.owner == cfg.owner && q.incarnation == cfg.incarnation {
                copy_samples(input, q.data);
                missing = false;
            } else if cfg.owner == 0 || (!w.config.authority && cfg.owner == w.config.local_owner) {
                {
                    cb := cfg.callbacks.sample_input;
                    if
                    cb != null {
                        cb((ifx cfg.callbacks.input_user != null then cfg.callbacks.input_user else cfg.callbacks.user), input, next);
                    }
                }

                missing = false;
            }
        }

        if cfg.input_size > 0 && !cfg.callbacks.validate_input(cfg.callbacks.user, input, next) {
            return .Invalid_Data;
        }

        w.steps[i] = .{
            world = w, system = cfg.id, tick = next, controller_tick = next, last_tick = s.last_tick, dt = w.config.fixed_dt, missing = missing, estimated = missing, input = input, last = last, defaults = cfg.defaults, carry_mask = cfg.carry_mask,
        };
    }

    copy_samples(f.last, w.last_input);
    for s, i: w.systems {
        step := *w.steps[i];
        step.last = view(f.last, s.input_offset, s.input_offset + s.config.input_size);
        f.meta[i] = .{
            controller_tick = next, last_tick = s.last_tick, owner = s.config.owner, missing = step.missing, estimated = step.estimated, predicted = world_predicted(w, s),
        };
    }

    world_run_phases(w, f, false);
    copy_samples(f.input, w.current_input);
    for s, i: w.systems {
        cfg := *s.config;
        if !w.steps[i].missing {
            copy_samples(view(w.last_input, s.input_offset, s.input_offset + cfg.input_size), w.steps[i].input);
            s.last_tick = next;
        } else {
            world_notify(w, .Missing_Input, cfg.id, next);
        }

        cfg.callbacks.capture(cfg.callbacks.user, view(f.state, s.state_offset, s.state_offset + cfg.state_size));
    }

    f.tick, f.valid = next, true;
    w.tick = next;
    for value, key: w.queued {
        if key.tick <= next {
            release(value.data, w.allocator);
            H.table_remove(*w.queued, key);
        }
    }

    return .Ok;
}

world_run_phases :: (w: *Simulation_World, f: *World_Frame, replay: bool) {
    held := new_slice(u8, w.state_size, w.allocator);
    defer release(held, w.allocator);
    for s, i: w.systems {
        if !f.meta[i].predicted {
            s.config.callbacks.capture(s.config.callbacks.user, view(held, s.state_offset, s.state_offset + s.config.state_size));
            {
                cb := s.config.callbacks.hold;
                if
                cb != null {
                    cb(s.config.callbacks.user, true);
                }
            }
        }
    }

    for s, i: w.systems {
        if f.meta[i].predicted {
            {
                cb := s.config.callbacks.early;
                if
                cb != null {
                    cb(s.config.callbacks.user, *w.steps[i]);
                }
            }
        }
    }

    {
        cb := w.callbacks.physics;
        if
        cb != null && (w.steps).count > 0 {
            cb(w.callbacks.user, w, w.steps[0].tick, w.config.fixed_dt, replay);
        }
    }

    for s, i: w.systems {
        if !f.meta[i].predicted {
            s.config.callbacks.restore(s.config.callbacks.user, view(held, s.state_offset, s.state_offset + s.config.state_size));
        }
    }

    for s, i: w.systems {
        if f.meta[i].predicted {
            {
                cb := s.config.callbacks.late;
                if
                cb != null {
                    cb(s.config.callbacks.user, *w.steps[i]);
                }
            }
        }
    }

    for s, i: w.systems {
        if !f.meta[i].predicted {
            s.config.callbacks.restore(s.config.callbacks.user, view(held, s.state_offset, s.state_offset + s.config.state_size));
            if !replay {
                {
                    cb := s.config.callbacks.hold;
                    if
                    cb != null {
                        cb(s.config.callbacks.user, false);
                    }
                }
            }
        }
    }
}

world_hash :: (data: [] u8) -> u32 {
    h := (cast, trunc(u32)(2166136261));
    for b: data {
        h = (h ^ (cast, trunc(u32)(b))) * 16777619;
    }

    return h;
}

world_system_hash :: (w: *Simulation_World, f: *World_Frame, id: System_Id) -> (u32, bool) {
    s, _ := world_find(w, id);
    if f == null || s == null {
        return 0, false;
    }

    return world_hash(view(f.state, s.state_offset, s.state_offset + s.config.state_size)), true;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
