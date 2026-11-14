using Basic;
using Math;
using Hash_Table;

// jfoster — Input, web (wasm64) implementation. W2: DOM 事件与 Gamepad 接线完成.
//
// ===========================================================================
// Same state machines, different provider
// ===========================================================================
// Foster splits Input in two: the state machines (states.jai, sets.jai,
// virtual.jai, bindings.jai — all portable, all shared with desktop) and the
// provider that turns OS events into calls on them. `input.jai` is the SDL
// provider: it owns an `SDL_Event` loop and reads ev.key.scancode / ev.wheel /
// ev.jbutton. That is the only part that cannot exist on wasm, so it is the only
// part that is replaced here.
//
// Every public name from input.jai is present with the same signature — except
// `input_on_event`, whose parameter is SDL's event struct and therefore becomes
// the bridge's own `Web_Event` (nothing outside App calls it; the App.poll
// equivalent is app_web.jai's app_poll_events).
//
// ===========================================================================
// The queue (W2: 真的有东西进来了)
// ===========================================================================
//   DOM                       host.js                       Jai
//   keydown   → 事件队列(JS)  → fw_dom_event_push(kind=1)  → web_drain_dom_events
//                                                             ↓ 翻译
//                                                            web_pending_events
//                                                             ↓ web_poll_events
//                                                            app_poll_events
//                                                             ↓
//                                                        input_on_web_event
//                                                             ↓
//                                             input_key / input_mouse_* / input_text
//
// 键盘的 DOM `event.code` → SDL scancode 查表在 **host.js**（那是浏览器侧最贴近
// 的一层，而且是一张纯数据表）。Jai 侧收到的已经是 SDL scancode，所以
// `key_from_sdl`（input/enums.jai）一行都不用改。
//
// 鼠标位置是 **CSS 像素**（和 window_size / 桌面端的窗口坐标同一单位）；
// canvas backing store 的设备像素只在 W3 的 WebGL2 视口里用。

Input :: struct {
    State: Input_State; // current
    LastState: Input_State; // previous
    NextState: Input_State; // accumulating

    Enabled: Input_Enabled_Flags = .ALL;

    on_text_event: (text: string, window: *Window) = null;
    on_controller_connected: (id: Controller_ID) = null;
    on_controller_disconnected: (id: Controller_ID) = null;

    // provider internals
    last_mouse: Vector2;
    // Same shape as desktop so nothing that walks these breaks; the web side has
    // no joystick backend yet (Gamepad API is W2), so both stay empty.
    open_joysticks: [..] struct {
        id: u32;
        ptr: *SDL_Joystick;
    };
    open_gamepads: [..] struct {
        id: u32;
        ptr: *SDL_Gamepad;
    };
}

//
// The bridge event
//
// A flat, JS-friendly mirror of the SDL_Event fields input.jai actually reads.
// The DOM side fills it in W2; the JS -> scancode mapping lives there (it is a
// lookup table, not engine logic) so `key_from_sdl` in input/enums.jai keeps
// working unchanged: DOM KeyboardEvent.code -> SDL scancode -> Keys.
//
Web_Event :: struct {
    type: SDL_EventType;
    window_id: u32;

    // key
    scancode: u32;
    repeat: bool;

    // mouse
    button: s32; // SDL_BUTTON_LEFT / ... (already in SDL numbering)
    wheel_x: float;
    wheel_y: float;
    mouse_x: float; // device pixels, canvas-relative
    mouse_y: float;

    // text input (UTF-8, owned by the caller until the queue is drained)
    text_ptr: *u8;
    text_len: s32;
}

web_pending_events: [..] Web_Event;
web_drained_events: [..] Web_Event;

// Called by web_events.jai 的翻译层。顺序保留，于是 App.update 看到的事件顺序与
// 浏览器派发顺序一致（和桌面的 SDL_PollEvent 语义对齐）。
web_push_event :: (ev: Web_Event) {
    array_add(*web_pending_events, ev);
}

// 相对模式（pointer lock）下的累计位移。DOM 的 movementX/movementY 在
// web_events.jai 里累加，input_update 每步取走清零 —— 和桌面端「每步读一次
// SDL_GetRelativeMouseState」是同一个语义。
web_pointer_delta: Vector2;

web_accumulate_pointer_delta :: (dx: float, dy: float) {
    web_pointer_delta += .{ dx, dy };
}

web_take_pointer_delta :: () -> Vector2 {
    d := web_pointer_delta;
    web_pointer_delta = .{};
    return d;
}

// Drains what has accumulated. Called once per frame from app_poll_events.
//
// 顺序：先把 DOM 队列拉空（fw_dom_event_push 循环），再顺带轮询 Gamepad API，
// 最后把攒下的事件交出去。这样 app_poll_events 里的事件顺序 == 浏览器顺序。
web_poll_events :: () -> [] Web_Event {
    web_drain_dom_events();
    web_poll_gamepads();

    array_reset(*web_drained_events);
    for e: web_pending_events array_add(*web_drained_events, e);
    array_reset(*web_pending_events);
    return web_drained_events;
}

input_create :: () -> *Input {
    i := New(Input);
    for *c, idx: i.State.Controllers c.Index = cast(s32) idx;
    for *c, idx: i.LastState.Controllers c.Index = cast(s32) idx;
    for *c, idx: i.NextState.Controllers c.Index = cast(s32) idx;
    return i;
}

input_destroy :: (i: *Input) {
    free(i);
}

// convenience accessors on the CURRENT state
input_keyboard :: (i: *Input) -> *Keyboard_State {
    return *i.State.Keyboard;
}

input_mouse :: (i: *Input) -> *Mouse_State {
    return *i.State.Mouse;
}

input_controllers :: (i: *Input) -> [] Controller_State {
    return i.State.Controllers;
}

input_get_controller :: (i: *Input, id: Controller_ID) -> *Controller_State {
    return input_state_get_controller(*i.State, id);
}

input_clear :: (i: *Input) {
    input_state_clear(*i.State);
    input_state_clear(*i.NextState);
}

// Clipboard: navigator.clipboard 是异步的，而 wasm 导出是同步的，所以桥做成
// 「写：立即写 DOM + 本地缓存；读：读本地缓存」。host.js 在 boot 时和每次
// window focus 时在后台 readText() 刷新缓存，于是 get 拿到的通常是系统剪贴板
// 的最新内容，但**同一帧内刚被别的程序改过的内容读不到** —— 这是 sync/async
// 边界的硬限制，不是实现偷懒。
WEB_CLIPBOARD_BUF :: 4096;

web_clipboard_buf: [WEB_CLIPBOARD_BUF] u8;
web_clipboard_text: string; // 本地镜像（write 之后就等于刚写进去的内容）

input_clipboard_set :: (i: *Input, value: string) {
    web_clipboard_text = copy_string(value);
    if value.count <= 0 return;
    if fw_clipboard_set(web_str_off(value), cast(s32) value.count) < 0 {
        log_warning("input_clipboard_set: 浏览器拒绝写剪贴板（需要用户手势 / 权限）");
    }
}

input_clipboard_get :: (i: *Input) -> string {
    n := fw_clipboard_get(cast(s32) cast(u64) *web_clipboard_buf[0], WEB_CLIPBOARD_BUF - 1);
    if n > 0 {
        if n > WEB_CLIPBOARD_BUF - 1 n = WEB_CLIPBOARD_BUF - 1;
        web_clipboard_buf[n] = 0;
        web_clipboard_text = copy_string(web_str_of(*web_clipboard_buf[0], n));
    }
    return web_clipboard_text;
}

// Gamepad rumble: the Web Gamepad API's `GamepadHapticActuator` is the
// equivalent. No device can be connected yet, so this returns before touching
// anything — the desktop version also returns early when the controller is not
// connected.
input_rumble :: (i: *Input, id: Controller_ID, low_intensity: float, high_intensity: float, duration: float) {
    it := input_get_controller(i, id);
    if it == null || !it.Connected return;

    // W3: Gamepad API 的 vibrationActuator.playEffect 也要走桥（要再加一条
    // fw_gamepad_rumble 导入）。现在 **不做**：Chrome 的 dual-rumble 只在部分
    // 手柄 + 用户手势后才生效，而少一条导入比多一条假成功的导入诚实。
    // 桌面版在这里会调 SDL_RumbleGamepad。
}

// 焦点丢失时清掉所有按下的键。
//
// 浏览器在标签页失去焦点后不会再补 keyup，所以不清就会出现「角色一直往前走」
// 这种经典 bug。桌面端 SDL 在 WILL_ENTER_BACKGROUND 时做同样的事。
//
// 注意：只清 down/pressed/released 的当前值，不产生 released 事件 —— 否则
// 一帧之内会给每个键都报一次 released（64 个假事件）。
web_release_keyboard_state :: (k: *Keyboard_State) {
    for *d: k.down d.* = false;
    for *p: k.pressed p.* = false;
    for *r: k.released r.* = false;
}

web_release_mouse_state :: (m: *Mouse_State) {
    for *d: m.down d.* = false;
    for *p: m.pressed p.* = false;
    for *r: m.released r.* = false;
}

web_release_all_keys :: () {
    i := App.input;
    if i == null return;

    web_release_keyboard_state(*i.NextState.Keyboard);
    web_release_keyboard_state(*i.State.Keyboard);
    web_release_keyboard_state(*i.LastState.Keyboard);

    web_release_mouse_state(*i.NextState.Mouse);
    web_release_mouse_state(*i.State.Mouse);
    web_release_mouse_state(*i.LastState.Mouse);
}

// called by App.step — advances the state buffers
input_update :: (i: *Input, time: Time) {
    // Mouse position/delta follows the window each step, exactly like desktop.
    // web_mouse_px is maintained by the DOM pointer handlers (W2) and by
    // window_set_mouse_position, so this stays a pure read.
    if App.window != null && App.window.handle != null {
        mouse := window_mouse_position(App.window);

        if App.window.web_mouse_relative {
            // 指针锁定：位置被浏览器钉在中心（我们拿不到真实的 clientX/Y 变化），
            // 真正的位移在 each pointermove 的 movementX/movementY 里，由
            // web_events.jai 累计，这里一次取走。
            delta := web_take_pointer_delta();
            i.last_mouse = mouse;
            if delta.x != 0 || delta.y != 0 {
                input_mouse_motion(i, mouse, delta, time.elapsed);
            }
        } else {
            delta := mouse - i.last_mouse;
            if i.last_mouse.x != mouse.x || i.last_mouse.y != mouse.y {
                i.last_mouse = mouse;
                input_mouse_motion(i, mouse, delta, time.elapsed);
            }
        }
    } else {
        // 没有窗口时也要把累计量清掉，否则重新连上窗口会吐出一次陈旧的位移。
        web_take_pointer_delta();
    }

    // step the triple buffer
    input_state_copy(*i.State, *i.LastState);
    input_state_copy(*i.NextState, *i.State);
    input_state_step(*i.NextState, time);

    // virtual inputs — same call, same position in the frame as input.jai
    virtual_inputs_update(i, time);
}

input_close_devices :: (i: *Input) {
    // Nothing is held open; resetting keeps the arrays clean for a restart.
    array_reset(*i.open_joysticks);
    array_reset(*i.open_gamepads);
}

//
// event feed (called from the drain loop in app_web.jai)
//

input_text :: (i: *Input, text: string, window: *Window) {
    if (i.Enabled & .TEXT) != 0 {
        SB.append(*i.NextState.Keyboard.Text, text);
    }
    if i.on_text_event != null i.on_text_event(text, window);
}

input_key :: (i: *Input, key_index: s32, key_pressed: bool, elapsed: float64) {
    if (i.Enabled & .KEYBOARD_KEYS) != 0 {
        keyboard_state_on_key(*i.NextState.Keyboard, key_index, key_pressed, elapsed);
    }
}

input_mouse_button :: (i: *Input, button_index: s32, button_pressed: bool, elapsed: float64) {
    if (i.Enabled & .MOUSE_BUTTONS) != 0 {
        mouse_state_on_button(*i.NextState.Mouse, button_index, button_pressed, elapsed);
    }
}

input_mouse_motion :: (i: *Input, position: Vector2, delta: Vector2, elapsed: float64) {
    if (i.Enabled & .MOUSE_MOTION) != 0 {
        mouse_state_on_motion(*i.NextState.Mouse, position, delta, elapsed);
    }
}

input_mouse_wheel :: (i: *Input, value: Vector2) {
    if (i.Enabled & .MOUSE_WHEEL) != 0 {
        mouse_state_on_wheel(*i.NextState.Mouse, value);
    }
}

input_connect_controller :: (i: *Input, id: Controller_ID, name: string,
                             button_count: s32, axis_count: s32, is_gamepad: bool,
                             gamepad_type: Gamepad_Types, vendor: u16, product: u16, version: u16) {
    for *c, idx: i.NextState.Controllers {
        if c.Connected continue;
        controller_state_connect(c, id, name, button_count, axis_count, is_gamepad,
                                 gamepad_type, vendor, product, version);
        virtual_inputs_notify_controller_connected(i, cast(s32) idx);
        if i.on_controller_connected != null i.on_controller_connected(id);
        return;
    }
}

input_disconnect_controller :: (i: *Input, id: Controller_ID) {
    for *c, idx: i.NextState.Controllers {
        if c.ID != id continue;
        c.Connected = false;
        virtual_inputs_notify_controller_disconnected(i, cast(s32) idx);
        if i.on_controller_disconnected != null i.on_controller_disconnected(id);
    }
}

input_controller_button :: (i: *Input, id: Controller_ID, button: s32, pressed: bool, elapsed: float64) {
    if (i.Enabled & .CONTROLLER_BUTTONS) == 0 return;
    c := input_state_get_controller(*i.NextState, id);
    if c != null controller_state_on_button(c, button, pressed, elapsed);
}

input_controller_axis :: (i: *Input, id: Controller_ID, axis: s32, value: float, elapsed: float64) {
    if (i.Enabled & .CONTROLLER_AXIS) == 0 return;
    c := input_state_get_controller(*i.NextState, id);
    if c != null controller_state_on_axis(c, axis, value, elapsed);
}

//
// web event dispatch — the `InputProviderSDL.OnEvent` port
//
// Same body as input_on_event in input.jai, reading Web_Event instead of
// SDL_Event and dropping the joystick/gamepad branches (no backend yet; the
// Gamepad API arrives in W2 and will plug in through input_connect_controller,
// which is already here).
//
input_on_web_event :: (i: *Input, ev: Web_Event) {
    t := ev.type;

    if t == .SDL_EVENT_MOUSE_BUTTON_DOWN {
        input_mouse_button(i, cast(s32) mouse_button_from_sdl(cast(u8) ev.button), true, App.time.elapsed);
    } else if t == .SDL_EVENT_MOUSE_BUTTON_UP {
        input_mouse_button(i, cast(s32) mouse_button_from_sdl(cast(u8) ev.button), false, App.time.elapsed);
    } else if t == .SDL_EVENT_MOUSE_WHEEL {
        input_mouse_wheel(i, .{ ev.wheel_x, ev.wheel_y });
    } else if t == .SDL_EVENT_KEY_DOWN {
        if !ev.repeat input_key(i, cast(s32) key_from_sdl(cast(SDL_Scancode) ev.scancode), true, App.time.elapsed);
    } else if t == .SDL_EVENT_KEY_UP {
        if !ev.repeat input_key(i, cast(s32) key_from_sdl(cast(SDL_Scancode) ev.scancode), false, App.time.elapsed);
    } else if t == .SDL_EVENT_TEXT_INPUT {
        if ev.text_ptr != null && ev.text_len > 0 {
            // web_events.jai 的文本池给每一个码点都补了 NUL，所以这里可以按
            // C 字符串读（一帧里多个码点各自 NUL 结尾，互不干扰）。
            input_text(i, cstr_to_string(ev.text_ptr), App.window);
        }
    }
}

// Mouse motion is not an SDL_EventType in the queue above: the DOM reports it on
// every pointermove, i.e. far more often than once per frame, and the desktop
// path derives it from SDL_GetGlobalMouseState once per step. input_update does
// the same here, so the bridge only has to keep web_mouse_px current.
web_set_mouse_position :: (x: float, y: float) {
    web_mouse_px = .{ x, y };
}
