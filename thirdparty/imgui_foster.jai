// imgui_foster.jai
// Dear ImGui backend for jfoster (SDL3 + SDL_GPU) — replaces imgui_raylib.jai.
//
// Input: jfoster Input (keyboard incl. keymap + text via Keyboard_State.Text,
// mouse position/delta/wheel, focus, clipboard). Rendering: ImGui DrawData is
// appended to the game's shared Batcher as raw triangles (ImDrawVert maps
// 1:1 onto Batcher_Vertex); each ImDrawCmd clips through the batcher's
// scissor stack (top-left pixel space, no GL-style y flip).
//
// Frame shape (called by the app shell):
//     imgui_foster_setup()
//     imgui_foster_process_input()          // every App.update step
//     imgui_foster_new_frame()              // every render frame, before widgets
//     ... imgui widgets ...
//     imgui_foster_render(batcher, target)  // appends triangles; the shell
//                                           // submits ONE batcher_render after
//     imgui_foster_shutdown()

#import "Basic";
#import "ImGui";

IMGF :: #import "jfoster";   // 独特别名：gfx.jai 也导出 F，非命名空间导入会冲突

imgui_dll :: #system_library "imgui";

// ---- ImGui procs the Jai module cannot call as members (rebound, same set
// ---- as the retired imgui_raylib backend).

IO_AddKeyEvent :: (this: *IO, key: Key, down: bool) #cpp_method #foreign imgui_dll "?AddKeyEvent@ImGuiIO@@QEAAXW4ImGuiKey@@_N@Z";
IO_AddMousePosEvent :: (this: *IO, x: float, y: float) #cpp_method #foreign imgui_dll "?AddMousePosEvent@ImGuiIO@@QEAAXMM@Z";
IO_AddMouseButtonEvent :: (this: *IO, button: s32, down: bool) #cpp_method #foreign imgui_dll "?AddMouseButtonEvent@ImGuiIO@@QEAAXH_N@Z";
IO_AddMouseWheelEvent :: (this: *IO, wheel_x: float, wheel_y: float) #cpp_method #foreign imgui_dll "?AddMouseWheelEvent@ImGuiIO@@QEAAXMM@Z";
IO_AddFocusEvent :: (this: *IO, focused: bool) #cpp_method #foreign imgui_dll "?AddFocusEvent@ImGuiIO@@QEAAX_N@Z";
IO_AddInputCharacter :: (this: *IO, c: u32) #cpp_method #foreign imgui_dll "?AddInputCharacter@ImGuiIO@@QEAAXI@Z";

FontAtlas_GetTexDataAsRGBA32 :: (atlas: *ImFontAtlas, out_pixels: **u8, out_width: *s32, out_height: *s32, out_bpp: *s32 = null) #cpp_method #foreign imgui_dll "?GetTexDataAsRGBA32@ImFontAtlas@@QEAAXPEAPEAEPEAH11@Z";
FontAtlas_AddFontFromFileTTF :: (this: *ImFontAtlas, filename: *u8, size_pixels: float, font_cfg: *ImFontConfig = null, glyph_ranges: *ImWchar = null) -> *ImFont #cpp_method #foreign imgui_dll "?AddFontFromFileTTF@ImFontAtlas@@QEAAPEAUImFont@@PEBDMPEBUImFontConfig@@PEBG@Z";
FontAtlas_GetGlyphRangesChineseSimplifiedCommon :: (this: *ImFontAtlas) -> *ImWchar #cpp_method #foreign imgui_dll "?GetGlyphRangesChineseSimplifiedCommon@ImFontAtlas@@QEAAPEBGXZ";

DrawList_AddLine :: (this: *ImDrawList, p1: *ImVec2, p2: *ImVec2, col: u32, thickness: float = 1.0) #cpp_method #foreign imgui_dll "?AddLine@ImDrawList@@QEAAXAEBUImVec2@@0IM@Z";
DrawList_AddRect :: (this: *ImDrawList, p_min: *ImVec2, p_max: *ImVec2, col: u32, rounding: float = 0.0, flags: s32 = 0, thickness: float = 1.0) #cpp_method #foreign imgui_dll "?AddRect@ImDrawList@@QEAAXAEBUImVec2@@0IMHM@Z";
DrawList_AddRectFilled :: (this: *ImDrawList, p_min: *ImVec2, p_max: *ImVec2, col: u32, rounding: float = 0.0, flags: s32 = 0) #cpp_method #foreign imgui_dll "?AddRectFilled@ImDrawList@@QEAAXAEBUImVec2@@0IMH@Z";
DrawList_AddText :: (this: *ImDrawList, pos: *ImVec2, col: u32, text_begin: *u8, text_end: *u8 = null) #cpp_method #foreign imgui_dll "?AddText@ImDrawList@@QEAAXAEBUImVec2@@IPEBD1@Z";

// ---- Minimal SDL3 cursor API (jfoster's bindings don't cover it; the SDL3
// ---- import library is already linked by the jfoster module).

// 光标 API：文件相对路径直指 jfoster 自带的 SDL3 导入库（同一 DLL）。
IMGUI_SDL3 :: #library "../../jfoster/internal/native/windows/SDL3";   // 从 thirdparty/ 上溯两级

SDL_SystemCursor :: enum u32 {
    DEFAULT;           // 0
    TEXT;              // 1
    WAIT;              // 2
    CROSSHAIR;         // 3
    PROGRESS;          // 4
    NWSE_RESIZE;       // 5
    NESW_RESIZE;       // 6
    EW_RESIZE;         // 7
    NS_RESIZE;         // 8
    MOVE;              // 9
    NOT_ALLOWED;       // 10
    POINTER;           // 11 (SDL_SYSTEM_CURSOR_POINTER)
}

SDL_CreateSystemCursor :: (id: SDL_SystemCursor) -> *void #foreign IMGUI_SDL3;
SDL_SetCursor :: (cursor: *void) -> void #foreign IMGUI_SDL3;
SDL_DestroyCursor :: (cursor: *void) -> void #foreign IMGUI_SDL3;
SDL3_ShowCursor :: (toggle: s32) -> s32 #foreign IMGUI_SDL3 "SDL_ShowCursor";
// 剪贴板直接用 jfoster 再导出的 SDL_GetClipboardText / SDL_SetClipboardText。

// --- backend state ---

KEY_MAP_SIZE :: 512; // SDL scancode space

key_map: [KEY_MAP_SIZE] Key; // SDL scancode -> ImGui Key; .None = unmapped
sdl_cursors: [MouseCursor.COUNT] *void;
current_mouse_cursor: MouseCursor = .COUNT;
font_texture: *IMGF.Texture;

last_frame_focused := false;
last_control_pressed := false;
last_shift_pressed := false;
last_alt_pressed := false;
last_super_pressed := false;
// 已投递的 Text 字节数：同一帧内多次 process_input 时只发新增部分。
text_consumed: s64;
last_render_elapsed := cast(float64) 0.0;

// --- lifecycle ---

imgui_initialized := false;

imgui_foster_setup :: (font_path: string = "") -> bool {
    // 宿主忘了建 context 是常见坑（直接 assert "No current context"）：
    // 这里自建（已存在则不动）。
    if GetCurrentContext() == null {
        _ = CreateContext();
    }
    imgui_initialized = true;
    setup_font_path = font_path;
    setup_keymap();
    setup_cursors();
    setup_backend();
    setup_font_texture();

    // Text input has to be enabled on the window for Keyboard_State.Text.
    IMGF.window_start_text_input(IMGF.App.window);
    return true;
}

imgui_foster_shutdown :: () {
    imgui_initialized = false;
    if font_texture != null {
        IMGF.texture_dispose(font_texture);
        font_texture = null;
    }
    for * sdl_cursors {
        if <<it != null SDL_DestroyCursor(<<it);
        <<it = null;
    }
}

// Queue input events into io (call every App.update step; ImGui consumes the
// queue at NewFrame, so multiple update steps per render frame are fine).
imgui_foster_process_input :: () {
    if !imgui_initialized return;
    io := GetIO();
    kb := IMGF.input_keyboard(IMGF.App.input);
    mouse := IMGF.input_mouse(IMGF.App.input);

    focused := IMGF.window_focused(IMGF.App.window);
    if focused != last_frame_focused {
        IO_AddFocusEvent(io, focused);
    }
    last_frame_focused = focused;

    // Modifier changes -> events so shortcuts work.
    ctrl_down := IMGF.keyboard_ctrl(kb);
    if ctrl_down != last_control_pressed IO_AddKeyEvent(io, .ImGuiMod_Ctrl, ctrl_down);
    last_control_pressed = ctrl_down;

    shift_down := IMGF.keyboard_shift(kb);
    if shift_down != last_shift_pressed IO_AddKeyEvent(io, .ImGuiMod_Shift, shift_down);
    last_shift_pressed = shift_down;

    alt_down := IMGF.keyboard_alt(kb);
    if alt_down != last_alt_pressed IO_AddKeyEvent(io, .ImGuiMod_Alt, alt_down);
    last_alt_pressed = alt_down;

    super_down := IMGF.keyboard_down2(kb, .LEFT_OS, .RIGHT_OS);
    if super_down != last_super_pressed IO_AddKeyEvent(io, .ImGuiMod_Super, super_down);
    last_super_pressed = super_down;

    // Pressed / released keys (only mapped scancodes; avoids touching enum holes).
    // 同一 step 内按下又松开（帧卡顿/快速点按）时 pressed 和 released 同时为
    // 真：必须先发 down 再发 up——用 else if 会吞掉 up，ImGui 认为键卡死
    //（Backspace 连删就是这个症状）。
    for sc: 0..KEY_MAP_SIZE-1 {
        imgui_key := key_map[sc];
        if imgui_key == .None continue;
        sdl_key := cast(IMGF.Keys) sc;
        pressed_now := IMGF.keyboard_pressed(kb, sdl_key);
        released_now := IMGF.keyboard_released(kb, sdl_key);
        if pressed_now {
            IO_AddKeyEvent(io, imgui_key, true);
            if released_now IO_AddKeyEvent(io, imgui_key, false);
        } else if released_now {
            IO_AddKeyEvent(io, imgui_key, false);
        }
    }

    // Text input (UTF-8 accumulated this step) -> codepoints, in order.
    if builder_string_length(*kb.Text) > 0 {
        text := builder_to_string(*kb.Text);
        if text.count < text_consumed text_consumed = 0;
        i := text_consumed;
        while i < text.count {
            cp, length := utf8_decode(text, i);
            if cp > 0 IO_AddInputCharacter(io, cp);
            i += length;
        }
        // 本文件允许多次 process_input 共用一个渲染帧（一次渲染可能跑多个 update step），
        // 所以用游标记住已投递的字节数，只发新增的尾巴；缓冲变短说明是新的一帧，游标归零。
        text_consumed = text.count;
    }

    if io.WantSetMousePos {
        IMGF.window_set_mouse_position(IMGF.App.window, .{ x = io.MousePos.x, y = io.MousePos.y });
    } else {
        pos := mouse.Position;
        IO_AddMousePosEvent(io, pos.x, pos.y);
    }

    set_mouse_event(io, .LEFT,   0);
    set_mouse_event(io, .RIGHT,  1);
    set_mouse_event(io, .MIDDLE, 2);
    set_mouse_event(io, .X1,     3);
    set_mouse_event(io, .X2,     4);

    wheel := IMGF.mouse_wheel(mouse);
    if wheel.x != 0 || wheel.y != 0 {
        IO_AddMouseWheelEvent(io, wheel.x, wheel.y);
    }
}

// Begin the ImGui frame (call once per render frame).
imgui_foster_new_frame :: () {
    io := GetIO();

    // jfoster renders in physical pixels and the batcher projection matches,
    // so ImGui works directly in pixel coordinates with a 1:1 framebuffer scale.
    size := IMGF.window_size_in_pixels(IMGF.App.window);
    io.DisplaySize = .{ x = cast(float) size.x, y = cast(float) size.y };
    io.DisplayFramebufferScale = .{ x = 1.0, y = 1.0 };

    dt := IMGF.App.time.elapsed - last_render_elapsed;
    last_render_elapsed = IMGF.App.time.elapsed;
    if dt > 0.0 {
        io.DeltaTime = cast(float) dt;
    }

    update_mouse_cursor(io);

    NewFrame();
}

// Finish the frame and append the DrawData to the batcher. The caller submits
// the single batcher_render(b, target) for the whole frame afterwards.
imgui_foster_render :: (b: *IMGF.Batcher) {
    Render();
    draw_data := GetDrawData();
    if draw_data == null || !draw_data.Valid return;

    // ImGui colors are straight alpha (raylib-era behavior we keep).
    IMGF.batcher_push_blend(b, IMGF.Blend_Mode_NonPremultiplied);

    for list_i: 0..draw_data.CmdListsCount-1 {
        draw_list := (draw_data.CmdLists)[list_i];
        if draw_list.CmdBuffer.Size <= 0 continue;

        for cmd_i: 0..draw_list.CmdBuffer.Size-1 {
            cmd := draw_list.CmdBuffer.Data[cmd_i];

            clip := IMGF.Rect_Int.{
                x = cast(s32) (cmd.ClipRect.x - draw_data.DisplayPos.x),
                y = cast(s32) (cmd.ClipRect.y - draw_data.DisplayPos.y),
                w = cast(s32) (cmd.ClipRect.z - cmd.ClipRect.x),
                h = cast(s32) (cmd.ClipRect.w - cmd.ClipRect.y),
            };
            IMGF.batcher_push_scissor(b, clip, true);

            if cmd.UserCallback != null {
                cmd.UserCallback(draw_list, *cmd);
                IMGF.batcher_pop_scissor(b);
                continue;
            }

            render_triangles(
                b,
                cmd.ElemCount,
                cmd.IdxOffset,
                draw_list.IdxBuffer,
                draw_list.VtxBuffer,
                cast(*IMGF.Texture) cmd.TextureId,
            );

            IMGF.batcher_pop_scissor(b);
        }
    }

    IMGF.batcher_pop_blend(b);
}

// Wrap a jfoster texture so it can be passed to ImGui.Image etc.
imgui_foster_register_texture :: (texture: *IMGF.Texture) -> ImTextureID {
    return cast(*void) texture;
}

// --- private helpers ---

render_triangles :: (b: *IMGF.Batcher, count: u32, index_start: u32, index_buffer: ImVector(ImDrawIdx), vert_buffer: ImVector(ImDrawVert), texture: *IMGF.Texture) {
    if count < 3 || texture == null return;

    n := cast(s32) count;
    IMGF.batcher_set_texture(b, texture);
    vertices, indices, offset := IMGF.batcher_request(b, n, n);

    matrix := b.Matrix; // imgui geometry is submitted in screen space, but
                         // honor an outer transform for parity with the batcher.
    for i: 0..n-1 {
        index := index_buffer.Data[cast(s64) (index_start + cast(u32) i)];
        src := vert_buffer.Data[cast(s64) index];
        dst := *vertices[i];
        dst.pos = IMGF.vector2_transform(.{ x = src.pos.x, y = src.pos.y }, matrix);
        dst.tex = .{ x = src.uv.x, y = src.uv.y };
        dst.col = .{
            r = cast(u8) ((src.col >> 0)  & 0xFF),
            g = cast(u8) ((src.col >> 8)  & 0xFF),
            b = cast(u8) ((src.col >> 16) & 0xFF),
            a = cast(u8) ((src.col >> 24) & 0xFF),
        };
        dst.mode = IMGF.Batcher_Mode_Normal;
        indices[i] = offset + i;
    }
}

set_mouse_event :: (io: *IO, button: IMGF.Mouse_Buttons, imgui_button: s32) {
    mouse := IMGF.input_mouse(IMGF.App.input);
    // 按下与松开要分别判断：同一 step 里既按下又松开时，`else if` 会把 up 事件吞掉。
    if IMGF.mouse_pressed(mouse, button) IO_AddMouseButtonEvent(io, imgui_button, true);
    if IMGF.mouse_released(mouse, button) IO_AddMouseButtonEvent(io, imgui_button, false);
}

update_mouse_cursor :: (io: *IO) {
    if (io.ConfigFlags_ & .NoMouseCursorChange) != 0 return;

    imgui_cursor := GetMouseCursor();
    if imgui_cursor == current_mouse_cursor && !io.MouseDrawCursor return;
    current_mouse_cursor = imgui_cursor;

    if io.MouseDrawCursor || imgui_cursor == .None {
        _ = SDL3_ShowCursor(0);
        return;
    }

    _ = SDL3_ShowCursor(1);
    if cast(s32) imgui_cursor > -1 && imgui_cursor < .COUNT {
        cursor := sdl_cursors[cast(s64) cast(s32) imgui_cursor];
        if cursor != null {
            SDL_SetCursor(cursor);
        }
    } else {
        SDL_SetCursor(sdl_cursors[cast(s64) cast(s32) MouseCursor.Arrow]);
    }
}

setup_cursors :: () {
    // ImGui MouseCursor 顺序：Arrow, TextInput, ResizeAll, ResizeNS,
    // ResizeEW, ResizeNESW, ResizeNWSE, Hand, NotAllowed。
    map: [MouseCursor.COUNT] SDL_SystemCursor = .[
        .DEFAULT,     // Arrow
        .TEXT,        // TextInput
        .MOVE,        // ResizeAll
        .NS_RESIZE,   // ResizeNS
        .EW_RESIZE,   // ResizeEW
        .NESW_RESIZE, // ResizeNESW
        .NWSE_RESIZE, // ResizeNWSE
        .POINTER,     // Hand
        .NOT_ALLOWED, // NotAllowed
    ];
    for i: 0..cast(s32) MouseCursor.COUNT-1 {
        sdl_cursors[i] = SDL_CreateSystemCursor(map[i]);
    }
}

setup_backend :: () {
    io := GetIO();
    io.BackendPlatformName = "imgui_impl_foster".data;
    io.BackendFlags_ = io.BackendFlags_ | .HasMouseCursors;
    io.MousePos = .{ x = 0.0, y = 0.0 };
    io.SetClipboardTextFn = set_clip_text_callback;
    io.GetClipboardTextFn = get_clip_text_callback;
}

EDITOR_FONT_SIZE :: 16.0;

setup_font_texture :: () {
    io := GetIO();

    if setup_font_path != "" {
        font := FontAtlas_AddFontFromFileTTF(
            io.Fonts,
            setup_font_path.data,
            EDITOR_FONT_SIZE,
            null,
            FontAtlas_GetGlyphRangesChineseSimplifiedCommon(io.Fonts),
        );
        if font != null {
            io.FontDefault = font;
        } else {
            print("imgui_foster: 字体加载失败 %（用 ImGui 内置默认字体）\n", setup_font_path);
        }
    }
    // setup_font_path 为空：只烘 ImGui 内置默认字体（ProggyClean 13px）。

    pixels: *u8;
    w: s32;
    h: s32;
    FontAtlas_GetTexDataAsRGBA32(io.Fonts, *pixels, *w, *h);

    bytes: [] u8;
    bytes.data  = pixels;
    bytes.count = cast(s64) w * h * 4;
    font_texture = IMGF.texture_create_from_pixels(IMGF.App.device, w, h, bytes);
    io.Fonts.TexID = cast(*void) font_texture;
    print("imgui_foster: 字体图集 %x%\n", w, h);
}

// 宿主在 imgui_foster_setup 之前设置（默认空 = 内置字体）。
// 字符集用 ChineseSimplifiedCommon（含 ASCII），任何 TTF 都能烘。
setup_font_path: string = "";

// #c_call 内只能调 #foreign：剪贴板直连 SDL（官方 SDL 后端同款；Get 返回
// 的指针由 SDL 持有、下次调用前有效，与 ImGui 语义一致）。
set_clip_text_callback :: (user_data: *void, text: *u8) #c_call {
    IMGF.SDL_SetClipboardText(text);
}

get_clip_text_callback :: (user_data: *void) -> *u8 #c_call {
    return IMGF.SDL_GetClipboardText();
}

// Decode one UTF-8 codepoint at text[i]; returns (codepoint, byte length).
utf8_decode :: (text: string, i: int) -> (u32, int) {
    c := text[i];
    if c < 0x80 {
        return cast(u32) c, 1;
    }
    if (c & 0xE0) == 0xC0 && i + 1 < text.count {
        q1 := (cast(u32) (c & 0x1F)) << 6;
        q2 := cast(u32) (text[i + 1] & 0x3F);
        return q1 | q2, 2;
    }
    if (c & 0xF0) == 0xE0 && i + 2 < text.count {
        // 注意括号：必须先 cast(u32) 再 <<，否则移位在 u8 上先溢出截断
        // （曾把所有中文解码成低字节垃圾——"输入不了中文"的根因）。
        // 变量分解：内联链式 cast/移位在 Jai 里结合方式不可靠，别合成一行。
        p1 := (cast(u32) (c & 0x0F)) << 12;
        p2 := (cast(u32) (text[i + 1] & 0x3F)) << 6;
        p3 := cast(u32) (text[i + 2] & 0x3F);
        return p1 | p2 | p3, 3;
    }
    if (c & 0xF8) == 0xF0 && i + 3 < text.count {
        w1 := (cast(u32) (c & 0x07)) << 18;
        w2 := (cast(u32) (text[i + 1] & 0x3F)) << 12;
        w3 := (cast(u32) (text[i + 2] & 0x3F)) << 6;
        w4 := cast(u32) (text[i + 3] & 0x3F);
        return w1 | w2 | w3 | w4, 4;
    }
    return 0, 1;
}

// --- keymap: jfoster Keys (SDL scancodes) -> ImGui Key ---

setup_keymap :: () {
    // 直接写 key_map 本体（固定数组是值语义，k := key_map 只会改到副本）

    key_map[cast(s64) IMGF.Keys.APOSTROPHE]     = .Apostrophe;
    key_map[cast(s64) IMGF.Keys.COMMA]          = .Comma;
    key_map[cast(s64) IMGF.Keys.MINUS]          = .Minus;
    key_map[cast(s64) IMGF.Keys.PERIOD]         = .Period;
    key_map[cast(s64) IMGF.Keys.SLASH]          = .Slash;
    key_map[cast(s64) IMGF.Keys.NUM_0]          = ._0;
    key_map[cast(s64) IMGF.Keys.NUM_1]          = ._1;
    key_map[cast(s64) IMGF.Keys.NUM_2]          = ._2;
    key_map[cast(s64) IMGF.Keys.NUM_3]          = ._3;
    key_map[cast(s64) IMGF.Keys.NUM_4]          = ._4;
    key_map[cast(s64) IMGF.Keys.NUM_5]          = ._5;
    key_map[cast(s64) IMGF.Keys.NUM_6]          = ._6;
    key_map[cast(s64) IMGF.Keys.NUM_7]          = ._7;
    key_map[cast(s64) IMGF.Keys.NUM_8]          = ._8;
    key_map[cast(s64) IMGF.Keys.NUM_9]          = ._9;
    key_map[cast(s64) IMGF.Keys.SEMICOLON]      = .Semicolon;
    key_map[cast(s64) IMGF.Keys.EQUALS]         = .Equal;
    key_map[cast(s64) IMGF.Keys.A]              = .A;
    key_map[cast(s64) IMGF.Keys.B]              = .B;
    key_map[cast(s64) IMGF.Keys.C]              = .C;
    key_map[cast(s64) IMGF.Keys.D]              = .D;
    key_map[cast(s64) IMGF.Keys.E]              = .E;
    key_map[cast(s64) IMGF.Keys.F]              = .F;
    key_map[cast(s64) IMGF.Keys.G]              = .G;
    key_map[cast(s64) IMGF.Keys.H]              = .H;
    key_map[cast(s64) IMGF.Keys.I]              = .I;
    key_map[cast(s64) IMGF.Keys.J]              = .J;
    key_map[cast(s64) IMGF.Keys.K]              = .K;
    key_map[cast(s64) IMGF.Keys.L]              = .L;
    key_map[cast(s64) IMGF.Keys.M]              = .M;
    key_map[cast(s64) IMGF.Keys.N]              = .N;
    key_map[cast(s64) IMGF.Keys.O]              = .O;
    key_map[cast(s64) IMGF.Keys.P]              = .P;
    key_map[cast(s64) IMGF.Keys.Q]              = .Q;
    key_map[cast(s64) IMGF.Keys.R]              = .R;
    key_map[cast(s64) IMGF.Keys.S]              = .S;
    key_map[cast(s64) IMGF.Keys.T]              = .T;
    key_map[cast(s64) IMGF.Keys.U]              = .U;
    key_map[cast(s64) IMGF.Keys.V]              = .V;
    key_map[cast(s64) IMGF.Keys.W]              = .W;
    key_map[cast(s64) IMGF.Keys.X]              = .X;
    key_map[cast(s64) IMGF.Keys.Y]              = .Y;
    key_map[cast(s64) IMGF.Keys.Z]              = .Z;
    key_map[cast(s64) IMGF.Keys.SPACE]          = .Space;
    key_map[cast(s64) IMGF.Keys.ESCAPE]         = .Escape;
    key_map[cast(s64) IMGF.Keys.RETURN]         = .Enter;
    key_map[cast(s64) IMGF.Keys.TAB]            = .Tab;
    key_map[cast(s64) IMGF.Keys.BACKSPACE]      = .Backspace;
    key_map[cast(s64) IMGF.Keys.INSERT]         = .Insert;
    key_map[cast(s64) IMGF.Keys.DELETE]         = .Delete;
    key_map[cast(s64) IMGF.Keys.RIGHT]          = .RightArrow;
    key_map[cast(s64) IMGF.Keys.LEFT]           = .LeftArrow;
    key_map[cast(s64) IMGF.Keys.DOWN]           = .DownArrow;
    key_map[cast(s64) IMGF.Keys.UP]             = .UpArrow;
    key_map[cast(s64) IMGF.Keys.PAGE_UP]        = .PageUp;
    key_map[cast(s64) IMGF.Keys.PAGE_DOWN]      = .PageDown;
    key_map[cast(s64) IMGF.Keys.HOME]           = .Home;
    key_map[cast(s64) IMGF.Keys.END]            = .End;
    key_map[cast(s64) IMGF.Keys.CAPS_LOCK]      = .CapsLock;
    key_map[cast(s64) IMGF.Keys.SCROLL_LOCK]    = .ScrollLock;
    key_map[cast(s64) IMGF.Keys.NUM_LOCK]       = .NumLock;
    key_map[cast(s64) IMGF.Keys.PRINT_SCREEN]   = .PrintScreen;
    key_map[cast(s64) IMGF.Keys.PAUSE]          = .Pause;
    key_map[cast(s64) IMGF.Keys.F1]             = .F1;
    key_map[cast(s64) IMGF.Keys.F2]             = .F2;
    key_map[cast(s64) IMGF.Keys.F3]             = .F3;
    key_map[cast(s64) IMGF.Keys.F4]             = .F4;
    key_map[cast(s64) IMGF.Keys.F5]             = .F5;
    key_map[cast(s64) IMGF.Keys.F6]             = .F6;
    key_map[cast(s64) IMGF.Keys.F7]             = .F7;
    key_map[cast(s64) IMGF.Keys.F8]             = .F8;
    key_map[cast(s64) IMGF.Keys.F9]             = .F9;
    key_map[cast(s64) IMGF.Keys.F10]            = .F10;
    key_map[cast(s64) IMGF.Keys.F11]            = .F11;
    key_map[cast(s64) IMGF.Keys.F12]            = .F12;
    key_map[cast(s64) IMGF.Keys.LEFT_SHIFT]     = .LeftShift;
    key_map[cast(s64) IMGF.Keys.LEFT_CONTROL]   = .LeftCtrl;
    key_map[cast(s64) IMGF.Keys.LEFT_ALT]       = .LeftAlt;
    key_map[cast(s64) IMGF.Keys.LEFT_OS]        = .LeftSuper;
    key_map[cast(s64) IMGF.Keys.RIGHT_SHIFT]    = .RightShift;
    key_map[cast(s64) IMGF.Keys.RIGHT_CONTROL]  = .RightCtrl;
    key_map[cast(s64) IMGF.Keys.RIGHT_ALT]      = .RightAlt;
    key_map[cast(s64) IMGF.Keys.RIGHT_OS]       = .RightSuper;
    key_map[cast(s64) IMGF.Keys.LEFT_BRACKET]   = .LeftBracket;
    key_map[cast(s64) IMGF.Keys.BACKSLASH]      = .Backslash;
    key_map[cast(s64) IMGF.Keys.RIGHT_BRACKET]  = .RightBracket;
    key_map[cast(s64) IMGF.Keys.GRAVE]          = .GraveAccent;
    key_map[cast(s64) IMGF.Keys.KP_0]           = .Keypad0;
    key_map[cast(s64) IMGF.Keys.KP_1]           = .Keypad1;
    key_map[cast(s64) IMGF.Keys.KP_2]           = .Keypad2;
    key_map[cast(s64) IMGF.Keys.KP_3]           = .Keypad3;
    key_map[cast(s64) IMGF.Keys.KP_4]           = .Keypad4;
    key_map[cast(s64) IMGF.Keys.KP_5]           = .Keypad5;
    key_map[cast(s64) IMGF.Keys.KP_6]           = .Keypad6;
    key_map[cast(s64) IMGF.Keys.KP_7]           = .Keypad7;
    key_map[cast(s64) IMGF.Keys.KP_8]           = .Keypad8;
    key_map[cast(s64) IMGF.Keys.KP_9]           = .Keypad9;
    key_map[cast(s64) IMGF.Keys.KP_PERIOD]      = .KeypadDecimal;
    key_map[cast(s64) IMGF.Keys.KP_DIVIDE]      = .KeypadDivide;
    key_map[cast(s64) IMGF.Keys.KP_MULTIPLY]    = .KeypadMultiply;
    key_map[cast(s64) IMGF.Keys.KP_MINUS]       = .KeypadSubtract;
    key_map[cast(s64) IMGF.Keys.KP_PLUS]        = .KeypadAdd;
    key_map[cast(s64) IMGF.Keys.KP_ENTER]       = .KeypadEnter;
}
