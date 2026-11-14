#scope_file
session :: #import "thirdparty/onet/session";
transport :: #import "thirdparty/onet/transport";
enet :: #import "thirdparty/onet/transport/enet";
#scope_export

//@region 鉴权会话fixture

Auth_Result :: struct {
    public_hits, private_hits, extension_hits, violations, ticks: int;
}

auth_public :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    ((cast(*Auth_Result) s.userdata)).public_hits += 1;
}

auth_private :: (s: *session.Session, from: transport.Connection_Id, payload: [] u8) {
    ((cast(*Auth_Result) s.userdata)).private_hits += 1;
}

auth_extension :: (s: *session.Session, from: transport.Connection_Id, side: transport.Invoker, channel: transport.Channel, payload: [] u8) {
    ((cast(*Auth_Result) s.userdata)).extension_hits += 1;
}

auth_violation :: (s: *session.Session, from: transport.Connection_Id, v: session.Violation) -> session.Violation_Action {
    ((cast(*Auth_Result) s.userdata)).violations += 1;
    return .Drop;
}

auth_tick :: (s: *session.Session) {
    ((cast(*Auth_Result) s.userdata)).ticks += 1;
}

auth_pump :: (s, c: *session.Session, count := 30) {
    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;
            session.update(s, 5);
            session.update(c, 5);
            sleep_milliseconds(1);
        }
    }
}

auth_pending :: (s: *session.Session) -> *session.Client_Info {
    for info, _: s.clients {
        if info != null {
            return info;
        }
    }

    return null;
}

//@endregion
//@region 真实消息路径

auth_preauth_isolation_generation_and_limits :: (t: *Test) {
    sx, cx: enet.Transport;
    defer {
        enet.destroy(*sx);
        enet.destroy(*cx);
    }

    s, c: session.Session;
    test_session(*s, *sx);
    test_session(*c, *cx);
    defer session.destroy(*s);
    defer session.destroy(*c);
    result: Auth_Result;
    s.userdata = *result;
    s.require_authentication = true;
    s.limits.authentication_timeout_ms = 100000;
    s.on_violation = auth_violation;
    session.register_handler(*s, 801, auth_public, false);
    session.register_handler(*s, 802, auth_private);
    session.register_extension(*s, 803, auth_extension);
    expect(t, session.start_server(*s, 0));
    expect(t, session.start_client(*c, "127.0.0.1", session.bound_port(*s)));
    auth_pump(*s, *c);
    info := auth_pending(*s);
    if !expect(t, info != null, "pending connection exists") {
        return;
    }

    expect(t, info.state == .Pending && session.connection_count(*s) == 0 && !c.client_authenticated);
    expect(t, !session.approve_client(*s, info.id, info.generation + 1, "account"));
    expect(t, session.send_to_server(*c, 801, u8.[1]));
    expect(t, session.send_to_server(*c, 802, u8.[1]));
    expect(t, session.send_extension(*c, session.local_connection(*c), 803, u8.[1]));
    auth_pump(*s, *c);
    expect_value(t, result.public_hits, 1);
    expect_value(t, result.private_hits, 0);
    expect_value(t, result.extension_hits, 0);
    expect(t, result.violations >= 2);
    expect(t, session.approve_client(*s, info.id, info.generation, "verified-account"));
    expect(t, !session.approve_client(*s, info.id, info.generation, "again"));
    auth_pump(*s, *c);
    expect(t, c.client_authenticated && c.client_generation == info.generation && c.client_server_id == info.id);
    expect_value(t, info.identity, "verified-account");
    expect(t, session.send_to_server(*c, 802, u8.[1]));
    auth_pump(*s, *c);
    expect_value(t, result.private_hits, 1);
    s.limits.packets_per_second = 1;
    info.window_ms = s.clock_ms;
    info.packets, info.bytes = 0, 0;
    {
        loop_index := 0;
        while loop_index < 3 {
            defer loop_index += 1;
            session.send_to_server(*c, 802, u8.[1]);
        }
    }

    auth_pump(*s, *c, 5);
    expect_value(t, result.private_hits, 2);
    expect(t, result.violations >= 4, "rate limit runs before dispatch");
    s.limits.max_packet_bytes = 8;
    s.limits.packets_per_second = 0;
    payload: [20] u8;
    expect(t, session.send_to_server(*c, 802, view(payload, 0)));
    auth_pump(*s, *c, 5);
    expect_value(t, result.private_hits, 2);
}

auth_pending_timeout_denies_and_fixed_catchup_is_bounded :: (t: *Test) {
    sx, cx: enet.Transport;
    defer {
        enet.destroy(*sx);
        enet.destroy(*cx);
    }

    s, c: session.Session;
    test_session(*s, *sx, 10);
    test_session(*c, *cx);
    defer session.destroy(*s);
    defer session.destroy(*c);
    result: Auth_Result;
    s.userdata, s.on_tick = *result, auth_tick;
    s.require_authentication = true;
    s.limits.authentication_timeout_ms = 100000;
    expect(t, session.start_server(*s, 0));
    expect(t, session.start_client(*c, "127.0.0.1", session.bound_port(*s)));
    auth_pump(*s, *c);
    info := auth_pending(*s);
    if !expect(t, info != null) {
        return;
    }

    id, generation := info.id, info.generation;
    s.limits.authentication_timeout_ms = 1;
    auth_pump(*s, *c);
    expect(t, !c.client_authenticated && session.connection_count(*s) == 0);
    expect(t, !session.approve_client(*s, id, generation, "late"));
    before := result.ticks;
    session.update(*s, 1000);
    expect_value(t, result.ticks - before, 2);
    expect(t, s.accumulator_ms < s.tick_interval_ms);
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
