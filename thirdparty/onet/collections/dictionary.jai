#scope_file
core :: #import "thirdparty/onet/core";
v :: #import "thirdparty/onet/values";
#scope_export

//@region Ordered dictionary storage

Entry :: struct(K, V: Type) {
    key: K;
    value: V;
}

Map_Change :: struct(K, V: Type) {
    operation: Operation;
    key: K;
    value: V;
}

// Sorted-vector dictionary: deterministic output, no hash seed or collision
// attacks. less must be a stable strict total order consistent with key.equal.

Dictionary :: struct(K, V: Type) {
    key_codec: v.Codec(K);

    value_codec: v.Codec(V);

    less: #type (*K, *K) -> bool;

    kind: Kind;

    limit: int;

    items: [..] Entry(K, V);

    previous: [..] Entry(K, V);

    changes: [..] Map_Change(K, V);

    revision: u64;

    base_revision: u64;

    timeline: Timeline;

    history: [..] Map_Snapshot(K, V);

    journal: [..] Map_Event(K, V);

    events: [..] Map_Change(K, V);

    applied: [..] Map_Event(K, V);

    applied_cursor: int;
}

dictionary_init :: (d: *Dictionary($K, $V), kc: v.Codec(K), vc: v.Codec(V), less: #type (*K, *K) -> bool, limit := DEFAULT_LIMIT) -> bool {
    if !v.valid(kc) || !v.valid(vc) || less == null || limit < 0 || limit > MAX_ELEMENTS {
        return false;
    }

    d.* = .{
        key_codec = kc, value_codec = vc, less = less, kind = .Dictionary, limit = limit,
    };

    return true;
}

map_destroy_entries :: (d: *Dictionary($K, $V), a: *[..] Entry(K, V)) {
    for *e: a.* {
        d.key_codec.destroy(*e.key);
        d.value_codec.destroy(*e.value);
    }

    release(a.*);
    a.* = .{};
}

map_destroy_changes :: (d: *Dictionary($K, $V)) {
    for *c: d.changes {
        if c.*.operation != .Clear {
            d.key_codec.destroy(*c.key);
        }

        if c.*.operation == .Set || c.*.operation == .Insert {
            d.value_codec.destroy(*c.value);
        }
    }

    release(d.changes);
    d.changes = .{};
}

dictionary_destroy :: (d: *Dictionary($K, $V)) {
    if v.valid(d.key_codec) && v.valid(d.value_codec) {
        map_destroy_entries(d, *d.items);
        map_destroy_entries(d, *d.previous);
        map_destroy_changes(d);
        map_destroy_timeline(d);
    }

    d.* = .{
    };
}

map_clone_entry :: (d: *Dictionary($K, $V), e: *Entry(K, V)) -> Entry(K, V) {
    return .{
        d.key_codec.clone(*e.key), d.value_codec.clone(*e.value),
    };
}

dictionary_begin_tick :: (d: *Dictionary($K, $V)) {
    d.timeline.tick += 1;
    d.timeline.started = true;
    d.timeline.rotated = false;
    map_before_change(d);
    map_destroy_changes(d);
    d.base_revision = d.revision;
    map_clear_events(d);
    map_compact_applied(d);
}

dictionary_changed :: (d: *Dictionary($K, $V)) -> bool {
    return d.revision != d.base_revision;
}

dictionary_count :: (d: *Dictionary($K, $V)) -> int {
    return (d.items).count;
}

map_find :: (d: *Dictionary($K, $V), a: [] Entry(K, V), key: *K) -> (index: int, found: bool) {
    lo, hi := 0, (a).count;
    while lo < hi {
        mid := lo + (hi - lo) / 2;
        if d.less(*a[mid].key, key) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    return lo, lo < (a).count && d.key_codec.equal(*a[lo].key, key);
}

// Borrowed value, invalidated by mutation; never free/mutate an owning result.

dictionary_get :: (d: *Dictionary($K, $V), input: K, previous := false) -> (V, bool) {
    key := input;
    a := view(d.items, 0);
    if previous {
        a = view(d.previous, 0);
    }

    i, found := map_find(d, a, *key);
    if !found {
        return .{
        }, false;
    };

    return a[i].value, true;
}

map_can_change :: (d: *Dictionary($K, $V)) -> bool {
    return !d.timeline.replaying && d.revision < (cast, trunc(u64)(18446744073709551615)) && (d.changes).count < MAX_OPERATIONS;
}

//@endregion
//@region Dictionary mutations

map_put :: (d: *Dictionary($K, $V), input_key: K, input_value: V, only_add: bool) -> bool {
    if d.timeline.replaying {
        return false;
    }

    key, value := input_key, input_value;
    #if V == bool {
        if d.kind == .HashSet && !value {
            return false;
        }
    }

    if d.less(*key, *key) {
        return false;
    }

    i, found := map_find(d, view(d.items, 0), *key);
    if found && only_add {
        return false;
    }

    if found && d.value_codec.equal(*d.items[i].value, *value) {
        return true;
    }

    if !map_can_change(d) || (!found && (d.items).count >= d.limit) {
        return false;
    }

    if !found {
        // Reject inconsistent comparator equivalence rather than silently
        // replacing a different key.

        if i < (d.items).count && !d.less(*key, *d.items[i].key) {
            return false;
        }

        if i > 0 && !d.less(*d.items[i - 1].key, *key) {
            return false;
        }
    }

    log := Map_Change(K, V).{
        key = d.key_codec.clone(*key), value = d.value_codec.clone(*value),
    };

    x := d.value_codec.clone(*value);
    map_before_change(d);
    if found {
        log.operation = .Set;
        d.value_codec.destroy(*d.items[i].value);
        d.items[i].value = x;
    } else {
        log.operation = .Insert;
        e := Entry(K, V).{
            d.key_codec.clone(*key), x,
        };

        array_add(*d.items, e);
        {
            j := (d.items).count - 1;
            while j > i {
                defer j -= 1;
                d.items[j] = d.items[j - 1];
            }
        }

        d.items[i] = e;
    }

    array_add(*d.changes, log);
    d.revision += 1;
    map_record(d, d.changes[(d.changes).count - 1]);
    return true;
}

dictionary_add :: (d: *Dictionary($K, $V), key: K, value: V) -> bool {
    return map_put(d, key, value, true);
}

dictionary_set :: (d: *Dictionary($K, $V), key: K, value: V) -> bool {
    return map_put(d, key, value, false);
}

dictionary_remove :: (d: *Dictionary($K, $V), input: K) -> bool {
    key := input;
    i, found := map_find(d, view(d.items, 0), *key);
    if !found || !map_can_change(d) {
        return false;
    }

    log := Map_Change(K, V).{
        operation = .Remove, key = d.key_codec.clone(*key),
    };

    map_before_change(d);
    d.key_codec.destroy(*d.items[i].key);
    d.value_codec.destroy(*d.items[i].value);
    {
        j := i;
        while j < (d.items).count - 1 {
            defer j += 1;
            d.items[j] = d.items[j + 1];
        }
    }

    pop(*d.items);
    array_add(*d.changes, log);
    d.revision += 1;
    map_record(d, d.changes[(d.changes).count - 1]);
    return true;
}

dictionary_clear :: (d: *Dictionary($K, $V)) -> bool {
    if d.timeline.replaying {
        return false;
    }

    if (d.items).count == 0 && (d.changes).count == 0 {
        return true;
    }

    if !map_can_change(d) {
        return false;
    }

    map_before_change(d);
    map_destroy_entries(d, *d.items);
    array_add(*d.changes, Map_Change(K, V).{
        operation = .Clear
    });
    d.revision += 1;
    map_record(d, d.changes[(d.changes).count - 1]);
    return true;
};

//@endregion
//@region Dictionary full/delta protocol

map_write_header :: (d: *Dictionary($K, $V), w: *core.Writer, delta: bool, n: int) {
    base: u64;
    if delta {
        base = d.base_revision;
    }

    write_header(w, d.kind, d.key_codec.schema, delta, base, d.revision, n);
    core.write_bits(w, (cast, trunc(u64)(d.value_codec.schema)), 32);
}

dictionary_write_full :: (d: *Dictionary($K, $V), w: *core.Writer) -> bool {
    if !v.valid(d.key_codec) || !v.valid(d.value_codec) || w.err != .None || (d.items).count > d.limit {
        return v.reject_write(w);
    }

    map_write_header(d, w, false, (d.items).count);
    for *e: d.items {
        if !v.write(d.key_codec, w, *e.key) || !v.write(d.value_codec, w, *e.value) {
            return false;
        }
    }

    return w.err == .None;
}

dictionary_write_delta :: (d: *Dictionary($K, $V), w: *core.Writer) -> bool {
    if !v.valid(d.key_codec) || !v.valid(d.value_codec) || w.err != .None || d.revision - d.base_revision != (cast, trunc(u64)((d.changes).count)) {
        return v.reject_write(w);
    }

    map_write_header(d, w, true, (d.changes).count);
    for *c: d.changes {
        core.write_bits(w, (cast, trunc(u64)(c.*.operation)), 8);
        if c.*.operation != .Clear {
            if !v.write(d.key_codec, w, *c.key) {
                return false;
            }
        }

        if c.*.operation == .Set || c.*.operation == .Insert {
            if !v.write(d.value_codec, w, *c.value) {
                return false;
            }
        }
    }

    return w.err == .None;
}

map_empty_like :: (d: *Dictionary($K, $V), revision: u64) -> Dictionary(K, V) {
    return .{
        key_codec = d.key_codec, value_codec = d.value_codec, less = d.less, kind = d.kind, limit = d.limit, revision = revision, base_revision = revision,
    };
}

dictionary_apply_full :: (d: *Dictionary($K, $V), r: *core.Reader) -> bool {
    if !v.valid(d.key_codec) || !v.valid(d.value_codec) {
        return v.reject_read(r);
    }

    base, revision, n, ok := read_header(r, d.kind, d.key_codec.schema, false);
    schema := core.read_bits(r, 32);
    if !ok || r.err != .None || schema != (cast, trunc(u64)(d.value_codec.schema)) || base != 0 || n > d.limit || n > core.reader_remaining_bits(r) / 2 {
        return v.reject_read(r);
    }

    tmp := map_empty_like(d, revision);
    tmp.timeline = d.timeline;
    tmp.timeline.head_tick = d.timeline.tick;
    tmp.timeline.rotated = false;
    tmp.timeline.has_remote = false;
    tmp.timeline.remote_revision = 0;
    defer dictionary_destroy(*tmp);
    {
        loop_index := 0;
        while loop_index < n {
            defer loop_index += 1;

            key, good := v.read_new(d.key_codec, r);
            if !good {
                return false;
            }

            value, good_value := v.read_new(d.value_codec, r);
            if !good_value {
                d.key_codec.destroy(*key);
                return false;
            }

            legal := !d.less(*key, *key);
            if (tmp.items).count > 0 {
                prev := *tmp.items[(tmp.items).count - 1].key;
                legal = legal && d.less(prev, *key) && !d.key_codec.equal(prev, *key);
            }

            #if V == bool {
                if d.kind == .HashSet {
                    legal = legal && value;
                }
            }

            if !legal {
                d.key_codec.destroy(*key);
                d.value_codec.destroy(*value);
                return v.reject_read(r);
            }

            array_add(*tmp.items, Entry(K, V).{
                key, value
            });
        }
    };

    for *e: tmp.items {
        array_add(*tmp.previous, map_clone_entry(d, e));
    }

    dictionary_destroy(d);
    d.* = tmp;
    tmp = .{
    };

    return true;
}

dictionary_apply_delta :: (d: *Dictionary($K, $V), r: *core.Reader) -> bool {
    if !v.valid(d.key_codec) || !v.valid(d.value_codec) {
        return v.reject_read(r);
    }

    base, revision, n, ok := read_header(r, d.kind, d.key_codec.schema, true);
    schema := core.read_bits(r, 32);
    if !ok || r.err != .None || schema != (cast, trunc(u64)(d.value_codec.schema)) || base != d.revision || n > MAX_OPERATIONS - (d.changes).count || n > core.reader_remaining_bits(r) / 8 || (cast, trunc(u64)(n)) > (cast, trunc(u64)(18446744073709551615)) - base || revision != base + (cast, trunc(u64)(n)) {
        return v.reject_read(r);
    }

    tmp := map_empty_like(d, base);
    tmp.base_revision = d.base_revision;
    defer dictionary_destroy(*tmp);
    for *e: d.items {
        array_add(*tmp.items, map_clone_entry(d, e));
    }

    for *e: d.previous {
        array_add(*tmp.previous, map_clone_entry(d, e));
    }

    for *ch: d.changes {
        copied := ch.*;
        if ch.*.operation != .Clear {
            copied.key = d.key_codec.clone(*ch.key);
        }

        if ch.*.operation == .Set || ch.*.operation == .Insert {
            copied.value = d.value_codec.clone(*ch.value);
        }

        array_add(*tmp.changes, copied);
    }

    map_clone_timeline(*tmp, d);
    replaying := tmp.timeline.replaying;
    tmp.timeline.replaying = false;
    {
        loop_index := 0;
        while loop_index < n {
            defer loop_index += 1;

            op := core.read_bits(r, 8);
            if r.err != .None {
                return false;
            }

            if op == (cast, trunc(u64)(Operation.Clear)) {
                if ((tmp.items).count == 0 && (tmp.changes).count == 0) || !dictionary_clear(*tmp) {
                    return v.reject_read(r);
                }

                continue;
            }

            if op != (cast, trunc(u64)(Operation.Set)) && op != (cast, trunc(u64)(Operation.Insert)) && op != (cast, trunc(u64)(Operation.Remove)) {
                return v.reject_read(r);
            }

            key, good := v.read_new(d.key_codec, r);
            if !good {
                return false;
            }

            _, found := map_find(*tmp, view(tmp.items, 0), *key);
            legal := (op == (cast, trunc(u64)(Operation.Insert)) && !found) || (op != (cast, trunc(u64)(Operation.Insert)) && found);
            if !legal {
                d.key_codec.destroy(*key);
                return v.reject_read(r);
            }

            before := tmp.revision;
            applied := false;
            if op == (cast, trunc(u64)(Operation.Remove)) {
                applied = dictionary_remove(*tmp, key);
            } else {
                value, good_value := v.read_new(d.value_codec, r);
                if !good_value {
                    d.key_codec.destroy(*key);
                    return false;
                }

                applied = map_put(*tmp, key, value, op == (cast, trunc(u64)(Operation.Insert)));
                d.value_codec.destroy(*value);
            }

            d.key_codec.destroy(*key);
            if !applied || tmp.revision != before + 1 {
                return v.reject_read(r);
            }
        }
    }

    if r.err != .None || tmp.revision != revision {
        return v.reject_read(r);
    }

    tmp.timeline.replaying = replaying;
    dictionary_destroy(d);
    d.* = tmp;
    tmp = .{
    };

    return true;
}

//@endregion
//@region Set semantics
// A deterministic ordered set, not a native hash table. No mutable key aliases.

HashSet :: struct(T: Type) {
    dictionary: Dictionary(T, bool);
}

hashset_init :: (s: *HashSet($T), c: v.Codec(T), less: #type (*T, *T) -> bool, limit := DEFAULT_LIMIT) -> bool {
    if !dictionary_init(*s.dictionary, c, v.builtin(bool), less, limit) {
        return false;
    }

    s.dictionary.kind = .HashSet;
    return true;
}

hashset_destroy :: (s: *HashSet($T)) {
    dictionary_destroy(*s.dictionary);
}

hashset_begin_tick :: (s: *HashSet($T)) {
    dictionary_begin_tick(*s.dictionary);
}

hashset_changed :: (s: *HashSet($T)) -> bool {
    return dictionary_changed(*s.dictionary);
}

hashset_count :: (s: *HashSet($T)) -> int {
    return dictionary_count(*s.dictionary);
}

hashset_contains :: (s: *HashSet($T), value: T, previous := false) -> bool {
    _, found := dictionary_get(*s.dictionary, value, previous);
    return found;
}

hashset_add :: (s: *HashSet($T), value: T) -> bool {
    return dictionary_add(*s.dictionary, value, true);
}

hashset_remove :: (s: *HashSet($T), value: T) -> bool {
    return dictionary_remove(*s.dictionary, value);
}

hashset_clear :: (s: *HashSet($T)) -> bool {
    return dictionary_clear(*s.dictionary);
}

hashset_write_full :: (s: *HashSet($T), w: *core.Writer) -> bool {
    return dictionary_write_full(*s.dictionary, w);
}

hashset_write_delta :: (s: *HashSet($T), w: *core.Writer) -> bool {
    return dictionary_write_delta(*s.dictionary, w);
}

hashset_apply_full :: (s: *HashSet($T), r: *core.Reader) -> bool {
    return dictionary_apply_full(*s.dictionary, r);
}

hashset_apply_delta :: (s: *HashSet($T), r: *core.Reader) -> bool {
    return dictionary_apply_delta(*s.dictionary, r);
}

//@endregion
// Cast semantics adapted.
// Loop scopes adapted.
// Iterator semantics adapted.
