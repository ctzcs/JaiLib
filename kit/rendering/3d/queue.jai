// rendering3d:queue —— 渲染项队列与排序（对位 DragonLib Renderer3D 的提交/分桶逻辑）。
// 一比一移植自 olib kit/rendering/3d/queue.odin。
//
// 每帧：clear -> 提交（payload + 视深度 + 是否透明）->
// queue_sort（不透明前到后省 early-z，透明后到前保正确混合）->
// 调用侧按序发射 GPU 命令。payload 由游戏定义（Mesh、材质、world 矩阵等）。
//
// Jai 侧差异（逐条对应 olib 的写法；排序键、比较顺序与稳定性不变）：
//   | olib (Odin)                                   | JaiLib (Jai)                                              |
//   | --------------------------------------------- | --------------------------------------------------------- |
//   | `Render_Item :: struct($T: typeid)`           | `Render_Item :: struct (T: Type)`                          |
//   | `[dynamic]Render_Item(T)` + append            | `[..] Render_Item(T)` + array_add                          |
//   | `map[int]f32` + `q.group_depths[k]`（缺键得 0） | `HASH.Table(int, float32)` + queue_group_depth（缺键同样 0）|
//   | `resize(&q.dense_depths, n)`                  | array_resize(*q.dense_depths, n)                           |
//   | `math.INF_F32`                                | JM.FLOAT32_INFINITY                                        |
//   | `math.abs`                                    | JM.abs                                                     |
//   | `for item in q.items`                          | for item: q.items（值拷贝，只读）                            |
//   | `for i := 0; cond; step`                      | while 循环 + 手写步进                                       |
//   | `for i in 0..<n`                              | for i: 0..n - 1（Jai 的区间含终点）                          |
//   | `@(private) render_item_less`                 | 去掉标注（Jai 无等价物），内部过程加 render_item_ 前缀         |
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）。

//@region 类型

Render_Item :: struct (T: Type) {
    payload: T;
    view_depth: float32; // 排序键：到相机的视空间深度（submit 时算好）
    transparent: bool;   // true 进透明桶（后到前）
    group: int;          // 可选的不透明分组；同深度组按此键排序
}

Render_Queue :: struct (T: Type) {
    items: [..] Render_Item(T);
    scratch: [..] Render_Item(T);
    group_depths: HASH.Table(int, float32);
    // 组键都是不大的非负整数时（Render3D 用来源下标）按下标存组深度，比较时不查 map。
    dense_depths: [..] float32;
}
//@endregion

//@region 提交与排序

queue_submit :: (q: *Render_Queue($T), payload: T, view_depth: float32, transparent: bool,
                 group: int = 0) {
    array_add(*q.items, Render_Item(T).{
        payload = payload,
        view_depth = view_depth,
        transparent = transparent,
        group = group,
    });
}

// 稳定 O(n log n) 归并；工作区跨帧复用。默认仍是不透明前到后、透明后到前。
// grouped 时不透明组按最近深度排列，组内前到后；透明始终全局后到前。
queue_sort :: (q: *Render_Queue($T), grouped := false) {
    HASH.table_reset(*q.group_depths); // olib: builtin.clear(&q.group_depths)
    dense := false;
    if grouped {
        // 组键都在 0..4n+64 内时用数组记各组最近深度，否则退回 map；比较只在组不同时取组深度。
        limit := -1;
        dense = true;
        for item: q.items {
            if item.transparent continue;
            if item.group < 0 || item.group > 4 * q.items.count + 64 {
                dense = false;
                break;
            }
            limit = max(limit, item.group);
        }
        if dense {
            array_resize(*q.dense_depths, limit + 1);
            for i: 0..q.dense_depths.count - 1 q.dense_depths[i] = JM.FLOAT32_INFINITY;
            for item: q.items {
                if item.transparent continue;
                q.dense_depths[item.group] = min(q.dense_depths[item.group], item.view_depth);
            }
        } else {
            for item: q.items {
                if item.transparent continue;
                exists, depth := HASH.table_find(*q.group_depths, item.group); // table_find 返回 (found, value)
                if !exists || item.view_depth < depth {
                    HASH.table_set(*q.group_depths, item.group, item.view_depth);
                }
            }
        }
    }
    if q.items.count < 2 return; // 0/1 项无需归并（olib 的两个 for 条件同样不进入）
    array_resize(*q.scratch, q.items.count);
    width := 1;
    while width < q.items.count {
        start := 0;
        while start < q.items.count {
            mid := min(start + width, q.items.count);
            end := min(start + 2 * width, q.items.count);
            a, b := start, mid;
            for i: start..end - 1 {
                if a < mid && (b == end || !render_item_less(q, q.items[b], q.items[a], grouped, dense)) {
                    q.scratch[i] = q.items[a];
                    a += 1;
                } else {
                    q.scratch[i] = q.items[b];
                    b += 1;
                }
            }
            start += 2 * width;
        }
        for i: 0..q.items.count - 1 q.items[i] = q.scratch[i];
        width *= 2;
    }
}

queue_clear :: (q: *Render_Queue($T)) {
    if q.items.data != null q.items.count = 0; // olib: builtin.clear(&q.items)
}

queue_dispose :: (q: *Render_Queue($T)) {
    if q.items.data != null array_free(q.items);
    if q.scratch.data != null array_free(q.scratch);
    HASH.deinit(*q.group_depths);
    if q.dense_depths.data != null array_free(q.dense_depths);
    q.* = Render_Queue(T).{};
}

// 便利：world 矩阵平移点在相机前方的距离（排序键，越大越远）。
// look_at 是右手系，视空间前方为 -Z，这里取反成正数。
queue_view_depth :: (camera: *W.Camera3D, world_matrix: W.Matrix4) -> float32 {
    view := W.camera3d_view(camera);
    // 行向量约定：平移在各列的第 4 分量
    position := W.vec4(world_matrix.c0[3], world_matrix.c1[3], world_matrix.c2[3], 1);
    p := W.matrix4_transform_vec4(view, position);
    if JM.abs(p[3]) < 1.0e-8 return 0;
    return -p[2] / p[3];
}

// olib 的 `dense ? q.dense_depths[g] : q.group_depths[g]`：两种容器缺键都取 0（odin map 的零值）。
queue_group_depth :: (q: *Render_Queue($T), group: int, dense: bool) -> float32 {
    if dense {
        if group < 0 || group >= q.dense_depths.count return 0;
        return q.dense_depths[group];
    }
    exists, depth := HASH.table_find(*q.group_depths, group);
    if !exists return 0;
    return depth;
}

render_item_less :: (q: *Render_Queue($T), a: Render_Item(T), b: Render_Item(T), grouped: bool, dense: bool) -> bool {
    if a.transparent != b.transparent {
        return !a.transparent; // 不透明排前面
    }
    if a.transparent {
        return a.view_depth > b.view_depth; // 透明：远者先画（后到前）
    }
    if grouped && a.group != b.group {
        da := queue_group_depth(q, a.group, dense);
        db := queue_group_depth(q, b.group, dense);
        if da != db return da < db;
        return a.group < b.group;
    }
    return a.view_depth < b.view_depth; // 不透明：近者先画（前到后）
}
//@endregion
