#scope_module
using Basic;
using Math;
using Hash_Table;
using String_Mod;
#scope_export   // note: kept module-visible; consumers reach it via graphics_device.jai wrappers

// Port of Foster Framework/Internal/GraphicsDeviceSDL.cs (SDL_GPU backend).

SDL_PROP_GPU_TEXTURE_CREATE_NAME_STRING         :: "SDL.gpu.texture.create.name";
SDL_PROP_GPU_BUFFER_CREATE_NAME_STRING          :: "SDL.gpu.buffer.create.name";
SDL_PROP_GPU_SHADER_CREATE_NAME_STRING          :: "SDL.gpu.shader.create.name";
SDL_PROP_GPU_COMPUTEPIPELINE_CREATE_NAME_STRING :: "SDL.gpu.computepipeline.create.name";

Backbuffer_Name :: "Foster Backbuffer";

//
// lifecycle
//

sdl_device_create :: (preferred: Graphics_Driver, flags: App_Flags) -> *Graphics_Device {
    d := New(Graphics_Device);
    d.preferred = preferred;
    d.flags = flags;
    d.disposed = false;

    requested_driver_name: *u8 = null;
    if preferred == {
        case .PRIVATE; requested_driver_name = "private";
        case .VULKAN;   requested_driver_name = "vulkan";
        case .D3D12;    requested_driver_name = "direct3d12";
        case .METAL;    requested_driver_name = "metal";
        case .NONE;     requested_driver_name = null;
    }

    d.device = SDL_CreateGPUDevice(
        .SDL_GPU_SHADERFORMAT_SPIRV | .SDL_GPU_SHADERFORMAT_DXIL | .SDL_GPU_SHADERFORMAT_MSL,
        (flags & .GRAPHICS_DEBUGGING) != 0,
        requested_driver_name);

    if d.device == null {
        log_error(app_sdl_error_message("SDL_CreateGPUDevice"));
        assert(false, "SDL_CreateGPUDevice failed");
    }

    driver_name := cstr_to_string(SDL_GetGPUDeviceDriver(d.device));
    // note: names can carry suffixes, e.g. "direct3d12s" (software D3D12)
    if driver_name == "private"                    d.driver = .PRIVATE;
    else if driver_name == "vulkan"                d.driver = .VULKAN;
    else if begins_with(driver_name, "direct3d12") d.driver = .D3D12;
    else if begins_with(driver_name, "metal")      d.driver = .METAL;
    else                                           d.driver = .NONE;

    if (flags & .MULTI_SAMPLED_BACK_BUFFER) != 0 {
        if graphics_device_is_texture_multi_sample_supported(d, .COLOR, .EIGHT) {
            d.backbuffer_format = .{ Format = .COLOR, Flags = .NONE, SampleCount = .EIGHT };
        } else if graphics_device_is_texture_multi_sample_supported(d, .COLOR, .FOUR) {
            d.backbuffer_format = .{ Format = .COLOR, Flags = .NONE, SampleCount = .FOUR };
        } else if graphics_device_is_texture_multi_sample_supported(d, .COLOR, .TWO) {
            d.backbuffer_format = .{ Format = .COLOR, Flags = .NONE, SampleCount = .TWO };
        }
    }

    if (flags & .NO_HEADER_LOG) == 0 {
        log_info(tprint("Graphics Driver: SDL_GPU [%s]", driver_name));
    }

    // we always have a command buffer ready
    sdl_reset_command_buffer_state(d);

    // create texture upload buffer
    {
        info: SDL_GPUTransferBufferCreateInfo;
        info.usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        info.size  = TRANSFER_BUFFER_SIZE;
        info.props = 0;
        d.texture_upload_buffer = SDL_CreateGPUTransferBuffer(d.device, *info);
        d.texture_upload_buffer_offset = 0;
    }

    // create buffer upload buffer
    {
        info: SDL_GPUTransferBufferCreateInfo;
        info.usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        info.size  = TRANSFER_BUFFER_SIZE;
        info.props = 0;
        d.buffer_upload_buffer = SDL_CreateGPUTransferBuffer(d.device, *info);
        d.buffer_upload_buffer_offset = 0;
    }

    // default textures we fall back to when a material is missing textures
    {
        data := color_from_rgba(0x00e82979);
        formats: [1] Target_Attachment_Info = .[.{ Format = .R8G8B8A8, Flags = .NONE, SampleCount = .ONE }];

        d.empty_default_texture = sdl_create_texture(d, "Fallback", 1, 1, .R8G8B8A8, .NONE, .ONE, 0);
        d.empty_default_compute_storage_texture = sdl_create_texture(d, "StorageFallback", 1, 1, .R8G8B8A8, .COMPUTE_READ | .COMPUTE_WRITE, .ONE, 0);
        sdl_set_texture_data(d, d.empty_default_texture, *data, 4, .{ 0, 0, 1, 1 });
        sdl_set_texture_data(d, d.empty_default_compute_storage_texture, *data, 4, .{ 0, 0, 1, 1 });
    }

    // default buffer we fall back to when a shader expects buffers the user didn't supply
    {
        data: u8 = 0;
        d.empty_default_buffer = sdl_create_buffer(d, "Fallback", .STORAGE, .SIXTEEN);
        sdl_upload_buffer_data(d, d.empty_default_buffer, *data, 1, 0);
    }

    // default to 3 frames in flight
    SDL_SetGPUAllowedFramesInFlight(d.device, MAX_FRAMES_IN_FLIGHT);

    mutex_init(*d.texture_download_mutex);
    return d;
}

sdl_destroy_device :: (d: *Graphics_Device) {
    SDL_DestroyGPUDevice(d.device);
    d.device = null;
    d.disposed = true;
}

sdl_window_created :: (d: *Graphics_Device, window: *Window) {
    state := New(GPU_Window_State);
    state.id = window.id;
    state.handle = window.handle;
    table_set(*d.windows, window.id, state);

    if !SDL_ClaimWindowForGPUDevice(d.device, window.handle) {
        log_error(app_sdl_error_message("SDL_ClaimWindowForGPUDevice"));
        assert(false, "SDL_ClaimWindowForGPUDevice failed");
    }
    state.claimed = true;
    state.reclaim_pending = false;

    // query supported present modes
    state.supports_immediate_present_mode =
        SDL_WindowSupportsGPUPresentMode(d.device, state.handle, .SDL_GPU_PRESENTMODE_IMMEDIATE);
    state.supports_mailbox_present_mode =
        SDL_WindowSupportsGPUPresentMode(d.device, state.handle, .SDL_GPU_PRESENTMODE_MAILBOX);

    // get backbuffer
    w, h: s32;
    SDL_GetWindowSizeInPixels(state.handle, *w, *h);
    state.backbuffer_size = .{ cast(s32) max(1, w), cast(s32) max(1, h) };

    formats: [1] Target_Attachment_Info = .[d.backbuffer_format];
    state.backbuffer = target_create_attachments(d, state.backbuffer_size.x, state.backbuffer_size.y, formats, Backbuffer_Name);

    // setup v-sync for this window
    sdl_update_window_present_mode(d, state, d.vsync_enabled);
}

sdl_window_destroyed :: (d: *Graphics_Device, window: *Window) {
    state, found := map_get(*d.windows, window.id);
    if found {
        if state.claimed {
            SDL_ReleaseWindowFromGPUDevice(d.device, window.handle);
            state.claimed = false;
        }
        table_remove(*d.windows, window.id);
    }
}

sdl_update_window_present_mode :: (d: *Graphics_Device, state: *GPU_Window_State, vsync_enabled: bool) {
    // get desired mode
    desired: SDL_GPUPresentMode = ifx vsync_enabled then .SDL_GPU_PRESENTMODE_VSYNC else .SDL_GPU_PRESENTMODE_IMMEDIATE;

    // desired mode isn't supported ... fallback, eventually to v-sync,
    // as it's the only always-supported mode
    if desired == .SDL_GPU_PRESENTMODE_IMMEDIATE && !state.supports_immediate_present_mode {
        desired = .SDL_GPU_PRESENTMODE_MAILBOX;
    }
    if desired == .SDL_GPU_PRESENTMODE_MAILBOX && !state.supports_mailbox_present_mode {
        desired = .SDL_GPU_PRESENTMODE_VSYNC;
    }

    // this operation is slow, so only do it on change
    if !state.has_present_mode || state.present_mode != desired {
        SDL_SetGPUSwapchainParameters(d.device, state.handle, .SDL_GPU_SWAPCHAINCOMPOSITION_SDR, desired);
        state.present_mode = desired;
        state.has_present_mode = true;
    }
}

sdl_shutdown :: (d: *Graphics_Device) {
    // submit remaining commands
    sdl_flush_commands(d, stall = false);
    SDL_SubmitGPUCommandBuffer(d.cmd_upload);
    SDL_SubmitGPUCommandBuffer(d.cmd_render);
    SDL_WaitForGPUIdle(d.device);

    // destroy default resources
    defaults_destroy(d);
    sdl_destroy_resource(d, d.empty_default_texture);
    sdl_destroy_resource(d, d.empty_default_compute_storage_texture);
    sdl_destroy_resource(d, d.empty_default_buffer);
    d.empty_default_texture = 0;
    d.empty_default_compute_storage_texture = 0;
    d.empty_default_buffer = 0;

    // destroy resources
    while d.resources.count > 0 {
        count := 0;
        destroying: [1024] Graphics_Resource_Handle;
        for v, k: d.resources {
            if count < destroying.count {
                destroying[count] = k;
                count += 1;
            }
        }
        for i: 0..count-1 {
            sdl_destroy_resource(d, destroying[i]);
        }
    }

    // destroy transfer buffers
    {
        if d.texture_download_buffer != null SDL_ReleaseGPUTransferBuffer(d.device, d.texture_download_buffer);
        d.texture_download_buffer = null;
        SDL_ReleaseGPUTransferBuffer(d.device, d.texture_upload_buffer);
        d.texture_upload_buffer = null;
        SDL_ReleaseGPUTransferBuffer(d.device, d.buffer_upload_buffer);
        d.buffer_upload_buffer = null;
    }

    // release pipelines
    {
        for pipeline: d.pipelines {
            SDL_ReleaseGPUGraphicsPipeline(d.device, pipeline);
        }
        table_reset(*d.pipelines);
    }

    // release samplers
    {
        for sampler: d.samplers {
            SDL_ReleaseGPUSampler(d.device, sampler);
        }
        table_reset(*d.samplers);
    }

    // all windows should be destroyed by this point
    assert(d.windows.count == 0, "Windows were not gracefully destroyed");

    // clear state
    d.cmd_upload = null;
    d.cmd_render = null;
    d.render_pass = null;
    d.copy_pass = null;
    d.render_pass_target = .{};
    d.driver = .NONE;
}

sdl_present :: (d: *Graphics_Device) {
    sdl_end_copy_pass(d);
    sdl_end_render_pass(d);

    // don't present to the screen if we're not visible
    if d.in_background {
        sdl_flush_commands(d, stall = false);
        return;
    }

    // present each window
    for state: d.windows {
        sdl_present_window(d, state);
    }

    // submit and present to screen
    sdl_flush_commands(d, stall = false);

    // reclaim any pending windows
    for state: d.windows {
        if state.reclaim_pending sdl_reclaim_window(d, state);
    }
}

sdl_on_event :: (d: *Graphics_Device, type: SDL_EventType) {
    if type == .SDL_EVENT_WILL_ENTER_BACKGROUND {
        // free window backbuffers while hidden
        for state: d.windows {
            if state.backbuffer != null {
                target_dispose(state.backbuffer);
                state.backbuffer = null;
            }
            state.reclaim_pending = true;
        }
        d.in_background = true;
    }

    if type == .SDL_EVENT_DID_ENTER_FOREGROUND {
        d.in_background = false;
    }
}

sdl_present_window :: (d: *Graphics_Device, state: *GPU_Window_State) {
    // on some platforms (Android) the underlying surface can be lost when the
    // app moves to the background; reclaim the window when we resume.
    if state.reclaim_pending return;

    // if the window is hidden, we do not draw to it
    if (SDL_GetWindowFlags(state.handle) & .SDL_WINDOW_HIDDEN) != 0 return;

    // get the swapchain for this window
    sc_tex: *SDL_GPUTexture = null;
    sc_w: u32; sc_h: u32;
    if !SDL_WaitAndAcquireGPUSwapchainTexture(d.cmd_render, state.handle, *sc_tex, *sc_w, *sc_h) {
        log_warning(app_sdl_error_message("SDL_WaitAndAcquireGPUSwapchainTexture"));
        return;
    }

    // blit backbuffer to swapchain
    if sc_tex != null && sc_w > 0 && sc_h > 0 &&
       state.backbuffer_size.x > 0 && state.backbuffer_size.y > 0 && state.backbuffer != null {
        blit: SDL_GPUBlitInfo;
        backbuffer_res := sdl_require_resource(d, state.backbuffer.Attachments[0].handle);
        blit.source.texture = sdl_sampler_texture(d, backbuffer_res);
        blit.source.mip_level = 0;
        blit.source.layer_or_depth_plane = 0;
        blit.source.x = 0;
        blit.source.y = 0;
        blit.source.w = min(sc_w, cast(u32) state.backbuffer.Width);
        blit.source.h = min(sc_h, cast(u32) state.backbuffer.Height);

        blit.destination.texture = sc_tex;
        blit.destination.mip_level = 0;
        blit.destination.layer_or_depth_plane = 0;
        blit.destination.x = 0;
        blit.destination.y = 0;
        blit.destination.w = min(sc_w, cast(u32) state.backbuffer.Width);
        blit.destination.h = min(sc_h, cast(u32) state.backbuffer.Height);

        blit.load_op = .SDL_GPU_LOADOP_DONT_CARE;
        blit.flip_mode = .SDL_FLIP_NONE;
        blit.filter = .SDL_GPU_FILTER_NEAREST;
        blit.cycle = false;

        SDL_BlitGPUTexture(d.cmd_render, *blit);
    }

    // update backbuffer size (if non-zero swapchain size)
    if sc_w > 0 && sc_h > 0 {
        state.backbuffer_size = .{ cast(s32) sc_w, cast(s32) sc_h };

        // intentionally resizing a bit larger so we're not constantly
        // recreating buffers as the window is dragged/scaled
        if state.backbuffer == null ||
           state.backbuffer.Width < state.backbuffer_size.x ||
           state.backbuffer.Height < state.backbuffer_size.y {
            if state.backbuffer != null target_dispose(state.backbuffer);
            formats: [1] Target_Attachment_Info = .[d.backbuffer_format];
            state.backbuffer = target_create_attachments(
                d, state.backbuffer_size.x + 64, state.backbuffer_size.y + 64, formats, Backbuffer_Name);
        }
        // resize buffer if it's too large
        else if state.backbuffer.Width > state.backbuffer_size.x + 128 ||
                state.backbuffer.Height > state.backbuffer_size.y + 128 {
            target_dispose(state.backbuffer);
            formats: [1] Target_Attachment_Info = .[d.backbuffer_format];
            state.backbuffer = target_create_attachments(
                d, state.backbuffer_size.x, state.backbuffer_size.y, formats, Backbuffer_Name);
        }
    }
}

sdl_reclaim_window :: (d: *Graphics_Device, state: *GPU_Window_State) {
    SDL_WaitForGPUIdle(d.device);

    if state.claimed {
        state.claimed = false;
        SDL_ReleaseWindowFromGPUDevice(d.device, state.handle);
    }

    if SDL_ClaimWindowForGPUDevice(d.device, state.handle) {
        state.claimed = true;
        state.reclaim_pending = false;
    } else {
        log_warning(app_sdl_error_message("SDL_ClaimWindowForGPUDevice"));
    }
}

//
// resources
//

sdl_register_resource :: (d: *Graphics_Device, kind: GPU_Resource_Kind) -> Graphics_Resource_Handle {
    d.next_resource_id += 1;
    res := New(GPU_Resource);
    res.kind = kind;
    res.handle = d.next_resource_id;
    table_set(*d.resources, res.handle, res);
    return res.handle;
}

sdl_require_resource :: (d: *Graphics_Device, handle: Graphics_Resource_Handle) -> *GPU_Resource {
    res, found := map_get(*d.resources, handle);
    if !found assert(false, "Attempting to use a Disposed Resource");
    return res;
}

sdl_find_resource :: (d: *Graphics_Device, handle: Graphics_Resource_Handle) -> *GPU_Resource {
    if handle == 0 return null;
    res, found := map_get(*d.resources, handle);
    if found return res;
    return null;
}

// If multisampled, we should sample from the resolve texture, NOT the
// texture that is being multisampled.
sdl_sampler_texture :: (d: *Graphics_Device, res: *GPU_Resource) -> *SDL_GPUTexture {
    if res.multi_sample_resolve != 0 {
        resolve := sdl_find_resource(d, res.multi_sample_resolve);
        if resolve != null return resolve.texture;
    }
    return res.texture;
}

sdl_create_texture :: (d: *Graphics_Device, name: string, width: s32, height: s32,
                       format: Texture_Format, flags: Texture_Flags, sample_count: Sample_Count,
                       target_binding: Graphics_Resource_Handle) -> Graphics_Resource_Handle {
    assert(d.device != null, "GPU Device has not been created");

    props: SDL_PropertiesID = 0;
    if name != "" {
        props = SDL_CreateProperties();
        prop_name := to_cstr(SDL_PROP_GPU_TEXTURE_CREATE_NAME_STRING);
        name_c := to_cstr(name);
        SDL_SetStringProperty(props, prop_name, name_c);
        free(prop_name); free(name_c);
    }

    info: SDL_GPUTextureCreateInfo;
    info.type = .SDL_GPU_TEXTURETYPE_2D;
    info.format = sdl_get_texture_format(format);
    info.usage = 0;   // enum_flags zero
    info.width = cast(u32) width;
    info.height = cast(u32) height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    info.sample_count = sdl_get_sample_count(sample_count);
    info.props = props;

    // only a sampler if not multisampled (resolve texture is created for that)
    if sample_count == .ONE info.usage |= .SDL_GPU_TEXTUREUSAGE_SAMPLER;

    // we're a render target attachment
    if target_binding != 0 {
        if texture_format_is_depth_stencil(format) {
            info.usage |= .SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET;
        } else {
            info.usage |= .SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
        }
    }

    // compute flags
    if (flags & .COMPUTE_READ)  != 0 info.usage |= .SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_READ;
    if (flags & .COMPUTE_WRITE) != 0 info.usage |= .SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE;

    // try to create texture on GPU
    texture := SDL_CreateGPUTexture(d.device, *info);
    if props != 0 SDL_DestroyProperties(props);
    if texture == null {
        log_error(app_sdl_error_message("SDL_CreateGPUTexture"));
        assert(false, "SDL_CreateGPUTexture failed");
    }

    // create a resolve texture if we're multisampled
    resolve_texture: Graphics_Resource_Handle = 0;
    if sample_count != .ONE {
        resolve_name := ifx name != "" then tprint("Resolve-%", name) else "";
        resolve_texture = sdl_create_texture(d, resolve_name, width, height, format, flags, .ONE, target_binding);
    }

    // create resulting texture resource
    handle := sdl_register_resource(d, .TEXTURE);
    res := sdl_require_resource(d, handle);
    res.texture = texture;
    res.width = width;
    res.height = height;
    res.format = info.format;
    res.sample_count = sdl_get_sample_count(sample_count);
    res.multi_sample_resolve = resolve_texture;

    // attach to target
    if target_binding != 0 {
        target_res := sdl_find_resource(d, target_binding);
        if target_res != null && target_res.kind == .TARGET {
            array_add(*target_res.attachments, handle);
        }
    }

    return handle;
}

round_to_alignment :: (value: u32, alignment: u32) -> u32 {
    return alignment * ((value + alignment - 1) / alignment);
}

sdl_set_texture_data :: (d: *Graphics_Device, handle: Graphics_Resource_Handle, data: *void, length: s32, dest_region: Rect_Int) {
    assert(d.device != null, "GPU Device has not been created");

    res := sdl_require_resource(d, handle);
    assert(res.kind == .TEXTURE, "Resource is not a Texture");

    // search up for resolve texture if we're multisampled
    if res.multi_sample_resolve != 0 {
        sdl_set_texture_data(d, res.multi_sample_resolve, data, length, dest_region);
        return;
    }

    using_temporary_transfer_buffer := false;
    transfer_buffer := d.texture_upload_buffer;
    transfer_offset: u32;
    transfer_cycle: bool;

    block_size := SDL_GPUTextureFormatTexelBlockSize(res.format);
    d.texture_upload_buffer_offset = round_to_alignment(d.texture_upload_buffer_offset, block_size);

    if length >= TRANSFER_BUFFER_SIZE {
        // uploading more data than our transfer buffer: temporary one
        info: SDL_GPUTransferBufferCreateInfo;
        info.usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        info.size = cast(u32) length;
        info.props = 0;
        transfer_buffer = SDL_CreateGPUTransferBuffer(d.device, *info);
        using_temporary_transfer_buffer = true;
        transfer_cycle = false;
        transfer_offset = 0;
    } else if d.texture_upload_buffer_offset + cast(u32) length >= TRANSFER_BUFFER_SIZE {
        // cycle transfer buffer because we're going to run out of space
        if d.texture_upload_cycle_count < MAX_UPLOAD_CYCLE_COUNT {
            transfer_cycle = true;
            d.texture_upload_cycle_count += 1;
            d.texture_upload_buffer_offset = 0;
            transfer_offset = 0;
        } else {
            sdl_flush_commands(d, stall = true);
            transfer_cycle = true;
            transfer_offset = 0;
        }
    } else {
        // normal transfer using existing buffer, only cycle if we're at the start
        transfer_cycle = d.texture_upload_buffer_offset == 0;
        transfer_offset = d.texture_upload_buffer_offset;
    }

    // copy data
    {
        dst := cast(*u8) SDL_MapGPUTransferBuffer(d.device, transfer_buffer, transfer_cycle) + transfer_offset;
        memcpy(dst, data, length);
        SDL_UnmapGPUTransferBuffer(d.device, transfer_buffer);
    }

    // upload to the GPU
    {
        sdl_begin_copy_pass(d);

        source: SDL_GPUTextureTransferInfo;
        source.transfer_buffer = transfer_buffer;
        source.offset = transfer_offset;
        // 0 here means width & height of destination region are used as defaults
        source.pixels_per_row = 0;
        source.rows_per_layer = 0;

        destination: SDL_GPUTextureRegion;
        destination.texture = res.texture;
        destination.layer = 0;
        destination.mip_level = 0;
        destination.x = cast(u32) dest_region.x;
        destination.y = cast(u32) dest_region.y;
        destination.z = 0;
        destination.w = cast(u32) dest_region.w;
        destination.h = cast(u32) dest_region.h;
        destination.d = 1;

        SDL_UploadToGPUTexture(d.copy_pass, *source, *destination, false);
    }

    // transfer buffer management
    if using_temporary_transfer_buffer {
        SDL_ReleaseGPUTransferBuffer(d.device, transfer_buffer);
    } else {
        d.texture_upload_buffer_offset += cast(u32) length;
    }
}

sdl_get_texture_data :: (d: *Graphics_Device, handle: Graphics_Resource_Handle, data: *void, length: s32, source_region: Rect_Int) {
    assert(d.device != null, "GPU Device has not been created");

    res := sdl_require_resource(d, handle);
    assert(res.kind == .TEXTURE, "Resource is not a Texture");

    // search up for the resolve texture
    if res.multi_sample_resolve != 0 {
        sdl_get_texture_data(d, res.multi_sample_resolve, data, length, source_region);
        return;
    }

    // we only allow one download at a time
    mutex_lock(*d.texture_download_mutex);
    {
        // BISECT: submit + WaitForGPUIdle instead of a fence-stall flush
        sdl_flush_commands(d, stall = false);
        SDL_WaitForGPUIdle(d.device);

        // verify download buffer is big enough
        if d.texture_download_buffer == null || d.texture_download_buffer_size < cast(u32) length {
            if d.texture_download_buffer != null {
                SDL_ReleaseGPUTransferBuffer(d.device, d.texture_download_buffer);
            }

            info: SDL_GPUTransferBufferCreateInfo;
            info.usage = .SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
            info.size = cast(u32) length;
            info.props = 0;
            d.texture_download_buffer = SDL_CreateGPUTransferBuffer(d.device, *info);
            d.texture_download_buffer_size = cast(u32) length;
        }

        // download from the gpu
        {
            sdl_begin_copy_pass(d);

            source: SDL_GPUTextureRegion;
            source.texture = res.texture;
            source.layer = 0;
            source.mip_level = 0;
            source.x = cast(u32) source_region.x;
            source.y = cast(u32) source_region.y;
            source.z = 0;
            source.w = cast(u32) source_region.w;
            source.h = cast(u32) source_region.h;
            source.d = 1;

            destination: SDL_GPUTextureTransferInfo;
            destination.transfer_buffer = d.texture_download_buffer;
            destination.offset = 0;
            destination.pixels_per_row = 0;
            destination.rows_per_layer = 0;

            SDL_DownloadFromGPUTexture(d.copy_pass, *source, *destination);
        }

        // flush and stall so the data is up to date
        sdl_flush_commands(d, stall = false);
        SDL_WaitForGPUIdle(d.device);

        // copy data
        {
            src := SDL_MapGPUTransferBuffer(d.device, d.texture_download_buffer, false);
            memcpy(data, src, length);
            SDL_UnmapGPUTransferBuffer(d.device, d.texture_download_buffer);
        }
    }
    mutex_unlock(*d.texture_download_mutex);
}

sdl_blit_texture :: (d: *Graphics_Device, source_texture: Graphics_Resource_Handle, source_region: Rect_Int,
                     dest_texture: Graphics_Resource_Handle, dest_region: Rect_Int, filter: Texture_Filter) {
    // without this, the texture won't necessarily be fully uploaded
    sdl_flush_commands(d, stall = false);

    src := sdl_require_resource(d, source_texture);
    dst := sdl_require_resource(d, dest_texture);
    assert(src.kind == .TEXTURE && dst.kind == .TEXTURE);

    // validate texture regions; don't let them go out of bounds since we cast to uint
    // Jai 的过程参数是不可变的，夹取结果落到局部变量。
    src_region := rect_int_get_intersection(source_region, Rect_Int.{ 0, 0, src.width, src.height });
    dst_region := rect_int_get_intersection(dest_region,   Rect_Int.{ 0, 0, dst.width, dst.height });

    blit: SDL_GPUBlitInfo;
    blit.source.texture = sdl_sampler_texture(d, src);
    blit.source.mip_level = 0;
    blit.source.layer_or_depth_plane = 0;
    blit.source.x = cast(u32) src_region.x;
    blit.source.y = cast(u32) src_region.y;
    blit.source.w = cast(u32) src_region.w;
    blit.source.h = cast(u32) src_region.h;

    blit.destination.texture = dst.texture;
    blit.destination.mip_level = 0;
    blit.destination.layer_or_depth_plane = 0;
    blit.destination.x = cast(u32) dst_region.x;
    blit.destination.y = cast(u32) dst_region.y;
    blit.destination.w = cast(u32) dst_region.w;
    blit.destination.h = cast(u32) dst_region.h;

    blit.load_op = .SDL_GPU_LOADOP_DONT_CARE;
    blit.flip_mode = .SDL_FLIP_NONE;
    blit.filter = sdl_get_filter(filter);
    blit.cycle = true;

    SDL_BlitGPUTexture(d.cmd_render, *blit);
}

sdl_create_target :: (d: *Graphics_Device, width: s32, height: s32) -> Graphics_Resource_Handle {
    handle := sdl_register_resource(d, .TARGET);
    res := sdl_require_resource(d, handle);
    return handle;
}

sdl_create_buffer :: (d: *Graphics_Device, name: string, type: Buffer_Kind, format: Index_Format) -> Graphics_Resource_Handle {
    usage: SDL_GPUBufferUsageFlags;
    if type == {
        case .VERTEX;          usage = .SDL_GPU_BUFFERUSAGE_VERTEX;
        case .INDEX;           usage = .SDL_GPU_BUFFERUSAGE_INDEX;
        case .STORAGE;         usage = .SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;
        case .COMPUTE_STORAGE;
            usage = .SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                    .SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE |
                    .SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;
    }

    handle := sdl_register_resource(d, .BUFFER);
    res := sdl_require_resource(d, handle);
    res.name = name;
    res.usage = usage;
    res.index_format = format;
    return handle;
}

sdl_upload_buffer_data :: (d: *Graphics_Device, handle: Graphics_Resource_Handle, data: *void, data_size: s32, data_dest_offset: s32) {
    // Uploads use a separate command buffer submitted before rendering. Once a
    // draw is recorded, submit it before overwriting buffers it still borrows.
    // Otherwise later instance/UI uploads replace data used by earlier draws.
    if data != null && d.render_pass != null sdl_flush_commands(d, stall = false);
    res := sdl_require_resource(d, handle);
    assert(res.kind == .BUFFER);
    res.dirty = true;

    // (re)create buffer if needed
    required := data_size + data_dest_offset;
    if required > res.capacity || res.buffer == null {
        // NOTE (Foster TODO): a resize wipes all contents but the API doesn't expect this
        if res.buffer != null {
            SDL_ReleaseGPUBuffer(d.device, res.buffer);
            res.buffer = null;
        }

        size: s32;
        if res.capacity == 0 {
            // never create a buffer that has 0 length
            size = cast(s32) max(8, required);
        } else {
            size = 8;
            while size < required size *= 2;
        }

        props: SDL_PropertiesID = 0;
        if res.name != "" {
            props = SDL_CreateProperties();
            prop_name := to_cstr(SDL_PROP_GPU_BUFFER_CREATE_NAME_STRING);
            name_c := to_cstr(res.name);
            SDL_SetStringProperty(props, prop_name, name_c);
            free(prop_name); free(name_c);
        }

        info: SDL_GPUBufferCreateInfo;
        info.usage = res.usage;
        info.size = cast(u32) size;
        info.props = props;
        res.buffer = SDL_CreateGPUBuffer(d.device, *info);

        if props != 0 SDL_DestroyProperties(props);

        if res.buffer == null {
            log_error(app_sdl_error_message("SDL_CreateGPUBuffer", "Mesh Creation Failed"));
            assert(false, "SDL_CreateGPUBuffer failed");
        }
        res.capacity = size;
    }

    // exit out if there's no data to upload
    if data == null return;

    using_temporary_transfer_buffer := false;
    transfer_buffer := d.buffer_upload_buffer;
    transfer_offset: u32;
    transfer_cycle: bool;

    if data_size >= TRANSFER_BUFFER_SIZE {
        info: SDL_GPUTransferBufferCreateInfo;
        info.usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        info.size = cast(u32) data_size;
        info.props = 0;
        transfer_buffer = SDL_CreateGPUTransferBuffer(d.device, *info);
        using_temporary_transfer_buffer = true;
        transfer_cycle = false;
        transfer_offset = 0;
    } else if d.buffer_upload_buffer_offset + cast(u32) data_size >= TRANSFER_BUFFER_SIZE {
        if d.buffer_upload_cycle_count < MAX_UPLOAD_CYCLE_COUNT {
            transfer_cycle = true;
            transfer_offset = 0;
            d.buffer_upload_cycle_count += 1;
            d.buffer_upload_buffer_offset = 0;
        } else {
            sdl_flush_commands(d, stall = true);
            transfer_cycle = true;
            transfer_offset = 0;
        }
    } else {
        transfer_cycle = d.buffer_upload_buffer_offset == 0;
        transfer_offset = d.buffer_upload_buffer_offset;
    }

    // copy data
    {
        dst := cast(*u8) SDL_MapGPUTransferBuffer(d.device, transfer_buffer, transfer_cycle) + transfer_offset;
        memcpy(dst, data, data_size);
        SDL_UnmapGPUTransferBuffer(d.device, transfer_buffer);
    }

    // submit to the GPU
    {
        sdl_begin_copy_pass(d);

        source: SDL_GPUTransferBufferLocation;
        source.transfer_buffer = transfer_buffer;
        source.offset = transfer_offset;

        destination: SDL_GPUBufferRegion;
        destination.buffer = res.buffer;
        destination.offset = cast(u32) data_dest_offset;
        destination.size = cast(u32) data_size;

        // NOTE: Foster uses cycle=true here; SDL 3.4.12 cycling broke multi-frame
        // rendering in our tests, so uploads never cycle (contents persist).
        SDL_UploadToGPUBuffer(d.copy_pass, *source, *destination, false);
    }

    // transfer buffer management
    if using_temporary_transfer_buffer {
        SDL_ReleaseGPUTransferBuffer(d.device, transfer_buffer);
    } else {
        d.buffer_upload_buffer_offset += cast(u32) data_size;
    }
}

sdl_create_shader :: (d: *Graphics_Device, shader: *Shader, code: [] u8, entry_point: string) -> Graphics_Resource_Handle {
    assert(d.device != null, "GPU Device has not been created");

    format: SDL_GPUShaderFormat = .SDL_GPU_SHADERFORMAT_SPIRV;
    if d.driver == .D3D12 format = .SDL_GPU_SHADERFORMAT_DXIL;
    if d.driver == .METAL format = .SDL_GPU_SHADERFORMAT_MSL;

    entry := to_cstr(entry_point);

    result: Graphics_Resource_Handle = 0;
    if shader.Stage == .COMPUTE {
        props: SDL_PropertiesID = 0;
        if shader.Name != "" {
            props = SDL_CreateProperties();
            prop_name := to_cstr(SDL_PROP_GPU_COMPUTEPIPELINE_CREATE_NAME_STRING);
            name_c := to_cstr(shader.Name);
            SDL_SetStringProperty(props, prop_name, name_c);
            free(prop_name); free(name_c);
        }

        info: SDL_GPUComputePipelineCreateInfo;
        info.code_size = cast(u64) code.count;
        info.code = code.data;
        info.entrypoint = entry;
        info.format = format;
        info.num_samplers = cast(u32) shader.SamplerCount;
        info.num_readonly_storage_textures = cast(u32) shader.ReadOnlyStorageTextureCount;
        info.num_readonly_storage_buffers = cast(u32) shader.ReadOnlyStorageBufferCount;
        info.num_readwrite_storage_textures = cast(u32) shader.ReadWriteStorageTextureCount;
        info.num_readwrite_storage_buffers = cast(u32) shader.ReadWriteStorageBufferCount;
        info.num_uniform_buffers = cast(u32) shader.UniformBufferCount;
        info.threadcount_x = cast(u32) shader.ThreadCountX;
        info.threadcount_y = cast(u32) shader.ThreadCountY;
        info.threadcount_z = cast(u32) shader.ThreadCountZ;
        info.props = props;

        pipeline := SDL_CreateGPUComputePipeline(d.device, *info);
        if props != 0 SDL_DestroyProperties(props);
        if pipeline == null {
            log_error(app_sdl_error_message("SDL_CreateGPUComputePipeline", "Failed to create Compute Shader"));
            assert(false, "SDL_CreateGPUComputePipeline failed");
        }

        result = sdl_register_resource(d, .COMPUTE);
        sdl_require_resource(d, result).pipeline = pipeline;
    } else {
        props: SDL_PropertiesID = 0;
        if shader.Name != "" {
            props = SDL_CreateProperties();
            prop_name := to_cstr(SDL_PROP_GPU_SHADER_CREATE_NAME_STRING);
            name_c := to_cstr(shader.Name);
            SDL_SetStringProperty(props, prop_name, name_c);
            free(prop_name); free(name_c);
        }

        info: SDL_GPUShaderCreateInfo;
        info.code_size = cast(u64) code.count;
        info.code = code.data;
        info.entrypoint = entry;
        info.format = format;
        info.stage = ifx shader.Stage == .VERTEX then .SDL_GPU_SHADERSTAGE_VERTEX else .SDL_GPU_SHADERSTAGE_FRAGMENT;
        info.num_samplers = cast(u32) shader.SamplerCount;
        info.num_storage_textures = 0;
        info.num_storage_buffers = cast(u32) shader.StorageBufferCount;
        info.num_uniform_buffers = cast(u32) shader.UniformBufferCount;
        info.props = props;

        program := SDL_CreateGPUShader(d.device, *info);
        if props != 0 SDL_DestroyProperties(props);
        if program == null {
            log_error(app_sdl_error_message("SDL_CreateGPUShader", tprint("Failed to create % Shader", shader.Stage)));
            assert(false, "SDL_CreateGPUShader failed");
        }

        result = sdl_register_resource(d, .SHADER);
        sdl_require_resource(d, result).shader = program;
    }

    // NOTE: entry is intentionally NOT freed — SDL_GPU does not copy the
    // entrypoint string, so it must outlive the shader (one small alloc per shader).
    return result;
}

sdl_destroy_resource :: (d: *Graphics_Device, resource: Graphics_Resource_Handle) {
    it, found := map_get(*d.resources, resource);
    if found {
        table_remove(*d.resources, resource);
        if it.kind == {
            case .TEXTURE;
                if it.multi_sample_resolve != 0 {
                    sdl_destroy_resource(d, it.multi_sample_resolve);
                }
                SDL_ReleaseGPUTexture(d.device, it.texture);
                free(it);
            case .TARGET;
                for att: it.attachments {
                    sdl_destroy_resource(d, att);
                }
                array_free(it.attachments);
                free(it);
            case .BUFFER;
                SDL_ReleaseGPUBuffer(d.device, it.buffer);
                free(it);
            case .SHADER;
                sdl_release_graphics_pipelines_associated_with(d, it);
                SDL_ReleaseGPUShader(d.device, it.shader);
                array_free(it.pipelines);
                free(it);
            case .COMPUTE;
                SDL_ReleaseGPUComputePipeline(d.device, it.pipeline);
                free(it);
        }
    }
}

sdl_release_graphics_pipelines_associated_with :: (d: *Graphics_Device, shader_res: *GPU_Resource) {
    for it: shader_res.pipelines {
        pipeline, found := map_get(*d.pipelines, it);
        if found {
            SDL_ReleaseGPUGraphicsPipeline(d.device, pipeline);
            table_remove(*d.pipelines, it);
        }
    }
    array_reset(*shader_res.pipelines);
}
