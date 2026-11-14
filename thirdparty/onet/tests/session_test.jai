#scope_file
session :: #import "thirdparty/onet/session";
transport :: #import "thirdparty/onet/transport";
enet :: #import "thirdparty/onet/transport/enet";
#scope_export
// Session layer tests (connection lifecycle, messages, ticks).
// Per-test result sinks (tests run in parallel; each test owns its own).

session_msg_seen_a: bool;
session_msg_seen_b: bool;
session_msg_payload: string;
session_connect_count: int;
session_disconnect_count: int;
session_tick_fires: int;
session_msg_ready: bool;

session_pump :: (
t: *Test,
sessions: [] *session.Session,
check: #type () -> bool,
label: string,
) -> bool {
    {
        loop_index := 0;
        while loop_index < 3000 {
            defer loop_index += 1;

            for s: sessions {
                session.update(s, 5);
            }

            if check() {
                return true;
            }

            sleep_milliseconds(1);
        }
    }

    expect(t, false, label);
    return false;
}

// 测试默认使用 ENet 后端。后端必须比 Session 活得久：先 session.destroy，再 enet.destroy。

test_session :: (s: *session.Session, backend: *enet.Transport, tick := session.DEFAULT_TICK_INTERVAL_MS) {
    session.init(s, tick);
    enet.init(backend);
    assert(session.set_driver(s, enet.driver(backend)));
}

bytes_of :: (s: string) -> [] u8 {
    return bit_cast([] u8, s);
}

session_set_ready :: (s: *session.Session, connection: transport.Connection_Id) {
    _ = s;
    _ = connection;
    session_msg_ready = true;
}

session_ready :: () -> bool {
    return session_msg_ready;
}

session_host_message_roundtrip :: (t: *Test) {
    session_msg_seen_a = false;
    session_msg_seen_b = false;
    session_msg_payload = "";
    session_msg_ready = false;

    x: enet.Transport;
    defer enet.destroy(*x);
    s: session.Session;
    test_session(*s, *x);
    defer session.destroy(*s);
    s.on_client_connected = session_set_ready;

    session.register_handler(*s, 101, session_msg_handler_a);
    session.register_handler(*s, 102, session_msg_handler_b);

    expect(t, session.start_host(*s), "host start");

    // Wait for the ENet handshake before sending (sending while the peer is
    // still CONNECTING drops the packet).

    session_pump(t, *session.Session.[*s], session_ready, "host connected");

    // Client -> server.

    session.send_to_server(*s, 101, bytes_of("ping"));
    session_pump(t, *session.Session.[*s], session_saw_a, "server got message 101");

    // Server -> client (broadcast to the one connection).

    session.broadcast_message(*s, 102, bytes_of("pong"));
    session_pump(t, *session.Session.[*s], session_saw_b, "client got message 102");

    expect_value(t, session_msg_payload, "pong");
    expect(t, session.connection_count(*s) == 1, "one server connection");
}

session_msg_handler_a :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    // Server side receives from the client.

    if s.role != .Host && s.role != .Server {
        return;
    }

    _ = from;
    if (cast(string) (payload)) == "ping" {
        session_msg_seen_a = true;
    }
}

session_msg_handler_b :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    _ = s;
    _ = from;
    session_msg_seen_b = true;
    session_msg_payload = (cast(string) (payload));
}

session_saw_a :: () -> bool {
    return session_msg_seen_a;
}

session_saw_b :: () -> bool {
    return session_msg_seen_b;
}

session_two_clients_broadcast :: (t: *Test) {
    tc_connects = 0;
    tc_server_hits = 0;
    tc_mark_a = false;
    tc_mark_b = false;

    server_x, a_x, b_x: enet.Transport;
    defer {
        enet.destroy(*server_x);
        enet.destroy(*a_x);
        enet.destroy(*b_x);
    }

    server: session.Session;
    test_session(*server, *server_x);
    defer session.destroy(*server);
    server.on_client_connected = tc_connect_hook;
    session.register_handler(*server, 201, tc_count_server_msg);

    client_a: session.Session;
    test_session(*client_a, *a_x);
    defer session.destroy(*client_a);
    session.register_handler(*client_a, 202, tc_mark_handler_a);

    client_b: session.Session;
    test_session(*client_b, *b_x);
    defer session.destroy(*client_b);
    session.register_handler(*client_b, 202, tc_mark_handler_b);

    expect(t, session.start_server(*server, 0), "server start");
    port := session.bound_port(*server);
    expect(t, session.start_client(*client_a, "127.0.0.1", port), "client A start");
    expect(t, session.start_client(*client_b, "127.0.0.1", port), "client B start");

    session_pump(t, *session.Session.[*server, *client_a, *client_b], tc_both_connected, "both clients connected");

    // Both clients talk to the server.

    session.send_to_server(*client_a, 201, bytes_of("a"));
    session.send_to_server(*client_b, 201, bytes_of("b"));
    session_pump(t, *session.Session.[*server, *client_a, *client_b], tc_saw_two, "server counted both");

    // Server broadcasts; both clients receive.

    session.broadcast_message(*server, 202, bytes_of("all"));
    session_pump(t, *session.Session.[*server, *client_a, *client_b], tc_both_marked, "both clients received broadcast");
}

// Dedicated globals: tests run in parallel and must not share result sinks.

tc_connects: int;
tc_server_hits: int;
tc_mark_a: bool;
tc_mark_b: bool;

tc_connect_hook :: (s: *session.Session, connection: transport.Connection_Id) {
    _ = s;
    _ = connection;
    tc_connects += 1;
}

tc_both_connected :: () -> bool {
    return tc_connects >= 2;
}

tc_count_server_msg :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    _ = s;
    _ = from;
    _ = payload;
    tc_server_hits += 1;
}

tc_saw_two :: () -> bool {
    return tc_server_hits >= 2;
}

tc_mark_handler_a :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    _ = s;
    _ = from;
    _ = payload;
    tc_mark_a = true;
}

tc_mark_handler_b :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    _ = s;
    _ = from;
    _ = payload;
    tc_mark_b = true;
}

tc_both_marked :: () -> bool {
    return tc_mark_a && tc_mark_b;
}

session_tick_and_kick :: (t: *Test) {
    session_connect_count = 0;
    session_disconnect_count = 0;
    session_tick_fires = 0;

    x: enet.Transport;
    defer enet.destroy(*x);
    s: session.Session;
    test_session(*s, *x, 10); // 10 ms tick for the test

    defer session.destroy(*s);
    s.on_tick = session_tick_hook;
    s.on_client_connected = session_connect_hook;
    s.on_client_disconnected = session_disconnect_hook;

    expect(t, session.start_host(*s), "host start");
    session_pump(t, *session.Session.[*s], session_saw_connect, "connect hook fired");

    // Tick fires roughly once per 10 ms of update time.

    {
        loop_index := 0;
        while loop_index < 10 {
            defer loop_index += 1;

            session.update(*s, 10);
        }
    }

    expect(t, session_tick_fires >= 9, "tick fires at 10ms cadence");

    // Kick the (own) client; the disconnect hook must fire.

    kicked := session.kick(*s, first_live_connection(*s));
    expect(t, kicked == .Success, "kick succeeds");
    session_pump(t, *session.Session.[*s], session_saw_disconnect, "disconnect hook fired");
}

session_tick_hook :: (s: *session.Session) {
    _ = s;
    session_tick_fires += 1;
}

session_connect_hook :: (s: *session.Session, connection: transport.Connection_Id) {
    _ = s;
    _ = connection;
    session_connect_count += 1;
}

session_disconnect_hook :: (s: *session.Session, connection: transport.Connection_Id) {
    _ = s;
    _ = connection;
    session_disconnect_count += 1;
}

session_saw_connect :: () -> bool {
    return session_connect_count == 1;
}

session_saw_disconnect :: () -> bool {
    return session_disconnect_count == 1;
}

first_live_connection :: (s: *session.Session) -> transport.Connection_Id {
    for id: s.connections {
        if id != transport.UNSET_CONNECTION_ID {
            return id;
        }
    }

    return transport.UNSET_CONNECTION_ID;
}

// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
