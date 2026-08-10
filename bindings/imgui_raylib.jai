// imgui_raylib.jai
// Dear ImGui backend for raylib — the Jai port of
// Ascension/tlib/odin-imgui/imgui_impl_raylib/imgui_impl_raylib.odin
// (which itself is based on the raylib extras rlImGui).
//
// Input comes from raylib (mouse, keyboard incl. keymap + text input,
// focus, clipboard); rendering goes through raylib's rlgl immediate-mode
// API (rlBegin/rlVertex2f/rlScissor) driven by ImDrawData, exactly like the
// Odin original. Call imgui_raylib_new_frame() before building the frame
// (it also pumps raylib input events), then imgui_raylib_render() after
// Render(), inside raylib's BeginDrawing()/EndDrawing().
//
// Usage (matches the Odin original):
//     imgui_raylib_setup()
//     for !WindowShouldClose() {
//         imgui_raylib_new_frame()
//         ... imgui widgets ...
//         imgui_raylib_render()
//     }
//     imgui_raylib_shutdown()

#import "Basic";
#import "ImGui";

rl :: #import "bindings/raylib";
rlgl :: #import "bindings/rlgl";

imgui_dll :: #system_library "imgui";

// The Jai ImGui module declares these as struct members (cpp_method); this
// compiler version cannot call them via member syntax, so rebind them here
// as standalone functions (same pattern as the DrawList_* helpers below).
IO_AddKeyEvent :: (this: *IO, key: Key, down: bool) #cpp_method #foreign imgui_dll "?AddKeyEvent@ImGuiIO@@QEAAXW4ImGuiKey@@_N@Z";
IO_AddMousePosEvent :: (this: *IO, x: float, y: float) #cpp_method #foreign imgui_dll "?AddMousePosEvent@ImGuiIO@@QEAAXMM@Z";
IO_AddMouseButtonEvent :: (this: *IO, button: s32, down: bool) #cpp_method #foreign imgui_dll "?AddMouseButtonEvent@ImGuiIO@@QEAAXH_N@Z";
IO_AddMouseWheelEvent :: (this: *IO, wheel_x: float, wheel_y: float) #cpp_method #foreign imgui_dll "?AddMouseWheelEvent@ImGuiIO@@QEAAXMM@Z";
IO_AddFocusEvent :: (this: *IO, focused: bool) #cpp_method #foreign imgui_dll "?AddFocusEvent@ImGuiIO@@QEAAX_N@Z";
IO_AddInputCharacter :: (this: *IO, c: u32) #cpp_method #foreign imgui_dll "?AddInputCharacter@ImGuiIO@@QEAAXI@Z";

// The Jai ImGui module does not bind this ImFontAtlas helper either.
FontAtlas_GetTexDataAsRGBA32 :: (atlas: *ImFontAtlas, out_pixels: **u8, out_width: *s32, out_height: *s32, out_bpp: *s32 = null) #cpp_method #foreign imgui_dll "?GetTexDataAsRGBA32@ImFontAtlas@@QEAAXPEAPEAEPEAH11@Z";

// The module declares these as ImFontAtlas members too (cpp_method); rebind
// them here so the CJK font can be loaded before the atlas is packed.
FontAtlas_AddFontFromFileTTF :: (this: *ImFontAtlas, filename: *u8, size_pixels: float, font_cfg: *ImFontConfig = null, glyph_ranges: *ImWchar = null) -> *ImFont #cpp_method #foreign imgui_dll "?AddFontFromFileTTF@ImFontAtlas@@QEAAPEAUImFont@@PEBDMPEBUImFontConfig@@PEBG@Z";
FontAtlas_GetGlyphRangesChineseFull :: (this: *ImFontAtlas) -> *ImWchar #cpp_method #foreign imgui_dll "?GetGlyphRangesChineseFull@ImFontAtlas@@QEAAPEBGXZ";
FontAtlas_GetGlyphRangesChineseSimplifiedCommon :: (this: *ImFontAtlas) -> *ImWchar #cpp_method #foreign imgui_dll "?GetGlyphRangesChineseSimplifiedCommon@ImFontAtlas@@QEAAPEBGXZ";

// ImDrawList primitives (same reason as above: the module declares them as
// struct members; rebind as standalone functions for the editor tools).
DrawList_AddLine :: (this: *ImDrawList, p1: *ImVec2, p2: *ImVec2, col: u32, thickness: float = 1.0) #cpp_method #foreign imgui_dll "?AddLine@ImDrawList@@QEAAXAEBUImVec2@@0IM@Z";
DrawList_AddRect :: (this: *ImDrawList, p_min: *ImVec2, p_max: *ImVec2, col: u32, rounding: float = 0.0, flags: s32 = 0, thickness: float = 1.0) #cpp_method #foreign imgui_dll "?AddRect@ImDrawList@@QEAAXAEBUImVec2@@0IMHM@Z";
DrawList_AddRectFilled :: (this: *ImDrawList, p_min: *ImVec2, p_max: *ImVec2, col: u32, rounding: float = 0.0, flags: s32 = 0) #cpp_method #foreign imgui_dll "?AddRectFilled@ImDrawList@@QEAAXAEBUImVec2@@0IMH@Z";
DrawList_AddText :: (this: *ImDrawList, pos: *ImVec2, col: u32, text_begin: *u8, text_end: *u8 = null) #cpp_method #foreign imgui_dll "?AddText@ImDrawList@@QEAAXAEBUImVec2@@IPEBD1@Z";

// --- backend state ---

current_mouse_cursor: MouseCursor = .COUNT;
mouse_cursor_map: [MouseCursor.COUNT] rl.RL_MouseCursor;
raylib_key_map: [349] Key;   // indexed by raylib keycode; Key.None (0) = unmapped
last_frame_focused := false;
last_control_pressed := false;
last_shift_pressed := false;
last_alt_pressed := false;
last_super_pressed := false;

font_texture_id: u32 = 0;

is_control_down :: () -> bool {
    return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL);
}

is_shift_down :: () -> bool {
    return rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT);
}

is_alt_down :: () -> bool {
    return rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT);
}

is_super_down :: () -> bool {
    return rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER);
}

// floor() for the scissor math (Basic has no floor; avoiding Math to keep
// its Vector2 etc. out of this module's scope).
floor_f :: (x: float32) -> float32 {
    xi := cast(s32) x;
    if cast(float32) xi > x {
        xi -= 1;
    }
    return cast(float32) xi;
}

// --- lifecycle ---

imgui_raylib_setup :: () -> bool {
    setup_globals();
    setup_keymap();
    setup_mouse_cursor();
    setup_backend();
    setup_font_texture();
    return true;
}

imgui_raylib_shutdown :: () {
    if font_texture_id != 0 {
        rlgl.rlUnloadTexture(font_texture_id);
        font_texture_id = 0;
    }
}

// Full frame start: pump raylib input events, update io for this frame, then
// begin the ImGui frame. (The Odin original calls process_events()/new_frame()
// and ImGui.NewFrame() separately; the app shell here only calls
// imgui_raylib_new_frame(), so all three are merged.)
imgui_raylib_new_frame :: () {
    process_events();

    io := GetIO();

    if rl.IsWindowFullscreen() {
        monitor := rl.GetCurrentMonitor();
        io.DisplaySize = .{ x = cast(float32) rl.GetMonitorWidth(monitor), y = cast(float32) rl.GetMonitorHeight(monitor) };
    } else {
        io.DisplaySize = .{ x = cast(float32) rl.GetScreenWidth(), y = cast(float32) rl.GetScreenHeight() };
    }

    // The real framebuffer scale is the RenderWidth/Height over the
    // ScreenWidth/Height ratio (handles HiDPI and resizing).
    fb_w := cast(float32) rl.GetRenderWidth();
    fb_h := cast(float32) rl.GetRenderHeight();
    if io.DisplaySize.x > 0.0 && io.DisplaySize.y > 0.0 {
        io.DisplayFramebufferScale = .{ x = fb_w / io.DisplaySize.x, y = fb_h / io.DisplaySize.y };
    } else {
        io.DisplayFramebufferScale = .{ x = 1.0, y = 1.0 };
    }

    io.DeltaTime = rl.GetFrameTime();

    if io.WantSetMousePos {
        rl.SetMousePosition(cast(s32) io.MousePos.x, cast(s32) io.MousePos.y);
    } else {
        mouse_pos := rl.GetMousePosition();
        IO_AddMousePosEvent(io, mouse_pos.x, mouse_pos.y);
    }

    set_mouse_event(io, rl.RL_MouseButton.LEFT, 0);
    set_mouse_event(io, rl.RL_MouseButton.RIGHT, 1);
    set_mouse_event(io, rl.RL_MouseButton.MIDDLE, 2);
    set_mouse_event(io, rl.RL_MouseButton.SIDE, 3);
    set_mouse_event(io, rl.RL_MouseButton.EXTRA, 4);

    wheel := rl.GetMouseWheelMoveV();
    IO_AddMouseWheelEvent(io, wheel.x, wheel.y);

    // Mouse cursor management (skip when the app opted out via config).
    if (io.ConfigFlags_ & .NoMouseCursorChange) == 0 {
        imgui_cursor := GetMouseCursor();
        if imgui_cursor != current_mouse_cursor || io.MouseDrawCursor {
            current_mouse_cursor = imgui_cursor;
            if io.MouseDrawCursor || imgui_cursor == .None {
                rl.HideCursor();
            } else {
                rl.ShowCursor();
                if cast(s32) imgui_cursor > -1 && imgui_cursor < .COUNT {
                    rl.SetMouseCursor(mouse_cursor_map[cast(s64) cast(s32) imgui_cursor]);
                } else {
                    rl.SetMouseCursor(rl.RL_MouseCursor.DEFAULT);
                }
            }
        }
    }

    NewFrame();
}

// Pump raylib input into the io event queue (focus, modifiers, keys, chars).
// Called automatically by imgui_raylib_new_frame(); exposed for parity with
// the Odin original.
process_events :: () -> bool {
    io := GetIO();

    focused := rl.IsWindowFocused();
    if focused != last_frame_focused {
        IO_AddFocusEvent(io, focused);
    }
    last_frame_focused = focused;

    // Modifier keys change -> emit events so shortcuts work.
    ctrl_down := is_control_down();
    if ctrl_down != last_control_pressed {
        IO_AddKeyEvent(io, .ImGuiMod_Ctrl, ctrl_down);
    }
    last_control_pressed = ctrl_down;

    shift_down := is_shift_down();
    if shift_down != last_shift_pressed {
        IO_AddKeyEvent(io, .ImGuiMod_Shift, shift_down);
    }
    last_shift_pressed = shift_down;

    alt_down := is_alt_down();
    if alt_down != last_alt_pressed {
        IO_AddKeyEvent(io, .ImGuiMod_Alt, alt_down);
    }
    last_alt_pressed = alt_down;

    super_down := is_super_down();
    if super_down != last_super_pressed {
        IO_AddKeyEvent(io, .ImGuiMod_Super, super_down);
    }
    last_super_pressed = super_down;

    // Pressed keys, in event order.
    key_id := rl.GetKeyPressed();
    while key_id != rl.KeyboardKey.NULL {
        imgui_key := raylib_key_map[cast(s64) cast(s32) key_id];
        if imgui_key != .None {
            IO_AddKeyEvent(io, imgui_key, true);
        }
        key_id = rl.GetKeyPressed();
    }

    // Released keys.
    for code: 0..raylib_key_map.count-1 {
        imgui_key := raylib_key_map[code];
        if imgui_key != .None && rl.IsKeyReleased(cast(rl.KeyboardKey) code) {
            IO_AddKeyEvent(io, imgui_key, false);
        }
    }

    // Text input, in order.
    ch := rl.GetCharPressed();
    while ch != 0 {
        IO_AddInputCharacter(io, cast(u32) ch);
        ch = rl.GetCharPressed();
    }

    return true;
}

// Render the current frame: Render() + draw data pass.
imgui_raylib_render :: () {
    Render();
    imgui_raylib_render_draw_data();
}

imgui_raylib_render_draw_data :: () {
    draw_data := GetDrawData();
    if draw_data == null || !draw_data.Valid {
        return;
    }

    // Flush raylib's batch so our immediate-mode triangles come out on top,
    // and disable backface culling like the Odin original.
    rlgl.rlDrawRenderBatchActive();
    rlgl.rlDisableBackfaceCulling();

    if draw_data.CmdListsCount > 0 {
        for list_i: 0..draw_data.CmdListsCount-1 {
            draw_list := (draw_data.CmdLists)[list_i];
            if draw_list.CmdBuffer.Size <= 0 {
                continue;
            }
            for cmd_i: 0..draw_list.CmdBuffer.Size-1 {
                cmd := draw_list.CmdBuffer.Data[cmd_i];

                enable_scissor(
                    cmd.ClipRect.x - draw_data.DisplayPos.x,
                    cmd.ClipRect.y - draw_data.DisplayPos.y,
                    cmd.ClipRect.z - (cmd.ClipRect.x - draw_data.DisplayPos.x),
                    cmd.ClipRect.w - (cmd.ClipRect.y - draw_data.DisplayPos.y),
                );

                if cmd.UserCallback != null {
                    cmd.UserCallback(draw_list, *cmd);
                    continue;
                }

                render_triangles(cmd.ElemCount, cmd.IdxOffset, draw_list.IdxBuffer, draw_list.VtxBuffer, cmd.TextureId);
                rlgl.rlDrawRenderBatchActive();
            }
        }
    }

    rlgl.rlSetTexture(0);
    rlgl.rlDisableScissorTest();
    rlgl.rlEnableBackfaceCulling();
}

// --- private helpers ---

enable_scissor :: (x: float32, y: float32, width: float32, height: float32) {
    rlgl.rlEnableScissorTest();
    io := GetIO();

    // rlgl scissor origin is bottom-left; flip y (matches official rlImGui:
    // y starts at the bottom of the display minus the clip height).
    rlgl.rlScissor(
        cast(s32)(x * io.DisplayFramebufferScale.x),
        cast(s32)((io.DisplaySize.y - floor_f(y + height)) * io.DisplayFramebufferScale.y),
        cast(s32)(width * io.DisplayFramebufferScale.x),
        cast(s32)(height * io.DisplayFramebufferScale.y),
    );
}

render_triangles :: (count: u32, index_start: u32, index_buffer: ImVector(ImDrawIdx), vert_buffer: ImVector(ImDrawVert), texture_ptr: ImTextureID) {
    if count < 3 {
        return;
    }

    texture_id := cast(u32) cast(u64) texture_ptr;

    rlgl.rlBegin(cast(s32) rlgl.rlGlMode.RL_TRIANGLES);
    rlgl.rlSetTexture(texture_id);

    i: u32 = 0;
    while i <= count - 3 {
        if rlgl.rlCheckRenderBatchLimit(3) != 0 {
            rlgl.rlBegin(cast(s32) rlgl.rlGlMode.RL_TRIANGLES);
            rlgl.rlSetTexture(texture_id);
        }

        index_a := index_buffer.Data[cast(s64)(index_start + i)];
        index_b := index_buffer.Data[cast(s64)(index_start + i + 1)];
        index_c := index_buffer.Data[cast(s64)(index_start + i + 2)];

        vertex_a := vert_buffer.Data[cast(s64) index_a];
        vertex_b := vert_buffer.Data[cast(s64) index_b];
        vertex_c := vert_buffer.Data[cast(s64) index_c];

        draw_triangle_vert(vertex_a);
        draw_triangle_vert(vertex_b);
        draw_triangle_vert(vertex_c);

        i += 3;
    }

    rlgl.rlEnd();
}

draw_triangle_vert :: (vert: ImDrawVert) {
    rlgl.rlColor4ub(
        cast(u8)((vert.col >> 0) & 0xFF),
        cast(u8)((vert.col >> 8) & 0xFF),
        cast(u8)((vert.col >> 16) & 0xFF),
        cast(u8)((vert.col >> 24) & 0xFF),
    );
    rlgl.rlTexCoord2f(vert.uv.x, vert.uv.y);
    rlgl.rlVertex2f(vert.pos.x, vert.pos.y);
}

set_mouse_event :: (io: *IO, rl_mouse: rl.RL_MouseButton, imgui_mouse: s32) {
    if rl.IsMouseButtonPressed(rl_mouse) {
        IO_AddMouseButtonEvent(io, imgui_mouse, true);
    } else if rl.IsMouseButtonReleased(rl_mouse) {
        IO_AddMouseButtonEvent(io, imgui_mouse, false);
    }
}

setup_globals :: () {
    last_frame_focused = rl.IsWindowFocused();
    last_control_pressed = false;
    last_shift_pressed = false;
    last_alt_pressed = false;
    last_super_pressed = false;
}

setup_keymap :: () {
    k := raylib_key_map;   // local alias for brevity (array is reference-semantic)

    k[cast(s64) cast(s32) rl.KeyboardKey.APOSTROPHE]    = .Apostrophe;
    k[cast(s64) cast(s32) rl.KeyboardKey.COMMA]         = .Comma;
    k[cast(s64) cast(s32) rl.KeyboardKey.MINUS]         = .Minus;
    k[cast(s64) cast(s32) rl.KeyboardKey.PERIOD]        = .Period;
    k[cast(s64) cast(s32) rl.KeyboardKey.SLASH]         = .Slash;
    k[cast(s64) cast(s32) rl.KeyboardKey.ZERO]          = ._0;
    k[cast(s64) cast(s32) rl.KeyboardKey.ONE]           = ._1;
    k[cast(s64) cast(s32) rl.KeyboardKey.TWO]           = ._2;
    k[cast(s64) cast(s32) rl.KeyboardKey.THREE]         = ._3;
    k[cast(s64) cast(s32) rl.KeyboardKey.FOUR]          = ._4;
    k[cast(s64) cast(s32) rl.KeyboardKey.FIVE]          = ._5;
    k[cast(s64) cast(s32) rl.KeyboardKey.SIX]           = ._6;
    k[cast(s64) cast(s32) rl.KeyboardKey.SEVEN]         = ._7;
    k[cast(s64) cast(s32) rl.KeyboardKey.EIGHT]         = ._8;
    k[cast(s64) cast(s32) rl.KeyboardKey.NINE]          = ._9;
    k[cast(s64) cast(s32) rl.KeyboardKey.SEMICOLON]     = .Semicolon;
    k[cast(s64) cast(s32) rl.KeyboardKey.EQUAL]         = .Equal;
    k[cast(s64) cast(s32) rl.KeyboardKey.A]             = .A;
    k[cast(s64) cast(s32) rl.KeyboardKey.B]             = .B;
    k[cast(s64) cast(s32) rl.KeyboardKey.C]             = .C;
    k[cast(s64) cast(s32) rl.KeyboardKey.D]             = .D;
    k[cast(s64) cast(s32) rl.KeyboardKey.E]             = .E;
    k[cast(s64) cast(s32) rl.KeyboardKey.F]             = .F;
    k[cast(s64) cast(s32) rl.KeyboardKey.G]             = .G;
    k[cast(s64) cast(s32) rl.KeyboardKey.H]             = .H;
    k[cast(s64) cast(s32) rl.KeyboardKey.I]             = .I;
    k[cast(s64) cast(s32) rl.KeyboardKey.J]             = .J;
    k[cast(s64) cast(s32) rl.KeyboardKey.K]             = .K;
    k[cast(s64) cast(s32) rl.KeyboardKey.L]             = .L;
    k[cast(s64) cast(s32) rl.KeyboardKey.M]             = .M;
    k[cast(s64) cast(s32) rl.KeyboardKey.N]             = .N;
    k[cast(s64) cast(s32) rl.KeyboardKey.O]             = .O;
    k[cast(s64) cast(s32) rl.KeyboardKey.P]             = .P;
    k[cast(s64) cast(s32) rl.KeyboardKey.Q]             = .Q;
    k[cast(s64) cast(s32) rl.KeyboardKey.R]             = .R;
    k[cast(s64) cast(s32) rl.KeyboardKey.S]             = .S;
    k[cast(s64) cast(s32) rl.KeyboardKey.T]             = .T;
    k[cast(s64) cast(s32) rl.KeyboardKey.U]             = .U;
    k[cast(s64) cast(s32) rl.KeyboardKey.V]             = .V;
    k[cast(s64) cast(s32) rl.KeyboardKey.W]             = .W;
    k[cast(s64) cast(s32) rl.KeyboardKey.X]             = .X;
    k[cast(s64) cast(s32) rl.KeyboardKey.Y]             = .Y;
    k[cast(s64) cast(s32) rl.KeyboardKey.Z]             = .Z;
    k[cast(s64) cast(s32) rl.KeyboardKey.SPACE]         = .Space;
    k[cast(s64) cast(s32) rl.KeyboardKey.ESCAPE]        = .Escape;
    k[cast(s64) cast(s32) rl.KeyboardKey.ENTER]         = .Enter;
    k[cast(s64) cast(s32) rl.KeyboardKey.TAB]           = .Tab;
    k[cast(s64) cast(s32) rl.KeyboardKey.BACKSPACE]     = .Backspace;
    k[cast(s64) cast(s32) rl.KeyboardKey.INSERT]        = .Insert;
    k[cast(s64) cast(s32) rl.KeyboardKey.DELETE]        = .Delete;
    k[cast(s64) cast(s32) rl.KeyboardKey.RIGHT]         = .RightArrow;
    k[cast(s64) cast(s32) rl.KeyboardKey.LEFT]          = .LeftArrow;
    k[cast(s64) cast(s32) rl.KeyboardKey.DOWN]          = .DownArrow;
    k[cast(s64) cast(s32) rl.KeyboardKey.UP]            = .UpArrow;
    k[cast(s64) cast(s32) rl.KeyboardKey.PAGE_UP]       = .PageUp;
    k[cast(s64) cast(s32) rl.KeyboardKey.PAGE_DOWN]     = .PageDown;
    k[cast(s64) cast(s32) rl.KeyboardKey.HOME]          = .Home;
    k[cast(s64) cast(s32) rl.KeyboardKey.END]           = .End;
    k[cast(s64) cast(s32) rl.KeyboardKey.CAPS_LOCK]     = .CapsLock;
    k[cast(s64) cast(s32) rl.KeyboardKey.SCROLL_LOCK]   = .ScrollLock;
    k[cast(s64) cast(s32) rl.KeyboardKey.NUM_LOCK]      = .NumLock;
    k[cast(s64) cast(s32) rl.KeyboardKey.PRINT_SCREEN]  = .PrintScreen;
    k[cast(s64) cast(s32) rl.KeyboardKey.PAUSE]         = .Pause;
    k[cast(s64) cast(s32) rl.KeyboardKey.F1]            = .F1;
    k[cast(s64) cast(s32) rl.KeyboardKey.F2]            = .F2;
    k[cast(s64) cast(s32) rl.KeyboardKey.F3]            = .F3;
    k[cast(s64) cast(s32) rl.KeyboardKey.F4]            = .F4;
    k[cast(s64) cast(s32) rl.KeyboardKey.F5]            = .F5;
    k[cast(s64) cast(s32) rl.KeyboardKey.F6]            = .F6;
    k[cast(s64) cast(s32) rl.KeyboardKey.F7]            = .F7;
    k[cast(s64) cast(s32) rl.KeyboardKey.F8]            = .F8;
    k[cast(s64) cast(s32) rl.KeyboardKey.F9]            = .F9;
    k[cast(s64) cast(s32) rl.KeyboardKey.F10]           = .F10;
    k[cast(s64) cast(s32) rl.KeyboardKey.F11]           = .F11;
    k[cast(s64) cast(s32) rl.KeyboardKey.F12]           = .F12;
    k[cast(s64) cast(s32) rl.KeyboardKey.LEFT_SHIFT]    = .LeftShift;
    k[cast(s64) cast(s32) rl.KeyboardKey.LEFT_CONTROL]  = .LeftCtrl;
    k[cast(s64) cast(s32) rl.KeyboardKey.LEFT_ALT]      = .LeftAlt;
    k[cast(s64) cast(s32) rl.KeyboardKey.LEFT_SUPER]    = .LeftSuper;
    k[cast(s64) cast(s32) rl.KeyboardKey.RIGHT_SHIFT]   = .RightShift;
    k[cast(s64) cast(s32) rl.KeyboardKey.RIGHT_CONTROL] = .RightCtrl;
    k[cast(s64) cast(s32) rl.KeyboardKey.RIGHT_ALT]     = .RightAlt;
    k[cast(s64) cast(s32) rl.KeyboardKey.RIGHT_SUPER]   = .RightSuper;
    k[cast(s64) cast(s32) rl.KeyboardKey.KB_MENU]       = .Menu;
    k[cast(s64) cast(s32) rl.KeyboardKey.LEFT_BRACKET]  = .LeftBracket;
    k[cast(s64) cast(s32) rl.KeyboardKey.BACKSLASH]     = .Backslash;
    k[cast(s64) cast(s32) rl.KeyboardKey.RIGHT_BRACKET] = .RightBracket;
    k[cast(s64) cast(s32) rl.KeyboardKey.GRAVE]         = .GraveAccent;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_0]          = .Keypad0;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_1]          = .Keypad1;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_2]          = .Keypad2;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_3]          = .Keypad3;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_4]          = .Keypad4;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_5]          = .Keypad5;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_6]          = .Keypad6;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_7]          = .Keypad7;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_8]          = .Keypad8;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_9]          = .Keypad9;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_DECIMAL]    = .KeypadDecimal;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_DIVIDE]     = .KeypadDivide;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_MULTIPLY]   = .KeypadMultiply;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_SUBTRACT]   = .KeypadSubtract;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_ADD]        = .KeypadAdd;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_ENTER]      = .KeypadEnter;
    k[cast(s64) cast(s32) rl.KeyboardKey.KP_EQUAL]      = .KeypadEqual;
}

setup_mouse_cursor :: () {
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.Arrow]      = rl.RL_MouseCursor.ARROW;
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.TextInput]  = rl.RL_MouseCursor.IBEAM;
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.Hand]       = rl.RL_MouseCursor.POINTING_HAND;
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.ResizeAll]  = rl.RL_MouseCursor.RESIZE_ALL;
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.ResizeEW]   = rl.RL_MouseCursor.RESIZE_EW;
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.ResizeNESW] = rl.RL_MouseCursor.RESIZE_NESW;
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.ResizeNS]   = rl.RL_MouseCursor.RESIZE_NS;
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.ResizeNWSE] = rl.RL_MouseCursor.RESIZE_NWSE;
    mouse_cursor_map[cast(s64) cast(s32) MouseCursor.NotAllowed] = rl.RL_MouseCursor.NOT_ALLOWED;
}

setup_backend :: () {
    io := GetIO();
    io.BackendPlatformName = "imgui_impl_raylib".data;

    // HasMouseCursors: backend can set the OS cursor. (The Odin original also
    // sets RendererHasTextures, which the Jai ImGui module does not define.)
    io.BackendFlags_ = io.BackendFlags_ | .HasMouseCursors;

    io.MousePos = .{ x = 0.0, y = 0.0 };

    io.SetClipboardTextFn = set_clip_text_callback;
    io.GetClipboardTextFn = get_clip_text_callback;
}

// CJK font (Simplified Chinese) used by the editor (dialogue tool etc.).
// MapleMono-CN covers ASCII + CJK; it becomes Fonts[0] and the default font
// so editor text renders Chinese. The file is loaded relative to the working
// directory (repo root when launched via build_dev.bat), same as game assets.
CJK_FONT_PATH :: "resources/fonts/MapleMono-CN-Medium.ttf";
EDITOR_FONT_SIZE :: 16.0;

setup_font_texture :: () {
    io := GetIO();

    // AddFontFromFileTTF must run before the atlas is packed by
    // GetTexDataAsRGBA32 below. On failure (missing file / wrong cwd) we keep
    // imgui's built-in font (English only) instead of crashing.
    chinese_font := FontAtlas_AddFontFromFileTTF(
        io.Fonts,
        CJK_FONT_PATH.data,
        EDITOR_FONT_SIZE,
        null,
        FontAtlas_GetGlyphRangesChineseSimplifiedCommon(io.Fonts),
    );
    if chinese_font != null {
        io.FontDefault = chinese_font;
    }

    pixels: *u8;
    w: s32;
    h: s32;
    FontAtlas_GetTexDataAsRGBA32(io.Fonts, *pixels, *w, *h);
    font_texture_id = rlgl.rlLoadTexture(cast(*void) pixels, w, h, cast(s32) rlgl.rlPixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, 1);
    io.Fonts.TexID = cast(*void) cast(u64) font_texture_id;
}

set_clip_text_callback :: (user_data: *void, text: *u8) #c_call {
    rl.rlSetClipboardText(text);
}

get_clip_text_callback :: (user_data: *void) -> *u8 #c_call {
    return rl.rlGetClipboardText();
}
