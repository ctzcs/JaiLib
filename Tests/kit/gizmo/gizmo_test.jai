// 一比一移植自 olib tests/kit/gizmo/gizmo_test.odin（12 例）+ wireframe_test.odin（2 例）。
// 用例名与 olib 一一对应，断言顺序保持；文件末尾的 5 个用例覆盖 olib 没有写测试的 CPU 面
// （translation_hit 阈值、transform_hit 的环 / 缩放中心、环角与角度环绕、线框常量字节布局、
// GPU 资源诊断与内嵌着色器字节码），它们不替换、不重排 olib 的断言。
//
// Jai 侧写法差异（与 olib 的 Odin 一一对应）：
//   | olib (Odin, core:testing)                  | 这里 (Jai, Tests/test_support.jai)                  |
//   | ------------------------------------------ | --------------------------------------------------- |
//   | testing.expect(t, cond, "msg")             | expect(state, cond, "msg")                          |
//   | testing.expect_value(t, a, b)              | expect(state, a == b, "msg")                        |
//   | testing.expectf(t, cond, "...%v", a)       | expectf(state, cond, "...% -> %", a, b)              |
//   | foster.Rect{80, 40, 960, 600}              | rect(80, 40, 960, 600)（F.Rect 的 x/y/w/h）         |
//   | foster.Vec3{…} / foster.Vec2{…}            | v3(…) / v2(…)，零值 v3_zero() / v2_zero()            |
//   | `v[axis]`                                  | `v.component[axis]`                                 |
//   | `a + b` / `a - b` / `a * s`                | add2 / sub2 / vsub / vscale（见工具区）              |
//   | `a == b`（结构体逐字段）                    | v2_eq / v3_eq / transform_eq / transform2d_eq        |
//   | `[4]f32{…}` / `{1, 2}`                     | `.[…]`（数组字面量要类型标注）                        |
//   | `len(x)`                                   | `x.count`                                           |
//   | `math.PI` / `math.INF_F32` / `math.nan_f32`| `PI_F` / `JM.FLOAT32_INFINITY` / `JM.FLOAT32_NAN`    |
//   | `switch`/`case`                            | if / else 链（Jai 的 if-switch 各 case 共享作用域）   |
//   | `g = {}`（零值重置）                        | `g = Translation_Gizmo.{}`                          |
//   | 嵌套 proc（read_vec4）                      | 顶层过程                                            |
//   | `nil` 设备                                  | `null`；假设备要显式 `disposed = false`              |
//   | olib 的测试与被测代码同在 `package gizmo`，   | Jai 侧 `#import "kit/gizmo"` 后，内部过程按移植约定用  |
//   | 所以能直接调 `@(private) drag_distance`、     | `gizmo_` 前缀调用：gizmo_drag_distance、              |
//   | `ring_angle`、`wrap_angle`、`rotate_xyz`、   | gizmo_ring_angle、gizmo_wrap_angle、gizmo_rotate_xyz、|
//   | `rotate_world`                              | gizmo_rotate_world（行为与 olib 的同名私有过程一致）   |
#import "Basic";
#import "test_support";
JM :: #import "Math";
F :: #import "jfoster";
W :: #import "kit/world";
MSH :: #import "core/meshutil";
#import "kit/gizmo";

//@region 工具

PI_F :: cast(float32) JM.PI;

// Tests/test_support.jai 的 expect 把 ..Any 当成一个整体再喂给 sprint（格式串的第二个 % 会报
// 「argument index is out of range」），这里先用 `..args` 正确展开再把结果交给同一个 expect。
expectf :: (state: *Test_State, condition: bool, msg: string, args: ..Any) {
    expect(state, condition, sprint(msg, ..args));
}

v2 :: (x: float32, y: float32) -> W.Vec2 { return W.Vec2.{ x, y }; }
v3 :: (x: float32, y: float32, z: float32) -> W.Vec3 { return W.Vec3.{ x, y, z }; }
v2_zero :: () -> W.Vec2 { z: W.Vec2; return z; }
v3_zero :: () -> W.Vec3 { z: W.Vec3; return z; }
rect :: (x: float32, y: float32, w: float32, h: float32) -> F.Rect { return F.Rect.{ x, y, w, h }; }

v2_eq :: (a: W.Vec2, b: W.Vec2) -> bool { return W.vec2_equal(a, b); }
v3_eq :: (a: W.Vec3, b: W.Vec3) -> bool { return W.vec3_equal(a, b); }

// olib 的 `dot2(d, d)`：二维长度平方。
len2_sq :: (d: W.Vec2) -> float32 { return d.x * d.x + d.y * d.y; }

add2 :: (a: W.Vec2, b: W.Vec2) -> W.Vec2 { return W.Vec2.{ a.x + b.x, a.y + b.y }; }
sub2 :: (a: W.Vec2, b: W.Vec2) -> W.Vec2 { return W.Vec2.{ a.x - b.x, a.y - b.y }; }
scale2 :: (v: W.Vec2, s: float32) -> W.Vec2 { return W.Vec2.{ v.x * s, v.y * s }; }

vadd :: (a: W.Vec3, b: W.Vec3) -> W.Vec3 { return W.Vec3.{ a.x + b.x, a.y + b.y, a.z + b.z }; }
vsub :: (a: W.Vec3, b: W.Vec3) -> W.Vec3 { return W.Vec3.{ a.x - b.x, a.y - b.y, a.z - b.z }; }
vscale :: (v: W.Vec3, s: float32) -> W.Vec3 { return W.Vec3.{ v.x * s, v.y * s, v.z * s }; }

// olib: `origin + (end - origin) * t`（二维手柄拾取点）。
lerp2 :: (origin: W.Vec2, end: W.Vec2, t: float32) -> W.Vec2 {
    return add2(origin, scale2(sub2(end, origin), t));
}

finite :: (x: float32) -> bool { return !JM.isnan(x) && !JM.isinf(x); }
finite3 :: (v: W.Vec3) -> bool { return finite(v.x) && finite(v.y) && finite(v.z); }

transform_eq :: (a: Transform, b: Transform) -> bool {
    return v3_eq(a.position, b.position) && v3_eq(a.rotation, b.rotation) && v3_eq(a.scale, b.scale);
}

transform2d_eq :: (a: Transform2D, b: Transform2D) -> bool {
    return v2_eq(a.position, b.position) && a.rotation == b.rotation && v2_eq(a.scale, b.scale);
}

// olib 的 test_camera：960x600 视野里的斜视角相机。
test_camera :: (width: s32, height: s32) -> W.Camera3D {
    c: W.Camera3D;
    W.camera3d_init(*c, width, height);
    W.camera3d_set_position(*c, v3(3, 3, 6));
    W.camera3d_set_target(*c, v3_zero());
    return c;
}

// olib 的 read_vec4：从常量块的小端 4 个 f32。
read_vec4 :: (buf: [] u8, offset: int) -> [4] float32 {
    v: [4] float32;
    memcpy(*v, buf.data + offset, 16);
    return v;
}

floats4_eq :: (a: [4] float32, b: [4] float32) -> bool {
    for i: 0..3 {
        if !(a[i] == b[i]) return false;
    }
    return true;
}

floats3_eq :: (a: [3] float32, b: [3] float32) -> bool {
    for i: 0..2 {
        if !(a[i] == b[i]) return false;
    }
    return true;
}

vec4_xyz_eq3 :: (a: [4] float32, b: W.Vec3) -> bool {
    return a[0] == b.x && a[1] == b.y && a[2] == b.z;
}
//@endregion

//@region 投影与命中

translation_viewport_and_projection :: (state: *Test_State) {
    c := test_camera(960, 600);
    viewport := rect(80, 40, 960, 600);
    center, ok := project(*c, v3_zero(), viewport);
    expect(state, ok && JM.abs(center.x - 560) < 0.001 && JM.abs(center.y - 340) < 0.001,
           "原点投影到视口中心");
    g := translation_geometry(*c, v3_zero(), viewport, 1.25);
    for axis: 0..2 {
        expect(state, g.visible[axis], "三根轴都可见");
        end := g.ends[axis];
        // olib: g.origin + (end-g.origin)*0.8
        expect(state, translation_hit(g, lerp2(g.origin, end, 0.8), 9 * 1.25) == axis,
               "轴 0.8 处命中本轴");
    }
    expect(state, translation_hit(g, center, 9) == -1,
           "center gap prevents ambiguous axis selection");
    _, behind := project(*c, v3(c.position.x * 2, c.position.y * 2, c.position.z * 2), viewport);
    expect(state, !behind, "相机后方的点不投影");
    _, mismatch := project(*c, v3_zero(), rect(0, 0, 480, 300));
    expect(state, !mismatch, "camera viewport mismatch cannot silently offset handles");
    _, empty_viewport := project(*c, v3_zero(), rect(0, 0, 0, 0));
    expect(state, !empty_viewport, "零尺寸视口不投影");
    W.camera3d_set_position(*c, v3(0, 0, 6));
    g = translation_geometry(*c, v3_zero(), viewport);
    expect(state, g.visible[0] && g.visible[1] && !g.visible[2], "view-aligned axis is hidden");
}
//@endregion

//@region 拖拽结果

translation_drag_all_axes :: (state: *Test_State) {
    sizes: [2][2] s32 = .[ .[1280, 720], .[960, 600] ];
    for size: sizes {
        c := test_camera(size[0], size[1]);
        viewport := rect(30, 55, cast(float32) size[0], cast(float32) size[1]);
        origin := v3(0.2, -0.1, 0.3);
        geometry := translation_geometry(*c, origin, viewport);
        for axis: 0..2 {
            g: Translation_Gizmo;
            p := lerp2(geometry.origin, geometry.ends[axis], 0.8);
            input := Translation_Input.{
                pointer = p, pressed = true, down = true, enabled = true, allow_start = true,
            };
            r := translation_update(*g, *c, origin, viewport, input);
            expect(state, r.started && !r.changed && r.captured && r.axis == axis, "按下即开始");
            expect(state, v3_eq(r.position, origin), "grabbing handle must not jump");
            ray, _ := W.camera3d_screen_point_to_ray(
                *c, v2(p.x - viewport.x, p.y - viewport.y));
            n := vsub(origin, c.position);
            n.component[axis] = 0;
            d, hit := W.ray3d_hit_plane(ray, origin, n);
            point := W.ray3d_at(ray, d);
            point.component[axis] += 0.75;
            end, end_ok := project(*c, point, viewport);
            expect(state, hit && end_ok, "拖拽平面与投影都成立");
            r = translation_update(*g, *c, origin, viewport, Translation_Input.{
                pointer = end, down = true, enabled = true, allow_start = false,
            });
            expect(state, r.changed && r.captured && !r.started && !r.ended,
                   "capture continues while pointer crosses UI");
            for component: 0..2 {
                expected: float32 = 0;
                if component == axis expected = 0.75;
                expectf(state, JM.abs(r.delta.component[component] - expected) < 0.001,
                        "轴 % 分量 % 位移 % -> %", axis, component,
                        r.delta.component[component], expected);
            }
            position := r.position;
            r = translation_update(*g, *c, position, viewport, Translation_Input.{ enabled = true });
            expect(state, r.ended && !r.cancelled && r.captured && !g.dragging && !g.captured,
                   "松开结束拖拽并释放捕获");
            expect(state, JM.abs(r.delta.component[axis] - 0.75) < 0.001,
                   "release reports accepted total displacement");
            r = translation_update(*g, *c, position, viewport, Translation_Input.{ enabled = true });
            expect(state, !r.captured && !r.ended, "release event is emitted once");
        }
    }
}
//@endregion

//@region 中断与捕获

translation_cancel_and_reacquire :: (state: *Test_State) {
    c := test_camera(1280, 720);
    viewport := rect(0, 0, 1280, 720);
    geometry := translation_geometry(*c, v3_zero(), viewport);
    p := lerp2(geometry.origin, geometry.ends[0], 0.8);
    g: Translation_Gizmo;
    input := Translation_Input.{
        pointer = p, down = true, pressed = true, enabled = true, allow_start = false,
    };
    r := translation_update(*g, *c, v3_zero(), viewport, input);
    expect(state, !r.captured && !r.started, "UI can prevent capture");
    input.allow_start = true;
    r = translation_update(*g, *c, v3_zero(), viewport, input);
    expect(state, r.started, "允许后开始");
    input.cancel = true;
    r = translation_update(*g, *c, v3_zero(), viewport, input);
    expect(state, r.ended && r.cancelled && r.captured && !r.changed, "取消结束拖拽");
    input.cancel = false;
    r = translation_update(*g, *c, v3_zero(), viewport, input);
    expect(state, !r.started && r.captured, "changing target cannot reacquire while held");
    translation_update(*g, *c, v3_zero(), viewport, Translation_Input.{ enabled = true });
    r = translation_update(*g, *c, v3_zero(), viewport, input);
    expect(state, r.started, "松开后可以重新捕获");
    input.enabled = false;
    r = translation_update(*g, *c, v3_zero(), viewport, input);
    expect(state, r.ended && r.cancelled && !r.changed,
           "focus loss ends without reverting object");
}

translation_camera_resize_and_invalid_pointer :: (state: *Test_State) {
    c := test_camera(1280, 720);
    viewport := rect(0, 0, 1280, 720);
    geometry := translation_geometry(*c, v3_zero(), viewport);
    p := lerp2(geometry.origin, geometry.ends[0], 0.8);
    input := Translation_Input.{
        pointer = p, down = true, pressed = true, enabled = true, allow_start = true,
    };
    g: Translation_Gizmo;
    translation_update(*g, *c, v3_zero(), viewport, input);
    input.pointer.x = JM.FLOAT32_INFINITY;
    r := translation_update(*g, *c, v3_zero(), viewport, input);
    expect(state, !r.changed && g.dragging, "invalid pointer never produces invalid positions");
    W.camera3d_set_position(*c, v3(4, 3, 6));
    r = translation_update(*g, *c, v3_zero(), viewport, input);
    expect(state, r.cancelled && r.ended && !r.changed,
           "moving camera ends drag instead of jumping");
    g = Translation_Gizmo.{};
    geometry = translation_geometry(*c, v3_zero(), viewport);
    input.pointer = lerp2(geometry.origin, geometry.ends[0], 0.8);
    translation_update(*g, *c, v3_zero(), viewport, input);
    W.camera3d_set_viewport(*c, 640, 360);
    r = translation_update(*g, *c, v3_zero(), rect(0, 0, 640, 360), input);
    expect(state, r.cancelled && r.ended && !r.changed, "resize ends drag");
    parallel_ray := W.Ray3D.{ origin = v3(0, 0, -2), direction = v3(1, 0, 0) };
    _, parallel := gizmo_drag_distance(parallel_ray, v3_zero(), v3(0, 0, 1), 0);
    expect(state, !parallel, "平行于拖拽平面的射线没有位移");
}
//@endregion

//@region 旋转与缩放

rotation_world_composition :: (state: *Test_State) {
    // 混合姿态与 ±90° 万向锁，验证旋转后的基向量，不要求唯一 Euler 表达。
    initials: [4] W.Vec3 = .[ v3(0.4, -0.7, 1.1), v3(0.6, PI_F / 2, 0.2),
                              v3(0.6, -PI_F / 2, 0.2), v3(3.1, 1.5, -2.9) ];
    angles: [4] float32 = .[ 0, 0.3, -1.2, 3.4 ];
    for initial: initials {
        for axis: 0..2 {
            for angle: angles {
                result := gizmo_rotate_world(initial, axis, angle, initial);
                for component: 0..2 {
                    basis: W.Vec3;
                    basis.component[component] = 1;
                    before := gizmo_rotate_xyz(basis, initial);
                    // Rodrigues 公式独立验证世界轴左乘，不能把 world angle 加进 Euler 分量。
                    normal: W.Vec3;
                    normal.component[axis] = 1;
                    cross := v3(normal.y * before.z - normal.z * before.y,
                                normal.z * before.x - normal.x * before.z,
                                normal.x * before.y - normal.y * before.x);
                    expected := vadd(vadd(vscale(before, JM.cos(angle)),
                                          vscale(cross, JM.sin(angle))),
                                     vscale(normal, W.v3_dot(normal, before) *
                                                    (1 - JM.cos(angle))));
                    diff := vsub(gizmo_rotate_xyz(basis, result), expected);
                    expectf(state, W.v3_dot(diff, diff) < 0.000001,
                            "world rotation preserves orientation at Euler singularities (% -> %)",
                            axis, angle);
                }
            }
        }
    }
}

rotation_drag_wrap_and_capture :: (state: *Test_State) {
    c := test_camera(960, 600);
    viewport := rect(41, 73, 960, 600);
    initial := Transform.{ rotation = v3(0.4, -0.7, 1.1), scale = v3(1, 2, 3) };
    geometry := transform_geometry(*c, initial, viewport, .Rotate, 1.25);
    for axis: 0..2 {
        start: W.Vec2;
        found := false;
        for i: 0..RING_SEGMENTS - 1 {
            p := geometry.rings[axis][i];
            if geometry.segments[axis][i] && transform_hit(geometry, p, 1.25) == axis {
                start = p;
                found = true;
                break;
            }
        }
        expectf(state, found, "each visible ring has a selectable segment (axis %)", axis);
        if !found continue;
        g: Transform_Gizmo;
        r := transform_update(*g, *c, initial, viewport, .Rotate, Translation_Input.{
            pointer = start, pressed = true, down = true, enabled = true, allow_start = true,
        }, 1.25);
        expect(state, r.started && !r.changed && transform_eq(r.transform, initial) && g.axis == axis,
               "按在环上即开始且不改变姿态");
        ray, _ := W.camera3d_screen_point_to_ray(
            *c, v2(start.x - viewport.x, start.y - viewport.y));
        normal: W.Vec3;
        normal.component[axis] = 1;
        d, _ := W.ray3d_hit_plane(ray, initial.position, normal);
        p := vsub(W.ray3d_at(ray, d), initial.position);
        base_angle := g.last_angle;
        radius := JM.sqrt(W.v3_dot(p, p));
        value := initial;
        for step: 1..80 {
            a := base_angle + cast(float32) step * 0.1;
            point := initial.position;
            point.component[(axis + 1) % 3] += JM.cos(a) * radius;
            point.component[(axis + 2) % 3] += JM.sin(a) * radius;
            pixel, pixel_ok := project(*c, point, viewport);
            expect(state, pixel_ok, "环上的采样点可投影");
            r = transform_update(*g, *c, value, viewport, .Rotate, Translation_Input.{
                pointer = pixel, down = true, enabled = true,
            }, 1.25);
            expectf(state, r.captured && r.changed &&
                    JM.abs(r.angle - cast(float32) step * 0.1) < 0.001,
                    "unwrapped angle crosses ±PI and multiple turns without jumping (% -> %)",
                    r.angle, cast(float32) step * 0.1);
            expect(state, v3_eq(r.transform.position, initial.position) &&
                   v3_eq(r.transform.scale, initial.scale), "旋转只改变姿态");
            value = r.transform;
        }
        r = transform_update(*g, *c, value, viewport, .Rotate,
                             Translation_Input.{ enabled = true }, 1.25);
        expect(state, r.ended && !r.cancelled && r.captured, "松开结束旋转拖拽");
    }
}

scale_local_axes_uniform_and_bounds :: (state: *Test_State) {
    c := test_camera(1280, 720);
    viewport := rect(30, 50, 1280, 720);
    initial := Transform.{
        position = v3(0.1, 0.2, 0), rotation = v3(0.2, 0.4, 0.3), scale = v3(1, 2, 3),
    };
    geometry := transform_geometry(*c, initial, viewport, .Scale);
    distances: [3] float32 = .[ 50, -1000, 10000000 ];
    for axis: 0..3 {
        start := geometry.axes.origin;
        if axis < 3 {
            expect(state, geometry.axes.visible[axis], "局部轴可见");
            start = geometry.axes.ends[axis];
        }
        expect(state, transform_hit(geometry, start) == axis, "命中本轴");
        g: Transform_Gizmo;
        r := transform_update(*g, *c, initial, viewport, .Scale, Translation_Input.{
            pointer = start, pressed = true, down = true, enabled = true, allow_start = true,
        });
        expect(state, r.started && !r.changed, "按下缩放手柄即开始");
        for distance: distances {
            pointer := add2(start, scale2(g.direction, distance));
            r = transform_update(*g, *c, initial, viewport, .Scale, Translation_Input.{
                pointer = pointer, down = true, enabled = true,
            });
            expect(state, v3_eq(r.transform.position, initial.position) &&
                   v3_eq(r.transform.rotation, initial.rotation), "缩放不动位置/姿态");
            for component: 0..2 {
                v := r.transform.scale.component[component];
                expectf(state, v >= 0.001 && v <= 10000, "比例 % 在上下限内（% 轴）",
                        v, axis);
                if axis != 3 && component != axis {
                    expect(state, v == initial.scale.component[component],
                           "非缩放轴保持不变");
                }
                if distance == 50 && (axis == 3 || component == axis) {
                    expectf(state, JM.abs(v - initial.scale.component[component] * 1.5) < 0.001,
                            "位移 50px 得到 1.5 倍（% 轴，得到 %）", axis, v);
                }
            }
            if axis == 3 {
                expect(state, JM.abs(r.transform.scale.z / r.transform.scale.x - 3) < 0.001,
                       "等比缩放保留非均匀比例");
            }
        }
        // 回到原始指针恢复原值，不以逐帧乘法累积误差。
        r = transform_update(*g, *c, r.transform, viewport, .Scale, Translation_Input.{
            pointer = start, down = true, enabled = true,
        });
        expect(state, transform_eq(r.transform, initial), "回到原始指针恢复原值");
    }
}

transform_cancel_mode_focus_resize :: (state: *Test_State) {
    modes: [3] Mode = .[ .Translate, .Rotate, .Scale ];
    for mode: modes {
        for reason: 0..4 {
            c := test_camera(1280, 720);
            viewport := rect(0, 0, 1280, 720);
            value := Transform.{ scale = v3(1, 1, 1) };
            geometry := transform_geometry(*c, value, viewport, mode);
            p := geometry.axes.origin;
            if mode == .Translate p = geometry.axes.ends[0];
            if mode == .Rotate {
                for i: 0..RING_SEGMENTS - 1 {
                    p = geometry.rings[2][i];
                    if transform_hit(geometry, p) == 2 break;
                }
            }
            g: Transform_Gizmo;
            input := Translation_Input.{
                pointer = p, down = true, pressed = true, enabled = true, allow_start = true,
            };
            r := transform_update(*g, *c, value, viewport, mode, input);
            expectf(state, r.started, "按下即开始（模式 %，原因 %）", mode, reason);
            input.pointer.x = JM.FLOAT32_INFINITY;
            r = transform_update(*g, *c, value, viewport, mode, input);
            expect(state, !r.changed && g.dragging, "非有限指针不产生结果");
            input.pointer = p;
            next_mode := mode;
            if reason == 0 next_mode = next_mode_of(mode);
            if reason == 1 input.enabled = false;
            if reason == 2 input.cancel = true;
            if reason == 3 W.camera3d_set_position(*c, v3(4, 3, 6));
            if reason == 4 {
                viewport.w = 640;
                W.camera3d_set_viewport(*c, 640, 720);
            }
            r = transform_update(*g, *c, value, viewport, next_mode, input);
            expectf(state, r.ended && r.cancelled && r.captured && !r.changed,
                    "中断四条件（模式 %，原因 %）", mode, reason);
            input.cancel = false;
            input.enabled = true;
            r = transform_update(*g, *c, value, viewport, next_mode, input);
            expect(state, !r.started && r.captured,
                   "held mouse cannot capture new mode or target");
            r = transform_update(*g, *c, value, viewport, next_mode,
                                 Translation_Input.{ enabled = true });
            expect(state, r.captured && !g.captured && !g.dragging, "松开清空捕获");
        }
    }
}

// olib: Mode((int(mode)+1)%3)
next_mode_of :: (mode: Mode) -> Mode {
    if mode == .Translate return .Rotate;
    if mode == .Rotate return .Scale;
    return .Translate;
}
//@endregion

//@region 二维工具

transform2d_move_and_projection :: (state: *Test_State) {
    c: W.Camera2D;
    W.camera2d_init(*c, 960, 600);
    W.camera2d_set_position(*c, v2(2, -3));
    W.camera2d_set_zoom(*c, 1.8);
    W.camera2d_set_rotation(*c, 0.6);
    viewport := rect(70, 40, 960, 600);
    value := Transform2D.{ position = v2(3, -2), rotation = 0.7, scale = v2(1, 2) };
    geometry := transform2d_geometry(*c, value, viewport, .Translate, 1.25);
    p, ok := project2d(*c, value.position, viewport);
    expect(state, ok && v2_eq(p, geometry.axes.origin), "二维投影与手柄原点一致");
    axes: [3] int = .[ 0, 1, 3 ];
    for axis: axes {
        g: Transform_Gizmo2D;
        start := p;
        if axis < 2 start = geometry.axes.ends[axis];
        expect(state, transform2d_hit(geometry, start, 1.25) == axis, "命中本轴或中心");
        r := transform2d_update(*g, *c, value, viewport, .Translate, Translation_Input.{
            pointer = start, pressed = true, down = true, enabled = true, allow_start = true,
        }, 1.25);
        expect(state, r.started && !r.changed, "按下即开始且不改变值");
        world_start, _ := W.camera2d_screen_to_world(
            *c, v2(start.x - viewport.x, start.y - viewport.y));
        end, _ := project2d(*c, v2(world_start.x + 1.3, world_start.y - 0.8), viewport);
        r = transform2d_update(*g, *c, value, viewport, .Translate, Translation_Input.{
            pointer = end, down = true, enabled = true,
        }, 1.25);
        expected := value.position;
        if axis == 0 || axis == 3 expected.x += 1.3;
        if axis == 1 || axis == 3 expected.y -= 0.8;
        d := sub2(r.transform.position, expected);
        expectf(state, r.changed && len2_sq(d) < 0.000001,
                "拖动位移逐轴约束（% 轴，偏移 %）", axis, len2_sq(d));
        expect(state, r.transform.rotation == value.rotation &&
               v2_eq(r.transform.scale, value.scale), "移动不改旋转/缩放");
        value_after := r.transform;
        r = transform2d_update(*g, *c, value_after, viewport, .Translate,
                               Translation_Input.{ enabled = true }, 1.25);
        expect(state, r.ended && !r.cancelled && r.captured && !g.captured,
               "松开结束二维移动");
    }
    W.camera2d_set_zoom(*c, 0);
    _, singular := project2d(*c, value.position, viewport);
    expect(state, !singular, "singular camera cannot project or capture");
}

transform2d_rotation_and_scale :: (state: *Test_State) {
    c: W.Camera2D;
    W.camera2d_init(*c, 960, 600);
    W.camera2d_set_rotation(*c, -0.8);
    W.camera2d_set_zoom(*c, 2.5);
    viewport := rect(60, 20, 960, 600);
    initial := Transform2D.{ rotation = 0.4, scale = v2(2, 3) };
    geometry := transform2d_geometry(*c, initial, viewport, .Rotate);
    g: Transform_Gizmo2D;
    start := v2(geometry.axes.origin.x + geometry.radius, geometry.axes.origin.y);
    r := transform2d_update(*g, *c, initial, viewport, .Rotate, Translation_Input.{
        pointer = start, pressed = true, down = true, enabled = true, allow_start = true,
    });
    expect(state, r.started && r.axis == 2, "按在旋转环上开始，轴为 2");
    value := initial;
    for step: 1..80 {
        a := cast(float32) step * 0.1;
        end := v2(geometry.axes.origin.x + JM.cos(a) * geometry.radius,
                  geometry.axes.origin.y + JM.sin(a) * geometry.radius);
        r = transform2d_update(*g, *c, value, viewport, .Rotate, Translation_Input.{
            pointer = end, down = true, enabled = true,
        });
        expectf(state, JM.abs(r.transform.rotation - initial.rotation - a) < 0.001,
                "二维环角累计 0.1/步（% -> %）", r.transform.rotation - initial.rotation, a);
        expect(state, v2_eq(r.transform.position, initial.position) &&
               v2_eq(r.transform.scale, initial.scale), "旋转不改位置/缩放");
        value = r.transform;
    }
    r = transform2d_update(*g, *c, value, viewport, .Rotate, Translation_Input.{
        pointer = geometry.axes.origin, down = true, enabled = true,
    });
    expect(state, !r.changed, "center angle is undefined");
    geometry = transform2d_geometry(*c, initial, viewport, .Scale, 1.25);
    axes: [3] int = .[ 0, 1, 3 ];
    distances: [3] float32 = .[ 62.5, -10000, 10000000 ];
    for axis: axes {
        g = Transform_Gizmo2D.{};
        start = geometry.axes.origin;
        if axis < 2 start = geometry.axes.ends[axis];
        r = transform2d_update(*g, *c, initial, viewport, .Scale, Translation_Input.{
            pointer = start, pressed = true, down = true, enabled = true, allow_start = true,
        }, 1.25);
        expect(state, r.started && r.axis == axis && !r.changed, "缩放手柄按下即开始");
        for distance: distances {
            pointer := add2(start, scale2(g.direction, distance));
            r = transform2d_update(*g, *c, initial, viewport, .Scale, Translation_Input.{
                pointer = pointer, down = true, enabled = true,
            }, 1.25);
            for i: 0..1 {
                v := r.transform.scale.component[i];
                expectf(state, v >= 0.001 && v <= 10000, "二维比例 % 在上下限内（% 轴）",
                        v, axis);
                if axis < 2 && axis != i {
                    expect(state, v == initial.scale.component[i], "二维非缩放轴不变");
                }
                if distance == 62.5 && (axis == 3 || axis == i) {
                    expectf(state, JM.abs(v - initial.scale.component[i] * 1.5) < 0.001,
                            "62.5px 得到 1.5 倍（% 轴，得到 %）", axis, v);
                }
            }
            if axis == 3 {
                expect(state, JM.abs(r.transform.scale.y / r.transform.scale.x - 1.5) < 0.001,
                       "二维等比缩放保留比例");
            }
            expect(state, v2_eq(r.transform.position, initial.position) &&
                   r.transform.rotation == initial.rotation, "二维缩放不改位置/旋转");
        }
        r = transform2d_update(*g, *c, r.transform, viewport, .Scale, Translation_Input.{
            pointer = start, down = true, enabled = true,
        }, 1.25);
        expect(state, transform2d_eq(r.transform, initial),
               "returning pointer restores initial values");
    }
}

transform2d_cancel_and_input_contract :: (state: *Test_State) {
    modes: [3] Mode = .[ .Translate, .Rotate, .Scale ];
    for mode: modes {
        for reason: 0..6 {
            c: W.Camera2D;
            W.camera2d_init(*c, 960, 600);
            viewport := rect(40, 20, 960, 600);
            value := Transform2D.{ scale = v2(1, 1) };
            geometry := transform2d_geometry(*c, value, viewport, mode);
            p := geometry.axes.origin;
            if mode == .Rotate p.x += geometry.radius;
            g: Transform_Gizmo2D;
            input := Translation_Input.{
                pointer = p, down = true, pressed = true, enabled = true,
            };
            r := transform2d_update(*g, *c, value, viewport, mode, input);
            expectf(state, !r.started, "UI prevents starting（模式 %，原因 %）", mode, reason);
            input.allow_start = true;
            r = transform2d_update(*g, *c, value, viewport, mode, input);
            expect(state, r.started, "允许后开始");
            input.pointer.x = JM.FLOAT32_INFINITY;
            r = transform2d_update(*g, *c, value, viewport, mode, input);
            expect(state, !r.changed && g.dragging, "非有限指针不产生结果");
            input.pointer = p;
            next_mode := mode;
            if reason == 0 input.cancel = true;
            if reason == 1 input.enabled = false;
            if reason == 2 next_mode = next_mode_of(mode);
            if reason == 3 W.camera2d_set_zoom(*c, 1.2);
            if reason == 4 W.camera2d_set_rotation(*c, 0.3);
            if reason == 5 W.camera2d_set_position(*c, v2(1, 2));
            if reason == 6 viewport.x += 20;
            r = transform2d_update(*g, *c, value, viewport, next_mode, input);
            expectf(state, r.ended && r.cancelled && r.captured && !r.changed,
                    "二维中断四条件（模式 %，原因 %）", mode, reason);
            input.enabled = true;
            input.cancel = false;
            r = transform2d_update(*g, *c, value, viewport, next_mode, input);
            expect(state, r.captured && !r.started, "按住期间不能重新捕获");
            r = transform2d_update(*g, *c, value, viewport, next_mode,
                                   Translation_Input.{ enabled = true });
            expect(state, r.captured && !g.captured, "松开释放捕获");
            r = transform2d_update(*g, *c, value, viewport, next_mode,
                                   Translation_Input.{ enabled = true });
            expect(state, !r.captured && !r.ended, "释放事件只发一次");
        }
    }
}

// 三维绘制的世界顶点应与命中几何一致；不需要窗口或 GPU。
transform_mesh_world_geometry :: (state: *Test_State) {
    c := test_camera(960, 600);
    viewport := rect(80, 40, 960, 600);
    vertices: [..] Vertex3D;
    defer { if vertices.data != null array_free(vertices); }
    value := Transform.{ rotation = v3(0.3, 0.5, -0.2), scale = v3(2, 1, 3) };
    gizmo_state: Transform_Gizmo;
    modes: [3] Mode = .[ .Translate, .Rotate, .Scale ];
    for mode: modes {
        labels := transform_mesh(*vertices, *c, value, viewport, mode, *gizmo_state,
                                 v2(-100, -100), 1.25);
        expectf(state, vertices.count > 100 && vertices.count % 3 == 0,
                "顶点数是三角形整数倍且非空（% 个）", vertices.count);
        g := transform_geometry(*c, value, viewport, mode, 1.25);
        for v: vertices {
            expect(state, finite3(v.position), "顶点位置有限");
            for n: v.color {
                expect(state, finite(n) && n >= 0 && n <= 1, "顶点颜色在 0..1");
            }
        }
        for axis: 0..2 {
            label := labels[axis];
            if mode == .Rotate || !g.axes.visible[axis] continue;
            expect(state, label.visible, "轴标签可见");
            nearest := JM.FLOAT32_INFINITY;
            for v: vertices {
                p, ok := project(*c, v.position, viewport);
                if ok nearest = min(nearest, len2_sq(sub2(p, g.axes.ends[axis])));
            }
            expectf(state, nearest < 100, "solid mesh ends align with screen-space picking (% 轴)",
                    axis);
        }
    }
    // 深度翻倍，网格世界尺寸也翻倍；屏幕位置保持不变。
    value.rotation = v3_zero();
    transform_mesh(*vertices, *c, value, viewport, .Translate, *gizmo_state, v2_zero());
    before: [..] Vertex3D;
    defer { if before.data != null array_free(before); }
    array_reserve(*before, vertices.count);
    for v: vertices array_add(*before, v);
    W.camera3d_set_position(*c, v3(c.position.x * 2, c.position.y * 2, c.position.z * 2));
    transform_mesh(*vertices, *c, value, viewport, .Translate, *gizmo_state, v2_zero());
    expect(state, vertices.count == before.count, "深度翻倍后顶点数不变");
    for v, i: vertices {
        difference := vsub(v.position, vscale(before[i].position, 2));
        expectf(state, W.v3_dot(difference, difference) < 0.00001,
                "constant apparent handle size（第 % 个顶点差 %）", i,
                W.v3_dot(difference, difference));
    }
    value.position = v3(c.position.x * 2, c.position.y * 2, c.position.z * 2);
    transform_mesh(*vertices, *c, value, viewport, .Translate, *gizmo_state, v2_zero());
    expect(state, vertices.count == 0, "behind-camera mesh is rejected");
    transform_mesh(*vertices, null, value, viewport, .Translate, *gizmo_state, v2_zero());
    expect(state, vertices.count == 0, "空相机不生成网格");
}
//@endregion

//@region 线框网格

wireframe_mesh_pixel_width_and_kinds :: (state: *Test_State) {
    c: W.Camera3D;
    W.camera3d_init(*c, 960, 600);
    W.camera3d_set_position(*c, v3(0, 0, 6));
    W.camera3d_set_target(*c, v3_zero());
    viewport := rect(80, 40, 960, 600);
    // 两个三角形组成的四边形：对角线为内部边，四周为边界。
    positions: [4][3] float32 = .[ .[-1, -1, 0], .[1, -1, 0], .[1, 1, 0], .[-1, 1, 0] ];
    indices: [6] u32 = .[ 0, 1, 2, 0, 2, 3 ];
    edges, edges_ok := MSH.edges(positions, indices);
    defer MSH.meshutil_free(edges);
    expect(state, edges_ok && edges.count == 5, "四边形网格有 5 条唯一边");
    vertices: [..] Vertex3D;
    defer { if vertices.data != null array_free(vertices); }

    scales: [2] float32 = .[ 1, 2 ];
    for scale: scales {
        wireframe_mesh(*vertices, *c, positions, edges, W.MATRIX4_IDENTITY, viewport, scale);
        expectf(state, vertices.count == 30, "每条边 6 个顶点，共 30（得到 %）", vertices.count);
        // 底边 0→1 水平：四边形两侧在屏幕上相距 line_width*scale 像素。
        for edge, i: edges {
            if !((edge.a == 0 && edge.b == 1) || (edge.a == 1 && edge.b == 0)) continue;
            low, low_ok := project(*c, vertices[i * 6].position, viewport);
            high, high_ok := project(*c, vertices[i * 6 + 5].position, viewport);
            expect(state, low_ok && high_ok, "线框顶点可投影");
            width := JM.abs(high.y - low.y);
            expected := DEFAULT_WIREFRAME_STYLE.line_width * scale;
            expectf(state, JM.abs(width - expected) < expected * 0.05,
                    "width % -> expected %", width, expected);
        }
    }
    default_style := DEFAULT_WIREFRAME_STYLE;
    for edge, i: edges {
        color := default_style.colors[cast(int) edge.kind];
        expect(state, vertices[i * 6].color[3] == cast(float32) color.a / 255,
               "线框颜色 alpha 来自样式");
        expect(state, edge.kind == MSH.Edge_Kind.Border || edge.kind == MSH.Edge_Kind.Interior,
               "四边形只有边界边与内部边");
    }

    // 只看边界：内部边颜色透明即跳过。
    style := DEFAULT_WIREFRAME_STYLE;
    style.colors[cast(int) MSH.Edge_Kind.Interior].a = 0;
    wireframe_mesh(*vertices, *c, positions, edges, W.MATRIX4_IDENTITY, viewport, 1, style);
    expectf(state, vertices.count == 24, "去掉内部边后 4 条边 24 顶点（得到 %）",
            vertices.count);

    // 模型矩阵生效：平移到相机后方时全部丢弃，跨过近裁面的边被截断。
    wireframe_mesh(*vertices, *c, positions, edges, W.matrix4_translation(0, 0, 10), viewport);
    expectf(state, vertices.count == 0, "相机后方整边丢弃（得到 %）", vertices.count);
    crossing: [1] MSH.Edge = .[ MSH.Edge.{ a = 0, b = 1, kind = .Border } ];
    through: [2][3] float32 = .[ .[0.5, 0, 0], .[0.5, 0, 10] ];
    wireframe_mesh(*vertices, *c, through, crossing, W.MATRIX4_IDENTITY, viewport);
    expectf(state, vertices.count == 6, "跨近裁面的边被截断保留（得到 %）", vertices.count);
    forward := W.camera3d_forward(*c);
    for v: vertices {
        depth := W.v3_dot(vsub(v.position, c.position), forward);
        expect(state, depth > c.near_clip * 0.99, "截断点位于近裁面之后");
    }

    // 越界边、相机视口不匹配直接忽略。
    bad: [1] MSH.Edge = .[ MSH.Edge.{ a = 0, b = 9, kind = .Border } ];
    wireframe_mesh(*vertices, *c, positions, bad, W.MATRIX4_IDENTITY, viewport);
    expectf(state, vertices.count == 0, "越界边被忽略（得到 %）", vertices.count);
    wireframe_mesh(*vertices, *c, positions, edges, W.MATRIX4_IDENTITY, rect(0, 0, 480, 300));
    expectf(state, vertices.count == 0, "视口不匹配时不生成（得到 %）", vertices.count);
}
//@endregion

//@region GPU 线框

wireframe_edges_and_uniforms :: (state: *Test_State) {
    positions: [3][3] float32 = .[ .[0, 0, 0], .[1, 0, 0], .[0, JM.FLOAT32_NAN, 0] ];
    edges: [3] MSH.Edge = .[
        MSH.Edge.{ a = 0, b = 1, kind = .Seam },
        MSH.Edge.{ a = 0, b = 9, kind = .Border },
        MSH.Edge.{ a = 0, b = 2, kind = .Border },
    ];
    instances: [..] Wireframe_Edge;
    defer { if instances.data != null array_free(instances); }
    // 越界索引和非有限端点在上传前剔除；种类按 Edge_Kind 序号写入。
    wireframe_edges(*instances, positions, edges);
    expectf(state, instances.count == 1, "只保留一条合法边（得到 %）", instances.count);
    expect(state, floats3_eq(instances[0].a, positions[0]) &&
           floats3_eq(instances[0].b, positions[1]), "实例端点来自顶点表");
    expect(state, instances[0].kind == cast(float32) cast(int) MSH.Edge_Kind.Seam,
           "实例种类写成枚举序号");
    expect(state, size_of(Wireframe_Edge) == 28, "实例结构 28 字节");

    // 没有设备时不创建资源，零值可重复 destroy。
    w: Wireframe;
    expect(state, !wireframe_init(*w, null, positions, edges), "无设备不创建资源");
    wireframe_destroy(*w);
    expect(state, !w.ready, "destroy 之后保持零值");

    c: W.Camera3D;
    W.camera3d_init(*c, 960, 600);
    W.camera3d_set_position(*c, v3(0, 0, 6));
    W.camera3d_set_target(*c, v3_zero());
    viewport := rect(80, 40, 960, 600);
    block, block_ok := wireframe_uniforms(*c, W.MATRIX4_IDENTITY, viewport, 2);
    expect(state, block_ok, "常量块生成成功");
    eye := read_vec4(block, 128);
    expect(state, vec4_xyz_eq3(eye, c.position) && eye[3] > c.near_clip,
           "128 是相机位置与近裁面");
    expect(state, read_vec4(block, 160)[0] == DEFAULT_WIREFRAME_STYLE.line_width,
           "160.x 是半线宽（1.25 × 2 × 0.5）");
    border := DEFAULT_WIREFRAME_STYLE.colors[cast(int) MSH.Edge_Kind.Border];
    expect(state, read_vec4(block, 176 + 2 * 16)[3] == cast(float32) border.a / 255,
           "176+2×16 是边界色");
    // 相机视口与绘制视口不一致、缩放无效时不画。
    _, mismatch := wireframe_uniforms(*c, W.MATRIX4_IDENTITY, rect(0, 0, 480, 300));
    expect(state, !mismatch, "视口不匹配不生成常量");
    _, zero_scale := wireframe_uniforms(*c, W.MATRIX4_IDENTITY, viewport, 0);
    expect(state, !zero_scale, "缩放 0 不生成常量");
}
//@endregion

//@region 补充：CPU 阈值与角度环绕

// olib 没有单独测 translation_hit 的阈值，这里用手搭的几何把每一条判定固定下来：
// 半径有效性、中心留空（radius*1.5）、侧向距离 < radius、隐藏轴、退化轴、最近者优先。
translation_hit_thresholds :: (state: *Test_State) {
    geo := Translation_Geometry.{
        origin = v2(100, 100),
        ends = .[ v2(200, 100), v2(100, 200), v2(100, 100) ],
        visible = .[ true, true, true ],
    };
    expect(state, translation_hit(geo, v2(200, 100), 0) == -1, "半径 0 不命中");
    expect(state, translation_hit(geo, v2(200, 100), -3) == -1, "负半径不命中");
    expect(state, translation_hit(geo, v2(200, 100), JM.FLOAT32_INFINITY) == -1,
           "非有限半径不命中");
    expect(state, translation_hit(geo, v2(150, 100), 9) == 0, "X 轴线段命中");
    expect(state, translation_hit(geo, v2(100, 150), 9) == 1, "Y 轴线段命中");
    // 中心附近留空：t*len < radius*1.5（9*1.5 = 13.5 像素）的采样被跳过。
    expect(state, translation_hit(geo, v2(100, 100), 9) == -1, "原点留空");
    expect(state, translation_hit(geo, v2(113.4, 100), 9) == -1, "留空区内不命中");
    expect(state, translation_hit(geo, v2(113.6, 100), 9) == 0, "留空区外命中");
    // 侧向阈值：distance < radius²。
    expect(state, translation_hit(geo, v2(150, 108.5), 9) == 0, "半径内命中");
    expect(state, translation_hit(geo, v2(150, 109.5), 9) == -1, "半径外不命中");
    expect(state, translation_hit(geo, v2(150, 108.5), 9.5) == 0, "放大半径后仍命中");
    hidden := geo;
    hidden.visible[1] = false;
    expect(state, translation_hit(hidden, v2(100, 150), 9) == -1, "隐藏轴不参与");
    degenerate := geo;
    degenerate.ends[0] = geo.origin;
    expect(state, translation_hit(degenerate, v2(150, 100), 9) == -1, "零长度轴跳过");
    expect(state, translation_hit(geo, v2(160, 103), 9) == 0, "两轴都可命中时取最近（X）");
    expect(state, translation_hit(geo, v2(103, 160), 9) == 1, "两轴都可命中时取最近（Y）");
    expect(state, translation_hit(geo, v2(160, 102), 3) == 0, "缩小半径后仍在半径内命中");
    expect(state, translation_hit(geo, v2(160, 103.5), 3) == -1, "缩小半径后落在半径外");
    // 完全不相交的指针。
    expect(state, translation_hit(geo, v2(180, 180), 9) == -1, "远离所有轴不命中");
}

// 环角（射线 → 平面角）与角度环绕：拖拽里 ±π 与多圈的连续性靠这两个过程。
gizmo_ring_angle_and_wrap :: (state: *Test_State) {
    origin := v3_zero();
    angles: [5] float32 = .[ 0, 0.7, 2.5, -2.9, PI_F / 2 ];
    for axis: 0..2 {
        for angle: angles {
            a := angle;
            point: W.Vec3;
            point.component[(axis + 1) % 3] = JM.cos(a) * 3;
            point.component[(axis + 2) % 3] = JM.sin(a) * 3;
            normal: W.Vec3;
            normal.component[axis] = 1;
            start := vsub(point, vscale(normal, 5));
            ray, ray_ok := W.ray3d_make(start, normal);
            got, angle_ok := gizmo_ring_angle(ray, origin, axis);
            expectf(state, ray_ok && angle_ok && JM.abs(gizmo_wrap_angle(got - a)) < 0.001,
                    "环角等于平面角（轴 %，期望 %，得到 %）", axis, a, got);
        }
    }
    // 射线打在环心：半径 0，角度没有定义。
    center_ray, center_ok := W.ray3d_make(v3(0, 0, -5), v3(0, 0, 1));
    _, center_angle := gizmo_ring_angle(center_ray, origin, 2);
    expect(state, center_ok && !center_angle, "环心角度无定义");
    // 平行于环平面的射线没有交点（分母接近 0）。
    edge_ray, edge_ok := W.ray3d_make(v3(-5, 2, 0), v3(1, 0, 0));
    _, edge_angle := gizmo_ring_angle(edge_ray, origin, 2);
    expect(state, edge_ok && !edge_angle, "平行于环平面的射线不命中");

    // gizmo_wrap_angle：结果落在 [-π, π)。
    inputs: [8] float32 = .[
        0, PI_F - 0.1, -PI_F + 0.1, PI_F + 0.5,
        2 * PI_F + 0.3, -2 * PI_F - 0.3, 10 * PI_F, -10 * PI_F,
    ];
    expected: [8] float32 = .[
        0, PI_F - 0.1, -PI_F + 0.1, -PI_F + 0.5,
        0.3, -0.3, 0, 0,
    ];
    for value, i: inputs {
        got := gizmo_wrap_angle(value);
        expectf(state, JM.abs(got - expected[i]) < 0.0001,
                "wrap(% -> %)（得到 %）", value, expected[i], got);
        expectf(state, got >= -PI_F - 0.0001 && got < PI_F + 0.0001,
                "wrap 结果落在 [-π, π)（% -> %）", value, got);
    }
    expect(state, gizmo_wrap_angle(PI_F) == -PI_F, "π 环绕到 -π");
    expect(state, gizmo_wrap_angle(-PI_F) == -PI_F, "-π 保持 -π");
    // 连续扫描跨过 ±π 时相邻差小于 π（拖拽不跳变的前提）。
    step_back := gizmo_wrap_angle(PI_F - 0.001);
    step_fwd := gizmo_wrap_angle(-PI_F + 0.001);
    expect(state, JM.abs(step_back - (PI_F - 0.001)) < 0.0001, "接缝左侧连续");
    expect(state, JM.abs(step_fwd - (-PI_F + 0.001)) < 0.0001, "接缝右侧连续");
    for i: 0..399 {
        a := cast(float32) (i - 200) * 0.05;
        next := gizmo_wrap_angle(a + 0.05);
        expectf(state, JM.abs(gizmo_wrap_angle(next - gizmo_wrap_angle(a))) <= PI_F + 0.0001,
                "相邻环绕值的差不超过 π（% 处）", a);
    }
    // 旋转角为 0 时姿态不变：万向锁处 Euler 表达可以等价改写（olib 的 rotate_world 会
    // 重建 atan2，结果有 1 ULP 级差异），所以这里比基向量而不是比 Euler 分量。
    gimbal := v3(0.6, PI_F / 2, 0.2);
    gimbal_result := gizmo_rotate_world(gimbal, 1, 0, gimbal);
    for axis: 0..2 {
        basis: W.Vec3;
        basis.component[axis] = 1;
        diff := vsub(gizmo_rotate_xyz(basis, gimbal_result), gizmo_rotate_xyz(basis, gimbal));
        expectf(state, W.v3_dot(diff, diff) < 0.000001,
                "角度 0 的 world 旋转保持基向量 %（万向锁姿态）", axis);
    }
    plain := v3(0.3, -0.4, 1.2);
    expect(state, v3_eq(gizmo_rotate_world(plain, 0, 0, plain), plain),
           "非奇异姿态下角度 0 是恒等");
}

// 手搭三个同心环（半径 100 / 140 / 180，互不相交，因此没有「谁更近」的并列情况），
// 把 transform_hit 的环半径阈值、空白区、隐藏段与缩放的轴 / 中心判定固定下来。
synthetic_ring_geometry :: (mode: Mode) -> Transform_Geometry {
    g := Transform_Geometry.{ mode = mode };
    g.axes.origin = v2(300, 300);
    g.center_visible = true;
    for axis: 0..2 {
        radius := cast(float32) 100 + cast(float32) axis * 40;
        for i: 0..RING_SEGMENTS {
            a := cast(float32) i * 2 * JM.PI / cast(float32) RING_SEGMENTS;
            g.rings[axis][i] = v2(g.axes.origin.x + JM.cos(a) * radius,
                                  g.axes.origin.y + JM.sin(a) * radius);
            if i > 0 g.segments[axis][i - 1] = true;
        }
    }
    return g;
}

// 半径 radius 处的屏幕点（取合成环的角度 0，避免落在四分之一圆的分段端点上）。
ring_point :: (g: Transform_Geometry, radius: float32) -> W.Vec2 {
    return v2(g.axes.origin.x + radius, g.axes.origin.y);
}

transform_hit_rings_and_scale_center :: (state: *Test_State) {
    rotate_geo := synthetic_ring_geometry(.Rotate);
    // 三个环各自命中自己：半径 100 处距离环 0 为 0、距环 1 为 40，无并列。
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 100)) == 0, "环 0 命中轴 0");
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 140)) == 1, "环 1 命中轴 1");
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 180)) == 2, "环 2 命中轴 2");
    // 命中阈值是 hit_radius (9px)：环 0 内 8px 命中、10px 不命中。
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 108)) == 0,
           "环外 8px 仍在命中半径内");
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 110)) == -1,
           "环外 10px 落在命中半径外");
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 92)) == 0,
           "环内 8px 仍命中");
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 120)) == -1,
           "两环之间空白不命中");
    // 缩放倍率参与命中半径。
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 110), 2) == 0,
           "hit_radius 随 UI 缩放放大");
    expect(state, transform_hit(rotate_geo, ring_point(rotate_geo, 110), 0) == -1,
           "缩放 0 不命中");
    // 隐藏的段（segments = false）不参与命中。
    hidden := rotate_geo;
    for i: 0..RING_SEGMENTS - 1 hidden.segments[2][i] = false;
    expect(state, transform_hit(hidden, ring_point(hidden, 180)) == -1, "隐藏段不命中");
    // 半径过小的段被 `length <= 0.0001` 跳过（退化环）。
    degenerate := rotate_geo;
    for i: 0..RING_SEGMENTS degenerate.rings[0][i] = degenerate.axes.origin;
    expect(state, transform_hit(degenerate, ring_point(degenerate, 100)) == -1,
           "零长度段被跳过");

    // 缩放模式：中心 8×scale 像素内即轴 3，外侧回落到轴命中。
    scale_geo := synthetic_ring_geometry(.Scale);
    scale_geo.axes.ends[0] = v2(300 + 100, 300);
    scale_geo.axes.ends[1] = v2(300, 300 + 100);
    scale_geo.axes.visible = .[ true, true, false ];
    expect(state, transform_hit(scale_geo, v2(306, 300)) == 3, "中心 6px 命中轴 3");
    expect(state, transform_hit(scale_geo, v2(308, 300)) == 3, "中心 8px 命中轴 3");
    expect(state, transform_hit(scale_geo, v2(300, 300 + 100)) == 1, "中心外回落到轴 1");
    expect(state, transform_hit(scale_geo, v2(310, 300)) == -1, "中心外且不在轴上不命中");
    expect(state, transform_hit(scale_geo, v2(303, 300), 0.5) == 3, "中心半径随 UI 缩放（3px）");
    expect(state, transform_hit(scale_geo, v2(306, 300), 0.5) == -1,
           "半径 0.5 时 6px 已在中心外且被中心留空跳过");
    scale_geo.center_visible = false;
    expect(state, transform_hit(scale_geo, v2(300, 300)) == -1, "中心不可见时不算轴 3");

    // 移动模式直接委托 translation_hit。
    translate_geo := synthetic_ring_geometry(.Translate);
    translate_geo.axes.origin = v2(100, 100);
    translate_geo.axes.ends = .[ v2(200, 100), v2(100, 200), v2(100, 100) ];
    translate_geo.axes.visible = .[ true, true, true ];
    expect(state, transform_hit(translate_geo, v2(150, 100)) == 0, "移动模式命中 X");
    expect(state, transform_hit(translate_geo, v2(100, 150)) == 1, "移动模式命中 Y");
    expect(state, transform_hit(translate_geo, v2(100, 100)) == -1, "移动模式中心留空");

    // 真实几何：正对 Z 轴看时 X/Y 环侧视被隐藏，只有 Z 环有段。
    c: W.Camera3D;
    W.camera3d_init(*c, 960, 600);
    W.camera3d_set_position(*c, v3(0, 0, 6));
    W.camera3d_set_target(*c, v3_zero());
    real := transform_geometry(*c, Transform.{ scale = v3(1, 1, 1) }, rect(80, 40, 960, 600), .Rotate);
    for axis: 0..2 {
        segments := 0;
        for i: 0..RING_SEGMENTS - 1 {
            if real.segments[axis][i] segments += 1;
        }
        if axis == 2 {
            expectf(state, segments == RING_SEGMENTS, "正对 Z 轴时 Z 环完整（% 段）", segments);
        } else {
            expectf(state, segments == 0, "侧视环被隐藏（轴 %，% 段）", axis, segments);
        }
    }
    // 旋转模式也会标记 center_visible（几何与绘制共用），但命中只看环，不看中心。
    expect(state, real.center_visible && real.mode == .Rotate, "旋转模式只在环上命中");
    expect(state, transform_hit(real, real.axes.origin) == -1, "旋转模式环心不算命中");
    expect(state, transform_geometry(*c, Transform.{ scale = v3(1, 1, 1) },
                                     rect(80, 40, 960, 600), .Scale).center_visible,
           "缩放模式标记中心手柄");
}

// 常量块的完整 std140 布局（128/144/160/176+4×16）与结构体尺寸。
wireframe_uniform_layout :: (state: *Test_State) {
    c: W.Camera3D;
    W.camera3d_init(*c, 960, 600);
    W.camera3d_set_position(*c, v3(1.5, -2, 5));
    W.camera3d_set_target(*c, v3_zero());
    viewport := rect(80, 40, 960, 600);
    transform := W.matrix4_translation(2, -1, 0.5);
    style := DEFAULT_WIREFRAME_STYLE;
    style.line_width = 2.5;
    style.depth_offset = 6;
    style.colors = .[
        F.Color.{ 1, 2, 3, 4 },
        F.Color.{ 5, 6, 7, 8 },
        F.Color.{ 9, 10, 11, 12 },
        F.Color.{ 13, 14, 15, 16 },
    ];
    block, block_ok := wireframe_uniforms(*c, transform, viewport, 2, style);
    expect(state, block_ok, "常量块生成成功");
    expect(state, WIREFRAME_UNIFORM_SIZE == 240, "常量块 240 字节");
    expect(state, size_of(block) == 240, "返回数组正好 240 字节");

    // 0..63 视图投影、64..127 模型矩阵（列主序，每列 16 字节）。
    view_projection := W.camera3d_view_projection(*c);
    expect(state, floats4_eq(read_vec4(block, 0), view_projection.c0), "0 是视图投影 c0");
    expect(state, floats4_eq(read_vec4(block, 16), view_projection.c1), "16 是视图投影 c1");
    expect(state, floats4_eq(read_vec4(block, 32), view_projection.c2), "32 是视图投影 c2");
    expect(state, floats4_eq(read_vec4(block, 48), view_projection.c3), "48 是视图投影 c3");
    expect(state, floats4_eq(read_vec4(block, 64), transform.c0), "64 是模型矩阵 c0");
    expect(state, floats4_eq(read_vec4(block, 112), transform.c3), "112 是模型矩阵 c3");

    // 128 相机位置 + 近裁面（近裁面 ×1.01 抗 z-fighting）。
    eye := read_vec4(block, 128);
    expect(state, vec4_xyz_eq3(eye, c.position), "128.xyz 是相机位置");
    near_expected: float32 = max(c.near_clip, 0.0001) * 1.01;
    expect(state, JM.abs(eye[3] - near_expected) < 0.000001, "128.w 是近裁面 ×1.01");

    // 144 前向 + 每像素世界长度。
    ahead := read_vec4(block, 144);
    forward := W.camera3d_forward(*c);
    expect(state, ahead[0] == forward.x && ahead[1] == forward.y && ahead[2] == forward.z,
           "144.xyz 是相机前向");
    pixel := 2 * JM.tan(c.field_of_view * 0.5) / viewport.h;
    expect(state, JM.abs(ahead[3] - pixel) < 0.000001, "144.w 是深度 1 处的像素世界长度");

    // 160 半线宽 + 深度偏移。
    width_offset := read_vec4(block, 160);
    expect(state, width_offset[0] == style.line_width * 2 * 0.5, "160.x 是半线宽 × scale");
    expect(state, width_offset[1] == style.depth_offset * 2, "160.y 是深度偏移 × scale");
    expect(state, width_offset[2] == 0 && width_offset[3] == 0, "160.zw 留空");

    // 176 + 4×16：四类边的颜色，alpha 为 0 的种类也照写（剔除在顶点阶段）。
    for kind: 0..3 {
        color := style.colors[kind];
        slot := read_vec4(block, 176 + kind * 16);
        expectf(state, JM.abs(slot[0] - cast(float32) color.r / 255) < 0.000001 &&
                JM.abs(slot[1] - cast(float32) color.g / 255) < 0.000001 &&
                JM.abs(slot[2] - cast(float32) color.b / 255) < 0.000001 &&
                JM.abs(slot[3] - cast(float32) color.a / 255) < 0.000001,
                "176+%×16 是第 % 类边色", kind, kind);
    }
    // 与 176+4×16 = 240 正好收尾。
    expect(state, 176 + 4 * 16 == WIREFRAME_UNIFORM_SIZE, "颜色槽位正好填满常量块");

    // 无效输入：零尺寸视口、非有限缩放、零线宽。
    _, empty_viewport := wireframe_uniforms(*c, transform, rect(0, 0, 0, 0));
    expect(state, !empty_viewport, "零尺寸视口不生成常量");
    _, infinite_scale := wireframe_uniforms(*c, transform, viewport, JM.FLOAT32_INFINITY);
    expect(state, !infinite_scale, "非有限缩放不生成常量");
    zero_width := style;
    zero_width.line_width = 0;
    _, no_width := wireframe_uniforms(*c, transform, viewport, 1, zero_width);
    expect(state, !no_width, "零线宽不生成常量");
    // 负的 depth_offset 夹到 0，而不是把线推远。
    negative := style;
    negative.depth_offset = -5;
    pushed, pushed_ok := wireframe_uniforms(*c, transform, viewport, 1, negative);
    expect(state, pushed_ok && read_vec4(pushed, 160)[1] == 0, "负深度偏移夹到 0");
}
//@endregion

//@region 补充：GPU 资源诊断（假设备，不创建真实设备）

// jfoster 的零值 Graphics_Device 是「已销毁」，假设备必须显式置 disposed = false；
// driver 保持 .NONE，所以 renderer3d_init 在碰 GPU 之前就拒绝。
fake_device :: () -> *F.Graphics_Device {
    device := New(F.Graphics_Device);
    device.disposed = false;
    return device;
}

gizmo_gpu_diagnostics :: (state: *Test_State) {
    device := fake_device();
    defer free(device);

    // 1. 不支持的着色器后端：初始化失败且不留半成品资源。
    r: Renderer3D;
    expect(state, !renderer3d_init(*r, device), "无后端驱动时初始化失败");
    expect(state, !r.ready && r.mesh == null && r.material == null &&
           r.wire_material == null && r.vertex == null && r.fragment == null &&
           r.wire_vertex == null && r.wire_fragment == null && r.vertices.count == 0,
           "失败后 Renderer3D 保持零值");
    renderer3d_destroy(*r); // 零值可重复销毁
    expect(state, !r.ready, "零值 destroy 安全");
    expect(state, !renderer3d_init(*r, null), "空设备被拒绝");
    renderer3d_destroy(*r);

    // 2. 未就绪的 Renderer3D：绘制入口只返回空标签，不碰设备。
    c := test_camera(960, 600);
    viewport := rect(80, 40, 960, 600);
    value := Transform.{ position = v3_zero(), rotation = v3_zero(), scale = v3(1, 1, 1) };
    gizmo_state: Transform_Gizmo;
    translation_state: Translation_Gizmo;
    target: F.Drawable_Target; // Kind = .NONE
    modes: [3] Mode = .[ .Translate, .Rotate, .Scale ];
    for mode: modes {
        labels := transform_draw(*r, target, *c, value, viewport, mode, *gizmo_state,
                                 v2(10, 10), 1.25);
        for axis: 0..2 {
            expectf(state, !labels[axis].visible, "未就绪的渲染器不产生标签（模式 %，轴 %）",
                    mode, axis);
        }
    }
    expect(state, r.vertices.count == 0, "未就绪的渲染器不生成顶点");
    labels := translation_draw(*r, target, *c, v3_zero(), viewport, *translation_state,
                               v2(10, 10), 1.25);
    for axis: 0..2 {
        expect(state, !labels[axis].visible, "translation_draw 未就绪时同样为空");
    }
    // 二维覆盖层：几何无效时在记录之前就返回空标签（batch 可以为 null）。
    bad_geometry: Transform_Geometry2D;
    gizmo2d: Transform_Gizmo2D;
    labels2d := transform2d_draw(null, *gizmo2d, bad_geometry, v2(10, 10), 1.25);
    for axis: 0..2 {
        expect(state, !labels2d[axis].visible, "无效二维几何不产生标签");
    }

    // 3. 线框：无设备或没有合法边时不创建资源。
    positions: [2][3] float32 = .[ .[0, 0, 0], .[1, 0, 0] ];
    edges: [1] MSH.Edge = .[ MSH.Edge.{ a = 0, b = 1, kind = .Border } ];
    bad_edges: [1] MSH.Edge = .[ MSH.Edge.{ a = 0, b = 7, kind = .Border } ];
    w: Wireframe;
    expect(state, !wireframe_init(*w, null, positions, edges), "无设备不创建线框资源");
    expect(state, !wireframe_init(*w, device, positions, bad_edges),
           "没有合法边时即使有设备也不创建");
    expect(state, !w.ready && w.mesh == null && w.edges == 0, "失败后 Wireframe 保持零值");
    wireframe_destroy(*w);
    wireframe_destroy(*w); // 零值可重复销毁
    expect(state, !w.ready, "零值线框可重复 destroy");

    // 4. wireframe_draw 的守卫：渲染器未就绪或线框未就绪都直接返回。
    wireframe_draw(*r, target, *c, *w, W.MATRIX4_IDENTITY, viewport, 1.25);
    expect(state, !r.ready && !w.ready, "未就绪时 wireframe_draw 是空操作");
    wireframe_draw(*r, target, *c, null, W.MATRIX4_IDENTITY, viewport, 1.25);
    expect(state, true, "空 Wireframe 指针不崩溃");

    // 5. 结构体尺寸与内嵌着色器字节码（移植新增的 shaders_compiled.jai）。
    expect(state, GIZMO_VERTEX_STRIDE == 28 && size_of(Vertex3D) == 28, "手柄顶点 28 字节");
    expect(state, WIREFRAME_EDGE_STRIDE == 28 && WIREFRAME_CORNER_STRIDE == 8,
           "线框实例 28 字节 / 角点 8 字节");
    expect(state, RING_SEGMENTS == 64, "环 64 段");
    expect(state, gizmo3d_vertex_spv.count > 4 && gizmo3d_vertex_dxil.count > 4 &&
           gizmo3d_vertex_msl.count > 4, "Gizmo3D 顶点三份字节码都在");
    expect(state, gizmo3d_fragment_spv.count > 4 && gizmo3d_fragment_dxil.count > 4 &&
           gizmo3d_fragment_msl.count > 4, "Gizmo3D 片元三份字节码都在");
    expect(state, wireframe3d_vertex_spv.count > 4 && wireframe3d_vertex_dxil.count > 4 &&
           wireframe3d_vertex_msl.count > 4, "Wireframe3D 顶点三份字节码都在");
    expect(state, wireframe3d_fragment_spv.count > 4 && wireframe3d_fragment_dxil.count > 4 &&
           wireframe3d_fragment_msl.count > 4, "Wireframe3D 片元三份字节码都在");
    // SPIR-V 魔数 0x07230203、DXIL 容器 "DXBC"、MSL 是源码（以 # 开头）。
    expect(state, gizmo3d_vertex_spv[0] == 0x03 && gizmo3d_vertex_spv[1] == 0x02 &&
           gizmo3d_vertex_spv[2] == 0x23 && gizmo3d_vertex_spv[3] == 0x07,
           "SPIR-V 魔数");
    expect(state, gizmo3d_vertex_dxil[0] == 68 && gizmo3d_vertex_dxil[1] == 88 &&
           gizmo3d_vertex_dxil[2] == 66 && gizmo3d_vertex_dxil[3] == 67,
           "DXIL 容器魔数 DXBC");
    expect(state, gizmo3d_vertex_msl[0] == 35, "MSL 以 # 开头");
    expect(state, wireframe3d_vertex_spv[0] == 0x03 && wireframe3d_vertex_spv[3] == 0x07,
           "线框 SPIR-V 魔数");
}
//@endregion
