// ui:text_input —— 单行文本输入 / 输入法候选框位置。
//
// clay 0.12 没有 ClipElementConfig，输入框的水平裁剪改用 Scroll 容器（只开 horizontal），
// 每帧把 -t.scroll 写进声明的 clip.childOffset（clay 布局按它偏移子元素，与 olib 一致）。
// 副作用：滚轮在输入框上会滚动它（olib 不会）；文本超出时由 clay 自己钳制在内容范围内，
// 因此 ui_text_width 的外层 clamp 仍然生效，行为在正常输入下一致。

//@region 宿主接入

// 宿主每帧在 ui_begin 前传入的文字编辑输入，字符串借用到 ui_end。
// text 是本帧键入的文字（含输入法提交）；paste 由宿主在 Ctrl+V 时读剪贴板填入。
// 其余是按键边沿（含按住重复）：Enter 为 submit，Escape 为 cancel。
UI_Text_Edit :: struct {
    text, paste: string;
    backspace, delete, left, right, home, end: bool;
    submit, cancel: bool;
}

// 同一时间只有一个文本框在编辑。
UI_Text_State :: struct {
    id:     u32;
    caret:  int;    // 字节位置，总在字符边界
    scroll: float32; // 水平滚动（逻辑像素）
    blink:  float32; // 光标闪烁计时，有编辑或移动时归零
    area:   F.Rect;  // 光标的渲染目标像素矩形，给输入法候选框
    editing, seen: bool;
}

UI_Text_Result :: struct {
    changed, submitted: bool;
}

ui_set_text_edit :: (ctx: *UI_Context, edit: UI_Text_Edit) {
    ctx.text_edit = edit;
}

// 上一帧是否有文本框在编辑。宿主据此打开系统文字输入，
// 并且不把字母、空格、方向键交给游戏；Tab 仍可作为导航移出文本框。
ui_text_editing :: (ctx: *UI_Context) -> bool {
    return ctx.text.editing;
}

// 编辑中光标的渲染目标像素矩形（不含 ui_set_visual 变换），交给输入法定位候选框。
ui_text_input_area :: (ctx: *UI_Context) -> (rect: F.Rect, ok: bool) {
    return ctx.text.area, ctx.text.editing;
}
//@endregion

//@region 控件

// 单行文本框，UTF-8 内容直接写入 buffer（调用方拥有），最多 max_bytes 字节，不截断半个字符。
// 按下即获得焦点并按点击位置放光标；也可用导航移入。编辑键见 UI_Text_Edit；Enter 返回 submitted，
// Escape 或导航 cancel 结束编辑。文字过长时水平滚动跟随光标。不支持选区、多行与密码掩码。
ui_text_input :: (ctx: *UI_Context, theme: *UI_Theme, id: string, buffer: *[..] u8,
                  placeholder: string = "", width: float32 = 240, max_bytes: int = 256,
                  widget: UI_Widget_Options = .{}) -> (result: UI_Text_Result) {
    element := clay.ID(id);
    options := widget;
    options.trigger = .Press;
    state := ui_interact(ctx, id, options);
    ui_focus_style(ctx, theme, state);
    font := ui_font_of(ctx, cast(int) theme.body_font_id);
    size := theme.body_font_size;
    pad := cast(float32) theme.padding;
    t := *ctx.text;
    editing := state.focused && !state.disabled;
    if editing && t.id != element.id {
        t.id = element.id;
        t.caret = buffer.count;
        t.scroll = 0;
        t.blink = 0;
    }
    if editing {
        result = ui_text_apply(ctx, element, id, font, size, pad, buffer, max_bytes, state.pressed);
        if ctx.text_edit.cancel {
            ctx.focused_id = 0;
            editing = false;
        }
    }
    if editing {
        ctx.input.keyboard = true;
        t.seen = true;
    }

    text := cast(string) buffer.*;
    inner := max(width - pad * 2, 1);
    caret_x: float32;
    if editing {
        caret := t.caret;
        if caret < 0 caret = 0;
        if caret > text.count caret = cast(int) text.count;
        caret_x = ui_text_width(font, ui_str_prefix(text, caret), size);
    }
    if editing {
        if caret_x - t.scroll > inner - 2 t.scroll = caret_x - inner + 2;
        if caret_x < t.scroll t.scroll = caret_x;
        t.scroll = clamp(t.scroll, 0, max(ui_text_width(font, text, size) - inner + 2, 0));
    }
    scroll: float32;
    if editing scroll = t.scroll;
    line := ui_text_line_height(font, size);
    // 编辑中的外框就是焦点框（UI_Focus_Style），这里只画悬停描边。
    // 0.14 的 border presence 由 width 是否为 0 决定，不需要额外的 has_border。
    border: clay.BorderElementConfig;
    if !editing && state.hovered && !state.disabled {
        border = ui_clay_border(1, ui_clay_color(theme.panel_border));
    }
    bg := theme.window_bg;
    if state.disabled bg = theme.panel;
    clay.UI(clay.ElementDeclaration.{
        id = element,
        layout = .{
            sizing = .{ width = clay.SizingFixed(max(width, 16)), height = clay.SizingFixed(line + pad * 2) },
            padding = clay.PaddingAll(theme.padding),
            childAlignment = .{ y = .CENTER },
        },
        clip = .{ horizontal = true, childOffset = .[ -scroll, 0 ] },
        backgroundColor = ui_clay_color(bg),
        cornerRadius = clay.CornerRadiusAll(theme.corner_radius),
        border = border,
    }, #code {
        shown := text;
        color := theme.text;
        if state.disabled color = theme.text_dim;
        if text.count == 0 {
            shown = placeholder;
            color = theme.text_dim;
        }
        config := ui_text_config(ctx, .{
            fontId = theme.body_font_id, fontSize = size, textColor = ui_clay_color(color), wrapMode = .NONE,
        });
        if config != null && shown.count > 0 clay.TextDynamic(shown, config);
        blink_phase := t.blink - JM.floor(t.blink);
        if editing && blink_phase < 0.5 {
            clay.UI(clay.ElementDeclaration.{
                layout = .{ sizing = .{ width = clay.SizingFixed(2), height = clay.SizingFixed(line) } },
                floating = .{
                    attachTo = .PARENT, offset = .[ pad + caret_x - scroll - 1, pad ],
                    clipTo = .ATTACHED_PARENT,
                },
                backgroundColor = ui_clay_color(theme.text),
            });
        }
    });
    if editing {
        // 上一帧布局的元素位置；视口原点与缩放换算到渲染目标像素。
        bb := clay.GetElementData(element).boundingBox;
        x := bb.x + pad + caret_x - scroll;
        t.area = .{
            ctx.viewport_origin.x + x * ctx.scale,
            ctx.viewport_origin.y + (bb.y + pad) * ctx.scale,
            2 * ctx.scale,
            line * ctx.scale,
        };
    }
    return;
}

ui_text_apply :: (ctx: *UI_Context, element: clay.ElementId, id: string, font: *F.Msdf_Font,
                  size: u16, pad: float32, buffer: *[..] u8, max_bytes: int, pressed: bool) -> (result: UI_Text_Result) {
    t := *ctx.text;
    edit := ctx.text_edit;
    t.caret = clamp(t.caret, 0, cast(int) buffer.count);
    if pressed {
        bb := clay.GetElementData(element).boundingBox;
        local, ok := ui_pointer_local(ctx, id);
        if ok {
            t.caret = ui_text_caret_at(font, cast(string) buffer.*, size, local.x - bb.x - pad + t.scroll);
        }
        t.blink = 0;
    }
    moved := false;
    if edit.backspace && t.caret > 0 {
        start := ui_utf8_prev(cast(string) buffer.*, t.caret);
        ui_buffer_remove(buffer, start, t.caret);
        t.caret = start;
        result.changed = true;
    }
    if edit.delete && t.caret < buffer.count {
        rest := ui_str_suffix(cast(string) buffer.*, t.caret);
        _, n := ui_utf8_next(*rest);
        if n > 0 ui_buffer_remove(buffer, t.caret, t.caret + n);
        result.changed = true;
    }
    if edit.left && t.caret > 0 {
        t.caret = ui_utf8_prev(cast(string) buffer.*, t.caret);
        moved = true;
    }
    if edit.right && t.caret < buffer.count {
        rest := ui_str_suffix(cast(string) buffer.*, t.caret);
        _, n := ui_utf8_next(*rest);
        t.caret += n;
        moved = true;
    }
    if edit.home {
        t.caret = 0;
        moved = true;
    }
    if edit.end {
        t.caret = buffer.count;
        moved = true;
    }
    inserts: [2] string = .[ edit.text, edit.paste ];
    for insert: inserts {
        rest := insert;
        while true {
            code, n := ui_utf8_next(*rest);
            if n <= 0 break;
            // 换行、制表等控制字符和无效字节丢弃；超出上限时停在完整字符处。
            if code < 0x20 || code == 0x7f || code == 0xFFFD continue;
            bytes: [4] u8;
            len := ui_utf8_encode(*bytes, code);
            if buffer.count + len > max_bytes break;
            ui_buffer_insert(buffer, t.caret, array_view(bytes, 0, len));
            t.caret += len;
            result.changed = true;
        }
    }
    if result.changed || moved t.blink = 0;
    result.submitted = edit.submit;
    return;
}
//@endregion

//@region 缓冲与测量助手

ui_buffer_insert :: (buf: *[..] u8, at: int, bytes: [] u8) {
    if bytes.count <= 0 return;
    old := buf.count;
    array_resize(buf, old + bytes.count);
    if at < 0 at = 0;
    if at > old at = old;
    tail := old - at;
    if tail > 0 memcpy(buf.data + at + bytes.count, buf.data + at, tail);
    for b, i: bytes buf.*[at + i] = b;
}

ui_buffer_remove :: (buf: *[..] u8, start: int, end: int) {
    a := start;
    b := end;
    if a < 0 a = 0;
    if b > buf.count b = buf.count;
    if b <= a return;
    tail := buf.count - b;
    if tail > 0 memcpy(buf.data + a, buf.data + b, tail);
    buf.count -= (b - a);
}

// text 的前 n 个字节（切片，不分配）。
ui_str_prefix :: (text: string, n: int) -> string {
    count := n;
    if count < 0 count = 0;
    if count > text.count count = cast(int) text.count;
    return .{ count = cast(s64) count, data = text.data };
}

ui_str_suffix :: (text: string, at: int) -> string {
    offset := at;
    if offset < 0 offset = 0;
    if offset > text.count offset = cast(int) text.count;
    return .{ count = text.count - cast(s64) offset, data = text.data + offset };
}

ui_text_width :: (font: *F.Msdf_Font, text: string, size: u16) -> float32 {
    return ui_measure_text(font, text, size, 0, 0).width;
}

ui_text_line_height :: (font: *F.Msdf_Font, size: u16) -> float32 {
    if font == null || font.Size <= 0 return cast(float32) size * 1.25;
    return font.LineHeight * cast(float32) size / font.Size;
}

// 离 x（逻辑像素，相对文字起点）最近的字符边界的字节位置。
ui_text_caret_at :: (font: *F.Msdf_Font, text: string, size: u16, x: float32) -> int {
    best, best_distance := 0, JM.abs(x);
    offset := 0;
    while offset < text.count {
        if offset != 0 {
            distance := JM.abs(ui_text_width(font, ui_str_prefix(text, offset), size) - x);
            if distance < best_distance {
                best, best_distance = offset, distance;
            }
        }
        rest := ui_str_suffix(text, offset);
        _, n := ui_utf8_next(*rest);
        if n <= 0 break;
        offset += n;
    }
    distance := JM.abs(ui_text_width(font, text, size) - x);
    if distance < best_distance best = cast(int) text.count;
    return best;
}
//@endregion
