// gizmo:transform2d —— 二维变换手柄：世界 X/Y 移动、绕原点 Z 旋转、局部 X/Y 与等比缩放。
// 一比一移植自 olib kit/gizmo/transform2d.odin。
//
// Jai 侧差异（逐条对应 olib 的写法；数值、绘制顺序与输入契约不变）：
//   | olib (Odin)                                    | JaiLib (Jai)                                          |
//   | ---------------------------------------------- | ----------------------------------------------------- |
//   | foster.Vec2 / foster.Rect / foster.Matrix3x2    | W.Vec2 / F.Rect{x,y,w,h} / F.Matrix3x2                |
//   | r2d "olib:kit/rendering/2d"                     | r2d "kit/rendering/2d"（*r2d.Render2D）                |
//   | `camera_matrix != world.camera2d_matrix(cam)`   | !W.matrix3x2_equal(g.camera_matrix, W.camera2d_matrix(camera)) |
//   | `camera2d_valid(camera, viewport)`（本文件私有）   | gizmo_camera2d_valid（kit/world 没有同名过程，按同一判据补） |
//   | `hover := state.dragging ? state.axis : hit()`  | 先取 hit 结果再 if 改写（Jai 没有三元）                   |
//   | `(pass == 0 ? outline_width : line_width)*scale` | thickness 先取默认值再 if 改写                        |
//   | `g.axis == 3 ? 0 : g.axis`                      | axis_index 先取默认值再 if 改写                        |
//   | `a, ok := …` 赋给数组元素                         | 先落临时变量再赋                                        |
//   | `@(private)`                                   | 去掉标注，内部过程加 gizmo_ 前缀                            |
// 导入（#import）由 module.jai 提供。

//@region 二维变换

// 与 Camera2D 一致：Y 向下，正角度在未旋转的相机中顺时针；rotation 单位弧度。
Transform2D :: struct {
    position: W.Vec2;
    rotation: float32;
    scale:    W.Vec2; // 必须为有限正值；单位变换显式传 {1, 1}。
}

gizmo_transform2d_equal :: (a: Transform2D, b: Transform2D) -> bool {
    return gizmo_v2_equal(a.position, b.position) && a.rotation == b.rotation &&
           gizmo_v2_equal(a.scale, b.scale);
}

// 零值可用，不持有对象、输入源或 GPU 资源。更换目标时由调用方传 cancel。
Transform_Gizmo2D :: struct {
    dragging, captured: bool;
    mode:               Mode;
    axis:               int; // 0/1 = X/Y；2 = Z 旋转；3 = 自由移动 / 等比缩放。
    start:              Transform2D;
    pointer, world_pointer, direction: W.Vec2;
    last_angle, angle, sensitivity, draw_scale: float32;
    viewport:           F.Rect;
    camera_matrix:      F.Matrix3x2;
}

Transform_Result2D :: struct {
    transform: Transform2D;
    axis:      int;
    angle, factor: float32;
    started, changed, ended, cancelled, captured: bool;
}

Transform_Geometry2D :: struct {
    mode:  Mode;
    axes:  Translation_Geometry; // 仅前两根轴有效，屏幕像素坐标。
    valid: bool;
    radius: float32;
}

gizmo_transform2d_valid :: (v: Transform2D) -> bool {
    return gizmo_finite2(v.position) && gizmo_finite(v.rotation) && gizmo_finite2(v.scale) &&
           v.scale.x > 0 && v.scale.y > 0;
}

// olib transform2d.odin 的 @(private) camera2d_valid：视口尺寸、相机数值与可逆性同一条判据。
gizmo_camera2d_valid :: (camera: *W.Camera2D, viewport: F.Rect) -> bool {
    if camera == null || !gizmo_finite(viewport.x) || !gizmo_finite(viewport.y) ||
       viewport.w <= 0 || viewport.h <= 0 {
        return false;
    }
    if cast(float32) camera.viewport_size.x != viewport.w ||
       cast(float32) camera.viewport_size.y != viewport.h ||
       !gizmo_finite2(camera.position) || !gizmo_finite(camera.rotation) ||
       !gizmo_finite(camera.zoom) || !gizmo_finite(camera.ppu) ||
       camera.zoom <= 0 || camera.ppu <= 0 {
        return false;
    }
    W.camera2d_update(camera);
    return camera.inverse_ok;
}
//@endregion

//@region 几何与命中

project2d :: (camera: *W.Camera2D, position: W.Vec2, viewport: F.Rect) -> (W.Vec2, bool) {
    if !gizmo_camera2d_valid(camera, viewport) || !gizmo_finite2(position) return W.Vec2.{0, 0}, false;
    p := gizmo_v2_add(W.camera2d_world_to_screen(camera, position), W.Vec2.{viewport.x, viewport.y});
    return p, gizmo_finite2(p);
}

transform2d_geometry :: (camera: *W.Camera2D, value: Transform2D, viewport: F.Rect,
                         mode: Mode, scale: float32 = 1,
                         style := DEFAULT_TRANSLATION_STYLE) -> Transform_Geometry2D {
    g := Transform_Geometry2D.{mode = mode};
    if !gizmo_transform2d_valid(value) || !gizmo_finite(scale) || scale <= 0 ||
       !gizmo_finite(style.length) || style.length <= 0 {
        return g;
    }
    center, ok := project2d(camera, value.position, viewport);
    if !ok return g;
    g.valid = true;
    g.axes.origin = center;
    g.radius = style.length * scale * 0.72;
    if mode == .Rotate return g;
    // 移动使用世界轴；缩放轴随对象旋转。轴长度固定为最终输出像素，不随 zoom 改变。
    angle := camera.rotation;
    if mode == .Scale angle += value.rotation;
    x := W.Vec2.{JM.cos(angle), JM.sin(angle)};
    y := W.Vec2.{-x.y, x.x};
    g.axes.ends[0] = gizmo_v2_add(center, gizmo_v2_scale(x, style.length * scale));
    g.axes.ends[1] = gizmo_v2_add(center, gizmo_v2_scale(y, style.length * scale));
    g.axes.visible[0] = true;
    g.axes.visible[1] = true;
    return g;
}

transform2d_hit :: (g: Transform_Geometry2D, pointer: W.Vec2, scale: float32 = 1,
                   style := DEFAULT_TRANSLATION_STYLE) -> int {
    if !g.valid || !gizmo_finite2(pointer) || !gizmo_finite(scale) || scale <= 0 return -1;
    d := gizmo_v2_sub(pointer, g.axes.origin);
    if g.mode == .Rotate {
        if JM.abs(JM.sqrt(gizmo_v2_dot(d, d)) - g.radius) < style.hit_radius * scale return 2;
        return -1;
    }
    if JM.abs(d.x) <= 8 * scale && JM.abs(d.y) <= 8 * scale return 3;
    return translation_hit(g.axes, pointer, style.hit_radius * scale);
}
//@endregion

//@region 拖拽生命周期

// 与三维工具共用 Mode、Translation_Input 和样式。每帧调用，包括释放/停用帧。
// 相机、视口、模式、UI 比例改变时中断，已经应用的结果不回滚，捕获保持至松开。
transform2d_update :: (g: *Transform_Gizmo2D, camera: *W.Camera2D,
                       value: Transform2D, viewport: F.Rect, mode: Mode, input: Translation_Input,
                       scale: float32 = 1, style := DEFAULT_TRANSLATION_STYLE,
                       min_scale: float32 = 0.001, max_scale: float32 = 10000) -> Transform_Result2D {
    r := Transform_Result2D.{transform = value, axis = -1, factor = 1, captured = g.captured};
    if g.dragging {
        r.axis = g.axis;
        r.angle = g.angle;
        if g.mode == .Scale {
            // olib: g.axis == 3 ? 0 : g.axis
            axis_index := g.axis;
            if g.axis == 3 axis_index = 0;
            r.factor = value.scale.component[axis_index] / g.start.scale.component[axis_index];
        }
    }
    invalid := !input.enabled || input.cancel || !gizmo_transform2d_valid(value) ||
               !gizmo_finite(scale) || scale <= 0 || !gizmo_finite(style.length) || style.length <= 0 ||
               !gizmo_finite(min_scale) || !gizmo_finite(max_scale) ||
               min_scale <= 0 || max_scale < min_scale ||
               !gizmo_camera2d_valid(camera, viewport);
    if g.dragging && !invalid {
        invalid = g.mode != mode || !gizmo_rect_equal(g.viewport, viewport) || g.draw_scale != scale ||
                  !W.matrix3x2_equal(g.camera_matrix, W.camera2d_matrix(camera));
    }
    if invalid || !input.down {
        r.ended = g.dragging;
        r.cancelled = invalid && g.dragging;
        g.dragging = false;
        if !input.down g.captured = false;
        return r;
    }
    if !gizmo_finite2(input.pointer) return r;
    local := gizmo_v2_sub(input.pointer, W.Vec2.{viewport.x, viewport.y});
    p, ok := W.camera2d_screen_to_world(camera, local);
    if !ok || !gizmo_finite2(p) return r;
    if g.dragging {
        candidate := g.start;
        if g.mode == .Translate {
            delta := gizmo_v2_sub(p, g.world_pointer);
            if g.axis == 3 {
                candidate.position = gizmo_v2_add(candidate.position, delta);
            } else {
                candidate.position.component[g.axis] += delta.component[g.axis];
            }
        } else if g.mode == .Rotate {
            d := gizmo_v2_sub(p, g.start.position);
            // 指针经过圆心时角度没有定义，保留最后有效采样。
            if gizmo_v2_dot(d, d) < 0.0000001 return r;
            a := JM.atan2(d.y, d.x);
            g.angle += gizmo_wrap_angle(a - g.last_angle);
            g.last_angle = a;
            r.angle = g.angle;
            candidate.rotation += g.angle;
        } else {
            factor := 1 + gizmo_v2_dot(gizmo_v2_sub(input.pointer, g.pointer), g.direction) / g.sensitivity;
            if !gizmo_finite(factor) return r;
            low: float32 = 0;
            high := cast(float32) JM.FLOAT32_INFINITY;
            for i: 0..1 {
                if g.axis != 3 && g.axis != i continue;
                low = max(low, min_scale / g.start.scale.component[i]);
                high = min(high, max_scale / g.start.scale.component[i]);
            }
            if low > high return r;
            // 按下后不动指针，不夹断从外部载入的超范围值。
            if !gizmo_v2_equal(input.pointer, g.pointer) {
                r.factor = clamp(factor, low, high);
                for i: 0..1 {
                    if g.axis == 3 || g.axis == i {
                        candidate.scale.component[i] = clamp(g.start.scale.component[i] * r.factor,
                                                             min_scale, max_scale);
                    }
                }
            }
        }
        if !gizmo_transform2d_valid(candidate) return r;
        r.transform = candidate;
        r.changed = !gizmo_transform2d_equal(candidate, value);
        return r;
    }
    if g.captured || !input.pressed || !input.allow_start return r;
    if local.x < 0 || local.y < 0 || local.x > viewport.w || local.y > viewport.h return r;
    geometry := transform2d_geometry(camera, value, viewport, mode, scale, style);
    axis := transform2d_hit(geometry, input.pointer, scale, style);
    if axis < 0 return r;
    g.start = value;
    g.pointer = input.pointer;
    g.world_pointer = p;
    g.axis = axis;
    g.mode = mode;
    g.angle = 0;
    g.last_angle = JM.atan2(p.y - value.position.y, p.x - value.position.x);
    g.direction = W.Vec2.{0.70710678, -0.70710678};
    if mode == .Scale && axis < 2 {
        d := gizmo_v2_sub(geometry.axes.ends[axis], geometry.axes.origin);
        g.direction = gizmo_v2_div(d, JM.sqrt(gizmo_v2_dot(d, d)));
    }
    g.sensitivity = style.length * scale;
    g.draw_scale = scale;
    g.viewport = viewport;
    g.camera_matrix = W.camera2d_matrix(camera);
    g.dragging = true;
    g.captured = true;
    r.axis = axis;
    r.started = true;
    r.captured = true;
    return r;
}
//@endregion

//@region 覆盖层绘制

// 最终像素覆盖层；调用方负责矩阵、材质和 viewport 裁剪。标签返回 XYZ 对应槽位。
transform2d_draw :: (batch: *r2d.Render2D, state: *Transform_Gizmo2D,
                     g: Transform_Geometry2D, pointer: W.Vec2, scale: float32 = 1,
                     style := DEFAULT_TRANSLATION_STYLE) -> [3] Axis_Label {
    labels: [3] Axis_Label;
    if !g.valid || !gizmo_finite(scale) || scale <= 0 return labels;
    hover := transform2d_hit(g, pointer, scale, style);
    if state.dragging hover = state.axis;
    if g.mode == .Rotate {
        color := style.colors[2];
        if hover == 2 color = style.highlight;
        // 先画完整描边再画前景，避免每段描边盖住相邻段的连接点。
        for pass: 0..1 {
            for i: 0..RING_SEGMENTS - 1 {
                a := cast(float32) i * 2 * JM.PI / cast(float32) RING_SEGMENTS;
                b := cast(float32) (i + 1) * 2 * JM.PI / cast(float32) RING_SEGMENTS;
                start := gizmo_v2_add(g.axes.origin,
                                      gizmo_v2_scale(W.Vec2.{JM.cos(a), JM.sin(a)}, g.radius));
                end := gizmo_v2_add(g.axes.origin,
                                    gizmo_v2_scale(W.Vec2.{JM.cos(b), JM.sin(b)}, g.radius));
                thickness := style.line_width * scale;
                line_color := color;
                if pass == 0 {
                    thickness = style.outline_width * scale;
                    line_color = style.outline;
                }
                r2d.line(batch, start, end, thickness, line_color);
            }
        }
        labels[2] = Axis_Label.{
            visible = true,
            position = gizmo_v2_add(g.axes.origin, W.Vec2.{0, -g.radius - style.label_gap * scale}),
            color = color,
        };
        return labels;
    }
    if g.mode == .Translate {
        translation := Translation_Gizmo.{dragging = state.dragging, axis = state.axis};
        labels = gizmo_draw_projected_axes(batch, *translation, g.axes, pointer, scale, style);
    } else {
        for axis: 0..1 {
            if !g.axes.visible[axis] continue;
            color := style.colors[axis];
            if hover == axis color = style.highlight;
            end_point := g.axes.ends[axis];
            r2d.line(batch, g.axes.origin, end_point, style.outline_width * scale, style.outline);
            r2d.line(batch, g.axes.origin, end_point, style.line_width * scale, color);
            gizmo_draw_square(batch, end_point, 5 * scale, color, style.outline);
            d := gizmo_v2_sub(end_point, g.axes.origin);
            labels[axis] = Axis_Label.{
                visible = true,
                position = gizmo_v2_add(end_point,
                    gizmo_v2_scale(gizmo_v2_div(d, JM.sqrt(gizmo_v2_dot(d, d))),
                                   style.label_gap * scale)),
                color = color,
            };
        }
    }
    center_color := style.center;
    if hover == 3 center_color = style.highlight;
    gizmo_draw_square(batch, g.axes.origin, 6 * scale, center_color, style.outline);
    return labels;
}

// olib 的 @(private) draw_projected_axes —— 二维的移动轴覆盖层（与三维共用同一命中几何）。
gizmo_draw_projected_axes :: (
    batch: *r2d.Render2D, g: *Translation_Gizmo, geometry: Translation_Geometry,
    pointer: W.Vec2, scale: float32 = 1, style := DEFAULT_TRANSLATION_STYLE,
) -> [3] Axis_Label {
    labels: [3] Axis_Label;
    if scale <= 0 || !gizmo_finite(scale) return labels;
    hover := translation_hit(geometry, pointer, style.hit_radius * scale);
    any_visible := false;
    for axis: 0..2 {
        if !geometry.visible[axis] continue;
        end_point := geometry.ends[axis];
        delta := gizmo_v2_sub(end_point, geometry.origin);
        length := JM.sqrt(delta.x * delta.x + delta.y * delta.y);
        if length <= 0 continue;
        any_visible = true;
        color := style.colors[axis];
        // olib: g.dragging ? g.axis == axis : hover == axis
        highlighted := hover == axis;
        if g.dragging highlighted = g.axis == axis;
        if highlighted color = style.highlight;
        direction := gizmo_v2_div(delta, length);
        base := gizmo_v2_sub(end_point, gizmo_v2_scale(direction, style.arrow_length * scale));
        side := gizmo_v2_scale(W.Vec2.{-direction.y, direction.x}, style.arrow_half_width * scale);
        r2d.line(batch, geometry.origin, base, style.outline_width * scale, style.outline);
        r2d.line(batch, geometry.origin, base, style.line_width * scale, color);
        r2d.triangle(batch, end_point, gizmo_v2_add(base, side), gizmo_v2_sub(base, side), color);
        labels[axis] = Axis_Label.{
            visible = true,
            position = gizmo_v2_add(end_point, gizmo_v2_scale(direction, style.label_gap * scale)),
            color = color,
        };
    }
    if any_visible {
        r2d.circle(batch, geometry.origin, style.center_radius * scale, 12, style.center);
    }
    return labels;
}

// olib 的 @(private) draw_square。
gizmo_draw_square :: (batch: *r2d.Render2D, center: W.Vec2, half: float32,
                      color: F.Color, outline: F.Color) {
    r2d.rect(batch, F.Rect.{center.x - half - 1, center.y - half - 1, 2 * half + 2, 2 * half + 2}, outline);
    r2d.rect(batch, F.Rect.{center.x - half, center.y - half, 2 * half, 2 * half}, color);
}
//@endregion
