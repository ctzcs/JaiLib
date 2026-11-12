// handle_map.jai
// Port of Ascension/tlib/handle/handle_map_growing/handle_map.odin
// Handle-based map using a growing arena. By Karl Zylinski (karl@zylinski.se).
//
// This implementation stores an array of pointers to items. Those items are
// allocated into a growing arena. They'll never move within the arena, so
// pointers are stable.
//
// Note: the Odin original's `remove` is ported as `remove_handle` because
// `remove` is a reserved keyword in Jai.

#import "Basic";
#import "handle/handle_map/arena";

Handle :: struct {
    // index into `items` array of the `Pool` struct.
    idx: u32;

    // When using the `get` proc, this will be matched to the `gen` on the item
    // in the handle map. The handle is only valid if they match. If they don't
    // match, then it means that the slot in the handle map has been reused.
    gen: u32;
}

operator == :: inline (a: Handle, b: Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

Pool :: struct(T: Type, HT: Type) {
    // Each item in this array is allocated using `items_arena`. This array is
    // allocated using the default allocator, not using the arena. Only the
    // items themselves are allocated using `items_arena`.
    //
    // Each item must have a field `handle` of type `HT`.
    //
    // There's always a "dummy element" at index 0. This way, a Handle with
    // `idx == 0` means "no Handle".
    items: [..] *T;

    // Arena that stores the data for each of the items. Since all of them are
    // allocated linearly into this arena, they are fairly well packed. This
    // gives stable pointers combined with good performance.
    items_arena: Arena;

    // The indices into `items` of unused slots. `remove_handle` adds to it.
    unused_items: [..] u32;
}

// Create a `Pool` for the given item type `T` and handle type `HT`. The
// handle type should usually be defined as
//     Handle_Type :: distinct Handle
//
// `min_items_per_block` says how many items the underlying arena can store in
// each block of memory. If it is <= 0, the default block size is used.
// Note: min_items_per_block * size_of(T) is clamped to at least one page.
make :: ($T: Type, $HT: Type, min_items_per_block: int = 0) -> (Pool(T, HT), bool) {
    m: Pool(T, HT);
    block_size := ARENA_DEFAULT_BLOCK_SIZE;
    if min_items_per_block > 0 {
        block_size = min_items_per_block * size_of(T);
    }
    ok := arena_init(*m.items_arena, cast(s64) block_size);
    return m, ok;
}

// Deallocate all memory associated with the Pool.
delete :: (m: *Pool($T, $HT)) {
    arena_destroy(*m.items_arena);
    array_free(m.items);
    array_free(m.unused_items);
}

// Empties the handle map without deallocating all memory. The `items_arena`
// is deallocated, except the first block, since that one will be reused.
// `items` and `unused_items` are cleared, but not deallocated.
reset :: (m: *Pool($T, $HT)) {
    arena_free_all(*m.items_arena);
    array_reset_keeping_memory(*m.items);
    array_reset_keeping_memory(*m.unused_items);
}

// Add a value of type `T` to the handle map. Returns a handle you can use as a
// permanent reference.
//
// New items are allocated using an arena allocator, into the Pool's
// `items_arena`. This makes pointers stable while giving good performance, due
// to the items being packed in the arena.
//
// Will reuse slots from `unused_items` array if there are any.
add :: (m: *Pool($T, $HT), v: T) -> (HT, bool) {
    if !arena_initialized(m.items_arena) {
        rebuilt, ok := make(T, HT);
        if !ok {
            zero: HT;
            return zero, false;
        }
        <<m = rebuilt;
    }

    if m.unused_items.count > 0 {
        reuse_idx := m.unused_items[m.unused_items.count - 1];
        m.unused_items.count -= 1;
        reused := m.items[cast(s64) reuse_idx];
        gen := reused.handle.gen;
        <<reused = v;
        reused.handle.idx = reuse_idx;
        reused.handle.gen = gen + 1;
        return reused.handle, true;
    }

    items_allocator := arena_allocator(*m.items_arena);

    if m.items.count == 0 {
        zero_dummy := cast(*T) items_allocator.proc(.ALLOCATE, size_of(T), 0, null, items_allocator.data);
        if zero_dummy == null {
            zero: HT;
            return zero, false;
        }
        array_add(*m.items, zero_dummy);
    }

    new_item := cast(*T) items_allocator.proc(.ALLOCATE, size_of(T), 0, null, items_allocator.data);
    if new_item == null {
        zero: HT;
        return zero, false;
    }
    <<new_item = v;
    new_item.handle.idx = cast(u32) m.items.count;
    new_item.handle.gen = 1;
    array_add(*m.items, new_item);
    return new_item.handle, true;
}

// Resolve a handle to a pointer of type `*T`. The pointer is stable due to
// being allocated on the `items_arena`. But you should _not_ store the pointer
// permanently. The item may get reused if any part of your program destroys and
// reuses that slot. Only store handles permanently and temporarily resolve them
// into pointers as needed.
get :: (m: Pool($T, $HT), h: HT) -> *T {
    if h.idx <= 0 || h.idx >= cast(u32) m.items.count {
        return null;
    }

    item := m.items[cast(s64) h.idx];
    if item.handle == h {
        return item;
    }

    return null;
}

// Remove an item from the handle map. You choose which item by passing a handle
// to this proc. The item is not really destroyed, rather its index is just
// added to the `unused_items` array. `handle.idx` on the item is set to zero,
// this is used by the `next` proc in order to skip that item when iterating.
remove_handle :: (m: *Pool($T, $HT), h: HT) {
    if h.idx <= 0 || h.idx >= cast(u32) m.items.count {
        return;
    }

    item := m.items[cast(s64) h.idx];
    if item.handle == h {
        array_add(*m.unused_items, h.idx);

        // This makes the item invalid. `next` uses that to skip over it.
        // We'll set the index back if the slot is reused.
        item.handle.idx = 0;
    }
}

// Tells you if a handle maps to a valid item.
valid :: (m: Pool($T, $HT), h: HT) -> bool {
    return get(m, h) != null;
}

// Tells you how many valid items there are in the handle map. Note how this
// is implemented: `1` is always subtracted from the total number, because there
// may be an item at index `0`. That item is not used, it's just there to make
// sure that `idx == 0` on a handle doesn't map to anything.
len :: (m: Pool($T, $HT)) -> int {
    return max(cast(int) m.items.count, 1) - cast(int) m.unused_items.count - 1;
}

// Returns the number of live items that fit without growing the pointer array.
cap :: (m: Pool($T, $HT)) -> int {
    return max(cast(int) m.items.allocated - 1, 0);
}

// For iterating a handle map. Create using `begin`.
Iterator :: struct(T: Type, HT: Type) {
    m:     *Pool(T, HT);
    index: int;
}

// Create an iterator. Use with `next` to do the actual iteration.
begin :: (m: *Pool($T, $HT)) -> Iterator(T, HT) {
    return .{ m = m, index = 0 };
}

// Iterate over the handle map. Skips unused slots, meaning that it skips slots
// with handle.idx == 0.
next :: (it: *Iterator($T, $HT)) -> (*T, HT, bool) {
    while it.index < cast(int) it.m.items.count {
        item := it.m.items[cast(s64) it.index];
        it.index += 1;

        if item.handle.idx != 0 {
            return item, item.handle, true;
        }
    }

    zero: HT;
    return null, zero, false;
}

// If you don't want to use iterator, you can instead do:
//   for * item: my_map.items {
//       if skip(item) { continue; }
//       // do stuff
//   }
skip :: (e: $T) -> bool {
    return e.handle.idx == 0;
}
