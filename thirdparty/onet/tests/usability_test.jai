#scope_file
core :: #import "thirdparty/onet/core";
objects :: #import "thirdparty/onet/objects";
rpc :: #import "thirdparty/onet/rpc";
nr :: #import "thirdparty/onet/runtime";
session :: #import "thirdparty/onet/session";
transport :: #import "thirdparty/onet/transport";
enet :: #import "thirdparty/onet/transport/enet";
wire :: #import "thirdparty/onet/wire";
#scope_export
// 游戏接入便捷 API：RPC 拒绝诊断、仅声明发送、参数包装、类型化组件与所有者查询。
//@region RPC 拒绝与声明

rpc_rejections_report_reason_and_count :: (t: *Test) {
    reg: objects.Registry;
    m: rpc.Manager;
    h: Rpc_Harness;
    rpc_harness_init(*m, *reg, *h, true);
    defer objects.registry_destroy(*reg);
    defer rpc.destroy(*m);
    defer rpc_harness_destroy(*h);
    // 拒绝原因按顺序记进 calls，发送方记进 senders。

    m.on_rejected = (m: *rpc.Manager, from: transport.Connection_Id, id: rpc.Id, object: objects.Network_Id, reason: rpc.Reject_Reason) {
        h := (cast(*Rpc_Harness) m.userdata);
        array_add(*h.senders, from);
        array_add(*h.calls, (cast, trunc(u8)(reason)));
    }

    array_add(*h.observers, 1);
    obj := objects.spawn(*reg, 1);
    payload := u8.[1];

    expect(t, rpc_deliver_call(*m, 1, .{
        sequence = 1, id = 1, object = obj.id + 100, target = .Server, payload = view(payload, 0)
    }));
    expect_value(t, m.rejected[cast(int) rpc.Reject_Reason.Unknown_Object], 1);
    expect(t, !rpc_deliver_call(*m, 2, .{
        sequence = 1, id = 1, object = obj.id, target = .Server, payload = view(payload, 0)
    }));
    expect_value(t, m.rejected[cast(int) rpc.Reject_Reason.Not_Observed], 1);
    array_add(*h.observers, 2);
    expect(t, !rpc_deliver_call(*m, 2, .{
        sequence = 2, id = 1, object = obj.id, target = .Server, payload = view(payload, 0)
    }));
    expect_value(t, m.rejected[cast(int) rpc.Reject_Reason.Not_Controller], 1);
    expect(t, !rpc_deliver_call(*m, 1, .{
        sequence = 2, id = 99, object = obj.id, target = .Server, payload = view(payload, 0)
    }));
    expect_value(t, m.rejected[cast(int) rpc.Reject_Reason.No_Handler], 1);
    expect(t, rpc_deliver_call(*m, 1, .{
        sequence = 3, id = 1, object = obj.id, target = .Server, payload = view(payload, 0)
    }));
    expect_value(t, (h.calls).count, 5); // 4 次拒绝 + 1 次 handler

    reasons: [] u8 = u8.[(cast, trunc(u8)(rpc.Reject_Reason.Unknown_Object)), (cast, trunc(u8)(rpc.Reject_Reason.Not_Observed)), (cast, trunc(u8)(rpc.Reject_Reason.Not_Controller)), (cast, trunc(u8)(rpc.Reject_Reason.No_Handler))];
    for reason, i: reasons {
        expect_value(t, h.calls[i], reason);
    }

    expect_value(t, h.senders[0], (cast(transport.Connection_Id) (1)));
    expect_value(t, h.senders[1], (cast(transport.Connection_Id) (2)));
};

rpc_declare_allows_client_send_without_handler :: (t: *Test) {
    reg: objects.Registry;
    m: rpc.Manager;
    h: Rpc_Harness;
    rpc_harness_init(*m, *reg, *h, false);
    defer objects.registry_destroy(*reg);
    defer rpc.destroy(*m);
    defer rpc_harness_destroy(*h);
    payload := u8.[3];
    expect(t, !rpc.send(*m, 20, 5, .Server, view(payload, 0)), "undeclared id rejected locally");
    rpc.declare(*m, 20);
    expect(t, rpc.send(*m, 20, 5, .Server, view(payload, 0)), "declared id can be sent");
    expect_value(t, (h.outputs).count, 1);
    expect_value(t, h.outputs[0].to, (cast(transport.Connection_Id) (7)));
    // declare 不覆盖已注册的 handler。

    rpc.declare(*m, 1);
    expect(t, table_get(*m.handlers, 1).handler != null && !table_get(*m.handlers, 1).declared);
}

Rpc_Move :: struct {
    dir: [2] float32;
    dash: u8;
}

rpc_write_move :: (w: *core.Writer, user: *void) {
    move := (cast(*Rpc_Move) user);
    core.write_bits(w, (cast, trunc(u64)(bit_cast(u32, move.dir[0]))), 32);
    core.write_bits(w, (cast, trunc(u64)(bit_cast(u32, move.dir[1]))), 32);
    core.write_uint8(w, move.dash, .Uncompressed);
}

rpc_send_with_round_trips_through_reader :: (t: *Test) {
    reg: objects.Registry;
    m: rpc.Manager;
    h: Rpc_Harness;
    rpc_harness_init(*m, *reg, *h, false);
    defer objects.registry_destroy(*reg);
    defer rpc.destroy(*m);
    defer rpc_harness_destroy(*h);
    move := Rpc_Move.{
        .[
        0.5, -1,
        ], 3,
    }

    expect(t, rpc.send_with(*m, 1, 5, .Server, rpc_write_move, *move));
    if !expect_value(t, (h.outputs).count, 1) {
        return;
    }

    call, ok := rpc.decode(h.outputs[0].data);
    defer release(call.payload);
    expect(t, ok);
    r := rpc.reader(call.payload);
    x := bit_cast(float32, (cast, trunc(u32)(core.read_bits(*r, 32))));
    y := bit_cast(float32, (cast, trunc(u32)(core.read_bits(*r, 32))));
    got := Rpc_Move.{
        .[
        x, y,
        ], core.read_uint8(*r, .Uncompressed),
    }

    expect(t, wire.finished(*r), "payload fully consumed");
    expect_value(t, got, move);
};

//@endregion
//@region 类型化组件与所有者

Owned_Value :: struct {
    value: s32;
}

owned_free :: (p: *void) {
    free((cast(*Owned_Value) p));
}

owned_spawn :: (reg: *objects.Registry, owner: transport.Connection_Id, type_id: objects.Component_Type_Id, value: s32) -> *objects.Network_Object {
    obj := objects.spawn(reg, owner);
    v := new_one(Owned_Value);
    v.value = value;
    c := objects.component_add(obj, type_id);
    c.userdata, c.destroy_userdata = v, owned_free;
    objects.member_i32(c, *v.value);
    return obj;
}

objects_component_data_and_owner_queries :: (t: *Test) {
    reg: objects.Registry;
    objects.registry_init(*reg);
    defer objects.registry_destroy(*reg);
    server := owned_spawn(*reg, objects.SERVER_OWNED, 5, 1);
    a := owned_spawn(*reg, 4, 5, 2);
    b := owned_spawn(*reg, 4, 6, 3);
    _ = owned_spawn(*reg, 9, 5, 4);

    expect_value(t, objects.component_data(a, Owned_Value, 5).value, 2);
    expect(t, objects.component_data(a, Owned_Value, 6) == null, "wrong type");
    expect(t, objects.component_data(null, Owned_Value, 5) == null, "null object");

    found, ok := objects.find_owned(*reg, 4);
    expect(t, ok && found == a, "lowest owned id");
    _, ok = objects.find_owned(*reg, objects.SERVER_OWNED);
    expect(t, !ok, "owner 0 never matches");
    _, ok = objects.find_owned(*reg, 77);
    expect(t, !ok, "unknown owner");

    ids: [..] objects.Network_Id;
    defer release(ids);
    objects.owned_by(*reg, 4, *ids);
    expect(t, (ids).count == 2 && ids[0] == a.id && ids[1] == b.id, "owned ids sorted");

    objects.despawn(*reg, a.id);
    expect(t, objects.component_data(a, Owned_Value, 5) == null, "despawned object");
    found, ok = objects.find_owned(*reg, 4);
    expect(t, ok && found == b, "despawned skipped");
    _ = server;
}

//@endregion
//@region 一次性关闭

runtime_close_finishes_shutdown_in_one_call :: (t: *Test) {
    s, a: RT_Node;
    rt_init(*s, true);
    rt_init(*a, false);
    nodes := (*RT_Node).[*s, *a];
    _ = rt_spawn(*s, 4);
    expect(t, session.start_server(*s.s, 0));
    expect(t, session.start_client(*a.s, "127.0.0.1", session.bound_port(*s.s)));
    rt_pump(nodes);
    expect(t, a.s.client_authenticated, "connected");
    for n: nodes {
        expect(t, nr.close(*n.r), "close");
        expect(t, !n.r.initialized, "runtime destroyed");
        expect(t, nr.close(*n.r), "close is idempotent");
        objects.registry_destroy(*n.reg);
        session.destroy(*n.s);
        enet.destroy(*n.backend);
    }
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.

operator == :: (a: Rpc_Move, b: Rpc_Move) -> bool {
    return a.dir == b.dir && a.dash == b.dash;
}
