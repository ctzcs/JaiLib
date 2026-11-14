#scope_file
session :: #import "thirdparty/onet/session";
sim :: #import "thirdparty/onet/simulation";
transport :: #import "thirdparty/onet/transport";
enet :: #import "thirdparty/onet/transport/enet";
memory :: #import "thirdparty/onet/transport/memory";
udp :: #import "thirdparty/onet/transport/udp";
#scope_export
// 后端一致性测试：每个后端跑同一组 Session 级用例。新后端加入 CF_Kind 后必须全部通过。
//@region 后端工厂与夹具

CF_Kind :: enum {
    ENet;
    UDP4;
    UDP6;
    Memory;
    Memory_Reliable_Only;
}

CF_RELIABLE :: (cast(session.Message_Id) (301));
CF_UNRELIABLE :: (cast(session.Message_Id) (302));

CF_Peer :: struct {
    kind: CF_Kind;

    enet: enet.Transport;

    udp: udp.Transport;

    mem: memory.Transport;

    s: session.Session;

    connected, disconnected, joined, left: int;

    reason: session.Server_Disconnect_Reason;

    reliable: [..] u32;

    unreliable: int;
}

cf_on_connected :: (s: *session.Session) {
    ((cast(*CF_Peer) s.userdata)).connected += 1;
}

cf_on_disconnected :: (s: *session.Session, reason: session.Server_Disconnect_Reason) {
    p := (cast(*CF_Peer) s.userdata);
    p.disconnected += 1;
    p.reason = reason;
}

cf_on_joined :: (s: *session.Session, id: transport.Connection_Id) {
    ((cast(*CF_Peer) s.userdata)).joined += 1;
}

cf_on_left :: (s: *session.Session, id: transport.Connection_Id) {
    ((cast(*CF_Peer) s.userdata)).left += 1;
}

cf_on_reliable :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    at := 0;
    n, _ := sim.state_get_u32(payload, *at);
    array_add(*((cast(*CF_Peer) s.userdata)).reliable, n);
}

cf_on_unreliable :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    ((cast(*CF_Peer) s.userdata)).unreliable += 1;
}

// 调用方保证 p 与 hub 地址稳定；hub 只被内存后端使用。

cf_init :: (p: *CF_Peer, kind: CF_Kind, hub: *memory.Hub) {
    p.kind = kind;
    session.init(*p.s, 10);
    d: transport.Driver;
    if kind == {
        case .ENet;
            enet.init(*p.enet);
            d = enet.driver(*p.enet);
        case .UDP4, .UDP6;
            cfg := udp.default_config();
            if kind == .UDP6 {
                cfg.family = .IPv6;
            }

            assert(udp.init(*p.udp, cfg));
            d = udp.driver(*p.udp);
        case .Memory, .Memory_Reliable_Only;
            cfg := memory.Config.{
                identity = "cf",
            };

            if kind == .Memory_Reliable_Only {
                cfg.reliable_only, cfg.max_message = true, 4096;
            }

            memory.init(*p.mem, hub, cfg);
            d = memory.driver(*p.mem);
    }

    assert(session.set_driver(*p.s, d));
    p.s.userdata = p;
    p.s.on_server_connected, p.s.on_server_disconnected = cf_on_connected, cf_on_disconnected;
    p.s.on_client_connected, p.s.on_client_disconnected = cf_on_joined, cf_on_left;
    p.s.limits.connect_timeout_ms = 2000;
    session.register_handler(*p.s, CF_RELIABLE, cf_on_reliable);
    session.register_handler(*p.s, CF_UNRELIABLE, cf_on_unreliable);
}

cf_destroy :: (p: *CF_Peer) {
    session.destroy(*p.s);
    if p.kind == {
        case .ENet; enet.destroy(*p.enet);
        case .UDP4, .UDP6; udp.destroy(*p.udp);
        case .Memory, .Memory_Reliable_Only; memory.destroy(*p.mem);
    }

    release(p.reliable);
}

cf_address :: (kind: CF_Kind) -> string {
    if kind == {
        case .UDP6; return "::1";
        case .Memory, .Memory_Reliable_Only; return memory.ADDRESS;
        case .ENet, .UDP4;
    }

    return "127.0.0.1";
}

cf_step :: (peers: [] *CF_Peer, count := 1) {
    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;

            for p: peers {
                session.update(*p.s, 5);
            }

            sleep_milliseconds(1);
        }
    }
}

cf_until :: (peers: [] *CF_Peer, done: #type (user: *void) -> bool, user: *void, limit := 3000) -> bool {
    {
        loop_index := 0;
        while loop_index < limit {
            defer loop_index += 1;

            cf_step(peers);
            if done(user) {
                return true;
            }
        }
    }

    return false;
}

cf_is_connected :: (user: *void) -> bool {
    return ((cast(*CF_Peer) user)).s.client_authenticated;
}

cf_is_disconnected :: (user: *void) -> bool {
    return ((cast(*CF_Peer) user)).disconnected > 0;
}

// 启动服务器并连上一个客户端。

cf_pair :: (t: *Test, s, c: *CF_Peer) -> bool {
    if !expectf(t, session.start_server(*s.s, 0), "%v server", s.kind) {
        return false;
    }

    expectf(t, session.start_client(*c.s, cf_address(c.kind), session.bound_port(*s.s)), "%v client", c.kind);
    return expectf(t, cf_until(.[
    s, c
    ], cf_is_connected, c), "%v connected", c.kind);
};

cf_u32 :: (n: u32) -> [4] u8 {
    b: [4] u8;
    at := 0;
    sim.state_put_u32(view(b, 0), *at, n);
    return b;
}

//@endregion
//@region 用例

conformance_connect_and_reliable_order :: (t: *Test) {
    for enum_value: (cast(*Type_Info_Enum) type_info(CF_Kind)).values {
        kind := cast(CF_Kind) enum_value;

        hub: memory.Hub;
        memory.hub_init(*hub);
        s, c: CF_Peer;
        cf_init(*s, kind, *hub);
        cf_init(*c, kind, *hub);
        if cf_pair(t, *s, *c) {
            expectf(t, c.connected == 1 && s.joined == 1 && session.connection_count(*s.s) == 1, "%v connect events", kind);
            // 契约：send 返回 true 的可靠帧按序到达。后端可以因发送窗口满而暂时拒绝，
            // 所以按批发送并只核对成功发出的序号。

            up, down: [..] u32;
            {
                i := 0;
                while i < 100 {
                    defer i += 1;

                    b := cf_u32((cast, trunc(u32)(i)));
                    if session.send_to_server(*c.s, CF_RELIABLE, view(b, 0)) {
                        array_add(*up, (cast, trunc(u32)(i)));
                    }

                    if session.broadcast_message(*s.s, CF_RELIABLE, view(b, 0)) {
                        array_add(*down, (cast, trunc(u32)(i)));
                    }

                    if i % 5 == 4 {
                        cf_step(.[
                        *s, *c
                        ]);
                    };
                }
            }

            cf_step(.[
           *s, *c
           ], 200);
            ok := (up).count == 100 && (down).count == 100 && (s.reliable).count == (up).count && (c.reliable).count == (down).count;
            for n, i: s.reliable {
                ok = ok && i < (up).count && n == up[i];
            }

            for n, i: c.reliable {
                ok = ok && i < (down).count && n == down[i];
            }

            expectf(t, ok, "%v reliable order (sent %d/%d, got %d/%d)", kind, (up).count, (down).count, (s.reliable).count, (c.reliable).count);
            release(up);
            release(down);
        };

        cf_destroy(*s);
        cf_destroy(*c);
        memory.hub_destroy(*hub);
    }
}

conformance_unreliable_and_message_limits :: (t: *Test) {
    for enum_value: (cast(*Type_Info_Enum) type_info(CF_Kind)).values {
        kind := cast(CF_Kind) enum_value;

        hub: memory.Hub;
        memory.hub_init(*hub);
        s, c: CF_Peer;
        cf_init(*s, kind, *hub);
        cf_init(*c, kind, *hub);
        if cf_pair(t, *s, *c) {
            d := session.driver_view(*c.s);
            caps := transport.capabilities(d);
            id := session.local_connection(*c.s);
            small := u8.[1];
            if caps.unreliable {
                {
                    loop_index := 0;
                    while loop_index < 20 {
                        defer loop_index += 1;
                        session.send_to_server(*c.s, CF_UNRELIABLE, view(small, 0), .Unreliable);
                    }
                }

                cf_step(.[
               *s, *c
               ], 100);
                expectf(t, s.unreliable == 20, "%v unreliable delivered %d", kind, s.unreliable);
                buf := new_slice(u8, caps.max_unreliable + 1);
                expectf(t, transport.send(d, id, .Unreliable, view(buf, 0, caps.max_unreliable)), "%v unreliable at limit", kind);
                expectf(t, !transport.send(d, id, .Unreliable, buf), "%v unreliable over limit", kind);
                release(buf);
            } else {
                expectf(t, caps.max_unreliable == 0 && !transport.send(d, id, .Unreliable, view(small, 0)), "%v unreliable refused, not silently reliable", kind);
            }

            session.set_network_conditions(*c.s, .{
                seed = 1
            });
            expectf(t, transport.capabilities(session.driver_view(*c.s)) == caps, "%v conditioner forwards capabilities", kind);
            buf := new_slice(u8, caps.max_message + 1);
            expectf(t, transport.send(d, id, .Reliable, view(buf, 0, caps.max_message)), "%v reliable at limit", kind);
            expectf(t, !transport.send(d, id, .Reliable, buf), "%v reliable over limit", kind);
            release(buf);
        };

        cf_destroy(*s);
        cf_destroy(*c);
        memory.hub_destroy(*hub);
    };
}

conformance_disconnect_reasons :: (t: *Test) {
    for enum_value: (cast(*Type_Info_Enum) type_info(CF_Kind)).values {
        kind := cast(CF_Kind) enum_value;

        hub: memory.Hub;
        memory.hub_init(*hub);
        // Connect_Failed：空闲端口（先监听再关闭得到）。

        {
            probe, c: CF_Peer;
            cf_init(*probe, kind, *hub);
            cf_init(*c, kind, *hub);
            expect(t, session.start_server(*probe.s, 0));
            port := session.bound_port(*probe.s);
            session.shutdown(*probe.s);
            c.s.limits.connect_timeout_ms = 300;
            expect(t, session.start_client(*c.s, cf_address(kind), port));
            expectf(t, cf_until(.[
            *c
            ], cf_is_disconnected, *c) && c.reason == .Connect_Failed && c.connected == 0, "%v connect failed: %v", kind, c.reason);
            cf_destroy(*probe);
            cf_destroy(*c);
        };

        // Local 与 Lost（服务器关闭）。

        {
            s, a, b: CF_Peer;
            cf_init(*s, kind, *hub);
            cf_init(*a, kind, *hub);
            cf_init(*b, kind, *hub);
            if cf_pair(t, *s, *a) {
                expect(t, session.start_client(*b.s, cf_address(kind), session.bound_port(*s.s)));
                expectf(t, cf_until(.[
                *s, *a, *b
                ], cf_is_connected, *b), "%v second client", kind);
                session.disconnect_local(*a.s);
                expectf(t, cf_until(.[
                *s, *a, *b
                ], cf_is_disconnected, *a) && a.reason == .Local, "%v local: %v", kind, a.reason);
                cf_step(.[
                *s, *a, *b
                ], 50);
                expectf(t, s.left == 1, "%v server saw local disconnect (%d)", kind, s.left);
                session.shutdown(*s.s);
                expectf(t, cf_until(.[
                *b
                ], cf_is_disconnected, *b) && b.reason == .Lost, "%v lost on server shutdown: %v", kind, b.reason);
                expect_value(t, a.disconnected, 1);
            };

            cf_destroy(*s);
            cf_destroy(*a);
            cf_destroy(*b);
        };

        // Lost（被踢）与 Denied。

        {
            s, a, b: CF_Peer;
            cf_init(*s, kind, *hub);
            cf_init(*a, kind, *hub);
            cf_init(*b, kind, *hub);
            if cf_pair(t, *s, *a) {
                session.kick(*s.s, a.s.client_server_id);
                expectf(t, cf_until(.[
                *s, *a
                ], cf_is_disconnected, *a) && a.reason == .Lost, "%v kicked: %v", kind, a.reason);
                s.s.require_authentication = true;
                s.s.on_client_connecting = (s: *session.Session, id: transport.Connection_Id, generation: u64) {
                    session.deny_client(s, id, generation);
                }

                expect(t, session.start_client(*b.s, cf_address(kind), session.bound_port(*s.s)));
                expectf(t, cf_until(.[
                *s, *b
                ], cf_is_disconnected, *b) && b.reason == .Denied, "%v denied: %v", kind, b.reason);
            };

            cf_destroy(*s);
            cf_destroy(*a);
            cf_destroy(*b);
        };

        memory.hub_destroy(*hub);
    }
}

conformance_host_mode_and_reconnect_ids :: (t: *Test) {
    for enum_value: (cast(*Type_Info_Enum) type_info(CF_Kind)).values {
        kind := cast(CF_Kind) enum_value;

        hub: memory.Hub;
        memory.hub_init(*hub);
        h, c: CF_Peer;
        cf_init(*h, kind, *hub);
        cf_init(*c, kind, *hub);
        // 先监听再关闭拿到空闲端口，验证 host 可监听指定端口。

        probe: CF_Peer;
        cf_init(*probe, kind, *hub);
        session.start_server(*probe.s, 0);
        port := session.bound_port(*probe.s);
        cf_destroy(*probe);
        if expectf(t, session.start_host(*h.s, 8, port), "%v host", kind) {
            expectf(t, session.bound_port(*h.s) == port, "%v host on fixed port", kind);
            expect(t, session.start_client(*c.s, cf_address(kind), port));
            expectf(t, cf_until(.[
            *h, *c
            ], cf_is_connected, *c) && cf_until(.[
            *h, *c
            ], cf_is_connected, *h), "%v host and remote connected", kind);
            expectf(t, session.connection_count(*h.s) == 2 && h.connected == 1, "%v host connections %d", kind, session.connection_count(*h.s));
            old_id, old_generation := c.s.client_server_id, c.s.client_generation;
            session.disconnect_local(*c.s);
            expect(t, cf_until(.[
            *h, *c
            ], cf_is_disconnected, *c));
            cf_step(.[
            *h, *c
            ], 20);
            expectf(t, session.stop_client(*c.s), "%v stop client", kind);
            expect(t, session.start_client(*c.s, cf_address(kind), session.bound_port(*h.s)));
            expectf(t, cf_until(.[
            *h, *c
            ], cf_is_connected, *c), "%v reconnected", kind);
            expectf(t, c.s.client_server_id != old_id && c.s.client_generation != old_generation, "%v ids not reused", kind);
        };

        cf_destroy(*h);
        cf_destroy(*c);
        memory.hub_destroy(*hub);
    };
};

CF_Run :: struct {
    stats: transport.Conditioner_Stats;
    unreliable, reliable: int;
    ordered: bool;
}

conformance_conditions_identical_across_backends :: (t: *Test) {
    runs: [5] CF_Run;
    for enum_value: (cast(*Type_Info_Enum) type_info(CF_Kind)).values {
        kind := cast(CF_Kind) enum_value;

        if kind == .Memory_Reliable_Only {
            continue;
        }

        hub: memory.Hub;
        memory.hub_init(*hub);
        s, c: CF_Peer;
        cf_init(*s, kind, *hub);
        cf_init(*c, kind, *hub);
        if cf_pair(t, *s, *c) {
            session.set_network_conditions(*c.s, .{
                seed = 7, loss_permille = 150, duplicate_permille = 100, reorder_permille = 100, latency_ms = 20, jitter_ms = 5, reorder_ms = 10
            });
            small := u8.[1];
            {
                i := 0;
                while i < 100 {
                    defer i += 1;

                    session.send_to_server(*c.s, CF_UNRELIABLE, view(small, 0), .Unreliable);
                    if i % 4 == 0 {
                        b := cf_u32((cast, trunc(u32)(i / 4)));
                        session.send_to_server(*c.s, CF_RELIABLE, view(b, 0));
                    }
                }
            };

            cf_step(.[
           *s, *c
           ], 150);
            ordered := (s.reliable).count == 25;
            for n, i: s.reliable {
                ordered = ordered && n == (cast, trunc(u32)(i));
            }

            runs[cast(int) kind] = .{
                c.s.conditioner.stats, s.unreliable, (s.reliable).count, ordered,
            };

            r := runs[cast(int) kind];
            expectf(t, r.ordered && r.unreliable == 100 - (cast(int) (r.stats.dropped)) + (cast(int) (r.stats.duplicated)), "%v conditioned delivery %v", kind, r);
        };

        cf_destroy(*s);
        cf_destroy(*c);
        memory.hub_destroy(*hub);
    }

    for enum_value: (cast(*Type_Info_Enum) type_info(CF_Kind)).values {
        kind := cast(CF_Kind) enum_value;

        if kind == .Memory_Reliable_Only || kind == .ENet {
            continue;
        }

        expectf(t, runs[cast(int) kind] == runs[cast(int) CF_Kind.ENet], "%v matches ENet: %v vs %v", kind, runs[cast(int) kind], runs[cast(int) CF_Kind.ENet]);
    }
}

//@endregion
//@region 连接质量

conformance_connection_quality :: (t: *Test) {
    for enum_value: (cast(*Type_Info_Enum) type_info(CF_Kind)).values {
        kind := cast(CF_Kind) enum_value;

        hub: memory.Hub;
        memory.hub_init(*hub);
        s, c: CF_Peer;
        cf_init(*s, kind, *hub);
        cf_init(*c, kind, *hub);
        if cf_pair(t, *s, *c) {
            {
                i := 0;
                while i < 20 {
                    defer i += 1;
                    b := cf_u32((cast, trunc(u32)(i)));
                    session.send_to_server(*c.s, CF_RELIABLE, view(b, 0));
                    cf_step(.[
                    *s, *c
                    ]);
                }
            };

            cf_step(.[
           *s, *c
           ], 20);
            caps := transport.capabilities(session.driver_view(*c.s));
            q, ok := session.connection_quality(*c.s, session.local_connection(*c.s));
            sq, sok := session.connection_quality(*s.s, c.s.client_server_id);
            expectf(t, ok == caps.connection_quality && sok == caps.connection_quality, "%v quality reported iff capable", kind);
            if ok {
                expectf(t, q.rtt_ms >= 0 && q.loss >= 0 && q.loss <= 1 && q.retransmits >= 0 && q.pending_bytes >= 0, "%v client quality %v", kind, q);
                expectf(t, sq.loss >= 0 && sq.loss <= 1 && sq.retransmits >= 0, "%v server quality %v", kind, sq);
            }

            _, unknown := session.connection_quality(*s.s, 0xFFFF);
            expectf(t, !unknown, "%v unknown connection has no quality", kind);
        };

        cf_destroy(*s);
        cf_destroy(*c);
        memory.hub_destroy(*hub);
    }
}

// 原生 UDP 的 RTT 来自协议 ACK：用它自带的模拟器给客户端出站加 40 ms 延迟、30% 丢包。

udp_connection_quality_tracks_latency_and_loss :: (t: *Test) {
    sx, cx: udp.Transport;
    ccfg := udp.default_config();
    ccfg.conditions = .{
        seed = 3, latency_ms = 40, loss_permille = 300,
    };

    expect(t, udp.init(*sx, udp.default_config()) && udp.init(*cx, ccfg));
    defer {
        udp.destroy(*sx);
        udp.destroy(*cx);
    }

    s, c: session.Session;
    session.init(*s, 10);
    session.init(*c, 10);
    defer {
        session.destroy(*s);
        session.destroy(*c);
    }

    expect(t, session.set_driver(*s, udp.driver(*sx)) && session.set_driver(*c, udp.driver(*cx)));
    expect(t, session.start_server(*s, 0) && session.start_client(*c, "127.0.0.1", session.bound_port(*s)));
    {
        i := 0;
        while i < 5000 && !c.client_authenticated {
            defer i += 1;
            session.update(*s, 2);
            session.update(*c, 2);
            sleep_milliseconds(1);
        }
    }

    if !expect(t, c.client_authenticated, "connected through loss") {
        return;
    }

    payload := u8.[];
    {
        loop_index := 0;
        while loop_index < 300 {
            defer loop_index += 1;

            session.send_to_server(*c, CF_RELIABLE, view(payload, 0));
            session.update(*s, 2);
            session.update(*c, 2);
            sleep_milliseconds(1);
        }
    }

    q, ok := session.connection_quality(*c, session.local_connection(*c));
    expectf(t, ok && q.rtt_ms >= 30 && q.rtt_ms < 400, "rtt follows simulated latency: %v", q);
    expectf(t, q.retransmits > 0 && q.loss > 0.05, "loss and retransmits observed: %v", q);
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.

operator == :: (a: CF_Run, b: CF_Run) -> bool {
    return a.stats.sent == b.stats.sent && a.stats.delayed == b.stats.delayed && a.stats.dropped == b.stats.dropped && a.stats.duplicated == b.stats.duplicated && a.stats.reordered == b.stats.reordered && a.unreliable == b.unreliable && a.reliable == b.reliable && a.ordered == b.ordered;
}

operator == :: (a: transport.Capabilities, b: transport.Capabilities) -> bool {
    return a.max_message == b.max_message && a.max_unreliable == b.max_unreliable && a.unreliable == b.unreliable && a.local_pair == b.local_pair && a.remote_identity == b.remote_identity && a.connection_quality == b.connection_quality;
}
