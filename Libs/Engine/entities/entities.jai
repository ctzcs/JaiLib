// entities.jai
// Port of Ascension/tlib/entities/entities.odin
// Lightweight entity container: a free-list-based pool per entity variant.
//
// Odin used union types (Val_Union / Sub_Union) + reflection intrinsics. The
// Jai port instead stores runtime Type lists (set via init) and uses runtime
// Type_Info reflection (cast(*Type_Info) type_value) for sizes/offsets.

#import "Basic";

Handle_Index   :: u32;
Handle_Gen     :: u64;
Handle_Variant :: u32;

// A handle uniquely identifies an entity.
Handle :: struct {
    index:   Handle_Index;
    variant: Handle_Variant;
    gen:     Handle_Gen;
}

operator == :: inline (a: Handle, b: Handle) -> bool {
    return a.index == b.index && a.gen == b.gen && a.variant == b.variant;
}

// Base type of each entity, must be at offset 0.
Base :: struct {
    handle:     Handle; // Self
    _next_free: Handle_Index;
}

// Raw pointer to an entity, exposing the shared base plus the variant index.
// Never store this beyond quick usage. Always use the handle.
Entity_Ptr :: struct {
    base:    *Base;
    variant: int;
}

Buffer :: struct {
    data: *u8;
    cap:  s32; // In number of values, not bytes!
    top:  s32; // Inclusive index watermark
    free: s32;
}

// Container for all the entities. Initialize with init(), passing the entity
// variant types and the queryable subtype types.
Entities :: struct {
    next_generation: u64 = 1; // Never reset by clear; fail before wraparound.
    val_types: [] Type;
    sub_types: [] Type;
    buffers:   [..] Buffer;
    sizes:     [..] s64;
    offsets:   [..] [..] s64;
}

// Index of T in the runtime type list, or -1.
type_index_of :: (types: [] Type, $T: Type) -> int {
    for i: 0..types.count-1 {
        if cast(*Type_Info) types[i] == cast(*Type_Info) T {
            return i;
        }
    }
    return -1;
}

// Byte offset of the member of type Sub inside Struct_Type, or -1.
find_sub_offset :: (struct_type: Type, sub_type: Type) -> s64 {
    info := cast(*Type_Info_Struct) cast(*Type_Info) struct_type;
    for * member: info.members {
        if member.type == cast(*Type_Info) sub_type {
            return member.offset_in_bytes;
        }
    }
    return -1;
}

init :: (ents: *Entities, val_types: [] Type, sub_types: [] Type, specific_cap: [] int = .[], default_cap := 4096) {
    assert(val_types.count <= 0x7fffffff, "Too many entity variants");
    ents.val_types = val_types;
    ents.sub_types = sub_types;

    array_reset(*ents.buffers);
    array_reset(*ents.sizes);
    array_reset(*ents.offsets);

    for i: 0..val_types.count-1 {
        size := (cast(*Type_Info) val_types[i]).runtime_size;
        array_add(*ents.sizes, size);

        cap := 0;
        if i < specific_cap.count {
            cap = specific_cap[i];
        }
        if cap == 0 {
            cap = default_cap;
        }
        assert(cap >= 2 && cap <= 0x7fffffff, "Entity capacity must fit in signed buffer indices (including dummy slot)");
        assert(find_sub_offset(val_types[i], Base) == 0, "Entity Base must be the first field");
        data := alloc(cast(s64) cap * size);
        array_add(*ents.buffers, .{ data = cast(*u8) data, cap = cast(s32) cap, top = 0, free = 0 });
    }

    for s: 0..sub_types.count-1 {
        row: [..] s64;
        for v: 0..val_types.count-1 {
            array_add(*row, find_sub_offset(val_types[v], sub_types[s]));
        }
        array_add(*ents.offsets, row);
    }
}

// Frees buffers and clears the entire container.
shutdown :: (ents: *Entities) {
    for buf: ents.buffers {
        free(buf.data);
    }
    array_free(ents.buffers);
    array_free(ents.sizes);
    for row: ents.offsets {
        array_free(row);
    }
    array_free(ents.offsets);
    <<ents = Entities.{};
}

clear :: (ents: *Entities) {
    for * buf, v: ents.buffers {
        // The container's monotonic next_generation survives clear.
        for i: 1..buf.top {
            base := cast(*Base) (buf.data + cast(s64) i * ents.sizes[v]);
            if base.handle.index != 0 {
                base.handle = .{};
            }
            base._next_free = 0;
        }
        buf.top = 0;
        buf.free = 0;
    }
}

create_empty :: (ents: *Entities, variant_index: int) -> (*Base, s32, bool) {
    buf := *ents.buffers[variant_index];

    index := buf.free;
    result := cast(*Base) (buf.data + cast(s64) index * ents.sizes[variant_index]);

    if index > 0 && index < buf.cap {
        buf.free = cast(s32) result._next_free;
    } else if buf.top >= (buf.cap - 1) {
        return null, -1, false;
    } else {
        buf.top += 1;
        index = buf.top;
        result = cast(*Base) (buf.data + cast(s64) index * ents.sizes[variant_index]);
    }

    return result, index, true;
}

// Create an entity from a concrete variant value.
create :: (ents: *Entities, val: $Val) -> (Handle, bool) {
    if ents.next_generation == 0 || ents.next_generation == 0xffffffffffffffff return .{}, false;
    variant_index := type_index_of(ents.val_types, Val);
    if variant_index < 0 return .{}, false;
    base, index, ok := create_empty(ents, variant_index);
    if !ok {
        zero: Handle;
        return zero, false;
    }

    result := Handle.{ index = cast(Handle_Index) index, gen = ents.next_generation, variant = cast(Handle_Variant) variant_index };
    ents.next_generation += 1;

    <<(cast(*Val) base) = val;
    base.handle = result;
    base._next_free = 0;

    return result, true;
}

destroy :: (ents: *Entities, handle: Handle) -> bool {
    if cast(s64) handle.variant >= ents.val_types.count {
        return false;
    }

    buf := *ents.buffers[handle.variant];

    if handle.index == 0 || cast(s64) handle.index > buf.top {
        return false;
    }

    base := cast(*Base) (buf.data + cast(s64) handle.index * ents.sizes[handle.variant]);

    if !(handle == base.handle) {
        return false;
    }

    base.handle = .{};
    base._next_free = cast(Handle_Index) buf.free;
    buf.free = cast(s32) handle.index;

    return true;
}

get :: (ents: *Entities, handle: Handle) -> (Entity_Ptr, bool) {
    if cast(s64) handle.variant >= ents.val_types.count {
        zero: Entity_Ptr;
        return zero, false;
    }

    buf := ents.buffers[handle.variant];

    if handle.index == 0 || cast(s64) handle.index > buf.top {
        zero: Entity_Ptr;
        return zero, false;
    }

    base := cast(*Base) (buf.data + cast(s64) handle.index * ents.sizes[handle.variant]);

    if !(handle == base.handle) {
        zero: Entity_Ptr;
        return zero, false;
    }

    return .{ base = base, variant = cast(int) handle.variant }, true;
}

get_sub :: (ents: *Entities, handle: Handle, $Sub: Type) -> (*Sub, bool) {
    entity, valid := get(ents, handle);
    if !valid return null, false;
    sub_index := type_index_of(ents.sub_types, Sub);
    if sub_index < 0 return null, false;
    offset := ents.offsets[sub_index][handle.variant];

    if offset == -1 {
        return null, false;
    }

    ptr := cast(*u8) entity.base + offset;
    return cast(*Sub) ptr, true;
}

// Returns the high-water storage range, skipping dummy slot 0. It includes
// destroyed slots: filter base.handle.index != 0 unless the dataset is dense.
get_buffer :: (ents: *Entities, $Val: Type) -> [] Val {
    val_index := type_index_of(ents.val_types, Val);
    buf := ents.buffers[val_index];

    result: [] Val;
    result.data = cast(*Val) (buf.data + ents.sizes[val_index]);
    result.count = cast(s64) buf.top;
    return result;
}

// --- Iteration ---

Iter_Val :: struct(Val: Type) {
    val: *Val;
    end: *Val;
}

begin_val :: (ents: *Entities, $Val: Type) -> Iter_Val(Val) {
    val_index := type_index_of(ents.val_types, Val);
    buf := ents.buffers[val_index];
    return .{ val = cast(*Val) buf.data, end = cast(*Val) (buf.data + cast(s64) buf.top * size_of(Val)) };
}

next_val :: (it: *Iter_Val($Val)) -> (*Val, bool) {
    while true {
        it.val = cast(*Val) (cast(*u8) it.val + size_of(Val));
        if cast(*u8) it.val > cast(*u8) it.end {
            break;
        }
        if it.val.base.handle.index != 0 {
            return it.val, true;
        }
    }
    return null, false;
}

// The handle isn't exposed directly, but it's stored in the iterator through
// the base pointer.
Iter_Sub :: struct(Sub: Type) {
    ents:      *Entities;
    ptr:       *Base;
    step:      s64;
    offset:    s64;
    end:       *Base;
    variant:   int;
    sub_index: int;
}

begin_sub :: (ents: *Entities, $Sub: Type) -> Iter_Sub(Sub) {
    result: Iter_Sub(Sub);
    result.ents = ents;
    result.variant = -1;
    result.sub_index = type_index_of(ents.sub_types, Sub);
    _iter_sub_next_variant(*result);
    return result;
}

// Returns a *void; cast it back to *Sub on the call site.
next_sub :: (it: *$It/Iter_Sub) -> (*void, bool) {
    while true {
        it.ptr = cast(*Base) (cast(*u8) it.ptr + it.step);
        if cast(*u8) it.ptr > cast(*u8) it.end {
            if !_iter_sub_next_variant(it) {
                return null, false;
            }
            continue;
        }
        if it.ptr.handle.index != 0 {
            return cast(*void) (cast(*u8) it.ptr + it.offset), true;
        }
    }
    return null, false;
}

_iter_sub_next_variant :: (it: *$It/Iter_Sub) -> bool {
    offsets := it.ents.offsets[it.sub_index];

    it.variant += 1;
    ok := false;
    while it.variant < it.ents.val_types.count {
        if offsets[it.variant] != -1 {
            ok = true;
            break;
        }
        it.variant += 1;
    }

    if !ok {
        return false;
    }

    offset := offsets[it.variant];
    size := it.ents.sizes[it.variant];
    buf := it.ents.buffers[it.variant];

    it.ptr = cast(*Base) buf.data;
    it.step = size;
    it.offset = offset;
    it.end = cast(*Base) (buf.data + cast(s64) buf.top * size);

    return true;
}
