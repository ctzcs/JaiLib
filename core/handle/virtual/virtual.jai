// handle/virtual —— 用静态虚存 arena 保存条目的代数句柄池（连续存储 + 指针稳定）。
// 一比一移植自 olib core/handle/virtual/virtual.odin（原作者 Karl Zylinski）。
//
// The Pool maps a handle to an item. A handle consists of an index and a
// generation. The item can be any type. Such a handle can be stored as a permanent
// reference, where you'd usually store a pointer. The benefit of storing handles
// instead of pointers is that you know if a slot has been reused, thanks to the
// generation number.
// 本实现是"动态数组 + 一次性预留的 arena"：动态数组的数据分配进 arena，
// 于是创建时就把容量预留好。预留不等于占用：内存只在动态数组真正长进那块空间时才用上。
// 因为数组总是 arena 里最近的一次分配，它可以原地扩容，所以元素指针永不移动。
//
// 用法（包导入别名为 hm）：
//
//     Entity_Handle :: hm.Handle
//     Entity :: struct {
//         handle: Entity_Handle,   // 所有条目都必须带 handle 字段
//         pos:    [2] float,
//     }
//     entities: hm.Pool(Entity, Entity_Handle, 10000)   // Max 只是预留
//     h1, _ := hm.add(*entities, Entity.{ pos = .[5, 7] })
//     if e := hm.get(entities, h1) e.pos.y = 123
//     hm.remove_handle(*entities, h1)                  // 留下一个空槽
//     hm.delete(*entities)
//
// Jai 侧差异（句柄布局、代数、容量、迭代语义不变）：
//   - 没有 vmem 虚存模块：预留区改为一次性 alloc（预留即提交，物理内存会按 Max 计入）；
//     指针稳定性、原地扩容、cap = 预留容量 / size_of(T) 的语义保持不变。
//   - arena 结构体与 olib 一样放在预留区起点，因此 cap 的减法项（size_of(Arena)）一致。
//   - 没有 #optional_allocator_error，make/add 返回 (…, bool)，false 等价于 err != nil；
//     没有 .Out_Of_Memory 可区分，append 失败一律走 olib 的"按 slot_cap 重试"分支。
//   - remove 是 Jai 关键字（循环控制），公开过程改名 remove_handle（同 Libs/Engine/handle 约定）。
//   - HT 泛型的句柄比较不用 operator ==（Jai 运算符按词法解析，跨模块不可见），
//     改用具名的 virtual_handle_eq；本模块自有的 Handle 另行声明 operator ==。
//   - olib 的 loc := #caller_location 形参：Jai 没有调用点信息，相关形参直接省略（不影响语义）。
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

// T 是存进 Pool 的类型；HT 是句柄类型（业务里写作 My_Handle :: Handle）；
// Max 是 Pool 最多能存的条目数——因为用预留内存，可以给一个很大的值，
// 它只决定预留多少地址空间。
Pool :: struct (T: Type, HT: Type, Max: int) {
    // 每个条目都必须有类型为 HT 的 handle 字段。
    // 0 号永远是 dummy 条目，这样 idx == 0 的 Handle 表示"没有句柄"。
    items: [..] T;

    // 容纳 Max 个元素的预留区（结构体本身也在预留区起点）。
    items_arena: *Virtual_Arena;

    // 空闲槽位下标，remove_handle 追加、add 取出。
    unused_items: [..] u32;
}

// 遍历用。用 begin 创建。
Iterator :: struct (T: Type, HT: Type, Max: int) {
    m:     *Pool(T, HT, Max);
    index: int;
}
//@endregion

//@region 静态 arena —— 一次性预留、原地扩容（对应 core:mem/virtual 的 arena_init_static）

// 一次性预留的 arena：bump 分配，永不移动、不单独释放。
Virtual_Arena :: struct {
    base:           *u8;   // 预留区起点（结构体自身也在这里）
    total_reserved: s64;   // 预留字节数
    used:           s64;   // 已 bump 的字节数
}

// arena 结构体占掉的头部大小（按 16 字节对齐）。olib 的 slot_cap 同样要扣掉 arena 结构体本身。
virtual_arena_header_size :: () -> s64 {
    return (size_of(Virtual_Arena) + 15) / 16 * 16;
}

// 预留区理论上能装的槽位数（含 0 号 dummy）。
virtual_slot_cap :: (m: Pool($T, $HT, $Max)) -> int {
    if m.items_arena == null {
        return 0;
    }
    return cast(int) ((m.items_arena.total_reserved - virtual_arena_header_size()) / size_of(T));
}

virtual_arena_allocate :: (arena: *Virtual_Arena, size: s64, alignment: s64) -> *void {
    if size <= 0 return null;
    if alignment < 1 alignment = 1;
    aligned_used := (arena.used + alignment - 1) / alignment * alignment;
    if aligned_used + size > arena.total_reserved return null;
    result := arena.base + aligned_used;
    arena.used = aligned_used + size;
    return cast(*void) result;
}

virtual_arena_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    arena := cast(*Virtual_Arena) allocator_data;
    if mode == .ALLOCATE {
        return virtual_arena_allocate(arena, size, 16);
    }
    if mode == .RESIZE {
        if old_memory == null return virtual_arena_allocate(arena, size, 16);
        // 数组总是预留区里的最近一次分配：只要新的末尾还在预留范围内，就原地扩容。
        offset := cast(s64) (cast(*u8) old_memory - arena.base);
        if offset < 0 || offset + size > arena.total_reserved return null;
        if offset + size > arena.used arena.used = offset + size;
        return old_memory;
    }
    return null;   // 整块回收走 virtual_arena_destroy
}

virtual_arena_allocator :: (arena: *Virtual_Arena) -> Allocator {
    result: Allocator;
    result.proc = virtual_arena_allocator_proc;
    result.data = cast(*void) arena;
    return result;
}

// 预留在 context.allocator 上做（olib 用 vmem 预留，同样不经过 make 的 allocator）。
virtual_arena_init :: (arena: *Virtual_Arena, total_reserved: s64) -> bool {
    allocator := context.allocator;
    memory := allocator.proc(.ALLOCATE, total_reserved, 0, null, allocator.data);
    if memory == null return false;
    arena.base           = cast(*u8) memory;
    arena.total_reserved = total_reserved;
    arena.used           = virtual_arena_header_size();   // 结构体自身占头部
    return true;
}

virtual_arena_destroy :: (arena: *Virtual_Arena) {
    if arena.base == null return;
    allocator := context.allocator;
    allocator.proc(.FREE, 0, arena.total_reserved, arena.base, allocator.data);
    arena.base = null;
    arena.total_reserved = 0;
    arena.used = 0;
}
//@endregion

//@region 动态数组桥接 / 句柄比较

// 分配器解析：olib 的默认实参是 context.allocator；Jai 形参不可赋值，用这个具名辅助。
virtual_allocator :: (allocator: Allocator) -> Allocator {
    resolved := allocator;
    if !resolved.proc resolved = context.allocator;
    return resolved;
}

// 对应 Odin 的 reserve：只增不减，失败返回 false。
virtual_reserve :: (array: *[..] $T, desired: s64) -> bool {
    if desired <= array.allocated return true;
    if !array.allocator.proc array.allocator = context.allocator;
    memory := array.allocator.proc(.RESIZE, desired * size_of(T), array.allocated * size_of(T), array.data, array.allocator.data);
    if memory == null return false;
    array.data = memory;
    array.allocated = desired;
    return true;
}

// 对应 Odin 的 append。
virtual_append :: (array: *[..] $T, value: T) -> bool {
    if array.count >= array.allocated {
        if !virtual_reserve(array, max(array.count + 1, max(array.allocated * 2, 8))) return false;
    }
    array.data[array.count] = value;
    array.count += 1;
    return true;
}

// 对应 runtime.clear（保留内存）。
virtual_clear :: (array: *[..] $T) {
    array.count = 0;
}

// 对应 runtime.delete（释放并清零）。
virtual_free :: (array: *[..] $T) {
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
virtual_handle_eq :: (a: $HT, b: HT) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}
//@endregion

//@region 生命周期 —— make / delete / reset / clear

// 通常直接声明 `hm: Pool(Item_Type, Handle_Type, 10000)`；想自己指定 unused_items 的分配器时，
// 改成 `hm, ok := hm.make(Item_Type, Handle_Type, 10000, some_allocator)`。
make :: ($T: Type, $HT: Type, $Max: int, allocator: Allocator = Allocator.{}) -> (Pool(T, HT, Max), bool) {
    result: Pool(T, HT, Max);
    alloc := virtual_allocator(allocator);

    // 与 olib 一致：预留 (Max + 1) * size_of(T) + size_of(Arena)，arena 结构体放在预留区里。
    arena := New(Virtual_Arena);
    if arena == null return result, false;
    total := (Max + 1) * size_of(T) + virtual_arena_header_size();
    if !virtual_arena_init(arena, total) {
        free(arena);
        return result, false;
    }

    result.items_arena = arena;
    result.items.allocator = virtual_arena_allocator(arena);
    result.unused_items.allocator = alloc;
    return result, true;
}

// 按需销毁存活值、释放容器内存并清零 Pool。
delete :: (m: *Pool($T, $HT, $Max), destroy: (value: *T) = null) {
    clear(m, destroy);
    if m.items_arena != null {
        virtual_arena_destroy(m.items_arena);
        free(m.items_arena);
    }
    // items 的数据在预留区里，随预留区一起归还，这里只清掉结构体本身。
    m.items.count = 0;
    m.items.allocated = 0;
    m.items.data = null;
    m.items.allocator = .{};
    m.items_arena = null;
    virtual_free(*m.unused_items);
}

// 清空句柄池但不释放任何内存。开始新的生命周期；全部旧句柄必须丢弃。
reset :: (m: *Pool($T, $HT, $Max), destroy: (value: *T) = null) {
    clear(m, destroy);
    virtual_clear(*m.items);
    virtual_clear(*m.unused_items);
}

// 保留槽位和代数、不分配。旧句柄在代数回绕前保持无效。回调不能结构性修改本池。
clear :: (m: *Pool($T, $HT, $Max), destroy: (value: *T) = null) {
    for 1..(m.items.count - 1) {
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
// 可能让 items 扩容：因为 items 的存储永远是 arena 里最近的一次分配，arena 能原地重分配，
// 所以不会有指针移动。unused_items 非空时优先复用其中的槽位。
add :: (m: *Pool($T, $HT, $Max), v: T) -> (HT, bool) {
    if m.items_arena == null {
        fresh, ok := make(T, HT, Max);
        if !ok {
            zero: HT;
            return zero, false;
        }
        m.* = fresh;
    }

    if m.unused_items.count > 0 {
        reuse_idx := virtual_pop_unused(m);
        reused := *m.items[cast(s64) reuse_idx];
        gen := reused.handle.gen;
        reused.* = v;
        reused.handle.idx = reuse_idx;
        reused.handle.gen = gen + 1;
        return reused.handle, true;
    }

    needed := max(m.items.count, 1) + 1;
    if m.unused_items.allocated < needed - 1 {
        if !virtual_reserve(*m.unused_items, max(needed - 1, max(2 * m.unused_items.allocated, 8))) { zero: HT; return zero, false; }
    }

    if m.items.count == 0 {
        empty_item: T;
        if !virtual_append(*m.items, empty_item) { zero: HT; return zero, false; }
    }

    new_item := v;
    new_item.handle.idx = cast(u32) m.items.count;
    new_item.handle.gen = 1;
    if !virtual_append(*m.items, new_item) {
        // 扩容失败了：多半是想长过预留区。按预留区能容纳的最大槽位数再长一次。
        if !virtual_reserve(*m.items, virtual_slot_cap(m.*)) { zero: HT; return zero, false; }
        if !virtual_append(*m.items, new_item) { zero: HT; return zero, false; }
    }

    return new_item.handle, true;
}

// 取出 unused_items 尾部下标。
virtual_pop_unused :: (m: *Pool($T, $HT, $Max)) -> u32 {
    result := m.unused_items[m.unused_items.count - 1];
    m.unused_items.count -= 1;
    return result;
}

// 删除一个存活值（可顺带销毁其资源），保留其代数以便复用。回调不能结构性修改本池。
remove_handle :: (m: *Pool($T, $HT, $Max), h: HT, destroy: (value: *T) = null) {
    item := get(m.*, h);
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
    // add 会先预留空闲列表容量再发布新槽位。
    virtual_append(*m.unused_items, idx);
    empty_item: T;
    item.* = empty_item;
    item.handle.gen = gen;
}
//@endregion

//@region 查询 —— get / get_value / valid / len / cap

// 把句柄解析成 *T。指针因数据在预留区里而稳定，但不要长期保存：槽位被销毁并复用后，
// 它就指向新的占用者了。长期只存句柄，需要时再解析成指针。
get :: (m: Pool($T, $HT, $Max), h: HT) -> *T {
    if h.idx <= 0 || cast(s64) h.idx >= m.items.count {
        return null;
    }

    item := *m.items[cast(s64) h.idx];
    if virtual_handle_eq(item.handle, h) {
        return item;
    }

    return null;
}

// 返回值的副本以及句柄是否有效。
get_value :: (m: Pool($T, $HT, $Max), h: HT) -> (value: T, ok: bool) {
    item := get(m, h);
    if item != null {
        return item.*, true;
    }
    zero: T;
    return zero, false;
}

// 句柄是否映射到一个有效条目。
valid :: (m: Pool($T, $HT, $Max), h: HT) -> bool {
    return get(m, h) != null;
}

// 池内有效条目数。
len :: (m: Pool($T, $HT, $Max)) -> int {
    return max(m.items.count, 1) - m.unused_items.count - 1;
}

// 理论上能装进池里的条目数。很多情况下 Max 给得极大，所以这个容量可能大得离谱。
// 注意这里不能直接返回 Max：预留的内存可能按页大小向上取整过（Jai 侧没有页取整，
// 但 arena 结构体本身要占掉头部）。
cap :: (m: Pool($T, $HT, $Max)) -> int {
    return max(virtual_slot_cap(m) - 1, 0);
}
//@endregion

//@region 迭代 —— begin / next / skip

// 创建迭代器，配合 next 使用。
begin :: (m: *Pool($T, $HT, $Max)) -> Iterator(T, HT, Max) {
    result: Iterator(T, HT, Max);
    result.m = m;
    // olib 原样：index 从 0 开始，0 号是 dummy（handle.idx == 0），next 会自动跳过。
    result.index = 0;
    return result;
}

// 遍历池，跳过空槽（handle.idx == 0 的槽位）。
//
// 用法：it := hm.begin(*my_pool); while true { item, h, ok := hm.next(*it); if !ok break; }
//
// 也可以直接遍历 items，用 skip 判断空槽。
next :: (it: *Iterator($T, $HT, $Max)) -> (val: *T, h: HT, cond: bool) {
    while it.index < it.m.items.count {
        item := *it.m.items[it.index];
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
