// shader_lab:shader_panel —— Shader 选择、中间目标查看和反馈控制；
// 没有节点编辑器，源声明仍归外部 .oshader 文件。
// 一比一移植自 olib kit/tools/shader_lab/shader_panel.odin。Jai 差异：
//   | olib (Odin)                                    | JaiLib (Jai)                                          |
//   | ---------------------------------------------- | ----------------------------------------------------- |
//   | `foster.TargetAttachment(t).SampleCount`       | F.target_texture(t).SampleCount                       |
//   | `t.Width / t.Height`                           | 同名字段（jfoster 的 Target 也是 s32 宽高）               |
//   | `dimension == 1 ? 2 : 0`                       | 先赋默认值再 if 改写                                     |
//   | `[]Shader_Template{…}` 切片字面量                | 定长数组 + array_view（Jai 的切片字面量要带类型标注）       |
//   | `imgui.Selectable(...)`                        | imgui_selectable(label, selected)                     |
//   | `imgui.TextUnformatted(cstr(x))`               | ImGui.TextUnformatted(x)（Jai 绑定收 string）            |
//   | `s.shaders` / `s.parameters`（using bank）      | s.bank.shaders / s.bank.parameters                    |
// 导入由 module.jai 提供。

preview_size_label :: (s: *Session) -> string {
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < s.bank.shaders.count {
        e := *s.bank.shaders[s.selected_shader];
        for p, i: e.desc.passes {
            if i == s.preview_pass || (s.preview_pass < 0 && p.output == e.desc.output) {
                index := i;
                if sh.shader_is_material(e.desc) index = 0;
                if index >= e.targets.count continue;
                t := e.targets[index].buffers[0];
                if t == null || t.Attachments.count == 0 break;
                x := 4;
                if t.Attachments[0].SampleCount == .ONE x = 1;
                return tprint("RT % x % / MSAA %x", t.Width, t.Height, x);
            }
        }
    }
    return tprint("VIEW % x %", cast(int) s.viewport.w, cast(int) s.viewport.h);
}

shader_has_3d :: (s: *Session, index: int) -> bool {
    return bank_shader_has_3d(s.bank, index);
}

bank_shader_has_3d :: (b: *Parameter_Bank, index: int) -> bool {
    if b == null || index < 0 || index >= b.shaders.count return false;
    if b.shaders[index].desc.preview != "" return b.shaders[index].desc.preview == "3d";
    for p: b.shaders[index].desc.passes {
        if p.draw == .Fullscreen continue;
        parameter := bank_index(b, p.params);
        if parameter < 0 || parameter >= b.parameters.count continue;
        if b.parameters[parameter].live.preview == "3d" return true;
    }
    return false;
}

select_shader :: (s: *Session, index: int, pass := -1) {
    if !s.initialized || s.bank == null return;
    if index < 0 || index >= s.bank.shaders.count return;
    e := *s.bank.shaders[index];
    if pass < -1 || pass >= e.desc.passes.count return;
    dimension := 0;
    if shader_has_3d(s, index) dimension = 1;
    if dimension != s.workspace {
        workspace_save(s);
        s.workspace = dimension;
        workspace_view_restore(s);
    }
    s.workspace_empty = false;
    selected_pass := pass;
    if pass < 0 {
        selected_pass = 0;
        if e.order.count > 0 selected_pass = e.order[0];
    }
    if index != s.selected_shader || selected_pass != s.inspect_pass cancel(s);
    if index == s.selected_shader && s.preview_pass >= 0 s.preview_pass = selected_pass;
    if index != s.selected_shader {
        s.preview_pass = -1;
        e.last_clock = s.clock;
        e.last_tick = s.tick_serial;
        if (s.mode >= 2) != (dimension == 1) {
            s.mode = 0;
            if dimension == 1 s.mode = 2;
        }
    }
    s.selected_shader = index;
    s.inspect_pass = selected_pass;
    for p, i: e.desc.passes {
        if i == selected_pass {
            index_of := bank_index(s.bank, p.params);
            if index_of >= 0 s.selected = index_of;
            break;
        }
    }
}

display_name :: (label: string, id: string) -> string {
    if label == "" return id;
    return label;
}

// folder 只是参数组的展示分组；一个 Pass 仍只绑定一个参数组（一个程序）。
group_folder :: (s: *Session, index: int, id: string) {
    p := *s.bank.parameters[index];
    name := display_name(p.live.label, p.name);
    if p.live.folder != "" name = tprint("% / %", p.live.folder, name);
    if lab_button(s, id, name, !p.folder_closed, true, "media/folder") {
        cancel(s);
        p.folder_closed = !p.folder_closed;
    }
    if p.folder_closed return;
    ImGui.Indent();
    defer ImGui.Unindent();
    // 宿主接了 open_file 时，源码文件名就是“用代码编辑器打开”的按钮。
    if s.open_file != null {
        if lab_button(s, tprint("open-source:%", p.name), tprint("编辑 %", p.live.shader), false, false, "media/code") &&
           !s.open_file(texture_path(s, p.live.shader)) {
            bank_error(s, tprint("无法打开 %", p.live.shader));
        }
    } else {
        lab_dim(p.live.shader);
    }
    if s.file_dialogs && s.selected_shader >= 0 && s.selected_shader < s.bank.shaders.count &&
       sh.shader_is_material(s.bank.shaders[s.selected_shader].desc) {
        lab_dim("保存 / 载入整个材质");
    }
    if s.file_dialogs {
        if lab_button(s, "preset-save", "保存", false, false, "ui/save") request_file(s, index, .Save_Preset);
        lab_same_line("载入", true);
        if lab_button(s, "preset-load", "载入", false, false, "media/import") request_file(s, index, .Load_Preset);
        lab_same_line("重置", true);
    }
    if lab_button(s, "preset-reset", "重置", false, false, "editing/undo") _ = reset_defaults(s, index, -1);
    if s.request.id != 0 lab_dim("等待选择文件…");
    parameters_panel(s, index);
}

// 无论一个还是多个 Pass，只有 Shader 这一个选择入口。菜单是 s.shader_menu 控制的浮层，
// 点外面、选中或 Escape 关闭，不挤动下方的 Pass 列表。
shader_selector :: (s: *Session) {
    name := "选择 Shader";
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < s.bank.shaders.count {
        e := *s.bank.shaders[s.selected_shader];
        name = display_name(e.desc.label, e.desc.name);
    }
    if lab_button(s, "shader-menu", name, s.shader_menu, true, "media/clapper") s.shader_menu = true;
    anchor := ImGui.GetItemRectMin();
    size := ImGui.GetItemRectSize();
    if s.shader_menu && !imgui_is_popup_open("shader-popup") {
        // 上一帧已打开、现在被 ImGui 关掉（点了浮层外面，包括这个按钮）就同步关闭，不能马上重开，
        // 否则重开的浮层第一帧隐藏测量尺寸，看起来闪一下而且关不掉。
        if s.shader_menu_shown {
            s.shader_menu = false;
        } else {
            imgui_open_popup("shader-popup");
        }
    }
    s.shader_menu_shown = s.shader_menu;
    ImGui.SetNextWindowPos(ImGui.ImVec2.{ anchor.x, anchor.y + size.y + 2 }, ImGui.Cond.Appearing, ImGui.ImVec2.{ 0, 0 });
    ImGui.SetNextWindowSizeConstraints(ImGui.ImVec2.{ size.x, 0 }, ImGui.ImVec2.{ max(size.x, 480), 360 });
    if !imgui_begin_popup("shader-popup") {
        s.shader_menu = false;
        return;
    }
    defer ImGui.EndPopup();
    if !s.shader_menu {
        ImGui.CloseCurrentPopup();
        return;
    }
    if s.bank == null return;
    for e, i: s.bank.shaders {
        if shader_has_3d(s, i) != (s.workspace == 1) continue;
        label := display_name(e.desc.label, e.desc.name);
        if imgui_selectable(tprint("%##shader:%", label, e.desc.name), s.selected_shader == i) {
            select_shader(s, i, -1);
            s.shader_menu = false;
        }
        track(s, tprint("shader:%", e.desc.name));
    }
    ImGui.Separator();
    // 新建：按当前工作区写一份能直接编译的模板到源码目录，热重载后自动选中。
    templates: [2] Shader_Template;
    if s.workspace == 1 {
        templates[0] = .Model;
        templates[1] = .Model_Instanced;
    } else {
        templates[0] = .Sprite;
        templates[1] = .Post_Process;
    }
    for template: templates {
        if lab_button(s, tprint("shader-new:%", template), template_menu_label(template), false, true, "symbols/plus") {
            _, reason := new_shader(s, template);
            if reason != "" bank_error(s, reason);
            s.shader_menu = false;
        }
    }
}

passes_panel :: (s: *Session) {
    if s.selected_shader < 0 || s.bank == null || s.selected_shader >= s.bank.shaders.count return;
    e := *s.bank.shaders[s.selected_shader];
    pending_pass := -1;
    for i: e.order {
        p := *e.desc.passes[i];
        selected := s.inspect_pass == i;
        if lab_checkbox(s, tprint("pass-enabled:%:%", e.desc.name, p.id), e.enabled[i]) {
            set_pass_enabled(s, s.selected_shader, i, !e.enabled[i]);
        }
        ImGui.SameLine();
        label := display_name(p.label, p.id);
        if imgui_selectable(tprint("%##pass:%", label, p.id), selected) {
            if selected {
                cancel(s);
                e.expanded[i] = !e.expanded[i];
            } else {
                e.expanded[i] = true;
            }
            pending_pass = i;
        }
        track(s, tprint("pass:%", p.id));
    }
    if pending_pass >= 0 select_shader(s, s.selected_shader, pending_pass);
}

inspector_panel :: (s: *Session) {
    if s.workspace_empty || s.bank == null || s.bank.program_count == 0 return;
    if s.selected_shader < 0 || s.inspect_pass < 0 return;
    if s.selected_shader >= s.bank.shaders.count return;
    e := *s.bank.shaders[s.selected_shader];
    i := s.inspect_pass;
    if i >= e.desc.passes.count return;
    p := *e.desc.passes[i];
    imgui_separator_text(display_name(p.label, p.id));
    if !e.enabled[i] lab_dim("已禁用 · 单输入直通，否则清屏");
    if e.expanded[i] {
        group_folder(s, s.selected, tprint("group-folder:%:%", e.desc.name, p.id));
    } else {
        lab_dim("参数已折叠，点击上方 Pass 展开");
    }
}

shader_value :: (s: *Session, index: int, field: string) -> (value: [4] float32, overridden: bool) {
    if s.selected_shader < 0 || s.bank == null || s.selected_shader >= s.bank.shaders.count return;
    e := *s.bank.shaders[s.selected_shader];
    target_name := s.bank.parameters[index].name;
    for p, i: e.desc.passes {
        if s.inspect_pass >= 0 && s.inspect_pass != i continue;
        if s.inspect_pass < 0 && e.desc.output != p.output continue;
        if p.params != target_name continue;
        for v: p.values {
            if v.field == field return v.number, true;
        }
    }
    return;
}

// 显示当前被检查 Pass 的纹理输入；由流程连接的字段不弹出磁盘图片选择器。
shader_input :: (s: *Session, index: int, field: string) -> (texture: *F.Texture, label: string) {
    if s.selected_shader < 0 || s.bank == null || s.selected_shader >= s.bank.shaders.count return null, "";
    e := *s.bank.shaders[s.selected_shader];
    target_name := s.bank.parameters[index].name;
    for p, i: e.desc.passes {
        if s.inspect_pass >= 0 && s.inspect_pass != i continue;
        if s.inspect_pass < 0 && e.desc.output != p.output continue;
        if p.params != target_name continue;
        for input: p.inputs {
            if input.field != field continue;
            for source, j: e.desc.passes {
                if source.output != input.target continue;
                if j >= e.targets.count continue;
                t := *e.targets[j];
                buffer := 0;
                if t.history {
                    if input.frame == .Previous buffer = 1 - e.current;
                    else buffer = e.current;
                }
                if t.buffers[buffer] == null continue;
                return F.target_texture(t.buffers[buffer]), tprint("% / %", input.target, input.frame);
            }
        }
    }
    return null, "";
}
