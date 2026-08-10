// handle_map.jai
// Port of Ascension/tlib/handle/handle_map_virtual/handle_map.odin
// Handle-based map using a static virtual arena. By Karl Zylinski.
//
// Virtual memory is reserved up-front (Max * size_of(T) bytes) but physical
// memory is only committed as the items array grows into that reservation.
// The dynamic array's backing memory lives in the arena, so reallocation
// happens in-place and no pointers ever move.
//
// Note: the Odin original's `remove` is ported as `remove_handle` because
// `remove` is a reserved keyword in Jai.

#import "Basic";

// --- Windows virtual memory bindings ---

kernel32 :: #system_library "kernel32";

VirtualAlloc :: (lpAddress: *void, dwSize: u64, flAllocationType: u32, flProtect: u32) -> *void #foreign kernel32;
VirtualFree :: (lpAddress: *void, dwSize: u64, dwFreeType: u32) -> s32 #foreign kernel32;

MEM_RESERVE   :: 0x2000;
MEM_COMMIT    :: 0x1000;
MEM_RELEASE   :: 0x8000;
PAGE_READWRITE :: 0x04;

PAGE_SIZE :: 4096;

// --- Static virtual arena ---

Static_Arena :: struct {
    base:      *u8;
    reserved:  s64;  // virtual bytes reserved
    committed: s64;  // virtual bytes committed
    used:      s64;  // bytes handed out (linear)
}

static_arena_init :: (arena: *Static_Arena, reserve_bytes: s64) -> bool {
    // VirtualAlloc reserves whole pages, and commits are page-aligned too, so
    // round the reservation up to a page boundary.
    reserve_bytes = (reserve_bytes + PAGE_SIZE - 1) / PAGE_SIZE * PAGE_SIZE;
    ptr := VirtualAlloc(null, cast(u64) reserve_bytes, MEM_RESERVE, PAGE_READWRITE);
    if ptr == null {
        return false;
    }
    arena.base = cast(*u8) ptr;
    arena.reserved = reserve_bytes;
    arena.committed = 0;
    arena.used = 0;
    return true;
}

static_arena_destroy :: (arena: *Static_Arena) {
    if arena.base != null {
        VirtualFree(arena.base, 0, MEM_RELEASE);
        arena.base = null;
        arena.reserved = 0;
        arena.committed = 0;
        arena.used = 0;
    }
}

static_arena_allocate :: (arena: *Static_Arena, size: s64, alignment: s64) -> *void {
    aligned_used := (arena.used + alignment - 1) / alignment * alignment;
    need := aligned_used + size;
    if need > arena.committed {
        commit_to := (need + PAGE_SIZE - 1) / PAGE_SIZE * PAGE_SIZE;
        if commit_to > arena.reserved {
            return null;  // ran out of the reserved virtual space
        }
        VirtualAlloc(arena.base + arena.committed, cast(u64) (commit_to - arena.committed), MEM_COMMIT, PAGE_READWRITE);
        arena.committed = commit_to;
    }
    result := arena.base + aligned_used;
    arena.used = need;
    return result;
}

// In-place growth only works if old_memory is the last allocation in the
// arena, which is always the case here (the items array is always the most
// recent allocation into the arena).
static_arena_resize :: (arena: *Static_Arena, old_memory: *void, old_size: s64, new_size: s64) -> *void {
    if old_memory == null {
        // First allocation of the array.
        return static_arena_allocate(arena, new_size, 16);
    }
    if cast(*u8) old_memory + old_size == arena.base + arena.used {
        arena.used -= old_size;
        return static_arena_allocate(arena, new_size, 1);
    }
    return null;
}

static_arena_alloc_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    arena := cast(*Static_Arena) allocator_data;
    if mode == .ALLOCATE {
        return static_arena_allocate(arena, size, 16);
    } else if mode == .RESIZE {
        return static_arena_resize(arena, old_memory, old_size, size);
    }
    return null;
}

static_arena_allocator :: (arena: *Static_Arena) -> Allocator {
    return .{ proc = static_arena_alloc_proc, data = cast(*void) arena };
}

// --- Handle map ---

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

// `T` is the type to store in the Pool.
//
// `HT` is the handle type. Usually `My_Handle_Type :: distinct hm.Handle`.
//
// `Max` is the maximum number of items the Pool can store. Since the
// Pool uses virtual memory, you can choose a very big value for `Max`:
// It will only be used to reserve virtual memory. Actual physical memory is
// only allocated as the `items` array grows into that reserved memory.
Pool :: struct(T: Type, HT: Type, Max: int) {
    // Each item must have a field `handle` of type `HT`.
    //
    // There's always a "dummy element" at index 0. This way, a Handle with
    // `idx == 0` means "no Handle".
    items: [..] T;

    // Arena that stores the data for the items. It has room for `Max + 1`
    // elements (index 0 is the dummy). arena_valid mirrors the Odin original's
    // `items_arena != nil` check.
    items_arena: Static_Arena;
    arena_valid: bool;

    // The indices of unused slots. `remove_handle` will add things to it and
    // `add` will remove things from it.
    unused_items: [..] u32;
}

// Usually you can just declare the Pool using
// `pool: Pool(Item_Type, Handle_Type, 10000)`, but if you want to override
// the allocator used for `unused_items`, you can instead call `make`.
make :: ($T: Type, $HT: Type, $Max: int) -> (Pool(T, HT, Max), bool) {
    m: Pool(T, HT, Max);
    reserve_bytes := (cast(s64) Max + 1) * size_of(T);
    ok := static_arena_init(*m.items_arena, reserve_bytes);
    if !ok {
        return m, false;
    }
    m.arena_valid = true;
    return m, true;
}

// Deallocate all memory associated with the Pool.
delete :: (m: *Pool($T, $HT, $Max)) {
    if m.arena_valid {
        static_arena_destroy(*m.items_arena);
        m.arena_valid = false;
    }
    array_free(m.unused_items);
}

// Empties the handle map without deallocating any memory.
reset :: (m: *Pool($T, $HT, $Max)) {
    array_reset_keeping_memory(*m.items);
    array_reset_keeping_memory(*m.unused_items);
}

// Add a value of type `T` to the handle map. Returns a handle you can use as a
// permanent reference.
//
// This may cause the `items` array to grow. Since the backing memory of `items`
// is always the most recent allocation into `items_arena`, the arena is able
// to reallocate the dynamic array `items` in-place: No pointers will move.
//
// Will reuse slots from `unused_items` array if there are any.
add :: (m: *Pool($T, $HT, $Max), v: T) -> (HT, bool) {
    if !m.arena_valid {
        rebuilt, ok := make(T, HT, Max);
        if !ok {
            zero: HT;
            return zero, false;
        }
        <<m = rebuilt;
    }

    if m.unused_items.count > 0 {
        reuse_idx := m.unused_items[m.unused_items.count - 1];
        m.unused_items.count -= 1;
        reused := *m.items[cast(s64) reuse_idx];
        gen := reused.handle.gen;
        <<reused = v;
        reused.handle.idx = reuse_idx;
        reused.handle.gen = gen + 1;
        return reused.handle, true;
    }

    if m.items.count >= cast(s64) Max + 1 {
        // Pool is full (dummy slot + Max items).
        zero: HT;
        return zero, false;
    }

    // Make the items array allocate from the arena. From the first allocation
    // on, the array remembers the arena as its allocator (push_allocator
    // restores the previous allocator when this scope exits).
    if m.items.count == 0 {
        push_allocator(static_arena_allocator(*m.items_arena));
        zero_dummy: T;
        array_add(*m.items, zero_dummy);
    }

    new_item := v;
    new_item.handle.idx = cast(u32) m.items.count;
    new_item.handle.gen = 1;
    push_allocator(static_arena_allocator(*m.items_arena));
    array_add(*m.items, new_item);

    return new_item.handle, true;
}

// Resolve a handle to a pointer of type `*T`. The pointer is stable due to the
// usage of the virtual static arena. But you should _not_ store the pointer
// permanently. The item may get reused if any part of your program destroys and
// reuses that slot. Only store handles permanently and temporarily resolve them
// into pointers as needed.
get :: (m: Pool($T, $HT, $Max), h: HT) -> *T {
    if h.idx <= 0 || h.idx >= cast(u32) m.items.count {
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
// added to the `unused_items` array. `handle.idx` on the item is set to zero,
// this is used by the `next` proc in order to skip that item when iterating.
remove_handle :: (m: *Pool($T, $HT, $Max), h: HT) {
    if h.idx <= 0 || h.idx >= cast(u32) m.items.count {
        return;
    }

    item := *m.items[cast(s64) h.idx];
    if item.handle == h {
        array_add(*m.unused_items, h.idx);

        // This makes the item invalid. `next` uses that to skip over it.
        // We'll set the index back if the slot is reused.
        item.handle.idx = 0;
    }
}

// Tells you if a handle maps to a valid item.
valid :: (m: Pool($T, $HT, $Max), h: HT) -> bool {
    return get(m, h) != null;
}

// Tells you how many valid items there are in the handle map.
len :: (m: Pool($T, $HT, $Max)) -> int {
    return max(cast(int) m.items.count, 1) - cast(int) m.unused_items.count - 1;
}

slot_cap :: (m: Pool($T, $HT, $Max)) -> int {
    if !m.arena_valid {
        return 0;
    }
    return cast(int) (m.items_arena.reserved / size_of(T));
}

// Calculates how many items you could, in theory, fit into the Pool. In
// many cases the Pool will be reserved with a very very large number, so
// this capacity may have an absurd value.
cap :: (m: Pool($T, $HT, $Max)) -> int {
    return max(slot_cap(m) - 1, 0);
}

// For iterating a handle map. Create using `begin`.
Iterator :: struct(T: Type, HT: Type, Max: int) {
    m:     *Pool(T, HT, Max);
    index: int;
}

// Create an iterator. Use with `next` to do the actual iteration.
begin :: (m: *Pool($T, $HT, $Max)) -> Iterator(T, HT, Max) {
    return .{ m = m, index = 0 };
}

// Iterate over the handle map. Skips unused slots, meaning that it skips slots
// with handle.idx == 0.
next :: (it: *Iterator($T, $HT, $Max)) -> (*T, HT, bool) {
    while it.index < cast(int) it.m.items.count {
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
