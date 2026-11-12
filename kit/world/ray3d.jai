// world:ray3d —— 射线与 3D 相交测试（对位 DragonLib World.Ray3D / Intersections3D）。
//
// 方向归一化，所有相交距离以世界单位计。
// DassetPrimitive 的逐三角形拾取等模型格式落地后再补（见 ROADMAP P2）。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   | olib (Odin)                    | JaiLib (Jai)                                       |
//   | foster.Vec3                        | Vec3（= Math.Vector3 别名，axis 循环用 .component） |
//   | foster.Vec3{x, y, z}               | Vec3.{ x, y, z }                                   |
//   | math.sqrt / math.abs               | JM.sqrt / abs                                      |
//   | math.INF_F32                       | JM.FLOAT32_INFINITY                              |
//   | `return {}, false`（零值 Ray3D）   | `return zero_ray3d(), false`（Jai 无零值字面量返回） |
//   | `a, b: foster.Vec3` 形参           | a: Vec3, b: Vec3（Jai 每个形参各自写类型）          |
//   | `double_sided := true` 默认参      | 同形（Jai 用 := 写默认参数）                        |
//   | `cond ? a : b` 表达式              | if / else 语句                                     |
//   | `for axis in 0..<3`                | `for axis: 0..2`（Jai 的 a..b 含终点）              |
#import "Basic";

//@region Ray3D —— 构造与采样

Ray3D :: struct {
    origin:    Vec3;
    direction: Vec3; // 单位向量
}

// 方向为零/非有限时返回 false。
ray3d_make :: (origin: Vec3, direction: Vec3) -> (Ray3D, bool) {
    l2 := v3_dot(direction, direction);
    if !(l2 >= cast(float32) 1.0e-20) { // 兼顾 NaN（NaN 比较全 false）
        return zero_ray3d(), false;
    }
    l := JM.sqrt(l2);
    return Ray3D.{ origin = origin, direction = Vec3.{
        direction.x / l, direction.y / l, direction.z / l,
    } }, true;
}

// 沿射线取距 origin 距离 d 的点。
ray3d_at :: (ray: Ray3D, d: float32) -> Vec3 {
    return Vec3.{
        ray.origin.x + ray.direction.x * d,
        ray.origin.y + ray.direction.y * d,
        ray.origin.z + ray.direction.z * d,
    };
}
//@endregion

//@region 相交测试 —— aabb / triangle / sphere / plane

// AABB 相交（slab 法）。命中返回进入距离；min>max 的无效盒子返回 false。
ray3d_hit_aabb :: (ray: Ray3D, bmin: Vec3, bmax: Vec3) -> (float32, bool) {
    near : float32 = 0;
    far  : float32 = JM.FLOAT32_INFINITY;

    for axis: 0..2 {
        o := ray.origin.component[axis];
        d := ray.direction.component[axis];
        if bmin.component[axis] > bmax.component[axis] return 0, false;
        if JM.abs(d) < cast(float32) 1.0e-8 {
            if o < bmin.component[axis] || o > bmax.component[axis] return 0, false;
            continue;
        }
        a := (bmin.component[axis] - o) / d;
        b := (bmax.component[axis] - o) / d;
        near = max(near, min(a, b));
        far = min(far, max(a, b));
        if near > far return 0, false;
    }
    return near, true;
}

// 三角形相交（Möller–Trumbore）。double_sided=false 时只接受正面。
ray3d_hit_triangle :: (ray: Ray3D, a: Vec3, b: Vec3, c: Vec3, double_sided := true) -> (float32, bool) {
    ab := v3_sub(b, a);
    ac := v3_sub(c, a);
    p := v3_cross(ray.direction, ac);
    det := v3_dot(ab, p);
    // olib 的 `double_sided ? math.abs(det) < 1.0e-8 : det < 1.0e-8`：Jai 无 ?: 表达式，写 if/else。
    if double_sided {
        if JM.abs(det) < cast(float32) 1.0e-8 return 0, false;
    } else {
        if det < cast(float32) 1.0e-8 return 0, false;
    }
    t := v3_sub(ray.origin, a);
    u := v3_dot(t, p) / det;
    if u < 0 || u > 1 return 0, false;
    q := v3_cross(t, ab);
    v := v3_dot(ray.direction, q) / det;
    if v < 0 || u + v > 1 return 0, false;
    distance := v3_dot(ac, q) / det;
    return distance, distance >= 0;
}

// 球相交。origin 在球内时返回距离 0 命中。
ray3d_hit_sphere :: (ray: Ray3D, center: Vec3, radius: float32) -> (float32, bool) {
    if radius < 0 return 0, false;
    offset := v3_sub(ray.origin, center);
    c := v3_dot(offset, offset) - radius * radius;
    if c <= 0 return 0, true;
    b := v3_dot(offset, ray.direction);
    discriminant := b * b - c;
    if discriminant < 0 return 0, false;
    distance := -b - JM.sqrt(discriminant);
    return distance, distance >= 0;
}

// 平面相交（point/normal 定义）。射线平行于平面返回 false。
ray3d_hit_plane :: (ray: Ray3D, point: Vec3, normal: Vec3) -> (float32, bool) {
    denominator := v3_dot(ray.direction, normal);
    if JM.abs(denominator) < cast(float32) 1.0e-8 return 0, false;
    distance := v3_dot(v3_sub(point, ray.origin), normal) / denominator;
    return distance, distance >= 0;
}
//@endregion

//@region 内部

// olib 的 `return {}, false`：Jai 里显式给一个零值 Ray3D。
zero_ray3d :: () -> Ray3D {
    r: Ray3D;
    return r;
}
//@endregion
