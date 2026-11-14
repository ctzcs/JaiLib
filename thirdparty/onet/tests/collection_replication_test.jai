#scope_file
core :: #import "thirdparty/onet/core";
c :: #import "thirdparty/onet/collections";
o :: #import "thirdparty/onet/objects";
v :: #import "thirdparty/onet/values";
#scope_export

//@region Five owning collections registered through member_custom

COLLECTION_TYPE :: (cast(o.Component_Type_Id) (8201));

Collection_State :: struct {
    list: c.List(string);

    array: c.Array([] u8);

    queue: c.Queue(string);

    dictionary: c.Dictionary(string, [] u8);

    set: c.HashSet(string);
}

collection_factory :: () -> *o.Component {
    st := new_one(Collection_State);
    assert(c.list_init(*st.list.state, v.builtin(string), 8));
    assert(c.array_init(*st.array.state, v.builtin([] u8), [] u8.[.[], .[]], 8));
    assert(c.queue_init(*st.queue.state, v.builtin(string), 8));
    assert(c.dictionary_init(*st.dictionary, v.builtin(string), v.builtin([] u8), collections_less_string, 8));
    assert(c.hashset_init(*st.set, v.builtin(string), collections_less_string, 8));
    comp := o.component_make(COLLECTION_TYPE);
    comp.userdata = st;
    comp.destroy_userdata = (p: *void) {
        free(p);
    }

    o.member_custom(comp, *st.list.state, o.collection_sequence_codec(string, 82011));
    o.member_custom(comp, *st.array.state, o.collection_sequence_codec([] u8, 82012));
    o.member_custom(comp, *st.queue.state, o.collection_sequence_codec(string, 82013));
    o.member_custom(comp, *st.dictionary, o.collection_dictionary_codec(string, [] u8, 82014));
    o.member_custom(comp, *st.set, o.collection_hashset_codec(string, 82015));
    return comp;
}

collection_restore :: (t: *Test, st: *Collection_State) {
    expect(t, c.clear(*st.list.state) && c.add(*st.list.state, "alpha") && c.add(*st.list.state, "beta"));
    expect(t, c.resize(*st.array.state, 2) && c.set(*st.array.state, 0, u8.[1, 2]) && c.set(*st.array.state, 1, u8.[3]));
    expect(t, c.clear(*st.queue.state) && c.enqueue(*st.queue.state, "q1") && c.enqueue(*st.queue.state, "q2"));
    expect(t, c.dictionary_clear(*st.dictionary) && c.dictionary_add(*st.dictionary, "k1", u8.[10]) && c.dictionary_add(*st.dictionary, "k2", u8.[20]));
    expect(t, c.hashset_clear(*st.set) && c.hashset_add(*st.set, "red") && c.hashset_add(*st.set, "blue"));
}

collection_tick :: (st: *Collection_State) {
    c.begin_tick(*st.list.state);
    c.begin_tick(*st.array.state);
    c.begin_tick(*st.queue.state);
    c.dictionary_begin_tick(*st.dictionary);
    c.hashset_begin_tick(*st.set);
}

collection_expect_initial :: (t: *Test, st: *Collection_State) {
    expect(t, (st.list.items).count == 2 && st.list.items[0] == "alpha" && st.list.items[1] == "beta");
    expect(t, (st.array.items).count == 2 && (st.array.items[0]).count == 2 && st.array.items[0][0] == 1 && st.array.items[1][0] == 3);
    expect(t, (st.queue.items).count == 2 && st.queue.items[0] == "q1" && st.queue.items[1] == "q2");
    x, found := c.dictionary_get(*st.dictionary, "k1");
    expect(t, found && (x).count == 1 && x[0] == 10 && c.dictionary_count(*st.dictionary) == 2);
    expect(t, c.hashset_count(*st.set) == 2 && c.hashset_contains(*st.set, "red") && !c.hashset_contains(*st.set, "green"));
}

collection_expect_changed :: (t: *Test, st: *Collection_State) {
    expect(t, (st.list.items).count == 2 && st.list.items[0] == "changed" && st.list.items[1] == "tail");
    expect(t, (st.array.items).count == 3 && (st.array.items[0]).count == 0 && (st.array.items[1]).count == 2 && st.array.items[1][0] == 8);
    expect(t, (st.queue.items).count == 2 && st.queue.items[0] == "q2" && st.queue.items[1] == "q3");
    x, found := c.dictionary_get(*st.dictionary, "k1");
    expect(t, found && (x).count == 2 && x[0] == 11 && c.dictionary_count(*st.dictionary) == 2);
    expect(t, c.hashset_count(*st.set) == 2 && !c.hashset_contains(*st.set, "red") && c.hashset_contains(*st.set, "green"));
}

collection_peer_roundtrip_changes_loss_and_recovery_ownership :: (t: *Test) {
    // Detect leaks and double frees across probes, failed decodes, repeated full
    // replacement, history snapshots and final component/member destruction.

    backing := context.allocator;
    track: Tracking_Allocator;
    tracking_allocator_init(*track, backing);
    context.allocator = tracking_allocator(*track);
    defer {
        context.allocator = backing;
        expect(t, (track.allocation_map).count == 0, "collection loopback leaked an owner");
        expect(t, (track.bad_free_array).count == 0);
        tracking_allocator_destroy(*track);
    }

    server, client: o.Registry;
    outgoing, incoming: o.Peer;
    o.registry_init(*server);
    o.registry_init(*client, false);
    o.register_factory(*server, COLLECTION_TYPE, collection_factory);
    o.register_factory(*client, COLLECTION_TYPE, collection_factory);
    o.peer_init(*outgoing, 1);
    o.peer_init(*incoming, 1);
    defer o.registry_destroy(*server);
    defer o.registry_destroy(*client);
    defer o.peer_destroy(*outgoing);
    defer o.peer_destroy(*incoming);
    obj := o.spawn(*server, 1);
    comp := collection_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    collection_restore(t, st);
    first := peer_packet(t, *server, *outgoing, 1);
    defer release(first);
    {
        n := 0;
        while n < (first).count {
            defer n += 1;

            _, ok, _ := peer_receive(*client, *incoming, view(first, 0, n));
            expect(t, !ok && client.active_count == 0 && incoming.applied == 0);
        }
    }

    seq, ok, _ := peer_receive(*client, *incoming, first);
    expect(t, ok && o.peer_ack(*outgoing, seq));
    mirror, exists := o.get(*client, obj.id);
    expect(t, exists);
    dst := (cast(*Collection_State) mirror.components[0].userdata);
    collection_expect_initial(t, dst);
    expect(t, raw_data(st.list.items[0]) != raw_data(dst.list.items[0]));
    expect(t, raw_data(st.array.items[0]) != raw_data(dst.array.items[0]));
    expect(t, raw_data(dst.array.items[0]) != raw_data(dst.array.previous[0]));
    expect(t, raw_data(st.dictionary.items[0].key) != raw_data(dst.dictionary.items[0].key));
    expect(t, raw_data(st.dictionary.items[0].value) != raw_data(dst.dictionary.items[0].value));
    expect(t, raw_data(st.set.dictionary.items[0].key) != raw_data(dst.set.dictionary.items[0].key));
    collection_tick(st);
    expect(t, c.set(*st.list.state, 0, "changed") && c.remove_at(*st.list.state, 1) && c.add(*st.list.state, "tail"));
    expect(t, c.resize(*st.array.state, 3) && c.fill(*st.array.state, st.array.items[0]) && c.clear(*st.array.state) && c.set(*st.array.state, 1, u8.[8, 9]));
    popped, popped_ok := c.dequeue(*st.queue.state);
    expect(t, popped_ok && popped == "q1" && c.enqueue(*st.queue.state, "q3"));
    st.queue.codec.destroy(*popped);
    expect(t, c.dictionary_set(*st.dictionary, "k1", u8.[11, 12]) && c.dictionary_remove(*st.dictionary, "k2") && c.dictionary_add(*st.dictionary, "k3", u8.[30]));
    expect(t, c.hashset_remove(*st.set, "red") && c.hashset_add(*st.set, "green"));
    collection_expect_initial(t, dst); // Server mutations cannot alias the mirror.

    second := peer_packet(t, *server, *outgoing, 2);
    defer release(second);
    {
        n := 0;
        while n < (second).count {
            defer n += 1;

            _, good, _ := peer_receive(*client, *incoming, view(second, 0, n));
            expect(t, !good && incoming.applied == seq);
            collection_expect_initial(t, dst);
        }
    }

    seq2, ok2, _ := peer_receive(*client, *incoming, second);
    expect(t, ok2 && o.peer_ack(*outgoing, seq2));
    expect(t, dst == (cast(*Collection_State) mirror.components[0].userdata));
    collection_expect_changed(t, dst);
    // Object bridges retain the changed-tick baseline and the received ops.

    expect(t, (dst.list.previous).count == 2 && dst.list.previous[0] == "alpha" && dst.list.base_revision == st.list.base_revision && dst.array.revision == st.array.revision);
    collection_tick(st);
    expect(t, c.set(*st.list.state, 0, "lost update"));
    lost := peer_packet(t, *server, *outgoing, 3);
    defer release(lost);
    collection_restore(t, st);
    // Forget receiver history but retain its live world: byte delta must reject
    // without touching any of the five containers until a requested full arrives.

    o.peer_destroy(*incoming);
    o.peer_init(*incoming, 1);
    missing := peer_packet(t, *server, *outgoing, 4);
    defer release(missing);
    _, missing_ok, needs_full := peer_receive(*client, *incoming, missing);
    expect(t, !missing_ok && needs_full);
    collection_expect_changed(t, dst);
    o.peer_request_full(*outgoing);
    recovered := peer_packet(t, *server, *outgoing, 5);
    defer release(recovered);
    seq5, recovery_ok, _ := peer_receive(*client, *incoming, recovered);
    expect(t, recovery_ok && o.peer_ack(*outgoing, seq5));
    collection_expect_initial(t, dst);
    expect(t, dst.list.revision == st.list.revision && dst.dictionary.revision == st.dictionary.revision && dst.set.dictionary.revision == st.set.dictionary.revision);
    _, duplicate_ok, _ := peer_receive(*client, *incoming, recovered);
    _, old_ok, _ := peer_receive(*client, *incoming, lost);
    expect(t, duplicate_ok && old_ok);
    collection_expect_initial(t, dst);
    expect(t, o.despawn(*server, obj.id));
    despawn := peer_packet(t, *server, *outgoing, 6);
    defer release(despawn);
    _, despawn_ok, _ := peer_receive(*client, *incoming, despawn);
    expect(t, despawn_ok && client.active_count == 0);
}

collection_custom_member_write_schema_validator_and_trailing_rejection :: (t: *Test) {
    reg: o.Registry;
    o.registry_init(*reg);
    defer o.registry_destroy(*reg);
    o.register_factory(*reg, COLLECTION_TYPE, collection_factory);
    reg.is_observer = control_observer;
    obj := o.spawn(*reg, 2);
    comp := collection_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    collection_restore(t, st);
    source: c.Sequence(string);
    expect(t, c.list_init(*source, v.builtin(string), 8) && c.add(*source, "replacement"));
    defer c.destroy(*source);
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    expect(t, c.write_full(*source, *w));
    data := core.writer_to_array(*w);
    defer release(data);
    expect(t, !o.apply_member_write(*reg, obj.id, 2, 0, 0, data, control_reject));
    collection_expect_initial(t, st);
    comp.members[0].codec.schema += 1;
    expect(t, !o.apply_member_write(*reg, obj.id, 2, 0, 0, data, control_never_validate));
    comp.members[0].codec.schema -= 1;
    extra := new_slice(u8, (data).count + 1);
    defer release(extra);
    copy_samples(extra, data);
    // Test the raw bridge too: rejection must precede replacing live owners.

    bridge := c.sequence_bridge(string, 82011);
    r: core.Reader;
    core.reader_init(*r, extra);
    expect(t, !bridge.read(*r, *st.list.state) && st.list.items[0] == "alpha");
    {
        n := 0;
        while n < (data).count {
            defer n += 1;

            expect(t, !o.apply_member_write(*reg, obj.id, 2, 0, 0, view(data, 0, n)) && st.list.items[0] == "alpha");
        }
    }

    // A live limit stricter than the factory must fail transactionally too.

    st.list.limit = 0;
    expect(t, !o.apply_member_write(*reg, obj.id, 2, 0, 0, data) && st.list.items[0] == "alpha");
    st.list.limit = 8;
    expect(t, o.apply_member_write(*reg, obj.id, 2, 0, 0, data) && (st.list.items).count == 1 && st.list.items[0] == "replacement");
    expect(t, raw_data(st.list.items[0]) != raw_data(source.items[0]));
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
