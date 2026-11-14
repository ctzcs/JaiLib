#scope_file
simulation :: #import "thirdparty/onet/simulation";
#scope_export

//@region TrajectoryProjector: exact discrete Euler gravity and drag

Gravity_Projection :: enum {
    Auto;
    None;
    Apply;
}

project_position :: (dt, ticks: float64, position, velocity, gravity: simulation.Vec3, drag: float64) -> simulation.Vec3 {
    assert(finite(dt) && dt > 0 && finite(ticks) && ticks >= 0 && finite(drag));
    if drag <= 0 {
        seconds := dt * ticks;
        return position + velocity * seconds + gravity * (seconds * (seconds + dt) * 0.5);
    }

    if drag * dt >= 1 {
        return position;
    }

    retention := 1 - drag * dt;
    power := Math.pow(retention, ticks);
    offset := gravity * (dt - 1 / drag);
    integral := retention * (1 - power) / drag;
    return position + (velocity + offset) * integral - offset * (ticks * dt);
}

project_velocity :: (dt, ticks: float64, velocity, gravity: simulation.Vec3, drag: float64) -> simulation.Vec3 {
    assert(finite(dt) && dt > 0 && finite(ticks) && ticks >= 0 && finite(drag));
    if drag <= 0 {
        return velocity + gravity * (dt * ticks);
    }

    if drag * dt >= 1 {
        if ticks > 0 {
            return .{
            };
        };
        return velocity;
    }

    power := Math.pow(1 - drag * dt, ticks);
    offset := gravity * (dt - 1 / drag);
    return (velocity + offset) * power - offset;
}

project_rotation :: (dt, ticks: float64, rotation: simulation.Quat, angular_velocity: simulation.Vec3) -> simulation.Quat {
    speed := simulation.vec3_length(angular_velocity);
    if speed <= 0 {
        return rotation;
    }

    half := speed * dt * ticks * 0.5;
    axis := angular_velocity * (Math.sin(half) / speed);
    return simulation.quat_normalize(simulation.quat_multiply(.[
    axis[0], axis[1], axis[2], Math.cos(half)
    ], rotation));
};

extract_rotation_vector :: (from, to: simulation.Quat) -> simulation.Vec3 {
    a := simulation.quat_normalize(from);
    b := simulation.quat_normalize(to);
    delta := simulation.quat_multiply(b, .[
    -a[0], -a[1], -a[2], a[3]
    ]);
    if delta[3] < 0 {
        for *component: delta component.* = -component.*;
    }

    delta = simulation.quat_normalize(delta);
    axis := float64.[
    delta[0], delta[1], delta[2],
    ];
    sine := simulation.vec3_length(axis);
    if sine < 1.0e-6 {
        return .{
        };
    }

    return axis * (2 * Math.atan2(sine, clamp(delta[3], -1, 1)) / sine);
};

resolve_gravity :: (state: Snapshot, gravity: simulation.Vec3, mode: Gravity_Projection) -> simulation.Vec3 {
    if mode == {
        case .None;
            return .{
            };

        case .Apply; return gravity;
        case .Auto;
            speed := simulation.vec3_length(gravity);
            if speed <= 0 || dot3(state.linear_velocity, gravity / speed) <= 0.25 {
                return .{
                };
            }

            return gravity;
    }

    assert(false, "invalid gravity projection mode");
    return .{};
}

project_snapshot :: (state: Snapshot, dt, ticks: float64, gravity: simulation.Vec3, drag: float64, mode: Gravity_Projection) -> Snapshot {
    if has_flag(state.flags, .Sleeping) {
        return state;
    }

    g := resolve_gravity(state, gravity, mode);
    s := state;
    s.position = project_position(dt, ticks, state.position, state.linear_velocity, g, drag);
    s.linear_velocity = project_velocity(dt, ticks, state.linear_velocity, g, drag);
    s.rotation = project_rotation(dt, ticks, state.rotation, state.angular_velocity);
    return s;
}

dot3 :: (a, b: simulation.Vec3) -> float64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

//@endregion
//@region Swept target including optional reflected velocity

Sweep_Hit :: struct {
    position, normal: simulation.Vec3;
}

Shape_Sweep :: (user: *void, body: Body, from, to: simulation.Vec3) -> (Sweep_Hit, bool);

Swept_Target :: struct {
    user: *void;
    sweep: Shape_Sweep;
    minimum_distance: float64;
    reflect: bool;
    restitution: float64;
}

swept_target_default :: () -> Swept_Target {
    return .{
        minimum_distance = 0.05, restitution = 0.6,
    };
}

swept_project :: (provider: Swept_Target, body: Body, state: Snapshot, dt, ticks: float64, gravity: simulation.Vec3, drag: float64, mode: Gravity_Projection) -> (Snapshot, bool) {
    target := project_snapshot(state, dt, ticks, gravity, drag, mode);
    if provider.sweep == null || simulation.vec3_length(target.position - state.position) < provider.minimum_distance {
        return target, true;
    }

    hit, blocked := provider.sweep(provider.user, body, state.position, target.position);
    if !blocked {
        return target, true;
    }

    for v: hit.position {
        if !finite(v) {
            return .{
            }, false;
        };
    }

    for v: hit.normal {
        if !finite(v) {
            return .{
            }, false;
        };
    }

    target.position = hit.position;
    if provider.reflect {
        n := simulation.vec3_length(hit.normal);
        if n <= 1.0e-12 {
            return .{
            }, false;
        };

        normal := hit.normal / n;
        target.linear_velocity = (target.linear_velocity - normal * (2 * dot3(target.linear_velocity, normal))) * clamp(provider.restitution, 0, 1);
    }

    return target, true;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
