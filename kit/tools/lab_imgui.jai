// kit/tools/lab_imgui.jai —— kit/tools 下所有工具共用的一层 ImGui 薄包装：标签/ID 吃 Jai `string`。
//
// 为什么需要这一层：jacket 的 ImGui 声明是纯 C 绑定，所有标签参数（label / str_id / fmt）都是
// `*u8`（NUL 结尾的 C 字符串）。Jai 只允许**常量**字符串隐式转 `*u8`：
//
//     ImGui.Button("字面量")            // 可以（编译期常量带 NUL 结尾）
//     ImGui.Button(tprint("%##%", a, b)) // 不行：argument of type `string` does not match `*u8`
//
// 工具里的标签几乎全是运行期拼出来的（tprint 出 "##参数名:字段名" 这种稳定 ID），所以每个调用点都
// 手写 temp_c_string 既不安全（容易漏）也不可读（`%s` 的格式化用法还会在运行期崩）。这里一次性
// 包掉，语义集中在一处，perf_overlay / scene_notes / tween_preview 直接复用。
//
// 这一层的约定：
//   1. 只用 temp 存储：temp_c_string 从临时分配器切一份带 NUL 的副本，随帧/作用域自动回收；
//      调用者不需要、也不应该 free 包装层内部的字符串。传进来的 `string` 借用即可。
//   2. 标签里的 `%` 一律不参与格式化：SetTooltip / TextColored 走 `"%s"` + 一个参数，
//      文本里出现 `%` 也不会被 ImGui 当成格式化指令。
//   3. 尺寸参数按值收 ImGui.ImVec2（默认 {0,0}），内部取地址给 C 声明；边界布尔直接是 bool
//      （jacket 没有 ChildFlags / SeparatorFlags）。
//   4. 不改 jacket 的 stdlib 声明目录：这里只是把 `string` 转成 `*u8` 后再调 ImGui。
//
// 使用前提（由 #load 它的模块提供，本文件不重复 #import，避免 "already declared in this scope"）：
//   Basic —— temp_c_string
//   ImGui —— jacket stdlib 的 ImGui 声明（模块里 `ImGui :: #import "thirdparty/imgui"`）
//
// 未包装的部分：TextUnformatted / CalcTextSize / PushID / GetID / SeparatorText 之类，jacket 的
// ImGui 模块自己带 `#optional` 的 string 重载，直接用 `ImGui.Xxx(some_string)` 即可；ColorButton
// 之类的值类型差异（[4] float32 ↔ ImVec4）在这一层里一并抹平。

//@region 按钮与选择

// ImGui.Button(label, size)；size 默认 {0,0}（按内容宽度）。
imgui_button :: (label: string, size := ImGui.ImVec2.{ 0, 0 }) -> bool {
    return ImGui.Button(temp_c_string(label), *size);
}

imgui_checkbox :: (label: string, value: *bool) -> bool {
    return ImGui.Checkbox(temp_c_string(label), value);
}

// 选中态按值传（工具里的 "当前项" 都是 Session 上的下标比较）；要写回时用 imgui_selectable_ref。
imgui_selectable :: (label: string, selected := false, flags := ImGui.SelectableFlags.None,
                     size := ImGui.ImVec2.{ 0, 0 }) -> bool {
    return ImGui.Selectable(temp_c_string(label), selected, flags, *size);
}

imgui_selectable_ref :: (label: string, selected: *bool, flags := ImGui.SelectableFlags.None,
                         size := ImGui.ImVec2.{ 0, 0 }) -> bool {
    return ImGui.Selectable(temp_c_string(label), selected, flags, *size);
}

// fmt 同样是 `*u8`：调用点写 "%.2f" 时是常量（本来能过），但允许运行期拼出来的格式串。
imgui_slider_float :: (label: string, value: *float32, minimum: float32, maximum: float32,
                       format := "%.3f", flags := ImGui.SliderFlags.None) -> bool {
    return ImGui.SliderFloat(temp_c_string(label), value, minimum, maximum, temp_c_string(format), flags);
}

// 预览区域这种"要矩形但不要按钮样子"的点击面。
imgui_invisible_button :: (id: string, size := ImGui.ImVec2.{ 0, 0 },
                           flags := ImGui.ButtonFlags.None) -> bool {
    return ImGui.InvisibleButton(temp_c_string(id), *size, flags);
}

imgui_separator_text :: (label: string) {
    // jacket 有 string 的 #optional 重载，但统一走包装，工具里就只用一套写法。
    ImGui.SeparatorText(temp_c_string(label));
}
//@endregion

//@region 窗口、子区与弹窗

imgui_begin :: (name: string, p_open: *bool = null, flags := ImGui.WindowFlags.None) -> bool {
    return ImGui.Begin(temp_c_string(name), p_open, flags);
}

// jacket 的 BeginChild 第三个参数是裸 bool（没有 ChildFlags），与 olib 的 {.Borders} 一一对应。
imgui_begin_child :: (id: string, size := ImGui.ImVec2.{ 0, 0 }, border := false,
                      flags := ImGui.WindowFlags.None) -> bool {
    return ImGui.BeginChild(temp_c_string(id), *size, border, flags);
}

imgui_begin_popup :: (id: string, flags := ImGui.WindowFlags.None) -> bool {
    return ImGui.BeginPopup(temp_c_string(id), flags);
}

imgui_begin_popup_modal :: (name: string, p_open: *bool = null, flags := ImGui.WindowFlags.None) -> bool {
    return ImGui.BeginPopupModal(temp_c_string(name), p_open, flags);
}

imgui_open_popup :: (id: string, flags := ImGui.PopupFlags.None) {
    ImGui.OpenPopup(temp_c_string(id), flags);
}

imgui_is_popup_open :: (id: string, flags := ImGui.PopupFlags.None) -> bool {
    return ImGui.IsPopupOpen(temp_c_string(id), flags);
}
//@endregion

//@region 颜色与文本

// 工具里的颜色统一是 [4] float32（sh.Value.number / Parameter_State.color 都是它），
// jacket 的 ColorButton 要 *ImVec4：在这里换掉，调用点不再关心 ImVec4。
imgui_color_button :: (desc_id: string, color: [4] float32, flags := ImGui.ColorEditFlags.None,
                       size := ImGui.ImVec2.{ 0, 0 }) -> bool {
    col := ImGui.ImVec4.{ color[0], color[1], color[2], color[3] };
    return ImGui.ColorButton(temp_c_string(desc_id), *col, flags, *size);
}

// 已经是 ImVec4 的常量（例如 ERROR_COLOR）用这个变体，省一次逐分量拷贝。
imgui_color_button_v :: (desc_id: string, color: ImGui.ImVec4, flags := ImGui.ColorEditFlags.None,
                         size := ImGui.ImVec2.{ 0, 0 }) -> bool {
    col := color;
    return ImGui.ColorButton(temp_c_string(desc_id), *col, flags, *size);
}

imgui_color_picker4 :: (label: string, color: *[4] float32, flags := ImGui.ColorEditFlags.None,
                        reference: *float32 = null) -> bool {
    return ImGui.ColorPicker4(temp_c_string(label), color, flags, reference);
}

// TextColored 的 fmt 是 `*u8` 且带可变参数：文本里有 % 时必须走 "%s"，否则会读错栈上的参数。
imgui_text_colored :: (color: [4] float32, text: string) {
    col := ImGui.ImVec4.{ color[0], color[1], color[2], color[3] };
    ImGui.TextColored(*col, "%s", temp_c_string(text));
}

imgui_text_colored_v :: (color: ImGui.ImVec4, text: string) {
    col := color;
    ImGui.TextColored(*col, "%s", temp_c_string(text));
}

// ImGui.SetTooltip(fmt, ...)：同一类问题，文本只当数据，不当格式串。
imgui_set_tooltip :: (text: string) {
    ImGui.SetTooltip("%s", temp_c_string(text));
}
//@endregion

//@region DrawList：值语义 + string 文本
//
// ImDrawList 的成员分两套声明：`#foreign`（`#cpp_method`，点位参数是 `*ImVec2`）和 jacket 追加的
// `#no_context` 值重载。**点号调用 `dl.AddRectFilled(...)` 只解析 `#cpp_method` 那套**（`this` 不会
// 自动绑到 dl 上，报的是 "argument of type Vector2 does not match *ImDrawList"），所以这里统一用
// `ImGui.ImDrawList.Xxx(dl, 值...)` 的显式写法：值进值出，`*ImVec2` 的取地址留在 jacket 里。
// AddImage 不经过 thirdparty/imgui_foster（那里只有 AddLine/AddRect/AddRectFilled/AddText）：
// ImDrawList 自己的成员是完整的，用 imgui_draw_image 即可。

imgui_draw_rect_filled :: (draw: *ImGui.ImDrawList, minimum: ImGui.ImVec2, maximum: ImGui.ImVec2,
                           color: ImGui.ImU32, rounding := 0.0) {
    ImGui.ImDrawList.AddRectFilled(draw, minimum, maximum, color, rounding);
}

imgui_draw_rect :: (draw: *ImGui.ImDrawList, minimum: ImGui.ImVec2, maximum: ImGui.ImVec2,
                    color: ImGui.ImU32, rounding := 0.0, thickness := 1.0) {
    ImGui.ImDrawList.AddRect(draw, minimum, maximum, color, rounding, ImGui.ImDrawFlags.None, thickness);
}

imgui_draw_line :: (draw: *ImGui.ImDrawList, from: ImGui.ImVec2, to: ImGui.ImVec2,
                    color: ImGui.ImU32, thickness := 1.0) {
    ImGui.ImDrawList.AddLine(draw, from, to, color, thickness);
}

// 值是 string：jacket 的 AddText 值重载直接吃 string（走 text_begin/text_end，不要求 NUL），
// 既不占 temp 存储，也不存在把文本当格式串解析的问题。
imgui_draw_text :: (draw: *ImGui.ImDrawList, position: ImGui.ImVec2, color: ImGui.ImU32, text: string) {
    ImGui.ImDrawList.AddText(draw, position, color, text);
}

imgui_draw_image :: (draw: *ImGui.ImDrawList, texture: ImGui.ImTextureID, minimum: ImGui.ImVec2,
                     maximum: ImGui.ImVec2) {
    ImGui.ImDrawList.AddImage(draw, texture, minimum, maximum);
}
//@endregion

//@region 追加：表格、文本输入、布局与其余绘制原语
//
// perf_imgui / scene_notes_imgui / tween_preview 用到的其余控件。加在这里而不是各文件自己
// temp_c_string，理由与本文件头一致：`*u8` ↔ `string` 的转换只集中在一处，调用点全部是 string。
//
// 已知缺口（jacket 的声明里没有，因此这几个工具的 olib 原行为要不回来）：
//   - 没有 ImGuiInputTextFlags_WordWrap：多行输入框靠滚动而不是折行（仍可手动换行）。
//   - 没有 WindowFlags_NoDocking（jacket 是 ImGui 主干的非 docking 分支）。
//   - 没有 ImGuiStyle.FontSizeBase / PushFontFloat：大字号只能 SetWindowFontScale（见 perf_imgui）。

imgui_dummy :: (size: ImGui.ImVec2) {
    ImGui.Dummy(size);
}

imgui_same_line :: (offset_from_start_x := 0.0, spacing := -1.0) {
    ImGui.SameLine(offset_from_start_x, spacing);
}

imgui_separator :: () {
    ImGui.Separator();
}

imgui_set_next_item_width :: (width: float32) {
    ImGui.SetNextItemWidth(width);
}

imgui_set_next_window_pos :: (pos: ImGui.ImVec2, cond := ImGui.Cond.None, pivot := ImGui.ImVec2.{ 0, 0 }) {
    ImGui.SetNextWindowPos(pos, cond, pivot);
}

imgui_set_next_window_size :: (size: ImGui.ImVec2, cond := ImGui.Cond.None) {
    ImGui.SetNextWindowSize(size, cond);
}

imgui_set_next_window_size_constraints :: (minimum: ImGui.ImVec2, maximum: ImGui.ImVec2) {
    ImGui.SetNextWindowSizeConstraints(minimum, maximum);
}

imgui_set_next_window_focus :: () {
    ImGui.SetNextWindowFocus();
}

imgui_set_window_focus :: (name: string) {
    ImGui.SetWindowFocus(temp_c_string(name));
}

// 按对象地址做 ID 栈（olib 的 imgui.PushIDPtr）：宿主每帧都会调 draw，同一前缀串还不够稳。
imgui_push_id_ptr :: (pointer: *void) {
    ImGui.PushID(pointer);
}

imgui_push_id :: (str_id: string) {
    ImGui.PushID(temp_c_string(str_id));
}

imgui_pop_id :: () {
    ImGui.PopID();
}

imgui_begin_disabled :: (disabled := true) {
    ImGui.BeginDisabled(disabled);
}

imgui_end_disabled :: () {
    ImGui.EndDisabled();
}

imgui_small_button :: (label: string) -> bool {
    return ImGui.SmallButton(temp_c_string(label));
}

imgui_radio_button :: (label: string, active: bool) -> bool {
    return ImGui.RadioButton(temp_c_string(label), active);
}

imgui_collapsing_header :: (label: string, flags := ImGui.TreeNodeFlags.None) -> bool {
    return ImGui.CollapsingHeader(temp_c_string(label), flags);
}

imgui_begin_combo :: (label: string, preview: string, flags := ImGui.ComboFlags.None) -> bool {
    return ImGui.BeginCombo(temp_c_string(label), temp_c_string(preview), flags);
}

imgui_end_combo :: () {
    ImGui.EndCombo();
}

imgui_close_current_popup :: () {
    ImGui.CloseCurrentPopup();
}

// 文本输入：缓冲区是调用方持有的 `*u8` + 字节数（olib 传 cstring + len），布局不变。
imgui_input_text :: (label: string, buffer: *u8, buffer_size: int, flags := ImGui.InputTextFlags.None) -> bool {
    return ImGui.InputText(temp_c_string(label), buffer, cast(u64) buffer_size, flags);
}

imgui_input_text_with_hint :: (label: string, hint: string, buffer: *u8, buffer_size: int,
                               flags := ImGui.InputTextFlags.None) -> bool {
    return ImGui.InputTextWithHint(temp_c_string(label), temp_c_string(hint), buffer,
                                   cast(u64) buffer_size, flags);
}

imgui_input_text_multiline :: (label: string, buffer: *u8, buffer_size: int,
                               size := ImGui.ImVec2.{ 0, 0 },
                               flags := ImGui.InputTextFlags.None) -> bool {
    return ImGui.InputTextMultiline(temp_c_string(label), buffer, cast(u64) buffer_size, size, flags);
}

imgui_input_float :: (label: string, value: *float32, step := 0.0, step_fast := 0.0,
                      format := "%.3f", flags := ImGui.InputTextFlags.None) -> bool {
    return ImGui.InputFloat(temp_c_string(label), value, step, step_fast, temp_c_string(format), flags);
}

// double 精度的滑条（tween_preview 的临时参数）：ImGui 只有通用 SliderScalar。
imgui_slider_double :: (label: string, value: *float64, minimum: *float64, maximum: *float64,
                        format := "%.3f", flags := ImGui.SliderFlags.None) -> bool {
    return ImGui.SliderScalar(temp_c_string(label), ImGui.DataType.Double, value, minimum, maximum,
                              temp_c_string(format), flags);
}

imgui_text_wrapped :: (text: string) {
    ImGui.TextWrapped("%s", temp_c_string(text));
}

imgui_push_text_wrap_pos :: (local_pos_x := 0.0) {
    ImGui.PushTextWrapPos(local_pos_x);
}

imgui_pop_text_wrap_pos :: () {
    ImGui.PopTextWrapPos();
}

// 表格：表头标签是 `*u8`，其余参数按值传（outer_size 的 ImVec2 由 #no_context 重载接收）。
imgui_begin_table :: (str_id: string, columns: int, flags := ImGui.TableFlags.None,
                      outer_size := ImGui.ImVec2.{ 0, 0 }, inner_width := 0.0) -> bool {
    return ImGui.BeginTable(temp_c_string(str_id), cast(s32) columns, flags, outer_size, inner_width);
}

imgui_end_table :: () {
    ImGui.EndTable();
}

imgui_table_setup_column :: (label: string, flags := ImGui.TableColumnFlags.None,
                             init_width_or_weight := 0.0) {
    ImGui.TableSetupColumn(temp_c_string(label), flags, init_width_or_weight);
}

imgui_table_setup_scroll_freeze :: (columns: int, rows: int) {
    ImGui.TableSetupScrollFreeze(cast(s32) columns, cast(s32) rows);
}

imgui_table_headers_row :: () {
    ImGui.TableHeadersRow();
}

imgui_table_next_row :: () {
    ImGui.TableNextRow();
}

imgui_table_next_column :: () {
    ImGui.TableNextColumn();
}

// 其余 DrawList 原语：与上面同一套 `ImGui.ImDrawList.Xxx(draw, 值...)` 写法。
imgui_draw_rect_filled_rounded :: (draw: *ImGui.ImDrawList, minimum: ImGui.ImVec2, maximum: ImGui.ImVec2,
                                   color: ImGui.ImU32, rounding: float32) {
    ImGui.ImDrawList.AddRectFilled(draw, minimum, maximum, color, rounding);
}

imgui_draw_triangle_filled :: (draw: *ImGui.ImDrawList, a: ImGui.ImVec2, b: ImGui.ImVec2,
                               c: ImGui.ImVec2, color: ImGui.ImU32) {
    ImGui.ImDrawList.AddTriangleFilled(draw, a, b, c, color);
}

imgui_draw_quad :: (draw: *ImGui.ImDrawList, a: ImGui.ImVec2, b: ImGui.ImVec2, c: ImGui.ImVec2,
                    d: ImGui.ImVec2, color: ImGui.ImU32, thickness := 1.0) {
    ImGui.ImDrawList.AddQuad(draw, a, b, c, d, color, thickness);
}

imgui_draw_quad_filled :: (draw: *ImGui.ImDrawList, a: ImGui.ImVec2, b: ImGui.ImVec2, c: ImGui.ImVec2,
                           d: ImGui.ImVec2, color: ImGui.ImU32) {
    ImGui.ImDrawList.AddQuadFilled(draw, a, b, c, d, color);
}

imgui_draw_circle :: (draw: *ImGui.ImDrawList, center: ImGui.ImVec2, radius: float32,
                      color: ImGui.ImU32, thickness := 1.0) {
    ImGui.ImDrawList.AddCircle(draw, center, radius, color, 0, thickness);
}

imgui_draw_circle_filled :: (draw: *ImGui.ImDrawList, center: ImGui.ImVec2, radius: float32,
                             color: ImGui.ImU32) {
    ImGui.ImDrawList.AddCircleFilled(draw, center, radius, color);
}

imgui_draw_push_clip_rect :: (draw: *ImGui.ImDrawList, minimum: ImGui.ImVec2, maximum: ImGui.ImVec2,
                              intersect_with_current := true) {
    ImGui.ImDrawList.PushClipRect(draw, minimum, maximum, intersect_with_current);
}

imgui_draw_pop_clip_rect :: (draw: *ImGui.ImDrawList) {
    ImGui.ImDrawList.PopClipRect(draw);
}
//@endregion

//@region 追加：查询、样式色与分组（scene_notes_imgui / tween_preview 需要）
//
// 这里的每一个都是"返回一个小结构体"或"按值收一个颜色"的纯转发。放进来只有两个理由：
//   1. 统一颜色形态：[4] float32 ↔ ImVec4 / ImU32 的转换只在这一层做（工具里全是 [4] float32）；
//   2. 统一取值入口：ImGui 的返回值是 ImVec2 / *ImDrawList / *Viewport，包装保持同一套命名，
//      移植 olib 代码时一行换一行，不需要在调用点区分"哪些走了包装、哪些没走"。
//
// 标签类控件（Button / Selectable / Begin* / Input*）一律必须走包装（见文件头），查询类不强制，
// 但 scene_notes_imgui / tween_preview 全部走这里，保证这两个文件里不出现裸的 ImGui.Xxx(label)。

imgui_color_u32 :: (color: [4] float32) -> ImGui.ImU32 {
    col := ImGui.ImVec4.{ color[0], color[1], color[2], color[3] };
    return ImGui.ColorConvertFloat4ToU32(*col);
}

imgui_push_style_color :: (idx: ImGui.Col, color: [4] float32) {
    ImGui.PushStyleColor(idx, imgui_color_u32(color));
}

imgui_pop_style_color :: (count := 1) {
    ImGui.PopStyleColor(cast(s32) count);
}

imgui_begin_group :: () {
    ImGui.BeginGroup();
}

imgui_end_group :: () {
    ImGui.EndGroup();
}

// Begin/End 成对：Begin 在包装里（标签吃 string），End 放在这里保持同一套命名。
imgui_end :: () {
    ImGui.End();
}

imgui_end_child :: () {
    ImGui.EndChild();
}

imgui_text_unformatted :: (text: string) {
    ImGui.TextUnformatted(text);
}

imgui_set_window_font_scale :: (scale: float32) {
    ImGui.SetWindowFontScale(scale);
}

imgui_set_keyboard_focus_here :: (offset := 0) {
    ImGui.SetKeyboardFocusHere(cast(s32) offset);
}

imgui_is_window_focused :: (flags := ImGui.FocusedFlags.None) -> bool {
    return ImGui.IsWindowFocused(flags);
}

imgui_is_key_pressed :: (key: ImGui.Key, repeat := false) -> bool {
    return ImGui.IsKeyPressed(key, repeat);
}

imgui_get_font_size :: () -> float32 {
    return ImGui.GetFontSize();
}

imgui_get_text_line_height :: () -> float32 {
    return ImGui.GetTextLineHeight();
}

imgui_get_text_line_height_with_spacing :: () -> float32 {
    return ImGui.GetTextLineHeightWithSpacing();
}

imgui_get_cursor_screen_pos :: () -> ImGui.ImVec2 {
    return ImGui.GetCursorScreenPos();
}

imgui_get_content_region_avail :: () -> ImGui.ImVec2 {
    return ImGui.GetContentRegionAvail();
}

imgui_get_window_size :: () -> ImGui.ImVec2 {
    return ImGui.GetWindowSize();
}

imgui_calc_text_size :: (text: string) -> ImGui.ImVec2 {
    return ImGui.CalcTextSize(text);
}

imgui_get_io :: () -> *ImGui.IO {
    return ImGui.GetIO();
}

imgui_get_main_viewport :: () -> *ImGui.Viewport {
    return ImGui.GetMainViewport();
}

imgui_get_window_draw_list :: () -> *ImGui.ImDrawList {
    return ImGui.GetWindowDrawList();
}

imgui_get_background_draw_list :: () -> *ImGui.ImDrawList {
    return ImGui.GetBackgroundDrawList();
}
//@endregion
