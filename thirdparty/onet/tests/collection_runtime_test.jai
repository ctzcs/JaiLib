#scope_file
c :: #import "thirdparty/onet/collections";
o :: #import "thirdparty/onet/objects";
#scope_export

//@region Real peer snapshots: independent ACKs, loss, history and commit-only events

collection_mirror :: (t: *Test, reg: *o.Registry, id: o.Network_Id) -> *Collection_State {
    obj, exists := o.get(reg, id);
    expect(t, exists);
    return (cast(*Collection_State) obj.components[0].userdata);
}

collection_expect_step_events :: (t: *Test, st: *Collection_State, steps: int, first_tick: u64) {
    list := c.take_applied_changes(*st.list.state);
    array := c.take_applied_changes(*st.array.state);
    queue := c.take_applied_changes(*st.queue.state);
    dict := c.dictionary_take_applied_changes(*st.dictionary);
    set := c.hashset_take_applied_changes(*st.set);
    expect(t, (list).count == steps && (array).count == steps && (queue).count == steps * 2 && (dict).count == steps && (set).count == steps * 2);
    for e, i: list {
        expect(t, e.tick == first_tick + (cast, trunc(u64)(i)) && e.change.operation == .Set);
        if i > 0 {
            expect(t, e.revision == list[i - 1].revision + 1);
        }
    }

    for e, i: queue {
        expect(t, e.tick == first_tick + (cast, trunc(u64)(i / 2)));
        if i % 2 == 0 {
            expect(t, e.change.operation == .Remove && e.change.value != "");
        } else {
            expect(t, e.change.operation == .Insert);
        }
    }

    collection_no_applied(t, st);
}

collection_real_peers_multitick_loss_late_ack_late_join_exactly_once :: (t: *Test) {
    server, a, b, late: o.Registry;
    sa, sb, sl, ra, rb, rl: o.Peer;
    o.registry_init(*server);
    o.registry_init(*a, false);
    o.registry_init(*b, false);
    o.registry_init(*late, false);
    defer o.registry_destroy(*server);
    defer o.registry_destroy(*a);
    defer o.registry_destroy(*b);
    defer o.registry_destroy(*late);
    o.register_factory(*a, COLLECTION_TYPE, collection_history_factory);
    o.register_factory(*b, COLLECTION_TYPE, collection_history_factory);
    o.register_factory(*late, COLLECTION_TYPE, collection_history_factory);
    o.peer_init(*sa, 1);
    o.peer_init(*sb, 2);
    o.peer_init(*sl, 3);
    o.peer_init(*ra, 1);
    o.peer_init(*rb, 2);
    o.peer_init(*rl, 3);
    defer o.peer_destroy(*sa);
    defer o.peer_destroy(*sb);
    defer o.peer_destroy(*sl);
    defer o.peer_destroy(*ra);
    defer o.peer_destroy(*rb);
    defer o.peer_destroy(*rl);
    obj := o.spawn(*server, 0);
    comp := collection_history_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    o.begin_tick(*server, 1);
    o.begin_tick(*a, 1);
    o.begin_tick(*b, 1);
    collection_restore(t, st);
    p1a := peer_packet(t, *server, *sa, 1);
    defer release(p1a);
    p1b := peer_packet(t, *server, *sb, 1);
    defer release(p1b);
    seq1a, ok1a, _ := peer_receive(*a, *ra, p1a);
    seq1b, ok1b, _ := peer_receive(*b, *rb, p1b);
    expect(t, ok1a && ok1b && o.peer_ack(*sa, seq1a) && o.peer_ack(*sb, seq1b));
    da := collection_mirror(t, *a, obj.id);
    db := collection_mirror(t, *b, obj.id);
    collection_no_applied(t, da);
    collection_no_applied(t, db);
    collection_no_changes(t, da);
    collection_no_changes(t, db);
    o.begin_tick(*server, 2);
    o.begin_tick(*a, 2);
    o.begin_tick(*b, 2);
    collection_step(t, st, "two", 2);
    lost_a := peer_packet(t, *server, *sa, 2);
    defer release(lost_a);
    p2b := peer_packet(t, *server, *sb, 2);
    defer release(p2b);
    seq2b, ok2b, _ := peer_receive(*b, *rb, p2b);
    expect(t, ok2b); // ACK intentionally delayed until after tick four.

    collection_expect_step_events(t, db, 1, 2);
    o.begin_tick(*server, 3);
    o.begin_tick(*a, 3);
    o.begin_tick(*b, 3);
    collection_step(t, st, "three", 3);
    p3a := peer_packet(t, *server, *sa, 3);
    defer release(p3a);
    lost_b := peer_packet(t, *server, *sb, 3);
    defer release(lost_b);
    // All byte truncations reject without publishing even an early member's
    // operation. Snapshot prevalidation must not touch committed pull cursors.

    {
        cut := 0;
        while cut < (p3a).count {
            defer cut += 1;

            _, good, _ := peer_receive(*a, *ra, view(p3a, 0, cut));
            expect(t, !good && da.list.items[0] == "alpha");
            collection_no_applied(t, da);
        }
    }

    seq3a, ok3a, _ := peer_receive(*a, *ra, p3a);
    expect(t, ok3a && seq3a == 3);
    collection_expect_step_events(t, da, 2, 2);
    expect(t, da.list.items[0] == "three" && da.list.previous[0] == "two");
    expect(t, da.array.previous[0][0] == 2 && da.dictionary.previous[0].value[0] == 2);
    expect(t, c.hashset_contains(*da.set, "two", true));
    at_one, retained := c.values_at(*da.list.state, 1);
    expect(t, retained && at_one[0] == "alpha");
    expect(t, (c.changes_view(*da.list.state)).count == 1 && c.changes_view(*da.list.state)[0].value == "three");
    expect(t, (c.changes_view(*da.queue.state)).count == 2 && c.changes_view(*da.queue.state)[0].value == "q2");
    // Duplicate/reordered packet and a late ACK cannot replay operations.

    _, duplicate, _ := peer_receive(*a, *ra, p3a);
    _, reordered, _ := peer_receive(*a, *ra, lost_a);
    expect(t, duplicate && reordered && o.peer_ack(*sa, seq1a));
    collection_no_applied(t, da);
    // A valid member followed by trailing object data causes a failed probe
    // after all five decoders ran, and still exposes no application event.

    image, encoded := o.image_encode(obj);
    expect(t, encoded);
    invalid := new_slice(u8, (image).count + 1);
    copy_samples(invalid, image);
    bad := o.Snapshot.{
    };

    array_add(*bad.images, o.Object_Image.{
        id = obj.id, data = invalid
    });
    expect(t, !o.snapshot_apply(*a, *bad) && da.list.items[0] == "three");
    o.snapshot_destroy(*bad);
    release(image);
    collection_no_applied(t, da);
    // A quiet tick does not erase the journal; B still needs the unseen tick 3
    // even though its acknowledged byte baseline is tick 1, not its live tick 2.

    o.begin_tick(*server, 4);
    o.begin_tick(*a, 4);
    o.begin_tick(*b, 4);
    o.begin_tick(*late, 4);
    p4a := peer_packet(t, *server, *sa, 4);
    defer release(p4a);
    p4b := peer_packet(t, *server, *sb, 4);
    defer release(p4b);
    p4l := peer_packet(t, *server, *sl, 4);
    defer release(p4l);
    _, ok4a, _ := peer_receive(*a, *ra, p4a);
    seq4b, ok4b, _ := peer_receive(*b, *rb, p4b);
    _, ok4l, _ := peer_receive(*late, *rl, p4l);
    expect(t, ok4a && ok4b && ok4l && seq4b == 4);
    collection_no_changes(t, da);
    collection_no_applied(t, da);
    collection_expect_step_events(t, db, 1, 3);
    dl := collection_mirror(t, *late, obj.id);
    collection_no_changes(t, dl);
    collection_no_applied(t, dl);
    expect(t, dl.list.items[0] == "three" && dl.list.previous[0] == "three");
    expect(t, o.peer_ack(*sb, seq2b) && o.peer_ack(*sa, seq3a));
    o.begin_tick(*server, 5);
    o.begin_tick(*a, 5);
    o.begin_tick(*b, 5);
    collection_step(t, st, "five", 5);
    p5a := peer_packet(t, *server, *sa, 5);
    defer release(p5a);
    p5b := peer_packet(t, *server, *sb, 5);
    defer release(p5b);
    _, ok5a, _ := peer_receive(*a, *ra, p5a);
    _, ok5b, _ := peer_receive(*b, *rb, p5b);
    expect(t, ok5a && ok5b);
    collection_expect_step_events(t, da, 1, 5);
    collection_expect_step_events(t, db, 1, 5);
    expect(t, da.list.previous[0] == "three" && db.list.previous[0] == "three");
    // Receiving during replay is legal, but never unblocks local mutation.

    o.set_replaying(*a, true);
    o.begin_tick(*server, 6);
    o.begin_tick(*a, 6);
    collection_step(t, st, "six", 6);
    o.peer_request_full(*sa);
    full := peer_packet(t, *server, *sa, 6);
    defer release(full);
    _, full_ok, _ := peer_receive(*a, *ra, full);
    expect(t, full_ok && da.list.items[0] == "six" && !c.set(*da.list.state, 0, "replayed"));
    collection_expect_step_events(t, da, 1, 6);
    o.set_replaying(*a, false);
};

collection_journal_gap_and_missing_ack_baseline_full_fallback :: (t: *Test) {
    // Nested tracking includes the five owners, previous/history, raw deltas,
    // coalesced Changes, wire journals, probe objects and applied pull logs.

    backing := context.allocator;
    track: Tracking_Allocator;
    tracking_allocator_init(*track, backing);
    context.allocator = tracking_allocator(*track);
    defer {
        context.allocator = backing;
        expect(t, (track.allocation_map).count == 0 && (track.bad_free_array).count == 0);
        tracking_allocator_destroy(*track);
    }

    server, client: o.Registry;
    send, receive: o.Peer;
    o.registry_init(*server);
    o.registry_init(*client, false);
    o.register_factory(*client, COLLECTION_TYPE, collection_gap_factory);
    o.peer_init(*send, 1, 2);
    o.peer_init(*receive, 1, 2);
    defer o.registry_destroy(*server);
    defer o.registry_destroy(*client);
    defer o.peer_destroy(*send);
    defer o.peer_destroy(*receive);
    obj := o.spawn(*server, 0);
    comp := collection_gap_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    o.begin_tick(*server, 1);
    o.begin_tick(*client, 1);
    collection_restore(t, st);
    initial := peer_packet(t, *server, *send, 1);
    defer release(initial);
    seq, ok, _ := peer_receive(*client, *receive, initial);
    expect(t, ok && o.peer_ack(*send, seq));
    dst := collection_mirror(t, *client, obj.id);
    texts: [] string = string.["two", "three", "four", "five", "six", "seven"];
    {
        tick := 2;
        while tick < 8 {
            defer tick += 1;

            o.begin_tick(*server, (cast, trunc(u64)(tick)));
            text := texts[tick - 2];
            collection_step(t, st, text, (cast, trunc(u8)(tick)));
            dropped := peer_packet(t, *server, *send, (cast, trunc(u64)(tick)));
            release(dropped);
        }
    }

    // The ACK byte baseline was evicted too. Build must automatically choose
    // full without mutating either peer's live operation lifecycle.

    expect(t, !o.peer_ack(*send, 2));
    o.begin_tick(*client, 8);
    recovery := peer_packet(t, *server, *send, 8);
    defer release(recovery);
    recovery_seq, recovered, need := peer_receive(*client, *receive, recovery);
    expect(t, recovered && !need && o.peer_ack(*send, recovery_seq));
    expect(t, dst.list.items[0] == "seven" && dst.list.previous[0] == "six");
    expect(t, dst.list.timeline.recovered && dst.array.timeline.recovered && dst.queue.timeline.recovered && dst.dictionary.timeline.recovered && dst.set.dictionary.timeline.recovered);
    collection_no_changes(t, dst);
    collection_no_applied(t, dst);
    expect(t, (st.list.history).count == 3 && (st.list.journal).count == 2 && (st.queue.journal).count == 2 && (st.dictionary.journal).count == 2 && (st.set.dictionary.journal).count == 2);
    expect(t, raw_data(st.list.items[0]) != raw_data(dst.list.items[0]));
    expect(t, raw_data(dst.list.items[0]) != raw_data(dst.list.history[(dst.list.history).count - 1].items[0]));
    // Forget receiver baselines only: an ACK delta must request recovery while
    // leaving contents, previous and Changes intact. Then explicit full repairs.

    o.peer_destroy(*receive);
    o.peer_init(*receive, 1, 2);
    o.begin_tick(*server, 9);
    o.begin_tick(*client, 9);
    collection_step(t, st, "nine", 9);
    missing := peer_packet(t, *server, *send, 9);
    defer release(missing);
    _, applied_missing, needs_full := peer_receive(*client, *receive, missing);
    expect(t, !applied_missing && needs_full && dst.list.items[0] == "seven");
    collection_no_applied(t, dst);
    o.peer_request_full(*send);
    full := peer_packet(t, *server, *send, 9);
    defer release(full);
    _, full_ok, _ := peer_receive(*client, *receive, full);
    expect(t, full_ok && dst.list.items[0] == "nine" && !dst.list.timeline.recovered);
    collection_expect_step_events(t, dst, 1, 9);
    // Repeated equal full snapshots preserve the cursor and previous head.

    o.peer_request_full(*send);
    again := peer_packet(t, *server, *send, 9);
    defer release(again);
    _, again_ok, _ := peer_receive(*client, *receive, again);
    expect(t, again_ok && dst.list.previous[0] == "seven");
    collection_no_applied(t, dst);
    // Clear/default owners and same-tick wire+local write rotate off the applied
    // head instead of treating the receiver's pre-apply previous as its base.

    expect(t, c.set(*dst.list.state, 0, "seven") && dst.list.previous[0] == "nine");
    expect(t, c.clear(*dst.array.state) && (dst.array.items).count == 2);
    expect(t, c.dictionary_clear(*dst.dictionary) && c.hashset_clear(*dst.set) && c.clear(*dst.queue.state));
}

//@endregion
//@region Same-tick multiple commits and relaying the compatible raw delta

collection_multiple_same_tick_snapshots_coalesce_without_republishing :: (t: *Test) {
    server, client: o.Registry;
    send, receive: o.Peer;
    o.registry_init(*server);
    o.registry_init(*client, false);
    defer o.registry_destroy(*server);
    defer o.registry_destroy(*client);
    o.register_factory(*client, COLLECTION_TYPE, collection_history_factory);
    o.peer_init(*send, 1);
    o.peer_init(*receive, 1);
    defer o.peer_destroy(*send);
    defer o.peer_destroy(*receive);
    obj := o.spawn(*server, 0);
    comp := collection_history_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    o.begin_tick(*server, 1);
    o.begin_tick(*client, 1);
    collection_restore(t, st);
    initial := peer_packet(t, *server, *send, 1);
    defer release(initial);
    seq, ok, _ := peer_receive(*client, *receive, initial);
    expect(t, ok && o.peer_ack(*send, seq));
    dst := collection_mirror(t, *client, obj.id);
    o.begin_tick(*server, 2);
    o.begin_tick(*client, 2);
    collection_step(t, st, "first", 2);
    first := peer_packet(t, *server, *send, 2);
    defer release(first);
    _, first_ok, _ := peer_receive(*client, *receive, first);
    expect(t, first_ok);
    collection_expect_step_events(t, dst, 1, 2);
    collection_step(t, st, "second", 3);
    second := peer_packet(t, *server, *send, 2);
    defer release(second);
    _, second_ok, _ := peer_receive(*client, *receive, second);
    expect(t, second_ok);
    collection_expect_step_events(t, dst, 1, 2);
    expect(t, (c.changes_view(*dst.list.state)).count == 1 && c.changes_view(*dst.list.state)[0].value == "second" && (dst.list.changes).count == 2);
    expect(t, dst.list.previous[0] == "alpha" && dst.array.previous[0][0] == 1);
    expect(t, (dst.queue.changes).count == 4 && (dst.dictionary.changes).count == 2 && (dst.set.dictionary.changes).count == 4);
    // A byte-identical full at another sequence must not erase the raw relay
    // window, duplicate its pull events, or rotate previous a second time.

    o.peer_request_full(*send);
    same := peer_packet(t, *server, *send, 2);
    defer release(same);
    _, same_ok, _ := peer_receive(*client, *receive, same);
    expect(t, same_ok && (dst.list.changes).count == 2 && dst.list.previous[0] == "alpha");
    collection_no_applied(t, dst);
}

//@endregion
//@region Ahead-of-clock receive followed by local writes

collection_received_head_ahead_of_local_clock_keeps_journal_monotonic :: (t: *Test) {
    server, client, relay: o.Registry;
    send, receive: o.Peer;
    o.registry_init(*server);
    o.registry_init(*client, false);
    o.registry_init(*relay, false);
    defer o.registry_destroy(*server);
    defer o.registry_destroy(*client);
    defer o.registry_destroy(*relay);
    o.register_factory(*client, COLLECTION_TYPE, collection_history_factory);
    o.register_factory(*relay, COLLECTION_TYPE, collection_history_factory);
    o.peer_init(*send, 1);
    o.peer_init(*receive, 1);
    defer o.peer_destroy(*send);
    defer o.peer_destroy(*receive);
    obj := o.spawn(*server, 0);
    comp := collection_history_factory();
    array_add(*obj.components, comp);
    st := (cast(*Collection_State) comp.userdata);
    o.begin_tick(*server, 100);
    o.begin_tick(*client, 2);
    o.begin_tick(*relay, 2);
    collection_restore(t, st);
    packet := peer_packet(t, *server, *send, 100);
    defer release(packet);
    _, ok, _ := peer_receive(*client, *receive, packet);
    expect(t, ok);
    dst := collection_mirror(t, *client, obj.id);
    collection_step(t, dst, "local", 3);
    mirror, _ := o.get(*client, obj.id);
    image, encoded := o.image_encode(mirror);
    expect(t, encoded);
    snapshot := o.Snapshot.{
    };

    array_add(*snapshot.images, o.Object_Image.{
        id = obj.id, data = image
    });
    defer o.snapshot_destroy(*snapshot);
    expect(t, o.snapshot_apply(*relay, *snapshot));
    next := collection_mirror(t, *relay, obj.id);
    expect(t, next.list.items[0] == "local" && next.array.items[0][0] == 3 && next.list.timeline.head_tick == 100);
    collection_no_applied(t, next);
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
