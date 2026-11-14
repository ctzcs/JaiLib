#scope_module
using Basic; // module-private
using Math;
#scope_export

// jfoster — Window, web (wasm64) implementation. W2: DOM 接线完成。
//
// ===========================================================================
// What this is
// ===========================================================================
// `window.jai` 是 Foster Window.cs 的逐行移植，44 个过程全是 SDL 胶水：一个
// getter 就是 SDL_GetWindowSize，一个 setter 就是 SDL_SetWindowFullscreen。
// 没有可复用的部分，所以 web 目标走平行实现而不是每个过程一个 #if。module.jai
// 二选一：
//
//     #if OS != .WASM { #load "window.jai"; } else { #load "internal/web/window_web.jai"; }
//
// **每个公开名字都和桌面版同名同签名**（`Window` / `window_size` /
// `window_set_fullscreen` / ...），`Window` 的字段名与顺序也一致。这是整个
// 平台隔离的前提：kit 层（JaiLib）不该出现一个 `#if`。
//
// ===========================================================================
// 一个 web "窗口" 就是页面上的那个 canvas
// ===========================================================================
// 两种尺寸，别混：
//   * CSS 像素  —— window_size() 报的、鼠标坐标用的（等于桌面的「窗口像素」）
//   * 设备像素  —— canvas 的 backing store，W3 的 WebGL2 视口用它
//                  （window_size_in_pixels() / fw_canvas_size）
// 比值就是 devicePixelRatio（window_content_scale / web_pixel_ratio）。
//
// W2 之后真的有东西落到 DOM 上了：
//   window_set_title            → document.title           (fw_set_title)
//   window_set_fullscreen       → requestFullscreen         (fw_request_fullscreen)
//   window_set_mouse_cursor     → canvas.style.cursor       (fw_set_cursor_css)
//   window_set_mouse_relative   → requestPointerLock        (fw_mouse_relative)
//   window_start_text_input     → 隐藏 <input> 显示 + 定位   (fw_text_input_area)
//   window_set_text_input_area  → 同上，[L-022] 的 IME 锚点
// 仍然做不到的（浏览器不给，不是我们懒）：
//   window_set_position / window_set_size —— canvas 的布局归宿主页的 CSS 管；
//   值会被记住并如实回报，但不会去改宿主页的样式表。
//
// ===========================================================================

Window :: struct {
    // `SDL_Window :: void` in the bindings, so this is the same `*void` on both
    // targets and `w.handle != null` keeps the meaning it has on desktop
    // ("this window has not been destroyed yet").
    handle: *SDL_Window; // null once destroyed
    id: u32;
    title: string;
    is_destroyed: bool;

    // callbacks (Foster: OnFocusGain etc.)
    on_focus_gain: () = null;
    on_focus_lost: () = null;
    on_mouse_enter: () = null;
    on_mouse_leave: () = null;
    on_resize: () = null;
    on_restore: () = null;
    on_maximize: () = null;
    on_minimize: () = null;
    on_fullscreen_enter: () = null;
    on_fullscreen_exit: () = null;

    // If null when close is requested: App.Exit() on the main window,
    // window_destroy() on any other window. (Foster: OnCloseRequested)
    on_close_requested: () = null;

    // ---- web-only state (not present on desktop; additive, so kit code that
    // only reads the fields above is unaffected) ----
    web_size: Point2; // CSS 像素：window_size() 报的就是它
    web_pixel_size: Point2; // canvas backing store（设备像素）
    web_position: Point2; // 恒为 0,0：canvas 就是视口
    web_fullscreen: bool;
    web_resizable: bool = true;
    web_text_input: bool;
    web_mouse_relative: bool;
    web_text_area: Rect; // [L-022] 最近一次请求的 IME 锚点（CSS 像素）
    web_has_text_area: bool;
}

//
// Web-side globals
//
// 单线程：这些就是 DOM 灌进来的值。web_pixel_ratio 是 CSS → 设备像素的比例，
// 相当于桌面的 SDL_GetWindowDisplayScale。
//
web_pixel_ratio: float = 1.0;
web_page_focused: bool = true;
web_mouse_px: Vector2; // 最后一次已知鼠标位置（CSS 像素）
web_mouse_inside: bool = true; // pointerleave/enter 用于 mouse enter/leave 事件
web_window_serial: u32 = 1;

window_create :: (title: string, width: s32, height: s32, fullscreen := false, resizable := true) -> *Window {
    w := New(Window);
    w.title = title;
    w.web_size = .{ width, height };
    w.web_resizable = resizable;
    w.web_fullscreen = fullscreen;
    w.id = web_window_serial;
    web_window_serial += 1;

    // A `*SDL_Window` is a `*void`; application code only ever compares it to
    // null, so a pointer to the Window's own web state is a fine stand-in and
    // keeps `handle != null` true for exactly as long as the window lives.
    w.handle = cast(*SDL_Window) w;

    app_window_created(w);

    // 画布的尺寸以宿主页为准：配置里的 width/height 只在没有 canvas 时兜底。
    web_window_sync_from_canvas(w);

    // 标题与全屏是 DOM 侧的副作用，创建时就落地一次（和 SDL_CreateWindow 一致）。
    window_apply_title(w);
    if fullscreen web_request_fullscreen(true);

    return w;
}

// 从桥读 canvas 尺寸 / devicePixelRatio，写进 window 与全局 web_pixel_ratio。
// boot 和 resize 都走这一个入口，保证两条路径不会算出不同的值。
web_window_sync_from_canvas :: (w: *Window) {
    device_w, device_h := web_canvas_size();

    ratio := web_pixel_ratio;
    w.web_pixel_size = .{ device_w, device_h };

    if device_w > 0 && device_h > 0 {
        css_w := cast(s32) (cast(float) device_w / ratio + 0.5);
        css_h := cast(s32) (cast(float) device_h / ratio + 0.5);
        if css_w > 0 && css_h > 0 {
            w.web_size = .{ css_w, css_h };
        }
    }
}

// resize 事件：JS 直接把两套尺寸都算好送过来（CSS + 设备），免掉一次除法误差。
web_window_on_resize :: (css_w: s32, css_h: s32, device_w: s32, device_h: s32) {
    w := App.window;
    if w == null return;

    if css_w > 0 && css_h > 0 w.web_size = .{ css_w, css_h };
    if device_w > 0 && device_h > 0 w.web_pixel_size = .{ device_w, device_h };
    else w.web_pixel_size = .{ css_w, css_h };
}

// 启动时做一次：像素比 + 尺寸。fw_boot 里调（canvas 已经存在）。
web_window_boot :: () {
    web_pixel_ratio = cast(float) web_query_pixel_ratio();

    // 每次 boot 都重置鼠标位置与焦点：页面刚加载时鼠标可能在别处。
    web_mouse_px = .{};
    web_page_focused = true;

    if App.window != null web_window_sync_from_canvas(App.window);
}

// Destroys the Window. If this is the main App window, this calls app_exit().
window_destroy :: (w: *Window) {
    if !w.is_destroyed {
        app_window_marked_for_destruction(w);
        if App.window == w app_exit();
        w.is_destroyed = true;
    }
}

window_title :: (w: *Window) -> string {
    return w.title;
}

window_set_title :: (w: *Window, title: string) {
    if w.title == title return;
    w.title = title;
    // Desktop queues this through app_run_on_main_thread only because the OS
    // window belongs to the main thread; there is one thread here.
    window_apply_title(w);
}

Title_Action :: struct {
    w: *Window;
    title: string;
}

// Kept for API parity with window.jai: the desktop version exists because
// window_set_title can be called from a worker. It is still reachable from code
// that was written against the desktop API, so the name and signature stay.
window_apply_title_action :: (data: *void) {
    action := cast(*Title_Action) data;
    action.w.title = action.title;
    window_apply_title(action.w);
    free(action);
}

window_position :: (w: *Window) -> Point2 {
    if w.handle == null return Point2_Zero; // closed: desktop asserts, web degrades
    return w.web_position;
}

window_set_position :: (w: *Window, position: Point2) {
    if w.handle == null return;
    w.web_position = position;
    // canvas 由宿主页的 CSS 定位，我们不能改它的布局；记住值让 getter 自洽。
    // 不打日志：每帧调一次会刷屏，而且这不是一个「会失败的操作」。
}

window_size :: (w: *Window) -> Point2 {
    if w.handle == null return Point2_Zero;
    return w.web_size;
}

window_set_size :: (w: *Window, size: Point2) {
    if w.handle == null return;
    // 不能真的改宿主页的 canvas 样式（那是页面的 CSS），但 getter 要自洽，
    // 所以记下来。再次 resize 时 DOM 的真实值会覆盖它。
    w.web_size = size;
}

window_width :: (w: *Window) -> s32 {
    return window_size(w).x;
}

window_height :: (w: *Window) -> s32 {
    return window_size(w).y;
}

window_set_width :: (w: *Window, width: s32) {
    s := window_size(w);
    window_set_size(w, .{ width, s.y });
}

window_set_height :: (w: *Window, height: s32) {
    s := window_size(w);
    window_set_size(w, .{ s.x, height });
}

// Render-target pixels: the canvas backing-store size, straight from the bridge
// (host.js writes the real width/height). Returns 0,0 when there is no canvas,
// which is exactly what the bridge reports outside a browser.
//
// **W3 的 WebGL2 视口必须用这个，不是 window_size()。**
window_size_in_pixels :: (w: *Window) -> Point2 {
    if w.handle == null return Point2_Zero;
    if w.web_pixel_size.x > 0 && w.web_pixel_size.y > 0 return w.web_pixel_size;
    width, height := web_canvas_size();
    return .{ width, height };
}

window_width_in_pixels :: (w: *Window) -> s32 {
    return window_size_in_pixels(w).x;
}

window_height_in_pixels :: (w: *Window) -> s32 {
    return window_size_in_pixels(w).y;
}

// Size of the display the window is currently in: the browser viewport, which
// the DOM reports through the resize handler (canvas 通常就铺满视口)。
window_display_size :: (w: *Window) -> Point2 {
    if w.handle == null return Point2_Zero;
    return window_size_in_pixels(w);
}

window_content_scale :: (w: *Window) -> Vector2 {
    ratio := web_pixel_ratio;
    if ratio <= 0 ratio = 1.0; // never hand the renderer a 0 scale
    return .{ ratio, ratio };
}

// Mouse position relative to the window, in CSS pixel coordinates — same meaning
// as the desktop version (window pixel coordinates). web_mouse_px 由
// web_events.jai 的 pointer 处理器维护。
window_mouse_position :: (w: *Window) -> Vector2 {
    if w.handle == null return .{};
    return web_mouse_px;
}

window_fullscreen :: (w: *Window) -> bool {
    if w.handle == null return false;
    return w.web_fullscreen;
}

window_set_fullscreen :: (w: *Window, fullscreen: bool) {
    if w.handle == null return;
    if w.web_fullscreen == fullscreen return;
    w.web_fullscreen = fullscreen;

    if web_request_fullscreen(fullscreen) < 0 {
        log_warning("window_set_fullscreen: 宿主拒绝了 fullscreen 请求（浏览器要求用户手势）");
    }
    // 真正的 fullscreenchange 会作为 DOM 事件回来，由 web_events.jai 转成
    // SDL_EVENT_WINDOW_ENTER_FULLSCREEN / LEAVE_FULLSCREEN 再触发回调；这里不
    // 直接调 on_fullscreen_enter，免得和浏览器的事件重复触发两次。
}

window_resizable :: (w: *Window) -> bool {
    if w.handle == null return false;
    return w.web_resizable;
}

window_set_resizable :: (w: *Window, resizable: bool) {
    if w.handle == null return;
    w.web_resizable = resizable;
    // 真实行为：宿主页的 canvas CSS 规则决定它是否随视口变化，没有 API 可设。
}

window_maximized :: (w: *Window) -> bool {
    // 浏览器里没有「最大化」这个窗口状态；全屏是唯一可比的东西，它有自己的标志。
    return false;
}

window_set_maximized :: (w: *Window, maximized: bool) {
    if w.handle == null return;
    // 无操作是诚实答案：canvas 的布局归 CSS。
}

// Sets whether the mouse is in Relative Mode.
window_set_mouse_relative_mode :: (w: *Window, enabled: bool) {
    if w.handle == null return;
    if w.web_mouse_relative == enabled return;
    w.web_mouse_relative = enabled;

    if web_set_mouse_relative(enabled) < 0 {
        log_warning("window_set_mouse_relative_mode: 指针锁定被拒（需要用户手势 / 已退出锁定）");
    }
}

// Sets the mouse position within the window, in pixel coordinates.
window_set_mouse_position :: (w: *Window, position: Vector2) {
    if w.handle == null return;
    // A web page cannot move the OS cursor. Tracking it keeps mouse_position()
    // coherent within the app; the real cursor never moves.
    web_mouse_px = position;
}

// Enables/disables text input for this window (populates KeyboardState.text).
window_set_text_input :: (w: *Window, enabled: bool) {
    if enabled window_start_text_input(w);
    else window_stop_text_input(w);
}

// 文本输入要一个真正可聚焦的 DOM 元素：键盘事件在 canvas 上，但 IME（中文、
// 日文、表情面板）和移动端软键盘只对 <input>/<textarea> 生效。host.js 有这么一个
// 隐藏 input，这里只是开关 + 定位。
window_start_text_input :: (w: *Window) {
    if w.handle == null return;
    w.web_text_input = true;
    web_push_text_input_area(w);
}

window_stop_text_input :: (w: *Window) {
    if w.handle == null return;
    w.web_text_input = false;
    web_set_text_input_area(0, 0, 0, 0, false);
}

window_start_text_input_mt :: (data: *void) {
    window_start_text_input(cast(*Window) data);
}

window_stop_text_input_mt :: (data: *void) {
    window_stop_text_input(cast(*Window) data);
}

// [olib L-022] IME 锚点：把隐藏 input 摆到 rect 处，浏览器据此决定候选窗口的
// 位置（以及移动端软键盘不遮挡输入区）。rect 用 CSS 像素，和 window_size 同一
// 坐标系。
//
// 返回值：桥真的应用了才返回 true。桌面版在 SDL 拒绝时也返回 false，语义一致。
window_set_text_input_area :: (w: *Window, rect: Rect) -> bool {
    if w == null || w.handle == null return false;

    w.web_text_area = rect;
    w.web_has_text_area = true;

    if !w.web_text_input {
        // 不在文本输入状态时仍然记住锚点：下次 start_text_input 直接用它。
        return true;
    }

    x := cast(s32) rect.x;
    y := cast(s32) rect.y;
    width := cast(s32) rect.w;
    height := cast(s32) rect.h;
    if width < 1 width = 1;
    if height < 1 height = 1;

    return web_set_text_input_area(x, y, width, height, true) >= 0;
}

web_push_text_input_area :: (w: *Window) {
    if w.web_has_text_area {
        window_set_text_input_area(w, w.web_text_area);
    } else {
        // 没设过锚点：贴在 canvas 左上角，至少让 IME 窗口不会飘到屏幕外。
        window_set_text_input_area(w, Rect.{ 0, 0, 8, 8 });
    }
}

window_focus :: (w: *Window) {
    if w.handle == null return;
    // 浏览器的 window.focus() 多数情况下被忽略（标签页切换由用户决定），
    // 所以这里只改本地状态，让 window_focused() 立刻自洽。
    web_page_focused = true;
}

//
// internal
//
// Callback dispatch. Desktop receives SDL_EventType values from app_poll_events;
// the web side receives the same enum values from web_events.jai (blur ->
// SDL_EVENT_WINDOW_FOCUS_LOST, resize -> SDL_EVENT_WINDOW_RESIZED, ...), so the
// switch is identical.
window_on_event :: (w: *Window, ev: SDL_EventType) {
    if ev == {
        case .SDL_EVENT_WINDOW_FOCUS_GAINED;
            if w.on_focus_gain != null w.on_focus_gain();
        case .SDL_EVENT_WINDOW_FOCUS_LOST;
            if w.on_focus_lost != null w.on_focus_lost();
        case .SDL_EVENT_WINDOW_MOUSE_ENTER;
            if w.on_mouse_enter != null w.on_mouse_enter();
        case .SDL_EVENT_WINDOW_MOUSE_LEAVE;
            if w.on_mouse_leave != null w.on_mouse_leave();
        case .SDL_EVENT_WINDOW_RESIZED;
            if w.on_resize != null w.on_resize();
        case .SDL_EVENT_WINDOW_RESTORED;
            if w.on_restore != null w.on_restore();
        case .SDL_EVENT_WINDOW_MAXIMIZED;
            if w.on_maximize != null w.on_maximize();
        case .SDL_EVENT_WINDOW_MINIMIZED;
            if w.on_minimize != null w.on_minimize();
        case .SDL_EVENT_WINDOW_ENTER_FULLSCREEN;
            if w.on_fullscreen_enter != null w.on_fullscreen_enter();
        case .SDL_EVENT_WINDOW_LEAVE_FULLSCREEN;
            if w.on_fullscreen_exit != null w.on_fullscreen_exit();
        case .SDL_EVENT_WINDOW_CLOSE_REQUESTED;
            if w.on_close_requested != null {
                w.on_close_requested();
            } else if App.window == w {
                app_exit();
            } else {
                window_destroy(w);
            }
    }
}

// The canvas is always "shown"; there is no window to hide. Kept because the DOM
// equivalent (canvas.style.display) is what a future W could flip here.
window_show :: (w: *Window) {
    if w.handle == null return;
    web_page_focused = true;
}

window_hide :: (w: *Window) {
    if w.handle == null return;
    web_page_focused = false;
}

window_destroyed :: (w: *Window) {
    w.handle = null;
}

window_apply_title :: (w: *Window) {
    if w.handle == null return;
    if w.title.count <= 0 return;
    web_set_title(w.title);
}
