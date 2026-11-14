#scope_file
ref :: #import "thirdparty/onet/tests/support/reference_physics";
#scope_file
objects :: #import "thirdparty/onet/objects";
phy :: #import "thirdparty/onet/physics";
nr :: #import "thirdparty/onet/runtime";
session :: #import "thirdparty/onet/session";
#scope_export

//@region 原生body通过认证对象流自动复制与推进

PB_State :: struct {
    body: ref.Native_Body;
    binding: phy.Body_Binding;
}

pb_free :: (p: *void) {
    free((cast(*PB_State) p));
}

pb_factory :: () -> *objects.Component {
    st := new_one(PB_State);
    ref.native_body_init(*st.body);
    st.body.gravity = .{
    };

    st.binding = .{
        adapter = ref.native_adapter(*st.body), convergence = phy.convergence_default(),
    };

    c := objects.component_make(9923);
    c.userdata, c.destroy_userdata = st, pb_free;
    objects.member_custom(c, *st.binding, nr.body_codec(0xB700));
    return c;
}

pb_build :: (user: *void, obj: *objects.Network_Object) -> *phy.Body_Binding {
    return *((cast(*PB_State) obj.components[0].userdata)).binding;
}

pb_state :: (n: *RT_Node, id: objects.Network_Id) -> *PB_State {
    o, ok := objects.get(*n.reg, id);
    return (ifx ok then (cast(*PB_State) o.components[0].userdata) else null);
}

physics_runtime_automatic_native_body_adopt_sleep_wake_late_join_and_remove :: (t: *Test) {
    s, a, b: RT_Node;
    rt_init(*s, true);
    rt_init(*a, false);
    rt_init(*b, false);
    ss, sa, sb: phy.Body_System;
    ws, wa, wb: ref.World;
    defer ref.world_destroy(*ws);
    defer ref.world_destroy(*wa);
    defer ref.world_destroy(*wb);
    as, aa, ab := ref.world_adapter(*ws), ref.world_adapter(*wa), ref.world_adapter(*wb);
    assert(phy.body_system_init(*ss, *as) && phy.body_system_init(*sa, *aa) && phy.body_system_init(*sb, *ab));
    defer phy.body_system_destroy(*ss);
    defer phy.body_system_destroy(*sa);
    defer phy.body_system_destroy(*sb);
    defer rt_shutdown((*RT_Node).[*s, *a, *b]);
    for n: ((*RT_Node).[*s, *a, *b]) {
        objects.register_factory(*n.reg, 9923, pb_factory);
    }

    assert(nr.bind_physics(*s.r.server, *ss) && nr.bind_physics(*a.r.client, *sa) && nr.bind_physics(*b.r.client, *sb));
    nr.unbind_physics(*b.r.client);
    expect(t, sb.host == null && ab.bound_system == *sb);
    expect(t, !nr.bind_physics(*b.r.client, *sa)); // exclusive borrower, not a copy

    expect(t, nr.bind_physics(*b.r.client, *sb));
    expect(t, b.r.client.physics_system == *sb && sb.world == *ab && sb.host == *b.r.client);
    assert(nr.register_body_component(*s.r.server, 9923, pb_build) && nr.register_body_component(*a.r.client, 9923, pb_build) && nr.register_body_component(*b.r.client, 9923, pb_build));
    o := objects.spawn(*s.reg, 0);
    array_add(*o.components, pb_factory());
    st := pb_state(*s, o.id);
    st.body.state.linear_velocity = .[
    1, 0, 0,
    ];

    assert(session.start_server(*s.s, 0) && session.start_client(*a.s, "127.0.0.1", session.bound_port(*s.s)));
    nodes := (*RT_Node).[*s, *a, *b];
    rt_pump(nodes, 100);
    remote := pb_state(*a, o.id);
    if !expect(t, remote != null && remote.binding.component.adopted && remote.body.steps > 0) {
        return;
    }

    expect(t, remote.body.state.position[0] > 0 && st.body.steps == s.s.tick && (sa.bindings).count == 1);
    expect(t, ws.steps == s.s.tick && wa.steps == a.s.tick);
    before := ws.steps;
    nr.step_physics_bodies(*s.r.server);
    expect_value(t, ws.steps, before);
    st.body.state.flags |= (phy.Body_Flags.Sleeping);
    st.body.state.linear_velocity = .{
    };

    rt_pump(nodes, 60);
    expect(t, phy.has_flag(remote.body.state.flags, .Sleeping) && Math.abs(remote.body.state.position[0] - st.body.state.position[0]) < 0.00001);
    quiet_tick := st.binding.component.state.tick;
    rt_pump(nodes, 20);
    expect_value(t, st.binding.component.state.tick, quiet_tick);
    assert(session.start_client(*b.s, "127.0.0.1", session.bound_port(*s.s)));
    rt_pump(nodes, 80);
    late := pb_state(*b, o.id);
    if !expect(t, late != null && late.binding.component.adopted && phy.has_flag(late.body.state.flags, .Sleeping)) {
        return;
    }

    ref.native_add_force(*st.body, .[
   100, 0, 0
   ]);
    rt_pump(nodes, 80);
    expect(t, !phy.has_flag(remote.body.state.flags, .Sleeping) && remote.body.state.position[0] > 0.6);
    expect(t, !phy.has_flag(late.body.state.flags, .Sleeping) && late.body.state.position[0] > 0.6);
    expect(t, !phy.has_flag(st.body.state.flags, .Sleeping));
    assert(objects.despawn(*s.reg, o.id));
    rt_pump(nodes, 60);
    expect(t, (ss.bindings).count == 0 && (sa.bindings).count == 0 && (sb.bindings).count == 0);
    expect(t, ws.steps == s.s.tick && wa.steps == a.s.tick && wb.steps == b.s.tick);
    expect(t, (ws.active).count == 0 && (wa.active).count == 0 && (wb.active).count == 0);
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
