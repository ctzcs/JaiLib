#scope_file
core :: #import "thirdparty/onet/core";
c :: #import "thirdparty/onet/collections";
v :: #import "thirdparty/onet/values";
#scope_export

//@region Collection replication tests

collections_less_string :: (a, b: *string) -> bool {
    return Str.compare(a.*, b.*) < 0;
}

collections_less_i32 :: (a, b: *s32) -> bool {
    return a.* < b.*;
}

collections_list_full_delta :: (t: *Test) {
    a, b: c.Sequence(string);
    codec := v.builtin(string);
    expect(t, c.list_init(*a, codec, 8) && c.list_init(*b, codec, 8));
    defer c.destroy(*a);
    defer c.destroy(*b);
    expect(t, c.add(*a, "first") && c.add(*a, "second"));
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    expect(t, c.write_full(*a, *w));
    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_full(*b, *r));
    expect(t, !c.changed(*b));
    c.begin_tick(*a);
    expect(t, c.set(*a, 0, "first") && !c.changed(*a));
    expect(t, c.insert(*a, 1, "middle") && c.set(*a, 0, "changed") && c.remove_at(*a, 2));
    old, exists := c.get(*a, 0, true);
    expect(t, exists && old == "first");
    core.writer_reset(*w);
    expect(t, c.write_delta(*a, *w));
    // Every byte truncation must leave live and previous owners/revision alone.

    {
        cut := 0;
        while cut < (w.buffer).count {
            defer cut += 1;

            core.reader_init(*r, view(w.buffer, 0, cut));
            expect(t, !c.apply_delta(*b, *r));
            x, found := c.get(*b, 0);
            expect(t, found && x == "first" && b.revision == a.base_revision);
        }
    }

    core.reader_from_writer(*r, *w);
    expect(t, c.apply_delta(*b, *r));
    x, found := c.get(*b, 0);
    expect(t, found && x == "changed" && c.count(*b) == 2 && b.revision == a.revision);
    old, exists = c.get(*b, 0, true);
    expect(t, exists && old == "first");
    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_delta(*b, *r) && b.revision == a.revision);
    c.begin_tick(*a);
    expect(t, c.clear(*a));
    core.writer_reset(*w);
    expect(t, c.write_delta(*a, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_delta(*b, *r) && c.count(*b) == 0);
    c.begin_tick(*a);
    c.begin_tick(*b);
    core.writer_reset(*w);
    expect(t, c.write_delta(*a, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_delta(*b, *r) && !c.changed(*b));
}

collections_array_and_queue :: (t: *Test) {
    a, b: c.Sequence(s32);
    codec := v.builtin(s32);
    initial: [] s32 = s32.[1, 2, 3];
    expect(t, c.array_init(*a, codec, initial) && c.array_init(*b, codec, initial));
    defer c.destroy(*a);
    defer c.destroy(*b);
    expect(t, !c.add(*a, 4) && !c.remove_at(*a, 0) && !c.set(*a, 3, 4));
    expect(t, c.set(*a, 1, 22));
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    expect(t, c.write_delta(*a, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_delta(*b, *r) && b.items[1] == 22);
    core.writer_reset(*w);
    expect(t, c.write_full(*a, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_full(*b, *r) && c.count(*b) == 3);
    q, z: c.Sequence(string);
    expect(t, c.queue_init(*q, v.builtin(string), 3) && c.queue_init(*z, v.builtin(string), 3));
    defer c.destroy(*q);
    defer c.destroy(*z);
    expect(t, c.enqueue(*q, "one") && c.enqueue(*q, "two") && !c.set(*q, 0, "bad") && !c.insert(*q, 0, "bad"));
    popped, good := c.dequeue(*q);
    expect(t, good && popped == "one");
    q.codec.destroy(*popped);
    expect(t, !c.remove_at(*q, 1));
    core.writer_reset(*w);
    expect(t, c.write_delta(*q, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_delta(*z, *r) && c.count(*z) == 1 && z.items[0] == "two");
    core.writer_reset(*w);
    expect(t, c.write_full(*q, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_full(*z, *r));
}

collections_dictionary_lifecycle_delta :: (t: *Test) {
    a, b: c.Dictionary(string, string);
    codec := v.builtin(string);
    expect(t, c.dictionary_init(*a, codec, codec, collections_less_string, 4) && c.dictionary_init(*b, codec, codec, collections_less_string, 4));
    defer c.dictionary_destroy(*a);
    defer c.dictionary_destroy(*b);
    expect(t, c.dictionary_add(*a, "b", "bee") && c.dictionary_add(*a, "a", "aye") && !c.dictionary_add(*a, "a", "duplicate"));
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    expect(t, c.dictionary_write_full(*a, *w));
    {
        cut := 0;
        while cut < (w.buffer).count {
            defer cut += 1;

            core.reader_init(*r, view(w.buffer, 0, cut));
            expect(t, !c.dictionary_apply_full(*b, *r) && c.dictionary_count(*b) == 0);
        }
    }

    core.reader_from_writer(*r, *w);
    expect(t, c.dictionary_apply_full(*b, *r));
    c.dictionary_begin_tick(*a);
    expect(t, c.dictionary_set(*a, "a", "aye") && !c.dictionary_changed(*a));
    expect(t, c.dictionary_set(*a, "a", "new") && c.dictionary_remove(*a, "b") && c.dictionary_set(*a, "c", "see"));
    old, found := c.dictionary_get(*a, "a", true);
    expect(t, found && old == "aye");
    core.writer_reset(*w);
    expect(t, c.dictionary_write_delta(*a, *w));
    {
        cut := 0;
        while cut < (w.buffer).count {
            defer cut += 1;

            core.reader_init(*r, view(w.buffer, 0, cut));
            expect(t, !c.dictionary_apply_delta(*b, *r));
            x, good := c.dictionary_get(*b, "a");
            expect(t, good && x == "aye" && c.dictionary_count(*b) == 2 && b.revision == a.base_revision);
        }
    }

    core.reader_from_writer(*r, *w);
    expect(t, c.dictionary_apply_delta(*b, *r));
    x, good := c.dictionary_get(*b, "a");
    expect(t, good && x == "new" && b.revision == a.revision);
    core.reader_from_writer(*r, *w);
    expect(t, !c.dictionary_apply_delta(*b, *r));
    c.dictionary_begin_tick(*a);
    expect(t, c.dictionary_clear(*a));
    core.writer_reset(*w);
    expect(t, c.dictionary_write_delta(*a, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.dictionary_apply_delta(*b, *r) && c.dictionary_count(*b) == 0);
}

collections_map_determinism_set :: (t: *Test) {
    a, b: c.Dictionary(s32, string);
    expect(t, c.dictionary_init(*a, v.builtin(s32), v.builtin(string), collections_less_i32) && c.dictionary_init(*b, v.builtin(s32), v.builtin(string), collections_less_i32));
    defer c.dictionary_destroy(*a);
    defer c.dictionary_destroy(*b);
    expect(t, c.dictionary_add(*a, 2, "two") && c.dictionary_add(*a, 1, "one"));
    expect(t, c.dictionary_add(*b, 1, "one") && c.dictionary_add(*b, 2, "two"));
    w, z: core.Writer;
    core.writer_init(*w);
    core.writer_init(*z);
    defer core.writer_destroy(*w);
    defer core.writer_destroy(*z);
    expect(t, c.dictionary_write_full(*a, *w) && c.dictionary_write_full(*b, *z));
    expect_value(t, (w.buffer).count, (z.buffer).count);
    for x, i: w.buffer {
        expect(t, x == z.buffer[i]);
    }

    s, u: c.HashSet(string);
    expect(t, c.hashset_init(*s, v.builtin(string), collections_less_string) && c.hashset_init(*u, v.builtin(string), collections_less_string));
    defer c.hashset_destroy(*s);
    defer c.hashset_destroy(*u);
    expect(t, c.hashset_add(*s, "z") && c.hashset_add(*s, "a") && !c.hashset_add(*s, "a"));
    core.writer_reset(*w);
    expect(t, c.hashset_write_full(*s, *w));
    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect(t, c.hashset_apply_full(*u, *r) && c.hashset_contains(*u, "z"));
    c.hashset_begin_tick(*s);
    expect(t, c.hashset_remove(*s, "z") && c.hashset_add(*s, "b") && c.hashset_changed(*s) && c.hashset_contains(*s, "z", true));
    core.writer_reset(*w);
    expect(t, c.hashset_write_delta(*s, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.hashset_apply_delta(*u, *r) && !c.hashset_contains(*u, "z") && c.hashset_count(*u) == 2);
    c.hashset_begin_tick(*s);
    expect(t, c.hashset_clear(*s));
    core.writer_reset(*w);
    expect(t, c.hashset_write_delta(*s, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.hashset_apply_delta(*u, *r) && c.hashset_count(*u) == 0);
}

collections_malformed_operations :: (t: *Test) {
    a: c.Sequence(s32);
    expect(t, c.list_init(*a, v.builtin(s32), 2) && c.add(*a, 10));
    defer c.destroy(*a);
    c.begin_tick(*a);
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    // A valid first operation followed by illegal index/op/size must roll back.

    bad_ops: [] u64 = u64.[1, 2, 3, 4, 255];
    for bad: bad_ops {
        core.writer_reset(*w);
        c.write_header(*w, .List, a.codec.schema, true, a.revision, a.revision + 2, 2);
        core.write_bits(*w, 1, 8);
        core.write_bits(*w, 0, 32);
        x := (cast, trunc(s32)(20));
        expect(t, v.write(a.codec, *w, *x));
        core.write_bits(*w, bad, 8);
        core.write_bits(*w, 999, 32);
        expect(t, v.write(a.codec, *w, *x));
        core.reader_from_writer(*r, *w);
        expect(t, !c.apply_delta(*a, *r) && a.items[0] == 10 && a.revision == 1 && (a.changes).count == 0);
    }

    core.writer_reset(*w);
    c.write_header(*w, .List, a.codec.schema, false, 0, 100, 3);
    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_full(*a, *r) && a.items[0] == 10);
    // Duplicate keys in an otherwise well-formed full are forbidden.

    d: c.Dictionary(s32, s32);
    expect(t, c.dictionary_init(*d, v.builtin(s32), v.builtin(s32), collections_less_i32));
    defer c.dictionary_destroy(*d);
    core.writer_reset(*w);
    c.write_header(*w, .Dictionary, d.key_codec.schema, false, 0, 2, 2);
    core.write_bits(*w, (cast, trunc(u64)(d.value_codec.schema)), 32);
    {
        loop_index := 0;
        while loop_index < 2 {
            defer loop_index += 1;
            core.write_bits(*w, 1, 32);
            core.write_bits(*w, 9, 32);
        }
    }

    core.reader_from_writer(*r, *w);
    expect(t, !c.dictionary_apply_full(*d, *r) && c.dictionary_count(*d) == 0 && d.revision == 0);
    // An insert of a duplicate key in a delta rolls back the first insertion.

    core.writer_reset(*w);
    c.write_header(*w, .Dictionary, d.key_codec.schema, true, 0, 2, 2);
    core.write_bits(*w, (cast, trunc(u64)(d.value_codec.schema)), 32);
    {
        loop_index := 0;
        while loop_index < 2 {
            defer loop_index += 1;
            core.write_bits(*w, 2, 8);
            core.write_bits(*w, 1, 32);
            core.write_bits(*w, 9, 32);
        }
    }

    core.reader_from_writer(*r, *w);
    expect(t, !c.dictionary_apply_delta(*d, *r) && c.dictionary_count(*d) == 0 && d.revision == 0);
}

collections_empty_wrappers_and_limits :: (t: *Test) {
    list: c.List(string);
    array: c.Array(string);
    queue: c.Queue(string);
    expect(t, c.list_init(*list.state, v.builtin(string), 1));
    expect(t, c.array_init(*array.state, v.builtin(string), .[]));
    expect(t, c.queue_init(*queue.state, v.builtin(string), 0));
    defer c.destroy(*list.state);
    defer c.destroy(*array.state);
    defer c.destroy(*queue.state);
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    expect(t, c.write_full(*list.state, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_full(*list.state, *r) && c.count(*list.state) == 0);
    core.writer_reset(*w);
    expect(t, c.write_full(*array.state, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_full(*array.state, *r) && c.count(*array.state) == 0);
    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_full(*queue.state, *r));
    expect(t, !c.enqueue(*queue.state, "too big"));
    _, ok := c.dequeue(*queue.state);
    expect(t, !ok);
    expect(t, c.add(*list.state, "one") && !c.add(*list.state, "two"));
    expect(t, !c.insert(*list.state, -1, "bad") && !c.remove_at(*list.state, -1));
    _, ok = c.get(*list.state, -1);
    expect(t, !ok);
    // Empty dictionary full/delta are valid, not a null marker.

    d: c.Dictionary(s32, string);
    expect(t, c.dictionary_init(*d, v.builtin(s32), v.builtin(string), collections_less_i32, 0));
    defer c.dictionary_destroy(*d);
    core.writer_reset(*w);
    expect(t, c.dictionary_write_full(*d, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.dictionary_apply_full(*d, *r));
    core.writer_reset(*w);
    expect(t, c.dictionary_write_delta(*d, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.dictionary_apply_delta(*d, *r) && !c.dictionary_changed(*d));
    expect(t, !c.dictionary_add(*d, 1, "over limit"));
}

collections_snapshot_survives_multiple_packets :: (t: *Test) {
    a, b, z: c.Sequence(string);
    expect(t, c.list_init(*a, v.builtin(string)) && c.list_init(*b, v.builtin(string)) && c.list_init(*z, v.builtin(string)));
    defer c.destroy(*a);
    defer c.destroy(*b);
    defer c.destroy(*z);
    expect(t, c.add(*a, "baseline"));
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    expect(t, c.write_full(*a, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_full(*b, *r));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_full(*z, *r));
    next: [] string = string.["packet one", "packet two"];
    for text: next {
        c.begin_tick(*a);
        expect(t, c.set(*a, 0, text));
        core.writer_reset(*w);
        expect(t, c.write_delta(*a, *w));
        {
            cut := 0;
            while cut < (w.buffer).count {
                defer cut += 1;

                revision := b.revision;
                core.reader_init(*r, view(w.buffer, 0, cut));
                expect(t, !c.apply_delta(*b, *r) && b.revision == revision && b.previous[0] == "baseline");
            }
        }

        core.reader_from_writer(*r, *w);
        expect(t, c.apply_delta(*b, *r) && b.previous[0] == "baseline");
    }

    // Receiver can forward the combined window without losing earlier ops.

    core.writer_reset(*w);
    expect(t, c.write_delta(*b, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_delta(*z, *r) && z.items[0] == "packet two" && z.previous[0] == "baseline");
    d, e, f: c.Dictionary(string, string);
    codec := v.builtin(string);
    expect(t, c.dictionary_init(*d, codec, codec, collections_less_string) && c.dictionary_init(*e, codec, codec, collections_less_string) && c.dictionary_init(*f, codec, codec, collections_less_string));
    defer c.dictionary_destroy(*d);
    defer c.dictionary_destroy(*e);
    defer c.dictionary_destroy(*f);
    expect(t, c.dictionary_add(*d, "key", "baseline"));
    core.writer_reset(*w);
    expect(t, c.dictionary_write_full(*d, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.dictionary_apply_full(*e, *r));
    core.reader_from_writer(*r, *w);
    expect(t, c.dictionary_apply_full(*f, *r));
    for text: next {
        c.dictionary_begin_tick(*d);
        expect(t, c.dictionary_set(*d, "key", text));
        core.writer_reset(*w);
        expect(t, c.dictionary_write_delta(*d, *w));
        {
            cut := 0;
            while cut < (w.buffer).count {
                defer cut += 1;

                revision := e.revision;
                core.reader_init(*r, view(w.buffer, 0, cut));
                expect(t, !c.dictionary_apply_delta(*e, *r) && e.revision == revision && e.previous[0].value == "baseline");
            }
        }

        core.reader_from_writer(*r, *w);
        expect(t, c.dictionary_apply_delta(*e, *r) && e.previous[0].value == "baseline");
    }

    core.writer_reset(*w);
    expect(t, c.dictionary_write_delta(*e, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.dictionary_apply_delta(*f, *r) && f.items[0].value == "packet two" && f.previous[0].value == "baseline");
}

collections_reject_family_schema_and_operation_forgery :: (t: *Test) {
    array: c.Array(s32);
    queue: c.Queue(s32);
    expect(t, c.array_init(*array.state, v.builtin(s32), s32.[1]));
    expect(t, c.queue_init(*queue.state, v.builtin(s32)) && c.enqueue(*queue.state, 1));
    defer c.destroy(*array.state);
    defer c.destroy(*queue.state);
    c.begin_tick(*queue.state);
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    // List-style structural edits are not legal for an array (use Resize).

    c.write_header(*w, .Array, array.codec.schema, true, 0, 1, 1);
    core.write_bits(*w, 2, 8);
    core.write_bits(*w, 0, 32);
    core.write_bits(*w, 2, 32);
    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_delta(*array.state, *r) && array.items[0] == 1 && array.revision == 0);
    core.writer_reset(*w);
    c.write_header(*w, .Array, array.codec.schema, false, 0, 1, c.MAX_ELEMENTS + 1);
    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_full(*array.state, *r) && c.count(*array.state) == 1);
    // Queue Set is forbidden even at a valid index.

    core.writer_reset(*w);
    c.write_header(*w, .Queue, queue.codec.schema, true, 1, 2, 1);
    core.write_bits(*w, 1, 8);
    core.write_bits(*w, 0, 32);
    core.write_bits(*w, 2, 32);
    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_delta(*queue.state, *r) && queue.items[0] == 1 && queue.revision == 1);
    // Correct family with the wrong schema cannot be reinterpreted.

    core.writer_reset(*w);
    c.write_header(*w, .Queue, v.builtin(u32).schema, false, 0, 1, 1);
    core.write_bits(*w, 2, 32);
    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_full(*queue.state, *r) && queue.items[0] == 1);
    d: c.Dictionary(s32, string);
    expect(t, c.dictionary_init(*d, v.builtin(s32), v.builtin(string), collections_less_i32));
    defer c.dictionary_destroy(*d);
    bad_ops: [] u64 = u64.[1, 3, 4, 255];
    for op: bad_ops {
        core.writer_reset(*w);
        c.write_header(*w, .Dictionary, d.key_codec.schema, true, 0, 1, 1);
        core.write_bits(*w, (cast, trunc(u64)(d.value_codec.schema)), 32);
        core.write_bits(*w, op, 8);
        core.write_bits(*w, 99, 32);
        core.reader_from_writer(*r, *w);
        expect(t, !c.dictionary_apply_delta(*d, *r) && c.dictionary_count(*d) == 0 && d.revision == 0 && (d.changes).count == 0);
    }

    set: c.HashSet(s32);
    expect(t, c.hashset_init(*set, v.builtin(s32), collections_less_i32));
    defer c.hashset_destroy(*set);
    core.writer_reset(*w);
    c.write_header(*w, .HashSet, v.builtin(s32).schema, false, 0, 1, 1);
    core.write_bits(*w, (cast, trunc(u64)(v.builtin(bool).schema)), 32);
    core.write_bits(*w, 1, 32);
    core.write_boolean(*w, false);
    core.reader_from_writer(*r, *w);
    expect(t, !c.hashset_apply_full(*set, *r) && c.hashset_count(*set) == 0);
    // Overflow and oversized counts cannot request allocation or wrap revision.

    core.writer_reset(*w);
    c.write_header(*w, .Queue, queue.codec.schema, true, 18446744073709551615, 0, 1);
    core.write_bits(*w, 4, 8);
    core.write_bits(*w, 0, 32);
    queue.revision = 18446744073709551615;
    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_delta(*queue.state, *r) && queue.revision == 18446744073709551615 && queue.items[0] == 1);
    expect(t, !c.enqueue(*queue.state, 2));
}

collections_array_resize_fill_clear_transactions :: (t: *Test) {
    a, b: c.Sequence(string);
    codec := v.builtin(string);
    expect(t, c.array_init(*a, codec, string.["one", "two"], 5));
    expect(t, c.array_init(*b, codec, string.["one", "two"], 5));
    defer c.destroy(*a);
    defer c.destroy(*b);
    expect(t, c.resize(*a, 2) && !c.changed(*a));
    expect(t, !c.resize(*a, -1) && !c.resize(*a, 6) && !c.resize(*a, c.MAX_ELEMENTS + 1));
    expect(t, c.resize(*a, 4) && a.items[0] == "one" && a.items[2] == "");
    expect(t, c.fill(*a, a.items[0]) && c.count(*a) == 4 && a.items[3] == "one");
    expect(t, c.resize(*a, 1) && c.clear(*a) && c.count(*a) == 1 && a.items[0] == "");
    expect(t, c.resize(*a, 3) && a.items[1] == "" && c.fill(*a, "final"));
    expect(t, a.revision == 6 && (a.changes).count == 6 && a.previous[0] == "one" && (a.previous).count == 2);
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    expect(t, c.write_delta(*a, *w));
    {
        cut := 0;
        while cut < (w.buffer).count {
            defer cut += 1;

            core.reader_init(*r, view(w.buffer, 0, cut));
            expect(t, !c.apply_delta(*b, *r) && b.revision == 0 && (b.changes).count == 0 && (b.items).count == 2 && b.items[0] == "one" && b.previous[1] == "two");
        }
    }

    core.reader_from_writer(*r, *w);
    expect(t, c.apply_delta(*b, *r) && b.revision == 6 && b.items[2] == "final" && b.previous[0] == "one");
    // Received fulls may resize an array and establish a fresh baseline.

    core.writer_reset(*w);
    expect(t, c.write_full(*a, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_full(*b, *r) && !c.changed(*b) && (b.items).count == 3 && b.previous[2] == "final");
    c.begin_tick(*a);
    expect(t, c.fill(*a, "final") && a.revision == 7); // Fill always logs.

    expect(t, c.resize(*a, 0) && c.clear(*a) && a.revision == 9);
    core.writer_reset(*w);
    expect(t, c.write_delta(*a, *w));
    core.reader_from_writer(*r, *w);
    expect(t, c.apply_delta(*b, *r) && (b.items).count == 0 && b.previous[0] == "final");
    c.begin_tick(*a);
    expect(t, c.clear(*a) && !c.changed(*a)); // Empty clean Clear is inert.

    expect(t, c.fill(*a, "unused") && a.revision == 10);
    // A legal resize followed by a forged oversize resize rolls back all owners.

    c.begin_tick(*b);
    core.writer_reset(*w);
    c.write_header(*w, .Array, codec.schema, true, b.revision, b.revision + 2, 2);
    for n: (int.[2, 6]) {
        core.write_bits(*w, (cast, trunc(u64)(c.Operation.Resize)), 8);
        core.write_bits(*w, (cast, trunc(u64)(n)), 32);
    }

    core.reader_from_writer(*r, *w);
    expect(t, !c.apply_delta(*b, *r) && (b.items).count == 0 && b.revision == 9 && (b.changes).count == 0);
    // Revision and operation budgets reject whole bulk operations, not prefixes.

    expect(t, c.resize(*b, 2));
    c.begin_tick(*b);
    b.revision = 18446744073709551615;
    expect(t, !c.fill(*b, "bad") && !c.clear(*b) && !c.resize(*b, 1) && (b.items).count == 2);
    b.revision = b.base_revision;
    array_resize(*b.changes, c.MAX_OPERATIONS);
    expect(t, !c.fill(*b, "bad") && !c.clear(*b) && !c.resize(*b, 1) && (b.items).count == 2);
    // Log padding has no owning values; restore a valid log before destruction.

    array_reset_keeping_memory(*b.changes);
}

collections_array_resize_hard_limit :: (t: *Test) {
    a: c.Sequence(bool);
    expect(t, c.array_init(*a, v.builtin(bool), .[]));
    defer c.destroy(*a);
    expect(t, c.resize(*a, c.MAX_ELEMENTS) && c.count(*a) == c.MAX_ELEMENTS);
    expect(t, !c.resize(*a, c.MAX_ELEMENTS + 1) && a.revision == 1);
    expect(t, c.clear(*a) && c.count(*a) == c.MAX_ELEMENTS && a.revision == 2);
    expect(t, c.resize(*a, 0) && c.count(*a) == 0);
}

//@endregion
// Cast semantics adapted.
// Loop scopes adapted.
// Iterator semantics adapted.
