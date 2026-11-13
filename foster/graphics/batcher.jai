#scope_module
using Basic;
using Math;
using Hash_Table;
#scope_export

// Port of Foster Framework/Graphics/Batcher.cs — the 2D batch renderer.
// Vertex/index buffers grow on demand; state changes split and re-merge
// batches; layers allow later batches to draw on top.

Batcher_Modes :: enum {
    NORMAL;
    WASH;
    FILL;
}

Batcher_Stencil :: struct {
    Enabled:       bool = false;
    State:         Stencil_State = .{ FailOp = .KEEP, PassOp = .KEEP, DepthFailOp = .KEEP, CompareOp = .ALWAYS };
    ReferenceValue: u8 = 0;
    CompareMask:   u8 = 0xFF;
    WriteMask:     u8 = 0xFF;
}

Batcher_Batch :: struct {
    Layer:    s32 = 0;
    Mat: *Material = null;      // renamed from Material (field name shadows the type)
    Blend:    Blend_Mode = Blend_Mode_Premultiply;
    Tex:  *Texture = null;      // renamed from Texture (field name shadows the type)
    HasScissor: bool = false;
    Scissor:  Rect_Int;
    Sampler:  Texture_Sampler;
    Stencil:  Batcher_Stencil;
    HasStencil: bool = false;
    Offset:   s32 = 0;   // first triangle
    Elements: s32 = 0;   // triangle count
}

STACK_DEPTH :: 32;

Batcher :: struct {
    device: *Graphics_Device;
    // Ring of GPU meshes: every batcher_render call uploads into its own mesh.
    // Uploads land on cmd_upload while draws land on cmd_render, and both are
    // only submitted together at flush — re-using one mesh would let a later
    // render's upload overwrite the vertex data earlier recorded draws read.
    // Slot k receives the k-th render of each frame, so capacities stay stable.
    meshes:      [..] *Mesh;
    mesh_cursor: s32 = 0;
    mesh_present_serial: u64;
    mesh_name:   string = "";

    Matrix: Matrix3x2 = Matrix3x2_Identity;

    VertexStorageBuffers:   [4] *Graphics_Buffer;  VertexStorageBufferCount:   s32 = 0;
    FragmentStorageBuffers: [4] *Graphics_Buffer;  FragmentStorageBufferCount: s32 = 0;

    // state stacks
    matrixStack:   [STACK_DEPTH] Matrix3x2;      matrixDepth:   s32 = 0;
    scissorStack:  [STACK_DEPTH] Rect_Int;       scissorHas:    [STACK_DEPTH] bool; scissorDepth: s32 = 0;
    blendStack:    [STACK_DEPTH] Blend_Mode;     blendDepth:    s32 = 0;
    samplerStack:  [STACK_DEPTH] Texture_Sampler; samplerDepth: s32 = 0;
    materialStack: [STACK_DEPTH] *Material;      materialDepth: s32 = 0;
    layerStack:    [STACK_DEPTH] s32;            layerDepth:    s32 = 0;
    modeStack:     [STACK_DEPTH] Color;          modeDepth:     s32 = 0;
    stencilStack:  [STACK_DEPTH] Batcher_Stencil; stencilHas: [STACK_DEPTH] bool; stencilDepth: s32 = 0;

    batches: [..] Batcher_Batch;
    materials_used: [..] *Material;
    materials_pool: [..] *Material;
    materials_pool_head: s32 = 0;

    default_material: *Material = null;
    mode: Color = Batcher_Mode_Normal;

    current_batch: Batcher_Batch;
    vertex_buffer: [..] Batcher_Vertex;
    index_buffer:  [..] s32;
    vertex_count: s32 = 0;
    index_count:  s32 = 0;
    current_batch_insert: s32 = 0;
    mesh_dirty: bool = false;
}

batcher_create :: (device: *Graphics_Device, name := "") -> *Batcher {
    b := New(Batcher);
    b.device = device;
    b.mesh_name = name;
    array_add(*b.meshes, mesh_create(device, Batcher_Vertex_Format, .THIRTY_TWO, name));
    batcher_clear(b);
    return b;
}

batcher_destroy :: (b: *Batcher) {
    for m: b.meshes {
        mesh_dispose(m);
        free(m.VertexBuffer);
        if m.InstanceBuffer != null free(m.InstanceBuffer);
        free(m.IndexBuffer);
        free(m);
    }
    array_free(b.meshes);
    array_free(b.vertex_buffer);
    array_free(b.index_buffer);
    array_free(b.batches);
    array_free(b.materials_used);
    for m: b.materials_pool material_destroy(m);
    array_free(b.materials_pool);
    if b.default_material != null material_destroy(b.default_material);
    free(b);
}

//
// properties
//

batcher_triangle_count :: (b: *Batcher) -> s32 { return b.index_count / 3; }
batcher_vertex_count   :: (b: *Batcher) -> s32 { return b.vertex_count; }
batcher_index_count    :: (b: *Batcher) -> s32 { return b.index_count; }
batcher_batch_count    :: (b: *Batcher) -> s32 {
    extra: s32 = 0;
    if b.current_batch.Elements > 0 extra = 1;
    return cast(s32) b.batches.count + extra;
}
batcher_scissor        :: (b: *Batcher) -> Rect_Int { return b.current_batch.Scissor; }

//
// upload / clear
//

batcher_upload :: (b: *Batcher) {
    if b.mesh_dirty && b.index_count > 0 && b.vertex_count > 0 {
        mesh := b.meshes[b.mesh_cursor];
        mesh_clear(mesh);
        mesh_set_indices(mesh, array_view(b.index_buffer, 0, b.index_count));
        mesh_set_vertices(mesh, array_view(b.vertex_buffer, 0, b.vertex_count));
        b.mesh_dirty = false;
    }
}

batcher_clear :: (b: *Batcher) {
    b.vertex_count = 0;
    b.index_count = 0;
    b.current_batch_insert = 0;
    b.current_batch = .{};
    b.mode = Batcher_Mode_Normal;
    array_reset(*b.batches);
    b.matrixDepth = 0;
    b.scissorDepth = 0;
    b.blendDepth = 0;
    b.materialDepth = 0;
    b.layerDepth = 0;
    b.samplerDepth = 0;
    b.modeDepth = 0;
    b.stencilDepth = 0;
    b.FragmentStorageBufferCount = 0;
    b.VertexStorageBufferCount = 0;

    // Pool already owns each copy; rewind instead of appending duplicate pointers.
    b.materials_pool_head = 0;
    array_reset(*b.materials_used);

    b.Matrix = Matrix3x2_Identity;
}

//
// rendering
//

batcher_render :: (b: *Batcher, target: Drawable_Target, viewport: Rect_Int = .{}, has_viewport := false, scissor: Rect_Int = .{}, has_scissor := false) {
    size: Point2;
    if has_viewport {
        size = .{ viewport.w, viewport.h };
    } else {
        size = .{ drawable_target_width_in_pixels(target), drawable_target_height_in_pixels(target) };
    }
    // Matrix4x4.CreateOrthographicOffCenter(0, w, h, 0, 0, float.MaxValue)
    m: Matrix4;
    m._11 = cast(float) ( 2.0 / cast(float) size.x);
    m._22 = cast(float) (-2.0 / cast(float) size.y);
    m._33 = cast(float) (1.0 / 3.4028235e38);
    m._41 = -1;
    m._42 =  1;
    m._43 = -1;
    m._44 = 1;
    batcher_render_matrix(b, target, m, viewport, has_viewport, scissor, has_scissor);
}

batcher_render_matrix :: (b: *Batcher, target: Drawable_Target, matrix: Matrix4, viewport: Rect_Int = .{}, has_viewport := false, scissor: Rect_Int = .{}, has_scissor := false) {
    assert(target.Kind != .NONE, "Target cannot be null");
    if b.vertex_count <= 0 || b.index_count <= 0 return;
    if b.batches.count <= 0 && b.current_batch.Elements <= 0 return;

    if b.mesh_present_serial != b.device.present_serial {
        b.mesh_present_serial = b.device.present_serial;
        b.mesh_cursor = 0;
    }
    if b.mesh_cursor >= b.meshes.count {
        array_add(*b.meshes, mesh_create(b.device, Batcher_Vertex_Format, .THIRTY_TWO,
            ifx b.mesh_name != "" then tprint("%-ring%", b.mesh_name, b.meshes.count) else ""));
    }
    // Even unchanged CPU geometry needs uploading into this render's mesh slot.
    b.mesh_dirty = true;
    batcher_upload(b);

    if b.default_material == null {
        b.default_material = material_clone(defaults_batch_material(b.device));
    }

    for i: 0..b.batches.count-1 {
        if b.current_batch_insert == i && b.current_batch.Elements > 0 {
            batcher_render_batch(b, target, b.current_batch, matrix, viewport, has_viewport, scissor, has_scissor);
        }
        batcher_render_batch(b, target, b.batches[i], matrix, viewport, has_viewport, scissor, has_scissor);
    }

    if b.current_batch_insert == b.batches.count && b.current_batch.Elements > 0 {
        batcher_render_batch(b, target, b.current_batch, matrix, viewport, has_viewport, scissor, has_scissor);
    }

    // next render call uploads into a fresh ring slot
    b.mesh_cursor += 1;
}

batcher_render_batch :: (b: *Batcher, target: Drawable_Target, batch: Batcher_Batch, matrix: Matrix4, viewport: Rect_Int, has_viewport: bool, scissor: Rect_Int, has_scissor: bool) {
    // trimmed scissor
    trimmed := scissor;
    trimmed_has := has_scissor;
    if batch.HasScissor && has_scissor {
        trimmed = rect_int_get_intersection(batch.Scissor, scissor);
    } else if batch.HasScissor {
        trimmed = batch.Scissor;
        trimmed_has = true;
    }

    if trimmed_has && (trimmed.w <= 0 || trimmed.h <= 0) return;

    texture := ifx batch.Tex != null && !texture_is_disposed(batch.Tex) then batch.Tex else null;
    mat := ifx batch.Mat != null then batch.Mat else b.default_material;
    assert(mat != null, "Default Material has not been instantiated");

    // fragment sampler 0 = texture
    mat.Fragment.Samplers[0] = .{ Tex = texture, Sampler = batch.Sampler };

    // vertex matrix in uniform slot 0
    material_stage_set_uniform_value(*mat.Vertex, 0, matrix);

    cmd := draw_command_from_mesh(target, b.meshes[b.mesh_cursor], mat);
    if has_viewport { cmd.Viewport = viewport; cmd.HasViewport = true; }
    if trimmed_has  { cmd.Scissor = trimmed;  cmd.HasScissor = true; }
    cmd.BlendMode = batch.Blend;
    cmd.IndexOffset = batch.Offset * 3;
    cmd.IndexCount = batch.Elements * 3;
    cmd.DepthWriteEnabled = false;
    cmd.DepthTestEnabled = false;
    cmd.StencilTestEnabled = batch.Stencil.Enabled;
    cmd.BackStencilState = batch.Stencil.State;
    cmd.FrontStencilState = batch.Stencil.State;
    cmd.StencilWriteMask = batch.Stencil.WriteMask;
    cmd.StencilCompareMask = batch.Stencil.CompareMask;
    cmd.StencilReferenceValue = batch.Stencil.ReferenceValue;
    cmd.CullMode = .NONE;
    for i: 0..b.VertexStorageBufferCount-1   cmd.VertexStorageBuffers[i]   = b.VertexStorageBuffers[i];
    cmd.VertexStorageBufferCount   = b.VertexStorageBufferCount;
    for i: 0..b.FragmentStorageBufferCount-1 cmd.FragmentStorageBuffers[i] = b.FragmentStorageBuffers[i];
    cmd.FragmentStorageBufferCount = b.FragmentStorageBufferCount;

    graphics_device_draw(b.device, cmd);
}

//
// modify state (split/merge batches)
//

batcher_set_texture :: (b: *Batcher, texture: *Texture) {
    if texture == null return;

    if b.current_batch.Tex == null || b.current_batch.Elements == 0 {
        b.current_batch.Tex = texture;
        batcher_try_to_merge(b);
    } else if b.current_batch.Tex != texture {
        batcher_split_current(b);
        b.current_batch.Tex = texture;
    }
}

batcher_set_sampler :: (b: *Batcher, sampler: Texture_Sampler) {
    if b.current_batch.Sampler == sampler || b.current_batch.Elements == 0 {
        b.current_batch.Sampler = sampler;
        batcher_try_to_merge(b);
    } else if b.current_batch.Sampler != sampler {
        batcher_split_current(b);
        b.current_batch.Sampler = sampler;
    }
}

batcher_set_layer :: (b: *Batcher, layer: s32) {
    if b.current_batch.Layer == layer return;

    if b.current_batch.Elements > 0 {
        batcher_split_current(b);
    }

    insert: s32 = 0;
    while insert < b.batches.count && b.batches[insert].Layer >= layer {
        insert += 1;
    }
    b.current_batch.Layer = layer;
    b.current_batch_insert = insert;
}

batcher_set_material :: (b: *Batcher, material: *Material) {
    if b.current_batch.Elements == 0 {
        b.current_batch.Mat = material;
        batcher_try_to_merge(b);
    } else if b.current_batch.Mat != material {
        batcher_split_current(b);
        b.current_batch.Mat = material;
    }
}

batcher_set_blend :: (b: *Batcher, blend: Blend_Mode) {
    if b.current_batch.Elements == 0 {
        b.current_batch.Blend = blend;
        batcher_try_to_merge(b);
    } else if b.current_batch.Blend != blend {
        batcher_split_current(b);
        b.current_batch.Blend = blend;
    }
}

batcher_set_scissor :: (b: *Batcher, scissor: Rect_Int, has_scissor: bool) {
    same := b.current_batch.HasScissor == has_scissor &&
            (!has_scissor || b.current_batch.Scissor == scissor);
    if b.current_batch.Elements == 0 {
        b.current_batch.Scissor = scissor;
        b.current_batch.HasScissor = has_scissor;
        batcher_try_to_merge(b);
    } else if !same {
        batcher_split_current(b);
        b.current_batch.Scissor = scissor;
        b.current_batch.HasScissor = has_scissor;
    }
}

batcher_set_stencil :: (b: *Batcher, stencil: Batcher_Stencil, has_stencil: bool) {
    same := b.current_batch.HasStencil == has_stencil &&
            (!has_stencil || (
                b.current_batch.Stencil.Enabled == stencil.Enabled &&
                b.current_batch.Stencil.State == stencil.State &&
                b.current_batch.Stencil.ReferenceValue == stencil.ReferenceValue &&
                b.current_batch.Stencil.CompareMask == stencil.CompareMask &&
                b.current_batch.Stencil.WriteMask == stencil.WriteMask));
    if b.current_batch.Elements == 0 {
        b.current_batch.Stencil = stencil;
        b.current_batch.HasStencil = has_stencil;
        batcher_try_to_merge(b);
    } else if !same {
        batcher_split_current(b);
        b.current_batch.Stencil = stencil;
        b.current_batch.HasStencil = has_stencil;
    }
}

// inserts the current batch into the list and resets its accumulation
batcher_split_current :: (b: *Batcher) {
    array_insert_at(*b.batches, b.current_batch, b.current_batch_insert);
    b.current_batch.Offset += b.current_batch.Elements;
    b.current_batch.Elements = 0;
    b.current_batch_insert += 1;
}

batcher_try_to_merge :: (b: *Batcher) {
    index := b.current_batch_insert - 1;
    if index >= 0 && index < b.batches.count && b.current_batch.Elements <= 0 {
        prev := *b.batches[index];
        curr := b.current_batch;

        if prev.Layer == curr.Layer &&
           prev.Tex == curr.Tex &&
           prev.Blend == curr.Blend &&
           prev.HasScissor == curr.HasScissor && (!curr.HasScissor || prev.Scissor == curr.Scissor) &&
           prev.Sampler == curr.Sampler &&
           prev.HasStencil == curr.HasStencil && (!curr.HasStencil || (
               prev.Stencil.Enabled == curr.Stencil.Enabled &&
               prev.Stencil.State == curr.Stencil.State &&
               prev.Stencil.ReferenceValue == curr.Stencil.ReferenceValue &&
               prev.Stencil.CompareMask == curr.Stencil.CompareMask &&
               prev.Stencil.WriteMask == curr.Stencil.WriteMask)) &&
           prev.Mat == curr.Mat {
            b.current_batch.Offset = prev.Offset;
            array_ordered_remove_by_index(*b.batches, index);
            b.current_batch_insert -= 1;
        }
    }
}

//
// state stacks
//

batcher_push_layer :: (b: *Batcher, delta: s32) {
    b.layerStack[b.layerDepth] = b.current_batch.Layer; b.layerDepth += 1;
    batcher_set_layer(b, b.current_batch.Layer + delta);
}

batcher_pop_layer :: (b: *Batcher) {
    b.layerDepth -= 1;
    batcher_set_layer(b, b.layerStack[b.layerDepth]);
}

batcher_push_material :: (b: *Batcher, material: *Material) {
    assert(material.Fragment.shader != null, "Material must have a Fragment assigned");

    b.materialStack[b.materialDepth] = b.current_batch.Mat; b.materialDepth += 1;

    // get a pooled copy
    copy: *Material;
    if b.materials_pool_head < b.materials_pool.count {
        copy = b.materials_pool[b.materials_pool_head];
        b.materials_pool_head += 1;
    } else {
        copy = material_create();
        array_add(*b.materials_pool, copy);
        b.materials_pool_head += 1;
    }
    array_add(*b.materials_used, copy);
    material_copy_to(material, copy);

    // allow fallback to the default vertex shader
    if copy.Vertex.shader == null {
        if b.default_material == null b.default_material = material_clone(defaults_batch_material(b.device));
        material_stage_set_shader(*copy.Vertex, b.default_material.Vertex.shader);
    }
    batcher_set_material(b, copy);
}

batcher_pop_material :: (b: *Batcher) {
    b.materialDepth -= 1;
    batcher_set_material(b, b.materialStack[b.materialDepth]);
}

batcher_push_sampler :: (b: *Batcher, sampler: Texture_Sampler) {
    b.samplerStack[b.samplerDepth] = b.current_batch.Sampler; b.samplerDepth += 1;
    batcher_set_sampler(b, sampler);
}

batcher_pop_sampler :: (b: *Batcher) {
    b.samplerDepth -= 1;
    batcher_set_sampler(b, b.samplerStack[b.samplerDepth]);
}

batcher_push_blend :: (b: *Batcher, blend: Blend_Mode) {
    b.blendStack[b.blendDepth] = b.current_batch.Blend; b.blendDepth += 1;
    batcher_set_blend(b, blend);
}

batcher_pop_blend :: (b: *Batcher) {
    b.blendDepth -= 1;
    batcher_set_blend(b, b.blendStack[b.blendDepth]);
}

batcher_push_scissor :: (b: *Batcher, scissor: Rect_Int, has_scissor: bool) {
    b.scissorStack[b.scissorDepth] = b.current_batch.Scissor;
    b.scissorHas[b.scissorDepth] = b.current_batch.HasScissor;
    b.scissorDepth += 1;
    batcher_set_scissor(b, scissor, has_scissor);
}

batcher_pop_scissor :: (b: *Batcher) {
    b.scissorDepth -= 1;
    batcher_set_scissor(b, b.scissorStack[b.scissorDepth], b.scissorHas[b.scissorDepth]);
}

batcher_push_stencil :: (b: *Batcher, stencil: Batcher_Stencil, has_stencil: bool) {
    b.stencilStack[b.stencilDepth] = b.current_batch.Stencil;
    b.stencilHas[b.stencilDepth] = b.current_batch.HasStencil;
    b.stencilDepth += 1;
    batcher_set_stencil(b, stencil, has_stencil);
}

batcher_pop_stencil :: (b: *Batcher) {
    b.stencilDepth -= 1;
    batcher_set_stencil(b, b.stencilStack[b.stencilDepth], b.stencilHas[b.stencilDepth]);
}

batcher_push_matrix :: (b: *Batcher, matrix: Matrix3x2, relative := true) -> Matrix3x2 {
    b.matrixStack[b.matrixDepth] = b.Matrix; b.matrixDepth += 1;
    if relative b.Matrix = matrix * b.Matrix;
    else        b.Matrix = matrix;
    return b.Matrix;
}

batcher_push_matrix_trs :: (b: *Batcher, position: Vector2, origin: Vector2, scale_v: Vector2, rotation: float, relative := true) -> Matrix3x2 {
    return batcher_push_matrix(b, matrix3x2_create_transform(position, origin, scale_v, rotation), relative);
}

batcher_pop_matrix :: (b: *Batcher) -> Matrix3x2 {
    b.matrixDepth -= 1;
    b.Matrix = b.matrixStack[b.matrixDepth];
    return b.Matrix;
}

batcher_push_mode :: (b: *Batcher, mode_enum: Batcher_Modes) {
    // jacket 不接受 `ifx x == { case }`；这里用运行时 if-switch，官方 Jai 与 jacket 都认。
    value := Batcher_Mode_Normal;
    if mode_enum == {
        case .NORMAL; value = Batcher_Mode_Normal;
        case .WASH;   value = Batcher_Mode_Wash;
        case .FILL;   value = Batcher_Mode_Fill;
    };
    b.modeStack[b.modeDepth] = b.mode; b.modeDepth += 1;
    b.mode = value;
}

batcher_push_mode_color :: (b: *Batcher, mode_color: Color) {
    b.modeStack[b.modeDepth] = b.mode; b.modeDepth += 1;
    b.mode = mode_color;
}

batcher_pop_mode :: (b: *Batcher) {
    b.modeDepth -= 1;
    b.mode = b.modeStack[b.modeDepth];
}

//
// request
//

batcher_request :: (b: *Batcher, vertex_append: s32, index_append: s32) -> ([] Batcher_Vertex, [] s32, s32) {
    vertex_offset := b.vertex_count;

    // ensure vertex space
    if b.vertex_count + vertex_append >= b.vertex_buffer.count {
        capacity := max(8, b.vertex_buffer.count);
        while capacity <= b.vertex_count + vertex_append capacity *= 2;
        array_resize(*b.vertex_buffer, capacity);
    }
    // ensure index space
    if b.index_count + index_append >= b.index_buffer.count {
        capacity := max(8, b.index_buffer.count);
        while capacity <= b.index_count + index_append capacity *= 2;
        array_resize(*b.index_buffer, capacity);
    }

    vertices := array_view(b.vertex_buffer, b.vertex_count, vertex_append);
    indices  := array_view(b.index_buffer, b.index_count, index_append);

    b.index_count += index_append;
    b.vertex_count += vertex_append;
    b.current_batch.Elements += index_append / 3;
    b.mesh_dirty = true;

    return vertices, indices, vertex_offset;
}

//
// primitives — lines
//

batcher_line :: (b: *Batcher, from: Vector2, to: Vector2, line_weight: float, color: Color) {
    normal := vector2_normalize(to - from);
    perp := .{ -normal.y, normal.x } * (line_weight * 0.5);
    batcher_quad(b, from + perp, from - perp, to - perp, to + perp, color);
}

batcher_line_gradient :: (b: *Batcher, from: Vector2, to: Vector2, line_weight: float, from_color: Color, to_color: Color) {
    normal := vector2_normalize(to - from);
    perp := .{ -normal.y, normal.x } * (line_weight * 0.5);
    batcher_quad_gradient(b, from + perp, from - perp, to - perp, to + perp, from_color, from_color, to_color, to_color);
}

batcher_line_dashed :: (b: *Batcher, from: Vector2, to: Vector2, line_weight: float, color: Color, dash_length: float, offset_percent: float) {
    diff := to - from;
    dist := vector2_length(diff);
    axis := vector2_normalize(diff);
    perp := vector2_turn_left(axis) * (line_weight * 0.5);
    offset_percent = mod_f32(offset_percent, 1.0);
    if offset_percent < 0 offset_percent += 1.0;

    start_d := dash_length * offset_percent * 2.0;
    if start_d > dash_length start_d -= dash_length * 2.0;

    d := start_d;
    while d < dist {
        a := from + axis * max(d, 0.0);
        e := from + axis * min(d + dash_length, dist);
        batcher_quad(b, a + perp, e + perp, e - perp, a - perp, color);
        d += dash_length * 2.0;
    }
}

//
// primitives — quads
//

batcher_quad :: (b: *Batcher, v0: Vector2, v1: Vector2, v2: Vector2, v3: Vector2, color: Color) {
    vertices, indices, offset := batcher_request(b, 4, 6);

    vertices[0].pos = vector2_transform(v0, b.Matrix);
    vertices[1].pos = vector2_transform(v1, b.Matrix);
    vertices[2].pos = vector2_transform(v2, b.Matrix);
    vertices[3].pos = vector2_transform(v3, b.Matrix);
    vertices[0].col = color; vertices[1].col = color;
    vertices[2].col = color; vertices[3].col = color;
    vertices[0].mode = Batcher_Mode_Fill; vertices[1].mode = Batcher_Mode_Fill;
    vertices[2].mode = Batcher_Mode_Fill; vertices[3].mode = Batcher_Mode_Fill;

    indices[0] = offset + 0; indices[1] = offset + 1; indices[2] = offset + 2;
    indices[3] = offset + 0; indices[4] = offset + 2; indices[5] = offset + 3;
}

batcher_quad_gradient :: (b: *Batcher, v0: Vector2, v1: Vector2, v2: Vector2, v3: Vector2, c0: Color, c1: Color, c2: Color, c3: Color) {
    vertices, indices, offset := batcher_request(b, 4, 6);

    vertices[0].pos = vector2_transform(v0, b.Matrix);
    vertices[1].pos = vector2_transform(v1, b.Matrix);
    vertices[2].pos = vector2_transform(v2, b.Matrix);
    vertices[3].pos = vector2_transform(v3, b.Matrix);
    vertices[0].col = c0; vertices[1].col = c1;
    vertices[2].col = c2; vertices[3].col = c3;
    vertices[0].mode = Batcher_Mode_Fill; vertices[1].mode = Batcher_Mode_Fill;
    vertices[2].mode = Batcher_Mode_Fill; vertices[3].mode = Batcher_Mode_Fill;

    indices[0] = offset + 0; indices[1] = offset + 1; indices[2] = offset + 2;
    indices[3] = offset + 0; indices[4] = offset + 2; indices[5] = offset + 3;
}

batcher_quad_textured :: (b: *Batcher, texture: *Texture, v0: Vector2, v1: Vector2, v2: Vector2, v3: Vector2, t0: Vector2, t1: Vector2, t2: Vector2, t3: Vector2, color: Color) {
    batcher_quad_textured_gradient(b, texture, v0, v1, v2, v3, t0, t1, t2, t3, color, color, color, color);
}

batcher_quad_textured_gradient :: (b: *Batcher, texture: *Texture, v0: Vector2, v1: Vector2, v2: Vector2, v3: Vector2, t0: Vector2, t1: Vector2, t2: Vector2, t3: Vector2, c0: Color, c1: Color, c2: Color, c3: Color) {
    batcher_set_texture(b, texture);
    vertices, indices, offset := batcher_request(b, 4, 6);

    vertices[0].pos = vector2_transform(v0, b.Matrix);
    vertices[1].pos = vector2_transform(v1, b.Matrix);
    vertices[2].pos = vector2_transform(v2, b.Matrix);
    vertices[3].pos = vector2_transform(v3, b.Matrix);
    vertices[0].tex = t0; vertices[1].tex = t1;
    vertices[2].tex = t2; vertices[3].tex = t3;
    vertices[0].col = c0; vertices[1].col = c1;
    vertices[2].col = c2; vertices[3].col = c3;
    vertices[0].mode = b.mode; vertices[1].mode = b.mode;
    vertices[2].mode = b.mode; vertices[3].mode = b.mode;

    indices[0] = offset + 0; indices[1] = offset + 1; indices[2] = offset + 2;
    indices[3] = offset + 0; indices[4] = offset + 2; indices[5] = offset + 3;
}

//
// primitives — triangles
//

batcher_triangle :: (b: *Batcher, v0: Vector2, v1: Vector2, v2: Vector2, color: Color) {
    vertices, indices, offset := batcher_request(b, 3, 3);

    vertices[0].pos = vector2_transform(v0, b.Matrix);
    vertices[1].pos = vector2_transform(v1, b.Matrix);
    vertices[2].pos = vector2_transform(v2, b.Matrix);
    vertices[0].col = color; vertices[1].col = color; vertices[2].col = color;
    vertices[0].mode = Batcher_Mode_Fill; vertices[1].mode = Batcher_Mode_Fill; vertices[2].mode = Batcher_Mode_Fill;

    indices[0] = offset + 0; indices[1] = offset + 1; indices[2] = offset + 2;
}

batcher_triangle_gradient :: (b: *Batcher, v0: Vector2, v1: Vector2, v2: Vector2, c0: Color, c1: Color, c2: Color) {
    vertices, indices, offset := batcher_request(b, 3, 3);

    vertices[0].pos = vector2_transform(v0, b.Matrix);
    vertices[1].pos = vector2_transform(v1, b.Matrix);
    vertices[2].pos = vector2_transform(v2, b.Matrix);
    vertices[0].col = c0; vertices[1].col = c1; vertices[2].col = c2;
    vertices[0].mode = Batcher_Mode_Fill; vertices[1].mode = Batcher_Mode_Fill; vertices[2].mode = Batcher_Mode_Fill;

    indices[0] = offset + 0; indices[1] = offset + 1; indices[2] = offset + 2;
}

batcher_triangle_textured :: (b: *Batcher, texture: *Texture, v0: Vector2, v1: Vector2, v2: Vector2, t0: Vector2, t1: Vector2, t2: Vector2, color: Color) {
    batcher_set_texture(b, texture);
    vertices, indices, offset := batcher_request(b, 3, 3);

    vertices[0].pos = vector2_transform(v0, b.Matrix);
    vertices[1].pos = vector2_transform(v1, b.Matrix);
    vertices[2].pos = vector2_transform(v2, b.Matrix);
    vertices[0].tex = t0; vertices[1].tex = t1; vertices[2].tex = t2;
    vertices[0].col = color; vertices[1].col = color; vertices[2].col = color;
    vertices[0].mode = b.mode; vertices[1].mode = b.mode; vertices[2].mode = b.mode;

    indices[0] = offset + 0; indices[1] = offset + 1; indices[2] = offset + 2;
}

//
// primitives — rects
//

batcher_rect :: (b: *Batcher, r: Rect, color: Color) {
    batcher_quad(b,
        .{ r.x, r.y },
        .{ r.x + r.w, r.y },
        .{ r.x + r.w, r.y + r.h },
        .{ r.x, r.y + r.h },
        color);
}

batcher_rect_xy :: (b: *Batcher, x: float, y: float, w: float, h: float, color: Color) {
    batcher_rect(b, .{ x, y, w, h }, color);
}

batcher_rect_gradient :: (b: *Batcher, r: Rect, c0: Color, c1: Color, c2: Color, c3: Color) {
    batcher_quad_gradient(b,
        .{ r.x, r.y },
        .{ r.x + r.w, r.y },
        .{ r.x + r.w, r.y + r.h },
        .{ r.x, r.y + r.h },
        c0, c1, c2, c3);
}

batcher_rect_line :: (b: *Batcher, r: Rect, line_weight: float, color: Color) {
    batcher_rect(b, .{ r.x, r.y, r.w, line_weight }, color);
    batcher_rect(b, .{ r.x, r.y + r.h - line_weight, r.w, line_weight }, color);
    batcher_rect(b, .{ r.x, r.y + line_weight, line_weight, r.h - line_weight * 2.0 }, color);
    batcher_rect(b, .{ r.x + r.w - line_weight, r.y + line_weight, line_weight, r.h - line_weight * 2.0 }, color);
}

batcher_rect_dashed :: (b: *Batcher, r: Rect, line_weight: float, color: Color, dash_length: float, offset_percent: float) {
    batcher_line_dashed(b, .{ r.x, r.y }, .{ r.x + r.w, r.y }, line_weight, color, dash_length, offset_percent);
    batcher_line_dashed(b, .{ r.x, r.y + r.h }, .{ r.x + r.w, r.y + r.h }, line_weight, color, dash_length, offset_percent);
    batcher_line_dashed(b, .{ r.x, r.y }, .{ r.x, r.y + r.h }, line_weight, color, dash_length, offset_percent);
    batcher_line_dashed(b, .{ r.x + r.w, r.y }, .{ r.x + r.w, r.y + r.h }, line_weight, color, dash_length, offset_percent);
}

batcher_rect_rounded :: (b: *Batcher, r: Rect, radius: float, color: Color) {
    batcher_rect_rounded_corners(b, r, radius, radius, radius, radius, color);
}

batcher_rect_rounded_corners :: (b: *Batcher, r: Rect, r0: float, r1: float, r2: float, r3: float, color: Color) {
    // clamp
    r0 = min(min(max(0.0, r0), r.w / 2.0), r.h / 2.0);
    r1 = min(min(max(0.0, r1), r.w / 2.0), r.h / 2.0);
    r2 = min(min(max(0.0, r2), r.w / 2.0), r.h / 2.0);
    r3 = min(min(max(0.0, r3), r.w / 2.0), r.h / 2.0);

    if r0 <= 0 && r1 <= 0 && r2 <= 0 && r3 <= 0 {
        batcher_rect(b, r, color);
        return;
    }

    // corner points
    r0_tl := rect_top_left(r);
    r0_tr := r0_tl + .{  r0, 0 };
    r0_br := r0_tl + .{  r0, r0 };
    r0_bl := r0_tl + .{  0, r0 };

    r1_tl := rect_top_right(r) + .{ -r1, 0 };
    r1_tr := r1_tl + .{  r1, 0 };
    r1_br := r1_tl + .{  r1, r1 };
    r1_bl := r1_tl + .{  0, r1 };

    r2_tl := rect_bottom_right(r) + .{ -r2, -r2 };
    r2_tr := r2_tl + .{  r2, 0 };
    r2_bl := r2_tl + .{  0, r2 };
    r2_br := r2_tl + .{  r2, r2 };

    r3_tl := rect_bottom_left(r) + .{  0, -r3 };
    r3_tr := r3_tl + .{  r3, 0 };
    r3_bl := r3_tl + .{  0, r3 };
    r3_br := r3_tl + .{  r3, r3 };

    // fill inner cross with two rectangles + center quad
    batcher_rect(b, .{ r.x + r0, r.y, cast(float) max(0.0, r.w - r0 - r1), r0 }, color);
    batcher_rect(b, .{ r.x + r3, r.y + r.h - r3, cast(float) max(0.0, r.w - r2 - r3), r3 }, color);
    batcher_rect(b, .{ r.x, r.y + r0, r.w, cast(float) max(0.0, r.h - r0 - r3) }, color);

    left  := PI;
    right := 0.0;
    up    := -PI / 2.0;
    down  := PI / 2.0;

    if r0 > 0 batcher_semicircle(b, r0_br, up, -left, r0, cast(s32) max(3.0, r0 / 4.0), color);
    else       batcher_quad(b, r0_tl, r0_tr, r0_br, r0_bl, color);

    if r1 > 0 batcher_semicircle(b, r1_bl, up, right, r1, cast(s32) max(3.0, r1 / 4.0), color);
    else       batcher_quad(b, r1_tl, r1_tr, r1_br, r1_bl, color);

    if r2 > 0 batcher_semicircle(b, r2_tl, right, down, r2, cast(s32) max(3.0, r2 / 4.0), color);
    else       batcher_quad(b, r2_tl, r2_tr, r2_br, r2_bl, color);

    if r3 > 0 batcher_semicircle(b, r3_tr, down, left, r3, cast(s32) max(3.0, r3 / 4.0), color);
    else       batcher_quad(b, r3_tl, r3_tr, r3_br, r3_bl, color);
}

batcher_rect_rounded_line :: (b: *Batcher, r: Rect, rounding: float, t: float, color: Color) {
    batcher_rect_rounded_line_corners(b, r, rounding, rounding, rounding, rounding, t, color);
}

batcher_rect_rounded_line_corners :: (b: *Batcher, r: Rect, rtl: float, rtr: float, rbr: float, rbl: float, t: float, color: Color) {
    rtl = min(min(max(0.0, rtl), r.w / 2.0), r.h / 2.0);
    rtr = min(min(max(0.0, rtr), r.w / 2.0), r.h / 2.0);
    rbr = min(min(max(0.0, rbr), r.w / 2.0), r.h / 2.0);
    rbl = min(min(max(0.0, rbl), r.w / 2.0), r.h / 2.0);

    if rtl <= 0 && rtr <= 0 && rbr <= 0 && rbl <= 0 {
        batcher_rect_line(b, r, t, color);
    } else {
        rtl_steps := cast(s32) cast(s32) max(3.0, rtl / 4.0);
        rtr_steps := cast(s32) cast(s32) max(3.0, rtr / 4.0);
        rbr_steps := cast(s32) cast(s32) max(3.0, rbr / 4.0);
        rbl_steps := cast(s32) cast(s32) max(3.0, rbl / 4.0);

        up    := -PI / 2.0;
        down  := PI / 2.0;
        left  := PI;

        batcher_semicircle_line(b, .{ r.x + rtl, r.y + rtl }, up, -left, rtl, rtl_steps, t, color);
        batcher_semicircle_line(b, .{ r.x + r.w - rtr, r.y + rtr }, up, up + TAU * 0.25, rtr, rtr_steps, t, color);
        batcher_semicircle_line(b, .{ r.x + rbl, r.y + r.h - rbl }, down, left, rbl, rbl_steps, t, color);
        batcher_semicircle_line(b, .{ r.x + r.w - rbr, r.y + r.h - rbr }, down, 0.0, rbr, rbr_steps, t, color);

        if r.h > rtl + rbl batcher_rect(b, .{ r.x, r.y + rtl, t, r.h - rtl - rbl }, color);
        if r.h > rtr + rbr batcher_rect(b, .{ r.x + r.w - t, r.y + rtr, t, r.h - rtr - rbr }, color);
        if r.w > rtl + rtr batcher_rect(b, .{ r.x + rtl, r.y, r.w - rtl - rtr, t }, color);
        if r.w > rbl + rbr batcher_rect(b, .{ r.x + rbl, r.y + r.h - t, r.w - rbl - rbr, t }, color);
    }
}

//
// primitives — circles
//

batcher_semicircle :: (b: *Batcher, center: Vector2, start_radians: float, end_radians: float, radius: float, steps: s32, color: Color) {
    batcher_semicircle_gradient(b, center, start_radians, end_radians, radius, steps, color, color);
}

batcher_semicircle_gradient :: (b: *Batcher, center: Vector2, start_radians: float, end_radians: float, radius: float, steps: s32, center_color: Color, edge_color: Color) {
    last := angle_to_vector(start_radians, radius);
    for i: 1..steps {
        next := angle_to_vector(start_radians + (end_radians - start_radians) * (cast(float) i / cast(float) steps), radius);
        batcher_triangle_gradient(b, center + last, center + next, center, edge_color, edge_color, center_color);
        last = next;
    }
}

batcher_semicircle_line :: (b: *Batcher, center: Vector2, start_radians: float, end_radians: float, radius: float, steps: s32, t: float, color: Color) {
    if t >= radius {
        batcher_semicircle(b, center, start_radians, end_radians, radius, steps, color);
    } else {
        last := angle_to_vector(start_radians, 1.0);
        r0 := radius - t;
        r1 := radius;
        for i: 1..steps {
            next := angle_to_vector(start_radians + (end_radians - start_radians) * (cast(float) i / cast(float) steps), 1.0);
            batcher_quad(b, center + last * r0, center + last * r1, center + next * r1, center + next * r0, color);
            last = next;
        }
    }
}

batcher_circle :: (b: *Batcher, center: Vector2, radius: float, steps: s32, color: Color) {
    batcher_circle_gradient(b, center, radius, steps, color, color);
}

batcher_circle_gradient :: (b: *Batcher, center: Vector2, radius: float, steps: s32, center_color: Color, edge_color: Color) {
    if steps < 3 return;
    vertices, indices, vertex_start := batcher_request(b, steps + 1, steps * 3);

    // center vertex
    vertices[0].pos = vector2_transform(center, b.Matrix);
    vertices[0].col = center_color;
    vertices[0].mode = Batcher_Mode_Fill;

    i := 0;
    for n: 0..steps-1 {
        next := angle_to_vector(cast(float) n / cast(float) steps * TAU, radius);
        vertices[n + 1].pos = vector2_transform(center + next, b.Matrix);
        vertices[n + 1].col = edge_color;
        vertices[n + 1].mode = Batcher_Mode_Fill;

        indices[i + 0] = vertex_start;                       // center
        indices[i + 1] = vertex_start + 1 + n;
        indices[i + 2] = vertex_start + 1 + (n + 1) % steps;
        i += 3;
    }
}

batcher_circle_line :: (b: *Batcher, center: Vector2, radius: float, line_weight: float, steps: s32, color: Color) {
    inner_radius := radius - line_weight;
    if inner_radius <= 0 {
        batcher_circle(b, center, radius, steps, color);
        return;
    }
    last := angle_to_vector(0.0, 1.0);
    for i: 1..steps {
        next := angle_to_vector(cast(float) i / cast(float) steps * TAU, 1.0);
        batcher_quad(b,
            center + last * inner_radius, center + last * radius,
            center + next * radius, center + next * inner_radius,
            color);
        last = next;
    }
}

batcher_circle_dashed :: (b: *Batcher, center: Vector2, radius: float, line_weight: float, steps: s32, color: Color, dash_length: float, dash_offset: float) {
    last := angle_to_vector(0.0, radius);
    segment_length := vector2_length(last - angle_to_vector(TAU / cast(float) steps, radius));
    for i: 1..steps {
        next := angle_to_vector(cast(float) i / cast(float) steps * TAU, radius);
        batcher_line_dashed(b, center + last, center + next, line_weight, color, dash_length, dash_offset);
        dash_offset += segment_length;
        last = next;
    }
}

batcher_radial_bar :: (b: *Batcher, position: Vector2, percent: float, inner_radius: float, outer_radius: float, color: Color) {
    if percent <= 0 return;

    segments :: 64;
    single_segment :: 1.0 / segments;
    bar_radius := (outer_radius - inner_radius) / 2.0;

    batcher_push_matrix(b, matrix3x2_create_translation(position.x, position.y));
    if percent < single_segment {
        scale := percent / single_segment;
        batcher_circle(b, .{ (inner_radius + outer_radius) / 2.0, 0 }, bar_radius * scale, 16, color);
    } else {
        for i: 0..segments-1 {
            prev := cast(float) i / segments;
            next := min(percent, cast(float) (i + 1) / segments);
            prev_angle := angle_to_vector(prev * TAU, 1.0);
            next_angle := angle_to_vector(next * TAU, 1.0);
            prev_inner := prev_angle * inner_radius;
            prev_outer := prev_angle * outer_radius;
            next_inner := next_angle * inner_radius;
            next_outer := next_angle * outer_radius;

            if percent < 0.99 {
                if prev <= 0 batcher_circle(b, (prev_inner + prev_outer) / 2.0, bar_radius, 16, color);
                if next >= percent batcher_circle(b, (next_inner + next_outer) / 2.0, bar_radius, 16, color);
            }
            batcher_quad(b, prev_inner, prev_outer, next_outer, next_inner, color);
            if next >= percent break;
        }
    }
    batcher_pop_matrix(b);
}

//
// primitives — images
//

batcher_image_full :: (b: *Batcher, texture: *Texture, color: Color) {
    w := cast(float) texture.Width;
    h := cast(float) texture.Height;
    batcher_quad_textured(b, texture,
        .{ 0, 0 }, .{ w, 0 }, .{ w, h }, .{ 0, h },
        .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 },
        color);
}

batcher_image :: (b: *Batcher, texture: *Texture, position: Vector2, color: Color) {
    w := cast(float) texture.Width;
    h := cast(float) texture.Height;
    batcher_quad_textured(b, texture,
        position, position + .{ w, 0 }, position + .{ w, h }, position + .{ 0, h },
        .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 },
        color);
}

batcher_image_trs :: (b: *Batcher, texture: *Texture, position: Vector2, origin: Vector2, scale_v: Vector2, rotation: float, color: Color) {
    was := b.Matrix;
    b.Matrix = matrix3x2_create_transform(position, origin, scale_v, rotation) * b.Matrix;
    batcher_image_full(b, texture, color);
    b.Matrix = was;
}

batcher_image_clip :: (b: *Batcher, texture: *Texture, clip: Rect, position: Vector2, color: Color) {
    tw := cast(float) texture.Width;
    th := cast(float) texture.Height;
    tx0 := clip.x / tw;   ty0 := clip.y / th;
    tx1 := rect_right(clip) / tw;   ty1 := rect_bottom(clip) / th;
    batcher_quad_textured(b, texture,
        position, position + .{ clip.w, 0 }, position + .{ clip.w, clip.h }, position + .{ 0, clip.h },
        .{ tx0, ty0 }, .{ tx1, ty0 }, .{ tx1, ty1 }, .{ tx0, ty1 },
        color);
}

batcher_image_clip_trs :: (b: *Batcher, texture: *Texture, clip: Rect, position: Vector2, origin: Vector2, scale_v: Vector2, rotation: float, color: Color) {
    was := b.Matrix;
    b.Matrix = matrix3x2_create_transform(position, origin, scale_v, rotation) * b.Matrix;
    batcher_image_clip(b, texture, clip, .{ 0, 0 }, color);
    b.Matrix = was;
}

batcher_subtexture :: (b: *Batcher, subtex: Subtexture, color: Color) {
    if subtex.Tex == null return;
    batcher_quad_textured(b, subtex.Tex,
        subtex.DrawCoords[0], subtex.DrawCoords[1], subtex.DrawCoords[2], subtex.DrawCoords[3],
        subtex.TexCoords[0],  subtex.TexCoords[1],  subtex.TexCoords[2],  subtex.TexCoords[3],
        color);
}

batcher_subtexture_at :: (b: *Batcher, subtex: Subtexture, position: Vector2, color: Color) {
    if subtex.Tex == null return;
    batcher_quad_textured(b, subtex.Tex,
        position + subtex.DrawCoords[0], position + subtex.DrawCoords[1],
        position + subtex.DrawCoords[2], position + subtex.DrawCoords[3],
        subtex.TexCoords[0],  subtex.TexCoords[1],  subtex.TexCoords[2],  subtex.TexCoords[3],
        color);
}

batcher_subtexture_trs :: (b: *Batcher, subtex: Subtexture, position: Vector2, origin: Vector2, scale_v: Vector2, rotation: float, color: Color) {
    if subtex.Tex == null return;
    was := b.Matrix;
    b.Matrix = matrix3x2_create_transform(position, origin, scale_v, rotation) * b.Matrix;
    batcher_subtexture(b, subtex, color);
    b.Matrix = was;
}

//
// helpers (Calc subset used by the primitives)
//

angle_to_vector :: (radians: float, length := 1.0) -> Vector2 {
    return .{ cos(radians) * length, sin(radians) * length };
}

vector2_normalize :: (v: Vector2) -> Vector2 {
    len := sqrt(v.x * v.x + v.y * v.y);
    if len == 0 return .{ 0, 0 };
    return v / len;
}

vector2_length :: (v: Vector2) -> float {
    return sqrt(v.x * v.x + v.y * v.y);
}

vector2_turn_left :: (v: Vector2) -> Vector2 {
    return .{ v.y, -v.x };
}

mod_f32 :: (a: float, b: float) -> float {
    return a - b * floor(a / b);
}
