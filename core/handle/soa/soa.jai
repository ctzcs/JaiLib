// handle/soa —— 槽位对齐的 SoA 代数句柄池，实体存储的默认选择。
// 一比一移植自 olib core/handle/soa/soa.odin。
//
// 属性按列存放在 rows（olib 为 #soa[dynamic]T）中，行号就是 handle.idx；删除不搬数据，
// 只清零该行并回收槽位。0 号槽位是 dummy，令零值句柄永远无效。
//
// 指针失效：rows 的列切片和行指针在 add 扩容后失效；行号在删除后不变，
// 但只有句柄能判断该行是否仍属于原实体，跨帧只存句柄。
// 分配：只有 add 和 capture/restore 分配；remove/clear 不分配（add 预留空闲列表容量）。
// 快照：#soa 不能直接 json 编码，用 capture 得到普通切片组成的 Snapshot，
// 它保存全部槽位代数和空闲列表顺序，restore 后旧句柄的有效性与后续复用顺序都与快照前一致。
//
// Jai 侧差异（句柄布局、代数、容量、迭代语义不变）：
//   - Jai 没有 #soa[dynamic]，rows 改为 [..] T（AoS）。olib 的列语法 rows.hp[i] 写作
//     rows[i].hp；行号、空洞、整行清零、迭代跳过空槽的行为完全一致，只是失去列的缓存局部性
//     （Jai 没有列切片，热点循环请自己维护列数组）。
//   - 没有 #optional_allocator_error，分配类过程返回 (…, bool ok)，false 表示失败（等价于
//     olib 的 err != nil），失败时已有元素与池内容保持有效。
//   - olib 的过程集合（remove/clear/reset/delete 的 without_destroy / with_destroy 两版）
//     用 destroy: (row: T) = null 默认参数表达，调用写法不变。
//   - remove 是 Jai 关键字（循环控制），公开过程改名 remove_handle（同 Libs/Engine/handle 约定）。
//   - HT 泛型的句柄比较不用 operator ==：Jai 的运算符按词法解析，跨模块找不到别的模块声明的
//     operator ==。本模块用 soa_handle_eq / soa_handle_is_zero，并为自有 Handle 声明 operator ==。
#import "Basic";

//@region 类型 —— Handle / Pool / Iterator / Snapshot

// 代数句柄。零值（idx=0）永远无效；remove 后同 idx 的旧句柄因 gen 过期失效。
// 业务按实体定义 distinct 类型（Unit_Handle :: distinct soa.Handle）；Jai 没有 distinct，
// 业务侧用 Handle_Type :: Handle 的别名即可（类型安全靠调用方自律）。
Handle :: struct {
    idx: u32;
    gen: u32;
}

operator == :: (a: Handle, b: Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// rows[i] 与 slots[i] 一一对应。存活槽位 slots[i] = {idx = i, gen}；
// 空槽 slots[i] = {idx = 0, gen = 最后一次使用的代数}，复用时 gen + 1。
Pool :: struct(T: Type, HT: Type) {
    rows: [..] T; // olib: #soa[dynamic]T，见文件头的 Jai 差异
    slots: [..] HT;
    freelist: [..] u32;
    num: int;
}

Iterator :: struct(T: Type, HT: Type) {
    pool: *Pool(T, HT);
    index: int;
}

// 普通切片组成的快照，可直接存盘 / 拷贝；用 snapshot_delete 释放。
Snapshot :: struct(T: Type, HT: Type) {
    slots: [] HT;
    freelist: [] u32;
    rows: [] T;
}
//@endregion

//@region 动态数组桥接（对应 Odin 的 builtin.append/pop/reserve/runtime.delete）

// 对应 Odin 的 reserve：只增不减，失败返回 false（Jai 的 array_reserve 直接断言，不能用来报错）。
// 分配器与 olib 一致：第一次分配时取用 context.allocator，之后沿用数组自带的那一个。
soa_reserve :: (array: *[..] $T, desired: s64) -> bool {
    if desired <= array.allocated return true;
    if !array.allocator.proc array.allocator = context.allocator;
    memory := array.allocator.proc(.RESIZE, desired * size_of(T), array.allocated * size_of(T), array.data, array.allocator.data);
    if memory == null return false; // 失败时数组保持原样
    array.data = memory;
    array.allocated = desired;
    return true;
}

// 对应 Odin 的 append。
soa_append :: (array: *[..] $T, value: T) -> bool {
    if array.count >= array.allocated {
        if !soa_reserve(array, max(array.count + 1, max(array.allocated * 2, 8))) return false;
    }
    array.data[array.count] = value;
    array.count += 1;
    return true;
}

// 对应 Odin 的 pop（取尾元素并减一）。
soa_pop :: (array: *[..] $T) -> T {
    result := array.data[array.count - 1];
    array.count -= 1;
    return result;
}

// 对应 runtime.delete（释放并清零）。
soa_free :: (array: *[..] $T) {
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

// 对应 runtime.clear（保留内存，只把长度归零）。
soa_clear_keep_memory :: (array: *[..] $T) {
    array.count = 0;
}

// 句柄比较的具名重声明：HT 由调用方提供，Jai 的 operator == 跨模块不可见，只能用字段比较。
soa_handle_eq :: (a: $HT, b: HT) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// 零值句柄判定（等价于 Odin 的 h == {}）。
soa_handle_is_zero :: (h: $HT) -> bool {
    return h.idx == 0 && h.gen == 0;
}

// 分配器解析：olib 的默认实参是 context.allocator；Jai 的形参不可赋值，用这个具名辅助。
soa_allocator :: (allocator: Allocator) -> Allocator {
    resolved := allocator;
    if !resolved.proc resolved = context.allocator;
    return resolved;
}

// 对应 Odin 的 make([]T, n, allocator)，返回 (切片, 是否成功)。
soa_make_slice :: ($T: Type, count: s64, allocator: Allocator) -> ([] T, bool) {
    result: [] T;
    if count <= 0 return result, true;
    alloc := soa_allocator(allocator);
    memory := alloc.proc(.ALLOCATE, count * size_of(T), 0, null, alloc.data);
    if memory == null return result, false;
    result.data = cast(*T) memory;
    result.count = count;
    return result, true;
}

// 对应 runtime.delete(切片)。
soa_delete_slice :: ($T: Type, slice: [] T, allocator: Allocator) {
    if !slice.data return;
    alloc := soa_allocator(allocator);
    alloc.proc(.FREE, 0, slice.count * size_of(T), slice.data, alloc.data);
}
//@endregion

//@region 增删 —— add 与 remove_handle

// 整行写入一个新实体并返回句柄；优先复用空闲槽位（gen 递增）。
add :: (p: *Pool($T, $HT), row: T) -> (HT, bool) {
    if p.freelist.count > 0 {
        idx := soa_pop(*p.freelist);
        h: HT;
        h.idx = idx;
        h.gen = p.slots[cast(s64) idx].gen + 1;
        p.slots[cast(s64) idx] = h;
        p.rows[cast(s64) idx] = row;
        p.num += 1;
        return h, true;
    }

    needed := max(p.slots.count, 1) + 1;
    // 先预留再发布槽位，remove 和 clear 因此不分配。
    if p.freelist.allocated < needed - 1 {
        if !soa_reserve(*p.freelist, max(needed - 1, max(2 * p.freelist.allocated, 8))) {
            zero: HT;
            return zero, false;
        }
    }
    if p.slots.allocated < needed {
        if !soa_reserve(*p.slots, max(needed, max(2 * p.slots.allocated, 8))) {
            zero: HT;
            return zero, false;
        }
    }
    if p.rows.allocated < needed {
        if !soa_reserve(*p.rows, max(needed, max(2 * p.rows.allocated, 8))) {
            zero: HT;
            return zero, false;
        }
    }
    if p.slots.count == 0 {
        dummy: HT; // 0 号为 dummy
        if !soa_append(*p.slots, dummy) {
            zero: HT;
            return zero, false;
        }
        empty_row: T;
        if !soa_append(*p.rows, empty_row) {
            zero: HT;
            return zero, false;
        }
    }

    h: HT;
    h.idx = cast(u32) p.slots.count;
    h.gen = 1;
    if !soa_append(*p.slots, h) {
        zero: HT;
        return zero, false;
    }
    if !soa_append(*p.rows, row) {
        zero: HT;
        return zero, false;
    }
    p.num += 1;
    return h, true;
}

// 按句柄删除（过期句柄是安全无操作）。destroy 收到该行的副本，用于释放行内堆数据。
// olib: remove(p, h) / remove(p, h, destroy)。
remove_handle :: (p: *Pool($T, $HT), h: HT, destroy: (row: T) = null) {
    if !valid(p.*, h) {
        return;
    }
    // 先把下标和代数固定成局部量：destroy 可能清空整行，而 Jai 的实参可能按引用传递，
    // 之后再用 h 的字段就读到被回调改过的值了（与 olib"回调可能清零整个值"的注释同理）。
    h_idx := h.idx;
    h_gen := h.gen;
    if destroy != null {
        destroy(p.rows[cast(s64) h_idx]);
    }
    soa_append(*p.freelist, h_idx);
    empty_handle: HT;
    empty_handle.gen = h_gen;
    p.slots[cast(s64) h_idx] = empty_handle;
    empty_row: T;
    p.rows[cast(s64) h_idx] = empty_row;
    p.num -= 1;
}
//@endregion

//@region 清理 —— clear / reset / delete

// 删除全部存活实体，保留槽位、代数和容量；旧句柄在代数回绕前保持无效。不分配。
// destroy 不能结构性修改本池。
clear :: (p: *Pool($T, $HT), destroy: (row: T) = null) {
    for 1..(p.slots.count - 1) {
        i := it;
        h := p.slots[i];
        if h.idx != 0 {
            remove_handle(p, h, destroy);
        }
    }
}

// 开始新的生命周期并保留容量；调用方必须丢弃全部旧句柄。
reset :: (p: *Pool($T, $HT), destroy: (row: T) = null) {
    soa_destroy_live(p, destroy);
    soa_clear_keep_memory(*p.slots);
    soa_clear_keep_memory(*p.freelist);
    soa_clear_keep_memory(*p.rows);
    p.num = 0;
}

// 释放全部内存并清零池；行内有堆数据时传 destroy 逐项清理。
delete :: (p: *Pool($T, $HT), destroy: (row: T) = null) {
    soa_destroy_live(p, destroy);
    soa_free(*p.slots);
    soa_free(*p.freelist);
    soa_free(*p.rows);
    z: Pool(T, HT);
    p.* = z;
}

soa_destroy_live :: (p: *Pool($T, $HT), destroy: (row: T)) {
    if destroy == null {
        return;
    }
    for 1..(p.slots.count - 1) {
        i := it;
        if p.slots[i].idx != 0 {
            destroy(p.rows[i]);
        }
    }
}
//@endregion

//@region 查询 —— valid / row / len / cap

valid :: (p: Pool($T, $HT), h: HT) -> bool {
    return h.idx > 0 && cast(s64) h.idx < p.slots.count && soa_handle_eq(p.slots[cast(s64) h.idx], h);
}

// 句柄 → 行号；句柄无效时 ok 为 false。行号只在当前操作内使用。
row :: (p: Pool($T, $HT), h: HT) -> (index: int, ok: bool) {
    if !valid(p, h) {
        return 0, false;
    }
    return cast(int) h.idx, true;
}

len :: (p: Pool($T, $HT)) -> int {
    return p.num;
}

// 不扩容时最多能容纳的存活实体数。
cap :: (p: Pool($T, $HT)) -> int {
    return max(cast(int) p.slots.allocated - 1, 0);
}
//@endregion

//@region 迭代 —— begin / next

// 用法：it := begin(*pool); while true { i, h, ok := next(*it); if !ok break; pool.rows[i].hp ... }
// 遍历期间可以 remove 当前元素（槽位对齐不搬数据、不分配）；不能 add，也不能删除其他元素。
begin :: (p: *Pool($T, $HT)) -> Iterator(T, HT) {
    result: Iterator(T, HT);
    result.pool = p;
    result.index = 1;
    return result;
}

next :: (it: *Iterator($T, $HT)) -> (index: int, handle: HT, ok: bool) {
    while it.index < it.pool.slots.count {
        i := it.index;
        it.index += 1;
        h := it.pool.slots[i];
        if h.idx != 0 {
            return i, h, true;
        }
    }
    zero: HT;
    return 0, zero, false;
}
//@endregion

//@region 快照 —— capture / restore / snapshot_delete

// 复制全部槽位（含空槽的代数）、空闲列表顺序和行数据。
capture :: (p: Pool($T, $HT), allocator: Allocator = Allocator.{}) -> (s: Snapshot(T, HT), ok: bool) {
    alloc := soa_allocator(allocator);
    n := p.slots.count;
    s.slots, ok = soa_make_slice(HT, n, alloc);
    if !ok return s, false;
    s.freelist, ok = soa_make_slice(u32, p.freelist.count, alloc);
    if !ok return s, false;
    s.rows, ok = soa_make_slice(T, n, alloc);
    if !ok return s, false;
    for 0..(n - 1) {
        s.slots[it] = p.slots[it];
        s.rows[it] = p.rows[it];
    }
    for 0..(p.freelist.count - 1) {
        s.freelist[it] = p.freelist[it];
    }
    return s, true;
}

// 用快照替换池内容。快照不一致或分配失败时返回 false，池保持原样。
// 成功时先按 destroy 规则丢弃旧内容（行内堆数据由调用方另行处理），快照本身不被占用。
restore :: (p: *Pool($T, $HT), s: Snapshot(T, HT), allocator: Allocator = Allocator.{}) -> bool {
    if !snapshot_valid(s) {
        return false;
    }
    alloc := soa_allocator(allocator);
    n := s.slots.count;

    fresh: Pool(T, HT);
    ok := false;
    defer {
        if !ok {
            soa_free(*fresh.slots);
            soa_free(*fresh.freelist);
            soa_free(*fresh.rows);
        }
    }
    fresh.slots.allocator = alloc;
    fresh.freelist.allocator = alloc;
    fresh.rows.allocator = alloc;
    // 与 add 相同：空闲列表预留到 n - 1，后续 remove 不分配。
    if !soa_reserve(*fresh.slots, n) return false;
    if !soa_reserve(*fresh.freelist, max(n - 1, 0)) return false;
    if !soa_reserve(*fresh.rows, n) return false;
    for 0..(n - 1) {
        soa_append(*fresh.slots, s.slots[it]);
        soa_append(*fresh.rows, s.rows[it]);
        if s.slots[it].idx != 0 {
            fresh.num += 1;
        }
    }
    for 0..(s.freelist.count - 1) {
        soa_append(*fresh.freelist, s.freelist[it]);
    }

    ok = true;
    delete(p);
    p.* = fresh;
    return true;
}

// 释放 capture 或反序列化得到的快照切片。
snapshot_delete :: (s: Snapshot($T, $HT), allocator: Allocator = Allocator.{}) {
    alloc := soa_allocator(allocator);
    soa_delete_slice(HT, s.slots, alloc);
    soa_delete_slice(u32, s.freelist, alloc);
    soa_delete_slice(T, s.rows, alloc);
}

// 检查快照内部一致：长度对齐、0 号为 dummy、存活槽位 idx 等于下标、
// 空闲列表恰好覆盖全部空槽且不重复。空快照（从未 add 过）合法。
snapshot_valid :: (s: Snapshot($T, $HT)) -> bool {
    n := s.slots.count;
    if s.rows.count != n {
        return false;
    }
    if n == 0 {
        return s.freelist.count == 0;
    }
    if !soa_handle_is_zero(s.slots[0]) {
        return false;
    }
    free_count := 0;
    for 1..(n - 1) {
        h := s.slots[it];
        if h.idx == 0 {
            free_count += 1;
        } else if cast(s64) h.idx != it || h.gen == 0 {
            return false;
        }
    }
    if s.freelist.count != free_count {
        return false;
    }
    for 0..(s.freelist.count - 1) {
        idx := s.freelist[it];
        if idx == 0 || cast(s64) idx >= n || s.slots[cast(s64) idx].idx != 0 {
            return false;
        }
        // olib: for other in s.freelist[:k]，Jai 的嵌套 for 都用 it，先把外层下标存下来。
        k := it;
        for 0..(k - 1) {
            if s.freelist[it] == idx {
                return false;
            }
        }
    }
    return true;
}
//@endregion
