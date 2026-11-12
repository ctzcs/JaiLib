// messaging —— 单线程更新循环的两种消息原语（对位 DragonLib Engine.Messaging）。
// 一比一移植自 olib core/messaging/messaging.odin。
//
//   Command_Queue(T)：单消费者 FIFO。生产者入队，唯一消费者 queue_drain；
//     drain 只处理调用开始时已入队的命令，handler 里再入队的留到下一次
//     （消费者不会在同一帧里被自己派生的命令递归轰炸）。
//
//   Broadcast_Channel(T)：多消费者、延迟一帧。本帧 channel_publish 的消息在下一帧
//     开始时（channel_advance_frame）对所有消费者可见，读到的是同一批数据；
//     每帧开始调用一次 channel_advance_frame（生产者/消费者运行之前）。
//
// 两者都为单线程更新循环设计（无锁、无等待）。零值即可用，*_dispose 释放内部缓冲。
//
// 用法：
//   MSG :: #import "core/messaging";
//   queue:   MSG.Command_Queue(Cmd)     defer MSG.queue_dispose(*queue)
//   channel: MSG.Broadcast_Channel(Hit) defer MSG.channel_dispose(*channel)
//
// Jai 侧差异（对外语义不变）：
//   - 没有 Odin 那样的 context.allocator 隐含在签名里：Jai 的动态数组自带分配器，
//     首次增长时取 context.allocator，之后一直用它。因此「零值可用、由 dispose 释放」
//     的契约与 olib 相同，queue_dispose / channel_dispose 按数组自己的分配器归还。
//   - Odin 的 int / rawptr / nil 在这里是 s64 / *void / null。
//   - 泛型参数写作 struct (T: Type)，调用处照 olib 写 Command_Queue(T)。
//   - handler 是过程指针 (item: T, userdata: *void)：Odin 的 proc 字面量同样没有闭包，
//     需要状态的 handler 一律通过 userdata 传入（与 olib 的用法完全一致）。
//   - queue_drain 用 while 逐条推进 head，与 olib 的 `for _ in 0..<n` 等价；handler 内
//     enqueue 可能让 items 重新分配，因此每轮都重新读 q.items[q.head]（不是先取指针）。
//   - channel_messages 返回 [] T 借用视图，同 olib 的 current[:]：有效到下一次
//     channel_advance_frame / channel_clear / channel_dispose。
#import "Basic";   // [..] T / array_add / array_free

//@region Command_Queue —— 单消费者

Command_Queue :: struct (T: Type) {
    items: [..] T;
    head:  s64;   // 下一个待消费下标
}

// 入队（生产者任意方调用）。
queue_enqueue :: (q: *Command_Queue($T), item: T) {
    array_add(*q.items, item);
}

// 待消费数量。
queue_count :: (q: *Command_Queue($T)) -> s64 {
    return q.items.count - q.head;
}

// 消费一批：只处理调用开始时已入队的命令，返回处理数量。
// handler 内 enqueue 的命令留给下一次 drain。
// 注意 Jai 的过程字面量无闭包：需要状态的 handler 用 userdata 传入。
queue_drain :: (q: *Command_Queue($T), handler: (item: T, userdata: *void), userdata: *void = null) -> s64 {
    n := q.items.count - q.head;
    done := 0;
    while done < n {
        handler(q.items[q.head], userdata);
        q.head += 1;
        done += 1;
    }
    if q.head == q.items.count {
        q.items.count = 0;   // 保留容量，头部归零
        q.head = 0;
    }
    return n;
}

// 丢弃全部未消费命令。
queue_clear :: (q: *Command_Queue($T)) {
    q.items.count = 0;
    q.head = 0;
}

queue_dispose :: (q: *Command_Queue($T)) {
    array_free(q.items);
    q.items = .{};
    q.head = 0;
}
//@endregion

//@region Broadcast_Channel —— 多消费者，延迟一帧

Broadcast_Channel :: struct (T: Type) {
    current: [..] T;   // 本帧可见批（只读约定）
    pending: [..] T;   // 等待下一帧
}

// 发布：下一帧开始时可见。
channel_publish :: (ch: *Broadcast_Channel($T), message: T) {
    array_add(*ch.pending, message);
}

// 本帧可见的消息批（所有消费者读到同一份切片）。
channel_messages :: (ch: *Broadcast_Channel($T)) -> [] T {
    return ch.current;
}

channel_count :: (ch: *Broadcast_Channel($T)) -> s64 {
    return ch.current.count;
}

channel_pending_count :: (ch: *Broadcast_Channel($T)) -> s64 {
    return ch.pending.count;
}

// 每帧开始调用一次（生产者/消费者运行之前）：
// pending 变为本帧可见批，上一帧的可见批作废。
channel_advance_frame :: (ch: *Broadcast_Channel($T)) {
    old := ch.current;
    ch.current = ch.pending;
    ch.pending = old;
    ch.pending.count = 0;
}

// 清空可见批与待发批。
channel_clear :: (ch: *Broadcast_Channel($T)) {
    ch.current.count = 0;
    ch.pending.count = 0;
}

channel_dispose :: (ch: *Broadcast_Channel($T)) {
    array_free(ch.current);
    array_free(ch.pending);
    ch.current = .{};
    ch.pending = .{};
}
//@endregion
