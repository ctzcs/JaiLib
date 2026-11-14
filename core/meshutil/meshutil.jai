// meshutil —— 三角网格的 CPU 工具：统计、拓扑边、焊接、压缩与简化，不依赖 GPU。
// 一比一移植自 olib core/meshutil/meshutil.odin（QEM 简化在 simplify.jai）。
//
// 输入统一为位置 [] [3] float32 + 三角形索引 [] u32（每 3 个一组，与 dasset 一致）。
// 位置相同的顶点视为同一几何点：UV/法线拆分产生的“缝”不算破洞。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   - Jai 没有数组算术，也没有 [3] float32 的 `==`：判等走 meshutil_vec_eq 逐分量比较
//     （-0 与 +0 相等、NaN 各自不相等，与 odin 的 == 语义一致）；
//   - 没有 switch：Edge_Kind 的分派写成 if 链 / if-switch，分支顺序与 olib 相同；
//   - Jai 无具名返回值：edges / weld / compact / simplify 的返回值按位置写，名字留在注释里；
//   - olib 的 core:hash.fnv32a 与 mem.compare_ptrs 由 meshutil_bytes_hash /
//     meshutil_bytes_equal 逐字节实现（FNV-1a 32 位，与 odin 同一算法）；
//     olib 的 map[u64]int 由开放寻址表（meshutil_hash_u64 + 线性探测）代替 —— 哈希只
//     影响探测顺序，条目仍按“首次出现”顺序写出，所以结果与 olib 一致；
//   - olib 的 make([]T, n, allocator) → meshutil_alloc(T, n)：Jai 的 alloc() 只收字节数、
//     从 context.allocator 取内存，所以带 allocator 参数的公开过程在开头
//     push_allocator(allocator)（作用域结束时自动还原），返回的切片由调用方用同一分配器
//     free；过程内部的临时数组也因此落在同一个分配器上（odin 版用 context.allocator），
//     数值与结果不变；
//   - 本包对 core/dasset 的依赖：core/dasset 尚未移植，Stats.bounds 用同形的
//     Dasset_Bounds 占位（字段 min/max 与 olib 一致），primitive_positions 写成对 *$P 的
//     泛型过程（要求 P 有 vertices / skin_vertices 字段，字段类型同 dasset）；
//     core/dasset 落地后把 Dasset_Bounds 换成 dasset.Dasset_Bounds、*$P 换成
//     *dasset.Dasset_Primitive 即可，其余不动；
//   - int 字面量不自动转 float32：与 float32 混算处写浮点字面量或显式 cast；
//   - u32 索引统一 cast(int) 后取下标，与 count 的 int 类型一致。
#import "Basic";
#import "Math";

//@region 类型

// dasset 占位：与 olib dasset.Dasset_Bounds 同形（core/dasset 未移植，见文件头）。
Dasset_Bounds :: struct {
    min: [3] float32;
    max: [3] float32;
}

// 反转极值的“空”盒：encapsulate 任意点后即为正常盒。
DASSET_BOUNDS_EMPTY :: Dasset_Bounds.{
    min = .[FLOAT32_INFINITY, FLOAT32_INFINITY, FLOAT32_INFINITY],
    max = .[-FLOAT32_INFINITY, -FLOAT32_INFINITY, -FLOAT32_INFINITY],
};

// 网格质量概况，用于判断顶点浪费、破洞和退化三角形。
Stats :: struct {
    vertices: int; // 顶点数组长度
    used_vertices: int; // 被索引引用的顶点数；少于 vertices 说明有闲置顶点（compact 可去除）
    unique_positions: int; // 被引用顶点中的不同位置数；与 used_vertices 的差距来自 UV/法线拆分
    triangles: int;
    degenerate_triangles: int; // 重复索引或重合位置的三角形（remove_degenerate 可去除）
    invalid_indices: int; // 越界索引；非零时其余拓扑数据不完整
    edges: int; // 按位置焊接后的唯一边
    border_edges: int; // 只属于一个三角形：破洞或开放边界
    seam_edges: int; // 两侧三角形使用不同顶点（UV/法线拆分）
    non_manifold_edges: int; // 属于三个及以上三角形
    bounds: Dasset_Bounds; // 被引用顶点的包围盒；无三角形时为 DASSET_BOUNDS_EMPTY
}

Edge_Kind :: enum u8 {
    Interior; // 两个三角形共享且使用相同顶点
    Seam; // 两个三角形共享位置，但顶点不同（属性缝）
    Border; // 只有一个三角形
    Non_Manifold; // 三个及以上三角形
}

// a、b 为第一次出现该边时三角形使用的顶点下标。
Edge :: struct {
    a, b: u32;
    kind: Edge_Kind;
}
//@endregion

//@region 查询

// 统计网格；只读，临时内存在返回前释放。
stats :: (positions: [][3] float32, indices: [] u32) -> Stats {
    s: Stats;
    s.vertices = positions.count;
    s.triangles = indices.count / 3;
    s.bounds = DASSET_BOUNDS_EMPTY;
    n := positions.count;
    for i: 0..indices.count - 1 {
        if cast(int) indices[i] >= n s.invalid_indices += 1;
    }
    used := meshutil_alloc_zeroed(bool, n);
    defer meshutil_free(used);
    for i: 0..indices.count - 1 {
        if cast(int) indices[i] < n used[cast(int) indices[i]] = true;
    }
    for i: 0..n - 1 {
        if !used[i] continue;
        s.used_vertices += 1;
        for axis: 0..2 {
            s.bounds.min[axis] = min(s.bounds.min[axis], positions[i][axis]);
            s.bounds.max[axis] = max(s.bounds.max[axis], positions[i][axis]);
        }
    }
    if s.invalid_indices > 0 return s;

    remap := meshutil_position_remap(positions, indices);
    defer meshutil_free(remap);
    for i: 0..n - 1 {
        if used[i] && remap[i] == cast(u32) i s.unique_positions += 1;
    }
    for tri: 0..indices.count / 3 - 1 {
        t := tri * 3;
        a := remap[cast(int) indices[t]];
        b := remap[cast(int) indices[t + 1]];
        c := remap[cast(int) indices[t + 2]];
        if a == b || b == c || a == c s.degenerate_triangles += 1;
    }
    list, ok := edges(positions, indices);
    defer meshutil_free(list);
    if ok {
        s.edges = list.count;
        for i: 0..list.count - 1 {
            if list[i].kind == {
                case Edge_Kind.Interior;
                case Edge_Kind.Seam; s.seam_edges += 1;
                case Edge_Kind.Border; s.border_edges += 1;
                case Edge_Kind.Non_Manifold; s.non_manifold_edges += 1;
            }
        }
    }
    return s;
}

// 按位置焊接后的唯一边列表，用于线框显示与拓扑检查。退化边（两端同一位置）被忽略。
// 索引越界或长度不是 3 的倍数时返回 nil, false（odin 的 nil 切片对应 Jai 的空切片）。
edges :: (positions: [][3] float32, indices: [] u32, allocator: Allocator = context.allocator) -> ([] Edge, bool) {
    if !meshutil_indices_valid(positions, indices) {
        empty: [] Edge;
        return empty, false;
    }
    push_allocator(allocator);
    remap := meshutil_position_remap(positions, indices);
    defer meshutil_free(remap);

    capacity := meshutil_table_capacity(indices.count);
    table := meshutil_alloc_zeroed(u32, capacity);
    defer meshutil_free(table);
    keys := meshutil_alloc(u64, capacity);
    defer meshutil_free(keys);

    // 与 odin 的 [dynamic]Entry 等价：容量按 len(indices)/2 起，需要时再长。
    entries: [..] Meshutil_Edge_Entry;
    array_reserve(*entries, indices.count / 2);
    defer array_free(entries);

    for tri: 0..indices.count / 3 - 1 {
        t := tri * 3;
        for e: 0..2 {
            i0 := indices[t + e];
            i1 := indices[t + (e + 1) % 3];
            r0 := remap[cast(int) i0];
            r1 := remap[cast(int) i1];
            if r0 == r1 continue;
            key := ((cast(u64) min(r0, r1)) << 32) | cast(u64) max(r0, r1);
            slot := cast(int) (meshutil_hash_u64(key) & cast(u64) (capacity - 1));
            found := -1;
            while true {
                stored := table[slot];
                if stored == 0 break;
                if keys[slot] == key {
                    found = slot;
                    break;
                }
                slot = (slot + 1) & (capacity - 1);
            }
            if found < 0 {
                table[slot] = cast(u32) entries.count + 1;
                keys[slot] = key;
                array_add(*entries, Meshutil_Edge_Entry.{ a = i0, b = i1, faces = 1, seam = false });
                continue;
            }
            entry := entries[cast(int) table[found] - 1];
            entry.faces += 1;
            // 共享边的另一侧按相反方向使用同一对顶点；顶点不同说明属性在此拆开。
            if !(entry.a == i1 && entry.b == i0) && !(entry.a == i0 && entry.b == i1) entry.seam = true;
            entries[cast(int) table[found] - 1] = entry;
        }
    }
    result := meshutil_alloc(Edge, entries.count);
    for i: 0..entries.count - 1 {
        kind := Edge_Kind.Interior;
        if entries[i].faces == 1 {
            kind = Edge_Kind.Border;
        } else if entries[i].faces > 2 {
            kind = Edge_Kind.Non_Manifold;
        } else if entries[i].seam {
            kind = Edge_Kind.Seam;
        }
        result[i] = Edge.{ a = entries[i].a, b = entries[i].b, kind = kind };
    }
    return result, true;
}

// 复制 dasset primitive（静态或蒙皮）的顶点位置，供本包和线框显示使用。
// odin 版参数是 ^dasset.Dasset_Primitive；core/dasset 未移植，这里写成泛型 *$P：
// P 需要有 vertices / skin_vertices 字段（[]Dasset_Vertex / []Dasset_Skin_Vertex 形状），
// skin_vertices != nil 即蒙皮。见文件头说明。
primitive_positions :: (p: *$P, allocator: Allocator = context.allocator) -> [][3] float32 {
    push_allocator(allocator);
    if p.skin_vertices.data != null {
        result := meshutil_alloc([3] float32, p.skin_vertices.count);
        for i: 0..result.count - 1 result[i] = p.skin_vertices[i].position;
        return result;
    }
    result := meshutil_alloc([3] float32, p.vertices.count);
    for i: 0..result.count - 1 result[i] = p.vertices[i].position;
    return result;
}
//@endregion

//@region 顶点整理

// 合并按字节完全相同的顶点（T 不应含未初始化的填充字节），原地改写 indices，
// 返回新顶点数组（按原顺序保留首次出现者，包含未引用顶点）。索引越界返回 nil, false 且不修改。
weld :: (vertices: [] $T, indices: [] u32, allocator: Allocator = context.allocator) -> ([] T, bool) {
    if !meshutil_indices_in_range(vertices.count, indices) {
        empty: [] T;
        return empty, false;
    }
    push_allocator(allocator);
    n := vertices.count;
    capacity := meshutil_table_capacity(n);
    table := meshutil_alloc_zeroed(u32, capacity);
    defer meshutil_free(table);
    remap := meshutil_alloc(u32, n);
    defer meshutil_free(remap);
    // odin 的 [dynamic]T 收缩后返回；这里直接按顶点数分配，返回的切片 count 为实际去重数。
    result := meshutil_alloc(T, n);
    count := 0;
    for i: 0..n - 1 {
        slot := cast(int) (meshutil_bytes_hash(cast(*void) *vertices[i], size_of(T)) & cast(u32) (capacity - 1));
        while true {
            stored := table[slot];
            if stored == 0 {
                table[slot] = cast(u32) count + 1;
                remap[i] = cast(u32) count;
                result[count] = vertices[i];
                count += 1;
                break;
            }
            other := cast(int) stored - 1;
            if meshutil_bytes_equal(cast(*void) *result[other], cast(*void) *vertices[i], size_of(T)) {
                remap[i] = stored - 1;
                break;
            }
            slot = (slot + 1) & (capacity - 1);
        }
    }
    for i: 0..indices.count - 1 indices[i] = remap[cast(int) indices[i]];
    welded := result;
    welded.count = count;
    return welded, true;
}

// 删除未被引用的顶点，原地改写 indices，返回按首次引用顺序排列的新顶点数组。
// 按引用顺序排列同时改善 GPU 顶点读取的局部性。索引越界返回 nil, false 且不修改。
compact :: (vertices: [] $T, indices: [] u32, allocator: Allocator = context.allocator) -> ([] T, bool) {
    if !meshutil_indices_in_range(vertices.count, indices) {
        empty: [] T;
        return empty, false;
    }
    push_allocator(allocator);
    // odin 的 NONE :: ~u32(0)。
    NONE: u32 : 0xFFFFFFFF;
    remap := meshutil_alloc(u32, vertices.count);
    defer meshutil_free(remap);
    for i: 0..remap.count - 1 remap[i] = NONE;
    count := 0;
    for i: 0..indices.count - 1 {
        index := indices[i];
        if remap[cast(int) index] == NONE {
            remap[cast(int) index] = cast(u32) count;
            count += 1;
        }
        indices[i] = remap[cast(int) index];
    }
    result := meshutil_alloc(T, count);
    for i: 0..vertices.count - 1 {
        r := remap[i];
        if r != NONE result[cast(int) r] = vertices[i];
    }
    return result, true;
}

// 原地删除退化三角形（重复索引，或两个顶点位置相同），返回 indices 的有效前缀。
// 不检查面积为零但三点不同的细长三角形。索引越界的三角形同样删除。
remove_degenerate :: (positions: [][3] float32, indices: [] u32) -> [] u32 {
    count := 0;
    n := positions.count;
    for tri: 0..indices.count / 3 - 1 {
        t := tri * 3;
        a := indices[t];
        b := indices[t + 1];
        c := indices[t + 2];
        if cast(int) a >= n || cast(int) b >= n || cast(int) c >= n continue;
        if meshutil_vec_eq(positions[cast(int) a], positions[cast(int) b]) ||
           meshutil_vec_eq(positions[cast(int) b], positions[cast(int) c]) ||
           meshutil_vec_eq(positions[cast(int) a], positions[cast(int) c]) continue;
        indices[count] = a;
        indices[count + 1] = b;
        indices[count + 2] = c;
        count += 3;
    }
    result := indices;
    result.count = count;
    return result;
}
//@endregion

//@region 内部

// odin 的 ~u32(0)：Jai 的 ~ 是一元取反，这里直接写常量更清楚。
MESHUTIL_NONE: u32 : 0xFFFFFFFF;

// 分配 count 个 T（未初始化），用 context.allocator —— 调用方负责 push_allocator。
meshutil_alloc :: ($T: Type, count: int) -> [] T {
    result: [] T;
    if count <= 0 return result;
    result.data = cast(*T) alloc(count * size_of(T));
    result.count = count;
    return result;
}

// 分配 count 个零值 T（odin 的 make 语义）。
meshutil_alloc_zeroed :: ($T: Type, count: int) -> [] T {
    result := meshutil_alloc(T, count);
    meshutil_zero(cast(*void) result.data, result.count * size_of(T));
    return result;
}

meshutil_free :: (items: [] $T) {
    if items.data == null return;
    free(items.data);
}

// 逐字节清零（odin 的 slice.zero / make 留下的零值）。
meshutil_zero :: (data: *void, size: int) {
    bytes: *u8 = data;
    for i: 0..size - 1 bytes[i] = 0;
}

// 切片级别的逐字节清零。
meshutil_zero_array :: (items: [] $T) {
    meshutil_zero(cast(*void) items.data, items.count * size_of(T));
}

// 逐分量判等：[3] float32 在 Jai 里没有 ==（odin 的 == 是逐分量 IEEE 比较）。
meshutil_vec_eq :: (a: [3] float32, b: [3] float32) -> bool {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}

meshutil_indices_valid :: (positions: [][3] float32, indices: [] u32) -> bool {
    if indices.count % 3 != 0 return false;
    return meshutil_indices_in_range(positions.count, indices);
}

meshutil_indices_in_range :: (count: int, indices: [] u32) -> bool {
    for i: 0..indices.count - 1 {
        if cast(int) indices[i] >= count return false;
    }
    return true;
}

meshutil_table_capacity :: (count: int) -> int {
    capacity := 16;
    while capacity < count * 2 capacity *= 2;
    return capacity;
}

// 被引用顶点按位置分组：remap[i] 为同位置中下标最小的被引用顶点；未引用顶点映射到自身。
// 比较使用 meshutil_vec_eq，因此 -0 与 +0 视为同一点，NaN 各自独立。调用方保证索引有效。
meshutil_position_remap :: (positions: [][3] float32, indices: [] u32) -> [] u32 {
    n := positions.count;
    remap := meshutil_alloc(u32, n);
    for i: 0..n - 1 remap[i] = cast(u32) i;
    used := meshutil_alloc_zeroed(bool, n);
    defer meshutil_free(used);
    for i: 0..indices.count - 1 used[cast(int) indices[i]] = true;
    capacity := meshutil_table_capacity(n);
    table := meshutil_alloc_zeroed(u32, capacity);
    defer meshutil_free(table);
    for i: 0..n - 1 {
        if !used[i] continue;
        p := positions[i];
        slot := cast(int) (meshutil_position_hash(p) & cast(u32) (capacity - 1));
        while true {
            stored := table[slot];
            if stored == 0 {
                table[slot] = cast(u32) i + 1;
                break;
            }
            if meshutil_vec_eq(positions[cast(int) stored - 1], p) {
                remap[i] = stored - 1;
                break;
            }
            slot = (slot + 1) & (capacity - 1);
        }
    }
    return remap;
}

// odin core:hash.fnv32a：FNV-1a 32 位。
meshutil_bytes_hash :: (data: *void, size: int) -> u32 {
    bytes: *u8 = data;
    h := cast(u32) 2166136261;
    for i: 0..size - 1 h = (h ^ cast(u32) bytes[i]) * 16777619;
    return h;
}

// odin mem.compare_ptrs(a, b, size) == 0。
meshutil_bytes_equal :: (a: *void, b: *void, size: int) -> bool {
    pa: *u8 = a;
    pb: *u8 = b;
    for i: 0..size - 1 {
        if pa[i] != pb[i] return false;
    }
    return true;
}

// +0 消除 -0，使相等的坐标得到相同的位模式（与 odin 的 transmute(u32)(p+0) 等价）。
meshutil_float_bits :: (x: float32) -> u32 {
    v := x + 0;
    bits := cast(*u32) *v;
    return bits[0];
}

meshutil_position_hash :: (p: [3] float32) -> u32 {
    x := meshutil_float_bits(p[0]);
    y := meshutil_float_bits(p[1]);
    z := meshutil_float_bits(p[2]);
    h := x * 73856093 ^ y * 19349663 ^ z * 83492791;
    return h ^ (h >> 16);
}

// u64 键的开放寻址散列（代替 odin 的 map[u64]int）：只影响探测顺序。
meshutil_hash_u64 :: (key: u64) -> u64 {
    h := key * 0x9E3779B97F4A7C15;
    return h ^ (h >> 29);
}

// edges 内部条目：odin 版是 proc 内的局部 struct，这里提到文件作用域并加前缀。
Meshutil_Edge_Entry :: struct {
    a, b: u32; // 第一次出现的有向边（原始顶点）
    faces: int;
    seam: bool;
}
//@endregion
