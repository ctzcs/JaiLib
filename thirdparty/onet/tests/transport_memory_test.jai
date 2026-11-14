#scope_file
transport :: #import "thirdparty/onet/transport";
memory :: #import "thirdparty/onet/transport/memory";
#scope_export
// 内存回环后端的直接行为：握手、按序送达、本地连接对、身份与拒绝。

mem_poll :: (ts: ..*memory.Transport) {
    {
        loop_index := 0;
        while loop_index < 3 {
            defer loop_index += 1;
            for t: ts {
                memory.poll(t);
            }
        }
    }
}

transport_memory_handshake_order_identity_and_close :: (t: *Test) {
    hub: memory.Hub;
    memory.hub_init(*hub);
    defer memory.hub_destroy(*hub);
    s, c: memory.Transport;
    memory.init(*s, *hub, .{
        identity = "server"
    });
    memory.init(*c, *hub, .{
        identity = "alice"
    });
    defer {
        memory.destroy(*s);
        memory.destroy(*c);
    }

    expect(t, !memory.start_client(*c, "127.0.0.1", 1), "non-memory address rejected");
    expect(t, memory.start_server(*s, 0, 1));
    port := memory.bound_port(*s);
    expect(t, memory.start_client(*c, "mem", port));
    mem_poll(*s, *c);
    if !expect(t, memory.client_is_connected(*c), "client connected") {
        return;
    }

    server_id := memory.state_changes_view(*s)[0].connection;
    expect_value(t, memory.remote_identity(*s, server_id), "alice");
    expect_value(t, memory.remote_identity(*c, memory.local_connection(*c)), "server");

    {
        i := 0;
        while i < 5 {
            defer i += 1;

            b := u8.[(cast, trunc(u8)(i))];
            expect(t, memory.send(*c, memory.local_connection(*c), (ifx i % 2 == 0 then .Reliable else .Unreliable), view(b, 0)));
        }
    };

    mem_poll(*s);
    packets := memory.incoming_packets(*s);
    if expect_value(t, (packets).count, 5) {
        for p, i: packets {
            expect_value(t, p.payload[0], (cast, trunc(u8)(i)));
        }
    }

    // 满员时第二个客户端被拒绝。

    d: memory.Transport;
    memory.init(*d, *hub);
    defer memory.destroy(*d);
    expect(t, memory.start_client(*d, "mem", port));
    mem_poll(*s, *d);
    expect(t, !memory.client_is_connected(*d) && memory.local_connection(*d) == 0, "full server rejects");

    // 服务器关闭后客户端收到断开。

    memory.clear_state_changes(*c);
    memory.shutdown(*s);
    mem_poll(*c);
    changes := memory.state_changes_view(*c);
    expect(t, (changes).count == 1 && changes[0].kind == .Disconnected && !memory.client_is_connected(*c));
};

transport_memory_local_pair_and_limits :: (t: *Test) {
    hub: memory.Hub;
    memory.hub_init(*hub);
    defer memory.hub_destroy(*hub);
    h: memory.Transport;
    memory.init(*h, *hub, .{
        max_message = 16, reliable_only = true
    });
    defer memory.destroy(*h);
    d := memory.driver(*h);
    caps := transport.capabilities(d);
    expect(t, caps.local_pair && caps.remote_identity && !caps.unreliable && caps.max_unreliable == 0 && caps.max_message == 16);
    expect(t, !transport.open_local_pair(d), "pair needs a running server");
    expect(t, transport.start_server(d, 7, 4));
    expect(t, transport.open_local_pair(d));
    transport.poll(d);
    expect(t, transport.client_is_connected(d), "local pair connected in one poll");
    expect_value(t, (transport.state_changes_view(d)).count, 2);
    buf: [17] u8;
    id := transport.local_connection(d);
    expect(t, transport.send(d, id, .Reliable, view(buf, 0, 16)));
    expect(t, !transport.send(d, id, .Reliable, view(buf, 0)), "over max_message");
    expect(t, !transport.send(d, id, .Unreliable, view(buf, 0, 1)), "reliable-only backend");
    transport.poll(d);
    expect_value(t, (transport.incoming_packets(d)).count, 1);
};

// Cast semantics adapted.
// Loop scopes adapted.
// Iterator semantics adapted.
