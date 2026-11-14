#scope_file

#scope_export
// Engine-independent fixed loop shared by world simulation and presentation.
// Callbacks run synchronously on one owner loop and borrow their slices.
//@region Fixed loop

Tick :: u64;
MAX_TICK :: ~(cast, trunc(u64)(0));
MAX_PAYLOAD :: 65536;
MAX_HISTORY :: 4096;
MAX_STORAGE :: 64 * 1024 * 1024;

Loop_Step :: enum {
    Receive;
    State_Apply;
    Reconcile;
    Fixed_Simulate;
    Serialize;
    Tick_Advance;
    Render;
}

Loop_Callback :: struct {
    user: *void;

    call: #type (user: *void, step: Loop_Step, tick: Tick, dt, alpha: float64);
}

Loop :: struct {
    fixed_dt, max_frame_dt, accumulator: float64;

    max_steps: int;

    tick: Tick;

    busy: bool;
}

Status :: enum {
    Ok;
    Invalid_Config;
    Invalid_Data;
    Schema_Mismatch;
    Truncated;
    Too_Large;
    Duplicate;
    Stale;
    Out_Of_Order;
    Queue_Full;
    Need_Resync;
    Empty;
    Expired;
    Not_Ready;
    Exhausted;
}

finite :: (v: float64) -> bool {
    return !Math.isnan(v) && !Math.isinf(v);
}

loop_init :: (l: *Loop, fixed_dt: float64, max_steps: int, max_frame_dt: float64) -> Status {
    if !finite(fixed_dt) || fixed_dt <= 0 || !finite(max_frame_dt) || max_frame_dt <= 0 ||
    max_steps < 1 || max_steps > 1024 || !finite(fixed_dt * (cast(float64) (max_steps))) {
        return .Invalid_Config;
    }

    l.* = Loop.{
        fixed_dt = fixed_dt, max_steps = max_steps, max_frame_dt = max_frame_dt, tick = 1,
    };

    return .Ok;
}

// Receive and Render run once, even without a fixed tick. The middle five stages
// run for EACH fixed tick. Tick_Advance observes the old tick, Render the new one.
// Excess elapsed time is dropped (returned in seconds), never deferred indefinitely.

loop_frame :: (l: *Loop, elapsed: float64, callbacks: [] Loop_Callback) -> (steps: int, dropped: float64, status: Status) {
    if l.busy || l.tick == 0 {
        return 0, 0, .Not_Ready;
    }

    if !finite(elapsed) || elapsed < 0 {
        return 0, 0, .Invalid_Data;
    }

    l.busy = true;
    defer l.busy = false;
    dt := min(elapsed, l.max_frame_dt);
    dropped = elapsed - dt;
    budget := l.fixed_dt * (cast(float64) (l.max_steps));
    total := l.accumulator + dt;
    if total > budget {
        dropped += total - budget;
        total = budget;
    }

    l.accumulator = total;
    loop_dispatch(callbacks, .Receive, l.tick, dt, 0);
    while l.accumulator >= l.fixed_dt && steps < l.max_steps {
        if l.tick == MAX_TICK {
            return steps, dropped, .Exhausted;
        }

        for stage: (Loop_Step.[.State_Apply, .Reconcile, .Fixed_Simulate, .Serialize, .Tick_Advance]) {
            loop_dispatch(callbacks, stage, l.tick, l.fixed_dt, 0);
        }

        l.tick += 1;
        l.accumulator = max((cast(float64) 0), l.accumulator - l.fixed_dt);
        steps += 1;
    }

    loop_dispatch(callbacks, .Render, l.tick, dt, clamp(l.accumulator / l.fixed_dt, 0, 1));
    return steps, dropped, .Ok;
}

loop_dispatch :: (callbacks: [] Loop_Callback, step: Loop_Step, tick: Tick, dt, alpha: float64) {
    for cb: callbacks {
        if cb.call != null {
            cb.call(cb.user, step, tick, dt, alpha);
        }
    }
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
