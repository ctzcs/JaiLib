// 一比一移植自 olib tests/core/geometry/geometry_test.odin。
// 断言语义、数值与出现顺序保持原样，只做语言差异替换：
//   - core:testing.expect → test_support.expect（同一处对应一条断言，附带中文说明）；
//   - [3]f32 的 `==` → GE.geom_vec_eq（Jai 没有数组的 == 运算符）；
//   - linalg.length(a - b) → GE.geom_length(GE.geom_sub(a, b))（Jai 没有数组算术）；
//   - [3]f32{a, b, c} → .[a, b, c]，矩阵字面量按行写 `.[.[...], ...]`；
//   - `for i in 0..<n` → `for 0..n-1`，`for i in a..=b` → `for a..b`（Jai 的 .. 含终点）；
//   - switch → if-switch（`if x == { case 0; ... }`）；
//   - math.is_nan → isnan（Math 模块）；
//   - 浮点指数字面量写 1.0e-5 / 1.0e-6（官方 Jai 不接受 `1e-5` 这种无小数部分的写法）。
#import "Basic";
#import "Math";
#import "test_support";
GE :: #import "core/geometry";

//@region 距离、特征与包围盒

closest_features_and_degenerates :: (state: *Test_State) {
    tri: [3] GE.V3 = .[.[0, 0, 0], .[2, 0, 0], .[0, 2, 0]];
    p, kind, index := GE.get_triangle_closest_point(.[0.5, 0.5, 3], tri);
    expect(state, GE.geom_vec_eq(p, .[0.5, 0.5, 0]) && kind == .Face, "面最近点");
    p, kind, index = GE.get_triangle_closest_point(.[1, -1, 0], tri);
    expect(state, GE.geom_vec_eq(p, .[1, 0, 0]) && kind == .Edge && index == 0, "边 01 最近点");
    p, kind, index = GE.get_triangle_closest_point(.[-1, 1, 0], tri);
    expect(state, GE.geom_vec_eq(p, .[0, 1, 0]) && kind == .Edge && index == 1, "边 02 最近点");
    p, kind, index = GE.get_triangle_closest_point(.[2, 2, 0], tri);
    expect(state, GE.geom_vec_eq(p, .[1, 1, 0]) && kind == .Edge && index == 2, "边 12 最近点");
    p, kind, index = GE.get_triangle_closest_point(.[-1, -1, 0], tri);
    expect(state, GE.geom_vec_eq(p, .[0, 0, 0]) && kind == .Vertex && index == 0, "顶点 0 最近点");
    flat: [3] GE.V3 = .[.[0, 0, 0], .[2, 0, 0], .[1, 0, 0]];
    p, _, _ = GE.get_triangle_closest_point(.[1, 3, 0], flat);
    expect(state, GE.geom_vec_eq(p, .[1, 0, 0]), "退化三角形最近点");
    expect(state, GE.get_triangle_dist(.[1, 3, 0], flat) == 3, "退化三角形距离");
    point: [3] GE.V3 = .[.[2, 0, 0], .[2, 0, 0], .[2, 0, 0]];
    expect(state, GE.get_triangle_dist(.[0, 0, 0], point) == 2, "点三角形距离");
    segment: [2] GE.V3 = .[.[2, 0, 0], .[2, 0, 0]];
    expect(state, GE.get_line_dist(.[0, 0, 0], segment) == 2, "点线段距离");
    dist, grad := GE.get_triangle_dist_grad(.[0.5, 0.5, -3], tri);
    expect(state, dist == 3 && GE.geom_vec_eq(grad, .[0, 0, -1]), "三角形面梯度");
    dist, grad = GE.get_line_dist_grad(.[2, 0, 0], segment);
    expect(state, dist == 0 && GE.geom_vec_eq(grad, .[0, 0, 0]), "退化线段零距离梯度");
}

signed_distances_and_gradients :: (state: *Test_State) {
    expect(state, GE.get_sphere_dist(.[0, 0, 0], .[0, 0, 0], 2) == -2, "球面距离内部为负");
    expect(state, GE.get_sphere_dist_sq(.[3, 0, 0], .[0, 0, 0], 2) == 5, "球面隐式函数 |p-c|²-r²");
    d, g := GE.get_sphere_dist_grad(.[0, 0, 0], .[0, 0, 0], 2);
    expect(state, d == -2 && GE.geom_vec_eq(g, .[0, 1, 0]), "球心梯度确定性方向");
    d, g = GE.get_box_dist_grad(.[0, 0, 0], .[0, 0, 0], .[1, 2, 3]);
    expect(state, d == -1 && GE.geom_vec_eq(g, .[1, 0, 0]), "盒内梯度取并列轴 x");
    d, g = GE.get_box_dist_grad(.[-4, 6, 0], .[0, 0, 0], .[1, 2, 3]);
    expect(state, d == 5 && GE.geom_length(GE.geom_sub(g, .[-0.6, 0.8, 0])) < 1.0e-6, "盒体棱角梯度");
    // 数值微分验证梯度方向与带符号距离一致。
    pos: GE.V3 = .[3, -4, 5];
    d, g = GE.get_box_dist_grad(pos, .[0, 0, 0], .[1, 2, 3]);
    for 0..2 {
        axis := it;
        offset: GE.V3;
        offset[axis] = 0.001;
        fd := (GE.get_box_dist(GE.geom_add(pos, offset), .[0, 0, 0], .[1, 2, 3]) -
        GE.get_box_dist(GE.geom_sub(pos, offset), .[0, 0, 0], .[1, 2, 3])) / 0.002;
        expect(state, abs(fd - g[axis]) < 0.001, "盒体梯度数值微分 axis %", axis);
    }
}

bounds_and_touching_overlap :: (state: *Test_State) {
    rot: [3][3] float32 = .[.[0, -1, 0], .[1, 0, 0], .[0, 0, 1]];
    lo, hi := GE.get_oriented_box_bounds(.[10, 20, 30], .[1, 2, 3], rot);
    expect(state, GE.geom_vec_eq(lo, .[8, 19, 27]) && GE.geom_vec_eq(hi, .[12, 21, 33]), "带朝向盒包围盒");
    expect(state, GE.test_point_vs_aabb(lo, lo, hi), "aabb 边界点命中");
    expect(state, !GE.test_point_vs_aabb(GE.geom_sub_scalar(lo, 1), lo, hi), "aabb 外点不命中");
    expect(state, GE.test_aabb_vs_aabb(.[0, 0, 0], .[1, 1, 1], .[1, 1, 1], .[2, 2, 2]), "aabb 相切命中");
    expect(state, GE.test_point_vs_sphere(.[1, 0, 0], .[0, 0, 0], 1), "点在球面命中");
    expect(state, GE.test_sphere_vs_sphere(.[0, 0, 0], 1, .[2, 0, 0], 1), "球球相切命中");
    expect(state, GE.test_sphere_vs_box(.[2, 0, 0], 1, .[0, 0, 0], .[1, 1, 1]), "球盒相切命中");
    expect(state, !GE.test_sphere_vs_box(.[2, 2, 0], 1, .[0, 0, 0], .[1, 1, 1]), "球盒分离不命中");
}
//@endregion

//@region 扫掠边界与端盖

// olib 的 @(private) expect_hit：命中且参数差 < 1e-5（Jai 写作 1.0e-5）。
expect_hit :: (state: *Test_State, actual: float32, ok: bool, expected: float32) {
    expect(state, ok && abs(actual - expected) < 1.0e-5,
    "期望命中 %，实得 (%, %)", expected, actual, ok);
}

sweep_ranges_parallel_and_initial_overlap :: (state: *Test_State) {
    hit, ok := GE.sweep_point_vs_sphere(.[-3, 0, 0], .[2, 0, 0], .[0, 0, 0], 1);
    expect_hit(state, hit, ok, 1);
    hit, ok = GE.sweep_point_vs_sphere(.[0, 0, 0], .[0, 0, 0], .[0, 0, 0], 1);
    expect_hit(state, hit, ok, 0);
    hit, ok = GE.sweep_point_vs_sphere(.[-3, 1, 0], .[1, 0, 0], .[0, 0, 0], 1, 4);
    expect_hit(state, hit, ok, 3);
    hit, ok = GE.sweep_point_vs_sphere(.[-3, 0, 0], .[0, 0, 0], .[0, 0, 0], 1);
    expect(state, !ok && hit == 1, "球扫掠静止未命中");
    hit, ok = GE.sweep_point_vs_aabb(.[-2, 1, 0], .[1, 0, 0], .[-1, -1, -1], .[1, 1, 1]);
    expect_hit(state, hit, ok, 1);
    hit, ok = GE.sweep_point_vs_aabb(.[-2, 2, 0], .[1, 0, 0], .[-1, -1, -1], .[1, 1, 1]);
    expect(state, !ok && hit == 1, "aabb 扫掠范围外未命中");
    hit, ok = GE.sweep_point_vs_aabb(.[0, 0, 0], .[0, 0, 0], .[-1, -1, -1], .[1, 1, 1], 0);
    expect_hit(state, hit, ok, 0);
    hit, ok = GE.sweep_point_vs_plane(.[0, 2, 0], .[0, -2, 0], .[0, 1, 0], 0);
    expect_hit(state, hit, ok, 1);
    hit, ok = GE.sweep_point_vs_plane(.[0, 2, 0], .[1, 0, 0], .[0, 1, 0], 0);
    expect(state, !ok && hit == 1, "平面平行未命中");
    tri: [3] GE.V3 = .[.[0, 0, 0], .[2, 0, 0], .[0, 2, 0]];
    hit, ok = GE.sweep_point_vs_triangle(.[0.5, 0.5, -1], .[0, 0, 1], tri);
    expect_hit(state, hit, ok, 1);
    hit, ok = GE.sweep_point_vs_triangle(.[3, 3, 1], .[0, 0, -1], tri);
    expect(state, !ok && hit == 1, "三角形扫掠平面外未命中");
}

cylinder_and_capsule_endcaps :: (state: *Test_State) {
    axis: [2] GE.V3 = .[.[0, 0, 0], .[0, 2, 0]];
    hit, ok := GE.sweep_point_vs_cylinder(.[0, -3, 0], .[0, 1, 0], axis, 1, 4);
    expect_hit(state, hit, ok, 3);
    hit, ok = GE.sweep_point_vs_cylinder(.[0, 5, 0], .[0, -2, 0], axis, 1, 2);
    expect_hit(state, hit, ok, 1.5);
    hit, ok = GE.sweep_point_vs_cylinder(.[3, 1, 0], .[-2, 0, 0], axis, 1);
    expect_hit(state, hit, ok, 1);
    hit, ok = GE.sweep_point_vs_cylinder(.[0, 1, 0], .[0, 0, 0], axis, 1);
    expect_hit(state, hit, ok, 0);
    hit, ok = GE.sweep_point_vs_uncapped_cylinder(.[0, -3, 0], .[0, 1, 0], axis, 1, 4);
    expect(state, !ok && hit == 4, "无端盖圆柱未命中");
    hit, ok = GE.sweep_point_vs_capsule(.[0, -3, 0], .[0, 1, 0], axis, 1, 4);
    expect_hit(state, hit, ok, 2);
    hit, ok = GE.sweep_point_vs_capsule(.[0, 5, 0], .[0, -2, 0], axis, 1, 2);
    expect_hit(state, hit, ok, 1);
    hit, ok = GE.sweep_point_vs_capsule(.[0, 5, 0], .[0, -1, 0], axis, 1);
    expect(state, !ok && hit == 1, "胶囊扫掠范围外未命中");
    degenerate: [2] GE.V3 = .[.[0, 0, 0], .[0, 0, 0]];
    hit, ok = GE.sweep_point_vs_capsule(.[3, 0, 0], .[-2, 0, 0], degenerate, 1);
    expect_hit(state, hit, ok, 1);
    hit, ok = GE.sweep_point_vs_capsule(.[0, -0.5, 0], .[0, 0, 0], axis, 1);
    expect_hit(state, hit, ok, 0);
}

sphere_faces_edges_and_vertices :: (state: *Test_State) {
    lo: GE.V3 = .[-1, -1, -1];
    hi: GE.V3 = .[1, 1, 1];
    hit, ok := GE.sweep_sphere_vs_aabb(.[-3, 0, 0], .[1, 0, 0], 0.5, lo, hi, 3);
    expect_hit(state, hit, ok, 1.5);
    hit, ok = GE.sweep_sphere_vs_aabb(.[-3, 1.3, 0], .[1, 0, 0], 0.5, lo, hi, 3);
    expect_hit(state, hit, ok, 1.6);
    hit, ok = GE.sweep_sphere_vs_aabb(.[-3, 1.3, 1.4], .[1, 0, 0], 0.5, lo, hi, 3);
    expect(state, ok && abs(hit - 2) < 0.001, "球扫掠 aabb 棱角命中 %", hit);
    hit, ok = GE.sweep_sphere_vs_aabb(.[-3, 1.4, 1.4], .[1, 0, 0], 0.5, lo, hi, 3);
    expect(state, !ok && hit == 3, "球扫掠 aabb 顶点旁未命中");
    tri: [3] GE.V3 = .[.[0, 0, 0], .[2, 0, 0], .[0, 2, 0]];
    hit, ok = GE.sweep_sphere_vs_triangle(.[0.5, 0.5, 2], .[0, 0, -1], 0.5, tri, 3);
    expect_hit(state, hit, ok, 1.5);
    hit, ok = GE.sweep_sphere_vs_triangle(.[1, -0.3, 2], .[0, 0, -1], 0.5, tri, 3);
    expect_hit(state, hit, ok, 1.6);
    hit, ok = GE.sweep_sphere_vs_triangle(.[-0.3, 0, 2], .[0, 0, -1], 0.5, tri, 3);
    expect_hit(state, hit, ok, 1.6);
    empty: [3] GE.V3 = .[.[0, 0, 0], .[0, 0, 0], .[0, 0, 0]];
    hit, ok = GE.sweep_sphere_vs_triangle(.[0, 0, 2], .[0, 0, -1], 0.5, empty, 3);
    expect_hit(state, hit, ok, 1.5);
}
//@endregion

//@region 静态距离交叉验证

// 固定网格覆盖不同方向与初始状态；距离函数独立验证扫掠接触和漏报。
sweeps_agree_with_static_distance :: (state: *Test_State) {
    tri: [3] GE.V3 = .[.[0, 0, 0], .[2, 0, 0], .[0, 2, 0]];
    axis: [2] GE.V3 = .[.[0, 0, 0], .[0, 2, 0]];
    // olib: for x in -3..=3 / y in -3..=3 / z in -2..=2（Jai 的 .. 含终点）
    for x: -3..3 {
        for y: -3..3 {
            for z: -2..2 {
                pos: GE.V3 = .[
                cast(float32) x * 0.8, cast(float32) y * 0.8, cast(float32) z * 0.8];
                move := GE.geom_sub(.[0.3, 0.4, 0.2], pos);
                for shape: 0..2 {
                    hit: float32;
                    ok := false;
                    if shape == {
                        case 0;
                            hit, ok = GE.sweep_point_vs_capsule(pos, move, axis, 0.5);
                        case 1;
                            hit, ok = GE.sweep_sphere_vs_aabb(
                            pos, move, 0.5, .[-1, -1, -1], .[1, 1, 1]);
                        case 2;
                            hit, ok = GE.sweep_sphere_vs_triangle(pos, move, 0.5, tri);
                    }
                    expect(state, !isnan(hit) && hit >= 0 && hit <= 1,
                    "shape % 扫掠参数在 [0, range] 内", shape);
                    if ok {
                        d := static_test_distance(
                        shape, GE.geom_add(pos, GE.geom_scale(move, hit)), tri, axis);
                        expect(state, d <= 0.5001, "shape % 命中过早: %", shape, d);
                        if hit > 0 {
                            expect(state, abs(d - 0.5) < 0.0001, "shape % 命中处距离: %", shape, d);
                        }
                    }
                    for 0..20 {
                        u := cast(float32) it / 20;
                        d := static_test_distance(
                        shape, GE.geom_add(pos, GE.geom_scale(move, u)), tri, axis);
                        if d < 0.4999 {
                            expect(state, ok && hit <= u + 0.0001,
                            "shape % 漏报重叠: u=% 起点=%", shape, u, pos);
                        }
                    }
                }
            }
        }
    }
}

// olib 的 @(private) static_test_distance：用静态距离函数交叉验证扫掠结果。
static_test_distance :: (
shape: int, pos: GE.V3, tri: [3] GE.V3, axis: [2] GE.V3,
) -> float32 {
    if shape == {
        case 0; return GE.get_line_dist(pos, axis);
        case 1; return GE.get_box_dist(pos, .[0, 0, 0], .[1, 1, 1]);
        case 2; return GE.get_triangle_dist(pos, tri);
    }
    return 0;
}
//@endregion

// Loop scopes adapted.
