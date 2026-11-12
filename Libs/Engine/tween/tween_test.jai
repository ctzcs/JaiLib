#import "Basic";
#import "test_support";
#import "tween/interpolated";
#import "tween/tween";
#import "tween/manager";
#import "tween/managed_tween";
#import "tween/managed_sequence";

// Port of tween/test.odin (which was a print-based smoke test): the key
// behaviors are checked with assertions instead of printed output.

lerp_f32 :: (a: float32, b: float32, ratio: float32) -> float32 {
    return a + (b - a) * ratio;
}

managed_value: float32;
managed_step_count: s32;
managed_start_count: s32;
managed_complete_count: s32;
managed_kill_count: s32;

set_managed_value :: (value: float32) {
    managed_value = value;
}

on_managed_step_complete :: (handle: Tween_Handle) {
    managed_step_count += 1;
}

on_managed_start :: (handle: Tween_Handle) {
    managed_start_count += 1;
}

on_managed_complete :: (handle: Tween_Handle) {
    managed_complete_count += 1;
}

on_managed_kill :: (handle: Tween_Handle) {
    managed_kill_count += 1;
}

test_tween_values :: (state: *Test_State) {
    // once + ease-out: reaches finish at t=1 and stays finished
    tw := make_ex(0.0, 10.0, 0, Tween_Config.{ duration = 1.0, transition = .EaseOut }, lerp_f32);
    expect(state, tween_get_value(*tw, 0.0) == 0.0, "t0 value 0");
    expect(state, !tween_is_finished(*tw, 0.5), "not finished at 0.5");
    expect(state, tween_get_value(*tw, 1.0) == 10.0, "t1 value 10");
    expect(state, tween_is_finished(*tw, 1.25), "finished at 1.25");
    expect(state, tween_get_value(*tw, 1.25) == 10.0, "value stays 10");

    // pingpong bounces between start and finish
    pp := make_ex(0.0, 100.0, 0, Tween_Config.{ duration = 1.0, repeat_mode = .PingPong, transition = .Linear }, lerp_f32);
    expect(state, tween_get_value(*pp, 0.5) == 50.0, "pingpong 0.5 -> 50");
    expect(state, tween_get_value(*pp, 1.5) == 50.0, "pingpong 1.5 -> 50 (returning)");
    expect(state, tween_get_value(*pp, 2.0) == 0.0, "pingpong 2.0 -> 0");
    expect(state, tween_get_value(*pp, 3.0) == 100.0, "pingpong 3.0 -> 100");
    expect(state, !tween_is_finished(*pp, 5.0), "pingpong never finishes");

    // delay + loop
    lp := make_ex(0.0, 1.0, 0, Tween_Config.{ duration = 0.5, delay = 0.25, repeat_mode = .Loop, transition = .Linear }, lerp_f32);
    expect(state, tween_get_value(*lp, 0.0) == 0.0, "loop delayed t0");
    expect(state, tween_get_value(*lp, 0.25) == 0.0, "loop starts after delay");
    expect(state, tween_get_value(*lp, 0.5) == 0.5, "loop t0.5 -> 0.5");
    expect(state, tween_get_value(*lp, 0.75) == 0.0, "loop wraps at 0.75");
    expect(state, tween_get_value(*lp, 1.0) == 0.5, "loop t1.0 -> 0.5");

    // transition proc
    ct := make_ex(0.0, 1.0, 0, Tween_Config.{ duration = 1.0, transition = .Linear }, lerp_f32);
    tween_set_transition_proc(*ct, (t: float32) -> float32 { return t * t; });
    expect(state, tween_get_value(*ct, 0.5) == 0.25, "custom transition t0.5 -> 0.25");
}

test_tween_manager :: (state: *Test_State) {
    mgr := manager_make();
    defer manager_delete(*mgr);

    managed_value = -1;
    managed_step_count = 0;
    managed_start_count = 0;
    managed_complete_count = 0;
    managed_kill_count = 0;

    tw := make_ex(0.0, 10.0, 0, Tween_Config.{ duration = 1.0, delay = 0.25, transition = .Linear }, lerp_f32);
    h := manager_add_tween(*mgr, tw, set_managed_value);
    expect(state, managed_value == 0.0, "start value pushed on register");
    expect(state, manager_is_handle_valid(mgr, h), "handle valid after add");
    _ = manager_on_start(*mgr, h, on_managed_start);
    _ = manager_on_complete(*mgr, h, on_managed_complete);
    _ = manager_on_kill(*mgr, h, on_managed_kill);

    manager_update(*mgr, 0.1); // now=0.1, still delayed
    expect(state, managed_value == 0.0, "still delayed at now=0.1");

    manager_update(*mgr, 0.2); // now=0.3, past the 0.25 delay
    expect(state, managed_value > 0.0, "value moved after delay");
    expect(state, managed_start_count == 1, "on_start fired once");

    manager_update(*mgr, 0.5); // now=0.8, tween duration 1.0 (elapsed 0.55)
    manager_update(*mgr, 0.5); // now=1.3 > 1.25 -> complete
    expect(state, managed_value == 10.0, "completed value 10");
    expect(state, managed_complete_count == 1, "on_complete fired");

    manager_update(*mgr, 0.1);
    expect(state, !manager_is_handle_valid(mgr, h), "auto-killed after completion");
    expect(state, managed_kill_count == 0, "auto-kill cleanup does not fire on_kill");

    // pause / play / kill
    h2 := manager_add_tween(*mgr, tw, set_managed_value);
    expect(state, manager_pause(*mgr, h2), "pause ok");
    manager_update(*mgr, 0.5);
    expect(state, managed_value == 0.0, "paused tween does not advance");
    expect(state, manager_play(*mgr, h2), "play ok");
    manager_update(*mgr, 0.5);
    expect(state, managed_value > 0.0, "resumed tween advances");

    expect(state, manager_kill(*mgr, h2), "kill ok");
    manager_update(*mgr, 0.1);
    expect(state, !manager_is_handle_valid(mgr, h2), "killed node cleaned up");
}

test_tween_sequence :: (state: *Test_State) {
    mgr := manager_make();
    defer manager_delete(*mgr);

    managed_value = -1;
    seq := manager_add_sequence(*mgr);

    tw1 := make_ex(0.0, 10.0, 0, Tween_Config.{ duration = 1.0, transition = .Linear }, lerp_f32);
    h1, ok := sequence_append_tween(*mgr, seq, tw1, set_managed_value);
    expect(state, ok && !(h1 == TWEEN_HANDLE_NONE), "append tween ok");

    tw2 := make_ex(10.0, 20.0, 0, Tween_Config.{ duration = 1.0, transition = .Linear }, lerp_f32);
    _, ok2 := sequence_append_tween(*mgr, seq, tw2, set_managed_value);
    expect(state, ok2, "append second tween ok");

    manager_update(*mgr, 0.5);
    expect(state, managed_value == 5.0, "seq: first tween at half");
    manager_update(*mgr, 0.5); // now=1.0
    expect(state, managed_value == 10.0, "seq: first tween done");
    manager_update(*mgr, 0.5); // now=1.5
    expect(state, managed_value == 15.0, "seq: second tween at half");
    manager_update(*mgr, 0.5); // now=2.0
    expect(state, managed_value == 20.0, "seq: second tween done");
    manager_update(*mgr, 0.5);
    expect(state, !manager_is_handle_valid(mgr, seq), "sequence auto-killed");
    expect(state, !manager_is_handle_valid(mgr, h1), "child auto-killed with sequence");

    // callback + interval
    seq2 := manager_add_sequence(*mgr);
    managed_step_count = 0;
    seq_callback_count = 0;
    _ = sequence_append_interval(*mgr, seq2, 0.5);
    expect(state, sequence_append_callback(*mgr, seq2, seq_callback_proc), "append callback ok");

    manager_update(*mgr, 0.25);
    expect(state, seq_callback_count == 0, "callback not yet fired");
    manager_update(*mgr, 0.5); // past the 0.5 interval
    expect(state, seq_callback_count == 1, "callback fired after interval");

    manager_delete(*mgr);
}

seq_callback_count: s32;

seq_callback_proc :: () {
    seq_callback_count += 1;
}
