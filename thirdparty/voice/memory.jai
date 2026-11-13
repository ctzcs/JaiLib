#scope_module
// Slices use an exclusive end, matching the protocol implementation's indexing.
view :: (a: [] $T, start: int, end: int = -1) -> [] T {
    if end < 0 end = a.count;
    assert(start >= 0 && end >= start && end <= a.count);
    return array_view(a, start, end - start);
}
release :: (a: [] $T, allocator: Allocator = context.allocator) {
    if a.data == null return;
    push_allocator(allocator);
    free(a.data);
}
release :: (a: [..] $T) { array_free(a); }
zero_slice :: (a: [] $T) { for *v: a v.* = .{}; }
copy_samples :: (dest: [] $T, src: [] T) {
    n := min(dest.count, src.count);
    // Overlap occurs when compacting the simple receiver's ring.
    if cast(u64) dest.data > cast(u64) src.data {
        i := n; while i > 0 { i -= 1; dest[i] = src[i]; }
    } else {
        i := 0; while i < n { dest[i] = src[i]; i += 1; }
    }
}
make_ring :: (capacity: int) -> [..] float32 {
    a: [..] float32;
    array_reserve(*a, capacity);
    return a;
}

