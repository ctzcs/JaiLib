// shader_lab:color_picker —— 调色板会话持有稳定组名/字段 ID；打开时记下原色，实时预览，取消完整恢复。
// 切换目标、字段重载、Escape 或宿主 cancel（离焦、隐藏）时取消。只编辑临时预览值，不创建材质存档。
// 一比一移植自 olib kit/tools/shader_lab/color_picker.odin。Jai 差异：
//   | olib (Odin)                                    | JaiLib (Jai)                                          |
//   | ---------------------------------------------- | ----------------------------------------------------- |
//   | `switch int(h) { case 0: … case: }`            | if / else if 链（Jai 无 switch）                        |
//   | `hi > 0 ? delta/hi : 0`                        | 先取默认值再 if 改写（Jai 没有三元）                      |
//   | `math.floor / math.mod / abs / clamp`          | JM.floor / JM.mod（不存在时用 `x - floor(x)`）/ JM.abs  |
//   | `math.clamp(v, 0, 1)*255+0.5`                  | clamp(...)（Basic）                                    |
//   | `imgui.ColorButton(id, color, flags, size)`    | imgui_color_button(id, color, ImGui.ColorEditFlags.X, size) |
//   | `imgui.PushStyleColorImVec4`                   | ImGui.PushStyleColor(ImGui.Col.Text, ImGui.GetColorU32(C)) |
//   | `imgui.BeginPopupModal(POPUP, nil, flags)`     | imgui_begin_popup_modal(POPUP, null, ImGui.WindowFlags.AlwaysAutoResize) |
//   | `s.widgets[widget_key(id)] = rect`             | table_set(*s.widgets, key, rect)                      |
// 导入由 module.jai 提供。

Color_Picker :: struct {
    open: bool;
    group, field, label: string;
    original: [4] float32;
    color: [4] float32; // 归一化 RGBA，ColorPicker4 直接编辑
    minimum, maximum: float32;
}

COLOR_POPUP :: "调色板###color-picker";
COLOR_PRESETS :: [8][3] float32;

color_presets_init :: () -> [8][3] float32 {
    presets: [8][3] float32;
    presets[0] = .[1, 1, 1];
    presets[1] = .[0, 0, 0];
    presets[2] = .[1, 0.2, 0.2];
    presets[3] = .[1, 0.65, 0.1];
    presets[4] = .[0.3, 0.9, 0.4];
    presets[5] = .[0.1, 0.75, 1];
    presets[6] = .[0.4, 0.3, 1];
    presets[7] = .[1, 0.3, 0.7];
    return presets;
}

color_hsv_to_rgb :: (hsv: [3] float32) -> [3] float32 {
    h := (hsv[0] - JM.floor(hsv[0])) * 6;
    c := hsv[2] * hsv[1];
    x := c * (1 - JM.abs(sl_mod(h, 2) - 1));
    m := hsv[2] - c;
    rgb: [3] float32;
    sector := cast(int) h;
    if sector == 0      rgb = .[c, x, 0];
    else if sector == 1 rgb = .[x, c, 0];
    else if sector == 2 rgb = .[0, c, x];
    else if sector == 3 rgb = .[0, x, c];
    else if sector == 4 rgb = .[x, 0, c];
    else                rgb = .[c, 0, x];
    return .[rgb[0] + m, rgb[1] + m, rgb[2] + m];
}

// olib 的 math.mod（Jai 的 Math 里没有同名过程时用它）。
sl_mod :: (x: float32, y: float32) -> float32 {
    return x - y * JM.floor(x / y);
}

color_rgb_to_hsv :: (rgb: [3] float32) -> [3] float32 {
    hi := max(rgb[0], rgb[1], rgb[2]);
    lo := min(rgb[0], rgb[1], rgb[2]);
    delta := hi - lo;
    h: float32 = 0;
    if delta > 0.00001 {
        if hi == rgb[0]      h = (rgb[1] - rgb[2]) / delta;
        else if hi == rgb[1] h = 2 + (rgb[2] - rgb[0]) / delta;
        else                 h = 4 + (rgb[0] - rgb[1]) / delta;
        h /= 6;
        if h < 0 h += 1;
    }
    saturation: float32 = 0;
    if hi > 0 saturation = delta / hi;
    return .[h, saturation, hi];
}

color_rgba :: (value: [4] float32) -> F.Color {
    return F.Color.{
        cast(u8) (clamp(value[0], 0, 1) * 255 + 0.5),
        cast(u8) (clamp(value[1], 0, 1) * 255 + 0.5),
        cast(u8) (clamp(value[2], 0, 1) * 255 + 0.5),
        cast(u8) (clamp(value[3], 0, 1) * 255 + 0.5),
    };
}

color_normalize :: (value: [4] float32, minimum: float32, maximum: float32) -> [4] float32 {
    result: [4] float32;
    span := max(maximum - minimum, 0.00001);
    for v, i: value result[i] = clamp((v - minimum) / span, 0, 1);
    return result;
}

//@region 会话：不跨帧借用参数切片内的指针

color_picker_target :: (s: *Session) -> *sh.Value {
    p := *s.color_picker;
    if s.bank == null return null;
    for *group: array_view(s.bank.parameters, 0, s.bank.program_count) {
        if !group.available || group.name != p.group continue;
        for f, i: group.live.fields {
            if f.id == p.field && f.kind == .Color return *group.values[i];
        }
    }
    return null;
}

color_picker_close :: (s: *Session, accept: bool) {
    p := *s.color_picker;
    if !p.open return;
    if !accept {
        value := color_picker_target(s);
        if value != null value.number = p.original;
    }
    p.open = false;
    if p.group.data != null free(p.group.data);
    if p.field.data != null free(p.field.data);
    if p.label.data != null free(p.label.data);
    p.group = "";
    p.field = "";
    p.label = "";
}

color_picker_dispose :: (s: *Session) {
    color_picker_close(s, false);
}

color_picker_open :: (s: *Session, group: *Parameter_State, field: int) {
    color_picker_close(s, false);
    p := *s.color_picker;
    f := group.live.fields[field];
    p.group = copy_string(group.name);
    p.field = copy_string(f.id);
    p.label = copy_string(f.label);
    p.original = group.values[field].number;
    p.minimum = f.minimum;
    p.maximum = f.maximum;
    p.color = color_normalize(p.original, p.minimum, p.maximum);
    p.open = true;
    s.orbiting = false;
}
//@endregion

//@region ImGui 弹窗：模态，应用 / 取消；ColorPicker4 的色域、色相和透明度区域按 ImGui 布局登记矩形

color_picker_popup :: (s: *Session) {
    p := *s.color_picker;
    if p.open && !imgui_is_popup_open(COLOR_POPUP) imgui_open_popup(COLOR_POPUP);
    if !imgui_begin_popup_modal(COLOR_POPUP, null, ImGui.WindowFlags.AlwaysAutoResize) return;
    defer ImGui.EndPopup();
    value := color_picker_target(s);
    if !p.open || value == null || s.selected < 0 || s.selected >= s.bank.program_count ||
       s.bank.parameters[s.selected].name != p.group {
        color_picker_close(s, false);
        ImGui.CloseCurrentPopup();
        return;
    }
    style := ImGui.GetStyle();
    lab_text(p.label);
    ImGui.SetNextItemWidth(ImGui.GetFontSize() * 17);
    origin := ImGui.GetCursorScreenPos();
    width := ImGui.CalcItemWidth();
    color := p.color;
    imgui_color_picker4("##color", *color,
                       ImGui.ColorEditFlags.AlphaBar | ImGui.ColorEditFlags.NoSidePreview |
                       ImGui.ColorEditFlags.PickerHueBar | ImGui.ColorEditFlags.AlphaPreviewHalf);
    p.color = color;
    bar := ImGui.GetFrameHeight();
    square := max(bar, width - 2 * (bar + style.ItemInnerSpacing.x));
    hue := origin.x + square + style.ItemInnerSpacing.x;
    alpha := hue + bar + style.ItemInnerSpacing.x;
    table_set(*s.widgets, widget_key("color-sv"),
              Widget_Rect.{ min = .[origin.x, origin.y], max = .[origin.x + square, origin.y + square] });
    table_set(*s.widgets, widget_key("color-hue"),
              Widget_Rect.{ min = .[hue, origin.y], max = .[hue + bar, origin.y + square] });
    table_set(*s.widgets, widget_key("color-alpha"),
              Widget_Rect.{ min = .[alpha, origin.y], max = .[alpha + bar, origin.y + square] });
    presets := color_presets_init();
    for preset, i: presets {
        if i > 0 ImGui.SameLine();
        id := tprint("color-preset:%", i);
        size := ImGui.ImVec2.{ bar, bar };
        if imgui_color_button(tprint("##%", id), .[preset[0], preset[1], preset[2], 1], ImGui.ColorEditFlags.None, size) {
            p.color = .[preset[0], preset[1], preset[2], p.color[3]];
        }
        track(s, id);
    }
    original := color_normalize(p.original, p.minimum, p.maximum);
    lab_dim("原色 / 当前");
    size := ImGui.ImVec2.{ bar * 3, bar };
    if imgui_color_button("##color-original", original, ImGui.ColorEditFlags.AlphaPreviewHalf, size) p.color = original;
    track(s, "color-original");
    ImGui.SameLine();
    _ = imgui_color_button("##color-current", p.color, ImGui.ColorEditFlags.AlphaPreviewHalf, size);
    color8 := color_rgba(p.color);
    ImGui.SameLine();
    lab_text(tprint("#%02X%02X%02X%02X", color8.r, color8.g, color8.b, color8.a));
    accept := lab_button(s, "color-apply", "应用", false, false, "");
    ImGui.SameLine();
    cancel_button := lab_button(s, "color-cancel", "取消", false, false, "") || accept;
    for v, i: p.color value.number[i] = p.minimum + v * (p.maximum - p.minimum);
    if cancel_button {
        color_picker_close(s, accept);
        ImGui.CloseCurrentPopup();
    }
}
//@endregion
