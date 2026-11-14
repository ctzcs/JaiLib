#scope_file
core :: #import "thirdparty/onet/core";
objects :: #import "thirdparty/onet/objects";
nr :: #import "thirdparty/onet/runtime";
session :: #import "thirdparty/onet/session";
sim :: #import "thirdparty/onet/simulation";
#scope_export

//@region World binding generations replace the old independent-stream lifecycle

wg_frame :: (kind: nr.Kind, generation, epoch, binding: u64, body: [] u8) -> [] u8 {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    core.write_uint8(*w, (cast, trunc(u8)(kind)), .Uncompressed);
    core.write_uint64(*w, generation, .Uncompressed);
    core.write_uint64(*w, epoch, .Uncompressed);
    core.write_uint64(*w, binding, .Uncompressed);
    core.write_u8_array_as_bytes_unsafe(*w, body, .Loose);
    return core.writer_to_array(*w);
}

world_runtime_rejects_one_mutable_world_bound_by_two_runtimes :: (t: *Test) {
    s, other: RT_Node;
    rt_init(*s, true);
    rt_init(*other, true);
    w: sim.Simulation_World;
    assert(sim.world_init(*w, .{
        authority = true, fixed_dt = 0.01
    }) == .Ok);
    defer sim.world_destroy(*w);
    defer rt_shutdown((*RT_Node).[*s, *other]);
    expect(t, nr.bind_simulation(*s.r.server, *w, false));
    expect(t, !nr.bind_simulation(*other.r.server, *w, false));
    nr.unbind_simulation(*s.r.server);
    expect(t, nr.bind_simulation(*other.r.server, *w, false));
};

world_runtime_rebind_ignores_old_snapshot_request_and_queued_owner_input :: (t: *Test) {
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
    server, client := *s.node.r.server, *a.node.r.client;
    old_binding, old_epoch := client.simulation_binding, server.simulation_epoch;
    body, status := sim.world_encode_snapshot(*s.fixture.world, s.fixture.world.tick);
    assert(status == .Ok);
    defer release(body);
    old_state := wg_frame(.World_State, a.node.s.client_generation, old_epoch, old_binding, body);
    defer release(old_state);
    nr.unbind_simulation(client);
    assert(nr.bind_simulation(client, *a.fixture.world));
    expect(t, client.simulation_binding > old_binding && a.fixture.world.needs_full);
    expect(t, nr.receive(*a.node.r, session.local_connection(*a.node.s), .Client, .Reliable, old_state));
    expect(t, !a.fixture.world.pending.valid && a.fixture.world.needs_full, "old state cannot arm the fresh binding");
    rt_pump(nodes, 60);
    expect(t, !a.fixture.world.needs_full && table_get(*server.peers, a.node.s.client_server_id).world_client_binding == client.simulation_binding);
    current_binding := client.simulation_binding;
    old_request := wg_frame(.World_Reset_Request, a.node.s.client_generation, old_epoch, old_binding, .[]);
    defer release(old_request);
    expect(t, nr.receive(*s.node.r, a.node.s.client_server_id, .Server, .Reliable, old_request));
    expect_value(t, table_get(*server.peers, a.node.s.client_server_id).world_client_binding, current_binding);
    sys, _ := sim.world_find(*s.fixture.world, (cast(sim.System_Id) (o.id)));
    sim.world_clear_inputs(*s.fixture.world);
    if !expect(t, sim.world_queue_input(*s.fixture.world, a.node.s.client_server_id, sys.config.id, s.fixture.world.tick + 1, sys.config.incarnation, u8.[9, 1]) == .Ok) {
        return;
    }

    nr.unbind_simulation(server);
    assert(nr.bind_simulation(server, *s.fixture.world));
    expect(t, server.simulation_epoch > old_epoch && (s.fixture.world.queued).count == 0);
    rt_pump(nodes, 60);
    expect(t, client.simulation_epoch == server.simulation_epoch && !a.fixture.world.needs_full);
    expect(t, nr.receive(*a.node.r, session.local_connection(*a.node.s), .Client, .Reliable, old_state));
}

world_runtime_removed_channel_protocol_numbers_are_never_reinterpreted :: (t: *Test) {
    s, a: RT_Node;
    rt_init(*s, true);
    rt_init(*a, false);
    defer rt_shutdown((*RT_Node).[*s, *a]);
    assert(session.start_server(*s.s, 0) && session.start_client(*a.s, "127.0.0.1", session.bound_port(*s.s)));
    rt_pump((*RT_Node).[*s, *a], 40);
    for old: 7..11 {
        frame := rt_frame((cast(nr.Kind) (old)), a.s.client_generation);
        expect(t, !nr.receive(*s.r, a.s.client_server_id, .Server, .Reliable, frame));
        expect(t, !nr.receive(*a.r, session.local_connection(*a.s), .Client, .Reliable, frame));
        release(frame);
    }
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
