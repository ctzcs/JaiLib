#scope_module
using Basic;   // module-private
using Math;
#scope_export

// Port of Foster Framework/Utility/Time.cs.
// Times are stored in seconds (float64) instead of TimeSpan; the helper
// semantics match Calc.OnInterval / IntervalCount / BetweenInterval exactly.

Time :: struct {
    elapsed:      float64;   // accumulation of delta time since the app started (seconds)
    previous:     float64;   // the previous elapsed value
    frame:        u64;   // total update frames since the app started
    render_frame: u64;   // total render frames since the app started
}

time_delta :: (t: Time) -> float {
    return cast(float) (t.elapsed - t.previous);
}

// Advances elapsed by delta, increments frame. Does not touch render_frame.
time_advance :: (t: Time, delta: float64) -> Time {
    return .{
        elapsed = t.elapsed + delta,
        previous = t.elapsed,
        frame = t.frame + 1,
        render_frame = t.render_frame,
    };
}

time_advance_render_frame :: (t: Time) -> Time {
    return .{
        elapsed = t.elapsed,
        previous = t.previous,
        frame = t.frame,
        render_frame = t.render_frame + 1,
    };
}

// True when Time passes a given interval (ex: interval 0.1 → true one frame every 0.1s).
time_on_interval :: (t: Time, interval: float64, offset := 0.0) -> bool {
    delta := t.elapsed - t.previous;
    return floor((t.elapsed - offset - delta) / interval) < floor((t.elapsed - offset) / interval);
}

// How many times the interval was passed over the last frame.
time_interval_count :: (t: Time, interval: float64, offset := 0.0) -> s32 {
    delta := t.elapsed - t.previous;
    a := floor((t.elapsed - offset) / interval);
    b := floor((t.elapsed - offset - delta) / interval);
    return cast(s32) (a - b);
}

// True when Time is between the given interval
// (ex: interval 0.1 → false 0.1s, then true 0.1s, repeat).
time_between_interval :: (t: Time, interval: float64, offset := 0.0) -> bool {
    return mod_f64(t.elapsed - offset, interval * 2) >= interval;
}

time_between_interval2 :: (t: Time, false_interval: float64, true_interval: float64, offset := 0.0) -> bool {
    return mod_f64(t.elapsed - offset, false_interval + true_interval) >= false_interval;
}

// Cycles through `options` based on elapsed time, advancing every `interval` seconds.
time_cycle_interval :: (t: Time, interval: float64, offset: float64, options: [] $T) -> T {
    return options[cast(s64) ((t.elapsed - offset) / interval) % options.count];
}

time_cycle_interval :: (t: Time, interval: float64, options: [] $T) -> T {
    return time_cycle_interval(t, interval, 0, options);
}

// Sine-wave a value between from/to with a period of `duration` seconds.
time_sine_wave :: (t: Time, from: float, to: float, duration: float64, offset_percent := 0.0) -> float {
    input := mod_f64((t.elapsed + duration * offset_percent) / duration, 1.0);
    sine  := sin(input * TAU64);
    // Calc.ClampedMap(sine, -1, 1, from, to)
    mapped := from + cast(float) (sine + 1) * 0.5 * (to - from);
    return max(from, min(to, mapped));
}

// Returns a Time whose delta is multiplied by `multiplier` (slow-motion etc).
time_multiply_delta :: (t: Time, multiplier: float64) -> Time {
    return .{
        elapsed  = t.previous + (t.elapsed - t.previous) * multiplier,
        previous = t.previous,
        frame = t.frame,
        render_frame = t.render_frame,
    };
}

// C# % on doubles truncates toward zero; both operands here are non-negative
// in practice, so this floor-mod matches Foster's behavior.
mod_f64 :: (a: float64, b: float64) -> float64 {
    return a - b * floor(a / b);
}
