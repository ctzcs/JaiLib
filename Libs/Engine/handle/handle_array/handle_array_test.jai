#import "Basic";
#import "test_support";

HA :: #import "handle/handle_array/handle_array";

// operator == must be visible in this scope for bare == on handles
// (Jai resolves operators lexically; the module's own operator == is namespaced).
operator == :: (a: HA.Handle, b: HA.Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// Port of handle_array_test.odin: iterator_skips_free_slots_and_returns_live_values
test_handle_array :: (state: *Test_State) {
    Test_Handle :: HA.Handle;

    values: HA.Pool(int, Test_Handle);
    defer HA.delete(*values);

    first   := HA.add(*values, 1);
    removed := HA.add(*values, 2);
    third   := HA.add(*values, 3);
    HA.remove_handle(*values, removed);

    expect(state, HA.len(values) == 2, "len == 2 after remove");
    expect(state, HA.cap(values) >= HA.len(values), "cap >= len");
    expect(state, HA.valid(values, first), "first is valid");
    expect(state, !HA.valid(values, removed), "removed is not valid");

    count := 0;
    sum := 0;
    saw_first := false;
    saw_third := false;

    it := HA.begin(*values);
    while true {
        value, handle, ok := HA.next(*it);
        if !ok break;
        count += 1;
        sum += <<value;
        saw_first = saw_first || (handle == first);
        saw_third = saw_third || (handle == third);
        <<value = <<value + 10;
    }

    expect(state, count == 2, "iteration count == 2");
    expect(state, sum == 4, "iteration sum == 4");
    expect(state, saw_first, "saw first");
    expect(state, saw_third, "saw third");
    expect(state, HA.get(values, removed) == null, "get removed is null");
    expect(state, <<HA.get(values, first) == 11, "first value updated to 11");
    expect(state, <<HA.get(values, third) == 13, "third value updated to 13");

    reused := HA.add(*values, 4);
    expect(state, reused.idx == removed.idx, "reused slot index matches removed");
    expect(state, reused.gen != removed.gen, "reused gen differs from removed");

    copied, ok := HA.get_value(values, reused);
    expect(state, ok, "get_value ok");
    expect(state, copied == 4, "get_value returns 4");

    HA.reset(*values);
    expect(state, HA.len(values) == 0, "len == 0 after reset");
    expect(state, !HA.valid(values, first), "first invalid after reset");
}

// Port of handle_array_test.odin: clear_preserves_generations_and_reuses_all_slots
test_handle_array_clear_preserves_generations :: (state: *Test_State) {
    Test_Handle :: HA.Handle;

    values: HA.Pool(int, Test_Handle);
    defer HA.delete(*values);

    HA.clear(*values);
    expect(state, HA.cap(values) == 0, "cap == 0 on empty pool after clear");

    old: [3]Test_Handle;
    old[0] = HA.add(*values, 1);
    old[1] = HA.add(*values, 2);
    old[2] = HA.add(*values, 3);
    HA.remove_handle(*values, old[1]);
    // Include a slot whose generation has already advanced.
    old[1] = HA.add(*values, 4);
    HA.remove_handle(*values, old[1]);
    capacity   := HA.cap(values);
    slot_count := values.slots.count;

    for 0..2 {
        HA.clear(*values);
        HA.clear(*values);
        expect(state, HA.len(values) == 0, "len == 0 after clear");
        expect(state, values.freelist.count == 3, "freelist holds all 3 slots");

        it := HA.begin(*values);
        _, _, ok := HA.next(*it);
        expect(state, !ok, "iteration yields nothing after clear");

        fresh: [3]Test_Handle;
        for i: 0..2 {
            fresh[i] = HA.add(*values, i);
            expect(state, HA.valid(values, fresh[i]), "fresh handle is valid");
            for old {
                expect(state, !HA.valid(values, it), "old handle stays invalid");
            }
            j := 0;
            while j < i {
                expect(state, fresh[i].idx != fresh[j].idx, "fresh indices are distinct");
                j += 1;
            }
        }
        expect(state, HA.len(values) == 3, "len == 3 after re-adds");
        expect(state, HA.cap(values) == capacity, "capacity preserved across clear");
        expect(state, values.slots.count == slot_count, "slot count preserved across clear");
        old = fresh;
    }
}

// Port of handle_array_test.odin: clear_destroys_only_live_values_once
test_handle_array_clear_destroys_once :: (state: *Test_State) {
    Test_Handle :: HA.Handle;
    Value :: struct { destroyed: *int; };

    destroy :: (v: *Value) {
        p := v.destroyed;
        <<p += 1;
        <<v = Value.{}; // zero the slot so a second destroy pass sees no pointer
    }

    values: HA.Pool(Value, Test_Handle);
    defer HA.delete(*values);

    counts: [3]int;
    first   := HA.add(*values, Value.{ destroyed = *counts[0] });
    removed := HA.add(*values, Value.{ destroyed = *counts[1] });
    third   := HA.add(*values, Value.{ destroyed = *counts[2] });

    HA.remove_handle(*values, removed, destroy);
    HA.clear(*values, destroy);
    HA.clear(*values, destroy);
    expect(state, counts[0] == 1 && counts[1] == 1 && counts[2] == 1, "each value destroyed exactly once");
    expect(state, !HA.valid(values, first), "first invalid after clear");
    expect(state, !HA.valid(values, third), "third invalid after clear");
    expect(state, HA.len(values) == 0, "len == 0 after clear");

    // Reset still discards slot history and supports the same callback form.
    HA.add(*values, Value.{ destroyed = *counts[0] });
    HA.reset(*values, destroy);
    expect(state, counts[0] == 2 && counts[1] == 1 && counts[2] == 1, "reset destroys the re-added value");
    expect(state, values.slots.count == 0, "slots emptied by reset");
}

// Jai-native replacement for olib's allocation_failure_leaves_pool_usable: that
// test leans on Odin's #optional_allocator_error with a failing allocator,
// which Jai's array_add has no equivalent of. The contract it protects is that
// remove_handle/clear never allocate, asserted here directly: add pre-reserves
// freelist capacity, so removal paths never grow either backing array.
test_handle_array_remove_clear_never_allocate :: (state: *Test_State) {
    Test_Handle :: HA.Handle;

    values: HA.Pool(int, Test_Handle);
    defer HA.delete(*values);

    HA.add(*values, 1);
    HA.add(*values, 2);
    third := HA.add(*values, 3);

    freelist_cap := values.freelist.allocated;
    slots_cap    := values.slots.allocated;

    HA.remove_handle(*values, third);
    expect(state, values.freelist.count == 1, "removed handle goes to freelist");
    expect(state, values.freelist.allocated == freelist_cap, "remove does not grow freelist");

    HA.clear(*values);
    expect(state, values.freelist.count == 3, "clear pushes all live slots");
    expect(state, values.freelist.allocated == freelist_cap, "clear does not grow freelist");
    expect(state, values.slots.allocated == slots_cap, "clear does not grow slots");
    expect(state, HA.len(values) == 0, "len == 0 after clear");

    // Re-adds drain the freelist without touching either backing array.
    HA.add(*values, 10);
    HA.add(*values, 20);
    HA.add(*values, 30);
    expect(state, values.freelist.count == 0, "re-adds drain the freelist");
    expect(state, values.slots.count == 4, "slot count unchanged (3 live + dummy)");
    expect(state, values.slots.allocated == slots_cap, "re-adds do not grow slots");
}
