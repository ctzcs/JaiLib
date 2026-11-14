#scope_file
sim :: #import "thirdparty/onet/simulation";
transport :: #import "thirdparty/onet/transport";
#scope_export

//@region 相互作用系统fixture

WX_Model :: struct {
    value, jumps, gain: u64;

    sample: [2] u8;

    id: int;

    peer, remote: *WX_Model;

    fixture: *WX_Fixture;

    carry, hold_all, held: bool;
}

WX_Fixture :: struct {
    world: sim.Simulation_World;

    a, b, remote: WX_Model;

    order: [2048] int;

    order_count, physics, replays, mode_starts, mode_ends, missing, mismatches: int;

    replay_mode: bool;

    replay_remote: u64;
}

wx_capture :: (p: *void, dst: [] u8) {
    m := (cast(*WX_Model) p);
    sim_put(view(dst, 0, 8), m.value);
    sim_put(view(dst, 8), m.jumps);
}

wx_restore :: (p: *void, state: [] u8) {
    m := (cast(*WX_Model) p);
    m.value, m.jumps = sim_get(view(state, 0, 8)), sim_get(view(state, 8));
}

wx_state_valid :: (p: *void, state: [] u8, tick: sim.Tick) -> bool {
    return (state).count == 16 && sim_get(view(state, 0, 8)) < 1000000000000 && sim_get(view(state, 8)) < 1000000;
}

wx_input_valid :: (p: *void, input: [] u8, tick: sim.Tick) -> bool {
    return (input).count == 2 && input[0] <= 10 && input[1] <= 10;
}

wx_sample :: (p: *void, dst: [] u8, tick: sim.Tick) {
    m := (cast(*WX_Model) p);
    copy_samples(dst, view(m.sample, 0));
}

wx_log :: (f: *WX_Fixture, n: int) {
    if f.order_count < (f.order).count {
        f.order[f.order_count] = n;
        f.order_count += 1;
    }
}

wx_early :: (p: *void, step: *sim.World_Step) {
    m := (cast(*WX_Model) p);
    if step.missing && m.carry {
        sim.world_try_last_state(step, m.hold_all);
    }

    m.value += (cast, trunc(u64)(step.input[0])) * m.gain;
    m.jumps += (cast, trunc(u64)(step.input[1]));
    wx_log(m.fixture, m.id);
    if step.replay {
        m.fixture.replays += 1;
        if m.remote != null {
            m.fixture.replay_remote = m.remote.value;
        }
    }
}

wx_late :: (p: *void, step: *sim.World_Step) {
    m := (cast(*WX_Model) p);
    if m.peer != null {
        m.value += m.peer.value;
    }

    if m.remote != null {
        m.value += m.remote.value;
    }

    wx_log(m.fixture, 100 + m.id);
}

wx_hold :: (p: *void, enabled: bool) {
    ((cast(*WX_Model) p)).held = enabled;
}

wx_physics :: (p: *void, w: *sim.Simulation_World, tick: sim.Tick, dt: float64, replay: bool) {
    f := (cast(*WX_Fixture) p);
    f.physics += 1;
    wx_log(f, 50);
}

wx_event :: (p: *void, w: *sim.Simulation_World, event: sim.World_Event, id: sim.System_Id, tick: sim.Tick) {
    f := (cast(*WX_Fixture) p);
    if event == {
        case .Missing_Input; f.missing += 1;
        case .Result_Mismatch; f.mismatches += 1;
    }
}

wx_mode :: (p: *void, enabled: bool) {
    f := (cast(*WX_Fixture) p);
    f.replay_mode = enabled;
    if enabled {
        f.mode_starts += 1;
    } else {
        f.mode_ends += 1;
    }
}

wx_register :: (f: *WX_Fixture, m: *WX_Model, id: sim.System_Id, owner: u32, observer := false) -> sim.Status {
    m.id, m.fixture = (cast(int) (id)), f;
    return sim.world_register(*f.world, .{
        id = id, schema = (cast, trunc(u32)(id)) + 1000, owner = (cast(transport.Connection_Id) (owner)),
        state_size = 16, input_size = 2, observer_prediction = observer, carry_mask = u8.[1, 0],
        callbacks = .{
            user = m, capture = wx_capture, restore = wx_restore, validate_state = wx_state_valid, validate_input = wx_input_valid, sample_input = wx_sample, early = wx_early, late = wx_late, hold = wx_hold
        },
    });
};

wx_init :: (f: *WX_Fixture, authority: bool, capacity := 16) {
    assert(sim.world_init(*f.world, .{
        authority = authority, local_owner = 1, fixed_dt = 0.02, capacity = capacity
    }, .{
        user = f, physics = wx_physics, event = wx_event, replay_mode = wx_mode
    }) == .Ok);
    f.a.gain, f.b.gain, f.remote.gain = 1, 1, 1;
    assert(wx_register(f, *f.b, 2, 1) == .Ok); // 故意逆序注册，执行仍按ID。

    assert(wx_register(f, *f.a, 1, 1) == .Ok);
    assert(wx_register(f, *f.remote, 3, 2) == .Ok);
};

wx_seed :: (t: *Test, s, c: *WX_Fixture) {
    data, status := sim.world_encode_snapshot(*s.world, s.world.tick);
    defer release(data);
    expect_value(t, status, .Ok);
    expect_value(t, sim.world_receive_snapshot(*c.world, data), .Ok);
    _, _, status = sim.world_reconcile(*c.world);
    expect_value(t, status, .Ok);
}

wx_input :: (t: *Test, s, c: *WX_Fixture, tick: u64) {
    data, status := sim.world_encode_input(*c.world, 1, tick);
    defer release(data);
    expect_value(t, status, .Ok);
    expect_value(t, sim.world_receive_input(*s.world, 1, data), .Ok);
}

//@endregion
//@region 世界固定顺序与缺失输入

world_all_early_physics_all_late_and_post_late_hash :: (t: *Test) {
    f: WX_Fixture;
    wx_init(*f, true);
    defer sim.world_destroy(*f.world);
    f.a.value, f.b.value = 2, 3;
    f.a.peer, f.b.peer = *f.b, *f.a;
    expect_value(t, sim.world_step(*f.world), .Ok);
    expect_value(t, f.order_count, 7); // server也模拟远端owner的missing tick。

    expected := int.[1, 2, 3, 50, 101, 102, 103];
    for value, i: expected {
        expect_value(t, f.order[i], value);
    }

    expect_value(t, f.a.value, (cast, trunc(u64)(5)));
    expect_value(t, f.b.value, (cast, trunc(u64)(8)));
    frame := sim.world_frame(*f.world, 1);
    hash, ok := sim.world_system_hash(*f.world, frame, 1);
    state: [16] u8;
    wx_capture(*f.a, view(state, 0));
    expect(t, ok && hash == sim.world_hash(view(state, 0)), "hash sees cross-system Late writes");
}

world_missing_input_default_selective_carry_and_late_rejection :: (t: *Test) {
    f: WX_Fixture;
    wx_init(*f, true);
    defer sim.world_destroy(*f.world);
    expect_value(t, sim.world_queue_input(*f.world, 1, 1, 1, 1, u8.[4, 1]), .Ok);
    expect_value(t, sim.world_step(*f.world), .Ok);
    expect(t, f.a.value == 4 && f.a.jumps == 1);
    expect_value(t, sim.world_step(*f.world), .Ok);
    expect(t, f.a.value == 4 && f.a.jumps == 1, "missing defaults do not carry implicitly");
    f.a.carry = true;
    expect_value(t, sim.world_step(*f.world), .Ok);
    expect(t, f.a.value == 8 && f.a.jumps == 1, "carry motion but not one-shot jump");
    f.a.hold_all = true;
    expect_value(t, sim.world_step(*f.world), .Ok);
    expect(t, f.a.value == 12 && f.a.jumps == 2);
    expect_value(t, sim.world_queue_input(*f.world, 1, 1, 2, 1, u8.[9, 9]), .Stale);
    expect_value(t, sim.world_queue_input(*f.world, 2, 1, 5, 1, u8.[9, 9]), .Invalid_Data);
    expect(t, sim.world_frame(*f.world, 4).meta[0].missing && f.missing > 0);
}

//@endregion
//@region 原子纠正、held世界与历史

world_reconcile_restores_interacting_systems_and_replays_together :: (t: *Test) {
    s, c: WX_Fixture;
    wx_init(*s, true);
    wx_init(*c, false);
    defer sim.world_destroy(*s.world);
    defer sim.world_destroy(*c.world);
    s.a.peer, s.b.peer = *s.b, *s.a;
    c.a.peer, c.b.peer = *c.b, *c.a;
    s.a.remote, c.a.remote = *s.remote, *c.remote;
    s.remote.value = 20;
    wx_seed(t, *s, *c);
    s.a.gain = 2; // 故意与本地规则不一致，强制校正。

    c.a.sample, c.b.sample = u8.[2, 1], u8.[1, 0];
    for tick: 1..3 {
        expect_value(t, sim.world_step(*c.world), .Ok);
        wx_input(t, *s, *c, (cast, trunc(u64)(tick)));
    }

    expect_value(t, sim.world_step(*s.world), .Ok);
    data, status := sim.world_encode_snapshot(*s.world, 1, 1);
    defer release(data);
    expect_value(t, status, .Ok);
    expect_value(t, sim.world_receive_snapshot(*c.world, data), .Ok);
    c.remote.value = 999; // 模拟该收包批的RPC/late-state写入，回放后必须保留。

    // 回放应使用正确的模拟规则，否则每次都会继续产生新mismatch。

    c.a.gain = 2;
    replayed, corrected, result := sim.world_reconcile(*c.world);
    expect(t, result == .Ok && corrected && replayed == 2);
    {
        loop_index := 0;
        while loop_index < 2 {
            defer loop_index += 1;
            expect_value(t, sim.world_step(*s.world), .Ok);
        }
    }

    expect_value(t, c.a.value, s.a.value);
    expect_value(t, c.b.value, s.b.value);
    expect_value(t, c.replay_remote, (cast, trunc(u64)(20)),);
    expect_value(t, c.remote.value, (cast, trunc(u64)(999)));
    expect(t, !c.remote.held && c.mode_starts == 1 && c.mode_ends == 1 && !c.replay_mode);
    expect_value(t, c.world.correction_serial, (cast, trunc(u64)(1)));
    expect_value(t, sim.world_receive_snapshot(*c.world, data), .Duplicate);
    _, _, status = sim.world_reconcile(*c.world);
    expect_value(t, status, .Empty);
};

world_snapshot_truncation_is_atomic_and_result_owner_checked :: (t: *Test) {
    s, c: WX_Fixture;
    wx_init(*s, true);
    wx_init(*c, false);
    defer sim.world_destroy(*s.world);
    defer sim.world_destroy(*c.world);
    wx_seed(t, *s, *c);
    c.a.sample = u8.[3, 1];
    expect_value(t, sim.world_step(*c.world), .Ok);
    wx_input(t, *s, *c, 1);
    expect_value(t, sim.world_step(*s.world), .Ok);
    data, status := sim.world_encode_snapshot(*s.world, 1);
    defer release(data);
    before := c.remote.value;
    {
        cut := 0;
        while cut < (data).count {
            defer cut += 1;

            status = sim.world_receive_snapshot(*c.world, view(data, 0, cut));
            expect(t, status != .Ok && c.remote.value == before && !c.world.pending.valid);
        }
    }

    result, rs := sim.world_encode_result(*c.world, 1, 1);
    defer release(result);
    expect_value(t, rs, .Ok);
    _, _, mismatch, check := sim.world_check_result(*s.world, 1, result);
    expect(t, check == .Ok && !mismatch);
    _, _, _, check = sim.world_check_result(*s.world, 2, result);
    expect_value(t, check, .Invalid_Data);
    result[(result).count - 1] ^= 1;
    _, _, mismatch, check = sim.world_check_result(*s.world, 1, result);
    expect(t, check == .Ok && mismatch && s.mismatches == 1);
}

world_history_overflow_recovers_from_absolute_world_state :: (t: *Test) {
    s, c: WX_Fixture;
    wx_init(*s, true, 4);
    wx_init(*c, false, 4);
    defer sim.world_destroy(*s.world);
    defer sim.world_destroy(*c.world);
    wx_seed(t, *s, *c);
    {
        loop_index := 0;
        while loop_index < 3 {
            defer loop_index += 1;
            expect_value(t, sim.world_step(*c.world), .Ok);
        }
    }

    expect_value(t, sim.world_step(*c.world), .Need_Resync);
    expect(t, c.world.needs_full);
    s.a.value = 17;
    expect_value(t, sim.world_step(*s.world), .Ok);
    data, status := sim.world_encode_snapshot(*s.world, 1);
    defer release(data);
    expect_value(t, status, .Ok);
    expect_value(t, sim.world_receive_snapshot(*c.world, data), .Ok);
    replayed, corrected, status2 := sim.world_reconcile(*c.world);
    expect(t, status2 == .Ok && corrected && replayed == 0 && c.world.tick == 1 && c.a.value == 17);
}

remote_clock_offset_jitter_monotone_release_and_idle_drain :: (t: *Test) {
    c: sim.Remote_Clock;
    expect_value(t, sim.clock_init(*c, .{
        fixed_ms = 20, interpolation_ticks = 2, input_lead_ticks = 1, max_lead_ticks = 16
    }), .Ok);
    expect_value(t, sim.clock_observe(*c, 100, 140, 1000, 50), .Ok);
    tick, status := sim.clock_estimate_tick(*c, 140);
    expect(t, status == .Ok && tick == 51);
    predict, ps := sim.clock_prediction_tick(*c, 140);
    expect(t, ps == .Ok && predict > tick);
    first, _ := sim.clock_release_tick(*c, 140);
    after, _ := sim.clock_release_tick(*c, 300);
    expect(t, after > first && after > 50, "last buffered sample releases even #if remote silent");
    expect_value(t, sim.clock_observe(*c, 100, 139, 999, 49), .Stale);
    expect_value(t, sim.clock_observe(*c, 200, 199, 1100, 55), .Invalid_Data);
    expect_value(t, sim.clock_observe(*c, 300, 380, 1240, 62), .Ok);
    expect(t, c.jitter_ms > 0);
    later, _ := sim.clock_release_tick(*c, 380);
    expect(t, later >= after);
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
