#import "Basic";
#import "test_support";

HMV :: #import "handle/handle_map_virtual/handle_map";

// operator == must be visible in this scope for bare == on handles.
operator == :: (a: HMV.Handle, b: HMV.Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// Port of handle_map_test.odin: pool_lifecycle_and_iteration
test_handle_map_virtual :: (state: *Test_State) {
    Test_Handle :: HMV.Handle;

    Test_Item :: struct {
        handle: Test_Handle;
        value:  s32;
    }

    pool: HMV.Pool(Test_Item, Test_Handle, 4);
    defer HMV.delete(*pool);

    first, _   := HMV.add(*pool, .{ value = 1 });
    removed, _ := HMV.add(*pool, .{ value = 2 });
    third, _   := HMV.add(*pool, .{ value = 3 });
    expect(state, HMV.len(pool) == 3, "len == 3");
    expect(state, HMV.cap(pool) >= HMV.len(pool), "cap >= len");

    HMV.remove_handle(*pool, removed);
    expect(state, HMV.len(pool) == 2, "len == 2 after remove");
    expect(state, HMV.valid(pool, first), "first is valid");
    expect(state, !HMV.valid(pool, removed), "removed is not valid");
    expect(state, HMV.get(pool, removed) == null, "get removed is null");

    reused, _ := HMV.add(*pool, .{ value = 4 });
    expect(state, reused.idx == removed.idx, "reused slot index matches removed");
    expect(state, reused.gen != removed.gen, "reused gen differs from removed");

    count := 0;
    sum: s32 = 0;
    it := HMV.begin(*pool);
    while true {
        item, handle, ok := HMV.next(*it);
        if !ok break;
        count += 1;
        sum += item.value;
        expect(state, handle == item.handle, "handle matches item.handle");
    }
    expect(state, count == 3, "iteration count == 3");
    expect(state, sum == 8, "iteration sum == 8");
    expect(state, HMV.valid(pool, third), "third is valid");

    HMV.reset(*pool);
    expect(state, HMV.len(pool) == 0, "len == 0 after reset");
    expect(state, !HMV.valid(pool, first), "first is not valid after reset");
}
