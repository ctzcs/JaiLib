#scope_file
simulation :: #import "thirdparty/onet/simulation";
#scope_export

//@region Pose-only component, initial adoption and automatic registered body loop
// The motion component transmits pose/flags/capture tick, NOT velocities.
// A timestamp is explicit here to avoid tying engine-neutral packets to one clock.

MOTION_SIZE :: 80;

Motion_Component :: struct {
    state: Snapshot;

    capture_tick: simulation.Tick;

    has_state, adopted, changed: bool;
}

motion_encode :: (dst: [] u8, state: Snapshot) -> simulation.Status {
    if (dst).count != MOTION_SIZE {
        return .Truncated;
    }

    s := state;
    s.flags &= ~(Body_Flags.Velocity);
    s.linear_velocity, s.angular_velocity = .{
    }, .{
    };

    full: [SNAPSHOT_SIZE] u8;
    status := snapshot_encode(view(full, 0), s);
    if status == .Ok {
        copy_samples(dst, view(full, 0, MOTION_SIZE));
    };
    return status;
}

motion_decode :: (src: [] u8) -> (Snapshot, simulation.Status) {
    if (src).count != MOTION_SIZE {
        return .{
        }, .Truncated;
    };

    if (has_flag(bit_cast(Body_Flags, src[1]), .Velocity)) {
        return .{
        }, .Invalid_Data;
    };

    full: [SNAPSHOT_SIZE] u8;
    copy_samples(view(full, 0, MOTION_SIZE), src);
    return snapshot_decode(view(full, 0));
}

motion_capture :: (c: *Motion_Component, body: Body, tick: simulation.Tick, time: float64) -> simulation.Status {
    s, ok := body_capture(body, tick, time);
    if !ok {
        return .Invalid_Data;
    }

    if !c.has_state || s.position != c.state.position || s.rotation != c.state.rotation {
        c.capture_tick = tick;
    }

    s.flags &= ~(Body_Flags.Velocity);
    s.linear_velocity, s.angular_velocity = .{
    }, .{
    };

    c.changed = !c.has_state || s.position != c.state.position || s.rotation != c.state.rotation || s.flags != c.state.flags;
    if !c.changed {
        return .Ok;
    }
    // quiet packets must keep their original wire tick/time

    c.state, c.has_state = s, true;
    return .Ok;
};

motion_receive :: (c: *Motion_Component, state: Snapshot, tick_delta: float64) -> simulation.Status {
    if !snapshot_valid(state) || !finite(tick_delta) || tick_delta <= 0 {
        return .Invalid_Data;
    }

    if c.has_state {
        if state.tick == c.state.tick {
            return .Duplicate;
        }

        if state.tick < c.state.tick || state.time <= c.state.time {
            return .Stale;
        }
    }

    s := state;
    s.rotation = simulation.quat_normalize(s.rotation);
    s.linear_velocity, s.angular_velocity = .{
    }, .{
    };

    if c.has_state && !has_flag(s.flags, .Sleeping) {
        seconds := (cast(float64) (s.tick - c.state.tick)) * tick_delta;
        s.linear_velocity = (s.position - c.state.position) / seconds;
        s.angular_velocity = extract_rotation_vector(c.state.rotation, s.rotation) / seconds;
    }

    s.flags |= (Body_Flags.Velocity);
    if !snapshot_valid(s) {
        return .Invalid_Data;
    }

    c.state, c.has_state, c.capture_tick = s, true, s.tick;
    return .Ok;
};

motion_adopt :: (c: *Motion_Component, body: Body) -> bool {
    if !c.has_state || c.adopted {
        return false;
    }

    if !body_apply(body, c.state, .Adopt) {
        return false;
    };
    c.adopted = true;
    return true;
}

motion_reset :: (c: *Motion_Component) {
    c.* = .{
    };
}

Body_Binding :: struct {
    adapter: Adapter;

    component: Motion_Component;

    convergence: Convergence;

    authority: bool;

    status: simulation.Status;

    userdata: *void;

    on_capture: #type (*void, u64, Snapshot);
    // caller can route pose-only motion_encode
}

// World_Adapter and Body_System addresses stay fixed until destroy. Body data
// must live through each step; detach uses cached opaque handles, not bindings.
// set_enabled(false) must not dereference body.user (runtime may have despawned
// it), and must exclude contacts/forces as well as pose integration. nil step
// explicitly selects capture/presentation-only mode; a solver needs set_enabled.

World_Adapter :: struct {
    user: *void;

    step: #type (user: *void, dt: float64);

    set_enabled: #type (user: *void, body: Body, enabled: bool);

    bound_system: *Body_System;
    // maintained by init/destroy; do not modify
}

Body_System :: struct {
    bindings: H.Table(u64, *Body_Binding);

    registered_bodies: H.Table(u64, Body);
    // stable detach handles; no freed binding reads

    ids: [..] u64;

    world: *World_Adapter;

    max_bodies: int;

    initialized, stepping: bool;

    last_tick: simulation.Tick;

    last_time: float64;

    host: *void;
    // exclusive runtime borrower; unbind before destroy
}

body_system_init :: (s: *Body_System, world: *World_Adapter, max_bodies: int = 1024) -> bool {
    if s.initialized || world == null || world.bound_system != null || max_bodies <= 0 {
        return false;
    }

    if world.step != null && world.set_enabled == null {
        return false;
    }

    s.bindings = new_table(u64, *Body_Binding);
    s.registered_bodies = new_table(u64, Body);
    s.ids = new_dynamic(u64);
    s.world, s.max_bodies, s.initialized = world, max_bodies, true;
    world.bound_system = s;
    return true;
}

body_system_register :: (s: *Body_System, id: u64, b: *Body_Binding) -> bool {
    if !s.initialized || s.world.bound_system != s || s.stepping || id == 0 || b == null || b.adapter.body.capture == null || b.adapter.body.apply == null || b.adapter.properties == null || !convergence_valid(*b.convergence) {
        return false;
    }

    {
        _, ok := table_get(*s.bindings, id);
        if
        ok || (s.bindings).count >= s.max_bodies {
            return false;
        }
    }

    for bound_id: s.ids {
        if table_get(*s.bindings, bound_id) == b || table_get(*s.registered_bodies, bound_id).user == b.adapter.body.user {
            return false;
        }
    }

    H.table_set(*s.bindings, id, b);
    H.table_set(*s.registered_bodies, id, b.adapter.body);
    array_add(*s.ids, id);
    i := (s.ids).count - 1;
    while i > 0 && s.ids[i - 1] > id {
        s.ids[i] = s.ids[i - 1];
        i -= 1;
    }

    s.ids[i] = id;
    // A newly created proxy must not touch the solver before its first sample.

    if s.world.set_enabled != null {
        s.world.set_enabled(s.world.user, b.adapter.body, false);
    }

    return true;
}

body_system_unregister :: (s: *Body_System, id: u64) {
    if !s.initialized || s.world.bound_system != s || s.stepping {
        return;
    }

    body, ok := table_get(*s.registered_bodies, id);
    if !ok {
        return;
    }

    if s.world.set_enabled != null {
        s.world.set_enabled(s.world.user, body, false);
    }

    H.table_remove(*s.bindings, id);
    H.table_remove(*s.registered_bodies, id);
    for v, i: s.ids {
        if v != id {
            continue;
        }

        {
            j := i;
            while j < (s.ids).count - 1 {
                defer j += 1;
                s.ids[j] = s.ids[j + 1];
            }
        }

        array_resize(*s.ids, (s.ids).count - 1);
        break;
    }
}

body_system_receive :: (s: *Body_System, id: u64, payload: [] u8, tick_delta: float64) -> simulation.Status {
    if !s.initialized || s.world.bound_system != s || s.stepping {
        return .Not_Ready;
    }

    b := table_get(*s.bindings, id);
    if b == null || b.authority {
        return .Not_Ready;
    }

    state, status := motion_decode(payload);
    if status != .Ok {
        return status;
    }

    return motion_receive(*b.component, state, tick_delta);
}

// One transaction per fixed tick: all prepare -> ONE world step -> all capture.
// Callbacks must not reenter or alter bindings, adapters or solver membership.

body_system_step :: (s: *Body_System, tick: simulation.Tick, now, dt: float64) -> simulation.Status {
    if !s.initialized || s.world.bound_system != s || s.stepping {
        return .Not_Ready;
    }

    if tick == 0 || !finite(now) || !finite(dt) || dt <= 0 {
        return .Invalid_Data;
    }

    if tick == s.last_tick {
        return .Duplicate;
    }

    if tick < s.last_tick || (s.last_tick != 0 && now < s.last_time) {
        return .Stale;
    }

    s.stepping = true;
    defer s.stepping = false;
    s.last_tick, s.last_time = tick, now;
    result := simulation.Status.Ok;
    for id: s.ids {
        b := table_get(*s.bindings, id);
        b.status = .Ok;
        if !b.authority {
            if !b.component.has_state {
                b.status = .Not_Ready;
            } else if !b.component.adopted {
                if !motion_adopt(*b.component, b.adapter.body) {
                    b.status = .Invalid_Data;
                }
            } else if !b.adapter.properties(b.adapter.body.user).kinematic {
                if has_flag(b.component.state.flags, .Sleeping) {
                    if !body_apply(b.adapter.body, b.component.state, .Sleep) {
                        b.status = .Invalid_Data;
                    }
                } else {
                    b.status = convergence_step(*b.convergence, b.adapter, b.component.state, dt, (now - b.component.state.time) / dt);
                }
            }
        }

        if s.world.set_enabled != null {
            s.world.set_enabled(s.world.user, b.adapter.body, b.status == .Ok);
        }

        if b.status != .Ok && b.status != .Not_Ready {
            result = b.status;
        }
    }

    if s.world.step != null {
        s.world.step(s.world.user, dt);
    }

    for id: s.ids {
        b := table_get(*s.bindings, id);
        if !b.authority {
            continue;
        }

        b.status = motion_capture(*b.component, b.adapter.body, tick, now);
        if b.status != .Ok {
            result = b.status;
        }
    }

    // Publish only after every authority has captured this solver result.

    for id: s.ids {
        b := table_get(*s.bindings, id);
        if b.authority && b.status == .Ok && b.component.changed && b.on_capture != null {
            b.on_capture(b.userdata, id, b.component.state);
        }
    }

    return result;
}

body_system_destroy :: (s: *Body_System) {
    assert(!s.stepping && s.host == null);
    if !s.initialized {
        return;
    }

    assert(s.world.bound_system == s);
    while (s.ids).count > 0 {
        body_system_unregister(s, s.ids[0]);
    }

    s.world.bound_system = null;
    release(s.ids);
    release(s.registered_bodies);
    release(s.bindings);
    s.* = .{
    };
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
