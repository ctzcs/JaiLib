// gizmo:translation —— 移动、旋转与缩放工具；只返回交互结果，不持有对象、场景或存档。
// 一比一移植自 olib kit/gizmo/translation.odin（olib 里 transform.odin 复用的内部工具
// finite / dot / dot2 也落在本文件，Jai 的 #load 共享模块作用域）。
//
// Jai 侧差异（逐条对应 olib 的写法；数值、分支顺序、默认值与输入契约不变）：
//   | olib (Odin)                                  | JaiLib (Jai)                                             |
//   | -------------------------------------------- | -------------------------------------------------------- |
//   | foster.Vec3 / foster.Vec2                    | W.Vec3 / W.Vec2（Math.Vector3 / Vector2 的别名，.x/.y/.z） |
//   | foster.Rect{X,Y,Width,Height}                | F.Rect{x,y,w,h}（jfoster 的 Rect）                        |
//   | foster.Color{R,G,B,A}                        | F.Color{r,g,b,a}                                         |
//   | v[axis]（Odin 向量当数组用）                    | v.component[axis]（Math.Vector3 的数组视图，可写）          |
//   | `a + b` / `a - b` / `a * s` / `a / s`        | gizmo_v2_* / gizmo_v3_* / W.v3_sub（Jai 的向量运算符只在   |
//   |                                              | 声明它的模块内可见，直接写会有 operator-out-of-scope 警告）  |
//   | `return {}, false`                           | `return W.Vec2.{0, 0}, false`（Jai 没有零值字面量）         |
//   | `a, ok := proj()` 后赋给数组元素               | 先落临时变量再赋（Jai 的多返回值不写进数组元素）              |
//   | `math.is_nan / math.is_inf / math.sqrt`      | JM.isnan / JM.isinf / JM.sqrt                            |
//   | `math.INF_F32`                               | JM.FLOAT32_INFINITY                                      |
//   | `#force_inline` / `@(private)`               | 去掉（Jai 自己决定内联；内部过程加 gizmo_ 前缀）             |
//   | `if !ok do return`                           | `if !ok return`（Jai 没有 do）                             |
// 导入（#import）由 module.jai 提供：#load 进来的文件共享这一层的名字。

//@region 内部工具 —— 判空、向量算子、比较

// olib: !math.is_nan(v) && !math.is_inf(v)
gizmo_finite :: (v: float32) -> bool {
    return !JM.isnan(v) && !JM.isinf(v);
}

gizmo_finite2 :: (v: W.Vec2) -> bool {
    return gizmo_finite(v.x) && gizmo_finite(v.y);
}

// olib 的 Vec2 `+` / `-`。
gizmo_v2_add :: (a: W.Vec2, b: W.Vec2) -> W.Vec2 {
    return W.Vec2.{ a.x + b.x, a.y + b.y };
}

gizmo_v2_sub :: (a: W.Vec2, b: W.Vec2) -> W.Vec2 {
    return W.Vec2.{ a.x - b.x, a.y - b.y };
}

// olib 的 Vec2 `v * s`（逐分量乘，标量在右）。
gizmo_v2_scale :: (v: W.Vec2, s: float32) -> W.Vec2 {
    return W.Vec2.{ v.x * s, v.y * s };
}

// olib 的 Vec2 `a * b`（逐分量）。
gizmo_v2_mul :: (a: W.Vec2, b: W.Vec2) -> W.Vec2 {
    return W.Vec2.{ a.x * b.x, a.y * b.y };
}

// olib 的 Vec2 `v / s`（逐分量除；不写成乘倒数，保持逐位相同的舍入）。
gizmo_v2_div :: (v: W.Vec2, s: float32) -> W.Vec2 {
    return W.Vec2.{ v.x / s, v.y / s };
}

// olib transform.odin / transform2d.odin 的 dot2
gizmo_v2_dot :: (a: W.Vec2, b: W.Vec2) -> float32 {
    return a.x * b.x + a.y * b.y;
}

gizmo_v2_equal :: (a: W.Vec2, b: W.Vec2) -> bool {
    return a.x == b.x && a.y == b.y;
}

// olib 的 Vec3 `+` / `-` / `* s` / `/ s`。W.v3_sub / W.v3_dot / W.v3_cross / W.v3_normalize
// 是 kit/world 已经提供的同名算子的显式形式，这里只补缺的几个。
gizmo_v3_add :: (a: W.Vec3, b: W.Vec3) -> W.Vec3 {
    return W.Vec3.{ a.x + b.x, a.y + b.y, a.z + b.z };
}

gizmo_v3_scale :: (v: W.Vec3, s: float32) -> W.Vec3 {
    return W.Vec3.{ v.x * s, v.y * s, v.z * s };
}

gizmo_v3_mul :: (a: W.Vec3, b: W.Vec3) -> W.Vec3 {
    return W.Vec3.{ a.x * b.x, a.y * b.y, a.z * b.z };
}

gizmo_v3_div :: (v: W.Vec3, s: float32) -> W.Vec3 {
    return W.Vec3.{ v.x / s, v.y / s, v.z / s };
}

// olib 的 `a == b`（Vec3 / Vec3 逐分量，含 NaN 语义）。
gizmo_v3_equal :: (a: W.Vec3, b: W.Vec3) -> bool {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

// olib 的 `rect != rect`。
gizmo_rect_equal :: (a: F.Rect, b: F.Rect) -> bool {
    return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

gizmo_color_equal :: (a: F.Color, b: F.Color) -> bool {
    return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
}

// olib 的 `foster.Vec2{p[0], p[1]}` / `foster.Vec3{p, q, r}`：Jai 的 Vector2/Vector3 是结构体，
// 从 [3]f32 顶点数组取值要显式搬。
gizmo_vec3_from_array :: (p: [3] float32) -> W.Vec3 {
    return W.Vec3.{ p[0], p[1], p[2] };
}

gizmo_vec3_to_array :: (v: W.Vec3) -> [3] float32 {
    return .[v.x, v.y, v.z];
}
//@endregion

//@region 类型与默认样式

// 零值可用，无堆资源；一套状态对应一个当前操作目标。目标改变时传 input.cancel。
Translation_Gizmo :: struct {
    dragging, captured: bool;
    axis: int; // dragging 时为 0/1/2，即世界 X/Y/Z。
    origin: W.Vec3;
    plane_normal: W.Vec3;
    start_distance: float32;
    viewport: F.Rect;
    view_projection: W.Matrix4;
}

Translation_Input :: struct {
    pointer: W.Vec2; // 最终输出像素，与 viewport 在同一坐标空间。
    pressed, down: bool; // 调用方提供按下边沿；同一个边沿只提交一次。
    enabled, allow_start: bool; // enabled=false 终止；allow_start=false 仅禁止开始。
    cancel: bool; // 取消只结束交互，不自动还原已应用的变换。
}

Translation_Result :: struct {
    position, delta: W.Vec3; // delta 相对按下时原点；changed 时由调用方决定是否应用。
    axis: int;
    started, changed, ended, cancelled, captured: bool;
}

Translation_Geometry :: struct {
    origin: W.Vec2;
    ends: [3] W.Vec2;
    visible: [3] bool;
}

// 文本中心位置；字号与字体由调用方选择。
Axis_Label :: struct {
    visible: bool;
    position: W.Vec2;
    color: F.Color;
}

Translation_Style :: struct {
    length, min_length, hit_radius: float32;
    line_width, outline_width, arrow_length, arrow_half_width, center_radius, label_gap: float32;
    colors: [3] F.Color;
    highlight, outline, center: F.Color;
}

DEFAULT_TRANSLATION_STYLE :: Translation_Style.{
    length = 100, min_length = 18, hit_radius = 9,
    line_width = 3, outline_width = 6, arrow_length = 12, arrow_half_width = 5,
    center_radius = 4, label_gap = 8,
    colors = .[F.Color.{ 255, 105, 104, 255 }, F.Color.{ 114, 232, 146, 255 }, F.Color.{ 108, 167, 255, 255 }],
    highlight = F.Color.{ 255, 180, 97, 255 },
    outline = F.Color.{ 13, 22, 29, 236 },
    center = F.Color.{ 234, 237, 227, 255 },
};
//@endregion

//@region 投影与命中

// Camera3D 的 viewport_size 必须匹配 rect 宽高；rect 允许非零偏移。
// 不改相机视口，不依赖场景内部渲染比例。无效尺寸、相机后方及裁剪范围外返回 false。
project :: (camera: *W.Camera3D, point: W.Vec3, viewport: F.Rect) -> (W.Vec2, bool) {
    if camera == null || viewport.w <= 0 || viewport.h <= 0 return W.Vec2.{ 0, 0 }, false;
    if cast(float32) camera.viewport_size.x != viewport.w ||
       cast(float32) camera.viewport_size.y != viewport.h {
        return W.Vec2.{ 0, 0 }, false;
    }
    h := W.matrix4_transform_vec4(W.camera3d_view_projection(camera),
                                 W.vec4(point.x, point.y, point.z, 1));
    if !gizmo_finite(h[3]) || h[3] <= 0.0001 return W.Vec2.{ 0, 0 }, false;
    // olib: !(h[2] >= 0 && h[2] <= h[3]) —— 写成同义的反向判断
    if !(h[2] >= 0 && h[2] <= h[3]) return W.Vec2.{ 0, 0 }, false;
    p := W.Vec2.{
        viewport.x + (h[0] / h[3] + 1) * 0.5 * viewport.w,
        viewport.y + (1 - h[1] / h[3]) * 0.5 * viewport.h,
    };
    return p, gizmo_finite(p.x) && gizmo_finite(p.y);
}

translation_geometry :: (
    camera: *W.Camera3D, position: W.Vec3, viewport: F.Rect,
    scale: float32 = 1, style := DEFAULT_TRANSLATION_STYLE,
) -> Translation_Geometry {
    g: Translation_Geometry;
    if !gizmo_finite(scale) || scale <= 0 || style.length <= 0 return g;
    start, ok := project(camera, position, viewport);
    if !ok return g;
    g.origin = start;
    depth := W.v3_dot(W.v3_sub(position, camera.position), W.camera3d_forward(camera));
    length := depth * 2 * JM.tan(camera.field_of_view * 0.5) * style.length * scale / viewport.h;
    for axis: 0..2 {
        end := position;
        end.component[axis] += length;
        end_point, end_ok := project(camera, end, viewport);
        g.ends[axis] = end_point;
        d := gizmo_v2_sub(end_point, start);
        // 接近视线方向的轴隐藏，避免退化拖拽；长度仍保留透视缩短。
        minimum := max(0.001, style.min_length) * scale;
        g.visible[axis] = end_ok && d.x * d.x + d.y * d.y >= minimum * minimum;
    }
    return g;
}

translation_hit :: (g: Translation_Geometry, pixel: W.Vec2, radius: float32) -> int {
    if !gizmo_finite(radius) || radius <= 0 return -1;
    best := radius * radius;
    result := -1;
    for axis: 0..2 {
        if !g.visible[axis] continue;
        end_point := g.ends[axis];
        d := gizmo_v2_sub(end_point, g.origin);
        p := gizmo_v2_sub(pixel, g.origin);
        length_sq := d.x * d.x + d.y * d.y;
        if length_sq <= 0 continue;
        t := clamp(gizmo_v2_dot(p, d) / length_sq, cast(float32) 0, cast(float32) 1);
        // 中心附近留空，避免三轴在原点互相抢命中。
        if t * JM.sqrt(length_sq) < radius * 1.5 continue;
        diff := gizmo_v2_sub(p, gizmo_v2_scale(d, t));
        distance := diff.x * diff.x + diff.y * diff.y;
        if distance < best {
            best = distance;
            result = axis;
        }
    }
    return result;
}
//@endregion

//@region 拖拽生命周期

// 每帧调用，包括释放、离焦或停用帧。相机/视口改变会结束拖动；按住期间保持捕获到松开。
// allow_start 由调用方根据 UI、对象选择等决定，开始后穿过 UI 不会丢失捕获。
translation_update :: (
    g: *Translation_Gizmo, camera: *W.Camera3D, position: W.Vec3,
    viewport: F.Rect, input: Translation_Input,
    scale: float32 = 1, style := DEFAULT_TRANSLATION_STYLE,
) -> Translation_Result {
    r := Translation_Result.{ position = position, axis = -1, captured = g.captured };
    if g.dragging {
        r.axis = g.axis;
        r.delta = W.v3_sub(position, g.origin);
    }
    invalid := !input.enabled || input.cancel || camera == null;
    if !invalid {
        invalid = !gizmo_finite(scale) || scale <= 0 || viewport.w <= 0 || viewport.h <= 0 ||
                  cast(float32) camera.viewport_size.x != viewport.w ||
                  cast(float32) camera.viewport_size.y != viewport.h;
    }
    if g.dragging && !invalid {
        invalid = !gizmo_rect_equal(viewport, g.viewport) ||
                  !W.matrix4_equal(W.camera3d_view_projection(camera), g.view_projection);
    }
    if invalid {
        r.ended = g.dragging;
        r.cancelled = g.dragging;
        g.dragging = false;
        if !input.down g.captured = false;
        return r;
    }
    if !input.down {
        r.ended = g.dragging;
        g.dragging = false;
        g.captured = false;
        return r;
    }
    if !gizmo_finite(input.pointer.x) || !gizmo_finite(input.pointer.y) return r;
    local := gizmo_v2_sub(input.pointer, W.Vec2.{ viewport.x, viewport.y });
    ray, ray_ok := W.camera3d_screen_point_to_ray(camera, local);
    if g.dragging {
        if ray_ok {
            d, distance_ok := gizmo_drag_distance(ray, g.origin, g.plane_normal, g.axis);
            if distance_ok {
                r.position = g.origin;
                r.position.component[g.axis] += d - g.start_distance;
                r.delta = W.v3_sub(r.position, g.origin);
                r.changed = !gizmo_v3_equal(r.position, position);
            }
        }
        return r;
    }
    if g.captured || !input.pressed || !input.allow_start || !ray_ok return r;
    if local.x < 0 || local.y < 0 || local.x > viewport.w || local.y > viewport.h return r;
    geometry := translation_geometry(camera, position, viewport, scale, style);
    axis := translation_hit(geometry, input.pointer, style.hit_radius * scale);
    if axis < 0 return r;
    normal := W.v3_sub(position, camera.position);
    normal.component[axis] = 0;
    length := JM.sqrt(W.v3_dot(normal, normal));
    if length <= 0.000001 return r;
    normal = gizmo_v3_div(normal, length);
    d, ok := gizmo_drag_distance(ray, position, normal, axis);
    if !ok return r;
    g.dragging = true;
    g.captured = true;
    g.axis = axis;
    g.origin = position;
    g.plane_normal = normal;
    g.start_distance = d;
    g.viewport = viewport;
    g.view_projection = W.camera3d_view_projection(camera);
    r.axis = axis;
    r.started = true;
    r.captured = true;
    return r;
}

// olib 的 @(private) drag_distance：沿选定轴取射线与拖拽平面的交点位移。
gizmo_drag_distance :: (ray: W.Ray3D, origin: W.Vec3, normal: W.Vec3, axis: int) -> (float32, bool) {
    distance, ok := W.ray3d_hit_plane(ray, origin, normal);
    if !ok return 0, false;
    point := W.ray3d_at(ray, distance);
    d := point.component[axis] - origin.component[axis];
    return d, gizmo_finite(d);
}
//@endregion
