// ui:widgets —— 主题、基础控件、图像、滑条、进度和容器。
//
// clay 0.12 语法映射（相对 olib 的 0.14 声明式）：
//   ElementDeclaration{id, layout, backgroundColor, cornerRadius, border, floating, clip}
//     → UI_Decl{id, layout, rect{color,cornerRadius}, border, floating, scroll}
//   clay.UI()(decl) { 子内容 } → ui_element(decl, children = #code { 子内容 })
//   枚举成员大写：.CENTER/.LEFT/.RIGHT/.TOP/.BOTTOM、.LEFT_TO_RIGHT/.TOP_TO_BOTTOM、.CAPTURE
//   clay.PaddingAll → ui_padding_all（0.12 没有这个助手）

//@region 主题

// 焦点框长什么样。零值是 2 像素 accent 色描边、贴着控件边缘。
// 焦点框在绘制阶段画在焦点控件自身之后，与控件同一层、同一裁剪，不影响布局和命中。
UI_Focus_Style :: struct {
    color:  F.Color;  // 描边颜色；零值用主题 accent
    width:  float32;  // 描边宽度（逻辑像素）；0 用 2
    offset: float32;  // 相对控件边缘外扩（负数内缩）
    // 设置后画这张九宫格贴图代替描边（圆角框、发光、角标等）；颜色作为染色，零值不染色。
    image: F.Subtexture;
    image_source_border, image_border: float32; // 源图片像素 / 逻辑像素，同 ui_nine_slice_decl
    keyboard_only: bool; // 只在导航或 ui_focus 获得的焦点上显示，鼠标点击获得的不画
    hidden:        bool;
}

UI_Theme :: struct {
    window_bg:     F.Color;
    panel:         F.Color;
    panel_border:  F.Color;
    button:        F.Color;
    button_hover:  F.Color;
    button_press:  F.Color;
    primary:       F.Color; // 主按钮底色（accent 填充）
    primary_hover: F.Color;
    primary_press: F.Color;
    text:          F.Color;
    text_dim:      F.Color; // 次级文本
    text_on_accent: F.Color; // 主按钮上的文字
    accent:        F.Color;
    ghost_hover:   F.Color; // 幽灵按钮 hover 蒙层（半透明叠加色）
    ghost_press:   F.Color;
    corner_radius:  float32;
    padding:        u16;
    body_font_id:   u16;
    body_font_size: u16;
    heading_font_size: u16;
    small_font_size:   u16;
    focus: UI_Focus_Style;
}

UI_THEME_DARK :: UI_Theme.{
    window_bg       = .{ 14, 15, 19, 255 },
    panel           = .{ 24, 26, 32, 255 },
    panel_border    = .{ 47, 51, 62, 255 },
    button          = .{ 42, 46, 56, 255 },
    button_hover    = .{ 55, 60, 73, 255 },
    button_press    = .{ 33, 36, 44, 255 },
    primary         = .{ 62, 109, 232, 255 },
    primary_hover   = .{ 82, 128, 242, 255 },
    primary_press   = .{ 48, 86, 196, 255 },
    text            = .{ 235, 237, 243, 255 },
    text_dim        = .{ 148, 154, 168, 255 },
    text_on_accent  = .{ 255, 255, 255, 255 },
    accent          = .{ 62, 109, 232, 255 },
    ghost_hover     = .{ 255, 255, 255, 26 },
    ghost_press     = .{ 255, 255, 255, 46 },
    corner_radius   = 8,
    padding         = 10,
    body_font_id    = 0,
    body_font_size  = 16,
    heading_font_size = 22,
    small_font_size   = 13,
}

// clay 颜色换算（F.Color 的 u8 通道 -> clay 的 0..1）。
ui_clay_color :: (c: F.Color) -> clay.Color {
    return .{ cast(float32) c.r / 255, cast(float32) c.g / 255,
              cast(float32) c.b / 255, cast(float32) c.a / 255 };
}

// clay 0.12 没有 PaddingAll。
ui_padding_all :: (p: u16) -> clay.Padding {
    return .{ left = p, right = p, top = p, bottom = p };
}

ui_layout_fill :: () -> clay.LayoutConfig {
    return .{ sizing = .{ width = clay.SizingGrow(), height = clay.SizingGrow() } };
}
//@endregion

//@region 控件

UI_Button_Style :: enum {
    Normal;  // 常规：深灰底
    Primary; // 主操作：accent 填充白字
    Ghost;   // 幽灵：透明底，hover 半透明白
}

// 按钮默认在内部松开时触发；options.trigger = .Press 可保留按下即触发。
// id 必须帧间稳定（clay 的悬停/过渡按 id 记忆；hover 查询发生在声明前，
// 用的是上一帧的布局——clay 官方模式）。
ui_button :: (ctx: *UI_Context, theme: *UI_Theme, id: string, label: string,
              options: UI_Widget_Options = .{}) -> bool {
    return ui_button_ex(ctx, theme, id, label, .Normal, options);
}

ui_button_ex :: (ctx: *UI_Context, theme: *UI_Theme, id: string, label: string,
                 style: UI_Button_Style, options: UI_Widget_Options = .{}) -> bool {
    state := ui_interact(ctx, id, options);
    ui_focus_style(ctx, theme, state);
    hovered := state.hovered && !state.disabled;
    clicked := state.clicked;

    bg, label_col: F.Color;
    if style == .Primary {
        bg = theme.primary;
        label_col = theme.text_on_accent;
        if hovered {
            if state.active bg = theme.primary_press;
            else bg = theme.primary_hover;
        }
    } else if style == .Ghost {
        bg = .{ 0, 0, 0, 0 };
        label_col = theme.text;
        if hovered {
            if state.active bg = theme.ghost_press;
            else bg = theme.ghost_hover;
        }
    } else {
        bg = theme.button;
        label_col = theme.text;
        if hovered {
            if state.active bg = theme.button_press;
            else bg = theme.button_hover;
        }
    }

    if state.disabled {
        label_col = theme.text_dim;
        bg = theme.panel;
    }
    min_width: float32;
    if style == .Ghost min_width = 0;
    else min_width = 80;
    ui_element(UI_Decl.{
        id = clay.ID(id),
        layout = .{
            sizing = .{
                width = clay.SizingFit(.{ min = min_width, max = 400 }),
                height = clay.SizingFit(),
            },
            padding = ui_padding_all(theme.padding),
            childAlignment = .{ x = .CENTER, y = .CENTER },
        },
        has_rect = true,
        rect = .{ color = ui_clay_color(bg), cornerRadius = clay.CornerRadiusAll(theme.corner_radius) },
    }, children = #code {
        ui_label_ex(ctx, theme, label, label_col, theme.body_font_size);
    });
    return clicked;
}

// 标题文本（heading 字号）。
ui_heading :: (ctx: *UI_Context, theme: *UI_Theme, text: string) {
    ui_label_ex(ctx, theme, text, theme.text, theme.heading_font_size);
}

// 标签：运行时字符串，使用 clay 默认 Words 换行。
ui_label :: (ctx: *UI_Context, theme: *UI_Theme, text: string) {
    ui_label_ex(ctx, theme, text, theme.text, theme.body_font_size);
}

// 次级标签（暗色小字）。
ui_label_dim :: (ctx: *UI_Context, theme: *UI_Theme, text: string) {
    ui_label_ex(ctx, theme, text, theme.text_dim, theme.small_font_size);
}

ui_label_ex :: (ctx: *UI_Context, theme: *UI_Theme, text: string, color: F.Color, size: u16) {
    config := ui_text_config(ctx, .{
        fontId = theme.body_font_id,
        fontSize = size,
        textColor = ui_clay_color(color),
    });
    if config == null return;
    ui_text_element(ctx, text, config); // 不用裸 clay.Text：文本元素要进视觉树
}

// 开关：点击翻转 *value，返回新值。胶囊轨道 + 圆形滑块。
ui_toggle :: (ctx: *UI_Context, theme: *UI_Theme, id: string, value: *bool,
              options: UI_Widget_Options = .{}) -> bool {
    state := ui_interact(ctx, id, options);
    ui_focus_style(ctx, theme, state);
    hovered := state.hovered && !state.disabled;
    if state.clicked value.* = !value.*;

    track := theme.button_hover;
    if value.* track = theme.accent;
    if hovered && !value.* track = theme.button;
    align: clay.ChildAlignment = .{ x = .LEFT, y = .CENTER };
    if value.* align = .{ x = .RIGHT, y = .CENTER };
    track_color := track;
    if state.disabled track_color = theme.panel;
    ui_element(UI_Decl.{
        id = clay.ID(id),
        layout = .{
            sizing = .{ width = clay.SizingFixed(36), height = clay.SizingFixed(20) },
            padding = .{ left = 2, right = 2, top = 2, bottom = 2 },
            childAlignment = align,
        },
        has_rect = true,
        rect = .{ color = ui_clay_color(track_color), cornerRadius = clay.CornerRadiusAll(10) }, // 半高 = 胶囊
    }, children = #code {
        ui_element(UI_Decl.{
            // 下标 1：滑块子元素的稳定 id
            id = clay.ID(id, 1),
            layout = .{ sizing = .{ width = clay.SizingFixed(16), height = clay.SizingFixed(16) } },
            has_rect = true,
            rect = .{ color = ui_clay_color(theme.text), cornerRadius = clay.CornerRadiusAll(8) }, // 半宽 = 圆
        });
    });
    return value.*;
}

// 分隔线：横贯父容器宽度的 1px 细线。
ui_separator :: (ctx: *UI_Context, theme: *UI_Theme) {
    ui_element(UI_Decl.{
        layout = .{ sizing = .{ width = clay.SizingGrow(), height = clay.SizingFixed(1) } },
        has_rect = true,
        rect = .{ color = ui_clay_color(theme.panel_border) },
    });
}

// 水平行容器声明（gap 像素间距，子元素垂直居中）。子内容在
// ui_element(ui_row_decl(...), children = #code { ... }) 里声明。
ui_row_decl :: (gap: u16 = 8) -> UI_Decl {
    return .{
        layout = .{
            sizing = .{ width = clay.SizingGrow(), height = clay.SizingFit() },
            childGap = gap,
            childAlignment = .{ x = .LEFT, y = .CENTER },
        },
    };
}

// 占位元素：吃掉行内剩余空间（推右对齐用）。
ui_spacer :: () {
    ui_element(UI_Decl.{
        layout = .{ sizing = .{ width = clay.SizingGrow(), height = clay.SizingFixed(1) } },
    });
}

// 面板：带内边距与圆角的容器声明（子内容在 ui_element 的 children 块里声明）。
ui_panel_decl :: (theme: *UI_Theme, gap: u16 = 8, width: float32 = 0) -> UI_Decl {
    sizing: clay.SizingAxis = clay.SizingGrow();
    if width > 0 sizing = clay.SizingFixed(width);
    return .{
        layout = .{
            sizing = .{ width = sizing, height = clay.SizingFit() },
            layoutDirection = .TOP_TO_BOTTOM, childGap = gap,
            padding = ui_padding_all(cast(u16) (theme.padding * 2)),
        },
        has_rect = true,
        rect = .{
            color = ui_clay_color(theme.panel),
            cornerRadius = clay.CornerRadiusAll(theme.corner_radius + 2),
        },
    };
}

// 面板描边容器：padding 1px + 边框色圆角底，包在 panel 外层即得 1px 边框。
ui_panel_border_decl :: (theme: *UI_Theme) -> UI_Decl {
    return .{
        layout = .{ padding = .{ left = 1, right = 1, top = 1, bottom = 1 } },
        has_rect = true,
        rect = .{
            color = ui_clay_color(theme.panel_border),
            cornerRadius = clay.CornerRadiusAll(theme.corner_radius + 3),
        },
    };
}
//@endregion

//@region 游戏常用控件 —— 图像 / 图像按钮 / 进度 / 滑条

// 控件获得焦点时登记它所用主题的焦点框样式；内置控件都会调用。自定义控件在 ui_interact 之后
// 调用它就能用自己主题的样式，否则沿用最近一次登记的样式。
ui_focus_style :: (ctx: *UI_Context, theme: *UI_Theme, state: UI_Interaction) {
    if !state.focused || state.disabled return;
    style := theme.focus;
    if style.color == F.Color.{} style.color = theme.accent;
    if style.width <= 0 style.width = 2;
    ctx.focus_style = style;
}

UI_Image_Data :: struct {
    sub: F.Subtexture;
    source_border, border: float32;
    tint: F.Color; // clay 0.12 的 Custom 命令没有 backgroundColor，染色存在这里
}

// 可容纳文字/图标的图片背景声明。纹理由调用者持有，颜色使用预乘 alpha。
ui_image_decl :: (ctx: *UI_Context, sub: F.Subtexture, tint: F.Color = .{ 255, 255, 255, 255 }) -> UI_Decl {
    decl := UI_Decl.{
        layout = .{ sizing = .{ width = clay.SizingGrow(), height = clay.SizingGrow() } },
    };
    if sub.Tex == null || ctx.image_len >= ctx.image_pool.count {
        ctx.pool_overflow = ctx.pool_overflow || ctx.image_len >= ctx.image_pool.count;
        return decl;
    }
    data := *ctx.image_pool[ctx.image_len];
    data.* = .{ sub = sub, tint = tint };
    ctx.image_len += 1;
    decl.has_custom = true;
    decl.custom = cast(*void) data;
    return decl;
}

// 整张纹理的对称九宫格背景。source_border 为源图片像素，border 为逻辑像素。
// 保留四角比例，边缘仅沿对应方向拉伸；透明圆角需由图片自身提供。
ui_nine_slice_decl :: (ctx: *UI_Context, texture: *F.Texture, source_border: float32, border: float32,
                       tint: F.Color = .{ 255, 255, 255, 255 }) -> UI_Decl {
    sub: F.Subtexture;
    if texture != null sub = F.subtexture_make_full(texture);
    decl := ui_image_decl(ctx, sub, tint);
    if decl.custom != null {
        data := cast(*UI_Image_Data) decl.custom;
        data.source_border = clamp(source_border, 0, min(sub.Frame.w, sub.Frame.h) * 0.5);
        data.border = max(border, 0);
    }
    return decl;
}

// Subtexture 同时支持整张贴图、图集区域和裁切后的帧；按 Frame 尺寸缩放。
// sub 被复制到帧内池，GPU 纹理仍由调用者拥有。尺寸单位为逻辑像素。
ui_image :: (ctx: *UI_Context, sub: F.Subtexture, width: float32, height: float32,
             tint: F.Color = .{ 255, 255, 255, 255 }) {
    decl := ui_image_decl(ctx, sub, tint);
    if decl.custom == null return;
    decl.layout.sizing = .{
        width = clay.SizingFixed(max(width, 0)),
        height = clay.SizingFixed(max(height, 0)),
    };
    ui_element(decl);
}

ui_image_button :: (ctx: *UI_Context, theme: *UI_Theme, id: string, sub: F.Subtexture,
                    size: float32 = 48, options: UI_Widget_Options = .{}) -> bool {
    state := ui_interact(ctx, id, options);
    ui_focus_style(ctx, theme, state);
    bg := theme.button;
    if state.hovered bg = theme.button_hover;
    if state.active bg = theme.button_press;
    tint := F.Color_White;
    if state.disabled {
        bg = theme.panel;
        tint = theme.text_dim;
    }
    ui_element(UI_Decl.{
        id = clay.ID(id),
        layout = .{ padding = ui_padding_all(theme.padding) },
        has_rect = true,
        rect = .{ color = ui_clay_color(bg), cornerRadius = clay.CornerRadiusAll(theme.corner_radius) },
    }, children = #code {
        ui_image(ctx, sub, size, size, tint);
    });
    return state.clicked;
}

// value 按 0..1 归一化，越界钳制；零进度不产生最小可见填充。
ui_progress_bar :: (ctx: *UI_Context, theme: *UI_Theme, value: float32,
                    width: float32 = 200, height: float32 = 12) {
    clamped_value := clamp(value, 0, 1);
    ui_element(UI_Decl.{
        layout = .{
            sizing = .{ width = clay.SizingFixed(max(width, 0)), height = clay.SizingFixed(max(height, 0)) },
        },
        has_rect = true,
        rect = .{ color = ui_clay_color(theme.button), cornerRadius = clay.CornerRadiusAll(height * 0.5) },
    }, children = #code {
        if clamped_value > 0 {
            ui_element(UI_Decl.{
                layout = .{
                    sizing = .{
                        width = clay.SizingFixed(max(width, 0) * clamped_value),
                        height = clay.SizingFixed(max(height, 0)),
                    },
                },
                has_rect = true,
                rect = .{
                    color = ui_clay_color(theme.accent),
                    cornerRadius = clay.CornerRadiusAll(height * 0.5),
                },
            });
        }
    });
}

// 返回本帧是否改变值。鼠标按下捕获后可拖出区域；导航 adjust 单位为 step。
ui_slider :: (ctx: *UI_Context, theme: *UI_Theme, id: string, value: *float32,
              minimum: float32 = 0, maximum: float32 = 1, step: float32 = 0.05,
              width: float32 = 200, options: UI_Widget_Options = .{}) -> bool {
    state := ui_interact(ctx, id, options);
    ui_focus_style(ctx, theme, state);
    before := value.*;
    span := maximum - minimum;
    min_width := max(width, 24);
    if !state.disabled && span > 0 {
        box := clay.GetElementData(clay.ID(id));
        local, invertible := ui_pointer_local(ctx, id);
        if box.found && invertible && (state.active || state.released) {
            t := clamp((local.x - box.boundingBox.x - 8) / max(box.boundingBox.width - 16, 1), 0, 1);
            value.* = minimum + span * t;
        }
        if state.focused && ctx.navigation.adjust != 0 {
            if step > 0 value.* += ctx.navigation.adjust * step;
            else value.* += ctx.navigation.adjust * (span * 0.01);
        }
        value.* = clamp(value.*, minimum, maximum);
    }
    t: float32;
    if span > 0 t = clamp((value.* - minimum) / span, 0, 1);
    track_color := theme.button;
    if state.disabled track_color = theme.panel;
    knob_color := theme.accent;
    if state.disabled knob_color = theme.text_dim;
    ui_element(UI_Decl.{
        id = clay.ID(id),
        layout = .{
            sizing = .{ width = clay.SizingFixed(min_width), height = clay.SizingFixed(24) },
            padding = .{ left = cast(u16) (t * (min_width - 16)), top = 4 },
        },
        has_rect = true,
        rect = .{ color = ui_clay_color(track_color), cornerRadius = clay.CornerRadiusAll(12) },
    }, children = #code {
        ui_element(UI_Decl.{
            layout = .{ sizing = .{ width = clay.SizingFixed(16), height = clay.SizingFixed(16) } },
            has_rect = true,
            rect = .{ color = ui_clay_color(knob_color), cornerRadius = clay.CornerRadiusAll(8) },
        });
    });
    return before != value.*;
}
//@endregion

//@region 容器 —— 列 / 滚动区域 / 全屏模态遮罩

ui_column_decl :: (gap: u16 = 8) -> UI_Decl {
    decl := ui_row_decl(gap);
    decl.layout.layoutDirection = .TOP_TO_BOTTOM;
    decl.layout.childAlignment = .{ x = .LEFT, y = .TOP };
    return decl;
}

// 内容竖排、滚轮滚动、双轴裁剪；width=0 时占满父容器。
UI_Scroll_Entry :: struct {
    id:     u32;
    offset: clay.Vector2;
    seen:   bool;
}

ui_scroll_decl :: (ctx: *UI_Context, id: string, height: float32,
                   width: float32 = 0, gap: u16 = 8) -> UI_Decl {
    ui_block_pointer(ctx, id);
    decl := ui_column_decl(gap);
    decl.id = clay.ID(id);
    width_axis: clay.SizingAxis = clay.SizingGrow();
    if width > 0 width_axis = clay.SizingFixed(width);
    decl.layout.sizing = .{ width = width_axis, height = clay.SizingFixed(height) };
    // clay 0.12 的裁剪就是 Scroll 容器（没有独立的 Clip 配置）。
    decl.has_scroll = true;
    decl.scroll = .{ vertical = true, horizontal = true };
    for *scroll: ctx.scrolls {
        if scroll.id == decl.id.id {
            scroll.seen = true;
            return decl;
        }
    }
    array_add(*ctx.scrolls, UI_Scroll_Entry.{ id = decl.id.id, seen = true });
    return decl;
}

// 配合 ui_set_modal/ui_set_scope；尺寸覆盖逻辑 viewport，内容居中。
ui_modal_decl :: (ctx: *UI_Context, id: string) -> UI_Decl {
    return .{
        id = clay.ID(id),
        layout = .{
            sizing = .{ width = clay.SizingFixed(ctx.width), height = clay.SizingFixed(ctx.height) },
            childAlignment = .{ x = .CENTER, y = .CENTER },
        },
        has_rect = true,
        rect = .{ color = .{ 0, 0, 0, 0.65 } },
        // olib: floating = {attachTo = .Root, zIndex = 100}；0.12 用 parentId 指根容器。
        has_floating = true,
        floating = .{
            parentId = clay.ID(UI_ROOT_ID).id,
            zIndex = 100,
            pointerCaptureMode = .CAPTURE,
        },
    };
}
//@endregion
