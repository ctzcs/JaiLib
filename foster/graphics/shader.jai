#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Shader.cs.

Shader :: struct {
    device: *Graphics_Device;
    handle: Graphics_Resource_Handle;

    Stage: Shader_Stage;
    Name: string;

    SamplerCount: s32;
    UniformBufferCount: s32;
    // Vertex/Fragment only
    StorageBufferCount: s32;
    // Compute only
    ReadOnlyStorageTextureCount: s32;
    ReadOnlyStorageBufferCount: s32;
    ReadWriteStorageTextureCount: s32;
    ReadWriteStorageBufferCount: s32;
    ThreadCountX: s32 = 1;
    ThreadCountY: s32 = 1;
    ThreadCountZ: s32 = 1;

    is_disposed: bool;
}

Shader_Create_Info :: struct {
    Stage: Shader_Stage;
    Bytes: [] u8; // 'Code' shadows a Jai primitive type
    SamplerCount: s32 = 0;
    UniformBufferCount: s32 = 0;
    StorageBufferCount: s32 = 0;
    EntryPoint: string = "main";
}

shader_create :: (
    device: *Graphics_Device,
    stage: Shader_Stage,
    code: [] u8,
    sampler_count: s32 = 0,
    uniform_buffer_count: s32 = 0,
    storage_buffer_count: s32 = 0,
    read_only_storage_texture_count: s32 = 0,
    read_only_storage_buffer_count: s32 = 0,
    read_write_storage_texture_count: s32 = 0,
    read_write_storage_buffer_count: s32 = 0,
    thread_count_x: s32 = 1,
    thread_count_y: s32 = 1,
    thread_count_z: s32 = 1,
    entry_point := "main",
    name := ""
) -> *Shader {
    s := New(Shader);
    s.device = device;
    s.Stage = stage;
    s.Name = name;
    s.SamplerCount = sampler_count;
    s.UniformBufferCount = uniform_buffer_count;
    s.StorageBufferCount = storage_buffer_count;
    s.ReadOnlyStorageTextureCount = read_only_storage_texture_count;
    s.ReadOnlyStorageBufferCount = read_only_storage_buffer_count;
    s.ReadWriteStorageTextureCount = read_write_storage_texture_count;
    s.ReadWriteStorageBufferCount = read_write_storage_buffer_count;
    s.ThreadCountX = thread_count_x;
    s.ThreadCountY = thread_count_y;
    s.ThreadCountZ = thread_count_z;
    s.handle = graphics_device_create_shader(device, s, code, entry_point);
    return s;
}

// Recreates the shader with new code (invalidates dependent pipelines).
shader_recreate :: (s: *Shader, code: [] u8, entry_point := "main") {
    assert(!s.is_disposed && !s.device.disposed, "Cannot recreate a disposed Shader");
    graphics_device_destroy_resource(s.device, s.handle);
    s.handle = graphics_device_create_shader(s.device, s, code, entry_point);
}

shader_dispose :: (s: *Shader) {
    if !s.is_disposed {
        graphics_device_destroy_resource(s.device, s.handle);
        s.is_disposed = true;
    }
}

shader_is_disposed :: (s: *Shader) -> bool {
    return s.is_disposed || s.device.disposed;
}
