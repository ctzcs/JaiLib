#scope_file
core :: #import "thirdparty/onet/core";
c :: #import "thirdparty/onet/collections";
o :: #import "thirdparty/onet/objects";
v :: #import "thirdparty/onet/values";
#scope_export

//@region Sparse history and Changes semantics

collection_history_factory :: () -> *o.Component {
    comp := collection_factory();
    st := (cast(*Collection_State) comp.userdata);
    assert(c.configure_history(*st.list.state, 4, 64));
    assert(c.configure_history(*st.array.state, 4, 64));
    assert(c.configure_history(*st.queue.state, 4, 64));
    assert(c.dictionary_configure_history(*st.dictionary, 4, 64));
    assert(c.hashset_configure_history(*st.set, 4, 64));
    return comp;
}

collection_gap_factory :: () -> *o.Component {
    comp := collection_factory();
    st := (cast(*Collection_State) comp.userdata);
    assert(c.configure_history(*st.list.state, 4, 2));
    assert(c.configure_history(*st.array.state, 4, 2));
    assert(c.configure_history(*st.queue.state, 4, 2));
    assert(c.dictionary_configure_history(*st.dictionary, 4, 2));
    assert(c.hashset_configure_history(*st.set, 4, 2));
    return comp;
}

collection_step :: (t: *Test, st: *Collection_State, text: string, byte: u8) {
    expect(t, c.set(*st.list.state, 0, text));
    expect(t, c.set(*st.array.state, 0, u8.[byte]));
    out, ok := c.dequeue(*st.queue.state);
    expect(t, ok);
    st.queue.codec.destroy(*out);
    expect(t, c.enqueue(*st.queue.state, text));
    expect(t, c.dictionary_set(*st.dictionary, "k1", u8.[byte]));
    expect(t, c.hashset_clear(*st.set) && c.hashset_add(*st.set, text));
}

collection_no_applied :: (t: *Test, st: *Collection_State) {
    expect(t, (c.take_applied_changes(*st.list.state)).count == 0);
    expect(t, (c.take_applied_changes(*st.array.state)).count == 0);
    expect(t, (c.take_applied_changes(*st.queue.state)).count == 0);
    expect(t, (c.dictionary_take_applied_changes(*st.dictionary)).count == 0);
    expect(t, (c.hashset_take_applied_changes(*st.set)).count == 0);
}

collection_no_changes :: (t: *Test, st: *Collection_State) {
    expect(t, (c.changes_view(*st.list.state)).count == 0);
    expect(t, (c.changes_view(*st.array.state)).count == 0);
    expect(t, (c.changes_view(*st.queue.state)).count == 0);
    expect(t, (c.dictionary_changes_view(*st.dictionary)).count == 0);
    expect(t, (c.hashset_changes_view(*st.set)).count == 0);
}

collection_sparse_previous_ring_coast_and_coalescing :: (t: *Test) {
    reg: o.Registry;
    o.registry_init(*reg);
    defer o.registry_destroy(*reg);
    obj := o.spawn(*reg, 0);
    comp := collection_history_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    o.begin_tick(*reg, 1);
    collection_restore(t, st);
    o.begin_tick(*reg, 2);
    collection_step(t, st, "two", 2);
    o.begin_tick(*reg, 3);
    collection_step(t, st, "three", 3);
    expect(t, st.list.previous[0] == "two" && st.array.previous[0][0] == 2);
    expect(t, st.queue.previous[0] == "q2" && st.dictionary.previous[0].value[0] == 2);
    expect(t, c.hashset_contains(*st.set, "two", true));
    expect(t, raw_data(st.list.items[0]) != raw_data(st.list.previous[0]));
    n := (st.list.history).count;
    // Quiet ticks end Changes, but do not consume a distinct-value ring slot.

    {
        tick := 4;
        while tick < 100 {
            defer tick += 1;
            o.begin_tick(*reg, (cast, trunc(u64)(tick)));
        }
    }

    collection_no_changes(t, st);
    expect(t, (st.list.history).count == n && st.list.previous[0] == "two");
    old, found := c.values_at(*st.list.state, 1);
    expect(t, found && old[0] == "alpha");
    old_map, found_map := c.dictionary_values_at(*st.dictionary, 2);
    expect(t, found_map && old_map[0].value[0] == 2);
    old_set, found_set := c.hashset_values_at(*st.set, 2);
    expect(t, found_set && old_set[0].key == "two");
    o.begin_tick(*reg, 100);
    expect(t, c.set(*st.list.state, 0, "a") && c.set(*st.list.state, 0, "b"));
    expect(t, (c.changes_view(*st.list.state)).count == 1 && c.changes_view(*st.list.state)[0].value == "b");
    expect(t, c.fill(*st.array.state, u8.[8]) && c.fill(*st.array.state, u8.[9]));
    expect(t, c.resize(*st.array.state, 4) && c.resize(*st.array.state, 3));
    expect(t, c.clear(*st.array.state) && c.clear(*st.array.state));
    ev := c.changes_view(*st.array.state);
    expect(t, (ev).count == 3 && ev[0].operation == .Fill && ev[0].value[0] == 9 && ev[1].operation == .Resize && ev[1].index == 3 && ev[2].operation == .Clear);
    expect(t, (st.array.items).count == 3 && (st.array.items[0]).count == 0);
    expect(t, c.dictionary_set(*st.dictionary, "k1", u8.[4]) && c.dictionary_set(*st.dictionary, "k1", u8.[5]));
    expect(t, (c.dictionary_changes_view(*st.dictionary)).count == 1 && c.dictionary_changes_view(*st.dictionary)[0].value[0] == 5);
    expect(t, c.clear(*st.list.state) && (c.changes_view(*st.list.state)).count == 1 && c.changes_view(*st.list.state)[0].operation == .Clear);
    expect(t, c.dictionary_clear(*st.dictionary) && (c.dictionary_changes_view(*st.dictionary)).count == 1);
    // Idempotent scheduling cannot consume operations or rotate previous twice.

    o.begin_tick(*reg, 100);
    expect(t, (c.changes_view(*st.list.state)).count == 1 && st.list.previous[0] == "three");
    o.begin_tick(*reg, 101);
    expect(t, c.add(*st.list.state, "new"));
    expect(t, (st.list.history).count == 3);
    _, retained := c.values_at(*st.list.state, 0);
    expect(t, !retained);
}

collection_every_mutator_refuses_replay_including_noops :: (t: *Test) {
    reg: o.Registry;
    o.registry_init(*reg);
    defer o.registry_destroy(*reg);
    obj := o.spawn(*reg, 0);
    comp := collection_history_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    o.begin_tick(*reg, 7);
    collection_restore(t, st);
    revs := u64.[st.list.revision, st.array.revision, st.queue.revision, st.dictionary.revision, st.set.dictionary.revision];
    o.set_replaying(*reg, true);
    expect(t, !c.set(*st.list.state, 0, "alpha") && !c.insert(*st.list.state, 0, "x") && !c.add(*st.list.state, "x") && !c.remove_at(*st.list.state, 0) && !c.clear(*st.list.state));
    expect(t, !c.set(*st.array.state, 0, st.array.items[0]) && !c.resize(*st.array.state, (st.array.items).count) && !c.fill(*st.array.state, .[]) && !c.clear(*st.array.state));
    o.begin_tick(*reg, 2); // Historical replay ticks cannot drain the live tick.

    expect(t, reg.collection_tick == 7 && st.list.timeline.tick == 7 && (c.changes_view(*st.list.state)).count == 2);
    expect(t, !c.enqueue(*st.queue.state, "x") && !c.remove_at(*st.queue.state, 0) && !c.clear(*st.queue.state));
    _, dequeued := c.dequeue(*st.queue.state);
    expect(t, !dequeued);
    expect(t, !c.dictionary_add(*st.dictionary, "x", .[]) && !c.dictionary_set(*st.dictionary, "k1", st.dictionary.items[0].value) && !c.dictionary_remove(*st.dictionary, "k1") && !c.dictionary_clear(*st.dictionary));
    expect(t, !c.hashset_add(*st.set, "x") && !c.hashset_remove(*st.set, "red") && !c.hashset_clear(*st.set));
    expect_value(t, revs, u64.[st.list.revision, st.array.revision, st.queue.revision, st.dictionary.revision, st.set.dictionary.revision]);
    collection_expect_initial(t, st);
    o.set_replaying(*reg, false);
    o.begin_tick(*reg, 8);
    collection_step(t, st, "accepted", 8);
    expect(t, st.list.items[0] == "accepted");
    // Standalone history configuration is validated, never silently wrapped.

    fresh: c.Sequence(s32);
    expect(t, c.list_init(*fresh, v.builtin(s32)));
    defer c.destroy(*fresh);
    expect(t, !c.configure_history(*fresh, 1, 1) && !c.configure_history(*fresh, 257, 1) && !c.configure_history(*fresh, 2, 0));
}

//@endregion
//@region Wire applies during replay and borrowed-history ownership

collection_wire_sequence :: (t: *Test, src, dst: *c.Sequence($T), delta: bool) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    if delta {
        expect(t, c.write_delta(src, *w));
    } else {
        expect(t, c.write_full(src, *w));
    }

    core.reader_from_writer(*r, *w);
    if delta {
        expect(t, c.apply_delta(dst, *r));
    } else {
        expect(t, c.apply_full(dst, *r));
    }

    expect(t, dst.timeline.replaying);
}

collection_wire_map :: (t: *Test, src, dst: *c.Dictionary($K, $V), delta: bool) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    r: core.Reader;
    if delta {
        expect(t, c.dictionary_write_delta(src, *w));
    } else {
        expect(t, c.dictionary_write_full(src, *w));
    }

    core.reader_from_writer(*r, *w);
    if delta {
        expect(t, c.dictionary_apply_delta(dst, *r));
    } else {
        expect(t, c.dictionary_apply_full(dst, *r));
    }

    expect(t, dst.timeline.replaying);
}

collection_standalone_wire_is_not_a_replayed_local_write :: (t: *Test) {
    source, target: o.Registry;
    o.registry_init(*source);
    o.registry_init(*target);
    defer o.registry_destroy(*source);
    defer o.registry_destroy(*target);
    a := o.spawn(*source, 0);
    b := o.spawn(*target, 0);
    ca, cb := collection_factory(), collection_factory();
    array_add(*a.components, ca);
    array_add(*b.components, cb);
    src, dst := (cast(*Collection_State) ca.userdata), (cast(*Collection_State) cb.userdata);
    o.begin_tick(*source, 1);
    collection_restore(t, src);
    o.set_replaying(*target, true);
    collection_wire_sequence(t, *src.list.state, *dst.list.state, false);
    collection_wire_sequence(t, *src.array.state, *dst.array.state, false);
    collection_wire_sequence(t, *src.queue.state, *dst.queue.state, false);
    collection_wire_map(t, *src.dictionary, *dst.dictionary, false);
    collection_wire_map(t, *src.set.dictionary, *dst.set.dictionary, false);
    o.begin_tick(*source, 2);
    collection_step(t, src, "wire", 2);
    collection_wire_sequence(t, *src.list.state, *dst.list.state, true);
    collection_wire_sequence(t, *src.array.state, *dst.array.state, true);
    collection_wire_sequence(t, *src.queue.state, *dst.queue.state, true);
    collection_wire_map(t, *src.dictionary, *dst.dictionary, true);
    collection_wire_map(t, *src.set.dictionary, *dst.set.dictionary, true);
    expect(t, dst.list.items[0] == "wire" && !c.clear(*dst.list.state) && !c.clear(*dst.array.state) && !c.clear(*dst.queue.state) && !c.dictionary_clear(*dst.dictionary) && !c.hashset_clear(*dst.set));
}

collection_borrowed_evicted_history_payloads_are_cloned_before_rotation :: (t: *Test) {
    reg: o.Registry;
    o.registry_init(*reg);
    defer o.registry_destroy(*reg);
    obj := o.spawn(*reg, 0);
    comp := collection_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    o.begin_tick(*reg, 1);
    collection_restore(t, st);
    o.begin_tick(*reg, 2);
    collection_step(t, st, "two", 2);
    o.begin_tick(*reg, 3);
    expect(t, c.set(*st.list.state, 0, st.list.history[0].items[0]) && st.list.items[0] == "alpha");
    expect(t, c.fill(*st.array.state, st.array.previous[0]) && st.array.items[0][0] == 1 && (st.array.items[0]).count == 2);
    expect(t, c.enqueue(*st.queue.state, st.queue.history[0].items[0]) && st.queue.items[2] == "q1");
    expect(t, c.dictionary_set(*st.dictionary, "k1", st.dictionary.previous[0].value) && st.dictionary.items[0].value[0] == 10);
    expect(t, c.hashset_add(*st.set, st.set.dictionary.history[0].items[0].key) && c.hashset_contains(*st.set, "blue"));
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
