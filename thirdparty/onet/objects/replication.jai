#scope_file
core :: #import "thirdparty/onet/core";
transport :: #import "thirdparty/onet/transport";
wire :: #import "thirdparty/onet/wire";
#scope_export
// onet objects: state replication packets.
//
// Wire format (bit codec, everything sequential):
//
//   [despawn_count u32][id u32]...
//   [object_count u32]
//   per object:
//     [id u32][owner u32][component_count u8]
//     per component:
//       [type_id u32][member_count u8]
//       per member:
//         F32:  [changed bit]; if changed: delta vs last-sent (accuracy-aware)
//         I32:  [changed bit]; if changed: full int32
//         Bool: [changed bit]; if changed: value bit
//         Vec3: [x changed][x delta][y changed][y delta][z changed][z delta]
//         Quat: [changed bit]; if changed: smallest-three quaternion (full)
//
// Objects a client does not know yet are created on the fly from the
// registered component factories (order-based member matching, validated by
// component type id and member count). Server and clients keep last-sent /
// last-applied in lockstep because replication rides the reliable ordered
// channel, which is what makes the receiver-side delta base valid.
// Builds one state packet from every active object that has dirty members
// (call poll_dirty first; build re-checks with the accuracy predicate).
// Returns whether anything was written. On success dirty flags and
// last-sent values are advanced.

build_state_packet :: (reg: *Registry, w: *core.Writer) -> bool {
    // Despawns first.

    had_despawns := (reg.pending_despawns).count > 0;
    core.write_uint32(w, (cast, trunc(u32)(reg.pending_despawns).count), .Loose);
    for id: reg.pending_despawns {
        core.write_uint32(w, (cast, trunc(u32) id), .Loose);
    }

    array_reset_keeping_memory(*reg.pending_despawns);

    // Count objects that carry changes.

    changed_objects: [..] *Network_Object;
    defer release(changed_objects);
    for obj, _: reg.objects {
        if obj != null && obj.active && has_wire_changes(obj) {
            array_add(*changed_objects, obj);
        }
    }

    core.write_uint32(w, (cast, trunc(u32)(changed_objects).count), .Loose);
    if (changed_objects).count == 0 {
        return had_despawns;
    }

    for obj: changed_objects {
        core.write_uint32(w, (cast, trunc(u32) obj.id), .Loose);
        core.write_uint32(w, (cast, trunc(u32) obj.owner), .Loose);
        core.write_uint8(w, (cast, trunc(u8)(obj.components).count), .Uncompressed);

        for comp: obj.components {
            core.write_uint32(w, (cast, trunc(u32) comp.type_id), .Loose);
            core.write_uint8(w, (cast, trunc(u8)(comp.members).count), .Uncompressed);

            {
                i := 0;
                while i < (comp.members).count {
                    defer i += 1;

                    m := *comp.members[i];
                    write_member_delta(w, m);
                }
            }
        }
    }

    return true;
}

// The accuracy-aware predicate that decides whether a member carries bits:
// identical to write_delta_single's internal decision so the changed bit on
// the wire always matches the value that follows it.

has_wire_changes :: (obj: *Network_Object) -> bool {
    for comp: obj.components {
        {
            i := 0;
            while i < (comp.members).count {
                defer i += 1;

                if member_will_write(*comp.members[i]) {
                    return true;
                }
            }
        }
    }

    return false;
}

member_will_write :: (m: *Member) -> bool {
    // The first send always carries the value, even when it equals the
    // zero-initialized delta base (a zero object must still replicate).

    if !m.ever_sent {
        return true;
    }

    if m.kind == {
        case .F32;
            cur := member_value_f32(m);
            return is_finite_single(cur) && Math.abs(cur - m.last_f32) > m.accuracy;
        case .I32;
            return ((cast(*s32) m.ptr)).* != m.last_i32;
        case .Bool;
            return ((cast(*bool) m.ptr)).* != m.last_bool;
        case .Vec3;
            cur := ((cast(*[3] float32) m.ptr)).*;
            {
                i := 0;
                while i < 3 {
                    defer i += 1;

                    if is_finite_single(cur[i]) && Math.abs(cur[i] - m.last_vec3[i]) > m.accuracy {
                        return true;
                    }
                }
            }

            return false;
        case .Quat;
            cur := ((cast(*[4] float32) m.ptr)).*;
            {
                i := 0;
                while i < 4 {
                    defer i += 1;

                    if is_finite_single(cur[i]) && Math.abs(cur[i] - m.last_quat[i]) > m.accuracy {
                        return true;
                    }
                }
            }

            return false;
        case;
            encoded, ok := member_bytes(m);
            defer release(encoded);
            return !ok || !bytes_equal(encoded, m.last_encoded);
    }

    return false;
}

is_finite_single :: (v: float32) -> bool {
    return !Math.isnan(v) && !Math.isinf(v);
}

write_member_delta :: (w: *core.Writer, m: *Member) {
    was_sent := m.ever_sent;
    if m.kind == {
        case .F32;
            cur := member_value_f32(m);
            changed := !m.ever_sent || (is_finite_single(cur) && Math.abs(cur - m.last_f32) > m.accuracy);
            core.write_boolean(w, changed);
            if changed {
                if m.ever_sent {
                    core.write_delta_single(w, m.last_f32, cur, m.accuracy);
                } else {
                    // First send: a delta from an equal base writes nothing, so
                    // the full quantized value goes on the wire instead.

                    core.write_single(w, cur, .Loose, m.accuracy);
                }

                m.last_f32 = cur;
                m.ever_sent = true;
            }

        case .I32;
            cur := ((cast(*s32) m.ptr)).*;
            core.write_boolean(w, !m.ever_sent || cur != m.last_i32);
            if !m.ever_sent || cur != m.last_i32 {
                core.write_int32(w, cur, .Loose);
                m.last_i32 = cur;
                m.ever_sent = true;
            }

        case .Bool;
            cur := ((cast(*bool) m.ptr)).*;
            core.write_boolean(w, !m.ever_sent || cur != m.last_bool);
            if !m.ever_sent || cur != m.last_bool {
                core.write_boolean(w, cur);
                m.last_bool = cur;
                m.ever_sent = true;
            }

        case .Vec3;
            cur := ((cast(*[3] float32) m.ptr)).*;
            {
                i := 0;
                while i < 3 {
                    defer i += 1;

                    changed := !was_sent || (is_finite_single(cur[i]) && Math.abs(cur[i] - m.last_vec3[i]) > m.accuracy);
                    core.write_boolean(w, changed);
                    if changed {
                        if was_sent {
                            core.write_delta_single(w, m.last_vec3[i], cur[i], m.accuracy);
                        } else {
                            core.write_single(w, cur[i], .Loose, m.accuracy);
                        }

                        m.last_vec3[i] = cur[i];
                        m.ever_sent = true;
                    }
                }
            }

        case .Quat;
            cur := ((cast(*[4] float32) m.ptr)).*;
            changed := !m.ever_sent;
            {
                i := 0;
                while i < 4 {
                    defer i += 1;

                    if is_finite_single(cur[i]) && Math.abs(cur[i] - m.last_quat[i]) > m.accuracy {
                        changed = true;
                    }
                }
            }

            core.write_boolean(w, changed);
            if changed {
                core.write_quaternion(w, cur[0], cur[1], cur[2], cur[3], .Loose, m.accuracy);
                m.last_quat = cur;
                m.ever_sent = true;
            }

        case;
            encoded, ok := member_bytes(m);
            defer release(encoded);
            if !ok {
                w.err = .Malformed;
                return;
            }

            changed := !m.ever_sent || !bytes_equal(encoded, m.last_encoded);
            core.write_boolean(w, changed);
            if changed {
                wire.write_bytes(w, encoded);
                release(m.last_encoded);
                m.last_encoded = wire.clone(encoded);
                m.ever_sent = true;
            }
    }

    m.dirty = false;
}

// ---------------------------------------------------------------------------
// Apply (client side)
// ---------------------------------------------------------------------------
// Applies a state packet: processes despawns, spawns unknown objects from
// the registered factories, and folds member deltas into the mirrors.
// Returns (objects_touched, ok). On a stream error the reader latches and
// ok is false.

apply_state_packet :: (reg: *Registry, r: *core.Reader) -> (touched: int, ok: bool) {
    despawn_count := core.read_uint32(r, .Loose);
    if r.err != .None {
        return 0, false;
    }

    {
        loop_index := 0;
        while loop_index < despawn_count {
            defer loop_index += 1;

            id := (cast(Network_Id) (core.read_uint32(r, .Loose)));
            if r.err != .None {
                return touched, false;
            }

            obj, known := table_get(*reg.objects, id);
            if known && obj != null {
                free_object(obj);
                H.table_remove(*reg.objects, id); // ids are never reused: next_id stays monotonic

                reg.active_count -= 1;
            }
        }
    }

    object_count := core.read_uint32(r, .Loose);
    if r.err != .None {
        return touched, false;
    }

    {
        loop_index := 0;
        while loop_index < object_count {
            defer loop_index += 1;

            id := (cast(Network_Id) (core.read_uint32(r, .Loose)));
            owner := (cast(transport.Connection_Id) (core.read_uint32(r, .Loose)));
            comp_count := core.read_uint8(r, .Uncompressed);
            if r.err != .None {
                return touched, false;
            }

            obj, known := get(reg, id);
            if !known {
                obj = spawn_mirror(reg, id, owner, comp_count, r);
                if obj == null {
                    return touched, false;
                }

                // Freshly created: component headers were already consumed by
                // spawn_mirror; fall through to member values below.

                apply_member_values(obj, r);
                if r.err != .None {
                    return touched, false;
                }

                touched += 1;
                continue;
            }

            // Known object: component headers again, then values.
            {
                c := 0;
                while c < comp_count {
                    defer c += 1;

                    type_id := (cast(Component_Type_Id) (core.read_uint32(r, .Loose)));
                    member_count := core.read_uint8(r, .Uncompressed);
                    if r.err != .None {
                        return touched, false;
                    }

                    if (cast(int) (c)) >= (obj.components).count || obj.components[c].type_id != type_id || (obj.components[c].members).count != (cast(int) (member_count)) {
                        return touched, false; // factory mismatch: refuse the packet
                    }

                    apply_members(obj.components[c], member_count, r);
                    if r.err != .None {
                        return touched, false;
                    }
                }
            }

            obj.owner = owner;
            touched += 1;
        }
    }

    return touched, true;
}

// Creates the client-side mirror of an object seen for the first time,
// consuming its component headers from the stream. Returns nil on any
// mismatch (factory missing, header mismatch, stream error).

spawn_mirror :: (
reg: *Registry,
id: Network_Id,
owner: transport.Connection_Id,
comp_count: u8,
r: *core.Reader,
) -> *Network_Object {
    obj := new_one(Network_Object);
    obj.id = id;
    obj.owner = owner;
    obj.active = true;
    obj.components = new_dynamic(*Component, 0, comp_count);

    H.table_set(*reg.objects, id, obj);
    reg.active_count += 1;
    if reg.next_id <= (cast, trunc(u32) id) {
        reg.next_id = (cast, trunc(u32) id) + 1;
    }

    {
        loop_index := 0;
        while loop_index < comp_count {
            defer loop_index += 1;

            type_id := (cast(Component_Type_Id) (core.read_uint32(r, .Loose)));
            member_count := core.read_uint8(r, .Uncompressed);
            if r.err != .None {
                return null;
            }

            factory, ok := table_get(*reg.factories, type_id);
            if !ok {
                return null; // unknown component type on this client
            }

            comp := factory();
            comp.type_id = type_id;
            if (comp.members).count != (cast(int) (member_count)) {
                component_destroy(comp);
                return null; // factory out of date vs server
            }

            array_add(*obj.components, comp);
        }
    }

    return obj;
}

apply_member_values :: (obj: *Network_Object, r: *core.Reader) {
    for comp: obj.components {
        apply_members(comp, (cast, trunc(u8)(comp.members).count), r);
        if r.err != .None {
            return;
        }
    }
}

apply_members :: (comp: *Component, member_count: u8, r: *core.Reader) {
    {
        i := 0;
        while i < (cast(int) (member_count)) {
            defer i += 1;

            m := *comp.members[i];
            read_member_delta(r, m);
        }
    }
}

read_member_delta :: (r: *core.Reader, m: *Member) {
    if m.kind == {
        case .F32;
            changed := core.read_boolean(r);
            if changed {
                v: float32;
                if m.ever_sent {
                    v = core.read_delta_single(r, m.last_f32, m.accuracy);
                } else {
                    v = core.read_single(r, .Loose, m.accuracy);
                }

                ((cast(*float32) m.ptr)).* = v;
                m.last_f32 = v;
            }

        case .I32;
            changed := core.read_boolean(r);
            if changed {
                v := core.read_int32(r, .Loose);
                ((cast(*s32) m.ptr)).* = v;
                m.last_i32 = v;
            }

        case .Bool;
            changed := core.read_boolean(r);
            if changed {
                v := core.read_boolean(r);
                ((cast(*bool) m.ptr)).* = v;
                m.last_bool = v;
            }

        case .Vec3;
            cur := ((cast(*[3] float32) m.ptr)).*;
            {
                i := 0;
                while i < 3 {
                    defer i += 1;

                    changed := core.read_boolean(r);
                    if changed {
                        if m.ever_sent {
                            cur[i] = core.read_delta_single(r, m.last_vec3[i], m.accuracy);
                        } else {
                            cur[i] = core.read_single(r, .Loose, m.accuracy);
                        }

                        m.last_vec3[i] = cur[i];
                    }
                }
            }

            ((cast(*[3] float32) m.ptr)).* = cur;
        case .Quat;
            changed := core.read_boolean(r);
            if changed {
                x, y, z, qw := core.read_quaternion(r, .Loose, m.accuracy);
                ((cast(*[4] float32) m.ptr)).* = .[x, y, z, qw];

                m.last_quat = .[x, y, z, qw];
            }

        case;
            if core.read_boolean(r) {
                encoded, ok := wire.read_bytes(r);
                defer release(encoded);
                if !ok {
                    return;
                }

                value_reader: core.Reader;
                core.reader_init(*value_reader, encoded);
                if !member_read_full(*value_reader, m) || !wire.finished(*value_reader) {
                    wire.fail(r);
                }
            }
    }

    if r.err == .None {
        m.ever_sent = true;
    }
}

// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
