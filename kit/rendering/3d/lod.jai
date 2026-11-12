// rendering3d:lod —— LOD 选择（对位 DragonLib LodSelector3D / ModelLod3D）。
// 一比一移植自 olib kit/rendering/3d/lod.odin。
//
// 屏幕高度占比阈值从高到低，最后必须为 0（最低档无条件兜底）；
// 阈值上下带相对滞回，避免相机在边界附近抖动。
//
// Jai 侧差异（逐条对应 olib 的写法；阈值判定、滞回与包围球算法不变）：
//   | olib (Odin)                                      | JaiLib (Jai)                                          |
//   | ------------------------------------------------ | ----------------------------------------------------- |
//   | `allocator := context.allocator`（默认形参）        | `allocator: Allocator = context.allocator` + 过程开头   |
//   |                                                  | push_allocator（与 core/meshutil 同一写法：Jai 的 alloc |
//   |                                                  | 只从 context.allocator 取内存）                         |
//   | `make([]f32, n, allocator)` / `delete(x)`         | lod_alloc(float32, n) / free(x.data)                   |
//   | `for i: int = 0; i < n; i += 1`                   | for i: 0..n - 1                                        |
//   | `f32(math.INF_F32)`                               | JM.FLOAT32_INFINITY                                    |
//   | `math.clamp` / `math.abs`                         | clamp（Basic）/ JM.abs                                  |
//   | `linalg.length(v)`                                | JM.sqrt(v3_dot(v, v))                                  |
//   | `linalg.dot(a, b)`                                | W.v3_dot(a, b)                                         |
//   | `center - camera.position`（[3]f32 数组减法）       | W.v3_sub（Jai 没有数组算术）                             |
//   | `lod_world_sphere(...) or_return`                 | 显式的 `if !ok return …, false`                         |
//   | `[3]f32`（盒子中心/角点）                           | W.Vec3（同形的三浮点向量，matrix4 变换的入参类型）        |
//   | `Model_Lod :: struct($T: typeid)`                 | `Model_Lod :: struct (T: Type)`                        |
//   | `return _, false`                                 | `zero: T; return zero, false`                          |
//   | `@(private)`                                      | 去掉标注，内部过程加 lod_ 前缀                            |
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）。

//@region Lod_Selector

Lod_Selector :: struct {
    thresholds: [] float32; // 严格降序，末项为 0
    current_level: int;     // -1 = 未初始化（下次 Select 全量扫）
    hysteresis: float32;    // 0..0.49；0 关闭
}

// olib: make([]T, n, allocator)。Jai 的 alloc 只收字节数，从 context.allocator 取内存。
lod_alloc :: ($T: Type, count: int) -> [] T {
    if count <= 0 {
        empty: [] T;
        return empty;
    }
    memory := alloc(cast(s64) (count * size_of(T)));
    assert(memory != null, "rendering3d: 分配失败");
    return .{ count = count, data = cast(*T) memory };
}

// thresholds 必须非空、有限、非负、严格降序且末项为 0；违反返回 false。
lod_selector_init :: (s: *Lod_Selector, thresholds: [] float32,
                      allocator: Allocator = context.allocator) -> bool {
    if thresholds.count == 0 return false;
    if thresholds[thresholds.count - 1] != 0 return false;
    for i: 0..thresholds.count - 1 {
        t := thresholds[i];
        if t != t || t < 0 return false; // NaN 或负
        if i > 0 && t >= thresholds[i - 1] return false;
    }

    push_allocator(allocator);
    s.thresholds = lod_alloc(float32, thresholds.count);
    for i: 0..thresholds.count - 1 s.thresholds[i] = thresholds[i];
    s.current_level = -1;
    s.hysteresis = 0.1;
    return true;
}

lod_selector_dispose :: (s: *Lod_Selector) {
    if s.thresholds.data != null free(s.thresholds.data); // olib: delete(s.thresholds, context.allocator)
    s.* = Lod_Selector.{};
}

lod_selector_level_count :: (s: *Lod_Selector) -> int {
    return s.thresholds.count;
}

lod_selector_reset :: (s: *Lod_Selector) {
    s.current_level = -1;
}

// 按屏幕高度选级（滞回生效）。NaN/负高度返回当前级。
lod_selector_select :: (s: *Lod_Selector, screen_height: float32) -> int {
    if screen_height != screen_height || screen_height < 0 {
        if s.current_level >= 0 return s.current_level;
        return s.thresholds.count - 1;
    }
    hysteresis := clamp(s.hysteresis, 0, cast(float32) 0.49);

    if s.current_level < 0 {
        s.current_level = s.thresholds.count - 1;
        for i: 0..s.thresholds.count - 1 {
            if screen_height >= s.thresholds[i] {
                s.current_level = i;
                break;
            }
        }
    } else {
        while s.current_level > 0 && screen_height >= s.thresholds[s.current_level - 1] * (1 + hysteresis) {
            s.current_level -= 1;
        }
        while s.current_level < s.thresholds.count - 1 && screen_height < s.thresholds[s.current_level] * (1 - hysteresis) {
            s.current_level += 1;
        }
    }
    return s.current_level;
}

// 保守球的投影直径 / 视口高度。相机在球内、近裁面相交或数据不可靠时
// 返回 +inf（选最高细节——宁多画不低估）。
lod_screen_height :: (camera: *W.Camera3D, bounds: DA.Dasset_Bounds) -> float32 {
    center := W.Vec3.{
        (bounds.min[0] + bounds.max[0]) * 0.5,
        (bounds.min[1] + bounds.max[1]) * 0.5,
        (bounds.min[2] + bounds.max[2]) * 0.5,
    };
    diagonal := W.Vec3.{
        bounds.max[0] - bounds.min[0],
        bounds.max[1] - bounds.min[1],
        bounds.max[2] - bounds.min[2],
    };
    return lod_sphere_screen_height(camera, center, JM.sqrt(W.v3_dot(diagonal, diagonal)) * 0.5);
}

// 球（世界空间）的投影直径 / 视口高度，规则同 lod_screen_height。
lod_sphere_screen_height :: (camera: *W.Camera3D, center: W.Vec3, radius: float32) -> float32 {
    forward := W.camera3d_forward(camera);
    depth := W.v3_dot(W.v3_sub(center, camera.position), forward);
    if radius != radius || depth != depth || radius < 0 ||
       depth - radius <= max(cast(float32) 0.001, camera.near_clip) {
        return JM.FLOAT32_INFINITY;
    }
    // 透视投影 M22 = zz（列 2 的第 2 分量）
    projection := W.camera3d_projection(camera);
    return radius * JM.abs(projection.c2[2]) / (depth - radius);
}

// 局部包围盒经 world_matrix 变换后的包围球：球心是盒中心的像，半径取 8 个角点到球心的最远距离。
// 平移、旋转、缩放（含非均匀缩放）下都不低估；变换退化时返回 ok=false。
lod_world_sphere :: (bounds: DA.Dasset_Bounds, world_matrix: W.Matrix4) -> (center: W.Vec3, radius: float32, ok: bool) {
    middle := W.Vec3.{
        (bounds.min[0] + bounds.max[0]) * 0.5,
        (bounds.min[1] + bounds.max[1]) * 0.5,
        (bounds.min[2] + bounds.max[2]) * 0.5,
    };
    center, ok = W.matrix4_transform_point(world_matrix, middle);
    if !ok return W.Vec3.{ 0, 0, 0 }, 0, false;
    corners := aabb_corners(bounds);
    for corner: corners {
        p, valid := W.matrix4_transform_point(world_matrix, W.Vec3.{ corner[0], corner[1], corner[2] });
        if !valid return W.Vec3.{ 0, 0, 0 }, 0, false;
        offset := W.v3_sub(p, center);
        radius = max(radius, JM.sqrt(W.v3_dot(offset, offset)));
    }
    return center, radius, true;
}
//@endregion

//@region Model_Lod —— 多级模型引用（泛型）

// 一个实例的多级模型引用与 LOD 状态。不拥有 GPU 资源、不生成简化网格；
// levels 的元素类型由调用侧决定（如 ^F.Mesh 或自定义 Model 包装）。
// bounds 是所有级别的共同局部包围盒（动画使用者应传保守盒）。
Model_Lod :: struct (T: Type) {
    models: [] T;
    selector: Lod_Selector;
    bounds: DA.Dasset_Bounds;
}

model_lod_init :: (m: *Model_Lod($T), models: [] T, thresholds: [] float32, bounds: DA.Dasset_Bounds,
                   allocator: Allocator = context.allocator) -> bool {
    if models.count != thresholds.count return false;
    if !lod_selector_init(*m.selector, thresholds, allocator) return false;
    m.models = models;
    m.bounds = bounds;
    return true;
}

model_lod_dispose :: (m: *Model_Lod($T)) {
    lod_selector_dispose(*m.selector);
    m.* = Model_Lod(T).{};
}

// 选当前级的模型（内部先走 selector）。局部包围盒按 world_matrix 变换成保守包围球再投影。
model_lod_select :: (m: *Model_Lod($T), camera: *W.Camera3D, world_matrix: W.Matrix4) -> (T, bool) {
    height := JM.FLOAT32_INFINITY; // 变换退化时选最高细节
    center, radius, ok := lod_world_sphere(m.bounds, world_matrix);
    if ok height = lod_sphere_screen_height(camera, center, radius);
    level := lod_selector_select(*m.selector, height);
    if level < 0 || level >= m.models.count {
        zero: T;
        return zero, false;
    }
    return m.models[level], true;
}
//@endregion
