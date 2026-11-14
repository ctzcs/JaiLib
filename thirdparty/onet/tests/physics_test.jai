#scope_file
ref :: #import "thirdparty/onet/tests/support/reference_physics";
#scope_file
phy :: #import "thirdparty/onet/physics";
sim :: #import "thirdparty/onet/simulation";
#scope_export

//@region Capture, wire validation and first adoption

phy_snapshot_capture_wire_and_invalid_values :: (t: *Test) {
    body := ref.Test_Body.{
        state = ref.test_state(1, 1, 3),
    };

    body.state.rotation = .[
   0, 0, 0, 2,
   ];

    body.state.flags = (phy.Body_Flags.Sleeping | phy.Body_Flags.Kinematic);

    state, ok := phy.body_capture(ref.test_adapter(*body), 5, 0.25);
    expect(t, ok);
    expect_value(t, state.tick, (cast, trunc(u64)(5)));
    expect_value(t, state.time, (cast(float64) (0.25)));
    expect(t, phy.has_flag(state.flags, .Captured) && phy.has_flag(state.flags, .Sleeping) && phy.has_flag(state.flags, .Kinematic));
    expect_value(t, state.rotation, float64.[0, 0, 0, 1]);
    bytes: [phy.SNAPSHOT_SIZE] u8;
    expect_value(t, phy.snapshot_encode(view(bytes, 0), state), .Ok);
    decoded, status := phy.snapshot_decode(view(bytes, 0));
    expect_value(t, status, .Ok);
    expect_value(t, decoded.position, state.position);
    expect_value(t, decoded.flags, state.flags);
    {
        cut := 0;
        while cut < (bytes).count {
            defer cut += 1;

            _, status = phy.snapshot_decode(view(bytes, 0, cut));
            expect_value(t, status, .Truncated);
        }
    };

    bytes[2] = 1;
    _, status = phy.snapshot_decode(view(bytes, 0));
    expect_value(t, status, .Invalid_Data);
    bytes[2], bytes[1] = 0, 0xFF;
    _, status = phy.snapshot_decode(view(bytes, 0));
    expect_value(t, status, .Invalid_Data);
    state.position[0] = nan64();
    expect_value(t, phy.snapshot_encode(view(bytes, 0), state), .Invalid_Data);
}

phy_first_state_adopts_without_origin_smoothing_and_rejects_old :: (t: *Test) {
    // An uninitialized engine pose is allowed until the first authority adoption.

    body: ref.Test_Body;
    f: phy.Follower;
    expect_value(t, phy.follower_init(*f, ref.test_adapter(*body), phy.settings_default()), .Ok);
    defer phy.follower_destroy(*f);
    expect_value(t, phy.follower_step(*f, 1, 0.1), .Not_Ready);
    first := ref.test_state(10, 1, 100);
    first.rotation = .[
    0, 1, 0, 0,
    ];

    expect_value(t, phy.follower_receive(*f, first), .Ok);
    expect(t, f.has_received_state);
    expect_value(t, body.applies, 1);
    expect_value(t, body.last_mode, phy.Apply_Mode.Adopt);
    expect_value(t, body.state.position, first.position);
    expect_value(t, body.state.rotation, first.rotation);
    expect_value(t, phy.follower_receive(*f, first), .Duplicate);
    first.tick = 9;
    expect_value(t, phy.follower_receive(*f, first), .Stale);
    first.tick, first.time = 11, 0.9;
    expect_value(t, phy.follower_receive(*f, first), .Stale);
    expect_value(t, body.applies, 1);
    phy.follower_reset(*f);
    expect(t, !f.has_received_state);
    expect_value(t, phy.follower_receive(*f, ref.test_state(1, 0, 5)), .Ok);
    expect_value(t, body.state.position[0], (cast(float64) (5)));
}

//@endregion
//@region Pose convergence, teleport and body conditions

phy_position_rotation_converge_and_teleport_snaps_whole_pose :: (t: *Test) {
    body: ref.Test_Body;
    f: phy.Follower;
    settings := phy.settings_default();
    settings.position_rate, settings.rotation_rate = Math.log((cast(float64) (2))), Math.log((cast(float64) (2)));
    expect_value(t, phy.follower_init(*f, ref.test_adapter(*body), settings), .Ok);
    defer phy.follower_destroy(*f);
    phy.follower_receive(*f, ref.test_state(1, 1, 0));
    next := ref.test_state(2, 2, 2);
    next.rotation = .[
    0, 2, 0, 0,
    ];

    expect_value(t, phy.follower_receive(*f, next), .Ok);
    expect_value(t, phy.follower_step(*f, 2, 1), .Ok);
    expect(t, Math.abs(body.state.position[0] - 1) < 1.0e-12);
    expect(t, Math.abs(body.state.rotation[1] - Math.sqrt(cast(float64) 0.5)) < 1.0e-12);
    expect(t, Math.abs(sim.quat_dot(body.state.rotation, body.state.rotation) - 1) < 1.0e-12);
    expect_value(t, body.last_mode, phy.Apply_Mode.Smooth);
    next.tick, next.time, next.position, next.rotation = 3, 3, .[
    100, 0, 0,
    ], .[
    0, 0, 0, -4,
    ];

    phy.follower_receive(*f, next);
    expect_value(t, phy.follower_step(*f, 3, 0.01), .Ok);
    expect(t, f.teleported);
    expect_value(t, body.last_mode, phy.Apply_Mode.Teleport);
    expect_value(t, body.state.position[0], (cast(float64) (100)));
    expect(t, Math.abs(body.state.rotation[3]) == 1);
};

phy_sleep_and_kinematic_hold_without_gravity_then_wake :: (t: *Test) {
    body: ref.Test_Body;
    f: phy.Follower;
    settings := phy.settings_default();
    settings.use_gravity = true;
    phy.follower_init(*f, ref.test_adapter(*body), settings);
    defer phy.follower_destroy(*f);
    phy.follower_receive(*f, ref.test_state(1, 1, 0));
    state := ref.test_state(2, 2, 1);
    state.flags |= (phy.Body_Flags.Sleeping | phy.Body_Flags.Velocity);
    state.linear_velocity = .[
    99, 0, 0,
    ];

    phy.follower_receive(*f, state);
    expect_value(t, phy.follower_step(*f, 2.1, 0.1), .Ok);
    expect_value(t, body.last_mode, phy.Apply_Mode.Sleep);
    expect_value(t, body.state.position, state.position);
    expect_value(t, body.state.linear_velocity, float64.[0, 0, 0]);
    state = ref.test_state(3, 3, 2);
    state.flags |= (phy.Body_Flags.Kinematic | phy.Body_Flags.Velocity);
    state.linear_velocity = .[
    99, 0, 0,
    ];

    phy.follower_receive(*f, state);
    phy.follower_step(*f, 3.1, 0.1);
    expect_value(t, body.last_mode, phy.Apply_Mode.Kinematic);
    expect_value(t, body.state.position, state.position);
    state = ref.test_state(4, 4, 3);
    phy.follower_receive(*f, state);
    phy.follower_step(*f, 4, 0.1);
    expect(t, !phy.has_flag(body.state.flags, .Sleeping) && !phy.has_flag(body.state.flags, .Kinematic));
};

//@endregion
//@region Remote interpolation, velocity, bounded gravity and sweep

phy_remote_history_uses_simulation_interpolation :: (t: *Test) {
    body: ref.Test_Body;
    f: phy.Follower;
    settings := phy.settings_default();
    settings.position_rate, settings.rotation_rate, settings.teleport_distance = 1000, 1000, 100;
    phy.follower_init(*f, ref.test_adapter(*body), settings);
    defer phy.follower_destroy(*f);
    phy.follower_receive(*f, ref.test_state(1, 1, 0));
    phy.follower_receive(*f, ref.test_state(2, 2, 10));
    expect_value(t, f.latest.linear_velocity[0], (cast(float64) (10)));
    phy.follower_step(*f, 1.5, 1);
    expect(t, Math.abs(body.state.position[0] - 5) < 1.0e-12);
    phy.follower_step(*f, 2.1, 1);
    expect(t, Math.abs(body.state.position[0] - 11) < 1.0e-12);
    phy.follower_step(*f, 3, 1);
    expect(t, Math.abs(body.state.position[0] - 11.5) < 1.0e-12);
    expect_value(t, phy.follower_step(*f, 5, 1), .Expired);
    expect_value(t, phy.follower_step(*f, 2, -1), .Invalid_Data);
}

phy_optional_gravity_and_sweep_bound_motion :: (t: *Test) {
    body: ref.Test_Body;
    f: phy.Follower;
    settings := phy.settings_default();
    settings.position_rate, settings.rotation_rate, settings.teleport_distance = 1000, 1000, 100;
    settings.max_extrapolation, settings.use_gravity, settings.gravity = 0.5, true, .[
    0, -10, 0,
    ];

    phy.follower_init(*f, ref.test_adapter(*body), settings, ref.wall_sweep);
    defer phy.follower_destroy(*f);
    state := ref.test_state(1, 1, 0);
    state.flags |= (phy.Body_Flags.Velocity);
    state.linear_velocity = .[
    10, 0, 0,
    ];

    phy.follower_receive(*f, state);
    expect_value(t, phy.follower_step(*f, 2, 1), .Ok);
    expect(t, body.state.position[0] <= 1, "shape sweep prevents crossing the wall");
    expect(t, Math.abs(body.state.position[1] + 1.25) < 1.0e-12, "gravity uses capped 0.5 seconds");
    // Rotation uses shortest-arc normalization even if the authority sends -q.

    state.tick, state.time, state.rotation = 2, 2, .[
   0, 0, 0, -2,
   ];

    state.linear_velocity = .{
    };

    phy.follower_receive(*f, state);
    phy.follower_step(*f, 2, 1);
    expect(t, Math.abs(body.state.rotation[3]) > 0.999);
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
