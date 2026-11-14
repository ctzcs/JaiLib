// rendering3d:debug_draw —— Render3D 调试线（对外 API 在“对外 API”region：line / aabb / ...）。
// 一比一移植自 olib kit/rendering/3d/debug_draw.odin。
//
// 排队 Line/Aabb/Sphere/Frustum/Axis/Grid/Skeleton 的线段，Render3D submit 时展开并绘制、clear 时清空。
// GPU 路径走"朝向相机的细四边形"：jfoster 管线固定为三角列表（无线拓扑），
// 每段线扩成两个三角形仍用 DebugLine3D 着色器（位置+颜色顶点，拓扑无关），
// 深度测试可选、始终不写深度。厚度是世界单位。
//
// Jai 侧差异（逐条对应 olib 的写法；线段条数、四边形顶点与颜色透传不变）：
//   | olib (Odin)                                    | JaiLib (Jai)                                            |
//   | ---------------------------------------------- | ------------------------------------------------------- |
//   | `[dynamic]Debug_Line_Vertex` + append          | `[..] Debug_Line_Vertex` + array_add                    |
//   | `linalg.cross / dot`、`math.sqrt`               | W.v3_cross 是 Vec3 版本，这里按 [3]f32 另写             |
//   |                                                | debug_v3_cross / debug_v3_dot / debug_v3_mul           |
//   | `side *= inv * half`（数组乘标量）               | debug_v3_mul(side, inv * half)（Jai 没有数组算术）       |
//   | `f32(math.TAU)`                                | cast(float32) JM.TAU                                    |
//   | `mat` 形参名（遮蔽了 mat 包名）                    | 形参改名为 world_matrix（Jai 里 mat 是本包的包别名）      |
//   | `foster.Mesh` / `foster.Material`（值）          | *F.Mesh / *F.Material（首次 prepare 时创建）              |
//   | `#load("…spv")`                                | shaders_compiled.jai 里的 u8 数组常量（jacket 的 #load   |
//   |                                                | 只认 .jai；字节相同，见该文件头）                         |
//   | `foster.ShaderInit(&s, dev, {…}, name)`        | F.shader_create(dev, stage, code, …, entry_point, name)  |
//   | `ShaderInit{Stage = .Vertex}`                  | F.Shader_Stage.VERTEX                                   |
//   | `ShaderInit{Code = …}`                         | 第三个位置参数 code（jfoster 的 Shader_Create_Info.Bytes）|
//   | `s.Resource != nil`                            | s != null && s.handle != 0                              |
//   | `foster.MeshSetVertexCount / SetVertices`      | F.mesh_set_vertex_count / F.mesh_set_vertices            |
//   | `foster.MaterialStageSetUniformBuffer(&s, …)`  | F.material_stage_set_uniform(*s, slot, bytes)            |
//   | `foster.DrawCommandFromMesh(&c, …)`            | F.draw_command_from_mesh(target, mesh, material)         |
//   | `command.BlendMode{.Color = …}`                | F.Blend_Mode.{ … BlendColor = F.Color_White }           |
//   | `foster.DepthCompare{.LessOrEqual}`            | .LESS_OR_EQUAL                                          |
//   | `foster.CullMode.None`                         | .NONE                                                   |
//   | `for i in 0..<8`、`for i := -n; i <= n; i += 1`  | for i: 0..7、while 循环（Jai 没有 C 风格 for）             |
//   | `switch plane { case 0: … }`                   | if / else if 链                                          |
//   | `i & int(bit) == 0`                            | 先 cast 再比（Jai 的位运算符优先级更高，写成显式比较）       |
//   | `@(private)`                                   | 去掉标注，内部过程加 debug_ 前缀                            |
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）。

//@region 类型

// 调试线顶点：Float3 位置 + Float4 颜色（28B，与 DebugLine3D 着色器一致）。
Debug_Line_Vertex :: struct {
    position: [3] float32;
    color: [4] float32;
}

DEBUG_LINE_VERTEX_STRIDE :: 28;
#assert(size_of(Debug_Line_Vertex) == DEBUG_LINE_VERTEX_STRIDE, "调试线顶点必须是 28 字节（位置 12 + 颜色 16）");

Debug_Draw_3D :: struct {
    depth_test_enabled: bool; // 遮挡关系（默认开）；始终不写深度
    thickness: float32;       // 线宽（世界单位）

    vertices: [..] Debug_Line_Vertex; // 每线段 2 个端点
    indices: [..] u32;
    expanded: [..] Debug_Line_Vertex; // 跨视图复用展开工作区

    mesh: *F.Mesh;
    shaders: Debug_Line_Shaders;
    material: *F.Material;
    has_gpu: bool;
}

DEBUG_DRAW_DEFAULT_THICKNESS :: 0.02;

debug_draw_prepare :: (d: *Debug_Draw_3D, device: *F.Graphics_Device) -> bool {
    if d.has_gpu return true;
    if device == null return false;
    if !debug_line_shaders_init(*d.shaders, device) return false;

    format := debug_line_format();
    d.mesh = F.mesh_create(device, format, .THIRTY_TWO, "Debug lines 3d");
    d.material = F.material_create(d.shaders.vertex, d.shaders.fragment);
    d.has_gpu = true;
    return true;
}

debug_draw_dispose :: (d: *Debug_Draw_3D) {
    if d.has_gpu {
        if d.material != null F.material_destroy(d.material);
        if d.shaders.vertex != null {
            F.shader_dispose(d.shaders.vertex);
            free(d.shaders.vertex);
        }
        if d.shaders.fragment != null {
            F.shader_dispose(d.shaders.fragment);
            free(d.shaders.fragment);
        }
        mesh_dispose(d.mesh);
        if d.mesh != null free(d.mesh);
    }
    if d.vertices.data != null array_free(d.vertices);
    if d.expanded.data != null array_free(d.expanded);
    if d.indices.data != null array_free(d.indices);
    d.* = Debug_Draw_3D.{};
}

debug_draw_line_count :: (d: *Debug_Draw_3D) -> int {
    return d.vertices.count / 2;
}

debug_draw_clear :: (d: *Debug_Draw_3D) {
    if d.vertices.data != null d.vertices.count = 0; // olib: builtin.clear(&d.vertices)
}
//@endregion

//@region 几何生成

debug_draw_line :: (d: *Debug_Draw_3D, a: [3] float32, b: [3] float32, color: [4] float32) {
    array_add(*d.vertices, Debug_Line_Vertex.{ position = a, color = color });
    array_add(*d.vertices, Debug_Line_Vertex.{ position = b, color = color });
}

debug_draw_aabb :: (d: *Debug_Draw_3D, bounds: DA.Dasset_Bounds, color: [4] float32) {
    corners := aabb_corners(bounds);
    debug_draw_box_edges(d, corners, color);
}

debug_draw_sphere :: (d: *Debug_Draw_3D, center: [3] float32, radius: float32, color: [4] float32,
                      segments := 32) {
    if radius < 0 || segments < 3 return;
    tau := cast(float32) JM.TAU;
    for plane: 0..2 {
        for i: 0..segments - 1 {
            a := cast(float32) i * tau / cast(float32) segments;
            b := cast(float32) (i + 1) * tau / cast(float32) segments;
            pa := sphere_point(plane, a);
            pb := sphere_point(plane, b);
            debug_draw_line(
                d,
                .[center[0] + pa[0] * radius, center[1] + pa[1] * radius, center[2] + pa[2] * radius],
                .[center[0] + pb[0] * radius, center[1] + pb[1] * radius, center[2] + pb[2] * radius],
                color,
            );
        }
    }
}

// 视锥线框：由 ViewProjection 逆变换回世界空间的 8 角点。
debug_draw_frustum :: (d: *Debug_Draw_3D, view_projection: W.Matrix4, color: [4] float32) {
    inverse, ok := W.matrix4_inverse(view_projection);
    if !ok return;

    corners: [8] [3] float32;
    for i: 0..7 {
        x := -1.0;
        if (i & 1) != 0 x = 1.0;
        y := -1.0;
        if (i & 2) != 0 y = 1.0;
        z := 0.0;
        if (i & 4) != 0 z = 1.0;
        h := W.matrix4_transform_vec4(inverse, W.vec4(cast(float32) x, cast(float32) y, cast(float32) z, 1));
        if JM.abs(h[3]) < 1.0e-8 return;
        corners[i] = .[h[0] / h[3], h[1] / h[3], h[2] / h[3]];
    }
    debug_draw_box_edges(d, corners, color);
}

// 坐标轴：X 红 / Y 绿 / Z 蓝（按 world 变换）。
debug_draw_axis :: (d: *Debug_Draw_3D, world_matrix: W.Matrix4, length: float32 = 1) {
    origin_h := W.matrix4_transform_vec4(world_matrix, W.vec4(0, 0, 0, 1));
    origin: [3] float32 = .[origin_h[0], origin_h[1], origin_h[2]];
    for axis: 0..2 {
        dir: [3] float32 = .[0, 0, 0];
        dir[axis] = 1;
        tip: [3] float32 = .[
            origin[0] + dir[0] * length,
            origin[1] + dir[1] * length,
            origin[2] + dir[2] * length,
        ];
        color: [4] float32 = .[0.2, 0.4, 1, 1];
        if axis == 0 {
            color = .[1, 0.2, 0.2, 1];
        } else if axis == 1 {
            color = .[0.2, 1, 0.2, 1];
        }
        debug_draw_line(d, origin, tip, color);
    }
}

// XZ 平面网格。
debug_draw_grid :: (d: *Debug_Draw_3D, half_lines: int, spacing: float32, color: [4] float32) {
    if half_lines < 0 || spacing <= 0 return;
    extent := cast(float32) half_lines * spacing;
    i := -half_lines;
    while i <= half_lines {
        t := cast(float32) i * spacing;
        debug_draw_line(d, .[t, 0, -extent], .[t, 0, extent], color);
        debug_draw_line(d, .[-extent, 0, t], .[extent, 0, t], color);
        i += 1;
    }
}

// 骨架线：is_palette=true 时矩阵是 palette（需经 inverse IBM 重建 global）。
// olib 的形参名是 skeleton；Jai 不允许形参遮蔽同作用域的过程名，这里改名 rig（顺序/类型/语义不变）。
debug_draw_skeleton :: (d: *Debug_Draw_3D, rig: *DA.Dasset_Skeleton, matrices: [] W.Matrix4,
                        world_matrix: W.Matrix4, color: [4] float32, is_palette := true) {
    count := min(rig.joints.count, matrices.count);
    positions := lod_alloc([3] float32, count);
    defer {
        if positions.data != null free(positions.data);
    }

    for i: 0..count - 1 {
        global := matrices[i];
        if is_palette {
            bind, ok := W.matrix4_inverse(W.matrix4_from_row_major(rig.joints[i].inverse_bind_matrix));
            if ok {
                global = W.matrix4_multiply(bind, global);
            }
        }
        h := W.matrix4_transform_vec4(W.matrix4_multiply(global, world_matrix), W.vec4(0, 0, 0, 1));
        if JM.abs(h[3]) < 1.0e-8 {
            positions[i] = .[0, 0, 0];
            continue;
        }
        positions[i] = .[h[0] / h[3], h[1] / h[3], h[2] / h[3]];
    }
    for i: 0..count - 1 {
        parent := rig.joints[i].parent_index;
        if parent >= 0 && cast(int) parent < count {
            debug_draw_line(d, positions[cast(int) parent], positions[i], color);
        }
    }
}
//@endregion

//@region 顶点展开 —— 线段 -> 朝向相机的四边形（两个三角形）

// olib 的 linalg.cross / linalg.dot / 数组乘标量：位置是 [3]f32，与 W.v3_*（Vec3）不同形，
// 这里按 [3]f32 写同一套运算（公式逐项相同）。
debug_v3_cross :: (a: [3] float32, b: [3] float32) -> [3] float32 {
    return .[
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ];
}

debug_v3_dot :: (a: [3] float32, b: [3] float32) -> float32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

debug_v3_sub :: (a: [3] float32, b: [3] float32) -> [3] float32 {
    return .[a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

debug_v3_mul :: (a: [3] float32, s: float32) -> [3] float32 {
    return .[a[0] * s, a[1] * s, a[2] * s];
}

debug_v3_mid :: (a: [3] float32, b: [3] float32) -> [3] float32 {
    return .[(a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5];
}

debug_v3_is_zero :: (a: [3] float32) -> bool {
    return a[0] == 0 && a[1] == 0 && a[2] == 0;
}

// 把已排队的线段展开为四边形顶点（不改变 d.vertices；输出追加到 out）。
// 每段 4 顶点 6 索引的扇形展开；侧面向量 = normalize(cross(线方向, 视线)) * 半厚。
debug_draw_expand :: (d: *Debug_Draw_3D, camera_position: [3] float32,
                      out: *[..] Debug_Line_Vertex, direction: [3] float32 = .[0, 0, 0]) {
    half := d.thickness * 0.5;
    for i: 0..d.vertices.count / 2 - 1 {
        a := d.vertices[i * 2];
        b := d.vertices[i * 2 + 1];

        // 线方向与视线叉积得侧面方向
        dir := debug_v3_sub(b.position, a.position);
        mid := debug_v3_mid(a.position, b.position);
        to_cam := debug_v3_sub(camera_position, mid);
        if !debug_v3_is_zero(direction) to_cam = direction; // 正交视图使用固定朝向
        side := debug_v3_cross(dir, to_cam);
        length2 := debug_v3_dot(side, side);
        if length2 > 1.0e-12 {
            inv := 1.0 / JM.sqrt(length2);
            side = debug_v3_mul(side, inv * half);
        } else {
            // 线与视线平行：任选一个正交向量
            side = .[half, 0, 0];
        }

        a0 := debug_v3_sub(a.position, side);
        a1 := .[a.position[0] + side[0], a.position[1] + side[1], a.position[2] + side[2]];
        b0 := debug_v3_sub(b.position, side);
        b1 := .[b.position[0] + side[0], b.position[1] + side[1], b.position[2] + side[2]];

        // 两个三角形：a0 b0 b1 / a0 b1 a1
        array_add(*out.*, Debug_Line_Vertex.{ position = a0, color = a.color });
        array_add(*out.*, Debug_Line_Vertex.{ position = b0, color = b.color });
        array_add(*out.*, Debug_Line_Vertex.{ position = b1, color = b.color });
        array_add(*out.*, Debug_Line_Vertex.{ position = a0, color = a.color });
        array_add(*out.*, Debug_Line_Vertex.{ position = b1, color = b.color });
        array_add(*out.*, Debug_Line_Vertex.{ position = a1, color = a.color });
    }
}
//@endregion

//@region GPU 渲染

// 绘制已排队的线段，不清空（Render3D 保留到 clear）。
debug_draw_submit :: (d: *Debug_Draw_3D, view: View) {
    if !d.has_gpu || d.vertices.count == 0 return;
    if d.expanded.data != null d.expanded.count = 0; // olib: builtin.clear(&d.expanded)
    inverse, ok := W.matrix4_inverse(view.view_matrix);
    if !ok inverse = W.MATRIX4_IDENTITY;
    position: [3] float32 = .[inverse.c0[3], inverse.c1[3], inverse.c2[3]];
    projection := W.matrix4_multiply(inverse, view.view_projection);
    direction: [3] float32 = .[0, 0, 0];
    if JM.abs(projection.c3[3]) > 1.0e-8 {
        v := W.matrix4_transform_vector(inverse, W.Vec3.{ 0, 0, 1 });
        direction = .[v.x, v.y, v.z];
    }
    debug_draw_expand(d, position, *d.expanded, direction);
    if d.expanded.count == 0 return;

    F.mesh_set_vertex_count(d.mesh, cast(s32) d.expanded.count);
    F.mesh_set_vertices(d.mesh, d.expanded);
    array_resize(*d.indices, d.expanded.count);
    for *index, i: d.indices index.* = cast(u32) i;
    F.mesh_set_indices(d.mesh, d.indices);

    vp_buf: [64] u8;
    mat.std140_write_matrix(vp_buf, 0, view.view_projection);
    F.material_stage_set_uniform(*d.material.Vertex, 0, vp_buf);

    command := F.draw_command_from_mesh(view.target, d.mesh, d.material);
    command.DepthTestEnabled = d.depth_test_enabled;
    command.DepthWriteEnabled = false;
    command.DepthCompare = .LESS_OR_EQUAL;
    command.CullMode = .NONE;
    command.BlendMode = F.Blend_Mode.{
        ColorOperation = .ADD,
        ColorSource = .SRC_ALPHA,
        ColorDestination = .ONE_MINUS_SRC_ALPHA,
        AlphaOperation = .ADD,
        AlphaSource = .ONE,
        AlphaDestination = .ONE_MINUS_SRC_ALPHA,
        Mask = .RGBA, // 零值 .NONE 会关掉颜色写入
        BlendColor = F.Color_White,
    };
    F.graphics_device_draw(d.mesh.device, command);
}
//@endregion

//@region 内部

// 调试线顶点格式（Float3 + Float4，28B）。
debug_line_format :: () -> F.Vertex_Format {
    elements: [2] F.Vertex_Format_Element = .[
        F.Vertex_Format_Element.{ 0, .FLOAT3, false },
        F.Vertex_Format_Element.{ 1, .FLOAT4, false },
    ];
    return F.vertex_format_make(array_view(elements, 0, 2), DEBUG_LINE_VERTEX_STRIDE);
}

aabb_corners :: (bounds: DA.Dasset_Bounds) -> [8] [3] float32 {
    corners: [8] [3] float32;
    for i: 0..7 {
        // olib: (i & 1) == 0 ? bounds.min[0] : bounds.max[0]（Jai 没有三元，先声明再分支）
        x := bounds.min[0];
        if (i & 1) != 0 x = bounds.max[0];
        y := bounds.min[1];
        if (i & 2) != 0 y = bounds.max[1];
        z := bounds.min[2];
        if (i & 4) != 0 z = bounds.max[2];
        corners[i] = .[x, y, z];
    }
    return corners;
}

// 8 角点的 12 条棱：bit 位相邻连接。
debug_draw_box_edges :: (d: *Debug_Draw_3D, corners: [8] [3] float32, color: [4] float32) {
    bits: [3] int = .[1, 2, 4];
    for i: 0..7 {
        for bit: bits {
            if (i & bit) == 0 {
                debug_draw_line(d, corners[i], corners[i | bit], color);
            }
        }
    }
}

sphere_point :: (plane: int, angle: float32) -> [3] float32 {
    if plane == 0 return .[JM.cos(angle), JM.sin(angle), 0];
    if plane == 1 return .[0, JM.cos(angle), JM.sin(angle)];
    return .[JM.sin(angle), 0, JM.cos(angle)];
}
//@endregion

//@region 着色器 —— DebugLine3D

// DebugLine3D（调试线）：vertex 1 个 UBO（ViewProjection），fragment 无。
Debug_Line_Shaders :: struct {
    vertex: *F.Shader;
    fragment: *F.Shader;
}

debug_line_shaders_init :: (pair: *Debug_Line_Shaders, device: *F.Graphics_Device) -> bool {
    if !mat.shader_driver_supported(device.driver) return false;

    vs_code := mat.shader_pick(device.driver, mat.Shader_Binaries.{
        spv = debugline_vertex_spv,
        dxil = debugline_vertex_dxil,
        msl = debugline_vertex_msl,
    });
    fs_code := mat.shader_pick(device.driver, mat.Shader_Binaries.{
        spv = debugline_fragment_spv,
        dxil = debugline_fragment_dxil,
        msl = debugline_fragment_msl,
    });

    pair.vertex = F.shader_create(device, .VERTEX, vs_code,
                                  sampler_count = 0, uniform_buffer_count = 1,
                                  entry_point = "vertex_main", name = "DebugLine3DVertex");
    pair.fragment = F.shader_create(device, .FRAGMENT, fs_code,
                                    entry_point = "fragment_main", name = "DebugLine3DFragment");
    return pair.vertex != null && pair.vertex.handle != 0 &&
           pair.fragment != null && pair.fragment.handle != 0;
}
//@endregion

//@region 对外 API

// 调试线：submit 后保留，clear 时一起清空。
// 线宽 / 深度测试可通过 r.debug.thickness / depth_test_enabled 设置。
line :: (r: *Render3D, from: [3] float32, to: [3] float32, color: [4] float32) {
    debug_draw_line(*r.debug, from, to, color);
}

aabb :: (r: *Render3D, bounds: DA.Dasset_Bounds, color: [4] float32) {
    debug_draw_aabb(*r.debug, bounds, color);
}

sphere :: (r: *Render3D, center: [3] float32, radius: float32, color: [4] float32, segments := 32) {
    debug_draw_sphere(*r.debug, center, radius, color, segments);
}

frustum :: (r: *Render3D, view_projection: W.Matrix4, color: [4] float32) {
    debug_draw_frustum(*r.debug, view_projection, color);
}

axis :: (r: *Render3D, transform: W.Matrix4, length: float32 = 1) {
    debug_draw_axis(*r.debug, transform, length);
}

grid :: (r: *Render3D, half_lines: int, spacing: float32, color: [4] float32) {
    debug_draw_grid(*r.debug, half_lines, spacing, color);
}

// olib 的形参名是 skeleton（遮蔽过程名）；Jai 不允许，改名 rig。
skeleton :: (r: *Render3D, rig: *DA.Dasset_Skeleton, matrices: [] W.Matrix4,
             transform: W.Matrix4, color: [4] float32, is_palette := true) {
    debug_draw_skeleton(*r.debug, rig, matrices, transform, color, is_palette);
}
//@endregion
