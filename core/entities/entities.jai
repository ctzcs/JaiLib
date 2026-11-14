// entities.jai —— 轻量实体容器（每个 variant 一个自由链表池）。
// 一比一移植自 olib core/entities/entities.odin（d3943f1，550 行；上游 ravn
// entities 864cccb + olib 本地修正）。公开名、参数顺序、返回语义、句柄校验
// （destroy/reuse 后旧句柄失效、get_sub 先查 variant/范围/代数再给指针）全部照搬；
// 注释也是 olib 的中文注释原文，仅在语言差异处补一行说明。
//
// ==== Jai 侧差异（都是语言层面的；行为、断言语义不变）====
//  1) 无 union 运行时 tag。olib 的 Entities($Val_Union, $Sub_Union) 用编译期 union
//     顺序生成 variant 下标（UNION_LEN / UNION_HAS / UNION_INDEX /
//     type_union_tag_offset …）。Jai 没有等价物，这里沿用旧实现
//     （Libs/Engine/entities）的 Variant 方案：
//       • Entities 携带 val_types / sub_types 两个运行时 Type 列表，由 init 传入；
//       • variant 下标 = 类型在 val_types 中的位置（type_index_of）；
//       • sub 下标 = 类型在 sub_types 中的位置；
//       • 偏移表 offsets[sub][variant] 在 init 时用运行期反射
//         （Type_Info_Struct.members 的 type/offset_in_bytes）一次建好，-1 表示
//         该 variant 不含此子结构。
//     因此 olib 的编译期约束（UNION_HAS / UNION_LEN）在这里降级为运行期 false：
//     create / get_sub / reserve / begin_* 传未注册类型时返回 (零值, false)，不 panic。
//  2) Entity_Ptr 不是 #raw_union：改成 { base: *Base; variant: int }。
//     olib 的 ptr.variant.(^Foo) 在这里写成 (cast(*Foo) ptr.base)；
//     ptr.variant 保留为 int，调用方可据此判断实际 variant。
//  3) create_val 无对应物（它靠 union tag 反查 variant 下标）。泛型 create 直接按
//     $Val 查表，语义等于 olib 的 create_sub；create_val 的“tag 无效 / 未注册”
//     失败分支由同一个 create 承担（见 Tests/core/entities/entities_test.jai）。
//  4) olib 的 create / get / begin / next 是重载集合，Jai 不能重载：公开为
//     create、get、begin_val / begin_sub、next_val / next_sub（旧实现已如此）。
//  5) Iter_Sub 不带类型参数（olib 的 Iter_Sub(Val_Union, Sub_Union, Sub) 只为编译期
//     约束存在）；next_sub 返回 *void，调用方 cast 回 *Sub。
//     “当前 variant 遍历完”用 ptr == null 表示（olib 用指针越过 end 表达），
//     dummy 槽 0 的跳过顺序完全一致。Jai 没有 uintptr，指针差量字段（step / offset /
//     end）用 u64。
//  6) max(T)（Odin 的类型极值）在 Jai 里是具名常量：Handle_Index_Max /
//     Handle_Gen_Max / Handle_Variant_Max，公开给测试与调用方。
//  7) olib 的 @(private) _capacity_valid / _release_slot / _iter_sub_next_variant
//     按 docs/PORTING.md 加模块前缀：entities_capacity_valid（公开，测试要直接用）/
//     entities_release_slot / entities_iter_sub_next_variant。
//     _extract_variant_index 无对应物（没有 union tag 可提取）。
//  8) 分配分工：实体 buffer 走 ents.allocator（默认 context.allocator），与 olib 一致；
//     而 val_types / sizes / offsets 在 olib 里是内联定长数组，Jai 只能用动态数组，
//     改走 context.allocator —— 这样自定义分配器看到的分配次数和 olib 完全相同
//     （olib 也只对 buffer 调 make / free），_reserve_atomic_test 的计数断言才成立。
//  9) 对齐：olib 用 runtime.make_aligned 按 max(64, align) 对齐 buffer；Jai 的
//     Allocator_Proc 没有 align 参数，这里用分配器默认对齐（context.allocator 为 16）。
//     对齐要求 > 16 的实体类型需要自行给 Entities 传自定义分配器。
// 10) 校验：olib 的 init 检查 variant 的 size 与 align；Jai 的 Type_Info 只暴露
//     runtime_size（没有 align 字段），因此保留 size 检查、放弃 align 检查。
// 11) 清零：Odin 的 make 返回清零内存，Jai 的分配不清零，buffer 分配后显式 memset
//     （否则“从未用过的槽 gen == 0”这类断言会读到垃圾）。
#import "Basic";

//@region 类型 —— Handle / Base / Entity_Ptr / Entities / Buffer

Handle_Index :: u32;
Handle_Gen :: u32;
Handle_Variant :: u8;

// olib 里的 max(Handle_Index) / max(Handle_Gen) / max(Handle_Variant)。
Handle_Index_Max: Handle_Index : 0xFFFF_FFFF;
Handle_Gen_Max: Handle_Gen : 0xFFFF_FFFF;
Handle_Variant_Max: Handle_Variant : 0xFF;

// A handle uniquely identifies an entity.
Handle :: struct {
    index: Handle_Index;
    gen: Handle_Gen;
    variant: Handle_Variant;
}

// olib 的 Handle 比较就是结构体比较；Jai 里显式声明（跨模块仍需在本文件可见，
// 测试文件另有一份具名等价物，见 entities_test.jai 文件头）。
operator == :: (a: Handle, b: Handle) -> bool {
    return a.index == b.index && a.gen == b.gen && a.variant == b.variant;
}

// Base type of each entity, must be the direct first field at offset 0.
// 用法（Odin 的 using base: Base 在 Jai 无等价物，字段名固定为 base，首字段
// 约束与偏移 0 由 init 用反射校验）：
//     My_Entity :: struct { base: Base; /* 其它字段 */ }
Base :: struct {
    handle: Handle; // Self
    _next_free: Handle_Index;
}

// Raw pointer to an entity, exposing the shared base plus the variants.
// Never store this pointer beyond quick usage. Always use the handle.
// olib: #raw_union { using base: ^Base, variant: <pointer union> }
// Jai: 见文件头 2)；variant 是 variant 下标，具体指针用 (cast(*Foo) ptr.base)。
Entity_Ptr :: struct {
    base: *Base;
    variant: int;
}

// Container for all the entities.
// olib 的 Val_Union / Sub_Union 在这里换成运行期类型列表，见文件头 1)。
Entities :: struct {
    buffers: [..] Buffer;
    sizes: [..] s64;
    offsets: [..][..] s64;
    allocator: Allocator;
    val_types: [] Type; // olib 没有（编译期 union 代替）；本轮新增，init 写入
    sub_types: [] Type; // 同上
}

Buffer :: struct {
    data: *u8;
    cap: s32; // 包括保留槽 0，以实体数量计费，不是字节数。
    top: s32; // 已使用槽的最高水位；clear 不回退，保持容量。
    free: s32;
    retired: s32; // 代数耗尽的槽永久占用容量，不进入 free list。
}
//@endregion

//@region 内部辅助 —— 类型目录 / 分配器 / 容量校验

// olib UNION_INDEX / UNION_HAS 的运行期替代：T 在 types 里的下标，-1 表示未注册。
type_index_of :: (types: [] Type, $T: Type) -> int {
    for i: 0..types.count - 1 {
        if cast(*Type_Info) types[i] == cast(*Type_Info) T {
            return i;
        }
    }
    return -1;
}

// 对应 olib init 里的字段搜索：Struct_Type 内第一个 Sub 类型字段的字节偏移，没有则 -1。
find_sub_offset :: (struct_type: Type, sub_type: Type) -> s64 {
    ti := cast(*Type_Info) struct_type;
    if ti.type != .STRUCT return -1;
    si := cast(*Type_Info_Struct) ti;
    for m: si.members {
        if m.type == cast(*Type_Info) sub_type {
            return cast(s64) m.offset_in_bytes;
        }
    }
    return -1;
}

// 分配器解析：olib 的默认实参是 context.allocator，Jai 里空 Allocator 也按默认处理。
entities_allocator :: (allocator: Allocator) -> Allocator {
    resolved := allocator;
    if !resolved.proc resolved = context.allocator;
    return resolved;
}

// capacity 包括槽 0；先限制 i32 槽计数，再检查 int 字节乘法，适用于 32/64 位。
// （olib: @(private) _capacity_valid）
entities_capacity_valid :: (size: s64, capacity: int) -> bool {
    return capacity >= 2 && capacity <= 0x7FFF_FFFF &&
           size > 0 && size <= 0x7FFF_FFFF_FFFF_FFFF / capacity;
}
//@endregion

//@region 生命周期 —— init / shutdown / clear / clone

// caps[i] 覆盖 variant i 的容量（下标 = type_index_of(val_types, T)），缺省用 default_cap。
// 只初始化零值或已 shutdown 的容器；先验证全部类型和容量，再原子安装。失败不改 ents。
// Jai 差异：多出 val_types / sub_types 两个前置参数（见文件头 1)），返回值同 olib 是 bool。
init :: (
    ents: *Entities,
    val_types: [] Type,
    sub_types: [] Type,
    default_cap: int = 4096,
    caps: [] int = .[],
    allocator: Allocator = context.allocator,
) -> bool {
    // olib 的 buffers / sizes / offsets 是内联定长数组，这里只能是动态数组：
    // count 非零同样说明容器已被安装过（照单覆盖会泄漏元数据）。
    if ents.buffers.count != 0 || ents.sizes.count != 0 || ents.offsets.count != 0 return false;
    for buf: ents.buffers {
        if buf.data != null || buf.cap != 0 return false;
    }
    if caps.count > val_types.count return false;
    if val_types.count == 0 || val_types.count > 256 return false; // Handle_Variant 是 u8

    // 1) 只校验，不分配：全部布局与容量验证先于任何分配。
    for i: 0..val_types.count - 1 {
        ti := cast(*Type_Info) val_types[i];
        if ti.type != .STRUCT return false;
        si := cast(*Type_Info_Struct) ti;
        if si.members.count == 0 return false;
        if si.members[0].type != cast(*Type_Info) Base return false;
        if si.members[0].offset_in_bytes != 0 return false;
        size := ti.runtime_size;
        if size < size_of(Base) return false;
        capacity := default_cap;
        if i < caps.count capacity = caps[i];
        if !entities_capacity_valid(cast(s64) size, capacity) return false;
    }

    // 2) 建候选容器；失败时只丢弃候选，ents 保持原样。
    candidate: Entities;
    candidate.allocator = entities_allocator(allocator);
    candidate.val_types = val_types;
    candidate.sub_types = sub_types;

    for i: 0..val_types.count - 1 {
        array_add(*candidate.sizes, cast(s64) (cast(*Type_Info) val_types[i]).runtime_size);
        array_add(*candidate.buffers, Buffer.{});
    }

    // offsets 先全部置 -1，再填实际偏移（olib: candidate.offsets = -1）。
    for s: 0..sub_types.count - 1 {
        row: [..] s64;
        for v: 0..val_types.count - 1 {
            array_add(*row, cast(s64) -1);
        }
        array_add(*candidate.offsets, row);
    }

    for s: 0..sub_types.count - 1 {
        for v: 0..val_types.count - 1 {
            offset := find_sub_offset(val_types[v], sub_types[s]);
            if offset != -1 candidate.offsets[s][v] = offset;
        }
    }

    // 3) 逐个 variant 安装 buffer；任何一个失败就回滚整个候选。
    for i: 0..val_types.count - 1 {
        capacity := default_cap;
        if i < caps.count capacity = caps[i];
        if !reserve_variant(*candidate, cast(Handle_Variant) i, capacity) {
            shutdown(*candidate);
            return false;
        }
    }

    <<ents = candidate;
    return true;
}

// 只增长，不在 create 内自动调用。调用方先做预算，并禁止在任何遍历期间 reserve。
// 成功保留句柄，但旧指针/切片/迭代器失效；只转移字节，不析构或复制用户指针字段。
reserve :: (ents: *Entities, $Val: Type, capacity: int) -> bool {
    variant_index := type_index_of(ents.val_types, Val);
    if variant_index < 0 return false;
    return reserve_variant(ents, cast(Handle_Variant) variant_index, capacity);
}

// 类型目录入口；单个 buffer 原子安装，分配失败保持旧 buffer 和全部句柄不变。
reserve_variant :: (ents: *Entities, variant: Handle_Variant, capacity: int) -> bool {
    if cast(int) variant >= ents.buffers.count return false;
    buf := *ents.buffers[cast(int) variant];
    size := ents.sizes[cast(int) variant];
    if !entities_capacity_valid(size, capacity) return false;
    if capacity <= cast(int) buf.cap return true;

    allocator := entities_allocator(ents.allocator);
    new_size := cast(s64) capacity * size;
    memory := allocator.proc(.ALLOCATE, new_size, 0, null, allocator.data);
    if memory == null return false; // 失败时旧 buffer 与全部句柄不变
    memset(memory, 0, new_size); // Odin 的 make 清零；Jai 的分配不清零（文件头 11）

    if buf.data != null {
        memcpy(memory, buf.data, (cast(s64) buf.top + 1) * size);
        allocator.proc(.FREE, 0, cast(s64) buf.cap * size, buf.data, allocator.data);
    }
    buf.data = cast(*u8) memory;
    buf.cap = cast(s32) capacity;
    return true;
}

// 只释放池 buffer 并归零，不递归释放实体中的用户资源；调用方先处理业务所有权。
// shutdown 结束容器生命周期，旧句柄不得用于重新 init 的容器。
shutdown :: (ents: *Entities) {
    allocator := entities_allocator(ents.allocator);
    for *buf, i: ents.buffers {
        if buf.data != null {
            allocator.proc(.FREE, 0, cast(s64) buf.cap * ents.sizes[i], buf.data, allocator.data);
        }
    }
    array_free(ents.buffers);
    array_free(ents.sizes);
    for row: ents.offsets array_free(row);
    array_free(ents.offsets);
    <<ents = Entities.{};
}

// 失效所有存活句柄；保留水位/代数，重建 free list，不重复推进空槽或复活退休槽。
// 与 destroy/shutdown 一样，不递归释放用户字段。
clear :: (ents: *Entities) {
    for *buf, var_index: ents.buffers {
        buf.free = 0;
        i := buf.top;
        while i > 0 {
            base := cast(*Base) (buf.data + cast(s64) i * ents.sizes[var_index]);
            if base.handle.index != 0 {
                entities_release_slot(buf, base, i);
            } else if base._next_free != Handle_Index_Max {
                base._next_free = cast(Handle_Index) buf.free;
                buf.free = i;
            }
            i -= 1;
        }
    }
}

// Deep copy with the same capacities; handles of the source stay valid in the clone.
// Entities must not own heap data that needs its own copy (the buffers are copied bytewise).
clone :: (src: *Entities, allocator: Allocator = context.allocator) -> Entities {
    caps: [..] int;
    defer array_free(caps);
    for buf: src.buffers array_add(*caps, cast(int) buf.cap);

    result: Entities;
    if !init(*result, src.val_types, src.sub_types, 4096, caps, allocator) {
        return Entities.{};
    }

    for i: 0..src.buffers.count - 1 {
        src_buf := src.buffers[i];
        dst_buf := *result.buffers[i];

        dst_buf.top = src_buf.top;
        dst_buf.free = src_buf.free;
        dst_buf.retired = src_buf.retired;

        elements_to_copy := cast(s64) src_buf.top + 1;
        if elements_to_copy > 0 && result.sizes[i] > 0 {
            memcpy(dst_buf.data, src_buf.data, elements_to_copy * result.sizes[i]);
        }
    }

    return result;
}
//@endregion

//@region 创建与销毁 —— create / destroy

// olib 的 create 是 {create_val, create_sub} 重载集合；Jai 不能重载，
// 这里就是 create_sub 的语义（按 $Val 查 val_types 得 variant 下标）。
// 失败（未注册类型 / 池满 / 引用已 shutdown 或未 init 的容器）返回 (零句柄, false)。
create :: (ents: *Entities, val: $Val) -> (Handle, bool) {
    variant_index := type_index_of(ents.val_types, Val);
    base, index, ok := entities_create_empty(ents, variant_index);
    if !ok return Handle.{}, false;

    // 槽位的代数在写入实体值之前读取：写入会覆盖 base.handle。
    gen := base.handle.gen;
    result := Handle.{
        index = cast(Handle_Index) index,
        gen = gen,
        variant = cast(Handle_Variant) variant_index,
    };

    <<(cast(*Val) base) = val;
    base.handle = result;
    base._next_free = 0;

    return result, true;
}

// 从 free list 或水位尾部取一个槽位（不清零、不写实体值）。
entities_create_empty :: (ents: *Entities, variant_index: int) -> (*Base, s32, bool) {
    if variant_index < 0 || variant_index >= ents.buffers.count return null, -1, false;
    buf := *ents.buffers[variant_index];
    if buf.data == null || buf.cap < 2 return null, -1, false;

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

// 最大代数的存活槽销毁后退休；最大代数的空闲槽仍可进行最后一次分配。
// （olib: @(private) _release_slot）
entities_release_slot :: (buf: *Buffer, base: *Base, index: s32) {
    base.handle.index = 0;
    base.handle.variant = Handle_Variant_Max;
    if base.handle.gen == Handle_Gen_Max {
        base._next_free = Handle_Index_Max;
        buf.retired += 1;
        return;
    }
    base.handle.gen += 1;
    base._next_free = cast(Handle_Index) buf.free;
    buf.free = index;
}

destroy :: (ents: *Entities, handle: Handle) -> bool {
    buf, ok := get_buffer(ents, handle.variant);
    if !ok return false;
    base, base_ok := get_entity_base(ents.*, buf.*, handle);
    if !base_ok return false;
    if !(handle == base.handle) {
        return false;
    }

    entities_release_slot(buf, base, cast(s32) handle.index);
    return true;
}
//@endregion

//@region 查询 —— get / get_sub / get_values / get_buffer / available_slots / get_entity_base

get :: (ents: *Entities, handle: Handle) -> (Entity_Ptr, bool) {
    buf, buf_ok := get_buffer(ents, handle.variant);
    if !buf_ok return Entity_Ptr.{}, false;
    base, base_ok := get_entity_base(ents.*, buf.*, handle);
    if !base_ok return Entity_Ptr.{}, false;
    if !(handle == base.handle) {
        return Entity_Ptr.{}, false;
    }

    return Entity_Ptr.{ base = base, variant = cast(int) handle.variant }, true;
}

// Returns null, false for stale or out-of-range handles, and for variants without that subtype.
// olib 用 UNION_HAS(Sub_Union, Sub) 在编译期拦下未注册的 Sub；Jai 只能运行期返回 false。
get_sub :: (ents: *Entities, handle: Handle, $Sub: Type) -> (*Sub, bool) {
    buf, buf_ok := get_buffer(ents, handle.variant);
    if !buf_ok return null, false;
    sub_index := type_index_of(ents.sub_types, Sub);
    if sub_index < 0 return null, false;
    offset := ents.offsets[sub_index][cast(int) handle.variant];
    if offset == -1 {
        return null, false;
    }

    // olib: 上游这里丢了 ok 结果，会编译不过并解引用 nil；这里照 olib 修正版校验句柄。
    base, base_ok := get_entity_base(ents.*, buf.*, handle);
    if !base_ok return null, false;
    if !(handle == base.handle) {
        return null, false;
    }

    return cast(*Sub) (cast(*u8) base + offset), true;
}

// All slots of one variant, including destroyed ones (their handle.index is 0).
get_values :: (ents: Entities, $Val: Type) -> [] Val {
    variant_index := type_index_of(ents.val_types, Val);
    if variant_index < 0 return .[];
    buf := ents.buffers[variant_index];
    if buf.data == null return .[];

    result: [] Val;
    result.data = cast(*Val) (buf.data + size_of(Val)); // 跳过 dummy 槽 0
    result.count = cast(s64) buf.top;
    return result;
}

get_buffer :: (ents: *Entities, variant: Handle_Variant) -> (*Buffer, bool) {
    if cast(int) variant >= ents.buffers.count {
        return null, false;
    }
    return *ents.buffers[cast(int) variant], true;
}

// 纯查询：未使用尾部 + free list，时间复杂度 O(空闲槽数)，不包含永久退休槽。
available_slots :: (ents: *Entities, variant: Handle_Variant) -> int {
    if cast(int) variant >= ents.buffers.count return 0;
    buf := *ents.buffers[cast(int) variant];
    if buf.data == null || buf.cap < 2 return 0;
    count := cast(int) (buf.cap - 1 - buf.top);
    index := buf.free;
    while index != 0 {
        base := cast(*Base) (buf.data + cast(s64) index * ents.sizes[cast(int) variant]);
        count += 1;
        index = cast(s32) base._next_free;
    }
    return count;
}

// Range check only; callers still compare base.handle with the handle to reject stale generations.
get_entity_base :: (ents: Entities, buf: Buffer, handle: Handle) -> (*Base, bool) {
    if cast(int) handle.variant >= ents.buffers.count || buf.data == null || buf.top <= 0 ||
       handle.index == 0 || handle.index > cast(Handle_Index) buf.top ||
       handle.index >= cast(Handle_Index) buf.cap {
        return null, false;
    }
    return cast(*Base) (buf.data + cast(s64) handle.index * ents.sizes[cast(int) handle.variant]), true;
}
//@endregion

//@region 迭代 —— begin / next（Val 与 Sub 两路）

// Usage: for it := begin_val(&s, Val); val, ok := next_val(&it); ok { ... }
// 遍历期间调用方不得 reserve；扩容会使迭代器内部指针失效。
Iter_Val :: struct(Val: Type) {
    val: *Val;
    end: u64;
}

begin_val :: (ents: *Entities, $Val: Type) -> Iter_Val(Val) {
    it: Iter_Val(Val);
    variant_index := type_index_of(ents.val_types, Val);
    if variant_index < 0 return it; // 未注册：val 为 null、end 为 0，next_val 立即结束

    buf := ents.buffers[variant_index];
    it.val = cast(*Val) buf.data;
    it.end = cast(u64) buf.data + cast(u64) buf.top * cast(u64) size_of(Val);
    return it;
}

next_val :: (it: *Iter_Val($Val)) -> (*Val, bool) {
    while true {
        it.val = cast(*Val) (cast(*u8) it.val + size_of(Val));
        if cast(u64) it.val > it.end {
            break;
        }
        base := cast(*Base) it.val;
        if base.handle.index != 0 {
            return it.val, true;
        }
    }
    return null, false;
}

// The handle isn't exposed directly, but it's stored in the iterator through base pointer.
// olib 的 `using ptr: ^Base` 在 Jai 里就是普通字段 ptr（无 using）。
Iter_Sub :: struct {
    ents: *Entities;
    ptr: *Base;
    step: u64;
    offset: u64;
    end: u64;
    variant: int;
    sub_index: int;
}

begin_sub :: (ents: *Entities, $Sub: Type) -> Iter_Sub {
    result: Iter_Sub;
    result.ents = ents;
    result.variant = -1;
    result.sub_index = type_index_of(ents.sub_types, Sub);
    entities_iter_sub_next_variant(*result);
    return result;
}

// 返回 *void；调用方按已知的 Sub 类型 cast 回来（olib 的 next_sub 直接返回 ^Sub）。
next_sub :: (it: *Iter_Sub) -> (*void, bool) {
    while true {
        if it.ptr == null {
            if !entities_iter_sub_next_variant(it) {
                return null, false;
            }
        }
        it.ptr = cast(*Base) (cast(*u8) it.ptr + it.step);
        if cast(u64) it.ptr > it.end {
            it.ptr = null; // 当前 variant 用尽，下一轮切到下一个含 Sub 的 variant
            continue;
        }
        if it.ptr.handle.index != 0 {
            return cast(*void) (cast(*u8) it.ptr + it.offset), true;
        }
    }
    return null, false;
}

// （olib: @(private) _iter_sub_next_variant）
entities_iter_sub_next_variant :: (it: *Iter_Sub) -> bool {
    if it.sub_index < 0 || it.sub_index >= it.ents.sub_types.count return false;
    offsets := it.ents.offsets[it.sub_index];

    it.variant += 1;
    ok := false;
    while it.variant < it.ents.buffers.count {
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
    it.step = cast(u64) size;
    it.offset = cast(u64) offset;
    it.end = cast(u64) buf.data + cast(u64) buf.top * cast(u64) size;

    return true;
}
//@endregion
