// gizmo:wireframe —— 网格线框查看：画 meshutil.edges 给出的拓扑边，线宽按最终像素保持，
// 边界 / 属性缝 / 非流形边分色，用于检查和优化模型。与手柄共用 Renderer3D 的 Shader；
// 每份网格的边作为实例上传一次（Wireframe），每帧只写相机常量，由顶点着色器展开。
// 一比一移植自 olib kit/gizmo/wireframe.odin。
//
// Jai 侧差异（逐条对应 olib 的写法；边数、颜色、截断与像素宽度不变）：
//   | olib (Odin)                                      | JaiLib (Jai)                                          |
//   | ------------------------------------------------ | ----------------------------------------------------- |
//   | `colors: [meshutil.Edge_Kind]foster.Color`        | `colors: [WIREFRAME_EDGE_KINDS]F.Color` + cast(int)   |
//   |                                                  | 索引（Jai 的数组长度必须是整数常量，枚举不能当长度）      |
//   | `for color, kind in style.colors`                | for kind 索引 + 局部 color                             |
//   | `#load("shaders/Compiled/Wireframe3D.…")`        | shaders_compiled.jai 的 u8 数组常量                     |
//   | `foster.MeshInitInstanced(&m, dev, c, e, …)`     | F.mesh_create_instanced(dev, c, e, .THIRTY_TWO, name) |
//   | `foster.MeshSetVertices / SetInstances`          | F.mesh_set_vertices / F.mesh_set_instances            |
//   | `foster.MeshDispose(&w.mesh)`                    | gizmo_mesh_release（jfoster 的缓冲结构体要自己 free）     |
//   | `make([dynamic]T, 0, n)` + `defer delete(x)`     | `[..] T` + array_reserve + 出口显式 array_free          |
//   | `positions[e.a]`（[3]f32 当 Vec3）                | gizmo_vec3_from_array(positions[...])（Jai 的 Vec3 是   |
//   |                                                  | 结构体，要显式搬）                                       |
//   | `a - b` / `a * s` / `a / s`                      | gizmo_v3_* / W.v3_sub                                  |
//   | `x ? a : b`                                      | 先取默认值再 if 改写（Jai 没有三元）                      |
//   | `return`（具名返回值）                             | 同形（Jai 支持具名返回 + 裸 return）                     |
//   | `@(private)`                                     | 去掉标注，内部过程加 gizmo_ 前缀                            |
// 导入（#import）由 module.jai 提供。

//@region 样式

// olib 是 `[meshutil.Edge_Kind]foster.Color`：Jai 的数组长度必须是整数常量，这里用 4 个槽位，
// 下标写 cast(int) kind（Edge_Kind 的序号就是槽位）。
WIREFRAME_EDGE_KINDS :: 4;

Wireframe_Style :: struct {
    line_width: float32; // 最终输出像素，再乘 UI scale
    depth_offset: float32; // 沿视线朝相机推近的像素量，避免线与模型表面深度冲突
    hidden_alpha: float32; // 被场景深度遮挡的线的透明度：0 不画，1 即透视全部线
    colors: [WIREFRAME_EDGE_KINDS] F.Color; // A=0 的种类直接跳过，可只看边界或缝
}

DEFAULT_WIREFRAME_STYLE :: Wireframe_Style.{
    line_width = 1.25, depth_offset = 3, hidden_alpha = 0.15,
    colors = .[
        F.Color.{ 205, 214, 222, 200 }, // .Interior     普通共享边
        F.Color.{ 108, 167, 255, 255 }, // .Seam         UV/法线属性缝
        F.Color.{ 255, 180, 97, 255 }, // .Border        只属于一个三角形
        F.Color.{ 255, 80, 96, 255 }, // .Non_Manifold  三个以上三角形共用
    ],
};
//@endregion

//@region 线框网格

// CPU 参考实现：与 Wireframe3D.hlsl 同一算法，供无窗口测试或自定义渲染器使用；
// 生成世界空间线框三角列表（每条边 6 个顶点，朝向相机的细四边形），不读取 GPU。
// positions 与 edges 为模型局部数据，transform 为模型世界矩阵；越界边、近裁面后的部分被丢弃。
// 相机 viewport_size 必须与 viewport 宽高一致。
wireframe_mesh :: (vertices: *[..] Vertex3D, camera: *W.Camera3D, positions: [][3] float32,
                   edges: [] MSH.Edge, transform: W.Matrix4, viewport: F.Rect,
                   scale: float32 = 1, style := DEFAULT_WIREFRAME_STYLE) {
    gizmo_array_clear(vertices);
    if camera == null || viewport.w <= 0 || viewport.h <= 0 return;
    if cast(float32) camera.viewport_size.x != viewport.w ||
       cast(float32) camera.viewport_size.y != viewport.h {
        return;
    }
    if !gizmo_finite(scale) || scale <= 0 || !gizmo_finite(style.line_width) || style.line_width <= 0 return;
    forward := W.camera3d_forward(camera);
    eye := camera.position;
    // 深度为 1 处一个像素对应的世界长度。
    pixel := 2 * JM.tan(camera.field_of_view * 0.5) / viewport.h;
    near := max(camera.near_clip, 0.0001) * 1.01;
    half_width := style.line_width * scale * 0.5;
    offset: float32 = 0;
    if gizmo_finite(style.depth_offset) offset = max(style.depth_offset, cast(float32) 0) * scale;
    for e: edges {
        color := style.colors[cast(int) e.kind];
        if color.a == 0 || cast(int) e.a >= positions.count || cast(int) e.b >= positions.count continue;
        a, a_ok := W.matrix4_transform_point(transform, gizmo_vec3_from_array(positions[cast(int) e.a]));
        b, b_ok := W.matrix4_transform_point(transform, gizmo_vec3_from_array(positions[cast(int) e.b]));
        if !a_ok || !b_ok continue;
        depth_a := W.v3_dot(W.v3_sub(a, eye), forward);
        depth_b := W.v3_dot(W.v3_sub(b, eye), forward);
        if !gizmo_finite(depth_a) || !gizmo_finite(depth_b) || (depth_a < near && depth_b < near) continue;
        if depth_a < near {
            a = gizmo_v3_add(a, gizmo_v3_scale(W.v3_sub(b, a), (near - depth_a) / (depth_b - depth_a)));
            depth_a = near;
        } else if depth_b < near {
            b = gizmo_v3_add(b, gizmo_v3_scale(W.v3_sub(a, b), (near - depth_b) / (depth_a - depth_b)));
            depth_b = near;
        }
        // 沿视线推近不改变屏幕位置，只让线稳定通过模型自身的深度测试。
        a = gizmo_toward(a, eye, depth_a * pixel * offset);
        b = gizmo_toward(b, eye, depth_b * pixel * offset);
        side := W.v3_cross(W.v3_sub(b, a), W.v3_sub(eye, gizmo_v3_scale(gizmo_v3_add(a, b), 0.5)));
        side_length := JM.sqrt(W.v3_dot(side, side));
        if !(side_length > 0) continue;
        side = gizmo_v3_div(side, side_length);
        wa := gizmo_v3_scale(side, depth_a * pixel * half_width);
        wb := gizmo_v3_scale(side, depth_b * pixel * half_width);
        c: [4] float32 = .[
            cast(float32) color.r / 255,
            cast(float32) color.g / 255,
            cast(float32) color.b / 255,
            cast(float32) color.a / 255,
        ];
        a_low := W.v3_sub(a, wa);
        b_low := W.v3_sub(b, wb);
        b_high := gizmo_v3_add(b, wb);
        a_high := gizmo_v3_add(a, wa);
        array_add(vertices,
                  Vertex3D.{ position = a_low, color = c },
                  Vertex3D.{ position = b_low, color = c },
                  Vertex3D.{ position = b_high, color = c },
                  Vertex3D.{ position = a_low, color = c },
                  Vertex3D.{ position = b_high, color = c },
                  Vertex3D.{ position = a_high, color = c });
    }
}

// olib 的 @(private) toward：沿视线朝相机推近，最多推到与相机距离的一半。
gizmo_toward :: (p: W.Vec3, eye: W.Vec3, distance: float32) -> W.Vec3 {
    d := W.v3_sub(eye, p);
    length := JM.sqrt(W.v3_dot(d, d));
    if !(length > 0) return p;
    return gizmo_v3_add(p, gizmo_v3_scale(d, min(distance, length * 0.5) / length));
}
//@endregion

//@region GPU 线框

// 一份网格的 GPU 线框，调用方持有：边端点和种类作为实例上传一次，网格变化后 destroy 再 init。
// 零值可安全 destroy；GraphicsDevice 必须比它活得久。
Wireframe :: struct {
    mesh: *F.Mesh;
    edges: int; // 实际上传的边数（已剔除越界和非有限端点）
    ready: bool;
}

// 实例属性：TEXCOORD1..3，见 Wireframe3D.hlsl（a/b 各 Float3，kind 为 Edge_Kind 序号）。
Wireframe_Edge :: struct {
    a, b: [3] float32;
    kind: float32; // meshutil.Edge_Kind 序号
}

WIREFRAME_EDGE_STRIDE :: 28;
#assert(size_of(Wireframe_Edge) == WIREFRAME_EDGE_STRIDE, "线框实例必须是 28 字节（两个 Float3 + Float）");

WIREFRAME_UNIFORM_SIZE :: 240;

// 每条边 6 个角点：x 沿边 0/1，y 侧向 ±1；顺序同 wireframe_mesh 的两个三角形。
// （Jai 的 `::` 常量不能直接由数组字面量初始化，数组常量要写成 `名字 : 类型 : 字面量`。）
WIREFRAME_CORNERS: [6][2] float32 : .[
    .[0, -1], .[1, -1], .[1, 1], .[0, -1], .[1, 1], .[0, 1],
];

WIREFRAME_CORNER_STRIDE :: 8;

// 剔除越界索引和非有限端点后的实例数据；不读取 GPU。
wireframe_edges :: (out: *[..] Wireframe_Edge, positions: [][3] float32, edges: [] MSH.Edge) {
    gizmo_array_clear(out);
    array_reserve(out, edges.count);
    for e: edges {
        if cast(int) e.a >= positions.count || cast(int) e.b >= positions.count continue;
        a := positions[cast(int) e.a];
        b := positions[cast(int) e.b];
        if !gizmo_finite(a[0]) || !gizmo_finite(a[1]) || !gizmo_finite(a[2]) ||
           !gizmo_finite(b[0]) || !gizmo_finite(b[1]) || !gizmo_finite(b[2]) {
            continue;
        }
        array_add(out, Wireframe_Edge.{ a = a, b = b, kind = cast(float32) cast(int) e.kind });
    }
}

gizmo_wireframe_corner_format :: () -> F.Vertex_Format {
    elements: [1] F.Vertex_Format_Element = .[F.Vertex_Format_Element.{ 0, .FLOAT2, false }];
    return F.vertex_format_make(array_view(elements, 0, 1), WIREFRAME_CORNER_STRIDE);
}

gizmo_wireframe_edge_format :: () -> F.Vertex_Format {
    elements: [3] F.Vertex_Format_Element = .[
        F.Vertex_Format_Element.{ 1, .FLOAT3, false },
        F.Vertex_Format_Element.{ 2, .FLOAT3, false },
        F.Vertex_Format_Element.{ 3, .FLOAT, false },
    ];
    return F.vertex_format_make(array_view(elements, 0, 3), WIREFRAME_EDGE_STRIDE);
}

// 没有可画的边或设备为空时返回 false，w 保持零值。
wireframe_init :: (w: *Wireframe, device: *F.Graphics_Device, positions: [][3] float32,
                   edges: [] MSH.Edge) -> bool {
    wireframe_destroy(w);
    if device == null return false;
    instances: [..] Wireframe_Edge;
    array_reserve(*instances, edges.count);
    wireframe_edges(*instances, positions, edges);
    if instances.count == 0 {
        if instances.data != null array_free(instances);
        return false;
    }
    w.mesh = F.mesh_create_instanced(device, gizmo_wireframe_corner_format(),
                                     gizmo_wireframe_edge_format(), .THIRTY_TWO, "Wireframe3D mesh");
    corners := WIREFRAME_CORNERS;
    F.mesh_set_vertices(w.mesh, corners);
    F.mesh_set_instances(w.mesh, instances);
    w.edges = instances.count;
    w.ready = true;
    if instances.data != null array_free(instances);
    return true;
}

wireframe_destroy :: (w: *Wireframe) {
    if w.ready gizmo_mesh_release(w.mesh);
    w.* = Wireframe.{};
}

// 顶点常量（布局见 Wireframe3D.hlsl 的 WireBlock）。相机视口与 viewport 不一致、线宽或缩放无效时返回 false。
wireframe_uniforms :: (camera: *W.Camera3D, transform: W.Matrix4, viewport: F.Rect,
                       scale: float32 = 1, style := DEFAULT_WIREFRAME_STYLE)
                      -> (block: [WIREFRAME_UNIFORM_SIZE] u8, ok: bool) {
    if camera == null || viewport.w <= 0 || viewport.h <= 0 return;
    if cast(float32) camera.viewport_size.x != viewport.w ||
       cast(float32) camera.viewport_size.y != viewport.h {
        return;
    }
    if !gizmo_finite(scale) || scale <= 0 || !gizmo_finite(style.line_width) || style.line_width <= 0 return;
    forward := W.camera3d_forward(camera);
    eye := camera.position;
    pixel := 2 * JM.tan(camera.field_of_view * 0.5) / viewport.h;
    near := max(camera.near_clip, 0.0001) * 1.01;
    offset: float32 = 0;
    if gizmo_finite(style.depth_offset) offset = max(style.depth_offset, cast(float32) 0) * scale;
    mat.std140_write_matrix(block, 0, W.camera3d_view_projection(camera));
    mat.std140_write_matrix(block, 64, transform);
    mat.std140_write_vec4(block, 128, .[eye.x, eye.y, eye.z, near]);
    mat.std140_write_vec4(block, 144, .[forward.x, forward.y, forward.z, pixel]);
    mat.std140_write_vec4(block, 160, .[style.line_width * scale * 0.5, offset, 0, 0]);
    for kind: 0..WIREFRAME_EDGE_KINDS - 1 {
        color := style.colors[kind];
        mat.std140_write_vec4(block, 176 + kind * 16, .[
            cast(float32) color.r / 255,
            cast(float32) color.g / 255,
            cast(float32) color.b / 255,
            cast(float32) color.a / 255,
        ]);
    }
    return block, true;
}
//@endregion

//@region 绘制

// 目标深度规则同 transform_draw：先画模型（写深度）再画线框，背面和被挡住的边按 hidden_alpha 淡化；
// 不画模型时深度为清除值，全部边可见。每帧只上传 240 字节常量，边数只影响 GPU 顶点数。
wireframe_draw :: (r: *Renderer3D, target: F.Drawable_Target, camera: *W.Camera3D,
                   w: *Wireframe, transform: W.Matrix4, viewport: F.Rect,
                   scale: float32 = 1, style := DEFAULT_WIREFRAME_STYLE) {
    if !r.ready || w == null || !w.ready return;
    block, ok := wireframe_uniforms(camera, transform, viewport, scale, style);
    if !ok return;
    F.material_stage_set_uniform(*r.wire_material.Vertex, 0, block);
    gizmo_draw_depth_tested(r.wire_material, w.mesh, target, viewport, style.hidden_alpha);
}
//@endregion
