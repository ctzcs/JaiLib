#scope_file
core :: #import "thirdparty/onet/core";
transport :: #import "thirdparty/onet/transport";
wire :: #import "thirdparty/onet/wire";
#scope_export
// 每连接确认快照。数据只依赖已确认的不可变字节基线；丢包不会推进它。
// 网络循环独占 Registry/Peer。peer_apply 仅可接收可信服务器的状态通道。
//@region 快照生命周期

PEER_MAGIC :: (cast, trunc(u32)(0x4E554332));
PEER_VERSION :: (cast, trunc(u8)(1));
MAX_COMPONENTS :: 64;
MAX_MEMBERS :: 256;

Object_Image :: struct {
    id: Network_Id;

    data: [] u8;
}

Snapshot :: struct {
    sequence: u64;

    tick: u64;

    images: [..] Object_Image;
}

Peer :: struct {
    connection: transport.Connection_Id;

    next_sequence: u64;

    acknowledged: u64;

    acknowledged_tick: u64;
    // tick of the acknowledged snapshot

    applied: u64;

    applied_tick: u64;

    history_limit: int;

    sent: [..] Snapshot;

    received: [..] Snapshot;

    force_full: bool;
}

Visibility :: (obj: *Network_Object, connection: transport.Connection_Id, userdata: *void) -> bool;

peer_init :: (peer: *Peer, connection: transport.Connection_Id, history_limit: int = 32) {
    peer.* = .{
    };

    peer.connection = connection;
    peer.next_sequence = 1;
    peer.history_limit = clamp(history_limit, 2, 256);
}

snapshot_destroy :: (snapshot: *Snapshot) {
    for image: snapshot.images {
        release(image.data);
    }

    release(snapshot.images);
    snapshot.* = .{
    };
}

peer_destroy :: (peer: *Peer) {
    for *snapshot: peer.sent {
        snapshot_destroy(snapshot);
    }

    for *snapshot: peer.received {
        snapshot_destroy(snapshot);
    }

    release(peer.sent);
    release(peer.received);
    peer.* = .{
    };
}

snapshot_find :: (history: [] Snapshot, sequence: u64) -> *Snapshot {
    for *snapshot: history {
        if snapshot.*.sequence == sequence {
            return snapshot;
        }
    }

    return null;
}

image_find :: (snapshot: *Snapshot, id: Network_Id) -> [] u8 {
    if snapshot == null {
        return .[];
    }

    for image: snapshot.images {
        if image.id == id {
            return image.data;
        }
    }

    return .[];
}

history_push :: (history: *[..] Snapshot, snapshot: Snapshot, limit: int) {
    if (history.*).count >= limit {
        snapshot_destroy(*history.*[0]);
        {
            i := 1;
            while i < (history.*).count {
                defer i += 1;

                history.*[i - 1] = history.*[i];
            }
        }

        array_resize(history, (history.*).count - 1);
    }

    array_add(history, snapshot);
}

peer_ack :: (peer: *Peer, sequence: u64) -> bool {
    if sequence == 0 || sequence >= peer.next_sequence {
        return false;
    }

    if sequence <= peer.acknowledged {
        return true;
    }

    snapshot := snapshot_find(view(peer.sent, 0), sequence);
    if snapshot == null {
        return false;
    }

    peer.acknowledged = sequence;
    peer.acknowledged_tick = snapshot.tick;
    return true;
}

peer_request_full :: (peer: *Peer) {
    peer.force_full = true;
}

//@endregion
//@region 完整对象与布局

image_encode :: (obj: *Network_Object) -> ([] u8, bool) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    core.write_uint32(*w, (cast, trunc(u32)(obj.owner)), .Uncompressed);
    core.write_uint32(*w, obj.scene, .Uncompressed);
    for v: obj.position {
        core.write_bits(*w, (cast, trunc(u64)(bit_cast(u32, v))), 32);
    }

    wire.write_count(*w, (obj.components).count, MAX_COMPONENTS);
    for comp: obj.components {
        core.write_uint32(*w, (cast, trunc(u32)(comp.type_id)), .Uncompressed);
        wire.write_count(*w, (comp.members).count, MAX_MEMBERS);
        for *m: comp.members {
            member_write_schema(*w, m);
            bytes, ok := member_bytes(m);
            if !ok {
                w.err = .Malformed;
            }

            wire.write_bytes(*w, bytes);
            release(bytes);
        }
    }

    if w.err != .None || core.writer_bytes_written(*w) > wire.MAX_PAYLOAD {
        return .[], false;
    }

    return core.writer_to_array(*w), true;
}

image_read :: (reg: *Registry, obj: *Network_Object, data: [] u8, create: bool) -> bool {
    r: core.Reader;
    core.reader_init(*r, data);
    obj.owner = (cast(transport.Connection_Id) (core.read_uint32(*r, .Uncompressed)));
    obj.scene = core.read_uint32(*r, .Uncompressed);
    {
        i := 0;
        while i < 3 {
            defer i += 1;

            obj.position[i] = bit_cast(float32, (cast, trunc(u32)(core.read_bits(*r, 32))));
        }
    }

    count, ok := wire.read_count(*r, MAX_COMPONENTS);
    if !ok || (!create && (obj.components).count != count) {
        return false;
    }

    {
        c := 0;
        while c < count {
            defer c += 1;

            type_id := (cast(Component_Type_Id) (core.read_uint32(*r, .Uncompressed)));
            members, count_ok := wire.read_count(*r, MAX_MEMBERS);
            if !count_ok {
                return false;
            }

            comp: *Component;
            if create {
                factory := table_get(*reg.factories, type_id);
                if factory == null {
                    return false;
                }

                comp = factory();
                if comp == null {
                    return false;
                }

                array_add(*obj.components, comp);
            } else {
                comp = obj.components[c];
            }

            if comp.type_id != type_id || (comp.members).count != members {
                return false;
            }

            {
                m := 0;
                while m < members {
                    defer m += 1;

                    if !member_check_schema(*r, *comp.members[m]) {
                        return false;
                    }

                    value, value_ok := wire.read_bytes(*r);
                    if !value_ok {
                        return false;
                    }

                    value_reader: core.Reader;
                    core.reader_init(*value_reader, value);
                    valid := member_read_full(*value_reader, *comp.members[m]) && wire.finished(*value_reader);
                    release(value);
                    if !valid {
                        return false;
                    }
                }
            }
        }
    }

    return wire.finished(*r);
}

layouts_equal :: (a, b: *Network_Object) -> bool {
    if (a.components).count != (b.components).count {
        return false;
    }

    for ac, c: a.components {
        bc := b.components[c];
        if ac.type_id != bc.type_id || (ac.members).count != (bc.members).count {
            return false;
        }

        for am, i: ac.members {
            bm := bc.members[i];
            if am.kind != bm.kind || am.codec.schema != bm.codec.schema || am.accuracy != bm.accuracy {
                return false;
            }
        }
    }

    return true;
}

snapshot_apply :: (reg: *Registry, snapshot: *Snapshot) -> bool {
    // 用同一工厂和codec预解码整包；自定义codec不得有外部副作用。

    probes: [..] *Network_Object;
    defer {
        for probe: probes {
            if probe != null {
                free_object(probe);
            }
        }

        release(probes);
    }

    for image: snapshot.images {
        probe := new_one(Network_Object);
        probe.id = image.id;
        probe.active = true;
        array_add(*probes, probe);
        if !image_read(reg, probe, image.data, true) {
            return false;
        }

        old, exists := get(reg, image.id);
        if exists && !layouts_equal(old, probe) {
            return false;
        }

        // Probes have no externally visible event callbacks. Set the local
        // clock before commit so newly admitted owners have the runtime hooks.

        collection_sync_object(reg, probe, true);
    }

    // 全部校验成功后再改变现有世界。已有组件的游戏指针保持稳定。

    for image, i: snapshot.images {
        old, exists := get(reg, image.id);
        if exists {
            if !image_read(reg, old, image.data, false) {
                return false; // 仅非确定性用户codec才可能在预验证后失败。
            }

            collection_sync_object(reg, old, false);
        } else {
            {
                tombstone := table_get(*reg.objects, image.id);
                if
                tombstone != null {
                    free_object(tombstone);
                }
            }

            H.table_set(*reg.objects, image.id, probes[i]);
            probes[i] = null;
        }

        if (cast, trunc(u32)(image.id)) >= reg.next_id {
            reg.next_id = (cast, trunc(u32)(image.id)) + 1;
        }
    }

    // 快照中缺席即已删除：释放并移除条目，map 规模跟随存活对象。

    removed: [..] Network_Id;
    defer release(removed);
    for obj, id: reg.objects {
        if image_find(snapshot, id).data == null {
            array_add(*removed, id);
            if obj != null {
                free_object(obj);
            }
        }
    }

    for id: removed {
        H.table_remove(*reg.objects, id);
    }

    reg.active_count = (snapshot.images).count;
    array_reset_keeping_memory(*reg.pending_despawns);
    return true;
}

//@endregion
//@region 每连接协议

peer_build :: (reg: *Registry, peer: *Peer, w: *core.Writer, tick: u64, visible: Visibility = null, userdata: *void = null) -> bool {
    if !reg.authoritative || peer.next_sequence == 0 || peer.history_limit < 2 || core.writer_bits_written(w) != 0 {
        return false;
    }

    current: Snapshot;
    current.sequence = peer.next_sequence;
    current.tick = tick;
    for obj, _: reg.objects {
        if obj == null || !obj.active || (visible != null && !visible(obj, peer.connection, userdata)) {
            continue;
        }

        data, ok := image_encode(obj);
        if !ok || (current.images).count >= wire.MAX_ITEMS {
            release(data);
            snapshot_destroy(*current);
            return false;
        }

        array_add(*current.images, Object_Image.{
            obj.id, data
        });
    };

    // map迭代无序；固定ID顺序使基线与测试可重现。

    {
        i := 1;
        while i < (current.images).count {
            defer i += 1;

            j := i;
            while j > 0 && current.images[j].id < current.images[j - 1].id {
                tmp := current.images[j - 1];
                current.images[j - 1] = current.images[j];
                current.images[j] = tmp;
                j -= 1;
            }
        }
    }

    base: *Snapshot;
    if !peer.force_full {
        base = snapshot_find(view(peer.sent, 0), peer.acknowledged);
    }

    core.write_uint32(w, PEER_MAGIC, .Uncompressed);
    core.write_uint8(w, PEER_VERSION, .Uncompressed);
    core.write_uint64(w, current.sequence, .Uncompressed);
    core.write_uint64(w, tick, .Uncompressed);
    core.write_uint64(w, (ifx base == null then 0 else base.sequence), .Uncompressed);
    wire.write_count(w, (current.images).count);
    for image: current.images {
        core.write_uint32(w, (cast, trunc(u32)(image.id)), .Uncompressed);
        previous := image_find(base, image.id);
        if previous.data != null && wire.equal(previous, image.data) {
            core.write_uint8(w, 0, .Uncompressed);
        } else if previous.data != null {
            core.write_uint8(w, 2, .Uncompressed);
            wire.write_delta(w, previous, image.data);
        } else {
            core.write_uint8(w, 1, .Uncompressed);
            wire.write_bytes(w, image.data);
        }
    }

    if w.err != .None || core.writer_bytes_written(w) > wire.MAX_PAYLOAD {
        snapshot_destroy(*current);
        return false;
    }

    peer.next_sequence += 1;
    peer.force_full = false;
    history_push(*peer.sent, current, peer.history_limit);
    return true;
}

// 返回需回传的sequence；缺基线时needs_full=true且世界保持原状。

peer_apply :: (reg: *Registry, peer: *Peer, r: *core.Reader) -> (sequence: u64, ok: bool, needs_full: bool) {
    if reg.authoritative || (r.data).count > wire.MAX_PAYLOAD {
        return 0, false, false;
    }

    magic := core.read_uint32(r, .Uncompressed);
    version := core.read_uint8(r, .Uncompressed);
    sequence = core.read_uint64(r, .Uncompressed);
    tick := core.read_uint64(r, .Uncompressed);
    base_sequence := core.read_uint64(r, .Uncompressed);
    if r.err != .None || magic != PEER_MAGIC || version != PEER_VERSION || sequence == 0 || base_sequence >= sequence {
        return 0, false, false;
    }

    if sequence <= peer.applied {
        return peer.applied, true, false;
    }

    if peer.applied != 0 && tick < peer.applied_tick {
        return 0, false, false;
    }

    base: *Snapshot;
    if base_sequence != 0 {
        base = snapshot_find(view(peer.received, 0), base_sequence);
        if base == null {
            return 0, false, true;
        }
    }

    count, count_ok := wire.read_count(r);
    if !count_ok {
        return 0, false, false;
    }

    candidate := Snapshot.{
        sequence = sequence, tick = tick,
    };

    accepted := false;
    defer {
        if !accepted {
            snapshot_destroy(*candidate);
        }
    }

    last_id := (cast(Network_Id) (0));
    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;

            id := (cast(Network_Id) (core.read_uint32(r, .Uncompressed)));
            mode := core.read_uint8(r, .Uncompressed);
            if r.err != .None || id == 0 || id <= last_id || id == (cast(Network_Id) (0xFFFFFFFF)) {
                return 0, false, false;
            }

            last_id = id;
            previous := image_find(base, id);
            data: [] u8;
            valid := true;
            if mode == {
                case 0;
                    if previous.data == null {
                        return 0, false, true;
                    }

                    data = wire.clone(previous);
                case 1;
                    data, valid = wire.read_bytes(r);
                case 2;
                    if previous.data == null {
                        return 0, false, true;
                    }

                    data, valid = wire.read_delta(r, previous);
                case;
                    return 0, false, false;
            }

            if !valid {
                release(data);
                return 0, false, false;
            }

            array_add(*candidate.images, Object_Image.{
                id, data
            });
        }
    };

    if !wire.finished(r) || !snapshot_apply(reg, *candidate) {
        return 0, false, false;
    }

    peer.applied = sequence;
    peer.applied_tick = tick;
    history_push(*peer.received, candidate, peer.history_limit);
    accepted = true;
    return sequence, true, false;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
