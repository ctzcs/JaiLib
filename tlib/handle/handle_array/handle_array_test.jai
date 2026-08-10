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
