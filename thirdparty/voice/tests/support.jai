Test :: struct { assertions: int; }
skipped: int;
expect :: (t: *Test, condition: bool) -> bool {
    t.assertions += 1; assert(condition); return condition;
}
expectf :: (t: *Test, condition: bool, message: string, args: ..Any) -> bool {
    if !condition print("FAILED: %\n", message);
    return expect(t, condition);
}
expect_value :: (t: *Test, actual: $T, expected: T) {
    t.assertions += 1;
    if actual != expected print("actual %, expected %\n", actual, expected);
    assert(actual == expected);
}
expect_value :: (t: *Test, a: voicelib.Neteq_Stats, b: voicelib.Neteq_Stats) {
    expect(t, a.dropped_packets == b.dropped_packets && a.concealed_samples == b.concealed_samples &&
        a.accelerated_samples == b.accelerated_samples && a.expanded_samples == b.expanded_samples);
}
note :: (message: string) { skipped += 1; print("%\n", message); }
nan32 :: () -> float32 { bits: u32 = 0x7fc00000; return (cast(*float32)*bits).*; }
wrap_timestamp :: (value: u64) -> u32 { return cast(u32)(value & 0xffffffff); }
panic_alloc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, data: *void) -> *void {
    assert(false, "PCM runtime attempted allocation or used the wrong deallocator"); return null;
}
Poison_Block :: struct { memory: *void; size: int; released: bool; }
Poison_Allocator :: struct { backing: Allocator; blocks: [4096]Poison_Block; count: int; }
poison_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, data: *void) -> *void {
    p := cast(*Poison_Allocator)data;
    if mode == .FREE {
        if old_memory == null return null;
        i := 0; while i < p.count {
            b := *p.blocks[i];
            if b.memory == old_memory && !b.released {
                bytes := cast(*u8)b.memory;
                j := 0; while j < b.size { bytes[j] = 0xff; j += 1; }
                b.released = true; return null;
            }
            i += 1;
        }
        assert(false, "free of untracked allocation");
    }
    if mode == .RESIZE {
        result := poison_allocator_proc(.ALLOCATE, size, 0, null, data);
        if old_memory != null {
            dest := cast(*u8)result; source := cast(*u8)old_memory;
            i := 0; while i < min(size, old_size) { dest[i] = source[i]; i += 1; }
            poison_allocator_proc(.FREE, 0, old_size, old_memory, data);
        }
        return result;
    }
    result := p.backing.proc(mode, size, old_size, old_memory, p.backing.data);
    if mode == .ALLOCATE && result != null {
        assert(p.count < p.blocks.count);
        p.blocks[p.count] = .{result, size, false}; p.count += 1;
    }
    return result;
}
poison_destroy :: (p: *Poison_Allocator) {
    i := 0; while i < p.count {
        b := p.blocks[i]; if b.released p.backing.proc(.FREE, 0, b.size, b.memory, p.backing.data); i += 1;
    }
}
