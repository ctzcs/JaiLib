// kit/tools 回归测试 —— 覆盖 `kit/tools` 里纯 CPU 可达的部分（调色板颜色换算、路径助手、
// 程序化几何、命名/格式映射、perf_overlay 的帧时间统计与作用域增量、tween_preview 的纯函数）。
//
// 组织方式与 olib 对位：每个用例对应一个过程，签名统一 `(state: *Test_State)`，用
// Tests/test_support.jai 的 expect / test_summary（由 runner 调度），本文件不写 main。
//
// 参照源：`olib/tests/kit/tools/*.odin`（1,361 行）。其中可直接对位的只有
//   perf_overlay/perf_overlay_test.odin → summarize_frame_times / scopes_report_deltas /
//                                    scopes_keep_slowest（GPU 布局用例见下"不移植"）
// 其余参照用例（scene_notes、tween_preview 的 Session 夹具、material_files 的临时目录读写）
// 属于文件/GPU/夹具密集的路径，不在本批范围；tween_preview 只移植纯函数部分。
//
// olib 完全没有覆盖、本文件新增的用例（olib 侧没有对应 @(test)）：
//   color_hsv_to_rgb / color_rgb_to_hsv / color_normalize / color_rgba / color_presets_init
//   sl_is_absolute / sl_relative_path / sl_replace_first
//   make_cube / make_sphere / display_name / shader_target_format
//   tween_preview: status_message / make_id / valid_id / id_text / target_id_* / target_step
//
// Jai 侧差异（断言语义不变）：
//   | olib (Odin)                                   | 这里 (Jai)                                            |
//   | --------------------------------------------- | ----------------------------------------------------- |
//   | testing.expect_value(t, a, b)                 | expect(state, a == b, "说明 %", a)                     |
//   | testing.expectf(t, cond, fmt, args)           | expect(state, cond, "fmt", args)                       |
//   | `[3]f32{a,b,c}`                               | `.[a, b, c]`（有期望类型时用字面量）                     |
//   | 数组算术 / 三元 / switch                        | 显式分量运算（to_v3_*）/ if-else 链                     |
//   | `max(1, n)`（int）                             | 保留 int 版；浮点必须写 `max(1.0, x)`                    |
//   | `map[string]Profile_Stat`                      | HASH.Table(string, profiler.Profile_Stat)              |
//   | `time.Duration` 纳秒                            | profiler.Duration = s64（同为纳秒）                     |
//
// 不移植的参照用例（原因）：
//   - perf_overlay `layout_builds_without_errors`：需要 kit/ui + MSDF 字体 + ui_translate，
//     属于 UI 布局链路，没有 GPU 也无法给出有意义断言（olib 自己也只是数 quad）。
//   - `frame_refreshes_on_interval`：需要 Overlay.frame → scopes_collect 读全局
//     profiler.profile_stats，会把宿主进程的统计表写进被测对象；且断言依赖
//     history 环形缓冲的跨帧状态，不属于"纯 CPU 可测"。summarize / scopes_collect 直接测。
//   - tween_preview 的 Session 夹具用例（open/seek/update/书签）需要 Cases 回调夹具，
//     不在本批范围；纯函数（status_message / make_id / valid_id / id_text / target_step）已覆盖。
//
// 具名导入一律带 TO_ 前缀：本文件将来会被 run_kit_tests 与其它 kit 测试聚合到同一模块，
// 裸的 F / M / W / SL 之类会和 audio_test（F、M）、world_test（W）重名。
#import "Basic";
TO_SL :: #import "kit/tools/shader_lab";
TO_PO :: #import "kit/tools/perf_overlay";
TO_TP :: #import "kit/tools/tween_preview";
TO_SH :: #import "kit/rendering/shader";
TO_DA :: #import "core/dasset";
TO_F :: #import "foster";
TO_PROF :: #import "core/profiler";
TO_HASH :: #import "Hash_Table";
TO_M :: #import "Math";
TO_STRING :: #import "String";
#import "test_support";

//@region 断言小工具（聚合进 run_kit_tests 后不会重名）

TO_EPS :: 0.0001; // float32 往返容差：远大于单精度舍入误差，远小于断言语义需要的精度

to_near :: (a: float32, b: float32, eps := TO_EPS) -> bool {
    d := a - b;
    if d < 0 d = -d;
    return d <= eps;
}

to_near3 :: (a: [3] float32, b: [3] float32, eps := TO_EPS) -> bool {
    return to_near(a[0], b[0], eps) && to_near(a[1], b[1], eps) && to_near(a[2], b[2], eps);
}

// Jai 的 print 不展开定长数组，消息里手工拼成 (x, y, z)。
to_v3_text :: (a: [3] float32) -> string {
    return tprint("(%, %, %)", a[0], a[1], a[2]);
}

to_v3_sub :: (a: [3] float32, b: [3] float32) -> [3] float32 {
    return .[a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

to_v3_dot :: (a: [3] float32, b: [3] float32) -> float32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

to_v3_cross :: (a: [3] float32, b: [3] float32) -> [3] float32 {
    return .[a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
}

to_v3_len :: (a: [3] float32) -> float32 {
    return TO_M.sqrt(to_v3_dot(a, a));
}

to_in_unit :: (v: float32) -> bool {
    return v >= 0.0 && v <= 1.0;
}

// 三角形从外侧看是 CCW：cross(p1-p0, p2-p0) 与法线同向。退化（面积为 0）返回 true 并由
// 调用方决定是否跳过；这里用面积阈值区分"退化"与"反向"。
to_triangle_ccw :: (p0: [3] float32, p1: [3] float32, p2: [3] float32, n: [3] float32,
degenerate: *bool) -> bool {
    c := to_v3_cross(to_v3_sub(p1, p0), to_v3_sub(p2, p0));
    degenerate.* = to_v3_len(c) < 0.000001;
    return to_v3_dot(c, n) > 0.0;
}

// 三个分量的最小/最大值（Jai 的 min/max 只有两参数版）。
to_v3_min :: (a: [3] float32) -> float32 {
    m := a[0];
    if a[1] < m m = a[1];
    if a[2] < m m = a[2];
    return m;
}

to_v3_max :: (a: [3] float32) -> float32 {
    m := a[0];
    if a[1] > m m = a[1];
    if a[2] > m m = a[2];
    return m;
}

// sl_replace_first / copy_string 的返回值是自有内存（不是借用的字面量）。
to_release :: (s: string) {
    if s.data != null free(s.data);
}
//@endregion

//@region 调色板颜色换算（shader_lab/color_picker.jai）

// hue 以"圈"为单位（0..1），不是角度：h=1/6 黄、1/3 绿、1/2 青、2/3 蓝、5/6 品红。
color_hsv_to_rgb_sectors_and_boundaries :: (state: *Test_State) {
    sixth: float32 = 1.0 / 6.0;
    third: float32 = 1.0 / 3.0;
    half: float32 = 0.5;
    two_thirds: float32 = 2.0 / 3.0;
    five_sixths: float32 = 5.0 / 6.0;

    // 六个扇区各命中一条 if 分支。
    red := TO_SL.color_hsv_to_rgb(.[0.0, 1.0, 1.0]);
    expect(state, to_near3(red, .[1, 0, 0]), "h=0 应为纯红 %", to_v3_text(red));
    yellow := TO_SL.color_hsv_to_rgb(.[sixth, 1.0, 1.0]);
    expect(state, to_near3(yellow, .[1, 1, 0]), "h=1/6 应为黄 %", to_v3_text(yellow));
    green := TO_SL.color_hsv_to_rgb(.[third, 1.0, 1.0]);
    expect(state, to_near3(green, .[0, 1, 0]), "h=1/3 应为绿 %", to_v3_text(green));
    cyan := TO_SL.color_hsv_to_rgb(.[half, 1.0, 1.0]);
    expect(state, to_near3(cyan, .[0, 1, 1]), "h=1/2 应为青 %", to_v3_text(cyan));
    blue := TO_SL.color_hsv_to_rgb(.[two_thirds, 1.0, 1.0]);
    expect(state, to_near3(blue, .[0, 0, 1]), "h=2/3 应为蓝 %", to_v3_text(blue));
    magenta := TO_SL.color_hsv_to_rgb(.[five_sixths, 1.0, 1.0]);
    expect(state, to_near3(magenta, .[1, 0, 1]), "h=5/6 应为品红 %", to_v3_text(magenta));

    // 灰色阶：s=0 时三个分量都等于 v（色相不影响）。
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[0.37, 0.0, 0.5]), .[0.5, 0.5, 0.5]),
    "s=0 中间亮度应为灰");
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[0.81, 0.0, 1.0]), .[1, 1, 1]),
    "s=0 v=1 应为白");
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[0.0, 0.0, 0.0]), .[0, 0, 0]),
    "v=0 应为黑（不管 s）");
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[0.5, 1.0, 0.0]), .[0, 0, 0]),
    "v=0 应为黑（饱和色也一样）");

    // 半饱和：c = v*s = 0.4、m = v-c = 0.4、h=1/3 → (m, m+c, m) = (0.4, 0.8, 0.4)。
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[third, 0.5, 0.8]), .[0.4, 0.8, 0.4]),
    "h=1/3 s=0.5 v=0.8 应得到 (0.4, 0.8, 0.4)");

    // 色相环绕：h 先取小数部分（(h - floor(h)) * 6），因此 1.0 / 2.0 / 3.0 都等价于 0，
    // 负色相 -0.5 等价于 0.5（青）。
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[1.0, 1.0, 1.0]), red), "h=1 应环绕到 h=0（红）");
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[3.0, 1.0, 1.0]), red), "h=3 应环绕到 h=0（红）");
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[-0.5, 1.0, 1.0]), cyan), "h=-0.5 应环绕到 h=0.5（青）");
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[2.0 / 3.0 + 1.0, 1.0, 1.0]), blue),
    "h=2/3+1 圈应仍是蓝");
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[5.0 / 6.0 - 1.0, 1.0, 1.0]), magenta),
    "h=5/6-1 圈应仍是品红");

    // 扇区边界（h*6 恰好是整数）两侧必须连续：h=1/6 的 x 由 c 退化成 0，两端都是黄。
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[sixth, 1.0, 1.0]),
    TO_SL.color_hsv_to_rgb(.[sixth - 0.00001, 1.0, 1.0])), "h=1/6 两侧应连续（左）");
    expect(state, to_near3(TO_SL.color_hsv_to_rgb(.[sixth, 1.0, 1.0]),
    TO_SL.color_hsv_to_rgb(.[sixth + 0.00001, 1.0, 1.0])), "h=1/6 两侧应连续（右）");

    // 24×5×5 网格：所有分量落在 [0,1]，且 max = v、min = v*(1-s)（HSV 的定义性质）。
    gamut_ok := true;
    extremes_ok := true;
    for hi: 0..23 {
        for si: 0..4 {
            for vi: 0..4 {
                h := cast(float32) hi / 24.0;
                s := cast(float32) si / 4.0;
                v := cast(float32) vi / 4.0;
                rgb := TO_SL.color_hsv_to_rgb(.[h, s, v]);
                if !to_in_unit(rgb[0]) || !to_in_unit(rgb[1]) || !to_in_unit(rgb[2]) gamut_ok = false;
                if !to_near(to_v3_max(rgb), v) extremes_ok = false;
                if !to_near(to_v3_min(rgb), v * (1.0 - s)) extremes_ok = false;
            }
        }
    }
    expect(state, gamut_ok, "24×5×5 的 HSV 网格应全部落在 [0,1]");
    expect(state, extremes_ok, "24×5×5 的 HSV 网格应满足 max=v、min=v*(1-s)");
}

color_rgb_to_hsv_primaries_and_edges :: (state: *Test_State) {
    third: float32 = 1.0 / 3.0;
    two_thirds: float32 = 2.0 / 3.0;

    // 三个主色分别命中 hi==r / hi==g / hi==b 三条分支。
    r := TO_SL.color_rgb_to_hsv(.[1.0, 0.0, 0.0]);
    expect(state, to_near(r[0], 0.0) && to_near(r[1], 1.0) && to_near(r[2], 1.0),
    "红应为 (0, 1, 1) 得到 %", to_v3_text(r));
    g := TO_SL.color_rgb_to_hsv(.[0.0, 1.0, 0.0]);
    expect(state, to_near(g[0], third) && to_near(g[1], 1.0) && to_near(g[2], 1.0),
    "绿应为 (1/3, 1, 1) 得到 %", to_v3_text(g));
    b := TO_SL.color_rgb_to_hsv(.[0.0, 0.0, 1.0]);
    expect(state, to_near(b[0], two_thirds) && to_near(b[1], 1.0) && to_near(b[2], 1.0),
    "蓝应为 (2/3, 1, 1) 得到 %", to_v3_text(b));

    // 二次色。
    y := TO_SL.color_rgb_to_hsv(.[1.0, 1.0, 0.0]);
    expect(state, to_near(y[0], 1.0 / 6.0), "黄应为 h=1/6 得到 %", to_v3_text(y));
    c := TO_SL.color_rgb_to_hsv(.[0.0, 1.0, 1.0]);
    expect(state, to_near(c[0], 0.5), "青应为 h=1/2 得到 %", to_v3_text(c));
    m := TO_SL.color_rgb_to_hsv(.[1.0, 0.0, 1.0]);
    expect(state, to_near(m[0], 5.0 / 6.0), "品红应为 h=5/6 得到 %", to_v3_text(m));

    // 灰度 / 黑 / 白：delta=0 → h=0；hi=0 → s=0。
    gray := TO_SL.color_rgb_to_hsv(.[0.5, 0.5, 0.5]);
    expect(state, to_near3(gray, .[0, 0, 0.5]), "灰应为 (0, 0, 0.5) 得到 %", to_v3_text(gray));
    expect(state, to_near3(TO_SL.color_rgb_to_hsv(.[0, 0, 0]), .[0, 0, 0]), "黑应为 (0, 0, 0)");
    expect(state, to_near3(TO_SL.color_rgb_to_hsv(.[1, 1, 1]), .[0, 0, 1]), "白应为 (0, 0, 1)");

    // 负色相回绕：hi==r 且 b>g 时 (g-b)/delta 为负，必须 +1 回到 [0,1)。
    wrapped := TO_SL.color_rgb_to_hsv(.[1.0, 0.0, 0.5]);
    expect(state, to_near(wrapped[0], 11.0 / 12.0), "r 通道色相为负时应回绕到 11/12，得到 %", to_v3_text(wrapped));

    // hi==g 且 b<r（(b-r) 为负，但不回绕）与 hi==b 但 g>r 的分支。
    // (0.2, 1, 0)：h = 2 + (b-r)/delta = 1.8 → /6 = 0.3。
    g_branch := TO_SL.color_rgb_to_hsv(.[0.2, 1.0, 0.0]);
    expect(state, to_near(g_branch[0], 0.3), "hi==g 且 b<r 应为 h=0.3，得到 %", to_v3_text(g_branch));
    b_branch := TO_SL.color_rgb_to_hsv(.[0.0, 0.25, 1.0]);
    expect(state, to_near(b_branch[0], 0.625), "hi==b 且 g>r 应为 h=0.625，得到 %", to_v3_text(b_branch));

    // 任意输入：三个分量都落在合法区间，且 v 恒等于最大分量、s 恒等于 delta/hi。
    ranges_ok := true;
    for ri: 0..4 {
        for gi: 0..4 {
            for bi: 0..4 {
                rgb: [3] float32 = .[cast(float32) ri / 4.0, cast(float32) gi / 4.0, cast(float32) bi / 4.0];
                hsv := TO_SL.color_rgb_to_hsv(rgb);
                if !to_in_unit(hsv[0]) || !to_in_unit(hsv[1]) || !to_in_unit(hsv[2]) ranges_ok = false;
                if !to_near(hsv[2], to_v3_max(rgb)) ranges_ok = false;
                if to_v3_max(rgb) > 0.0 {
                    delta := to_v3_max(rgb) - to_v3_min(rgb);
                    if !to_near(hsv[1], delta / to_v3_max(rgb)) ranges_ok = false;
                }
            }
        }
    }
    expect(state, ranges_ok, "5×5×5 的 RGB 网格应给出 h/s/v ∈ [0,1] 且 v=max、s=delta/max");
}

// HSV → RGB → HSV 必须闭合（v>0；v=0 时色相无定义）。
color_hsv_rgb_roundtrip :: (state: *Test_State) {
    hue_ok := true;
    sat_ok := true;
    val_ok := true;
    again_ok := true;
    for hi: 0..11 {
        for si: 0..3 {
            for vi: 1..4 {
                h := cast(float32) hi / 12.0;
                s := cast(float32) si / 3.0;
                v := cast(float32) vi / 4.0;
                rgb := TO_SL.color_hsv_to_rgb(.[h, s, v]);
                back := TO_SL.color_rgb_to_hsv(rgb);
                if !to_near(back[2], v, 0.0002) val_ok = false;
                if s > 0.0 {
                    if !to_near(back[1], s, 0.0002) sat_ok = false;
                    if !to_near(back[0], h, 0.0005) hue_ok = false;
                }
                // 再正向转一次必须逐分量一致（往返不漂移）。
                if !to_near3(TO_SL.color_hsv_to_rgb(back), rgb, 0.0005) again_ok = false;
            }
        }
    }
    expect(state, val_ok, "往返应保持亮度 v（12×4×4 网格）");
    expect(state, sat_ok, "s>0 时往返应保持饱和度 s");
    expect(state, hue_ok, "s>0 时往返应保持色相 h");
    expect(state, again_ok, "HSV → RGB → HSV → RGB 应与第一次的 RGB 一致");

    // 灰阶：色相与饱和度归零，亮度原样保留（s=0 是色相的奇点）。
    for vi: 0..4 {
        v := cast(float32) vi / 4.0;
        back := TO_SL.color_rgb_to_hsv(TO_SL.color_hsv_to_rgb(.[0.37, 0.0, v]));
        expect(state, to_near(back[0], 0.0) && to_near(back[1], 0.0) && to_near(back[2], v),
        "s=0 往返应得到 (0, 0, %) 得到 %", v, to_v3_text(back));
    }
}

color_normalize_maps_range_and_clamps :: (state: *Test_State) {
    // 0..1 是恒等（四个分量一起归一化，alpha 也不例外）。
    identity := TO_SL.color_normalize(.[0.0, 0.25, 0.5, 1.0], 0.0, 1.0);
    expect(state, to_near(identity[0], 0.0) && to_near(identity[1], 0.25) &&
    to_near(identity[2], 0.5) && to_near(identity[3], 1.0),
    "0..1 归一化应是恒等，得到 (%, %, %, %)", identity[0], identity[1], identity[2], identity[3]);

    // 偏移区间：minimum..maximum 线性映射到 0..1。
    offset := TO_SL.color_normalize(.[10.0, 12.5, 15.0, 20.0], 10.0, 20.0);
    expect(state, to_near(offset[0], 0.0) && to_near(offset[1], 0.25) &&
    to_near(offset[2], 0.5) && to_near(offset[3], 1.0),
    "10..20 应线性映射到 0..1，得到 (%, %, %, %)", offset[0], offset[1], offset[2], offset[3]);

    // 越界值钳到 0/1（ColorPicker4 只接受归一化值）。
    clamped := TO_SL.color_normalize(.[-5.0, 10.0, 30.0, 100.0], 10.0, 20.0);
    expect(state, to_near(clamped[0], 0.0) && to_near(clamped[1], 0.0) &&
    to_near(clamped[2], 1.0) && to_near(clamped[3], 1.0),
    "越界值应钳到 [0,1]，得到 (%, %, %, %)", clamped[0], clamped[1], clamped[2], clamped[3]);

    // 零区间：span 下限 1e-5，所以恰好等于 minimum 的分量为 0，比它大的直接到 1。
    zero_span := TO_SL.color_normalize(.[0.5, 0.5, 0.5, 0.5], 0.5, 0.5);
    expect(state, to_near(zero_span[0], 0.0) && to_near(zero_span[3], 0.0),
    "minimum == maximum 时等于 minimum 的分量应为 0");
    above := TO_SL.color_normalize(.[0.5001, 0.5001, 0.5001, 0.5001], 0.5, 0.5);
    expect(state, to_near(above[0], 1.0) && to_near(above[3], 1.0),
    "零区间里略大于 minimum 的值应到 1（span 被钳到 1e-5），得到 %", above[0]);

    // 反转区间（maximum < minimum）：span 仍取 1e-5，于是所有 ≤ minimum 的分量都变成 0、
    // 高于 minimum 的直接到 1。这是 span 防除零钳位的直接结果（schema 校验保证 min <= max，
    // 生产路径不会走到），记录成断言以固定既有行为。
    inverted := TO_SL.color_normalize(.[0.0, 0.5, 1.0, 2.0], 1.0, 0.0);
    expect(state, to_near(inverted[0], 0.0) && to_near(inverted[1], 0.0) &&
    to_near(inverted[2], 0.0) && to_near(inverted[3], 1.0),
    "反转区间时 ≤ minimum 的分量为 0、更高的为 1（span 被钳到 1e-5），得到 (%, %, %, %)",
    inverted[0], inverted[1], inverted[2], inverted[3]);
}

// 同一文件里的另两个纯函数（不是任务清单的必测项，但同属调色板语义，顺手钉住）。
color_rgba_and_presets_stay_in_gamut :: (state: *Test_State) {
    // 0.5*255+0.5 = 128（四色五入到 128，不是 127）；1.0*255+0.5 = 255.5 截断到 255。
    half := TO_SL.color_rgba(.[0.5, 1.0, 0.0, 0.5]);
    expect(state, half.r == 128 && half.g == 255 && half.b == 0 && half.a == 128,
    "color_rgba(0.5, 1, 0, 0.5) 应为 (128, 255, 0, 128)，得到 (%, %, %, %)",
    half.r, half.g, half.b, half.a);
    // 先 clamp 再乘，越界输入不会绕回。
    out_of_range := TO_SL.color_rgba(.[-1.0, 2.0, 0.5, 0.5]);
    expect(state, out_of_range.r == 0 && out_of_range.g == 255 && out_of_range.b == 128,
    "越界输入应先 clamp 再转换，得到 (%, %, %, %)", out_of_range.r, out_of_range.g,
    out_of_range.b, out_of_range.a);

    presets := TO_SL.color_presets_init();
    in_gamut := true;
    for p: presets {
        for i: 0..2 if !to_in_unit(p[i]) in_gamut = false;
    }
    expect(state, in_gamut, "8 个预设色应全部落在 [0,1]");
    expect(state, to_near3(presets[0], .[1, 1, 1]), "预设 0 应为白");
    expect(state, to_near3(presets[1], .[0, 0, 0]), "预设 1 应为黑");
}
//@endregion

//@region 路径助手（shader_lab/files.jai、shader_lab/material_files.jai）

sl_is_absolute_drive_and_leading_separators :: (state: *Test_State) {
    expect(state, TO_SL.sl_is_absolute("C:/Users/a.png"), "盘符 + 正斜杠应是绝对路径");
    expect(state, TO_SL.sl_is_absolute("c:\\a"), "小写盘符 + 反斜杠应是绝对路径");
    expect(state, TO_SL.sl_is_absolute("/usr/local"), "POSIX 绝对路径");
    expect(state, TO_SL.sl_is_absolute("\\a"), "单个前导反斜杠也是绝对路径");
    expect(state, TO_SL.sl_is_absolute("C:x.png"), "盘符相对（C:x）按 filepath.is_abs 语义算绝对");

    expect(state, !TO_SL.sl_is_absolute(""), "空串不是绝对路径");
    expect(state, !TO_SL.sl_is_absolute("a/b.png"), "相对路径不是绝对路径");
    expect(state, !TO_SL.sl_is_absolute("C"), "单个字母不是盘符（长度 < 2）");
    expect(state, !TO_SL.sl_is_absolute("1:/a"), "数字前缀不算盘符");
    expect(state, !TO_SL.sl_is_absolute("./a.png"), "当前目录标记不是绝对路径");
    expect(state, !TO_SL.sl_is_absolute(".:/a"), "点号不算盘符");
}

sl_relative_path_shares_prefix_and_rejects_cousins :: (state: *Test_State) {
    rel, ok := TO_SL.sl_relative_path("a/b", "a/b/c.png");
    expect(state, ok && rel == "c.png", "同一目录下应得到相对文件名，得到 % / %", rel, ok);

    rel, ok = TO_SL.sl_relative_path("C:\\proj\\assets", "C:/proj/assets/tex/a.png");
    expect(state, ok && rel == "tex/a.png", "混用分隔符也应识别前缀，得到 % / %", rel, ok);

    rel, ok = TO_SL.sl_relative_path("a/b", "a/b\\c.png");
    expect(state, ok && rel == "c.png", "目标用反斜杠分隔时应得到 % / %", rel, ok);

    // 前缀相同但边界不是分隔符：是"表兄弟目录"，不能当成子路径。
    rel, ok = TO_SL.sl_relative_path("a/b", "a/bc.png");
    expect(state, !ok && rel == "a/bc.png", "边界不是分隔符时应失败并原样返回目标，得到 % / %", rel, ok);

    rel, ok = TO_SL.sl_relative_path("a/b", "a/c.png");
    expect(state, !ok && rel == "a/c.png", "不同目录应失败并原样返回目标，得到 % / %", rel, ok);

    rel, ok = TO_SL.sl_relative_path("a/b/c", "a/b");
    expect(state, !ok, "目标比目录短应失败，得到 % / %", rel, ok);

    rel, ok = TO_SL.sl_relative_path("a/b", "a/b");
    expect(state, !ok, "目标等于目录时没有相对部分，应失败，得到 % / %", rel, ok);

    rel, ok = TO_SL.sl_relative_path("", "a/b");
    expect(state, !ok, "空目录应失败，得到 % / %", rel, ok);

    // 目录带尾分隔符：逐字节比完后要求 target[directory.count] 是分隔符，这里拿到的是
    // 目标里的 'c'，于是失败。调用方传的是 sl_path_dir 的结果（不带尾分隔符），
    // 生产路径不会踩到；记录既有行为（见报告）。
    rel, ok = TO_SL.sl_relative_path("a/b/", "a/b/c.png");
    expect(state, !ok, "目录带尾分隔符时当前实现返回失败（既有行为）");

    // 成功时返回的是 target 的切片（借用，不分配）。
    borrowed, found := TO_SL.sl_relative_path("dir", "dir/file.json");
    expect(state, found && borrowed == "file.json", "相对路径应只剥掉目录前缀，得到 %", borrowed);
    expect(state, borrowed.data == "dir/file.json".data + 4, "返回值应借用目标字符串，不复制");
}

sl_replace_first_only_touches_first_match :: (state: *Test_State) {
    text := "aXbXc";

    first := TO_SL.sl_replace_first(text, "X", "Y");
    expect(state, first == "aYbXc", "只替换第一处，得到 %", first);
    expect(state, first.data != text.data, "返回值是自有内存，不借用入参");
    to_release(first);

    head := TO_SL.sl_replace_first(text, "a", "Z");
    expect(state, head == "ZXbXc", "命中开头时应替换开头，得到 %", head);
    to_release(head);

    tail := TO_SL.sl_replace_first(text, "c", "Z");
    expect(state, tail == "aXbXZ", "命中结尾时应替换结尾，得到 %", tail);
    to_release(tail);

    whole := TO_SL.sl_replace_first("X", "X", "Y");
    expect(state, whole == "Y", "整串命中时应得到替换串，得到 %", whole);
    to_release(whole);

    deletion := TO_SL.sl_replace_first(text, "X", "");
    expect(state, deletion == "abXc", "替换为空串等价于删除第一处，得到 %", deletion);
    to_release(deletion);

    longer := TO_SL.sl_replace_first("aXb", "X", "long-value");
    expect(state, longer == "along-valueb", "替换串更长时尾部应完整保留，得到 %", longer);
    to_release(longer);

    missing := TO_SL.sl_replace_first(text, "Q", "Y");
    expect(state, missing == "aXbXc", "找不到时应原样返回，得到 %", missing);
    expect(state, missing.data != text.data, "找不到时也返回自有副本（不借用入参）");
    to_release(missing);

    empty := TO_SL.sl_replace_first("", "X", "Y");
    expect(state, empty == "", "空文本应返回空串，得到 %", empty);
    to_release(empty);

    // 多字节 needle：按字节匹配，不按码点。
    wide := TO_SL.sl_replace_first("前置X后置X尾", "X", "-");
    expect(state, wide == "前置-后置X尾", "UTF-8 文本里也只在第一处替换，得到 %", wide);
    to_release(wide);
}
//@endregion

//@region 程序化几何（shader_lab/shapes.jai）

make_cube_counts_normals_uv_and_bounds :: (state: *Test_State) {
    material := TO_DA.Dasset_Material.{
        base_color_factor = .[0.5, 0.25, 0.125, 1.0],
        roughness = 0.25,
    };
    cube := TO_SL.make_cube(2.0, material);
    defer TO_SL.primitive_dispose(*cube);

    // 每面 4 个独立顶点（法线不共享）+ 每面 6 个索引。
    expect(state, cube.vertices.count == 24, "立方体应有 24 个顶点，得到 %", cube.vertices.count);
    expect(state, cube.indices.count == 36, "立方体应有 36 个索引，得到 %", cube.indices.count);
    expect(state, cube.skin_index == -1, "静态几何 skin_index = -1，得到 %", cube.skin_index);
    expect(state, cube.skin_vertices.count == 0, "静态几何不应带蒙皮顶点，得到 %", cube.skin_vertices.count);

    // 材质原样带出。
    expect(state, cube.material.roughness == 0.25, "材质 roughness 应原样带出，得到 %", cube.material.roughness);
    expect(state, cube.material.base_color_factor[0] == 0.5 && cube.material.base_color_factor[3] == 1.0,
    "材质 base_color_factor 应原样带出，得到 (%, %, %, %)",
    cube.material.base_color_factor[0], cube.material.base_color_factor[1],
    cube.material.base_color_factor[2], cube.material.base_color_factor[3]);

    // 包围盒 = ±size/2。
    expect(state, to_near3(cube.bounds.min, .[-1, -1, -1]) && to_near3(cube.bounds.max, .[1, 1, 1]),
    "size=2 的包围盒应为 ±1，得到 min=% max=%", to_v3_text(cube.bounds.min), to_v3_text(cube.bounds.max));

    // 逐顶点：位置在 ±0.5*size 盒内且贴面，法线是轴对齐单位向量，UV 是四角之一，
    // 切线是单位向量且 w=1（dasset 约定）。
    in_box := true;
    on_surface := true;
    normals_ok := true;
    uv_ok := true;
    tangent_ok := true;
    for v: cube.vertices {
        for axis: 0..2 {
            if v.position[axis] < -1.0 || v.position[axis] > 1.0 in_box = false;
        }
        // 贴面：|position| 的最大分量等于 h，且沿法线方向的投影等于 +h（法线朝外）。
        if !to_near(to_v3_max(.[TO_M.abs(v.position[0]), TO_M.abs(v.position[1]), TO_M.abs(v.position[2])]), 1.0) on_surface = false;
        if !to_near(to_v3_dot(v.position, v.normal), 1.0) on_surface = false;

        // 法线：单位长度 + 恰好一个分量是 ±1（其余为 0）。
        if !to_near(to_v3_len(v.normal), 1.0) normals_ok = false;
        nonzero := 0;
        for axis: 0..2 if TO_M.abs(v.normal[axis]) > 0.5 nonzero += 1;
        if nonzero != 1 normals_ok = false;

        // UV：每个分量非 0 即 1（每面铺满整张图）。
        if !to_near(v.uv[0], 0.0) && !to_near(v.uv[0], 1.0) uv_ok = false;
        if !to_near(v.uv[1], 0.0) && !to_near(v.uv[1], 1.0) uv_ok = false;

        if !to_near(v.tangent[3], 1.0) tangent_ok = false;
        if !to_near(to_v3_len(.[v.tangent[0], v.tangent[1], v.tangent[2]]), 1.0) tangent_ok = false;
    }
    expect(state, in_box, "所有顶点位置应在 ±size/2 内（±1）");
    expect(state, on_surface, "所有顶点应贴在立方体表面上（法线投影 = h）");
    expect(state, normals_ok, "所有法线应是轴对齐的单位向量");
    expect(state, uv_ok, "所有 UV 分量应非 0 即 1");
    expect(state, tangent_ok, "所有切线应是单位向量且 w=1");

    // 每面 4 个 UV 恰好覆盖四角：每分量求和 = 2（两个 0 两个 1）。
    uv_corners_ok := true;
    for f: 0..5 {
        sum_u: float32 = 0;
        sum_v: float32 = 0;
        for i: 0..3 {
            sum_u += cube.vertices[f * 4 + i].uv[0];
            sum_v += cube.vertices[f * 4 + i].uv[1];
        }
        if !to_near(sum_u, 2.0) || !to_near(sum_v, 2.0) uv_corners_ok = false;
    }
    expect(state, uv_corners_ok, "每个面的 4 个 UV 应覆盖 (0,0)(1,0)(1,1)(0,1) 四角");

    // 六个面各有一个方向不同的法线，且恰好覆盖 ±X / ±Y / ±Z。
    distinct := true;
    for a: 0..5 {
        for b: 0..5 {
            if b <= a continue;
            if to_near3(cube.vertices[a * 4].normal, cube.vertices[b * 4].normal) distinct = false;
        }
    }
    expect(state, distinct, "六个面的法线应互不相同");
    for axis: 0..2 {
        for sign: 0..1 {
            want: float32 = 1.0;
            if sign == 1 want = -1.0;
            found := false;
            for f: 0..5 {
                n := cube.vertices[f * 4].normal;
                if to_near(n[axis], want) && to_near(n[(axis + 1) % 3], 0.0) &&
                to_near(n[(axis + 2) % 3], 0.0) found = true;
            }
            expect(state, found, "应存在法线为轴 % 方向 % 的面", axis, sign);
        }
    }
}

make_cube_faces_are_ccw_and_indices_match_vertices :: (state: *Test_State) {
    cube := TO_SL.make_cube(1.0, TO_DA.DASSET_MATERIAL_DEFAULT);
    defer TO_SL.primitive_dispose(*cube);

    // size=1 → 顶点位置必须落在 ±0.5（单位立方体），包围盒同样是 ±0.5。
    expect(state, to_near3(cube.bounds.min, .[-0.5, -0.5, -0.5]) &&
    to_near3(cube.bounds.max, .[0.5, 0.5, 0.5]),
    "size=1 的包围盒应为 ±0.5，得到 min=% max=%",
    to_v3_text(cube.bounds.min), to_v3_text(cube.bounds.max));
    unit_box := true;
    for v: cube.vertices {
        for axis: 0..2 {
            if v.position[axis] < -0.5 || v.position[axis] > 0.5 unit_box = false;
        }
    }
    expect(state, unit_box, "size=1 时所有顶点位置应在 ±0.5 内（单位立方体）");

    // 索引全部落在 [0, 24)。
    indices_in_range := true;
    for i: cube.indices {
        if i >= cast(u32) cube.vertices.count indices_in_range = false;
    }
    expect(state, indices_in_range, "所有索引应小于顶点数 24");

    // 每面一块 4 顶点 / 6 索引，索引模式 0,1,2 / 0,2,3。
    pattern_ok := true;
    winding_ok := true;
    degenerate := 0;
    for f: 0..5 {
        base := f * 4;
        idx := f * 6;
        if cube.indices[idx + 0] != cast(u32) (base + 0) pattern_ok = false;
        if cube.indices[idx + 1] != cast(u32) (base + 1) pattern_ok = false;
        if cube.indices[idx + 2] != cast(u32) (base + 2) pattern_ok = false;
        if cube.indices[idx + 3] != cast(u32) (base + 0) pattern_ok = false;
        if cube.indices[idx + 4] != cast(u32) (base + 2) pattern_ok = false;
        if cube.indices[idx + 5] != cast(u32) (base + 3) pattern_ok = false;

        // 每面 4 个顶点共用同一法线（面法线不跨面共享）。
        n := cube.vertices[base].normal;
        for i: 1..3 {
            if !to_near3(cube.vertices[base + i].normal, n) pattern_ok = false;
        }

        // 两个三角形从外侧看都是 CCW（cross·n > 0）。
        for t: 0..1 {
            i0 := cube.indices[idx + t * 3 + 0];
            i1 := cube.indices[idx + t * 3 + 1];
            i2 := cube.indices[idx + t * 3 + 2];
            p0 := cube.vertices[i0].position;
            p1 := cube.vertices[i1].position;
            p2 := cube.vertices[i2].position;
            is_degenerate: bool;
            ok := to_triangle_ccw(p0, p1, p2, n, *is_degenerate);
            if is_degenerate degenerate += 1;
            if !ok winding_ok = false;
        }
    }
    expect(state, pattern_ok, "每面应是 4 顶点 + 索引模式 0,1,2/0,2,3，且 4 顶点共用面法线");
    expect(state, winding_ok, "12 个三角形从外侧看都应 CCW（cross·n > 0）");
    expect(state, degenerate == 0, "立方体不应有退化三角形，得到 %", degenerate);
}

make_sphere_mesh_counts_and_attributes :: (state: *Test_State) {
    rings := 8;
    segments := 12;
    radius: float32 = 1.15;
    sphere := TO_SL.make_sphere(radius, rings, segments, TO_DA.DASSET_MATERIAL_DEFAULT);
    defer TO_SL.primitive_dispose(*sphere);

    vertex_count := (rings + 1) * (segments + 1);
    index_count := rings * segments * 6;
    expect(state, sphere.vertices.count == vertex_count, "顶点数应为 (rings+1)*(segments+1)=%，得到 %",
    vertex_count, sphere.vertices.count);
    expect(state, sphere.indices.count == index_count, "索引数应为 rings*segments*6=%，得到 %",
    index_count, sphere.indices.count);
    expect(state, sphere.skin_index == -1, "静态几何 skin_index = -1，得到 %", sphere.skin_index);
    expect(state, to_near3(sphere.bounds.min, .[-radius, -radius, -radius]) &&
    to_near3(sphere.bounds.max, .[radius, radius, radius]),
    "包围盒应为 ±radius，得到 min=% max=%", to_v3_text(sphere.bounds.min), to_v3_text(sphere.bounds.max));

    // 索引全部落在 [0, 顶点数)。
    indices_in_range := true;
    for i: sphere.indices {
        if i >= cast(u32) sphere.vertices.count indices_in_range = false;
    }
    expect(state, indices_in_range, "所有索引应小于顶点数 %", sphere.vertices.count);

    // 逐顶点：法线单位长度、位置在半径上、位置与法线同向、UV 网格、切线单位且 w=1。
    normals_ok := true;
    on_sphere := true;
    uv_ok := true;
    tangent_ok := true;
    for ring: 0..rings {
        for seg: 0..segments {
            v := sphere.vertices[ring * (segments + 1) + seg];
            if !to_near(to_v3_len(v.normal), 1.0, 0.00001) normals_ok = false;
            if !to_near(to_v3_len(v.position), radius, 0.0001) on_sphere = false;
            // 位置 = 法线 * radius（同向），点积应为 radius。
            if !to_near(to_v3_dot(v.position, v.normal), radius, 0.0001) on_sphere = false;
            want_u := cast(float32) seg / cast(float32) segments;
            want_v := cast(float32) ring / cast(float32) rings;
            if !to_near(v.uv[0], want_u) || !to_near(v.uv[1], want_v) uv_ok = false;
            if !to_in_unit(v.uv[0]) || !to_in_unit(v.uv[1]) uv_ok = false;
            if !to_near(v.tangent[3], 1.0) tangent_ok = false;
            if !to_near(to_v3_len(.[v.tangent[0], v.tangent[1], v.tangent[2]]), 1.0) tangent_ok = false;
        }
    }
    expect(state, normals_ok, "所有法线应是单位长度");
    expect(state, on_sphere, "所有顶点位置应在半径 % 上且与法线同向", radius);
    expect(state, uv_ok, "UV 应是 seg/segments × ring/rings 的规则网格");
    expect(state, tangent_ok, "所有切线应是单位向量且 w=1");

    // 两极：ring=0 是北极（+Y），ring=rings 是南极（-Y），所有经线共点。
    pole_ok := true;
    for seg: 0..segments {
        north := sphere.vertices[0 * (segments + 1) + seg];
        if !to_near(north.normal[1], 1.0) || !to_near(north.position[1], radius) pole_ok = false;
        south := sphere.vertices[rings * (segments + 1) + seg];
        if !to_near(south.normal[1], -1.0) || !to_near(south.position[1], -radius) pole_ok = false;
    }
    expect(state, pole_ok, "ring=0 应是 +Y 极点、ring=rings 应是 -Y 极点");

    // 三角形绕序：除极点附近的退化三角形外，从外侧看都应 CCW。
    winding_ok := true;
    degenerate := 0;
    for t: 0..(index_count / 3) - 1 {
        i0 := sphere.indices[t * 3 + 0];
        i1 := sphere.indices[t * 3 + 1];
        i2 := sphere.indices[t * 3 + 2];
        p0 := sphere.vertices[i0].position;
        p1 := sphere.vertices[i1].position;
        p2 := sphere.vertices[i2].position;
        is_degenerate: bool;
        ok := to_triangle_ccw(p0, p1, p2, sphere.vertices[i0].normal, *is_degenerate);
        if is_degenerate {
            degenerate += 1;
            continue;
        }
        if !ok winding_ok = false;
    }
    expect(state, winding_ok, "非退化的球面三角形应全部 CCW");
    // 两个极环（ring 0→1 与 ring rings-1→rings）各 segments 个三角形退化成点。
    expect(state, degenerate == segments * 2, "应恰有 % 个极点退化三角形，得到 %", segments * 2, degenerate);
}
//@endregion

//@region 命名与格式映射（shader_lab/shader_panel.jai、shader_runtime.jai）

display_name_prefers_label_falls_back_to_id :: (state: *Test_State) {
    expect(state, TO_SL.display_name("", "albedo_gain") == "albedo_gain", "空标签应退回字段 ID");
    expect(state, TO_SL.display_name("Gain", "albedo_gain") == "Gain", "非空标签应优先");
    expect(state, TO_SL.display_name("Gain", "") == "Gain", "ID 为空也应返回标签");
    expect(state, TO_SL.display_name("", "") == "", "两者皆空应返回空串");
    expect(state, TO_SL.display_name(" ", "id") == " ", "不裁剪空白：单个空格也算标签");

    label := "曝光量 Expose";
    expect(state, TO_SL.display_name(label, "expose") == label, "非 ASCII 标签应原样返回");
    // 只是借用：标签非空时不复制、不改写（面板每帧都会调用它）。
    picked := TO_SL.display_name(label, "expose");
    expect(state, picked.data == label.data && picked.count == label.count,
    "非空标签应直接借用入参内存（不复制）");
    fallback := TO_SL.display_name("", "expose");
    expect(state, fallback.data == "expose".data, "退回 ID 时同样借用入参内存");
}

shader_target_format_preserves_precision :: (state: *Test_State) {
    formats := TO_SH.Target_Format.[.Color, .Float16, .Float32];
    expected := TO_F.Texture_Format.[.COLOR, .R16G16B16A16_FLOAT, .R32G32B32A32_FLOAT];
    sizes := int.[4, 8, 16];
    for format, i: formats {
        got := TO_SL.shader_target_format(format);
        expect(state, got == expected[i], "Declared target precision must be preserved");
        expect(state, TO_F.texture_format_size(got) == sizes[i], "Target byte stride must match its channels");
        expect(state, TO_F.texture_format_is_color(got) && !TO_F.texture_format_is_depth_stencil(got), "HDR targets are color attachments");
    }
}
//@endregion

//@region perf_overlay 采样统计（perf_overlay/perf_overlay.jai）

// olib: summarize_frame_times
summarize_frame_times :: (state: *Test_State) {
    samples := NewArray(200, float32);
    for *ms: samples ms.* = 10.0;
    samples[7] = 40.0;
    samples[150] = 20.0;
    s := TO_PO.summarize(samples);
    expect(state, s.count == 200, "count 应等于样本数，得到 %", s.count);
    expect(state, to_near(s.min_ms, 10.0), "min 应为 10，得到 %", s.min_ms);
    expect(state, to_near(s.max_ms, 40.0), "max 应为 40，得到 %", s.max_ms);
    expect(state, to_near(s.avg_ms, 2040.0 / 200.0, 0.0001), "avg 应为 2040/200 = 10.2，得到 %", s.avg_ms);
    expect(state, to_near(s.fps, 1000.0 / 10.2, 0.001), "fps 应为 1000/avg，得到 %", s.fps);
    // 最慢 1%（2 帧）平均 30 ms。
    expect(state, to_near(s.low1_fps, 1000.0 / 30.0, 0.001), "low1_fps 应为 1000/30，得到 %", s.low1_fps);

    // 空样本：全零（面板据此判断"还没有数据"）。
    empty := TO_PO.summarize(.[]);
    expect(state, empty.count == 0 && empty.fps == 0.0 && empty.avg_ms == 0.0 &&
    empty.min_ms == 0.0 && empty.max_ms == 0.0 && empty.low1_fps == 0.0,
    "空样本应返回全零汇总，得到 count=%", empty.count);

    // 单个样本：min == max == avg，最慢 1% 至少取 1 帧（worst = max(1, count/100)）。
    one := TO_PO.summarize(.[16.0]);
    expect(state, one.count == 1 && to_near(one.min_ms, 16.0) && to_near(one.max_ms, 16.0) &&
    to_near(one.avg_ms, 16.0) && to_near(one.fps, 62.5, 0.001) && to_near(one.low1_fps, 62.5, 0.001),
    "单样本汇总应一致（fps = low1_fps = 1000/16）");

    // 全零帧时间：fps / low1_fps 保持 0（不做除零）。
    zeros := TO_PO.summarize(.[0.0, 0.0, 0.0]);
    expect(state, zeros.avg_ms == 0.0 && zeros.fps == 0.0 && zeros.low1_fps == 0.0,
    "全零帧时间不应产生除零（fps/low1_fps 仍为 0）");

    // 顺序无关：打乱顺序（最低 1% 靠排序找）必须得到同一份汇总。
    shuffled := NewArray(200, float32);
    for *ms, i: shuffled {
        // 简单的逆序/错位填充，不含随机数。
        j := (i * 37) % 200;
        if j == 7 {
            ms.* = 40.0;
        } else if j == 150 {
            ms.* = 20.0;
        } else {
            ms.* = 10.0;
        }
    }
    t := TO_PO.summarize(shuffled);
    expect(state, t.count == s.count && to_near(t.avg_ms, s.avg_ms, 0.0001) &&
    to_near(t.min_ms, s.min_ms) && to_near(t.max_ms, s.max_ms) &&
    to_near(t.low1_fps, s.low1_fps, 0.001),
    "样本顺序不应影响汇总（low1 靠内部排序取最慢 1\%）");
}

// olib: scopes_report_deltas
scopes_report_deltas :: (state: *Test_State) {
    o: TO_PO.Overlay;
    defer TO_PO.dispose(*o);

    stats: TO_HASH.Table(string, TO_PROF.Profile_Stat);
    defer TO_HASH.deinit(*stats);
    // total 是纳秒（profiler.Duration = s64，与 olib time.Duration 同）。
    TO_HASH.table_set(*stats, "update", TO_PROF.Profile_Stat.{ count = 10, total = 20000000 });
    TO_HASH.table_set(*stats, "render", TO_PROF.Profile_Stat.{ count = 10, total = 50000000 });
    TO_HASH.table_set(*stats, "idle", TO_PROF.Profile_Stat.{ count = 3, total = 1000000 });

    TO_PO.scopes_collect(*o, stats, 10);
    expect(state, o.scope_count == 3, "三个作用域都应进榜，得到 %", o.scope_count);
    // 按 ms_per_frame 降序：render 5 ms/帧 > update 2 ms/帧 > idle 0.1 ms/帧。
    expect(state, o.scopes[0].name == "render", "最慢的应是 render，得到 %", o.scopes[0].name);
    expect(state, to_near(o.scopes[0].ms_per_frame, 5.0), "render 应为 50ms/10 帧 = 5，得到 %",
    o.scopes[0].ms_per_frame);
    expect(state, to_near(o.scopes[0].calls_per_frame, 1.0), "render 每帧 1 次，得到 %",
    o.scopes[0].calls_per_frame);
    expect(state, o.scopes[1].name == "update", "第二慢应是 update，得到 %", o.scopes[1].name);
    expect(state, to_near(o.scopes[1].ms_per_frame, 2.0), "update 应为 20ms/10 帧 = 2，得到 %",
    o.scopes[1].ms_per_frame);
    expect(state, o.scopes[2].name == "idle", "最后应是 idle，得到 %", o.scopes[2].name);

    // 只统计增量：没有新调用的作用域不进榜（render / idle 的 count 未变）。
    TO_HASH.table_set(*stats, "update", TO_PROF.Profile_Stat.{ count = 30, total = 80000000 });
    TO_PO.scopes_collect(*o, stats, 20);
    expect(state, o.scope_count == 1, "只有 update 有新调用，得到 %", o.scope_count);
    expect(state, o.scopes[0].name == "update", "唯一入榜的应是 update，得到 %", o.scopes[0].name);
    // (80ms - 20ms) / 20 帧 = 3 ms/帧；(30 - 10) / 20 = 1 次/帧。
    expect(state, to_near(o.scopes[0].ms_per_frame, 3.0), "增量应为 60ms/20 帧 = 3，得到 %",
    o.scopes[0].ms_per_frame);
    expect(state, to_near(o.scopes[0].calls_per_frame, 1.0), "调用增量应为 20/20 = 1，得到 %",
    o.scopes[0].calls_per_frame);

    // 统计表被 profile_init 重建后 count 回退：按新值从零重算，不出现负增量。
    TO_HASH.table_set(*stats, "update", TO_PROF.Profile_Stat.{ count = 2, total = 4000000 });
    TO_PO.scopes_collect(*o, stats, 2);
    expect(state, o.scope_count == 1, "重建后仍只有 update 进榜，得到 %", o.scope_count);
    expect(state, to_near(o.scopes[0].ms_per_frame, 2.0), "计数回退后应按新值算 4ms/2 帧 = 2，得到 %",
    o.scopes[0].ms_per_frame);
    expect(state, to_near(o.scopes[0].calls_per_frame, 1.0), "计数回退后调用数应为 2/2 = 1，得到 %",
    o.scopes[0].calls_per_frame);

    // frames <= 0：清空榜单并直接返回（不会把上一轮的行留在面板上）。
    TO_PO.scopes_collect(*o, stats, 0);
    expect(state, o.scope_count == 0, "frames=0 应清空榜单，得到 %", o.scope_count);
    TO_PO.scopes_collect(*o, stats, -3);
    expect(state, o.scope_count == 0, "frames<0 应清空榜单，得到 %", o.scope_count);
}

// olib: scopes_keep_slowest
scopes_keep_slowest :: (state: *Test_State) {
    o: TO_PO.Overlay;
    defer TO_PO.dispose(*o);

    names: [10] string = .["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"];
    stats: TO_HASH.Table(string, TO_PROF.Profile_Stat);
    defer TO_HASH.deinit(*stats);
    for name, i: names {
        // 1..10 ms，一条一个作用域，帧数 1 → ms_per_frame 就等于 total。
        TO_HASH.table_set(*stats, name, TO_PROF.Profile_Stat.{ count = 1, total = (cast(s64) (i + 1)) * 1000000 });
    }

    TO_PO.scopes_collect(*o, stats, 1);
    expect(state, o.scope_count == TO_PO.MAX_SCOPES, "榜单上限 MAX_SCOPES = %，得到 %",
    TO_PO.MAX_SCOPES, o.scope_count);
    expect(state, o.scopes[0].name == "j", "最慢的应是 j（10 ms），得到 %", o.scopes[0].name);
    expect(state, o.scopes[0].ms_per_frame == 10.0, "j 应为 10 ms/帧，得到 %", o.scopes[0].ms_per_frame);
    expect(state, o.scopes[TO_PO.MAX_SCOPES - 1].name == "c", "第 % 名应是 c（3 ms），得到 %",
    TO_PO.MAX_SCOPES, o.scopes[TO_PO.MAX_SCOPES - 1].name);
    expect(state, o.scopes[TO_PO.MAX_SCOPES - 1].ms_per_frame == 3.0, "第 % 名应为 3 ms，得到 %",
    TO_PO.MAX_SCOPES, o.scopes[TO_PO.MAX_SCOPES - 1].ms_per_frame);

    // 榜单严格降序（被截断的那两根不能以任意顺序混进来）。
    descending := true;
    for i: 1..TO_PO.MAX_SCOPES - 1 {
        if o.scopes[i - 1].ms_per_frame < o.scopes[i].ms_per_frame descending = false;
    }
    expect(state, descending, "榜单应按 ms_per_frame 降序排列");
}
//@endregion

//@region tween_preview 纯函数（tween_preview/session.jai）

status_message_covers_every_status :: (state: *Test_State) {
    expect(state, TO_TP.status_message(.Ready) == "", "Ready 不应有提示文本");
    ready_missing := TO_TP.status_message(.Case_Missing);
    target_missing := TO_TP.status_message(.Target_Missing);
    create_failed := TO_TP.status_message(.Create_Failed);
    invalid_observation := TO_TP.status_message(.Invalid_Observation);

    expect(state, ready_missing != "", "Case_Missing 应有提示文本");
    expect(state, target_missing != "", "Target_Missing 应有提示文本");
    expect(state, create_failed != "", "Create_Failed 应有提示文本");
    expect(state, invalid_observation != "", "Invalid_Observation 应有提示文本");

    // 四条文案互不相同：if 链里漏写/写重一条会立刻失败。
    all_distinct := ready_missing != target_missing && ready_missing != create_failed &&
    ready_missing != invalid_observation && target_missing != create_failed &&
    target_missing != invalid_observation && create_failed != invalid_observation;
    expect(state, all_distinct, "四种失败状态的提示文本应互不相同");

    // 文案要点出各自的成因与处置。
    expect(state, TO_STRING.contains(ready_missing, "案例"), "Case_Missing 应提到案例，得到 %", ready_missing);
    expect(state, TO_STRING.contains(target_missing, "对象"), "Target_Missing 应提到对象，得到 %", target_missing);
    expect(state, TO_STRING.contains(target_missing, "重新选择"), "Target_Missing 应提示重新选择，得到 %", target_missing);
    expect(state, TO_STRING.contains(invalid_observation, "NaN"), "Invalid_Observation 应提到 NaN，得到 %",
    invalid_observation);
    expect(state, TO_STRING.contains(invalid_observation, "停止"), "Invalid_Observation 应说明已停止，得到 %",
    invalid_observation);

    // 越界枚举值走的是最后那条 fallback，返回空串（不崩、不复用别的文案）。
    fallback := TO_TP.status_message(cast(TO_TP.Status) 99);
    expect(state, fallback == "", "未知状态应返回空串（fallback），得到 %", fallback);
}

// make_id / valid_id / id_text：无指针的语义 ID 快照。
stored_id_roundtrip_and_validation :: (state: *Test_State) {
    expect(state, TO_TP.valid_id("alpha"), "普通 ID 合法");
    expect(state, !TO_TP.valid_id(""), "空 ID 非法");

    // 128 是上限（Stored_ID.bytes 正好 128 字节），129 超限。
    buf: [129] u8;
    for *b: buf b.* = 97; // 'a'
    at_limit: string;
    at_limit.data = *buf[0];
    at_limit.count = 128;
    over_limit: string;
    over_limit.data = *buf[0];
    over_limit.count = 129;
    expect(state, TO_TP.valid_id(at_limit), "128 字节 ID 合法（上限）");
    expect(state, !TO_TP.valid_id(over_limit), "129 字节 ID 非法");

    // 内嵌 0 字节的 ID 非法（会截断 json / 字符串协议）。
    with_zero := "bad\x00id";
    expect(state, !TO_TP.valid_id(with_zero), "含 0 字节的 ID 非法");

    id := TO_TP.make_id("alpha");
    expect(state, id.length == 5, "make_id 应记录长度 5，得到 %", id.length);
    expect(state, TO_TP.id_text(*id) == "alpha", "id_text 应还原原字符串，得到 %", TO_TP.id_text(*id));
    expect(state, TO_TP.id_text(*id).count == 5, "id_text 的长度应为 5");
    // id_text 借用快照自身的 bytes（面板每帧调用，不能分配）。
    expect(state, TO_TP.id_text(*id).data == *id.bytes[0], "id_text 应直接指向快照的 bytes，不复制");

    empty := TO_TP.make_id("");
    expect(state, empty.length == 0, "空 ID 应得到零长度快照，得到 %", empty.length);
    expect(state, TO_TP.id_text(*empty) == "", "零长度快照的 text 应为空串");

    full := TO_TP.make_id(at_limit);
    expect(state, full.length == 128, "128 字节 ID 应完整写入，得到 %", full.length);
    expect(state, TO_TP.id_text(*full).count == 128, "id_text 应返回 128 字节");

    // 超限时 make_id 不写任何字节（返回零值快照），不会截断成半截 ID。
    rejected := TO_TP.make_id(over_limit);
    expect(state, rejected.length == 0, "129 字节 ID 应被拒绝，得到长度 %", rejected.length);
    expect(state, TO_TP.id_text(*rejected) == "", "被拒绝的快照 text 应为空");

    // 读取侧也挡一道：length > 128 的快照不返回任何字节（手写坏数据不会越界）。
    corrupt := TO_TP.Stored_ID.{ length = 129 };
    expect(state, TO_TP.id_text(*corrupt) == "", "length>128 的快照应返回空串");

    // make_id 是值拷贝：改原字符串不影响快照。
    mutable := copy_string("beta");
    snapshot := TO_TP.make_id(mutable);
    mutable.data[0] = cast(u8) 122; // 'z'
    expect(state, TO_TP.id_text(*snapshot) == "beta", "快照应持有自己的字节副本，得到 %",
    TO_TP.id_text(*snapshot));
    free(mutable.data);
}

// Target_ID 是 128 位稳定身份：只做逐字段比较，不当下标/哈希。
target_id_helpers_and_step_quantization :: (state: *Test_State) {
    zero: TO_TP.Target_ID;
    one := TO_TP.Target_ID.{ high = 1, low = 1 };
    one_same := TO_TP.Target_ID.{ high = 1, low = 1 };
    two := TO_TP.Target_ID.{ high = 2, low = 1 };
    crossed := TO_TP.Target_ID.{ high = 1, low = 2 };

    expect(state, TO_TP.target_id_is_zero(zero), "全零 ID 是'选择默认对象'");
    expect(state, !TO_TP.target_id_is_zero(one), "非零 ID 不是默认值");
    expect(state, !TO_TP.target_id_is_zero(crossed), "只有 high 非零也不算默认值");
    expect(state, TO_TP.target_id_equal(one, one_same), "同字段的 ID 应相等");
    expect(state, !TO_TP.target_id_equal(one, two), "high 不同应不等");
    expect(state, !TO_TP.target_id_equal(one, crossed), "high/low 交换后应不等（逐字段比较）");
    expect(state, !TO_TP.target_id_equal(one, zero), "非零与全零应不等");

    // target_step：固定步长重演的定位换算（olib: floor(seconds/fixed_dt + 1e-9)，
    // 到达时长则用 ceil(duration/fixed_dt)）。
    case_item: TO_TP.Case;
    case_item.id = "alpha";
    case_item.duration = 1.0;
    cases: [] TO_TP.Case;
    cases.data = *case_item;
    cases.count = 1;

    session: TO_TP.Session;
    session.config.cases = cases;
    session.config.fixed_dt = 0.1;
    session.case_index = 0;
    session.initialized = true;

    expect(state, TO_TP.target_step(*session, 0.0) == 0, "0 秒应定位到第 0 步，得到 %",
   TO_TP.target_step(*session, 0.0));
    expect(state, TO_TP.target_step(*session, 0.1) == 1, "0.1 秒应定位到第 1 步");
    // 0.3/0.1 = 2.9999999999999996：+1e-9 后必须仍然落在第 3 步，不能丢一步。
    expect(state, TO_TP.target_step(*session, 0.3) == 3, "0.3 秒应定位到第 3 步（浮点误差不丢步），得到 %",
    TO_TP.target_step(*session, 0.3));
    expect(state, TO_TP.target_step(*session, 0.35) == 3, "0.35 秒应向下取整到第 3 步，得到 %",
    TO_TP.target_step(*session, 0.35));
    expect(state, TO_TP.target_step(*session, 1.0) == 10, "到达时长应 ceil(duration/fixed_dt) = 10，得到 %",
    TO_TP.target_step(*session, 1.0));
    expect(state, TO_TP.target_step(*session, 5.0) == 10, "超出时长也应钳到末步 10，得到 %",
    TO_TP.target_step(*session, 5.0));

    // fixed_dt 换成 1/120（0 值时的实际默认）后的换算仍按同一公式。
    session.config.fixed_dt = 1.0 / 120.0;
    expect(state, TO_TP.target_step(*session, 1.0 / 120.0) == 1, "1/120 秒应定位到第 1 步，得到 %",
    TO_TP.target_step(*session, 1.0 / 120.0));

    // 未初始化 / 案例下标越界的 Session 拿不到案例（current_case 返回 null 前会先看这两个条件）；
    // 这里只验证有限性判断本身，不构造越界调用。
    expect(state, TO_TP.finite(0.0), "0 是有限值");
    expect(state, TO_TP.finite(-1.5), "负数也是有限值");
    expect(state, !TO_TP.finite(TO_M.FLOAT64_NAN), "NaN 不是有限值");
    expect(state, !TO_TP.finite(TO_M.FLOAT64_INFINITY), "+Inf 不是有限值");
    expect(state, !TO_TP.finite(-TO_M.FLOAT64_INFINITY), "-Inf 不是有限值");
}
//@endregion

// Loop scopes adapted.
