#scope_file
core :: #import "thirdparty/onet/core";
v :: #import "thirdparty/onet/values";
wire :: #import "thirdparty/onet/wire";
#scope_export

map_reject_read :: (r: *core.Reader) -> bool {
    return v.reject_read(r);
}

map_finished :: (r: *core.Reader) -> bool {
    return wire.finished(r);
}

//@region Dictionary and set history and Changes
// HashSet forwards through its dictionary; all owners use the same lifetime.

dictionary_configure_history :: (d: *Dictionary($K, $V), depth, operations: int) -> bool {
    if depth < 2 || depth > MAX_HISTORY_DEPTH || operations < 1 || operations > MAX_OPERATIONS || (d.history).count != 0 || (d.journal).count != 0 {
        return false;
    }

    d.timeline.history_depth, d.timeline.journal_limit = depth, operations;
    return true;
}

map_clone_change :: (d: *Dictionary($K, $V), ch: Map_Change(K, V)) -> Map_Change(K, V) {
    out := ch;
    if ch.operation != .Clear {
        out.key = d.key_codec.clone(*out.key);
    }

    if ch.operation == .Set || ch.operation == .Insert {
        out.value = d.value_codec.clone(*out.value);
    }

    return out;
}

map_destroy_change :: (d: *Dictionary($K, $V), ch: *Map_Change(K, V)) {
    if ch.operation != .Clear {
        d.key_codec.destroy(*ch.key);
    }

    if ch.operation == .Set || ch.operation == .Insert {
        d.value_codec.destroy(*ch.value);
    }
}

map_clear_events :: (d: *Dictionary($K, $V)) {
    for *e: d.events {
        map_destroy_change(d, e);
    }

    release(d.events);
    d.events = .{};
}

map_end_events :: (d: *Dictionary($K, $V)) {
    map_clear_events(d);
    for *e: d.applied {
        map_destroy_change(d, *e.change);
    }

    release(d.applied);
    d.applied = .{};
    d.applied_cursor = 0;
    d.timeline.recovered = false;
}

map_compact_applied :: (d: *Dictionary($K, $V)) {
    count := max(d.applied_cursor, (d.applied).count - journal_limit(d.timeline));
    if count > d.applied_cursor {
        d.timeline.recovered = true;
    }

    {
        i := 0;
        while i < count {
            defer i += 1;
            map_destroy_change(d, *d.applied[i].change);
        }
    }

    {
        i := count;
        while i < (d.applied).count {
            defer i += 1;
            d.applied[i - count] = d.applied[i];
        }
    }

    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;
            array_ordered_remove_by_index(*d.applied, (d.applied).count - 1);
        }
    }

    d.applied_cursor = 0;
}

map_destroy_timeline :: (d: *Dictionary($K, $V)) {
    map_end_events(d);
    for *h: d.history {
        map_destroy_entries(d, *h.items);
    }

    release(d.history);
    for *e: d.journal {
        map_destroy_change(d, *e.change);
    }

    release(d.journal);
}

map_clone_timeline :: (dst, src: *Dictionary($K, $V)) {
    dst.timeline = src.timeline;
    dst.applied_cursor = src.applied_cursor;
    for h: src.history {
        copied := Map_Snapshot(K, V).{
            tick = h.tick, revision = h.revision,
        };

        for *e: h.items {
            array_add(*copied.items, map_clone_entry(src, e));
        }

        array_add(*dst.history, copied);
    }

    for e: src.journal {
        array_add(*dst.journal, Map_Event(K, V).{
            e.tick, e.revision, map_clone_change(src, *e.change)
        });
    };

    for e: src.applied {
        array_add(*dst.applied, Map_Event(K, V).{
            e.tick, e.revision, map_clone_change(src, *e.change)
        });
    };

    for e: src.events {
        array_add(*dst.events, map_clone_change(src, e));
    }
}

dictionary_tick :: (d: *Dictionary($K, $V), tick: u64) {
    if d.timeline.replaying || (d.timeline.started && tick < d.timeline.tick) {
        return;
    }

    if d.timeline.started && d.timeline.tick == tick {
        return;
    }

    d.timeline.started = true;
    d.timeline.tick = tick;
    d.timeline.rotated = false;
    map_destroy_changes(d);
    map_clear_events(d);
    map_compact_applied(d);
    d.base_revision = d.revision;
}

map_before_change :: (d: *Dictionary($K, $V)) {
    if d.timeline.rotated {
        return;
    }

    h := Map_Snapshot(K, V).{
        tick = d.timeline.head_tick, revision = d.revision,
    };

    for *e: d.items {
        array_add(*h.items, map_clone_entry(d, e));
    }

    if (d.history).count > 0 && d.history[(d.history).count - 1].tick == h.tick {
        map_destroy_entries(d, *d.history[(d.history).count - 1].items);
        d.history[(d.history).count - 1] = h;
    } else {
        if (d.history).count >= history_depth(d.timeline) - 1 {
            map_destroy_entries(d, *d.history[0].items);
            array_ordered_remove_by_index(*d.history, 0);
        }

        array_add(*d.history, h);
    }

    map_destroy_entries(d, *d.previous);
    for *e: d.items {
        array_add(*d.previous, map_clone_entry(d, e));
    }

    d.timeline.head_tick = max(d.timeline.head_tick, d.timeline.tick);
    d.timeline.rotated = true;
}

map_event :: (d: *Dictionary($K, $V), ch: Map_Change(K, V), tick: u64) {
    if d.timeline.event_tick != tick {
        map_clear_events(d);
    }

    d.timeline.event_tick = tick;
    if ch.operation == .Clear {
        map_clear_events(d);
    }

    // The dictionary Changes view reports Set even for an absent key. Preserve Insert in
    // the raw replay protocol but expose Set in its coalesced Changes view.

    view := ch;
    if d.kind == .Dictionary && view.operation == .Insert {
        view.operation = .Set;
    }

    if (d.events).count > 0 && view.operation == .Set {
        last := *d.events[(d.events).count - 1];
        if last.operation == .Set && d.key_codec.equal(*last.key, *view.key) {
            map_destroy_change(d, last);
            last.* = map_clone_change(d, view);
            return;
        }
    }

    array_add(*d.events, map_clone_change(d, view));
}

map_record :: (d: *Dictionary($K, $V), ch: Map_Change(K, V)) {
    d.timeline.head_tick = max(d.timeline.head_tick, d.timeline.tick);
    if (d.journal).count >= journal_limit(d.timeline) {
        map_destroy_change(d, *d.journal[0].change);
        array_ordered_remove_by_index(*d.journal, 0);
    }

    array_add(*d.journal, Map_Event(K, V).{
        d.timeline.head_tick, d.revision, map_clone_change(d, ch)
    });
    map_event(d, ch, d.timeline.head_tick);
};

dictionary_changes_view :: (d: *Dictionary($K, $V)) -> [] Map_Change(K, V) {
    return view(d.events, 0);
}

dictionary_take_applied_changes :: (d: *Dictionary($K, $V)) -> [] Map_Event(K, V) {
    out := view(d.applied, d.applied_cursor);
    d.applied_cursor = (d.applied).count;
    return out;
}

dictionary_values_at :: (d: *Dictionary($K, $V), tick: u64) -> ([] Entry(K, V), bool) {
    if tick >= d.timeline.head_tick {
        return view(d.items, 0), true;
    }

    {
        i := (d.history).count - 1;
        while i >= 0 {
            defer i -= 1;
            if d.history[i].tick <= tick {
                return view(d.history[i].items, 0), true;
            }
        }
    }

    return .[], false;
}

hashset_configure_history :: (s: *HashSet($T), depth, operations: int) -> bool {
    return dictionary_configure_history(*s.dictionary, depth, operations);
}

hashset_changes_view :: (s: *HashSet($T)) -> [] Map_Change(T, bool) {
    return dictionary_changes_view(*s.dictionary);
}

hashset_take_applied_changes :: (s: *HashSet($T)) -> [] Map_Event(T, bool) {
    return dictionary_take_applied_changes(*s.dictionary);
}

hashset_values_at :: (s: *HashSet($T), tick: u64) -> ([] Entry(T, bool), bool) {
    return dictionary_values_at(*s.dictionary, tick);
}

//@endregion
//@region Dictionary and set network values

map_write_value :: (d: *Dictionary($K, $V), w: *core.Writer) -> bool {
    body: core.Writer;
    core.writer_init(*body);
    defer core.writer_destroy(*body);
    if !dictionary_write_full(d, *body) {
        return v.reject_write(w);
    }

    data := core.writer_to_array(*body);
    defer release(data);
    wire.write_bytes(w, data);
    return w.err == .None;
}

map_read_value :: (d: *Dictionary($K, $V), r: *core.Reader) -> bool {
    data, ok := wire.read_bytes(r);
    if !ok {
        return false;
    }

    defer release(data);
    body: core.Reader;
    core.reader_init(*body, data);
    if !dictionary_apply_full(d, *body) || !wire.finished(*body) {
        return v.reject_read(r);
    }

    return true;
}

map_network_write :: (d: *Dictionary($K, $V), w: *core.Writer) -> bool {
    core.write_bits(w, NETWORK_MAGIC, 32);
    core.write_bits(w, d.timeline.head_tick, 64);
    if !map_write_value(d, w) {
        return false;
    }

    wire.write_count(w, (d.history).count, MAX_HISTORY_DEPTH - 1);
    for h: d.history {
        core.write_bits(w, h.tick, 64);
        view := map_empty_like(d, h.revision);
        view.items = h.items;
        if !map_write_value(*view, w) {
            return false;
        }
    }

    wire.write_count(w, (d.journal).count, MAX_OPERATIONS);
    for *e: d.journal {
        core.write_bits(w, e.*.tick, 64);
        core.write_bits(w, e.*.revision, 64);
        core.write_bits(w, (cast, trunc(u64)(e.*.change.operation)), 8);
        if e.*.change.operation != .Clear {
            if !v.write(d.key_codec, w, *e.change.key) {
                return false;
            }
        }

        if e.*.change.operation == .Set || e.*.change.operation == .Insert {
            if !v.write(d.value_codec, w, *e.change.value) {
                return false;
            }
        }
    }

    return w.err == .None;
}

map_network_read :: (d: *Dictionary($K, $V), r: *core.Reader) -> bool {
    peek := r.*;
    if core.read_bits(*peek, 32) != NETWORK_MAGIC {
        tmp := map_empty_like(d, 0);
        defer dictionary_destroy(*tmp);
        if !dictionary_apply_full(*tmp, r) || !wire.finished(r) || d.revision == (cast, trunc(u64)(18446744073709551615)) {
            return v.reject_read(r);
        }

        tmp.revision = max(tmp.revision, d.revision + 1);
        tmp.base_revision = tmp.revision;
        map_before_change(d);
        map_clone_timeline(*tmp, d);
        map_end_events(*tmp);
        for *e: tmp.journal {
            map_destroy_change(*tmp, *e.change);
        }

        release(tmp.journal);
        tmp.journal = .{};
        tmp.timeline.head_tick = max(d.timeline.head_tick, d.timeline.tick);
        tmp.timeline.rotated = false;
        map_destroy_entries(*tmp, *tmp.previous);
        for *e: d.items {
            array_add(*tmp.previous, map_clone_entry(d, e));
        }

        dictionary_destroy(d);
        d.* = tmp;
        tmp = .{
        };

        return true;
    }

    core.read_bits(r, 32);
    head_tick := core.read_bits(r, 64);
    tmp := map_empty_like(d, 0);
    defer dictionary_destroy(*tmp);
    if !map_read_value(*tmp, r) {
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
            h := map_empty_like(d, 0);
            if !map_read_value(*h, r) {
                dictionary_destroy(*h);
                return false;
            }

            legal := tick <= head_tick && h.revision <= tmp.revision;
            if i > 0 {
                legal = legal && tick > tmp.history[i - 1].tick && h.revision >= tmp.history[i - 1].revision;
            }

            if !legal {
                dictionary_destroy(*h);
                return v.reject_read(r);
            }

            array_add(*tmp.history, Map_Snapshot(K, V).{
                tick, h.revision, h.items
            });
            h.items = .{};
            dictionary_destroy(*h);
        }
    };

    n, ok = wire.read_count(r, MAX_OPERATIONS);
    if !ok || n > core.reader_remaining_bits(r) / 136 {
        return v.reject_read(r);
    }

    {
        i := 0;
        while i < n {
            defer i += 1;

            e := Map_Event(K, V).{
                tick = core.read_bits(r, 64), revision = core.read_bits(r, 64),
            };

            op := core.read_bits(r, 8);
            legal := op >= 1 && op <= 4 && e.tick <= head_tick && e.revision > 0 && e.revision <= tmp.revision;
            if d.kind == .HashSet && op == 1 {
                legal = false;
            }

            if i > 0 {
                legal = legal && e.revision == tmp.journal[i - 1].revision + 1 && e.tick >= tmp.journal[i - 1].tick;
            }

            if !legal {
                return v.reject_read(r);
            }

            e.change.operation = cast(Operation) (op);
            if op != 4 {
                key, good := v.read_new(d.key_codec, r);
                if !good {
                    return false;
                }

                e.change.key = key;
            }

            if op == 1 || op == 2 {
                value, good := v.read_new(d.value_codec, r);
                if !good {
                    map_destroy_change(*tmp, *e.change);
                    return false;
                }

                e.change.value = value;
                #if V == bool {
                    if d.kind == .HashSet && !value {
                        map_destroy_change(*tmp, *e.change);
                        return v.reject_read(r);
                    }
                }
            }

            array_add(*tmp.journal, e);
        }
    }

    if !wire.finished(r) || (n > 0 && tmp.journal[n - 1].revision != tmp.revision) {
        return v.reject_read(r);
    }

    map_commit_network(d, *tmp, head_tick);
    return true;
}

map_commit_network :: (d, tmp: *Dictionary($K, $V), head_tick: u64) {
    remote := d.timeline.remote_revision;
    continuous := d.timeline.has_remote && (tmp.revision == remote || (tmp.revision > remote && (tmp.journal).count > 0 && tmp.journal[0].revision <= remote + 1));
    tmp.timeline = d.timeline;
    tmp.timeline.recovered = d.timeline.has_remote && !continuous;
    tmp.timeline.head_tick = head_tick;
    tmp.timeline.has_remote = true;
    tmp.timeline.remote_revision = tmp.revision;
    tmp.timeline.rotated = false;
    while (tmp.history).count > history_depth(tmp.timeline) - 1 {
        map_destroy_entries(d, *tmp.history[0].items);
        array_ordered_remove_by_index(*tmp.history, 0);
    }

    map_destroy_entries(d, *tmp.previous);
    if !d.timeline.has_remote {
        for *e: tmp.items {
            array_add(*tmp.previous, map_clone_entry(d, e));
        }
    } else if tmp.revision == remote {
        for *e: d.previous {
            array_add(*tmp.previous, map_clone_entry(d, e));
        }
    } else if (tmp.history).count > 0 {
        for *e: tmp.history[(tmp.history).count - 1].items {
            array_add(*tmp.previous, map_clone_entry(d, e));
        }
    } else {
        for *e: d.items {
            array_add(*tmp.previous, map_clone_entry(d, e));
        }
    }

    for e: d.events {
        array_add(*tmp.events, map_clone_change(d, e));
    }

    for e: d.applied {
        array_add(*tmp.applied, Map_Event(K, V).{
            e.tick, e.revision, map_clone_change(d, *e.change)
        });
    };

    tmp.applied_cursor = d.applied_cursor;
    if continuous {
        tmp.base_revision = remote;
        if d.revision == remote && (d.changes).count + (cast(int) (tmp.revision - remote)) <= MAX_OPERATIONS {
            tmp.base_revision = d.base_revision;
            for ch: d.changes {
                array_add(*tmp.changes, map_clone_change(d, ch));
            }
        }

        for e: tmp.journal {
            if e.revision <= remote {
                continue;
            }

            array_add(*tmp.changes, map_clone_change(d, *e.change));
            array_add(*tmp.applied, Map_Event(K, V).{
                e.tick, e.revision, map_clone_change(d, *e.change)
            });
            map_event(tmp, *e.change, e.tick);
        };
    } else {
        map_clear_events(tmp);
        tmp.base_revision = tmp.revision;
    }

    map_compact_applied(tmp);
    while (tmp.journal).count > journal_limit(tmp.timeline) {
        map_destroy_change(tmp, *tmp.journal[0].change);
        array_ordered_remove_by_index(*tmp.journal, 0);
    }

    dictionary_destroy(d);
    d.* = tmp.*;
    tmp.* = .{
    };
}

//@endregion
// Cast semantics adapted.
// Loop scopes adapted.
// Iterator semantics adapted.
