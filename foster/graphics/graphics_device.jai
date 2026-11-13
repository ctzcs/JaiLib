#scope_module
using Basic;
using Math;
using Hash_Table;
#scope_export

// Port of Foster Framework/Graphics/GraphicsDevice.cs (public validation layer)
// + the backend contract implemented in internal/graphics_device_sdl.jai.

Graphics_Driver :: enum {
    NONE;
    PRIVATE;
    VULKAN;
    D3D12;
    METAL;
}

// Returns the shader blob extension used by the given driver.
graphics_driver_shader_extension :: (driver: Graphics_Driver) -> string {
    if driver == .VULKAN || driver == .PRIVATE return "spv";
    if driver == .D3D12 return "dxil";
    if driver == .METAL return "msl";
    return "spv";
}

Graphics_Resource_Handle :: u64;   // 0 = null handle

// Constants shared with the backend (Foster GraphicsDeviceSDL).
MAX_FRAMES_IN_FLIGHT   :: 3;
TRANSFER_BUFFER_SIZE   :: 16 * 1024 * 1024;   // 16MB
MAX_UPLOAD_CYCLE_COUNT :: 4;
MAX_COLOR_ATTACHMENTS  :: 8;

GPU_Resource_Kind :: enum {
    TEXTURE;
    TARGET;
    BUFFER;
    SHADER;
    COMPUTE;
}

// Flattened equivalent of Foster's Resource subclasses (TextureResource,
// TargetResource, BufferResource, ShaderResource, ComputeResource).
GPU_Resource :: struct {
    kind: GPU_Resource_Kind;
    handle: Graphics_Resource_Handle;

    // TEXTURE
    texture:              *SDL_GPUTexture;
    width, height:        s32;
    format:               SDL_GPUTextureFormat;
    sample_count:         SDL_GPUSampleCount;
    multi_sample_resolve: Graphics_Resource_Handle;   // set when multisampled

    // TARGET
    attachments: [..] Graphics_Resource_Handle;

    // BUFFER
    name:         string;
    usage:        SDL_GPUBufferUsageFlags;
    index_format: Index_Format;
    buffer:       *SDL_GPUBuffer;
    capacity:     s32;
    dirty:        bool;

    // SHADER (pipelines: hashes of dependent graphics pipelines)
    shader: *SDL_GPUShader;
    pipelines: [..] u64;

    // COMPUTE
    pipeline: *SDL_GPUComputePipeline;
}

GPU_Window_State :: struct {
    id:     u32;
    handle: *SDL_Window;
    reclaim_pending: bool;
    claimed: bool;
    backbuffer: *Target;
    backbuffer_size: Point2;
    supports_mailbox_present_mode: bool;
    supports_immediate_present_mode: bool;
    present_mode: SDL_GPUPresentMode;
    has_present_mode: bool = false;
}

Graphics_Device :: struct {
    driver: Graphics_Driver = .NONE;
    disposed: bool = true;   // true until created (device == null)

    // object pointers
    device: *SDL_GPUDevice = null;
    cmd_upload: *SDL_GPUCommandBuffer = null;
    cmd_render: *SDL_GPUCommandBuffer = null;
    render_pass: *SDL_GPURenderPass = null;
    copy_pass: *SDL_GPUCopyPass = null;

    // render pass state
    render_pass_target: Drawable_Target;
    render_pass_target_size: Point2;
    render_pass_pipeline: *SDL_GPUGraphicsPipeline = null;
    render_pass_vertex_buffers: [4] Graphics_Resource_Handle;  render_pass_vertex_buffer_count: s32 = 0;
    render_pass_index_buffer: Graphics_Resource_Handle = 0;
    render_pass_scissor: Rect_Int;  has_render_pass_scissor: bool = false;
    render_pass_viewport: Rect_Int; has_render_pass_viewport: bool = false;

    // state
    vsync_enabled: bool = false;
    // Completed present boundaries; lets Batcher reuse slots on the next frame.
    present_serial: u64;
    in_background: bool = false;
    windows: Table(u32, *GPU_Window_State);

    // tracked / allocated resources
    samplers: Table(u32, *SDL_GPUSampler);        // key: packed Texture_Sampler
    pipelines: Table(u64, *SDL_GPUGraphicsPipeline);
    resources: Table(Graphics_Resource_Handle, *GPU_Resource);
    empty_default_texture: Graphics_Resource_Handle = 0;
    empty_default_compute_storage_texture: Graphics_Resource_Handle = 0;
    empty_default_buffer: Graphics_Resource_Handle = 0;
    next_resource_id: u64 = 0;

    // transfer buffers
    buffer_upload_buffer: *SDL_GPUTransferBuffer = null;
    buffer_upload_buffer_offset: u32;
    buffer_upload_cycle_count: u32;
    texture_upload_buffer: *SDL_GPUTransferBuffer = null;
    texture_upload_buffer_offset: u32;
    texture_upload_cycle_count: u32;
    texture_download_buffer: *SDL_GPUTransferBuffer = null;
    texture_download_buffer_size: u32;
    texture_download_mutex: Mutex;

    // backbuffer format (Foster: [(Color, None, One)]; MSAA flag upgrades it)
    backbuffer_format: Target_Attachment_Info = .{ Format = .COLOR, Flags = .NONE, SampleCount = .ONE };

    preferred: Graphics_Driver = .NONE;
    flags: App_Flags;

    // Defaults (default materials/fonts)
    defaults: *Default_Resources = null;
}

graphics_device_set_vsync :: (d: *Graphics_Device, enabled: bool) {
    assert(d.device != null, "GPU Device has not been created");
    d.vsync_enabled = enabled;
    for state: d.windows {   // 值已是 *GPU_Window_State（本地补丁 #4：原为 for *state 双重指针）
        sdl_update_window_present_mode(d, state, enabled);
    }
}

graphics_device_is_texture_format_supported :: (d: *Graphics_Device, format: Texture_Format) -> bool {
    usage: SDL_GPUTextureUsageFlags = .SDL_GPU_TEXTUREUSAGE_SAMPLER;
    if texture_format_is_depth_stencil(format) {
        usage |= .SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET;
    } else {
        usage |= .SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
    }
    return SDL_GPUTextureSupportsFormat(d.device, sdl_get_texture_format(format), .SDL_GPU_TEXTURETYPE_2D, usage);
}

graphics_device_is_texture_multi_sample_supported :: (d: *Graphics_Device, format: Texture_Format, sample_count: Sample_Count) -> bool {
    return SDL_GPUTextureSupportsSampleCount(d.device, sdl_get_texture_format(format), sdl_get_sample_count(sample_count));
}

// The (oversized) off-screen backbuffer Target a window renders into before
// being blitted to its swapchain.
graphics_device_get_backbuffer :: (d: *Graphics_Device, window: *Window) -> *Target {
    // table_find_pointer 在官方 Jai 与 jacket 上签名一致（返回 *Value，缺失为 null）；
    // 而 table_find 的返回顺序两个编译器相反，所以这里统一用指针版。
    state := table_find_pointer(*d.windows, window.id);
    if state != null return (<<state).backbuffer;
    return null;
}

graphics_device_insert_debug_label :: (d: *Graphics_Device, text: string) {
    if d.cmd_render != null {
        c := to_cstr(text);
        SDL_InsertGPUDebugLabel(d.cmd_render, c);
        free(c);
    }
}

//
// Public draw/dispatch entry points (validation, then backend perform).
// Port of GraphicsDevice.Draw / Dispatch.
//

graphics_device_draw :: (d: *Graphics_Device, command: Draw_Command) {
    // invalid shader state
    assert(command.VertexShader != null && !shader_is_disposed(command.VertexShader),
           "Attempting to render a null or disposed Vertex Shader");
    assert(command.FragmentShader != null && !shader_is_disposed(command.FragmentShader),
           "Attempting to render a null or disposed Fragment Shader");

    // invalid target state
    assert(command.Target.Kind != .NONE, "Attempting to render a null Target");
    if command.Target.Kind == .TARGET {
        assert(!target_is_disposed(command.Target.target), "Attempting to render a disposed Target");
    }

    // invalid index buffer state
    if command.IndexBuffer != null && buffer_is_disposed(command.IndexBuffer) {
        assert(false, "Attempting to render with a disposed Index Buffer");
    }

    // using vertex count with an index buffer
    if command.IndexBuffer != null && command.VertexCount != 0 {
        assert(false, "Attempting to render using a Vertex Count with an Index Buffer. Use IndexCount instead.");
    }
    // using index offset/count without an index buffer
    if command.IndexBuffer == null && (command.IndexOffset != 0 || command.IndexCount != 0) {
        assert(false, "Attempting to render using Index Offset/Count without an Index Buffer.");
    }

    // validate vertex buffers
    for i: 0..command.VertexBufferCount-1 {
        it := command.VertexBuffers[i].Buffer;
        assert(it != null && !buffer_is_disposed(it), "Attempting to render a null or disposed Vertex Buffer");
        if it.handle == 0 || it.Count <= 0 {
            log_warning("Attempting to render an empty Vertex Buffer; Nothing will be drawn");
            return;
        }
    }

    // validate storage buffers
    for i: 0..command.VertexStorageBufferCount-1 {
        assert(command.VertexStorageBuffers[i] != null && !buffer_is_disposed(command.VertexStorageBuffers[i]),
               "Attempting to render a null or disposed Vertex Storage Buffer");
    }
    for i: 0..command.FragmentStorageBufferCount-1 {
        assert(command.FragmentStorageBuffers[i] != null && !buffer_is_disposed(command.FragmentStorageBuffers[i]),
               "Attempting to render a null or disposed Fragment Storage Buffer");
    }

    // using an index buffer that is empty
    if command.IndexBuffer != null && command.IndexBuffer.Count <= 0 {
        log_warning("Attempting to render an empty Index Buffer; Nothing will be drawn");
        return;
    }
    // using an index buffer without an index count
    if command.IndexBuffer != null && command.IndexCount <= 0 {
        log_warning("Attempting to render from an Index Buffer while using an IndexCount of 0; Nothing will be drawn");
        return;
    }
    // not using an index buffer and no vertex count
    if command.IndexBuffer == null && command.VertexCount <= 0 {
        log_warning("Attempting to render with a VertexCount of 0; Nothing will be drawn");
        return;
    }
    // invalid viewport
    if command.HasViewport && (command.Viewport.w <= 0 || command.Viewport.h <= 0) {
        log_warning("Attempting to render with an empty Viewport; Nothing will be drawn");
        return;
    }
    // invalid scissor
    if command.HasScissor && (command.Scissor.w <= 0 || command.Scissor.h <= 0) {
        log_warning("Attempting to render with an empty Scissor; Nothing will be drawn");
        return;
    }

    sdl_perform_draw(d, command);
}

graphics_device_dispatch :: (d: *Graphics_Device, command: Compute_Command) {
    assert(command.shader != null && !shader_is_disposed(command.shader),
           "Attempting to dispatch with a null or disposed Shader");
    assert(command.shader.Stage == .COMPUTE,
           "Attempting to dispatch a Compute command with a Shader that is not a Compute shader");

    if command.GroupCountX <= 0 || command.GroupCountY <= 0 || command.GroupCountZ <= 0 {
        log_warning("Attempting to dispatch with a group count of 0; Nothing will be dispatched");
        return;
    }

    for i: 0..command.ReadOnlyStorageBufferCount-1 {
        assert(command.ReadOnlyStorageBuffers[i] != null && !buffer_is_disposed(command.ReadOnlyStorageBuffers[i]),
               "Attempting to dispatch with a null or disposed read-only Storage Buffer");
    }
    for i: 0..command.ReadWriteStorageBufferCount-1 {
        assert(command.ReadWriteStorageBuffers[i] != null && !buffer_is_disposed(command.ReadWriteStorageBuffers[i]),
               "Attempting to dispatch with a null or disposed read-write Storage Buffer");
    }

    sdl_perform_dispatch(d, command);
}

// Clears a drawable target (port of IDrawableTarget.Clear extension).
graphics_device_clear :: (d: *Graphics_Device, target: Drawable_Target, color: [] Color, depth: float, stencil: s32, mask: Clear_Mask) {
    if mask != .NONE {
        sdl_clear(d, target, color, depth, stencil, mask);
    }
}

graphics_device_clear_color :: (d: *Graphics_Device, target: Drawable_Target, color: Color) {
    colors: [1] Color; colors[0] = color;
    graphics_device_clear(d, target, colors, 1, 0, .COLOR);
}

//
// Lifecycle + resource entry points — forwarding to the SDL backend
// (internal/graphics_device_sdl.jai). These are public so advanced users
// (and our samples) can drive the device directly.
//

graphics_device_create           :: (preferred: Graphics_Driver, flags: App_Flags) -> *Graphics_Device { return sdl_device_create(preferred, flags); }
graphics_device_shutdown         :: (device: *Graphics_Device) { sdl_shutdown(device); }
graphics_device_destroy_device   :: (device: *Graphics_Device) { sdl_destroy_device(device); }
graphics_device_present          :: (device: *Graphics_Device) {
    sdl_present(device);
    device.present_serial += 1;
}
graphics_device_window_created   :: (device: *Graphics_Device, window: *Window) { sdl_window_created(device, window); }
graphics_device_window_destroyed :: (device: *Graphics_Device, window: *Window) { sdl_window_destroyed(device, window); }
graphics_device_on_event         :: (device: *Graphics_Device, ev: SDL_EventType) { sdl_on_event(device, ev); }

graphics_device_create_texture     :: (device: *Graphics_Device, name: string, width: s32, height: s32, format: Texture_Format, flags: Texture_Flags, sample_count: Sample_Count, target_binding: Graphics_Resource_Handle) -> Graphics_Resource_Handle { return sdl_create_texture(device, name, width, height, format, flags, sample_count, target_binding); }
graphics_device_set_texture_data   :: (device: *Graphics_Device, texture: Graphics_Resource_Handle, data: *void, length: s32, dest_region: Rect_Int) { sdl_set_texture_data(device, texture, data, length, dest_region); }
graphics_device_get_texture_data   :: (device: *Graphics_Device, texture: Graphics_Resource_Handle, data: *void, length: s32, source_region: Rect_Int) { sdl_get_texture_data(device, texture, data, length, source_region); }
graphics_device_blit_texture       :: (device: *Graphics_Device, source: Graphics_Resource_Handle, source_region: Rect_Int, dest: Graphics_Resource_Handle, dest_region: Rect_Int, filter: Texture_Filter) { sdl_blit_texture(device, source, source_region, dest, dest_region, filter); }
graphics_device_create_target      :: (device: *Graphics_Device, width: s32, height: s32) -> Graphics_Resource_Handle { return sdl_create_target(device, width, height); }
graphics_device_create_shader      :: (device: *Graphics_Device, shader: *Shader, code: [] u8, entry_point: string) -> Graphics_Resource_Handle { return sdl_create_shader(device, shader, code, entry_point); }
graphics_device_create_buffer      :: (device: *Graphics_Device, name: string, type: Buffer_Kind, format: Index_Format) -> Graphics_Resource_Handle { return sdl_create_buffer(device, name, type, format); }
graphics_device_upload_buffer_data :: (device: *Graphics_Device, buffer: Graphics_Resource_Handle, data: *void, data_size: s32, data_dest_offset: s32) { sdl_upload_buffer_data(device, buffer, data, data_size, data_dest_offset); }
graphics_device_destroy_resource   :: (device: *Graphics_Device, resource: Graphics_Resource_Handle) { sdl_destroy_resource(device, resource); }
