// perf_imgui —— 用 Dear ImGui 画 perf_overlay 的悬浮性能面板。
//
// 采样仍由 perf_overlay.Overlay 负责：宿主每帧调用 perf.frame，不需要 perf.init（那是 kit/ui 版的
// 字体与渲染器）。本包只在宿主的 ImGui 帧里提交一个窗口，不初始化 ImGui、不读取 jfoster 输入。
// 窗口不接收鼠标、不抢焦点、不保存布局，输入分配仍由宿主按 WantCaptureMouse 决定。
//
// 一比一移植自 olib kit/tools/perf_overlay/imgui/perf_imgui.odin。Jai / jacket 差异
// （不改对外语义，只改现实手段）：
//   | olib (Odin + imgui_foster)                        | JaiLib (Jai + jacket ImGui)                          |
//   | ------------------------------------------------- | --------------------------------------------------- |
//   | `imgui.PushFontFloat(nil, base * 1.25)`           | `ImGui.SetWindowFontScale(1.25)`（无 PushFontFloat）  |
//   | `imgui.GetStyle().FontSizeBase`                   | 模块级 base_font_size：首帧取 GetFontSize() 当基准    |
//   | `imgui.WindowFlags_NoDocking`                     | 去掉（jacket 是非 docking 主干，没有该标志）            |
//   | `imgui.DrawList_AddRectFilled/AddLine`            | imgui_draw_rect_filled / imgui_draw_line（lab 包装）  |
//   | `imgui.BeginTable("##scopes", 3, .SizingFixedFit)`| imgui_begin_table / imgui_table_setup_column          |
//   | `imgui.TableSetupColumn("scope", {.WidthStretch})` | imgui_table_setup_column（标签吃 string）             |
//   | `fmt.tprintf("%.0f FPS")` / `fmt.ctprintf(…)`     | `%` 不吃精度修饰 → 先 perf_round 再 tprint("%")        |
//   | `foster.Color{R,G,B,A}`                           | F.Color 字段是小写 r/g/b/a                             |
//   | `text_colored(text, color)` 走 cstring             | 同函数，文本当数据传（`"%s"` + 一个参数）               |
//
// 未使用 perf.init / perf.draw：那两条是 kit/ui + clay 的渲染路径，与本包互斥（Olover.initialized
// 与 ctx/renderer 都不碰）。宿主只调 perf.frame 采样，然后每帧调本包的 draw 或 draw_window。
//
// 导入由 module.jai 提供（Basic / ImGui / F / perf / lab_imgui 的 imgui_* 包装）。

//@region 常量

WINDOW :: "Perf##jalib_perf_overlay";
WINDOW_SIZE :: ImGui.ImVec2.{ 380, 340 };
MARGIN :: 12;           // 与视口工作区边缘的距离（逻辑像素，随 ImGui 缩放）
GRAPH_BAR_WIDTH :: 2;
GRAPH_HEIGHT :: 48;
BG_ALPHA :: 0.88;
FPS_FONT_SCALE :: 1.25; // olib 的 base * 1.25
//@endregion

//@region 界面缩放与数字格式

// olib 用 GetStyle().FontSizeBase 做基准（含 DPI 与界面缩放）；jacket 没有这个字段，
// 于是首帧把宿主当前字号记成基准，之后用比值当缩放。SetWindowFontScale 会改 GetFontSize，
// 所以基准必须在缩放之前取（draw / draw_window 的第一句就是 ui_scale）。
base_font_size: float32 = 0;

ui_scale :: () -> float32 {
    size := ImGui.GetFontSize();
    if base_font_size <= 0 base_font_size = size;
    if base_font_size <= 0 return 1;
    return size / base_font_size;
}

// Jai 的 `%` 不吃精度修饰（"%.2f" 会被当成字面量），所以先把数按位数 round 好再交给 tprint。
// 屏幕效果与 olib 的 %.0f / %.1f / %.2f 相同。
perf_round :: (value: float32, digits: int) -> float32 {
    scale: float32 = 1;
    for _: 0..digits - 1 scale *= 10;
    scaled := value * scale;
    // jacket 的 Math 没有 round：四舍五入用 floor(±x + 0.5)，负数对称。
    rounded := JM.floor(scaled + 0.5);
    if scaled < 0 rounded = -JM.floor(-scaled + 0.5);
    return rounded / scale;
}

// foster.Color 是 RGBA8，与 ImGui 的 IM_COL32 打包顺序（R 在最低字节）一致。
color_u32 :: (c: F.Color) -> ImGui.ImU32 {
    return cast(ImGui.ImU32) (cast(u32) c.r | (cast(u32) c.g << 8) |
                              (cast(u32) c.b << 16) | (cast(u32) c.a << 24));
}
//@endregion

//@region 绘制

// 在 ImGui 帧（宿主 BeginRender 与 EndRender 之间）调用；visible 为 false 时不提交窗口。
// 两种画法共用采样与内容：draw 是角落浮层，draw_window 是带标题栏的常规窗口（可拖动、可停靠）。
// 面板贴在主视口工作区的 o.corner 角，尺寸跟随 ImGui 的界面缩放。
draw :: (o: *perf.Overlay) {
    if !o.visible return;
    scale := ui_scale();
    viewport := ImGui.GetMainViewport();
    if viewport == null return;
    right := o.corner == .Top_Right || o.corner == .Bottom_Right;
    bottom := o.corner == .Bottom_Right || o.corner == .Bottom_Left;
    margin := MARGIN * scale;
    pos := ImGui.ImVec2.{ viewport.WorkPos.x, viewport.WorkPos.y };
    pivot := ImGui.ImVec2.{ 0, 0 };
    if right {
        pos.x += viewport.WorkSize.x - margin;
        pivot.x = 1; // 右对齐：窗口左上角 = 锚点 - 尺寸
    } else {
        pos.x += margin;
    }
    if bottom {
        pos.y += viewport.WorkSize.y - margin;
        pivot.y = 1;
    } else {
        pos.y += margin;
    }
    imgui_set_next_window_pos(pos, ImGui.Cond.Always, pivot);
    ImGui.SetNextWindowBgAlpha(BG_ALPHA);
    flags := ImGui.WindowFlags.NoDecoration | ImGui.WindowFlags.NoInputs |
             ImGui.WindowFlags.AlwaysAutoResize | ImGui.WindowFlags.NoSavedSettings |
             ImGui.WindowFlags.NoFocusOnAppearing | ImGui.WindowFlags.NoMove;
    if imgui_begin(WINDOW, null, flags) contents(o, scale);
    ImGui.End();
}

// 常规窗口：标题栏、可拖动，首次使用时的尺寸为 size，之后随宿主的 ImGui 布局保存。
// title 的显示文案可带 ### 后缀固定窗口身份；标题栏关闭按钮直接写 o.visible，
// 宿主若要同步自己的菜单勾选与偏好保存，比较调用前后的 o.visible 即可。
draw_window :: (o: *perf.Overlay, title: string, size := WINDOW_SIZE) {
    if !o.visible return;
    scale := ui_scale();
    imgui_set_next_window_size(size, ImGui.Cond.FirstUseEver);
    if imgui_begin(title, *o.visible) contents(o, scale);
    ImGui.End();
}

contents :: (o: *perf.Overlay, scale: float32) {
    s := o.summary;
    // olib 是 PushFontFloat(nil, base * 1.25)：这里放大整窗字号，画完立刻还原，
    // 后面的正文、曲线、表格仍是宿主的基础字号。
    ImGui.SetWindowFontScale(FPS_FONT_SCALE);
    text_colored(tprint("% FPS", perf_round(s.fps, 0)), perf.rating_color(s.avg_ms));
    ImGui.SetWindowFontScale(1);
    imgui_same_line();
    ImGui.TextUnformatted(tprint("% ms", perf_round(s.avg_ms, 2)));
    ImGui.PushStyleColor(ImGui.Col.Text, ImGui.GetColorU32(ImGui.Col.TextDisabled));
    ImGui.TextUnformatted(tprint("min %  max % ms  1% low % FPS",
                                  perf_round(s.min_ms, 1), perf_round(s.max_ms, 1),
                                  perf_round(s.low1_fps, 0)));
    ImGui.PopStyleColor();
    graph(o, scale);
    scopes(o);
}

text_colored :: (text: string, color: F.Color) {
    ImGui.PushStyleColor(ImGui.Col.Text, color_u32(color));
    ImGui.TextUnformatted(text);
    ImGui.PopStyleColor();
}
//@endregion

//@region 曲线与表格

// 与 kit/ui 版一致：最近 GRAPH_BARS 帧，最新在右；纵轴至少 33 ms，更长的帧出现时整体压缩；
// 细线为 60 FPS。
graph :: (o: *perf.Overlay, scale: float32) {
    bar_w := GRAPH_BAR_WIDTH * scale;
    size := ImGui.ImVec2.{ cast(float32) perf.GRAPH_BARS * bar_w, GRAPH_HEIGHT * scale };
    origin := ImGui.GetCursorScreenPos();
    imgui_dummy(size);
    list := ImGui.GetWindowDrawList();
    if list == null return;
    bottom := origin.y + size.y;
    imgui_draw_rect_filled(list, origin, ImGui.ImVec2.{ origin.x + size.x, bottom },
                           ImGui.ColorConvertFloat4ToU32(ImGui.ImVec4.{ 0, 0, 0, 0.35 }));
    bars := min(o.count, perf.GRAPH_BARS);
    top: float32 = 2 * perf.TARGET_MS;
    for i: 0..bars - 1 top = max(top, perf.history_at(o, i));
    if top <= 0 return;
    for i: 0..bars - 1 {
        ms := perf.history_at(o, i);
        x := origin.x + size.x - cast(float32) (i + 1) * bar_w;
        h := max(1.0, ms / top * size.y);
        imgui_draw_rect_filled(list, ImGui.ImVec2.{ x, bottom - h },
                               ImGui.ImVec2.{ x + bar_w, bottom }, color_u32(perf.rating_color(ms)));
    }
    y := bottom - perf.TARGET_MS / top * size.y;
    imgui_draw_line(list, ImGui.ImVec2.{ origin.x, y }, ImGui.ImVec2.{ origin.x + size.x, y },
                    ImGui.ColorConvertFloat4ToU32(ImGui.ImVec4.{ 1, 1, 1, 0.43 }),
                    max(1.0, scale));
}

scopes :: (o: *perf.Overlay) {
    if o.scope_count == 0 return;
    if !imgui_begin_table("##scopes", 3, ImGui.TableFlags.SizingFixedFit) return;
    defer imgui_end_table();
    imgui_table_setup_column("scope", ImGui.TableColumnFlags.WidthStretch);
    imgui_table_setup_column("ms/frame");
    imgui_table_setup_column("calls");
    ImGui.PushStyleColor(ImGui.Col.Text, ImGui.GetColorU32(ImGui.Col.TextDisabled));
    imgui_table_headers_row();
    ImGui.PopStyleColor();
    for row: array_view(o.scopes, 0, o.scope_count) {
        imgui_table_next_row();
        imgui_table_next_column();
        ImGui.TextUnformatted(row.name);
        imgui_table_next_column();
        right_aligned(tprint("%", perf_round(row.ms_per_frame, 2)));
        imgui_table_next_column();
        right_aligned(tprint("%", perf_round(row.calls_per_frame, 1)));
    }
}

right_aligned :: (text: string) {
    offset := ImGui.GetContentRegionAvail().x - ImGui.CalcTextSize(text).x;
    if offset > 0 ImGui.SetCursorPosX(ImGui.GetCursorPosX() + offset);
    ImGui.TextUnformatted(text);
}
//@endregion
