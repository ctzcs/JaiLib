#scope_module
using Basic;
using Math;
using Hash_Table;
#scope_module

// jfoster — Graphics backend, web (wasm64) — **W3: WebGL2 最小可绘制后端**
//
// ===========================================================================
// 这个后端要满足的契约
// ===========================================================================
// `graphics/graphics_device.jai` 是*公开校验层*（Foster 的 GraphicsDevice.cs）：
// 参数检查、句柄簿记，然后调进 ~40 个 `sdl_*` 后端入口。它从来看不到 SDL_GPU
// 的具体类型（除了三个查询），所以 web 后端只要满足同一份 `sdl_*` 契约，
// `graphics/` 下的 5000 行（batcher / sprite_font / mesh / material / target…）
// 就能一字不改地为 wasm 编译。W1 用**桩**证明了这件事成立；W3 把桩换成真的
// WebGL2 调用。
//
// ===========================================================================
// 三层地址：命令 → 状态 → GL 调用
// ===========================================================================
//   Draw_Command（graphics/draw_command.jai）
//     → sdl_perform_draw               本文件：与桌面后端逐行同构的流程
//     → web_gl_get_pipeline            取 program + VAO（按大哈希缓存）
//     → gl_*                           哑通道（web_bridge.jai 声明，host.js 实现）
//
// 三处和 SDL_GPU 的本质差异，W3 用「结构留位 + 诚实降级」处理：
//
// 1. **没有 pipeline 状态对象**。SDL 的 GraphicsPipeline 一次描述 blend / depth /
//    cull / stencil / 顶点布局；WebGL2 里前四样是全局状态。所以 web 的
//    pipeline = program + VAO（只有顶点布局），每次 draw 都重设状态
//    （web_gl_apply_state）。blend 在桌面是**永远打开**的
//    （sdl_get_blend_state 里 enable_blend = true），这里也一样 —— 两端的像素
//    才能对齐。
//
// 2. **uniform 按槽位，不按名字**（W4）。SDL_GPU 是 register(bN, spaceM)，
//    WebGL2 是 `layout(std140) uniform <Block>` + gl.uniformBlockBinding。
//    后端的映射因此是「槽位 == binding point」：vertex 槽 i → binding i，
//    fragment 槽 i → binding 8+i。block 里有什么、叫什么，后端一概不看（只有
//    sampler 还得按名字绑，因为 GLSL ES 3.00 不允许 opaque 类型进 block）。
//    详见 web_gl.jai 的「uniform 槽位 → std140 block 的 binding point」。
//
// 3. **没有 command buffer / copy pass**。桌面把上传攒进 copy pass 再提交；
//    WebGL2 是立即模式，所以 sdl_begin_copy_pass / sdl_flush_commands 之类的
//    形状保留、内容是空操作。sdl_upload_buffer_data / sdl_set_texture_data
//    直接落到 bufferSubData / texSubImage2D。
//
// ===========================================================================
// 渲染目标
// ===========================================================================
// W3 只画到 **canvas 的默认 framebuffer**（sdl_begin_render_pass 里
// Drawable_Target.Kind == .WINDOW → fbo 0）。于是：
//   * `state.backbuffer` 故意保持 null —— 没有离屏的 backbuffer Target 需要
//     创建、销毁、在切后台时回收（桌面的 sdl_on_event 有一整套）；
//   * `graphics_device_get_backbuffer()` 在 web 上返回 null，读回改走
//     gl_read_pixels（见 tests/wasm/main.jai 的 W3 验收）；
//   * 画到 `Kind == .TARGET`（render-to-texture）在 W3 是**明确失败**：返回
//     false + 一次性警告。W5 补 FBO + renderbuffer，挂点就是 web_gpu.pass_fbo。
//
// ===========================================================================
// 什么还是假的（见报告与 README §7.3）
// ===========================================================================
//   * 计算管线（glDispatchCompute 在 WebGL2 里不存在，W6 要换赛道）
//   * MSAA（要 renderbuffer + resolve，W5）
//   * sdl_blit_texture（要 FBO 到 FBO 的 blit，W5）
//   * FillMode.LINE（glPolygonMode 不在 WebGL2 里）
//   * 自定义着色器（没有槽位表；W4 的 std140 UBO 方案）
// 这些路径全部是「打一条一次性警告 + 什么都不做」，不会静默画错。
//
// 文件末尾 #load 同目录的 web_gl.jai（枚举翻译 + 句柄缓存）。放末尾是因为被 load
// 的文件会以 #scope_* 收尾，放前面会改变上面 sdl_* 的可见性。
//
// web_shader_source.jai（六个 GLSL ES 3.00 源）不在这里 load：W4 起
// graphics/default_resource_data.jai 的 wasm 分支需要它（shader 的字节就是 GLSL
// 文本），而那个文件在 module.jai 里排在 backend 之前 —— 在这里再 load 一次会被
// 判成 module-already-loaded。

//
// The three SDL entry points graphics_device.jai calls directly. They are
// `#if OS != .WASM` in the bindings (there is no SDL3 library to link), so the
// web build declares them here with the identical signature. The answers are the
// conservative ones: "not supported" makes the caller fall back instead of
// assuming a format uploads correctly.
//
// W3: these stay conservative even though a real GL context exists — reporting
// "supported" would let `graphics/defaults.jai` and the target code assume
// things about MSAA / depth formats that W3 genuinely cannot do yet (no FBO, no
// renderbuffer). W5 flips them to real queries.
//
// [W5] 这两个现在是真的查询。
//
// W3 把两个都答成 false / 「只有 1×」，因为那时候离屏 Target 整个不存在：报
// 「支持」会让调用方以为能建 MSAA 纹理/渲染目标，然后拿到一片黑。W5 有 FBO 和
// renderbuffer 了，答案改成「这张表里有没有」，而表本身（web_gl_sdl_internal_format
// + web_gl_sdl_format_renderable）是**代码里唯一**的能力来源，不会出现
// 「表说支持、GL 不认」这种两份真相。
//
// 采样数：MAX_SAMPLES 是设备属性（glGetParameter(MAX_SAMPLES)，GL ES 3.0 保证
// >= 4），所以 2×/4× 在最小机器上也成立；8× 要看设备。
SDL_GPUTextureSupportsFormat :: (device: *SDL_GPUDevice, format: SDL_GPUTextureFormat, type: SDL_GPUTextureType, usage: SDL_GPUTextureUsageFlags) -> bool {
    internal := web_gl_sdl_internal_format(format);
    if internal == 0 return false;   // 包括 B8G8R8A8（WebGL2 没有 BGRA8 存储格式）

    wants_target := (usage & (.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
                              .SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET)) != 0;
    if wants_target return web_gl_sdl_format_renderable(format);

    // 采样/上传：只要表里有就能建（RGBA16F 也是，浮点采样是 WebGL2 核心）。
    return true;
}

SDL_GPUTextureSupportsSampleCount :: (device: *SDL_GPUDevice, format: SDL_GPUTextureFormat, sample_count: SDL_GPUSampleCount) -> bool {
    count := web_gl_sdl_sample_count(sample_count);
    if count == 1 return web_gl_sdl_internal_format(format) != 0;
    if !web_gl_sdl_format_renderable(format) return false;   // 只有 renderable 的格式能多重采样
    if web_gpu.max_samples <= 0 return count <= 4;           // 还没有 context：报 ES 3.0 的下限
    return count <= web_gpu.max_samples;
}

SDL_InsertGPUDebugLabel :: (command_buffer: *SDL_GPUCommandBuffer, text: *u8) { }

//
// Enum translation shared with the desktop backend
//
// Pure table lookups that both backends must agree on. Duplicated (25 lines)
// instead of copied out of graphics_device_sdl.jai, because moving them would
// edit a desktop file that W1..W3 must leave untouched. They change together.
//

sdl_get_texture_format :: (format: Texture_Format) -> SDL_GPUTextureFormat {
    if format == {
        case .R8G8B8A8;        return .SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
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

//
// device / lifecycle
//

// Creates the WebGL2 device (one per page: `canvas.getContext("webgl2")`) and
// then does exactly what the desktop backend does to the rest of the framework:
// the fallback texture/buffer that `graphics/defaults.jai` samples when a
// material leaves a slot empty, and the backbuffer_format choice.
//
// `d.device` stays the "device exists" marker it was in W1 (a `*SDL_GPUDevice`
// is a `*void`; pointing it at the framework's own struct keeps every
// `d.device != null` assert in graphics_device.jai and the kit layer happy).
// The JS-side handle lives in web_gpu.device — the browser has exactly one GL
// context, so it does not need to be per-device.
sdl_device_create :: (preferred: Graphics_Driver, flags: App_Flags) -> *Graphics_Device {
    web_gpu_reset();

    d := New(Graphics_Device);
    d.driver = .PRIVATE;         // no SDL driver name to report; PRIVATE is the stub's old value
    d.disposed = false;
    d.preferred = preferred;
    d.flags = flags;

    d.device = cast(*SDL_GPUDevice) d;

    d.cmd_upload = null;
    d.cmd_render = null;
    d.render_pass = null;
    d.copy_pass = null;
    d.vsync_enabled = false;
    d.in_background = false;
    mutex_init(*d.texture_download_mutex);

    // The real thing: canvas → webgl2 context.
    {
        width, height := web_canvas_size();
        web_gpu.device = gl_device_create(width, height);
    }

    if web_gpu.device <= 0 {
        // No canvas (Node verifier) or no WebGL2 (old browser / blocklisted GPU).
        // Everything below still runs so that the bookkeeping — and therefore the
        // whole framework — behaves; draws become no-ops and say so once.
        if !web_gpu.warned_no_gl {
            web_gpu.warned_no_gl = true;
            log_warning("graphics_device_create: 宿主没有 WebGL2（无 canvas 或浏览器不支持）—— 后端进入「只簿记不绘制」模式");
        }
    } else {
        web_gl_log_context();
        web_gl_query_capabilities();
    }

    // [W6] 窗口级 MSAA。桌面是把整帧画到一张超采样的离屏 backbuffer、present 时
    // blit 到 swapchain；web 上的等价物是「窗口大小的 MS FBO + end pass 时
    // blitFramebuffer 到 0 号 FBO」，由 web_gl.jai :: web_gl_window_msaa_ensure 建、
    // web_gl_window_msaa_resolve 解析。
    //
    // 这里只**表达意图**（想要几倍采样），真正的 FBO 要等 canvas 尺寸确定（window
    // 创建 / resize）之后才建 —— backbuffer_format 报告的是真实生效的采样数，
    // 不再是「说一套做一套」。
    if (flags & .MULTI_SAMPLED_BACK_BUFFER) != 0 {
        web_gl_window_msaa_configure(4);
        d.backbuffer_format = .{ Format = .COLOR, Flags = .NONE,
                                 SampleCount = ifx web_gpu.window_msaa_wanted then .FOUR else .ONE };
        if !web_gpu.window_msaa_wanted {
            if !web_gpu.warned_msaa {
                web_gpu.warned_msaa = true;
                log_info(tprint("graphics_device_create: MULTI_SAMPLED_BACK_BUFFER 被请求，但这台设备的 MAX_SAMPLES = % —— 窗口按单采样",
                                web_gpu.max_samples));
            }
            d.backbuffer_format.SampleCount = .ONE;
        } else {
            log_info(tprint("graphics_device_create: MULTI_SAMPLED_BACK_BUFFER 已启用 —— 窗口目标 % 倍采样（MS FBO + present 时 resolve 到 0 号 FBO）",
                            web_gpu.window_msaa_samples));
        }
    }

    // Fallbacks: the same two GPU resources the desktop backend creates, now
    // backed by real GL objects (a 1×1 RGBA8 texture and an 8-byte buffer).
    {
        data := color_from_rgba(0x00e82979);
        d.empty_default_texture = sdl_create_texture(d, "Fallback", 1, 1, .R8G8B8A8, .NONE, .ONE, 0);
        d.empty_default_compute_storage_texture = sdl_create_texture(d, "StorageFallback", 1, 1, .R8G8B8A8, .COMPUTE_READ | .COMPUTE_WRITE, .ONE, 0);
        sdl_set_texture_data(d, d.empty_default_texture, *data, 4, .{ 0, 0, 1, 1 });
        sdl_set_texture_data(d, d.empty_default_compute_storage_texture, *data, 4, .{ 0, 0, 1, 1 });
    }
    {
        data: u8 = 0;
        d.empty_default_buffer = sdl_create_buffer(d, "Fallback", .STORAGE, .SIXTEEN);
        sdl_upload_buffer_data(d, d.empty_default_buffer, *data, 1, 0);
    }

    if (flags & .NO_HEADER_LOG) == 0 {
        if web_gpu.device > 0 {
            log_info("Graphics Driver: web (WebGL2, W3 —— clear + textured quad 可用；Batcher/字体见 W4)");
        } else {
            log_info("Graphics Driver: web (无 WebGL2 —— W3 后端只簿记)");
        }
    }
    return d;
}

// One line + one multi-line block describing the GL context. Goes to the host
// log so the browser console (and --dump-dom) shows exactly which renderer ran:
// the report's pixel evidence means nothing without it.
web_gl_log_context :: () {
    if web_gpu.device <= 0 return;

    // 每行一个独立缓冲区：web_gl_string 返回的是**指向这块缓冲区的 string 视图**
    // （故意不分配），复用一块的话三行日志会全都指向最后一次写入的内容。
    log_info(tprint("web/gl: %", web_gl_string(0)));
    log_info(tprint("web/gl: renderer = %", web_gl_string(1)));
    log_info(tprint("web/gl: glsl = %", web_gl_string(3)));
    log_info(tprint("web/gl: max texture = %, max vertex attribs = %, texture units = %",
                    gl_get_param(2), gl_get_param(3), gl_get_param(4)));
    log_info(tprint("web/gl: canvas = %x% device pixels, drawing buffer = %x%",
                    gl_get_param(0), gl_get_param(1), gl_get_param(6), gl_get_param(7)));
}

// 0 VERSION / 1 RENDERER / 2 VENDOR / 3 SHADING_LANGUAGE_VERSION
//
// 返回的是**指向静态缓冲区**的 string 视图：不分配、不能跨越下一次调用保存
// （调用方只用来 log，这也是它不用 tprint 拼接的原因）。
WEB_GL_INFO_BUFFER_SIZE :: 256;
web_gl_info_buffer: [WEB_GL_INFO_BUFFER_SIZE] u8;

web_gl_string :: (which: s32) -> string {
    n := gl_get_string(which, web_gl_off(*web_gl_info_buffer[0]), WEB_GL_INFO_BUFFER_SIZE);
    if n <= 0 return "(unknown)";
    return web_str_of(*web_gl_info_buffer[0], min(n, WEB_GL_INFO_BUFFER_SIZE));
}

// [W5] 设备能力问一次，之后按它决定「这个采样数/格式行不行」。
//
// 为什么要问而不是写死：MAX_SAMPLES 在 GL ES 3.0 只保证 >= 4，MAX_COLOR_ATTACHMENTS
// 保证 >= 4，而 EXT_color_buffer_float 可能完全没有（SwiftShader 有，老移动 GPU
// 不一定）。写死的话，一份「4× 一定行」的假设会在某些机器上变成
// INCOMPLETE_MULTISAMPLE，而错误信息只会说"不完整"。
web_gl_query_capabilities :: () {
    web_gpu.max_samples = cast(s32) max(1, gl_get_param(5));
    web_gpu.max_renderbuffer = gl_get_param(9);
    web_gpu.max_color_attachments = cast(s32) max(1, gl_get_param(10));
    web_gpu.float_renderable = gl_get_param(11) > 0;
    // [W6] 纹理上限。超过它的创建要在 **Jai 侧** 就拒绝：GL 那边只会给一个
    // INVALID_VALUE，然后纹理变成一个不可用的对象，而调用方拿到的 handle 依然
    // "有效" —— 后面每一次 draw 都在画一张空纹理，最难查的一类静默降级。
    web_gpu.max_texture_size = gl_get_param(2);
    log_info(tprint("web/gl: 能力 —— MAX_SAMPLES=% MAX_RENDERBUFFER=% 颜色附件=% MAX_TEXTURE_SIZE=% EXT_color_buffer_float=%",
                    web_gpu.max_samples, web_gpu.max_renderbuffer,
                    web_gpu.max_color_attachments, web_gpu.max_texture_size,
                    web_gpu.float_renderable));
}

sdl_shutdown :: (d: *Graphics_Device) {
    if d == null return;

    // Desktop submits the remaining command buffers here; there is nothing to
    // submit in WebGL2 (immediate mode), but the render pass must be closed so
    // the state machine is back at rest.
    sdl_end_copy_pass(d);
    sdl_end_render_pass(d);

    // [W6] 窗口级 MSAA 的 renderbuffer / FBO 先回收：它们不属于任何 GPU_Resource
    // （窗口没有 Target 对象），所以不会走 sdl_destroy_resource 那条路。
    web_gl_window_msaa_release();

    defaults_destroy(d);

    // Release the Jai-side bookkeeping. The GPU objects themselves go away with
    // the context (gl_device_destroy → loseContext), which is the only honest
    // teardown for a canvas: there is no per-object "release device" step that
    // would matter, and a double-delete through target attachments is exactly
    // the bug this ordering avoids.
    for v, k: d.resources {
        if v != null free(v);
    }
    table_reset(*d.resources);
    table_reset(*d.pipelines);
    table_reset(*d.samplers);

    for v, k: d.windows {
        if v != null free(v);
    }
    table_reset(*d.windows);

    d.cmd_render = null;
    d.cmd_upload = null;
    d.render_pass = null;
    d.copy_pass = null;

    if web_gpu.device > 0 {
        gl_device_destroy();
    }
    web_gpu_reset();
}

sdl_destroy_device :: (d: *Graphics_Device) {
    if d == null return;
    if !d.disposed {
        sdl_shutdown(d);
        d.device = null;
        d.disposed = true;
    }
    free(d);
}

//
// window / swapchain
//

// The canvas *is* the swapchain: no claim, no present mode, no backbuffer
// Target. What is real: the drawing buffer is resized to the canvas backing
// store and the viewport follows it.
sdl_window_created :: (d: *Graphics_Device, window: *Window) {
    if d == null || window == null return;
    if table_find_pointer(*d.windows, window.id) != null return;   // already tracked

    state := New(GPU_Window_State);
    state.id = window.id;
    state.handle = window.handle;
    state.reclaim_pending = false;
    state.claimed = true;
    state.backbuffer = null;                       // nothing offscreen in W3
    state.backbuffer_size = window_size_in_pixels(window);
    state.supports_mailbox_present_mode = false;
    state.supports_immediate_present_mode = false;
    state.present_mode = .SDL_GPU_PRESENTMODE_VSYNC;
    state.has_present_mode = false;
    table_set(*d.windows, window.id, state);

    if web_gpu.device > 0 {
        size := state.backbuffer_size;
        if size.x > 0 && size.y > 0 {
            gl_swapchain_bind(size.x, size.y);
            // [W6] 窗口级 MSAA 的 renderbuffer 尺寸是固定的，尺寸一变就得重建。
            web_gl_window_msaa_ensure(size.x, size.y);
        }
    }
}

sdl_window_destroyed :: (d: *Graphics_Device, window: *Window) {
    if d == null || window == null return;
    state := table_find_pointer(*d.windows, window.id);
    if state != null {
        free(<<state);
        table_remove(*d.windows, window.id);
    }
}

sdl_update_window_present_mode :: (d: *Graphics_Device, state: *GPU_Window_State, vsync_enabled: bool) {
    if d == null || state == null return;
    // The browser owns presentation; there is no swapchain to reconfigure. Record
    // the intent so the getter and any future diagnostics see what desktop would
    // have written (rAF pacing == VSYNC).
    state.present_mode = ifx vsync_enabled then .SDL_GPU_PRESENTMODE_VSYNC else .SDL_GPU_PRESENTMODE_IMMEDIATE;
    state.has_present_mode = true;
}

// [W6] 窗口级 MSAA 的「present」就是 end_render_pass 里的那次 resolve
// （ms_fbo → 0 号 FBO）。之后 gl_present 只是把队列交给驱动 —— 浏览器在任务结束
// 时合成 0 号 FBO，所以执行顺序不能反：先 resolve 再 flush。
sdl_present :: (d: *Graphics_Device) {
    if d == null return;

    sdl_end_copy_pass(d);
    sdl_end_render_pass(d);

    if web_gpu.device <= 0 return;

    // WebGL2 has no present call: the browser composites the drawing buffer at
    // the end of the task, which is exactly what gl.flush() hands over to. Doing
    // it here (rather than never) keeps the GPU work overlapped with the JS side
    // of the next frame.
    gl_present();
    web_gl_check_error("present");
}

sdl_on_event :: (d: *Graphics_Device, type: SDL_EventType) {
    if d == null return;
    if type == .SDL_EVENT_WILL_ENTER_BACKGROUND || type == .SDL_EVENT_DID_ENTER_BACKGROUND {
        // Desktop frees the window backbuffers here and reclaims them on resume.
        // There is no backbuffer to free (we draw straight to the canvas), so the
        // only thing that matters is not issuing draws while hidden.
        d.in_background = true;
    } else if type == .SDL_EVENT_WILL_ENTER_FOREGROUND || type == .SDL_EVENT_DID_ENTER_FOREGROUND {
        d.in_background = false;
    }
}

// Desktop re-acquires the swapchain for a window that lost its surface (Android
// background/foreground). A canvas cannot lose its drawing buffer like that, but
// the name stays so the contract is complete: on resume the size may have
// changed while we were hidden, so re-bind it.
sdl_reclaim_window :: (d: *Graphics_Device, state: *GPU_Window_State) {
    if d == null || state == null return;
    state.reclaim_pending = false;
    if web_gpu.device <= 0 return;
    if App.window != null {
        size := window_size_in_pixels(App.window);
        if size.x > 0 && size.y > 0 {
            state.backbuffer_size = size;
            gl_swapchain_bind(size.x, size.y);
            web_gl_window_msaa_ensure(size.x, size.y);   // [W6] 尺寸变了就重建 MS FBO
        }
    }
}

// Desktop blits the (oversized) offscreen backbuffer into the swapchain and
// submits. Here the window *is* its backbuffer, so presenting a window is a
// no-op beyond bookkeeping — sdl_present does the only GL call that exists.
sdl_present_window :: (d: *Graphics_Device, state: *GPU_Window_State) {
    if d == null || state == null return;
    state.has_present_mode = true;
}

//
// Resource bookkeeping
//
// These three live next to the device in graphics_device_sdl.jai on desktop; the
// public layer never calls them, but the creation paths below need the same
// semantics, so they are here too.
//

sdl_register_resource :: (d: *Graphics_Device, kind: GPU_Resource_Kind) -> Graphics_Resource_Handle {
    d.next_resource_id += 1;
    handle := d.next_resource_id;

    res := New(GPU_Resource);
    res.kind = kind;
    res.handle = handle;
    table_set(*d.resources, handle, res);
    return handle;
}

sdl_require_resource :: (d: *Graphics_Device, handle: Graphics_Resource_Handle) -> *GPU_Resource {
    res := sdl_find_resource(d, handle);
    assert(res != null, "GPU Resource has not been created");
    return res;
}

sdl_find_resource :: (d: *Graphics_Device, handle: Graphics_Resource_Handle) -> *GPU_Resource {
    if d == null || handle == 0 return null;
    res := table_find_pointer(*d.resources, handle);
    if res == null return null;
    return <<res;
}

// If multisampled, we should sample from the resolve texture, NOT the texture
// that is being multisampled. (W3 never creates a resolve texture — MSAA is W5 —
// but keeping the hop means that code does not have to change then.)
sdl_sampler_texture :: (d: *Graphics_Device, res: *GPU_Resource) -> *SDL_GPUTexture {
    if res == null return null;
    if res.multi_sample_resolve != 0 {
        resolve := sdl_find_resource(d, res.multi_sample_resolve);
        if resolve != null return resolve.texture;
    }
    return res.texture;
}

//
// textures
//

sdl_create_texture :: (d: *Graphics_Device, name: string, width: s32, height: s32,
                       format: Texture_Format, flags: Texture_Flags, sample_count: Sample_Count,
                       target_binding: Graphics_Resource_Handle) -> Graphics_Resource_Handle {
    // [W6] 尺寸上限前置检查。三条理由：
    //   1. `texture_create` 只 assert 了 > 0，一个 40000×16 的纹理在 GL 侧会拿到
    //      INVALID_VALUE，而 handle 依然是"有效"的 —— 调用方以为建成功了；
    //   2. texStorage2D 失败后纹理对象不可用，后面每次采样都是黑的，且**没有**
    //      任何一处会报错（驱动只在 getError 里有话说，而我们只在 check_error
    //      的调用点才看）；
    //   3. 大多数驱动在超限时不是"拒绝"而是直接 abort/丢 context（SwiftShader 会
    //      抛异常），那是崩溃，不是错误。
    // 所以：明确拒绝 + 一条能直接照做的错误 + 返回 0 句柄（调用方的 handle 为 0，
    // 绘制路径会跳过它，和「格式不支持」同一个行为）。
    if width <= 0 || height <= 0 {
        log_error(tprint("web/gl: 纹理 '%' 的尺寸非法（%x%）—— 拒绝创建", name, width, height));
        web_gpu.texture_size_rejections += 1;
        return 0;
    }
    if web_gpu.device > 0 && web_gpu.max_texture_size > 0 &&
       (width > web_gpu.max_texture_size || height > web_gpu.max_texture_size) {
        web_gpu.texture_size_rejections += 1;
        log_error(tprint("web/gl: 纹理 '%' 的尺寸 %x% 超过 MAX_TEXTURE_SIZE = % —— 拒绝创建（不降级、不崩溃；更大要分块或用压缩格式）",
                         name, width, height, web_gpu.max_texture_size));
        return 0;
    }

    // [W5] 格式矩阵前置检查：不认识/做不到的格式**在注册资源之前**就失败。
    //
    // W3 的写法是先 register 再"兜底成 RGBA8"，于是「格式不支持」变成了一张内容
    // 正确但通道顺序/位宽不对的纹理 —— 最糟的降级。现在：log_error + 返回 0，
    // 调用方（graphics/target.jai、texture.jai）拿到 0 句柄，绘制会被后端跳过，
    // 而且日志里有明确的一行。
    internal_format, _, _, known := web_gl_texture_formats(format);
    if !known {
        web_gpu.unsupported_formats += 1;
        log_error(tprint("web/gl: 纹理格式 % 在 WebGL2 里没有对应的 sized internal format —— 拒绝创建（不降级成 RGBA8）。见 internal/web/README.md 的格式矩阵",
                         format));
        return 0;
    }

    handle := sdl_register_resource(d, .TEXTURE);
    res := sdl_require_resource(d, handle);
    res.texture = null;
    res.width = width;
    res.height = height;
    res.format = sdl_get_texture_format(format);
    res.sample_count = sdl_get_sample_count(sample_count);
    res.multi_sample_resolve = 0;

    // `flags` (COMPUTE_READ/WRITE) has no WebGL2 counterpart for a sampled
    // texture — compute storage is W6 — so it is accepted and dropped, exactly
    // like the desktop backend drops it for non-compute usage.

    // Attach to the target that owns us. 这份列表就是 W5 拼 FBO 的输入
    // （web_gl.jai :: web_gl_target_build），所以顺序很重要：MSAA 的附件先登记，
    // 它的解析纹理随后登记 —— 拼 FBO 时解析纹理会被跳过（见那里的说明）。
    if target_binding != 0 {
        target_res := sdl_find_resource(d, target_binding);
        if target_res != null && target_res.kind == .TARGET {
            array_add(*target_res.attachments, handle);
        }
    }

    if web_gpu.device <= 0 return handle;

    // [W5] 多重采样（桌面语义的镜像）：
    //
    // 桌面 sdl_create_texture 在 sample_count != ONE 时**先建一张 MS 纹理，再递归
    // 建一张 sample_count = ONE 的解析纹理**，并把 res.multi_sample_resolve 指向它。
    // W3 的 web 版本把 multi_sample_resolve 塞成了 target_binding（一个 TARGET
    // 句柄）—— 那是错的：sdl_sampler_texture / sdl_set_texture_data / 销毁路径都按
    // 「它是一张 TEXTURE」来用它，结果采样会拿到 null、上传会被丢掉、销毁还可能
    // 递归到正在销毁的自己。
    //
    // WebGL2 没有 MS 纹理（texStorage2DMultisample 是 ES 3.1），所以这里：
    //   * 不建 MS 纹理对象（res.texture 留 null，绘制时用的是 renderbuffer，
    //     由 web_gl_target_build 建）；
    //   * 只建解析纹理（单采样、可采样、可读回），并把它登记成 target 的附件。
    // 于是「采样一张 MSAA 附件的颜色」在 web 上和桌面上是同一个答案。
    samples := web_gl_sdl_sample_count(res.sample_count);
    if samples > 1 {
        if samples > web_gpu.max_samples {
            if !web_gpu.warned_msaa_supported {
                web_gpu.warned_msaa_supported = true;
                log_error(tprint("web/gl: '%' 请求 % 倍采样，但 MAX_SAMPLES = % —— 请改用 <= % 倍",
                                 name, samples, web_gpu.max_samples, web_gpu.max_samples));
            }
            samples = web_gpu.max_samples;
        }
        // [W6] 多重采样附件是 renderbuffer，大小受 MAX_RENDERBUFFER_SIZE 约束
        // （见 web_gl_target_entry 的同一条检查；这里提前一次是为了让错误落在
        // 「创建纹理」这个动作上，而不是等到第一次 draw）。
        if web_gpu.max_renderbuffer > 0 &&
           (width > web_gpu.max_renderbuffer || height > web_gpu.max_renderbuffer) {
            web_gpu.renderbuffer_size_rejections += 1;
            log_error(tprint("web/gl: '%' 要用 %x% 的多重采样 renderbuffer，超过 MAX_RENDERBUFFER_SIZE = % —— 拒绝创建",
                             name, width, height, web_gpu.max_renderbuffer));
            return 0;
        }
        resolve_name := ifx name != "" then tprint("Resolve-%", name) else "Resolve";
        res.multi_sample_resolve = sdl_create_texture(d, resolve_name, width, height, format, flags, .ONE, target_binding);
        return handle;
    }

    // Filtering lives on the Sampler Object in WebGL2 (bindSampler), so the
    // texture's own filters only matter when nothing is bound. LINEAR without
    // mipmaps is a complete texture, which is what every upload path assumes.
    texture_id := gl_create_texture(width, height, internal_format,
                                    GL_LINEAR, GL_LINEAR, GL_CLAMP_TO_EDGE, GL_CLAMP_TO_EDGE);
    if texture_id <= 0 {
        web_gl_check_error("create_texture");
        return handle;
    }
    res.texture = web_gl_ptr(texture_id);

    return handle;
}

sdl_set_texture_data :: (d: *Graphics_Device, handle: Graphics_Resource_Handle, data: *void, length: s32, dest_region: Rect_Int) {
    if length <= 0 return;
    res := sdl_find_resource(d, handle);
    if res == null || res.kind != .TEXTURE return;

    // Search up for the resolve texture if we're multisampled (same as desktop).
    if res.multi_sample_resolve != 0 {
        sdl_set_texture_data(d, res.multi_sample_resolve, data, length, dest_region);
        return;
    }

    if web_gpu.device <= 0 return;
    texture_id := web_gl_id(res.texture);
    if texture_id <= 0 return;

    data_format, data_type := web_gl_sdl_data_format(res.format);
    if data_format == 0 {
        // 明确失败：以前这里会回落成 RGBA/UNSIGNED_BYTE，对 R8 来说等于按 4 倍
        // 长度读源缓冲 —— 静默越界，比拒绝糟糕得多。
        if !web_gpu.warned_texture_data {
            web_gpu.warned_texture_data = true;
            log_error(tprint("web/gl: 纹理上传格式 % 没有对应的 (format,type) 组合 —— 上传被拒绝", res.format));
        }
        return;
    }
    region := rect_int_get_intersection(dest_region, Rect_Int.{ 0, 0, res.width, res.height });
    if region.w <= 0 || region.h <= 0 return;

    web_gl_resolve_open_pass(d);
    ok := gl_set_texture_data(texture_id, region.x, region.y, region.w, region.h,
                              web_gl_off(data), length, data_format, data_type);
    if ok <= 0 {
        if !web_gpu.warned_texture_data {
            web_gpu.warned_texture_data = true;
            log_warning("web/gl: texSubImage2D 失败（纹理已满 / 格式不支持上传）—— 后续同类失败不再逐条报告");
        }
        web_gl_check_error("set_texture_data");
        return;
    }
    web_gl_texture_written(d, res);
    web_gpu.texture_uploads += 1;
}

// [W5] 读回。三处 W3 做不到的地方：
//
//  1. **多重采样附件**：像素在 renderbuffer 里，纹理里什么也没有。begin/end render
//     pass 那条路已经把它解析进解析纹理了（web_gl_target_resolve），所以这里走
//     web_gl_resolved_texture_id —— 读的就是解析后的那张。这就是任务里说的
//     「读回时注意 resolve 后再读」。
//  2. **格式**：R8 / RG8 / RGBA8 各自要匹配的 (format,type) 组合，RGBA 读 R8 是
//     INVALID_OPERATION（而且行宽对齐也要 PACK_ALIGNMENT=1）。
//  3. **深度**：WebGL2 的 readPixels 没有读深度的合法组合，所以明确拒绝并说明理由，
//     而不是返回一片零。
sdl_get_texture_data :: (d: *Graphics_Device, handle: Graphics_Resource_Handle, data: *void, length: s32, source_region: Rect_Int) {
    if length <= 0 return;
    res := sdl_find_resource(d, handle);
    if res == null || res.kind != .TEXTURE return;
    if web_gpu.device <= 0 return;

    // [W5/W6] 如果这张纹理正躺在**当前开着的那个多重采样 pass** 里，像素还在
    // renderbuffer 里，纹理里是上一帧的内容 —— 先解析再读（W5 的「resolve 后再读」）。
    web_gl_resolve_open_pass(d);

    if web_gl_sdl_format_is_depth(res.format) {
        if !web_gpu.warned_depth_readback {
            web_gpu.warned_depth_readback = true;
            web_gpu.readback_refusals += 1;
            log_warning(tprint("web/gl: 深度/深度模板纹理（%）在 WebGL2 上不能 readPixels 读回 —— 只能当渲染目标或采样源", res.format));
        }
        return;
    }

    // [W6] 读回的**显式**格式边界：这个后端只支持 8 位 UNORM 颜色读回
    // （RGBA8 是主路径；R8 / RG8 走 RED / RG 通道，WebGL2 允许匹配的 format/type）。
    // 浮点（R16F / RG16F / RGBA16F / RGBA32F）在 WebGL2 里要么要 EXT_color_buffer_float
    // 的 FLOAT 通道、要么根本不是合法组合，所以一律明确拒绝 —— 而**不是**用
    // RGBA/UNSIGNED_BYTE 去读一张 RGBA16F（那会返回 INVALID_OPERATION，而 W3 那一版
    // 会静默读到一片零，看起来像"渲染没生效"）。
    data_format, data_type := web_gl_sdl_data_format(res.format);
    is_8bit_unorm := res.format == .SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM ||
                     res.format == .SDL_GPU_TEXTUREFORMAT_R8_UNORM ||
                     res.format == .SDL_GPU_TEXTUREFORMAT_R8G8_UNORM;
    if data_format == 0 || !is_8bit_unorm {
        web_gpu.readback_refusals += 1;
        web_gpu.readback_unsupported_format += 1;
        if !web_gpu.warned_readback_refusal {
            web_gpu.warned_readback_refusal = true;
            log_error(tprint("web/gl: 纹理读回只支持 8 位 UNORM 颜色格式（RGBA8 / R8 / RG8）；% 被拒绝；浮点纹理要 format=FLOAT + EXT_color_buffer_float，深度/模板在 WebGL2 里根本读不回来",
                             res.format));
        }
        return;
    }
    // 一次性的能力说明：读回通道的能力边界写进日志，免得以后有人猜。
    if !web_gpu.warned_readback_format {
        web_gpu.warned_readback_format = true;
        log_info("web/gl: 纹理读回 —— 只支持 8 位 UNORM（RGBA8 主路径；R8/RG8 走 RED/RG + PACK_ALIGNMENT=1）");
    }

    texture_id := web_gl_resolved_texture_id(d, res);
    if texture_id <= 0 return;

    region := rect_int_get_intersection(source_region, Rect_Int.{ 0, 0, res.width, res.height });
    if region.w <= 0 || region.h <= 0 return;

    attachment := web_gl_sdl_read_attachment(res.format);
    ok := gl_get_texture_data(texture_id, region.x, region.y, region.w, region.h,
                              web_gl_off(data), length, data_format, data_type, attachment);
    if ok <= 0 {
        web_gl_check_error("get_texture_data");
        return;
    }
    web_gpu.readbacks += 1;
}

// [W5] texture_blit = 两张纹理各自的临时 FBO + 一条 glBlitFramebuffer。
//
// 两条路径都走同一条 GL 入口，区别只在矩形：
//   * 同尺寸：src 矩形和 dst 矩形一样大 → 逐 texel 拷贝；
//   * 缩放：矩形尺寸不同 + filter → 由 blitFramebuffer 的重采样做（NEAREST 是
//     抽样，LINEAR 是插值）。
//
// **限制（明确记录，不是静默）**：GL ES 3.0 的 blitFramebuffer 要求源和目标的
// **格式完全一致**（ES 3.1 才放宽成"兼容"）。所以 RGBA8 → RGBA8、R8 → R8 都行，
// RGBA8 → R8 不行 —— 这种调用会被拒绝并打一条 log_warning，而不是画出一半。
// 要跨格式转换，正确做法是拿一张全屏 quad 走着色器（W6 的 blit pass）。
sdl_blit_texture :: (d: *Graphics_Device, source_texture: Graphics_Resource_Handle, source_region: Rect_Int,
                     destination_texture: Graphics_Resource_Handle, destination_region: Rect_Int,
                     filter: Texture_Filter) {
    if d == null return;
    if web_gpu.device <= 0 return;

    src := sdl_find_resource(d, source_texture);
    dst := sdl_find_resource(d, destination_texture);
    if src == null || dst == null || src.kind != .TEXTURE || dst.kind != .TEXTURE {
        log_warning("web/gl: texture_blit 的两端都必须是纹理");
        web_gpu.blit_failures += 1;
        return;
    }

    if src.format != dst.format {
        web_gpu.blit_failures += 1;
        if !web_gpu.warned_blit_format {
            web_gpu.warned_blit_format = true;
            log_warning(tprint("web/gl: texture_blit 两端格式不同（% → %）—— ES 3.0 的 blitFramebuffer 要求相同格式，这次拷贝被忽略（跨格式要走着色器，见 W6）",
                               src.format, dst.format));
        }
        return;
    }

    src_region := rect_int_get_intersection(source_region, Rect_Int.{ 0, 0, src.width, src.height });
    dst_region := rect_int_get_intersection(destination_region, Rect_Int.{ 0, 0, dst.width, dst.height });
    if src_region.w <= 0 || src_region.h <= 0 || dst_region.w <= 0 || dst_region.h <= 0 return;

    // 源纹理可能正躺在开着的多重采样 pass 里（renderbuffer 里才是最新像素）。
    web_gl_resolve_open_pass(d);

    src_fbo := web_gl_texture_fbo(d, src);
    dst_fbo := web_gl_texture_fbo(d, dst);
    if src_fbo <= 0 || dst_fbo <= 0 {
        web_gpu.blit_failures += 1;
        return;
    }

    // Public textures store logical row zero at GL row zero (V=0).
    sx0 := src_region.x;
    sx1 := src_region.x + src_region.w;
    sy0 := src_region.y;
    sy1 := src_region.y + src_region.h;
    dx0 := dst_region.x;
    dx1 := dst_region.x + dst_region.w;
    dy0 := dst_region.y;
    dy1 := dst_region.y + dst_region.h;

    gl_filter := cast(s32) (ifx filter == .NEAREST then GL_NEAREST else GL_LINEAR);
    ok := gl_blit_framebuffer(src_fbo, dst_fbo, sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1,
                              WEB_BLIT_COLOR, gl_filter);
    if ok <= 0 {
        web_gpu.blit_failures += 1;
        web_gl_check_error("blit_texture");
        return;
    }
    web_gl_texture_written(d, dst);
    web_gpu.blits += 1;
}

// Target 只是簿记：真正的 FBO 在第一次 begin_render_pass 时拼（那时候附件纹理
// 才都建好，见 web_gl.jai :: web_gl_target_build）。
sdl_create_target :: (d: *Graphics_Device, width: s32, height: s32) -> Graphics_Resource_Handle {
    handle := sdl_register_resource(d, .TARGET);
    res := sdl_require_resource(d, handle);
    res.width = width;
    res.height = height;
    res.format = .SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    res.sample_count = .SDL_GPU_SAMPLECOUNT_1;
    return handle;
}

//
// buffers
//

sdl_create_buffer :: (d: *Graphics_Device, name: string, type: Buffer_Kind, format: Index_Format) -> Graphics_Resource_Handle {
    handle := sdl_register_resource(d, .BUFFER);
    res := sdl_require_resource(d, handle);
    res.name = name;
    res.index_format = format;
    res.capacity = 0;
    res.dirty = true;

    // Same usage bits the desktop backend sets; they are also what tells the web
    // side which GL target to bind (VERTEX → ARRAY_BUFFER, INDEX →
    // ELEMENT_ARRAY_BUFFER). Storage buffers have no WebGL2 equivalent and fall
    // back to ARRAY_BUFFER so an accidental upload does not corrupt an index bind.
    if type == {
        case .VERTEX;          res.usage = .SDL_GPU_BUFFERUSAGE_VERTEX;
        case .INDEX;           res.usage = .SDL_GPU_BUFFERUSAGE_INDEX;
        case .STORAGE;         res.usage = .SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;
        case .COMPUTE_STORAGE;
            res.usage = .SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                        .SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE |
                        .SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;
    }

    return handle;
}

// Buffer_Kind is not stored in GPU_Resource, so the GL target comes from the
// usage bits sdl_create_buffer just set — the same information the desktop
// backend hands to SDL_CreateGPUBuffer.
web_gl_buffer_target :: (usage: SDL_GPUBufferUsageFlags) -> s32 {
    if (usage & .SDL_GPU_BUFFERUSAGE_INDEX) != 0 return GL_ELEMENT_ARRAY_BUFFER;
    return GL_ARRAY_BUFFER;
}

sdl_upload_buffer_data :: (d: *Graphics_Device, handle: Graphics_Resource_Handle, data: *void, data_size: s32, data_dest_offset: s32) {
    res := sdl_find_resource(d, handle);
    if res == null || res.kind != .BUFFER return;
    res.dirty = true;

    if web_gpu.device <= 0 return;

    // Same growth policy as the desktop backend: never a 0-length buffer, and
    // doubling from 8 bytes so that a Batch vertex buffer streamed every frame
    // does not reallocate. (The desktop version wipes contents on resize and
    // notes it as a Foster TODO; WebGL2's bufferData does the same, and the
    // doubling keeps us out of that path in practice.)
    required := data_size + data_dest_offset;
    capacity := res.capacity;
    if capacity == 0 {
        capacity = cast(s32) max(8, required);
    } else if required > capacity {
        while capacity < required capacity *= 2;
    }

    buffer_id := web_gl_id(res.buffer);
    if buffer_id <= 0 {
        if capacity <= 0 return;
        buffer_id = gl_create_buffer(web_gl_buffer_target(res.usage));
        if buffer_id <= 0 {
            web_gl_check_error("create_buffer");
            return;
        }
        res.buffer = web_gl_ptr(buffer_id);
    }

    ok := gl_set_buffer_data(buffer_id, web_gl_off(data), data_size, data_dest_offset, capacity,
                             web_gl_buffer_target(res.usage));
    if ok <= 0 {
        web_gl_check_error("set_buffer_data");
        return;
    }
    res.capacity = capacity;
    if data_size > 0 web_gpu.buffer_uploads += 1;
}

//
// shaders
//

// WebGL2 only accepts GLSL ES 3.00 *text*; the desktop blob is SPIR-V / DXIL /
// MSL. Since W4 the text arrives in the `code` slice, exactly like the desktop
// backends get their binary in it:
//
//     graphics/default_resource_data.jai  (wasm branch)
//       → defaults_shader_bytes("Batcher", .VERTEX, driver) -> [] u8 GLSL text
//       → graphics/defaults.jai :: defaults_load_shader
//         → shader_create(..., code = the text)
//           → sdl_create_shader            ← this proc compiles `code`
//
// That removes W3's hardcoded (name → source) table from the *inputs* of the
// backend: any GLSL ES 3.00 text works, which is what makes custom shaders and
// the hot-replace path (shader_pair_replace_web.jai) possible.
//
// A caller that still passes a non-GLSL blob (e.g. desktop-shaped SPIR-V bytes)
// falls back to the name-keyed table in web_shader_source.jai for the three
// default programs, so a cross-target game does not have to special-case itself
// per target while it migrates. Anything else is rejected loudly.
sdl_create_shader :: (d: *Graphics_Device, shader: *Shader, code: [] u8, entry_point: string) -> Graphics_Resource_Handle {
    handle := sdl_register_resource(d, .SHADER);
    res := sdl_require_resource(d, handle);
    res.shader = null;

    if web_gpu.device <= 0 return handle;
    if shader == null return handle;

    gl_stage, web_stage, stage_found := web_gl_stage_of(shader.Stage);
    if !stage_found {
        // .COMPUTE: WebGL2 has no compute stage at all.
        if !web_gpu.warned_no_shader {
            web_gpu.warned_no_shader = true;
            log_error(tprint("web/gl: 着色器 '%' 是计算阶段 —— WebGL2 没有 compute stage，这个 shader 不可用", shader.Name));
        }
        return handle;
    }

    src: string;
    origin: string;
    if web_shader_code_is_glsl(code) {
        src = web_str_of(code.data, cast(s32) code.count);
        origin = "code";
    } else {
        variant, variant_found := web_shader_variant_of_name(shader.Name);
        if !variant_found {
            if !web_gpu.warned_no_shader {
                web_gpu.warned_no_shader = true;
                log_error(tprint("web/gl: 着色器 '%'（stage %）既不是 GLSL ES 3.00 文本，也不是三个默认 program 之一 —— 无法在 WebGL2 上创建。绘制会被跳过。", shader.Name, shader.Stage));
            }
            return handle;
        }
        src = web_shader_source(variant, web_stage);
        origin = tprint("内置 %/%", variant, web_stage);
    }

    if src.count <= 0 {
        log_error(tprint("web/gl: 着色器 '%' 的 GLSL 源为空（来源：%）", shader.Name, origin));
        return handle;
    }

    shader_id := gl_create_shader(gl_stage, web_gl_str_off(src), web_gl_str_len(src),
                                  web_gl_str_off(shader.Name), web_gl_str_len(shader.Name));
    if shader_id <= 0 {
        web_gl_check_error(tprint("compileShader %", shader.Name));
        return handle;
    }

    res.shader = web_gl_ptr(shader_id);
    web_gpu.shaders_compiled += 1;
    log_info(tprint("web/gl: shader '%'（% stage）编译通过 —— % 字节，来源 %",
                    shader.Name, shader.Stage, cast(s32) src.count, origin));
    return handle;
}

sdl_destroy_resource :: (d: *Graphics_Device, resource: Graphics_Resource_Handle) {
    if d == null || resource == 0 return;
    res := sdl_find_resource(d, resource);
    if res == null return;

    if res.kind == {
        case .TEXTURE;
            // 先记住自己的 GL 纹理 id 再递归销毁解析纹理：递归之后 res 可能已经
            // 被释放（解析纹理反过来又被 target 引用时），不能再读 res.texture。
            texture_id := web_gl_id(res.texture);
            released_handle := res.handle;
            if res.multi_sample_resolve != 0 sdl_destroy_resource(d, res.multi_sample_resolve);
            if texture_id > 0 {
                gl_destroy_texture(texture_id);
                // 这张纹理的临时 FBO、以及**引用它的** target FBO 作废（W5 全作废 → W6 精确作废）。
                web_gl_texture_released(d, released_handle, texture_id);
            }
            free(res);
        case .TARGET;
            // FBO / renderbuffer 先回收：它们引用着附件的纹理，顺序反了就等于在
            // 一份指向已删除对象的 FBO 上继续画。
            web_gl_target_release(res.handle);
            for att: res.attachments sdl_destroy_resource(d, att);
            array_free(res.attachments);
            free(res);
        case .BUFFER;
            gl_destroy_buffer(web_gl_id(res.buffer));
            free(res);
        case .SHADER;
            sdl_release_graphics_pipelines_associated_with(d, res);
            // ... and the programs linked from it. The program cache is keyed on
            // shader handles, so an entry that still names this handle can never be
            // valid again — dropping it here is what keeps hot-replacement from
            // reusing a dead program. (Desktop gets the same guarantee because a
            // pipeline object holds its own shaders.)
            web_gl_purge_programs_for(res.handle);
            gl_destroy_shader(web_gl_id(res.shader));
            array_free(res.pipelines);
            free(res);
        case .COMPUTE;
            // No compute pipelines exist on this target (WebGL2 has no
            // glDispatchCompute); the handle is pure bookkeeping.
            free(res);
    }
    table_remove(*d.resources, resource);
}

// WebGL2 has no pipeline objects to release per shader: a pipeline here is
// program + VAO, and deleting the shader/program is the whole teardown. The
// cached ids still have to leave d.pipelines, or the next draw would look up a
// dead program — that is what this proc guarantees, exactly like desktop.
sdl_release_graphics_pipelines_associated_with :: (d: *Graphics_Device, shader_res: *GPU_Resource) {
    if d == null || shader_res == null return;
    for it: shader_res.pipelines {
        p := table_find_pointer(*web_gpu.pipelines, it);
        if p != null {
            gl_destroy_pipeline(<<p);
            table_remove(*web_gpu.pipelines, it);
        }
    }
    array_reset(*shader_res.pipelines);
}

//
// render pass
//

// The desktop version takes Clear_Info from graphics_device_sdl_draw.jai, a file
// the web build never loads — so the struct is declared here with the same field
// names and defaults. sdl_clear fills it the same way.
Clear_Info :: struct {
    Colors: [] Color;          // empty (count 0) = no color clear
    Depth: float = 0;
    HasDepth: bool = false;
    Stencil: s32 = 0;
    HasStencil: bool = false;
}

web_drawable_target_equals :: (a: Drawable_Target, b: Drawable_Target) -> bool {
    if a.Kind != b.Kind return false;
    if a.Kind == .WINDOW return a.window == b.window;
    if a.Kind == .TARGET return a.target == b.target;
    return true;
}

// A "render pass" in WebGL2 is just "the framebuffer that is bound, plus a
// clear". Everything the desktop backend records in d.render_pass_* is recorded
// here too, so sdl_perform_draw can keep the desktop's "only rebind what
// changed" logic verbatim.
sdl_begin_render_pass :: (d: *Graphics_Device, drawable_target: Drawable_Target, clear: Clear_Info) -> bool {
    if d == null return false;

    // only begin if we're not already in a matching render pass without clears
    if d.render_pass != null &&
       web_drawable_target_equals(d.render_pass_target, drawable_target) &&
       clear.Colors.count == 0 && !clear.HasDepth && !clear.HasStencil {
        return true;
    }

    sdl_end_render_pass(d);

    // make sure we have something to draw to
    fbo: s32 = 0;
    size := Point2_Zero;
    target_is_target := false;
    target_handle: Graphics_Resource_Handle = 0;

    window_pass := false;
    if drawable_target.Kind == .WINDOW {
        if drawable_target.window == null || drawable_target.window.handle == null return false;
        size = window_size_in_pixels(drawable_target.window);
        fbo = 0;                       // the canvas default framebuffer
        // [W6] 窗口级 MSAA：有窗口大小的 MS FBO 就画它，present/end pass 时解析到 0 号。
        if web_gpu.window_msaa_wanted && web_gpu.window_ms.ready &&
           web_gpu.window_ms.width == size.x && web_gpu.window_ms.height == size.y {
            fbo = web_gpu.window_ms.fbo;
            window_pass = true;
        } else if web_gpu.window_msaa_wanted && web_gl_window_msaa_ensure(size.x, size.y) {
            fbo = web_gpu.window_ms.fbo;
            window_pass = true;
        }
    } else if drawable_target.Kind == .TARGET {
        // [W5] render-to-target：把 target 的附件列表拼成 FBO（懒建 + 缓存），
        // 多重采样时绑的是 ms_fbo（绘制期间像素在 renderbuffer 里，end pass 解析）。
        if drawable_target.target == null return false;
        fbo_id, target_size, found := web_gl_target_pass_fbo(d, drawable_target.target.handle);
        if !found {
            // 建不出来（FBO 不完整 / 没有颜色附件 / 格式不支持）：不画。
            // 具体原因已经在 web_gl_target_build 里逐条 log_error 过了。
            if !web_gpu.warned_target_draw {
                web_gpu.warned_target_draw = true;
                log_warning("web/gl: 这个 Target 的 FBO 建不起来 —— 画到它的命令会被跳过（原因见上一条 error）");
            }
            return false;
        }
        fbo = fbo_id;
        size = target_size;
        target_is_target = true;
        target_handle = drawable_target.target.handle;
    } else {
        return false;
    }

    if size.x <= 0 || size.y <= 0 return false;
    if web_gpu.device <= 0 return false;

    if gl_begin_render_pass(fbo, size.x, size.y) <= 0 {
        web_gl_check_error("begin_render_pass");
        return false;
    }

    d.render_pass = cast(*SDL_GPURenderPass) cast(*void) 1;   // non-null == "in a pass"
    d.render_pass_target = drawable_target;
    d.render_pass_target_size = size;
    d.render_pass_pipeline = null;
    d.render_pass_vertex_buffer_count = 0;
    d.render_pass_index_buffer = 0;
    // The VAO cache-key halves have to be forgotten together with the counts they
    // qualify (see web_gl.jai :: Web_GPU_State.vb_owner_pipeline).
    web_gpu.vb_owner_pipeline = 0;
    web_gpu.ib_owner_pipeline = 0;
    d.render_pass_viewport = .{};
    d.has_render_pass_viewport = false;
    d.render_pass_scissor = .{};
    d.has_render_pass_scissor = false;
    web_gpu.pass_fbo = fbo;
    web_gpu.pass_target = target_handle;
    web_gpu.pass_window = window_pass;
    web_gpu.passes += 1;

    // The clear is part of beginning the pass — the desktop backend expresses it
    // as the attachment's load_op, WebGL2 as an explicit glClear here. Doing it at
    // begin (not on the first draw) keeps "clear, then draw" and "only clear"
    // identical.
    if clear.Colors.count > 0 || clear.HasDepth || clear.HasStencil {
        color := ifx clear.Colors.count > 0 then clear.Colors[0] else Color_Transparent;
        ok := gl_clear(cast(s32) color.r, cast(s32) color.g, cast(s32) color.b, cast(s32) color.a,
                       web_b32(clear.Colors.count > 0),
                       cast(float64) clear.Depth,
                       clear.Stencil,
                       web_b32(clear.HasDepth),
                       web_b32(clear.HasStencil));
        if ok <= 0 {
            web_gl_check_error("clear");
        } else {
            web_gpu.clears += 1;
        }
    }

    return true;
}

sdl_end_render_pass :: (d: *Graphics_Device) {
    if d == null return;

    // [W5] MSAA resolve：必须在**关 pass 之前**做（像素还在 renderbuffer 里，
    // 而 gl_end_render_pass 会把 framebuffer 绑回 canvas）。桌面的等价物是
    // color_info.store_op = SDL_GPU_STOREOP_RESOLVE + resolve_texture，由驱动在
    // end pass 时执行；WebGL2 没有这个概念，所以这里显式 blitFramebuffer。
    if d.render_pass != null && web_gpu.device > 0 && web_gpu.pass_target != 0 {
        web_gl_target_resolve(d, web_gpu.pass_target);
    }
    // [W6] 窗口级 MSAA 的解析：ms_fbo → 0 号 FBO。同样必须在关 pass 之前做
    // （gl_end_render_pass 会把 framebuffer 绑回 canvas，那时再 blit 就是从
    // 已经解绑的 READ 源拿像素 —— 虽然 blit 自己会重绑，但"最后一次 resolve
    // 发生在 pass 还开着的时候"和桌面的 store_op = RESOLVE 是同一时序）。
    if d.render_pass != null && web_gpu.device > 0 && web_gpu.pass_window && web_gpu.window_ms.ready {
        web_gl_window_msaa_resolve();
    }

    if d.render_pass != null && web_gpu.device > 0 {
        gl_end_render_pass();
    }
    web_gpu.pass_target = 0;
    web_gpu.pass_window = false;
    d.render_pass = null;
    d.render_pass_target = .{};
    d.render_pass_pipeline = null;
    d.render_pass_viewport = .{};
    d.has_render_pass_viewport = false;
    d.render_pass_scissor = .{};
    d.has_render_pass_scissor = false;
    d.render_pass_index_buffer = 0;
    d.render_pass_vertex_buffer_count = 0;
    web_gpu.pass_fbo = 0;
    web_gpu.vb_owner_pipeline = 0;
    web_gpu.ib_owner_pipeline = 0;
}

// Desktop opens an SDL copy pass on the upload command buffer. WebGL2 uploads are
// immediate, so these two exist only so sdl_present / sdl_shutdown / the upload
// paths keep the same shape.
sdl_begin_copy_pass :: (d: *Graphics_Device) { }
sdl_end_copy_pass :: (d: *Graphics_Device) { }

// Desktop submits both command buffers here (and optionally waits on fences).
// There is nothing queued: every gl_* call already went to the driver.
sdl_flush_commands :: (d: *Graphics_Device, stall: bool) {
    if d == null return;
    if web_gpu.device <= 0 return;
    gl_present();
}

sdl_reset_command_buffer_state :: (d: *Graphics_Device) {
    if d == null return;
    // Nothing to acquire: no command buffers exist on this target. The name is
    // kept because graphics_device_sdl.jai calls it from device creation and from
    // sdl_flush_commands.
    sdl_end_render_pass(d);
}

//
// graphics pipeline = program + VAO, cached by the same big hash desktop uses
//

// Uniform / attribute plumbing lives in web_gl.jai; this is the assembly step.
//
// Program cache key: the two fw shader handles. The desktop pipeline hash covers
// the same two plus every state that WebGL2 keeps global (blend/cull/depth/…),
// which is why our pipeline hash is only (shaders + vertex layout + target
// formats + instance rates): the rest is applied per draw.

// Link a program for the command's shader pair. NOT cached (the cache wrapper is
// web_gl_get_program below; the probe path wants a throw-away program).
//
// The staged uniform-block binding points are assigned by the JS side at link
// time (host.js :: bindUniformBlocks), because only the linker knows how many
// blocks a stage really has and in what order: GL ES 3.0 numbers the vertex
// shader's blocks first, then the fragment shader's. The Jai side never sees a
// block name — see web_gl.jai :: web_gl_uniform_binding_point.
web_gl_link_program :: (d: *Graphics_Device, vertex_shader, fragment_shader: *Shader) -> s32 {
    if vertex_shader == null || fragment_shader == null return 0;

    vs_res := sdl_find_resource(d, vertex_shader.handle);
    fs_res := sdl_find_resource(d, fragment_shader.handle);
    if vs_res == null || fs_res == null return 0;

    vs_id := web_gl_id(vs_res.shader);
    fs_id := web_gl_id(fs_res.shader);
    if vs_id <= 0 || fs_id <= 0 return 0;

    name := vertex_shader.Name;
    program_id := gl_create_program(vs_id, fs_id, web_gl_str_off(name), web_gl_str_len(name));
    if program_id <= 0 {
        web_gl_check_error(tprint("linkProgram %", name));
        return 0;
    }

    web_gpu.programs_linked += 1;

    // One line per program: which GLSL actually got linked. Cheap, and it is the
    // only place the browser log says so.
    log_info(tprint("web/gl: program '%' 链上（vs=% fs=%）", name, vs_id, fs_id));
    return program_id;
}

web_gl_get_program :: (d: *Graphics_Device, command: Draw_Command) -> s32 {
    if command.VertexShader == null || command.FragmentShader == null return 0;

    key := Web_Program_Key.{ command.VertexShader.handle, command.FragmentShader.handle };
    cached := table_find_pointer(*web_gpu.programs, key);
    if cached != null return cached.id;

    program_id := web_gl_link_program(d, command.VertexShader, command.FragmentShader);
    if program_id <= 0 return 0;

    entry := Web_Program_Entry.{
        id = program_id,
        vs = command.VertexShader.handle,
        fs = command.FragmentShader.handle,
    };
    table_set(*web_gpu.programs, key, entry);
    return program_id;
}

// Flatten every vertex buffer of the command into the 8 × s32 per attribute table
// the JS side turns into vertexAttribPointer calls:
//   (slot, location, size, GL type, normalized, stride, offset, divisor)
// Shared by the draw path and the hot-replace probe path on purpose: a probe that
// accepted a layout the draw path then rejects would be worthless.
web_gl_build_attribute_table :: (command: Draw_Command) -> s32 {
    attribute_count: s32 = 0;
    for slot: 0..command.VertexBufferCount-1 {
        it := command.VertexBuffers[slot].Buffer;
        if it == null continue;
        divisor := web_b32(command.VertexBuffers[slot].InstanceInputRate);
        offset: s32 = 0;

        for j: 0..it.Format.ElementCount-1 {
            el := it.Format.Elements[j];
            gl_type, components := web_gl_vertex_type(el.Type);
            if gl_type == 0 continue;

            if attribute_count >= WEB_MAX_ATTRIBUTES {
                log_warning("web/gl: 顶点属性超过 64 个（和桌面后端同一个上限），多余的被丢弃");
                break;
            }

            base := attribute_count * 8;
            web_gpu.attr_scratch[base + 0] = slot;
            web_gpu.attr_scratch[base + 1] = el.Index;
            web_gpu.attr_scratch[base + 2] = components;
            web_gpu.attr_scratch[base + 3] = gl_type;
            web_gpu.attr_scratch[base + 4] = web_b32(el.Normalized);
            web_gpu.attr_scratch[base + 5] = it.Format.Stride;
            web_gpu.attr_scratch[base + 6] = offset;
            web_gpu.attr_scratch[base + 7] = divisor;

            offset += vertex_type_size_in_bytes(el.Type);
            attribute_count += 1;
        }
    }
    return attribute_count;
}

// The pipeline hash, verbatim from internal/graphics_device_sdl_draw.jai ::
// sdl_get_graphics_pipeline, minus the state that WebGL2 applies per draw
// (blend/cull/depth/stencil) and minus the target formats, which a VAO does not
// bake in. Keeping the function shape identical makes the two backends diffable.
web_gl_pipeline_hash :: (command: Draw_Command) -> u64 {
    hash: u64 = 0;
    hash = web_gl_hash_combine(hash, cast(u64) command.VertexShader.handle);
    hash = web_gl_hash_combine(hash, cast(u64) command.FragmentShader.handle);

    for i: 0..command.VertexBufferCount-1 {
        vb := command.VertexBuffers[i].Buffer;
        if vb == null continue;
        hash = web_gl_hash_combine(hash, cast(u64) vb.Format.Stride);
        hash = web_gl_hash_combine(hash, cast(u64) vb.Format.ElementCount);
        for j: 0..vb.Format.ElementCount-1 {
            el := vb.Format.Elements[j];
            hash = web_gl_hash_combine(hash, cast(u64) el.Index);
            hash = web_gl_hash_combine(hash, cast(u64) el.Type);
            hash = web_gl_hash_combine(hash, cast(u64) el.Normalized);
        }
        hash = web_gl_hash_combine(hash, cast(u64) command.VertexBuffers[i].InstanceInputRate);
    }
    return hash;
}

web_gl_get_pipeline :: (d: *Graphics_Device, command: Draw_Command) -> s32 {
    hash := web_gl_pipeline_hash(command);

    cached := table_find_pointer(*web_gpu.pipelines, hash);
    if cached != null return <<cached;

    program_id := web_gl_get_program(d, command);
    if program_id <= 0 return 0;

    attribute_count := web_gl_build_attribute_table(command);
    pipeline_id := gl_create_pipeline(program_id, web_gl_off(*web_gpu.attr_scratch[0]), attribute_count);
    if pipeline_id <= 0 {
        web_gl_check_error("create_pipeline");
        return 0;
    }

    table_set(*web_gpu.pipelines, hash, pipeline_id);
    web_gpu.pipelines_created += 1;

    // Record the hash on both shaders so sdl_destroy_resource can drop the cached
    // pipelines when a shader goes away — the same bookkeeping the desktop backend
    // keeps in ShaderResource::pipelines, and what makes hot-replacement unable to
    // reuse a released pipeline.
    shaders: [2] *Shader = .[command.VertexShader, command.FragmentShader];
    for shader: shaders {
        if shader == null continue;
        res := sdl_find_resource(d, shader.handle);
        if res == null continue;
        if !web_gl_contains_hash(res.pipelines, hash) array_add(*res.pipelines, hash);
    }
    return pipeline_id;
}

web_gl_contains_hash :: (hashes: [..] u64, hash: u64) -> bool {
    for h: hashes if h == hash return true;
    return false;
}

//
// hot-replace probe pipeline (ShaderPairTryReplace)
//

// Builds, but does not cache, a program + VAO for the command's shader pair.
// Returns the pipeline id, or 0 when the candidate pair does not compile/link —
// the failure is already in the log (host.js reports LINK_STATUS + info log).
// The caller must release it with web_gl_release_probe_pipeline.
web_gl_probe_pipeline :: (d: *Graphics_Device, command: Draw_Command) -> s32 {
    if d == null || web_gpu.device <= 0 return 0;

    program_id := web_gl_link_program(d, command.VertexShader, command.FragmentShader);
    if program_id <= 0 return 0;

    attribute_count := web_gl_build_attribute_table(command);
    pipeline_id := gl_create_pipeline(program_id, web_gl_off(*web_gpu.attr_scratch[0]), attribute_count);
    if pipeline_id <= 0 {
        web_gl_check_error("create_pipeline (probe)");
        gl_destroy_program(program_id);
        return 0;
    }
    return pipeline_id;
}

// Probe pipelines own their program (the draw path's borrow a cached one), so the
// release has to drop both.
web_gl_release_probe_pipeline :: (pipeline: s32) {
    if pipeline <= 0 return;
    gl_release_pipeline_with_program(pipeline);
}

//
// per-draw state
//

// Everything the desktop backend bakes into SDL_GPUGraphicsPipeline and WebGL2
// keeps as global state. Called on every draw: the GL calls are cheap and
// deduplicating them here would need a shadow of every state field, i.e. the
// object we just got rid of. (W6 can add the shadow if a profile asks for it.)
web_gl_apply_state :: (d: *Graphics_Device, command: Draw_Command) {
    blend := command.BlendMode;

    // enable_blend is always true on desktop (sdl_get_blend_state), so it is
    // always true here — otherwise the two backends would disagree on every
    // translucent pixel.
    gl_set_blend(1,
                 web_gl_blend_factor(blend.ColorSource), web_gl_blend_factor(blend.ColorDestination),
                 web_gl_blend_op(blend.ColorOperation),
                 web_gl_blend_factor(blend.AlphaSource), web_gl_blend_factor(blend.AlphaDestination),
                 web_gl_blend_op(blend.AlphaOperation),
                 web_gl_blend_mask_bits(blend.Mask));

    gl_set_cull(web_gl_cull(command.CullMode));

    gl_set_depth(web_b32(command.DepthTestEnabled),
                 web_b32(command.DepthWriteEnabled),
                 web_gl_compare(command.DepthCompare));

    gl_set_stencil(web_b32(command.StencilTestEnabled),
                   cast(s32) command.StencilReferenceValue,
                   cast(s32) command.StencilCompareMask,
                   cast(s32) command.StencilWriteMask,
                   web_gl_compare(command.BackStencilState.CompareOp),
                   web_gl_stencil_op(command.BackStencilState.PassOp),
                   web_gl_stencil_op(command.BackStencilState.FailOp),
                   web_gl_stencil_op(command.BackStencilState.DepthFailOp),
                   web_gl_compare(command.FrontStencilState.CompareOp),
                   web_gl_stencil_op(command.FrontStencilState.PassOp),
                   web_gl_stencil_op(command.FrontStencilState.FailOp),
                   web_gl_stencil_op(command.FrontStencilState.DepthFailOp));

    // glPolygonMode does not exist in WebGL2 — line fill is a desktop-only nicety.
    // Silence is not an option: a wireframe debug view that silently renders
    // filled is a debugging trap.
    if command.FillMode == .LINE && !web_gpu.warned_no_uniform {
        web_gpu.warned_no_uniform = true;
        log_warning("web/gl: FillMode.LINE（线框）在 WebGL2 里不存在（glPolygonMode 不是 ES 3.0 的一部分）—— 按 FILL 绘制");
    }
}

//
// draw / dispatch / clear
//

sdl_perform_draw :: (d: *Graphics_Device, command: Draw_Command) {
    if d == null return;

    if web_gpu.device <= 0 {
        web_gpu.draw_skips += 1;
        return;
    }

    // try to start a render pass
    if !sdl_begin_render_pass(d, command.Target, Clear_Info.{}) return;

    // set viewport (WebGL2 origin is bottom-left; the JS shim flips Y, so this
    // stays in jfoster's top-left coordinates all the way down)
    next_viewport := ifx command.HasViewport then command.Viewport
        else Rect_Int.{ 0, 0, d.render_pass_target_size.x, d.render_pass_target_size.y };
    if !d.has_render_pass_viewport || d.render_pass_viewport != next_viewport {
        d.render_pass_viewport = next_viewport;
        d.has_render_pass_viewport = true;
        gl_set_viewport(next_viewport.x, next_viewport.y, next_viewport.w, next_viewport.h);
    }

    // set scissor: desktop defaults the scissor to the viewport on every draw
    next_scissor := ifx command.HasScissor then command.Scissor else next_viewport;
    if !d.has_render_pass_scissor || d.render_pass_scissor != next_scissor {
        d.render_pass_scissor = next_scissor;
        d.has_render_pass_scissor = true;
        gl_set_scissor(next_scissor.x, next_scissor.y, next_scissor.w, next_scissor.h, 1);
    }

    // pipeline (program + VAO); the state half is applied below
    pipeline_id := web_gl_get_pipeline(d, command);
    if pipeline_id <= 0 {
        web_gpu.draw_skips += 1;
        return;
    }
    if d.render_pass_pipeline != cast(*SDL_GPUGraphicsPipeline) cast(*void) pipeline_id {
        d.render_pass_pipeline = cast(*SDL_GPUGraphicsPipeline) cast(*void) pipeline_id;
        gl_bind_pipeline(pipeline_id);
    }

    program_id := web_gl_get_program(d, command);
    if program_id <= 0 {
        web_gpu.draw_skips += 1;
        return;
    }

    web_gl_apply_state(d, command);

    // bind index buffer
    //
    // Same (pipeline, buffer) key as the vertex buffers above: the
    // ELEMENT_ARRAY_BUFFER binding is VAO state, so a new pipeline (new VAO) starts
    // with no index buffer even when the handle did not change.
    index_res := ifx command.IndexBuffer != null then sdl_find_resource(d, command.IndexBuffer.handle) else null;
    if index_res != null && (web_gpu.ib_owner_pipeline != pipeline_id ||
                             d.render_pass_index_buffer != index_res.handle || index_res.dirty) {
        d.render_pass_index_buffer = index_res.handle;
        web_gpu.ib_owner_pipeline = pipeline_id;
        index_res.dirty = false;
        gl_bind_index_buffer(web_gl_id(index_res.buffer));
    }

    // check if we need to rebind vertex buffers
    //
    // [W4] The cache key has to be **(pipeline, slot)**, not just slot.
    //
    // Desktop binds a vertex buffer onto the *command buffer*: "slot 0 now points
    // at buffer B" is global state, so remembering the last bound handle per slot
    // is enough. In WebGL2 the pointer (buffer + offset + stride) is **VAO state**,
    // and the VAO belongs to the pipeline. Two draws can therefore reference the
    // same vertex buffer through two different pipelines (two VAOs), and the
    // second one still needs its own vertexAttribPointer or its draw raises
    // INVALID_OPERATION ("no buffer is bound to enabled attribute").
    //
    // W3 never hit this: one program, one pipeline, one mesh per frame. W4 draws
    // the same Batcher mesh through the Batcher program *and* the Msdf program
    // (the text batch of the same Batcher), which is exactly the case that breaks.
    // `web_gpu.vb_owner_pipeline` is the missing half of the key — it is reset
    // whenever d.render_pass_vertex_buffer_count is (i.e. on begin_render_pass).
    rebind_vertex_buffers := web_gpu.vb_owner_pipeline != pipeline_id ||
                             d.render_pass_vertex_buffer_count != command.VertexBufferCount;
    if !rebind_vertex_buffers {
        for i: 0..command.VertexBufferCount-1 {
            vb := sdl_find_resource(d, command.VertexBuffers[i].Buffer.handle);
            if vb == null || d.render_pass_vertex_buffers[i] != vb.handle || vb.dirty {
                rebind_vertex_buffers = true;
                break;
            }
        }
    }

    // bind vertex buffers. Every bind re-issues vertexAttribPointer for the
    // attributes of that slot: in WebGL2 the pointer (buffer + offset) is VAO
    // state, so "the format matched, keep the binding" does not exist — the VAO
    // has to be told about *this* buffer. That is the one place where the desktop
    // "bind-at-slot" model and the GL model genuinely differ.
    if rebind_vertex_buffers {
        d.render_pass_vertex_buffer_count = 0;

        for i: 0..command.VertexBufferCount-1 {
            res := sdl_find_resource(d, command.VertexBuffers[i].Buffer.handle);
            if res == null continue;
            res.dirty = false;

            gl_bind_vertex_buffer(pipeline_id, i, web_gl_id(res.buffer));

            d.render_pass_vertex_buffers[i] = res.handle;
            d.render_pass_vertex_buffer_count += 1;
            web_gpu.vb_owner_pipeline = pipeline_id;
        }
    }

    // bind vertex samplers
    if command.VertexShader.SamplerCount > 0 {
        for i: 0..command.VertexShader.SamplerCount-1 {
            web_gl_bind_sampler_slot(d, program_id, command.VertexShader, .VERTEX, i,
                                     ifx i < command.VertexSamplerCount then command.VertexSamplers[i] else Bound_Sampler.{},
                                     d.empty_default_texture);
        }
    }

    // bind fragment samplers
    if command.FragmentShader.SamplerCount > 0 {
        for i: 0..command.FragmentShader.SamplerCount-1 {
            web_gl_bind_sampler_slot(d, program_id, command.FragmentShader, .FRAGMENT, i,
                                     ifx i < command.FragmentSamplerCount then command.FragmentSamplers[i] else Bound_Sampler.{},
                                     d.empty_default_texture);
        }
    }

    // push vertex uniforms (SDL: PushGPUVertexUniformData(slot i))
    web_gl_push_uniforms(d, program_id, command.VertexShader, .VERTEX,
                         command.VertexUniformBuffers, command.VertexUniformBufferCount);

    // push fragment uniforms
    web_gl_push_uniforms(d, program_id, command.FragmentShader, .FRAGMENT,
                         command.FragmentUniformBuffers, command.FragmentUniformBufferCount);

    // storage buffers: WebGL2 has no SSBO binding point for graphics stages (only
    // UBOs and TBOs), so a shader that declared one cannot be served here. The
    // three default programs declare none; warn once for anything else.
    if command.VertexStorageBufferCount > 0 || command.FragmentStorageBufferCount > 0 {
        if !web_gpu.warned_no_uniform {
            web_gpu.warned_no_uniform = true;
            log_warning("web/gl: 图形阶段存储缓冲（SSBO）在 WebGL2 里不存在 —— 绑定被忽略");
        }
    }

    // perform draw
    instances := cast(s32) max(1, command.InstanceCount);
    if command.IndexBuffer != null {
        element_type := web_gl_index_type(command.IndexBuffer.IndexFormat);
        index_size := index_format_size_in_bytes(command.IndexBuffer.IndexFormat);
        offset_bytes := command.IndexOffset * index_size;
        if command.VertexOffset != 0 && !web_gpu.warned_base_vertex {
            web_gpu.warned_base_vertex = true;
            log_warning("web/gl: 索引绘制 + VertexOffset 需要 drawElementsBaseVertex，WebGL2 没有这个入口 —— offset 被忽略");
        }
        gl_draw_indexed(GL_TRIANGLES, command.IndexCount, element_type, offset_bytes, instances, 0);
    } else {
        gl_draw(GL_TRIANGLES, command.VertexOffset, command.VertexCount, instances);
    }
    web_gpu.draws += 1;
}

// Sampler slot → (texture unit, sampler object, uniform name). Split out because
// vertex and fragment stages need the identical logic, which is one of the places
// the desktop file repeats itself.
//
// Textures stay name-addressed: GLSL ES 3.00 forbids opaque types (sampler2D) as
// uniform-block members, so a sampler can never ride the std140 slot table. The
// convention is slot 0 = `Texture`, slot i = `Texture<i>` (web_gl.jai ::
// web_gl_sampler_name) — which is exactly what the three default programs declare.
web_gl_bind_sampler_slot :: (d: *Graphics_Device, program_id: s32, shader: *Shader, stage: Shader_Stage,
                             slot: s32, value: Bound_Sampler, fallback_texture: Graphics_Resource_Handle) {
    name := web_gl_sampler_name(slot);
    if name == "" {
        if !web_gpu.warned_no_uniform {
            web_gpu.warned_no_uniform = true;
            log_warning(tprint("web/gl: 采样器槽 % 超出 WebGL2 的 16 个槽位上限 —— 纹理未被绑定", slot));
        }
        return;
    }

    // Resolve the texture the desktop way: the bound one, or the 1×1 fallback that
    // graphics/defaults.jai relies on for "material left this slot empty".
    texture_res: *GPU_Resource = null;
    if value.Tex != null texture_res = sdl_find_resource(d, value.Tex.handle);
    if texture_res == null {
        texture_res = sdl_find_resource(d, fallback_texture);
    }
    if texture_res == null return;

    // [W5] 采样的是「解析后的那张」，不是附件本身：
    //   * 多重采样附件自己没有纹理（WebGL2 的 MS 附件是 renderbuffer），
    //     web_gl_resolved_texture_id 会跳到它的解析纹理；
    //   * 格式不支持 / 创建失败的资源纹理 id 是 0 —— 绑 0 会让采样返回黑色，
    //     所以退回 1×1 的默认纹理（和「槽位为空」同一个行为）。
    texture_id := web_gl_resolved_texture_id(d, texture_res);
    if texture_id <= 0 {
        fallback := sdl_find_resource(d, fallback_texture);
        if fallback == null return;
        texture_id = web_gl_id(fallback.texture);
    }
    if texture_id <= 0 return;

    sampler_id := web_gl_get_sampler(d, value.Sampler);
    gl_bind_sampler(program_id, slot, texture_id, sampler_id,
                    web_gl_str_off(name), web_gl_str_len(name));
}

// Uniform slots (W4): the slot IS the std140 block's binding point.
//
// Desktop pushes `uniform_buffer_get(slot)` bytes with SDL_PushGPU*UniformData;
// WebGL2 gets the identical bytes through bufferSubData + bindBufferBase on
// binding = slot (vertex) / 8 + slot (fragment). No names, no type knowledge, no
// per-shader table — see web_gl.jai :: web_gl_uniform_binding_point. Whatever the
// GLSL declared inside that block reads the same bytes the HLSL `register(bN)`
// constant buffer read on desktop.
web_gl_push_uniforms :: (d: *Graphics_Device, program_id: s32, shader: *Shader, stage: Shader_Stage,
                         buffers: [MAX_UNIFORM_BUFFERS] *Uniform_Buffer, buffer_count: s32) {
    for i: 0..shader.UniformBufferCount-1 {
        if i >= buffer_count continue;
        ub := buffers[i];
        if ub == null continue;
        data := uniform_buffer_get(ub);
        if data.count <= 0 continue;

        if !web_gl_upload_uniform_block(stage, i, data) {
            if !web_gpu.warned_no_uniform {
                web_gpu.warned_no_uniform = true;
                log_warning(tprint("web/gl: 着色器 '%' 的 uniform 槽 %（stage %）没能推上去 —— 检查该 stage 是否真的声明了 layout(std140) uniform block", shader.Name, i, stage));
            }
        }
    }
}

sdl_perform_dispatch :: (d: *Graphics_Device, command: Compute_Command) {
    if d == null return;
    // WebGL2 has no glDispatchCompute (compute shaders are WebGL3/WebGPU). The
    // compute path therefore has no web implementation at all — W6 has to decide
    // between WebGPU and a CPU fallback. Failing loudly beats pretending.
    if !web_gpu.warned_no_uniform {
        web_gpu.warned_no_uniform = true;
        log_warning("web/gl: 计算管线在 WebGL2 里不存在（没有 glDispatchCompute）—— dispatch 被忽略，见 W6");
    }
}

sdl_clear :: (d: *Graphics_Device, target: Drawable_Target, color: [] Color, depth: float, stencil: s32, mask: Clear_Mask) {
    if d == null return;
    if mask == .NONE return;

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

    // Same shape as desktop: clearing *is* beginning a pass with a clear load op.
    // The clear happens immediately, so a later draw in the same pass keeps the
    // result (WebGL2 has no "clear on begin" concept to be surprised by).
    if web_gpu.device <= 0 return;
    sdl_begin_render_pass(d, target, clear);
}

//
// diagnostics
//

// glGetError after a call that we know can fail. `tag` names the call so the
// console line is actionable; the count is kept for fw_stats so the verifier can
// assert "zero GL errors during the whole run".
web_gl_check_error :: (tag: string) {
    if web_gpu.device <= 0 return;
    err := gl_get_error(web_gl_str_off(tag), web_gl_str_len(tag));
    if err != 0 web_gpu.gl_errors += 1;
}

#load "web_gl.jai";
