#scope_file
collections :: #import "thirdparty/onet/collections";
objects :: #import "thirdparty/onet/objects";
rpc :: #import "thirdparty/onet/rpc";
nr :: #import "thirdparty/onet/runtime";
session :: #import "thirdparty/onet/session";
sim :: #import "thirdparty/onet/simulation";
udp :: #import "thirdparty/onet/transport/udp";
v :: #import "thirdparty/onet/values";
#scope_export

//@region 真实组件与自动系统fixture

RW_Body :: struct {
    model: WX_Model;
    bag: collections.Sequence(s32);
    rpc: *rpc.Manager;
    replay_blocked, replay_rpc_blocked: bool;
}

RW_Endpoint :: struct {
    node: RT_Node;
    fixture: WX_Fixture;
    native: udp.Transport;
    native_ready: bool;
    moving, mutate_bag, observer_prediction: bool;
    gain: u64;
    events: int;
    event_tick: u64;
}

rw_carry_mask: [2] u8 = .[
1, 0,
];

rw_release :: (p: *void) {
    free((cast(*RW_Body) p));
}

rw_factory :: () -> *objects.Component {
    b := new_one(RW_Body);
    assert(collections.list_init(*b.bag, v.builtin(s32)));
    c := objects.component_make(9922);
    c.userdata, c.destroy_userdata = b, rw_release;
    objects.member_u64(c, *b.model.value); // 故意同时存在复制回声，必须保留本地预测显示。

    objects.member_custom(c, *b.bag, objects.collection_sequence_codec(s32, 0xB600));
    return c;
}

rw_capture :: (p: *void, dst: [] u8) {
    wx_capture(*((cast(*RW_Body) p)).model, dst);
}

rw_restore :: (p: *void, state: [] u8) {
    wx_restore(*((cast(*RW_Body) p)).model, state);
}

rw_sample :: (p: *void, dst: [] u8, tick: sim.Tick) {
    wx_sample(*((cast(*RW_Body) p)).model, dst, tick);
}

rw_early :: (p: *void, step: *sim.World_Step) {
    b := (cast(*RW_Body) p);
    wx_early(*b.model, step);
    if step.replay {
        b.replay_blocked = b.replay_blocked || !collections.add(*b.bag, 999);
    }

    if step.replay && b.rpc != null {
        b.replay_rpc_blocked = b.replay_rpc_blocked || (b.rpc.replaying && !rpc.send(b.rpc, 71, (cast(objects.Network_Id) (b.model.id)), .Server, .[]));
    }
}

rw_late :: (p: *void, step: *sim.World_Step) {
    wx_late(*((cast(*RW_Body) p)).model, step);
}

rw_hold :: (p: *void, enabled: bool) {
    wx_hold(*((cast(*RW_Body) p)).model, enabled);
}

rw_build :: (p: *void, obj: *objects.Network_Object) -> (sim.System_Config, bool) {
    e := (cast(*RW_Endpoint) p);
    b := (cast(*RW_Body) obj.components[0].userdata);
    b.model.fixture, b.model.id, b.model.gain = *e.fixture, (cast(int) (obj.id)), e.gain;
    b.rpc = (ifx e.node.reg.authoritative then *e.node.r.server.rpc else *e.node.r.client.rpc);
    return .{
        schema = 0xB500 + (cast, trunc(u32)(obj.id)), state_size = 16, input_size = 2, carry_mask = view(rw_carry_mask, 0), observer_prediction = e.observer_prediction,
        callbacks = .{
            user = b, capture = rw_capture, restore = rw_restore, validate_state = wx_state_valid, validate_input = wx_input_valid, sample_input = rw_sample, early = rw_early, late = rw_late, hold = rw_hold,
        },
    }, true;
};

rw_game_tick :: (s: *session.Session) {
    e := (cast(*RW_Endpoint) s.userdata);
    for obj, _: e.node.reg.objects {
        if obj == null || !obj.active {
            continue;
        }

        b := (cast(*RW_Body) obj.components[0].userdata);
        if e.node.reg.authoritative && e.mutate_bag && obj.id == 1 {
            assert(collections.add(*b.bag, (cast, trunc(s32)(s.tick))));
        }

        if !e.node.reg.authoritative {
            for ev: collections.take_applied_changes(*b.bag) {
                e.events += 1;
                e.event_tick = max(e.event_tick, ev.tick);
            }
        }

        b.model.gain = e.gain;
        b.model.sample = .{
        };

        if !e.node.reg.authoritative && obj.owner == s.client_server_id && obj.id == 1 && e.moving {
            b.model.sample = .[
            2, 0,
            ];
        }
    }
}

rw_init :: (e: *RW_Endpoint, authority, native: bool) {
    rt_init(*e.node, authority);
    e.gain = 1;
    objects.register_factory(*e.node.reg, 9922, rw_factory);
    e.node.s.userdata, e.node.s.on_tick = e, rw_game_tick;
    assert(sim.world_init(*e.fixture.world, .{
        authority = authority, fixed_dt = 0.01, capacity = 64
    }, .{
        user = *e.fixture, physics = wx_physics, event = wx_event, replay_mode = wx_mode
    }) == .Ok);
    w := (ifx authority then *e.node.r.server else *e.node.r.client);
    assert(nr.bind_simulation(w, *e.fixture.world));
    assert(nr.register_world_component(w, 9922, rw_build, e));
    if native {
        cfg := udp.default_config();
        cfg.family = .IPv6;
        assert(udp.init(*e.native, cfg));
        e.native_ready = true;
        assert(session.set_driver(*e.node.s, udp.driver(*e.native)));
    }
};

rw_shutdown :: (endpoints: [] *RW_Endpoint) {
    nodes: [..] *RT_Node;
    for e: endpoints {
        array_add(*nodes, *e.node);
    }

    rt_shutdown(view(nodes, 0));
    release(nodes);
    for e: endpoints {
        sim.world_destroy(*e.fixture.world);
        if e.native_ready {
            udp.destroy(*e.native);
        }
    }
}

rw_body :: (e: *RW_Endpoint, id: objects.Network_Id) -> *RW_Body {
    o, exists := objects.get(*e.node.reg, id);
    return (ifx exists then (cast(*RW_Body) o.components[0].userdata) else null);
}

rw_run :: (t: *Test, native: bool) {
    s, a, b: RW_Endpoint;
    rw_init(*s, true, native);
    rw_init(*a, false, native);
    rw_init(*b, false, native);
    defer rw_shutdown((*RW_Endpoint).[*s, *a, *b]);
    s.gain = 2;
    a.moving = true;
    {
        loop_index := 0;
        while loop_index < 40 {
            defer loop_index += 1;
            o := objects.spawn(*s.node.reg, 0);
            array_add(*o.components, rw_factory());
        }
    }

    expect(t, session.start_server(*s.node.s, 0));
    address := (ifx native then "::1" else "127.0.0.1");
    expect(t, session.start_client(*a.node.s, address, session.bound_port(*s.node.s)));
    nodes := (*RT_Node).[*s.node, *a.node, *b.node];
    rt_pump(nodes, 80);
    if !expect(t, a.node.s.client_authenticated, "controller authenticated") {
        return;
    }

    expect(t, objects.set_controller(*s.node.reg, 1, a.node.s.client_server_id));
    rt_pump(nodes, 100);
    if !expect(t, rw_body(*a, 1) != null, "auto component mirror exists") {
        return;
    }

    expect(t, (a.fixture.world.systems).count == 40 && (s.fixture.world.systems).count == 40);
    expect(t, a.fixture.world.tick > 0 && a.fixture.physics > 0 && a.node.r.client.world_clock.sampled);
    expect(t, a.fixture.mode_starts > 0 && rw_body(*a, 1).replay_blocked && rw_body(*a, 1).replay_rpc_blocked && !a.node.r.client.rpc.replaying, "network replay rejects collections and RPC, then restores guards");
    // 集合操作通过真实runtime复制，消费提交事件而不是临时解码事件。

    s.mutate_bag = true;
    rt_pump(nodes, 20);
    s.mutate_bag = false;
    rt_pump(nodes, 30);
    expect(t, a.events == (rw_body(*s, 1).bag.items).count && a.events > 0 && a.event_tick > 0);
    // 晚加入只观察权威系统，不获得其他controller的输入权限。

    expect(t, session.start_client(*b.node.s, address, session.bound_port(*s.node.s)));
    rt_pump(nodes, 100);
    expect(t, b.node.s.client_authenticated && (b.fixture.world.systems).count == 40);
    expect_value(t, b.events, 0); // 晚加入不得重演服务器已发生的操作。

    a.moving = false;
    a.gain = 2;
    rt_pump(nodes, 120);
    if !expect(t, rw_body(*b, 1) != null) {
        return;
    }

    // Native ENet fragmentation/retransmission follows wall time. Wait for convergence
    // within a bounded number of pump steps instead of assuming 120 iterations suffice.
    for 0..399 {
        if rw_body(*a, 1).model.value == rw_body(*s, 1).model.value &&
           rw_body(*b, 1).model.value == rw_body(*s, 1).model.value break;
        rt_pump(nodes, 1);
    }
    expect_value(t, rw_body(*a, 1).model.value, rw_body(*s, 1).model.value);
    expect_value(t, rw_body(*b, 1).model.value, rw_body(*s, 1).model.value);
    // 批量销毁后，不得在一次次重建之间访问另一已释放组件的userdata。

    expect(t, objects.despawn(*s.node.reg, 2) && objects.despawn(*s.node.reg, 3));
    rt_pump(nodes, 80);
    expect(t, (s.fixture.world.systems).count == 38 && (a.fixture.world.systems).count == 38 && (b.fixture.world.systems).count == 38);
    // 转移控制权时普通对象流可晚到；世界消息不得被旧owner反向覆盖。

    expect(t, objects.set_controller(*s.node.reg, 1, b.node.s.client_server_id));
    rt_pump(nodes, 80);
    as, _ := sim.world_find(*a.fixture.world, 1);
    bs, _ := sim.world_find(*b.fixture.world, 1);
    expect(t, as != null && bs != null && as.config.owner == b.node.s.client_server_id && bs.config.owner == b.node.s.client_server_id);
    expect_value(t, as.config.incarnation, bs.config.incarnation);
};

world_runtime_enet_auto_systems_missing_ticks_and_global_replay :: (t: *Test) {
    rw_run(t, false);
}

world_runtime_native_ipv6_large_snapshot_fragmentation_and_transfer :: (t: *Test) {
    rw_run(t, true);
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
