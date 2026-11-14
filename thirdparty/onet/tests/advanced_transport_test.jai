#scope_file
session :: #import "thirdparty/onet/session";
transport :: #import "thirdparty/onet/transport";
udp :: #import "thirdparty/onet/transport/udp";
#scope_export

//@region Native loopback, late join and reconnect

native_pump :: (server, a: *udp.Transport, b: *udp.Transport = null, iterations: int = 300) {
    {
        loop_index := 0;
        while loop_index < iterations {
            defer loop_index += 1;
            udp.poll(server);
            udp.poll(a);
            if b != null {
                udp.poll(b);
            };
            sleep_milliseconds(1);
        }
    }
}

native_ready :: (server, a: *udp.Transport) -> bool {
    {
        loop_index := 0;
        while loop_index < 1000 {
            defer loop_index += 1;

            udp.poll(server);
            udp.poll(a);
            if udp.client_is_connected(a) {
                return true;
            };
            sleep_milliseconds(1);
        }
    }

    return false;
}

native_server_id :: (server: *udp.Transport, client: *udp.Transport) -> transport.Connection_Id {
    for p, id: server.peers {
        if p.nonce == client.client.nonce {
            return id;
        }
    };
    return 0;
}

native_udp_ipv4_two_clients_late_join_reconnect :: (t: *Test) {
    cfg := udp.default_config();
    server, a, b: udp.Transport;
    expect(t, udp.init(*server, cfg));
    defer udp.destroy(*server);
    expect(t, udp.init(*a, cfg));
    defer udp.destroy(*a);
    expect(t, udp.init(*b, cfg));
    defer udp.destroy(*b);
    if !expect(t, udp.start_server(*server, 0, 2)) {
        return;
    }

    if !expect(t, udp.start_client(*a, "localhost", udp.bound_port(*server))) {
        return;
    }

    if !expect(t, native_ready(*server, *a), "real IPv4/DNS handshake") {
        return;
    }

    a_id := native_server_id(*server, *a);
    old_local := udp.local_client_connection(*a);
    old_nonce := a.client.nonce;
    message := (cast(string) ("before late join"));
    expect(t, udp.send(*server, a_id, .Reliable, bit_cast([] u8, message)));
    native_pump(*server, *a, null, 10);
    expect_value(t, (a.incoming).count, 1);
    if (a.incoming).count > 0 {
        expect_value(t, (cast(string) (a.incoming[0].payload)), "before late join");
    }

    udp.clear_incoming(*a);
    expect(t, udp.start_client(*b, "127.0.0.1", udp.bound_port(*server)));
    if !expect(t, native_ready(*server, *b)) {
        return;
    }

    expect_value(t, udp.server_connection_count(*server), 2);
    b_id := native_server_id(*server, *b);
    expect(t, a_id != b_id && a_id != 0 && b_id != 0);
    expect(t, udp.send(*a, old_local, .Reliable, u8.[10]));
    expect(t, udp.send(*b, udp.local_client_connection(*b), .Reliable, u8.[20]));
    native_pump(*server, *a, *b, 15);
    expect_value(t, (server.incoming).count, 2);
    udp.clear_incoming(*server);
    expect(t, udp.disconnect_local(*a) == .Success);
    native_pump(*server, *a, *b, 10);
    expect_value(t, udp.server_connection_count(*server), 1);
    expect(t, udp.stop_client(*a));
    expect(t, udp.start_client(*a, "127.0.0.1", udp.bound_port(*server)));
    if !expect(t, native_ready(*server, *a)) {
        return;
    }

    new_id := native_server_id(*server, *a);
    expect(t, new_id != a_id && udp.local_client_connection(*a) != old_local && a.client.nonce != old_nonce);
    expect_value(t, (a.client.pending).count, 0);
    expect_value(t, a.client.next_receive, (cast, trunc(u32)(1)));
    expect(t, !udp.send(*server, a_id, .Reliable, u8.[0]));
    expect(t, udp.send(*server, new_id, .Reliable, u8.[30]));
    native_pump(*server, *a, *b, 10);
    expect_value(t, (a.incoming).count, 1);
    if (a.incoming).count > 0 {
        expect_value(t, a.incoming[0].payload[0], (cast, trunc(u8)(30)));
    }
}

native_udp_real_ipv4_ipv6_dual_listener :: (t: *Test) {
    cfg := udp.default_config();
    cfg.family = .Dual;
    server, a, b: udp.Transport;
    expect(t, udp.init(*server, cfg));
    defer udp.destroy(*server);
    cfg.family = .IPv4;
    expect(t, udp.init(*a, cfg));
    defer udp.destroy(*a);
    cfg.family = .IPv6;
    expect(t, udp.init(*b, cfg));
    defer udp.destroy(*b);
    if !expect(t, udp.start_server(*server, 0)) {
        return;
    }

    expect(t, server.server_sockets[0] != 0 && server.server_sockets[1] != 0, "two native address-family sockets, not ENet");
    expect(t, udp.start_client(*a, "127.0.0.1", udp.bound_port(*server)));
    expect(t, udp.start_client(*b, "::1", udp.bound_port(*server)));
    if !expect(t, native_ready(*server, *a) && native_ready(*server, *b)) {
        return;
    }

    expect(t, udp.send(*a, udp.local_client_connection(*a), .Reliable, u8.[4]));
    expect(t, udp.send(*b, udp.local_client_connection(*b), .Reliable, u8.[6]));
    native_pump(*server, *a, *b, 15);
    expect_value(t, (server.incoming).count, 2);
    expect_value(t, udp.server_connection_count(*server), 2);
    for p, _: server.peers {
        expect(t, udp.send(*server, p.id, .Reliable, u8.[9]));
    }

    native_pump(*server, *a, *b, 10);
    expect_value(t, (a.incoming).count, 1);
    expect_value(t, (b.incoming).count, 1);
}

//@endregion
//@region Actual UDP relay loss, duplication and reordering

Native_Relay :: struct {
    socket: net.UDP_Socket;

    server, client: net.Endpoint;

    delayed: [] u8;

    counts: [16] int;

    dropped: bool;
}

native_relay_poll :: (r: *Native_Relay) {
    buf: [65536] u8;
    {
        loop_index := 0;
        while loop_index < 500 {
            defer loop_index += 1;

            n, from, err := net.recv_udp(r.socket, view(buf, 0));
            if err != .None {
                break;
            }

            if from.port == r.server.port {
                if r.client.address.family != .Invalid {
                    net.send_udp(r.socket, view(buf, 0, n), r.client);
                };
                continue;
            }

            r.client = from;
            if n >= udp.HEADER_SIZE && buf[5] == (cast, trunc(u8)(udp.Packet_Type.Data)) && udp.get32(view(buf, 16, 20)) == 1 {
                index := (cast(int) (udp.get16(view(buf, 20, 22))));
                if index < (r.counts).count {
                    r.counts[index] += 1;
                }

                if index == 1 && !r.dropped {
                    r.dropped = true;
                    continue;
                }
                // absent at the actual receiving UDP socket

                if index == 2 && r.delayed.data == null {
                    r.delayed = new_slice(u8, n);
                    copy_samples(r.delayed, view(buf, 0, n));
                    continue;
                }

                if index == 0 {
                    net.send_udp(r.socket, view(buf, 0, n), r.server);
                }
                // actual duplicate datagram
            }

            net.send_udp(r.socket, view(buf, 0, n), r.server);
        }
    }
}

native_udp_selective_fragment_recovery_through_real_lossy_udp :: (t: *Test) {
    cfg := udp.default_config();
    cfg.retry_ms = 100;
    server, a: udp.Transport;
    expect(t, udp.init(*server, cfg));
    defer udp.destroy(*server);
    expect(t, udp.init(*a, cfg));
    defer udp.destroy(*a);
    if !expect(t, udp.start_server(*server, 0)) {
        return;
    }

    s, err := net.make_bound_udp_socket(net.IP4_Loopback, 0);
    if !expect(t, err == .None) {
        return;
    };
    defer net.close(s);
    net.set_blocking(s, false);
    ep, _ := net.bound_endpoint(s);
    r := Native_Relay.{
        socket = s, server = .{
            net.IP4_Loopback, (cast(int) (udp.bound_port(*server))),
        },
    };

    defer release(r.delayed);
    expect(t, udp.start_client(*a, "127.0.0.1", (cast, trunc(u16)(ep.port))));
    {
        loop_index := 0;
        while loop_index < 1000 {
            defer loop_index += 1;
            native_relay_poll(*r);
            udp.poll(*server);
            udp.poll(*a);
            if udp.client_is_connected(*a) {
                break;
            };
            sleep_milliseconds(1);
        }
    }

    if !expect(t, udp.client_is_connected(*a)) {
        return;
    }

    big := new_slice(u8, 6000);
    defer release(big);
    {
        i := 0;
        while i < (big).count {
            defer i += 1;
            big[i] = (cast, trunc(u8)(i * 7 + 3));
        }
    }

    expect(t, udp.send(*a, udp.local_client_connection(*a), .Reliable, big));
    expect(t, udp.send(*a, udp.local_client_connection(*a), .Reliable, u8.[99]));
    {
        i := 0;
        while i < 1000 {
            defer i += 1;

            native_relay_poll(*r);
            udp.poll(*server);
            udp.poll(*a);
            if i == 5 && r.delayed.data != null {
                net.send_udp(s, r.delayed, r.server);
            }

            if (server.incoming).count == 2 && (a.client.pending).count == 0 {
                break;
            };
            sleep_milliseconds(1);
        }
    }

    expect(t, r.dropped, "relay actually discarded one on-wire fragment");
    expect_value(t, (server.incoming).count, 2);
    if (server.incoming).count == 2 {
        expect_value(t, (server.incoming[0].payload).count, (big).count);
        for v, i: server.incoming[0].payload {
            if v != big[i] {
                expect(t, false, "fragment content");
                break;
            }
        }

        expect_value(t, server.incoming[1].payload[0], (cast, trunc(u8)(99)));
    }

    {
        i := 0;
        while i < 6 {
            defer i += 1;
            expect(t, r.counts[i] == (ifx i == 1 then 2 else 1), "only the missing fragment was resent");
        }
    }

    expect_value(t, a.stats.retransmitted, (cast, trunc(u64)(1)));
    expect_value(t, (a.client.pending).count, 0);
}

//@endregion
//@region Simulation ownership, deterministic sequence and wrap safety

native_udp_owned_latency_queue_and_explicit_flush :: (t: *Test) {
    cfg := udp.default_config();
    server, a: udp.Transport;
    expect(t, udp.init(*server, cfg));
    defer udp.destroy(*server);
    expect(t, udp.init(*a, cfg));
    defer udp.destroy(*a);
    expect(t, udp.start_server(*server, 0));
    expect(t, udp.start_client(*a, "127.0.0.1", udp.bound_port(*server)));
    if !expect(t, native_ready(*server, *a)) {
        return;
    }

    udp.set_conditions(*a, .{
        seed = 91, latency_ms = 10000, jitter_ms = 100, reorder_permille = 1000, reorder_ms = 300
    });
    data: [] u8 = u8.[1, 2, 3, 4];
    expect(t, udp.send(*a, udp.local_client_connection(*a), .Reliable, data));
    data[0] = 255;
    expect_value(t, (a.queue).count, 1);
    udp.poll(*server);
    expect_value(t, (server.incoming).count, 0);
    udp.flush(*a);
    expect_value(t, (a.queue).count, 0);
    udp.poll(*server);
    expect_value(t, (server.incoming).count, 1);
    if (server.incoming).count > 0 {
        expect_value(t, server.incoming[0].payload[0], (cast, trunc(u8)(1)));
    }

    udp.poll(*a);
    expect_value(t, (a.client.pending).count, 0);
};

native_udp_seeded_loss_jitter_reorder_is_reproducible :: (t: *Test) {
    cfg := udp.default_config();
    cfg.conditions = .{
        seed = 781, loss_permille = 200, duplicate_permille = 300, reorder_permille = 500, latency_ms = 100000, jitter_ms = 100, reorder_ms = 500,
    };

    cfg.max_queue_packets = 8;
    cfg.max_queue_bytes = 8 * cfg.max_datagram;
    a, b: udp.Transport;
    expect(t, udp.init(*a, cfg));
    defer udp.destroy(*a);
    expect(t, udp.init(*b, cfg));
    defer udp.destroy(*b);
    expect(t, udp.bind_client(*a));
    expect(t, udp.bind_client(*b));
    ep := net.Endpoint.{
        net.IP4_Loopback, 45678,
    };

    {
        i := 0;
        while i < 50 {
            defer i += 1;

            udp.emit(*a, .Client, ep, .Ping, 1, 0, 0, 0, (cast, trunc(u64)(i + 1)), 0, u8.[(cast, trunc(u8)(i))]);
            udp.emit(*b, .Client, ep, .Ping, 1, 0, 0, 0, (cast, trunc(u64)(i + 1)), 0, u8.[(cast, trunc(u8)(i))]);
        }
    }

    expect(t, (a.queue).count <= cfg.max_queue_packets && a.queue_bytes <= cfg.max_queue_bytes);
    expect(t, a.stats.dropped > 0 && a.stats.duplicated > 0);
    expect_value(t, a.stats.dropped, b.stats.dropped);
    expect_value(t, (a.queue).count, (b.queue).count);
    for q, i: a.queue {
        expect_value(t, q.due, b.queue[i].due);
        expect_value(t, (cast(string) (q.payload)), (cast(string) (b.queue[i].payload)));
    }
}

native_udp_sequence_wrap_and_duplicate_suppression :: (t: *Test) {
    cfg := udp.default_config();
    server, a: udp.Transport;
    expect(t, udp.init(*server, cfg));
    defer udp.destroy(*server);
    expect(t, udp.init(*a, cfg));
    defer udp.destroy(*a);
    expect(t, udp.start_server(*server, 0));
    expect(t, udp.start_client(*a, "127.0.0.1", udp.bound_port(*server)));
    if !expect(t, native_ready(*server, *a)) {
        return;
    }

    p := table_get(*server.peers, native_server_id(*server, *a));
    a.client.next_send = (cast, trunc(u32)(4294967295)) - 1;
    p.next_receive = (cast, trunc(u32)(4294967295)) - 1;
    a.client.next_unreliable = (cast, trunc(u32)(4294967295)) - 1;
    udp.set_conditions(*a, .{
        seed = 1, duplicate_permille = 1000
    });
    {
        i := 0;
        while i < 3 {
            defer i += 1;
            expect(t, udp.send(*a, a.client.id, .Reliable, u8.[(cast, trunc(u8)(i))]));
        }
    };

    native_pump(*server, *a, null, 15);
    expect_value(t, (server.incoming).count, 3);
    for packet, i: server.incoming {
        expect_value(t, packet.payload[0], (cast, trunc(u8)(i)));
    }

    udp.clear_incoming(*server);
    {
        i := 0;
        while i < 3 {
            defer i += 1;
            expect(t, udp.send(*a, a.client.id, .Unreliable, u8.[(cast, trunc(u8)(i))]));
        }
    }

    native_pump(*server, *a, null, 10);
    expect_value(t, (server.incoming).count, 3);
    expect_value(t, p.next_receive, (cast, trunc(u32)(1)));
    udp.clear_incoming(*server);
    udp.emit(*a, .Client, a.client.endpoint, .Data, a.client.token ^ 1, 1, 0, 1, a.client.nonce, 0, u8.[77]);
    native_pump(*server, *a, null, 5);
    expect(t, (server.incoming).count == 0, "wrong session token is ignored");
}

//@endregion
//@region Session selection and independent custom vtable

native_udp_session_ipv6_host_driver :: (t: *Test) {
    cfg := udp.default_config();
    cfg.family = .IPv6;
    x: udp.Transport;
    expect(t, udp.init(*x, cfg));
    defer udp.destroy(*x);
    s: session.Session;
    session.init(*s);
    defer session.destroy(*s);
    expect(t, session.set_driver(*s, udp.driver(*x)));
    if !expect(t, session.start_host(*s)) {
        return;
    }

    {
        loop_index := 0;
        while loop_index < 1000 {
            defer loop_index += 1;
            session.update(*s, 1);
            if s.client_authenticated && session.connection_count(*s) == 1 {
                break;
            };
            sleep_milliseconds(1);
        }
    }

    expect(t, s.client_authenticated && session.client_is_connected(*s));
    expect_value(t, session.connection_count(*s), 1);
    none: session.Session;
    session.init(*none);
    defer session.destroy(*none);
    expect(t, !session.start_server(*none, 0) && !session.start_host(*none) && session.update(*none, 5), "no backend: start fails, update is a no-op");
    expect(t, !session.set_driver(*s, .{
    }), "cannot replace a running backend");
    session.shutdown(*s);
    expect_value(t, udp.bound_port(*x), (cast, trunc(u16)(0)));
};

Custom_Driver_Test :: struct {
    started_server, started_client, delivered: bool;
    polls, sends, shutdowns, handled: int;
    trace: [..] u8;
    changes: [2] transport.State_Change;
    incoming: [1] transport.Incoming_Packet;
}

custom_transport_vtable := transport.Driver_Vtable.{
    start_server = (p: *void, port: u16, limit: u64) -> bool {
        ((cast(*Custom_Driver_Test) p)).started_server = true;
        return port == 0 && limit > 0;
    },
    start_client = (p: *void, host: string, port: u16) -> bool {
        ((cast(*Custom_Driver_Test) p)).started_client = true;
        return host == "127.0.0.1" && port == 32123;
    },
    bound_port = (p: *void) -> u16 {
        return 32123;
    },
    local_connection = (p: *void) -> transport.Connection_Id {
        return 2;
    },
    client_is_connected = (p: *void) -> bool {
        return ((cast(*Custom_Driver_Test) p)).started_client;
    },
    poll = (p: *void) {
        x := (cast(*Custom_Driver_Test) p);
        x.polls += 1;
        if x.polls == 1 {
            x.changes = .[.{ 1, .Server, .Connected }, .{ 2, .Client, .Connected }];
        };
    },
    send = (p: *void, id: transport.Connection_Id, c: transport.Channel, b: [] u8) -> bool {
        ((cast(*Custom_Driver_Test) p)).sends += 1;
        return (b).count > 0 && id != 0;
    },
    kick = (p: *void, id: transport.Connection_Id, later: bool) -> transport.Connection_State_Change_Result {
        return .Success;
    },
    incoming = (p: *void) -> [] transport.Incoming_Packet {
        x := (cast(*Custom_Driver_Test) p);
        if x.delivered {
            return .[];
        };
        return view(x.incoming, 0);
    },
    clear_incoming = (p: *void) {
        ((cast(*Custom_Driver_Test) p)).delivered = true;
    },
    changes = (p: *void) -> [] transport.State_Change {
        x := (cast(*Custom_Driver_Test) p);
        if x.polls != 1 {
            return .[];
        };
        return view(x.changes, 0);
    },
    clear_changes = (p: *void) {},
    flush = (p: *void) {},
    disconnect_local = (p: *void) -> transport.Connection_State_Change_Result {
        return .Success;
    },
    stop_client = (p: *void) -> bool {
        return true;
    },
    shutdown = (p: *void) {
        ((cast(*Custom_Driver_Test) p)).shutdowns += 1;
    },
}

session_custom_driver_and_fixed_tick_runtime_order :: (t: *Test) {
    x: Custom_Driver_Test;
    defer release(x.trace);
    frame: [] u8 = u8.[(cast, trunc(u8)(session.Packet_Kind.Message)), 0, 7, 42];
    x.incoming[0] = .{
        1, .Server, .Reliable, frame,
    };

    s: session.Session;
    session.init(*s);
    defer session.destroy(*s);
    s.userdata = *x;
    s.runtime_before_tick = (s: *session.Session) {
        array_add(*((cast(*Custom_Driver_Test) s.userdata)).trace, 1);
    }

    s.on_tick = (s: *session.Session) {
        array_add(*((cast(*Custom_Driver_Test) s.userdata)).trace, 2);
    }

    s.runtime_tick = (s: *session.Session) {
        array_add(*((cast(*Custom_Driver_Test) s.userdata)).trace, 3);
    }

    session.register_handler(*s, 7, (s: *session.Session, id: transport.Connection_Id, payload: [] u8) {
        if id == 1 && (payload).count == 1 && payload[0] == 42 {
            ((cast(*Custom_Driver_Test) s.userdata)).handled += 1
            ;
        }
    });
    expect(t, session.set_driver(*s, .{
        *x, *custom_transport_vtable
    }));
    expect(t, session.start_host(*s));
    expect(t, session.update(*s, 100));
    expect(t, x.started_server && x.started_client);
    expect_value(t, x.handled, 1);
    expect(t, x.sends >= 1);
    expect_value(t, (x.trace).count, 6);
    for v, i: x.trace {
        expect_value(t, v, (cast, trunc(u8)(i % 3 + 1)));
    }

    expect(t, session.disconnect_local(*s) == .Success && session.stop_client(*s));
    session.flush(*s);
    expect(t, session.kick(*s, 1) == .Success);
    session.shutdown(*s);
    expect_value(t, x.shutdowns, 1);
};

//@endregion
//@region Lossy handshake, ACK loss and exact memory bounds

native_udp_seeded_lossy_handshake_and_bidirectional_fragments :: (t: *Test) {
    cfg := udp.default_config();
    cfg.retry_ms = 20;
    cfg.conditions = .{
        seed = 19271, loss_permille = 300, duplicate_permille = 150, reorder_permille = 500, latency_ms = 1, jitter_ms = 3, reorder_ms = 6,
    };

    server, a: udp.Transport;
    expect(t, udp.init(*server, cfg));
    defer udp.destroy(*server);
    cfg.conditions.seed = 8761;
    expect(t, udp.init(*a, cfg));
    defer udp.destroy(*a);
    expect(t, udp.start_server(*server, 0));
    expect(t, udp.start_client(*a, "127.0.0.1", udp.bound_port(*server)));
    if !expect(t, native_ready(*server, *a), "challenge/echo/accept retries under loss") {
        return;
    }

    payload := new_slice(u8, 32768);
    defer release(payload);
    {
        i := 0;
        while i < (payload).count {
            defer i += 1;
            payload[i] = (cast, trunc(u8)(i * 3));
        }
    }

    expect(t, udp.send(*a, a.client.id, .Reliable, payload));
    expect(t, udp.send(*server, native_server_id(*server, *a), .Reliable, payload));
    {
        loop_index := 0;
        while loop_index < 3000 {
            defer loop_index += 1;

            udp.poll(*server);
            udp.poll(*a);
            if (server.incoming).count == 1 && (a.incoming).count == 1 && (a.client.pending).count == 0 && (table_get(*server.peers, native_server_id(*server, *a)).pending).count == 0 {
                break;
            }

            sleep_milliseconds(1);
        }
    }

    expect_value(t, (server.incoming).count, 1);
    expect_value(t, (a.incoming).count, 1);
    if (server.incoming).count == 1 {
        expect_value(t, (cast(string) (server.incoming[0].payload)), (cast(string) (payload)));
    }

    if (a.incoming).count == 1 {
        expect_value(t, (cast(string) (a.incoming[0].payload)), (cast(string) (payload)));
    }

    expect(t, server.stats.retransmitted > 0 && a.stats.retransmitted > 0);
}

native_udp_lost_acks_duplicate_delivery_and_exact_reassembly_budget :: (t: *Test) {
    cfg := udp.default_config();
    cfg.retry_ms = 10;
    cfg.max_message = 4096;
    cfg.max_buffered_bytes = 4096;
    server, a: udp.Transport;
    expect(t, udp.init(*server, cfg));
    defer udp.destroy(*server);
    expect(t, udp.init(*a, cfg));
    defer udp.destroy(*a);
    expect(t, udp.start_server(*server, 0));
    expect(t, udp.start_client(*a, "127.0.0.1", udp.bound_port(*server)));
    if !expect(t, native_ready(*server, *a)) {
        return;
    }

    udp.set_conditions(*server, .{
        seed = 1, loss_permille = 1000
    });
    payload := new_slice(u8, 4096);
    defer release(payload);
    expect(t, udp.send(*a, a.client.id, .Reliable, payload));
    udp.poll(*server);
    udp.poll(*a);
    expect_value(t, (server.incoming).count, 1);
    expect_value(t, (a.client.pending).count, 1);
    udp.set_conditions(*server, .{
        seed = 1
    });
    sleep_milliseconds(15);
    {
        loop_index := 0;
        while loop_index < 100 {
            defer loop_index += 1;
            udp.poll(*a);
            udp.poll(*server);
            if (a.client.pending).count == 0 {
                break;
            };
            sleep_milliseconds(1);
        }
    }

    expect_value(t, (a.client.pending).count, 0);
    expect_value(t, (server.incoming).count, 1);
    expect(t, a.stats.retransmitted >= 4, "lost ACKs recover without duplicate application delivery");
    for p, _: server.peers {
        expect_value(t, p.assembly_bytes, 0);
    }
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
