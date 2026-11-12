// scene_notes_imgui 在宿主 ImGui 帧中提交世界图钉、就地便签框与可选列表。
// Panel 拥有独立草稿；放置不修改文档，保存成功才提交一条事务。场景投影与输入归属仍归宿主。
//
// 一比一移植自 olib kit/tools/scene_notes/imgui/scene_notes_imgui.odin。Jai 差异
// （不改对外语义，只改现实手段）：
//   | olib (Odin + imgui_foster)                          | JaiLib (Jai + jacket ImGui)                          |
//   | --------------------------------------------------- | ----------------------------------------------------- |
//   | `imgui.PushStyleColorImVec4(.Border, {r,g,b,a})`    | imgui_push_style_color(ImGui.Col.Border, {r,g,b,a})    |
//   | `imgui.PushStyleColor(3)` / PopStyleColorImVec4     | imgui_pop_style_color(3)（[4] float32 → ImU32 在包装里）|
//   | `imgui.ColorConvertFloat4ToU32(c)`                  | imgui_color_u32(c)                                    |
//   | `imgui.DrawList_AddXxx(list, …)`                    | imgui_draw_xxx（lab_imgui 的值语义包装）               |
//   | `imgui.InputText(label, cstring(&buf[0]), len)`     | imgui_input_text(label, *u8, size)（同形，*u8 由切片来） |
//   | `{.WordWrap}` 多行输入                               | 无 WordWrap（jacket 无该标志）：靠滚动 + 手动换行      |
//   | `imgui.WindowFlags_NoDocking`                        | 去掉（jacket 是非 docking 分支）                       |
//   | `imgui.SetWindowFocusStr(s)`                         | imgui_set_window_focus(s)                             |
//   | `imgui.BeginChild(id, size, {.Borders})`             | imgui_begin_child(id, size, true)（第三参是裸 bool）   |
//   | `imgui.TableFlags_RowBg \\| …`                       | ImGui.TableFlags.RowBg \\| …（enum_flags）             |
//   | `for status in Overview_Status`（枚举迭代）           | 三个 imgui_radio_button 展开（Jai 无枚举迭代）         |
//   | `strings.trim_space(x)` / `strings.to_lower(x, temp)`| STRING.trim(x) / STRING.contains_nocase(x, q)         |
//   | `fmt.tprintf("%s：%s", a, b)`                        | tprint("%：%", a, b)（`%` 不吃精度修饰）               |
//   | `foster.Vec2 / foster.Rect`                          | JM.Vector2 / F.Rect（字段 x,y / x,y,w,h 小写）         |
//   | `len(x)` / `x[i]`                                    | x.count / x[i]                                       |
//   | `math.clamp / math.abs`                              | clamp / JM.abs                                        |
//   | `nil`                                                | null                                                  |
//   | `? :` 三元                                            | if / else（Jai 没有三元）                              |
//
// 三条必须知道的行为差异（依赖库形态，不是接口变化）：
//   1. **float 显示精度**：olib 的 "%.2f" 在 Jai 的 tprint 里没有等价写法（`%` 不吃精度修饰），
//      世界位置/通道值都按 `%` 的默认格式打印。数值本身不变，只有小数位数可能不同。
//   2. **多行输入不折行**：没有被包装的 WordWrap 标志，长行靠水平滚动；Insert 手动换行仍可用。
//   3. **`imgui_end()` 等 End 调用必须与 Begin 成对出现在同一层**：Jai 的 `defer` 绑定当前作用域，
//      而 `if imgui_begin(...) { … }` 的 End 必须在 if 之外（semantics 与 ImGui 一致），所以
//      本文件不用 defer 收尾，逐个显式配对。
//
// 导入由 module.jai 提供（Basic / STRING / JM / ImGui / F / W / notes / lab_imgui 的 imgui_* 包装）。

//@region 面板状态与草稿

WINDOW :: "场景批注##jalib_scene_notes";
OVERVIEW_WINDOW :: "批注总览##jalib_scene_notes_overview";

Overview_Status :: enum u8 {
    All;
    Pending;
    Resolved;
}

// 数组包含末尾 NUL，容量与文件校验一致；不截断已载入的合法便签。
Draft :: struct {
    id: u64;
    has_position: bool;
    position: W.Vec3;
    resolved: bool;
    title: [notes.MAX_TITLE_BYTES + 1] u8;
    scene: [notes.MAX_LABEL_BYTES + 1] u8;
    object_id: [notes.MAX_LABEL_BYTES + 1] u8;
    screenshot: [notes.MAX_LABEL_BYTES + 1] u8;
    source_hint: [notes.MAX_LABEL_BYTES + 1] u8;
    text: [notes.MAX_TEXT_BYTES + 1] u8;
    resolution: [notes.MAX_TEXT_BYTES + 1] u8;
}

Panel :: struct {
    selected: u64;
    show_resolved: bool;
    editing: bool;
    focus_editor: bool;
    editor_size: JM.Vector2;
    error: notes.Error;
    draft: Draft;
    // 总览窗口只读审阅；筛选与开关属于面板状态，不写入文档。
    overview_open: bool;
    overview_status: Overview_Status;
    overview_query: [notes.MAX_TITLE_BYTES + 1] u8;
}

Actions :: struct {
    locate: u64;
}

//@region 字节缓冲区小工具（olib: []byte + copy + buffer_text）
//
// Draft 的每个字段都是 [N+1]u8（末尾 NUL），ImGui 的输入框直接写这块内存；
// 读出来时按第一个 0 截断，得到借用原缓冲区的 string（不分配、不需要释放）。

scn_set_text :: (buffer: [] u8, text: string) {
    if buffer.count == 0 return;
    count := min(text.count, buffer.count - 1);
    if count > 0 memcpy(buffer.data, text.data, count);
    buffer[count] = 0;
}

scn_buffer_text :: (buffer: [] u8) -> string {
    result: string;
    result.data = buffer.data;
    result.count = 0;
    while result.count < buffer.count && buffer[result.count] != 0 result.count += 1;
    return result;
}

scn_input :: (label: string, buffer: [] u8) -> bool {
    return imgui_input_text(label, buffer.data, buffer.count);
}

scn_input_hint :: (label: string, hint: string, buffer: [] u8) -> bool {
    return imgui_input_text_with_hint(label, hint, buffer.data, buffer.count);
}

// olib 的 {.WordWrap}：本仓库的 ImGui 声明没有该标志，只能给高度 + 靠滚动。
scn_input_multiline :: (label: string, buffer: [] u8, height: float32) -> bool {
    return imgui_input_text_multiline(label, buffer.data, buffer.count, ImGui.ImVec2.{ -1, height });
}

// olib 的 wrapped()：PushTextWrapPos(0) → 文本 → Pop。
scn_wrapped :: (text: string) {
    imgui_push_text_wrap_pos(0);
    ImGui.TextUnformatted(text);
    imgui_pop_text_wrap_pos();
}

// 状态 → 显示文案。olib 用三元，Jai 没有三元，所以统一走这个函数。
scn_status_text :: (note: notes.Note) -> string {
    if note.status == notes.RESOLVED return "已处理";
    return "待处理";
}
//@endregion

//@region 创建与选择

// 在世界坐标放置独立便签；不绑定物体，不分配正式 ID，也不写入空记录。
// 宿主当帧把此位置投影后调用 draw_editor，即可显示临时图钉与编辑框。
place :: (p: *Panel, scene: string, position: W.Vec3, source_hint := "") -> bool {
    initial: notes.Note;
    initial.scene = scene;
    initial.has_position = true;
    initial.position = position;
    initial.source_hint = source_hint;
    return start(p, initial);
}

// id=0 为新便签，非零编辑已有便签；已有草稿时拒绝，避免丢失正在输入的文字。
start :: (p: *Panel, note: notes.Note) -> bool {
    if p == null || p.editing return false;
    if note.title.count > notes.MAX_TITLE_BYTES ||
       note.scene.count > notes.MAX_LABEL_BYTES || note.object_id.count > notes.MAX_LABEL_BYTES ||
       note.screenshot.count > notes.MAX_LABEL_BYTES || note.source_hint.count > notes.MAX_LABEL_BYTES ||
       note.text.count > notes.MAX_TEXT_BYTES || note.resolution.count > notes.MAX_TEXT_BYTES {
        return false;
    }
    p.draft = Draft.{};
    p.draft.id = note.id;
    p.draft.has_position = note.has_position;
    p.draft.position = note.position;
    p.draft.resolved = note.status == notes.RESOLVED;
    scn_set_text(p.draft.title, note.title);
    scn_set_text(p.draft.scene, note.scene);
    scn_set_text(p.draft.object_id, note.object_id);
    scn_set_text(p.draft.screenshot, note.screenshot);
    scn_set_text(p.draft.source_hint, note.source_hint);
    scn_set_text(p.draft.text, note.text);
    scn_set_text(p.draft.resolution, note.resolution);
    p.selected = note.id;
    p.editing = true;
    p.focus_editor = true;
    p.editor_size = JM.Vector2.{ 0, 0 };
    p.error = .None;
    return true;
}

select :: (p: *Panel, id: u64) -> bool {
    if p == null || p.editing return false;
    p.selected = id;
    return true;
}

// 停用/切换/离焦由宿主调用；临时图钉与草稿一起撤回，不修改文档和历史。
cancel :: (p: *Panel) {
    if p == null return;
    p.editing = false;
    p.focus_editor = false;
    p.editor_size = JM.Vector2.{ 0, 0 };
    p.draft = Draft.{};
}

// 默认只应用到内存，兼容列表内编辑；persist=true 时必须安全落盘成功才清除草稿。
// olib 的 `d := &p.draft` 在 Jai 是 `d := *p.draft`（`*x` 取地址，`x.*` 解引用）。
apply :: (p: *Panel, s: *notes.Session, persist := false) -> notes.Error {
    if p == null || !p.editing return .Invalid_Argument;
    d := *p.draft;
    note: notes.Note;
    note.id = d.id;
    note.has_position = d.has_position;
    note.position = d.position;
    note.title = STRING.trim(scn_buffer_text(d.title));
    note.scene = scn_buffer_text(d.scene);
    note.object_id = scn_buffer_text(d.object_id);
    note.text = scn_buffer_text(d.text);
    note.screenshot = scn_buffer_text(d.screenshot);
    note.source_hint = scn_buffer_text(d.source_hint);
    note.resolution = scn_buffer_text(d.resolution);
    note.status = notes.PENDING;
    if d.resolved note.status = notes.RESOLVED;
    id := note.id;
    err: notes.Error;
    if id == 0 {
        new_id, add_error := notes.add(s, note, persist);
        err = add_error;
        id = new_id;
    } else {
        err = notes.replace(s, note, persist);
    }
    p.error = err;
    if err == .None {
        cancel(p);
        p.selected = id;
    }
    return err;
}
//@endregion
//@endregion

//@region 批注列表与兼容面板

// floating_editor=true 只画列表/详情，编辑交给 draw_editor；否则保留原来的内联草稿界面。
draw :: (p: *Panel, s: *notes.Session, target := notes.Note.{}, floating_editor := false) -> (actions: Actions) {
    if p == null || s == null || !s.initialized return actions;
    imgui_set_next_window_size(ImGui.ImVec2.{ 460, 620 }, ImGui.Cond.FirstUseEver);
    if imgui_begin(WINDOW) {
        scn_wrapped(tprint("文件：%", s.path));
        scn_wrapped("保存后，在 Agent 中说：处理项目中未处理的场景批注。");
        if imgui_button("批注总览") {
            p.overview_open = true;
            imgui_set_window_focus(OVERVIEW_WINDOW);
        }
        imgui_begin_disabled(p.editing);
        if imgui_button("保存文件") p.error = notes.save(s);
        imgui_same_line();
        if imgui_button("重新载入") {
            if notes.is_dirty(s) imgui_open_popup("放弃未保存批注？");
            else p.error = notes.reload(s);
        }
        imgui_begin_disabled(!notes.can_undo(s));
        if imgui_button("撤销") p.error = notes.undo(s);
        imgui_end_disabled();
        imgui_same_line();
        imgui_begin_disabled(!notes.can_redo(s));
        if imgui_button("重做") p.error = notes.redo(s);
        imgui_end_disabled();
        if !floating_editor {
            imgui_same_line();
            if imgui_button("新建批注") {
                initial := target;
                initial.id = 0;
                _ = start(p, initial);
            }
        }
        imgui_end_disabled();
        if notes.is_dirty(s) ImGui.TextUnformatted("有未保存修改");
        confirm_reload(p, s);
        if p.error != .None scn_wrapped(notes.error_text(p.error));
        imgui_separator();
        if p.editing && !floating_editor {
            draw_draft(p, s);
        } else {
            imgui_begin_disabled(p.editing);
            imgui_checkbox("显示已处理", *p.show_resolved);
            list_height := imgui_get_text_line_height_with_spacing() * 7;
            if imgui_begin_child("##notes", ImGui.ImVec2.{ 0, list_height }, true) {
                for note: notes.all(s) {
                    if !p.show_resolved && note.status == notes.RESOLVED continue;
                    label_text := STRING.trim(note.title);
                    if label_text == "" label_text = note.scene;
                    label := tprint("#%  %  %", note.id, scn_status_text(note), label_text);
                    position := imgui_get_cursor_screen_pos();
                    clicked := imgui_selectable(tprint("##note-%", note.id), p.selected == note.id,
                                                ImGui.SelectableFlags.None,
                                                ImGui.ImVec2.{ 0, imgui_get_text_line_height() });
                    // olib 的 DrawList_AddText：标签自己画在 Selectable 上，避免 ImGui 把 "##" 之后吞掉。
                    imgui_draw_text(imgui_get_window_draw_list(), position,
                                    ImGui.GetColorU32(ImGui.Col.Text), label);
                    if clicked {
                        p.selected = note.id;
                        if floating_editor _ = start(p, note);
                    }
                }
            }
            imgui_end_child();
            imgui_end_disabled();
            imgui_separator();
            imgui_begin_disabled(p.editing);
            actions = draw_details(p, s);
            imgui_end_disabled();
        }
    }
    imgui_end();
    overview_actions := draw_overview(p, s);
    if overview_actions.locate != 0 actions = overview_actions;
    return actions;
}

confirm_reload :: (p: *Panel, s: *notes.Session) {
    if imgui_begin_popup_modal("放弃未保存批注？", null, ImGui.WindowFlags.AlwaysAutoResize) {
        ImGui.TextUnformatted("本地未保存内容将被磁盘文件替换。此操作不可撤销。");
        if imgui_button("放弃并载入") {
            p.error = notes.reload(s, true);
            imgui_close_current_popup();
        }
        imgui_same_line();
        if imgui_button("取消") imgui_close_current_popup();
    }
    ImGui.EndPopup();
}

draw_details :: (p: *Panel, s: *notes.Session) -> (actions: Actions) {
    note, ok := notes.find(s, p.selected);
    if !ok {
        scn_wrapped("在世界中点击放置便签，或点击已有图钉。");
        return actions;
    }
    ImGui.TextUnformatted(tprint("#% · %", note.id, scn_status_text(note)));
    if STRING.trim(note.title) != "" scn_wrapped(note.title);
    scn_wrapped(tprint("场景：%", note.scene));
    if note.object_id != "" scn_wrapped(tprint("关联对象（可选）：%", note.object_id));
    if note.has_position {
        ImGui.TextUnformatted(tprint("世界位置：%, %, %",
                                     note.position.x, note.position.y, note.position.z));
    }
    scn_wrapped(note.text);
    if note.screenshot != "" scn_wrapped(tprint("截图：%", note.screenshot));
    if note.source_hint != "" scn_wrapped(tprint("源码提示：%", note.source_hint));
    if note.resolution != "" scn_wrapped(tprint("处理说明：%", note.resolution));
    imgui_begin_disabled(!note.has_position);
    if imgui_button("定位标记") {
        actions.locate = note.id;
        if note.status == notes.RESOLVED p.show_resolved = true;
    }
    imgui_end_disabled();
    imgui_same_line();
    if imgui_button("编辑") _ = start(p, note);
    if note.status == notes.RESOLVED {
        imgui_same_line();
        if imgui_button("重新打开") p.error = notes.reopen(s, note.id);
    }
    return actions;
}

draw_draft :: (p: *Panel, s: *notes.Session) {
    d := *p.draft;
    if d.id == 0 ImGui.TextUnformatted("新批注草稿");
    else          ImGui.TextUnformatted("编辑批注草稿");
    scn_input("标题（可选）", d.title);
    scn_input("场景", d.scene);
    scn_input("对象 ID（可选）", d.object_id);
    imgui_checkbox("记录世界位置", *d.has_position);
    if d.has_position {
        imgui_input_float("X", *d.position.x);
        imgui_input_float("Y", *d.position.y);
        imgui_input_float("Z", *d.position.z);
    }
    ImGui.TextUnformatted("笔记");
    scn_input_multiline("##text", d.text, imgui_get_text_line_height_with_spacing() * 6);
    scn_input("截图路径（可选）", d.screenshot);
    scn_input("源码提示（可选）", d.source_hint);
    if d.id != 0 {
        imgui_checkbox("已处理", *d.resolved);
        ImGui.TextUnformatted("处理说明（标记已处理时必填）");
        scn_input_multiline("##resolution", d.resolution, imgui_get_text_line_height_with_spacing() * 3);
    }
    if imgui_button("应用批注") _ = apply(p, s);
    imgui_same_line();
    if imgui_button("取消草稿") cancel(p);
}
//@endregion

//@region 批注总览

// draw 已调用此窗口；只接入世界图钉的宿主可自行设置 overview_open 并每帧调用一次。
// 浏览与筛选不修改文档；编辑复用独立草稿，定位仍由宿主消费稳定 ID。
draw_overview :: (p: *Panel, s: *notes.Session) -> (actions: Actions) {
    if p == null || s == null || !s.initialized || !p.overview_open return actions;
    imgui_set_next_window_size(ImGui.ImVec2.{ 760, 620 }, ImGui.Cond.FirstUseEver);
    if imgui_begin(OVERVIEW_WINDOW, *p.overview_open) {
        items := notes.all(s);
        pending := 0;
        for note: items {
            if note.status == notes.PENDING pending += 1;
        }
        ImGui.TextUnformatted(tprint("共 % 条 · 待处理 % · 已处理 %",
                                     items.count, pending, items.count - pending));
        // olib 的 `for status in Overview_Status`：Jai 没有枚举迭代，三个单选按钮直接展开。
        if imgui_radio_button("全部", p.overview_status == .All) p.overview_status = .All;
        imgui_same_line();
        if imgui_radio_button("待处理", p.overview_status == .Pending) p.overview_status = .Pending;
        imgui_same_line();
        if imgui_radio_button("已处理", p.overview_status == .Resolved) p.overview_status = .Resolved;
        imgui_set_next_item_width(-1);
        scn_input_hint("##search", "搜索标题、正文、场景或处理说明", p.overview_query);
        query := STRING.trim(scn_buffer_text(p.overview_query));
        matched := 0;
        avail := imgui_get_content_region_avail();
        table_height := max(cast(float32) 100, avail.y * 0.48);
        flags := ImGui.TableFlags.RowBg | ImGui.TableFlags.BordersInnerH |
                 ImGui.TableFlags.Resizable | ImGui.TableFlags.ScrollY;
        if imgui_begin_table("##overview", 4, flags, ImGui.ImVec2.{ 0, table_height }) {
            imgui_table_setup_column("编号", ImGui.TableColumnFlags.WidthFixed, 60);
            imgui_table_setup_column("状态", ImGui.TableColumnFlags.WidthFixed, 65);
            imgui_table_setup_column("标题 / 笔记", ImGui.TableColumnFlags.WidthStretch, 2);
            imgui_table_setup_column("场景", ImGui.TableColumnFlags.WidthStretch, 1);
            imgui_table_setup_scroll_freeze(0, 1);
            imgui_table_headers_row();
            for note: items {
                if !overview_matches(note, p.overview_status, query) continue;
                matched += 1;
                imgui_table_next_row();
                imgui_table_next_column();
                imgui_begin_disabled(p.editing);
                if imgui_selectable(tprint("#%", note.id), p.selected == note.id,
                                    ImGui.SelectableFlags.SpanAllColumns) {
                    _ = select(p, note.id);
                }
                imgui_end_disabled();
                imgui_table_next_column();
                ImGui.TextUnformatted(scn_status_text(note));
                imgui_table_next_column();
                title := STRING.trim(note.title);
                if title == "" title = preview_text(note.text);
                scn_wrapped(title);
                imgui_table_next_column();
                scn_wrapped(note.scene);
            }
            imgui_end_table();
        }
        if items.count == 0 scn_wrapped("还没有批注。在场景中放置图钉，保存后即可在这里审阅。");
        else if matched == 0 scn_wrapped("没有符合筛选条件的批注。");
        if p.editing scn_wrapped("正在编辑便签；保存或取消后可选择其他批注。");
        imgui_separator();
        if imgui_begin_child("##review", ImGui.ImVec2.{ 0, 0 }) {
            note, found := notes.find(s, p.selected);
            if found && overview_matches(note, p.overview_status, query) {
                imgui_begin_disabled(p.editing);
                actions = draw_details(p, s);
                imgui_end_disabled();
            } else {
                scn_wrapped("选择上方批注，查看完整内容。");
            }
            if p.error != .None scn_wrapped(notes.error_text(p.error));
        }
        imgui_end_child();
    }
    imgui_end();
    return actions;
}

// olib 用 strings.to_lower(…, temp_allocator) 后做 contains；这里用 contains_nocase，
// 省掉逐字段的临时小写副本（两个返回值的第一个是 found）。
overview_matches :: (note: notes.Note, status: Overview_Status, query: string) -> bool {
    if status == .Pending && note.status != notes.PENDING return false;
    if status == .Resolved && note.status != notes.RESOLVED return false;
    if query == "" return true;
    found, _ := STRING.contains_nocase(note.title, query);
    if found return true;
    found, _ = STRING.contains_nocase(note.text, query);
    if found return true;
    found, _ = STRING.contains_nocase(note.scene, query);
    if found return true;
    found, _ = STRING.contains_nocase(note.object_id, query);
    if found return true;
    found, _ = STRING.contains_nocase(note.resolution, query);
    if found return true;
    found, _ = STRING.contains_nocase(tprint("#%", note.id), query);
    return found;
}

// 无标题时只在审阅列表摘取第一行；世界图钉仍不显示文字。
preview_text :: (text: string) -> string {
    end := 0;
    truncated := false;
    for i: 0..text.count - 1 {
        // Jai 没有 `'\r'` 这种字符字面量：用字节值（13 '\r'、10 '\n'）。
        if text[i] == 13 || text[i] == 10 || i >= 120 {
            truncated = true;
            break;
        }
        end = i + 1;
    }
    if truncated return tprint("%…", STRING.slice(text, 0, end));
    return text;
}
//@endregion

//@region 就地便签编辑

// anchor/viewport 是最终 drawable 像素。anchor 是草稿世界位置的投影，不是鼠标当前位置。
// 显示临时图钉后在其旁边打开编辑框；新建/修改均在安全保存成功后才关闭，Esc/关闭按钮只取消草稿。
draw_editor :: (p: *Panel, s: *notes.Session, anchor: JM.Vector2, viewport: F.Rect,
                marker_draw_list: *ImGui.ImDrawList = null) -> (saved: bool) {
    if p == null || s == null || !s.initialized || !p.editing return saved;
    io := imgui_get_io();
    if io == null return saved;
    scale := JM.Vector2.{ io.DisplayFramebufferScale.x, io.DisplayFramebufferScale.y };
    if scale.x <= 0 || scale.y <= 0 return saved;
    work := imgui_get_main_viewport();
    if work == null return saved;
    origin := work.Pos;
    if p.draft.has_position {
        list := begin_pins(viewport, scale, marker_draw_list);
        if in_rect(anchor, viewport) {
            draw_pin(list, ImGui.ImVec2.{ origin.x + anchor.x / scale.x, origin.y + anchor.y / scale.y },
                     imgui_get_font_size(), p.draft.resolved, true, true);
            draw_pin_title(list, scn_buffer_text(p.draft.title), anchor, viewport, scale);
        }
        imgui_draw_pop_clip_rect(list);
    }
    font_size := imgui_get_font_size();
    bounds := F.Rect.{ work.WorkPos.x + 12, work.WorkPos.y + 12,
                       max(1.0, work.WorkSize.x - 24), max(1.0, work.WorkSize.y - 24) };
    width := min(max(300.0, font_size * 24), bounds.w);
    height := font_size * 13;
    if p.editor_size.y > 0 height = p.editor_size.y;
    rect := editor_rect(JM.Vector2.{ origin.x + anchor.x / scale.x, origin.y + anchor.y / scale.y },
                        bounds, JM.Vector2.{ width, height });
    imgui_set_next_window_pos(ImGui.ImVec2.{ rect.x, rect.y }, ImGui.Cond.Always);
    imgui_set_next_window_size(ImGui.ImVec2.{ width, 0 }, ImGui.Cond.Always);
    imgui_set_next_window_size_constraints(ImGui.ImVec2.{ min(160.0, width), 0 },
                                           ImGui.ImVec2.{ bounds.w, bounds.h });
    if p.focus_editor imgui_set_next_window_focus();
    imgui_push_style_color(ImGui.Col.Border, .[ 0.9, 0.63, 0.23, 1.0 ]);
    imgui_push_style_color(ImGui.Col.WindowBg, .[ 0.075, 0.065, 0.09, 0.98 ]);
    imgui_push_style_color(ImGui.Col.TitleBgActive, .[ 0.16, 0.12, 0.12, 1.0 ]);
    open := true;
    want_save := false;
    want_cancel := false;
    has_text := STRING.trim(scn_buffer_text(p.draft.text)) != "";
    // ### 之后是稳定的窗口身份：标题里的编号可以变，布局不会被当成新窗口。
    title := "新便签（未保存）###jalib_world_note";
    if p.draft.id != 0 title = tprint("便签 #%###jalib_world_note", p.draft.id);
    flags := ImGui.WindowFlags.AlwaysAutoResize | ImGui.WindowFlags.NoResize |
             ImGui.WindowFlags.NoSavedSettings;
    if imgui_begin(title, *open, flags) {
        scn_wrapped(scn_buffer_text(p.draft.scene));
        imgui_set_next_item_width(-1);
        scn_input_hint("##title", "标题（可选，留空只显示图钉）", p.draft.title);
        if p.focus_editor {
            imgui_set_keyboard_focus_here(0);
            p.focus_editor = false;
        }
        text_flags := ImGui.InputTextFlags.EnterReturnsTrue | ImGui.InputTextFlags.CtrlEnterForNewLine;
        entered := imgui_input_text_multiline("##note", p.draft.text.data, p.draft.text.count,
                                              ImGui.ImVec2.{ -1, imgui_get_text_line_height_with_spacing() * 5 },
                                              text_flags);
        if entered want_save = true;
        if p.draft.id != 0 {
            imgui_checkbox("已处理", *p.draft.resolved);
            if p.draft.resolved {
                ImGui.TextUnformatted("处理说明");
                imgui_input_text_multiline("##result", p.draft.resolution.data, p.draft.resolution.count,
                                           ImGui.ImVec2.{ -1, imgui_get_text_line_height_with_spacing() * 3 });
            }
        }
        if p.error != .None scn_wrapped(notes.error_text(p.error));
        ImGui.TextUnformatted("Enter 保存 · Shift+Enter 换行 · Esc 取消");
        has_text = STRING.trim(scn_buffer_text(p.draft.text)) != "";
        imgui_begin_disabled(!has_text);
        button_label := "添加";
        if p.draft.id != 0 button_label = "保存";
        if imgui_button(button_label) want_save = true;
        imgui_end_disabled();
        imgui_same_line();
        if imgui_button("取消") want_cancel = true;
        if want_save && !has_text want_save = false;
        focus_flags := ImGui.FocusedFlags.RootWindow | ImGui.FocusedFlags.ChildWindows;
        if imgui_is_window_focused(focus_flags) && imgui_is_key_pressed(ImGui.Key.Escape, false) {
            want_cancel = true;
        }
        size := imgui_get_window_size();
        p.editor_size = JM.Vector2.{ size.x, size.y };
    }
    imgui_end();
    imgui_pop_style_color(3);
    if !open || want_cancel {
        cancel(p);
    } else if want_save {
        saved = apply(p, s, true) == .None;
    }
    return saved;
}

// 纯布局查询：先尝试图钉右侧，放不下时换到左侧，并钳制到宿主工作区。
editor_rect :: (anchor: JM.Vector2, bounds: F.Rect, size: JM.Vector2) -> F.Rect {
    width := min(max(1.0, size.x), max(1.0, bounds.w));
    height := min(max(1.0, size.y), max(1.0, bounds.h));
    x := anchor.x + 24;
    if x + width > bounds.x + bounds.w x = anchor.x - width - 24;
    y := anchor.y - height * 0.2;
    result: F.Rect;
    result.x = clamp(x, bounds.x, bounds.x + max(0.0, bounds.w - width));
    result.y = clamp(y, bounds.y, bounds.y + max(0.0, bounds.h - height));
    result.w = width;
    result.h = height;
    return result;
}
//@endregion

//@region 世界图钉绘制与命中

// 所有 pin API 的 anchor 均为针尖（世界位置投影）；圆头在上方，不能按原来的圆点半径命中。
pin_geometry :: (anchor: JM.Vector2, font_size: float32, scale: JM.Vector2) ->
                (head: JM.Vector2, radius: JM.Vector2) {
    r := max(1.0, font_size * 0.65);
    radius = JM.Vector2.{ r * scale.x, r * scale.y };
    head = JM.Vector2.{ anchor.x, anchor.y - radius.y * 1.6 };
    return head, radius;
}

// 只查询几何，不读取输入。markers 应与当前显示的场景/状态筛选一致；返回最近命中的稳定 ID。
pin_hit :: (markers: [] notes.Marker, point: JM.Vector2, viewport: F.Rect, font_size: float32,
            scale := JM.Vector2.{ 1, 1 }) -> u64 {
    if !in_rect(point, viewport) || font_size <= 0 || scale.x <= 0 || scale.y <= 0 return 0;
    nearest: float32 = 1e30;
    id: u64;
    for marker: markers {
        if marker.id == 0 || !in_rect(marker.position, viewport) continue;
        head, radius := pin_geometry(marker.position, font_size, scale);
        x := (point.x - head.x) / radius.x;
        y := (point.y - head.y) / radius.y;
        distance := x * x + y * y;
        body := y >= 0.25 && y <= 1.7 && JM.abs(x) <= 0.1 + 0.8 * max(0.0, 1.6 - y) / 1.35;
        if (distance <= 1.1 * 1.1 || body) && distance < nearest {
            nearest = distance;
            id = marker.id;
        }
    }
    return id;
}

// 在最终场景上方、普通面板下方绘制。宿主负责相机前方与当前场景的投影筛选。
draw_markers :: (p: *Panel, s: *notes.Session, markers: [] notes.Marker, viewport: F.Rect,
                 draw_list: *ImGui.ImDrawList = null) {
    if p == null || s == null || viewport.w <= 0 || viewport.h <= 0 return;
    io := imgui_get_io();
    if io == null return;
    scale := JM.Vector2.{ io.DisplayFramebufferScale.x, io.DisplayFramebufferScale.y };
    if scale.x <= 0 || scale.y <= 0 return;
    work := imgui_get_main_viewport();
    if work == null return;
    origin := work.Pos;
    list := begin_pins(viewport, scale, draw_list);
    for marker: markers {
        note, ok := notes.find(s, marker.id);
        if !ok || (!p.show_resolved && note.status == notes.RESOLVED) continue;
        if p.editing && marker.id == p.draft.id continue;
        if !in_rect(marker.position, viewport) continue;
        draw_pin(list, ImGui.ImVec2.{ origin.x + marker.position.x / scale.x,
                                      origin.y + marker.position.y / scale.y },
                 imgui_get_font_size(), note.status == notes.RESOLVED, p.selected == marker.id, false);
        draw_pin_title(list, note.title, marker.position, viewport, scale);
    }
    imgui_draw_pop_clip_rect(list);
}

// 标题是被动的图钉说明，命中仍限于圆头和针尖，不扩大宿主的场景输入区域。
draw_pin_title :: (list: *ImGui.ImDrawList, title: string, anchor: JM.Vector2, viewport: F.Rect,
                   scale: JM.Vector2) {
    text := STRING.trim(title);
    if text == "" return;
    font_size := imgui_get_font_size();
    work := imgui_get_main_viewport();
    if work == null return;
    origin := work.Pos;
    bounds := F.Rect.{ origin.x + viewport.x / scale.x, origin.y + viewport.y / scale.y,
                       viewport.w / scale.x, viewport.h / scale.y };
    padding := font_size * 0.35;
    width := min(font_size * 16, max(1.0, bounds.w - padding * 2));
    if imgui_calc_text_size(text).x > width {
        end := 0;
        for i: 1..text.count - 1 {
            if imgui_calc_text_size(tprint("%…", STRING.slice(text, 0, i))).x > width break;
            end = i;
        }
        text = tprint("%…", STRING.slice(text, 0, end));
    }
    size := imgui_calc_text_size(text);
    r := font_size * 0.65;
    head := JM.Vector2.{ origin.x + anchor.x / scale.x, origin.y + anchor.y / scale.y - r * 1.6 };
    rect := pin_title_rect(head, bounds, JM.Vector2.{ size.x + padding * 2, size.y + padding * 2 }, r + 6);
    low := ImGui.ImVec2.{ rect.x, rect.y };
    high := ImGui.ImVec2.{ rect.x + rect.w, rect.y + rect.h };
    imgui_draw_rect_filled(list, low, high, imgui_color_u32(.[ 0.075, 0.065, 0.09, 0.94 ]), 4);
    imgui_draw_push_clip_rect(list, low, high, true);
    imgui_draw_text(list, ImGui.ImVec2.{ low.x + padding, low.y + padding },
                    imgui_color_u32(.[ 1.0, 0.94, 0.82, 1.0 ]), text);
    imgui_draw_pop_clip_rect(list);
}

pin_title_rect :: (head: JM.Vector2, bounds: F.Rect, size: JM.Vector2, gap: float32) -> F.Rect {
    width := min(size.x, max(1.0, bounds.w));
    height := min(size.y, max(1.0, bounds.h));
    x := head.x + gap;
    if x + width > bounds.x + bounds.w x = head.x - gap - width;
    result: F.Rect;
    result.x = clamp(x, bounds.x, bounds.x + max(0.0, bounds.w - width));
    result.y = clamp(head.y - height * 0.5, bounds.y, bounds.y + max(0.0, bounds.h - height));
    result.w = width;
    result.h = height;
    return result;
}

begin_pins :: (viewport: F.Rect, scale: JM.Vector2, draw_list: *ImGui.ImDrawList = null) -> *ImGui.ImDrawList {
    work := imgui_get_main_viewport();
    list := draw_list;
    if list == null list = imgui_get_background_draw_list();
    if list == null return null;
    if work != null {
        origin := work.Pos;
        low := ImGui.ImVec2.{ origin.x + viewport.x / scale.x, origin.y + viewport.y / scale.y };
        high := ImGui.ImVec2.{ low.x + viewport.w / scale.x, low.y + viewport.h / scale.y };
        imgui_draw_push_clip_rect(list, low, high, true);
    }
    return list;
}

draw_pin :: (list: *ImGui.ImDrawList, anchor: ImGui.ImVec2, font_size: float32,
             resolved: bool, selected: bool, draft: bool) {
    if list == null return;
    r := max(1.0, font_size * 0.65);
    head := ImGui.ImVec2.{ anchor.x, anchor.y - r * 1.6 };
    color := .[ 0.95, 0.63, 0.18, 1.0 ];
    if resolved color = .[ 0.30, 0.73, 0.42, 1.0 ];
    if draft color[3] = 0.72;
    fill := imgui_color_u32(color);
    ink := imgui_color_u32(.[ 0.1, 0.08, 0.09, 1.0 ]);
    imgui_draw_triangle_filled(list,
                               ImGui.ImVec2.{ head.x - r * 0.8, head.y + r * 0.25 },
                               ImGui.ImVec2.{ head.x + r * 0.8, head.y + r * 0.25 },
                               anchor, fill);
    imgui_draw_circle_filled(list, head, r + 1.5, ink);
    imgui_draw_circle_filled(list, head, r, fill);
    if selected {
        imgui_draw_circle(list, head, r + 3, imgui_color_u32(.[ 1.0, 0.87, 0.58, 1.0 ]), 2);
    }
    thickness := max(1.5, r * 0.13);
    if draft {
        imgui_draw_line(list, ImGui.ImVec2.{ head.x - r * 0.35, head.y },
                        ImGui.ImVec2.{ head.x + r * 0.35, head.y }, ink, thickness);
        imgui_draw_line(list, ImGui.ImVec2.{ head.x, head.y - r * 0.35 },
                        ImGui.ImVec2.{ head.x, head.y + r * 0.35 }, ink, thickness);
    } else if resolved {
        imgui_draw_line(list, ImGui.ImVec2.{ head.x - r * 0.4, head.y },
                        ImGui.ImVec2.{ head.x - r * 0.1, head.y + r * 0.3 }, ink, thickness);
        imgui_draw_line(list, ImGui.ImVec2.{ head.x - r * 0.1, head.y + r * 0.3 },
                        ImGui.ImVec2.{ head.x + r * 0.45, head.y - r * 0.35 }, ink, thickness);
    } else {
        // olib: for row in -1 ..= 1 —— 负起点区间在 Jai 里写成 0..2 再减 1。
        for row: 0..2 {
            y := (cast(float32) row - 1) * r * 0.3;
            imgui_draw_line(list, ImGui.ImVec2.{ head.x - r * 0.35, head.y + y },
                            ImGui.ImVec2.{ head.x + r * 0.35, head.y + y }, ink, thickness);
        }
    }
}

in_rect :: (point: JM.Vector2, rect: F.Rect) -> bool {
    return point.x >= rect.x && point.y >= rect.y &&
           point.x < rect.x + rect.w && point.y < rect.y + rect.h;
}
//@endregion
