// world:frustum3d —— 视锥（对位 DragonLib World.Frustum3D）。
//
// 6 个归一化平面，xyz 为朝内法线、w 为距离项。
// 点 p 在视锥内 ⟺ 对所有平面 dot(n, p) + w >= 0。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   | olib (Odin)                        | JaiLib (Jai)                                    |
//   | foster.Vec3                        | Math.Vector3（.x/.y/.z，或 .component 数组视图） |
//   | Vec4 :: [4]f32                     | Vec4 :: [4] float32（定义在 matrix4.jai）        |
//   | `plane[0..3]`                      | 同形，[4] float32 索引                           |
//   | math.sqrt / math.abs               | sqrt / abs                                      |
//   | `cond ? max[i] : min[i]`           | if / else 语句（Jai 无 ?: 表达式）               |
//   | @(private) plane_distance / ...    | 去掉标注，内部过程加 frustum_ 前缀避免聚合后重名 |
#import "Basic";
#import "Math";

//@region 提取 —— 从 ViewProjection 得 6 平面

Frustum3D :: struct {
    left, right, bottom, top, near, far: Vec4;
}

// Gribb-Hartmann 提取：行向量约定（v*M）下平面来自矩阵列的组合；
// 深度范围 [0,1]（D3D/Vulkan/Metal，SDL GPU 全系），近平面即 c2。
frustum_from_view_projection :: (m: Matrix4) -> Frustum3D {
    return Frustum3D.{
        left = frustum_normalize_plane(frustum_vec4_add(m.c3, m.c0)),
        right = frustum_normalize_plane(frustum_vec4_sub(m.c3, m.c0)),
        bottom = frustum_normalize_plane(frustum_vec4_add(m.c3, m.c1)),
        top = frustum_normalize_plane(frustum_vec4_sub(m.c3, m.c1)),
        near = frustum_normalize_plane(m.c2),
        far = frustum_normalize_plane(frustum_vec4_sub(m.c3, m.c2)),
    };
}
//@endregion

//@region 相交测试 —— 点 / AABB

frustum_contains_point :: (f: Frustum3D, p: Vector3) -> bool {
    return frustum_plane_distance(f.left, p) >= 0 &&
           frustum_plane_distance(f.right, p) >= 0 &&
           frustum_plane_distance(f.bottom, p) >= 0 &&
           frustum_plane_distance(f.top, p) >= 0 &&
           frustum_plane_distance(f.near, p) >= 0 &&
           frustum_plane_distance(f.far, p) >= 0;
}

// AABB 相交测试（保守正确）：逐平面取法线方向上的正顶点，正顶点落在平面
// 外侧才判整体不可见；跨平面边界的盒子一律算可见。
frustum_intersects_aabb :: (f: Frustum3D, min: Vector3, max: Vector3) -> bool {
    return frustum_test_plane(f.left, min, max) &&
           frustum_test_plane(f.right, min, max) &&
           frustum_test_plane(f.bottom, min, max) &&
           frustum_test_plane(f.top, min, max) &&
           frustum_test_plane(f.near, min, max) &&
           frustum_test_plane(f.far, min, max);
}
//@endregion

//@region 内部

// olib 的 @(private) plane_distance。
frustum_plane_distance :: (plane: Vec4, p: Vector3) -> float32 {
    return plane[0] * p.x + plane[1] * p.y + plane[2] * p.z + plane[3];
}

frustum_test_plane :: (plane: Vec4, min: Vector3, max: Vector3) -> bool {
    // olib 的 `plane[0] >= 0 ? max[0] : min[0]`，Jai 写 if/else。
    px := min.x;
    if plane[0] >= 0 px = max.x;
    py := min.y;
    if plane[1] >= 0 py = max.y;
    pz := min.z;
    if plane[2] >= 0 pz = max.z;
    return plane[0] * px + plane[1] * py + plane[2] * pz + plane[3] >= 0;
}

frustum_normalize_plane :: (plane: Vec4) -> Vec4 {
    length := JM.sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
    if length <= cast(float32) 1.0e-8 return plane;
    return .[plane[0] / length, plane[1] / length, plane[2] / length, plane[3] / length];
}

// olib 的 @(private) vec4_add / vec4_sub：Jai 没有数组算术，逐分量写。
frustum_vec4_add :: (a: Vec4, b: Vec4) -> Vec4 {
    return .[a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3]];
}

frustum_vec4_sub :: (a: Vec4, b: Vec4) -> Vec4 {
    return .[a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3]];
}
//@endregion
