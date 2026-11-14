// handle/fixed —— 固定容量的代数句柄池（无堆分配）。
// 一比一移植自 olib core/handle/fixed/fixed.odin（原作者 Karl Zylinski）。
//
// The Pool maps a handle to an item. A handle consists of an index and a
// generation. The item can be any type. Such a handle can be stored as a permanent
// reference, where you'd usually store a pointer. The benefit of handles is that
// you know if some other system has destroyed the object at that index, since the
// generation will then differ.
// 本实现用内嵌固定数组，容器本身不做堆分配；Pool(T, HT, N) 可存 N - 1 个元素。
//
// 用法（包导入别名为 hm）：
//
//     Entity_Handle :: hm.Handle
//     Entity :: struct {
//         handle: Entity_Handle,   // 所有条目都必须带 handle 字段
//         pos:    [2] float,
//     }
//     entities: hm.Pool(Entity, Entity_Handle, 1024)   // 注意 N 太大别放栈上
//     h1, _ := hm.add(*entities, Entity.{ pos = .[5, 7] })
//     if e := hm.get(*entities, h1) e.pos.y = 123
//     hm.remove_handle(*entities, h1)                  // 留下一个空槽
//
// Jai 侧差异（句柄布局、代数、容量、迭代语义不变）：
//   - remove 是 Jai 关键字（循环控制），公开过程改名 remove_handle（同 Libs/Engine/handle 约定）。
//   - add 的 #optional_ok 用 (HT, bool) 表达：容量满时返回零句柄 + false。
//   - reset 用 memset 清零整池，等价于 olib 的 intrinsics.mem_zero（避免大对象栈临时）。
//   - HT 泛型的句柄比较不用 operator ==（Jai 运算符按词法解析，跨模块不可见），
//     改用具名的 fixed_handle_eq；本模块自有的 Handle 另行声明 operator ==。
#import "Basic";

//@region 类型 —— Handle / Pool / Iterator

// add 返回它。把它当作池内条目的长期引用，用 get 解析成指针。
Handle :: struct {
    // items 数组下标。
    idx: u32;

    // get 时会与条目里的 gen 比对，相等才有效；不等说明槽位已被复用。
    gen: u32;
}

operator == :: (a: Handle, b: Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

Pool :: struct(T: Type, HT: Type, N: int) {
    // 每个条目都必须有类型为 HT 的 handle 字段。
    //
    // 0 号永远是 dummy 条目，这样 idx == 0 的 Handle 表示"没有句柄"，
    // 因此实际可用 N - 1 个槽位。
    items: [N] T;

    // items 用到了多少（含 0 号 dummy）。
    num_items: u32;

    // items 里第一个空闲元素的下标；unused_items 在这一位存放再下一个空闲下标。
    // 由 add 使用，初值由 remove 设置。
    next_unused: u32;

    // 某位非零表示 items 中该下标的条目是空闲的，值即下一个空闲下标，
    // 于是串成一条以 next_unused 开头的空闲链表。
    unused_items: [N] u32;

    // 只为快速算出有效条目数。
    num_unused: u32;
}

// 遍历用。用 begin 创建。
Iterator :: struct(T: Type, HT: Type, N: int) {
    m: *Pool(T, HT, N);
    index: u32;
}
//@endregion

//@region 动态数组桥接 / 句柄比较

// 句柄比较的具名重声明（见文件头）。
fixed_handle_eq :: (a: $HT, b: HT) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}
//@endregion

//@region 生命周期 —— reset / delete / clear

// 开始新的生命周期：丢弃全部旧句柄。用 memset 清零整池，避免内嵌数组的大栈临时。
// 可选地销毁存活值。
reset :: (m: *Pool($T, $HT, $N), destroy: (value: *T) = null) {
    clear(m, destroy);
    memset(cast(*void) m, 0, size_of(Pool(T, HT, N)));
}

// 固定池没有堆内存需要释放，所以 delete 等价于 reset。
delete :: (m: *Pool($T, $HT, $N), destroy: (value: *T) = null) {
    reset(m, destroy);
}

// 保留槽位和代数。旧句柄在代数回绕前保持无效。回调不能结构性修改本池。
clear :: (m: *Pool($T, $HT, $N), destroy: (value: *T) = null) {
    for 1..(cast(s64) m.num_items - 1) {
        item := *m.items[it];
        if item.handle.idx != 0 {
            remove_handle(m, item.handle, destroy);
        }
    }
}
//@endregion

//@region 增删 —— add / remove_handle

// 追加一个 T，返回可长期引用的句柄。
//
// next_unused 非零时优先复用该槽位。第二个返回值在池满时为 false。
add :: (m: *Pool($T, $HT, $N), v: T) -> (HT, bool) {
    if m.next_unused != 0 {
        idx := m.next_unused;
        item := *m.items[cast(s64) idx];
        m.next_unused = m.unused_items[cast(s64) idx];
        m.unused_items[cast(s64) idx] = 0;
        gen := item.handle.gen;
        item.* = v;
        item.handle.idx = idx;
        item.handle.gen = gen + 1;
        m.num_unused -= 1;
        return item.handle, true;
    }

    // 0 号永远是 dummy：handle.idx 为 0 表示"没有条目"，所以那一位不能拿来存东西。
    if m.num_items == 0 {
        empty_item: T;
        m.items[0] = empty_item;
        m.num_items += 1;
    }

    if m.num_items == N {
        zero: HT;
        return zero, false;
    }

    item := *m.items[cast(s64) m.num_items];
    item.* = v;
    item.handle.idx = m.num_items;
    item.handle.gen = 1;
    m.num_items += 1;
    return item.handle, true;
}

// 删除一个存活值（可顺带销毁其资源），保留其代数以便复用。回调不能结构性修改本池。
remove_handle :: (m: *Pool($T, $HT, $N), h: HT, destroy: (value: *T) = null) {
    item := get(m, h);
    if item == null {
        return;
    }
    // 先把下标和代数存下来：回调可能把整个值清零，而 Jai 的实参可能按引用传递，
    // 之后再用 h 的字段就读到被回调改过的值了。
    idx := h.idx;
    gen := h.gen;
    if destroy != null {
        destroy(item);
    }
    m.unused_items[cast(s64) idx] = m.next_unused;
    m.next_unused = idx;
    m.num_unused += 1;
    empty_item: T;
    item.* = empty_item;
    item.handle.gen = gen;
}
//@endregion

//@region 查询 —— get / get_value / valid / len / cap

// 把句柄解析成 *T。指针因为用内嵌固定数组而稳定，但不要长期保存：槽位被销毁并复用后，
// 它就指向新的占用者了。长期只存句柄，需要时再解析成指针。
get :: (m: *Pool($T, $HT, $N), h: HT) -> *T {
    if h.idx <= 0 || h.idx >= m.num_items {
        return null;
    }

    item := *m.items[cast(s64) h.idx];
    if fixed_handle_eq(item.handle, h) {
        return item;
    }

    return null;
}

// 返回值的副本以及句柄是否有效。
get_value :: (m: *Pool($T, $HT, $N), h: HT) -> (value: T, ok: bool) {
    item := get(m, h);
    if item != null {
        return item.*, true;
    }
    zero: T;
    return zero, false;
}

// 句柄是否映射到一个有效条目：比对条目里的句柄与该句柄。
valid :: (m: Pool($T, $HT, $N), h: HT) -> bool {
    return h.idx > 0 && h.idx < m.num_items && fixed_handle_eq(m.items[cast(s64) h.idx].handle, h);
}

// 池内有效条目数。
len :: (m: Pool($T, $HT, $N)) -> int {
    if m.num_items == 0 {
        return 0;
    }
    return cast(int) (m.num_items - m.num_unused - 1);
}

// 池最多能容纳的条目数。
cap :: (m: Pool($T, $HT, $N)) -> int {
    return max(N - 1, 0);
}
//@endregion

//@region 迭代 —— begin / next / skip

// 创建迭代器，配合 next 使用。
begin :: (m: *Pool($T, $HT, $N)) -> Iterator(T, HT, N) {
    result: Iterator(T, HT, N);
    result.m = m;
    result.index = 1;
    return result;
}

// 遍历池，跳过空槽（handle.idx == 0 的槽位）。
//
// 用法：it := hm.begin(*my_pool); while true { item, h, ok := hm.next(*it); if !ok break; }
//
// 也可以直接遍历 items，用 skip 判断空槽。
next :: (it: *Iterator($T, $HT, $N)) -> (val: *T, h: HT, cond: bool) {
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

// 不用迭代器时：for item: my_pool.items { if hm.skip(item) continue; ... }
skip :: (e: $T) -> bool {
    return e.handle.idx == 0;
}
//@endregion
