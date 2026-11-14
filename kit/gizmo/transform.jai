// gizmo:transform —— 三维变换手柄：移动 / 旋转 / 缩放的世界空间几何、命中与拖拽状态。
// 一比一移植自 olib kit/gizmo/transform.odin。
//
// Jai 侧差异（逐条对应 olib 的写法；数值、分支顺序、默认值与输入契约不变）：
//   | olib (Odin)                                    | JaiLib (Jai)                                          |
//   | ---------------------------------------------- | ----------------------------------------------------- |
//   | foster.Vec3 / foster.Vec2                      | W.Vec3 / W.Vec2                                       |
//   | v[axis]（Odin 向量当数组用）                       | v.component[axis]                                     |
//   | `a + b` / `a - b` / `a - b` 等向量算术            | gizmo_v3_* / W.v3_sub（见 translation.jai 的说明）       |
//   | `switch mode { case .Translate: … }`           | if / else if 链（Jai 的 if-switch 各 case 共享块作用域， |
//   |                                                | 里面要声明同名局部变量，用 if 链更直接）                   |
//   | `math.pow(x, 2)`                               | gizmo_pow2（x*x；同样的平方，避免依赖 pow 实现）           |
//   | `math.PI / math.tan / math.sqrt / math.atan2`  | JM.PI / JM.tan / JM.sqrt / JM.atan2                   |
//   | `(r[1] > 0 ? r[2] : -r[2])`                    | 先取默认值再 if 改写（Jai 没有三元）                      |
//   | `g.rings[axis][i], ok = project(…)`            | 先落临时变量再赋（Jai 的多返回值不写进数组元素）             |
//   | `for ring, axis in g.rings`                    | for axis 索引 + 局部 `ring := g.rings[axis]`（Jai 的大元素  |
//   |                                                | 迭代按指针，数组元素不能直接当左值迭代变量）                 |
//   | `candidate != value`（结构体逐字段）              | !gizmo_transform_equal(candidate, value)               |
//   | `@(private)`                                   | 去掉标注，内部过程加 gizmo_ 前缀                            |
// 导入（#import）由 module.jai 提供。

//@region 变换与交互状态

Mode :: enum {
    Translate;
    Rotate;
    Scale;
}

// rotation 为弧度，固定轴依次 X、Y、Z（Rz * Ry * Rx）；scale 必须为正。
Transform :: struct {
    position, rotation, scale: W.Vec3;
}

// olib 的 `a == b`（Transform 逐字段）。
gizmo_transform_equal :: (a: Transform, b: Transform) -> bool {
    return gizmo_v3_equal(a.position, b.position) &&
           gizmo_v3_equal(a.rotation, b.rotation) &&
           gizmo_v3_equal(a.scale, b.scale);
}

// 零值可用，不持有对象或资源。拖拽中更换对象必须传 input.cancel。
Transform_Gizmo :: struct {
    dragging, captured: bool;
    mode: Mode;
    axis: int; // 0/1/2 对应 XYZ；3 为等比缩放。
    start: Transform;
    pointer, direction: W.Vec2;
    normal: W.Vec3;
    distance, last_angle, angle: float32;
    viewport: F.Rect;
    view_projection: W.Matrix4;
}

Transform_Result :: struct {
    transform: Transform;
    axis: int;
    angle, factor: float32; // 本次拖拽累计弧度 / 比例；其余模式为 0 / 1。
    started, changed, ended, cancelled, captured: bool;
}

RING_SEGMENTS :: 64;

Transform_Geometry :: struct {
    mode: Mode;
    axes: Translation_Geometry;
    center_visible: bool;
    rings: [3][RING_SEGMENTS + 1] W.Vec2;
    segments: [3][RING_SEGMENTS] bool;
}

// olib 的 math.pow(x, 2)。
gizmo_pow2 :: (x: float32) -> float32 {
    return x * x;
}
//@endregion

//@region 几何与命中

transform_geometry :: (
    camera: *W.Camera3D, value: Transform, viewport: F.Rect, mode: Mode,
    scale: float32 = 1, style := DEFAULT_TRANSLATION_STYLE,
) -> Transform_Geometry {
    g := Transform_Geometry.{ mode = mode };
    if mode == .Translate {
        g.axes = translation_geometry(camera, value.position, viewport, scale, style);
        return g;
    }
    if !gizmo_finite(scale) || scale <= 0 || !gizmo_finite(style.length) || style.length <= 0 return g;
    center, center_ok := project(camera, value.position, viewport);
    if !center_ok return g;
    g.axes.origin = center;
    g.center_visible = true;
    depth := W.v3_dot(W.v3_sub(value.position, camera.position), W.camera3d_forward(camera));
    length := depth * 2 * JM.tan(camera.field_of_view * 0.5) * style.length * scale / viewport.h;
    if mode == .Scale {
        for axis: 0..2 {
            v: W.Vec3;
            v.component[axis] = length;
            end_point, end_ok := project(camera, gizmo_v3_add(value.position, gizmo_rotate_xyz(v, value.rotation)),
                                         viewport);
            g.axes.ends[axis] = end_point;
            d := gizmo_v2_sub(end_point, center);
            g.axes.visible[axis] = end_ok &&
                gizmo_v2_dot(d, d) >= gizmo_pow2(style.min_length * scale);
        }
        return g;
    }
    for axis: 0..2 {
        normal: W.Vec3;
        normal.component[axis] = 1;
        // 近乎侧视的环无法稳定求交；飞行相机转向后自动恢复。
        view := W.v3_sub(value.position, camera.position);
        if JM.abs(W.v3_dot(normal, view)) < 0.12 * JM.sqrt(W.v3_dot(view, view)) continue;
        previous_ok := false;
        for i: 0..RING_SEGMENTS {
            a := cast(float32) i * 2 * JM.PI / cast(float32) RING_SEGMENTS;
            point := value.position;
            point.component[(axis + 1) % 3] += JM.cos(a) * length * 0.72;
            point.component[(axis + 2) % 3] += JM.sin(a) * length * 0.72;
            p, ring_ok := project(camera, point, viewport);
            g.rings[axis][i] = p;
            if i > 0 g.segments[axis][i - 1] = ring_ok && previous_ok;
            previous_ok = ring_ok;
        }
    }
    return g;
}

transform_hit :: (g: Transform_Geometry, pointer: W.Vec2, scale: float32 = 1,
                  style := DEFAULT_TRANSLATION_STYLE) -> int {
    if !gizmo_finite(scale) || scale <= 0 return -1;
    if g.mode == .Translate return translation_hit(g.axes, pointer, style.hit_radius * scale);
    if g.mode == .Scale {
        d := gizmo_v2_sub(pointer, g.axes.origin);
        if g.center_visible && JM.abs(d.x) <= 8 * scale && JM.abs(d.y) <= 8 * scale return 3;
        return translation_hit(g.axes, pointer, style.hit_radius * scale);
    }
    best := style.hit_radius * style.hit_radius * scale * scale;
    hit := -1;
    for axis: 0..2 {
        ring := g.rings[axis];
        for i: 0..RING_SEGMENTS - 1 {
            if !g.segments[axis][i] continue;
            d := gizmo_v2_sub(ring[i + 1], ring[i]);
            length := gizmo_v2_dot(d, d);
            if length <= 0.0001 continue;
            p := gizmo_v2_sub(pointer, ring[i]);
            diff := gizmo_v2_sub(p, gizmo_v2_scale(d, clamp(gizmo_v2_dot(p, d) / length,
                                                           cast(float32) 0, cast(float32) 1)));
            distance := gizmo_v2_dot(diff, diff);
            if distance < best {
                best = distance;
                hit = axis;
            }
        }
    }
    return hit;
}
//@endregion

//@region 拖拽生命周期

// 输入契约与 translation_update 相同。模式、相机、视口改变结束拖拽，捕获保持到释放。
// 缩放沿模型局部轴，中心手柄等比缩放；上下限共同约束比例，保留非均匀比例。
transform_update :: (
    g: *Transform_Gizmo, camera: *W.Camera3D, value: Transform, viewport: F.Rect,
    mode: Mode, input: Translation_Input, scale: float32 = 1,
    style := DEFAULT_TRANSLATION_STYLE,
    min_scale: float32 = 0.001, max_scale: float32 = 10000,
) -> Transform_Result {
    r := Transform_Result.{ transform = value, axis = -1, factor = 1, captured = g.captured };
    if g.dragging {
        r.axis = g.axis;
        r.angle = g.angle;
        if g.mode == .Scale {
            r.factor = value.scale.component[g.axis % 3] / g.start.scale.component[g.axis % 3];
        }
    }
    invalid := !input.enabled || input.cancel || camera == null || !gizmo_finite(scale) || scale <= 0 ||
               !gizmo_finite(style.length) || style.length <= 0;
    if !invalid {
        invalid = viewport.w <= 0 || viewport.h <= 0 ||
                  cast(float32) camera.viewport_size.x != viewport.w ||
                  cast(float32) camera.viewport_size.y != viewport.h;
        for i: 0..2 {
            invalid = invalid || !gizmo_finite(value.position.component[i]) ||
                      !gizmo_finite(value.rotation.component[i]) ||
                      !gizmo_finite(value.scale.component[i]) || value.scale.component[i] <= 0;
        }
        invalid = invalid || !gizmo_finite(min_scale) || !gizmo_finite(max_scale) ||
                  min_scale <= 0 || max_scale < min_scale;
    }
    if g.dragging && !invalid {
        invalid = mode != g.mode || !gizmo_rect_equal(viewport, g.viewport) ||
                  !W.matrix4_equal(W.camera3d_view_projection(camera), g.view_projection);
    }
    if invalid || !input.down {
        r.ended = g.dragging;
        r.cancelled = invalid && g.dragging;
        g.dragging = false;
        if !input.down g.captured = false;
        return r;
    }
    if !gizmo_finite(input.pointer.x) || !gizmo_finite(input.pointer.y) return r;
    local := gizmo_v2_sub(input.pointer, W.Vec2.{ viewport.x, viewport.y });
    ray, ray_ok := W.camera3d_screen_point_to_ray(camera, local);
    if g.dragging {
        candidate := g.start;
        // olib: switch g.mode —— 各分支里都要新声明局部变量，用 if 链避免同块重名。
        if g.mode == .Translate {
            if !ray_ok return r;
            d, distance_ok := gizmo_drag_distance(ray, g.start.position, g.normal, g.axis);
            if !distance_ok return r;
            candidate.position.component[g.axis] += d - g.distance;
        } else if g.mode == .Rotate {
            if !ray_ok return r;
            a, angle_ok := gizmo_ring_angle(ray, g.start.position, g.axis);
            if !angle_ok return r;
            g.angle += gizmo_wrap_angle(a - g.last_angle);
            g.last_angle = a;
            r.angle = g.angle;
            if g.angle != 0 {
                candidate.rotation = gizmo_rotate_world(g.start.rotation, g.axis, g.angle, value.rotation);
            }
        } else {
            factor := 1 + gizmo_v2_dot(gizmo_v2_sub(input.pointer, g.pointer), g.direction) /
                (style.length * scale);
            low: float32 = 0;
            high := cast(float32) JM.FLOAT32_INFINITY;
            for i: 0..2 {
                if g.axis != 3 && g.axis != i continue;
                low = max(low, min_scale / g.start.scale.component[i]);
                high = min(high, max_scale / g.start.scale.component[i]);
            }
            if low > high || !gizmo_finite(factor) return r;
            r.factor = clamp(factor, low, high);
            for i: 0..2 {
                if g.axis == 3 || g.axis == i {
                    candidate.scale.component[i] = clamp(candidate.scale.component[i] * r.factor,
                                                         min_scale, max_scale);
                }
            }
        }
        r.transform = candidate;
        r.changed = !gizmo_transform_equal(candidate, value);
        return r;
    }
    if g.captured || !input.pressed || !input.allow_start || !ray_ok return r;
    if local.x < 0 || local.y < 0 || local.x > viewport.w || local.y > viewport.h return r;
    geometry := transform_geometry(camera, value, viewport, mode, scale, style);
    axis := transform_hit(geometry, input.pointer, scale, style);
    if axis < 0 return r;
    if mode == .Translate {
        normal := W.v3_sub(value.position, camera.position);
        normal.component[axis] = 0;
        length := JM.sqrt(W.v3_dot(normal, normal));
        if length <= 0.000001 return r;
        g.normal = gizmo_v3_div(normal, length);
        d, distance_ok := gizmo_drag_distance(ray, value.position, g.normal, axis);
        if !distance_ok return r;
        g.distance = d;
    } else if mode == .Rotate {
        a, angle_ok := gizmo_ring_angle(ray, value.position, axis);
        if !angle_ok return r;
        g.last_angle = a;
        g.angle = 0;
    } else {
        g.direction = W.Vec2.{ 0.70710678, -0.70710678 };
        if axis < 3 {
            d := gizmo_v2_sub(geometry.axes.ends[axis], geometry.axes.origin);
            g.direction = gizmo_v2_div(d, JM.sqrt(gizmo_v2_dot(d, d)));
        }
    }
    g.start = value;
    g.angle = 0;
    g.pointer = input.pointer;
    g.axis = axis;
    g.mode = mode;
    g.viewport = viewport;
    g.view_projection = W.camera3d_view_projection(camera);
    g.dragging = true;
    g.captured = true;
    r.axis = axis;
    r.started = true;
    r.captured = true;
    return r;
}
//@endregion

//@region 旋转数学

// olib 的 @(private) ring_angle：射线与旋转环所在平面求交后的平面角。
gizmo_ring_angle :: (ray: W.Ray3D, origin: W.Vec3, axis: int) -> (float32, bool) {
    normal: W.Vec3;
    normal.component[axis] = 1;
    d, ok := W.ray3d_hit_plane(ray, origin, normal);
    if !ok return 0, false;
    p := W.v3_sub(W.ray3d_at(ray, d), origin);
    if W.v3_dot(p, p) < 0.0000001 return 0, false;
    a := JM.atan2(p.component[(axis + 2) % 3], p.component[(axis + 1) % 3]);
    return a, gizmo_finite(a);
}

gizmo_wrap_angle :: (a: float32) -> float32 {
    return a - 2 * JM.PI * JM.floor((a + JM.PI) / (2 * JM.PI));
}

gizmo_rotate_xyz :: (v: W.Vec3, angles: W.Vec3) -> W.Vec3 {
    r := v;
    for axis: 0..2 {
        a := (axis + 1) % 3;
        b := (axis + 2) % 3;
        x := r.component[a] * JM.cos(angles.component[axis]) -
             r.component[b] * JM.sin(angles.component[axis]);
        r.component[b] = r.component[a] * JM.sin(angles.component[axis]) +
                         r.component[b] * JM.cos(angles.component[axis]);
        r.component[a] = x;
    }
    return r;
}

// 左乘世界轴旋转；输出选择靠近 reference 的等价 Euler 分支，跨 ±π 时保持连续。
gizmo_rotate_world :: (initial: W.Vec3, axis: int, angle: float32, reference: W.Vec3) -> W.Vec3 {
    delta: W.Vec3;
    delta.component[axis] = angle;
    x := gizmo_rotate_xyz(gizmo_rotate_xyz(W.Vec3.{ 1, 0, 0 }, initial), delta);
    y := gizmo_rotate_xyz(gizmo_rotate_xyz(W.Vec3.{ 0, 1, 0 }, initial), delta);
    z := gizmo_rotate_xyz(gizmo_rotate_xyz(W.Vec3.{ 0, 0, 1 }, initial), delta);
    cy := JM.sqrt(x.component[0] * x.component[0] + x.component[1] * x.component[1]);
    r := W.Vec3.{ 0, JM.atan2(-x.component[2], cy), 0 };
    if cy > 0.000001 {
        r.component[0] = JM.atan2(y.component[2], z.component[2]);
        r.component[2] = JM.atan2(x.component[1], x.component[0]);
    } else {
        // 万向锁处保留上一帧 Z，求出等价 X，避免强制归零导致面板跳变。
        r.component[2] = reference.component[2];
        // olib: (r[1] > 0 ? r[2] : -r[2])
        sign_z := -r.component[2];
        if r.component[1] > 0 sign_z = r.component[2];
        r.component[0] = JM.atan2(-z.component[1], y.component[1]) + sign_z;
    }
    alternative := W.Vec3.{ r.component[0] + JM.PI, JM.PI - r.component[1], r.component[2] + JM.PI };
    for i: 0..2 {
        r.component[i] = reference.component[i] + gizmo_wrap_angle(r.component[i] - reference.component[i]);
        alternative.component[i] = reference.component[i] +
            gizmo_wrap_angle(alternative.component[i] - reference.component[i]);
    }
    diff_r := W.v3_sub(r, reference);
    diff_alt := W.v3_sub(alternative, reference);
    if W.v3_dot(diff_alt, diff_alt) < W.v3_dot(diff_r, diff_r) return alternative;
    return r;
}
//@endregion
