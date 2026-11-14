#scope_module
using Basic;
using Math;
#scope_export

// jfoster — Cursor, web (wasm64) implementation. W2: CSS cursor 真的落地。
//
// Desktop binds the mouse cursor through four SDL entry points
// (SDL_CreateColorCursor / SDL_CreateSystemCursor / SDL_SetCursor /
// SDL_DestroyCursor) which cursor.jai declares itself because it is not allowed
// to touch internal/sdl3. On the web the same job is done by the CSS `cursor`
// property plus, for image cursors, a `url(data:image/png;base64,...) hot_x
// hot_y` value — both of which require a bridge call (W2).
//
// The types and the whole public API are identical to input/cursor.jai so that
// kit code which holds a Cursor keeps compiling. `SDL_Cursor :: void` is repeated
// here because cursor.jai (the only other place that declares it) is desktop-only.

SDL_Cursor :: void;

// Built-in system cursors, a one-to-one mapping of SDL_SystemCursor:
// https://wiki.libsdl.org/SDL3/SDL_SystemCursor
Cursor_System_Types :: enum u32 {
    DEFAULT :: 0;
    TEXT;
    WAIT;
    CROSSHAIR;
    PROGRESS;
    RESIZE_NWSE;
    RESIZE_NESW;
    RESIZE_HORIZONTAL;
    RESIZE_VERTICAL;
    MOVE;
    NOT_ALLOWED;
    POINTER;
    RESIZE_NW;
    RESIZE_N;
    RESIZE_NE;
    RESIZE_E;
    RESIZE_SE;
    RESIZE_S;
    RESIZE_SW;
    RESIZE_W;
}

// Structure representing an OS Mouse Cursor.
// Bind it with window_set_mouse_cursor().
Cursor :: struct {
    // null once destroyed. On the web this is the browser's cursor handle as
    // soon as the CSS `cursor` value has been pushed (W2); until then a Cursor
    // created here is a live, bindable description with a null handle.
    handle: *SDL_Cursor;

    // The Focus Point of the Cursor (where it is considered active).
    FocusPoint: Point2;

    // The Size of the Cursor Image.
    Size: Point2;

    // The System Type used to create this cursor; only meaningful when
    // HasSystemType is true.
    SystemType: Cursor_System_Types;
    HasSystemType: bool;
}

// Creates a new Cursor from an Image.
//
// The desktop version asserts when SDL rejects the surface. There is nothing to
// reject here: an image cursor is a pending description until the canvas CSS
// bridge exists, so the Cursor is returned live-but-unbound instead of killing
// the app (the desktop version's assert exists to catch a bad GPU/format state,
// which has no counterpart on this target).
cursor_create :: (image: Image, focus_point: Point2) -> Cursor {
    c: Cursor;
    c.handle = null;
    c.FocusPoint = focus_point;
    c.Size = .{ image.Width, image.Height };
    c.SystemType = .DEFAULT;
    c.HasSystemType = false;

    // 图像光标的落地方式（W3）：把 Image 像素写进一块离屏 canvas，用
    // canvas.toDataURL() 让 JS 编码成
    //   cursor: url(data:image/png;base64,...) <focus.x> <focus.y>, auto
    // 现在还没有像素管线，所以 handle 保持 null（= 未绑定），见 window_set_mouse_cursor。
    return c;
}

// Creates a new Cursor from a built-in System type.
// Note that FocusPoint and Size are not valid for system cursors.
cursor_create_system :: (type: Cursor_System_Types) -> Cursor {
    c: Cursor;
    c.FocusPoint = Point2_Zero;
    c.Size = Point2_Zero;
    c.SystemType = type;
    c.HasSystemType = true;
    // 系统光标本身是「描述」，绑定到窗口时（window_set_mouse_cursor）才推 CSS，
    // 和桌面端 SDL_CreateSystemCursor 的语义一致：创建不等于生效。
    return c;
}

// Destroys the Cursor's resources.
cursor_destroy :: (c: *Cursor) {
    c.handle = null;
}

// If the Cursor has been destroyed, in which case it can no longer be used.
cursor_disposed :: (c: Cursor) -> bool {
    // Same rule as desktop (null handle == disposed). A Cursor that was never
    // bound yet is therefore reported as disposed, which is the honest answer:
    // the DOM has no cursor object for it to point at.
    return c.handle == null;
}

// The underlying cursor handle (null when destroyed).
cursor_handle :: (c: Cursor) -> *SDL_Cursor {
    return c.handle;
}

// Cursor_System_Types → CSS cursor 关键字。SDL 的枚举和 CSS 的关键字几乎一一
// 对应，所以这是一张纯查表。
web_cursor_css_for_system :: (type: Cursor_System_Types) -> string {
    if type == {
        case .TEXT; return "text";
        case .WAIT; return "wait";
        case .CROSSHAIR; return "crosshair";
        case .PROGRESS; return "progress";
        case .RESIZE_NWSE; return "nwse-resize";
        case .RESIZE_NESW; return "nesw-resize";
        case .RESIZE_HORIZONTAL; return "ew-resize";
        case .RESIZE_VERTICAL; return "ns-resize";
        case .MOVE; return "move";
        case .NOT_ALLOWED; return "not-allowed";
        case .POINTER; return "pointer";
        case .RESIZE_NW; return "nw-resize";
        case .RESIZE_N; return "n-resize";
        case .RESIZE_NE; return "ne-resize";
        case .RESIZE_E; return "e-resize";
        case .RESIZE_SE; return "se-resize";
        case .RESIZE_S; return "s-resize";
        case .RESIZE_SW; return "sw-resize";
        case .RESIZE_W; return "w-resize";
    }
    return "default";
}

// 把 Cursor 描述翻译成 canvas.style.cursor 的值。
//
// 图像光标需要把 Image 编码成 data URL —— 那要 PNG 编码器（stb 是原生库，
// wasm 下没有），所以图像光标暂时只落到「焦点提示不生效」这一步：返回默认值并
// 记一条一次性的警告，而不是假装成功。W3 顺手可以用 canvas.toDataURL() 让 JS
// 侧编码（Jai 把像素写进 canvas 就行），那时这里再加一条桥导入。
web_cursor_apply :: (cursor: *Cursor) -> s32 {
    if cursor == null {
        return web_set_cursor_css("default");
    }

    if cursor.HasSystemType {
        return web_set_cursor_css(web_cursor_css_for_system(cursor.SystemType));
    }

    if !web_cursor_image_warned {
        web_cursor_image_warned = true;
        log_warning("window_set_mouse_cursor: 图像光标在 web 目标下还做不到（需要 PNG 编码；W3 用 canvas.toDataURL 交给 JS 编码），已退回 default");
    }
    return web_set_cursor_css("default");
}

web_cursor_image_warned: bool;

// Binds a Cursor to the Window (null, or a destroyed cursor, restores the
// default cursor).
window_set_mouse_cursor :: (w: *Window, cursor: *Cursor) {
    if w == null || w.handle == null return;
    if web_cursor_apply(cursor) < 0 {
        log_warning("window_set_mouse_cursor: 宿主拒绝设置 CSS cursor");
    }
}
