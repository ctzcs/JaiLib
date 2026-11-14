#scope_file
ref :: #import "thirdparty/onet/tests/support/reference_physics";
#scope_file
phy :: #import "thirdparty/onet/physics";
#scope_export

//@region Instrumented interacting world, independent solver math

WS_Body :: struct {
    native: ref.Native_Body;
    id: u64;
    world: *WS_World;
    authority: bool;
}

WS_World :: struct {
    t: *Test;

    system: *phy.Body_System;

    bodies: [5] *WS_Body;

    active: [5] bool;

    events: [..] int;

    steps, prepared: int;

    phase: int;
}

ws_capture :: (user: *void) -> phy.Snapshot {
    b := (cast(*WS_Body) user);
    if b.authority {
        expect_value(b.world.t, b.world.phase, 2);
        array_add(*b.world.events, 100 + (cast(int) (b.id)));
    }

    return b.native.state;
}

ws_apply :: (user: *void, state: phy.Snapshot, mode: phy.Apply_Mode) {
    b := (cast(*WS_Body) user);
    expect_value(b.world.t, b.world.phase, 1);
    ref.native_apply(*b.native, state, mode);
}

ws_properties :: (user: *void) -> phy.Body_Properties {
    return ref.native_properties(*((cast(*WS_Body) user)).native);
}

ws_enable :: (user: *void, body: phy.Body, enabled: bool) {
    w := (cast(*WS_World) user);
    b := (cast(*WS_Body) body.user);
    for candidate, i: w.bodies {
        if candidate == b {
            w.active[i] = enabled;
        }
    }

    if w.phase == 1 {
        array_add(*w.events, (cast(int) (b.id)));
        w.prepared += 1;
    }
}

ws_step :: (user: *void, dt: float64) {
    w := (cast(*WS_World) user);
    expect_value(w.t, w.phase, 1);
    expect_value(w.t, w.prepared, 5);
    expect_value(w.t, w.bodies[0].native.last_mode, phy.Apply_Mode.Adopt);
    expect_value(w.t, w.bodies[2].native.last_mode, phy.Apply_Mode.Adopt);
    expect(w.t, !w.active[4]);
    expect_value(w.t, phy.body_system_step(w.system, 2, 0.2, dt), .Not_Ready);
    array_add(*w.events, 1000);
    w.steps += 1;
    // Equal masses in an approaching 1D contact exchange velocities. This reads
    // BOTH bodies before either integrates; it cannot be a per-body callback.

    a, b := *w.bodies[1].native, *w.bodies[3].native;
    if b.state.position[0] - a.state.position[0] < 1 && a.state.linear_velocity[0] > b.state.linear_velocity[0] {
        a.state.linear_velocity, b.state.linear_velocity = b.state.linear_velocity, a.state.linear_velocity;
    }

    for body, i: w.bodies {
        if w.active[i] {
            ref.native_simulate(*body.native, dt);
        }
    }

    w.phase = 2;
}

ws_publish :: (user: *void, id: u64, state: phy.Snapshot) {
    w := (cast(*WS_World) user);
    expect_value(w.t, w.phase, 2);
    expect(w.t, table_get(*w.system.bindings, 20).component.has_state && table_get(*w.system.bindings, 40).component.has_state);
    array_add(*w.events, 200 + (cast(int) (id)));
}

physics_world_prepares_all_steps_once_then_captures_all_in_stable_id_order :: (t: *Test) {
    s: phy.Body_System;
    w := WS_World.{
        t = t, system = *s,
    };

    defer release(w.events);
    adapter := phy.World_Adapter.{
        user = *w, step = ws_step, set_enabled = ws_enable,
    };

    expect(t, phy.body_system_init(*s, *adapter));
    defer phy.body_system_destroy(*s);
    bodies: [5] WS_Body;
    bindings: [5] phy.Body_Binding;
    for *body, i: bodies {
        ref.native_body_init(*body.*.native);
        body.*.native.gravity = .{
        };

        body.*.id, body.*.world, body.*.authority = (cast, trunc(u64)((i + 1) * 10)), *w, i == 1 || i == 3;
        w.bodies[i] = body;
        bindings[i] = .{ adapter = .{ body = .{ user = body, capture = ws_capture, apply = ws_apply, }, properties = ws_properties, }, convergence = phy.convergence_default(), authority = body.*.authority, userdata = *w, on_capture = ws_publish, };

        if !body.*.authority && i != 4 {
            state := ref.test_state(1, 0, 10 + (cast(float64) (i)));
            phy.motion_receive(*bindings[i].component, state, 0.1);
        }
    };

    bodies[1].native.state.position = .[
   0, 0, 0,
   ];
    bodies[1].native.state.linear_velocity = .[
    1, 0, 0,
    ];

    bodies[3].native.state.position = .[
   0.5, 0, 0,
   ];
    bodies[3].native.state.linear_velocity = .[
    -1, 0, 0,
    ];

    bodies[4].native.state.linear_velocity = .[
   100, 0, 0,
   ];

    // Deliberately scrambled registration/map order.

    for i: (int.[3, 0, 4, 1, 2]) {
        expect(t, phy.body_system_register(*s, bodies[i].id, *bindings[i]));
    }

    w.phase = 1;
    expect_value(t, phy.body_system_step(*s, 1, 0.1, 0.1), .Ok);
    expected: [] int = int.[10, 20, 30, 40, 50, 1000, 120, 140, 220, 240];
    expect_value(t, (w.events).count, (expected).count);
    for event, i: w.events {
        if i < (expected).count {
            expect_value(t, event, expected[i]);
        }
    }

    expect_value(t, w.steps, 1);
    expect_value(t, bodies[1].native.state.position[0], (cast(float64) (-0.1)));
    expect_value(t, bodies[3].native.state.position[0], (cast(float64) (0.6)));
    expect_value(t, bindings[1].component.state.position, bodies[1].native.state.position);
    expect_value(t, bindings[3].component.state.position, bodies[3].native.state.position);
    expect_value(t, bodies[4].native.steps, (cast, trunc(u64)(0)));
    expect_value(t, bindings[4].status, .Not_Ready);
    expect_value(t, phy.body_system_step(*s, 1, 0.1, 0.1), .Duplicate);
    expect_value(t, phy.body_system_step(*s, 0, 0, 0.1), .Invalid_Data);
    expect_value(t, phy.body_system_step(*s, 2, 0.09, 0.1), .Stale);
    expect_value(t, phy.body_system_step(*s, 2, 0.2, 0), .Invalid_Data);
    expect_value(t, w.steps, 1);
    expect_value(t, (w.events).count, (expected).count);
};

//@endregion
//@region Explicit no-solver configuration and borrowed address lifetime

physics_world_configuration_exclusive_binding_detach_and_reuse :: (t: *Test) {
    s, other: phy.Body_System;
    expect(t, !phy.body_system_init(*s, null));
    invalid := phy.World_Adapter.{
        step = (user: *void, dt: float64) {}
    };

    expect(t, !phy.body_system_init(*s, *invalid));
    world: ref.World;
    defer ref.world_destroy(*world);
    adapter := ref.world_adapter(*world);
    expect(t, phy.body_system_init(*s, *adapter, 2));
    expect(t, !phy.body_system_init(*other, *adapter));
    body: ref.Native_Body;
    ref.native_body_init(*body);
    body.gravity = .{
    };
    body.state.linear_velocity = .[
    1, 0, 0,
    ];

    binding := phy.Body_Binding.{
        adapter = ref.native_adapter(*body), authority = true, convergence = phy.convergence_default(),
    };

    expect(t, phy.body_system_register(*s, 1, *binding));
    expect(t, !phy.body_system_register(*s, 2, *binding));
    phy.body_system_step(*s, 1, 0.1, 0.1);
    expect_value(t, world.steps, (cast, trunc(u64)(1)));
    expect_value(t, (world.active).count, 1);
    phy.body_system_destroy(*s);
    expect(t, adapter.bound_system == null && (world.active).count == 0);
    // Destroy did not delete/reset the borrowed body or solver world.

    expect_value(t, body.state.position[0], (cast(float64) (0.1)));
    expect_value(t, world.steps, (cast, trunc(u64)(1)));
    expect(t, phy.body_system_init(*other, *adapter));
    phy.body_system_destroy(*other);
    capture_only: phy.World_Adapter; // required explicit configuration, not a fallback

    expect(t, phy.body_system_init(*s, *capture_only));
    defer phy.body_system_destroy(*s);
    expect(t, phy.body_system_register(*s, 1, *binding));
    expect_value(t, phy.body_system_step(*s, 1, 0.1, 0.1), .Ok);
    expect_value(t, body.steps, (cast, trunc(u64)(1)));
    expect_value(t, binding.component.state.position, body.state.position);
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
