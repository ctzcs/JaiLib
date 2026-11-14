// jfoster — Web (wasm64) 的 Jai 侧 JS 桥。
//
// 这是「框架侧」的桥：env 导入声明 + 持久 context 引导 + 帧驱动 + 一组哑包装
// （把 string / bool / Rect 这些 Jai 值翻译成 s32 内存偏移）。只有 wasm 目标
// 会看到本文件（desktop 构建走不到这里，见 module.jai 的 #if）。
//
// ============================================================================
// 事实（jaic 0.35.1 + lld -flavor wasm，均已实测，详见 internal/web/README.md）
// ============================================================================
// 1. 导出：只有 `#program_export` 的「前缀形式」+ `#no_context` 才能得到干净的
//    JS 可直接调用的签名。裸 #program_export 不带 #no_context 时，签名前面会多
//    一个 i64（隐藏的 context 指针），JS 侧必须先传一个 BigInt 才能调，等于不可用。
//
//        #program_export
//        fw_step :: (dt: float64) -> s32 #no_context { ... }   // (f64) -> i32
//
//    `#program_export\nfname;` 这种「独立语句形式」（Jai 官方 dll 例子里那种）
//    jacket 不会把它变成 wasm export，实测无效，必须写成声明前缀。
//
// 2. 导入：不加库名的 `#foreign` 声明即可，符号落在 import module `env`：
//
//        fw_log :: (ptr: s32, len: s32) #foreign;   // => env.fw_log (i32,i32)->()
//
//    不需要 -extra_linker_options / --allow-undefined。-os wasm 这条路径没有
//    传额外链接选项的入口；要多导出符号就给 JAIC_WASM_LD 包一层 --export=...。
//    **host.js 必须把下面每一个导入都实现掉**：少一个 WebAssembly.instantiate
//    直接抛 LinkError，实例根本起不来。
//
// 3. 内存：模块自带 `memory` 导出（无需 --export-memory），是 **wasm64**
//    （flags=0x4，初始 130~147 页，无上限）。指针是 8 字节；因此桥接口一律用
//    s32「内存偏移」而不是指针，JS 侧就完全不用碰 BigInt。
//
// 4. context：#no_context 过程里不能用 context（array_add/sprint/print 都会报
//    call-cannot-without-context）。持久化的办法是 __jai_runtime_init 一次，
//    把返回的 *#Context 存起来，之后每帧 push_context saved.* { ... }。
//    不要调 _start：它会跑 main + __jai_runtime_fini + proc_exit（fini 会拆掉
//    我们存下来的 context，之后每帧都会 use-after-free）。
//
// 5. 日志：把 context.logger 指向一个「带 context 的」过程，框架里任何 log()/print
//    都会流到 JS。注意该过程 **不能** 加 #no_context，否则间接调用签名不匹配，
//    运行期 trap（null function or function signature mismatch）。
//
// 6. 临时内存：每帧末尾 reset_temporary_storage()，否则 sprint/log 可持续增长。
// ============================================================================

#if OS == .WASM {

    // ---------------------------------------------------------------- JS imports
    //
    // 全部是 s32「线性内存偏移」+ 长度；只有 fw_now_ms / fw_pixel_ratio 用 float64。
    // 这样 JS 侧收到的都是普通 Number，一个 BigInt 都不用（wasm64 的指针是 i64，
    // 传指针的话 JS 得写 BigInt(...)，既慢又容易忘）。
    //
    // 方向约定：
    //   * Jai → JS：偏移指向 Jai 写好的 UTF-8 字节。
    //   * JS → Jai：偏移指向一块由 Jai 提供、JS 负责填写（或写入长度）的缓冲区。
    // 返回值统一 `s32`：写入了多少字节（>=0），或 -1 表示失败/不支持。

    // 日志：写一段 UTF-8 到宿主（JS 侧决定是 console 还是 DOM）。
    fw_log :: (ptr: s32, len: s32) #foreign;

    // 宿主时钟（毫秒，单调）。不依赖 rAF 的 dt 兜底也用它。
    fw_now_ms :: () -> float64 #foreign;

    // [W6] wasm 线性内存当前的字节数（JS 侧的 `memory.buffer.byteLength`）。
    //
    // 为什么只能问 JS：WebAssembly.Memory 的大小是**宿主**的财产，Jai 侧没有任何
    // 内建能读到它（没有 __builtin_wasm_memory_size 的暴露）。而「跑几千帧看有没有
    // 泄漏」的**首要**证据就是它 —— Jai 侧那些缓存表只能证明「对象没变多」，证明不了
    // 「内存没涨」（每帧 new 一块临时内存再丢掉，表里看不出来，内存里看得出来）。
    // 返回 s32：模块内存是几十 MB 量级，远小于 2GB。
    fw_memory_bytes :: () -> s32 #foreign;

    // canvas 的**backing store**像素尺寸：JS 把 int32 写到两个偏移上。
    fw_canvas_size :: (width_off: s32, height_off: s32) #foreign;

    // devicePixelRatio（CSS 像素 → 设备像素的比例，相当于 SDL 的 display scale）。
    fw_pixel_ratio :: () -> float64 #foreign;

    // document.title（窗口标题）。
    fw_set_title :: (ptr: s32, len: s32) -> s32 #foreign;

    // requestFullscreen / exitFullscreen。第 1 个参数是 0/1。
    fw_request_fullscreen :: (on: s32) -> s32 #foreign;

    // canvas.style.cursor（CSS 关键字或 url(data:...) hot_x hot_y）。
    fw_set_cursor_css :: (ptr: s32, len: s32) -> s32 #foreign;

    // navigator.clipboard。get 是**同步**的：见 host.js 的说明（读缓存，
    // readText() 的异步结果在后台刷新缓存）。
    fw_clipboard_get :: (buf: s32, cap: s32) -> s32 #foreign;
    fw_clipboard_set :: (ptr: s32, len: s32) -> s32 #foreign;

    // 存档：key 是相对存档根的逻辑路径（"settings.json" / "save/slot1.dat"）。
    fw_storage_read :: (key: s32, key_len: s32, buf: s32, cap: s32) -> s32 #foreign;
    fw_storage_write :: (key: s32, key_len: s32, val: s32, val_len: s32) -> s32 #foreign;
    // 列目录：把 key 前缀下的条目名用 "\n" 拼进 buf，返回总字节数。
    fw_storage_list :: (prefix: s32, prefix_len: s32, buf: s32, cap: s32) -> s32 #foreign;
    // 删除一个键（storage_remove / jf_file_delete 走它）。
    fw_storage_remove :: (key: s32, key_len: s32) -> s32 #foreign;

    // DOM 事件队列 → Jai。**拉模式**（名字是站在 DOM 的视角：把事件推进来）：
    // 每次调用把「队列里的下一个事件」写成一条 6×s32 的记录到 rec 偏移上，
    // 返回 1 表示写了一条，0 表示队列空了。Jai 侧在每帧的 app_poll_events 里循环
    // 拉到 0，于是事件顺序和浏览器派发的顺序完全一致。记录布局见 web_events.jai。
    fw_dom_event_push :: (rec: s32, cap: s32) -> s32 #foreign;

    // 指针锁定（相对鼠标模式）。第 1 个参数是 0/1。
    fw_mouse_relative :: (on: s32) -> s32 #foreign;

    // [L-022] IME 锚点：把隐藏的 <input> 摆到 canvas 上的计划矩形处。
    // 参数是 CSS 像素；on=0 时隐藏。返回 1 表示已经应用。
    fw_text_input_area :: (x: s32, y: s32, w: s32, h: s32, on: s32) -> s32 #foreign;

    // Gamepad API 快照：JS 把最多 count 条记录写进 rec（布局见 web_events.jai 的
    // Web_Gamepad_Rec），返回写了几条。
    fw_gamepad_poll :: (rec: s32, count: s32) -> s32 #foreign;

    // ------------------------------------------------------------ WebGL2 (W3)
    //
    // 这一组是「哑 GL 通道」：**不做任何枚举翻译**，Jai 侧（internal/web/web_gl.jai）
    // 把 jfoster 的枚举翻成 GL 常量再传下来，JS 侧只负责调用对应的 WebGL2 方法。
    // 理由和 SDL_GPU 后端的分工一致（sdl_get_blend_state / sdl_get_vertex_format
    // 都在 Jai 侧），而且这样 host.js 里没有一行 jfoster 的语义。
    //
    // 句柄模型：**一律是 JS 侧对象表的下标**（1 起，0 = 无效）。JS 用一张数组
    // `objects[id]` 存 WebGL 对象 + 创建时记下的元数据（pipeline 的属性布局、
    // program 的 uniform 位置缓存……）。Jai 侧把这个 id 存进 GPU_Resource 现有的
    // 指针字段（`cast(*T) cast(*void) id`），所以 `sdl_*` 的签名一个都没动。
    //
    // 参数全部是 s32「内存偏移 / 标量」；只有需要浮点的地方（clear 的 depth、
    // uniform1f 的值）用 float64 —— 两者到 JS 侧都是普通 Number，不用 BigInt。
    //
    // 所有 gl_* 在「宿主没有 WebGL2」（Node 校验环境）时都不抛异常：创建类返回 0，
    // 其余返回 -1，调用方据此跳过绘制。这样 verify.mjs 里同一份 wasm 也能跑。

    // -- device / swapchain
    gl_device_create :: (width: s32, height: s32) -> s32 #foreign; // -> device id；0 = 没有 WebGL2
    gl_device_destroy :: () -> s32 #foreign;
    gl_swapchain_bind :: (width: s32, height: s32) -> s32 #foreign; // canvas backing store + viewport
    gl_present :: () -> s32 #foreign; // flush（浏览器下一帧合成）
    gl_get_error :: (tag_ptr: s32, tag_len: s32) -> s32 #foreign; // glGetError + 带标签的控制台日志
    gl_get_string :: (which: s32, buf: s32, cap: s32) -> s32 #foreign; // 0 VERSION 1 RENDERER 2 VENDOR 3 GLSL
    gl_get_param :: (which: s32) -> s32 #foreign; // 0/1 canvas w/h  2 MAX_TEXTURE_SIZE  3 MAX_VERTEX_ATTRIBS

    // 4 纹理单元数  5 MAX_SAMPLES  6/7 drawingBuffer w/h
    // -- textures
    gl_create_texture :: (width: s32, height: s32, internal_format: s32,
                          min_filter: s32, mag_filter: s32, wrap_s: s32, wrap_t: s32) -> s32 #foreign;

    gl_set_texture_data :: (texture: s32, x: s32, y: s32, w: s32, h: s32,
                            data_ptr: s32, length: s32, format: s32, type: s32) -> s32 #foreign;

    gl_get_texture_data :: (texture: s32, x: s32, y: s32, w: s32, h: s32,
                            out_ptr: s32, length: s32,
                            format: s32, type: s32, attachment: s32) -> s32 #foreign;

    gl_destroy_texture :: (texture: s32) -> s32 #foreign;
    // -- framebuffer / renderbuffer / blit（W5：render-to-target + MSAA）
    //
    // 附件枚举（attachment）由 Jai 侧翻成 GL 常量传下来：GL_COLOR_ATTACHMENT0 + i /
    // GL_DEPTH_ATTACHMENT / GL_DEPTH_STENCIL_ATTACHMENT。挂接类入口把
    // **glCheckFramebufferStatus 的结果**原样返回（0x8CD5 = COMPLETE），于是「FBO 不
    // 完整」在 Jai 侧是一条带状态的明确错误，而不是画了很久才发现是黑的。
    gl_create_framebuffer :: () -> s32 #foreign; // -> fbo id；0 = 失败
    gl_destroy_framebuffer :: (framebuffer: s32) -> s32 #foreign;
    gl_attach_texture :: (framebuffer: s32, attachment: s32, texture: s32) -> s32 #foreign; // -> FB 状态
    gl_create_renderbuffer :: (internal_format: s32, width: s32, height: s32, samples: s32) -> s32 #foreign;
    gl_destroy_renderbuffer :: (renderbuffer: s32) -> s32 #foreign;
    gl_attach_renderbuffer :: (framebuffer: s32, attachment: s32, renderbuffer: s32) -> s32 #foreign; // -> FB 状态
    gl_framebuffer_status :: (framebuffer: s32) -> s32 #foreign;

    // src/dst 传 0 表示 canvas 的默认 framebuffer；mask 位见 web_gl.jai :: WEB_BLIT_*。
    // 坐标是 GL 的左下原点（Jai 侧翻好），filter 是 GL_NEAREST / GL_LINEAR。
    gl_blit_framebuffer :: (src: s32, dst: s32,
                            sx0: s32, sy0: s32, sx1: s32, sy1: s32,
                            dx0: s32, dy0: s32, dx1: s32, dy1: s32,
                            mask: s32, filter: s32) -> s32 #foreign;

    // -- buffers
    gl_create_buffer :: (target: s32) -> s32 #foreign; // GL_ARRAY_BUFFER / GL_ELEMENT_ARRAY_BUFFER

    gl_set_buffer_data :: (buffer: s32, data_ptr: s32, length: s32,
                           dest_offset: s32, capacity: s32, target: s32) -> s32 #foreign;

    gl_destroy_buffer :: (buffer: s32) -> s32 #foreign;
    // -- samplers
    gl_create_sampler :: (min_filter: s32, mag_filter: s32, wrap_s: s32, wrap_t: s32) -> s32 #foreign;
    gl_destroy_sampler :: (sampler: s32) -> s32 #foreign;
    // -- shaders / programs
    gl_create_shader :: (stage: s32, src_ptr: s32, src_len: s32, name_ptr: s32, name_len: s32) -> s32 #foreign;
    gl_create_program :: (vs: s32, fs: s32, name_ptr: s32, name_len: s32) -> s32 #foreign;
    gl_destroy_shader :: (shader: s32) -> s32 #foreign;
    gl_destroy_program :: (program: s32) -> s32 #foreign;
    // -- uniform buffers（W4：std140 block，binding index == uniform 槽位）
    //
    // gl_create_program 在 link 成功后自己做完 uniformBlockBinding：binding point 由
    // (stage, 该 stage 内第几个 block) 决定，Jai 侧只按 binding 号绑定 UBO，永不查
    // block 名字。见 web_gl.jai :: web_gl_uniform_binding_point。
    gl_create_uniform_buffer :: (size: s32) -> s32 #foreign;
    gl_set_uniform_buffer_data :: (buffer: s32, data_ptr: s32, length: s32, dest_offset: s32, capacity: s32) -> s32 #foreign;
    gl_bind_uniform_buffer :: (buffer: s32, binding: s32) -> s32 #foreign; // bindBufferBase
    gl_destroy_uniform_buffer :: (buffer: s32) -> s32 #foreign;
    // -- pipeline = program + VAO + 属性布局（blend/depth/cull 是每次 draw 的状态）
    gl_create_pipeline :: (program: s32, attrs_ptr: s32, attr_count: s32) -> s32 #foreign;
    gl_destroy_pipeline :: (pipeline: s32) -> s32 #foreign;
    // ShaderPairTryReplace 的探针 pipeline 自己拥有 program（正常绘制路径的 pipeline
    // 借用缓存里的 program），所以释放时要连 program 一起删。
    gl_release_pipeline_with_program :: (pipeline: s32) -> s32 #foreign;
    // -- render pass
    gl_begin_render_pass :: (framebuffer: s32, width: s32, height: s32) -> s32 #foreign; // 0 = canvas 默认 FBO

    gl_clear :: (r: s32, g: s32, b: s32, a: s32, color_mask: s32,
                 depth: float64, stencil: s32, depth_mask: s32, stencil_mask: s32) -> s32 #foreign;

    gl_end_render_pass :: () -> s32 #foreign;
    // -- draw state
    gl_bind_pipeline :: (pipeline: s32) -> s32 #foreign;
    gl_bind_vertex_buffer :: (pipeline: s32, slot: s32, buffer: s32) -> s32 #foreign;
    gl_bind_index_buffer :: (buffer: s32) -> s32 #foreign;

    gl_bind_sampler :: (program: s32, unit: s32, texture: s32, sampler: s32,
                        name_ptr: s32, name_len: s32) -> s32 #foreign;

    gl_set_blend :: (enable: s32, src_color: s32, dst_color: s32, color_op: s32,
                     src_alpha: s32, dst_alpha: s32, alpha_op: s32, color_mask: s32) -> s32 #foreign;

    gl_set_cull :: (mode: s32) -> s32 #foreign; // 0 off / GL_FRONT / GL_BACK
    gl_set_depth :: (test: s32, write: s32, compare: s32) -> s32 #foreign;

    gl_set_stencil :: (enable: s32, ref: s32, compare_mask: s32, write_mask: s32,
                       front_compare: s32, front_pass: s32, front_fail: s32, front_depth_fail: s32,
                       back_compare: s32, back_pass: s32, back_fail: s32, back_depth_fail: s32) -> s32 #foreign;

    gl_set_viewport :: (x: s32, y: s32, w: s32, h: s32) -> s32 #foreign;
    gl_set_scissor :: (x: s32, y: s32, w: s32, h: s32, enabled: s32) -> s32 #foreign;
    // -- draw calls
    gl_draw :: (mode: s32, first: s32, count: s32, instances: s32) -> s32 #foreign;

    gl_draw_indexed :: (mode: s32, count: s32, element_type: s32, offset_bytes: s32,
                        instances: s32, base_vertex: s32) -> s32 #foreign;

    // -- readback（坐标是 jfoster 的左上原点，JS 侧翻成 GL 的左下原点）
    //
    // [W6] 最后一个参数是「从哪个 framebuffer 读」：
    //   -1 = 保持当前绑定（W3/W4 的行为，窗口单采样时才正确）
    //    0 = canvas 的默认 framebuffer（窗口级 MSAA 解析后的落点）
    //   >0 = 某个离屏 FBO（target 的单采样 FBO —— 多重采样的那个不能直接 readPixels）
    // Jai 侧由 web_gl.jai :: web_gl_readback_fbo 算出这个值，调用点不用关心。
    gl_read_pixels :: (x: s32, y: s32, w: s32, h: s32, out_ptr: s32, length: s32,
                       framebuffer: s32) -> s32 #foreign;

    // -- 计数器（fw_stats 复用；也是报告里的客观数字）
    gl_stats :: (which: s32) -> s32 #foreign;

    // -------------------------------------------------------- persistent context
    //
    // web_context 由 web_boot_runtime() 填，此后永远非空；所有导出过程都靠它。
    web_context: *#Context;

    // App 侧每帧回调：返回 false = 请求停止（host.js 收到 0 就停 rAF）。
    web_step_handler: (dt: float64) -> bool = null;

    // 补换行用的一字节常量（避免在 #no_context 里为 "\n" 走分配）。
    web_newline: [1] u8 = .[#char "\n"];

    // 初始化一次 Jai 运行时 context。幂等；成功返回 true。
    // 注意：不跑 main、不跑 __jai_runtime_fini、不调 proc_exit。
    web_boot_runtime :: () -> bool #no_context {
        if web_context {
            return true;
        }

        context_ptr := __jai_runtime_init(0, null);
        if !context_ptr {
            return false;
        }

        web_context = context_ptr;
        return true;
    }

    // 把 context.logger 接到 JS 控制台。必须在 web_boot_runtime() 之后调。
    web_install_logger :: () #no_context {
        if !web_context {
            return;
        }

        push_context web_context.* {
            context.logger = web_logger;
        }
    }

    // ------------------------------------------------------------------ logging
    //
    // 不带 context 的原始写入口：任何地方（含 #no_context）都能用，但它只收现成
    // 的 string，不做格式化（格式化需要 temp allocator = 需要 context）。
    web_log :: (message: string) #no_context {
        if message.count <= 0 {
            return;
        }

        fw_log(cast(s32) cast(u64) message.data, cast(s32) message.count);
    }

    // context.logger 的实现。**故意不加 #no_context**：Logger 类型带 context 参数，
    // 签名必须一致，否则间接调用在 wasm 里 trap。
    web_logger :: (message: string, data: *void, info: Log_Info) {
        if message.count <= 0 {
            return;
        }

        fw_log(cast(s32) cast(u64) message.data, cast(s32) message.count);

        // Jai 的 logger 不保证结尾有换行（log() 就没有），JS 控制台是按行缓冲的，
        // 不补的话多条日志会粘成一行。
        if message[message.count - 1] != #char "\n" {
            fw_log(cast(s32) cast(u64) web_newline.data, 1);
        }
    }

    // ------------------------------------------------------------------- clock
    web_now_ms :: () -> float64 #no_context {
        return fw_now_ms();
    }

    // ------------------------------------------------------------------- strings
    //
    // string -> s32 内存偏移。wasm64 里指针是 8 字节，先转 u64 再截成 s32 偏移；
    // 线性内存现实上限 4 GiB（WASI preview1 的地址是 u32，见 README §4），所以截断
    // 是安全的。
    web_str_off :: (s: string) -> s32 #no_context {
        return cast(s32) cast(u64) s.data;
    }

    // (ptr, count) -> string。jacket 不支持 `arr[a..b]` 切片语法（实测
    // error[parse-expected-token]），所以这类「静态缓冲区里的一段」直接手搭
    // string 头，比绕 String.slice 少一层间接。
    web_str_of :: (data: *u8, count: s32) -> string #no_context {
        if data == null || count <= 0 return "";
        result: string;
        result.data = data;
        result.count = count;
        return result;
    }

    //
    // 哑包装：都必须在有 context 的地方调用（它们不分配，但调用方通常在有 context
    // 的代码里）。返回值原样透传给 JS 的 s32。
    //

    web_set_title :: (title: string) -> s32 {
        if title.count <= 0 return -1;
        return fw_set_title(web_str_off(title), cast(s32) title.count);
    }

    web_request_fullscreen :: (on: bool) -> s32 {
        return fw_request_fullscreen(cast(s32) (ifx on then 1 else 0));
    }

    web_set_cursor_css :: (css: string) -> s32 {
        if css.count <= 0 return -1;
        return fw_set_cursor_css(web_str_off(css), cast(s32) css.count);
    }

    web_set_mouse_relative :: (on: bool) -> s32 {
        return fw_mouse_relative(cast(s32) (ifx on then 1 else 0));
    }

    web_set_text_input_area :: (x: s32, y: s32, w: s32, h: s32, on: bool) -> s32 {
        return fw_text_input_area(x, y, w, h, cast(s32) (ifx on then 1 else 0));
    }

    // canvas 的 backing-store 像素尺寸。0,0 表示宿主没有 canvas（纯 Node 校验环境）。
    web_canvas_size :: () -> (width: s32, height: s32) #no_context {
        w: s32;
        h: s32;
        fw_canvas_size(cast(s32) cast(u64) *w, cast(s32) cast(u64) *h);
        return w, h;
    }

    // 名字带 query 是为了和 window_web.jai 里的 globals `web_pixel_ratio` 区分
    // （Jai 的变量和过程共用命名空间）。
    web_query_pixel_ratio :: () -> float64 #no_context {
        ratio := fw_pixel_ratio();
        if ratio <= 0.0 return 1.0;
        return ratio;
    }

    // ------------------------------------------------------------- frame driver
    //
    // 每帧的模板：进入持久 context → 跑 App 回调 → 回收 temp storage。
    // 返回 false 表示应当停止（host.js 停止 requestAnimationFrame）。
    web_run_frame :: (dt: float64) -> bool #no_context {
        if !web_context {
            web_log("web_run_frame: bridge not booted (call fw_boot first)\n");
            return false;
        }

        // 页面切回来时浏览器会给一个巨大的 dt，钳死它免得物理炸掉。
        clamped := dt;
        if clamped < 0.0 {
            clamped = 0.0;
        }
        if clamped > 0.25 {
            clamped = 0.25;
        }

        keep_going := true;
        push_context web_context.* {
            if web_step_handler != null {
                keep_going = web_step_handler(clamped);
            }
            reset_temporary_storage();
        }

        return keep_going;
    }

} // #if OS == .WASM
