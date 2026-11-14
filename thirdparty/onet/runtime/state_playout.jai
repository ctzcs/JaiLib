#scope_file
core :: #import "thirdparty/onet/core";
objects :: #import "thirdparty/onet/objects";
session :: #import "thirdparty/onet/session";
sim :: #import "thirdparty/onet/simulation";
transport :: #import "thirdparty/onet/transport";
wire :: #import "thirdparty/onet/wire";
rpc :: #import "thirdparty/onet/rpc";
#scope_export

//@region 状态播放水位与已应用ACK

Queued_State :: struct {
    from: transport.Connection_Id;
    generation, sequence, tick: u64;
    data: [] u8;
}

clear_state_queue :: (w: *World) {
    for packet: w.state_pending {
        release(packet.data);
    }

    release(w.state_pending);
    w.state_pending = .{};
}

enqueue_state :: (w: *World, from: transport.Connection_Id, data: [] u8) -> bool {
    if (data).count > wire.MAX_PAYLOAD || (data).count < 29 {
        return false;
    }

    r: core.Reader;
    core.reader_init(*r, data);
    magic := core.read_uint32(*r, .Uncompressed);
    version := core.read_uint8(*r, .Uncompressed);
    sequence := core.read_uint64(*r, .Uncompressed);
    tick := core.read_uint64(*r, .Uncompressed);
    base := core.read_uint64(*r, .Uncompressed);
    if r.err != .None || magic != objects.PEER_MAGIC || version != objects.PEER_VERSION || sequence == 0 || base >= sequence {
        return false;
    }

    if sequence <= w.client_peer.applied {
        return true;
    }

    for packet: w.state_pending {
        if packet.sequence == sequence {
            return true;
        }
    }

    now := (cast(float64) (w.runtime.session.clock_ms));
    if !w.state_clock.sampled {
        sim.clock_observe(*w.state_clock, now, now, now, tick);
    }

    bytes := (data).count;
    for packet: w.state_pending {
        bytes += (packet.data).count;
    }

    while (w.state_pending).count > 0 && ((w.state_pending).count >= 64 || bytes > wire.MAX_PAYLOAD) {
        bytes -= (w.state_pending[0].data).count;
        release(w.state_pending[0].data);
        {
            i := 1;
            while i < (w.state_pending).count {
                defer i += 1;
                w.state_pending[i - 1] = w.state_pending[i];
            }
        }

        array_resize(*w.state_pending, (w.state_pending).count - 1);
    }

    array_add(*w.state_pending, Queued_State.{
        from, w.generation, sequence, tick, wire.clone(data)
    });
    {
        i := (w.state_pending).count - 1;
        while i > 0 && w.state_pending[i].sequence < w.state_pending[i - 1].sequence {
            defer i -= 1;
            w.state_pending[i], w.state_pending[i - 1] = w.state_pending[i - 1], w.state_pending[i];
        }
    };

    return true;
}

drain_state :: (w: *World) {
    if w.authority || w.generation == 0 || (w.state_pending).count == 0 {
        return;
    }

    release_tick, status := sim.clock_release_tick(*w.state_clock, (cast(float64) (w.runtime.session.clock_ms)));
    if status != .Ok {
        return;
    }

    applied := (cast, trunc(u64)(0));
    kept := 0;
    for packet: w.state_pending {
        if packet.generation != w.generation || packet.sequence <= w.client_peer.applied {
            release(packet.data);
            continue;
        }

        if packet.tick > release_tick {
            w.state_pending[kept] = packet;
            kept += 1;
            continue;
        }

        saved := world_save_prediction(w);
        r: core.Reader;
        core.reader_init(*r, packet.data);
        sequence, ok, full := objects.peer_apply(w.registry, *w.client_peer, *r);
        if ok {
            sync_simulation_objects(w);
            w.rpc.has_state, w.rpc.state_tick = true, w.client_peer.applied_tick;
            applied = max(applied, sequence);
        }

        world_restore_prediction(w, saved);
        if full && w.runtime.session.clock_ms - w.state_full_last_ms >= 100 {
            w.state_full_last_ms = w.runtime.session.clock_ms;
            send(w, packet.from, .Full, .[]);
        } else if !ok && !full {
            session.report_violation(w.runtime.session, packet.from, .Malformed);
        }

        release(packet.data);
    }

    array_resize(*w.state_pending, kept);
    if applied > 0 {
        send_number(w, session.local_connection(w.runtime.session), .Ack, applied);
    }
}

before_tick :: (s: *session.Session) {
    r := (cast(*Runtime) s.runtime_userdata);
    synchronize(r);
    if r.client.initialized {
        drain_state(*r.client);
    }

    for w: ((*World).[*r.server, *r.client]) {
        if !w.initialized {
            continue;
        }

        rpc.update(*w.rpc, 0);
        objects.begin_tick(w.registry, s.tick);
        world_before_tick(w);
    }
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
