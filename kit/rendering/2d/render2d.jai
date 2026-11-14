// rendering2d:render2d —— Render2D：2D 唯一的绘制入口（记录后统一提交，olib 材质，含 UI），
// 以及常驻显存的精灵实例缓冲（r2d.buffer 绘制）。
// 一比一移植自 olib kit/rendering/2d/render2d.odin。
//
// 用法与 Batcher 一致——记录图元（矩阵 / 裁剪 / 混合 / 采样器 / mode 栈），
// submit 时按记录顺序合批提交并清空，submit 是唯一的提交点。材质是 olib 的 mat.Material；不传时用材质库的
// 内置 Sprite_Default（贴图 × 顶点色）。顶点格式就是 jfoster 的 Batcher_Vertex，tint 放在顶点色里。
//
// Jai 侧差异（逐条对应 olib 的写法；记录顺序、合批条件、顶点/实例布局与提交语义不变）：
//   | olib (Odin)                                        | JaiLib (Jai)                                            |
//   | -------------------------------------------------- | ------------------------------------------------------- |
//   | foster.BatcherVertex{Pos,Tex,Col,Mode}             | F.Batcher_Vertex{pos,tex,col,mode}                       |
//   | foster.BatcherVertexFormat()                       | F.Batcher_Vertex_Format（#run 常量）                      |
//   | foster.BatcherMode / foster.BatcherModeState       | F.Batcher_Modes / Render2D_Mode_State（jfoster 的 mode    |
//   |                                                    | 直接存成 Color，没有 BatcherModeState，这里补同名字段结构） |
//   | foster.TextureSamplerMake(.Nearest, .Clamp)        | F.texture_sampler_make(.NEAREST, .CLAMP)                 |
//   | foster.BlendModePremultiply                        | F.Blend_Mode_Premultiply                                 |
//   | foster.Vec2 / Color / Rect / RectInt               | F.Vector2 / F.Color / F.Rect / F.Rect_Int（x,y,w,h）      |
//   | foster.Matrix3x2{M11,M12,M21,M22,M31,M32}          | F.Matrix3x2{m11,m12,m21,m22,m31,m32}                     |
//   | foster.TransformCreateMatrix(pos, origin, s, rot)   | F.matrix3x2_create_transform(pos, origin, s, rot)        |
//   | foster.Matrix3x2TransformPoint(m, p)               | F.vector2_transform(p, m)（形参顺序相反）                  |
//   | foster.Subtexture.Texture / foster.SubtextureFrom…  | F.Subtexture.Tex / F.subtexture_make_full / _Empty       |
//   | foster.Texture（值类型 + .Resource）                | *F.Texture（堆对象 + .handle != 0）                        |
//   | foster.Mesh（值）                                   | *F.Mesh（F.mesh_create / mesh_dispose + free）            |
//   | foster.StorageBuffer / VertexBuffer                | *F.Graphics_Buffer（storage_buffer_ / vertex_buffer_）    |
//   | foster.Material（值，MaterialInitWithShaders）      | *F.Material（F.material_create() / material_destroy）     |
//   | foster.MaterialStageSetShader(&stage, s)           | F.material_stage_set_shader(*stage, s)                   |
//   | foster.MaterialStageSetUniformBuffer(&s, bytes, i)  | F.material_stage_set_uniform(*s, i, bytes)               |
//   | foster.VertexFormatMake / VertexFormatClone        | F.vertex_format_make / 值拷贝格式（Graphics_Buffer 整份浅  |
//   |                                                    | 拷贝，只换 Elements[].Index）                             |
//   | foster.DrawCommandFromMesh(&cmd, target, mesh, m)   | cmd = F.draw_command_from_mesh(target, mesh, m)          |
//   | foster.GraphicsDeviceDraw(device, &cmd)            | F.graphics_device_draw(device, cmd)                      |
//   | foster.DrawableTarget.WidthInPixels                | F.drawable_target_width_in_pixels(target)                |
//   | foster.DrawCommand.VertexStorageBuffers 的 append   | VertexStorageBuffers[count] + VertexStorageBufferCount    |
//   | `[dynamic]T` + append / delete / len               | `[..]T` + array_add / array_free / .count                |
//   | `pop(&stack)`                                      | render2d_pop（jacket 没有 array_pop）                     |
//   | struct / 数组的 `==`                                | render2d_scissor_equal / render2d_selection_equal        |
//   | `size := size > 0 ? size : font.Size`（遮蔽形参）    | `size_px := …`（Jai 不允许同作用域遮蔽形参）               |
//   | `for c, index in value`（Odin 按码点迭代）           | render2d_utf8_next（同样的码点 + 字节下标）               |
//   | foster.SpriteFont.Size / .Ascent / .LineHeight      | font.Size / font.Ascent / F.sprite_font_line_height      |
//   | foster.SpriteFontHeightOf / WidthOfLine / …         | F.sprite_font_height_of / width_of_line / try_get_character |
//   | glyph.Subtexture                                    | glyph.Subtex                                             |
//   | foster.VertexBufferReserve(&buf, n)                | F.buffer_upload(buf, null, n, 0) 后把 Count 归零（jfoster   |
//   |                                                    | 没有 Reserve：空数据上传只重建 GPU 缓冲，语义就是预留）      |
//   | mem.slice_to_bytes(x[:])                           | render2d_bytes(&x)（同一条「值即字节」视图）                |
//   | @(private)                                         | 去掉标注，内部过程加 render2d_ / sprite_ 前缀               |
#import "Basic";

//@region 类型

// 一次提交的视图：目标与时间（写入 olib Shader 的 Clock）。pointer 是归一化指针位置（Pointer.xy），业务通常不用。
View :: struct {
    target: F.Drawable_Target;
    time, delta_time: float32;
    frame: u64;
    pointer: [2] float32;
}

// 材质路径的引擎块字节数：顶点 b0 为 Projection + Clock，片元 b0 为 Clock、Pointer、Tint。
// 与 kit/rendering/shader/lang/include/olib/sprite.hlsli 一致（kit/rendering/twod 测试检查）。
SPRITE_VERTEX_BLOCK_SIZE :: 80;
SPRITE_FRAME_BLOCK_SIZE :: 48;

// 一段记录的四边形上限：超过就开新段，限制单次 Draw 的范围。
RENDER2D_BATCH_QUADS :: 4096;

Render2D :: struct {
    library: *mat.Material_Library;
    default_material: *mat.Material; // 内置 Sprite_Default 的实例，归材质库所有
    draw_calls: int; // 最近一次 submit 的 Draw 数
    // 以下由渲染器维护。
    transform: [16] float32; // 4×4 矩阵，行向量约定（v * M，下标 行*4+列），存储与 jfoster Batcher 相同
    sampler: F.Texture_Sampler;
    blend: F.Blend_Mode;
    mode: F.Batcher_Modes;
    mode_color: F.Color;
    scissor: F.Rect_Int;
    has_scissor: bool;
    transform_stack: [..][16] float32;
    sampler_stack: [..] F.Texture_Sampler;
    blend_stack: [..] F.Blend_Mode;
    mode_stack: [..] Render2D_Mode_State;
    scissor_stack: [..] Render2D_Scissor;
    vertices: [..] F.Batcher_Vertex;
    runs: [..] Render2D_Run;
    // 每个 run 的每个 Pass 一份 GPU 材质快照（Shader、参数 uniform、贴图）；跨帧复用，submit 时补上投影与 Clock。
    snapshots: [..] *F.Material;
    snapshot_count: int;
    mesh: *F.Mesh;
    index_quads: int; // 索引缓冲已覆盖的四边形数（索引是固定的四边形图案，只在增长时重建）
    // 带 [Instance] 字段的 Shader：每个精灵一组 float4，顶点 mode 字节存它的起始偏移；[0] 保留不用。submit 时上传一次。
    instance_values: [..][4] float32;
    // 每个 run 的各所选 Pass 一张实例值表，开段时按材质建一次，逐精灵按表写值。
    instance_tables: [..] mat.Instance_Table;
    instance_buffer: *F.Graphics_Buffer;
    instance_ready: bool;
    // r2d.buffer 用的单位四边形角点网格，首次使用时创建。
    corner_mesh: *F.Mesh;
    corner_ready: bool;
}

// olib: foster.BatcherModeState —— jfoster 把 mode 直接存成顶点色，没有这个结构，这里按同名同字段补上。
Render2D_Mode_State :: struct {
    Mode: F.Batcher_Modes;
    Color: F.Color;
}

Render2D_Scissor :: struct {
    rect: F.Rect_Int;
    enabled: bool;
}

// 连续可合并的一段记录：同一材质与 Pass 选择、同一帧贴图 / 采样器 / 混合 / 裁剪、参数相同。
Render2D_Run :: struct {
    material: *mat.Material;
    revision: u64; // 快照时的材质 revision；之后数值或贴图有变就开新段

    pass_id: mat.Pass_Id;
    selection: mat.Pass_Selection;
    snapshot: int; // 第一个 Pass 的快照下标，后面连续 selection.count 个
    texture: *F.Texture;
    sampler: F.Texture_Sampler;
    blend: F.Blend_Mode;
    scissor: Render2D_Scissor;
    quad_start, quad_count: int;
    storage: bool; // 顶点从 instance_values 读两条轴和 [Instance] 字段（.oshader Shader 总是）
    pass_offsets: [sh.MAX_PASSES] u32; // 每个精灵的数值记录内，各 Pass 的 float4 偏移
    tables: int; // r.instance_tables 中的起点，各所选 Pass 依次一张
    // r2d.buffer 记录的常驻缓冲：不与其他记录合并，用缓冲变体顶点着色器实例化绘制。
    buffer: *Sprite_Buffer;
    instance_count: int;
    transform: [16] float32; // 记录时的变换栈，提交时其 2D 仿射部分写入顶点 b1
}
//@endregion

//@region 生命周期

// 设备取自材质库；返回 "" 表示成功。r 初始化后不得搬动（快照材质被绘制命令借用）。
init :: (r: *Render2D, library: *mat.Material_Library) -> string {
    if library == null || library.device == null return "Missing graphics device";
    material, reason := mat.material_create(library, mat.BUILTIN_SPRITE);
    if reason != "" return reason;
    r.* = Render2D.{ library = library, default_material = material };
    render2d_reset_state(r);
    r.mesh = F.mesh_create(library.device, F.Batcher_Vertex_Format, .THIRTY_TWO, "render2d");
    return "";
}

// 丢弃未提交的记录并释放 GPU 资源；默认材质归材质库，不在这里释放。
dispose :: (r: *Render2D) {
    if r.snapshots.data != null {
        for snapshot: r.snapshots F.material_destroy(snapshot);
        array_free(r.snapshots);
    }
    if r.vertices.data != null array_free(r.vertices);
    if r.runs.data != null array_free(r.runs);
    if r.transform_stack.data != null array_free(r.transform_stack);
    if r.sampler_stack.data != null array_free(r.sampler_stack);
    if r.blend_stack.data != null array_free(r.blend_stack);
    if r.mode_stack.data != null array_free(r.mode_stack);
    if r.scissor_stack.data != null array_free(r.scissor_stack);
    if r.instance_values.data != null array_free(r.instance_values);
    if r.instance_tables.data != null array_free(r.instance_tables);
    if r.instance_ready {
        render2d_buffer_release(r.instance_buffer);
    }
    if r.corner_ready {
        render2d_mesh_release(r.corner_mesh);
    }
    if r.library != null {
        render2d_mesh_release(r.mesh);
    }
    r.* = Render2D.{};
}

// 丢弃已记录、未提交的内容并恢复默认状态（与 BatcherClear 相同），例如目标失效时放弃本帧。
reset :: (r: *Render2D) {
    render2d_reset(r);
}

// olib: foster.MeshDispose(&mesh)。jfoster 的 Mesh / Graphics_Buffer 都是 New 出来的堆对象。
render2d_mesh_release :: (mesh: *F.Mesh) {
    if mesh == null return;
    if (mesh.device == null || !mesh.device.disposed) && !mesh_is_disposed_flag(mesh) {
        F.mesh_dispose(mesh);
    }
    free(mesh);
}

// 再见一次 mesh_is_disposed 的判断：缓冲区均已释放时不再重复销毁 GPU 资源。
mesh_is_disposed_flag :: (mesh: *F.Mesh) -> bool {
    if mesh.VertexBuffer == null || mesh.IndexBuffer == null return false;
    return F.buffer_is_disposed(mesh.VertexBuffer) && F.buffer_is_disposed(mesh.IndexBuffer);
}

// olib: foster.VertexBufferDispose / StorageBufferDispose。同上：先还 GPU 资源，再 free。
render2d_buffer_release :: (buffer: *F.Graphics_Buffer) {
    if buffer == null return;
    if buffer.handle != 0 && buffer.device != null && !buffer.device.disposed && !buffer.is_disposed {
        F.buffer_dispose(buffer);
    }
    free(buffer);
}
//@endregion

//@region 状态栈 —— 语义与 Batcher 的同名 Push/Pop 相同；submit 后全部恢复默认。

// olib: pop(&dynamic_array)。jacket 没有 array_pop，这里补一个（不缩容量）。
render2d_pop :: ($T: Type, array: *[..] T) -> T {
    value := array.*[array.count - 1];
    array.count -= 1;
    return value;
}

// olib: fence.post_increment? 无——只是把值写进临时数组时用的字节视图。
render2d_bytes :: ($T: Type, value: *T) -> [] u8 {
    return .{ data = cast(*u8) value, count = size_of(T) };
}

relative_keep :: (value: bool) -> bool {
    return value;
}

push_matrix :: (r: *Render2D, m: F.Matrix3x2, relative := true) {
    identity_projection: [16] float32 = .[m.m11, m.m12, 0, 0, m.m21, m.m22, 0, 0, 0, 0, 1, 0, m.m31, m.m32, 0, 1];
    push_matrix_raw(r, identity_projection, relative);
}

push_matrix_trs :: (r: *Render2D, position: F.Vector2, scale: F.Vector2, rotation: float32, relative := true) {
    push_matrix(r, F.matrix3x2_create_transform(position, F.Vector2.{ 0, 0 }, scale, rotation), relative);
}

push_matrix_raw :: (r: *Render2D, m: [16] float32, relative := true) {
    array_add(*r.transform_stack, r.transform);
    if !relative {
        r.transform = m;
        return;
    }
    // 行向量约定（v' = v * M，下标 行*4+列）：out = m * 当前，与上游 Foster 的 `matrix * Matrix` 一致。
    a := r.transform;
    out: [16] float32;
    for row: 0..3 {
        for col: 0..3 {
            out[row * 4 + col] = m[row * 4] * a[col] + m[row * 4 + 1] * a[4 + col] +
                               m[row * 4 + 2] * a[8 + col] + m[row * 4 + 3] * a[12 + col];
        }
    }
    r.transform = out;
}

pop_matrix :: (r: *Render2D) {
    if r.transform_stack.count > 0 {
        r.transform = render2d_pop([16] float32, *r.transform_stack);
    }
}

// 只影响默认材质：Normal 为贴图 × 颜色，Wash 只取贴图 alpha，Fill 只用颜色。
push_mode :: (r: *Render2D, mode: F.Batcher_Modes) {
    array_add(*r.mode_stack, Render2D_Mode_State.{ r.mode, r.mode_color });
    r.mode = mode;
    r.mode_color = render2d_mode_color(mode);
}

pop_mode :: (r: *Render2D) {
    if r.mode_stack.count == 0 return;
    state := render2d_pop(Render2D_Mode_State, *r.mode_stack);
    r.mode, r.mode_color = state.Mode, state.Color;
}

// 帧贴图的采样方式；材质自带的其他贴图不受影响。
push_sampler :: (r: *Render2D, sampler: F.Texture_Sampler) {
    array_add(*r.sampler_stack, r.sampler);
    r.sampler = sampler;
}

pop_sampler :: (r: *Render2D) {
    if r.sampler_stack.count > 0 {
        r.sampler = render2d_pop(F.Texture_Sampler, *r.sampler_stack);
    }
}

// 未声明混合方式的 Pass 使用它；Pass 显式声明的 blend 优先。
push_blend :: (r: *Render2D, blend: F.Blend_Mode) {
    array_add(*r.blend_stack, r.blend);
    r.blend = blend;
}

pop_blend :: (r: *Render2D) {
    if r.blend_stack.count > 0 {
        r.blend = render2d_pop(F.Blend_Mode, *r.blend_stack);
    }
}

// 目标像素坐标的裁剪矩形。
push_scissor :: (r: *Render2D, scissor: F.Rect_Int) {
    array_add(*r.scissor_stack, Render2D_Scissor.{ r.scissor, r.has_scissor });
    r.scissor, r.has_scissor = scissor, true;
}

pop_scissor :: (r: *Render2D) {
    if r.scissor_stack.count == 0 return;
    state := render2d_pop(Render2D_Scissor, *r.scissor_stack);
    r.scissor, r.has_scissor = state.rect, state.enabled;
}
//@endregion

//@region 图元 —— 只记录；返回值为记录时就能确定的错误（材质未加载、Pass 不存在等），.None 表示已记录。
// material 为 null 时用内置 Sprite_Default。纯色图元在默认材质下用 Fill 模式，不因贴图不同而断批。

// 画图集子图：保留裁剪后的 DrawCoords / TexCoords，origin 是相对未裁剪原图的锚点像素。
// values 只设置这一次绘制的 [Instance] 字段，不修改共享材质。
image :: (r: *Render2D, frame: F.Subtexture, transform: F.Matrix3x2, color := F.Color_White,
          origin := F.Vector2.{ 0, 0 }, material: *mat.Material = null, values: *mat.Instance_Values = null,
          pass_id: mat.Pass_Id = "") -> mat.Draw_Error {
    if frame.Tex == null || frame.Tex.handle == 0 return .Missing_Sprite_Texture;
    corners := render2d_frame_corners(frame, origin, transform);
    axes: [4] float32 = .[transform.m11, transform.m12, transform.m21, transform.m22];
    return render2d_record(r, material, frame.Tex, corners, frame.TexCoords, .[color, color, color, color],
                           values, pass_id, axes);
}

// 整张贴图当一帧。
texture :: (r: *Render2D, texture: *F.Texture, transform: F.Matrix3x2, color := F.Color_White,
            origin := F.Vector2.{ 0, 0 }, material: *mat.Material = null, values: *mat.Instance_Values = null,
            pass_id: mat.Pass_Id = "") -> mat.Draw_Error {
    if texture == null || texture.handle == 0 return .Missing_Sprite_Texture;
    return image(r, F.subtexture_make_full(texture), transform, color, origin, material, values, pass_id);
}

// 任意四边形贴图，顶点顺序 a→b→c→d（两个三角形 abc、acd）。
quad_texture :: (r: *Render2D, texture: *F.Texture, a: F.Vector2, b: F.Vector2, c: F.Vector2, d: F.Vector2,
                 uv0: F.Vector2, uv1: F.Vector2, uv2: F.Vector2, uv3: F.Vector2, color := F.Color_White,
                 material: *mat.Material = null, values: *mat.Instance_Values = null,
                 pass_id: mat.Pass_Id = "") -> mat.Draw_Error {
    if texture == null || texture.handle == 0 return .Missing_Sprite_Texture;
    return render2d_record(r, material, texture, .[a, b, c, d], .[uv0, uv1, uv2, uv3],
                           .[color, color, color, color], values, pass_id, RENDER2D_AXES_IDENTITY);
}

quad :: (r: *Render2D, a: F.Vector2, b: F.Vector2, c: F.Vector2, d: F.Vector2, color: F.Color,
         material: *mat.Material = null) -> mat.Draw_Error {
    return render2d_record(r, material, null, .[a, b, c, d], .[F.Vector2.{ 0, 0 }, F.Vector2.{ 0, 0 }, F.Vector2.{ 0, 0 }, F.Vector2.{ 0, 0 }],
                           .[color, color, color, color], null, "", RENDER2D_AXES_IDENTITY);
}

// 四个顶点各自的颜色，GPU 插值成渐变；顶点顺序同 quad。
quad_gradient :: (r: *Render2D, a: F.Vector2, b: F.Vector2, c: F.Vector2, d: F.Vector2,
                  c0: F.Color, c1: F.Color, c2: F.Color, c3: F.Color,
                  material: *mat.Material = null) -> mat.Draw_Error {
    return render2d_record(r, material, null, .[a, b, c, d], .[F.Vector2.{ 0, 0 }, F.Vector2.{ 0, 0 }, F.Vector2.{ 0, 0 }, F.Vector2.{ 0, 0 }],
                           .[c0, c1, c2, c3], null, "", RENDER2D_AXES_IDENTITY);
}

// 矩形渐变：c0..c3 依次为左上、右上、右下、左下。
rect_gradient :: (r: *Render2D, rect: F.Rect, c0: F.Color, c1: F.Color, c2: F.Color, c3: F.Color,
                  material: *mat.Material = null) -> mat.Draw_Error {
    x0, y0, x1, y1 := rect.x, rect.y, rect.x + rect.w, rect.y + rect.h;
    return quad_gradient(r, .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 }, c0, c1, c2, c3, material);
}

rect :: (r: *Render2D, rect: F.Rect, color: F.Color, material: *mat.Material = null) -> mat.Draw_Error {
    x0, y0, x1, y1 := rect.x, rect.y, rect.x + rect.w, rect.y + rect.h;
    return quad(r, .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 }, color, material);
}

// 粗细为 thickness 的线段（四边形）；长度为 0 时不记录。
line :: (r: *Render2D, from: F.Vector2, to: F.Vector2, thickness: float32, color: F.Color,
         material: *mat.Material = null) -> mat.Draw_Error {
    d := to - from;
    length := JM.sqrt(d.x * d.x + d.y * d.y);
    if length <= 0 return .None;
    n := F.Vector2.{ -d.y, d.x } / length * thickness * 0.5;
    return quad(r, from + n, to + n, to - n, from - n, color, material);
}

// 三角形按退化四边形（第四个顶点重复 c）记录，与其他图元共用同一套索引。
triangle :: (r: *Render2D, a: F.Vector2, b: F.Vector2, c: F.Vector2, color: F.Color,
             material: *mat.Material = null) -> mat.Draw_Error {
    return quad(r, a, b, c, c, color, material);
}

// 实心圆，steps < 3 时不记录。
circle :: (r: *Render2D, center: F.Vector2, radius: float32, steps: int, color: F.Color,
           material: *mat.Material = null) -> mat.Draw_Error {
    if steps < 3 return .None;
    for i: 0..steps - 1 {
        a0 := cast(float32) i / cast(float32) steps * JM.TAU;
        a1 := cast(float32) (i + 1) / cast(float32) steps * JM.TAU;
        p0 := center + F.Vector2.{ JM.cos(a0), JM.sin(a0) } * radius;
        p1 := center + F.Vector2.{ JM.cos(a1), JM.sin(a1) } * radius;
        error := triangle(r, center, p0, p1, color, material);
        if error != .None return error;
    }
    return .None;
}

// 中心到边缘渐变的实心圆，steps < 3 时不记录。
circle_gradient :: (r: *Render2D, center: F.Vector2, radius: float32, steps: int,
                    center_color: F.Color, edge_color: F.Color, material: *mat.Material = null) -> mat.Draw_Error {
    if steps < 3 return .None;
    for i: 0..steps - 1 {
        a0 := cast(float32) i / cast(float32) steps * JM.TAU;
        a1 := cast(float32) (i + 1) / cast(float32) steps * JM.TAU;
        p0 := center + F.Vector2.{ JM.cos(a0), JM.sin(a0) } * radius;
        p1 := center + F.Vector2.{ JM.cos(a1), JM.sin(a1) } * radius;
        error := quad_gradient(r, center, p0, p1, p1, center_color, edge_color, edge_color, edge_color, material);
        if error != .None return error;
    }
    return .None;
}

// 用 jfoster 的位图字体（Sprite_Font）画一段文字，语义同 F.sprite_font_draw：position 是左上角，
// size 为 0 时用字体原始字号，justify 为对齐比例（0 左/上，0.5 居中，1 右/下），支持换行与字距。
// 字形用字体的采样器；字体自带的 Material 不使用（material 为 null 时用默认材质）。
text :: (r: *Render2D, font: *F.Sprite_Font, value: string, position: F.Vector2, color := F.Color_White,
         size: float32 = 0, justify := F.Vector2.{ 0, 0 }, material: *mat.Material = null) -> mat.Draw_Error {
    if font == null return .None;
    size_px := size;
    if size_px <= 0 size_px = font.Size; // olib: size > 0 ? size : font.Size
    scale := 1.0;
    if font.Size > 0 scale = size_px / font.Size;
    push_matrix(r, F.Matrix3x2.{ scale, 0, 0, scale, position.x, position.y });
    defer pop_matrix(r);
    push_sampler(r, font.Sampler);
    defer pop_sampler(r);
    line_height := F.sprite_font_line_height(font);
    line_start := 0;
    at := F.Vector2.{ 0, font.Ascent };
    if justify.y != 0 {
        at.y -= justify.y * F.sprite_font_height_of(font, value);
    }
    last := 0;
    index := 0;
    while index < value.count {
        c, next := render2d_utf8_next(value, index);
        if index == line_start && justify.x != 0 {
            at.x = -justify.x * F.sprite_font_width_of_line(font, atlas_substring(value, index, value.count));
        }
        if c == 10 { // '\n'
            at = .{ 0, at.y + line_height };
            line_start, last = next, 0;
            index = next;
            continue;
        }
        glyph, ok := F.sprite_font_try_get_character(font, cast(s32) c);
        if ok {
            if last != 0 {
                at.x += F.sprite_font_get_kerning(font, cast(s32) last, cast(s32) c);
            }
            if glyph.Subtex.Tex != null {
                p := at + glyph.Offset;
                error := image(r, glyph.Subtex, F.Matrix3x2.{ 1, 0, 0, 1, p.x, p.y }, color, material = material);
                if error != .None return error;
            }
            at.x += glyph.Advance;
            last = c;
        }
        index = next;
    }
    return .None;
}

// olib 的 `for c, index in value`：按 UTF-8 码点迭代，返回码点与下一码点的字节下标。
render2d_utf8_next :: (value: string, at: int) -> (codepoint: int, next: int) {
    c := value[at];
    if c < 0x80 return cast(int) c, at + 1;
    length := 1;
    rune := 0;
    if (c & 0xE0) == 0xC0 {
        length = 2;
        rune = c & 0x1F;
    } else if (c & 0xF0) == 0xE0 {
        length = 3;
        rune = c & 0x0F;
    } else if (c & 0xF8) == 0xF0 {
        length = 4;
        rune = c & 0x07;
    } else {
        return cast(int) c, at + 1;
    }
    for i: 1..length - 1 {
        if at + i >= value.count break;
        rune = (rune << 6) | (value[at + i] & 0x3F);
    }
    return cast(int) rune, at + length;
}

// 空心圆：外径 radius、环宽 thickness；环宽不小于半径时画实心圆，steps < 3 时不记录。
circle_line :: (r: *Render2D, center: F.Vector2, radius: float32, thickness: float32, steps: int,
                color: F.Color, material: *mat.Material = null) -> mat.Draw_Error {
    if steps < 3 return .None;
    inner := radius - thickness;
    if inner <= 0 {
        return circle(r, center, radius, steps, color, material);
    }
    for i: 0..steps - 1 {
        a0 := cast(float32) i / cast(float32) steps * JM.TAU;
        a1 := cast(float32) (i + 1) / cast(float32) steps * JM.TAU;
        d0 := F.Vector2.{ JM.cos(a0), JM.sin(a0) };
        d1 := F.Vector2.{ JM.cos(a1), JM.sin(a1) };
        error := quad(r, center + d0 * inner, center + d0 * radius, center + d1 * radius, center + d1 * inner,
                      color, material);
        if error != .None return error;
    }
    return .None;
}
//@endregion

//@region 提交 —— 上传本帧顶点，按记录顺序逐段、逐 Pass 绘制，然后清空记录并恢复默认状态。

submit :: (r: *Render2D, view: View) -> mat.Draw_Error {
    defer render2d_reset(r);
    r.draw_calls = 0;
    if r.runs.count == 0 return .None;
    w := F.drawable_target_width_in_pixels(view.target);
    h := F.drawable_target_height_in_pixels(view.target);
    if w <= 0 || h <= 0 return .Invalid_Target;
    render2d_upload(r);
    // 顶点 b0：目标像素到裁剪空间的投影，后接 Clock（与片元 Clock 同值）。
    vertex_uniform: [SPRITE_VERTEX_BLOCK_SIZE / 4] float32 = .[
        2.0 / cast(float32) w, 0, 0, 0,
        0, -2.0 / cast(float32) h, 0, 0,
        0, 0, 1, 0,
        -1, 1, 0, 1,
        view.time, view.delta_time, cast(float32) view.frame, 0,
    ];
    frame: [SPRITE_FRAME_BLOCK_SIZE / 4] float32 = .[
        view.time, view.delta_time, cast(float32) view.frame, 0,
        view.pointer[0], view.pointer[1], cast(float32) w, cast(float32) h,
        1, 1, 1, 1,
    ];
    for *run: r.runs {
        shader := run.material.shader.desc;
        for i: 0..run.selection.count - 1 {
            snapshot := r.snapshots[run.snapshot + i];
            storage := run.storage;
            if storage {
                pass_offset: [4] u32 = .[run.pass_offsets[i], 0, 0, 0];
                F.material_stage_set_uniform(*snapshot.Vertex, 1, render2d_bytes([4] u32, *pass_offset));
            }
            if run.buffer != null {
                // 常驻缓冲的实例在变换栈之前的坐标里：olib_sprite 用 b1 的 2D 仿射部分换算到目标像素，
                // 与批量变体在 CPU 上套用的部分相同，position 与轴在两种变体里同一空间。
                t := run.transform;
                stack: [8] float32 = .[t[0], t[1], t[4], t[5], t[12], t[13], 0, 0];
                F.material_stage_set_uniform(*snapshot.Vertex, 1, render2d_bytes([8] float32, *stack));
            }
            F.material_stage_set_uniform(*snapshot.Vertex, 0, render2d_bytes([SPRITE_VERTEX_BLOCK_SIZE / 4] float32, *vertex_uniform));
            if shader.uniforms == .Olib {
                F.material_stage_set_uniform(*snapshot.Fragment, 0, render2d_bytes([SPRITE_FRAME_BLOCK_SIZE / 4] float32, *frame));
            }
            command: F.Draw_Command;
            if run.buffer != null {
                // 角点保持 TEXCOORD0，实例属性用 TEXCOORD6 起（见 sprite_instance_format），不需要改编号。
                command = F.draw_command_from_mesh(view.target, r.corner_mesh, snapshot);
                command.VertexBuffers[1] = F.Vertex_Buffer_Binding.{ Buffer = run.buffer.buffer, InstanceInputRate = true };
                command.VertexBufferCount = 2;
                command.InstanceCount = cast(s32) run.instance_count;
            } else {
                command = F.draw_command_from_mesh(view.target, r.mesh, snapshot);
                command.IndexOffset = cast(s32) (run.quad_start * 6);
                command.IndexCount = cast(s32) (run.quad_count * 6);
                command.VertexCount = 0;
                if storage {
                    command.VertexStorageBuffers[command.VertexStorageBufferCount] = r.instance_buffer;
                    command.VertexStorageBufferCount += 1;
                }
            }
            command.BlendMode = run.blend;
            command.CullMode = .NONE;
            command.DepthTestEnabled = false;
            command.DepthWriteEnabled = false;
            command.HasScissor = run.scissor.enabled;
            command.Scissor = run.scissor.rect;
            mat.pass_state_apply(*command, shader.passes[run.selection.passes[i]].state);
            F.graphics_device_draw(r.library.device, command);
            r.draw_calls += 1;
        }
    }
    return .None;
}

// 记录常驻缓冲 buf 的前 count 个精灵：每个 Pass 一次实例化 Draw，帧贴图都是 texture（图集页）。
// 材质须是 instanced 精灵 Shader（有缓冲变体）；[Instance] 字段以缓冲为准，统一参数来自材质。
// 当前变换栈（如相机）同样作用于这些精灵；按记录顺序与其他图元叠放，不与它们合批。
buffer :: (r: *Render2D, material: *mat.Material, buf: *Sprite_Buffer, count: int,
           texture: *F.Texture, pass_id: mat.Pass_Id = "") -> mat.Draw_Error {
    if r.library == null || r.library.device == null return .Missing_Device;
    if material == null || material.owner == null || material.shader == null return .Missing_Material;
    if material.owner.device != r.library.device return .Device_Mismatch;
    shader := material.shader;
    if !sh.shader_is_sprite(shader.desc) || !shader.desc.instanced || shader.instanced_vertex.count == 0 {
        return .Not_Instanced_Shader;
    }
    if buf == null || buf.capacity <= 0 return .Instance_Buffer_Required;
    if buf.slots != mat.instance_slot_count(material) return .Instance_Mismatch;
    if texture == null || texture.handle == 0 return .Missing_Sprite_Texture;
    selection: mat.Pass_Selection;
    error := mat.material_select(shader.desc, material.bindings, .Sprite, pass_id, texture, *selection);
    if error != .None return error;
    if selection.count == 0 return .None;
    if !render2d_corner_mesh(r) return .Missing_Device;
    render2d_run_begin(r, material, pass_id, texture, selection, null);
    run := *r.runs[r.runs.count - 1];
    run.buffer = buf;
    run.instance_count = clamp(count, 0, buf.capacity);
    run.transform = r.transform;
    run.storage = false; // 缓冲变体的数值在实例顶点里，不使用 storage 或 Pass 偏移。
    // 顶点阶段换成缓冲变体；片元、参数与贴图与批量变体相同。
    for i: 0..selection.count - 1 {
        group := material.bindings[selection.bindings[i]].schema.name;
        for schema, j: shader.schemas {
            if schema.name == group {
                F.material_stage_set_shader(*r.snapshots[run.snapshot + i].Vertex, shader.instanced_vertex[j]);
            }
        }
    }
    return .None;
}
//@endregion

//@region 记录与合批

render2d_mode_color :: (mode: F.Batcher_Modes) -> F.Color {
    if mode == {
        case .NORMAL; return F.Color.{ 255, 0, 0, 0 };
        case .WASH; return F.Color.{ 0, 255, 0, 0 };
        case .FILL; return F.Color.{ 0, 0, 255, 0 };
    }
    return F.Color.{ 255, 0, 0, 0 };
}

render2d_reset_state :: (r: *Render2D) {
    r.transform = .[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
    r.sampler = F.texture_sampler_make(.NEAREST, .CLAMP);
    r.blend = F.Blend_Mode_Premultiply;
    r.mode = .NORMAL;
    r.mode_color = render2d_mode_color(.NORMAL);
    r.scissor, r.has_scissor = F.Rect_Int.{ 0, 0, 0, 0 }, false;
    if r.transform_stack.data != null r.transform_stack.count = 0;
    if r.sampler_stack.data != null r.sampler_stack.count = 0;
    if r.blend_stack.data != null r.blend_stack.count = 0;
    if r.mode_stack.data != null r.mode_stack.count = 0;
    if r.scissor_stack.data != null r.scissor_stack.count = 0;
}

render2d_reset :: (r: *Render2D) {
    if r.vertices.data != null r.vertices.count = 0;
    if r.runs.data != null r.runs.count = 0;
    if r.instance_values.data != null r.instance_values.count = 0;
    if r.instance_tables.data != null r.instance_tables.count = 0;
    r.snapshot_count = 0;
    render2d_reset_state(r);
}

// 精灵局部 1 像素在变换栈之前的两条轴 (x.x, x.y, y.x, y.y)；没有局部空间的图元用单位轴。
RENDER2D_AXES_IDENTITY: [4] float32 : .[1, 0, 0, 1];

// 记录一个四边形。texture 为 null 表示纯色图元。corners 与 axes 是变换栈之前的坐标与局部轴。
render2d_record :: (r: *Render2D, material: *mat.Material, texture: *F.Texture,
                    corners: [4] F.Vector2, uvs: [4] F.Vector2, colors: [4] F.Color,
                    values: *mat.Instance_Values, pass_id: mat.Pass_Id, axes: [4] float32) -> mat.Draw_Error {
    if r.library == null || r.library.device == null return .Missing_Device;
    m := material;
    if m == null m = r.default_material;
    if m == null || m.owner == null || m.shader == null return .Missing_Material;
    if m.owner.device != r.library.device return .Device_Mismatch;
    last: *Render2D_Run = null;
    if r.runs.count > 0 last = *r.runs[r.runs.count - 1];
    frame_texture := texture;
    mode := F.Color.{ 0, 0, 0, 0 };
    if m.shader.desc.uniforms == .Foster {
        mode = r.mode_color;
    }
    if texture == null {
        if m == r.default_material {
            // Fill 只用顶点色：沿用当前段的帧贴图即可继续合批。
            mode = render2d_mode_color(.FILL);
            if last != null && last.material == m && last.texture != null {
                frame_texture = last.texture;
            } else {
                frame_texture = r.library.white;
            }
        } else {
            frame_texture = r.library.white;
        }
    }
    selection: mat.Pass_Selection;
    error := mat.material_select(m.shader.desc, m.bindings, .Sprite, pass_id, frame_texture, *selection);
    if error != .None return error;
    if selection.count == 0 return .None;
    if !render2d_run_matches(r, last, m, pass_id, frame_texture, selection) {
        render2d_run_begin(r, m, pass_id, frame_texture, selection, values);
        last = *r.runs[r.runs.count - 1];
    }
    if last.storage {
        // 轴也经过变换栈，与顶点位置在同一空间。
        t := r.transform;
        stacked: [4] float32 = .[
            axes[0] * t[0] + axes[1] * t[4], axes[0] * t[1] + axes[1] * t[5],
            axes[2] * t[0] + axes[3] * t[4], axes[2] * t[1] + axes[3] * t[5],
        ];
        offset := render2d_record_instances(r, array_view(r.instance_tables, last.tables, selection.count), values, stacked);
        mode = F.Color.{ cast(u8) offset, cast(u8) (offset >> 8), cast(u8) (offset >> 16), cast(u8) (offset >> 24) };
    }
    for i: 0..3 {
        array_add(*r.vertices, F.Batcher_Vertex.{
            pos = render2d_transform(r, corners[i]),
            tex = uvs[i],
            col = colors[i],
            mode = mode,
        });
    }
    last.quad_count += 1;
    return .None;
}

// 一个精灵的记录：首项是两条轴，随后连续存放各 Pass 的独立数值；顶点保存起点，
// 提交时由顶点 b1 选择该 Pass 的偏移。
render2d_record_instances :: (r: *Render2D, tables: [] mat.Instance_Table, values: *mat.Instance_Values,
                              axes: [4] float32) -> int {
    if r.instance_values.count == 0 array_add(*r.instance_values, .[0.0, 0.0, 0.0, 0.0]);
    offset := r.instance_values.count;
    array_add(*r.instance_values, axes);
    for *table: tables {
        start := r.instance_values.count;
        array_resize(*r.instance_values, start + table.count);
        out := array_view(r.instance_values, start, table.count);
        if values != null {
            mat.instance_table_write(table, array_view(values.numbers, 0, values.numbers.count), values.set, out);
        } else {
            mat.instance_table_write(table, .[], 0, out);
        }
    }
    return offset;
}

// 子图四角（裁剪后的 DrawCoords 减去锚点）经 transform 变换，顺序与 TexCoords 一致。
render2d_frame_corners :: (frame: F.Subtexture, origin: F.Vector2, transform: F.Matrix3x2) -> (corners: [4] F.Vector2) {
    for *corner, i: corners {
        corner.* = F.vector2_transform(frame.DrawCoords[i] - origin, transform);
    }
    return;
}

render2d_transform :: (r: *Render2D, p: F.Vector2) -> F.Vector2 {
    m := r.transform;
    return .{ p.x * m[0] + p.y * m[4] + m[12], p.x * m[1] + p.y * m[5] + m[13] };
}

// 参数 uniform 所在的片元槽：内置 Shader（Foster 布局）在槽 0，.oshader Shader 在槽 1（槽 0 是 Clock 帧块）。
render2d_param_slot :: (shader: sh.Shader_Desc) -> s32 {
    if shader.uniforms == .Foster return 0;
    return 1;
}

// olib 直接用 struct == 比较；Jai 的结构体没有内建 ==，这里逐字段比较。
render2d_scissor_equal :: (a: Render2D_Scissor, b: Render2D_Scissor) -> bool {
    return a.enabled == b.enabled && a.rect == b.rect;
}

render2d_selection_equal :: (a: mat.Pass_Selection, b: mat.Pass_Selection) -> bool {
    if a.count != b.count return false;
    for i: 0..a.count - 1 {
        if a.passes[i] != b.passes[i] || a.bindings[i] != b.bindings[i] return false;
    }
    return true;
}

render2d_run_matches :: (r: *Render2D, run: *Render2D_Run, m: *mat.Material, pass_id: mat.Pass_Id,
                         texture: *F.Texture, selection: mat.Pass_Selection) -> bool {
    // 两次绘制之间 material_set_number / material_set_texture / reload 会递增 revision：参数或贴图快照过期就断批。
    // [Instance] 数值不进参数 uniform，不影响合批。
    if run == null || run.buffer != null || run.quad_count >= RENDER2D_BATCH_QUADS return false;
    if run.material != m || run.revision != m.revision || run.pass_id != pass_id || run.texture != texture return false;
    if run.sampler != r.sampler || run.blend != r.blend return false;
    return render2d_scissor_equal(run.scissor, Render2D_Scissor.{ r.scissor, r.has_scissor }) &&
           render2d_selection_equal(run.selection, selection);
}

render2d_run_begin :: (r: *Render2D, m: *mat.Material, pass_id: mat.Pass_Id, texture: *F.Texture,
                       selection: mat.Pass_Selection, values: *mat.Instance_Values) {
    run := Render2D_Run.{
        material = m,
        revision = m.revision,
        pass_id = pass_id,
        selection = selection,
        snapshot = r.snapshot_count,
        texture = texture,
        sampler = r.sampler,
        blend = r.blend,
        scissor = Render2D_Scissor.{ r.scissor, r.has_scissor },
        quad_start = r.vertices.count / 4,
        tables = r.instance_tables.count,
    };
    slot := render2d_param_slot(m.shader.desc);
    offset: u32 = 0;
    for i: 0..selection.count - 1 {
        p := m.shader.desc.passes[selection.passes[i]];
        binding := m.bindings[selection.bindings[i]];
        run.pass_offsets[i] = offset;
        if m.shader.desc.uniforms == .Olib {
            offset += cast(u32) sh.instance_count(binding.schema);
        }
        array_add(*r.instance_tables, mat.instance_table_make(p, binding));
        if r.snapshot_count == r.snapshots.count {
            array_add(*r.snapshots, F.material_create());
        }
        snapshot := r.snapshots[r.snapshot_count];
        r.snapshot_count += 1;
        F.material_stage_set_shader(*snapshot.Vertex, binding.material.Vertex.shader);
        F.material_stage_set_shader(*snapshot.Fragment, binding.material.Fragment.shader);
        for k: 0..7 F.material_stage_set_uniform(*snapshot.Vertex, cast(s32) k, .[]);
        for k: 0..7 F.material_stage_set_uniform(*snapshot.Fragment, cast(s32) k, .[]);
        uniform, _ := mat.material_pass_values(p, binding, values);
        F.material_stage_set_uniform(*snapshot.Fragment, slot, uniform);
        for k: 0..15 snapshot.Fragment.Samplers[k] = F.Bound_Sampler.{};
        for k: 0..binding.samplers.count - 1 snapshot.Fragment.Samplers[k] = binding.samplers[k];
        if p.sprite_texture != "" {
            index := 0;
            for field: binding.schema.fields {
                if field.kind != .Texture continue;
                if field.id == p.sprite_texture {
                    snapshot.Fragment.Samplers[index] = F.Bound_Sampler.{
                        Tex = texture,
                        Sampler = sh.field_sprite_sampler(field, r.sampler),
                    };
                }
                index += 1;
            }
        }
    }
    run.storage = m.shader.desc.uniforms == .Olib;
    array_add(*r.runs, run);
}

// 上传本帧顶点；索引是固定的四边形图案（0,1,2, 0,2,3），只在四边形数超过已有容量时重建。
render2d_upload :: (r: *Render2D) {
    quads := r.vertices.count / 4;
    if quads > r.index_quads {
        capacity := max(quads, r.index_quads * 2, 1024);
        indices := mat.material_temp_array(u32, capacity * 6);
        for q: 0..capacity - 1 {
            base := cast(u32) (q * 4);
            indices[q * 6 + 0] = base;
            indices[q * 6 + 1] = base + 1;
            indices[q * 6 + 2] = base + 2;
            indices[q * 6 + 3] = base;
            indices[q * 6 + 4] = base + 2;
            indices[q * 6 + 5] = base + 3;
        }
        F.mesh_set_indices(r.mesh, array_view(indices, 0, capacity * 6));
        r.index_quads = capacity;
    }
    F.mesh_set_vertices(r.mesh, array_view(r.vertices, 0, r.vertices.count));
    if r.instance_values.count > 1 {
        if !r.instance_ready {
            r.instance_buffer = F.storage_buffer_create(r.library.device, 16, "render2d instance values");
            r.instance_ready = true;
        }
        F.buffer_upload_slice(r.instance_buffer, array_view(r.instance_values, 0, r.instance_values.count));
    }
}

// 单位四边形的四个角点，缓冲变体用 olib_sprite_vertex 把它展开成屏幕上的矩形。
render2d_corner_mesh :: (r: *Render2D) -> bool {
    if r.corner_ready return true;
    if r.library == null || r.library.device == null return false;
    elements: [1] F.Vertex_Format_Element = .[
        F.Vertex_Format_Element.{ Index = 0, Type = .FLOAT2, Normalized = false },
    ];
    format := F.vertex_format_make(array_view(elements, 0, 1), size_of([2] float32));
    r.corner_mesh = F.mesh_create(r.library.device, format, .THIRTY_TWO, "render2d corners");
    corners: [4][2] float32 = .[.[0, 0], .[1, 0], .[1, 1], .[0, 1]];
    F.mesh_set_vertices(r.corner_mesh, array_view(corners, 0, 4));
    indices: [6] u32 = .[0, 1, 2, 0, 2, 3];
    F.mesh_set_indices(r.corner_mesh, array_view(indices, 0, 6));
    r.corner_ready = true;
    return true;
}
//@endregion

//@region 常驻精灵实例缓冲

// 精灵实例缓冲：调用方持有、常驻显存的 GPU 缓冲，r2d.buffer 一次 Draw 画出几十万到上百万个精灵。
// 库不缓存、不排序、不剔除：调用方决定写入哪些精灵、何时更新、分成几块。
// 使用 instanced 精灵 Shader 的缓冲变体（实例记录 + 角点）；逐个绘制走 Render2D 的批量变体，片元代码相同。

//@region 实例记录 —— 一个精灵的数据

// 一个精灵的数据：2D 变换、局部矩形（已减去锚点）、UV 矩形与 tint。
// 内存布局就是 GPU 记录的前 80 字节（与 hlsl 生成的 OlibInstanceInput 的前 5 个 float4 一致），
// 没有 [Instance] 字段时整块上传，有字段时按块拷贝拼接，不做逐字段打包。
// [Instance] 字段的数值不放在这里：它们的个数由 Shader 决定，由调用方另备一个平铺数组，上传时一并传入
// （sprite_buffer_upload 的 values，用 mat.instance_array_set 写入）。
// 一次 Draw 里所有精灵共用同一张贴图（图集页），贴图在 r2d.buffer 时指定。
Sprite_Item :: struct {
    transform: F.Matrix3x2;
    rect: [4] float32; // 局部 x0, y0, 宽, 高（像素，已减去锚点）
    uv: [4] float32; // u0, v0, 宽, 高
    reserved: [2] float32; // olib 的 `_: [2]f32`（GPU 布局的保留字节，由 sprite_item_make 置零；Jai 没有匿名字段名）
    tint: [4] float32;
}

#assert(size_of(Sprite_Item) == 80);
#assert(offset_of(Sprite_Item, "rect") == 24);
#assert(offset_of(Sprite_Item, "uv") == 40);
#assert(offset_of(Sprite_Item, "tint") == 64);

// 由图集子图构造：保留裁剪后的 DrawCoords / TexCoords；origin 相对于未裁剪原图。
sprite_item_make :: (frame: F.Subtexture, origin: F.Vector2, transform: F.Matrix3x2,
                     tint: [4] float32 = .[1, 1, 1, 1]) -> Sprite_Item {
    top_left := frame.DrawCoords[0] - origin;
    bottom_right := frame.DrawCoords[2] - origin;
    uv0, uv1 := frame.TexCoords[0], frame.TexCoords[2];
    return Sprite_Item.{
        transform = transform,
        rect = .[top_left.x, top_left.y, bottom_right.x - top_left.x, bottom_right.y - top_left.y],
        uv = .[uv0.x, uv0.y, uv1.x - uv0.x, uv1.y - uv0.y],
        tint = tint,
    };
}

// 实例记录在 GPU 上的字节数：5 个 float4（变换、矩形、UV、tint）加每个字段一个 float4。
sprite_stride :: (slots: int) -> int {
    return sh.INSTANCE_FIXED_ATTRIBUTES * 16 + 16 * slots;
}

// 实例缓冲的顶点格式：每个 float4 一个属性。属性编号必须等于 HLSL 的语义号（olib/instance.hlsli
// 的 TEXCOORD6 起），因为 SDL_GPU 的 D3D12 后端按 location 生成 TEXCOORD<location>：
// 编号写 0.. 会和网格的 TEXCOORD0.. 撞车，管线创建直接 E_INVALIDARG。
sprite_instance_format :: (slots: int) -> F.Vertex_Format {
    elements := mat.material_temp_array(F.Vertex_Format_Element, sh.INSTANCE_FIXED_ATTRIBUTES + slots);
    for i: 0..elements.count - 1 {
        elements[i] = F.Vertex_Format_Element.{ Index = cast(s32) (sh.INSTANCE_SEMANTIC_BASE + i),
                                                 Type = .FLOAT4, Normalized = false };
    }
    return F.vertex_format_make(elements, cast(s32) sprite_stride(slots));
}
//@endregion

//@region 缓冲创建与上传

Sprite_Buffer :: struct {
    buffer: *F.Graphics_Buffer;
    slots: int;
    capacity: int;
}

// 为 material 的 instanced Shader 预留 capacity 个精灵的 GPU 空间（实际按 2 的幂向上取整），用 r2d.buffer 绘制。
// 设备与槽数（Shader 的 [Instance] 字段数）都取自材质。返回 "" 表示成功，否则是失败原因。
// 每个精灵 80 + 16×slots 字节，100 万个精灵（1 个字段）约 96 MB。
sprite_buffer_init :: (buf: *Sprite_Buffer, material: *mat.Material, capacity: int, name := "") -> string {
    if material == null || material.owner == null || material.owner.device == null || material.shader == null {
        return "Material is not loaded";
    }
    if !sh.shader_is_sprite(material.shader.desc) || !material.shader.desc.instanced {
        return "Sprite buffers require an Instanced sprite shader";
    }
    slots := mat.instance_slot_count(material);
    if slots < 0 return "Instance field count differs between parameter groups";
    if slots > sh.MAX_INSTANCE_FIELDS return "Too many Instance fields";
    if capacity <= 0 return "Sprite buffer capacity must be positive";
    format := sprite_instance_format(slots);
    buf.* = Sprite_Buffer.{ slots = slots, capacity = capacity };
    buf.buffer = F.vertex_buffer_create(material.owner.device, format, name);
    // olib: foster.VertexBufferReserve(&buf.buffer, capacity)——只预留 GPU 空间，不写入元素。
    // jfoster 没有 Reserve：空数据上传（data == null）只按需重建更大的缓冲，语义相同，随后把 Count 归零。
    F.buffer_upload(buf.buffer, null, cast(s32) capacity, 0);
    buf.buffer.Count = 0;
    return "";
}

sprite_buffer_dispose :: (buf: *Sprite_Buffer) {
    if buf.capacity > 0 {
        render2d_buffer_release(buf.buffer);
    }
    buf.* = Sprite_Buffer.{};
}

// 一次最多拼接上传的精灵数：限制临时内存；更大的批量分段写入。
SPRITE_UPLOAD_CHUNK :: 262144;

// 把 items 写到缓冲第 first 个精灵起的位置（部分更新只需传变化的区间）。
// values 是这批精灵的 [Instance] 数值：平铺数组，每个精灵连续 buf.slots 个 float4，长度须为 len(items) × slots
// （用 mat.instance_array_set 写入）；slots 为 0 或传 null（全部为 0）时可省略。
// 没有 [Instance] 字段时 items 整块拷贝到 GPU；有字段时按精灵拼接 items 与 values 两块内存。
// 超出容量或 values 长度不对返回 false 且不写入。帧内上传会占用设备暂存区，百万级请在加载时一次性上传。
sprite_buffer_upload :: (buf: *Sprite_Buffer, items: [] Sprite_Item, first := 0, values: [][4] float32 = .[]) -> bool {
    if buf.capacity <= 0 || first < 0 || first + items.count > buf.capacity return false;
    slots := buf.slots;
    if values.data != null && values.count != items.count * slots return false;
    if items.count == 0 return true;
    if slots == 0 {
        // 与 GPU 记录同一布局，直接上传。
        F.buffer_upload(buf.buffer, cast(*void) items.data, cast(s32) items.count, cast(s32) first);
        return true;
    }
    stride := sprite_stride(slots);
    scratch := atlas_alloc_array(u8, min(items.count, SPRITE_UPLOAD_CHUNK) * stride);
    defer if scratch.data != null array_free(scratch);
    value_bytes := 16 * slots;
    start := 0;
    while start < items.count {
        chunk := min(start + SPRITE_UPLOAD_CHUNK, items.count) - start;
        for i: 0..chunk - 1 {
            record := scratch.data + i * stride;
            memcpy(record, *items[start + i], size_of(Sprite_Item));
            if values.data != null {
                memcpy(record + size_of(Sprite_Item), values.data + (start + i) * slots, value_bytes);
            } else {
                memset(record + size_of(Sprite_Item), 0, value_bytes);
            }
        }
        F.buffer_upload(buf.buffer, cast(*void) scratch.data, cast(s32) chunk, cast(s32) (first + start));
        start += SPRITE_UPLOAD_CHUNK;
    }
    return true;
}
//@endregion
//@endregion
