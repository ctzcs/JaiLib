// geometry 提供无分配的 3D 距离、最近点、包围盒与重叠查询。
// 改编自 Ravn c7e3e1a2ed24ded01105dcbbc478be1e6b67f64c 的 geometry，见 LICENSE.txt。
// 坐标为 [3] float32，半径/半尺寸非负；退化线段和三角形按点或线段处理。
// 一比一移植自 olib core/geometry/geometry.odin（sweep 部分见 sweep.jai）。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   - Jai 没有数组算术：[3] float32 不能直接 + - * /，也不能整体取 abs / max，
//     所以向量运算统一走本文件开头的具名桥接 geom_add / geom_sub / geom_scale /
//     geom_div / geom_add_scalar / geom_sub_scalar / geom_dot / geom_cross /
//     geom_length_sq / geom_length / geom_abs / geom_max_zero / geom_vec_eq，
//     与 Odin 的 linalg 同名函数一一对应（linalg.length2 → geom_length_sq，
//     linalg.max(q, 0) → geom_max_zero）；
//   - Jai 没有 [3] float32 的 `==`，判等用 geom_vec_eq 逐分量比较；
//   - Jai 无具名返回值：`-> (a, b)` 只能匿名写，olib 的返回值名字保留在注释里，
//     olib 里「先给具名返回赋值、末尾 `return`」的写法改成显式写全返回值；
//   - Jai 没有 i32，feature_index 用 s32；
//   - 没有 switch，枚举分派用 if 链 / if-switch；
//   - `cond ? a : b` 表达式语法不可用，改写成 if / else 语句；
//   - olib 的 `matrix[3,3]f32` 改为 `[3][3] float32`（Jai 是 [行][列]）：olib 里
//     rot[0..2] 是第 0..2 列，这里按列取元 rot[行][列]，见 get_oriented_box_bounds；
//   - int 字面量不自动转 float32：与 float32 混算处写浮点字面量或显式 cast；
//   - olib 的 `"contextless"` 在 Jai 没有对应标注（Jai 过程默认不携带上下文），去掉；
//   - `[3][2]int{{0,1},{0,2},{1,2}}` 这类嵌套字面量写成 `.[.[0, 1], .[0, 2], .[1, 2]]`，
//     `[3]f32{a, b, c}` 写成 `.[a, b, c]`。
#import "Basic";
#import "Math";

//@region 向量桥接（Jai 没有数组算术）

// 向量类型保持 [3] float32，不改成 struct，与 olib 的 [3]f32 完全等价。
// V3 只是该类型的书写别名（Jai 的全局类型别名，无运行时差异），供内部桥接与测试
// 声明「带类型的数组字面量」用；公开签名里的 V3 == olib 的 [3]f32。
V3 :: [3] float32;

geom_add :: (a: V3, b: V3) -> V3 {
    return .[a[0] + b[0], a[1] + b[1], a[2] + b[2]];
}

geom_sub :: (a: V3, b: V3) -> V3 {
    return .[a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

geom_scale :: (a: V3, s: float32) -> V3 {
    return .[a[0] * s, a[1] * s, a[2] * s];
}

geom_div :: (a: V3, s: float32) -> V3 {
    return .[a[0] / s, a[1] / s, a[2] / s];
}

// 向量 + 标量，对应 olib 的 `v + s` 广播。
geom_add_scalar :: (a: V3, s: float32) -> V3 {
    return .[a[0] + s, a[1] + s, a[2] + s];
}

// 向量 - 标量，对应 olib 的 `v - s` 广播。
geom_sub_scalar :: (a: V3, s: float32) -> V3 {
    return .[a[0] - s, a[1] - s, a[2] - s];
}

geom_dot :: (a: V3, b: V3) -> float32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

geom_cross :: (a: V3, b: V3) -> V3 {
    return .[a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
}

// 对应 olib 的 linalg.length2。
geom_length_sq :: (a: V3) -> float32 {
    return geom_dot(a, a);
}

// 对应 olib 的 linalg.length。
geom_length :: (a: V3) -> float32 {
    return sqrt(geom_length_sq(a));
}

// 对应 olib 的 linalg.abs（逐分量绝对值）。
geom_abs :: (a: V3) -> V3 {
    return .[abs(a[0]), abs(a[1]), abs(a[2])];
}

// 对应 olib 的 linalg.max(q, 0)：逐分量与 0 取大。
geom_max_zero :: (a: V3) -> V3 {
    return .[max(a[0], 0.0), max(a[1], 0.0), max(a[2], 0.0)];
}

// 对应 olib 的 `a == b`；Jai 没有数组的 == 运算符，逐分量比较。
geom_vec_eq :: (a: V3, b: V3) -> bool {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}
//@endregion

//@region 最近点与特征

Voronoi_Feature_Kind :: enum u8 {
    Face;
    Edge;
    Vertex;
}

// olib 的具名返回 (closest, t)；末尾 return 对应 olib 的 `return points[0] + t * d, t`。
get_line_closest_point :: (pos: V3, points: [2] V3) -> (V3, float32) {
    d := geom_sub(points[1], points[0]);
    len_sq := geom_length_sq(d);
    // olib: t = len_sq > 0 ? clamp(dot(pos - points[0], d) / len_sq, 0, 1) : 0
    t: float32 = 0;
    if len_sq > 0 {
        t = clamp(geom_dot(geom_sub(pos, points[0]), d) / len_sq, 0.0, 1.0);
    }
    return geom_add(points[0], geom_scale(d, t)), t;
}

// Edge 下标对应 01、02、12；退化时选择最近线段，相等时按此顺序。
// olib 的具名返回 (closest, feature_kind, feature_index)。
get_triangle_closest_point :: (pos: V3, tri: [3] V3) -> (V3, Voronoi_Feature_Kind, s32) {
    v01 := geom_sub(tri[1], tri[0]);
    v02 := geom_sub(tri[2], tri[0]);
    v12 := geom_sub(tri[2], tri[1]);
    if geom_length_sq(geom_cross(v01, v02)) == 0 {
        indices: [3][2] int = .[.[0, 1], .[0, 2], .[1, 2]];
        best: float32;
        closest: V3;
        feature_kind: Voronoi_Feature_Kind;
        feature_index: s32;
        for edge, i: indices {
            segment: [2] V3 = .[tri[edge[0]], tri[edge[1]]];
            p, u := get_line_closest_point(pos, segment);
            d := geom_length_sq(geom_sub(pos, p));
            if i == 0 || d < best {
                best = d;
                closest = p;
                feature_kind = .Edge;
                feature_index = cast(s32) i;
                if u == 0 || u == 1 {
                    feature_kind = .Vertex;
                    // olib: i32(u == 0 ? edge[0] : edge[1])，改成 if / else。
                    if u == 0 {
                        feature_index = cast(s32) edge[0];
                    } else {
                        feature_index = cast(s32) edge[1];
                    }
                }
            }
        }
        return closest, feature_kind, feature_index;
    }
    d1 := geom_dot(v01, geom_sub(pos, tri[0]));
    d2 := geom_dot(v02, geom_sub(pos, tri[0]));
    d3 := geom_dot(v01, geom_sub(pos, tri[1]));
    d4 := geom_dot(v02, geom_sub(pos, tri[1]));
    d5 := geom_dot(v01, geom_sub(pos, tri[2]));
    d6 := geom_dot(v02, geom_sub(pos, tri[2]));
    if d1 <= 0 && d2 <= 0 return tri[0], .Vertex, 0;
    if d3 >= 0 && d4 <= d3 return tri[1], .Vertex, 1;
    if d6 >= 0 && d5 <= d6 return tri[2], .Vertex, 2;
    vc := d1 * d4 - d3 * d2;
    vb := d5 * d2 - d1 * d6;
    va := d3 * d6 - d5 * d4;
    if vc <= 0 && d1 >= 0 && d3 <= 0 {
        return geom_add(tri[0], geom_scale(v01, d1 / (d1 - d3))), .Edge, 0;
    }
    if vb <= 0 && d2 >= 0 && d6 <= 0 {
        return geom_add(tri[0], geom_scale(v02, d2 / (d2 - d6))), .Edge, 1;
    }
    if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 {
        return geom_add(tri[1], geom_scale(v12, (d4 - d3) / ((d4 - d3) + (d5 - d6)))), .Edge, 2;
    }
    denom := 1.0 / (va + vb + vc);
    return geom_add(geom_add(tri[0], geom_scale(v01, vb * denom)), geom_scale(v02, vc * denom)),
        .Face, 0;
}
//@endregion

//@region 距离与梯度

// 保留上游语义：这是球的隐式函数 |p-c|²-r²，不是到球面的距离平方。
get_sphere_dist_sq :: (pos: V3, center: V3, rad: float32) -> float32 {
    return geom_length_sq(geom_sub(pos, center)) - rad * rad;
}

get_sphere_dist :: (pos: V3, center: V3, rad: float32) -> float32 {
    return geom_length(geom_sub(pos, center)) - rad;
}

// olib 的具名返回 (dist, grad)。
get_sphere_dist_grad :: (pos: V3, center: V3, rad: float32) -> (float32, V3) {
    rel := geom_sub(pos, center);
    d := geom_length(rel);
    // olib: return d - rad, d > 0 ? rel / d : [3]f32{0, 1, 0}
    if d > 0 {
        return d - rad, geom_div(rel, d);
    }
    return d - rad, .[0, 1, 0];
}

get_box_dist :: (pos: V3, center: V3, rad: V3) -> float32 {
    q := geom_sub(geom_abs(geom_sub(pos, center)), rad);
    return geom_length(geom_max_zero(q)) + min(max(max(q[0], q[1]), q[2]), 0.0);
}

// 不可微处确定性选择一个单位外向方向（并列轴按 x、y、z）。
// olib 的具名返回 (dist, grad)。
get_box_dist_grad :: (pos: V3, center: V3, rad: V3) -> (float32, V3) {
    rel := geom_sub(pos, center);
    w := geom_sub(geom_abs(rel), rad);
    q := geom_max_zero(w);
    d := geom_length(q);
    if d > 0 {
        grad := geom_div(q, d);
        for 0..2 {
            axis := it;
            if rel[axis] < 0 grad[axis] = -grad[axis];
        }
        return d, grad;
    }
    axis := 0;
    if w[1] > w[axis] axis = 1;
    if w[2] > w[axis] axis = 2;
    grad: V3;
    // olib: grad[axis] = rel[axis] < 0 ? -1 : 1
    if rel[axis] < 0 {
        grad[axis] = -1;
    } else {
        grad[axis] = 1;
    }
    return w[axis], grad;
}

get_line_dist_sq :: (pos: V3, points: [2] V3) -> float32 {
    p, _ := get_line_closest_point(pos, points);
    return geom_length_sq(geom_sub(pos, p));
}

get_line_dist :: (pos: V3, points: [2] V3) -> float32 {
    return sqrt(get_line_dist_sq(pos, points));
}

// olib 的具名返回 (dist, grad)。
get_line_dist_grad :: (pos: V3, points: [2] V3) -> (float32, V3) {
    p, _ := get_line_closest_point(pos, points);
    dist := geom_length(geom_sub(pos, p));
    // olib: return dist, dist > 0 ? (pos - p) / dist : [3]f32{}
    if dist > 0 {
        return dist, geom_div(geom_sub(pos, p), dist);
    }
    return dist, .[0, 0, 0];
}

get_triangle_dist_sq :: (pos: V3, tri: [3] V3) -> float32 {
    p, _, _ := get_triangle_closest_point(pos, tri);
    return geom_length_sq(geom_sub(pos, p));
}

get_triangle_dist :: (pos: V3, tri: [3] V3) -> float32 {
    return sqrt(get_triangle_dist_sq(pos, tri));
}

// olib 的具名返回 (dist, grad)。
get_triangle_dist_grad :: (pos: V3, tri: [3] V3) -> (float32, V3) {
    p, _, _ := get_triangle_closest_point(pos, tri);
    dist := geom_length(geom_sub(pos, p));
    // olib: return dist, dist > 0 ? (pos - p) / dist : [3]f32{}
    if dist > 0 {
        return dist, geom_div(geom_sub(pos, p), dist);
    }
    return dist, .[0, 0, 0];
}
//@endregion

//@region 包围盒与重叠

// olib 的具名返回 (min, max)（min / max 是 Jai 的既有过程名，这里只作返回值注释）。
// extent = |rad.x * 列0| + |rad.y * 列1| + |rad.z * 列2|；Jai 的 [3][3] 是 [行][列]，
// 所以第 c 列是 (rot[0][c], rot[1][c], rot[2][c])。
get_oriented_box_bounds :: (pos: V3, rad: V3, rot: [3][3] float32) -> (V3, V3) {
    extent: V3;
    for 0..2 {
        c := it;
        column: V3 = .[rot[0][c], rot[1][c], rot[2][c]];
        extent = geom_add(extent, geom_scale(geom_abs(column), rad[c]));
    }
    return geom_sub(pos, extent), geom_add(pos, extent);
}

test_point_vs_aabb :: (pos: V3, min: V3, max: V3) -> bool {
    return pos[0] >= min[0] && pos[0] <= max[0] &&
        pos[1] >= min[1] && pos[1] <= max[1] && pos[2] >= min[2] && pos[2] <= max[2];
}

test_point_vs_sphere :: (pos: V3, center: V3, rad: float32) -> bool {
    return geom_length_sq(geom_sub(pos, center)) <= rad * rad;
}

test_point_vs_capsule :: (pos: V3, points: [2] V3, rad: float32) -> bool {
    return get_line_dist_sq(pos, points) <= rad * rad;
}

test_sphere_vs_sphere :: (pos_a: V3, rad_a: float32, pos_b: V3, rad_b: float32) -> bool {
    return geom_length_sq(geom_sub(pos_a, pos_b)) <= (rad_a + rad_b) * (rad_a + rad_b);
}

test_sphere_vs_box :: (pos: V3, rad: float32, center: V3, extent: V3) -> bool {
    q := geom_max_zero(geom_sub(geom_abs(geom_sub(pos, center)), extent));
    return geom_length_sq(q) <= rad * rad;
}

test_sphere_vs_triangle :: (pos: V3, rad: float32, tri: [3] V3) -> bool {
    return get_triangle_dist_sq(pos, tri) <= rad * rad;
}

test_aabb_vs_aabb :: (a_min: V3, a_max: V3, b_min: V3, b_max: V3) -> bool {
    return a_max[0] >= b_min[0] && a_min[0] <= b_max[0] &&
        a_max[1] >= b_min[1] && a_min[1] <= b_max[1] &&
        a_max[2] >= b_min[2] && a_min[2] <= b_max[2];
}
//@endregion
