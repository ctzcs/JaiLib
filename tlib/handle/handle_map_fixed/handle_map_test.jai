#import "Basic";
#import "test_support";

HMF :: #import "handle/handle_map_fixed/handle_map";

// operator == must be visible in this scope for bare == on handles.
operator == :: (a: HMF.Handle, b: HMF.Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// Port of handle_map_test.odin: pool_lifecycle_and_iteration
test_handle_map_fixed :: (state: *Test_State) {
    Test_Handle :: HMF.Handle;

    Test_Item :: struct {
        handle: Test_Handle;
        value:  s32;
    }

    pool: HMF.Pool(Test_Item, Test_Handle, 4);
    defer HMF.delete(*pool);

    expect(state, HMF.len(pool) == 0, "len == 0");
    expect(state, HMF.cap(pool) == 3, "cap == 3");

    first, _   := HMF.add(*pool, .{ value = 1 });
    removed, _ := HMF.add(*pool, .{ value = 2 });
    third, _   := HMF.add(*pool, .{ value = 3 });
    _, added := HMF.add(*pool, .{ value = 99 });
    expect(state, !added, "4th add fails (cap 3)");

    HMF.remove_handle(*pool, removed);
    expect(state, HMF.len(pool) == 2, "len == 2 after remove");
    expect(state, HMF.valid(pool, first), "first is valid");
    expect(state, !HMF.valid(pool, removed), "removed is not valid");
    expect(state, HMF.get(*pool, removed) == null, "get removed is null");

    reused, _ := HMF.add(*pool, .{ value = 4 });
    expect(state, reused.idx == removed.idx, "reused slot index matches removed");
    expect(state, reused.gen != removed.gen, "reused gen differs from removed");

    count := 0;
    sum: s32 = 0;
    it := HMF.begin(*pool);
    while true {
        item, handle, ok := HMF.next(*it);
        if !ok break;
        count += 1;
        sum += item.value;
        expect(state, handle == item.handle, "handle matches item.handle");
    }
    expect(state, count == 3, "iteration count == 3");
    expect(state, sum == 8, "iteration sum == 8");
    expect(state, HMF.valid(pool, third), "third is valid");

    HMF.reset(*pool);
    expect(state, HMF.len(pool) == 0, "len == 0 after reset");
    expect(state, !HMF.valid(pool, first), "first is not valid after reset");
}
