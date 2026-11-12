// shader_lab:parameters —— 参数预览由 Session 持有；值不写入项目文件。声明/Shader 成功后一起切换。
// 一比一移植自 olib kit/tools/shader_lab/parameters.odin。Jai 差异（除 module.jai 的全局六条外）：
//   | olib (Odin)                                  | JaiLib (Jai)                                          |
//   | -------------------------------------------- | ----------------------------------------------------- |
//   | `textures: [16]foster.Texture`               | `[16] *F.Texture`（句柄就绪判据 .handle != 0）           |
//   | `buffer: []u8`                               | `[..] u8` + array_resize                              |
//   | `foster.ImageLoadFile` / `ImagePremultiply`  | F.image_load / F.image_premultiply                    |
//   | `foster.TextureFromImage`                    | F.texture_create_from_colors(dev, w, h, image.Data)   |
//   | `stage.Samplers[slot] = {texture, sampler}`  | F.Bound_Sampler.{ Tex = …, Sampler = … }              |
//   | `foster.MaterialStageSetUniformBuffer(st, buf, 1)` | F.material_stage_set_uniform(st, 1, buf)        |
//   | `switch { case … case: }`（Odin 无标签 switch） | if / else if 链（Jai 的 if-switch 各 case 共享作用域）  |
//   | `imgui.SliderFloat(..., &value.number[0], ...)` | 先落局部 float 再写回（Jai 不取数组元素地址给外部 C）     |
//   | `imgui.Image(imgui_foster.Texture(t), size)`  | ImGui.Image(imgui_texture_id(t), size)                |
//   | `os.read_all_directory_by_path`              | FU.file_list（目录枚举；只取文件名）                     |
//   | `filepath.ext / base`                        | STRING.path_extension / STRING.path_filename           |
// 导入由 module.jai 提供。

Parameter_State :: struct {
    name: string;
    live, pending: sh.Schema;
    values: [] sh.Value;
    textures: [sh.MAX_TEXTURES] *F.Texture;
    buffer: [..] u8;
    has_pending, available: bool;
    folder_closed: bool;
    error: string;
    texture_picker: string;
    generation: u64;
    texture_stamps, texture_pending: [sh.MAX_TEXTURES] Texture_Stamp;
}

parameter_dispose :: (p: *Parameter_State) {
    sh.schema_dispose(*p.live);
    sh.schema_dispose(*p.pending);
    sh.values_dispose(p.values);
    for *texture: p.textures {
        if texture.* != null {
            F.texture_dispose(texture.*);
            free(texture.*);
        }
        texture.* = null;
    }
    if p.name.data != null free(p.name.data);
    if p.error.data != null free(p.error.data);
    if p.buffer.data != null array_free(p.buffer);
    if p.texture_picker.data != null free(p.texture_picker.data);
    p.* = Parameter_State.{};
}

parameters_update :: (s: *Session) {
    dev.parameters_update(*s.parameter_watch, cast(float64) s.delta_time);
    if s.parameter_watch.status != .Ready return;
    build := dev.parameters_take(*s.parameter_watch);
    defer dev.parameter_build_dispose(*build);
    if s.parameter_watch.status != .Live return;
    bank_dispose(s.pending_bank);
    s.pending_bank = bank_make(s, build);
    bank_error(s, "");
}

parameter_error :: (p: *Parameter_State, message: string) {
    if p.error.data != null free(p.error.data);
    p.error = copy_string(message);
    if message != "" print("%\n", message);
}

load_parameter_texture :: (s: *Session, device: *F.Graphics_Device, path: string) -> (*F.Texture, bool) {
    if path == "" return null, true; // 空路径使用工具内置棋盘纹理。
    fullpath := path;
    if !sl_is_absolute(path) fullpath = tprint("%/%", s.source_root, path);
    image := F.image_load(fullpath);
    defer if image.Data.data != null array_free(image.Data);
    if image.Width == 0 || image.Height == 0 return null, false;
    F.image_premultiply(*image);
    texture := F.texture_create_from_colors(device, image.Width, image.Height, image.Data, name = "parameter texture");
    if texture == null || texture.handle == 0 return null, false;
    return texture, true;
}

parameters_bind :: (s: *Session, index: int) {
    p := *s.bank.parameters[index];
    if !sh.pack(p.live, p.values, p.buffer) return;
    stage := *s.bank.materials[index].Fragment;
    F.material_stage_set_uniform(stage, 1, p.buffer);
    slot := 0;
    for f: p.live.fields {
        if f.kind != .Texture continue;
        texture := s.texture;
        if p.textures[slot] != null && p.textures[slot].handle != 0 texture = p.textures[slot];
        stage.Samplers[slot] = F.Bound_Sampler.{ Tex = texture, Sampler = sh.field_sampler(f) };
        slot += 1;
    }
}

parameter_number :: (s: *Session, index: int, id: string) -> float32 {
    p := *s.bank.parameters[index];
    for f, i: p.live.fields {
        if f.id == id return p.values[i].number[0];
    }
    return 0;
}

//@region 自动面板：数值/向量滑条、RGBA、纹理目录选择；参数值仅用于本次预览

parameters_panel :: (s: *Session, index: int) {
    p := *s.bank.parameters[index];
    if p.error != "" lab_error(p.error);
    style := ImGui.GetStyle();
    reset_width := ImGui.CalcTextSize("R").x + style.FramePadding.x * 2;
    // 属性表：标签列按本组最长的标签取宽（最多占一半），控件填满中间，行尾是单项重置 R。
    widest := ImGui.CalcTextSize("W").x + style.IndentSpacing * 0.5;
    for f: p.live.fields widest = max(widest, ImGui.CalcTextSize(f.label).x);
    label_width := min(widest + style.ItemSpacing.x * 2, ImGui.GetContentRegionAvail().x * 0.5);
    for f, i: p.live.fields {
        override, overridden := shader_value(s, index, f.id);
        bound_texture, binding_label := shader_input(s, index, f.id);
        resettable := !overridden && binding_label == "";
        value := *p.values[i];
        count := sh.components(f.kind);
        field_label(f.label, label_width, false);
        if overridden {
            lab_dim(tprint("Pass 覆盖 %", array_view(override, 0, count)));
            continue;
        }
        reset := tprint("reset:%:%", p.name, f.id);
        widget_width := -(reset_width + style.ItemSpacing.x);
        handled := false;
        if f.kind == .Texture && binding_label != "" {
            if bound_texture != null && bound_texture.handle != 0 {
                scale := ImGui.GetFrameHeight() / cast(float32) max(cast(s32) 1, max(bound_texture.Width, bound_texture.Height));
                ImGui.Image(imgui_texture_id(bound_texture),
                            .{ cast(float32) bound_texture.Width * scale, cast(float32) bound_texture.Height * scale });
                ImGui.SameLine();
            }
            lab_dim(binding_label);
            handled = true;
        } else if f.kind == .Texture {
            name := "Built-in checker";
            if p.values[i].texture != "" name = STRING.path_filename(p.values[i].texture);
            lab_dim(name);
            handled = true;
        } else if f.kind == .Color {
            id := tprint("%:%:color", p.name, f.id);
            color := color_normalize(value.number, f.minimum, f.maximum);
            size := ImGui.ImVec2.{ ImGui.GetContentRegionAvail().x - reset_width - style.ItemSpacing.x,
                                   ImGui.GetFrameHeight() };
            if imgui_color_button(tprint("##%", id), color, ImGui.ColorEditFlags.AlphaPreviewHalf, size) {
                color_picker_open(s, p, i);
            }
            track(s, id);
            handled = true;
        } else if count == 1 {
            id := tprint("%:%", p.name, f.id);
            ImGui.SetNextItemWidth(widget_width);
            number := value.number[0];
            imgui_slider_float(tprint("##%", id), *number, f.minimum, f.maximum, "%.2f", ImGui.SliderFlags.AlwaysClamp);
            value.number[0] = number;
            track(s, id);
            handled = true;
        } else {
            ImGui.Dummy(.{ max(cast(float32) 1, ImGui.GetContentRegionAvail().x - reset_width - style.ItemSpacing.x),
                           ImGui.GetFrameHeight() });
            handled = true;
        }
        if resettable {
            align_right(reset_width);
            if imgui_button(tprint("R##%", reset)) _ = reset_defaults(s, index, i);
            track(s, reset);
        }
        if f.kind == .Texture && binding_label == "" {
            button := tprint("texture:%:%", p.name, f.id);
            if parameter_texture_card(s, index, i, button) {
                if p.texture_picker.data != null free(p.texture_picker.data);
                p.texture_picker = copy_string(f.id);
            }
            if p.texture_picker == f.id texture_picker(s, index, i);
        }
        if count > 1 && f.kind != .Color && f.kind != .Texture {
            components: [4] string = .[ "X", "Y", "Z", "W" ];
            for c: 0..count - 1 {
                id := tprint("%:%:%", p.name, f.id, c);
                field_label(components[c], label_width, true);
                ImGui.SetNextItemWidth(widget_width);
                number := value.number[c];
                imgui_slider_float(tprint("##%", id), *number, f.minimum, f.maximum, "%.2f", ImGui.SliderFlags.AlwaysClamp);
                value.number[c] = number;
                track(s, id);
            }
        }
        p.values[i] = value;
    }
}

// 标签与同行控件按框架内边距对齐；过长时截断显示，悬停看全名。
field_label :: (label: string, width: float32, indent: bool) {
    ImGui.AlignTextToFramePadding();
    start := ImGui.GetCursorPosX();
    if indent ImGui.SetCursorPosX(start + ImGui.GetStyle().IndentSpacing * 0.5);
    clip := ImGui.GetCursorScreenPos();
    right := ImGui.ImVec2.{ clip.x + width - ImGui.GetStyle().ItemSpacing.x, clip.y + ImGui.GetFrameHeight() };
    ImGui.PushClipRect(clip, right, true);
    ImGui.TextUnformatted(label);
    ImGui.PopClipRect();
    if ImGui.IsItemHovered() && ImGui.CalcTextSize(label).x > width imgui_set_tooltip(label);
    ImGui.SameLine(start + width);
}

texture_picker :: (s: *Session, index: int, field: int) {
    p := *s.bank.parameters[index];
    if s.file_dialogs && lab_button(s, "texture-browse", "浏览文件…", false, true, "") {
        request_file(s, index, .Texture, p.live.fields[field].id);
    }
    if lab_button(s, "texture-default", "清除 / 棋盘格", false, true, "") {
        parameter_texture_set(s, index, field, "");
    }
    directory := tprint("%/textures", s.source_root);
    // jacket: file_list -> [] string（单返回值，元素是**完整路径**，每个都由 copy_string 拥有；
    // 失败只在 context.logger 上记一条，不返回 bool），所以目录名与判重都改用基名。
    entries := FU.file_list(directory);
    for name: entries {
        base := STRING.path_filename(name);
        ext, has_extension := STRING.path_extension(base);
        if has_extension && (STRING.equal_nocase(ext, ".png") || STRING.equal_nocase(ext, ".jpg") ||
                             STRING.equal_nocase(ext, ".jpeg") || STRING.equal_nocase(ext, ".qoi")) {
            if lab_button(s, name, base, false, true, "") {
                parameter_texture_set(s, index, field, tprint("textures/%", base));
            }
        }
    }
    for name: entries free(name.data);
    array_free(entries);
    lab_dim("可将图片添加到 shaders/textures");
    if lab_button(s, "texture-cancel", "关闭", false, true, "") {
        if p.texture_picker.data != null free(p.texture_picker.data);
        p.texture_picker = "";
    }
}

// 卡片显示当前绑定的实际纹理；路径仍是 Properties 声明中的持久化表示。拖入的文件落在卡片上才替换。
parameter_texture_card :: (s: *Session, index: int, field: int, id: string) -> bool {
    p := *s.bank.parameters[index];
    label := "Built-in checker";
    if p.values[field].texture != "" label = STRING.path_filename(p.values[field].texture);
    slot := 0;
    for f: array_view(p.live.fields, 0, field) {
        if f.kind == .Texture slot += 1;
    }
    texture := s.texture;
    if p.textures[slot] != null && p.textures[slot].handle != 0 texture = p.textures[slot];
    thumb := cast(float32) 48;
    pad := ImGui.GetStyle().FramePadding.y;
    clicked := imgui_button(tprint("##%", id), .{ ImGui.GetContentRegionAvail().x, thumb + pad * 2 });
    track(s, id);
    rect_min := ImGui.GetItemRectMin();
    rect_max := ImGui.GetItemRectMax();
    draw := ImGui.GetWindowDrawList();
    box := ImGui.ImVec2.{ rect_min.x + pad, rect_min.y + pad };
    box_max := ImGui.ImVec2.{ box.x + thumb, box.y + thumb };
    imgui_draw_rect_filled(draw, box, box_max, ImGui.GetColorU32(ImGui.Col.WindowBg, 1.0));
    scale := thumb / cast(float32) max(cast(s32) 1, max(texture.Width, texture.Height));
    w := cast(float32) texture.Width * scale;
    h := cast(float32) texture.Height * scale;
    corner := ImGui.ImVec2.{ box.x + (thumb - w) / 2, box.y + (thumb - h) / 2 };
    imgui_draw_image(draw, imgui_texture_id(texture), corner,
                     ImGui.ImVec2.{ corner.x + w, corner.y + h });
    x := box.x + thumb + ImGui.GetStyle().ItemInnerSpacing.x * 2;
    line1 := ImGui.ImVec2.{ x, box.y + 4 };
    line2 := ImGui.ImVec2.{ x, box.y + thumb / 2 + 4 };
    imgui_draw_text(draw, line1, ImGui.GetColorU32(ImGui.Col.Text, 1.0), label);
    imgui_draw_text(draw, line2, ImGui.GetColorU32(ImGui.Col.TextDisabled, 1.0), "Click / drop image");
    drop := s.drop_position;
    if s.dropped_files.count > 0 && drop[0] >= rect_min.x && drop[0] < rect_max.x &&
       drop[1] >= rect_min.y && drop[1] < rect_max.y {
        parameter_texture_set(s, index, field, s.dropped_files[0]);
    }
    return clicked;
}

parameter_texture_set :: (s: *Session, index: int, field: int, path: string) {
    if index < 0 || index >= s.bank.program_count return;
    p := *s.bank.parameters[index];
    if !p.available || field < 0 || field >= p.live.fields.count || p.live.fields[field].kind != .Texture return;
    texture, ok := load_parameter_texture(s, s.device, path);
    if !ok {
        parameter_error(p, "图片加载失败，已保留原纹理");
        return;
    }
    slot := 0;
    for f: array_view(p.live.fields, 0, field) {
        if f.kind == .Texture slot += 1;
    }
    parameter_texture_replace(s, *p.textures[slot], texture);
    owned_path := copy_string(path);
    if p.values[field].texture.data != null free(p.values[field].texture.data);
    p.values[field].texture = owned_path;
    texture_stamps_reset(s, p);
    if p.texture_picker.data != null free(p.texture_picker.data);
    p.texture_picker = "";
    parameter_error(p, "");
}

// draw 期间本帧的 ImGui 绘制列表可能已引用旧纹理（缩略图、预览）；宿主 EndRender 之后才提交，
// 所以旧资源先留着，下一次 draw 开始时再释放。
// olib 的签名是 (s, destination: ^foster.Texture, texture: foster.Texture)：参数状态里的
// foster.Texture 是值，取址就是槽位。jfoster 的槽位本身是 *F.Texture，所以这里收 **F.Texture
// （槽位地址），调用方写 `*p.textures[slot]`；null 表示该槽位回到内置棋盘纹理。
parameter_texture_replace :: (s: *Session, slot: **F.Texture, texture: *F.Texture) {
    old := <<slot;
    if s.drawing && old != null && old.handle != 0 {
        retired := New(F.Texture);
        retired.* = old.*;
        array_add(*s.retired_textures, retired);
    } else if old != null {
        F.texture_dispose(old);
        free(old);
    }
    slot.* = texture;
}

texture_retire_flush :: (s: *Session) {
    for texture: s.retired_textures {
        if texture != null {
            F.texture_dispose(texture);
            free(texture);
        }
    }
    array_reset(*s.retired_textures);
}

// ImGui 按需光栅化字形，但 olib 字体只含 ASCII、Latin-1 与 GB2312；热改标签后报告缺字。
// 在 ImGui 帧内调用。Jai 的 ImGui 绑定没有 Font_IsGlyphInFont：缺字检查退化为「非 ASCII 全算」，
// 只在控制台报告（不误报 ASCII，也不假装知道字体覆盖范围）。
validate_parameter_fonts :: (s: *Session) {
    s.fonts_dirty = false;
    s.missing_glyphs = 0;
    if s.bank == null return;
    for p: array_view(s.bank.parameters, 0, s.bank.program_count) {
        validate_label_font(s, display_name(p.live.label, p.name));
        validate_label_font(s, p.live.folder);
        for f: p.live.fields {
            validate_label_font(s, f.label);
        }
    }
    for e: s.bank.shaders {
        validate_label_font(s, display_name(e.desc.label, e.desc.name));
        for p: e.desc.passes validate_label_font(s, display_name(p.label, p.id));
    }
}

validate_label_font :: (s: *Session, label: string) {
    for cp: label {
        if cp <= 0x7F continue;
        s.missing_glyphs += 1;
        print("ImGui font may lack U+%04X in %; the olib UI font covers ASCII, Latin-1 and GB2312\n", cp, label);
    }
}
//@endregion
