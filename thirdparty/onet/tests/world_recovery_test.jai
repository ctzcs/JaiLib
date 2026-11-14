#scope_file
objects :: #import "thirdparty/onet/objects";
nr :: #import "thirdparty/onet/runtime";
session :: #import "thirdparty/onet/session";
sim :: #import "thirdparty/onet/simulation";
#scope_export

//@region Migrated overflow and foreign-owner runtime regressions

world_runtime_history_exhaustion_renews_binding_and_clears_old_server_tail :: (t: *Test) {
    s, a: RW_Endpoint;
    rw_init(*s, true, false);
    rw_init(*a, false, false);
    defer rw_shutdown((*RW_Endpoint).[*s, *a]);
    o := objects.spawn(*s.node.reg, 0);
    array_add(*o.components, rw_factory());
    assert(session.start_server(*s.node.s, 0) && session.start_client(*a.node.s, "127.0.0.1", session.bound_port(*s.node.s)));
    nodes := (*RT_Node).[*s.node, *a.node];
    rt_pump(nodes, 80);
    assert(objects.set_controller(*s.node.reg, o.id, a.node.s.client_server_id));
    rt_pump(nodes, 30);
    old := a.node.r.client.simulation_binding;
    // Keep client clocks/fixed loop running, but stop the authority network loop.

    {
        loop_index := 0;
        while loop_index < 300 {
            defer loop_index += 1;
            nr.update(*a.node.r, 5);
        }
    }

    if !expect(t, a.fixture.world.needs_full && a.node.r.client.simulation_binding > old) {
        return;
    }

    tick := a.fixture.world.tick;
    {
        loop_index := 0;
        while loop_index < 20 {
            defer loop_index += 1;
            nr.update(*a.node.r, 5);
        }
    }

    expect_value(t, a.fixture.world.tick, tick);
    sim.world_clear_inputs(*s.fixture.world);
    sys, _ := sim.world_find(*s.fixture.world, (cast(sim.System_Id) (o.id)));
    assert(sim.world_queue_input(*s.fixture.world, a.node.s.client_server_id, sys.config.id, s.fixture.world.tick + 2, sys.config.incarnation, u8.[9, 1]) == .Ok);
    // Poll only: the new binding request must erase the old queued tail before
    // any authority tick is allowed to execute it.

    {
        loop_index := 0;
        while loop_index < 20 {
            defer loop_index += 1;
            nr.update(*s.node.r, 0);
        }
    }

    expect(t, table_get(*s.node.r.server.peers, a.node.s.client_server_id).world_client_binding == a.node.r.client.simulation_binding && (s.fixture.world.queued).count == 0);
    rt_pump(nodes, 120);
    expect(t, !a.fixture.world.needs_full && rw_body(*a, o.id).model.value == rw_body(*s, o.id).model.value && rw_body(*s, o.id).model.jumps == 0);
}

world_runtime_observer_binding_does_not_authorize_another_controllers_input :: (t: *Test) {
    s, a, b: RW_Endpoint;
    rw_init(*s, true, false);
    rw_init(*a, false, false);
    rw_init(*b, false, false);
    defer rw_shutdown((*RW_Endpoint).[*s, *a, *b]);
    b.observer_prediction = true;
    o := objects.spawn(*s.node.reg, 0);
    array_add(*o.components, rw_factory());
    assert(session.start_server(*s.node.s, 0));
    assert(session.start_client(*a.node.s, "127.0.0.1", session.bound_port(*s.node.s)));
    assert(session.start_client(*b.node.s, "127.0.0.1", session.bound_port(*s.node.s)));
    nodes := (*RT_Node).[*s.node, *a.node, *b.node];
    rt_pump(nodes, 80);
    assert(objects.set_controller(*s.node.reg, o.id, a.node.s.client_server_id));
    rt_pump(nodes, 40);
    expect(t, !sim.world_has_owner(*b.fixture.world, (cast, trunc(u32)(b.node.s.client_server_id))));
    assert(sim.world_step(*a.fixture.world) == .Ok);
    data, status := sim.world_encode_input(*a.fixture.world, a.node.s.client_server_id, a.fixture.world.tick);
    assert(status == .Ok);
    defer release(data);
    frame := wg_frame(.World_Input, b.node.s.client_generation, s.node.r.server.simulation_epoch, b.node.r.client.simulation_binding, data);
    defer release(frame);
    before := (s.fixture.world.queued).count;
    expect(t, !nr.receive(*s.node.r, b.node.s.client_server_id, .Server, .Reliable, frame));
    expect_value(t, (s.fixture.world.queued).count, before);
}

world_new_timeline_snapshot_is_validated_before_replacing_live_history :: (t: *Test) {
    s, c: WX_Fixture;
    sw_init(*s, true);
    sw_init(*c, false);
    defer sim.world_destroy(*s.world);
    defer sim.world_destroy(*c.world);
    wx_seed(t, *s, *c);
    c.a.sample = .[
    2, 1,
    ];
    assert(sim.world_step(*c.world) == .Ok);
    s.a.value = 15;
    assert(sim.world_step(*s.world) == .Ok);
    data, status := sim.world_encode_snapshot(*s.world, 1);
    assert(status == .Ok);
    defer release(data);
    sequence, applied := c.world.received_sequence, c.world.applied_tick;
    {
        cut := 0;
        while cut < (data).count {
            defer cut += 1;

            expect(t, sim.world_receive_snapshot(*c.world, view(data, 0, cut), true) != .Ok && c.world.received_sequence == sequence && c.world.applied_tick == applied && c.a.value == 2 && sim.world_frame(*c.world, 1) != null);
        }
    };

    assert(sim.world_receive_snapshot(*c.world, data, true) == .Ok);
    _, corrected, result := sim.world_reconcile(*c.world);
    expect(t, result == .Ok && corrected && c.a.value == 15 && !c.world.needs_full);
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
