// 扫掠沿 pos + move*t，t ∈ [0, range]；move 不要求归一化。
// 命中实体内部/表面起点返回 (0, true)，未命中返回 (range, false)。
// 改编自 Ravn 的标量扫掠，重写端盖与球体边角处理；不依赖 SIMD 或平台指令。
// 一比一移植自 olib core/geometry/sweep.odin（向量桥接与几何查询见 geometry.jai）。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   - Jai 没有数组算术：`m - md * d`、`pos + move * t` 等一律走 geometry.jai 里的
//     geom_add / geom_sub / geom_scale / geom_div / geom_add_scalar / geom_sub_scalar；
//   - Jai 没有数组字面量拆包：`{a, b}` 这种 [2][3]f32 复合字面量要写成带类型的
//     局部变量 `edge : [2] V3 = .[a, b]`，不能直接当实参（会被当成两个实参展开）；
//   - Jai 无具名返回值：olib 的 `t = range` 初值改成局部变量 `t := range`，
//     `return` 一律显式写全 (t, ok) / (t, uv, ok)；
//   - `cond ? a : b` 表达式语法不可用，改写成 if / else；
//   - `normal /= nlen` 改用 geom_div（参数与局部向量都不支持 /= ）；
//   - olib 的 `for side in ([2]f32{-1, 1})` 改成 `sides : [2] float32 = .[-1, 1]` 再遍历；
//   - `for i in 0..<3` 在 Jai 写 `for 0..2`（Jai 的 `..` 含终点），`0..=20` 写 `0..20`；
//   - int 字面量不自动转 float32：与 float32 混算处写浮点字面量或显式 cast；
//   - olib 的 `"contextless"` 与 `@(private)` 在 Jai 没有对应标注，去掉（Jai 过程
//     默认不携带上下文；triangle_coordinates 仍只在本包内使用）。
#import "Basic";
#import "Math";

//@region 点扫掠

// olib 的具名返回 (t, ok)。
sweep_point_vs_plane :: (
    pos: V3, move: V3, normal: V3, dist: float32, range: float32 = 1,
) -> (float32, bool) {
    if range < 0 || geom_length_sq(normal) == 0 return range, false;
    rel := dist - geom_dot(normal, pos);
    if rel == 0 return 0, true;
    denom := geom_dot(normal, move);
    if denom == 0 return range, false;
    t := rel / denom;
    ok := t >= 0 && t <= range;
    // olib: return ok ? t : range, ok
    if ok return t, ok;
    return range, ok;
}

// olib 的具名返回 (t, ok)。
sweep_point_vs_sphere :: (
    pos: V3, move: V3, center: V3, rad: float32, range: float32 = 1,
) -> (float32, bool) {
    if range < 0 return range, false;
    m := geom_sub(pos, center);
    c := geom_length_sq(m) - rad * rad;
    if c <= 0 return 0, true;
    a := geom_length_sq(move);
    b := geom_dot(m, move);
    if a == 0 || b >= 0 return range, false;
    discr := b * b - a * c;
    if discr < 0 return range, false;
    // 等价于 (-b-sqrt(discr))/a，避免起点贴近球面时相减抵消。
    t := c / (-b + sqrt(discr));
    ok := t >= 0 && t <= range;
    if ok return t, true;
    return range, false;
}

// olib 的具名返回 (t, ok)。
sweep_point_vs_aabb :: (
    pos: V3, move: V3, aabb_min: V3, aabb_max: V3, range: float32 = 1,
) -> (float32, bool) {
    if range < 0 return range, false;
    enter: float32 = 0;
    exit := range; // 局部变量遮蔽 Basic 的同名过程 exit，proc 内不再调用它，行为与 olib 一致
    for 0..2 {
        axis := it;
        if move[axis] == 0 {
            if pos[axis] < aabb_min[axis] || pos[axis] > aabb_max[axis] {
                return range, false;
            }
            continue;
        }
        t0 := (aabb_min[axis] - pos[axis]) / move[axis];
        t1 := (aabb_max[axis] - pos[axis]) / move[axis];
        enter = max(enter, min(t0, t1));
        exit = min(exit, max(t0, t1));
        if enter > exit return range, false;
    }
    return enter, true;
}

// 双面三角形；平行/共面路径只报告恰好在三角形上的起点，不求共面边穿越。
// 退化三角形也只报告起点接触；需要线段/点的厚度扫掠时使用 sphere_vs_triangle。
// olib 的具名返回 (t, ok)。
sweep_point_vs_triangle :: (
    pos: V3, move: V3, tri: [3] V3, range: float32 = 1,
) -> (float32, bool) {
    if range < 0 return range, false;
    if get_triangle_dist_sq(pos, tri) == 0 return 0, true;
    normal := geom_cross(geom_sub(tri[1], tri[0]), geom_sub(tri[2], tri[0]));
    t, ok := sweep_point_vs_plane(pos, move, normal, geom_dot(normal, tri[0]), range);
    if !ok return range, false;
    _, inside := triangle_coordinates(geom_add(pos, geom_scale(move, t)), tri);
    if inside return t, true;
    return range, false;
}

// 仅查询沿单位法线偏移 ±rad 的两个三角形面，不包含三个侧面。
// uv 分别对应 tri[1]、tri[2] 权重；未命中时为零。
// olib 的具名返回 (t, uv, ok)。
sweep_point_vs_triangle_slab :: (
    pos: V3, move: V3, tri: [3] V3, rad: float32, range: float32 = 1,
) -> (float32, [2] float32, bool) {
    t := range;
    uv: [2] float32;
    ok := false;
    raw_normal := geom_cross(geom_sub(tri[1], tri[0]), geom_sub(tri[2], tri[0]));
    nlen := geom_length(raw_normal);
    if nlen == 0 || range < 0 return t, uv, ok;
    normal := geom_div(raw_normal, nlen);
    sides : [2] float32 = .[-1, 1];
    for side: sides {
        plane_dist := geom_dot(normal, tri[0]) + side * rad;
        candidate, hit := sweep_point_vs_plane(pos, move, normal, plane_dist, t);
        if !hit continue;
        // olib: pos + move * candidate - normal * side * rad
        shifted := geom_sub(
            geom_add(pos, geom_scale(move, candidate)), geom_scale(normal, side * rad));
        coords, inside := triangle_coordinates(shifted, tri);
        if inside {
            t = candidate;
            uv = coords;
            ok = true;
        }
    }
    return t, uv, ok;
}

// 无端盖版本仅查询圆柱侧面；非零长度轴，起点在侧面上时返回零。
// olib 的具名返回 (t, ok)。
sweep_point_vs_uncapped_cylinder :: (
    pos: V3, move: V3, points: [2] V3, rad: float32, range: float32 = 1,
) -> (float32, bool) {
    t := range;
    ok := false;
    d := geom_sub(points[1], points[0]);
    dd := geom_length_sq(d);
    if dd == 0 || range < 0 return t, ok;
    m := geom_sub(pos, points[0]);
    md := geom_dot(m, d) / dd;
    nd := geom_dot(move, d) / dd;
    rm := geom_sub(m, geom_scale(d, md));
    rn := geom_sub(move, geom_scale(d, nd));
    a := geom_length_sq(rn);
    b := geom_dot(rm, rn);
    c := geom_length_sq(rm) - rad * rad;
    if c == 0 && md >= 0 && md <= 1 return 0, true;
    if a == 0 return t, ok;
    discr := b * b - a * c;
    if discr < 0 return t, ok;
    root := sqrt(discr);
    candidates : [2] float32 = .[(-b - root) / a, (-b + root) / a];
    for candidate: candidates {
        height := md + candidate * nd;
        if candidate >= 0 && candidate <= t && height >= 0 && height <= 1 {
            t = candidate;
            ok = true;
        }
    }
    return t, ok;
}

// 带平端盖的实体圆柱；零长度轴没有确定端盖方向，返回未命中。
// olib 的具名返回 (t, ok)。
sweep_point_vs_cylinder :: (
    pos: V3, move: V3, points: [2] V3, rad: float32, range: float32 = 1,
) -> (float32, bool) {
    t := range;
    ok := false;
    d := geom_sub(points[1], points[0]);
    dd := geom_length_sq(d);
    if dd == 0 || range < 0 return t, ok;
    m := geom_sub(pos, points[0]);
    md := geom_dot(m, d) / dd;
    nd := geom_dot(move, d) / dd;
    if md >= 0 && md <= 1 && geom_length_sq(geom_sub(m, geom_scale(d, md))) <= rad * rad {
        return 0, true;
    }
    t, ok = sweep_point_vs_uncapped_cylinder(pos, move, points, rad, range);
    if nd != 0 {
        caps : [2] float32 = .[0, 1];
        for cap: caps {
            candidate := (cap - md) / nd;
            if candidate < 0 || candidate > t continue;
            // olib: q := m + move * candidate - cap * d
            q := geom_sub(geom_add(m, geom_scale(move, candidate)), geom_scale(d, cap));
            if geom_length_sq(q) <= rad * rad {
                t = candidate;
                ok = true;
            }
        }
    }
    return t, ok;
}

// 胶囊为有限圆柱侧面与两个端点球的并集；零长度轴退化为球。
// olib 的具名返回 (t, ok)。
sweep_point_vs_capsule :: (
    pos: V3, move: V3, points: [2] V3, rad: float32, range: float32 = 1,
) -> (float32, bool) {
    if range < 0 return range, false;
    if test_point_vs_capsule(pos, points, rad) return 0, true;
    t, ok := sweep_point_vs_uncapped_cylinder(pos, move, points, rad, range);
    for center: points {
        candidate, hit := sweep_point_vs_sphere(pos, move, center, rad, t);
        if hit {
            t = candidate;
            ok = true;
        }
    }
    return t, ok;
}
//@endregion

//@region 球扫掠

// olib 的具名返回 (t, ok)。
sweep_sphere_vs_aabb :: (
    pos: V3, move: V3, rad: float32, aabb_min: V3, aabb_max: V3, range: float32 = 1,
) -> (float32, bool) {
    if range < 0 return range, false;
    center := geom_scale(geom_add(aabb_min, aabb_max), 0.5);
    extent := geom_scale(geom_sub(aabb_max, aabb_min), 0.5);
    if test_sphere_vs_box(pos, rad, center, extent) return 0, true;
    entry, broad_hit := sweep_point_vs_aabb(
        pos, move, geom_sub_scalar(aabb_min, rad), geom_add_scalar(aabb_max, rad), range);
    if !broad_hit return range, false;
    // 扩张盒的面区域为精确命中；棱角需查询圆角，不能直接用扩张盒代替。
    q := geom_add(pos, geom_scale(move, entry));
    for 0..2 {
        axis := it;
        u := (axis + 1) % 3;
        v := (axis + 2) % 3;
        if q[u] >= aabb_min[u] && q[u] <= aabb_max[u] &&
            q[v] >= aabb_min[v] && q[v] <= aabb_max[v] {
            return entry, true;
        }
    }
    t := range;
    ok := false;
    // 12 条边的胶囊覆盖全部棱与顶点的球面区域。
    for 0..2 {
        axis := it;
        u := (axis + 1) % 3;
        v := (axis + 2) % 3;
        for 0..3 {
            mask := it;
            a := aabb_min;
            // olib: a[u] = mask & 1 != 0 ? aabb_max[u] : aabb_min[u]
            if (mask & 1) != 0 {
                a[u] = aabb_max[u];
            } else {
                a[u] = aabb_min[u];
            }
            if (mask & 2) != 0 {
                a[v] = aabb_max[v];
            } else {
                a[v] = aabb_min[v];
            }
            b := a;
            b[axis] = aabb_max[axis];
            // Jai 的 .[a, b] 直接当实参会被展开成两个实参，先落成带类型的局部变量。
            edge : [2] V3 = .[a, b];
            candidate, hit := sweep_point_vs_capsule(pos, move, edge, rad, t);
            if hit {
                t = candidate;
                ok = true;
            }
        }
    }
    return t, ok;
}

// 双面三角形，检查面、全部边与顶点；退化三角形仍可作为线段/点查询。
// olib 的具名返回 (t, ok)。
sweep_sphere_vs_triangle :: (
    pos: V3, move: V3, rad: float32, tri: [3] V3, range: float32 = 1,
) -> (float32, bool) {
    if range < 0 return range, false;
    if test_sphere_vs_triangle(pos, rad, tri) return 0, true;
    // olib: t, _, ok = sweep_point_vs_triangle_slab(...)；uv 在这里丢弃。
    t, _, ok := sweep_point_vs_triangle_slab(pos, move, tri, rad, range);
    for 0..2 {
        i := it;
        edge : [2] V3 = .[tri[i], tri[(i + 1) % 3]];
        candidate, hit := sweep_point_vs_capsule(pos, move, edge, rad, t);
        if hit {
            t = candidate;
            ok = true;
        }
    }
    return t, ok;
}
//@endregion

//@region 三角形面坐标

// olib 的 @(private) triangle_coordinates；olib 的具名返回 (uv, inside)。
triangle_coordinates :: (pos: V3, tri: [3] V3) -> ([2] float32, bool) {
    uv: [2] float32;
    inside := false;
    a := geom_sub(tri[1], tri[0]);
    b := geom_sub(tri[2], tri[0]);
    p := geom_sub(pos, tri[0]);
    n := geom_cross(a, b);
    denom := geom_length_sq(n);
    if denom == 0 return uv, inside;
    uv = .[
        geom_dot(geom_cross(p, b), n) / denom,
        geom_dot(geom_cross(a, p), n) / denom,
    ];
    inside = uv[0] >= 0 && uv[1] >= 0 && uv[0] + uv[1] <= 1;
    return uv, inside;
}
//@endregion
