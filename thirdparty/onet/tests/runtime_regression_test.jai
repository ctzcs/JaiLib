#scope_file
session :: #import "thirdparty/onet/session";
transport :: #import "thirdparty/onet/transport";
enet :: #import "thirdparty/onet/transport/enet";
wire :: #import "thirdparty/onet/wire";
#scope_export

//@region 审查缺陷回归

kick_batch :: (s: *session.Session, from: transport.Connection_Id, v: session.Violation) -> session.Violation_Action {
    ((cast(*Auth_Result) s.userdata)).violations += 1;
    return .Kick;
}

kick_immediately_revokes_auth_for_remaining_polled_packets :: (t: *Test) {
    x: enet.Transport;
    defer enet.destroy(*x);
    s: session.Session;
    test_session(*s, *x);
    defer session.destroy(*s);
    result: Auth_Result;
    s.userdata, s.on_violation = *result, kick_batch;
    info := new_one(session.Client_Info);
    info.* = .{
        id = 7, generation = 1, state = .Approved,
    };

    H.table_set(*s.clients, 7, info);
    array_add(*s.connections, 7);
    session.register_handler(*s, 802, auth_private);
    // 模拟同次poll已持有两个包：第一个触发Kick，第二个原本有写权限。

    array_add(*x.incoming, transport.Incoming_Packet.{
        connection = 7, invoker = .Server, channel = .Reliable, payload = wire.clone(u8.[255])
    });
    array_add(*x.incoming, transport.Incoming_Packet.{
        connection = 7, invoker = .Server, channel = .Reliable, payload = wire.clone(u8.[1, 0x03, 0x22, 1])
    });
    session.update(*s, 0);
    expect_value(t, result.violations, 1);
    expect_value(t, result.private_hits, 0);
    expect(t, !session.is_authenticated(*s, 7) && session.connection_count(*s) == 0);
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
