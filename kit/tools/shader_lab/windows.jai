// shader_lab:windows —— 控制窗口：播放控制、工作区、Shader 选择、Pass 流程、参数 / 预览设置与诊断。
// 选择参数不会隐式切换预览输出；布局、滚动和停靠交给宿主的 ImGui。
// 每帧入口与预览窗口：Pass 直接渲染进自己的目标，预览窗口按最终输出像素 1:1 显示，
// UI 由宿主的 ImGui 在全部 Pass 之后绘制，不进入模糊/反馈链。
// 一比一移植自 olib kit/tools/shader_lab/windows.odin。Jai 差异：
//   | olib (Odin)                                        | JaiLib (Jai)                                          |
//   | -------------------------------------------------- | ----------------------------------------------------- |
//   | `imgui_foster.IconButton(&s.icons, …)`（图标）       | lab_button = 纯文字 ImGui.Button（图标图集未移植）        |
//   | `imgui_foster.Icons` / `IconsInit`                 | Icon_Set（空表；icons_init 恒成功，见 module.jai 第 5 条）|
//   | `hash.fnv64a(transmute([]u8)id)`                   | sl_hash_string（同参数 FNV-1a 64）                      |
//   | `s.widgets[id] = rect`                             | table_set(*s.widgets, key, rect)                      |
//   | `imgui.TextUnformatted(cstr(t))`                   | ImGui.TextUnformatted(t)                              |
//   | `imgui.PushStyleColorImVec4(.Text, C)`             | ImGui.PushStyleColor(ImGui.Col.Text, ImGui.GetColorU32(C)) |
//   | `imgui.BeginChild("passes", {0,h}, {.Borders})`     | imgui_begin_child("passes", .{0, h}, true)             |
//   | `imgui.Image(imgui_foster.Texture(t), size)`       | ImGui.Image(imgui_texture_id(t), size)                |
//   | `imgui.DrawList_AddRectFilled(dl, a, b, col)`      | dl.AddRectFilled(a, b, col)（ImDrawList 成员）          |
//   | `rows := clamp(f32(len(order)), 1, 6)`             | cast(float32) clamp(order.count, 1, 6)                |
//   | `quad(r, tex, foster.Rect{…})`                     | 同（类型换成 F.Rect，字段 x/y/w/h）                      |
// 导入由 module.jai 提供。

//@region 图标表（移植为空表，见 module.jai 第 5 条）

// 界面用到的内置图标名。olib 在 init 时从内置图集挑出来缩成 ICON_CELL 像素的小图标表；
// 该图集（assets/icons/game-icons.*）不属于本仓库，r2d.builtin_icons_decode 也就没有移植。
// 这里保留名字表与类型，图标按钮退化为文字按钮，稳定 ID 不变。
ICON_NAMES :: [18] string;
ICON_CELL :: 40;

Icon_Set :: struct {
    icons: [..] *F.Texture;
    rects: HASH.Table(string, F.Rect_Int);
}

icons_init :: (set: Icon_Set) -> bool {
    // 空表也是「初始化成功」：lab_button 只用文字，不依赖图集。
    return true;
}

icons_dispose :: (set: Icon_Set) {
    for texture: set.icons {
        if texture != null {
            F.texture_dispose(texture);
            free(texture);
        }
    }
    if set.icons.data != null array_free(set.icons);
    deinit(*set.rects);
}

// olib 的 imgui_foster.Texture(t)：把 *F.Texture 转成 ImGui 的纹理 ID（jfoster 用资源句柄）。
// jacket 的 ImTextureID 是 *void（不是 olib 的 u64/ImTextureID 整数别名），空值写 null。
imgui_texture_id :: (texture: *F.Texture) -> ImGui.ImTextureID {
    if texture == null return null;
    return cast(ImGui.ImTextureID) texture.handle;
}
//@endregion

//@region 控件封装：图标按钮、复选框与控件矩形登记

ERROR_COLOR :: ImGui.ImVec4.{ 1, 0.48, 0.45, 1 };

// ImGui 屏幕坐标（窗口逻辑坐标，与鼠标输入相同）。
Widget_Rect :: struct {
    min, max: [2] float32;
}

// olib 的 hash.fnv64a：参数与 ID 稳定性一致（宿主注入点击时用同一 ID）。
sl_hash_string :: (text: string) -> u64 {
    hash: u64 = 0xcbf29ce484222325;
    for c: text {
        hash = hash ^ cast(u64) c;
        hash = hash * 0x100000001b3;
    }
    return hash;
}

widget_key :: (id: string) -> u64 {
    return sl_hash_string(id);
}

// 登记上一个控件的矩形，宿主或外部检查可按稳定 ID 定位（例如注入点击）。
track :: (s: *Session, id: string) {
    rect := Widget_Rect.{ min = .[ImGui.GetItemRectMin().x, ImGui.GetItemRectMin().y],
                          max = .[ImGui.GetItemRectMax().x, ImGui.GetItemRectMax().y] };
    table_set(*s.widgets, widget_key(id), rect);
}

// 最近一次 draw 登记的控件矩形；该帧没有画出这个控件时 found=false。
widget_rect :: (s: *Session, id: string) -> (Widget_Rect, bool) {
    // jacket 的 table_find 返回 (success, value)，与 olib 的 `v, ok := t[k]` 顺序相反。
    found, rect := table_find(*s.widgets, widget_key(id));
    return rect, found;
}

lab_button :: (s: *Session, id: string, label: string, selected := false, grow := false, icon := "") -> bool {
    // 图标表为空：selected 用 ImGui 的按钮配色表达，grow 撑满宽度。
    if selected ImGui.PushStyleColor(ImGui.Col.Button, ImGui.GetColorU32(ImGui.Col.ButtonHovered, 1.0));
    defer if selected ImGui.PopStyleColor();
    clicked := false;
    if grow clicked = imgui_button(tprint("%##%", label, id), .{ -1, 0 });
    else       clicked = imgui_button(tprint("%##%", label, id));
    track(s, id);
    return clicked;
}

lab_checkbox :: (s: *Session, id: string, checked: bool) -> bool {
    value := checked;
    clicked := imgui_checkbox(tprint("##%", id), *value);
    track(s, id);
    return clicked;
}

lab_text :: (text: string) {
    ImGui.TextUnformatted(text);
}

lab_dim :: (text: string) {
    ImGui.PushStyleColor(ImGui.Col.Text, ImGui.GetColorU32(ImGui.Col.TextDisabled, 1.0));
    ImGui.TextUnformatted(text);
    ImGui.PopStyleColor();
}

// 编译器路径常没有空格；ImGui 在宽度不够时按字符换行，完整原文仍输出到控制台。
lab_error :: (text: string) {
    ImGui.PushStyleColor(ImGui.Col.Text, ImGui.GetColorU32(ERROR_COLOR));
    ImGui.PushTextWrapPos(0);
    ImGui.TextUnformatted(text);
    ImGui.PopTextWrapPos();
    ImGui.PopStyleColor();
}

// 下一个图标按钮放得下就接在同一行，否则换行；宽度与 IconButton 的计算一致。
lab_same_line :: (label: string, icon := true) {
    style := ImGui.GetStyle();
    width := ImGui.CalcTextSize(label).x + style.FramePadding.x * 2;
    if icon {
        width += JM.floor(ImGui.GetFontSize() * 1.25 + 0.5);
        if label != "" width += style.ItemInnerSpacing.x;
    }
    right := ImGui.GetCursorScreenPos().x + ImGui.GetContentRegionAvail().x;
    if ImGui.GetItemRectMax().x + style.ItemSpacing.x + width <= right ImGui.SameLine();
}

// 把下一个控件推到当前行最右，宽度 width。
align_right :: (width: float32) {
    ImGui.SameLine();
    ImGui.SetCursorPosX(ImGui.GetCursorPosX() + max(cast(float32) 0, ImGui.GetContentRegionAvail().x - width));
}
//@endregion

//@region 控制窗口

control_window :: (s: *Session) {
    ImGui.SetNextWindowSize(ImGui.ImVec2.{ 360, 680 }, ImGui.Cond.FirstUseEver);
    visible := imgui_begin(CONTROL_WINDOW);
    defer ImGui.End();
    if !visible return;
    paused_label := "暂停";
    if s.paused paused_label = "播放";
    if lab_button(s, "pause", paused_label, false, false, "") s.paused = !s.paused;
    if s.selected_shader >= 0 {
        lab_same_line("单步", true);
        if lab_button(s, "shader-step", "单步", false, false, "media/next-frame") step(s);
        lab_same_line("重置反馈", true);
        if lab_button(s, "shader-reset", "重置反馈", false, false, "ui/refresh") reset_history(s);
    }
    failed := s.bank_error != "" || s.parameter_watch.status == .Error;
    if failed {
        imgui_text_colored_v(ERROR_COLOR, "编译失败 · 保留上次结果");
    } else {
        if s.pending_bank != null lab_dim("正在编译");
        else                     lab_dim("LIVE · 保存源码即更新");
    }
    ImGui.Separator();
    if lab_button(s, "workspace:2d", "2D", s.workspace == 0, false, "media/image") select_workspace(s, 0);
    ImGui.SameLine();
    if lab_button(s, "workspace:3d", "3D", s.workspace == 1, false, "media/pc-host") select_workspace(s, 1);
    shader_selector(s);
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < s.bank.shaders.count {
        lab_dim("处理流程 · 勾选启用，点击编辑");
        rows := cast(float32) clamp(s.bank.shaders[s.selected_shader].order.count, 1, 6);
        height := rows * ImGui.GetFrameHeightWithSpacing() + ImGui.GetStyle().WindowPadding.y * 2;
        if imgui_begin_child("passes", .{ 0, height }, true) passes_panel(s);
        ImGui.EndChild();
    }
    if lab_button(s, "inspector-parameters", "参数", !s.preview_settings, false, "ui/slider") {
        cancel(s);
        s.preview_settings = false;
    }
    lab_same_line("预览设置", true);
    if lab_button(s, "preview-settings", "预览设置", s.preview_settings, false, "ui/settings") {
        cancel(s);
        s.preview_settings = true;
    }
    // 详情区单独滚动，切换参数 / 预览设置不移动上方的选择区。
    if imgui_begin_child("inspector", .{ 0, 0 }, true) {
        if s.preview_settings {
            preview_options(s);
        } else {
            inspector_panel(s);
        }
        lab_diagnostics(s);
    }
    ImGui.EndChild();
    track(s, "inspector");
}
//@endregion

//@region 预览设置与诊断

preview_options :: (s: *Session) {
    if s.workspace_empty || s.bank == null || s.bank.program_count == 0 return;
    lab_dim("预览载体 · 不会切换 Shader");
    model3d := s.bank.parameters[s.selected].live.preview == "3d";
    if s.selected_shader >= 0 && s.selected_shader < s.bank.shaders.count {
        model3d = shader_has_3d(s, s.selected_shader);
    }
    ids: [4] string = .[ "2D / Fullscreen", "2D / Sprite", "3D / Sphere", "3D / Cube" ];
    names: [4] string = .[ "全屏", "精灵", "球体", "立方体" ];
    first := true;
    for id, i: ids {
        if model3d != (i >= 2) continue;
        if !first lab_same_line(names[i], false);
        first = false;
        if lab_button(s, id, names[i], s.mode == i, false, "") s.mode = i;
    }
    host_mesh := model3d && s.preview_hooks.mesh != null;
    if s.preview_hooks.record != null || host_mesh {
        if lab_button(s, "preview-host", "使用宿主模型", s.custom_preview, false, "") s.custom_preview = !s.custom_preview;
    }
    if model3d {
        lab_dim("预览上右键拖动旋转 / 滚轮缩放");
        if lab_button(s, "reset-camera", "重置相机", false, false, "media/camera") {
            s.yaw = 0.4;
            s.pitch = 0.25;
            s.distance = 4;
        }
    }
    if s.selected_shader >= 0 {
        if lab_button(s, "settings-step", "单步", false, false, "media/next-frame") step(s);
        lab_same_line("重置反馈", true);
        if lab_button(s, "settings-reset", "重置反馈", false, false, "ui/refresh") reset_history(s);
    }
    if lab_button(s, "retry", "重新编译", false, false, "media/code") {
        s.parameter_watch.has_attempted = false;
    }
}

lab_diagnostics :: (s: *Session) {
    if s.bank_error != "" lab_error(s.bank_error);
    if s.parameter_watch.diagnostic != "" lab_error(s.parameter_watch.diagnostic);
    if s.bank != null && s.bank.program_count > 0 && s.selected >= 0 && s.selected < s.bank.program_count {
        diagnostic := s.bank.programs[s.selected].diagnostic;
        if diagnostic != "" {
            if imgui_begin_child("diagnostic", .{ 0, 170 }, true) {
                // jacket 的 String 只有 replace(s, old, new)（全部替换，返回新串 + 替换次数）。
                message, _ := STRING.replace(diagnostic, s.source_root, "shaders");
                defer if message.data != null free(message.data);
                lab_error(message);
            }
            ImGui.EndChild();
        }
    }
}
//@endregion

//@region 每帧入口与预览窗口

// 在宿主的 ImGui 帧里（BeginRender 与 EndRender 之间）每帧调用一次：切换候选包、按预览窗口尺寸
// 渲染当前 Shader，并提交控制窗口、预览窗口和调色板。dropped_files 是本帧拖入的文件，只借用到返回；
// drop_position 是拖放位置（ImGui 坐标，即窗口逻辑坐标），落在纹理卡片上才替换。
draw :: (s: *Session, dropped_files: [] string = .[], drop_position: [2] float32 = .[0, 0]) {
    if !s.initialized return;
    // 上一帧的绘制列表已由宿主 EndRender 提交，这时才释放它借用的旧纹理和未选中 Shader 的目标；
    // 本帧新选中的 Shader 在下一帧开始时创建目标。
    texture_retire_flush(s);
    shader_targets_trim(s.bank, s.selected_shader);
    if s.pending_bank != null {
        shader_targets_trim(s.pending_bank, bank_selected_shader(s, s.pending_bank));
    }
    deinit(*s.widgets);
    s.widgets = HASH.Table(u64, Widget_Rect).{};
    s.dropped_files = dropped_files;
    s.drop_position = drop_position;
    s.drawing = true;
    defer {
        s.drawing = false;
        s.dropped_files = .[];
    }
    if s.pending_bank != null && bank_apply(s, s.pending_bank, bank_selected_shader(s, s.pending_bank), true) {
        bank_commit(s);
    }
    // 新布局尚未整体通过时，只准备旧包当前 Shader，不分批应用新的 HLSL。
    _ = bank_apply(s, s.bank, s.selected_shader, s.pending_bank == null);
    if s.fonts_dirty validate_parameter_fonts(s);
    if ImGui.IsKeyPressed(ImGui.Key.Escape, false) {
        cancel(s);
        s.shader_menu = false;
    }
    control_window(s);
    image: *F.Texture = null;
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < s.bank.shaders.count &&
       s.bank.shaders[s.selected_shader].ready {
        image = shader_render(s, *s.bank.shaders[s.selected_shader]);
    } else {
        s.step_requested = false;
    }
    preview_window(s, image);
    color_picker_popup(s);
    s.render_serial += 1;
}

// 预览图占满窗口内容区（留一行状态）；区域原点和尺寸取整到最终输出像素，Pass 目标在下一帧按它分配。
preview_window :: (s: *Session, image: *F.Texture) {
    ImGui.SetNextWindowSize(ImGui.ImVec2.{ 760, 600 }, ImGui.Cond.FirstUseEver);
    visible := imgui_begin(PREVIEW_WINDOW, null, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
    defer ImGui.End();
    if !visible return;
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < s.bank.shaders.count &&
       s.bank.shaders[s.selected_shader].desc.passes.count > 1 {
        if lab_button(s, "shader-final", "最终效果", s.preview_pass < 0, false, "media/display") s.preview_pass = -1;
        lab_same_line("当前 Pass", true);
        if lab_button(s, "pass-preview", "当前 Pass", s.preview_pass >= 0, false, "ui/visible") {
            s.preview_pass = s.inspect_pass;
        }
        if s.preview_pass >= 0 && s.preview_pass < s.bank.shaders[s.selected_shader].desc.passes.count {
            p := *s.bank.shaders[s.selected_shader].desc.passes[s.preview_pass];
            ImGui.SameLine();
            lab_dim(display_name(p.label, p.id));
        }
    } else {
        lab_text("最终效果");
    }
    io := ImGui.GetIO();
    scale := io.DisplayFramebufferScale;
    origin := ImGui.GetCursorScreenPos();
    avail := ImGui.GetContentRegionAvail();
    size := ImGui.ImVec2.{ max(cast(float32) 1, avail.x), max(cast(float32) 1, avail.y - ImGui.GetTextLineHeightWithSpacing()) };
    s.viewport = F.Rect.{
        x = JM.floor(origin.x * scale.x),
        y = JM.floor(origin.y * scale.y),
        w = max(cast(float32) 1, JM.floor(size.x * scale.x)),
        h = max(cast(float32) 1, JM.floor(size.y * scale.y)),
    };
    // 纹理显示与目标共用整数物理像素边界，避免线性采样在限色色块边缘混出新颜色。
    origin = ImGui.ImVec2.{ s.viewport.x / scale.x, s.viewport.y / scale.y };
    size = ImGui.ImVec2.{ s.viewport.w / scale.x, s.viewport.h / scale.y };
    ImGui.SetCursorScreenPos(origin);
    if image != null {
        ImGui.Image(imgui_texture_id(image), size);
    } else {
        // 空工作区或 Shader 尚未就绪时只画背景，不分配替代场景目标。
        background := ImGui.ImVec4.{ 17.0 / 255, 21.0 / 255, 26.0 / 255, 1 };
        imgui_draw_rect_filled(ImGui.GetWindowDrawList(), origin,
                               ImGui.ImVec2.{ origin.x + size.x, origin.y + size.y },
                               ImGui.GetColorU32(background));
        ImGui.Dummy(size);
    }
    ImGui.SetCursorScreenPos(origin);
    imgui_invisible_button("##preview-area", size,
                          ImGui.ButtonFlags.MouseButtonLeft | ImGui.ButtonFlags.MouseButtonRight);
    track(s, "preview-area");
    s.pointer = JM.Vector2.{ io.MousePos.x * scale.x, io.MousePos.y * scale.y };
    // 右键轨道旋转只在预览上开始，ImGui 的激活状态保持捕获到松开。
    if s.mode >= 2 {
        if ImGui.IsItemActive() && ImGui.IsMouseDown(ImGui.MouseButton.Right) && !s.color_picker.open s.orbiting = true;
        if !ImGui.IsMouseDown(ImGui.MouseButton.Right) s.orbiting = false;
        if s.orbiting {
            s.yaw -= io.MouseDelta.x * scale.x * 0.008;
            s.pitch = clamp(s.pitch + io.MouseDelta.y * scale.y * 0.008, -1.4, 1.4);
        }
        if ImGui.IsItemHovered() && io.MouseWheel != 0 {
            s.distance = clamp(s.distance - io.MouseWheel * 0.25, 2, 10);
        }
    }
    time := s.clock;
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < s.bank.shaders.count {
        time = s.bank.shaders[s.selected_shader].time;
    }
    lab_dim(tprint("%.2fs   %", time, preview_size_label(s)));
}

quad :: (r: *r2d.Render2D, texture: *F.Texture, rect: F.Rect) {
    r2d.quad_texture(r, texture,
                     JM.Vector2.{ rect.x, rect.y },
                     JM.Vector2.{ rect.x + rect.w, rect.y },
                     JM.Vector2.{ rect.x + rect.w, rect.y + rect.h },
                     JM.Vector2.{ rect.x, rect.y + rect.h },
                     JM.Vector2.{ 0, 0 }, JM.Vector2.{ 1, 0 }, JM.Vector2.{ 1, 1 }, JM.Vector2.{ 0, 1 },
                     F.Color_White);
}
//@endregion
