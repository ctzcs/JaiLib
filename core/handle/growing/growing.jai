// handle/growing —— 用增长型 arena 保存条目的代数句柄池（指针稳定）。
// 一比一移植自 olib core/handle/growing/growing.odin（原作者 Karl Zylinski），
// 以及它的平台后端 arena_default.odin（非 web：Growing Virtual Arena）；
// arena_js.odin 的 Dynamic Arena 是 wasm 专用分支，Jai 侧不需要，故未移植。
//
// The Pool maps a handle to an item. A handle consists of an index and a
// generation. The item can be any type. Such a handle can be stored as a permanent
// reference, where you'd usually store a pointer. The benefit of storing handles
// instead of pointers is that you know if a slot has been reused, thanks to the
// generation number.
// 本实现用"指针数组 + arena"：数组本身用 allocator 分配，条目逐个分配进 arena，
// 因此条目地址稳定、排布紧凑。
//
// 用法（包导入别名为 hm）：
//
//     Entity_Handle :: hm.Handle
//     Entity :: struct {
//         handle: Entity_Handle,   // 所有条目都必须带 handle 字段
//         pos:    [2] float,
//     }
//     entities: hm.Pool(Entity, Entity_Handle)
//     h1, _ := hm.add(*entities, Entity.{ pos = .[5, 7] })
//     if e := hm.get(entities, h1) e.pos.y = 123
//     hm.remove_handle(*entities, h1)                  // 留下一个空槽
//     hm.delete(*entities)
//
// Jai 侧差异（句柄布局、代数、容量、迭代语义不变）：
//   - remove 是 Jai 关键字（循环控制），公开过程改名 remove_handle（同 Libs/Engine/handle 约定）。
//   - 没有 #optional_allocator_error，make/add 返回 (…, bool)，false 等价于 err != nil。
//   - 没有 vmem 虚存 arena：Arena 改为普通的分块线性 arena（块分配取 context.allocator，
//     与 olib 非 web 版一致——那里 arena_init 的 allocator 形参同样不参与分配）。
//   - min_items_per_block 省略或 <= 0 表示 olib 的默认值 ARENA_DEFAULT_BLOCK_SIZE / size_of(T)，
//     块大小最小为一页（ARENA_DEFAULT_BLOCK_SIZE），与 Odin vmem 的最小块一致。
//   - HT 泛型的句柄比较不用 operator ==（Jai 运算符按词法解析，跨模块不可见），
//     改用具名的 growing_handle_eq；本模块自有的 Handle 另行声明 operator ==。
//   - olib 的 loc := #caller_location 形参：Jai 没有调用点信息，相关形参直接省略（不影响语义）。
//   - Jai 的 Allocator 不带对齐参数，条目按 16 字节对齐分配（同 Libs/Engine/handle 的 arena）：
//     align_of(T) > 16 的类型不适用。
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

Pool :: struct(T: Type, HT: Type) {
    // 数组本身用 allocator 分配（不用 items_arena），数组元素指向 arena 里的条目。
    //
    // 每个条目都必须有类型为 HT 的 handle 字段。
    // 0 号永远是 dummy 条目，这样 idx == 0 的 Handle 表示"没有句柄"。
    items: [..] *T;

    // 保存条目数据的 arena：条目线性分配进去，排布紧凑且指针稳定。
    items_arena: Arena;

    // items 中的空闲下标，由 remove_handle 追加。
    unused_items: [..] u32;
}

// 遍历用。用 begin 创建。
Iterator :: struct(T: Type, HT: Type) {
    m: *Pool(T, HT);
    index: int;
}
//@endregion

//@region arena_default —— 增长型 arena（对应 olib growing/arena_default.odin）

// 一页内存，与 Odin 增长型 arena 的最小块大小一致。
ARENA_DEFAULT_BLOCK_SIZE :: 4096;

Arena_Block :: struct {
    memory: *u8;
    size: s64;
    used: s64;
    next: *Arena_Block;
}

// 分块线性 arena：块只追加、从不移动，所以指向块内的指针稳定。
Arena :: struct {
    curr_block: *Arena_Block;
    all_blocks: *Arena_Block;
    block_size: s64;
    allocator: Allocator; // 块头和块内存的来源
    // olib 用 curr_block != nil 判断"已初始化"；vmem 的 arena 一 init 就有块。
    // Jai 侧为了不在 init 时消耗一次分配（make 之后才第一次真正分配），改用显式标记。
    initialized: bool;
}

arena_initialized :: (arena: Arena) -> bool {
    return arena.initialized;
}

// 与 vmem.arena_init_growing 一致：块大小被抬到至少一页。
arena_init :: (arena: *Arena, block_size: s64 = ARENA_DEFAULT_BLOCK_SIZE) -> bool {
    arena.block_size = max(block_size, ARENA_DEFAULT_BLOCK_SIZE);
    arena.curr_block = null;
    arena.all_blocks = null;
    arena.allocator = context.allocator;
    arena.initialized = true;
    return true;
}

growing_arena_allocate :: (arena: *Arena, size: s64, alignment: s64) -> *void {
    if alignment < 1 alignment = 1;
    block := arena.curr_block;
    if block != null {
        aligned_used := (block.used + alignment - 1) / alignment * alignment;
        if aligned_used + size <= block.size {
            result := block.memory + aligned_used;
            block.used = aligned_used + size;
            return cast(*void) result;
        }
    }

    // 当前块放不下：新开一块（旧块保留，指针继续有效）。
    block_size := max(size + alignment, arena.block_size);
    allocator := arena.allocator;
    if !allocator.proc allocator = context.allocator;
    memory := allocator.proc(.ALLOCATE, block_size, 0, null, allocator.data);
    if memory == null return null;
    header := allocator.proc(.ALLOCATE, size_of(Arena_Block), 0, null, allocator.data);
    if header == null {
        allocator.proc(.FREE, 0, block_size, memory, allocator.data);
        return null;
    }

    new_block := cast(*Arena_Block) header;
    new_block.memory = cast(*u8) memory;
    new_block.size = block_size;
    new_block.used = size;
    new_block.next = arena.all_blocks;
    arena.all_blocks = new_block;
    arena.curr_block = new_block;
    return memory;
}

// 保留最近的一块（之后复用），释放其余块。
arena_free_all :: (arena: *Arena) {
    first := arena.all_blocks;
    block := arena.all_blocks;
    while block != null {
        next := block.next;
        if block != first {
            if block.memory arena.allocator.proc(.FREE, 0, block.size, block.memory, arena.allocator.data);
            arena.allocator.proc(.FREE, 0, size_of(Arena_Block), block, arena.allocator.data);
        }
        block = next;
    }
    if first != null {
        first.used = 0;
        first.next = null;
        arena.all_blocks = first;
        arena.curr_block = first;
    } else {
        arena.all_blocks = null;
        arena.curr_block = null;
    }
}

// 释放全部块（含块头），arena 回到未初始化状态。
arena_destroy :: (arena: *Arena) {
    block := arena.all_blocks;
    while block != null {
        next := block.next;
        if block.memory arena.allocator.proc(.FREE, 0, block.size, block.memory, arena.allocator.data);
        arena.allocator.proc(.FREE, 0, size_of(Arena_Block), block, arena.allocator.data);
        block = next;
    }
    arena.all_blocks = null;
    arena.curr_block = null;
    arena.block_size = 0;
    arena.initialized = false;
}

growing_arena_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    arena := cast(*Arena) allocator_data;
    if mode == .ALLOCATE {
        return growing_arena_allocate(arena, size, 16);
    }
    if mode == .RESIZE {
        if old_memory == null return growing_arena_allocate(arena, size, 16);
        // arena 语义：只有最近一次分配可以原地扩张，否则报失败（不静默丢数据）。
        // 本池的 items/unused_items 数组不走 arena，正常路径不会用到这里。
        block := arena.curr_block;
        if block != null {
            offset := cast(s64) (cast(*u8) old_memory - block.memory);
            if offset >= 0 && offset + old_size == block.used && offset + size <= block.size {
                block.used = offset + size;
                return old_memory;
            }
        }
        return null;
    }
    // 逐个释放是空操作；整块回收用 arena_free_all / arena_destroy。
    return null;
}

arena_allocator :: (arena: *Arena) -> Allocator {
    result: Allocator;
    result.proc = growing_arena_allocator_proc;
    result.data = cast(*void) arena;
    return result;
}
//@endregion

//@region 动态数组桥接 / 句柄比较

// 分配器解析：olib 的默认实参是 context.allocator；Jai 形参不可赋值，用这个具名辅助。
growing_allocator :: (allocator: Allocator) -> Allocator {
    resolved := allocator;
    if !resolved.proc resolved = context.allocator;
    return resolved;
}

// 对应 Odin 的 reserve：只增不减，失败返回 false。
growing_reserve :: (array: *[..] $T, desired: s64) -> bool {
    if desired <= array.allocated return true;
    if !array.allocator.proc array.allocator = context.allocator;
    memory := array.allocator.proc(.RESIZE, desired * size_of(T), array.allocated * size_of(T), array.data, array.allocator.data);
    if memory == null return false;
    array.data = memory;
    array.allocated = desired;
    return true;
}

// 对应 Odin 的 append。
growing_append :: (array: *[..] $T, value: T) -> bool {
    if array.count >= array.allocated {
        if !growing_reserve(array, max(array.count + 1, max(array.allocated * 2, 8))) return false;
    }
    array.data[array.count] = value;
    array.count += 1;
    return true;
}

// 对应 Odin 的 pop。
growing_pop :: (array: *[..] $T) -> T {
    result := array.data[array.count - 1];
    array.count -= 1;
    return result;
}

// 对应 runtime.clear（保留内存）。
growing_clear :: (array: *[..] $T) {
    array.count = 0;
}

// 对应 runtime.delete（释放并清零）。
growing_free :: (array: *[..] $T) {
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
growing_handle_eq :: (a: $HT, b: HT) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}
//@endregion

//@region 生命周期 —— make / delete / reset / clear

// 为条目类型 T 与句柄类型 HT 创建 Pool。句柄类型通常写成
//     Handle_Type :: Handle
//
// min_items_per_block 表示底层 arena 每块能存多少条目；省略或 <= 0 时取 olib 的默认值
// ARENA_DEFAULT_BLOCK_SIZE / size_of(T)。块大小最小一页（ARENA_DEFAULT_BLOCK_SIZE）。
//
// allocator 用于 items 与 unused_items 两个数组。
make :: ($T: Type, $HT: Type, min_items_per_block: int = 0, allocator: Allocator = Allocator.{}) -> (Pool(T, HT), bool) {
    m: Pool(T, HT);
    alloc := growing_allocator(allocator);
    m.items.allocator = alloc;
    m.unused_items.allocator = alloc;

    per_block := min_items_per_block;
    if per_block <= 0 per_block = ARENA_DEFAULT_BLOCK_SIZE / size_of(T);
    if !arena_init(*m.items_arena, per_block * size_of(T)) return m, false;
    return m, true;
}

// 按需销毁存活值、释放容器内存并清零 Pool。
delete :: (m: *Pool($T, $HT), destroy: (value: *T) = null) {
    clear(m, destroy);
    if arena_initialized(m.items_arena) {
        arena_destroy(*m.items_arena);
    }
    growing_free(*m.items);
    growing_free(*m.unused_items);
    z: Pool(T, HT);
    m.* = z;
}

// 清空句柄池但不释放全部内存：items_arena 除第一块外都归还（第一块之后复用），
// items 和 unused_items 只清长度不释放。开始新的生命周期；全部旧句柄必须丢弃。
reset :: (m: *Pool($T, $HT), destroy: (value: *T) = null) {
    clear(m, destroy);
    if arena_initialized(m.items_arena) {
        arena_free_all(*m.items_arena);
    }
    growing_clear(*m.items);
    growing_clear(*m.unused_items);
}

// 保留槽位和代数、不分配。旧句柄在代数回绕前保持无效。回调不能结构性修改本池。
clear :: (m: *Pool($T, $HT), destroy: (value: *T) = null) {
    for 1..(m.items.count - 1) {
        item := m.items[it];
        if item.handle.idx != 0 {
            remove_handle(m, item.handle, destroy);
        }
    }
}
//@endregion

//@region 增删 —— add / remove_handle

// 追加一个 T，返回可长期引用的句柄。
//
// 新条目用 arena 分配进 Pool 的 items_arena：指针稳定，且因条目在 arena 里紧凑排布而高效。
// unused_items 非空时优先复用其中的槽位。
add :: (m: *Pool($T, $HT), v: T) -> (HT, bool) {
    if !arena_initialized(m.items_arena) {
        fresh, ok := make(T, HT);
        if !ok {
            zero: HT;
            return zero, false;
        }
        m.* = fresh;
    }

    if m.unused_items.count > 0 {
        reuse_idx := growing_pop(*m.unused_items);
        reused := m.items[cast(s64) reuse_idx];
        gen := reused.handle.gen;
        reused.* = v;
        reused.handle.idx = reuse_idx;
        reused.handle.gen = gen + 1;
        return reused.handle, true;
    }

    needed := max(m.items.count, 1) + 1;
    if m.unused_items.allocated < needed - 1 {
        if !growing_reserve(*m.unused_items, max(needed - 1, max(2 * m.unused_items.allocated, 8))) {
            zero: HT;
            return zero, false;
        }
    }
    if m.items.allocated < needed {
        if !growing_reserve(*m.items, max(needed, max(2 * m.items.allocated, 8))) {
            zero: HT;
            return zero, false;
        }
    }

    items_allocator := arena_allocator(*m.items_arena);

    if m.items.count == 0 {
        if !growing_append(*m.items, null) {
            zero: HT;
            return zero, false;
        }
    }

    new_item := cast(*T) items_allocator.proc(.ALLOCATE, size_of(T), 0, null, items_allocator.data);
    if new_item == null {
        zero: HT;
        return zero, false;
    }
    new_item.* = v;
    new_item.handle.idx = cast(u32) m.items.count;
    new_item.handle.gen = 1;
    if !growing_append(*m.items, new_item) {
        zero: HT;
        return zero, false;
    }
    return new_item.handle, true;
}

// 删除一个存活值（可顺带销毁其资源），保留其代数以便复用。回调不能结构性修改本池。
remove_handle :: (m: *Pool($T, $HT), h: HT, destroy: (value: *T) = null) {
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
    growing_append(*m.unused_items, idx);
    empty_item: T;
    item.* = empty_item;
    item.handle.gen = gen;
}
//@endregion

//@region 查询 —— get / get_value / valid / len / cap

// 把句柄解析成 *T。指针因条目分配在 items_arena 而稳定，但不要长期保存：槽位被销毁并复用后，
// 它就指向新的占用者了。长期只存句柄，需要时再解析成指针。
get :: (m: Pool($T, $HT), h: HT) -> *T {
    if h.idx <= 0 || cast(s64) h.idx >= m.items.count {
        return null;
    }

    item := m.items[cast(s64) h.idx];
    if growing_handle_eq(item.handle, h) {
        return item;
    }

    return null;
}

// 返回值的副本以及句柄是否有效。
get_value :: (m: Pool($T, $HT), h: HT) -> (value: T, ok: bool) {
    item := get(m, h);
    if item != null {
        return item.*, true;
    }
    zero: T;
    return zero, false;
}

// 句柄是否映射到一个有效条目。
valid :: (m: Pool($T, $HT), h: HT) -> bool {
    return get(m, h) != null;
}

// 池内有效条目数。注意实现：总数里永远减 1，因为 0 号可能有一个条目——
// 那一位不使用，只是为了让 idx == 0 的句柄不映射到任何东西。
len :: (m: Pool($T, $HT)) -> int {
    return max(m.items.count, 1) - m.unused_items.count - 1;
}

// 不扩容指针数组时最多能容纳的存活条目数。
cap :: (m: Pool($T, $HT)) -> int {
    return max(cast(int) m.items.allocated - 1, 0);
}
//@endregion

//@region 迭代 —— begin / next / skip

// 创建迭代器，配合 next 使用。
begin :: (m: *Pool($T, $HT)) -> Iterator(T, HT) {
    result: Iterator(T, HT);
    result.m = m;
    result.index = 1;
    return result;
}

// 遍历池，跳过空槽（handle.idx == 0 的槽位）。
//
// 用法：it := hm.begin(*my_pool); while true { item, h, ok := hm.next(*it); if !ok break; }
//
// 也可以直接遍历 items，用 skip 判断空槽。
next :: (it: *Iterator($T, $HT)) -> (val: *T, h: HT, cond: bool) {
    while it.index < it.m.items.count {
        item := it.m.items[it.index];
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
