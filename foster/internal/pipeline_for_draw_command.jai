#scope_module
using Basic;
using Math;
#scope_module

// Reusable graphics-pipeline construction for one Draw_Command — the *non-fatal*
// twin of sdl_get_graphics_pipeline (internal/graphics_device_sdl_draw.jai).
//
// Why a second entry point instead of a parameter on the existing one:
//   * sdl_get_graphics_pipeline is the draw path: it hash-caches every pipeline
//     in device.pipelines and `assert(false)`s when SDL rejects the create info
//     (an invalid candidate shader must not take the process down).
//   * This entry point is the validation path used by ShaderPairTryReplace: it
//     assembles the exact same SDL_GPUGraphicsPipelineCreateInfo from the same
//     Draw_Command fields (same state mappings, same target-format discovery,
//     same vertex-attribute flattening) but returns null on rejection and logs
//     the SDL error instead of asserting.
//   * It deliberately does NOT touch device.pipelines: a probe pipeline is
//     thrown away right after creation, so the cache can never end up holding a
//     released pipeline, and no pipeline bookkeeping is attributed to shaders
//     that may be discarded one line later.
//
// The assembly below mirrors internal/graphics_device_sdl_draw.jai
// (sdl_get_graphics_pipeline, "otherwise create a new one") field for field.
// Keep the two in sync when the draw path changes.

// Vertex_Format holds at most 32 elements (graphics/vertex_format.jai); a single
// pipeline flattens all vertex buffers into one attribute list of 64.
MAX_PIPELINE_VERTEX_ATTRIBUTES :: 64;

// Builds (but does not cache, bind or retain) a graphics pipeline for `command`.
// Returns null — with the reason already in the log — when SDL rejects it.
// The caller owns the result: SDL_ReleaseGPUGraphicsPipeline it, or use
// pipeline_release_for_draw_command.
pipeline_for_draw_command :: (device: *Graphics_Device, command: Draw_Command) -> *SDL_GPUGraphicsPipeline {
    if device == null || device.device == null return null;
    if command.VertexShader == null || command.FragmentShader == null return null;
    if command.VertexBufferCount < 0 || command.VertexBufferCount > MAX_VERTEX_BUFFERS return null;

    vertex_res := sdl_find_resource(device, command.VertexShader.handle);
    fragment_res := sdl_find_resource(device, command.FragmentShader.handle);
    if vertex_res == null || fragment_res == null return null;
    if vertex_res.kind != .SHADER || fragment_res.kind != .SHADER return null;

    vertex_attribute_count := 0;
    for i: 0..command.VertexBufferCount - 1 {
        buffer := command.VertexBuffers[i].Buffer;
        if buffer == null || buffer.is_disposed return null;
        if buffer.Format.ElementCount < 0 || buffer.Format.ElementCount > 32 return null;
        vertex_attribute_count += buffer.Format.ElementCount;
    }
    if vertex_attribute_count > MAX_PIPELINE_VERTEX_ATTRIBUTES return null;

    color_blend_state := sdl_get_blend_state(command.BlendMode);
    color_attachments: [MAX_COLOR_ATTACHMENTS] SDL_GPUColorTargetDescription;
    color_attachment_count := 0;
    depth_stencil_attachment: SDL_GPUTextureFormat = .SDL_GPU_TEXTUREFORMAT_INVALID;
    vertex_bindings: [MAX_VERTEX_BUFFERS] SDL_GPUVertexBufferDescription;
    vertex_attributes: [64] SDL_GPUVertexAttribute;

    // target attachment formats + sample count (window backbuffer or Target)
    formats: [32] Target_Format_Sample;
    format_count: s32 = 0;
    sdl_get_draw_target_formats(device, command.Target, formats, *format_count);
    if format_count <= 0 {
        log_error("pipeline_for_draw_command: draw target has no attachments");
        return null;
    }

    sample_count: SDL_GPUSampleCount = .SDL_GPU_SAMPLECOUNT_1;
    for i: 0..format_count - 1 {
        if sdl_is_depth_texture_format(formats[i].format) {
            depth_stencil_attachment = formats[i].format;
        } else {
            if color_attachment_count >= MAX_COLOR_ATTACHMENTS {
                log_error("pipeline_for_draw_command: too many color attachments");
                return null;
            }
            color_attachments[color_attachment_count].format = formats[i].format;
            color_attachments[color_attachment_count].blend_state = color_blend_state;
            color_attachment_count += 1;
        }
        if cast(s32) formats[i].sample_count > cast(s32) sample_count {
            sample_count = formats[i].sample_count;
        }
    }

    attrb_index := 0;
    for slot: 0..command.VertexBufferCount - 1 {
        it := command.VertexBuffers[slot].Buffer;
        instance_rate := command.VertexBuffers[slot].InstanceInputRate;
        vertex_offset := 0;

        vertex_bindings[slot].slot = cast(u32) slot;
        vertex_bindings[slot].pitch = cast(u32) it.Format.Stride;
        vertex_bindings[slot].input_rate = ifx instance_rate
            then .SDL_GPU_VERTEXINPUTRATE_INSTANCE else .SDL_GPU_VERTEXINPUTRATE_VERTEX;
        vertex_bindings[slot].instance_step_rate = 0;

        for j: 0..it.Format.ElementCount - 1 {
            el := it.Format.Elements[j];
            vertex_attributes[attrb_index].location = cast(u32) el.Index;
            vertex_attributes[attrb_index].buffer_slot = cast(u32) slot;
            vertex_attributes[attrb_index].format = sdl_get_vertex_format(el.Type, el.Normalized);
            vertex_attributes[attrb_index].offset = cast(u32) vertex_offset;
            vertex_offset += vertex_type_size_in_bytes(el.Type);
            attrb_index += 1;
        }
    }

    info: SDL_GPUGraphicsPipelineCreateInfo;
    info.vertex_shader = vertex_res.shader;
    info.fragment_shader = fragment_res.shader;
    info.vertex_input_state.vertex_buffer_descriptions = vertex_bindings.data;
    info.vertex_input_state.num_vertex_buffers = cast(u32) command.VertexBufferCount;
    info.vertex_input_state.vertex_attributes = vertex_attributes.data;
    info.vertex_input_state.num_vertex_attributes = cast(u32) vertex_attribute_count;

    info.primitive_type = .SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;

    info.rasterizer_state.fill_mode = ifx command.FillMode == .FILL then .SDL_GPU_FILLMODE_FILL else .SDL_GPU_FILLMODE_LINE;
    if command.CullMode == .NONE info.rasterizer_state.cull_mode = .SDL_GPU_CULLMODE_NONE;
    if command.CullMode == .FRONT info.rasterizer_state.cull_mode = .SDL_GPU_CULLMODE_FRONT;
    if command.CullMode == .BACK info.rasterizer_state.cull_mode = .SDL_GPU_CULLMODE_BACK;
    info.rasterizer_state.front_face = .SDL_GPU_FRONTFACE_CLOCKWISE;
    info.rasterizer_state.enable_depth_bias = false;

    info.multisample_state.sample_count = sample_count;
    info.multisample_state.sample_mask = 0; // not used per SDL docs
    info.multisample_state.enable_mask = false; // not used per SDL docs
    info.multisample_state.enable_alpha_to_coverage = false;

    info.depth_stencil_state.compare_op = sdl_get_compare_op(command.DepthCompare);
    info.depth_stencil_state.back_stencil_state.fail_op = sdl_get_stencil_op(command.BackStencilState.FailOp);
    info.depth_stencil_state.back_stencil_state.pass_op = sdl_get_stencil_op(command.BackStencilState.PassOp);
    info.depth_stencil_state.back_stencil_state.depth_fail_op = sdl_get_stencil_op(command.BackStencilState.DepthFailOp);
    info.depth_stencil_state.back_stencil_state.compare_op = sdl_get_compare_op(command.BackStencilState.CompareOp);
    info.depth_stencil_state.front_stencil_state.fail_op = sdl_get_stencil_op(command.FrontStencilState.FailOp);
    info.depth_stencil_state.front_stencil_state.pass_op = sdl_get_stencil_op(command.FrontStencilState.PassOp);
    info.depth_stencil_state.front_stencil_state.depth_fail_op = sdl_get_stencil_op(command.FrontStencilState.DepthFailOp);
    info.depth_stencil_state.front_stencil_state.compare_op = sdl_get_compare_op(command.FrontStencilState.CompareOp);
    info.depth_stencil_state.compare_mask = command.StencilCompareMask;
    info.depth_stencil_state.write_mask = command.StencilWriteMask;
    info.depth_stencil_state.enable_depth_test = command.DepthTestEnabled;
    info.depth_stencil_state.enable_depth_write = command.DepthWriteEnabled;
    info.depth_stencil_state.enable_stencil_test = command.StencilTestEnabled;

    info.target_info.color_target_descriptions = color_attachments.data;
    info.target_info.num_color_targets = cast(u32) color_attachment_count;
    info.target_info.has_depth_stencil_target = depth_stencil_attachment != .SDL_GPU_TEXTUREFORMAT_INVALID;
    info.target_info.depth_stencil_format = depth_stencil_attachment;

    pipeline := SDL_CreateGPUGraphicsPipeline(device.device, *info);
    if pipeline == null {
        log_error(app_sdl_error_message("SDL_CreateGPUGraphicsPipeline",
                                        "candidate pipeline rejected by the GPU backend"));
        return null;
    }
    return pipeline;
}

// Releases a pipeline obtained from pipeline_for_draw_command. Safe on null.
// Only for pipelines this module created *outside* device.pipelines — never call
// it on a pipeline returned by the draw path (those are cached and shared).
pipeline_release_for_draw_command :: (device: *Graphics_Device, pipeline: *SDL_GPUGraphicsPipeline) {
    if pipeline == null return;
    if device == null || device.device == null return;
    SDL_ReleaseGPUGraphicsPipeline(device.device, pipeline);
}
