// rendering3d:render3d —— Render3D：3D 唯一的绘制入口（记录后按视图提交）与常驻模型实例缓冲。
// 一比一移植自 olib kit/rendering/3d/render3d.odin。
//
// 记录拥有 CPU 数据与材质绑定快照；GPU 资源借用至 clear/dispose。
// submit 只重建当前视图的队列，不消耗记录，也不清理目标附件。
//
// Jai 侧差异（逐条对应 olib 的写法；记录顺序、Pass 选择、快照去重、排序键与字节布局不变）：
//   | olib (Odin)                                     | JaiLib (Jai)                                             |
//   | ----------------------------------------------- | -------------------------------------------------------- |
//   | `foster.DrawableTarget`                         | F.Drawable_Target（jfoster 的 kind 标签结构）              |
//   | `.WidthInPixels / .HeightInPixels`              | F.drawable_target_width_in_pixels / _height_in_pixels     |
//   | `Maybe(bool)`（view.draw_debug）                 | `draw_debug: bool` + `has_draw_debug: bool`（Jai 没有       |
//   |                                                 | Maybe；has_draw_debug = false 等价于 nil）                 |
//   | `[dynamic]T` + append / resize / len            | `[..] T` + array_add / array_resize / .count             |
//   | `map[u64]int` / `map[^mat.Material]R`           | HASH.Table（jfoster/stdlib 的 Hash_Table；缺键判 found）    |
//   | `builtin.clear(&x)`（保留容量）                   | render3d_array_clear（只把 count 归零）                    |
//   | `copy(dst, src)` / `mem.copy` / `mem.zero`      | memcpy / memset（指针 + 字节数）                            |
//   | `foster.Material`（值，MaterialInitWithShaders）   | *F.Material（F.material_create / material_destroy）        |
//   | `foster.MaterialStageSetShader(&s, x)`          | F.material_stage_set_shader(*s, x)                       |
//   | `foster.MaterialStageSetUniformBuffer(&s, b, i)` | F.material_stage_set_uniform(*s, i, b)                  |
//   | `snapshot.Fragment.UniformBuffers[i][:]`        | F.uniform_buffer_get(*snapshot.Fragment.UniformBuffers[i])|
//   | `sampler.Texture` / `.Sampler`                  | F.Bound_Sampler.Tex / .Sampler                          |
//   | `x.Resource == nil`                             | threed_buffer_ready / mat.material_program_ready 的判据     |
//   |                                                 |（handle != 0 且未释放）                                   |
//   | `foster.DrawCommandFromMesh(&cmd, …)`           | cmd = F.draw_command_from_mesh(target, mesh, material)   |
//   | `command.VertexBuffers` 的 append                | VertexBuffers[1] + VertexBufferCount = 2                 |
//   | `command.InstanceOffset = first`                | jfoster 的 Draw_Command 没有 InstanceOffset（SDL 后端的   |
//   |                                                 | first_instance 固定为 0）：自动实例化批次改用               |
//   |                                                 | render3d_instance_slice 把本批实例重传到缓冲起点，绘制区间  |
//   |                                                 | [0, count) 等价于 olib 的 [first, first + count)          |
//   | `foster.BlendModeDisabled`                      | mat.BLEND_MODE_DISABLED（(ONE, ZERO)，jfoster 无 Disabled）|
//   | `.Back / .Less`（foster 的枚举）                  | .BACK / .LESS（jfoster 全大写）                            |
//   | `World.Matrix4`                                 | W.Matrix4（本包具名导入 kit/world）                        |
//   | `world.matrix4_transform_point(...) or_return`  | 显式判 ok 后返回（Jai 没有 or_return）                     |
//   | `transform.c3 == {0,0,0,1}`                     | W.vec4_equal(transform.c3, W.vec4(0, 0, 0, 1))           |
//   | `math.is_nan / math.is_inf / math.abs`          | JM.isnan / JM.isinf / JM.abs                             |
//   | `for field, i in x`（左值引用）                    | `for *field: x`（要改）或 `for field, i: x`（只读）         |
//   | `for count, slots in counts`                    | for count, slots: counts                                 |
//   | `Model_Item{transform, {1,1,1,1}}`              | Model_Item.{ world = …, tint = .[1, 1, 1, 1] }            |
//   | `make([]T, n, context.temp_allocator)`          | 栈上定长数组 + array_view（元素数有 MAX_* 上界时）            |
//   | `context.allocator = context.temp_allocator`    | 不需要：jfoster 的命令结构不含动态数组，Draw 之间不再分配      |
//   | `foster.VertexBufferReserve(&b, n)`             | F.buffer_upload(b, null, n, 0)（空数据只重建/扩容 GPU 缓冲） |
//   | `foster.VertexBufferUpload(&b, p, n[, first])`  | F.buffer_upload(b, p, n, first)                          |
//   | `instance_table_write(t, …)`（`^Instance_Table`）| mat.instance_table_write(t, …)（t 已是指针，不再取址）      |
//   | `(1 << u32(slots)) - 1`                         | mat.MATERIAL_PROBE_BIT(slots) - 1                        |
//   | `@(private)`                                    | 去掉标注，内部过程加 render3d_ / model_ 前缀                |
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）。

//@region 类型

View :: struct {
    target: F.Drawable_Target;
    view_projection: W.Matrix4;
    // 必填（如 camera3d_view）：排序深度、调试线朝向与材质的 CameraPosition 使用它；零矩阵 submit 返回错误
    view_matrix: W.Matrix4;
    // 未指定时只在画全部 Pass（pass_id 为空）的提交里画；分阶段多次提交时在需要的那一次设为 true。
    // olib 的 draw_debug 是 Maybe(bool)：has_draw_debug 为 false 就是那个 nil。
    draw_debug: bool;
    has_draw_debug: bool;
    time, delta_time: float32;
    frame: u64;
    // 游戏按 std140 打包的视图级数据（太阳方向、雾色等），只在 submit 期间借用；
    // Model Pass 从顶点 b1 / 片元 b2 读取，超过 mat.VIEW_GLOBALS_SIZE 时 submit 返回错误。
    globals: [] u8;
}

Render3D :: struct {
    library: *mat.Material_Library;
    draw_calls, instances: int; // 最近一次 submit 的模型 Draw / 实例数（按 Pass 累计）
    // 以下由渲染器维护，clear 保留容量。
    records: [..] Render3D_Record;
    sources: [..] Render3D_Source;
    source_heads: HASH.Table(u64, int);
    snapshots: [..] *F.Material;
    snapshot_count: int;
    queue: Render_Queue(int);
    values: [..][4] float32;
    // 记录时复制的模型空间蒙皮矩阵，活到 clear/dispose；不同记录不共享可变姿态。
    joints: [..] W.Matrix4;

    // 每个材质最近一次准备的结果（选择、快照来源与各 Pass 的实例值表），revision 与 Shader 不变时复用。
    prepared: HASH.Table(*mat.Material, Render3D_Prepared);
    tables: [..] mat.Instance_Table;
    batches: [..] Render3D_Batch;
    upload: [..] u8;
    buffers: [sh.MAX_INSTANCE_FIELDS + 1] Model_Buffer; // 自动实例化的临时缓冲，按 [Instance] 字段数各一个
    debug: Debug_Draw_3D; // 线宽与深度开关；GPU 资源延迟到首次提交线段时创建
}

// 排序后队列中的一段连续 Draw。自动实例化时，第 k 个所选 Pass 的实例从临时缓冲的
// first + k × (end - start) 开始；每次 submit 先一次上传全部批次，再按偏移逐批绘制。
Render3D_Batch :: struct {
    start, end: int;
    first: int;
}

Render3D_Record :: struct {
    mesh: *F.Mesh;
    source: int;
    item: Model_Item;
    bounds: DA.Dasset_Bounds; // 已转换到世界空间
    has_bounds: bool;
    values: int;
    buffer: *Model_Buffer;
    joint_start, joint_count: int;

    count: int;
}

// 一个材质在当前记录集里的准备结果。材质只经 material_set_number / set_texture / reload 修改，
// 这些都会递增 revision，所以 revision 与 Shader 指针不变时选择、参数快照和默认实例值都仍然有效。
Render3D_Prepared :: struct {
    revision: u64;
    shader: *mat.Material_Shader;
    source: int;
    tables: int; // r.tables 中的起点：各所选 Pass 依次一张实例值表
}

// 记录时的 Shader 与槽数一并保存：之后 material_reload 换了 Shader 或参数组，已记录的快照仍按原布局绘制。
Render3D_Source :: struct {
    material: *mat.Material;
    shader: *mat.Material_Shader;
    slots: int;
    selection: mat.Pass_Selection;
    snapshot, next: int;
    // 本次 submit 的选择，不改记录的完整 selection。
    selected: [sh.MAX_PASSES] int;
    count: int;
    transparent: bool;
    checked: bool; // 本次 submit 的预检已查过这个来源的材质与快照
}
//@endregion

//@region 生命周期

init :: (r: *Render3D, library: *mat.Material_Library) -> string {
    if library == null || library.device == null return "Missing graphics device";
    r.* = Render3D.{ library = library };
    r.debug.thickness = DEBUG_DRAW_DEFAULT_THICKNESS;
    r.debug.depth_test_enabled = true;
    return "";
}

dispose :: (r: *Render3D) {
    for snapshot: r.snapshots {
        if snapshot != null F.material_destroy(snapshot); // olib: foster.MaterialDispose
    }
    if r.snapshots.data != null array_free(r.snapshots);
    if r.records.data != null array_free(r.records);
    if r.sources.data != null array_free(r.sources);
    HASH.deinit(*r.source_heads);
    queue_dispose(*r.queue);
    if r.joints.data != null array_free(r.joints);

    if r.values.data != null array_free(r.values);
    HASH.deinit(*r.prepared);
    if r.tables.data != null array_free(r.tables);
    if r.batches.data != null array_free(r.batches);
    if r.upload.data != null array_free(r.upload);
    for *buffer: r.buffers model_buffer_dispose(buffer);
    debug_draw_dispose(*r.debug);
    r.* = Render3D.{};
}

// olib: builtin.clear(&x) —— 只把长度归零，容量与已分配的缓冲保留。
// 泛型参数必须在形参类型里被约束（写成 `($T: Type, array: *[..] T)` 时，jacket 无法从
// `*r.records` 这样的字段取址推断 T）。
render3d_array_clear :: (array: *[..] $T) {
    if array.data != null array.count = 0;
}

clear :: (r: *Render3D) {
    render3d_array_clear(*r.records);
    render3d_array_clear(*r.sources);
    HASH.table_reset(*r.source_heads);
    r.snapshot_count = 0;
    queue_clear(*r.queue);
    render3d_array_clear(*r.joints);

    render3d_array_clear(*r.values);
    HASH.table_reset(*r.prepared);
    render3d_array_clear(*r.tables);
    render3d_array_clear(*r.batches);
    debug_draw_clear(*r.debug);
}
//@endregion

//@region 记录入口与材质快照

model :: (r: *Render3D, mesh: *F.Mesh, material: *mat.Material, transform: W.Matrix4,
          bounds: *DA.Dasset_Bounds = null, values: *mat.Instance_Values = null) -> mat.Draw_Error {
    item := Model_Item.{ world = transform, tint = .[1, 1, 1, 1] };
    items: [1] Model_Item = .[item];
    return render3d_record(r, mesh, material, items, bounds, .[], values);
}

// palette 为模型空间的最终蒙皮矩阵（如 animation.compute_palette），在调用内复制。
// bounds 必须覆盖当前姿态（不是绑定姿态）；nil 不做包围盒剔除。暂不支持蒙皮实例化。
skinned_model :: (r: *Render3D, mesh: *F.Mesh, material: *mat.Material, transform: W.Matrix4,
                  palette: [] W.Matrix4, bounds: *DA.Dasset_Bounds = null,
                  values: *mat.Instance_Values = null) -> mat.Draw_Error {
    if palette.count == 0 || palette.count > MAX_JOINTS return .Invalid_Joint_Palette;
    item := Model_Item.{ world = transform, tint = .[1, 1, 1, 1] };
    items: [1] Model_Item = .[item];
    return render3d_record(r, mesh, material, items, bounds, .[], values, palette);
}

// items 和 values 都在调用内复制；nil values 沿用材质默认值。
models :: (r: *Render3D, mesh: *F.Mesh, material: *mat.Material, items: [] Model_Item,
           bounds: *DA.Dasset_Bounds = null, values: [][4] float32 = .[]) -> mat.Draw_Error {
    return render3d_record(r, mesh, material, items, bounds, values, null);
}

render3d_validate :: (r: *Render3D, mesh: *F.Mesh, m: *mat.Material, skinned := false) -> mat.Draw_Error {
    error := render3d_validate_material(r, m);
    if error != .None return error;
    error = render3d_validate_mesh(r, mesh, skinned);
    if error != .None return error;
    if m.shader.desc.skinned != skinned || (skinned &&
        (m.shader.desc.instanced || m.shader.desc.uniforms != .Olib)) {
        return .Skin_Mismatch;
    }
    return .None;
}

render3d_validate_material :: (r: *Render3D, m: *mat.Material) -> mat.Draw_Error {
    if r.library == null || r.library.device == null return .Missing_Device;
    if m == null || m.owner == null || m.shader == null return .Missing_Material;
    if m.owner.device != r.library.device return .Device_Mismatch;
    if !sh.shader_is_material(m.shader.desc) return .Not_Material_Shader;
    return .None;
}

// olib 的 `mesh.VertexData.Base.Resource == nil`：jfoster 的顶点缓冲是 *F.Graphics_Buffer。
threed_buffer_ready :: (buffer: *F.Graphics_Buffer) -> bool {
    return buffer != null && buffer.handle != 0 && !buffer.is_disposed;
}

render3d_validate_mesh :: (r: *Render3D, mesh: *F.Mesh, skinned := false) -> mat.Draw_Error {
    if mesh == null return .Missing_Mesh;
    if mesh.device != r.library.device return .Device_Mismatch;
    if mesh.VertexBuffer == null return .Unsupported_Mesh; // 没有顶点缓冲就没有格式可比
    stride: s32 = DA.DASSET_VERTEX_STRIDE_STATIC;
    if skinned stride = DA.DASSET_VERTEX_STRIDE_SKIN;
    if mesh.VertexBuffer.Format.Stride != stride return .Unsupported_Mesh;
    return .None;
}

render3d_record :: (r: *Render3D, mesh: *F.Mesh, m: *mat.Material, items: [] Model_Item,
                    bounds: *DA.Dasset_Bounds, flat: [][4] float32, overrides: *mat.Instance_Values,
                    palette: [] W.Matrix4 = .[]) -> mat.Draw_Error {
    error := render3d_validate(r, mesh, m, palette.count > 0);
    if error != .None return error;
    prepared, prepared_error := render3d_prepared(r, m);
    if prepared_error != .None return prepared_error;
    source := *r.sources[prepared.source];
    slots, selection := source.slots, source.selection;
    if flat.data != null && flat.count != items.count * slots return .Instance_Mismatch;
    joint_start := r.joints.count;
    array_add(*r.joints, ..palette);
    for item, item_index: items {
        record := Render3D_Record.{ mesh = mesh, source = prepared.source, item = item,
                                   values = r.values.count, count = 1,
                                   joint_start = joint_start, joint_count = palette.count };
        if bounds != null {
            record.bounds, record.has_bounds = render3d_world_bounds(bounds.*, item.world);
        }
        array_add(*r.records, record);
        if slots == 0 continue;
        // 按准备好的表逐 Pass 写实例值：平铺数组每个槽位都算覆盖，nil 用材质值。
        start := r.values.count;
        array_resize(*r.values, start + selection.count * slots);
        for i: 0..selection.count - 1 {
            table := *r.tables[prepared.tables + i];
            out := array_view(r.values, start + i * slots, slots);
            if flat.data != null {
                mat.instance_table_write(table, array_view(flat, item_index * slots, slots),
                                         mat.MATERIAL_PROBE_BIT(slots) - 1, out);
            } else if overrides != null {
                mat.instance_table_write(table, array_view(overrides.numbers, 0, sh.MAX_INSTANCE_FIELDS),
                                         overrides.set, out);
            } else {
                mat.instance_table_write(table, .[], 0, out);
            }
        }
    }
    return .None;
}

// olib 的 `source.selection != selection`（Odin 的结构体逐字段 ==）：Jai 要显式写。
render3d_selection_equal :: (a: mat.Pass_Selection, b: mat.Pass_Selection) -> bool {
    if a.count != b.count return false;
    for i: 0..sh.MAX_PASSES - 1 {
        if a.passes[i] != b.passes[i] || a.bindings[i] != b.bindings[i] return false;
    }
    return true;
}

// olib 的 `sampler != snapshot.Fragment.Samplers[j]`（foster.BoundSampler 的 ==）。
// jfoster 的 operator == 是模块作用域的，这里逐字段比（语义与它逐字节相同）。
render3d_sampler_equal :: (a: F.Bound_Sampler, b: F.Bound_Sampler) -> bool {
    return a.Tex == b.Tex &&
           a.Sampler.Filter == b.Sampler.Filter &&
           a.Sampler.WrapX == b.Sampler.WrapX &&
           a.Sampler.WrapY == b.Sampler.WrapY;
}

// 取材质的准备结果；revision 或 Shader 变了（含 reload）就重新选择 Pass、打包参数并查找快照来源。
// 实例覆盖只影响 [Instance] 字段，不进参数 uniform，因此同一准备结果对所有覆盖都适用。
render3d_prepared :: (r: *Render3D, m: *mat.Material) -> (Render3D_Prepared, mat.Draw_Error) {
    found, cached := HASH.table_find(*r.prepared, m);
    if found && cached.revision == m.revision && cached.shader == m.shader {
        return cached, .None;
    }
    slots := mat.instance_slot_count(m);
    if slots < 0 || slots > sh.MAX_INSTANCE_FIELDS return Render3D_Prepared.{}, .Instance_Mismatch;
    selection: mat.Pass_Selection;
    error := mat.material_select(m.shader.desc, m.bindings, .Model, "", null, *selection);
    if error != .None return Render3D_Prepared.{}, error;
    prepared := Render3D_Prepared.{ revision = m.revision, shader = m.shader, tables = r.tables.count };
    uniforms: [sh.MAX_PASSES][] u8;
    for i: 0..selection.count - 1 {
        p := m.shader.desc.passes[selection.passes[i]];
        binding := m.bindings[selection.bindings[i]];
        uniform, _ := mat.material_pass_values(p, binding, null);
        uniforms[i] = uniform;
        array_add(*r.tables, mat.instance_table_make(p, binding));
    }
    prepared.source = render3d_source(r, m, selection, array_view(uniforms, 0, selection.count));
    HASH.table_set(*r.prepared, m, prepared);
    return prepared, .None;
}

// 进阶：bounds 是整块实例的世界包围盒；不读回、重排或上传常驻实例。
buffer :: (r: *Render3D, mesh: *F.Mesh, material: *mat.Material, buf: *Model_Buffer, count: int,
           bounds: *DA.Dasset_Bounds = null) -> mat.Draw_Error {
    error := render3d_validate(r, mesh, material);
    if error != .None return error;
    if !material.shader.desc.instanced return .Not_Instanced_Shader;
    if buf == null || buf.capacity <= 0 return .Instance_Buffer_Required;
    if buf.buffer == null || buf.buffer.device != r.library.device return .Device_Mismatch;
    if buf.slots != mat.instance_slot_count(material) || count < 0 || count > buf.capacity {
        return .Instance_Mismatch;
    }
    prepared, prepared_error := render3d_prepared(r, material);
    if prepared_error != .None return prepared_error;
    if count == 0 return .None;
    record := Render3D_Record.{ mesh = mesh, source = prepared.source, buffer = buf, count = count,
                               item = Model_Item.{ world = W.MATRIX4_IDENTITY, tint = .[1, 1, 1, 1] } };
    if bounds != null {
        record.bounds = bounds.*;
        record.has_bounds = true;
    }
    array_add(*r.records, record);
    return .None;
}

// 同一材质、相同 uniform 与采样绑定共用快照；实例数值不作为快照键。
// 哈希冲突再逐字段比较，不依赖指针所指的可变材质值。
render3d_source :: (r: *Render3D, m: *mat.Material, selection: mat.Pass_Selection,
                    uniforms: [][] u8) -> int {
    hash := cast(u64) m; // olib: u64(uintptr(m))
    for uniform: uniforms {
        for byte: uniform {
            hash = (hash ^ cast(u64) byte) * 1099511628211; // olib 的 `~` 是 XOR，Jai 的 XOR 是 `^`
        }
    }
    slot: s32 = 0;
    if m.shader.desc.uniforms != .Foster slot = 1;
    head := -1;
    found_head, stored_head := HASH.table_find(*r.source_heads, hash);
    if found_head head = stored_head - 1;
    index := head;
    while index >= 0 {
        source := *r.sources[index];
        if source.material == m && source.shader == m.shader && render3d_selection_equal(source.selection, selection) {
            matches := true;
            for i: 0..selection.count - 1 {
                if !matches break;
                binding := m.bindings[selection.bindings[i]];
                snapshot := r.snapshots[source.snapshot + i];
                current := F.uniform_buffer_get(*snapshot.Fragment.UniformBuffers[slot]);
                if current.count != uniforms[i].count ||
                   (current.count > 0 && memcmp(current.data, uniforms[i].data, current.count) != 0) ||
                   snapshot.Vertex.shader != binding.material.Vertex.shader ||
                   snapshot.Fragment.shader != binding.material.Fragment.shader {
                    matches = false;
                    break;
                }
                for sampler, j: binding.samplers {
                    if !render3d_sampler_equal(sampler, snapshot.Fragment.Samplers[j]) matches = false;
                }
            }
            if matches return index;
        }
        index = source.next;
    }
    index = r.sources.count;
    array_add(*r.sources, Render3D_Source.{ material = m, shader = m.shader,
                                            slots = mat.instance_slot_count(m), selection = selection,
                                            snapshot = r.snapshot_count, next = head });
    HASH.table_set(*r.source_heads, hash, index + 1);
    for i: 0..selection.count - 1 {
        if r.snapshot_count == r.snapshots.count {
            array_add(*r.snapshots, F.material_create(null, null)); // olib: MaterialInitWithShaders(nil, nil)
        }
        snapshot := r.snapshots[r.snapshot_count];
        r.snapshot_count += 1;
        binding := m.bindings[selection.bindings[i]];
        F.material_stage_set_shader(*snapshot.Vertex, binding.material.Vertex.shader);
        F.material_stage_set_shader(*snapshot.Fragment, binding.material.Fragment.shader);
        F.material_stage_set_uniform(*snapshot.Fragment, slot, uniforms[i]);
        for j: 0..15 snapshot.Fragment.Samplers[j] = F.Bound_Sampler.{}; // olib: Samplers = {}
        for sampler, j: binding.samplers snapshot.Fragment.Samplers[j] = sampler;
    }
    return index;
}
//@endregion

//@region 包围盒与当前视图队列

render3d_world_bounds :: (bounds: DA.Dasset_Bounds, transform: W.Matrix4) -> (result: DA.Dasset_Bounds, valid: bool) {
    if W.vec4_equal(transform.c3, W.vec4(0, 0, 0, 1)) {
        // 仿射矩阵：中心照常变换，半长按各输出分量系数的绝对值累加，与 8 个角点的外包盒相同。
        center: [3] float32 = .[
            (bounds.min[0] + bounds.max[0]) * 0.5,
            (bounds.min[1] + bounds.max[1]) * 0.5,
            (bounds.min[2] + bounds.max[2]) * 0.5,
        ];
        extent: [3] float32 = .[
            (bounds.max[0] - bounds.min[0]) * 0.5,
            (bounds.max[1] - bounds.min[1]) * 0.5,
            (bounds.max[2] - bounds.min[2]) * 0.5,
        ];
        for i: 0..2 extent[i] = JM.abs(extent[i]); // 反向的盒与角点算法一致
        axes: [3] W.Vec4 = .[transform.c0, transform.c1, transform.c2];
        for axis, j: axes {
            mid := center[0] * axis[0] + center[1] * axis[1] + center[2] * axis[2] + axis[3];
            half := extent[0] * JM.abs(axis[0]) + extent[1] * JM.abs(axis[1]) + extent[2] * JM.abs(axis[2]);
            if JM.isnan(mid) || JM.isinf(mid) || JM.isnan(half) || JM.isinf(half) {
                return DA.Dasset_Bounds.{}, false;
            }
            result.min[j] = mid - half;
            result.max[j] = mid + half;
        }
        return result, true;
    }
    corners := aabb_corners(bounds);
    for corner, i: corners {
        point, ok := W.matrix4_transform_point(transform, W.Vec3.{ corner[0], corner[1], corner[2] });
        if !ok return DA.Dasset_Bounds.{}, false; // 非仿射或无效盒保守保留
        values: [3] float32 = .[point.x, point.y, point.z];
        for value: values {
            if JM.isnan(value) || JM.isinf(value) return DA.Dasset_Bounds.{}, false;
        }
        if i == 0 {
            result.min = values;
            result.max = values;
        } else {
            for axis: 0..2 {
                result.min[axis] = min(result.min[axis], values[axis]);
                result.max[axis] = max(result.max[axis], values[axis]);
            }
        }
    }
    return result, true;
}

// 每次从完整记录生成可见队列；Pass 是否存在在剔除之前判断。
render3d_prepare :: (r: *Render3D, view: View, pass_id: mat.Pass_Id) -> mat.Draw_Error {
    queue_clear(*r.queue);
    found := pass_id == "" || r.records.count == 0;
    for *source: r.sources {
        source.count = 0;
        source.transparent = false;
        source.checked = false;
        shader := source.shader.desc;
        for p: shader.passes {
            if p.id == pass_id found = true;
        }
        for i: 0..source.selection.count - 1 {
            p := shader.passes[source.selection.passes[i]];
            if pass_id != "" && p.id != pass_id continue;
            source.selected[source.count] = i;
            source.count += 1;
            source.transparent = source.transparent ||
                (p.state.blend != .Default && p.state.blend != .Opaque);
        }
    }
    if !found return .Unknown_Pass;
    frustum := W.frustum_from_view_projection(view.view_projection);
    view_matrix := view.view_matrix;
    for record, i: r.records {
        source := *r.sources[record.source];
        if source.count == 0 continue;
        if record.has_bounds && !W.frustum_intersects_aabb(frustum, render3d_vec3(record.bounds.min),
                                                          render3d_vec3(record.bounds.max)) {
            continue;
        }
        position: [3] float32 = .[record.item.world.c0[3], record.item.world.c1[3], record.item.world.c2[3]];
        if record.has_bounds {
            position = .[
                (record.bounds.min[0] + record.bounds.max[0]) * 0.5,
                (record.bounds.min[1] + record.bounds.max[1]) * 0.5,
                (record.bounds.min[2] + record.bounds.max[2]) * 0.5,
            ];
        }
        p := W.matrix4_transform_vec4(view_matrix, W.vec4(position[0], position[1], position[2], 1));
        depth: float32 = 0;
        if JM.abs(p[3]) > 1.0e-8 depth = -p[2] / p[3];
        if JM.isnan(depth) || JM.isinf(depth) depth = 0;
        queue_submit(*r.queue, i, depth, source.transparent, record.source);
    }
    queue_sort(*r.queue, grouped = true);
    return .None;
}

render3d_vec3 :: (v: [3] float32) -> W.Vec3 {
    return W.Vec3.{ v[0], v[1], v[2] };
}
//@endregion

//@region 提交与实例上传

submit :: (r: *Render3D, view: View, pass_id: mat.Pass_Id = "") -> mat.Draw_Error {
    r.draw_calls = 0;
    r.instances = 0;
    // 分阶段提交（指定 pass_id）默认不画调试线，避免多次提交重复叠加或画进阴影图。
    draw_debug := pass_id == "";
    if view.has_draw_debug draw_debug = view.draw_debug;
    if r.records.count == 0 && (!draw_debug || r.debug.vertices.count == 0) return .None;
    if r.library == null || r.library.device == null return .Missing_Device;
    if F.drawable_target_width_in_pixels(view.target) <= 0 ||
       F.drawable_target_height_in_pixels(view.target) <= 0 return .Invalid_Target;
    // 零矩阵不是有效视矩阵；不悄悄当成单位矩阵，否则透明排序、调试线朝向与 CameraPosition 会无声地出错。
    if W.matrix4_equal(view.view_matrix, W.Matrix4.{}) return .Missing_View_Matrix;
    globals: [mat.VIEW_GLOBALS_SIZE] u8;
    if !mat.view_globals_pack(*globals, view.globals) return .View_Globals_Too_Large;
    error := render3d_prepare(r, view, pass_id);
    if error != .None return error;
    // 完整预检后再发 Draw；错误保留所有记录。材质与快照每个来源查一次，网格在相邻记录换网格时查。
    last_mesh: *F.Mesh = null;
    for item: r.queue.items {
        record := *r.records[item.payload];
        source := *r.sources[record.source];
        if source.shader.desc.skinned != (record.joint_count > 0) return .Skin_Mismatch;
        if record.mesh != last_mesh {
            error = render3d_validate_mesh(r, record.mesh, record.joint_count > 0);
            if error != .None return error;
            if !threed_buffer_ready(record.mesh.VertexBuffer) return .Missing_Mesh;
            last_mesh = record.mesh;
        }
        if record.buffer != null {
            buf := record.buffer;
            if !threed_buffer_ready(buf.buffer) || buf.capacity < record.count return .Instance_Buffer_Required;
            if buf.buffer.device != r.library.device return .Device_Mismatch;
            if buf.slots != source.slots return .Instance_Mismatch;
        } else if source.shader.desc.instanced && !render3d_instance_buffer(r, source.slots) {
            return .Instance_Buffer_Required; // 临时实例缓冲创建失败
        }
        if source.checked continue;
        source.checked = true;
        error = render3d_validate_material(r, source.material);
        if error != .None return error;
        for k: 0..source.count - 1 {
            i := source.selected[k];
            snapshot := r.snapshots[source.snapshot + i];
            if !mat.material_program_ready(snapshot) return .Invalid_Binding;
            for sampler: snapshot.Fragment.Samplers {
                if sampler.Tex != null && !threed_texture_ready(sampler.Tex) return .Invalid_Binding;
            }
        }
    }
    if draw_debug && r.debug.vertices.count > 0 && !debug_draw_prepare(*r.debug, r.library.device) {
        return .Invalid_Binding;
    }
    // 发 Draw 之前一次上传全部自动实例化数据（每种槽数一个缓冲），绘制期间不再因上传打断渲染通道。
    counts := render3d_plan(r);
    bases := render3d_pack(r, counts);
    for count, slots: counts {
        if count == 0 continue;
        buf := *r.buffers[slots]; // 预检阶段已创建
        if buf.capacity < count {
            buf.capacity = max(count, buf.capacity * 2);
            F.buffer_upload(buf.buffer, null, cast(s32) buf.capacity, 0); // olib: VertexBufferReserve
        }
        F.buffer_upload(buf.buffer, cast(*void) (r.upload.data + bases[slots]), cast(s32) count, 0);
    }
    camera := camera_position(view.view_matrix);
    // 视图块整次提交相同：每个用到的快照只设一次，不逐 Draw 复制 1 KB。
    for *source: r.sources {
        if source.count == 0 || source.shader.desc.uniforms != .Olib continue;
        for k: 0..source.count - 1 {
            i := source.selected[k];
            snapshot := r.snapshots[source.snapshot + i];
            F.material_stage_set_uniform(*snapshot.Vertex, mat.MODEL_VIEW_VERTEX_SLOT, globals);
            F.material_stage_set_uniform(*snapshot.Fragment, mat.MODEL_VIEW_FRAGMENT_SLOT, globals);
        }
    }
    for batch: r.batches {
        record := *r.records[r.queue.items[batch.start].payload];
        source := *r.sources[record.source];
        n := batch.end - batch.start;
        for k: 0..source.count - 1 {
            pass := source.selected[k];
            buf, count, first := record.buffer, record.count, 0;
            if buf == null && source.shader.desc.instanced {
                buf = *r.buffers[source.slots];
                count = n;
                first = batch.first + k * n;
            }
            if buf != null && first > 0 {
                render3d_instance_slice(r, buf, bases[source.slots], first, count);
            }
            render3d_draw(r, record, source, pass, view, camera, buf, count, first);
        }
    }
    if draw_debug && r.debug.vertices.count > 0 debug_draw_submit(*r.debug, view);
    return .None;
}

// olib 的 `sampler.Texture.Resource == nil`：jfoster 的贴图是 *F.Texture。
threed_texture_ready :: (texture: *F.Texture) -> bool {
    return texture != null && texture.handle != 0;
}

// 只合并排序后相邻项；透明多 Pass 保持每对象的完整 Pass 顺序。
render3d_batch_end :: (r: *Render3D, start: int) -> int {
    a := *r.records[r.queue.items[start].payload];
    source := *r.sources[a.source];
    if a.buffer != null || !source.shader.desc.instanced ||
       (source.transparent && source.count > 1) {
        return start + 1;
    }
    end := start + 1;
    while end < r.queue.items.count {
        b := *r.records[r.queue.items[end].payload];
        if b.mesh != a.mesh || b.source != a.source || b.buffer != null break;
        end += 1;
    }
    return end;
}

// 把排序后的队列切成批次；自动实例化批次按槽数排位，返回各槽数需要的实例总数（每个所选 Pass 一份）。
// 只读记录与队列，不碰 GPU。
render3d_plan :: (r: *Render3D) -> (counts: [sh.MAX_INSTANCE_FIELDS + 1] int) {
    render3d_array_clear(*r.batches);
    start := 0;
    while start < r.queue.items.count {
        end := render3d_batch_end(r, start);
        batch := Render3D_Batch.{ start = start, end = end };
        record := *r.records[r.queue.items[start].payload];
        source := *r.sources[record.source];
        if record.buffer == null && source.shader.desc.instanced {
            batch.first = counts[source.slots];
            counts[source.slots] += (end - start) * source.count;
        }
        array_add(*r.batches, batch);
        start = end;
    }
    return counts;
}

// 按槽数分段写入 r.upload：每段对应一个临时缓冲，段内按 plan 的 first 排列，返回各段字节起点。
render3d_pack :: (r: *Render3D, counts: [sh.MAX_INSTANCE_FIELDS + 1] int) -> (bases: [sh.MAX_INSTANCE_FIELDS + 1] int) {
    total := 0;
    for count, slots: counts {
        bases[slots] = total;
        total += count * model_stride(slots);
    }
    array_resize(*r.upload, total);
    for batch: r.batches {
        record := *r.records[r.queue.items[batch.start].payload];
        source := *r.sources[record.source];
        if record.buffer != null || !source.shader.desc.instanced continue;
        slots := source.slots;
        stride := model_stride(slots);
        n := batch.end - batch.start;
        for k: 0..source.count - 1 {
            pass := source.selected[k];
            for j: 0..n - 1 {
                item := *r.records[r.queue.items[batch.start + j].payload];
                at := bases[slots] + (batch.first + k * n + j) * stride;
                memcpy(r.upload.data + at, *item.item, size_of(Model_Item));
                if slots > 0 {
                    memcpy(r.upload.data + at + MODEL_BASE_BYTES,
                           r.values.data + (item.values + pass * slots), slots * 16);
                }
            }
        }
    }
    return bases;
}

// 自动实例化用的临时缓冲，按 [Instance] 字段数各一个，首次需要时创建。
// submit 在预检阶段调用，保证发 Draw 之前缓冲已就绪。
render3d_instance_buffer :: (r: *Render3D, slots: int) -> bool {
    if slots < 0 || slots > sh.MAX_INSTANCE_FIELDS return false;
    buf := *r.buffers[slots];
    if buf.capacity == 0 model_buffer_create(buf, r.library.device, slots, 64, "render3d instances");
    return buf.capacity > 0;
}

// jfoster 的 Draw_Command 没有 InstanceOffset：SDL 后端的 first_instance 固定为 0，自动实例化的
// 非首批无法按 olib 的 first 取段。这里把本批实例重新上传到临时缓冲的起点——字节仍是 r.upload 里
// 同一份（布局与 olib 逐个相同），绘制区间 [0, count) 等价于 olib 的 [first, first + count)。
// first == 0 的批次不重传，仍是「一次上传、多批绘制」。
render3d_instance_slice :: (r: *Render3D, buf: *Model_Buffer, base: int, first: int, count: int) {
    stride := model_stride(buf.slots);
    F.buffer_upload(buf.buffer, cast(*void) (r.upload.data + base + first * stride), cast(s32) count, 0);
}

// first 是实例缓冲中的起始实例（自动实例化的批次偏移；常驻缓冲为 0）。
// 视图块（globals）由 submit 每个快照设一次，这里只写随 Draw 变化的矩阵块与帧块。
render3d_draw :: (r: *Render3D, record: *Render3D_Record, source: *Render3D_Source, i: int, view: View,
                  camera: [4] float32, buf: *Model_Buffer, count: int, first: int) {
    snapshot := r.snapshots[source.snapshot + i];
    matrices: [MATERIAL_VERTEX_BLOCK_SIZE] u8;
    frame: [MATERIAL_FRAME_BLOCK_SIZE] u8;
    if buf != null {
        pack_material_blocks(matrices, frame, view.view_projection, W.MATRIX4_IDENTITY,
                             view, camera, .[0, 0], .[1, 1, 1, 1]);
    } else {
        pack_material_blocks(matrices, frame, W.matrix4_multiply(record.item.world, view.view_projection),
                             record.item.world, view, camera, .[0, 0], record.item.tint);
    }
    F.material_stage_set_uniform(*snapshot.Vertex, 0, matrices);
    if source.shader.desc.uniforms == .Olib {
        F.material_stage_set_uniform(*snapshot.Fragment, 0, frame);
    }
    if record.joint_count > 0 {
        palette0: [JOINT_PALETTE_BLOCK_SIZE] u8;
        palette1: [JOINT_PALETTE_BLOCK_SIZE] u8;
        pack_joint_palette(palette0, palette1, array_view(r.joints, record.joint_start, record.joint_count));
        F.material_stage_set_uniform(*snapshot.Vertex, 2, palette0);
        F.material_stage_set_uniform(*snapshot.Vertex, 3, palette1);
    }
    command := F.draw_command_from_mesh(view.target, record.mesh, snapshot);
    shifted: F.Graphics_Buffer;
    if buf != null model_instanced_command(*command, record.mesh, buf, *shifted);
    if buf != null command.InstanceCount = cast(s32) count;
    command.CullMode = .BACK;
    command.BlendMode = mat.BLEND_MODE_DISABLED;
    command.DepthTestEnabled = true;
    command.DepthWriteEnabled = true;
    command.DepthCompare = .LESS;
    p := source.shader.desc.passes[source.selection.passes[i]];
    mat.pass_state_apply(*command, p.state);
    F.graphics_device_draw(r.library.device, command);
    r.draw_calls += 1;
    r.instances += count;
}
//@endregion

//@region 常驻模型实例缓冲

// 模型缓冲：调用方持有的 GPU 顶点缓冲（按实例步进），用于 instanced 模型 Shader 的大批量绘制（与 Sprite_Buffer 对应）。
// 库不缓存、不排序、不剔除：调用方决定哪些实例写入、分成几块（每块一个缓冲，按块剔除）、何时更新。

//@region 类型

// 一个实例的数据：世界矩阵与 tint。
// [Instance] 字段的数值不放在这里：个数由 Shader 决定，由调用方另备一个平铺数组，上传时一并传入
// （model_buffer_upload 的 values，用 mat.instance_array_set 写入）。
// 内存布局就是 GPU 记录的前 80 字节：没有 [Instance] 字段时整块上传。
Model_Item :: struct {
    world: W.Matrix4;
    tint: [4] float32;
}

#assert(size_of(Model_Item) == 80, "Model_Item 必须是 80 字节（世界矩阵 64 + tint 16）");

// 缓冲里每个实例按 世界矩阵(64B) + tint(16B) + slots × 16B 紧凑排列；
// slots 是材质 Shader 的 [Instance] 字段数（init 时读取）。大批量静态场景只需上传一次，动画交给着色器（Clock）。
Model_Buffer :: struct {
    buffer: *F.Graphics_Buffer;
    slots: int;
    capacity: int;
}

MODEL_BASE_BYTES :: 64 + 16;

model_stride :: (slots: int) -> int {
    return MODEL_BASE_BYTES + 16 * slots;
}
//@endregion

//@region 创建与释放

// 为 material 的 instanced Shader 预留 capacity 个实例的 GPU 空间（实际按 2 的幂向上取整）。
// 设备与槽数取自材质；成功返回空串，失败返回原因。
// 属性编号固定为 6..5+slots（世界矩阵 4 列、tint、字段），与 olib/instance.hlsli 的 TEXCOORD6 起一致；
// SDL_GPU 的 D3D12 后端按 location 生成 TEXCOORD<location>，所以编号必须等于语义号，网格属性留在 0..5。
model_buffer_init :: (buf: *Model_Buffer, material: *mat.Material, capacity: int, name := "") -> string {
    if material == null || material.owner == null || material.shader == null return "Missing material";
    if material.owner.device == null return "Missing graphics device";
    slots := mat.instance_slot_count(material);
    if !material.shader.desc.instanced return "Material shader is not instanced";
    if capacity <= 0 return "Instance capacity must be positive";
    if slots < 0 || slots > sh.MAX_INSTANCE_FIELDS return "Inconsistent instance field count";
    model_buffer_create(buf, material.owner.device, slots, capacity, name);
    return "";
}

// 按槽数创建缓冲，不经材质；参数由调用方校验。Render3D 的临时实例缓冲按槽数共用，
// Shader Lab 建 instanced 模型的管线时也用它（只需格式，不上传实例）。
model_buffer_create :: (buf: *Model_Buffer, device: *F.Graphics_Device, slots: int, capacity: int, name: string) {
    elements: [sh.INSTANCE_FIXED_ATTRIBUTES + sh.MAX_INSTANCE_FIELDS] F.Vertex_Format_Element;
    count := sh.INSTANCE_FIXED_ATTRIBUTES + slots;
    for i: 0..count - 1 {
        elements[i] = F.Vertex_Format_Element.{ cast(s32) (sh.INSTANCE_SEMANTIC_BASE + i), .FLOAT4, false };
    }
    format := F.vertex_format_make(array_view(elements, 0, count), cast(s32) model_stride(slots));
    buf.* = Model_Buffer.{ slots = slots, capacity = capacity };
    buf.buffer = F.vertex_buffer_create(device, format, name);
    F.buffer_upload(buf.buffer, null, cast(s32) capacity, 0); // olib: foster.VertexBufferReserve
}

// 把网格的绘制命令改成实例化：网格属性留在 TEXCOORD0..5，实例缓冲用 TEXCOORD6 起，
// 两者编号不冲突，所以直接绑定网格自己的顶点缓冲（shifted 参数保留给调用方传临时副本，可为 null）。
model_instanced_command :: (command: *F.Draw_Command, mesh: *F.Mesh, buf: *Model_Buffer, shifted: *F.Graphics_Buffer) {
    vertex_buffer := mesh.VertexBuffer;
    if shifted != null {
        shifted.* = mesh.VertexBuffer.*;
        vertex_buffer = shifted;
    }
    command.VertexBuffers[0] = F.Vertex_Buffer_Binding.{ Buffer = vertex_buffer, InstanceInputRate = false };
    command.VertexBuffers[1] = F.Vertex_Buffer_Binding.{ Buffer = buf.buffer, InstanceInputRate = true };
    command.VertexBufferCount = 2;
}

model_buffer_dispose :: (buf: *Model_Buffer) {
    if buf.capacity > 0 threed_buffer_release(buf.buffer);
    buf.* = Model_Buffer.{};
}
//@endregion

//@region 上传

// 一次最多拼接上传的实例数：限制临时内存；更大的批量分段写入。
INSTANCE_UPLOAD_CHUNK :: 262144;

// 把 instances 写到缓冲的第 first 个实例起的位置（部分更新只需传变化的区间）。
// values 是这批实例的 [Instance] 数值：平铺数组，每个实例连续 buf.slots 个 float4，长度须为 len(instances) × slots
// （用 mat.instance_array_set 写入）；slots 为 0 或传 nil（全部为 0）时可省略。
// 没有 [Instance] 字段时 instances 整块拷贝到 GPU；有字段时按实例拼接两块内存。
// 超出容量或 values 长度不对返回 false 且不写入。帧内上传会占用设备的暂存区，百万级请在加载时一次性上传。
model_buffer_upload :: (buf: *Model_Buffer, instances: [] Model_Item, first := 0,
                        values: [][4] float32 = .[]) -> bool {
    if buf.capacity <= 0 || first < 0 || first + instances.count > buf.capacity return false;
    slots := buf.slots;
    if values.data != null && values.count != instances.count * slots return false;
    if slots == 0 {
        // 与 Model_Item 同一布局，可直接上传。
        F.buffer_upload(buf.buffer, cast(*void) instances.data, cast(s32) instances.count, cast(s32) first);
        return true;
    }
    stride := model_stride(slots);
    scratch_count := min(instances.count, INSTANCE_UPLOAD_CHUNK);
    scratch: *u8 = null;
    if scratch_count > 0 {
        scratch = cast(*u8) alloc(cast(s64) (scratch_count * stride));
        assert(scratch != null, "rendering3d: 实例上传暂存分配失败");
    }
    defer {
        if scratch != null free(scratch);
    }
    value_bytes := 16 * slots;
    start := 0;
    while start < instances.count {
        chunk := min(start + INSTANCE_UPLOAD_CHUNK, instances.count) - start;
        for i: 0..chunk - 1 {
            at := i * stride;
            memcpy(scratch + at, *instances[start + i], size_of(Model_Item));
            if values.data != null {
                memcpy(scratch + at + size_of(Model_Item), values.data + (start + i) * slots, value_bytes);
            } else {
                memset(scratch + at + size_of(Model_Item), 0, value_bytes);
            }
        }
        F.buffer_upload(buf.buffer, scratch, cast(s32) chunk, cast(s32) (first + start));
        start += INSTANCE_UPLOAD_CHUNK;
    }
    return true;
}
//@endregion
//@endregion
