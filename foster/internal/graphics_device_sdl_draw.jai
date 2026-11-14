#scope_module
using Basic;
using Math;
using Hash_Table;
#scope_module

// Port of Foster GraphicsDeviceSDL.cs — draw/dispatch/clear, command
// buffers, render passes and the graphics-pipeline cache.
// (Lifecyle + resources live in graphics_device_sdl.jai.)


Clear_Info :: struct {
    Colors: [] Color;          // empty (count 0) = no color clear
    Depth: float = 0;
    HasDepth: bool = false;
    Stencil: s32 = 0;
    HasStencil: bool = false;
}

sdl_perform_draw :: (d: *Graphics_Device, command: Draw_Command) {
    assert(d.device != null, "GPU Device has not been created");

    // try to start a render pass
    if !sdl_begin_render_pass(d, command.Target, Clear_Info.{}) return;

    vertex_shader := command.VertexShader;
    fragment_shader := command.FragmentShader;

    // set viewport
    next_viewport := ifx command.HasViewport then command.Viewport
        else Rect_Int.{ 0, 0, d.render_pass_target_size.x, d.render_pass_target_size.y };
    if !d.has_render_pass_viewport || d.render_pass_viewport != next_viewport {
        d.render_pass_viewport = next_viewport;
        d.has_render_pass_viewport = true;
        viewport: SDL_GPUViewport;
        viewport.x = cast(float) next_viewport.x;
        viewport.y = cast(float) next_viewport.y;
        viewport.w = cast(float) next_viewport.w;
        viewport.h = cast(float) next_viewport.h;
        viewport.min_depth = 0;
        viewport.max_depth = 1;
        SDL_SetGPUViewport(d.render_pass, *viewport);
    }

    // set scissor
    next_scissor := ifx command.HasScissor then command.Scissor else next_viewport;
    if !d.has_render_pass_scissor || d.render_pass_scissor != next_scissor {
        d.render_pass_scissor = next_scissor;
        d.has_render_pass_scissor = true;
        scissor: SDL_Rect;
        scissor.x = next_scissor.x;
        scissor.y = next_scissor.y;
        scissor.w = next_scissor.w;
        scissor.h = next_scissor.h;
        SDL_SetGPUScissor(d.render_pass, *scissor);
    }

    // figure out graphics pipeline, potentially create a new one
    pipeline := sdl_get_graphics_pipeline(d, command);
    if d.render_pass_pipeline != pipeline {
        d.render_pass_pipeline = pipeline;
        SDL_BindGPUGraphicsPipeline(d.render_pass, pipeline);
    }

    // bind index buffer
    index_res := ifx command.IndexBuffer != null then sdl_find_resource(d, command.IndexBuffer.handle) else null;
    if index_res == null || d.render_pass_index_buffer != command.IndexBuffer.handle || index_res.dirty {
        d.render_pass_index_buffer = ifx index_res != null then index_res.handle else 0;
        if index_res != null {
            index_res.dirty = false;
            index_binding: SDL_GPUBufferBinding;
            index_binding.buffer = index_res.buffer;
            index_binding.offset = 0;
            index_element_size: SDL_GPUIndexElementSize = .SDL_GPU_INDEXELEMENTSIZE_32BIT;
            if index_res.index_format == .SIXTEEN index_element_size = .SDL_GPU_INDEXELEMENTSIZE_16BIT;
            SDL_BindGPUIndexBuffer(d.render_pass, *index_binding, index_element_size);
        }
    }

    // check if we need to rebind vertex buffers
    rebind_vertex_buffers := d.render_pass_vertex_buffer_count != command.VertexBufferCount;
    if !rebind_vertex_buffers {
        for i: 0..command.VertexBufferCount-1 {
            vb := sdl_require_resource(d, command.VertexBuffers[i].Buffer.handle);
            if d.render_pass_vertex_buffers[i] != vb.handle || vb.dirty {
                rebind_vertex_buffers = true;
                break;
            }
        }
    }

    // bind vertex buffers
    if rebind_vertex_buffers {
        d.render_pass_vertex_buffer_count = 0;

        if command.VertexBufferCount <= 0 {
            SDL_BindGPUVertexBuffers(d.render_pass, 0, null, 0);
        } else {
            vertex_bindings: [MAX_VERTEX_BUFFERS] SDL_GPUBufferBinding;

            for i: 0..command.VertexBufferCount-1 {
                res := sdl_require_resource(d, command.VertexBuffers[i].Buffer.handle);
                res.dirty = false;

                vertex_bindings[i].buffer = res.buffer;
                vertex_bindings[i].offset = 0;

                d.render_pass_vertex_buffers[i] = res.handle;
                d.render_pass_vertex_buffer_count += 1;
            }

            SDL_BindGPUVertexBuffers(d.render_pass, 0, vertex_bindings.data, cast(u32) command.VertexBufferCount);
        }
    }

    // bind vertex samplers
    if vertex_shader.SamplerCount > 0 {
        samplers: [MAX_BOUND_SAMPLERS] SDL_GPUTextureSamplerBinding;
        for i: 0..vertex_shader.SamplerCount-1 {
            value := ifx i < command.VertexSamplerCount then command.VertexSamplers[i] else Bound_Sampler.{};
            tex := ifx value.Tex != null then sdl_find_resource(d, value.Tex.handle) else null;
            if tex != null {
                samplers[i].texture = sdl_sampler_texture(d, tex);
            } else {
                samplers[i].texture = sdl_sampler_texture(d, sdl_require_resource(d, d.empty_default_texture));
            }
            samplers[i].sampler = sdl_get_sampler(d, value.Sampler);
        }
        SDL_BindGPUVertexSamplers(d.render_pass, 0, samplers.data, cast(u32) vertex_shader.SamplerCount);
    }

    // bind fragment samplers
    if fragment_shader.SamplerCount > 0 {
        samplers: [MAX_BOUND_SAMPLERS] SDL_GPUTextureSamplerBinding;
        for i: 0..fragment_shader.SamplerCount-1 {
            value := ifx i < command.FragmentSamplerCount then command.FragmentSamplers[i] else Bound_Sampler.{};
            tex := ifx value.Tex != null then sdl_find_resource(d, value.Tex.handle) else null;
            if tex != null {
                samplers[i].texture = sdl_sampler_texture(d, tex);
            } else {
                samplers[i].texture = sdl_sampler_texture(d, sdl_require_resource(d, d.empty_default_texture));
            }
            samplers[i].sampler = sdl_get_sampler(d, value.Sampler);
        }
        SDL_BindGPUFragmentSamplers(d.render_pass, 0, samplers.data, cast(u32) fragment_shader.SamplerCount);
    }

    // upload vertex uniforms
    for i: 0..vertex_shader.UniformBufferCount-1 {
        if i >= command.VertexUniformBufferCount continue;
        unibuf := command.VertexUniformBuffers[i];
        if unibuf == null continue;
        data := uniform_buffer_get(unibuf);
        if data.count > 0 {
            SDL_PushGPUVertexUniformData(d.cmd_render, cast(u32) i, data.data, cast(u32) data.count);
        }
    }

    // upload fragment uniforms
    for i: 0..fragment_shader.UniformBufferCount-1 {
        if i >= command.FragmentUniformBufferCount continue;
        unibuf := command.FragmentUniformBuffers[i];
        if unibuf == null continue;
        data := uniform_buffer_get(unibuf);
        if data.count > 0 {
            SDL_PushGPUFragmentUniformData(d.cmd_render, cast(u32) i, data.data, cast(u32) data.count);
        }
    }

    // bind vertex storage buffers
    if vertex_shader.StorageBufferCount > 0 {
        buffers: [MAX_STORAGE_BUFFERS] *SDL_GPUBuffer;
        for i: 0..vertex_shader.StorageBufferCount-1 {
            if i < command.VertexStorageBufferCount && command.VertexStorageBuffers[i] != null {
                buffers[i] = sdl_require_resource(d, command.VertexStorageBuffers[i].handle).buffer;
            } else {
                buffers[i] = sdl_require_resource(d, d.empty_default_buffer).buffer;
            }
        }
        SDL_BindGPUVertexStorageBuffers(d.render_pass, 0, buffers.data, cast(u32) vertex_shader.StorageBufferCount);
    }

    // bind fragment storage buffers
    if fragment_shader.StorageBufferCount > 0 {
        buffers: [MAX_STORAGE_BUFFERS] *SDL_GPUBuffer;
        for i: 0..fragment_shader.StorageBufferCount-1 {
            if i < command.FragmentStorageBufferCount && command.FragmentStorageBuffers[i] != null {
                buffers[i] = sdl_require_resource(d, command.FragmentStorageBuffers[i].handle).buffer;
            } else {
                buffers[i] = sdl_require_resource(d, d.empty_default_buffer).buffer;
            }
        }
        SDL_BindGPUFragmentStorageBuffers(d.render_pass, 0, buffers.data, cast(u32) fragment_shader.StorageBufferCount);
    }

    // update stencil reference value
    if command.StencilTestEnabled {
        SDL_SetGPUStencilReference(d.render_pass, command.StencilReferenceValue);
    }

    // perform draw
    if command.IndexBuffer != null {
        SDL_DrawGPUIndexedPrimitives(
            d.render_pass,
            cast(u32) command.IndexCount,
            cast(u32) max(1, command.InstanceCount),
            cast(u32) command.IndexOffset,
            command.VertexOffset,
            0);
    } else {
        SDL_DrawGPUPrimitives(
            d.render_pass,
            cast(u32) command.VertexCount,
            cast(u32) max(1, command.InstanceCount),
            cast(u32) command.VertexOffset,
            0);
    }
}

sdl_perform_dispatch :: (d: *Graphics_Device, command: Compute_Command) {
    assert(d.device != null, "GPU Device has not been created");

    // end any existing renderpass
    sdl_end_render_pass(d);

    shader := command.shader;
    compute_res := sdl_require_resource(d, shader.handle);
    assert(compute_res.kind == .COMPUTE);
    compute_pass: *SDL_GPUComputePass = null;

    // begin compute pass with read-write storage bindings
    {
        rw_texture_bindings: [MAX_STORAGE_BUFFERS] SDL_GPUStorageTextureReadWriteBinding;
        rw_buffer_bindings:  [MAX_STORAGE_BUFFERS] SDL_GPUStorageBufferReadWriteBinding;

        for i: 0..shader.ReadWriteStorageTextureCount-1 {
            if i >= command.ReadWriteStorageTextureCount || command.ReadWriteStorageTextures[i] == null {
                rw_texture_bindings[i].texture = null;
                continue;
            }
            tex := sdl_require_resource(d, command.ReadWriteStorageTextures[i].handle);
            rw_texture_bindings[i].texture = sdl_sampler_texture(d, tex);
            rw_texture_bindings[i].cycle = true;
        }

        for i: 0..shader.ReadWriteStorageBufferCount-1 {
            if i >= command.ReadWriteStorageBufferCount || command.ReadWriteStorageBuffers[i] == null {
                rw_buffer_bindings[i].buffer = null;
                continue;
            }
            buf := sdl_require_resource(d, command.ReadWriteStorageBuffers[i].handle);
            rw_buffer_bindings[i].buffer = buf.buffer;
            rw_buffer_bindings[i].cycle = true;
        }

        compute_pass = SDL_BeginGPUComputePass(
            d.cmd_render,
            rw_texture_bindings.data, cast(u32) shader.ReadWriteStorageTextureCount,
            rw_buffer_bindings.data,  cast(u32) shader.ReadWriteStorageBufferCount);

        if compute_pass == null {
            log_warning("Failed to begin GPU compute pass");
            return;
        }
    }

    // bind compute pipeline
    SDL_BindGPUComputePipeline(compute_pass, compute_res.pipeline);

    // bind samplers
    if shader.SamplerCount > 0 {
        samplers: [MAX_BOUND_SAMPLERS] SDL_GPUTextureSamplerBinding;
        for i: 0..shader.SamplerCount-1 {
            value := ifx i < command.SamplerCount then command.Samplers[i] else Bound_Sampler.{};
            tex := ifx value.Tex != null then sdl_find_resource(d, value.Tex.handle) else null;
            if tex != null {
                samplers[i].texture = sdl_sampler_texture(d, tex);
            } else {
                samplers[i].texture = sdl_sampler_texture(d, sdl_require_resource(d, d.empty_default_texture));
            }
            samplers[i].sampler = sdl_get_sampler(d, value.Sampler);
        }
        SDL_BindGPUComputeSamplers(compute_pass, 0, samplers.data, cast(u32) shader.SamplerCount);
    }

    // push uniform data
    for i: 0..shader.UniformBufferCount-1 {
        if i >= command.UniformBufferCount continue;
        unibuf := command.UniformBuffers[i];
        if unibuf == null continue;
        data := uniform_buffer_get(unibuf);
        if data.count > 0 {
            SDL_PushGPUComputeUniformData(d.cmd_render, cast(u32) i, data.data, cast(u32) data.count);
        }
    }

    // bind read-only storage textures
    if shader.ReadOnlyStorageTextureCount > 0 {
        textures: [MAX_STORAGE_BUFFERS] *SDL_GPUTexture;
        for i: 0..shader.ReadOnlyStorageTextureCount-1 {
            if i < command.ReadOnlyStorageTextureCount && command.ReadOnlyStorageTextures[i] != null {
                tex := sdl_require_resource(d, command.ReadOnlyStorageTextures[i].handle);
                textures[i] = sdl_sampler_texture(d, tex);
            } else {
                textures[i] = sdl_sampler_texture(d, sdl_require_resource(d, d.empty_default_compute_storage_texture));
            }
        }
        SDL_BindGPUComputeStorageTextures(compute_pass, 0, textures.data, cast(u32) shader.ReadOnlyStorageTextureCount);
    }

    // bind read-only storage buffers
    if shader.ReadOnlyStorageBufferCount > 0 {
        buffers: [MAX_STORAGE_BUFFERS] *SDL_GPUBuffer;
        for i: 0..shader.ReadOnlyStorageBufferCount-1 {
            if i < command.ReadOnlyStorageBufferCount && command.ReadOnlyStorageBuffers[i] != null {
                buffers[i] = sdl_require_resource(d, command.ReadOnlyStorageBuffers[i].handle).buffer;
            } else {
                buffers[i] = sdl_require_resource(d, d.empty_default_buffer).buffer;
            }
        }
        SDL_BindGPUComputeStorageBuffers(compute_pass, 0, buffers.data, cast(u32) shader.ReadOnlyStorageBufferCount);
    }

    // dispatch
    SDL_DispatchGPUCompute(
        compute_pass,
        cast(u32) command.GroupCountX,
        cast(u32) command.GroupCountY,
        cast(u32) command.GroupCountZ);

    SDL_EndGPUComputePass(compute_pass);
}

sdl_clear :: (d: *Graphics_Device, target: Drawable_Target, color: [] Color, depth: float, stencil: s32, mask: Clear_Mask) {
    assert(d.device != null, "GPU Device has not been created");

    if mask != .NONE {
        clear: Clear_Info;
        if (mask & .COLOR) != 0 {
            count := min(color.count, MAX_COLOR_ATTACHMENTS);
            clear.Colors = array_view(color, 0, count);
        } else {
            clear.Colors = .[];
        }
        if (mask & .DEPTH) != 0 {
            clear.Depth = depth;
            clear.HasDepth = true;
        }
        if (mask & .STENCIL) != 0 {
            clear.Stencil = stencil;
            clear.HasStencil = true;
        }
        sdl_begin_render_pass(d, target, clear);
    }
}

//
// command buffers / passes
//

sdl_flush_commands :: (d: *Graphics_Device, stall: bool) {
    sdl_end_copy_pass(d);
    sdl_end_render_pass(d);

    fences: [4] *SDL_GPUFence;
    fence_count := 0;

    // submit buffers
    if stall {
        upload_fence := SDL_SubmitGPUCommandBufferAndAcquireFence(d.cmd_upload);
        if upload_fence != null {
            fences[fence_count] = upload_fence; fence_count += 1;
        } else {
            log_warning(tprint("Failed to acquire upload fence: %", cstr_to_string(SDL_GetError())));
        }

        render_fence := SDL_SubmitGPUCommandBufferAndAcquireFence(d.cmd_render);
        if render_fence != null {
            fences[fence_count] = render_fence; fence_count += 1;
        } else {
            log_warning(tprint("Failed to acquire render fence: %", cstr_to_string(SDL_GetError())));
        }
    } else {
        SDL_SubmitGPUCommandBuffer(d.cmd_upload);
        SDL_SubmitGPUCommandBuffer(d.cmd_render);
    }

    // reset state
    d.cmd_upload = null;
    d.cmd_render = null;
    sdl_reset_command_buffer_state(d);

    // wait for gpu fences
    if fence_count > 0 {
        SDL_WaitForGPUFences(d.device, true, fences.data, cast(u32) fence_count);
    }

    // release gpu fences
    for i: 0..fence_count-1 {
        SDL_ReleaseGPUFence(d.device, fences[i]);
    }
}

sdl_reset_command_buffer_state :: (d: *Graphics_Device) {
    assert(d.cmd_render == null && d.cmd_upload == null, "Must submit previous command buffers!");

    d.cmd_render = SDL_AcquireGPUCommandBuffer(d.device);
    d.cmd_upload = SDL_AcquireGPUCommandBuffer(d.device);

    d.texture_upload_buffer_offset = 0;
    d.texture_upload_cycle_count = 0;
    d.buffer_upload_buffer_offset = 0;
    d.buffer_upload_cycle_count = 0;
}

sdl_begin_copy_pass :: (d: *Graphics_Device) {
    if d.copy_pass != null return;
    d.copy_pass = SDL_BeginGPUCopyPass(d.cmd_upload);
}

sdl_end_copy_pass :: (d: *Graphics_Device) {
    if d.copy_pass != null SDL_EndGPUCopyPass(d.copy_pass);
    d.copy_pass = null;
}

drawable_target_equals :: (a: Drawable_Target, b: Drawable_Target) -> bool {
    if a.Kind != b.Kind return false;
    if a.Kind == .WINDOW return a.window == b.window;
    if a.Kind == .TARGET return a.target == b.target;
    return true;
}

sdl_begin_render_pass :: (d: *Graphics_Device, drawable_target: Drawable_Target, clear: Clear_Info) -> bool {
    // only begin if we're not already in a matching render pass without clears
    if d.render_pass != null &&
       drawable_target_equals(d.render_pass_target, drawable_target) &&
       clear.Colors.count == 0 && !clear.HasDepth && !clear.HasStencil {
        return true;
    }

    sdl_end_render_pass(d);

    // make sure we have something to draw to
    target, size := sdl_get_draw_target(d, drawable_target);
    d.render_pass_target_size = size;
    if target == null return false;

    d.render_pass_target = drawable_target;

    color_attachments: [MAX_COLOR_ATTACHMENTS] *SDL_GPUTexture;
    color_resolves:    [MAX_COLOR_ATTACHMENTS] *SDL_GPUTexture;
    color_target_count := 0;
    depth_stencil_target: *SDL_GPUTexture = null;

    for it: target.Attachments {
        tex := sdl_require_resource(d, it.handle);
        if texture_format_is_depth_stencil(it.Format) {
            depth_stencil_target = tex.texture;
        } else {
            resolve := sdl_find_resource(d, tex.multi_sample_resolve);
            color_attachments[color_target_count] = tex.texture;
            color_resolves[color_target_count] = ifx resolve != null then resolve.texture else null;
            color_target_count += 1;
        }
    }

    color_info: [MAX_COLOR_ATTACHMENTS] SDL_GPUColorTargetInfo;

    for i: 0..color_target_count-1 {
        col := ifx i < clear.Colors.count then clear.Colors[i] else Color_Transparent;
        color_info[i].texture = color_attachments[i];
        color_info[i].mip_level = 0;
        color_info[i].layer_or_depth_plane = 0;
        color_info[i].clear_color = sdl_get_color(col);
        color_info[i].load_op = ifx clear.Colors.count > 0 then .SDL_GPU_LOADOP_CLEAR else .SDL_GPU_LOADOP_LOAD;
        color_info[i].store_op = ifx color_resolves[i] == null
            then .SDL_GPU_STOREOP_STORE else .SDL_GPU_STOREOP_RESOLVE;
        color_info[i].cycle = false;   // NOTE: Foster sets cycle=has-clear; kept false because
                                       // SDL 3.4.12 cycling hid contents from readback (see git history)
        color_info[i].resolve_texture = color_resolves[i];
    }

    // depth target (nullable pointer)
    depth_value: SDL_GPUDepthStencilTargetInfo;
    depth_ptr: *SDL_GPUDepthStencilTargetInfo = null;
    if depth_stencil_target != null {
        depth_value.texture = depth_stencil_target;
        depth_value.clear_depth = clear.Depth;
        depth_value.load_op = ifx clear.HasDepth then .SDL_GPU_LOADOP_CLEAR else .SDL_GPU_LOADOP_LOAD;
        depth_value.store_op = .SDL_GPU_STOREOP_STORE;
        depth_value.stencil_load_op = ifx clear.HasStencil then .SDL_GPU_LOADOP_CLEAR else .SDL_GPU_LOADOP_LOAD;
        depth_value.stencil_store_op = .SDL_GPU_STOREOP_STORE;
        depth_value.cycle = clear.HasDepth && clear.HasStencil;
        depth_value.clear_stencil = cast(u8) clear.Stencil;
        depth_ptr = *depth_value;
    }

    // begin pass
    d.render_pass = SDL_BeginGPURenderPass(
        d.cmd_render,
        color_info.data, cast(u32) color_target_count,
        depth_ptr);

    return d.render_pass != null;
}

sdl_end_render_pass :: (d: *Graphics_Device) {
    if d.render_pass != null SDL_EndGPURenderPass(d.render_pass);
    d.render_pass = null;
    d.render_pass_target = .{};
    d.render_pass_pipeline = null;
    d.render_pass_viewport = .{};
    d.has_render_pass_viewport = false;
    d.render_pass_scissor = .{};
    d.has_render_pass_scissor = false;
    d.render_pass_index_buffer = 0;
    d.render_pass_vertex_buffer_count = 0;
}

//
// graphics pipeline creation (hash-cached)
//

gpu_hash_mix :: (h: u64) -> u64 {
    x := h;
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9;
    x ^= x >> 27; x *= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

gpu_hash_combine :: (h: u64, v: u64) -> u64 {
    return gpu_hash_mix(h ^ v);
}

Target_Format_Sample :: struct {
    format: SDL_GPUTextureFormat;
    sample_count: SDL_GPUSampleCount;
}

sdl_get_graphics_pipeline :: (d: *Graphics_Device, command: Draw_Command) -> *SDL_GPUGraphicsPipeline {
    // build a big hash of everything in use (Foster: HashCode.Combine)
    hash: u64 = 0;
    hash = gpu_hash_combine(hash, command.VertexShader.handle);
    hash = gpu_hash_combine(hash, command.FragmentShader.handle);
    hash = gpu_hash_combine(hash, cast(u64) command.CullMode);
    hash = gpu_hash_combine(hash, cast(u64) command.FillMode);
    hash = gpu_hash_combine(hash, cast(u64) command.DepthCompare);
    hash = gpu_hash_combine(hash, cast(u64) command.DepthTestEnabled);
    hash = gpu_hash_combine(hash, cast(u64) command.DepthWriteEnabled);
    hash = gpu_hash_combine(hash, cast(u64) command.StencilTestEnabled);
    hash = gpu_hash_combine(hash, cast(u64) command.BlendMode.ColorOperation);
    hash = gpu_hash_combine(hash, cast(u64) command.BlendMode.ColorSource);
    hash = gpu_hash_combine(hash, cast(u64) command.BlendMode.ColorDestination);
    hash = gpu_hash_combine(hash, cast(u64) command.BlendMode.AlphaOperation);
    hash = gpu_hash_combine(hash, cast(u64) command.BlendMode.AlphaSource);
    hash = gpu_hash_combine(hash, cast(u64) command.BlendMode.AlphaDestination);
    hash = gpu_hash_combine(hash, cast(u64) command.BlendMode.Mask);
    hash = gpu_hash_combine(hash, color_rgba(command.BlendMode.BlendColor));

    if command.StencilTestEnabled {
        hash = gpu_hash_combine(hash, cast(u64) command.StencilCompareMask);
        hash = gpu_hash_combine(hash, cast(u64) command.StencilWriteMask);
        hash = gpu_hash_combine(hash, cast(u64) command.BackStencilState.FailOp);
        hash = gpu_hash_combine(hash, cast(u64) command.BackStencilState.PassOp);
        hash = gpu_hash_combine(hash, cast(u64) command.BackStencilState.DepthFailOp);
        hash = gpu_hash_combine(hash, cast(u64) command.BackStencilState.CompareOp);
        hash = gpu_hash_combine(hash, cast(u64) command.FrontStencilState.FailOp);
        hash = gpu_hash_combine(hash, cast(u64) command.FrontStencilState.PassOp);
        hash = gpu_hash_combine(hash, cast(u64) command.FrontStencilState.DepthFailOp);
        hash = gpu_hash_combine(hash, cast(u64) command.FrontStencilState.CompareOp);
    }

    if command.IndexBuffer != null {
        hash = gpu_hash_combine(hash, cast(u64) command.IndexBuffer.IndexFormat);
    }

    for i: 0..command.VertexBufferCount-1 {
        vb := command.VertexBuffers[i].Buffer;
        hash = gpu_hash_combine(hash, cast(u64) vb.Format.Stride);
        hash = gpu_hash_combine(hash, cast(u64) vb.Format.ElementCount);
        for j: 0..vb.Format.ElementCount-1 {
            el := vb.Format.Elements[j];
            hash = gpu_hash_combine(hash, cast(u64) el.Index);
            hash = gpu_hash_combine(hash, cast(u64) el.Type);
            hash = gpu_hash_combine(hash, cast(u64) el.Normalized);
        }
        hash = gpu_hash_combine(hash, cast(u64) command.VertexBuffers[i].InstanceInputRate);
    }

    // combine with target attachment formats + sample count
    formats: [32] Target_Format_Sample;
    format_count: s32 = 0;
    sdl_get_draw_target_formats(d, command.Target, formats, *format_count);
    for i: 0..format_count-1 {
        hash = gpu_hash_combine(hash, cast(u64) formats[i].format);
        hash = gpu_hash_combine(hash, cast(u64) formats[i].sample_count);
    }

    // try to find an existing pipeline
    existing, found := map_get(*d.pipelines, hash);
    if found return existing;

    // ... otherwise create a new one
    vert_res := sdl_require_resource(d, command.VertexShader.handle);
    frag_res := sdl_require_resource(d, command.FragmentShader.handle);
    assert(vert_res.kind == .SHADER && frag_res.kind == .SHADER);

    vertex_attribute_count := 0;
    for i: 0..command.VertexBufferCount-1 {
        vertex_attribute_count += command.VertexBuffers[i].Buffer.Format.ElementCount;
    }

    color_blend_state := sdl_get_blend_state(command.BlendMode);
    color_attachments: [MAX_COLOR_ATTACHMENTS] SDL_GPUColorTargetDescription;
    color_attachment_count := 0;
    depth_stencil_attachment: SDL_GPUTextureFormat = .SDL_GPU_TEXTUREFORMAT_INVALID;
    vertex_bindings: [MAX_VERTEX_BUFFERS] SDL_GPUVertexBufferDescription;
    vertex_attributes: [64] SDL_GPUVertexAttribute;

    // get highest sample count
    sample_count: SDL_GPUSampleCount = .SDL_GPU_SAMPLECOUNT_1;

    for i: 0..format_count-1 {
        if sdl_is_depth_texture_format(formats[i].format) {
            depth_stencil_attachment = formats[i].format;
        } else {
            color_attachments[color_attachment_count].format = formats[i].format;
            color_attachments[color_attachment_count].blend_state = color_blend_state;
            color_attachment_count += 1;
        }
        if cast(s32) formats[i].sample_count > cast(s32) sample_count {
            sample_count = formats[i].sample_count;
        }
    }

    attrb_index := 0;
    for slot: 0..command.VertexBufferCount-1 {
        it := command.VertexBuffers[slot].Buffer;
        instance_rate := command.VertexBuffers[slot].InstanceInputRate;
        vertex_offset := 0;

        vertex_bindings[slot].slot = cast(u32) slot;
        vertex_bindings[slot].pitch = cast(u32) it.Format.Stride;
        vertex_bindings[slot].input_rate = ifx instance_rate
            then .SDL_GPU_VERTEXINPUTRATE_INSTANCE else .SDL_GPU_VERTEXINPUTRATE_VERTEX;
        vertex_bindings[slot].instance_step_rate = 0;

        for j: 0..it.Format.ElementCount-1 {
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
    info.vertex_shader = vert_res.shader;
    info.fragment_shader = frag_res.shader;
    info.vertex_input_state.vertex_buffer_descriptions = vertex_bindings.data;
    info.vertex_input_state.num_vertex_buffers = cast(u32) command.VertexBufferCount;
    info.vertex_input_state.vertex_attributes = vertex_attributes.data;
    info.vertex_input_state.num_vertex_attributes = cast(u32) vertex_attribute_count;

    info.primitive_type = .SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;

    info.rasterizer_state.fill_mode = ifx command.FillMode == .FILL then .SDL_GPU_FILLMODE_FILL else .SDL_GPU_FILLMODE_LINE;
    if command.CullMode == .NONE  info.rasterizer_state.cull_mode = .SDL_GPU_CULLMODE_NONE;
    if command.CullMode == .FRONT info.rasterizer_state.cull_mode = .SDL_GPU_CULLMODE_FRONT;
    if command.CullMode == .BACK  info.rasterizer_state.cull_mode = .SDL_GPU_CULLMODE_BACK;
    info.rasterizer_state.front_face = .SDL_GPU_FRONTFACE_CLOCKWISE;
    info.rasterizer_state.enable_depth_bias = false;

    info.multisample_state.sample_count = sample_count;
    info.multisample_state.sample_mask = 0;         // not used per SDL docs
    info.multisample_state.enable_mask = false;     // not used per SDL docs
    info.multisample_state.enable_alpha_to_coverage = false;

    info.depth_stencil_state.compare_op = sdl_get_compare_op(command.DepthCompare);
    info.depth_stencil_state.back_stencil_state.fail_op       = sdl_get_stencil_op(command.BackStencilState.FailOp);
    info.depth_stencil_state.back_stencil_state.pass_op       = sdl_get_stencil_op(command.BackStencilState.PassOp);
    info.depth_stencil_state.back_stencil_state.depth_fail_op = sdl_get_stencil_op(command.BackStencilState.DepthFailOp);
    info.depth_stencil_state.back_stencil_state.compare_op    = sdl_get_compare_op(command.BackStencilState.CompareOp);
    info.depth_stencil_state.front_stencil_state.fail_op       = sdl_get_stencil_op(command.FrontStencilState.FailOp);
    info.depth_stencil_state.front_stencil_state.pass_op       = sdl_get_stencil_op(command.FrontStencilState.PassOp);
    info.depth_stencil_state.front_stencil_state.depth_fail_op = sdl_get_stencil_op(command.FrontStencilState.DepthFailOp);
    info.depth_stencil_state.front_stencil_state.compare_op    = sdl_get_compare_op(command.FrontStencilState.CompareOp);
    info.depth_stencil_state.compare_mask = command.StencilCompareMask;
    info.depth_stencil_state.write_mask  = command.StencilWriteMask;
    info.depth_stencil_state.enable_depth_test  = command.DepthTestEnabled;
    info.depth_stencil_state.enable_depth_write = command.DepthWriteEnabled;
    info.depth_stencil_state.enable_stencil_test = command.StencilTestEnabled;

    info.target_info.color_target_descriptions = color_attachments.data;
    info.target_info.num_color_targets = cast(u32) color_attachment_count;
    info.target_info.has_depth_stencil_target = depth_stencil_attachment != .SDL_GPU_TEXTUREFORMAT_INVALID;
    info.target_info.depth_stencil_format = depth_stencil_attachment;

    pipeline := SDL_CreateGPUGraphicsPipeline(d.device, *info);
    if pipeline == null {
        log_error(app_sdl_error_message("SDL_CreateGPUGraphicsPipeline"));
        assert(false, "SDL_CreateGPUGraphicsPipeline failed");
    }

    // track pipelines by the shaders that use them
    array_add(*vert_res.pipelines, hash);
    array_add(*frag_res.pipelines, hash);

    table_set(*d.pipelines, hash, pipeline);
    return pipeline;
}

sdl_get_draw_target :: (d: *Graphics_Device, drawable: Drawable_Target) -> *Target, Point2 {
    // get specific target
    if drawable.Kind == .TARGET {
        return drawable.target, .{ drawable.target.Width, drawable.target.Height };
    }

    // get backbuffer target
    if drawable.Kind == .WINDOW {
        window := drawable.window;
        state, found := map_get(*d.windows, window.id);
        if found && !window.is_destroyed && state.backbuffer != null {
            return state.backbuffer, state.backbuffer_size;
        }
    }

    return null, Point2_Zero;
}

sdl_get_draw_target_formats :: (d: *Graphics_Device, drawable: Drawable_Target, formats: [] Target_Format_Sample, count: *s32) {
    count.* = 0;
    target, size := sdl_get_draw_target(d, drawable);
    if target != null {
        for it: target.Attachments {
            if count.* >= formats.count break;
            formats[count.*].format = sdl_get_texture_format(it.Format);
            formats[count.*].sample_count = sdl_get_sample_count(it.SampleCount);
            count.* += 1;
        }
    }
}

//
// enum / state mappings
//

sdl_get_blend_state :: (blend: Blend_Mode) -> SDL_GPUColorTargetBlendState {
    get_factor :: (factor: Blend_Factor) -> SDL_GPUBlendFactor {
        if factor == {
            case .ZERO;                     return .SDL_GPU_BLENDFACTOR_ZERO;
            case .ONE;                      return .SDL_GPU_BLENDFACTOR_ONE;
            case .SRC_COLOR;                return .SDL_GPU_BLENDFACTOR_SRC_COLOR;
            case .ONE_MINUS_SRC_COLOR;      return .SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_COLOR;
            case .DST_COLOR;                return .SDL_GPU_BLENDFACTOR_DST_COLOR;
            case .ONE_MINUS_DST_COLOR;      return .SDL_GPU_BLENDFACTOR_ONE_MINUS_DST_COLOR;
            case .SRC_ALPHA;                return .SDL_GPU_BLENDFACTOR_SRC_ALPHA;
            case .ONE_MINUS_SRC_ALPHA;      return .SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
            case .DST_ALPHA;                return .SDL_GPU_BLENDFACTOR_DST_ALPHA;
            case .ONE_MINUS_DST_ALPHA;      return .SDL_GPU_BLENDFACTOR_ONE_MINUS_DST_ALPHA;
            case .CONSTANT_COLOR;           return .SDL_GPU_BLENDFACTOR_CONSTANT_COLOR;
            case .ONE_MINUS_CONSTANT_COLOR; return .SDL_GPU_BLENDFACTOR_ONE_MINUS_CONSTANT_COLOR;
            case .SRC_ALPHA_SATURATE;       return .SDL_GPU_BLENDFACTOR_SRC_ALPHA_SATURATE;
        }
        return .SDL_GPU_BLENDFACTOR_ZERO;
    }

    get_op :: (op: Blend_Op) -> SDL_GPUBlendOp {
        if op == {
            case .ADD;              return .SDL_GPU_BLENDOP_ADD;
            case .SUBTRACT;         return .SDL_GPU_BLENDOP_SUBTRACT;
            case .REVERSE_SUBTRACT; return .SDL_GPU_BLENDOP_REVERSE_SUBTRACT;
            case .MIN;              return .SDL_GPU_BLENDOP_MIN;
            case .MAX;              return .SDL_GPU_BLENDOP_MAX;
        }
        return .SDL_GPU_BLENDOP_ADD;
    }

    get_flags :: (mask: Blend_Mask) -> SDL_GPUColorComponentFlags {
        flags: SDL_GPUColorComponentFlags = 0;
        if (mask & .RED)   != 0 flags |= .SDL_GPU_COLORCOMPONENT_R;
        if (mask & .GREEN) != 0 flags |= .SDL_GPU_COLORCOMPONENT_G;
        if (mask & .BLUE)  != 0 flags |= .SDL_GPU_COLORCOMPONENT_B;
        if (mask & .ALPHA) != 0 flags |= .SDL_GPU_COLORCOMPONENT_A;
        return flags;
    }

    state: SDL_GPUColorTargetBlendState;
    state.enable_blend = true;
    state.src_color_blendfactor = get_factor(blend.ColorSource);
    state.dst_color_blendfactor = get_factor(blend.ColorDestination);
    state.color_blend_op = get_op(blend.ColorOperation);
    state.src_alpha_blendfactor = get_factor(blend.AlphaSource);
    state.dst_alpha_blendfactor = get_factor(blend.AlphaDestination);
    state.alpha_blend_op = get_op(blend.AlphaOperation);
    state.color_write_mask = get_flags(blend.Mask);
    return state;
}

texture_sampler_key :: (sampler: Texture_Sampler) -> u32 {
    f := cast(u32) sampler.Filter;
    x := cast(u32) sampler.WrapX;
    y := cast(u32) sampler.WrapY;
    return f | (x << 1) | (y << 3);
}

sdl_get_sampler :: (d: *Graphics_Device, sampler: Texture_Sampler) -> *SDL_GPUSampler {
    get_wrap_mode :: (wrap: Texture_Wrap) -> SDL_GPUSamplerAddressMode {
        if wrap == {
            case .REPEAT;          return .SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
            case .MIRRORED_REPEAT; return .SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT;
            case .CLAMP;           return .SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        }
        return .SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
    }

    key := texture_sampler_key(sampler);
    result, found := map_get(*d.samplers, key);
    if found return result;

    info: SDL_GPUSamplerCreateInfo;
    info.min_filter = sdl_get_filter(sampler.Filter);
    info.mag_filter = sdl_get_filter(sampler.Filter);
    info.address_mode_u = get_wrap_mode(sampler.WrapX);
    info.address_mode_v = get_wrap_mode(sampler.WrapY);
    info.address_mode_w = .SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
    info.compare_op = .SDL_GPU_COMPAREOP_ALWAYS;
    info.enable_compare = false;

    sampler_handle := SDL_CreateGPUSampler(d.device, *info);
    if sampler_handle == null {
        log_error(app_sdl_error_message("SDL_CreateGPUSampler"));
        assert(false, "SDL_CreateGPUSampler failed");
    }

    table_set(*d.samplers, key, sampler_handle);
    return sampler_handle;
}

sdl_get_filter :: (filter: Texture_Filter) -> SDL_GPUFilter {
    if filter == .NEAREST return .SDL_GPU_FILTER_NEAREST;
    return .SDL_GPU_FILTER_LINEAR;
}

sdl_get_vertex_format :: (type: Vertex_Type, normalized: bool) -> SDL_GPUVertexElementFormat {
    if type == {
        case .FLOAT;   return .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT;
        case .FLOAT2;  return .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
        case .FLOAT3;  return .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3;
        case .FLOAT4;  return .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4;
        case .BYTE4;   return ifx normalized then .SDL_GPU_VERTEXELEMENTFORMAT_BYTE4_NORM  else .SDL_GPU_VERTEXELEMENTFORMAT_BYTE4;
        case .UBYTE4;  return ifx normalized then .SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM else .SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4;
        case .SHORT2;  return ifx normalized then .SDL_GPU_VERTEXELEMENTFORMAT_SHORT2_NORM else .SDL_GPU_VERTEXELEMENTFORMAT_SHORT2;
        case .USHORT2; return ifx normalized then .SDL_GPU_VERTEXELEMENTFORMAT_USHORT2_NORM else .SDL_GPU_VERTEXELEMENTFORMAT_USHORT2;
        case .SHORT4;  return ifx normalized then .SDL_GPU_VERTEXELEMENTFORMAT_SHORT4_NORM else .SDL_GPU_VERTEXELEMENTFORMAT_SHORT4;
        case .USHORT4; return ifx normalized then .SDL_GPU_VERTEXELEMENTFORMAT_USHORT4_NORM else .SDL_GPU_VERTEXELEMENTFORMAT_USHORT4;
        case .NONE;    return .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT;
    }
    return .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT;
}

sdl_get_texture_format :: (format: Texture_Format) -> SDL_GPUTextureFormat {
    if format == {
        case .R8G8B8A8; return .SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        case .R16G16B16A16_FLOAT; return .SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
        case .R32G32B32A32_FLOAT; return .SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT;
        case .R8;              return .SDL_GPU_TEXTUREFORMAT_R8_UNORM;
        case .R8G8;            return .SDL_GPU_TEXTUREFORMAT_R8G8_UNORM;
        case .DEPTH24STENCIL8; return .SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT;
        case .DEPTH32STENCIL8; return .SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
        case .DEPTH16;         return .SDL_GPU_TEXTUREFORMAT_D16_UNORM;
        case .DEPTH24;         return .SDL_GPU_TEXTUREFORMAT_D24_UNORM;
        case .DEPTH32;         return .SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
    }
    return .SDL_GPU_TEXTUREFORMAT_INVALID;
}

sdl_get_sample_count :: (sample_count: Sample_Count) -> SDL_GPUSampleCount {
    if sample_count == {
        case .ONE;   return .SDL_GPU_SAMPLECOUNT_1;
        case .TWO;   return .SDL_GPU_SAMPLECOUNT_2;
        case .FOUR;  return .SDL_GPU_SAMPLECOUNT_4;
        case .EIGHT; return .SDL_GPU_SAMPLECOUNT_8;
    }
    return .SDL_GPU_SAMPLECOUNT_1;
}

sdl_is_depth_texture_format :: (format: SDL_GPUTextureFormat) -> bool {
    if format == {
        case .SDL_GPU_TEXTUREFORMAT_D16_UNORM;
        case .SDL_GPU_TEXTUREFORMAT_D24_UNORM;
        case .SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
        case .SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT;
        case .SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
            return true;
    }
    return false;
}

sdl_get_stencil_op :: (op: Stencil_Op) -> SDL_GPUStencilOp {
    if op == {
        case .INVALID;             return .SDL_GPU_STENCILOP_INVALID;
        case .KEEP;                return .SDL_GPU_STENCILOP_KEEP;
        case .ZERO;                return .SDL_GPU_STENCILOP_ZERO;
        case .REPLACE;             return .SDL_GPU_STENCILOP_REPLACE;
        case .INCREMENT_AND_CLAMP; return .SDL_GPU_STENCILOP_INCREMENT_AND_CLAMP;
        case .DECREMENT_AND_CLAMP; return .SDL_GPU_STENCILOP_DECREMENT_AND_CLAMP;
        case .INVERT;              return .SDL_GPU_STENCILOP_INVERT;
        case .INCREMENT_AND_WRAP;  return .SDL_GPU_STENCILOP_INCREMENT_AND_WRAP;
        case .DECREMENT_AND_WRAP;  return .SDL_GPU_STENCILOP_DECREMENT_AND_WRAP;
    }
    return .SDL_GPU_STENCILOP_KEEP;
}

sdl_get_compare_op :: (op: Depth_Compare) -> SDL_GPUCompareOp {
    if op == {
        case .ALWAYS;           return .SDL_GPU_COMPAREOP_ALWAYS;
        case .NEVER;            return .SDL_GPU_COMPAREOP_NEVER;
        case .LESS;             return .SDL_GPU_COMPAREOP_LESS;
        case .EQUAL;            return .SDL_GPU_COMPAREOP_EQUAL;
        case .LESS_OR_EQUAL;    return .SDL_GPU_COMPAREOP_LESS_OR_EQUAL;
        case .GREATER;          return .SDL_GPU_COMPAREOP_GREATER;
        case .NOT_EQUAL;        return .SDL_GPU_COMPAREOP_NOT_EQUAL;
        case .GREATER_OR_EQUAL; return .SDL_GPU_COMPAREOP_GREATER_OR_EQUAL;
    }
    return .SDL_GPU_COMPAREOP_NEVER;
}

sdl_get_color :: (color: Color) -> SDL_FColor {
    v := color_to_vector4(color);
    return .{ r = v.x, g = v.y, b = v.z, a = v.w };
}
