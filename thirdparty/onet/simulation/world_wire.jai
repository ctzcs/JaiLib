#scope_file
core :: #import "thirdparty/onet/core";
transport :: #import "thirdparty/onet/transport";
wire :: #import "thirdparty/onet/wire";
#scope_export

//@region 世界消息有界编码

WORLD_MAGIC :: (cast, trunc(u32)(0x574c4432));

World_Packet :: enum u8 {
    Input = 1;
    Snapshot;
    Result;
}

world_header :: (w: *Simulation_World, writer: *core.Writer, kind: World_Packet, layout_override: u32 = 0) {
    core.write_uint32(writer, WORLD_MAGIC, .Uncompressed);
    core.write_uint8(writer, 1, .Uncompressed);
    core.write_uint8(writer, (cast, trunc(u8)(kind)), .Uncompressed);
    core.write_uint32(writer, (ifx layout_override == 0 then w.layout else layout_override), .Uncompressed);
}

world_read_header :: (w: *Simulation_World, r: *core.Reader, kind: World_Packet, layout_required := true) -> bool {
    magic := core.read_uint32(r, .Uncompressed);
    version := core.read_uint8(r, .Uncompressed);
    actual := core.read_uint8(r, .Uncompressed);
    layout := core.read_uint32(r, .Uncompressed);
    return r.err == .None && magic == WORLD_MAGIC && version == 1 && actual == (cast, trunc(u8)(kind)) && (!layout_required || layout == w.layout);
}

world_encode_input :: (w: *Simulation_World, owner: transport.Connection_Id, tick: Tick) -> ([] u8, Status) {
    f := world_frame(w, tick);
    if f == null {
        return .[], .Expired;
    }

    writer: core.Writer;
    core.writer_init(*writer);
    defer core.writer_destroy(*writer);
    world_header(w, *writer, .Input);
    core.write_uint64(*writer, tick, .Uncompressed);
    count := 0;
    for s: w.systems {
        if s.config.owner == owner && s.config.input_size > 0 {
            count += 1;
        }
    }

    wire.write_count(*writer, count, MAX_WORLD_SYSTEMS);
    for s: w.systems {
        cfg := *s.config;
        if cfg.owner != owner || cfg.input_size == 0 {
            continue;
        }

        core.write_uint32(*writer, (cast, trunc(u32)(cfg.id)), .Uncompressed);
        core.write_uint32(*writer, cfg.schema, .Uncompressed);
        core.write_uint64(*writer, cfg.incarnation, .Uncompressed);
        wire.write_bytes(*writer, view(f.input, s.input_offset, s.input_offset + cfg.input_size), MAX_PAYLOAD);
    }

    if writer.err != .None || core.writer_bytes_written(*writer) > wire.MAX_PAYLOAD {
        return .[], .Too_Large;
    }

    return core.writer_to_array(*writer), .Ok;
}

World_Input_Authorizer :: (user: *void, id: System_Id, owner: transport.Connection_Id) -> bool;

world_receive_input :: (w: *Simulation_World, owner: transport.Connection_Id, data: [] u8, admit: World_Input_Authorizer = null, user: *void = null) -> Status {
    if !w.initialized || !w.config.authority || w.busy || owner == 0 || (data).count > wire.MAX_PAYLOAD {
        return .Invalid_Data;
    }

    r: core.Reader;
    core.reader_init(*r, data);
    if !world_read_header(w, *r, .Input, false) {
        return .Schema_Mismatch;
    }

    tick := core.read_uint64(*r, .Uncompressed);
    if tick <= w.tick {
        return .Stale;
    }

    if tick - w.tick > (cast, trunc(u64)(w.config.max_future_ticks)) {
        return .Out_Of_Order;
    }

    count, ok := wire.read_count(*r, MAX_WORLD_SYSTEMS);
    if !ok {
        return .Invalid_Data;
    }

    keys: [..] Input_Key;
    values: [..] World_Input;
    defer {
        for v: values {
            release(v.data, w.allocator);
        };
        release(keys);
        release(values);
    }

    last := (cast(System_Id) (0));
    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;

            id := (cast(System_Id) (core.read_uint32(*r, .Uncompressed)));
            schema := core.read_uint32(*r, .Uncompressed);
            incarnation := core.read_uint64(*r, .Uncompressed);
            bytes, valid := wire.read_bytes(*r, MAX_PAYLOAD);
            if !valid {
                return .Invalid_Data;
            }

            s, _ := world_find(w, id);
            if s == null || id <= last || s.config.schema != schema || s.config.incarnation != incarnation || s.config.owner != owner || (bytes).count != s.config.input_size || s.config.callbacks.validate_input == null || !s.config.callbacks.validate_input(s.config.callbacks.user, bytes, tick) {
                release(bytes);
                return .Invalid_Data;
            }

            if admit != null && !admit(user, id, owner) {
                release(bytes);
                return .Invalid_Data;
            }

            last = id;
            key := Input_Key.{
                tick, id,
            };

            {
                old, exists := table_get(*w.queued, key);
                if
                exists {
                    if !wire.equal(old.data, bytes) {
                        release(bytes);
                        return .Invalid_Data;
                    }

                    release(bytes);
                    continue;
                }
            }

            owned := new_slice(u8, (bytes).count, w.allocator);
            copy_samples(owned, bytes);
            release(bytes);
            array_add(*keys, key);
            array_add(*values, World_Input.{
                owner, incarnation, owned
            });
        }
    };

    if !wire.finished(*r) || (w.queued).count + (keys).count > w.config.capacity * max(1, (w.systems).count) {
        return .Invalid_Data;
    }

    for key, i: keys {
        H.table_set(*w.queued, key, values[i]);
        values[i].data = .[];
    }

    return .Ok;
}

world_encode_snapshot :: (w: *Simulation_World, tick: Tick, correction_serial: u64 = 0, selection: World_Selection = null, user: *void = null) -> ([] u8, Status) {
    f := world_frame(w, tick);
    if f == null {
        return .[], .Expired;
    }

    if w.snapshot_sequence == MAX_TICK {
        return .[], .Exhausted;
    }

    writer: core.Writer;
    core.writer_init(*writer);
    defer core.writer_destroy(*writer);
    world_header(w, *writer, .Snapshot, world_layout_hash(w, selection, user));
    core.write_uint64(*writer, w.snapshot_sequence + 1, .Uncompressed);
    core.write_uint64(*writer, tick, .Uncompressed);
    core.write_uint64(*writer, correction_serial, .Uncompressed);
    core.write_uint8(*writer, (cast, trunc(u8)(correction_serial % 256)), .Uncompressed);
    count := 0;
    for s: w.systems {
        if selection == null || selection(s.config.id, user) {
            count += 1;
        }
    }

    wire.write_count(*writer, count, MAX_WORLD_SYSTEMS);
    for s, i: w.systems {
        if selection != null && !selection(s.config.id, user) {
            continue;
        }

        cfg := *s.config;
        core.write_uint32(*writer, (cast, trunc(u32)(cfg.id)), .Uncompressed);
        core.write_uint32(*writer, cfg.schema, .Uncompressed);
        core.write_uint64(*writer, cfg.incarnation, .Uncompressed);
        core.write_uint32(*writer, (cast, trunc(u32)(cfg.owner)), .Uncompressed);
        core.write_uint64(*writer, f.meta[i].controller_tick, .Uncompressed);
        core.write_uint64(*writer, f.meta[i].last_tick, .Uncompressed);
        core.write_uint8(*writer, (cast, trunc(u8)(((ifx f.meta[i].missing then 1 else 0)) | ((ifx f.meta[i].estimated then 2 else 0)))), .Uncompressed);
        wire.write_bytes(*writer, view(f.state, s.state_offset, s.state_offset + cfg.state_size), MAX_PAYLOAD);
        wire.write_bytes(*writer, view(f.input, s.input_offset, s.input_offset + cfg.input_size), MAX_PAYLOAD);
        wire.write_bytes(*writer, view(f.last, s.input_offset, s.input_offset + cfg.input_size), MAX_PAYLOAD);
    }

    if writer.err != .None || core.writer_bytes_written(*writer) > wire.MAX_PAYLOAD {
        return .[], .Too_Large;
    }

    w.snapshot_sequence += 1;
    return core.writer_to_array(*writer), .Ok;
}

world_receive_snapshot :: (w: *Simulation_World, data: [] u8, new_timeline := false) -> Status {
    if !w.initialized || w.config.authority || w.busy || (data).count > wire.MAX_PAYLOAD {
        return .Invalid_Data;
    }

    r: core.Reader;
    core.reader_init(*r, data);
    if !world_read_header(w, *r, .Snapshot, false) {
        return .Schema_Mismatch;
    }

    header_reader := r;
    header_reader.bit_position = 48;
    wire_layout := core.read_uint32(*header_reader, .Uncompressed);
    sequence := core.read_uint64(*r, .Uncompressed);
    tick := core.read_uint64(*r, .Uncompressed);
    correction := core.read_uint64(*r, .Uncompressed);
    short_seq := core.read_uint8(*r, .Uncompressed);
    count, ok := wire.read_count(*r, MAX_WORLD_SYSTEMS);
    if !ok || sequence == 0 || short_seq != (cast, trunc(u8)(correction % 256)) || tick == MAX_TICK {
        return .Invalid_Data;
    }

    if count != (w.systems).count {
        return .Schema_Mismatch;
    }

    incarnations := new_slice(u64, count, w.allocator);
    owners := new_slice(transport.Connection_Id, count, w.allocator);
    defer release(incarnations, w.allocator);
    defer release(owners, w.allocator);
    structure_changed := false;
    candidate := World_Frame.{
        tick = tick, valid = true, state = new_slice(u8, w.state_size, w.allocator), input = new_slice(u8, w.input_size, w.allocator), last = new_slice(u8, w.input_size, w.allocator), meta = new_slice(World_Meta, count, w.allocator),
    };

    defer world_frame_destroy(w, *candidate);
    for s, i: w.systems {
        id := (cast(System_Id) (core.read_uint32(*r, .Uncompressed)));
        schema := core.read_uint32(*r, .Uncompressed);
        incarnation := core.read_uint64(*r, .Uncompressed);
        owner := (cast(transport.Connection_Id) (core.read_uint32(*r, .Uncompressed)));
        controller_tick := core.read_uint64(*r, .Uncompressed);
        last_tick := core.read_uint64(*r, .Uncompressed);
        flags := core.read_uint8(*r, .Uncompressed);
        state, state_ok := wire.read_bytes(*r, MAX_PAYLOAD);
        input, input_ok := wire.read_bytes(*r, MAX_PAYLOAD);
        last, last_ok := wire.read_bytes(*r, MAX_PAYLOAD);
        valid := state_ok && input_ok && last_ok && id == s.config.id && schema == s.config.schema && incarnation != 0 && (new_timeline || incarnation >= s.config.incarnation) && (new_timeline || owner == s.config.owner || incarnation > s.config.incarnation || w.received_sequence == 0) && flags <= 3 && last_tick <= tick && controller_tick <= tick && (state).count == s.config.state_size && (input).count == s.config.input_size && (last).count == s.config.input_size;
        incarnations[i], owners[i] = incarnation, owner;
        structure_changed = structure_changed || incarnation != s.config.incarnation || owner != s.config.owner;
        if valid {
            valid = s.config.callbacks.validate_state(s.config.callbacks.user, state, tick) && (s.config.input_size == 0 || (s.config.callbacks.validate_input(s.config.callbacks.user, input, controller_tick) && s.config.callbacks.validate_input(s.config.callbacks.user, last, last_tick)));
        }

        if valid {
            copy_samples(view(candidate.state, s.state_offset, s.state_offset + s.config.state_size), state);
            copy_samples(view(candidate.input, s.input_offset, s.input_offset + s.config.input_size), input);
            copy_samples(view(candidate.last, s.input_offset, s.input_offset + s.config.input_size), last);
            candidate.meta[i] = .{
                controller_tick, last_tick, owner, flags & 1 != 0, flags & 2 != 0, (w.config.local_owner != 0 && owner == w.config.local_owner) || s.config.observer_prediction,
            };
        }

        release(state);
        release(input);
        release(last);
        if !valid {
            if id != s.config.id || schema != s.config.schema || incarnation < s.config.incarnation {
                return .Schema_Mismatch;
            };
            return .Invalid_Data;
        }
    }

    if !wire.finished(*r) {
        return .Invalid_Data;
    }

    if wire_layout != world_layout_hash(w, null, null, incarnations) {
        return .Schema_Mismatch;
    }

    if !new_timeline && sequence <= w.received_sequence {
        return .Duplicate;
    }

    if !new_timeline && (tick < w.applied_tick || (w.pending.valid && tick < w.pending.tick)) {
        return .Stale;
    }

    // A trusted binding change is committed only after complete validation.

    if new_timeline {
        w.received_sequence, w.applied_tick, w.correction_serial = 0, 0, 0;
    }

    if structure_changed || new_timeline {
        for s, i: w.systems {
            s.config.owner, s.config.incarnation = owners[i], incarnations[i];
        }

        w.layout = wire_layout;
        world_clear_inputs(w);
        for *frame: w.history {
            frame.*.valid = false;
        }

        w.needs_full = true;
    }

    w.received_sequence = sequence;
    world_frame_destroy(w, *w.pending);
    w.pending, candidate = candidate, .{
    };

    w.pending_sequence, w.pending_correction = sequence, correction;
    // 非预测对象先接收权威值；随后RPC/late-state写入在整世界hold结束时恢复。

    for s: w.systems {
        if !world_predicted(w, s) {
            s.config.callbacks.restore(s.config.callbacks.user, view(w.pending.state, s.state_offset, s.state_offset + s.config.state_size));
        }
    }

    return .Ok;
}

//@endregion
//@region Validate结果hash与纠正序号

world_encode_result :: (w: *Simulation_World, owner: transport.Connection_Id, tick: Tick) -> ([] u8, Status) {
    f := world_frame(w, tick);
    if f == null {
        return .[], .Expired;
    }

    writer: core.Writer;
    core.writer_init(*writer);
    defer core.writer_destroy(*writer);
    world_header(w, *writer, .Result);
    core.write_uint64(*writer, tick, .Uncompressed);
    core.write_uint64(*writer, w.correction_serial, .Uncompressed);
    core.write_uint8(*writer, (cast, trunc(u8)(w.correction_serial % 256)), .Uncompressed);
    count := 0;
    for s: w.systems {
        if s.config.owner == owner {
            count += 1;
        }
    }

    wire.write_count(*writer, count, MAX_WORLD_SYSTEMS);
    for s: w.systems {
        if s.config.owner != owner {
            continue;
        }

        hash, _ := world_system_hash(w, f, s.config.id);
        core.write_uint32(*writer, (cast, trunc(u32)(s.config.id)), .Uncompressed);
        core.write_uint64(*writer, s.config.incarnation, .Uncompressed);
        core.write_uint32(*writer, hash, .Uncompressed);
    }

    return core.writer_to_array(*writer), .Ok;
}

world_check_result :: (w: *Simulation_World, owner: transport.Connection_Id, data: [] u8, notify := true) -> (tick: Tick, correction_ack: u64, mismatch: bool, status: Status) {
    if !w.initialized || !w.config.authority || owner == 0 || (data).count > wire.MAX_PAYLOAD {
        return 0, 0, false, .Invalid_Data;
    }

    r: core.Reader;
    core.reader_init(*r, data);
    if !world_read_header(w, *r, .Result, false) {
        return 0, 0, false, .Schema_Mismatch;
    }

    tick = core.read_uint64(*r, .Uncompressed);
    correction_ack = core.read_uint64(*r, .Uncompressed);
    short_seq := core.read_uint8(*r, .Uncompressed);
    count, ok := wire.read_count(*r, MAX_WORLD_SYSTEMS);
    if !ok || short_seq != (cast, trunc(u8)(correction_ack % 256)) || tick == 0 || count == 0 {
        return tick, correction_ack, false, .Invalid_Data;
    }

    f := world_frame(w, tick);
    last := (cast(System_Id) (0));
    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;

            id := (cast(System_Id) (core.read_uint32(*r, .Uncompressed)));
            incarnation := core.read_uint64(*r, .Uncompressed);
            hash := core.read_uint32(*r, .Uncompressed);
            s, _ := world_find(w, id);
            if s == null || id <= last || s.config.owner != owner || s.config.incarnation != incarnation {
                return tick, correction_ack, false, .Invalid_Data;
            }

            last = id;
            if f != null {
                expected, _ := world_system_hash(w, f, id);
                mismatch = mismatch || hash != expected;
            }
        }
    }

    if !wire.finished(*r) {
        return tick, correction_ack, false, .Invalid_Data;
    }

    if tick > w.tick {
        if tick - w.tick > (cast, trunc(u64)(w.config.max_future_ticks)) {
            return tick, correction_ack, false, .Out_Of_Order;
        };
        return tick, correction_ack, false, .Not_Ready;
    }

    if f == null {
        return tick, correction_ack, false, .Expired;
    }

    if mismatch && notify {
        world_notify(w, .Result_Mismatch, 0, tick);
    }

    return tick, correction_ack, mismatch, .Ok;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
