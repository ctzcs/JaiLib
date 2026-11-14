#scope_file
core :: #import "thirdparty/onet/core";
objects :: #import "thirdparty/onet/objects";
rpc :: #import "thirdparty/onet/rpc";
nr :: #import "thirdparty/onet/runtime";
scenes :: #import "thirdparty/onet/scenes";
session :: #import "thirdparty/onet/session";
transport :: #import "thirdparty/onet/transport";
enet :: #import "thirdparty/onet/transport/enet";
#scope_export

//@region 独占多会话fixture

RT_Value :: struct {
    value: s32;
}

RT_Node :: struct {
    backend: enet.Transport;
    // rt_init 默认选择；需要别的后端时在启动前再 set_driver

    s: session.Session;

    reg, mirror: objects.Registry;

    r: nr.Runtime;

    hits: int;

    sender: transport.Connection_Id;

    ticket: scenes.Ticket;

    requests: int;
}

rt_free :: (p: *void) {
    free((cast(*RT_Value) p));
}

rt_factory :: () -> *objects.Component {
    v := new_one(RT_Value);
    c := objects.component_make(9901);
    c.userdata, c.destroy_userdata = v, rt_free;
    objects.member_i32(c, *v.value);
    return c;
}

rt_rpc :: (ctx: *rpc.Context, payload: [] u8) {
    n := (cast(*RT_Node) ctx.manager.userdata);
    n.hits += 1;
    n.sender = ctx.sender;
}

rt_carry :: (userdata: *void, old_scene, new_scene: scenes.Handle) -> bool {
    n := (cast(*RT_Node) userdata);
    return nr.carry_scene_objects(*n.r.server, old_scene, new_scene);
}

rt_loader :: (userdata: *void, ticket: scenes.Ticket) {
    n := (cast(*RT_Node) userdata);
    n.ticket = ticket;
    n.requests += 1;
    if ticket.operation == .Unload {
        m := (ifx n.r.client.initialized then *n.r.client.scenes else *n.r.server.scenes);
        scenes.complete_unload(m, ticket, true);
    }
}

rt_init :: (n: *RT_Node, authority: bool, host := false) {
    test_session(*n.s, *n.backend, 10);
    n.s.userdata = n;
    objects.registry_init(*n.reg, authority);
    objects.register_factory(*n.reg, 9901, rt_factory);
    config := nr.Config.{
    };

    if authority {
        config.server_registry = *n.reg;
    } else {
        config.client_registry = *n.reg;
    }

    config.server_scenes = .{
        userdata = n, request = rt_loader, carry = rt_carry, timeout_ms = 1000, resend_ms = 20,
    };

    config.client_scenes = config.server_scenes;
    if host {
        objects.registry_init(*n.mirror, false);
        objects.register_factory(*n.mirror, 9901, rt_factory);
        config.client_registry = *n.mirror;
    }

    assert(nr.init(*n.r, *n.s, config));
    for w: (*nr.World.[*n.r.server, *n.r.client]) {
        if w.initialized {
            w.rpc.userdata = n;
            rpc.register(*w.rpc, 71, rt_rpc, .Any_Observer);
        }
    }
}

rt_shutdown :: (nodes: [] *RT_Node) {
    for n: nodes {
        session.shutdown(*n.s);
        nr.shutdown(*n.r);
    }

    {
        loop_index := 0;
        while loop_index < 20 {
            defer loop_index += 1;
            for n: nodes {
                nr.update(*n.r, 10);
            }
        }
    }

    for n: nodes {
        assert(nr.destroy(*n.r));
        objects.registry_destroy(*n.reg);
        {
            objects.registry_destroy(*n.mirror);
        }

        session.destroy(*n.s);
        enet.destroy(*n.backend);
    }
}

rt_pump :: (nodes: [] *RT_Node, count := 50) {
    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;

            for n: nodes {
                nr.update(*n.r, 5);
            }

            sleep_milliseconds(1);
        }
    }
}

rt_spawn :: (n: *RT_Node, value: s32) -> *objects.Network_Object {
    o := objects.spawn(*n.reg, 0);
    c := rt_factory();
    ((cast(*RT_Value) c.userdata)).value = value;
    array_add(*o.components, c);
    return o;
}

rt_value :: (n: *RT_Node, id: objects.Network_Id) -> s32 {
    o, ok := objects.get(*n.reg, id);
    if !ok {
        return -999;
    }

    return ((cast(*RT_Value) o.components[0].userdata)).value;
}

rt_frame :: (kind: nr.Kind, generation: u64) -> [] u8 {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    core.write_uint8(*w, (cast, trunc(u8)(kind)), .Uncompressed);
    core.write_uint64(*w, generation, .Uncompressed);
    return core.writer_to_array(*w);
}

//@endregion
//@region 真实UDP集成

rt_two_clients_late_join_write_rpc_and_reconnect :: (t: *Test) {
    s, a, b: RT_Node;
    rt_init(*s, true);
    rt_init(*a, false);
    rt_init(*b, false);
    nodes := (*RT_Node).[*s, *a, *b];
    defer rt_shutdown(nodes);
    o := rt_spawn(*s, 7);
    expect(t, session.start_server(*s.s, 0));
    port := session.bound_port(*s.s);
    expect(t, session.start_client(*a.s, "127.0.0.1", port));
    rt_pump(nodes);
    if !expect(t, rt_value(*a, o.id) == 7, "first client full state") {
        return;
    };

    old_id, old_generation := a.s.client_server_id, a.s.client_generation;
    ((cast(*RT_Value) o.components[0].userdata)).value = 9;
    expect(t, session.start_client(*b.s, "localhost", port));
    rt_pump(nodes);
    expect_value(t, rt_value(*b, o.id), (cast, trunc(s32)(9)));
    expect(t, objects.set_controller(*s.reg, o.id, old_id));
    rt_pump(nodes);
    ao, _ := objects.get(*a.reg, o.id);
    ((cast(*RT_Value) ao.components[0].userdata)).value = 42;
    expect(t, nr.write_member(*a.r.client, o.id, 0, 0));
    expect(t, !nr.write_member(*b.r.client, o.id, 0, 0), "noncontroller rejected locally");
    rt_pump(nodes);
    expect_value(t, rt_value(*s, o.id), (cast, trunc(s32)(42)));
    expect_value(t, rt_value(*b, o.id), (cast, trunc(s32)(42)));
    expect(t, rpc.send(*a.r.client.rpc, 71, o.id, .Observers, u8.[1]));
    rt_pump(nodes);
    expect_value(t, s.hits, 1);
    expect_value(t, b.hits, 1);
    expect_value(t, a.hits, 0);
    expect_value(t, s.sender, old_id);
    expect(t, s.s.userdata == *s, "application Session userdata preserved");
    expect(t, session.disconnect_local(*a.s) == .Success);
    rt_pump(nodes);
    if !expect(t, !a.s.client_authenticated, "disconnect observed") {
        return;
    }

    expect(t, a.reg.active_count == 0, "disconnect clears world");
    expect(t, session.stop_client(*a.s));
    expect(t, session.start_client(*a.s, "127.0.0.1", port));
    rt_pump(nodes);
    expect(t, a.s.client_generation != old_generation && a.s.client_server_id != old_id);
    expect_value(t, rt_value(*a, o.id), (cast, trunc(s32)(42)));
    frame := rt_frame(.Full, old_generation);
    defer release(frame);
    expect(t, !nr.receive(*s.r, a.s.client_server_id, .Server, .Reliable, frame), "old generation rejected");
    frame[0] = (cast, trunc(u8)(nr.Kind.State));
    expect(t, !nr.receive(*s.r, a.s.client_server_id, .Server, .Reliable, frame), "client cannot send state");
    expect(t, !nr.write_member(*a.r.client, o.id, 0, 0), "old controller cannot write after reconnect");
}

rt_host_keeps_separate_worlds :: (t: *Test) {
    n: RT_Node;
    rt_init(*n, true, true);
    defer rt_shutdown((*RT_Node).[*n]);
    o := rt_spawn(*n, 13);
    expect(t, session.start_host(*n.s));
    rt_pump((*RT_Node).[*n]);
    mirror, ok := objects.get(*n.mirror, o.id);
    if expect(t, ok, "host client received replication") {
        expect(t, mirror != o && mirror.components[0] != o.components[0]);
        expect_value(t, ((cast(*RT_Value) mirror.components[0].userdata)).value, (cast, trunc(s32)(13)));
    }
}

rt_scene_gate_waits_for_loader_confirmation :: (t: *Test) {
    s, a: RT_Node;
    rt_init(*s, true);
    rt_init(*a, false);
    nodes := (*RT_Node).[*s, *a];
    defer rt_shutdown(nodes);
    expect(t, session.start_server(*s.s, 0));
    h, ok := scenes.open(*s.r.server.scenes, 12, .{
        kind = .Global
    });
    expect(t, ok);
    o := rt_spawn(*s, 23);
    o.scene = (cast, trunc(u32)(h));
    expect(t, session.start_client(*a.s, "127.0.0.1", session.bound_port(*s.s)));
    rt_pump(nodes);
    expect(t, a.requests == 1 && a.ticket.operation == .Load, "request reached real loader userdata");
    expect_value(t, a.reg.active_count, 0);
    expect(t, !objects.can_write(*s.reg, o.id, a.s.client_server_id));
    expect(t, scenes.complete_load(*a.r.client.scenes, a.ticket, true));
    rt_pump(nodes);
    expect_value(t, rt_value(*a, o.id), (cast, trunc(s32)(23)));
    expect(t, scenes.is_loaded(*s.r.server.scenes, h, a.s.client_server_id));
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
