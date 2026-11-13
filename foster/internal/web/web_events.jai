// jfoster — Web (wasm64)：DOM 事件队列 → Web_Event，以及 Gamepad API 快照。
//
// ===========================================================================
// 为什么单独一个文件
// ===========================================================================
// 桥的导入声明（web_bridge.jai）只负责「怎么说」；这里负责「说什么」：
//   * 记录布局（Jai <-> JS 的 ABI，改一个字段就必须改 host.js）
//   * DOM 事件 → Web_Event 的翻译（含窗口/焦点/可见性/尺寸这些非输入事件）
//   * Gamepad API 快照 → input_connect_controller / input_controller_*
// 拆出来是因为 host.js 每次都要对着这一份文件核对偏移；塞进 input_web.jai 会
// 让「输入状态机」和「跨语言 ABI」两件事混在一处。
//
// ===========================================================================
// 谁在什么时候调用
// ===========================================================================
//   requestAnimationFrame
//     → fw_step(dt)                        [web_entry.jai]
//       → web_run_frame(dt)                [web_bridge.jai]   push_context
//         → app_web_frame()                [app_web.jai]
//           → app_tick() → app_step() → app_poll_events()
//             → web_drain_dom_events()     ← 本文件：把 JS 队列拉空
//             → web_poll_gamepads()        ← 本文件：Gamepad API 快照
//             → web_poll_events()          [input_web.jai] 把攒下的事件取走
//           → input_on_web_event(...)      [input_web.jai]
//
// 每帧把 JS 队列**拉空**是关键：DOM 派发事件的频率远高于帧率（pointermove 可
// 到 120+ Hz），所以 JS 侧只入队，Jai 侧每帧一次性全取，顺序与派发顺序一致。
//
// ===========================================================================
// 记录布局（s32 le × 6 = 24 字节；host.js 里有一份一模一样的）
// ===========================================================================
//   offset 0  kind   WEB_EV_* 常量
//   offset 4  a      kind 相关（见下面每个常量的注释）
//   offset 8  b
//   offset 12 c
//   offset 16 d
//   offset 20 e      预留
//
// 所有坐标都是**设备像素**（canvas backing store），与 window_mouse_position
// 的单位一致；CSS 像素只在 RESIZE 事件里额外给一份。
//
// ===========================================================================

#scope_module

//
// 事件种类。数值是和 host.js 的约定，不要改（改了要同时改 JS）。
//
WEB_EV_KEY_DOWN     :: 1;    // a=scancode  b=repeat(0/1)
WEB_EV_KEY_UP       :: 2;    // a=scancode
WEB_EV_POINTER_DOWN :: 3;    // a=button(1=左,2=中,3=右,4=X1,5=X2) b=x c=y
WEB_EV_POINTER_UP   :: 4;    // a=button b=x c=y
WEB_EV_POINTER_MOVE :: 5;    // a=x b=y c=movementX d=movementY（指针锁定时才有意义）
WEB_EV_WHEEL        :: 6;    // a=deltaX*100 b=deltaY*100 c=x d=y
WEB_EV_FOCUS        :: 7;
WEB_EV_BLUR         :: 8;
WEB_EV_VISIBILITY   :: 9;    // a=1 可见 / 0 隐藏
WEB_EV_RESIZE       :: 10;   // a=css_w b=css_h c=device_w d=device_h
WEB_EV_TEXT         :: 11;   // a=Unicode 码点

Web_Dom_Event :: struct {
    kind: s32;
    a: s32;
    b: s32;
    c: s32;
    d: s32;
    e: s32;
}

// DOM 队列拉空用的暂存记录（JS 写，我们读）。
web_dom_rec: Web_Dom_Event;

// 累计统计（fw_stats 读，浏览器验收用）。
web_dom_events_total: s32;
web_dom_text_total: s32;
web_resize_total: s32;

//
// 文本输入的目标缓冲区
//
// Web_Event.text_ptr 是「队列被取走之前都有效」的裸指针，所以文本不能指向临时
// 分配的字符串。这里用一块每帧复位的静态池：一帧内所有 TEXT 事件顺序写入，
// 各自 NUL 结尾（input_on_web_event 用 cstr_to_string 读它）。
//
WEB_TEXT_POOL_SIZE :: 1024;
web_text_pool: [WEB_TEXT_POOL_SIZE] u8;
web_text_pool_used: s32;

web_text_pool_reset :: () {
    web_text_pool_used = 0;
}

// 把一个码点按 UTF-8 写进池子，返回偏移；空间不足返回 -1。
web_text_pool_put_codepoint :: (cp: u32) -> s32 {
    // 最长 4 字节 + NUL
    if web_text_pool_used + 5 > WEB_TEXT_POOL_SIZE return -1;

    at := web_text_pool_used;
    p := at;
    if cp < 0x80 {
        web_text_pool[p] = cast(u8) cp;
        p += 1;
    } else if cp < 0x800 {
        web_text_pool[p] = cast(u8) (0xC0 | (cp >> 6));
        web_text_pool[p + 1] = cast(u8) (0x80 | (cp & 0x3F));
        p += 2;
    } else if cp < 0x10000 {
        web_text_pool[p] = cast(u8) (0xE0 | (cp >> 12));
        web_text_pool[p + 1] = cast(u8) (0x80 | ((cp >> 6) & 0x3F));
        web_text_pool[p + 2] = cast(u8) (0x80 | (cp & 0x3F));
        p += 3;
    } else {
        web_text_pool[p] = cast(u8) (0xF0 | (cp >> 18));
        web_text_pool[p + 1] = cast(u8) (0x80 | ((cp >> 12) & 0x3F));
        web_text_pool[p + 2] = cast(u8) (0x80 | ((cp >> 6) & 0x3F));
        web_text_pool[p + 3] = cast(u8) (0x80 | (cp & 0x3F));
        p += 4;
    }
    web_text_pool[p] = 0;
    web_text_pool_used = p + 1;
    return at;
}

//
// 拉取 + 翻译
//
// 注意方向：fw_dom_event_push 是「JS 把下一个事件推进调用方给的记录里」，所以
// 这里是一个 while 循环拉到 0 为止，而不是等 JS 回调。
//
web_drain_dom_events :: () {
    web_text_pool_reset();

    while fw_dom_event_push(cast(s32) cast(u64) *web_dom_rec, 1) != 0 {
        web_dom_events_total += 1;
        web_dispatch_dom_event(*web_dom_rec);
    }
}

web_dispatch_dom_event :: (rec: Web_Dom_Event) {
    kind := rec.kind;

    if kind == WEB_EV_KEY_DOWN || kind == WEB_EV_KEY_UP {
        ev: Web_Event;
        ev.window_id = web_main_window_id();
        ev.scancode  = cast(u32) rec.a;
        ev.repeat    = rec.b != 0;
        if kind == WEB_EV_KEY_DOWN ev.type = .SDL_EVENT_KEY_DOWN;
        else                       ev.type = .SDL_EVENT_KEY_UP;
        web_push_event(ev);

    } else if kind == WEB_EV_POINTER_DOWN || kind == WEB_EV_POINTER_UP {
        // 顺序很重要：先把位置更新掉，按键事件里读到的 mouse position 才是
        // 按下那一刻的值（桌面端也是这个顺序，SDL 先更新 mouse state）。
        web_set_mouse_position(cast(float) rec.b, cast(float) rec.c);

        ev: Web_Event;
        ev.window_id = web_main_window_id();
        ev.button    = rec.a;                      // 已经是 SDL 编号（1=左）
        ev.mouse_x   = cast(float) rec.b;
        ev.mouse_y   = cast(float) rec.c;
        if kind == WEB_EV_POINTER_DOWN ev.type = .SDL_EVENT_MOUSE_BUTTON_DOWN;
        else                           ev.type = .SDL_EVENT_MOUSE_BUTTON_UP;
        web_push_event(ev);

    } else if kind == WEB_EV_POINTER_MOVE {
        // 移动不排队：桌面端也是每步轮询一次鼠标状态（SDL_GetGlobalMouseState），
        // 而不是消费每个 SDL_EVENT_MOUSE_MOTION。input_web.jai 的 input_update
        // 用 web_mouse_px 算 delta，指针锁定模式下用 web_pointer_delta 累加值。
        web_set_mouse_position(cast(float) rec.a, cast(float) rec.b);
        if rec.c != 0 || rec.d != 0 {
            web_accumulate_pointer_delta(cast(float) rec.c, cast(float) rec.d);
        }

    } else if kind == WEB_EV_WHEEL {
        // JS 侧乘了 100 再取整，这里还原成 SDL 的「行」单位（一格约 1.0）。
        ev: Web_Event;
        ev.window_id = web_main_window_id();
        ev.type      = .SDL_EVENT_MOUSE_WHEEL;
        ev.wheel_x   = cast(float) rec.a / 100.0;
        ev.wheel_y   = cast(float) rec.b / 100.0;
        ev.mouse_x   = cast(float) rec.c;
        ev.mouse_y   = cast(float) rec.d;
        web_push_event(ev);

    } else if kind == WEB_EV_FOCUS || kind == WEB_EV_BLUR {
        web_page_focused = kind == WEB_EV_FOCUS;
        if kind == WEB_EV_BLUR {
            // 浏览器切走时不会再补 keyup：不清就会「粘键」。
            web_release_all_keys();
        }
        ev: Web_Event;
        ev.window_id = web_main_window_id();
        if kind == WEB_EV_FOCUS ev.type = .SDL_EVENT_WINDOW_FOCUS_GAINED;
        else                   ev.type = .SDL_EVENT_WINDOW_FOCUS_LOST;
        web_push_event(ev);

    } else if kind == WEB_EV_VISIBILITY {
        // App.on_event(.ENTER_BACKGROUND / .ENTER_FOREGROUND) 走这条线。
        app_web_on_visibility(rec.a != 0);

    } else if kind == WEB_EV_RESIZE {
        web_resize_total += 1;
        web_window_on_resize(cast(s32) rec.a, cast(s32) rec.b,
                             cast(s32) rec.c, cast(s32) rec.d);

        ev: Web_Event;
        ev.window_id = web_main_window_id();
        ev.type      = .SDL_EVENT_WINDOW_RESIZED;
        web_push_event(ev);

    } else if kind == WEB_EV_TEXT {
        off := web_text_pool_put_codepoint(cast(u32) rec.a);
        if off >= 0 {
            web_dom_text_total += 1;
            ev: Web_Event;
            ev.window_id = web_main_window_id();
            ev.type      = .SDL_EVENT_TEXT_INPUT;
            ev.text_ptr  = *web_text_pool[off];
            ev.text_len  = web_text_pool_used - off - 1;   // 不含 NUL
            web_push_event(ev);
        }
    }
}

// 主窗口 id：web 目标只有一个 canvas，window_create 里发的第一个 id 就是 1。
web_main_window_id :: () -> u32 {
    if App.window != null return App.window.id;
    return 1;
}

//
// Gamepad API
//
// JS 侧快照一张表（每帧一次），这里翻译成 input_connect_controller +
// input_controller_button/axis。映射表在 host.js（W3C standard mapping →
// SDL gamepad 编号），因为那是最贴近 DOM 的一层。
//
// 已知偏差：浏览器只给 `gamepad.mapping == "standard"` 的手柄保证按键布局，
// 其余手柄靠 `id` 猜，接不上就退化成「只有轴」。桌面端的多手柄热插拔语义
// 这里用「每帧 diff」近似：新出现的 index 视为连接，消失的视为断开。
//
WEB_GAMEPAD_MAX         :: 4;     // 同时接线的手柄上限（够用，且省内存）
WEB_GAMEPAD_NAME_MAX    :: 64;
WEB_GAMEPAD_AXES_MAX    :: 8;
WEB_GAMEPAD_BUTTONS_MAX :: 24;

// 布局必须与 host.js 的 writeGamepad() 完全一致：
//   0 connected / 4 index / 8 button_count / 12 axis_count / 16 name_len
//   20 vendor / 24 product / 28 id
//   32 name[64] / 96 axes[8] float32 / 128 buttons[24] u8   → 152 字节
Web_Gamepad_Rec :: struct {
    connected:    s32;
    index:        s32;
    button_count: s32;
    axis_count:   s32;
    name_len:     s32;
    vendor:       s32;
    product:      s32;
    id:           s32;
    name:         [WEB_GAMEPAD_NAME_MAX] u8;
    axes:         [WEB_GAMEPAD_AXES_MAX] float;
    buttons:      [WEB_GAMEPAD_BUTTONS_MAX] u8;
}

web_gamepad_recs: [WEB_GAMEPAD_MAX] Web_Gamepad_Rec;
web_gamepad_connected: [WEB_GAMEPAD_MAX] bool;    // 上一帧的状态，用于 diff
web_gamepad_controller_id: [WEB_GAMEPAD_MAX] Controller_ID;
web_gamepad_prev_buttons: [WEB_GAMEPAD_MAX][WEB_GAMEPAD_BUTTONS_MAX] bool;
web_gamepads_seen: s32;

web_poll_gamepads :: () {
    if App.input == null return;

    count := fw_gamepad_poll(cast(s32) cast(u64) *web_gamepad_recs[0], WEB_GAMEPAD_MAX);
    if count < 0 return;
    if count > WEB_GAMEPAD_MAX count = WEB_GAMEPAD_MAX;

    // 反向遍历：把这一帧没出现的手柄标记为断开。
    for slot: 0..WEB_GAMEPAD_MAX-1 {
        rec := *web_gamepad_recs[slot];
        now_connected := slot < count && rec.connected != 0;

        if web_gamepad_connected[slot] && !now_connected {
            web_gamepad_connected[slot] = false;
            input_disconnect_controller(App.input, web_gamepad_controller_id[slot]);
        } else if !web_gamepad_connected[slot] && now_connected {
            web_gamepad_connected[slot] = true;
            web_gamepads_seen += 1;

            id := cast(Controller_ID) (1000 + rec.index);
            web_gamepad_controller_id[slot] = id;
            for *b: web_gamepad_prev_buttons[slot] b.* = false;

            name := "";
            if rec.name_len > 0 {
                n := rec.name_len;
                if n > WEB_GAMEPAD_NAME_MAX n = WEB_GAMEPAD_NAME_MAX;
                // [64] u8 的运行时切片 -> [] u8 -> string；copy_string 拷到
                // 常驻分配器里（Controller_State.Name 要活过这一帧）。
                name = copy_string(web_str_of(*rec.name[0], n));
            } else {
                name = copy_string("Web Gamepad");
            }

            // 和桌面的 gamepad 分支同一组数字：15 键 / 6 轴，is_gamepad = true。
            input_connect_controller(App.input, id, name, 15, 6, true, .UNKNOWN,
                                     cast(u16) rec.vendor, cast(u16) rec.product, 0);
        }

        if !web_gamepad_connected[slot] continue;

        // 轴：W3C standard 的 0..3 与 SDL 的 LEFTX/LEFTY/RIGHTX/RIGHTY 同序；
        // 扳机由 JS 从 button 6/7 折算到 axis 4/5。
        axis_count := rec.axis_count;
        if axis_count > WEB_GAMEPAD_AXES_MAX axis_count = WEB_GAMEPAD_AXES_MAX;
        for a: 0..axis_count-1 {
            input_controller_axis(App.input, web_gamepad_controller_id[slot], a,
                                  rec.axes[a], App.time.elapsed);
        }

        // 按键：只在边沿上报（down/pressed 状态机自己记着），这样一帧里同一个键
        // 不会因为 120 Hz 的轮询被记成多次 pressed。
        button_count := rec.button_count;
        if button_count > WEB_GAMEPAD_BUTTONS_MAX button_count = WEB_GAMEPAD_BUTTONS_MAX;
        for b: 0..button_count-1 {
            pressed := rec.buttons[b] != 0;
            if pressed == web_gamepad_prev_buttons[slot][b] continue;
            web_gamepad_prev_buttons[slot][b] = pressed;
            input_controller_button(App.input, web_gamepad_controller_id[slot], b,
                                    pressed, App.time.elapsed);
        }
    }
}
