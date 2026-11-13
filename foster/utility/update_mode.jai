#scope_module
using Basic;   // module-private
#scope_export

// Port of Foster Framework/Utility/UpdateMode.cs.
//
// C# `TimeSpan` has no Jai twin here, so times are plain `float64` seconds —
// same convention as utility/time.jai. `UpdateMode.FixedStep(TimeSpan)` and
// `UpdateMode.FixedStep(int fps)` are the two C# overloads, spelled
// update_mode_fixed_step_seconds() / update_mode_fixed_step().

Update_Modes :: enum {
    // Not in Foster: zero-initialised App_Config keeps this, and app_run turns
    // it into a 60 Hz fixed step (Foster's App has no "unset" state either).
    NONE :: 0;
    FIXED;
    UNLOCKED;
}

Update_Mode :: struct {
    Mode:               Update_Modes;
    FixedTargetTime:    float64;   // seconds per fixed update  (C#: TimeSpan)
    FixedMaxTime:       float64;   // max time a fixed update may take (spiral-of-death guard)
    FixedWaitEnabled:   bool;      // main thread sleeps until the next fixed update is due
}

// C# UpdateMode.FixedStep(TimeSpan targetTimePerFrame, TimeSpan? maxTimePerFrame, bool)
// `max_time_per_frame` defaults to target*5, like C#.
update_mode_fixed_step_seconds :: (target_time_per_frame: float64, max_time_per_frame: float64 = 0.0, wait_for_next_update := true) -> Update_Mode {
    max_time := max_time_per_frame;
    if max_time <= 0.0 max_time = target_time_per_frame * 5.0;
    return .{
        Mode             = .FIXED,
        FixedTargetTime  = target_time_per_frame,
        FixedMaxTime     = max_time,
        FixedWaitEnabled = wait_for_next_update,
    };
}

// C# UpdateMode.FixedStep(int fps, bool)
update_mode_fixed_step :: (fps: s32, wait_for_next_update := true) -> Update_Mode {
    assert(fps > 0, "fps must be positive");
    return update_mode_fixed_step_seconds(1.0 / cast(float64) fps, wait_for_next_update = wait_for_next_update);
}

// C# UpdateMode.UnlockedStep()
update_mode_unlocked :: () -> Update_Mode {
    return .{ Mode = .UNLOCKED };
}

//
// Fixed-step scheduling
//
// The stepping itself lives in app_tick (app.jai, port of App.Tick): accumulate
// the frame delta, clamp it to FixedMaxTime so a long frame can't spiral, then
// run floor(accumulator / FixedTargetTime) fixed updates. That loop is tied to
// thread waits and the app's frame callbacks, so this file only mirrors its
// arithmetic in a pure, testable helper. app_tick does not use it (yet).
//

Fixed_Step_Clock :: struct {
    accumulator: float64;   // time fed in but not yet consumed by a fixed update
    dropped:     float64;   // time discarded by the FixedMaxTime clamp
    steps:       s32;       // fixed updates run so far
}

fixed_step_clock_create :: () -> Fixed_Step_Clock {
    return .{};
}

// Feeds `delta` seconds to the clock and returns how many updates to run this
// frame: 0 for NONE, floor(...) for FIXED, and 1 for UNLOCKED (one variable
// step of the whole delta, which is what app_tick does).
update_mode_fixed_steps :: (clock: *Fixed_Step_Clock, mode: Update_Mode, delta: float64) -> s32 {
    if mode.Mode == .UNLOCKED return 1;
    if mode.Mode != .FIXED return 0;
    if mode.FixedTargetTime <= 0.0 return 0;   // unset mode: never divide by zero

    clock.accumulator += delta;

    // do not allow any update to take longer than the max
    if clock.accumulator > mode.FixedMaxTime {
        clock.dropped += clock.accumulator - mode.FixedMaxTime;
        clock.accumulator = mode.FixedMaxTime;
    }

    steps := cast(s32) floor(clock.accumulator / mode.FixedTargetTime);
    if steps < 0 steps = 0;
    clock.accumulator -= cast(float64) steps * mode.FixedTargetTime;
    if clock.accumulator < 0.0 clock.accumulator = 0.0;   // rounding never leaves debt
    clock.steps += steps;
    return steps;
}
