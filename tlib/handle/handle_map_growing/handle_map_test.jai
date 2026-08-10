#import "Basic";
#import "test_support";

HMG :: #import "handle/handle_map_growing/handle_map";

// operator == must be visible in this scope for bare == on handles.
operator == :: (a: HMG.Handle, b: HMG.Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// Port of handle_map_test.odin: pool_lifecycle_and_iteration
test_handle_map_growing :: (state: *Test_State) {
    Test_Handle :: HMG.Handle;

    Test_Item :: struct {
        handle: Test_Handle;
        value:  s32;
    }

    pool: HMG.Pool(Test_Item, Test_Handle);
    defer HMG.delete(*pool);

    first, _   := HMG.add(*pool, .{ value = 1 });
    removed, _ := HMG.add(*pool, .{ value = 2 });
    third, _   := HMG.add(*pool, .{ value = 3 });
    expect(state, HMG.len(pool) == 3, "len == 3");
    expect(state, HMG.cap(pool) >= HMG.len(pool), "cap >= len");

    HMG.remove_handle(*pool, removed);
    expect(state, HMG.len(pool) == 2, "len == 2 after remove");
    expect(state, HMG.valid(pool, first), "first is valid");
    expect(state, !HMG.valid(pool, removed), "removed is not valid");
    expect(state, HMG.get(pool, removed) == null, "get removed is null");

    reused, _ := HMG.add(*pool, .{ value = 4 });
    expect(state, reused.idx == removed.idx, "reused slot index matches removed");
    expect(state, reused.gen != removed.gen, "reused gen differs from removed");

    count := 0;
    sum: s32 = 0;
    it := HMG.begin(*pool);
    while true {
        item, handle, ok := HMG.next(*it);
        if !ok break;
        count += 1;
        sum += item.value;
        expect(state, handle == item.handle, "handle matches item.handle");
    }
    expect(state, count == 3, "iteration count == 3");
    expect(state, sum == 8, "iteration sum == 8");
    expect(state, HMG.valid(pool, third), "third is valid");

    HMG.reset(*pool);
    expect(state, HMG.len(pool) == 0, "len == 0 after reset");
    expect(state, !HMG.valid(pool, first), "first is not valid after reset");
}
