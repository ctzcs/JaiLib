// ui:controls —— 下拉框 / 虚拟列表 / 拖放。
//
// 浮层用 0.14 的 floating 定位：attachTo = .PARENT 挂到声明处的层级父元素（与 olib 一致），
// 挂到 root 的写法见 ui_modal_decl（attachTo = .ROOT）。

//@region 下拉框

// 超过这么多项时浮层改为滚动区。
UI_DROPDOWN_VISIBLE_ROWS :: 6;

// 按钮显示当前项，点开后在下方浮层列出 options；点选、点外面或导航 cancel 关闭，同一时间只展开一个。
// 用 activate 打开时焦点移到当前项，可用 next 在选项间移动。selected 越界时按钮为空。
// 返回本帧是否改了 selected。id 帧间稳定；选项 ID 为 "<id>#<下标>"，浮层为 "<id>#popup"。
ui_dropdown :: (ctx: *UI_Context, theme: *UI_Theme, id: string, options: [] string,
                selected: *int, width: float32 = 200, widget: UI_Widget_Options = .{}) -> bool {
    element := clay.ID(id);
    popup_id := tprint("%#popup", id);
    state := ui_interact(ctx, id, widget);
    ui_focus_style(ctx, theme, state);
    open := ctx.dropdown_id == element.id;
    if state.disabled {
        open = false;
    } else if state.clicked {
        open = !open;
        if open && ctx.navigation.activate && options.count > 0 {
            ui_focus(ctx, tprint("%#%", id, clamp(selected.*, 0, options.count - 1)));
            // 这次确认已用来打开，不能再让刚获得焦点的选项当作点击。
            ctx.navigation.activate = false;
        }
    } else if open && ui_clicked(ctx) && !clay.PointerOver(element) && !clay.PointerOver(clay.ID(popup_id)) {
        open = false;
    }
    if open {
        ctx.dropdown_id = element.id;
    } else if ctx.dropdown_id == element.id {
        ctx.dropdown_id = 0;
    }

    bg := theme.button;
    if state.disabled bg = theme.panel;
    else if state.active bg = theme.button_press;
    else if state.hovered || open bg = theme.button_hover;
    label_color := theme.text;
    if state.disabled label_color = theme.text_dim;
    changed := false;
    width_axis := max(width, 48);
    clay.UI(clay.ElementDeclaration.{
        id = element,
        layout = .{
            sizing = .{ width = clay.SizingFixed(width_axis), height = clay.SizingFit() },
            padding = clay.PaddingAll(theme.padding),
            childGap = 8,
            childAlignment = .{ y = .CENTER },
        },
        backgroundColor = ui_clay_color(bg),
        cornerRadius = clay.CornerRadiusAll(theme.corner_radius),
    }, #code {
        current := "";
        if selected.* >= 0 && selected.* < options.count current = options[selected.*];
        ui_label_ex(ctx, theme, current, label_color, theme.body_font_size);
        ui_spacer();
        ui_label_ex(ctx, theme, ui_dropdown_arrow(ctx, theme, open), theme.text_dim, theme.body_font_size);
        if open {
            if ui_dropdown_popup(ctx, theme, id, popup_id, options, selected, width_axis) changed = true;
        }
    });
    return changed;
}

ui_dropdown_popup :: (ctx: *UI_Context, theme: *UI_Theme, id: string, popup_id: string,
                      options: [] string, selected: *int, width: float32) -> bool {
    changed := false;
    ui_block_pointer(ctx, popup_id);
    clay.UI(clay.ElementDeclaration.{
        id = clay.ID(popup_id),
        layout = .{
            sizing = .{ width = clay.SizingFixed(width), height = clay.SizingFit() },
            layoutDirection = .TOP_TO_BOTTOM,
            padding = clay.PaddingAll(4),
        },
        floating = .{
            attachTo = .PARENT,
            attachment = .{ element = .LEFT_TOP, parent = .LEFT_BOTTOM },
            offset = .[0, 4],
            zIndex = 60,
            pointerCaptureMode = .CAPTURE,
        },
        backgroundColor = ui_clay_color(theme.panel),
        cornerRadius = clay.CornerRadiusAll(theme.corner_radius),
        border = ui_clay_border(1, ui_clay_color(theme.panel_border)),
    }, #code {
        list: clay.ElementDeclaration;
        if options.count > UI_DROPDOWN_VISIBLE_ROWS {
            row := cast(float32) theme.body_font_size * 1.4 + cast(float32) theme.padding;
            list = ui_scroll_decl(ctx, tprint("%#list", id), row * UI_DROPDOWN_VISIBLE_ROWS, gap = 2);
        } else {
            list = ui_column_decl(2);
        }
        clay.UI(list, #code {
            for option, i: options {
                option_id := tprint("%#%", id, i);
                s := ui_interact(ctx, option_id, UI_Widget_Options.{ no_focus_ring = true }); // 选项用底色表示焦点
                row_bg := F.Color.{};
                if i == selected.* row_bg = theme.button;
                if s.hovered || s.focused row_bg = theme.button_hover;
                text_color := theme.text;
                if i == selected.* text_color = theme.accent;
                clay.UI(clay.ElementDeclaration.{
                    id = clay.ID(option_id),
                    layout = .{
                        sizing = .{ width = clay.SizingGrow(), height = clay.SizingFit() },
                        padding = .{
                            left = theme.padding, right = theme.padding,
                            top = theme.padding / 2, bottom = theme.padding / 2,
                        },
                    },
                    backgroundColor = ui_clay_color(row_bg),
                    cornerRadius = clay.CornerRadiusAll(max(theme.corner_radius - 2, 0)),
                }, #code {
                    ui_label_ex(ctx, theme, option, text_color, theme.body_font_size);
                });
                if s.clicked {
                    changed = selected.* != i;
                    selected.* = i;
                    ctx.dropdown_id = 0;
                    ui_focus(ctx, id);
                }
            }
        });
    });
    return changed;
}

// 字体有向下三角就用它，否则退回字母 v。
ui_dropdown_arrow :: (ctx: *UI_Context, theme: *UI_Theme, open: bool) -> string {
    font := ui_font_of(ctx, cast(int) theme.body_font_id);
    glyph: s32 = 0x25BC;
    if open glyph = 0x25B2;
    if font != null {
        found, _ := ui_msdf_glyph(font, glyph);
        if found return tprint("%", cast(u32) glyph);
    }
    if open return "^";
    return "v";
}
//@endregion

//@region 虚拟列表

// 长列表只声明可见行：before / after 是前后占位高度，[first, last) 是要声明的行。
UI_Virtual_Range :: struct {
    first, last: int;
    before, after: float32;
}

// 固定行高 row_height（含行间距）的 count 行列表，放在 ID 为 id、高 view_height 的滚动区里。
// 按滚动区本帧开始时的滚动位置计算，上下多声明 overscan 行；滚动区须用 gap = 0，
// 先 ui_virtual_spacer(range.before)，再声明 [first, last) 行，最后 ui_virtual_spacer(range.after)。
ui_virtual_range :: (ctx: *UI_Context, id: string, count: int, row_height: float32,
                     view_height: float32, overscan := 2) -> UI_Virtual_Range {
    if count <= 0 || row_height <= 0 return .{};
    key := clay.ID(id).id;
    top: float32;
    for scroll: ctx.scrolls if scroll.id == key top = -scroll.offset[1];
    first := clamp(cast(int) JM.floor(top / row_height) - overscan, 0, count);
    last := clamp(cast(int) JM.ceil((top + view_height) / row_height) + overscan, first, count);
    return .{ first, last, cast(float32) first * row_height, cast(float32) (count - last) * row_height };
}

// 虚拟列表的占位：撑开被省略行的高度，使滚动范围与完整列表一致。
ui_virtual_spacer :: (height: float32) {
    if height <= 0 return;
    clay.UI(clay.ElementDeclaration.{
        layout = .{ sizing = .{ width = clay.SizingGrow(), height = clay.SizingFixed(height) } },
    });
}
//@endregion

//@region 拖放

// 按下源控件后移动超过这么多逻辑像素才算开始拖动，否则仍是点击。
UI_DRAG_THRESHOLD: float32 : 4;

UI_Drag :: struct {
    source: u32;
    payload: int;
    origin: F.Vector2;
    pending, dragging: bool;
}

// 在源控件的 ui_interact 之后调用（同一帧、同一 id），payload 由调用方定义（如背包格下标）。
// 返回该源这一帧是否正被拖动。拖动结束的那次松开不算点击；导航 cancel 取消拖动。
ui_drag_source :: (ctx: *UI_Context, id: string, state: UI_Interaction, payload: int) -> bool {
    key := clay.ID(id).id;
    if state.pressed {
        ctx.drag = .{ source = key, payload = payload, origin = .{ ctx.pointer_x, ctx.pointer_y }, pending = true };
    }
    d := *ctx.drag;
    if d.source != key return false;
    if d.pending && state.active {
        dx := ctx.pointer_x - d.origin.x;
        dy := ctx.pointer_y - d.origin.y;
        if dx * dx + dy * dy >= UI_DRAG_THRESHOLD * UI_DRAG_THRESHOLD {
            d.pending = false;
            d.dragging = true;
        }
    }
    return d.dragging;
}

// 拖动中返回载荷，供目标高亮或画跟随指针的预览。
ui_dragging :: (ctx: *UI_Context) -> (payload: int, ok: bool) {
    return ctx.drag.payload, ctx.drag.dragging;
}

// 跟随指针的预览位置（逻辑坐标），用 floating 挂到 root 画在最上层。
ui_drag_position :: (ctx: *UI_Context) -> F.Vector2 {
    return .{ ctx.pointer_x, ctx.pointer_y };
}

// 放置目标，在目标元素声明前调用（按上一帧布局命中）。拖动中指针在目标上时 hovered=true，
// 松开那一帧 dropped=true 并返回载荷；模态期间只有模态作用域内的目标可放置。
ui_drop_target :: (ctx: *UI_Context, id: string) -> (payload: int, hovered: bool, dropped: bool) {
    if !ctx.drag.dragging return 0, false, false;
    if ctx.modal_id != 0 && ctx.scope_id != ctx.modal_id return 0, false, false;
    hovered = clay.PointerOver(clay.ID(id));
    dropped = hovered && ui_released(ctx);
    return ctx.drag.payload, hovered, dropped;
}
//@endregion
