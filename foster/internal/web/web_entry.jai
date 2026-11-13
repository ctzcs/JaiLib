#scope_module
using Basic;

// jfoster — wasm 目标的程序入口与生命周期（W2）
//
// ---------------------------------------------------------------------------
// 为什么这个文件存在
// ---------------------------------------------------------------------------
// `jaic -os wasm` 只有「产出 wasm 模块」这一条路：它总是走 build 路径，因此
// 即便带 `-check` 也要求程序里有 `main :: () { ... }`，否则报
//
//     error[program-no-procedure]: the program has no 'main :: () { ... }'
//
// 桌面目标不受影响（native 的 -check 允许没有 main），所以本文件 **只在
// OS == .WASM 时被 module.jai #load**，桌面构建连读都读不到。
//
// ---------------------------------------------------------------------------
// 归属约定：wasm 下进程只有一个入口，归 jfoster 模块
// ---------------------------------------------------------------------------
// 应用的 `main` 只做**配置**：设 App.startup/update/render，然后调 app_run()。
// 帧循环归宿主（requestAnimationFrame）和本文件所有。所以应用 **不要** 在
// wasm 目标下把 app_run 当阻塞循环用、也不要在它后面调 app_destroy —— 见
// tests/wasm/main.jai 的写法。
//
// ---------------------------------------------------------------------------
// 怎么从模块里调用「程序的 main」
// ---------------------------------------------------------------------------
// Jai 的模块看不见程序作用域，所以不能直接写 `main()`。司法上的解法是
// **#entry_point**：一个声明成 `() -> s32 #entry_point` 的过程，jacket 会把它的
// 函数体填成「跳到程序入口」，于是模块也能调用程序的 main：
//
//     web_program_entry :: () -> s32 #entry_point;    // 声明，不实现
//     ...
//     push_context web_context.* { web_program_entry(); }   // == 调程序的 main
//
// 实测（本文件 + tests/wasm/main.jai）：调用时 context 已经 push 好，main 里
// 的 log/array_add/sprint 全都正常；返回后 context 仍然有效。
//
// 不能用的两条路，都实测过：
//   * `_start`：跑 main → __jai_runtime_fini → proc_exit，实例直接废掉。
//   * 导出的 `main`（jacket 的 runtime_entry）：它内部同样会 fini 我们保存的
//     context，之后每帧 use-after-free。
//
// ---------------------------------------------------------------------------
// 生命周期（和 app_web.jai 的分工）
// ---------------------------------------------------------------------------
//   host.js: fw_boot()
//     ├─ web_boot_runtime()        __jai_runtime_init 一次，存下 context
//     ├─ web_install_logger()      log()/print 全部流到 JS 控制台
//     ├─ web_window_boot()         canvas 尺寸 + devicePixelRatio
//     └─ push_context {
//            web_program_entry()   应用 main：App 回调 + app_run() 的 setup 段
//        }                         （app_run 在 web 上不阻塞，立刻返回）
//
//   host.js: fw_step(dt)  每帧一次
//     └─ web_run_frame(dt)         push_context + 钳 dt + reset_temporary_storage
//          └─ web_app_frame(dt)     app_web_frame()：App.update/App.render
//              └─ 返回 false → app_web_stop()（shutdown 回调 + 关输入设备）
//
//   fw_step 返回 0 → host.js 停止 requestAnimationFrame。

// jacket 填的函数体：跳到程序的 main。见上面的说明。
web_program_entry :: () -> s32 #entry_point;

// 帧回调（web_run_frame 调用，已经在 context 里）。
web_app_frame :: (dt: float64) -> bool {
    keep_going := app_web_frame(dt);
    if !keep_going {
        // 收尾必须在 context 里做：shutdown 回调和日志都要分配。
        // app_web_frame 只在 App.running 变 false / App.exiting 时返回 false。
        app_web_stop();
    }
    return keep_going;
}

// 帧计数：只是为了给宿主/验收一个客观数字（App.time.frame 是 u64 游戏时钟）。
web_frames_stepped: s32;
web_boot_done: bool;

//
// 导出给 JS 的入口
//

#program_export
fw_boot :: () -> s32 #no_context {
    if web_boot_done {
        web_log("fw_boot: 已经 boot 过了（只调一次）\n");
        return 1;
    }

    if !web_boot_runtime() {
        web_log("fw_boot: __jai_runtime_init 失败\n");
        return 0;
    }

    web_install_logger();
    web_step_handler = web_app_frame;

    push_context web_context.* {
        log_info("jfoster/wasm: fw_boot 开始（runtime + logger 就绪）");

        // canvas 尺寸 / devicePixelRatio 要在任何 window_create 之前拿到。
        web_window_boot();

        // 应用 main：设回调 + app_run() 的 setup 段（不阻塞）。
        web_program_entry();

        if App.window != null {
            size := window_size(App.window);
            pixels := window_size_in_pixels(App.window);
            log_info(tprint("jfoster/wasm: window '%' css=%x% device=%x% scale=%",
                            window_title(App.window), size.x, size.y,
                            pixels.x, pixels.y, web_pixel_ratio));
        } else {
            log_warning("jfoster/wasm: 应用的 main 没有调用 app_run()（App.window 为 null），fw_step 会立刻返回 0");
        }

        log_info(tprint("jfoster/wasm: 存档根 = '%'（OPFS/localStorage 虚拟键空间）", app_user_path()));
    }

    web_boot_done = true;
    return 1;
}

#program_export
fw_step :: (dt: float64) -> s32 #no_context {
    if !web_boot_done {
        web_log("fw_step: fw_boot 还没成功，先调 fw_boot\n");
        return 0;
    }

    keep_going := web_run_frame(dt);
    if !keep_going {
        web_frames_stepped += 1;    // 让 fw_stats 的帧数和宿主看到的一致
        web_log("fw_step: stop (app 请求退出)\n");
        return 0;
    }

    web_frames_stepped += 1;
    return 1;
}

// ------------------------------------------------------------------- 调试
//
// JS 侧读状态的唯一入口。浏览器验收靠它拿客观数字（键盘是否真的进了 Input、
// 窗口尺寸是否来自 canvas、事件队列是否在动）。
//
// 全是 s32，因为 wasm 多返回值会变成隐藏的 out 指针，而 s32 在 JS 侧就是普通
// Number。
#program_export
fw_stats :: (which: s32) -> s32 #no_context {
    value: s32 = 0;

    if web_context == null return -1;

    push_context web_context.* {
        if which == 0 {
            value = web_frames_stepped;
        } else if which == 1 {
            value = cast(s32) App.time.frame;
        } else if which == 2 {
            if App.window != null value = window_size(App.window).x;
        } else if which == 3 {
            if App.window != null value = window_size(App.window).y;
        } else if which == 4 {
            if App.window != null value = window_size_in_pixels(App.window).x;
        } else if which == 5 {
            if App.window != null value = window_size_in_pixels(App.window).y;
        } else if which == 6 {
            kb := input_keyboard(App.input);
            if kb != null {
                n: s32;
                for d: kb.down if d n += 1;
                value = n;
            }
        } else if which == 7 {
            // 最近一次按下的键（SDL scancode），没按过是 -1。
            kb := input_keyboard(App.input);
            value = -1;
            if kb != null {
                for d, i: kb.down {
                    if d {
                        value = cast(s32) i;
                    }
                }
            }
        } else if which == 8 {
            value = cast(s32) window_mouse_position(App.window).x;
        } else if which == 9 {
            value = cast(s32) window_mouse_position(App.window).y;
        } else if which == 10 {
            value = web_dom_events_total;
        } else if which == 11 {
            value = web_dom_text_total;
        } else if which == 12 {
            n: s32;
            for c: input_controllers(App.input) if c.Connected n += 1;
            value = n;
        } else if which == 13 {
            value = cast(s32) (web_pixel_ratio * 100.0);
        } else if which == 14 {
            value = web_resize_total;
        } else if which == 15 {
            value = web_gamepads_seen;
        } else if which == 16 {
            if App.running value = 1;
        } else if which == 17 {
            if App.exiting value = 1;
        } else if which == 18 {
            value = web_dom_rec.kind;   // 最近处理的事件种类（调试用）
        } else if which >= 200 {
            // [W6] 后端自己的计数（缓存表 / target / 读回拒绝 / 窗口 MSAA）：
            // 200 + i 转发到 web_gpu_stat(i)。和 100+ 的 GL 计数分两个号段，
            // 因为一个是「JS 侧真对象」，一个是「Jai 侧缓存」—— 内存报告要把
            // 两者并排看才能区分「泄漏」和「缓存没命中」。
            value = web_gpu_stat(App.device, which - 200);
        } else if which >= 100 {
            // [W3] 图形侧计数：100 + i 转发到 gl_stats(i)。放在同一条通道里，
            // 是为了让宿主的验收脚本只需要一套读数接口。
            value = gl_stats(which - 100);
        }
    }

    return value;
}

// 让宿主能在同一帧里主动推一条自定义事件（比如页面上的调试按钮）。
// 参数和 DOM 记录的语义完全一致，转发到 web_events.jai 的翻译层。
#program_export
fw_push_dom_event :: (kind: s32, a: s32, b: s32, c: s32, d: s32) -> s32 #no_context {
    if web_context == null return 0;

    applied: s32 = 0;
    push_context web_context.* {
        rec: Web_Dom_Event;
        rec.kind = kind;
        rec.a = a;
        rec.b = b;
        rec.c = c;
        rec.d = d;
        web_dispatch_dom_event(rec);
        applied = 1;
    }
    return applied;
}

// 布局自检：把跨语言 ABI 的大小/偏移报给 JS，verify.mjs 拿它和 host.js 里的
// 常量对拍，防止「改了一个字段忘了改另一侧」这类静默错位。
#program_export
fw_layout :: (which: s32) -> s32 #no_context {
    // size_of / offset_of 都是 s64，导出签名是 s32（JS 侧直接读 Number）。
    if which == 0 return cast(s32) size_of(Web_Dom_Event);
    if which == 1 return cast(s32) offset_of(Web_Gamepad_Rec, "axes");
    if which == 2 return cast(s32) offset_of(Web_Gamepad_Rec, "buttons");
    if which == 3 return cast(s32) size_of(Web_Gamepad_Rec);
    if which == 4 return cast(s32) offset_of(Web_Gamepad_Rec, "name");
    return -1;
}

// 公开读数入口：应用不能直接调 fw_stats（那是 #program_export 的过程，声明在
// #scope_module 里，模块外看不见）。桌面构建没有这个名字，所以应用侧要放在
// `#if OS == .WASM` 里调用（见 tests/wasm/main.jai 的 sample_stats）。
#scope_export
web_stats :: (which: s32) -> s32 #no_context {
    return fw_stats(which);
}

// [W6] 线性内存当前大小（字节）—— 内存 soak 的唯一直接读数。
//
// 应用不能直接调 fw_memory_bytes（那是 #foreign 声明，模块外看不见），所以和
// web_stats 一样包一层 #scope_export。桌面构建没有这个名字，调用点要放在
// `#if OS == .WASM` 里（见 tests/wasm/main.jai 的 sample_memory_bytes）。
#scope_export
web_linear_memory_bytes :: () -> s32 #no_context {
    return fw_memory_bytes();
}

// [W3] 从 Jai 侧读回 canvas 默认 framebuffer 的一个像素（RGBA8，左上原点）。
//
// 这是验收路径上唯一一个不属于「渲染 API」的入口：渲染本身全在 graphics/ 的
// 公开 API 里，而**证明它真的出了像素**需要把 GPU 的帧缓冲读回 CPU。桌面用的是
// texture_get_data（离屏 backbuffer Target）；web 直接画在 canvas 上，所以走
// gl.readPixels。
//
// 返回值：真的读到像素才 true。宿主没有 WebGL2 时返回 false —— 调用方据此把
// 断言标成「跳过」而不是「通过」，免得在 Node 里假绿。
// [W6] 读的是「解析之后的那张」：web_gl_readback_fbo 会
//   * 窗口级 MSAA 生效时先 resolve 到 0 号 FBO 再读 0；
//   * 离屏 target 的 MSAA pass 还开着时先 resolve 再读它的单采样 FBO。
// 不这么做的话，读回会打在多重采样的 renderbuffer 上 —— WebGL2 里那是
// INVALID_OPERATION（readPixels 不允许读 MS 附件），而错误只在 getError 里。
#scope_export
web_read_pixel :: (x: s32, y: s32, out: *Color) -> bool #no_context {
    if web_context == null || out == null return false;

    ok: bool = false;
    push_context web_context.* {
        fbo := web_gl_readback_fbo(App.device);
        ok = gl_read_pixels(x, y, 1, 1, web_gl_off(out), 4, fbo) > 0;
    }
    return ok;
}

// 一次读一块（w×h RGBA8），给需要整块比对的场景（W5 的像素级对拍）。
#scope_export
web_read_pixels :: (x: s32, y: s32, w: s32, h: s32, out: *void, length: s32) -> bool #no_context {
    if web_context == null || out == null || length <= 0 return false;

    ok: bool = false;
    push_context web_context.* {
        fbo := web_gl_readback_fbo(App.device);
        ok = gl_read_pixels(x, y, w, h, web_gl_off(out), length, fbo) > 0;
    }
    return ok;
}

// ------------------------------------------------------------------- main
//
// jacket 需要一个程序 main 才肯产出可执行模块。它只在「把 module.jai 本身当
// 程序编译」（-check -os wasm module.jai）时才会被跑到；真正的应用有自己的
// main，web_program_entry 指向那个。加了 #scope_module 是为了这个 main 不被
// 导出成 `foster.main` —— 否则应用的 main 会触发
// warning[declaration-hides-import]（官方 Jai 直接报错）。
main :: () {
    log_info("jfoster/wasm: module.jai 自带的 main 被调起来了 —— 应用应该有自己的 main；宿主应该调 fw_boot 而不是 _start");
}
