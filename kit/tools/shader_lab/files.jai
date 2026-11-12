// shader_lab:files —— 文件对话框由宿主执行；请求绑定组名、字段 ID 和布局版本，异步返回不误写其他目标。
// 一比一移植自 olib kit/tools/shader_lab/files.odin。Jai 差异：
//   | olib (Odin)                                       | JaiLib (Jai)                                          |
//   | ------------------------------------------------- | ----------------------------------------------------- |
//   | `os.stat(...).modification_time` / `.size`        | FU.file_modtime_and_size(path) -> (mod, size, exists) |
//   | `Texture_Stamp{modified: time.Time, size: i64}`   | `{modified: Apollo_Time, size: s64, exists: bool}`（同一比较语义）|
//   | `filepath.is_abs`                                 | sl_is_absolute（本文件，按盘符 / 前导分隔符判断）         |
//   | `filepath.base`                                   | STRING.path_filename                                 |
//   | `os.exists(path)`                                 | FU.file_exists(path)                                 |
//   | `os.write_entire_file`                            | FILE.write_entire_file                               |
//   | `#load("templates/X.oshader", string)`（编译期内嵌） | 运行时读 <template_root>/X.oshader（jacket 0.35.1 没有 `#string #load`）|
//   | `strings.replace(s, old, new, 1, temp)`           | sl_replace_first（本文件，Jai 的 String 只有 replace_all）|
//   | `fmt.tprint(n)` 拼后缀                            | tprint("%", n)                                        |
// 模板文件已随仓库放在 kit/tools/shader_lab/templates/（内容与 olib 逐字节相同）。
// 导入由 module.jai 提供。

//@region 路径小工具

sl_is_absolute :: (path: string) -> bool {
    if path.count >= 2 {
        c := path[0];
        upper := c >= 65 && c <= 90;   // 'A'..'Z'
        lower := c >= 97 && c <= 122;  // 'a'..'z'
        if (upper || lower) && path[1] == 58 return true; // 58 == ':'
    }
    if path.count >= 1 {
        if path[0] == 47 || path[0] == 92 return true; // 47 == '/', 92 == '\\'
    }
    return false;
}

// 只替换第一处（olib 的 strings.replace(..., 1)）。
// jacket 没有 index_of：STRING.find_index_from_left 找不到时返回 -1（与 olib index_of 一致）；
// STRING.slice(s, index, count) 的第三个参数是**长度**不是结束下标；STRING.replace 会替换全部，
// 所以这里仍手搓 builder。
sl_replace_first :: (text: string, needle: string, replacement: string) -> string {
    at := STRING.find_index_from_left(text, needle);
    if at < 0 return copy_string(text);
    builder: String_Builder;
    if at > 0 append(*builder, STRING.slice(text, 0, at));
    append(*builder, replacement);
    rest := at + needle.count;
    if rest < text.count append(*builder, STRING.slice(text, rest, text.count - rest));
    return builder_to_string(*builder);
}
//@endregion

File_Action :: enum { None; Texture; Save_Preset; Load_Preset; }

File_Request :: struct {
    id, generation: u64;
    action: File_Action;
    group, field: string;
    shader: string; // 模型材质请求绑定整个 Shader，切换选中项不会重定向保存/载入。
}

// 返回借用描述；宿主只需保留 id/action，路径在主线程通过 file_reply 交回。
file_request :: (s: *Session) -> File_Request {
    return s.request;
}

file_request_clear :: (s: *Session) {
    if s.request.group.data != null free(s.request.group.data);
    if s.request.field.data != null free(s.request.field.data);
    if s.request.shader.data != null free(s.request.shader.data);
    s.request = File_Request.{};
}

request_file :: (s: *Session, index: int, action: File_Action, field := "") {
    if !s.file_dialogs || s.request.id != 0 || index < 0 || index >= s.bank.program_count return;
    p := *s.bank.parameters[index];
    if !p.available return;
    color_picker_close(s, true);
    s.request_serial += 1;
    s.request = File_Request.{
        id = s.request_serial,
        generation = p.generation,
        action = action,
        group = copy_string(p.name),
        field = copy_string(field),
    };
    if action != .Texture && s.selected_shader >= 0 &&
       sh.shader_is_material(s.bank.shaders[s.selected_shader].desc) {
        s.request.shader = copy_string(s.bank.shaders[s.selected_shader].desc.name);
    }
}

// 空路径代表取消；旧请求或已改变的布局被丢弃。只能在工具没有排队绘制时调用。
file_reply :: (s: *Session, id: u64, path: string) -> bool {
    if id == 0 || s.request.id != id return false;
    request := s.request;
    defer file_request_clear(s);
    if path == "" return true;
    for *p, index: array_view(s.bank.parameters, 0, s.bank.program_count) {
        if !p.available || p.name != request.group || p.generation != request.generation continue;
        if request.shader != "" {
            for e, i: s.bank.shaders {
                if e.desc.name != request.shader continue;
                if request.action == .Save_Preset return save_material(s, i, path);
                if request.action == .Load_Preset return load_material(s, i, path);
            }
            return false;
        }
        if request.action == .Save_Preset return save_preset(s, index, path);
        if request.action == .Load_Preset return load_preset(s, index, path);
        if request.action == .Texture {
            for f, i: p.live.fields {
                if f.id == request.field && f.kind == .Texture {
                    parameter_texture_set(s, index, i, path);
                    return p.error == "";
                }
            }
        }
    }
    return false;
}

// jfoster / jacket 的文件时间戳是 Apollo_Time（i128，纳秒），比 Odin 的 time.Time 更宽；
// 这里直接保存原值，比较语义不变（相等即"未改动"）。s64 装不下，所以字段类型跟着走。
Texture_Stamp :: struct {
    modified: Apollo_Time;
    size: s64;
    exists: bool;
}

texture_path :: (s: *Session, path: string) -> string {
    if sl_is_absolute(path) return path;
    return tprint("%/%", s.source_root, path);
}

texture_stamp :: (s: *Session, path: string) -> Texture_Stamp {
    if path == "" return Texture_Stamp.{};
    modified, size, exists := FU.file_modtime_and_size(texture_path(s, path));
    if !exists return Texture_Stamp.{};
    return Texture_Stamp.{ modified = modified, size = size, exists = true };
}

texture_stamps_reset :: (s: *Session, p: *Parameter_State) {
    slot := 0;
    for f, i: p.live.fields {
        if f.kind != .Texture continue;
        p.texture_stamps[slot] = texture_stamp(s, p.values[i].texture);
        p.texture_pending[slot] = p.texture_stamps[slot];
        slot += 1;
    }
}

textures_update :: (s: *Session) {
    s.texture_poll += s.delta_time;
    if s.texture_poll < 0.25 return;
    s.texture_poll = 0;
    if s.bank == null return;
    for *p: array_view(s.bank.parameters, 0, s.bank.program_count) {
        if !p.available continue;
        slot := 0;
        for f, i: p.live.fields {
            if f.kind != .Texture continue;
            current := texture_stamp(s, p.values[i].texture);
            if current.modified != p.texture_stamps[slot].modified ||
               current.size != p.texture_stamps[slot].size ||
               current.exists != p.texture_stamps[slot].exists {
                if current.modified == p.texture_pending[slot].modified &&
                   current.size == p.texture_pending[slot].size &&
                   current.exists == p.texture_pending[slot].exists {
                    // 两次轮询稳定后再加载；失败保留旧图，等下一次文件变化再尝试。
                    p.texture_stamps[slot] = current;
                    texture, ok := load_parameter_texture(s, s.device, p.values[i].texture);
                    if ok {
                        parameter_texture_replace(s, *p.textures[slot], texture);
                        parameter_error(p, "");
                    } else {
                        parameter_error(p, "Texture reload failed; previous image retained");
                    }
                } else {
                    p.texture_pending[slot] = current;
                }
            }
            slot += 1;
        }
    }
}

//@region 新建着色器模板

// 新建着色器：把能直接编译、满足 D3D12 规则的 .oshader 模板写到 source_root，热重载发现后自动选中。
// 模板在 templates/ 下，是普通 .oshader，单元测试按游戏同一解析器检查。
Shader_Template :: enum {
    Sprite;          // 2D 精灵材质
    Model;           // 3D 模型材质
    Model_Instanced; // 3D 实例化模型材质
    Post_Process;    // 2D 后处理：铺满屏幕的精灵材质
}

// 模板文件名（文件里的 Shader 名是 "Template"）、新文件的默认名与显示名。
// olib 在这里 `#load` 模板正文；jacket 0.35.1 没有 `#string #load`，正文改由 new_shader 运行时读取，
// 这里只给出文件名，text 恒为空（签名保持与 olib 一致）。
template_source :: (template: Shader_Template) -> (text: string, base: string, label: string) {
    if template == .Sprite          return "", "NewSprite",         "新 2D 精灵 Shader";
    if template == .Model           return "", "NewModel",          "新 3D 模型 Shader";
    if template == .Model_Instanced return "", "NewInstancedModel", "新 3D 实例化模型 Shader";
    return "", "NewPostProcess", "新后处理 Shader";
}

template_file :: (template: Shader_Template) -> string {
    if template == .Sprite          return "Sprite.oshader";
    if template == .Model           return "Model.oshader";
    if template == .Model_Instanced return "Model_Instanced.oshader";
    return "Post_Process.oshader";
}

// Shader 菜单里的文字：新建的是 .oshader 源文件，要在代码编辑器里改。
template_menu_label :: (template: Shader_Template) -> string {
    if template == .Sprite          return "新建 Shader：2D 精灵";
    if template == .Model           return "新建 Shader：3D 模型";
    if template == .Model_Instanced return "新建 Shader：3D 实例化模型";
    return "新建 Shader：后处理";
}

// 写出模板，返回新文件路径（临时分配）。Shader 名取 base、base2、base3… 中第一个没被文件或已有
// Shader 占用的，不覆盖文件。
new_shader :: (s: *Session, template: Shader_Template) -> (path: string, reason: string) {
    if !s.initialized return "", "Shader Lab is not initialized";
    _, base, label := template_source(template);
    template_dir := tprint("%/templates", s.source_root);
    // jacket: read_entire_file -> (string, bool)，顺序是「数据在前、成功在后」。
    template_text, read_ok := FILE.read_entire_file(tprint("%/%", template_dir, template_file(template)));
    if !read_ok {
        return "", tprint("Cannot read template %/%", template_dir, template_file(template));
    }
    defer if template_text.data != null free(template_text.data);
    text := template_text;
    for n: 1..99 {
        suffix := "";
        if n != 1 suffix = tprint("%", n);
        name := tprint("%%%", base, suffix);
        path = tprint("%/%.oshader", s.source_root, name);
        if FU.file_exists(path) || template_shader_named(s, name) continue;
        content := sl_replace_first(text, "Shader \"Template\"", tprint("Shader \"%\"", name));
        defer if content.data != null free(content.data);
        if suffix != "" {
            updated := sl_replace_first(content, tprint("Label \"%\"", label), tprint("Label \"% %\"", label, suffix));
            if content.data != null free(content.data);
            content = updated;
        }
        ok := FILE.write_entire_file(path, content);
        if !ok return "", tprint("Cannot write %", path);
        if s.pending_shader.data != null free(s.pending_shader.data);
        s.pending_shader = copy_string(name);
        return path, "";
    }
    return "", tprint("No free name for %", base);
}

// 新建的 Shader 编译进 bank 后选中它；编译失败时继续等待，错误照常显示在面板上。
templates_update :: (s: *Session) {
    if s.pending_shader == "" return;
    if s.bank == null return;
    for e, i: s.bank.shaders {
        if e.desc.name != s.pending_shader continue;
        select_shader(s, i, -1);
        free(s.pending_shader.data);
        s.pending_shader = "";
        return;
    }
}

template_shader_named :: (s: *Session, name: string) -> bool {
    if s.bank == null return false;
    for e: s.bank.shaders {
        if e.desc.name == name return true;
    }
    return false;
}
//@endregion
