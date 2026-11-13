#scope_module
using Basic;
using Math;
using Hash_Table;


#scope_export

// Port of Foster Framework/Graphics/Defaults/DefaultResources.cs.
// Compiled shaders and Roboto MSDF data are embedded at compile time, like
// Foster's assembly resources. No runtime content directory is required.

Default_Resources :: struct {
    device: *Graphics_Device;

    batch_material:     *Material = null;   // Batcher shader
    textured_material:  *Material = null;   // PosTexColVertex shader
    msdf_material:      *Material = null;
    msdf_font:          *Msdf_Font = null;
}

defaults_get :: (device: *Graphics_Device) -> *Default_Resources {
    if device.defaults == null {
        d := New(Default_Resources);
        d.device = device;
        device.defaults = d;
    }
    return device.defaults;
}

defaults_load_shader :: (device: *Graphics_Device, name: string, stage: Shader_Stage) -> *Shader {
    code := defaults_shader_bytes(name, stage, device.driver);
    if code.count == 0 {
        log_warning(tprint("No embedded default shader '%' for stage % / driver %", name, stage, device.driver));
        return null;
    }
    sampler_count: s32 = 0;
    uniform_count: s32 = 0;
    entry := "fragment_main";
    if stage == .VERTEX {
        entry = "vertex_main";
        uniform_count = 1;
    } else {
        sampler_count = 1;
        if name == "Msdf" uniform_count = 1;
    }
    return shader_create(device, stage, code,
        sampler_count        = sampler_count,
        uniform_buffer_count = uniform_count,
        entry_point = entry,
        name = name);
}

// Batcher shader material (BatcherVertex layout, 1 frag sampler, 1 vert uniform)
defaults_batch_material :: (device: *Graphics_Device) -> *Material {
    defaults := defaults_get(device);
    if defaults.batch_material == null {
        vs := defaults_load_shader(device, "Batcher", .VERTEX);
        fs := defaults_load_shader(device, "Batcher", .FRAGMENT);
        assert(vs != null && fs != null, "failed to load default Batcher shaders");
        defaults.batch_material = material_create(vs, fs);
    }
    return defaults.batch_material;
}

// Textured shader material (PosTexColVertex layout, 1 frag sampler, 1 vert uniform)
defaults_textured_material :: (device: *Graphics_Device) -> *Material {
    defaults := defaults_get(device);
    if defaults.textured_material == null {
        vs := defaults_load_shader(device, "Textured", .VERTEX);
        fs := defaults_load_shader(device, "Textured", .FRAGMENT);
        assert(vs != null && fs != null, "failed to load default Textured shaders");
        defaults.textured_material = material_create(vs, fs);
    }
    return defaults.textured_material;
}

defaults_msdf_material :: (device: *Graphics_Device) -> *Material {
    defaults := defaults_get(device);
    if defaults.msdf_material == null {
        vs := defaults_load_shader(device, "Msdf", .VERTEX);
        fs := defaults_load_shader(device, "Msdf", .FRAGMENT);
        assert(vs != null && fs != null, "failed to load embedded MSDF shaders");
        defaults.msdf_material = material_create(vs, fs);
    }
    return defaults.msdf_material;
}

defaults_msdf_font :: (device: *Graphics_Device) -> *Msdf_Font {
    defaults := defaults_get(device);
    if defaults.msdf_font == null {
        defaults.msdf_font = msdf_font_load_bytes(cast([] u8) EMBEDDED_ROBOTO_JSON, cast([] u8) EMBEDDED_ROBOTO_PNG);
        assert(defaults.msdf_font != null, "failed to decode embedded Roboto font");
    }
    return defaults.msdf_font;
}

// Device owns these cached resources; borrowed callers must not destroy them.
defaults_destroy :: (device: *Graphics_Device) {
    defaults := device.defaults;
    if defaults == null return;
    materials: [3] *Material = .[defaults.batch_material, defaults.textured_material, defaults.msdf_material];
    for mat: materials {
        if mat == null continue;
        shader_dispose(mat.Vertex.shader);
        shader_dispose(mat.Fragment.shader);
        free(mat.Vertex.shader);
        free(mat.Fragment.shader);
        material_destroy(mat);
    }
    if defaults.msdf_font != null msdf_font_destroy(defaults.msdf_font);
    free(defaults);
    device.defaults = null;
}
