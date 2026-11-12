// shader_lab:shapes —— 程序化几何：示例没有模型资源，直接在代码里生成 dasset primitive，
// 再走与真实模型相同的 r3d.mesh_upload 路径。三角形从外侧看为 CCW（与 dasset 约定一致）。
// 一比一移植自 olib kit/tools/shader_lab/shapes.odin。
//
// Jai 侧差异：
//   | olib (Odin)                                  | JaiLib (Jai)                                        |
//   | -------------------------------------------- | --------------------------------------------------- |
//   | `[3]f32` 的 `n + u*c[0] + v*c[1]`             | sl_v3_add / sl_v3_scale（Jai 的数组没有算术）          |
//   | `make([]T, n)`                                | array_resize 出计数（动态数组 [..] T）                  |
//   | `copy(p.indices[i:], []u32{...})`             | 逐个下标赋值                                          |
//   | `for ring in 0..=rings`                       | for ring: 0..rings（a..b 即闭区间）                    |
//   | `p^ = {}`                                     | p.* = DA.Dasset_Primitive.{}                        |
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）。

//@region 三维数组小工具（dasset 顶点是 [3]f32，没有跨模块运算符）

sl_v3 :: (x: float32, y: float32, z: float32) -> [3] float32 {
    return .[x, y, z];
}

sl_v3_add :: (a: [3] float32, b: [3] float32) -> [3] float32 {
    return .[a[0] + b[0], a[1] + b[1], a[2] + b[2]];
}

sl_v3_scale :: (a: [3] float32, s: float32) -> [3] float32 {
    return .[a[0] * s, a[1] * s, a[2] * s];
}
//@endregion

//@region 立方体 / 球体

// 中心在原点、边长 size 的立方体：每面 4 个顶点（法线不共享）。
make_cube :: (size: float32, material: DA.Dasset_Material) -> DA.Dasset_Primitive {
    h := size * 0.5;
    // 每面：法线 n 与面内两轴 u、v（u × v = n，保证外侧看 CCW）
    faces: [6][3][3] float32;
    faces[0] = .[ .[1, 0, 0],  .[0, 0, -1], .[0, 1, 0] ];
    faces[1] = .[ .[-1, 0, 0], .[0, 0, 1],  .[0, 1, 0] ];
    faces[2] = .[ .[0, 1, 0],  .[1, 0, 0],  .[0, 0, -1] ];
    faces[3] = .[ .[0, -1, 0], .[1, 0, 0],  .[0, 0, 1] ];
    faces[4] = .[ .[0, 0, 1],  .[1, 0, 0],  .[0, 1, 0] ];
    faces[5] = .[ .[0, 0, -1], .[-1, 0, 0], .[0, 1, 0] ];
    corners: [4][2] float32;
    corners[0] = .[-1, -1];
    corners[1] = .[1, -1];
    corners[2] = .[1, 1];
    corners[3] = .[-1, 1];

    p: DA.Dasset_Primitive;
    array_resize(*p.vertices, 24);
    array_resize(*p.indices, 36);
    p.skin_index = -1;
    p.material = material;
    p.bounds = DA.Dasset_Bounds.{ min = .[-h, -h, -h], max = .[h, h, h] };

    for f: 0..5 {
        n := faces[f][0];
        u := faces[f][1];
        v := faces[f][2];
        for i: 0..3 {
            c := corners[i];
            pos := sl_v3_scale(sl_v3_add(n, sl_v3_add(sl_v3_scale(u, c[0]), sl_v3_scale(v, c[1]))), h);
            p.vertices[f * 4 + i] = DA.Dasset_Vertex.{
                position = pos,
                normal   = n,
                uv       = .[ (c[0] + 1) * 0.5, (1 - c[1]) * 0.5 ],
                tangent  = .[ u[0], u[1], u[2], 1 ],
            };
        }
        base := f * 4;
        idx := f * 6;
        p.indices[idx + 0] = cast(u32) (base + 0);
        p.indices[idx + 1] = cast(u32) (base + 1);
        p.indices[idx + 2] = cast(u32) (base + 2);
        p.indices[idx + 3] = cast(u32) (base + 0);
        p.indices[idx + 4] = cast(u32) (base + 2);
        p.indices[idx + 5] = cast(u32) (base + 3);
    }
    return p;
}

// 中心在原点、半径 radius 的经纬球：rings 条纬线带 × segments 条经线。
make_sphere :: (radius: float32, rings: int, segments: int, material: DA.Dasset_Material) -> DA.Dasset_Primitive {
    p: DA.Dasset_Primitive;
    array_resize(*p.vertices, (rings + 1) * (segments + 1));
    array_resize(*p.indices, rings * segments * 6);
    p.skin_index = -1;
    p.material = material;
    p.bounds = DA.Dasset_Bounds.{ min = .[-radius, -radius, -radius], max = .[radius, radius, radius] };

    for ring: 0..rings {
        theta := cast(float32) ring / cast(float32) rings * JM.PI; // 0 = 北极（+Y）
        for seg: 0..segments {
            phi := cast(float32) seg / cast(float32) segments * 2 * JM.PI;
            n := sl_v3(JM.sin(theta) * JM.cos(phi), JM.cos(theta), JM.sin(theta) * JM.sin(phi));
            p.vertices[ring * (segments + 1) + seg] = DA.Dasset_Vertex.{
                position = sl_v3_scale(n, radius),
                normal   = n,
                uv       = .[ cast(float32) seg / cast(float32) segments, cast(float32) ring / cast(float32) rings ],
                tangent  = .[ -JM.sin(phi), 0, JM.cos(phi), 1 ],
            };
        }
    }
    i := 0;
    for ring: 0..rings - 1 {
        for seg: 0..segments - 1 {
            a := cast(u32) (ring * (segments + 1) + seg); // a b  （ring 向下、seg 绕 +Y 转向 -Z 侧）
            b := a + 1;                                   // d c
            d := a + cast(u32) (segments + 1);
            c := d + 1;
            p.indices[i + 0] = a;
            p.indices[i + 1] = b;
            p.indices[i + 2] = c;
            p.indices[i + 3] = a;
            p.indices[i + 4] = c;
            p.indices[i + 5] = d;
            i += 6;
        }
    }
    return p;
}
//@endregion

//@region 释放

primitive_dispose :: (p: *DA.Dasset_Primitive) {
    if p.vertices.data != null array_free(p.vertices);
    if p.indices.data != null array_free(p.indices);
    p.* = DA.Dasset_Primitive.{};
}
//@endregion
