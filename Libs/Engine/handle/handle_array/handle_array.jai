// handle_array.jai
// Port of Ascension/tlib/handle/handle_array/handle_array.odin
// Growable handle pool: slots[] + freelist[] + generation counters.
// Slots[0] is a dummy slot; a handle is valid iff slots[idx].handle == h.

#import "Basic";

Handle :: struct {
    idx: u32;
    gen: u32;
}

operator == :: inline (a: Handle, b: Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

Slot :: struct(T: Type, HT: Type) {
    value:  T;
    handle: HT;
}

Pool :: struct(T: Type, HT: Type) {
    slots:    [..] Slot(T, HT);
    freelist: [..] HT;
    num:      int;
}

Iterator :: struct(T: Type, HT: Type) {
    ha:    *Pool(T, HT);
    index: int;
}

HANDLE_NONE :: Handle.{};

add :: (ha: *Pool($T, $HT), v: T) -> HT {
    if ha.freelist.count > 0 {
        h := ha.freelist[ha.freelist.count - 1];
        ha.freelist.count -= 1;
        h.gen += 1;
        ha.slots[cast(s64) h.idx].value  = v;
        ha.slots[cast(s64) h.idx].handle = h;
        ha.num += 1;
        return h;
    }

    if ha.slots.count == 0 {
        _ := array_add(*ha.slots); // index 0 is a dummy slot
    }

    // Reserve before publishing a slot, so remove_handle and clear never
    // allocate: every slot that can later go to the freelist already has room.
    needed := ha.slots.count + 1;
    if ha.freelist.allocated < needed - 1 {
        _ := array_reserve(*ha.freelist, max(needed - 1, 2 * ha.freelist.allocated, 8));
    }

    idx := cast(u32) ha.slots.count;
    h: HT;
    h.idx = idx;
    h.gen = 1;

    array_add(*ha.slots, .{ value = v, handle = h });
    ha.num += 1;
    return h;
}

// remove_handle: Jai's 'remove' is a reserved keyword (loop keyword), so the
// Odin original's remove is ported as remove_handle. If destroy is non-null it
// is called with the value before removal.
remove_handle :: (ha: *Pool($T, $HT), h: HT, destroy: (value: *T) = null) {
    if h.idx > 0 && cast(s64) h.idx < ha.slots.count && (ha.slots[cast(s64) h.idx].handle.idx == h.idx && ha.slots[cast(s64) h.idx].handle.gen == h.gen) {
        if destroy != null {
            destroy(*ha.slots[cast(s64) h.idx].value);
        }
        array_add(*ha.freelist, h);
        ha.slots[cast(s64) h.idx] = Slot(T, HT).{};
        ha.num -= 1;
    }
}

// clear: removes all live values while retaining slots and generation history.
// Subsequent adds reuse free slots; old handles stay invalid until generation
// wraparound. Neither the freelist nor the slot array allocates during clear.
// The destroy callback must not structurally mutate this pool.
clear :: (ha: *Pool($T, $HT), destroy: (value: *T) = null) {
    // Existing free slots already carry their generation in the freelist.
    // Only append live slots, so repeated clears cannot duplicate entries.
    i := 1;
    while i < cast(int) ha.slots.count {
        h := ha.slots[cast(s64) i].handle;
        if h.idx != 0 {
            remove_handle(ha, h, destroy);
        }
        i += 1;
    }
}

// reset: clears for a new lifecycle while retaining allocated capacity.
reset :: (ha: *Pool($T, $HT), destroy: (value: *T) = null) {
    if destroy != null {
        i := 1;
        while i < cast(int) ha.slots.count {
            if ha.slots[cast(s64) i].handle.idx > 0 {
                destroy(*ha.slots[cast(s64) i].value);
            }
            i += 1;
        }
    }
    array_reset_keeping_memory(*ha.slots);
    array_reset_keeping_memory(*ha.freelist);
    ha.num = 0;
}

// delete: frees the pool's memory. Pass destroy to clean up each value first.
delete :: (ha: *Pool($T, $HT), destroy: (value: *T) = null) {
    if destroy != null {
        i := 1;
        while i < cast(int) ha.slots.count {
            if ha.slots[cast(s64) i].handle.idx > 0 {
                destroy(*ha.slots[cast(s64) i].value);
            }
            i += 1;
        }
    }
    array_free(ha.slots);
    array_free(ha.freelist);
    <<ha = Pool(T, HT).{};
}

get_value :: (ha: Pool($T, $HT), h: HT) -> (T, bool) {
    if h.idx > 0 && cast(s64) h.idx < ha.slots.count && (ha.slots[cast(s64) h.idx].handle.idx == h.idx && ha.slots[cast(s64) h.idx].handle.gen == h.gen) {
        return ha.slots[cast(s64) h.idx].value, true;
    }
    zero_value: T;
    return zero_value, false;
}

get :: (ha: Pool($T, $HT), h: HT) -> *T {
    if h.idx > 0 && cast(s64) h.idx < ha.slots.count && (ha.slots[cast(s64) h.idx].handle.idx == h.idx && ha.slots[cast(s64) h.idx].handle.gen == h.gen) {
        return *ha.slots[cast(s64) h.idx].value;
    }
    return null;
}

valid :: (ha: Pool($T, $HT), h: HT) -> bool {
    return get(ha, h) != null;
}

len :: (ha: Pool($T, $HT)) -> int {
    return ha.num;
}

// Returns the number of live items that fit without growing the slot array.
cap :: (ha: Pool($T, $HT)) -> int {
    return max(cast(int) ha.slots.allocated - 1, 0);
}

begin :: (ha: *Pool($T, $HT)) -> Iterator(T, HT) {
    return .{ ha = ha, index = 1 };
}

// Structural mutation during iteration is not allowed. Adding an item may
// relocate slots and invalidate a pointer returned by next.
next :: (it: *Iterator($T, $HT)) -> (*T, HT, bool) {
    while it.index < cast(int) it.ha.slots.count {
        index := it.index;
        it.index += 1;

        slot := *it.ha.slots[cast(s64) index];
        if slot.handle.idx != 0 {
            return *slot.value, slot.handle, true;
        }
    }

    return null, HT.{}, false;
}
