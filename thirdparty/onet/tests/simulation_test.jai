#scope_file
sim :: #import "thirdparty/onet/simulation";
#scope_export

//@region Explicit byte fixtures shared by world and interpolation tests

sim_put :: (dst: [] u8, value: u64) {
    {
        i := 0;
        while i < 8 {
            defer i += 1;
            dst[i] = (cast, trunc(u8)(value >> cast, trunc(u64)(i * 8)));
        }
    }
}

sim_get :: (src: [] u8) -> (value: u64) {
    for byte, i: src {
        value |= (cast, trunc(u64)(byte)) << cast, trunc(u64)(i * 8);
    };
    return;
}

//@endregion
//@region Fixed loop and remote interpolation

Sim_Loop_Log :: struct {
    steps: [32] sim.Loop_Step;
    ticks: [32] sim.Tick;
    count: int;
}

sim_log_step :: (user: *void, step: sim.Loop_Step, tick: sim.Tick, dt, alpha: float64) {
    log := (cast(*Sim_Loop_Log) user);
    log.steps[log.count], log.ticks[log.count] = step, tick;
    log.count += 1;
}

sim_loop_order_bounded_catchup_and_invalid_elapsed :: (t: *Test) {
    loop: sim.Loop;
    expect_value(t, sim.loop_init(*loop, 0.25, 2, 2), .Ok);
    log: Sim_Loop_Log;
    callbacks := sim.Loop_Callback.[.{
        user = *log, call = sim_log_step
        , }];
    n, dropped, status := sim.loop_frame(*loop, 2, view(callbacks, 0));
    expect(t, status == .Ok && n == 2 && dropped == 1.5);
    expected: [] sim.Loop_Step = sim.Loop_Step.[.Receive, .State_Apply, .Reconcile, .Fixed_Simulate, .Serialize, .Tick_Advance, .State_Apply, .Reconcile, .Fixed_Simulate, .Serialize, .Tick_Advance, .Render];
    expect_value(t, log.count, (expected).count);
    for stage, i: expected {
        expect_value(t, log.steps[i], stage);
    }

    expect(t, log.ticks[1] == 1 && log.ticks[6] == 2 && log.ticks[11] == 3);
    _, _, status = sim.loop_frame(*loop, -1, view(callbacks, 0));
    expect_value(t, status, .Invalid_Data);
    _, _, status = sim.loop_frame(*loop, nan64(), view(callbacks, 0));
    expect_value(t, status, .Invalid_Data);
    expect_value(t, log.count, 12);
    log.count = 0;
    n, _, status = sim.loop_frame(*loop, 0.125, view(callbacks, 0));
    expect(t, status == .Ok && n == 0 && log.steps[0] == .Receive && log.steps[1] == .Render);
}

sim_blend_float :: (user: *void, a, b: [] u8, factor: float64, dst: [] u8) {
    x, y := bit_cast(float64, sim_get(a)), bit_cast(float64, sim_get(b));
    sim_put(dst, bit_cast(u64, sim.lerp_scalar(x, y, factor)));
}

sim_remote_buffer_interpolation_bounded_extrapolation_and_eviction :: (t: *Test) {
    buffer: sim.Buffer;
    assert(sim.buffer_init(*buffer, .{
        capacity = 3, value_size = 8, max_age = 4, max_extrapolation = 0.5
    }, sim_blend_float) == .Ok);
    defer sim.buffer_destroy(*buffer);
    value, dst: [8] u8;
    sim_put(view(value, 0), bit_cast(u64, (cast(float64) (0))));
    assert(sim.buffer_push(*buffer, 1, 1, view(value, 0)) == .Ok);
    sim_put(view(value, 0), bit_cast(u64, (cast(float64) (10))));
    assert(sim.buffer_push(*buffer, 2, 2, view(value, 0)) == .Ok);
    value[0] = 0xFF;
    mode, status := sim.buffer_sample(*buffer, 1.5, view(dst, 0));
    expect(t, status == .Ok && mode == .Interpolated && bit_cast(float64, sim_get(view(dst, 0))) == 5);
    mode, status = sim.buffer_sample(*buffer, 2.25, view(dst, 0));
    expect(t, status == .Ok && mode == .Extrapolated && bit_cast(float64, sim_get(view(dst, 0))) == 12.5);
    mode, status = sim.buffer_sample(*buffer, 3, view(dst, 0));
    expect(t, status == .Ok && mode == .Clamped && bit_cast(float64, sim_get(view(dst, 0))) == 15);
    expect_value(t, sim.buffer_push(*buffer, 2, 3, view(value, 0)), .Duplicate);
    expect_value(t, sim.buffer_push(*buffer, 1, 3, view(value, 0)), .Stale);
    expect_value(t, sim.buffer_push(*buffer, 3, 1.9, view(value, 0)), .Stale);
    _, status = sim.buffer_sample(*buffer, 7, view(dst, 0));
    expect_value(t, status, .Expired);
    for tick: (cast, trunc(u64)(3))..(cast, trunc(u64)(4)) {
        sim.buffer_push(*buffer, tick, (cast(float64) (tick)), view(value, 0));
    }

    expect(t, buffer.count == 3 && buffer.samples[buffer.head].tick == 2);
    expect_value(t, sim.buffer_push(*buffer, 10, 10, view(value, 0)), .Ok);
    expect_value(t, buffer.count, 1);
};

sim_quaternion_shortest_arc_normalization_and_vec_helpers :: (t: *Test) {
    identity := float64.[
   0, 0, 0, 2,
   ];

    q := sim.quat_slerp(identity, .[
   0, 0, 0, -5
   ], 0.5);
    expect(t, Math.abs(q[3] - 1) < 1.0e-12);
    q = sim.quat_slerp(identity, .[
    0, 2, 0, 0
    ], 0.5);
    expect(t, Math.abs(sim.quat_dot(q, q) - 1) < 1.0e-12 && Math.abs(q[1] - Math.sqrt(cast(float64) 0.5)) < 1.0e-12);
    expect_value(t, sim.quat_normalize(.{
    }), float64.[0, 0, 0, 1]);
    expect_value(t, sim.lerp_vec3(.[
    0, 2, 4
    ], .[
    2, 4, 6
    ], 0.5), float64.[1, 3, 5]);
};

sim_tick_exhaustion_never_wraps :: (t: *Test) {
    f: WX_Fixture;
    wx_init(*f, true);
    defer sim.world_destroy(*f.world);
    f.world.tick = sim.MAX_TICK - 2;
    expect_value(t, sim.world_step(*f.world), .Ok);
    expect_value(t, sim.world_step(*f.world), .Exhausted);
    expect_value(t, f.world.tick, sim.MAX_TICK - 1);
    loop: sim.Loop;
    sim.loop_init(*loop, 0.5, 2, 2);
    loop.tick = sim.MAX_TICK;
    _, _, status := sim.loop_frame(*loop, 0.5, .[]);
    expect_value(t, status, .Exhausted);
    expect_value(t, loop.tick, sim.MAX_TICK);
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
