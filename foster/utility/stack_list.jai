#scope_module
using Basic; // module-private
#scope_export

// Port of Foster Framework/Utility/StackList.cs.
//
// C# has five copy-pasted `StackList4/8/16/32/64<T>` structs that differ only in
// their (inline) capacity. Jai can put the capacity in the polymorphic
// parameter list, so all five collapse into one definition:
//
//     Stack_List :: struct ($T: Type, $N: int)
//
// i.e. C# `StackList32<Point>` == Jai `Stack_List(Point, 32)`.
// Jai cannot partially apply polymorphic parameters, so the fixed-capacity
// names are provided as *constructor procedures* (the "alias or constructor"
// option) instead of type aliases:
//
//     l := stack_list8(Point);        // == Stack_List(Point, 8), count 0
//     l:  Stack_List(Point, 8);       // the type spelling, if you prefer it
//
// C# throws on misuse (Add past Capacity, index >= Count); Jai has no
// exceptions, so the un-checked procs assert and every checked operation has a
// `_try_` / bool-returning sibling for code that must recover:
//
//     stack_list_add(*l, v);              // asserts when full   (C#: throw)
//     if !stack_list_try_add(*l, v) ...   // returns false        (no C# twin)
//     v, ok := stack_list_pop(*l);        // (T, bool), no out params
//
// A Stack_List is a value type with inline storage: keep it in a struct field
// or on the stack and pass `*Stack_List(...)` around, exactly like C# passes
// the struct by `ref`. Nothing here allocates.

Stack_List :: struct($T: Type, $N: int = 4) {
    elements: [N] T;
    count: s32;
}

// Zero value of a $T: Jai has no `default(T)` expression, and `value: T = ---;`
// inside polymorphic code leaves a struct with garbage members under jaic, so
// clear the bytes explicitly. (Fine for every Jai type: none have destructors.)
stack_list_zero_value :: ($T: Type) -> T {
    value: T;
    memset(*value, 0, size_of(T));
    return value;
}

//
// construction / fixed-capacity variants (C# StackList4/8/16/32/64<T>)
//

stack_list_create :: ($T: Type, $N := 4) -> Stack_List($T, $N) {
    return .{ count = 0 };
}

stack_list4 :: ($T: Type) -> Stack_List($T, 4) {
    return .{ count = 0 };
}

stack_list8 :: ($T: Type) -> Stack_List($T, 8) {
    return .{ count = 0 };
}

stack_list16 :: ($T: Type) -> Stack_List($T, 16) {
    return .{ count = 0 };
}

stack_list32 :: ($T: Type) -> Stack_List($T, 32) {
    return .{ count = 0 };
}

stack_list64 :: ($T: Type) -> Stack_List($T, 64) {
    return .{ count = 0 };
}

stack_list_capacity :: (list: *Stack_List($T, $N)) -> s32 {
    return N; // C# StackListN<T>.Capacity / TypeCapacity
}

stack_list_count :: (list: *Stack_List($T, $N)) -> s32 {
    return list.count;
}

stack_list_is_full :: (list: *Stack_List($T, $N)) -> bool {
    return list.count >= N;
}

// View of the live elements (C# StackListN<T>.Span). Writes through it land in
// the list's inline storage.
stack_list_span :: (list: *Stack_List($T, $N)) -> [] T {
    return cast([] T) .{ data = *list.elements[0], count = list.count };
}

//
// add / push / pop
//

// C# Add: asserts instead of throwing when the capacity is exceeded.
stack_list_add :: (list: *Stack_List($T, $N), value: T) {
    assert(list.count < N, "Exceeding Capacity of StackList");
    list.elements[list.count] = value;
    list.count += 1;
}

// Checked Add: false when the list is full (Jai's replacement for the throw).
stack_list_try_add :: (list: *Stack_List($T, $N), value: T) -> bool {
    if list.count >= N return false;
    list.elements[list.count] = value;
    list.count += 1;
    return true;
}

// Convenience aliases, for code that thinks of the list as a stack.
stack_list_push :: (list: *Stack_List($T, $N), value: T) {
    stack_list_add(list, value);
}

// Removes and returns the last element; false when empty.
stack_list_pop :: (list: *Stack_List($T, $N)) -> (T, bool) {
    if list.count <= 0 return .{}, false;
    list.count -= 1;
    value := list.elements[list.count];
    list.elements[list.count] = stack_list_zero_value(T);
    return value, true;
}

// Returns the last element without removing it; false when empty.
stack_list_peek :: (list: *Stack_List($T, $N)) -> (T, bool) {
    if list.count <= 0 return .{}, false;
    return list.elements[list.count - 1], true;
}

//
// element access (C# indexer, which throws on index >= Count)
//

stack_list_get :: (list: *Stack_List($T, $N), index: s32) -> T {
    assert(index >= 0 && index < list.count, "IndexOutOfRangeException");
    return list.elements[index];
}

stack_list_try_get :: (list: *Stack_List($T, $N), index: s32) -> (T, bool) {
    if index < 0 || index >= list.count return .{}, false;
    return list.elements[index], true;
}

stack_list_set :: (list: *Stack_List($T, $N), index: s32, value: T) {
    assert(index >= 0 && index < list.count, "IndexOutOfRangeException");
    list.elements[index] = value;
}

//
// size / clearing
//

// C# Resize: changes Count without touching the capacity limit. Growing exposes
// zeroed slots (C#'s default-initialised elements), shrinking zeroes the slots
// that fall out of the live range.
stack_list_resize :: (list: *Stack_List($T, $N), new_count: s32) {
    assert(new_count >= 0 && new_count <= N, "Exceeding Capacity of StackList");
    zero := stack_list_zero_value(T);
    if new_count < list.count {
        for i: new_count..list.count - 1 list.elements[i] = zero;
    } else {
        for i: list.count..new_count - 1 list.elements[i] = zero;
    }
    list.count = new_count;
}

stack_list_clear :: (list: *Stack_List($T, $N)) {
    zero := stack_list_zero_value(T);
    for i: 0..list.count - 1 list.elements[i] = zero;
    list.count = 0;
}

//
// search / mutation (C# IndexOf / Contains / Insert / RemoveAt / Remove / CopyTo)
//

stack_list_index_of :: (list: *Stack_List($T, $N), item: T) -> s32 {
    for i: 0..list.count - 1 {
        if list.elements[i] == item return i;
    }
    return -1;
}

stack_list_contains :: (list: *Stack_List($T, $N), item: T) -> bool {
    return stack_list_index_of(list, item) >= 0;
}

stack_list_insert :: (list: *Stack_List($T, $N), index: s32, item: T) {
    assert(list.count < N, "Exceeding Capacity of StackList");
    assert(index >= 0 && index <= list.count, "IndexOutOfRangeException");
    i := list.count;
    while i > index {
        list.elements[i] = list.elements[i - 1];
        i -= 1;
    }
    list.elements[index] = item;
    list.count += 1;
}

// C# RemoveAt, but the vacated slot is zeroed (C# leaves a stale reference,
// which is harmless with a GC and a leak without one).
stack_list_remove_at :: (list: *Stack_List($T, $N), index: s32) {
    assert(index >= 0 && index < list.count, "IndexOutOfRangeException");
    for i: index..list.count - 2 list.elements[i] = list.elements[i + 1];
    list.count -= 1;
    list.elements[list.count] = stack_list_zero_value(T);
}

stack_list_remove :: (list: *Stack_List($T, $N), item: T) -> bool {
    index := stack_list_index_of(list, item);
    if index < 0 return false;
    stack_list_remove_at(list, index);
    return true;
}

stack_list_copy_to :: (list: *Stack_List($T, $N), dest: [] T, dest_index: s32) {
    assert(dest_index >= 0 && dest_index + list.count <= dest.count, "Destination array was not long enough");
    for i: 0..list.count - 1 dest[dest_index + i] = list.elements[i];
}
