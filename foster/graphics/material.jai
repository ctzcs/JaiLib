#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Material.cs.

Material_Stage :: struct {
    Stage: Shader_Stage;
    shader: *Shader = null; // 'Shader' would shadow the type name; must match Stage

    Samplers: [16] Bound_Sampler;
    UniformBuffers: [8] Uniform_Buffer;
}

material_stage_set_shader :: (s: *Material_Stage, shader: *Shader) {
    if shader != null {
        assert(shader.Stage == s.Stage, "Invalid Shader Stage");
    }
    s.shader = shader;
}

material_stage_set_uniform :: (s: *Material_Stage, slot: s32, data: [] u8) {
    uniform_buffer_set(*s.UniformBuffers[slot], data);
}

material_stage_set_uniform_value :: (s: *Material_Stage, slot: s32, value: $T) {
    local := value; // stable stack copy — & of a by-value param is unsafe past 32 bytes
    uniform_buffer_set_value(*s.UniformBuffers[slot], *local);
}

material_stage_get_uniform :: (s: *Material_Stage, slot: s32) -> [] u8 {
    return uniform_buffer_get(*s.UniformBuffers[slot]);
}

material_stage_copy_to :: (from: *Material_Stage, to: *Material_Stage) {
    to.shader = from.shader;
    for i: 0..15 to.Samplers[i] = from.Samplers[i];
    for i: 0..7 {
        uniform_buffer_copy_to(*from.UniformBuffers[i], *to.UniformBuffers[i]);
    }
}

material_stage_equal_to :: (a: *Material_Stage, b: *Material_Stage) -> bool {
    if a.shader != b.shader return false;
    for i: 0..15 {
        if a.Samplers[i] != b.Samplers[i] return false;
    }
    for i: 0..7 {
        if !uniform_buffer_equal_to(*a.UniformBuffers[i], *b.UniformBuffers[i]) return false;
    }
    return true;
}

Material :: struct {
    Vertex: Material_Stage;
    Fragment: Material_Stage;
}

material_create :: (vertex_shader: *Shader = null, fragment_shader: *Shader = null) -> *Material {
    m := New(Material);
    m.Vertex.Stage = .VERTEX;
    m.Fragment.Stage = .FRAGMENT;
    material_stage_set_shader(*m.Vertex, vertex_shader);
    material_stage_set_shader(*m.Fragment, fragment_shader);
    return m;
}

material_copy_to :: (from: *Material, to: *Material) {
    material_stage_copy_to(*from.Vertex, *to.Vertex);
    material_stage_copy_to(*from.Fragment, *to.Fragment);
}

material_copy_from :: (to: *Material, from: *Material) {
    material_copy_to(from, to);
}

material_clone :: (m: *Material) -> *Material {
    clone := material_create();
    material_copy_to(m, clone);
    return clone;
}

material_equal_to :: (a: *Material, b: *Material) -> bool {
    if a == b return true;
    return material_stage_equal_to(*a.Vertex, *b.Vertex) && material_stage_equal_to(*a.Fragment, *b.Fragment);
}

material_destroy :: (m: *Material) {
    for i: 0..7 {
        uniform_buffer_destroy(*m.Vertex.UniformBuffers[i]);
        uniform_buffer_destroy(*m.Fragment.UniformBuffers[i]);
    }
    free(m);
}
