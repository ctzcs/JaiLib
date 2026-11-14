#scope_file

#scope_export

//@region 后端无关弱网模拟
// 字段与原生 UDP 的 Network_Conditions 一致：千分比概率，毫秒延迟（各自限制在 0..60000）。

Network_Conditions :: struct {
    seed: u64;
    loss_permille, duplicate_permille, reorder_permille: u32;
    latency_ms, jitter_ms, reorder_ms: int;
}

Conditioner_Stats :: struct {
    sent, delayed, dropped, duplicated, reordered: u64;
}

Conditioned_Send :: struct {
    connection: Connection_Id;
    channel: Channel;
    payload: [] u8;
    due: s64;
}

// 包装任意 Driver，只作用于本端发出的应用数据：send 时决定丢弃/复制/延迟并复制入队，
// poll/send 时释放到期项。可靠帧只延迟、不丢不复制，并保持每连接顺序；丢包、复制、
// 重排只作用于非可靠帧。决策流由 seed 决定，同样的发送序列在任何后端上结果相同。
// 传输层自身的握手/确认/重传不经过这里，可靠语义仍由后端保证。

Conditioner :: struct {
    inner: Driver;
    conditions: Network_Conditions;
    prng: u64;
    origin: float64;
    queue: [..] Conditioned_Send;
    reliable_due: H.Table(Connection_Id, s64);
    stats: Conditioner_Stats;
}

conditioner_init :: (c: *Conditioner, inner: Driver, conditions: Network_Conditions) {
    c.* = .{
        inner = inner, origin = monotonic_seconds(),
    };

    c.reliable_due = new_table(Connection_Id, s64);
    conditioner_set(c, conditions);
}

conditioner_destroy :: (c: *Conditioner) {
    conditioner_drop(c);
    release(c.queue);
    release(c.reliable_due);
    c.* = .{
    };
}

// 只重置决策流，不影响已排队的数据。

conditioner_set :: (c: *Conditioner, conditions: Network_Conditions) {
    n := conditions;
    n.loss_permille = min(n.loss_permille, 1000);
    n.duplicate_permille = min(n.duplicate_permille, 1000);
    n.reorder_permille = min(n.reorder_permille, 1000);
    n.latency_ms = clamp(n.latency_ms, 0, 60000);
    n.jitter_ms = clamp(n.jitter_ms, 0, 60000);
    n.reorder_ms = clamp(n.reorder_ms, 0, 60000);
    c.conditions = n;
    c.prng = max(n.seed, 1);
}

conditioner_driver :: (c: *Conditioner) -> Driver {
    return .{
        c, *conditioner_vtable,
    };
}

conditioner_now :: (c: *Conditioner) -> s64 {
    return (cast, trunc(s64)(((monotonic_seconds() - c.origin) * 1000)));
}

conditioner_random :: (c: *Conditioner) -> u64 {
    x := c.prng;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    c.prng = x;
    return x;
}

conditioner_roll :: (c: *Conditioner, permille: u32) -> bool {
    return conditioner_random(c) % 1000 < (cast, trunc(u64)(permille));
}

conditioner_send :: (c: *Conditioner, id: Connection_Id, channel: Channel, payload: [] u8) -> bool {
    n := c.conditions;
    now := conditioner_now(c);
    reliable := channel == .Reliable;
    if !reliable && conditioner_roll(c, n.loss_permille) {
        c.stats.dropped += 1;
        return true;
    }

    copies := 1;
    if !reliable && conditioner_roll(c, n.duplicate_permille) {
        copies = 2;
        c.stats.duplicated += 1;
    }

    {
        loop_index := 0;
        while loop_index < copies {
            defer loop_index += 1;

            delay := n.latency_ms;
            if n.jitter_ms > 0 {
                delay += (cast(int) (conditioner_random(c) % (cast, trunc(u64)(n.jitter_ms + 1))));
            }

            if !reliable && conditioner_roll(c, n.reorder_permille) {
                delay += n.reorder_ms;
                c.stats.reordered += 1;
            }

            due := now + (cast, trunc(s64)(delay));
            if reliable {
                due = max(due, table_get(*c.reliable_due, id));
                H.table_set(*c.reliable_due, id, due);
            }

            owned := new_slice(u8, (payload).count);
            copy_samples(owned, payload);
            array_add(*c.queue, Conditioned_Send.{
                id, channel, owned, due
            });
            if delay > 0 {
                c.stats.delayed += 1;
            }
        }
    };

    conditioner_release(c, false);
    return true;
}

// 按入队顺序释放到期项；force 释放全部（flush 语义与原生 UDP 一致）。
// 后端暂时拒收的可靠帧（例如发送窗口已满）留在队列重试，并挡住同连接后续可靠帧以保序。

conditioner_release :: (c: *Conditioner, force: bool) {
    now := conditioner_now(c);
    blocked: [..] Connection_Id;
    defer release(blocked);
    kept := 0;
    for item: c.queue {
        if item.channel == .Reliable {
            for id: blocked {
                if id == item.connection {
                    c.queue[kept] = item;
                    kept += 1;
                    continue item;
                }
            }
        }

        if !force && item.due > now {
            c.queue[kept] = item;
            kept += 1;
            continue;
        }

        if send(c.inner, item.connection, item.channel, item.payload) {
            c.stats.sent += 1;
        } else if item.channel == .Reliable && reliable_retry_allowed(c, item, now) {
            array_add(*blocked, item.connection);
            c.queue[kept] = item;
            kept += 1;
            continue;
        }

        release(item.payload);
    }

    array_resize(*c.queue, kept);
}

// 连接已断开（或10秒仍发不出去）时可靠帧无处可去，丢弃以免永久占用队列。

reliable_retry_allowed :: (c: *Conditioner, item: Conditioned_Send, now: s64) -> bool {
    if item.connection == local_connection(c.inner) && !client_is_connected(c.inner) {
        return false;
    }

    return now - item.due < 10000;
}

conditioner_drop :: (c: *Conditioner) {
    for item: c.queue {
        release(item.payload);
    }

    array_reset_keeping_memory(*c.queue);
    array_reset_keeping_memory(*c.reliable_due);
}

conditioner_vtable := Driver_Vtable.{
    start_server = (p: *void, port: u16, limit: u64) -> bool {
        return start_server(((cast(*Conditioner) p)).inner, port, limit);
    },
    start_client = (p: *void, host: string, port: u16) -> bool {
        return start_client(((cast(*Conditioner) p)).inner, host, port);
    },
    loopback_address = (p: *void) -> string {
        return loopback_address(((cast(*Conditioner) p)).inner);
    },
    bound_port = (p: *void) -> u16 {
        return bound_port(((cast(*Conditioner) p)).inner);
    },
    local_connection = (p: *void) -> Connection_Id {
        return local_connection(((cast(*Conditioner) p)).inner);
    },
    client_is_connected = (p: *void) -> bool {
        return client_is_connected(((cast(*Conditioner) p)).inner);
    },
    poll = (p: *void) {
        c := (cast(*Conditioner) p);
        conditioner_release(c, false);
        poll(c.inner);
    },
    send = (p: *void, id: Connection_Id, channel: Channel, payload: [] u8) -> bool {
        return conditioner_send((cast(*Conditioner) p), id, channel, payload);
    },
    kick = (p: *void, id: Connection_Id, later: bool) -> Connection_State_Change_Result {
        return kick(((cast(*Conditioner) p)).inner, id, later);
    },
    incoming = (p: *void) -> [] Incoming_Packet {
        return incoming_packets(((cast(*Conditioner) p)).inner);
    },
    clear_incoming = (p: *void) {
        clear_incoming(((cast(*Conditioner) p)).inner);
    },
    changes = (p: *void) -> [] State_Change {
        return state_changes_view(((cast(*Conditioner) p)).inner);
    },
    clear_changes = (p: *void) {
        clear_state_changes(((cast(*Conditioner) p)).inner);
    },
    flush = (p: *void) {
        c := (cast(*Conditioner) p);
        conditioner_release(c, true);
        flush(c.inner);
    },
    disconnect_local = (p: *void) -> Connection_State_Change_Result {
        return disconnect_local(((cast(*Conditioner) p)).inner);
    },
    stop_client = (p: *void) -> bool {
        return stop_client(((cast(*Conditioner) p)).inner);
    },
    shutdown = (p: *void) {
        c := (cast(*Conditioner) p);
        conditioner_drop(c);
        shutdown(c.inner);
    },
    capabilities = (p: *void) -> Capabilities {
        return capabilities(((cast(*Conditioner) p)).inner);
    },
    remote_identity = (p: *void, id: Connection_Id) -> string {
        return remote_identity(((cast(*Conditioner) p)).inner, id);
    },
    open_local_pair = (p: *void) -> bool {
        return open_local_pair(((cast(*Conditioner) p)).inner);
    },
    // 内层质量加上本层仍在排队的可靠字节；本层施加的延迟不计入 rtt_ms。

    connection_quality = (p: *void, id: Connection_Id) -> Connection_Quality, bool {
        c := (cast(*Conditioner) p);
        q, ok := connection_quality(c.inner, id);
        if !ok {
            return q, false;
        }

        for item: c.queue {
            if item.connection == id && item.channel == .Reliable {
                q.pending_bytes = max(q.pending_bytes, 0) + (cast, trunc(s64)((item.payload).count));
            }
        }

        return q, true;
    },
}

//@endregion
// Cast semantics adapted.
// Loop scopes adapted.
