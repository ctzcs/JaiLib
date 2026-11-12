// 一比一移植自 olib tests/core/messaging/messaging_test.odin。
// 断言与拆分方式保持原样，只把 core:testing.expect 换成 test_support.expect；
// 三个测试过程名（command_queue_drain_semantics / command_queue_clear /
// broadcast_channel_frame_semantics）与 olib 一致。
//
// Jai 侧差异（只影响测试的写法，被测语义不变）：
//   - olib 的 Test_Cmd 是无标签 union { Spawn_Effect, Play_Sound }；Jai 没有无标签 union，
//     这里用带标签的结构体表达同一批 payload（队列本身与 payload 无关，被测的是 drain 的
//     批次语义：只处理调用开始时已入队的命令）。
//   - Odin 的 int / f32 → Jai 的 s64 / float32。
//   - Odin 的 proc 字面量无闭包，handler 需要状态一律走 userdata（与 olib 相同）。
#import "Basic";
#import "test_support";
MSG :: #import "core/messaging";

//@region Command_Queue —— drain 语义

Test_Cmd_Kind :: enum {
    Spawn_Effect;
    Play_Sound;
}

Test_Cmd :: struct {
    kind: Test_Cmd_Kind;
    id:   s64;       // Play_Sound 的 id
    x:    float32;   // Spawn_Effect 的位置
    y:    float32;
}

// drain handler 的状态：记录 + 反向引用队列（演示 handler 内再入队）。
Drain_State :: struct {
    queue: *MSG.Command_Queue(Test_Cmd);
    log:   [..] s64;
}

drain_handler :: (c: Test_Cmd, userdata: *void) {
    s := cast(*Drain_State) userdata;
    if c.kind == {
        case .Play_Sound;
            array_add(*s.log, c.id);
            if c.id == 1 {   // 派生命令，留到下次
                MSG.queue_enqueue(s.queue, Test_Cmd.{ kind = .Play_Sound, id = 99 });
            }
        case .Spawn_Effect;
            array_add(*s.log, -1);
    }
}

command_queue_drain_semantics :: (state: *Test_State) {
    q: MSG.Command_Queue(Test_Cmd);
    defer MSG.queue_dispose(*q);

    expect(state, MSG.queue_count(*q) == 0, "零值队列为空");

    MSG.queue_enqueue(*q, Test_Cmd.{ kind = .Play_Sound, id = 1 });
    MSG.queue_enqueue(*q, Test_Cmd.{ kind = .Spawn_Effect, x = 1, y = 2 });
    MSG.queue_enqueue(*q, Test_Cmd.{ kind = .Play_Sound, id = 2 });
    expect(state, MSG.queue_count(*q) == 3, "入队 3 条后计数为 3");

    ds: Drain_State;
    defer array_free(ds.log);
    ds.queue = *q;

    // drain 开始时已入队的 3 条全部处理；handler 里再入队的 1 条留下次
    n := MSG.queue_drain(*q, drain_handler, *ds);
    expect(state, n == 3, "drain 应处理 3 条, 实际 %", n);
    expect(state, ds.log.count == 3, "handler 收到 3 条, 实际 %", ds.log.count);
    expect(state, MSG.queue_count(*q) == 1, "派生命令应留到下次: %", MSG.queue_count(*q));

    // 第二次 drain 处理派生命令
    ds.log.count = 0;
    n2 := MSG.queue_drain(*q, drain_handler, *ds);
    expect(state, n2 == 1 && ds.log.count == 1 && ds.log[0] == 99, "第二次 drain 应处理派生命令");
    expect(state, MSG.queue_count(*q) == 0, "drain 完队列清空");
}

int_count_handler :: (v: s64, userdata: *void) {
    p := cast(*s64) userdata;
    p.* += 1;
}

command_queue_clear :: (state: *Test_State) {
    q: MSG.Command_Queue(s64);
    defer MSG.queue_dispose(*q);

    for 0..4 MSG.queue_enqueue(*q, it);
    total: s64 = 0;
    n := MSG.queue_drain(*q, int_count_handler, *total);
    expect(state, n == 5 && total == 5, "drain 5 条, 实际 % / %", n, total);

    for 0..2 MSG.queue_enqueue(*q, it);
    MSG.queue_clear(*q);
    expect(state, MSG.queue_count(*q) == 0, "clear 后计数为 0");
    n2 := MSG.queue_drain(*q, int_count_handler, *total);
    expect(state, n2 == 0 && total == 5, "clear 后 drain 不再处理, 实际 % / %", n2, total);
}
//@endregion

//@region Broadcast_Channel —— 延迟一帧

Hit :: struct {
    target: s64;
    damage: float32;
}

broadcast_channel_frame_semantics :: (state: *Test_State) {
    ch: MSG.Broadcast_Channel(Hit);
    defer MSG.channel_dispose(*ch);

    expect(state, MSG.channel_count(*ch) == 0 && MSG.channel_pending_count(*ch) == 0, "零值通道为空");

    // 第 0 帧：发布 a/b，尚未可见
    MSG.channel_publish(*ch, Hit.{ target = 1, damage = 10 });
    MSG.channel_publish(*ch, Hit.{ target = 2, damage = 20 });
    expect(state, MSG.channel_count(*ch) == 0, "发布后本帧仍不可见");
    expect(state, MSG.channel_pending_count(*ch) == 2, "待发批有 2 条");

    // 第 1 帧开始：advance 后可见
    MSG.channel_advance_frame(*ch);
    expect(state, MSG.channel_count(*ch) == 2, "advance 后可见 2 条");
    expect(state, MSG.channel_pending_count(*ch) == 0, "advance 后待发批清空");

    // 两个消费者读到同一批、同一份数据
    consumer_a := MSG.channel_messages(*ch);
    consumer_b := MSG.channel_messages(*ch);
    expect(state, consumer_a.count == 2 && consumer_a[0].target == 1 && consumer_a[1].damage == 20,
           "两个消费者读到同一批数据");
    expect(state, consumer_a.data == consumer_b.data, "两个消费者拿到同一片内存");

    // 第 1 帧中再发布 c
    MSG.channel_publish(*ch, Hit.{ target = 3, damage = 30 });
    expect(state, MSG.channel_count(*ch) == 2, "帧中发布不改变可见批");

    // 第 2 帧：可见批换成 [c]，旧批作废
    MSG.channel_advance_frame(*ch);
    expect(state, MSG.channel_count(*ch) == 1, "第 2 帧可见 1 条");
    expect(state, MSG.channel_messages(*ch)[0].target == 3, "第 2 帧可见的是 c");

    // 无发布的帧：advance 后可见批为空
    MSG.channel_advance_frame(*ch);
    expect(state, MSG.channel_count(*ch) == 0 && MSG.channel_pending_count(*ch) == 0,
           "空帧 advance 后全空");
}
//@endregion

//@region 释放与清空（olib 无对应用例，补测 dispose 契约）

command_queue_dispose_releases_buffer :: (state: *Test_State) {
    q: MSG.Command_Queue(s64);
    for 0..7 MSG.queue_enqueue(*q, it);
    expect(state, q.items.data != null, "入队后内部缓冲已分配");

    MSG.queue_dispose(*q);
    expect(state, q.items.count == 0 && q.items.data == null && q.head == 0, "dispose 归还缓冲并归零");
    // 二次 dispose 与再次使用都必须是安全的（零值可用）
    MSG.queue_dispose(*q);
    MSG.queue_enqueue(*q, 42);
    expect(state, MSG.queue_count(*q) == 1, "dispose 后可重新使用");
    MSG.queue_dispose(*q);
}

broadcast_channel_clear_and_dispose :: (state: *Test_State) {
    ch: MSG.Broadcast_Channel(Hit);
    MSG.channel_publish(*ch, Hit.{ target = 1 });
    MSG.channel_advance_frame(*ch);
    MSG.channel_publish(*ch, Hit.{ target = 2 });
    expect(state, MSG.channel_count(*ch) == 1 && MSG.channel_pending_count(*ch) == 1, "清空前可见/待发各 1 条");

    MSG.channel_clear(*ch);
    expect(state, MSG.channel_count(*ch) == 0 && MSG.channel_pending_count(*ch) == 0, "clear 同时清空两批");

    MSG.channel_publish(*ch, Hit.{ target = 3 });
    MSG.channel_advance_frame(*ch);
    MSG.channel_dispose(*ch);
    expect(state, ch.current.data == null && ch.pending.data == null, "dispose 归还两批缓冲");
}
//@endregion
