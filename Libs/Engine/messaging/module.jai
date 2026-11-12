// Frame-owned, single-threaded messages, matching DragonLib Engine.Messaging.
// Payloads are value-copied; any referenced memory is owned by the application.
#import "Basic";

Command_Queue :: struct(T: Type) { items: [..] T; head: s64; draining: bool; }
command_enqueue :: (q: *Command_Queue($T), value: T) { array_add(*q.items, value); }
command_count :: (q: *Command_Queue($T)) -> s64 { return q.items.count - q.head; }
command_dequeue :: (q: *Command_Queue($T)) -> (T, bool) {
    if q.head >= q.items.count return .{}, false;
    value := q.items[q.head]; q.head += 1;
    if q.head == q.items.count { q.items.count = 0; q.head = 0; }
    return value, true;
}
command_drain :: (q: *Command_Queue($T), handler: (T, *void), user: *void = null) -> s64 {
    assert(!q.draining, "Command drain cannot be reentered");
    q.draining = true; defer q.draining = false;
    count := command_count(q);
    // Move the initial batch out: handlers can enqueue or clear the queue.
    batch: [..] T;
    for i: q.head..q.items.count-1 array_add(*batch, q.items[i]);
    q.items.count = 0; q.head = 0;
    defer array_free(batch);
    for value: batch handler(value, user);
    return count;
}
command_clear :: (q: *Command_Queue($T)) { q.items.count = 0; q.head = 0; }
command_destroy :: (q: *Command_Queue($T)) { array_free(q.items); <<q = .{}; }

Broadcast_Channel :: struct(T: Type) { current: [..] T; pending: [..] T; frame: u64; }
broadcast_publish :: (c: *Broadcast_Channel($T), value: T) { array_add(*c.pending, value); }
broadcast_advance :: (c: *Broadcast_Channel($T)) {
    old := c.current; c.current = c.pending; c.pending = old;
    c.pending.count = 0; c.frame += 1;
}
// Borrowed until the next advance/clear/destroy. Consumers must not mutate it.
broadcast_messages :: (c: *Broadcast_Channel($T)) -> [] T { return c.current; }
broadcast_clear :: (c: *Broadcast_Channel($T)) { c.current.count = 0; c.pending.count = 0; }
broadcast_destroy :: (c: *Broadcast_Channel($T)) {
    array_free(c.current); array_free(c.pending); <<c = .{};
}
