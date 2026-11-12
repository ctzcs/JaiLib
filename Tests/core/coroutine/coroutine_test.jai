// coroutine 包单元测试。dt 用可精确表示的 0.25，到点时刻不受浮点累积影响。
// 一比一移植自 olib tests/core/coroutine/coroutine_test.odin。
//
// Jai 侧差异（断言顺序与数值与 odin 版一一对应）：
//   - core:testing.expect_value 换成 test_support.expect + 比较表达式；
//   - Jai 的结构体没有内建 `==`，odin 里 `expect_value(snapshot, seq)` 的整体比较
//     改成逐字段比较（test_world_eq / flow_eq / door_flow_eq，见下方）；
//   - odin 的 `&seq` 取址写作 `*seq`；`c^` 之类的显式解引用在 Jai 里直接传指针即可；
//   - int 字面量不自动转 float32：与 float32 比较/相乘时写浮点字面量（90.0）或
//     把字面量放在右侧（t * 90）；
//   - odin 的 `if t, active := ...; active` 在 Jai 里不能同时声明两个变量，
//     拆成 `t, active := ...` + `if active`；
//   - odin 的 switch 换成 Jai 的 if-switch（`if step == { case ...; }`）。
#import "Basic";
#import "Math";
#import "test_support";
CO :: #import "core/coroutine";

DT :: 0.25;

Test_World :: struct {
    sounds: int;
    angle: float32;
    line: int;
}

// Jai 的结构体没有内建 ==：逐字段比较。
test_world_eq :: (a: Test_World, b: Test_World) -> bool {
    return a.sounds == b.sounds && a.angle == b.angle && a.line == b.line;
}

flow_eq :: (a: CO.Flow, b: CO.Flow) -> bool {
    return a.step == b.step && a.at == b.at && a.elapsed == b.elapsed;
}

//@region Flow

Door_Flow :: struct {
    flow: CO.Flow;
}

door_flow_step :: (seq: *Door_Flow, world: *Test_World, dt: float32) -> bool {
    f := *seq.flow;
    CO.flow_begin(f, dt);
    if CO.flow_wait(f, 0.5) return false;
    if CO.flow_once(f) {
        world.sounds += 1;
    }
    t, active := CO.flow_progress(f, 1);
    if active {
        world.angle = t * 90;
    }
    if CO.flow_wait(f, 1) return false;
    return true;
}

// odin 的 expect_value(snapshot, seq)：Door_Flow 只含 flow 一个字段。
door_flow_eq :: (a: Door_Flow, b: Door_Flow) -> bool {
    return flow_eq(a.flow, b.flow);
}

Intro_Flow :: struct {
    flow: CO.Flow;
    door: Door_Flow;
}

intro_flow_step :: (seq: *Intro_Flow, world: *Test_World, dt: float32) -> bool {
    f := *seq.flow;
    CO.flow_begin(f, dt);
    if CO.flow_once(f) {
        world.line = 1;
    }
    if CO.flow_wait(f, 1) return false;
    if CO.flow_until(f, door_flow_step(*seq.door, world, dt)) return false;
    if CO.flow_once(f) {
        world.line = 2;
    }
    if CO.flow_wait(f, 1) return false;
    return true;
}

flow_wait_and_once_run_in_order :: (state: *Test_State) {
    world: Test_World;
    seq: Door_Flow;

    expect(state, !door_flow_step(*seq, *world, DT), "第 1 帧未完成"); // 0.25
    expect(state, world.sounds == 0, "sounds=%", world.sounds);
    expect(state, !door_flow_step(*seq, *world, DT), "第 2 帧未完成"); // 0.5：等待结束，进入转动
    expect(state, world.sounds == 1, "sounds=%", world.sounds);
    expect(state, world.angle == 0.0, "angle=%", world.angle);
    expect(state, !door_flow_step(*seq, *world, DT), "第 3 帧未完成"); // 0.75
    expect(state, world.angle == 22.5, "angle=%", world.angle);
    expect(state, world.sounds == 1, "sounds=%", world.sounds);
    expect(state, !door_flow_step(*seq, *world, DT), "第 4 帧未完成"); // 1.0
    expect(state, !door_flow_step(*seq, *world, DT), "第 5 帧未完成"); // 1.25
    expect(state, door_flow_step(*seq, *world, DT), "第 6 帧完成"); // 1.5：完成，末值不丢
    expect(state, world.angle == 90.0, "angle=%", world.angle);
}

flow_wait_carries_surplus_time :: (state: *Test_State) {
    f: CO.Flow;
    CO.flow_begin(*f, 0.75);
    expect(state, !CO.flow_wait(*f, 0.5), "0.75 秒时 0.5 秒的等待已结束");
    expect(state, f.elapsed == 0.25, "elapsed=%", f.elapsed);
    expect(state, CO.flow_wait(*f, 1), "余量不够第二个等待");
}

flow_large_dt_passes_several_checkpoints :: (state: *Test_State) {
    world: Test_World;
    seq: Door_Flow;
    expect(state, door_flow_step(*seq, *world, 10), "大 dt 一帧内完成");
    expect(state, world.sounds == 1, "sounds=%", world.sounds);
    expect(state, world.angle == 90.0, "angle=%", world.angle);
}

flow_nested_child_runs_after_parent_wait :: (state: *Test_State) {
    world: Test_World;
    seq: Intro_Flow;

    frames := 0;
    while !intro_flow_step(*seq, *world, DT) {
        frames += 1;
        expect(state, frames < 100, "frames=%", frames);
        if frames >= 100 return;
    }
    expect(state, world.line == 2, "line=%", world.line);
    expect(state, world.sounds == 1, "sounds=%", world.sounds);
    expect(state, world.angle == 90.0, "angle=%", world.angle);
    // 第 4 帧父序列到点，同帧开始推进子序列；子序列 1.5 秒占 6 帧，再等 1 秒占 4 帧。
    expect(state, frames + 1 == 13, "frames+1=%", frames + 1);
}

flow_until_resets_timer :: (state: *Test_State) {
    f: CO.Flow;
    CO.flow_begin(*f, 5);
    expect(state, CO.flow_until(*f, false), "条件不成立时继续等");
    CO.flow_begin(*f, 5);
    expect(state, !CO.flow_until(*f, true), "条件成立后放行");
    expect(state, f.elapsed == 0.0, "elapsed=%", f.elapsed);
    expect(state, f.step == 1, "step=%", f.step);
}

flow_progress_handles_zero_seconds_and_past_steps :: (state: *Test_State) {
    f: CO.Flow;
    CO.flow_begin(*f, 0);
    p, active := CO.flow_progress(*f, 0);
    expect(state, active, "0 秒的检查点处于活动状态");
    expect(state, p == 1.0, "p=%", p);
    expect(state, !CO.flow_wait(*f, 0), "0 秒等待不阻塞");

    // 第 0 个检查点已过，重入时 flow_progress 不再报告它。
    CO.flow_begin(*f, 0);
    _, active = CO.flow_progress(*f, 1);
    expect(state, !active, "已过的检查点不再报告");
}

flow_copy_resumes_from_same_point :: (state: *Test_State) {
    world: Test_World;
    seq: Door_Flow;
    door_flow_step(*seq, *world, 0.75);

    snapshot := seq;
    world_snapshot := world;
    door_flow_step(*seq, *world, 0.25);
    door_flow_step(*snapshot, *world_snapshot, 0.25);
    expect(state, door_flow_eq(snapshot, seq), "快照与原件状态一致");
    expect(state, test_world_eq(world_snapshot, world), "快照世界与原件一致");
}
//@endregion

//@region Cursor

Door_Step :: enum u8 {
    Unlock;
    Sound;
    Swing;
    Done;
}

door_cursor_step :: (c: *CO.Cursor(Door_Step), world: *Test_World, dt: float32) -> bool {
    c.elapsed += dt;
    while true {
        if c.step == {
            case Door_Step.Unlock;
                if !CO.cursor_wait(c, 0.5, Door_Step.Sound) return false;
            case Door_Step.Sound;
                world.sounds += 1;
                CO.cursor_wait(c, 0, Door_Step.Swing);
            case Door_Step.Swing;
                world.angle = CO.cursor_progress(c, 1) * 90;
                if !CO.cursor_wait(c, 1, Door_Step.Done) return false;
            case Door_Step.Done;
                return true;
        }
    }
    return true;
}

cursor_runs_instant_steps_in_one_call :: (state: *Test_State) {
    world: Test_World;
    c: CO.Cursor(Door_Step);

    expect(state, !door_cursor_step(*c, *world, 0.75), "0.75 秒时未完成");
    expect(state, c.step == Door_Step.Swing, "step=%", c.step);
    expect(state, world.sounds == 1, "sounds=%", world.sounds);
    expect(state, c.elapsed == 0.25, "elapsed=%", c.elapsed); // 瞬时步保留余量
    expect(state, world.angle == 22.5, "angle=%", world.angle);
}

cursor_finishes_and_stays_done :: (state: *Test_State) {
    world: Test_World;
    c: CO.Cursor(Door_Step);
    expect(state, door_cursor_step(*c, *world, 10), "大 dt 一帧内完成");
    expect(state, world.angle == 90.0, "angle=%", world.angle);
    expect(state, door_cursor_step(*c, *world, DT), "完成后仍返回 true");
    expect(state, world.sounds == 1, "sounds=%", world.sounds);
}

cursor_enter_resets_timer :: (state: *Test_State) {
    c: CO.Cursor(Door_Step) = .{ elapsed = 3 };
    CO.cursor_enter(*c, Door_Step.Swing);
    expect(state, c.step == Door_Step.Swing, "step=%", c.step);
    expect(state, c.elapsed == 0.0, "elapsed=%", c.elapsed);
}

cursor_progress_clamps :: (state: *Test_State) {
    c: CO.Cursor(Door_Step) = .{ elapsed = 3 };
    expect(state, CO.cursor_progress(c, 2) == 1.0, "过长夹到 1");
    expect(state, CO.cursor_progress(c, 0) == 1.0, "0 秒即 1");
    expect(state, CO.cursor_progress(c, 6) == 0.5, "一半进度");
}
//@endregion
