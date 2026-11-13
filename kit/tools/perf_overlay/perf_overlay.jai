// perf_overlay —— 悬浮性能面板：FPS、帧时间统计与曲线、core/profiler 作用域耗时。
//
// 宿主每帧调用 frame 记录帧时间，用自己的按键切换 visible，最后在所有 UI 之上调用 draw。
// 面板是被动浮层：不读取窗口输入、不捕获指针，也不影响宿主的输入分配。
// ImGui 画法见子包 perf_overlay/imgui；只用它时不调用 init，Overlay 零值即可采样。
//
// 一比一移植自 olib kit/tools/perf_overlay/perf_overlay.odin。Jai 差异（都是 jfoster / Jai /
// clay 0.12 绑定的形态问题，不改对外语义）：
//   | olib (Odin)                                | JaiLib (Jai)                                          |
//   | ------------------------------------------ | ----------------------------------------------------- |
//   | `foster.GraphicsDevice` / `MsdfFont`        | `*F.Graphics_Device` / `*F.Msdf_Font`（堆对象）          |
//   | `foster.Texture`（值 + .Resource）           | `*F.Texture`（句柄判据 .handle != 0）                   |
//   | `foster.DrawableTarget`                     | `F.Drawable_Target`                                    |
//   | `target.WidthInPixels`                      | F.drawable_target_width_in_pixels(target)              |
//   | `foster.Color{R,G,B,A}`                     | F.Color 字段是小写 r/g/b/a                              |
//   | `map[string]Scope_Previous`                 | HASH.Table(string, Scope_Previous)（table_find/set）    |
//   | `slice.clone` + `slice.sort`                | NewArray(temporary_allocator) + 本文件的插入排序         |
//   | `fmt.eprintln("Perf overlay:", reason)`     | print("%\n")（Jai 的 Basic 没有 stderr 版本）            |
//   | `clay.PaddingAll(n)` / `CornerRadiusAll(n)` | Padding 是结构体（CornerRadiusAll 仍在 clay 里）          |
//   | `clay.UI()(decl) { … }`                     | clay.UI(decl, #code { … })              |
//   | `decl.backgroundColor` / `.cornerRadius`    | decl.has_rect + decl.rect.{ color, cornerRadius }      |
//   | `decl.floating = { attachTo = .Root, … }`   | floating = { parentId = clay.ID(UI_ROOT_ID).id, … }   |
//   | `clay.ChildAlignment{x = .Right}`           | Jai 枚举是大写 `.RIGHT` / `.BOTTOM`                     |
//   | `ui_init(&ctx, w, h)`                       | ui_init(*ctx, w, h)                                   |
//   | `r2d.submit(&r, {target = t})`              | r2d.submit(*r, r2d.View.{ target = t })               |
// 导入由 module.jai 提供（HASH / JM / F / profiler / mat / r2d / ui / clay）。

//@region 数据

HISTORY :: 240;         // 统计窗口（帧）
GRAPH_BARS :: 120;      // 曲线显示最近的帧数
REFRESH_INTERVAL :: 0.5; // 数字与作用域表的刷新间隔（秒），避免逐帧跳动
MAX_SCOPES :: 8;

Corner :: enum {
    Top_Right;
    Top_Left;
    Bottom_Right;
    Bottom_Left;
}

Frame_Summary :: struct {
    fps, avg_ms, min_ms, max_ms: float32;
    low1_fps: float32; // 最慢 1% 帧的平均 FPS
    count: int;
}

Scope_Row :: struct {
    name: string;          // 借用 Overlay.previous 中复制的名字
    ms_per_frame, calls_per_frame: float32;
}

// 上次刷新时的累计值；name 复制自 profiler 的键，防止键字符串随热重载 DLL 卸载失效。
Scope_Previous :: struct {
    name: string;
    stat: profiler.Profile_Stat;
}

// 初始化后不得搬动（Render2D 与 UI_Context 要求地址稳定）。
Overlay :: struct {
    visible: bool;
    corner: Corner;
    history: [HISTORY] float32; // 毫秒，环形缓冲
    head, count: int;
    elapsed: float32;
    window_frames: int;
    summary: Frame_Summary;
    scopes: [MAX_SCOPES] Scope_Row;
    scope_count: int;
    previous: Table(string, Scope_Previous); // 键与 name 为同一份复制
    ctx: ui.UI_Context;
    materials: mat.Material_Library;
    renderer: r2d.Render2D; // 借用 materials
    theme: ui.UI_Theme;
    initialized: bool;
}
//@endregion

//@region 生命周期

// font / font_texture 借用至 dispose，须为真正的 MSDF 图集。
init :: (o: *Overlay, device: *F.Graphics_Device, font: *F.Msdf_Font, font_texture: *F.Texture) -> bool {
    if o.initialized || device == null || font == null return false;
    if !ui.ui_init(*o.ctx, 960, 720) return false;
    o.materials = mat.Material_Library.{ device = device };
    reason := r2d.init(*o.renderer, *o.materials);
    if reason != "" {
        print("Perf overlay: %\n", reason);
        ui.ui_dispose(*o.ctx);
        mat.material_library_dispose(*o.materials);
        return false;
    }
    o.theme = ui.UI_THEME_DARK;
    o.theme.body_font_id = cast(u16) ui.ui_register_font(*o.ctx, font, font_texture, .MSDF);
    o.initialized = true;
    return true;
}

dispose :: (o: *Overlay) {
    if o.initialized {
        ui.ui_dispose(*o.ctx);
        r2d.dispose(*o.renderer);
        mat.material_library_dispose(*o.materials);
    }
    for entry, _key: o.previous {
        if entry.name.data != null free(entry.name.data);
    }
    deinit(*o.previous);
    o.* = Overlay.{};
}
//@endregion

//@region 采样

// 每帧调用一次，隐藏时也要调用，打开面板时才有完整历史。
// delta_time 是整帧间隔（含垂直同步等待）；CPU 各阶段耗时用 profiler.profile_scope 标记。
frame :: (o: *Overlay, delta_time: float32) {
    dt := max(0.0, delta_time);
    o.history[o.head] = dt * 1000;
    o.head = (o.head + 1) % HISTORY;
    o.count = min(o.count + 1, HISTORY);
    o.window_frames += 1;
    o.elapsed += dt;
    if o.elapsed < REFRESH_INTERVAL && o.summary.count > 0 return;
    o.summary = summarize(array_view(o.history, 0, o.count));
    scopes_collect(o, profiler.profile_stats, o.window_frames);
    o.elapsed = 0;
    o.window_frames = 0;
}

// 帧时间（毫秒）汇总；顺序无关。
summarize :: (samples: [] float32) -> Frame_Summary {
    if samples.count == 0 return Frame_Summary.{};
    s := Frame_Summary.{ min_ms = samples[0], max_ms = samples[0], count = samples.count };
    total: float32 = 0;
    for ms: samples {
        total += ms;
        s.min_ms = min(s.min_ms, ms);
        s.max_ms = max(s.max_ms, ms);
    }
    s.avg_ms = total / cast(float32) samples.count;
    if s.avg_ms > 0 s.fps = 1000 / s.avg_ms;
    // olib 是 slice.clone(samples, context.temp_allocator) + slice.sort：这里同样只用 temp 存储。
    sorted := NewArray(samples.count, float32); // NewArray 分配在临时分配器上
    memcpy(sorted.data, samples.data, samples.count * size_of(float32));
    sort_floats_ascending(sorted);
    worst := max(1, sorted.count / 100);
    slow: float32 = 0;
    for ms: array_view(sorted, sorted.count - worst, worst) slow += ms;
    slow /= cast(float32) worst;
    if slow > 0 s.low1_fps = 1000 / slow;
    return s;
}

// 升序插入排序：≤ HISTORY 个元素，避免为一处排序引入额外的依赖。
sort_floats_ascending :: (values: [] float32) {
    for i: 1..values.count - 1 {
        v := values[i];
        j := i - 1;
        while j >= 0 && values[j] > v {
            values[j + 1] = values[j];
            j -= 1;
        }
        values[j + 1] = v;
    }
}

// 按上次刷新以来的增量统计每帧耗时与调用次数，按耗时降序保留前 MAX_SCOPES 项。
// profile_init 重建统计表导致计数回退时，从零重新计算。
scopes_collect :: (o: *Overlay, current: Table(string, profiler.Profile_Stat), frames: int) {
    o.scope_count = 0;
    if frames <= 0 return;
    // NewArray 返回的是定长切片 `[] T`（不是可增长的 `[..] T`），`array_add` 选不中重载；
    // 这里按 olib slice.clone 的等价做法预分配上限，再用 row_count 当写入游标。
    rows := NewArray(current.count, Scope_Row);
    row_count := 0;
    for stat, name: current {
        found, entry := table_find(*o.previous, name);
        if !found entry.name = copy_string(name);
        prev := entry.stat;
        if stat.count < prev.count prev = profiler.Profile_Stat.{};
        entry.stat = stat;
        table_set(*o.previous, entry.name, entry);
        calls := stat.count - prev.count;
        if calls <= 0 continue;
        row := Scope_Row.{
            name = entry.name,
            ms_per_frame = cast(float32) (stat.total - prev.total) / 1000000.0 / cast(float32) frames,
            calls_per_frame = cast(float32) calls / cast(float32) frames,
        };
        rows[row_count] = row;
        row_count += 1;
    }
    sort_scopes_descending(array_view(rows, 0, row_count));
    o.scope_count = min(row_count, MAX_SCOPES);
    for row, i: array_view(rows, 0, o.scope_count) o.scopes[i] = row;
}

// 按 ms_per_frame 降序；插入排序，行数 ≤ 作用域数（最多 MAX_SCOPES 进榜，但先整体排序）。
sort_scopes_descending :: (rows: [] Scope_Row) {
    for i: 1..rows.count - 1 {
        v := rows[i];
        j := i - 1;
        while j >= 0 && rows[j].ms_per_frame < v.ms_per_frame {
            rows[j + 1] = rows[j];
            j -= 1;
        }
        rows[j + 1] = v;
    }
}
//@endregion

//@region 绘制

GRAPH_BAR_WIDTH :: 2;
GRAPH_HEIGHT :: 48;
PANEL_PADDING :: 10;
PANEL_WIDTH :: GRAPH_BARS * GRAPH_BAR_WIDTH + PANEL_PADDING * 2;
TARGET_MS :: 1000.0 / 60;
PANEL_Z :: 1000;

// 在 target 上叠加面板；放在宿主所有 UI 之后调用。scale 与宿主 UI 比例一致，
// 面板在最终像素尺寸绘制，不随低分辨率场景放大。
draw :: (o: *Overlay, target: F.Drawable_Target, scale: float32 = 1) {
    if !o.initialized || !o.visible return;
    width := F.drawable_target_width_in_pixels(target);
    height := F.drawable_target_height_in_pixels(target);
    if width <= 0 || height <= 0 return;
    ui.ui_set_viewport(*o.ctx, F.Rect.{ x = 0, y = 0, w = cast(float32) width, h = cast(float32) height }, scale);
    ui.ui_set_pointer(*o.ctx, -10000, -10000, false);
    ui.ui_begin(*o.ctx, 0);
    panel_layout(o);
    ui.ui_draw(*o.ctx, *o.renderer);
    err := r2d.submit(*o.renderer, r2d.View.{ target = target });
    if err != .None print("Perf overlay: %\n", err);
}

// 在 ui_begin 与 ui_draw 之间声明面板。
panel_layout :: (o: *Overlay) {
    attach: clay.FloatingAttachPointType;
    offset: clay.Vector2;
    if o.corner == {
        case .Top_Right;    attach = .RIGHT_TOP;    offset = .[ -12, 12 ];
        case .Top_Left;     attach = .LEFT_TOP;     offset = .[ 12, 12 ];
        case .Bottom_Right; attach = .RIGHT_BOTTOM; offset = .[ -12, -12 ];
        case .Bottom_Left;  attach = .LEFT_BOTTOM;  offset = .[ 12, -12 ];
    }
    panel := ui.ui_column_decl(6);
    pad := cast(u16) PANEL_PADDING;
    panel.layout.padding = clay.Padding.{ left = pad, right = pad, top = pad, bottom = pad };
    panel.layout.sizing.width = clay.SizingFixed(cast(float) PANEL_WIDTH);
    // clay 0.14 没有 has_rect / has_floating 标志位：presence 由字段值决定
    // （backgroundColor 的 alpha > 0、floating.attachTo != .NONE）。
    panel.backgroundColor = ui.ui_clay_color(F.Color.{ 16, 18, 24, 225 });
    panel.cornerRadius = clay.CornerRadiusAll(6);
    panel.floating = .{
        attachTo = .ROOT, // olib: attachTo = .Root
        attachment = .{ element = attach, parent = attach },
        offset = offset,
        zIndex = PANEL_Z,
        pointerCaptureMode = .PASSTHROUGH,
    };
    ui.clay.UI(panel, #code { panel_contents(o); });
}

panel_contents :: (o: *Overlay) {
    s := o.summary;
    ui.clay.UI(ui.ui_row_decl(), #code {
        ui.ui_label_ex(*o.ctx, *o.theme, tprint("% FPS", s.fps), rating_color(s.avg_ms), 20);
        ui.ui_spacer();
        ui.ui_label_ex(*o.ctx, *o.theme, tprint("% ms", s.avg_ms), o.theme.text, 16);
    });
    ui.ui_label_dim(*o.ctx, *o.theme,
                    tprint("min %  max % ms  1\% low % FPS", s.min_ms, s.max_ms, s.low1_fps));
    graph(o);
    if o.scope_count == 0 return;
    ui.clay.UI(ui.ui_row_decl(4), #code {
        cell(o, "scope", 0, o.theme.text_dim);
        cell(o, "ms/frame", 64, o.theme.text_dim);
        cell(o, "calls", 44, o.theme.text_dim);
    });
    for row: array_view(o.scopes, 0, o.scope_count) {
        ui.clay.UI(ui.ui_row_decl(4), #code {
            cell(o, row.name, 0, o.theme.text);
            cell(o, tprint("%", row.ms_per_frame), 64, o.theme.text);
            cell(o, tprint("%", row.calls_per_frame), 44, o.theme.text_dim);
        });
    }
}

// 最近 GRAPH_BARS 帧，最新在右；纵轴至少 33 ms，出现更长的帧时整体压缩。细线为 60 FPS。
graph :: (o: *Overlay) {
    bars := min(o.count, GRAPH_BARS);
    top: float32 = 2 * TARGET_MS;
    for i: 0..bars - 1 top = max(top, history_at(o, i));
    ui.clay.UI(ui.clay.ElementDeclaration.{
        layout = .{
            sizing = .{ width = clay.SizingFixed(cast(float) (GRAPH_BARS * GRAPH_BAR_WIDTH)),
                        height = clay.SizingFixed(cast(float) GRAPH_HEIGHT) },
            childAlignment = .{ x = .RIGHT, y = .BOTTOM },
        },
        backgroundColor = ui.ui_clay_color(F.Color.{ 0, 0, 0, 90 }),
    }, #code { graph_bars(o, bars, top); });
}

graph_bars :: (o: *Overlay, bars: int, top: float32) {
    i := bars - 1;
    while i >= 0 {
        ms := history_at(o, i);
        ui.clay.UI(ui.clay.ElementDeclaration.{
            layout = .{ sizing = .{
                width = clay.SizingFixed(cast(float) GRAPH_BAR_WIDTH),
                height = clay.SizingFixed(max(1.0, ms / top * cast(float32) GRAPH_HEIGHT)),
            } },
            backgroundColor = ui.ui_clay_color(rating_color(ms)),
        });
        i -= 1;
    }
    ui.clay.UI(ui.clay.ElementDeclaration.{
        layout = .{ sizing = .{
            width = clay.SizingFixed(cast(float) (GRAPH_BARS * GRAPH_BAR_WIDTH)),
            height = clay.SizingFixed(1),
        } },
        backgroundColor = ui.ui_clay_color(F.Color.{ 255, 255, 255, 110 }),
        floating = .{
            attachment = .{ element = .LEFT_BOTTOM, parent = .LEFT_BOTTOM },
            offset = .[ 0, -TARGET_MS / top * cast(float32) GRAPH_HEIGHT ],
            zIndex = PANEL_Z + 1,
            pointerCaptureMode = .PASSTHROUGH,
        },
    });
}

// 第 age 帧之前的帧时间，0 为最新；age < count 时有效。
history_at :: (o: *Overlay, age: int) -> float32 {
    return o.history[(o.head - 1 - age + HISTORY * 2) % HISTORY];
}

// width=0 占满剩余宽度（左对齐、裁剪溢出）；否则固定宽度右对齐。
cell :: (o: *Overlay, text: string, width: float32, color: F.Color) {
    width_axis := clay.SizingGrow();
    align_x := clay.LayoutAlignmentX.LEFT;
    if width > 0 {
        width_axis = clay.SizingFixed(width);
        align_x = .RIGHT;
    }
    decl := ui.clay.ElementDeclaration.{
        layout = .{
            sizing = .{ width = width_axis },
            childAlignment = .{ x = align_x },
        },
        // olib 的 clip = {horizontal = width == 0}：0.14 的 ClipElementConfig 就是它本身，
        // horizontal/vertical 任一为真即挂上裁剪（没有 has_scroll / force_clip）。
        clip = .{ horizontal = width == 0 },
    };
    ui.clay.UI(decl, #code {
        ui.ui_label_ex(*o.ctx, *o.theme, text, color, o.theme.small_font_size + 1);
    });
}

// 按 60 FPS 预算着色：绿 ≤ 1 帧，黄 ≤ 2 帧，红更慢。
rating_color :: (ms: float32) -> F.Color {
    if ms <= TARGET_MS * 1.05 return F.Color.{ 96, 214, 120, 255 };
    if ms <= TARGET_MS * 2.05 return F.Color.{ 236, 196, 82, 255 };
    return F.Color.{ 236, 92, 84, 255 };
}
//@endregion
