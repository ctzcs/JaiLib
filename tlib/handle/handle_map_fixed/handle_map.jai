// handle_map.jai
// Port of Ascension/tlib/handle/handle_map_fixed/handle_map.odin
// Handle-based map using fixed arrays (no dynamic memory allocations).
// By Karl Zylinski (karl@zylinski.se).
//
// Note: the Odin original's `remove` is ported as `remove_handle` because
// `remove` is a reserved keyword in Jai.

#import "Basic";

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

Pool :: struct(T: Type, HT: Type, N: int) {
    // Each item must have a field `handle` of type `HT`.
    //
    // There's always a "dummy element" at index 0. This way, a Handle with
    // `idx == 0` means "no Handle". This means that you actually have `N - 1`
    // items available.
    items: [N] T;

    // How much of `items` that is in use.
    num_items: u32;

    // The index of the first unused element in `items`. At this index in
    // `unused_items` you'll find the next-next unused index. Used by `add` and
    // originally set by `remove_handle`.
    next_unused: u32;

    // An element in this array that is non-zero means the thing at that index
    // in `items` is unused. The non-zero number is the index of the next unused
    // item. This forms a linked series of indices. The series starts with
    // `next_unused`.
    unused_items: [N] u32;

    // Only used for making it possible to quickly calculate the number of valid
    // elements.
    num_unused: u32;
}

// Clears the handle map using memset. It doesn't do `<<m = .{}` because that
// may blow the stack for a handle map with very big `N`.
reset :: (m: *Pool($T, $HT, $N)) {
    memset(m, 0, size_of(Pool(T, HT, N)));
}

// Fixed pools own no heap allocations, so deleting one is equivalent to reset.
delete :: (m: *Pool($T, $HT, $N)) {
    reset(m);
}

// Add a value of type `T` to the handle map. Returns a handle you can use as a
// permanent reference.
//
// Will reuse the item at `next_unused` if that value is non-zero.
//
// Second return value is `false` if the handle-based map is full.
add :: (m: *Pool($T, $HT, $N), v: T) -> (HT, bool) {
    if m.next_unused != 0 {
        idx := m.next_unused;
        item := *m.items[cast(s64) idx];
        m.next_unused = m.unused_items[cast(s64) idx];
        m.unused_items[cast(s64) idx] = 0;
        gen := item.handle.gen;
        <<item = v;
        item.handle.idx = idx;
        item.handle.gen = gen + 1;
        m.num_unused -= 1;
        return item.handle, true;
    }

    // We always have a "dummy item" at index zero. This is because handle.idx
    // being zero means "no item", so we can't use that slot for anything.
    if m.num_items == 0 {
        m.num_items += 1;
    }

    if m.num_items == cast(u32) N {
        zero: HT;
        return zero, false;
    }

    item := *m.items[cast(s64) m.num_items];
    <<item = v;
    item.handle.idx = m.num_items;
    item.handle.gen = 1;
    m.num_items += 1;
    return item.handle, true;
}

// Resolve a handle to a pointer of type `*T`. The pointer is stable since the
// handle map uses a fixed array. But you should _not_ store the pointer
// permanently. The item may get reused if any part of your program destroys and
// reuses that slot. Only store handles permanently and temporarily resolve them
// into pointers as needed.
get :: (m: *Pool($T, $HT, $N), h: HT) -> *T {
    if h.idx <= 0 || h.idx >= m.num_items {
        return null;
    }

    item := *m.items[cast(s64) h.idx];
    if item.handle == h {
        return item;
    }

    return null;
}

// Remove an item from the handle map. You choose which item by passing a handle
// to this proc. The item is not really destroyed, rather its index is just
// set on `m.next_unused`. Also, the item's `handle.idx` is set to zero, this
// is used by the `next` proc in order to skip that item when iterating.
remove_handle :: (m: *Pool($T, $HT, $N), h: HT) {
    if h.idx <= 0 || h.idx >= m.num_items {
        return;
    }

    item := *m.items[cast(s64) h.idx];
    if item.handle == h {
        m.unused_items[cast(s64) h.idx] = m.next_unused;
        m.next_unused = h.idx;
        m.num_unused += 1;
        item.handle.idx = 0;
    }
}

// Tells you if a handle maps to a valid item. This is done by checking if the
// handle on the item is the same as the passed handle.
valid :: (m: Pool($T, $HT, $N), h: HT) -> bool {
    return h.idx > 0 && h.idx < m.num_items && m.items[cast(s64) h.idx].handle == h;
}

// Tells you how many valid items there are in the handle map.
len :: (m: Pool($T, $HT, $N)) -> int {
    if m.num_items == 0 {
        return 0;
    }
    return cast(int) (m.num_items - m.num_unused - 1);
}

// The maximum number of items the handle map can contain.
cap :: (m: Pool($T, $HT, $N)) -> int {
    return max(cast(int) N - 1, 0);
}

// For iterating a handle map. Create using `begin`.
Iterator :: struct(T: Type, HT: Type, N: int) {
    m:     *Pool(T, HT, N);
    index: u32;
}

// Create an iterator. Use with `next` to do the actual iteration.
begin :: (m: *Pool($T, $HT, $N)) -> Iterator(T, HT, N) {
    return .{ m = m, index = 1 };
}

// Iterate over the handle map. Skips unused slots, meaning that it skips slots
// with handle.idx == 0.
next :: (it: *Iterator($T, $HT, $N)) -> (*T, HT, bool) {
    while it.index < it.m.num_items {
        item := *it.m.items[cast(s64) it.index];
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
