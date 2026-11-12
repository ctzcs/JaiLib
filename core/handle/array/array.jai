// handle/array —— 可扩容的代数句柄池。
// 一比一移植自 olib core/handle/array/array.odin。
//
// Pool 按 slot 存储 value，外部只持有轻量 Handle（idx + gen 代数）：
// 句柄过期（remove 后代数 +1）不会被误认成新条目。0 号 slot 是 dummy，
// 令零值 Handle 永远无效。
//
// Jai 侧差异（句柄布局、代数、容量、迭代语义不变）：
//   - 没有 #optional_allocator_error，add 返回 (句柄, bool)，false 等价于 olib 的
//     err != nil（零句柄 + 已有元素保持有效 + 容量可能已经增加）。
//   - olib 的过程集合（remove/clear/reset/delete 的 without_destroy / with_destroy 两版）
//     用 destroy 默认参数 = null 表达，调用写法不变。
//   - remove 是 Jai 关键字（循环控制），公开过程改名 remove_handle（同 Libs/Engine/handle 约定）。
//   - Jai 的 array_reserve 失败是断言、且内置数组函数同名，故本模块自带
//     handle_array_reserve / handle_array_append 等桥接（语义与 Odin 的 reserve/append 一致）。
//   - HT 泛型的句柄比较不用 operator ==（Jai 运算符按词法解析，跨模块不可见），
//     改用具名的 handle_array_handle_eq；本模块自有的 Handle 另行声明 operator ==。
#import "Basic";

//@region 类型 —— Handle / Slot / Pool / Iterator

// 代数句柄。零值（idx=0）永远无效；remove 后同 idx 的旧句柄因 gen 过期失效。
Handle :: struct {
    idx: u32;
    gen: u32;
}

operator == :: (a: Handle, b: Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// 槽位：value 与其当前有效句柄一起存放，校验即比对 handle。
Slot :: struct (T: Type, HT: Type) {
    value:  T;
    handle: HT;
}

// 可扩容句柄池。slots[0] 为 dummy（见 add）；freelist 回收已删槽位。
Pool :: struct (T: Type, HT: Type) {
    slots:    [..] Slot(T, HT);
    freelist: [..] HT;
    num:      int;
}

Iterator :: struct (T: Type, HT: Type) {
    ha:    *Pool(T, HT);
    index: int;
}

HANDLE_NONE :: Handle.{ };
//@endregion

//@region 动态数组桥接（对应 Odin 的 builtin.append/pop/reserve/runtime.delete）

// 对应 Odin 的 reserve：只增不减，失败返回 false。分配器与 olib 一致：首次分配取
// context.allocator，之后沿用数组自带的那个。
handle_array_reserve :: (array: *[..] $T, desired: s64) -> bool {
    if desired <= array.allocated return true;
    if !array.allocator.proc array.allocator = context.allocator;
    memory := array.allocator.proc(.RESIZE, desired * size_of(T), array.allocated * size_of(T), array.data, array.allocator.data);
    if memory == null return false;
    array.data = memory;
    array.allocated = desired;
    return true;
}

// 对应 Odin 的 append。
handle_array_append :: (array: *[..] $T, value: T) -> bool {
    if array.count >= array.allocated {
        if !handle_array_reserve(array, max(array.count + 1, max(array.allocated * 2, 8))) return false;
    }
    array.data[array.count] = value;
    array.count += 1;
    return true;
}

// 对应 Odin 的 pop。
handle_array_pop :: (array: *[..] $T) -> T {
    result := array.data[array.count - 1];
    array.count -= 1;
    return result;
}

// 对应 runtime.clear（保留内存）。
handle_array_clear :: (array: *[..] $T) {
    array.count = 0;
}

// 对应 runtime.delete（释放并清零）。
handle_array_free :: (array: *[..] $T) {
    if array.data {
        allocator := array.allocator;
        if !allocator.proc allocator = context.allocator;
        allocator.proc(.FREE, 0, array.allocated * size_of(T), array.data, allocator.data);
    }
    array.count = 0;
    array.allocated = 0;
    array.data = null;
    array.allocator = .{};
}

// 句柄比较的具名重声明（见文件头）。
handle_array_handle_eq :: (a: $HT, b: HT) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}
//@endregion

//@region 增删 —— add 与 remove_handle

// 插入一个值并返回其句柄；优先复用 freelist 里的槽位（gen 递增）。
add :: (ha: *Pool($T, $HT), v: T) -> (HT, bool) {
    if ha.freelist.count > 0 {
        h := handle_array_pop(*ha.freelist);
        h.gen += 1;
        ha.slots[cast(s64) h.idx].value  = v;
        ha.slots[cast(s64) h.idx].handle = h;
        ha.num += 1;
        return h, true;
    }

    needed := max(ha.slots.count, 1) + 1;
    // 先预留再发布槽位，remove 和 clear 因此不分配。
    if ha.freelist.allocated < needed - 1 {
        if !handle_array_reserve(*ha.freelist, max(needed - 1, max(2 * ha.freelist.allocated, 8))) { zero: HT; return zero, false; }
    }
    if ha.slots.allocated < needed {
        if !handle_array_reserve(*ha.slots, max(needed, max(2 * ha.slots.allocated, 8))) { zero: HT; return zero, false; }
    }
    if ha.slots.count == 0 {
        dummy: Slot(T, HT);              // 0 索引为 dummy
        if !handle_array_append(*ha.slots, dummy) { zero: HT; return zero, false; }
    }

    h: HT;
    h.idx = cast(u32) ha.slots.count;
    h.gen = 1;

    slot: Slot(T, HT);
    slot.value  = v;
    slot.handle = h;
    if !handle_array_append(*ha.slots, slot) { zero: HT; return zero, false; }
    ha.num += 1;
    return h, true;
}

// 按句柄移除（代数不符的旧句柄是安全无操作）。destroy 先于回收被调用。
// olib: remove(ha, h) / remove(ha, h, destroy)。
remove_handle :: (ha: *Pool($T, $HT), h: HT, destroy: (value: *T) = null) {
    if h.idx > 0 && cast(s64) h.idx < ha.slots.count && handle_array_handle_eq(ha.slots[cast(s64) h.idx].handle, h) {
        // 回调可能清空整个值；Jai 的实参可能按引用传递，先固定要回收的句柄。
        h_removed := h;
        if destroy != null {
            destroy(*ha.slots[cast(s64) h_removed.idx].value);
        }
        handle_array_append(*ha.freelist, h_removed);
        empty_slot: Slot(T, HT);
        ha.slots[cast(s64) h_removed.idx] = empty_slot;
        ha.num -= 1;
    }
}
//@endregion

//@region 清理 —— clear / reset / delete

// 删除全部存活值，保留槽位和代数历史。之后的 add 复用空闲槽位；旧句柄在代数回绕前保持无效。
// clear 期间 freelist 与槽位数组都不分配。destroy 不能结构性修改本池。
clear :: (ha: *Pool($T, $HT), destroy: (value: *T) = null) {
    // 已在 freelist 里的空槽自带代数，这里只追加存活槽位，
    // 因此重复 clear 不会出现重复条目。
    for 1..(ha.slots.count - 1) {
        h := ha.slots[it].handle;
        if h.idx != 0 {
            remove_handle(ha, h, destroy);
        }
    }
}

// 开始新的生命周期并保留已分配容量；调用方必须丢弃全部旧句柄。
reset :: (ha: *Pool($T, $HT), destroy: (value: *T) = null) {
    if destroy != null {
        for 1..(ha.slots.count - 1) {
            if ha.slots[it].handle.idx > 0 {
                destroy(*ha.slots[it].value);
            }
        }
    }
    handle_array_clear(*ha.slots);
    handle_array_clear(*ha.freelist);
    ha.num = 0;
}

// 释放全部内存（池不可再用）；持有资源时传 destroy 先逐项清理。
delete :: (ha: *Pool($T, $HT), destroy: (value: *T) = null) {
    if destroy != null {
        for 1..(ha.slots.count - 1) {
            if ha.slots[it].handle.idx > 0 {
                destroy(*ha.slots[it].value);
            }
        }
    }
    handle_array_free(*ha.slots);
    handle_array_free(*ha.freelist);
    z: Pool(T, HT);
    ha.* = z;
}
//@endregion

//@region 查询 —— get / get_value / valid / len / cap

// 按值取出（无效句柄返回零值 + false）。
get_value :: (ha: Pool($T, $HT), h: HT) -> (val: T, ok: bool) {
    if h.idx > 0 && cast(s64) h.idx < ha.slots.count && handle_array_handle_eq(ha.slots[cast(s64) h.idx].handle, h) {
        return ha.slots[cast(s64) h.idx].value, true;
    }
    zero: T;
    return zero, false;
}

// 取值指针（无效句柄返回 null）。指针在 add/remove 后可能失效。
get :: (ha: Pool($T, $HT), h: HT) -> *T {
    if h.idx > 0 && cast(s64) h.idx < ha.slots.count && handle_array_handle_eq(ha.slots[cast(s64) h.idx].handle, h) {
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

// 不扩容槽位数组时最多能容纳的存活条目数。
cap :: (ha: Pool($T, $HT)) -> int {
    return max(cast(int) ha.slots.allocated - 1, 0);
}
//@endregion

//@region 迭代 —— begin / next

begin :: (ha: *Pool($T, $HT)) -> Iterator(T, HT) {
    result: Iterator(T, HT);
    result.ha = ha;
    result.index = 1;
    return result;
}

// 遍历期间不允许结构性修改。add 可能搬移槽位，使 next 返回的指针失效。
next :: (it: *Iterator($T, $HT)) -> (value: *T, handle: HT, ok: bool) {
    while it.index < it.ha.slots.count {
        index := it.index;
        it.index += 1;

        slot := *it.ha.slots[index];
        if slot.handle.idx != 0 {
            return *slot.value, slot.handle, true;
        }
    }
    zero: HT;
    return null, zero, false;
}
//@endregion
