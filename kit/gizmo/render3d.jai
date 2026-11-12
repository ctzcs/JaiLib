// gizmo:render3d —— 三维手柄的世界空间网格生成（CPU，可测）与两通道深度绘制（GPU）。
// 一比一移植自 olib kit/gizmo/render3d.odin。
//
// CPU 顶点、Mesh、Shader、Material 由 Renderer3D 独占；宿主提供有场景深度的目标。
// 线框 Shader/Material 也归它；各网格的线框实例缓冲由调用方的 Wireframe 持有。
//
// Jai 侧差异（逐条对应 olib 的写法；顶点数、三角形顺序、颜色与绘制语义不变）：
//   | olib (Odin)                                    | JaiLib (Jai)                                          |
//   | ---------------------------------------------- | ----------------------------------------------------- |
//   | foster.Mesh / foster.Shader / foster.Material   | *F.Mesh / *F.Shader / *F.Material（堆对象，.handle）     |
//   | `#load("shaders/Compiled/…")`                   | shaders_compiled.jai 的 u8 数组常量（jacket 的 #load    |
//   |                                                | 只认 .jai；字节逐字节相同）                               |
//   | `foster.ShaderInit(&s, dev, {…}, name)`        | F.shader_create(dev, stage, code, …, entry_point, name) |
//   | `ShaderInit{Stage = .Vertex}`                  | F.Shader_Stage.VERTEX                                  |
//   | `s.Resource == nil`                            | s == null || s.handle == 0                             |
//   | `foster.MeshInitWithFormat(&m, dev, f, …)`     | F.mesh_create(dev, format, .THIRTY_TWO, name)          |
//   | `foster.VertexFormatMake(elements, stride)`    | F.vertex_format_make（值类型，无需 Dispose）             |
//   | `foster.MaterialInitWithShaders(&m, &vs, &fs)` | F.material_create(vs, fs)                              |
//   | `foster.MaterialStageSetUniformBuffer(&s, b, i)`| F.material_stage_set_uniform(*s, i, b)                |
//   | `foster.MeshSetVertexCount / MeshSetVertices`  | F.mesh_set_vertex_count / F.mesh_set_vertices          |
//   | `foster.DrawCommandFromMesh(&c, …)`            | c = F.draw_command_from_mesh(target, mesh, material)   |
//   | `foster.GraphicsDeviceDraw(dev, &cmd)`         | F.graphics_device_draw(dev, cmd)（按值传）               |
//   | `command.Viewport = {int(x), …}`               | F.Rect_Int{x, y, w, h}（s32）                           |
//   | `[dynamic]Vertex3D` + append / clear           | `[..] Vertex3D` + array_add / gizmo_array_clear         |
//   | `a - b` / `a * s` / `a / s`（向量算术）           | gizmo_v3_* / W.v3_sub（见 translation.jai 的说明）        |
//   | `linalg.cross`                                 | W.v3_cross                                             |
//   | `for side in ([2]f32{-1, 1})`                   | sides 定长数组 + for 索引                                |
//   | `occluded ? min(…) : 1` / `occluded ? .Greater : …` | 先取默认值再 if 改写（Jai 没有三元）                  |
//   | `@(private)`                                   | 去掉标注，内部过程加 gizmo_ 前缀                            |
// 导入（#import）由 module.jai 提供。

//@region 类型与资源生命周期

// 手柄顶点：Float3 位置 + Float4 颜色（28B，与 Gizmo3D.hlsl 一致）。
Vertex3D :: struct {
    position: W.Vec3;
    color:    [4] float32;
}

GIZMO_VERTEX_STRIDE :: 28;
#assert(size_of(Vertex3D) == GIZMO_VERTEX_STRIDE, "手柄顶点必须是 28 字节（位置 12 + 颜色 16）");

Renderer3D :: struct {
    mesh:                        *F.Mesh;
    vertex, fragment:            *F.Shader;
    material:                    *F.Material;
    wire_vertex, wire_fragment:  *F.Shader;
    wire_material:               *F.Material;
    vertices:                    [..] Vertex3D;
    ready:                       bool;
}

// olib: foster.MeshSetVertexCount / clear(&vertices) —— 只把长度归零，容量与已分配的缓冲保留。
gizmo_array_clear :: (array: *[..] $T) {
    if array.data != null array.count = 0;
}

// 手柄顶点格式：Float3 位置 + Float4 颜色（28B）。
gizmo_vertex_format :: () -> F.Vertex_Format {
    elements: [2] F.Vertex_Format_Element = .[
        F.Vertex_Format_Element.{ 0, .FLOAT3, false },
        F.Vertex_Format_Element.{ 1, .FLOAT4, false },
    ];
    return F.vertex_format_make(array_view(elements, 0, 2), GIZMO_VERTEX_STRIDE);
}

// jfoster 的缓冲不 free 自己的结构体（olib 的 foster 是内联值），与 kit/rendering/3d/mesh.jai 同一处理。
gizmo_buffer_release :: (buffer: *F.Graphics_Buffer) {
    if buffer == null return;
    if buffer.handle != 0 && buffer.device != null && !buffer.device.disposed && !buffer.is_disposed {
        F.buffer_dispose(buffer);
    }
    free(buffer);
}

gizmo_mesh_release :: (mesh: *F.Mesh) {
    if mesh == null return;
    gizmo_buffer_release(mesh.VertexBuffer);
    gizmo_buffer_release(mesh.InstanceBuffer);
    gizmo_buffer_release(mesh.IndexBuffer);
    free(mesh);
}

gizmo_shader_release :: (program: *F.Shader) {
    if program == null return;
    if program.handle != 0 && program.device != null && !program.device.disposed && !program.is_disposed {
        F.shader_dispose(program);
    }
    free(program);
}

renderer3d_init :: (r: *Renderer3D, device: *F.Graphics_Device) -> bool {
    if device == null || !mat.shader_driver_supported(device.driver) return false;
    r.vertex = F.shader_create(device, .VERTEX,
        mat.shader_pick(device.driver, mat.Shader_Binaries.{
            spv = gizmo3d_vertex_spv, dxil = gizmo3d_vertex_dxil, msl = gizmo3d_vertex_msl }),
        sampler_count = 0, uniform_buffer_count = 1,
        entry_point = "vertex_main", name = "Gizmo3D vertex");
    r.fragment = F.shader_create(device, .FRAGMENT,
        mat.shader_pick(device.driver, mat.Shader_Binaries.{
            spv = gizmo3d_fragment_spv, dxil = gizmo3d_fragment_dxil, msl = gizmo3d_fragment_msl }),
        uniform_buffer_count = 1, entry_point = "fragment_main", name = "Gizmo3D fragment");
    r.wire_vertex = F.shader_create(device, .VERTEX,
        mat.shader_pick(device.driver, mat.Shader_Binaries.{
            spv = wireframe3d_vertex_spv, dxil = wireframe3d_vertex_dxil, msl = wireframe3d_vertex_msl }),
        sampler_count = 0, uniform_buffer_count = 1,
        entry_point = "vertex_main", name = "Wireframe3D vertex");
    r.wire_fragment = F.shader_create(device, .FRAGMENT,
        mat.shader_pick(device.driver, mat.Shader_Binaries.{
            spv = wireframe3d_fragment_spv, dxil = wireframe3d_fragment_dxil, msl = wireframe3d_fragment_msl }),
        uniform_buffer_count = 1, entry_point = "fragment_main", name = "Wireframe3D fragment");
    if r.vertex == null || r.vertex.handle == 0 || r.fragment == null || r.fragment.handle == 0 ||
       r.wire_vertex == null || r.wire_vertex.handle == 0 ||
       r.wire_fragment == null || r.wire_fragment.handle == 0 {
        renderer3d_destroy(r);
        return false;
    }
    r.mesh = F.mesh_create(device, gizmo_vertex_format(), .THIRTY_TWO, "Gizmo3D mesh");
    r.material = F.material_create(r.vertex, r.fragment);
    r.wire_material = F.material_create(r.wire_vertex, r.wire_fragment);
    array_reserve(*r.vertices, 16000); // olib: make([dynamic]Vertex3D, 0, 16000)
    r.ready = true;
    return true;
}

renderer3d_destroy :: (r: *Renderer3D) {
    if r.material != null F.material_destroy(r.material);
    if r.wire_material != null F.material_destroy(r.wire_material);
    gizmo_mesh_release(r.mesh);
    gizmo_shader_release(r.vertex);
    gizmo_shader_release(r.fragment);
    gizmo_shader_release(r.wire_vertex);
    gizmo_shader_release(r.wire_fragment);
    if r.vertices.data != null array_free(r.vertices);
    r.* = Renderer3D.{};
}
//@endregion

//@region 世界空间网格

// 不读取 GPU，可供测试和自定义渲染器使用。顶点缓冲复用，标签只用于最终像素 UI。
transform_mesh :: (vertices: *[..] Vertex3D, camera: *W.Camera3D, value: Transform,
                   viewport: F.Rect, mode: Mode, state: *Transform_Gizmo, pointer: W.Vec2,
                   scale: float32 = 1, style := DEFAULT_TRANSLATION_STYLE) -> [3] Axis_Label {
    gizmo_array_clear(vertices);
    labels: [3] Axis_Label;
    if !gizmo_finite(scale) || scale <= 0 || !gizmo_finite(style.length) || style.length <= 0 return labels;
    _, center_ok := project(camera, value.position, viewport);
    if !center_ok return labels;
    for i: 0..2 {
        if !gizmo_finite(value.rotation.component[i]) || !gizmo_finite(value.scale.component[i]) ||
           value.scale.component[i] <= 0 {
            return labels;
        }
    }
    geometry := transform_geometry(camera, value, viewport, mode, scale, style);
    depth := W.v3_dot(W.v3_sub(value.position, camera.position), W.camera3d_forward(camera));
    unit := depth * 2 * JM.tan(camera.field_of_view * 0.5) * scale / viewport.h;
    length := unit * style.length;
    hover := transform_hit(geometry, pointer, scale, style);
    if state.dragging hover = state.axis;
    for axis: 0..2 {
        color := style.colors[axis];
        if hover == axis color = style.highlight;
        if mode == .Rotate {
            for i: 0..RING_SEGMENTS - 1 {
                if !geometry.segments[axis][i] continue;
                a := cast(float32) i * 2 * JM.PI / cast(float32) RING_SEGMENTS;
                b := cast(float32) (i + 1) * 2 * JM.PI / cast(float32) RING_SEGMENTS;
                p := value.position;
                q := value.position;
                p.component[(axis + 1) % 3] += JM.cos(a) * length * 0.72;
                p.component[(axis + 2) % 3] += JM.sin(a) * length * 0.72;
                q.component[(axis + 1) % 3] += JM.cos(b) * length * 0.72;
                q.component[(axis + 2) % 3] += JM.sin(b) * length * 0.72;
                gizmo_tube(vertices, p, q, unit * style.line_width * 0.5, unit * style.line_width * 0.5,
                           color);
                if i == axis * RING_SEGMENTS / 3 {
                    labels[axis] = Axis_Label.{
                        visible = true, position = geometry.rings[axis][i], color = color,
                    };
                }
            }
        } else if geometry.axes.visible[axis] {
            direction: W.Vec3;
            direction.component[axis] = 1;
            if mode == .Scale direction = gizmo_rotate_xyz(direction, value.rotation);
            end_point := gizmo_v3_add(value.position, gizmo_v3_scale(direction, length));
            // olib: mode == .Translate ? end - direction*arrow_length*unit : end
            shaft_end := end_point;
            if mode == .Translate {
                shaft_end = W.v3_sub(end_point, gizmo_v3_scale(direction, style.arrow_length * unit));
            }
            gizmo_tube(vertices, value.position, shaft_end, unit * style.line_width * 0.5,
                       unit * style.line_width * 0.5, color);
            if mode == .Translate {
                gizmo_tube(vertices, shaft_end, end_point, style.arrow_half_width * unit, 0, color);
            } else {
                gizmo_box(vertices, end_point, value.rotation, unit * 5, color);
            }
            delta := gizmo_v2_sub(geometry.axes.ends[axis], geometry.axes.origin);
            labels[axis] = Axis_Label.{
                visible = true,
                position = gizmo_v2_add(geometry.axes.ends[axis],
                    gizmo_v2_scale(gizmo_v2_div(delta, JM.sqrt(gizmo_v2_dot(delta, delta))),
                                   style.label_gap * scale)),
                color = color,
            };
        }
    }
    if mode == .Scale && geometry.center_visible {
        center_color := style.center;
        if hover == 3 center_color = style.highlight;
        gizmo_box(vertices, value.position, value.rotation, unit * 6, center_color);
    }
    return labels;
}

// olib 的 @(private) triangle：固定柔和明暗让圆柱和方块显出体积，不依赖项目的灯光材质。
gizmo_triangle :: (v: *[..] Vertex3D, a: W.Vec3, b: W.Vec3, c: W.Vec3, color: F.Color) {
    n := W.v3_cross(W.v3_sub(b, a), W.v3_sub(c, a));
    magnitude := JM.sqrt(W.v3_dot(n, n));
    if magnitude <= 0 || !gizmo_finite(magnitude) return;
    shade := 0.7 + 0.3 * JM.abs(W.v3_dot(gizmo_v3_div(n, magnitude), W.Vec3.{0.36, 0.8, 0.48}));
    col: [4] float32 = .[
        cast(float32) color.r / 255 * shade,
        cast(float32) color.g / 255 * shade,
        cast(float32) color.b / 255 * shade,
        cast(float32) color.a / 255,
    ];
    array_add(v, Vertex3D.{position = a, color = col}, Vertex3D.{position = b, color = col},
              Vertex3D.{position = c, color = col});
}

// olib 的 @(private) tube：8 边柱体（每段 4 个三角形，含两端封口）。
gizmo_tube :: (v: *[..] Vertex3D, a: W.Vec3, b: W.Vec3, radius_a: float32, radius_b: float32,
               color: F.Color) {
    d := W.v3_sub(b, a);
    length_v := JM.sqrt(W.v3_dot(d, d));
    if length_v <= 0.0000001 return;
    d = gizmo_v3_div(d, length_v);
    reference := W.Vec3.{0, 1, 0};
    if JM.abs(d.y) > 0.9 reference = W.Vec3.{1, 0, 0};
    u := W.v3_cross(d, reference);
    u = gizmo_v3_div(u, JM.sqrt(W.v3_dot(u, u)));
    w := W.v3_cross(d, u);
    for i: 0..7 {
        x := cast(float32) i * 2 * JM.PI / 8;
        y := cast(float32) (i + 1) * 2 * JM.PI / 8;
        p := gizmo_v3_add(gizmo_v3_scale(u, JM.cos(x)), gizmo_v3_scale(w, JM.sin(x)));
        q := gizmo_v3_add(gizmo_v3_scale(u, JM.cos(y)), gizmo_v3_scale(w, JM.sin(y)));
        pa := gizmo_v3_add(a, gizmo_v3_scale(p, radius_a));
        pb := gizmo_v3_add(b, gizmo_v3_scale(p, radius_b));
        qb := gizmo_v3_add(b, gizmo_v3_scale(q, radius_b));
        qa := gizmo_v3_add(a, gizmo_v3_scale(q, radius_a));
        gizmo_triangle(v, pa, pb, qb, color);
        gizmo_triangle(v, pa, qb, qa, color);
        gizmo_triangle(v, a, qa, pa, color);
        gizmo_triangle(v, b, pb, qb, color);
    }
}

// olib 的 @(private) box：三个轴的 ±half 面各两个三角形（共 12 个），整体按 rotation 旋转。
gizmo_box :: (v: *[..] Vertex3D, center: W.Vec3, rotation: W.Vec3, half: float32, color: F.Color) {
    sides: [2] float32 = .[-1, 1];
    corners: [4][2] float32 = .[.[-1, -1], .[1, -1], .[1, 1], .[-1, 1]];
    for axis: 0..2 {
        for side: sides {
            points: [4] W.Vec3;
            for i: 0..3 {
                p: W.Vec3;
                p.component[axis] = side * half;
                p.component[(axis + 1) % 3] = corners[i][0] * half;
                p.component[(axis + 2) % 3] = corners[i][1] * half;
                points[i] = gizmo_v3_add(center, gizmo_rotate_xyz(p, rotation));
            }
            gizmo_triangle(v, points[0], points[1], points[2], color);
            gizmo_triangle(v, points[0], points[2], points[3], color);
        }
    }
}
//@endregion

//@region 三维绘制

// 目标必须已有与 camera/viewport 匹配的场景深度（标准 0..1 深度，近小远大）。
// 两通道都不写深度；被遮挡部分淡化，保留可操作提示。返回的标签交由 UI 绘制。
transform_draw :: (r: *Renderer3D, target: F.Drawable_Target, camera: *W.Camera3D,
                   value: Transform, viewport: F.Rect, mode: Mode, state: *Transform_Gizmo,
                   pointer: W.Vec2, scale: float32 = 1,
                   style := DEFAULT_TRANSLATION_STYLE) -> [3] Axis_Label {
    labels: [3] Axis_Label; // olib: `return {}`
    if !r.ready return labels;
    labels = transform_mesh(*r.vertices, camera, value, viewport, mode, state, pointer, scale, style);
    gizmo_draw_vertices(r, target, camera, viewport, 0.12);
    return labels;
}

translation_draw :: (r: *Renderer3D, target: F.Drawable_Target, camera: *W.Camera3D,
                     position: W.Vec3, viewport: F.Rect, state: *Translation_Gizmo,
                     pointer: W.Vec2, scale: float32 = 1,
                     style := DEFAULT_TRANSLATION_STYLE) -> [3] Axis_Label {
    transform := Transform_Gizmo.{dragging = state.dragging, axis = state.axis};
    unit_scale := W.Vec3.{1, 1, 1};
    return transform_draw(r, target, camera, Transform.{position = position, scale = unit_scale},
                          viewport, .Translate, *transform, pointer, scale, style);
}

// 提交 r.vertices：被场景遮挡的片元按 hidden_alpha 淡化（0 不画），可见片元正常显示，都不写深度。
gizmo_draw_vertices :: (r: *Renderer3D, target: F.Drawable_Target, camera: *W.Camera3D,
                        viewport: F.Rect, hidden_alpha: float32) {
    if r.vertices.count == 0 return;
    F.mesh_set_vertex_count(r.mesh, cast(s32) r.vertices.count);
    F.mesh_set_vertices(r.mesh, r.vertices);
    matrix_bytes: [64] u8;
    mat.std140_write_matrix(matrix_bytes, 0, W.camera3d_view_projection(camera));
    F.material_stage_set_uniform(*r.material.Vertex, 0, matrix_bytes);
    gizmo_draw_depth_tested(r.material, r.mesh, target, viewport, hidden_alpha);
}

// 顶点常量由调用方写好；遮挡与可见两通道只改片元 Tint 和深度比较。
gizmo_draw_depth_tested :: (material: *F.Material, mesh: *F.Mesh, target: F.Drawable_Target,
                            viewport: F.Rect, hidden_alpha: float32) {
    command := F.draw_command_from_mesh(target, mesh, material);
    command.DepthTestEnabled = true;
    command.DepthWriteEnabled = false;
    command.CullMode = .NONE;
    command.HasViewport = true;
    command.Viewport = F.Rect_Int.{
        cast(s32) viewport.x, cast(s32) viewport.y, cast(s32) viewport.w, cast(s32) viewport.h,
    };
    command.HasScissor = true;
    command.Scissor = command.Viewport;
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
    occluded_flags: [2] bool = .[true, false];
    for occluded: occluded_flags {
        if occluded && !(hidden_alpha > 0) continue;
        // olib: occluded ? min(hidden_alpha, 1) : 1
        alpha: float32 = 1;
        if occluded alpha = min(hidden_alpha, cast(float32) 1);
        tint: [16] u8;
        mat.std140_write_vec4(tint, 0, .[cast(float32) 1, cast(float32) 1, cast(float32) 1, alpha]);
        F.material_stage_set_uniform(*material.Fragment, 0, tint);
        if occluded command.DepthCompare = .GREATER; else command.DepthCompare = .LESS_OR_EQUAL;
        F.graphics_device_draw(mesh.device, command);
    }
}
//@endregion
