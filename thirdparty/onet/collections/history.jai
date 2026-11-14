#scope_file
core :: #import "thirdparty/onet/core";
v :: #import "thirdparty/onet/values";
wire :: #import "thirdparty/onet/wire";
#scope_export

// Keep dependencies visible to standalone -vet without generic instantiations.

history_reject_read :: (r: *core.Reader) -> bool {
    return v.reject_read(r);
}

history_finished :: (r: *core.Reader) -> bool {
    return wire.finished(r);
}

//@region Sparse history and committed operation journals

NETWORK_MAGIC :: (cast, trunc(u64)(0x4e434a32));
DEFAULT_JOURNAL_LIMIT :: 256;
MAX_HISTORY_DEPTH :: 256;

Timeline :: struct {
    tick, head_tick, event_tick: u64;

    started, rotated, replaying: bool;

    history_depth, journal_limit: int;

    remote_revision: u64;

    has_remote: bool;

    // True when an absolute replaced operations outside the retained window.

    recovered: bool;
}

Sequence_Snapshot :: struct(T: Type) {
    tick, revision: u64;
    items: [..] T;
}

Sequence_Event :: struct(T: Type) {
    tick, revision: u64;
    change: Change(T);
}

Map_Snapshot :: struct(K, V: Type) {
    tick, revision: u64;
    items: [..] Entry(K, V);
}

Map_Event :: struct(K, V: Type) {
    tick, revision: u64;
    change: Map_Change(K, V);
}

history_depth :: (t: Timeline) -> int {
    return (ifx t.history_depth == 0 then 2 else t.history_depth);
}

journal_limit :: (t: Timeline) -> int {
    return (ifx t.journal_limit == 0 then DEFAULT_JOURNAL_LIMIT else t.journal_limit);
}

// Configure before registration/use. Depth includes the current head; quiescent
// ticks do not consume slots. Journal retention is independent of ring depth.

configure_history :: (s: *Sequence($T), depth, operations: int) -> bool {
    if depth < 2 || depth > MAX_HISTORY_DEPTH || operations < 1 || operations > MAX_OPERATIONS || (s.history).count != 0 || (s.journal).count != 0 {
        return false;
    }

    s.timeline.history_depth, s.timeline.journal_limit = depth, operations;
    return true;
}

sequence_clone_change :: (s: *Sequence($T), ch: Change(T)) -> Change(T) {
    out := ch;
    if ch.operation == .Set || ch.operation == .Insert || ch.operation == .Fill || (ch.operation == .Remove && s.kind == .Queue) {
        out.value = s.codec.clone(*out.value);
    }

    return out;
}

sequence_destroy_change :: (s: *Sequence($T), ch: *Change(T)) {
    if ch.operation == .Set || ch.operation == .Insert || ch.operation == .Fill || (ch.operation == .Remove && s.kind == .Queue) {
        s.codec.destroy(*ch.value);
    }
}

sequence_clear_events :: (s: *Sequence($T)) {
    for *e: s.events {
        sequence_destroy_change(s, e);
    }

    release(s.events);
    s.events = .{};
}

sequence_end_events :: (s: *Sequence($T)) {
    sequence_clear_events(s);
    for *e: s.applied {
        sequence_destroy_change(s, *e.change);
    }

    release(s.applied);
    s.applied = .{};
    s.applied_cursor = 0;
    s.timeline.recovered = false;
}

// Network apply can happen between fixed ticks. Keep unread commit events for
// the next game callback; bound a non-consuming subscriber by journal capacity.

sequence_compact_applied :: (s: *Sequence($T)) {
    count := max(s.applied_cursor, (s.applied).count - journal_limit(s.timeline));
    if count > s.applied_cursor {
        s.timeline.recovered = true;
    }

    {
        i := 0;
        while i < count {
            defer i += 1;
            sequence_destroy_change(s, *s.applied[i].change);
        }
    }

    {
        i := count;
        while i < (s.applied).count {
            defer i += 1;
            s.applied[i - count] = s.applied[i];
        }
    }

    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;
            array_ordered_remove_by_index(*s.applied, (s.applied).count - 1);
        }
    }

    s.applied_cursor = 0;
}

sequence_destroy_timeline :: (s: *Sequence($T)) {
    sequence_end_events(s);
    for *h: s.history {
        destroy_items(s.codec, *h.items);
    }

    release(s.history);
    for *e: s.journal {
        sequence_destroy_change(s, *e.change);
    }

    release(s.journal);
}

sequence_clone_timeline :: (dst, src: *Sequence($T)) {
    dst.timeline = src.timeline;
    dst.applied_cursor = src.applied_cursor;
    for h: src.history {
        copied := Sequence_Snapshot(T).{
            tick = h.tick, revision = h.revision,
        };

        for *x: h.items {
            array_add(*copied.items, src.codec.clone(x));
        }

        array_add(*dst.history, copied);
    }

    for e: src.journal {
        array_add(*dst.journal, Sequence_Event(T).{
            e.tick, e.revision, sequence_clone_change(src, *e.change)
        });
    };

    for e: src.applied {
        array_add(*dst.applied, Sequence_Event(T).{
            e.tick, e.revision, sequence_clone_change(src, *e.change)
        });
    };

    for e: src.events {
        array_add(*dst.events, sequence_clone_change(src, e));
    }
}

sequence_tick :: (s: *Sequence($T), tick: u64) {
    if s.timeline.replaying || (s.timeline.started && tick < s.timeline.tick) {
        return;
    }

    if s.timeline.started && s.timeline.tick == tick {
        return;
    }

    s.timeline.started = true;
    s.timeline.tick = tick;
    s.timeline.rotated = false;
    destroy_changes(s);
    sequence_clear_events(s);
    sequence_compact_applied(s);
    s.base_revision = s.revision;
}

sequence_before_change :: (s: *Sequence($T)) {
    if s.timeline.rotated {
        return;
    }

    h := Sequence_Snapshot(T).{
        tick = s.timeline.head_tick, revision = s.revision,
    };

    for *x: s.items {
        array_add(*h.items, s.codec.clone(x));
    }

    if (s.history).count > 0 && s.history[(s.history).count - 1].tick == h.tick {
        destroy_items(s.codec, *s.history[(s.history).count - 1].items);
        s.history[(s.history).count - 1] = h;
    } else {
        if (s.history).count >= history_depth(s.timeline) - 1 {
            destroy_items(s.codec, *s.history[0].items);
            array_ordered_remove_by_index(*s.history, 0);
        }

        array_add(*s.history, h);
    }

    destroy_items(s.codec, *s.previous);
    for *x: s.items {
        array_add(*s.previous, s.codec.clone(x));
    }

    s.timeline.head_tick = max(s.timeline.head_tick, s.timeline.tick);
    s.timeline.rotated = true;
}

// The coalesced Changes view. The raw `changes` field remains the compatible
// standalone delta stream (one revision per operation), not this presentation.

sequence_event :: (s: *Sequence($T), ch: Change(T), tick: u64) {
    if s.timeline.event_tick != tick {
        sequence_clear_events(s);
    }

    s.timeline.event_tick = tick;
    if ch.operation == .Clear && s.kind != .Array {
        sequence_clear_events(s);
    }

    if (s.events).count > 0 {
        last := *s.events[(s.events).count - 1];
        same := last.operation == ch.operation;
        if same && ((ch.operation == .Set && last.index == ch.index) || ch.operation == .Fill || ch.operation == .Resize || ch.operation == .Clear) {
            sequence_destroy_change(s, last);
            last.* = sequence_clone_change(s, ch);
            return;
        }
    }

    array_add(*s.events, sequence_clone_change(s, ch));
}

sequence_record :: (s: *Sequence($T), ch: Change(T)) {
    // A received head may be ahead of the local fixed clock. Never produce a
    // backwards journal when a legal local write follows that wire apply.

    s.timeline.head_tick = max(s.timeline.head_tick, s.timeline.tick);
    if (s.journal).count >= journal_limit(s.timeline) {
        sequence_destroy_change(s, *s.journal[0].change);
        array_ordered_remove_by_index(*s.journal, 0);
    }

    array_add(*s.journal, Sequence_Event(T).{
        s.timeline.head_tick, s.revision, sequence_clone_change(s, ch)
    });
    sequence_event(s, ch, s.timeline.head_tick);
};

changes_view :: (s: *Sequence($T)) -> [] Change(T) {
    return view(s.events, 0);
}

// Pull once after commit or from the next game tick. Unread events survive ticks.
// Borrowed; valid until mutation/apply/tick/destroy. Bounded by journal_limit.

take_applied_changes :: (s: *Sequence($T)) -> [] Sequence_Event(T) {
    out := view(s.applied, s.applied_cursor);
    s.applied_cursor = (s.applied).count;
    return out;
}

values_at :: (s: *Sequence($T), tick: u64) -> ([] T, bool) {
    if tick >= s.timeline.head_tick {
        return view(s.items, 0), true;
    }

    {
        i := (s.history).count - 1;
        while i >= 0 {
            defer i -= 1;
            if s.history[i].tick <= tick {
                return view(s.history[i].items, 0), true;
            }
        }
    }

    return .[], false;
}

//@endregion
//@region Sequence network value: absolute state, sparse heads and bounded journal

sequence_write_value :: (s: *Sequence($T), w: *core.Writer) -> bool {
    body: core.Writer;
    core.writer_init(*body);
    defer core.writer_destroy(*body);
    if !write_full(s, *body) {
        return v.reject_write(w);
    }

    data := core.writer_to_array(*body);
    defer release(data);
    wire.write_bytes(w, data);
    return w.err == .None;
}

sequence_read_value :: (s: *Sequence($T), r: *core.Reader) -> bool {
    data, ok := wire.read_bytes(r);
    if !ok {
        return false;
    }

    defer release(data);
    body: core.Reader;
    core.reader_init(*body, data);
    if !apply_full(s, *body) || !wire.finished(*body) {
        return v.reject_read(r);
    }

    return true;
}

sequence_network_write :: (s: *Sequence($T), w: *core.Writer) -> bool {
    core.write_bits(w, NETWORK_MAGIC, 32);
    core.write_bits(w, s.timeline.head_tick, 64);
    if !sequence_write_value(s, w) {
        return false;
    }

    wire.write_count(w, (s.history).count, MAX_HISTORY_DEPTH - 1);
    for h: s.history {
        core.write_bits(w, h.tick, 64);
        view := Sequence(T).{
            codec = s.codec, kind = s.kind, limit = s.limit, items = h.items, revision = h.revision,
        };

        if !sequence_write_value(*view, w) {
            return false;
        }
    }

    wire.write_count(w, (s.journal).count, MAX_OPERATIONS);
    for *e: s.journal {
        core.write_bits(w, e.*.tick, 64);
        core.write_bits(w, e.*.revision, 64);
        core.write_bits(w, (cast, trunc(u64)(e.*.change.operation)), 8);
        core.write_bits(w, (cast, trunc(u64)(e.*.change.index)), 32);
        op := e.*.change.operation;
        if op == .Set || op == .Insert || op == .Fill || (op == .Remove && s.kind == .Queue) {
            if !v.write(s.codec, w, *e.change.value) {
                return false;
            }
        }
    }

    return w.err == .None;
}

sequence_network_read :: (s: *Sequence($T), r: *core.Reader) -> bool {
    peek := r.*;
    if core.read_bits(*peek, 32) != NETWORK_MAGIC {
        // Upstream collection writes retain the existing absolute-only API.

        tmp := Sequence(T).{
            codec = s.codec, kind = s.kind, limit = s.limit,
        };

        defer destroy(*tmp);
        if !apply_full(*tmp, r) || !wire.finished(r) || s.revision == (cast, trunc(u64)(18446744073709551615)) {
            return v.reject_read(r);
        }

        tmp.revision = max(tmp.revision, s.revision + 1);
        tmp.base_revision = tmp.revision;
        sequence_before_change(s);
        sequence_clone_timeline(*tmp, s);
        sequence_end_events(*tmp);
        for *e: tmp.journal {
            sequence_destroy_change(*tmp, *e.change);
        }

        release(tmp.journal);
        tmp.journal = .{};
        tmp.timeline.head_tick = max(s.timeline.head_tick, s.timeline.tick);
        // An absolute supersedes operations, but never overwrites previous with
        // the incoming value. The next local write rotates off this apply.

        destroy_items(tmp.codec, *tmp.previous);
        for *x: s.items {
            array_add(*tmp.previous, s.codec.clone(x));
        }

        destroy(s);
        s.* = tmp;
        tmp = .{
        };

        return true;
    }

    core.read_bits(r, 32);
    head_tick := core.read_bits(r, 64);
    tmp := Sequence(T).{
        codec = s.codec, kind = s.kind, limit = s.limit,
    };

    defer destroy(*tmp);
    if !sequence_read_value(*tmp, r) {
        return false;
    }

    n, ok := wire.read_count(r, MAX_HISTORY_DEPTH - 1);
    if !ok {
        return false;
    }

    {
        i := 0;
        while i < n {
            defer i += 1;

            tick := core.read_bits(r, 64);
            h := Sequence(T).{
                codec = s.codec, kind = s.kind, limit = s.limit,
            };

            if !sequence_read_value(*h, r) {
                destroy(*h);
                return false;
            }

            legal := tick <= head_tick && h.revision <= tmp.revision;
            if i > 0 {
                legal = legal && tick > tmp.history[i - 1].tick && h.revision >= tmp.history[i - 1].revision;
            }

            if !legal {
                destroy(*h);
                return v.reject_read(r);
            }

            array_add(*tmp.history, Sequence_Snapshot(T).{
                tick, h.revision, h.items
            });
            h.items = .{};
            destroy(*h);
        }
    };

    n, ok = wire.read_count(r, MAX_OPERATIONS);
    if !ok || n > core.reader_remaining_bits(r) / 168 {
        return v.reject_read(r);
    }

    {
        i := 0;
        while i < n {
            defer i += 1;

            e := Sequence_Event(T).{
                tick = core.read_bits(r, 64), revision = core.read_bits(r, 64),
            };

            op := core.read_bits(r, 8);
            index := (cast(int) (core.read_bits(r, 32)));
            legal := op >= 1 && op <= 6 && index <= MAX_ELEMENTS && e.tick <= head_tick && e.revision > 0 && e.revision <= tmp.revision;
            if i > 0 {
                legal = legal && e.revision == tmp.journal[i - 1].revision + 1 && e.tick >= tmp.journal[i - 1].tick;
            }

            if !legal {
                return v.reject_read(r);
            }

            e.change.operation = cast(Operation) (op);
            e.change.index = index;
            if e.change.operation == {
                case .Set; legal = s.kind == .List || s.kind == .Array;
                case .Insert; legal = s.kind == .List || s.kind == .Queue;
                case .Remove; legal = s.kind == .List || (s.kind == .Queue && index == 0);
                case .Resize; legal = s.kind == .Array && index <= s.limit;
                case .Fill; legal = s.kind == .Array && index == 0;
                case .Clear; legal = index == 0;
            }

            if !legal {
                return v.reject_read(r);
            }

            if op == 1 || op == 2 || op == 6 || (op == 3 && s.kind == .Queue) {
                x, good := v.read_new(s.codec, r);
                if !good {
                    return false;
                }

                e.change.value = x;
            }

            array_add(*tmp.journal, e);
        }
    }

    if !wire.finished(r) || (n > 0 && tmp.journal[n - 1].revision != tmp.revision) {
        return v.reject_read(r);
    }

    sequence_commit_network(s, *tmp, head_tick);
    return true;
}

sequence_commit_network :: (s, tmp: *Sequence($T), head_tick: u64) {
    remote := s.timeline.remote_revision;
    continuous := s.timeline.has_remote && (tmp.revision == remote || (tmp.revision > remote && (tmp.journal).count > 0 && tmp.journal[0].revision <= remote + 1));
    tmp.timeline = s.timeline;
    tmp.timeline.recovered = s.timeline.has_remote && !continuous;
    tmp.timeline.head_tick = head_tick;
    tmp.timeline.has_remote = true;
    tmp.timeline.remote_revision = tmp.revision;
    tmp.timeline.rotated = false;
    while (tmp.history).count > history_depth(tmp.timeline) - 1 {
        destroy_items(s.codec, *tmp.history[0].items);
        array_ordered_remove_by_index(*tmp.history, 0);
    }

    destroy_items(s.codec, *tmp.previous);
    if !s.timeline.has_remote {
        for *x: tmp.items {
            array_add(*tmp.previous, s.codec.clone(x));
        }
    } else if tmp.revision == remote {
        for *x: s.previous {
            array_add(*tmp.previous, s.codec.clone(x));
        }
    } else if (tmp.history).count > 0 {
        for *x: tmp.history[(tmp.history).count - 1].items {
            array_add(*tmp.previous, s.codec.clone(x));
        }
    } else {
        for *x: s.items {
            array_add(*tmp.previous, s.codec.clone(x));
        }
    }

    for e: s.events {
        array_add(*tmp.events, sequence_clone_change(s, e));
    }

    for e: s.applied {
        array_add(*tmp.applied, Sequence_Event(T).{
            e.tick, e.revision, sequence_clone_change(s, *e.change)
        });
    };

    tmp.applied_cursor = s.applied_cursor;
    if continuous {
        tmp.base_revision = remote;
        if s.revision == remote && (s.changes).count + (cast(int) (tmp.revision - remote)) <= MAX_OPERATIONS {
            tmp.base_revision = s.base_revision;
            for ch: s.changes {
                array_add(*tmp.changes, sequence_clone_change(s, ch));
            }
        }

        for e: tmp.journal {
            if e.revision <= remote {
                continue;
            }

            array_add(*tmp.changes, sequence_clone_change(s, *e.change));
            array_add(*tmp.applied, Sequence_Event(T).{
                e.tick, e.revision, sequence_clone_change(s, *e.change)
            });
            sequence_event(tmp, *e.change, e.tick);
        };
    } else {
        sequence_clear_events(tmp);
        tmp.base_revision = tmp.revision;
    }

    sequence_compact_applied(tmp);
    while (tmp.journal).count > journal_limit(tmp.timeline) {
        sequence_destroy_change(tmp, *tmp.journal[0].change);
        array_ordered_remove_by_index(*tmp.journal, 0);
    }

    destroy(s);
    s.* = tmp.*;
    tmp.* = .{
    };
}

//@endregion
// Cast semantics adapted.
// Loop scopes adapted.
// Iterator semantics adapted.
