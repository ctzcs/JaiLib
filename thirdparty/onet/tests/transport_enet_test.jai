#scope_file
transport :: #import "thirdparty/onet/transport";
enet_transport :: #import "thirdparty/onet/transport/enet";
#scope_export
// ENet transport loopback tests (host mode = server + client in one transport).
//
// Run from onet/:
//   odin test thirdparty/onet/tests -collection:olib=. -vet
// ENet stores Address.host in network byte order; on little-endian hosts
// these literals are byte-swapped from the usual dotted-quad reading.

ENET_LOOPBACK_HOST :: (cast, trunc(u32)(0x0100007F)); // 127.0.0.1

ENET_LAN_HOST :: (cast, trunc(u32)(0x6401A8C0)); // 192.168.1.100

// Polls both halves until predicate is true or the iteration cap hits.

pump_until :: (
t: *Test,
x: *enet_transport.Transport,
check: #type (x: *enet_transport.Transport) -> bool,
label: string,
) -> bool {
    {
        loop_index := 0;
        while loop_index < 3000 {
            defer loop_index += 1;

            enet_transport.poll(x);
            if check(x) {
                return true;
            }

            sleep_milliseconds(1);
        }
    }

    expect(t, false, label);
    return false;
}

server_has_connection :: (x: *enet_transport.Transport) -> bool {
    return enet_transport.server_connection_count(x) == 1;
}

client_connected :: (x: *enet_transport.Transport) -> bool {
    return enet_transport.client_is_connected(x);
}

has_incoming :: (x: *enet_transport.Transport) -> bool {
    return (enet_transport.incoming_packets(x)).count > 0;
}

incoming_from :: (x: *enet_transport.Transport, side: transport.Invoker) -> bool {
    for packet: enet_transport.incoming_packets(x) {
        if packet.invoker == side {
            return true;
        }
    }

    return false;
}

find_incoming :: (x: *enet_transport.Transport, side: transport.Invoker, connection: transport.Connection_Id) -> (payload: [] u8, ok: bool) {
    for packet: enet_transport.incoming_packets(x) {
        if packet.invoker == side && packet.connection == connection {
            return packet.payload, true;
        }
    }

    return .[], false;
}

make_host_transport :: (t: *Test) -> (x: enet_transport.Transport, server_connection: transport.Connection_Id) {
    enet_transport.init(*x);

    ok := enet_transport.start_server(*x, 0);
    expect(t, ok, "server start");
    expect(t, !enet_transport.failed(*x), "server start clean");

    ok = enet_transport.start_client(*x, "127.0.0.1", enet_transport.bound_port(*x));
    expect(t, ok, "client start");
    expect(t, enet_transport.is_host_mode(*x), "host mode");

    pump_until(t, *x, server_has_connection, "server saw connection");
    pump_until(t, *x, client_connected, "client connected");

    // Exactly one server-side connection exists: it is the local client.

    expect(t, enet_transport.server_connection_count(*x) == 1, "one connection");
    for change: enet_transport.state_changes_view(*x) {
        if change.invoker == .Server && change.kind == .Connected {
            server_connection = change.connection;
        }
    }

    expect(t, server_connection != transport.UNSET_CONNECTION_ID, "captured server connection id");
    return;
}

enet_host_mode_echo_reliable :: (t: *Test) {
    x, server_connection := make_host_transport(t);
    defer enet_transport.destroy(*x);

    // Client -> server.

    msg := "hello from client";
    ok := enet_transport.send(*x, enet_transport.local_client_connection(*x), .Reliable, bit_cast([] u8, msg));
    expect(t, ok, "client send");

    pump_until(t, *x, has_incoming, "server receive");
    payload, found := find_incoming(*x, .Server, server_connection);
    expect(t, found, "server incoming from loopback peer");
    expect_value(t, (cast(string) (payload)), msg);
    enet_transport.clear_incoming(*x);

    // Server -> client (echo back).

    reply := "echo from server";
    ok = enet_transport.send(*x, server_connection, .Reliable, bit_cast([] u8, reply));
    expect(t, ok, "server send");

    pump_until(t, *x, incoming_from_client, "client receive");
    payload, found = find_incoming(*x, .Client, enet_transport.local_client_connection(*x));
    expect(t, found, "client incoming");
    expect_value(t, (cast(string) (payload)), reply);
}

incoming_from_client :: (x: *enet_transport.Transport) -> bool {
    return incoming_from(x, .Client);
}

enet_host_mode_echo_unreliable :: (t: *Test) {
    x, server_connection := make_host_transport(t);
    defer enet_transport.destroy(*x);

    msg := "u";
    {
        loop_index := 0;
        while loop_index < 64 {
            defer loop_index += 1;

            ok := enet_transport.send(*x, enet_transport.local_client_connection(*x), .Unreliable, bit_cast([] u8, msg));
            expect(t, ok, "unreliable send");
            enet_transport.poll(*x);
            sleep_milliseconds(1);
        }
    }

    // Loopback drops nothing; all 64 should arrive.

    count := 0;
    for packet: enet_transport.incoming_packets(*x) {
        if packet.invoker == .Server {
            count += 1;
        }
    }

    expect(t, count == 64, "all unreliable datagrams arrived on loopback");
    _ = server_connection;
}

enet_large_reliable_packet_fragments :: (t: *Test) {
    x, server_connection := make_host_transport(t);
    defer enet_transport.destroy(*x);

    // Larger than one MTU: ENet fragments reliable packets itself.

    big := new_slice(u8, 32_768);
    {
        i := 0;
        while i < (big).count {
            defer i += 1;

            big[i] = (cast, trunc(u8)(i * 7 + 1));
        }
    }

    ok := enet_transport.send(*x, enet_transport.local_client_connection(*x), .Reliable, big);
    expect(t, ok, "large send");
    release(big);

    pump_until(t, *x, has_incoming, "fragmented receive");
    payload, found := find_incoming(*x, .Server, server_connection);
    expect(t, found, "fragmented incoming");
    expect_value(t, (payload).count, 32_768);
    {
        i := 0;
        while i < (payload).count {
            defer i += 1;

            if payload[i] != (cast, trunc(u8)(i * 7 + 1)) {
                expect(t, false, "fragment payload mismatch");
                return;
            }
        }
    }
}

enet_is_own_client_connection :: (t: *Test) {
    x, server_connection := make_host_transport(t);
    defer enet_transport.destroy(*x);

    // The loopback peer is this transport's own client half.

    expect(t, enet_transport.is_own_client_connection(*x, server_connection), "loopback peer is own client");
    // A bogus id answers false rather than guessing.

    expect(t, !enet_transport.is_own_client_connection(*x, (cast(transport.Connection_Id) (9999))), "unknown id is not own client");
}

enet_kick_now :: (t: *Test) {
    x, server_connection := make_host_transport(t);
    defer enet_transport.destroy(*x);

    result := enet_transport.kick_now(*x, server_connection);
    expect(t, result == .Success, "kick_now succeeds");
    expect(t, enet_transport.server_connection_count(*x) == 0, "connection dropped");

    // Second kick on the same id: invalid connection.

    result = enet_transport.kick_now(*x, server_connection);
    expect(t, result == .Invalid_Connection, "second kick rejected");

    // Sends to the removed connection fail.

    ok := enet_transport.send(*x, server_connection, .Reliable, u8.[#char "x"]);
    expect(t, !ok, "send to removed connection fails");
    expect(t, enet_transport.error_of(*x) == .Unknown_Connection, "Unknown_Connection reported");
}

enet_parse_ipv4 :: (t: *Test) {
    host, ok := enet_transport.parse_ipv4("127.0.0.1");
    expect(t, ok, "127.0.0.1 parses");
    expect(t, host == ENET_LOOPBACK_HOST, "127.0.0.1 value");

    host, ok = enet_transport.parse_ipv4("192.168.1.100");
    expect(t, ok, "192.168.1.100 parses");
    expect(t, host == ENET_LAN_HOST, "192.168.1.100 value");

    _, ok = enet_transport.parse_ipv4("256.1.1.1");
    expect(t, !ok, "octet overflow rejected");

    _, ok = enet_transport.parse_ipv4("1.2.3");
    expect(t, !ok, "short address rejected");

    _, ok = enet_transport.parse_ipv4("a.b.c.d");
    expect(t, !ok, "non-numeric rejected");
}

// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
