// kit/ui 测试：一比一移植自 olib tests/kit/ui/（ui_test.odin 27 例 + ui_controls_test.odin 13 例 +
// ui_motion_test.odin 3 例，共 1,788 行）。用例名与 olib 一一对应、断言顺序保持；文件末尾的
// 5 个用例是 olib 没写测试、但本任务的验收点（ui_translate 字段翻译、ui_ops_insert 中间插入、
// 焦点框插入位置、ui_visual_lerp、UTF-8/缓冲拼接），它们不替换、不重排 olib 的断言。
//
// Jai 侧写法差异（与 olib 的 Odin 一一对应）：
//   | olib (Odin, core:testing)                    | 这里 (Jai, Tests/test_support.jai)                  |
//   | ------------------------------------------- | --------------------------------------------------- |
//   | testing.expect(t, cond, "msg")               | expect(state, cond, "msg")                           |
//   | testing.expect_value(t, a, b)                | expect(state, a == b, "msg")                         |
//   | testing.expectf(t, cond, "...%v", a)         | expectf(state, cond, "...%", a)                      |
//   | sync.mutex_lock（clay 全局 context）          | 不需要：runner 串行调用，一个 ctx 用完就 dispose     |
//   | `if clay.UI()(decl) { … }`                   | `clay.UI(decl, #code { … })`           |
//   | clay.ElementDeclaration{…}                   | 同名同字段（没有适配层；presence 见 kit/ui/module.jai）        |
//   | `foster.Texture{Width=128}`                  | fake_texture（只填元数据，不建 GPU 资源）            |
//   | `foster.MsdfCharacter{Codepoint='A'}`        | 合成 F.Msdf_Font（字形表 + 平面/图集边界）           |
//   | `len(x)`                                     | `x.count`                                            |
//   | `[dynamic]T` / append                        | `[..]T` / array_add                                  |
//   | `'A'` 字符字面量                              | 码点数字（jacket 不支持字符字面量）                   |
//   | `map` 下标                                   | table_find / table_set（Hash_Table）                 |
//
// 与 olib 行为不同、因此断言方向也不同的地方（都是 kit/ui 头部已声明的移植差异，不是本次改动）：
//   * 差异 C（迁移到 clay 0.14 之后已消失）：移植版带 SetPointerHitTestFunction，kit/ui 把它装成
//     ui_visual_hit，于是 clay.PointerOver 自己就跟着 ui_set_visual 的变换、嵌套裁剪和 presence 的
//     inert 走 —— visual_subtree_* / visual_slider_* 恢复成 olib 的「变换后位置才命中」。
//     ui_pointer_local / ui_visual_pointer 仍是自定义滑条、拖动要用的逆变换入口。
//   * 差异 E/H：jfoster 的 Msdf_Font 没有 Characters/Kerning/SourceRect/Offset，字距恒为 0
//     （ui_msdf_kerning 是留空的钩子）。olib 里依赖字距的期望值相应按 0 字距折算。
//   * 需要 Render2D/GPU 的断言（ui_render 的 runs/vertices、MSDF 材质分段、圆角纹理、字体上传）
//     一律不执行，见 ui_render_* 处注释；本文件不伪造 GPU 设备。
//   * 命中测试走 clay 自己的 SetPointerHitTestFunction 回调（ui_visual_hit），所以
//     clay.PointerOver 就是完整判据：它看得到变换、嵌套裁剪与 presence 的 inert。
//
// 补写的后半部分用例（olib 一一对应，见各 @region 注释）：
//   * 指针边沿 5 例（ui_controls_test.odin 的 pointer_edges_*，含显式 setter 与重按归属）；
//   * 焦点自动滚动、下拉框、虚拟列表、拖放（ui_controls_test.odin）；
//   * 文本输入 2 例、焦点框 2 例（同一文件的 text_input_* / focus_ring_*）；
//   * 状态驱动动效 3 例（ui_motion_test.odin）；
//   * 5 个本任务验收点（ui_translate 字段翻译、ui_ops_insert 中间插入、焦点框插入位置、
//     ui_visual_lerp、UTF-8/缓冲拼接）。
//
// 这批用例在迁移到 clay 0.14 前后查出/复核过的真 bug（都在命中/翻译层与夹具，接口与结构未改）：
//   1) 命中链把浮动元素的**声明父元素**也算作被指针覆盖。clay 把浮动元素挂成布局树的独立根
//      （不加入父的 children），于是 clay.PointerOver(按钮) 在指针位于浮层上时为 false。迁移之后
//      这条不用再自己维护：clay 的 pointerOverIds 按树根分别 DFS，浮动根的 parentId 只决定视觉
//      与裁剪继承。（历史修法：UI_Element_Info / UI_Hit_Element 记 floating 标志。）
//   2) 带裁剪的焦点元素（文本框）的焦点框画在了它自己的裁剪之内。clay 0.14 有**两条** SCISSOR_END：
//      clay_layout.jai 里元素自己那条带 elementId，根级那条（浮动根的 root.clipElementId）不带，
//      elementId 默认 0。文本框的光标是 clipTo = ATTACHED_PARENT 的浮动根，它的根级 SCISSOR_START
//      同样带着文本框的 elementId —— 若把 SCISSOR_START 算成「焦点元素自己的命令」，ring_at 会停在
//      这条裁剪起点之后，而收尾的根级 SCISSOR_END 没有 elementId，再也挪不回来，焦点框落进裁剪里。
//      修法：ui_translate_into 的 focused 判定排除 SCISSOR_START（与 olib 一致），ring_at 只由矩形、
//      描边、文字和**元素自己**的 SCISSOR_END 推进；ring_bb 仍取非裁剪命令的 boundingBox，元素没有
//      自己的绘制命令时退回布局矩形。
//   3) 浮动子树的嵌套裁剪在夹具里没接上：clip-inner 省略了 clipTo，而 clay 的零值枚举就是
//      .NONE（CLAY_CLIP_TO_NONE == 0），等于声明「这条浮层不跟父元素裁剪」，clay 会把它的 clipId
//      清 0 —— 外层裁剪既不进 clipId 链、也不进 clay 的 hit-test 裁剪检查。夹具按 olib 显式写
//      clipTo = .ATTACHED_PARENT；断言一条没动。
#import "Basic";
#import "test_support";
JM :: #import "Math";
F :: #import "foster";
HASH :: #import "Hash_Table";

using HASH;

FILE :: #import "File";
clay :: #import "thirdparty/clay/module";
#import "kit/ui";

//@region 工具

PI_F :: cast(float32) JM.PI;

// Tests/test_support.jai 的 expect 把 ..Any 当整体喂 sprint（第二个 % 会报错），这里先正确展开。
expectf :: (state: *Test_State, condition: bool, msg: string, args: ..Any) {
    expect(state, condition, sprint(msg, ..args));
}

fabs :: (v: float32) -> float32 {
    if v < 0 return -v;
    return v;
}

near :: (a: float32, b: float32) -> bool {
    return fabs(a - b) < 1e-4;
}

near_e :: (a: float32, b: float32, eps: float32) -> bool {
    return fabs(a - b) <= eps;
}

vec2 :: (x: float32, y: float32) -> F.Vector2 {
    return .{ x, y };
}

vec2_eq :: (a: F.Vector2, b: F.Vector2) -> bool {
    return a.x == b.x && a.y == b.y;
}

// olib 的 `bb == clay.BoundingBox{…}`。
bbox :: (x: float32, y: float32, w: float32, h: float32) -> clay.BoundingBox {
    return .{ x, y, w, h };
}

bbox_eq :: (a: clay.BoundingBox, b: clay.BoundingBox) -> bool {
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

// Jai 的结构体没有隐式 == （olib 的 UI_Visual 比较靠逐字段）。
visual_eq :: (a: UI_Visual, b: UI_Visual) -> bool {
    return vec2_eq(a.offset, b.offset) && vec2_eq(a.scale, b.scale) &&
    a.rotation == b.rotation && vec2_eq(a.pivot, b.pivot) && a.opacity == b.opacity;
}

// olib 的 testing.expect_value(t, r, UI_Virtual_Range{…})。
range_eq :: (a: UI_Virtual_Range, b: UI_Virtual_Range) -> bool {
    return a.first == b.first && a.last == b.last && a.before == b.before && a.after == b.after;
}

// 只构造纹理元数据（olib 的零值 foster.Texture + Width/Height）。handle 非零走真实就绪判据；
// device 为 null，任何释放路径都不会碰 GPU。
fake_texture :: (width: s32, height: s32) -> *F.Texture {
    texture := New(F.Texture);
    texture.Width = width;
    texture.Height = height;
    texture.handle = 1;
    return texture;
}

file_present :: (path: string) -> bool {
    data, ok := FILE.read_entire_file(path);
    if !ok return false;
    if data.data != null free(data.data);
    return true;
}

// 真实 TTF（字体烘焙用例）与 olib 的 msdf 图集（离线 atlas 用例）；缺失时用例自行跳过。
UI_TEST_FONT_PATH :: "C:/Windows/Fonts/arial.ttf";
UI_TEST_MSDF_JSON :: "D:/MySpace/Github/olib/tests/kit/ui/testdata/abel-msdf.json";
UI_TEST_MSDF_PNG :: "D:/MySpace/Github/olib/tests/kit/ui/testdata/abel-msdf.png";

// olib 的 make_test_font：两个可见字形 + 一对字距。
// jfoster 的 Msdf_Font 用平面边界（em 归一化 pl/pt/pr/pb）与图集边界（0..1 al/at/ar/ab）。
// olib 的 SourceRect{0,0,16,20} / Offset{0,0} / Advance 18 在这里写成 pl=0,pr=16/32 …；
// 字距对（A,B,-2）在 jfoster 里没有承载字段，ui_msdf_kerning 恒为 0（见文件头）。
make_test_font :: () -> *F.Msdf_Font {
    font := New(F.Msdf_Font);
    font.Size = 32;
    font.Ascent = 24;
    font.Descent = -8;
    font.LineHeight = 36;
    font.Atlas = New(F.Image);
    font.Atlas.* = F.image_create(64, 64);
    // A: 源矩形 (0,0,16,20)，advance 18，偏移 (0,0)
    test_font_glyph(font, 65, 0, 0, 16, 20, 18, 0, 0);
    // B: 源矩形 (16,0,14,20)，advance 15，偏移 (1,0)
    test_font_glyph(font, 66, 16, 0, 14, 20, 15, 1, 0);
    return font;
}

// unicode_spacing 用例：同样的度量，码点换成 U+4E2D / U+6587。
// 不重用 make_test_font 再清空：`array_free` / Table 的 `deinit` 都只释放内存、不置空指针
// （见 jacket stdlib arrays.jai 与 Hash_Table.jai），之后 array_add/table_set 会写回已释放的
// 存储。这里直接造一份新的。
make_test_font_cjk :: () -> *F.Msdf_Font {
    font := New(F.Msdf_Font);
    font.Size = 32;
    font.Ascent = 24;
    font.Descent = -8;
    font.LineHeight = 36;
    font.Atlas = New(F.Image);
    font.Atlas.* = F.image_create(64, 64);
    test_font_glyph(font, 0x4E2D, 0, 0, 16, 20, 18, 0, 0);
    test_font_glyph(font, 0x6587, 16, 0, 14, 20, 15, 1, 0);
    return font;
}

// 合成字形的第三个（"AV" 用）：图集里放在 (32,0)，宽 12 高 20，advance 16。
make_test_font_av :: () -> *F.Msdf_Font {
    font := make_test_font();
    test_font_glyph(font, 86, 32, 0, 12, 20, 16, 1, 0);
    return font;
}

test_font_glyph :: (font: *F.Msdf_Font, codepoint: s32, sx: float32, sy: float32,
w: float32, h: float32, advance: float32, offset_x: float32, offset_y: float32) {
    glyph: F.Msdf_Font_Glyph;
    glyph.Unicode = codepoint;
    glyph.Advance = advance;
    glyph.pl = offset_x / font.Size;
    glyph.pt = offset_y / font.Size;
    glyph.pr = (offset_x + w) / font.Size;
    glyph.pb = (offset_y + h) / font.Size;
    glyph.al = sx / cast(float32) font.Atlas.Width;
    glyph.at = sy / cast(float32) font.Atlas.Height;
    glyph.ar = (sx + w) / cast(float32) font.Atlas.Width;
    glyph.ab = (sy + h) / cast(float32) font.Atlas.Height;
    table_set(*font.lookup, codepoint, cast(s32) font.Glyphs.count);
    array_add(*font.Glyphs, glyph);
}

dispose_test_font :: (font: *F.Msdf_Font) {
    if font == null return;
    if font.Atlas != null {
        F.image_destroy(font.Atlas);
        free(font.Atlas);
    }
    array_free(font.Glyphs);
    deinit(*font.lookup);
    free(font);
}

// 把一组手搓的 clay 渲染命令送进翻译层（不经过布局，纯 CPU）。
translate_commands :: (ctx: *UI_Context, commands: [] clay.RenderCommand) -> [..] UI_Op {
    array := clay.ClayArray(clay.RenderCommand).{
        capacity = cast(s32) commands.count,
        length = cast(s32) commands.count,
        internalArray = commands.data,
    };
    return ui_translate(ctx, array);
}

// 0.14 的 RenderCommand 直接带 renderData（union），不再是 0.12 那种
// `config = .{ xxxElementConfig = ptr }` 的指针包装；圆角也从 elementConfig 移到 renderData。
rect_command :: (id: u32, x: float32, y: float32, w: float32, h: float32,
color: clay.Color, radius: float32 = 0) -> clay.RenderCommand {
    return clay.RenderCommand.{
        boundingBox = bbox(x, y, w, h),
        renderData = .{ rectangle = .{
            backgroundColor = color,
            cornerRadius = clay.CornerRadiusAll(radius),
        } },
        id = id,
        commandType = .RECTANGLE,
    };
}
//@endregion

//@region 子树视觉变换 —— 真实布局、绘制顶点、命中和 Tween 生命周期

// olib 的 visual_test_frame。父元素 100x60（padding 10）带左描边，子元素 40x20。
visual_test_frame :: (ctx: *UI_Context, visual: UI_Visual, enabled := true) -> UI_Interaction {
    ui_begin(ctx, 1.0 / 60);
    if enabled ui_set_visual(ctx, "visual-parent", visual);
    state := ui_interact(ctx, "visual-child");
    clay.UI(clay.ElementDeclaration.{
        id = clay.ID("visual-parent"),
        layout = .{
            sizing = .{ width = clay.SizingFixed(100), height = clay.SizingFixed(60) },
            padding = clay.PaddingAll(10),
        },
        backgroundColor = .[0.78, 0.39, 0.2, 1],
        border = .{ color = .[1, 1, 1, 1], width = .{ left = 2 } },
    }, #code {
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("visual-child"),
            layout = .{ sizing = .{ width = clay.SizingFixed(40), height = clay.SizingFixed(20) } },
            backgroundColor = .[1, 1, 1, 1],
        });
    });
    ui_translate_into(ctx, ui_end(ctx), *ctx.ops);
    return state;
}

visual_subtree_render_and_pointer_follow_last_display :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    ui_set_viewport(*ctx, F.Rect.{ 17, 23, 1000, 750 }, 1.25);
    v := UI_VISUAL_DEFAULT;
    v.offset = vec2(200, 50);
    v.pivot = vec2(0, 0);
    v.scale = vec2(2, 2);
    v.rotation = PI_F / 2;
    v.opacity = 0.5;
    visual_test_frame(*ctx, v);
    bb := clay.GetElementData(clay.ID("visual-child")).boundingBox;
    expect(state, bbox_eq(bb, bbox(10, 10, 40, 20)), "视觉变换不得改变布局");
    expect(state, ctx.ops.count == 3, "父底 + 子底 + 后画的描边");
    for op: ctx.ops {
        expect(state, op.transformed && op.color.a == 127, "描边同样继承透明度");
    }
    // ui_render 的顶点位置（olib 的 r.vertices[0].Pos == {267, 85.5}）与变换栈恢复需要真实
    // Render2D/材质库，本文件不伪造 GPU 设备，故不执行；发射前的像素矩阵单独验证：
    m := ui_visual_pixel_matrix(*ctx, ctx.ops[0].transform);
    expect(state, m[12] == 17 + 200 * 1.25 && m[13] == 23 + 50 * 1.25, "像素矩阵含视口原点与缩放");
    // 命中测试跟随显示变换（ui_visual.jai 的「命中测试」区）：子元素中心 (30,20) 经变换到
    // 逻辑 (160,110)（= 渲染目标像素 (217, 160.5)），指针在那里才算命中。
    ui_set_pointer(*ctx, 217, 160.5, true);
    pressed := visual_test_frame(*ctx, v);
    expect(state, pressed.pressed && pressed.hovered, "变换后的位置命中");
    ui_set_pointer(*ctx, 217, 160.5, false);
    released := visual_test_frame(*ctx, v);
    expect(state, released.clicked && released.released, "变换后的位置松开算点击");
    // 逆变换的同一套数字：像素 -> 逻辑 -> 子元素局部。
    local, invertible := ui_pointer_local(*ctx, "visual-child");
    expect(state, invertible && near(local.x, 30) && near(local.y, 20), "ui_pointer_local 反算到 (30,20)");
    // 旧的（未变换）布局位置不再命中。
    ui_set_pointer(*ctx, 54.5, 48, true);
    expect(state, !visual_test_frame(*ctx, v).hovered, "未变换的旧位置不命中");
    // 注册是帧内的：撤掉后绘制与输入都恢复原样。
    visual_test_frame(*ctx, v, false);
    expect(state, ctx.visual_elements.count == 0 && !ctx.ops[0].transformed, "撤掉视觉后不留状态");
    expect(state, visual_test_frame(*ctx, v, false).hovered, "撤掉视觉后布局命中");
}

// 嵌套文本 / 九宫格 / 裁剪 / 视口外入场。
visual_nested_text_image_clip_and_offscreen_entry :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 300, 200), "ui_init");
    defer ui_dispose(*ctx);
    font := make_test_font_av();
    defer dispose_test_font(font);
    tex := fake_texture(128, 128);
    defer free(tex);
    ui_register_font(*ctx, font, tex, .MSDF);
    ui_begin(*ctx, 0);
    outer := UI_VISUAL_DEFAULT;
    outer.offset = vec2(60, 30);
    outer.opacity = 0.5;
    inner := UI_VISUAL_DEFAULT;
    inner.offset = vec2(5, 0);
    inner.opacity = 0.5;
    ui_set_visual(*ctx, "clip-parent", outer);
    ui_set_visual(*ctx, "image-child", inner);
    clay.UI(clay.ElementDeclaration.{
        id = clay.ID("clip-parent"),
        layout = .{ sizing = .{ width = clay.SizingFixed(100), height = clay.SizingFixed(60) } },
        clip = .{ horizontal = true, vertical = true },
    }, #code {
        decl := ui_nine_slice_decl(*ctx, tex, 12, 6);
        decl.id = clay.ID("image-child");
        decl.layout.sizing = .{
            width = clay.SizingFixed(80), height = clay.SizingFixed(40),
        };
        clay.UI(decl, #code {
            theme := UI_THEME_DARK;
            theme.body_font_id = 0;
            ui_label(*ctx, *theme, "AV");
        });
    });
    // 布局在视口外的元素也能动画入场。
    entry := UI_VISUAL_DEFAULT;
    entry.offset = vec2(-400, 0);
    ui_set_visual(*ctx, "offscreen", entry);
    clay.UI(clay.ElementDeclaration.{
        id = clay.ID("offscreen"),
        layout = .{ sizing = .{ width = clay.SizingFixed(20), height = clay.SizingFixed(20) } },
        floating = .{ attachTo = .ROOT, offset = .[450, 100] },
        backgroundColor = .[1, 1, 1, 1],
    });
    ui_translate_into(*ctx, ui_end(*ctx), *ctx.ops);
    text_count, nine_count := 0, 0;
    entry_found := false;
    for op: ctx.ops {
        if op.kind == .Scissor_Start {
            expect(state, op.clip_x == 60 && op.clip_y == 30, "裁剪框跟着外层变换走");
        } else if op.msdf {
            text_count += 1;
            expect(state, near(op.transform.m31, 65) && op.color.a == 63, "文本继承父+自身变换与透明度");
        } else if op.texture != null {
            nine_count += 1;
            expect(state, near(op.transform.m31, 65) && op.color.a == 63, "九宫格同样继承");
        } else if op.kind == .Quad && op.x0 == 450 {
            entry_found = true;
            p := ui_visual_point(op.transform, vec2(op.x0, op.y0));
            expect(state, vec2_eq(p, vec2(50, 100)), "视口外元素靠变换移入视口");
        }
    }
    expect(state, text_count == 2 && nine_count == 9 && entry_found, "两段文本 + 九个切片 + 入场元素");
    ui_set_pointer(*ctx, 70, 40, false);
    ui_begin(*ctx, 0);
    expect(state, clay.PointerOver(clay.ID("image-child")), "裁剪容器内的子元素可命中");
    ui_end(*ctx);
}

// olib 用 core:tween 的 manager 打断/重定向；本仓库的 core/tween 只提供 spring 原语，
// ui_visual_lerp 是等价的插值入口（olib 也是把它交给 tween 的 make_ex）。
visual_tween_interrupt_and_singular_input :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    visual := UI_VISUAL_DEFAULT;
    target := visual;
    target.offset = vec2(100, 0);
    // 线性 1 秒的一半：ui_visual_lerp(visual, target, 0.5)
    mid := ui_visual_lerp(visual, target, 0.5);
    expect(state, mid.offset.x == 50, "插值到一半");
    // 打断：从当前位置重定向回默认值，t=1 时必须精确落到目标。
    back := ui_visual_lerp(mid, UI_VISUAL_DEFAULT, 1);
    expect(state, visual_eq(back, UI_VISUAL_DEFAULT), "重定向后精确到位");
    // 退化缩放（0,1）不可逆：不能开始或推进拖动。
    visual.scale = vec2(0, 1);
    visual_test_frame(*ctx, visual);
    ui_set_pointer(*ctx, 50, 20, true);
    _, invertible := ui_pointer_local(*ctx, "visual-child");
    expect(state, !invertible, "奇异变换拒绝反算");
    visual_test_frame(*ctx, visual);
    expect(state, ctx.active_id == 0, "奇异变换下不产生捕获");
}

// 滑条拖动走 ui_pointer_local 的逆变换。
visual_slider_frame :: (ctx: *UI_Context, value: *float32) {
    ui_begin(ctx, 0);
    v := UI_VISUAL_DEFAULT;
    v.offset = vec2(200, 50);
    v.pivot = vec2(0, 0);
    v.rotation = PI_F / 2;
    ui_set_visual(ctx, "slider-parent", v);
    theme := UI_THEME_DARK;
    clay.UI(clay.ElementDeclaration.{
        id = clay.ID("slider-parent"),
        layout = .{ sizing = .{ width = clay.SizingFixed(200), height = clay.SizingFixed(24) } },
    }, #code {
        ui_slider(ctx, *theme, "visual-slider", value);
    });
    ui_end(ctx);
}

visual_slider_drag_uses_inverse_transform :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    value: float32;
    visual_slider_frame(*ctx, *value);
    visual_slider_frame(*ctx, *value);
    // 滑条父元素旋转 90 度、位移 (200,50)：布局 (100,12) 落在逻辑 (188,150)。
    // 按下的命中判定同样走逆变换，所以这里按在**变换后**的位置上。
    ui_set_pointer(*ctx, 188, 150, true);
    visual_slider_frame(*ctx, *value);
    expect(state, near(value, 0.5) && ctx.active_id != 0, "反算出滑条中点：% -> 0.5", value);
    // 逻辑 (188,500) 落在旋转后父元素的可见区域外，仍按捕获继续拖动并钳制到 1。
    ui_set_pointer(*ctx, 188, 500, true);
    visual_slider_frame(*ctx, *value);
    expect(state, value == 1, "捕获后拖出变换范围仍生效");
    ui_set_pointer(*ctx, 188, 58, false);
    visual_slider_frame(*ctx, *value);
    expect(state, near(value, 0) && ctx.active_id == 0, "松开在起点附近回到 0");
}

// 浮动子树的祖先关系与嵌套裁剪。
visual_clip_frame :: (ctx: *UI_Context) {
    ui_begin(ctx, 0);
    v := UI_VISUAL_DEFAULT;
    v.offset = vec2(100, 50);
    ui_set_visual(ctx, "clip-outer", v);
    clay.UI(clay.ElementDeclaration.{
        id = clay.ID("clip-outer"),
        layout = .{ sizing = .{ width = clay.SizingFixed(100), height = clay.SizingFixed(100) } },
        clip = .{ horizontal = true, vertical = true },
    }, #code {
        // 浮动子树继承声明处的父元素，且被祖先裁剪。
        // clipTo 必须显式写 ATTACHED_PARENT：clay 的零值枚举是 .NONE（CLAY_CLIP_TO_NONE == 0），
        // 不写就等于声明「这条浮层不跟父元素裁剪」，clay 会把它的 clipId 清 0 —— 于是外层裁剪
        // 既不进 clipId 链、也不进 clay 的 hit-test 裁剪检查。olib 的同名 fixture 就是这么写的。
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("clip-inner"),
            layout = .{ sizing = .{ width = clay.SizingFixed(100), height = clay.SizingFixed(100) } },
            floating = .{ attachTo = .PARENT, offset = .[60, 0], zIndex = 2, clipTo = .ATTACHED_PARENT },
            clip = .{ horizontal = true, vertical = true },
        }, #code {
            clay.UI(clay.ElementDeclaration.{
                id = clay.ID("clip-target"),
                layout = .{ sizing = .{ width = clay.SizingFixed(100), height = clay.SizingFixed(100) } },
                backgroundColor = .[1, 1, 1, 1],
            });
        });
    });
    ui_translate_into(ctx, ui_end(ctx), *ctx.ops);
}

visual_floating_ancestry_and_nested_clip_match_input :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    visual_clip_frame(*ctx);
    ui_set_pointer(*ctx, 180, 80, false);
    ui_begin(*ctx, 0);
    expect(state, clay.PointerOver(clay.ID("clip-target")), "浮动元素在祖先裁剪内可命中");
    ui_end(*ctx);
    visual_clip_frame(*ctx);
    ui_set_pointer(*ctx, 230, 80, false);
    ui_begin(*ctx, 0);
    expect(state, !clay.PointerOver(clay.ID("clip-target")), "外层裁剪仍拒绝输入");
    ui_end(*ctx);
}

element_rect_reports_last_layout_without_visual :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    _, found := ui_element_rect(*ctx, "visual-child");
    expect(state, !found, "未声明过 -> ok=false");
    v := UI_VISUAL_DEFAULT;
    v.offset = vec2(200, 50);
    visual_test_frame(*ctx, v);
    r, ok := ui_element_rect(*ctx, "visual-child");
    expect(state, ok, "声明过 -> ok=true");
    expectf(state, r == F.Rect.{ 10, 10, 40, 20 }, "矩形不含视觉变换: %", r);
    _, missing := ui_element_rect(*ctx, "never-declared");
    expect(state, !missing, "从未声明的 id -> ok=false");
}
//@endregion

//@region 真实字体：CPU 烘焙与资源所有权（无 GPU）

font_bake_ascii_atlas :: (state: *Test_State) {
    if !file_present(UI_TEST_FONT_PATH) {
        print("  [SKIP] font_bake_ascii_atlas: 缺 %\n", UI_TEST_FONT_PATH);
        return;
    }
    source := F.font_load(UI_TEST_FONT_PATH);
    loaded := source != null;
    expect(state, loaded, "font_load");
    if !loaded {
        return;
    }
    defer F.font_destroy(source);
    font, ok := ui_font_bake_image(source, 48);
    expect(state, ok, "ui_font_bake_image");
    if !ok {
        return;
    }
    defer ui_font_dispose(font);
    expect(state, font.Glyphs.count == 95, "默认 ASCII 32..126 共 95 个字形");
    expect(state, font.Atlas.Width == 1024 && font.Atlas.Height == 512, "初始图集 1024x512");
    expect(state, font.Atlas.Data.count == 1024 * 512, "图集像素已分配");
    found_a, a := ui_msdf_glyph(font, 65);
    expect(state, found_a && a.pr > a.pl && a.pb > a.pt, "'A' 有非零平面边界");
    found_space, space := ui_msdf_glyph(font, 32);
    // 空格不可见：图集/平面边界留零（烘焙里的归一化会跳过它），advance 仍为正。
    expect(state, found_space && space.al == 0 && space.ar == 0 && space.at == 0 && space.ab == 0,
    "空格没有可见边界");
    expect(state, found_space && space.Advance > 0, "空格仍有前进量");
    expect(state, font.Descent < 0 && font.LineHeight == font.Ascent - font.Descent, "行高 = 上行 - 下行");
    visible := false;
    for pixel: font.Atlas.Data {
        expect(state, pixel.r == pixel.a && pixel.g == pixel.a && pixel.b == pixel.a, "预乘 alpha");
        visible = visible || pixel.a > 0;
    }
    expect(state, visible, "图集里确实有覆盖度");
}

// olib 在这里核对字距表；jfoster 的 Msdf_Font 没有 Kerning 字段，ui_msdf_kerning 是留空的钩子
// （恒 0，见 ui_text.jai 头部）。保留用例名与断言顺序，把“字距一致”换成：
// 两次烘焙完全一致 + 钩子对任意字对返回 0（也就是“显式字符集不会改变度量”这一条）。
font_bake_default_and_explicit_ascii_have_codepoint_kerning :: (state: *Test_State) {
    if !file_present(UI_TEST_FONT_PATH) {
        print("  [SKIP] font_bake_default_and_explicit_ascii_have_codepoint_kerning: 缺 %\n", UI_TEST_FONT_PATH);
        return;
    }
    source := F.font_load(UI_TEST_FONT_PATH);
    loaded := source != null;
    expect(state, loaded, "font_load");
    if !loaded {
        return;
    }
    defer F.font_destroy(source);
    points: [95] s32;
    for *cp, i: points cp.* = cast(s32) (32 + i);
    default_font, default_ok := ui_font_bake_image(source, 48);
    defer ui_font_dispose(default_font);
    explicit_font, explicit_ok := ui_font_bake_image(source, 48, points);
    defer ui_font_dispose(explicit_font);
    both := default_ok && explicit_ok;
    expect(state, both, "两次烘焙都成功");
    if !both {
        return;
    }
    expect(state, default_font.Glyphs.count == explicit_font.Glyphs.count, "字形数一致");
    nonzero_pairs := 0;
    for first: points {
        for second: points {
            expect(state, ui_msdf_kerning(default_font, first, second) == 0, "jfoster 无字距表：钩子恒 0");
            expect(state, ui_msdf_kerning(explicit_font, first, second) == 0, "显式字符集同样恒 0");
        }
    }
    expect(state, nonzero_pairs == 0, "没有非零字距对");
    for *glyph, i: default_font.Glyphs {
        expect(state, glyph.Advance == explicit_font.Glyphs[i].Advance, "同尺寸下 advance 一致");
    }
}

font_bake_custom_charset_grows_atlas :: (state: *Test_State) {
    if !file_present(UI_TEST_FONT_PATH) {
        print("  [SKIP] font_bake_custom_charset_grows_atlas: 缺 %\n", UI_TEST_FONT_PATH);
        return;
    }
    source := F.font_load(UI_TEST_FONT_PATH);
    loaded := source != null;
    expect(state, loaded, "font_load");
    if !loaded {
        return;
    }
    defer F.font_destroy(source);
    points: [95] s32;
    for *cp, i: points cp.* = cast(s32) (32 + i);
    font, ok := ui_font_bake_image(source, 192, points);
    expect(state, ok, "192 号烘焙");
    if !ok {
        return;
    }
    defer ui_font_dispose(font);
    expect(state, font.Glyphs.count == points.count, "字形数等于字符集");
    expect(state, font.Atlas.Height > 512, "大字号撑高图集");
    for glyph: font.Glyphs {
        expect(state, glyph.al >= 0 && glyph.at >= 0, "图集边界非负");
        expect(state, glyph.ar <= 1 && glyph.ab <= 1, "图集边界归一化在 0..1");
        expect(state, glyph.ar >= glyph.al && glyph.ab >= glyph.at, "图集边界有序");
    }
}

font_bake_rejects_unusable_inputs :: (state: *Test_State) {
    _, ok := ui_font_bake_image(null, 48);
    expect(state, !ok, "空 Font");
    empty: F.Font;
    _, ok = ui_font_bake_image(*empty, 48);
    expect(state, !ok, "没有字体数据");
    _, ok = ui_font_bake_image(*empty, 0);
    expect(state, !ok, "字号为 0");
    _, _, ok = ui_font_bake(null, *empty, 48);
    expect(state, !ok, "没有设备");
}
//@endregion

//@region 测量

measure_text_advances_and_kerning :: (state: *Test_State) {
    font := make_test_font();
    defer dispose_test_font(font);

    // 单字符 16px（scale 0.5）：advance 18*0.5 = 9
    d := ui_measure_text(font, "A", 16, 0, 0);
    expectf(state, near(d.width, 9), "A 宽: %", d.width);
    expectf(state, near(d.height, 36 * 0.5), "行高: %", d.height);

    // olib: 9 + (-2*0.5) + 7.5 + 2；jfoster 无字距表，字距项恒 0 -> 9 + 7.5 + 2
    d2 := ui_measure_text(font, "AB", 16, 2, 0);
    expectf(state, near_e(d2.width, 9 + 7.5 + 2, 1e-4), "AB 宽: %", d2.width);
    expect(state, ui_msdf_kerning(font, 65, 66) == 0, "字距钩子恒 0");

    // 显式行高覆盖
    d3 := ui_measure_text(font, "A", 16, 0, 20);
    expect(state, d3.height == 20, "显式行高覆盖");
}
//@endregion

//@region 字形四边形

glyph_quads_advance_and_uv :: (state: *Test_State) {
    font := make_test_font();
    defer dispose_test_font(font);

    quads: [..] UI_Glyph_Quad;
    defer array_free(quads);
    end_x := ui_push_glyph_quads(font, "AB", 10, 30, 16, 0, F.Color.{ 255, 255, 255, 255 }, *quads);

    expect(state, quads.count == 2, "两个字形的四边形");
    // A：offset(0,0)，quad 从 (10,30) 起，uv 0..0.25 / 0..0.3125
    a := quads[0];
    expect(state, a.x0 == 10 && a.y0 == 30, "A 起点");
    expectf(state, near(a.x1, 10 + 16 * 0.5), "A 宽: %", a.x1 - a.x0);
    expect(state, a.u0 == 0 && a.v0 == 0, "A uv 起点");
    expectf(state, near_e(a.u1, 16.0 / 64, 1e-6) && near_e(a.v1, 20.0 / 64, 1e-6), "A uv 终点");
    // B：offset.x=1*0.5，起点 x = 10 + 9（A 推进）+ 0（无字距）+ 0.5
    b := quads[1];
    expectf(state, near(b.x0, 10 + 9 + 0.5), "B 起点: %", b.x0);
    // 笔尖返回：10 + 9 + 0 + 7.5
    expectf(state, near_e(end_x, 10 + 9 + 7.5, 1e-4), "笔尖: %", end_x);
}
//@endregion

//@region 端到端：clay 布局 -> 命令 -> 翻译

// 一个按钮 + 两段文字经过真实布局再翻译：按钮底色 1 个 Quad + 两个字形 Quad。
layout_translate_roundtrip :: (state: *Test_State) {
    font := make_test_font();
    defer dispose_test_font(font);
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    ui_register_font(*ctx, font, null); // 纹理零值（CPU 测试不上传）
    ui_begin(*ctx, 1.0 / 60);
    theme := UI_THEME_DARK;
    _ = ui_button(*ctx, *theme, "btn1", "AB");
    ops := ui_translate(*ctx, ui_end(*ctx));
    quads := 0;
    for op: ops if op.kind == .Quad quads += 1;
    expectf(state, quads >= 3, "quad 数: %", quads);
    array_free(ops);
}
//@endregion

//@region 控件状态机

// 真正按帧驱动交互；无字体时按钮仍有 80px 最小宽度和 20px padding 高度。
button_frame :: (ctx: *UI_Context, x: float32, y: float32, down: bool,
options: UI_Widget_Options = .{}) -> bool {
    ui_set_pointer(ctx, x, y, down);
    ui_begin(ctx, 1.0 / 60);
    theme := UI_THEME_DARK;
    clicked := ui_button(ctx, *theme, "button", "", options);
    ui_end(ctx);
    return clicked;
}

button_release_capture_cancel_and_disabled :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    button_frame(*ctx, 5, 5, false);
    expect(state, !button_frame(*ctx, 5, 5, true), "按下不触发");
    expect(state, ctx.active_id != 0, "按下即捕获");
    expect(state, !button_frame(*ctx, 5, 5, true), "按住不重复触发");
    expect(state, button_frame(*ctx, 5, 5, false), "松开触发");
    expect(state, ctx.active_id == 0 && ui_input_capture(*ctx).pointer, "松开后释放捕获并消费指针");
    button_frame(*ctx, 5, 5, true);
    expect(state, !button_frame(*ctx, 500, 500, false), "外面松开取消");
    button_frame(*ctx, 500, 500, true);
    expect(state, !button_frame(*ctx, 5, 5, false), "外面按下不能激活");
    expect(state, !button_frame(*ctx, 5, 5, true, UI_Widget_Options.{ disabled = true }), "禁用不触发");
    expect(state, !button_frame(*ctx, 5, 5, false, UI_Widget_Options.{ disabled = true }), "禁用松开不触发");
    expect(state, ui_input_capture(*ctx).pointer, "禁用仍挡住世界点击");
    expect(state, button_frame(*ctx, 5, 5, true, UI_Widget_Options.{ trigger = .Press }), "Press 模式按下即触发");
    expect(state, !button_frame(*ctx, 5, 5, false, UI_Widget_Options.{ trigger = .Press }), "Press 模式松开不重复");
}

toggle_flips_only_after_confirmation :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    theme := UI_THEME_DARK;
    value := false;
    states: [5] bool = .[false, true, false, true, false];
    for down, i: states {
        ui_set_pointer(*ctx, 5, 5, down);
        ui_begin(*ctx, 1.0 / 60);
        _ = ui_toggle(*ctx, *theme, "toggle", *value);
        ui_end(*ctx);
        expected := i == 2 || i == 3;
        expectf(state, value == expected, "第 % 帧的开关值: %", i, value);
    }
}
//@endregion

//@region Unicode 间距 / 图像 UV / 九宫格

unicode_spacing_and_glyph_positions_agree :: (state: *Test_State) {
    font := make_test_font_cjk();
    defer dispose_test_font(font);
    d := ui_measure_text(font, "中文", 16, 2, 0);
    expectf(state, d.width == 18.5, "Unicode 宽度: %", d.width);
    expect(state, ui_measure_text(font, "中", 16, 2, 0).width == 9, "单字宽度");
    quads: [..] UI_Glyph_Quad;
    end := ui_push_glyph_quads(font, "中文", 0, 0, 16, 2, F.Color.{ 255, 255, 255, 255 }, *quads);
    expect(state, end == d.width, "笔尖推进等于测量宽度");
    expectf(state, quads.count == 2 && quads[1].x0 == 11.5, "字距排在第二个字形之前: %", quads[1].x0);
    array_free(quads);
}

image_uv_and_trimmed_atlas_frame :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    tex := fake_texture(128, 64);
    defer free(tex);
    // 0.14 的图像配置就在 renderData.image（同 olib），不再经 elementConfig 指针。
    commands: [1] clay.RenderCommand;
    commands[0] = clay.RenderCommand.{
        commandType = .IMAGE,
        boundingBox = bbox(0, 0, 40, 40),
        renderData = .{ image = .{ imageData = cast(*void) tex } },
    };
    ops := translate_commands(*ctx, commands);
    expect(state, ops.count == 1, "一条图像命令");
    expect(state, ops[0].u0 == 0 && ops[0].v0 == 0 && ops[0].u1 == 1 && ops[0].v1 == 1, "整张纹理 UV");
    expect(state, ops[0].color == F.Color_White, "未染色按白色");
    // 图集区域 + 裁切后的帧：画出来的是 Source 在 Frame 里的位置。
    ui_begin(*ctx, 1.0 / 60);
    sub := F.subtexture_make(tex, F.Rect.{ 32, 16, 16, 16 }, F.Rect.{ -4, -8, 32, 32 });
    ui_image(*ctx, sub, 64, 64);
    ui_translate_into(*ctx, ui_end(*ctx), *ops);
    found := false;
    for op: ops {
        if op.texture != tex continue;
        found = true;
        expect(state, op.x0 == 8 && op.y0 == 16 && op.x1 == 40 && op.y1 == 48, "裁切帧的绘制偏移");
        expect(state, op.u0 == 0.25 && op.u1 == 0.375 && op.v0 == 0.25 && op.v1 == 0.5, "图集 UV");
    }
    expect(state, found, "找到图片 op");
    array_free(ops);
}

nine_slice_preserves_corners_and_draws_behind_children :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    tex := fake_texture(128, 128);
    defer free(tex);
    sizes: [2] F.Vector2 = .[.{ 240, 50 }, .{ 20, 12 }];
    for size: sizes {
        ui_begin(*ctx, 1.0 / 60);
        decl := ui_nine_slice_decl(*ctx, tex, 32, 12);
        decl.layout.sizing = .{ width = clay.SizingFixed(size.x), height = clay.SizingFixed(size.y) };
        clay.UI(decl, #code {
            clay.UI(clay.ElementDeclaration.{
                layout = .{ sizing = .{ width = clay.SizingFixed(2), height = clay.SizingFixed(2) } },
                backgroundColor = .[1, 0, 0, 1],
            });
        });
        ops := ui_translate(*ctx, ui_end(*ctx));
        expect(state, ops.count > 1, "九宫格 + 子内容");
        expect(state, ops[0].texture == tex && ops[ops.count - 1].texture == null, "底色画在子内容之前");
        expectf(state, ops[0].x1 - ops[0].x0 == min(size.y * 0.5, 12), "角切片边长: %", ops[0].x1 - ops[0].x0);
        expect(state, ops[0].u1 == 0.25 && ops[0].v1 == 0.25, "源边界换算成 UV");
        area: float32;
        for op: ops {
            if op.texture != tex continue;
            expect(state, op.x1 > op.x0 && op.y1 > op.y0, "小尺寸也不会反转切片");
            expect(state, op.x0 >= 0 && op.y0 >= 0 && op.x1 <= size.x && op.y1 <= size.y, "切片不越界");
            expect(state, op.u0 >= 0 && op.v0 >= 0 && op.u1 <= 1 && op.v1 <= 1, "UV 落在 0..1");
            area += (op.x1 - op.x0) * (op.y1 - op.y0);
        }
        expectf(state, area == size.x * size.y, "切片铺满请求矩形: %", area);
        array_free(ops);
    }
}
//@endregion

//@region 焦点 / 模态 / 滑条 / 上下文生命周期

focus_navigation_and_modal_isolation :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    theme := UI_THEME_DARK;
    for frame: 0..3 {
        if frame == 1 ui_set_navigation(*ctx, UI_Navigation.{ next = 1, activate = true });
        if frame == 2 {
            ui_set_modal(*ctx, "dialog");
            ui_set_navigation(*ctx, UI_Navigation.{ next = 1, activate = true });
        }
        ui_begin(*ctx, 1.0 / 60);
        background := ui_button(*ctx, *theme, "background", "");
        _ = ui_button(*ctx, *theme, "disabled", "", UI_Widget_Options.{ disabled = true });
        ui_set_scope(*ctx, "dialog");
        dialog := ui_button(*ctx, *theme, "confirm", "");
        ui_set_scope(*ctx, "");
        ui_end(*ctx);
        if frame == 1 {
            expect(state, background && !dialog && ctx.input.keyboard, "导航确认激活背景按钮");
        }
        if frame == 2 {
            expect(state, !background && dialog && ctx.input.pointer && ctx.input.keyboard,
            "模态只让作用域内响应");
            expect(state, ctx.focused_id == clay.ID("confirm").id, "焦点进入模态");
        }
        if frame == 3 expect(state, !background && !dialog, "导航是一次性的");
    }
}

slider_capture_scale_and_keyboard :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    ui_set_viewport(*ctx, F.Rect.{ 10, 20, 800, 600 }, 2);
    theme := UI_THEME_DARK;
    value: float32 = 0.5;
    for frame: 0..4 {
        px: float32 = 26; // 渲染目标像素 -> 逻辑 (8,5)
        if frame == 2 px = 1000;
        down := frame == 1 || frame == 2;
        ui_set_pointer(*ctx, px, 30, down);
        if frame == 4 ui_set_navigation(*ctx, UI_Navigation.{ adjust = -1 });
        ui_begin(*ctx, 1.0 / 60);
        _ = ui_slider(*ctx, *theme, "volume", *value);
        ui_end(*ctx);
        if frame == 1 expect(state, value == 0, "按在左端归零");
        if frame == 2 expect(state, value == 1 && ctx.input.pointer, "捕获后拖出范围钳制到 1");
        if frame == 4 expect(state, value == 0 && ctx.input.keyboard, "键盘步进钳制到 0");
    }
}

context_reinitialization_and_pool_diagnostics :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "首次 ui_init");
    expect(state, ui_init(*ctx, 400, 300), "可重复 ui_init");
    defer ui_dispose(*ctx);
    ui_begin(*ctx, 1.0 / 60);
    ctx.text_config_len = ctx.text_config_pool.count;
    expect(state, ui_text_config(*ctx, .{}) == null && ctx.pool_overflow, "池满返回 null 并置溢出标记");
    ui_end(*ctx);
    ui_begin(*ctx, 1.0 / 60);
    expect(state, !ctx.pool_overflow && ui_text_config(*ctx, .{}) != null, "下一帧重置池与标记");
    ui_end(*ctx);
    expect(state, ui_color(.[1.0, 1.0, 1.0, 0.5]) == F.Color.{ 128, 128, 128, 128 }, "颜色换算");
}

scroll_layout_starts_at_top_and_clips_after_wheel :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 300, 300), "ui_init");
    defer ui_dispose(*ctx);
    for frame: 0..2 {
        ui_set_pointer(*ctx, 5, 5, false);
        if frame == 2 ui_add_scroll(*ctx, 0, -2);
        ui_begin(*ctx, 1.0 / 60);
        clay.UI(ui_scroll_decl(*ctx, "list", 50, 100), #code {
            for i: 0..7 {
                clay.UI(clay.ElementDeclaration.{
                    id = clay.ID("row", cast(u32) i),
                    layout = .{
                        sizing = .{ width = clay.SizingFixed(80), height = clay.SizingFixed(20) },
                    },
                    backgroundColor = .[1.0, 1.0, 1.0, 1.0],
                });
            }
        });
        commands := ui_end(*ctx);
        data := clay.GetScrollContainerData(clay.ID("list"));
        expect(state, data.found, "滚动容器数据存在");
        if frame == 0 expect(state, clay.GetElementData(clay.ID("row", 0)).boundingBox.y == 0, "初始在顶部");
        if frame == 2 {
            expect(state, data.scrollPosition != null && data.scrollPosition.*[1] < 0, "滚轮把内容推上去");
            expect(state, clay.GetElementData(clay.ID("row", 0)).boundingBox.y < 0, "首行跟着滚动");
        }
        ops := ui_translate(*ctx, commands);
        has_start, has_end := false, false;
        for op: ops {
            has_start = has_start || op.kind == .Scissor_Start;
            has_end = has_end || op.kind == .Scissor_End;
        }
        expect(state, has_start && has_end, "滚动区带裁剪命令");
        array_free(ops);
    }
}

contexts_switch_without_stealing_layout_or_lifetime :: (state: *Test_State) {
    a, b: UI_Context;
    expect(state, ui_init(*a, 200, 100), "a 初始化");
    expect(state, ui_init(*b, 400, 300), "b 初始化");
    defer ui_dispose(*b);
    button_frame(*a, 5, 5, false);
    expect(state, clay.GetCurrentContext() == a.clay_context, "a 的 context 是当前的");
    button_frame(*b, 5, 5, false);
    ui_dispose(*a);
    expect(state, clay.GetCurrentContext() == b.clay_context, "释放 a 后 b 仍是当前的");
    button_frame(*b, 5, 5, true);
    expect(state, button_frame(*b, 5, 5, false), "b 仍能完整交互");
}

cancel_and_disappearing_widget_release_capture :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 200, 100), "ui_init");
    defer ui_dispose(*ctx);
    button_frame(*ctx, 5, 5, false);
    button_frame(*ctx, 5, 5, true);
    ui_set_navigation(*ctx, UI_Navigation.{ cancel = true });
    expect(state, !button_frame(*ctx, 5, 5, false), "cancel 帧不触发");
    expect(state, ctx.active_id == 0 && ctx.focused_id == 0, "cancel 清掉捕获与焦点");
    button_frame(*ctx, 5, 5, true);
    ui_begin(*ctx, 1.0 / 60);
    ui_end(*ctx);
    expect(state, ctx.active_id == 0 && ctx.focused_id == 0, "控件消失后释放捕获");
    expect(state, !button_frame(*ctx, 5, 5, false), "松开不落到消失的控件上");
}
//@endregion

//@region 指针边沿

// 不提交输入的帧也走完整 begin/end，验证边沿确实被消费而不是依赖下次 setter 覆盖。
pointer_edges_frame :: (ctx: *UI_Context, options: UI_Widget_Options = .{}, drag := false)
-> (a: UI_Interaction, b: UI_Interaction, dropped: bool) {
    ui_begin(ctx, 1.0 / 60);
    clay.UI(ui_row_decl(20), #code {
        a = ui_interact(ctx, "edge-a", options);
        if drag _ = ui_drag_source(ctx, "edge-a", a, 7);
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("edge-a"),
            layout = .{ sizing = .{ width = clay.SizingFixed(60), height = clay.SizingFixed(50) } },
        });
        ui_set_scope(ctx, "edge-modal");
        b = ui_interact(ctx, "edge-b");
        _, _, dropped = ui_drop_target(ctx, "edge-b");
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("edge-b"),
            layout = .{ sizing = .{ width = clay.SizingFixed(60), height = clay.SizingFixed(50) } },
        });
        ui_set_scope(ctx, "");
    });
    ui_end(ctx);
}

pointer_edges_legacy_and_short_click :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    ui_set_viewport(*ctx, F.Rect.{ 20, 30, 800, 600 }, 2);
    pointer_edges_frame(*ctx);
    // 目标像素 (40,50) 对应逻辑 (10,10)，旧接口仍按相邻 UI 帧的 down 推导边沿。
    ui_set_pointer(*ctx, 40, 50, true);
    a, _, _ := pointer_edges_frame(*ctx);
    expect(state, a.pressed && a.active && !a.clicked, "按下边沿");
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, !a.pressed && a.active && !a.clicked, "按住不再报边沿");
    ui_set_pointer(*ctx, 40, 50, false);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, a.released && a.clicked && !a.active && ctx.active_id == 0, "松开即点击并释放捕获");
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, !a.pressed && !a.released && !a.clicked, "边沿消费后清零");

    ui_set_pointer_edges(*ctx, 40, 50, false, true, true);
    expect(state, ui_clicked(*ctx) && ui_released(*ctx), "显式边沿可查询");
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, a.pressed && a.released && a.clicked && !a.active, "同帧按下松开算短点击");
    expect(state, ctx.active_id == 0 && ui_input_capture(*ctx).pointer, "短点击后不留捕获");
    expect(state, !ui_clicked(*ctx) && !ui_released(*ctx), "边沿在帧末清空");
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, !a.pressed && !a.released && !a.clicked, "下一帧没有边沿");

    // 多次提交只合并成一次；Press 控件同样不重放。
    ui_set_pointer_edges(*ctx, 40, 50, true, true, false);
    ui_set_pointer_edges(*ctx, 40, 50, false, false, true);
    a, _, _ = pointer_edges_frame(*ctx, UI_Widget_Options.{ trigger = .Press });
    expect(state, a.pressed && a.released && a.clicked, "多次提交合并成一次边沿");
    ui_set_pointer_edges(*ctx, 40, 50, false, false, false);
    a, _, _ = pointer_edges_frame(*ctx, UI_Widget_Options.{ trigger = .Press });
    expect(state, !a.clicked && ctx.active_id == 0, "没有边沿不触发");
    ui_set_pointer_edges(*ctx, 40, 50, false, true, true);
    ui_set_pointer(*ctx, 40, 50, false);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, !a.clicked, "旧接口丢弃待处理的显式边沿");
}

pointer_edges_hold_release_and_cancel :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    a, _, _ := pointer_edges_frame(*ctx);
    expect(state, a.pressed && a.active && !a.clicked, "显式按下");
    ui_set_pointer_edges(*ctx, 10, 10, true, false, false);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, a.active && !a.pressed && !a.released && !a.clicked, "按住帧没有边沿");
    ui_focus(*ctx, "edge-b");
    b: UI_Interaction;
    a, b, _ = pointer_edges_frame(*ctx);
    expect(state, a.active && b.focused, "键盘焦点不夺走指针捕获");
    ui_set_pointer_edges(*ctx, 10, 10, false, false, true);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, a.clicked && a.released && ctx.active_id == 0, "松开即点击并释放");
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 200, 100, false, false, true);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, a.released && !a.clicked && ctx.active_id == 0, "外面松开不算点击");
    ui_set_navigation(*ctx, UI_Navigation.{ cancel = true });
    ui_set_pointer_edges(*ctx, 10, 10, false, true, true);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, !a.pressed && !a.clicked && ctx.active_id == 0, "cancel 同时吞掉边沿");
}

pointer_edges_disabled_and_modal :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 10, 10, false, true, true);
    a, b, _ := pointer_edges_frame(*ctx, UI_Widget_Options.{ disabled = true });
    expect(state, a.disabled && !a.clicked && !b.clicked && ctx.active_id == 0, "禁用不捕获也不点击");
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 10, 10, false, false, true);
    a, _, _ = pointer_edges_frame(*ctx, UI_Widget_Options.{ disabled = true });
    expect(state, !a.clicked && ctx.active_id == 0, "禁用态下松开不触发");
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx);
    ui_set_modal(*ctx, "edge-modal");
    expect(state, ctx.active_id == 0 && ctx.focused_id == 0, "模态切换清掉捕获与焦点");
    ui_set_pointer_edges(*ctx, 10, 10, false, true, true);
    a, b, _ = pointer_edges_frame(*ctx);
    expect(state, a.disabled && !a.clicked && !b.clicked && ui_input_capture(*ctx).pointer,
    "模态期间背景被禁用但仍消费指针");
    ui_set_pointer_edges(*ctx, 90, 10, false, true, true);
    _, b, _ = pointer_edges_frame(*ctx);
    expect(state, b.clicked, "模态作用域内仍可交互");
    ui_set_modal(*ctx, "");
    ui_set_pointer_edges(*ctx, 10, 10, false, false, true);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, !a.clicked, "关闭模态不会漏出孤立的松开");
}

pointer_edges_repress_keeps_owner :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 10, 10, true, true, true);
    a, b, _ := pointer_edges_frame(*ctx, UI_Widget_Options.{ trigger = .Press });
    expect(state, a.pressed && a.active && a.clicked && !a.released && !b.clicked,
    "同一控件重按仍归它");
    expect(state, ctx.active_id == clay.ID("edge-a").id, "捕获者不变");
    a, _, _ = pointer_edges_frame(*ctx, UI_Widget_Options.{ trigger = .Press });
    expect(state, a.active && !a.pressed && !a.clicked, "重按只报一次");
    ui_set_pointer_edges(*ctx, 10, 10, true, true, true);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, a.pressed && a.active && !a.released && !a.clicked, "松开型控件重按不点击");
    ui_set_pointer_edges(*ctx, 10, 10, false, false, true);
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, a.released && a.clicked && ctx.active_id == 0, "之后松开仍能点击");
    a, _, _ = pointer_edges_frame(*ctx);
    expect(state, !a.clicked, "没有重复点击");
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 90, 10, true, true, true);
    a, b, _ = pointer_edges_frame(*ctx);
    expect(state, a.active && !a.released && !a.clicked && !b.pressed && !b.clicked,
    "重按不把捕获转交给别的控件");
    expect(state, ctx.active_id == clay.ID("edge-a").id, "捕获者仍是 edge-a");
    ui_set_pointer_edges(*ctx, 90, 10, false, false, true);
    a, b, _ = pointer_edges_frame(*ctx);
    expect(state, a.released && !a.clicked && !b.clicked && ctx.active_id == 0,
    "松开在别的控件上不算点击");
    // 即使原捕获者在本帧禁用并清除 active，重按也不能转交给后声明的控件。
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 90, 10, true, true, true);
    a, b, _ = pointer_edges_frame(*ctx, UI_Widget_Options.{ disabled = true });
    expect(state, a.disabled && !b.pressed && !b.clicked && ctx.active_id == 0,
    "捕获者禁用后重按也不转交");
}

pointer_edges_drag_release_and_cancel :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    pointer_edges_frame(*ctx);
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx, drag = true);
    ui_set_pointer_edges(*ctx, 90, 10, true, false, false);
    pointer_edges_frame(*ctx, drag = true);
    expect(state, ctx.drag.dragging, "超过阈值进入拖动");
    ui_set_pointer_edges(*ctx, 90, 10, true, true, true);
    a, b, dropped := pointer_edges_frame(*ctx, drag = true);
    expect(state, !dropped && !a.clicked && !b.clicked && !ctx.drag.dragging,
    "同帧重按不重放旧拖动");
    expect(state, a.active && ctx.active_id == clay.ID("edge-a").id, "捕获仍在源控件上");
    ui_set_pointer_edges(*ctx, 90, 10, false, false, true);
    _, _, dropped = pointer_edges_frame(*ctx, drag = true);
    expect(state, !dropped && ctx.drag.source == 0, "拖动在松开帧之后清掉");
    // 普通拖放仍在松开帧放置一次，end 后清理。
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx, drag = true);
    ui_set_pointer_edges(*ctx, 90, 10, true, false, false);
    pointer_edges_frame(*ctx, drag = true);
    ui_set_pointer_edges(*ctx, 90, 10, false, false, true);
    a, _, dropped = pointer_edges_frame(*ctx, drag = true);
    expect(state, dropped && !a.clicked && ctx.drag.source == 0 && ctx.active_id == 0,
    "松开帧放置一次且不算点击");
    _, _, dropped = pointer_edges_frame(*ctx, drag = true);
    expect(state, !dropped, "下一帧不再放置");
    ui_set_pointer_edges(*ctx, 10, 10, true, true, false);
    pointer_edges_frame(*ctx, drag = true);
    ui_set_pointer_edges(*ctx, 90, 10, true, false, false);
    pointer_edges_frame(*ctx, drag = true);
    ui_set_navigation(*ctx, UI_Navigation.{ cancel = true });
    ui_set_pointer_edges(*ctx, 90, 10, false, false, true);
    a, b, dropped = pointer_edges_frame(*ctx, drag = true);
    expect(state, !dropped && !a.clicked && !b.clicked && ctx.drag.source == 0,
    "cancel 取消拖动与放置");
}
//@endregion

//@region 焦点自动滚动

// olib 的 focus_scroll_frame：20 行 200x20 放进 200x100 的滚动区，整帧无输入。
focus_scroll_frame :: (ctx: *UI_Context, nav: UI_Navigation = .{}) {
    ui_set_navigation(ctx, nav);
    ui_begin(ctx, 1.0 / 60);
    clay.UI(ui_scroll_decl(ctx, "rows", 100, 200, gap = 0), #code {
        for i: 0..19 {
            id := tprint("row-%", i);
            _ = ui_interact(ctx, id);
            clay.UI(clay.ElementDeclaration.{
                id = clay.ID(id),
                layout = .{ sizing = .{ width = clay.SizingFixed(200), height = clay.SizingFixed(20) } },
            });
        }
    });
    ui_end(ctx);
}

focus_scroll_y :: (ctx: *UI_Context) -> float32 {
    clay.SetCurrentContext(ctx.clay_context);
    data := clay.GetScrollContainerData(clay.ID("rows"));
    if !data.found || data.scrollPosition == null return 0;
    return data.scrollPosition.*[1];
}

focus_change_scrolls_container_to_show_widget :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    focus_scroll_frame(*ctx);
    focus_scroll_frame(*ctx);
    expectf(state, focus_scroll_y(*ctx) == 0, "初始滚到顶部: %", focus_scroll_y(*ctx));
    // 第 15 行（300..320）在 100 高的视口下方：滚到底边对齐。
    ui_focus(*ctx, "row-15");
    focus_scroll_frame(*ctx);
    focus_scroll_frame(*ctx);
    expectf(state, focus_scroll_y(*ctx) == -220, "底边对齐: %", focus_scroll_y(*ctx));
    // 已可见的控件不动滚动。
    ui_focus(*ctx, "row-13");
    focus_scroll_frame(*ctx);
    focus_scroll_frame(*ctx);
    expectf(state, focus_scroll_y(*ctx) == -220, "已可见不动: %", focus_scroll_y(*ctx));
    // 导航回到上方：顶边对齐。
    ui_focus(*ctx, "row-2");
    focus_scroll_frame(*ctx);
    focus_scroll_frame(*ctx);
    expectf(state, focus_scroll_y(*ctx) == -40, "顶边对齐: %", focus_scroll_y(*ctx));
    // Tab 从第 0 行往回绕到最后一行，滚到底。
    ui_focus(*ctx, "row-0");
    focus_scroll_frame(*ctx);
    focus_scroll_frame(*ctx, UI_Navigation.{ next = -1 });
    focus_scroll_frame(*ctx);
    expect(state, ctx.focused_id == clay.ID("row-19").id, "反向导航绕到最后一行");
    expectf(state, focus_scroll_y(*ctx) == -300, "滚到底: %", focus_scroll_y(*ctx));
}
//@endregion

//@region 下拉框

dropdown_frame :: (ctx: *UI_Context, selected: *int, x: float32, y: float32, down: bool,
nav: UI_Navigation = .{}) -> bool {
    options: [3] string = .["Low", "Medium", "High"];
    theme := UI_THEME_DARK;
    ui_set_pointer(ctx, x, y, down);
    ui_set_navigation(ctx, nav);
    ui_begin(ctx, 1.0 / 60);
    changed := ui_dropdown(ctx, *theme, "quality", options, selected, 160);
    ui_end(ctx);
    return changed;
}

// 元素布局中心（上一帧），olib 的 center_of。
center_of :: (ctx: *UI_Context, id: string) -> (x: float32, y: float32) {
    rect, ok := ui_element_rect(ctx, id);
    if !ok return 0, 0;
    return rect.x + rect.w * 0.5, rect.y + rect.h * 0.5;
}

dropdown_opens_selects_and_closes :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    selected := 0;
    dropdown_frame(*ctx, *selected, -1, -1, false);
    bx, by := center_of(*ctx, "quality");
    dropdown_frame(*ctx, *selected, bx, by, false);
    dropdown_frame(*ctx, *selected, bx, by, true);
    dropdown_frame(*ctx, *selected, bx, by, false);
    expect(state, ctx.dropdown_id == clay.ID("quality").id, "在按钮上松开即展开");
    dropdown_frame(*ctx, *selected, bx, by, false);
    option_id := tprint("%#%", "quality", 2);
    ox, oy := center_of(*ctx, option_id);
    expectf(state, oy > by, "选项浮在按钮下方: % > %", oy, by);
    dropdown_frame(*ctx, *selected, ox, oy, false);
    dropdown_frame(*ctx, *selected, ox, oy, true);
    changed := dropdown_frame(*ctx, *selected, ox, oy, false);
    expect(state, changed && selected == 2 && ctx.dropdown_id == 0, "点选项即选中并关闭");
    // 再打开，点外面关闭且不改值。
    dropdown_frame(*ctx, *selected, bx, by, true);
    dropdown_frame(*ctx, *selected, bx, by, false);
    expect(state, ctx.dropdown_id != 0, "再次展开");
    dropdown_frame(*ctx, *selected, 390, 290, false);
    dropdown_frame(*ctx, *selected, 390, 290, true);
    expect(state, ctx.dropdown_id == 0 && selected == 2, "点外面关闭且不改值");
    dropdown_frame(*ctx, *selected, 390, 290, false);
    // 键盘：焦点在按钮上按确认打开，焦点落到当前项且不被同一次确认选中；cancel 关闭。
    ui_focus(*ctx, "quality");
    dropdown_frame(*ctx, *selected, -1, -1, false, UI_Navigation.{ activate = true });
    expect(state, ctx.dropdown_id != 0 && ctx.focused_id == clay.ID(option_id).id && selected == 2,
    "确认打开并把焦点移到当前项");
    dropdown_frame(*ctx, *selected, -1, -1, false, UI_Navigation.{ next = -1 });
    changed = dropdown_frame(*ctx, *selected, -1, -1, false, UI_Navigation.{ activate = true });
    expect(state, changed && selected == 1 && ctx.dropdown_id == 0, "导航选上一项并关闭");
    dropdown_frame(*ctx, *selected, -1, -1, false, UI_Navigation.{ activate = true });
    dropdown_frame(*ctx, *selected, -1, -1, false, UI_Navigation.{ cancel = true });
    expect(state, ctx.dropdown_id == 0 && selected == 1, "cancel 关闭");
}
//@endregion

//@region 虚拟列表

virtual_frame :: (ctx: *UI_Context, scroll: float32 = 0) -> UI_Virtual_Range {
    ui_set_pointer(ctx, 50, 50, false);
    ui_add_scroll(ctx, 0, scroll);
    ui_begin(ctx, 1.0 / 60);
    r := ui_virtual_range(ctx, "big", 1000, 20, 100, 1);
    clay.UI(ui_scroll_decl(ctx, "big", 100, 200, gap = 0), #code {
        ui_virtual_spacer(r.before);
        if r.last > r.first {
            for _: r.first..r.last - 1 {
                clay.UI(clay.ElementDeclaration.{
                    layout = .{ sizing = .{ width = clay.SizingGrow(), height = clay.SizingFixed(20) } },
                });
            }
        }
        ui_virtual_spacer(r.after);
    });
    ui_end(ctx);
    return r;
}

virtual_list_declares_only_visible_rows :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    r := virtual_frame(*ctx);
    expect(state, range_eq(r, UI_Virtual_Range.{ first = 0, last = 6, before = 0, after = 994 * 20 }),
    "初始只声明可见行");
    virtual_frame(*ctx);
    data := clay.GetScrollContainerData(clay.ID("big"));
    expect(state, data.contentDimensions.height == 1000 * 20, "占位撑满整张列表");
    // 直接把滚动位置放到第 500 行，下一帧只声明附近几行。
    data.scrollPosition.*[1] = -10000;
    r = virtual_frame(*ctx);
    expect(state, range_eq(r, UI_Virtual_Range.{ 499, 506, 499 * 20, 494 * 20 }), "滚动后只声明附近行");
    virtual_frame(*ctx);
    expect(state, clay.GetScrollContainerData(clay.ID("big")).contentDimensions.height == 1000 * 20,
    "占位仍撑满整张列表");
    empty := ui_virtual_range(*ctx, "big", 0, 20, 100);
    expect(state, range_eq(empty, UI_Virtual_Range.{}), "空列表不声明行");
}
//@endregion

//@region 拖放

Drag_Test_Result :: struct {
    clicked, dragging, dropped: bool;
    payload: int;
}

drag_frame :: (ctx: *UI_Context, x: float32, y: float32, down: bool) -> Drag_Test_Result {
    result: Drag_Test_Result;
    ui_set_pointer(ctx, x, y, down);
    ui_begin(ctx, 1.0 / 60);
    clay.UI(ui_row_decl(40), #code {
        state := ui_interact(ctx, "slot-a");
        result.clicked = state.clicked;
        result.dragging = ui_drag_source(ctx, "slot-a", state, 7);
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("slot-a"),
            layout = .{ sizing = .{ width = clay.SizingFixed(50), height = clay.SizingFixed(50) } },
        });
        payload, _, dropped := ui_drop_target(ctx, "slot-b");
        result.dropped = dropped;
        result.payload = payload;
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("slot-b"),
            layout = .{ sizing = .{ width = clay.SizingFixed(50), height = clay.SizingFixed(50) } },
        });
    });
    ui_end(ctx);
    return result;
}

drag_threshold_click_and_drop :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    drag_frame(*ctx, -1, -1, false);
    // 移动不足阈值：仍是点击。
    drag_frame(*ctx, 20, 20, false);
    drag_frame(*ctx, 20, 20, true);
    small := drag_frame(*ctx, 22, 21, true);
    expect(state, !small.dragging, "移动不足阈值不算拖动");
    click := drag_frame(*ctx, 22, 21, false);
    expect(state, click.clicked && !click.dropped, "阈值内松开仍是点击");
    // 拖过阈值到 slot-b（x 90..140）松开：放置，不算点击。
    drag_frame(*ctx, 20, 20, true);
    moved := drag_frame(*ctx, 60, 20, true);
    expect(state, moved.dragging, "超过阈值开始拖动");
    payload, ok := ui_dragging(*ctx);
    expect(state, ok && payload == 7, "拖动中可查载荷");
    drag_frame(*ctx, 110, 25, true);
    drop := drag_frame(*ctx, 110, 25, false);
    expect(state, drop.dropped && drop.payload == 7 && !drop.clicked, "放到目标上不算点击");
    _, ok = ui_dragging(*ctx);
    expect(state, !ok, "松开帧之后拖动结束");
    // 拖到空白处松开：没有放置，也不算点击。
    drag_frame(*ctx, 20, 20, true);
    drag_frame(*ctx, 20, 120, true);
    miss := drag_frame(*ctx, 20, 120, false);
    expect(state, !miss.dropped && !miss.clicked, "空白处松开没有放置");
    // cancel 中途取消拖动。
    drag_frame(*ctx, 20, 20, true);
    drag_frame(*ctx, 60, 20, true);
    ui_set_navigation(*ctx, UI_Navigation.{ cancel = true });
    cancelled := drag_frame(*ctx, 110, 25, true);
    expect(state, !cancelled.dragging, "cancel 取消拖动");
}
//@endregion

//@region 文本输入

text_frame :: (ctx: *UI_Context, buffer: *[..] u8, x: float32, y: float32, down: bool,
edit: UI_Text_Edit = .{}, width: float32 = 240, max_bytes: int = 16) -> UI_Text_Result {
    theme := UI_THEME_DARK;
    ui_set_pointer(ctx, x, y, down);
    ui_set_text_edit(ctx, edit);
    ui_begin(ctx, 1.0 / 60);
    result := ui_text_input(ctx, *theme, "name", buffer, "Name", width, max_bytes);
    ui_end(ctx);
    return result;
}

text_input_edits_utf8_and_reports_ime_area :: (state: *Test_State) {
    font := make_test_font();
    defer dispose_test_font(font);
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    ui_register_font(*ctx, font, null);
    buffer: [..] u8;
    defer array_free(buffer);
    text_frame(*ctx, *buffer, -1, -1, false);
    expect(state, !ui_text_editing(*ctx), "未点击前不在编辑");
    rect, found := ui_element_rect(*ctx, "name");
    expect(state, found, "输入框有布局矩形");
    cy := rect.y + rect.h * 0.5;
    // 按下即获得焦点；之后输入的控制字符被丢弃。
    text_frame(*ctx, *buffer, rect.x + 20, cy, true);
    r := text_frame(*ctx, *buffer, rect.x + 20, cy, false, UI_Text_Edit.{ text = "AB\n\t" });
    expect(state, ui_text_editing(*ctx) && r.changed && cast(string) buffer == "AB",
    "只有可打印字符进入缓冲");
    expect(state, ctx.text.caret == 2, "光标跟在插入文字之后");
    expect(state, ui_input_capture(*ctx).keyboard, "编辑中捕获键盘");
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ left = true });
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ text = "中" });
    expect(state, cast(string) buffer == "A中B", "在中间插入多字节字符");
    expect(state, ctx.text.caret == 4, "光标按字节前进");
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ backspace = true });
    expect(state, cast(string) buffer == "AB" && ctx.text.caret == 1, "退格删掉整个字符");
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ home = true });
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ delete = true });
    expect(state, cast(string) buffer == "B" && ctx.text.caret == 0, "Delete 删掉光标后的字符");
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ end = true, paste = "AAAAAAAAAAAAAAAAAAAA" });
    expectf(state, buffer.count == 16 && ctx.text.caret == 16, "粘贴停在 max_bytes: %", buffer.count);
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ backspace = true, text = "中" });
    expectf(state, buffer.count == 15, "放不下的多字节字符不截半个: %", buffer.count);
    r = text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ submit = true });
    expect(state, r.submitted && !r.changed, "Enter 只提交不改内容");
    // 点击定位：字体缩放 16/32，A 前进 9 像素；点在第 1 个字之后附近。
    buffer.count = 0;
    array_add(*buffer, 65); // 'A'
    array_add(*buffer, 66); // 'B'
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ end = true });
    text_frame(*ctx, *buffer, rect.x + cast(float32) UI_THEME_DARK.padding + 10, cy, true);
    expectf(state, ctx.text.caret == 1, "点击落在第 1 个字之后: %", ctx.text.caret);
    text_frame(*ctx, *buffer, -1, -1, false);
    // 输入法区域是光标的渲染目标像素矩形，含视口原点与缩放。
    ui_set_viewport(*ctx, F.Rect.{ 100, 50, 800, 600 }, 2);
    text_frame(*ctx, *buffer, -1, -1, false);
    text_frame(*ctx, *buffer, -1, -1, false);
    area, area_ok := ui_text_input_area(*ctx);
    scaled, _ := ui_element_rect(*ctx, "name");
    pad := cast(float32) UI_THEME_DARK.padding;
    expect(state, area_ok, "编辑中报告输入法区域");
    expectf(state, area.x == 100 + (scaled.x + pad + 9) * 2 && area.y == 50 + (scaled.y + pad) * 2 &&
    area.w == 4 && area.h == 36,
    "区域是光标的渲染目标像素矩形: % % % %", area.x, area.y, area.w, area.h);
    // Escape 结束编辑；下一帧不再报告编辑。
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ cancel = true });
    expect(state, !ui_text_editing(*ctx) && ctx.focused_id == 0, "Escape 结束编辑并清焦点");
}

text_input_scrolls_long_text_to_follow_caret :: (state: *Test_State) {
    font := make_test_font();
    defer dispose_test_font(font);
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    ui_register_font(*ctx, font, null);
    buffer: [..] u8;
    defer array_free(buffer);
    ui_focus(*ctx, "name");
    // 宽 60、内边距 10：可见 40 像素；20 个 A 宽 180。
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ text = "AAAAAAAAAAAAAAAAAAAA" }, 60, 64);
    expectf(state, near(ctx.text.scroll, 180 - 40 + 2), "水平滚动跟随光标: %", ctx.text.scroll);
    text_frame(*ctx, *buffer, -1, -1, false, UI_Text_Edit.{ home = true }, 60, 64);
    expectf(state, ctx.text.scroll == 0, "光标回到行首时滚回原点: %", ctx.text.scroll);
}
//@endregion

//@region 焦点框样式

color_eq :: (a: F.Color, b: F.Color) -> bool {
    return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
}

focus_ring_frame :: (ctx: *UI_Context, theme: *UI_Theme, x: float32, y: float32, down: bool,
widget: UI_Widget_Options = .{}) {
    ui_set_pointer(ctx, x, y, down);
    ui_begin(ctx, 1.0 / 60);
    clay.UI(clay.ElementDeclaration.{ layout = .{ padding = clay.PaddingAll(20) } }, #code {
        _ = ui_button(ctx, theme, "ring", "", widget);
    });
    ui_translate_into(ctx, ui_end(ctx), *ctx.ops);
}

// 焦点框的四条边：与按钮底色不同的颜色、紧跟按钮之后的 op。
ring_ops :: (ctx: *UI_Context, color: F.Color) -> (count: int, x0: float32, y0: float32,
x1: float32, y1: float32) {
    x0 = 1e9;
    y0 = 1e9;
    x1 = -1e9;
    y1 = -1e9;
    for op: ctx.ops {
        if !color_eq(op.color, color) || op.texture != null continue;
        count += 1;
        x0 = min(x0, op.x0);
        y0 = min(y0, op.y0);
        x1 = max(x1, op.x1);
        y1 = max(y1, op.y1);
    }
}

focus_ring_follows_theme_style :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    theme := UI_THEME_DARK;
    red := F.Color.{ 255, 0, 0, 255 };
    theme.focus = UI_Focus_Style.{ color = red, width = 3, offset = 4 };
    focus_ring_frame(*ctx, *theme, -1, -1, false);
    n, _, _, _, _ := ring_ops(*ctx, red);
    expect(state, n == 0, "没焦点不画焦点框");
    ui_focus(*ctx, "ring");
    focus_ring_frame(*ctx, *theme, -1, -1, false);
    rect, _ := ui_element_rect(*ctx, "ring");
    x0, y0, x1, y1: float32;
    n, x0, y0, x1, y1 = ring_ops(*ctx, red);
    expect(state, n == 4, "四边描边");
    expectf(state, x0 == rect.x - 4 && y0 == rect.y - 4 &&
    x1 == rect.x + rect.w + 4 && y1 == rect.y + rect.h + 4,
    "焦点框按 offset 外扩且不动布局: % % % %", x0, y0, x1, y1);
    expect(state, color_eq(ctx.ops[ctx.ops.count - 1].color, red), "焦点框画在焦点控件之后");
    // 九宫格贴图代替描边。
    tex := fake_texture(12, 12);
    defer free(tex);
    theme.focus = UI_Focus_Style.{
        image = F.subtexture_make(tex, F.Rect.{ 0, 0, 12, 12 }, F.Rect.{ 0, 0, 12, 12 }),
        image_source_border = 4,
        image_border = 6,
    };
    focus_ring_frame(*ctx, *theme, -1, -1, false);
    images := 0;
    for op: ctx.ops if op.texture == tex images += 1;
    expectf(state, images == 9, "贴图焦点框铺成九宫格: %", images);
    // hidden、no_focus_ring 与只在键盘焦点显示。
    theme.focus = UI_Focus_Style.{ color = red, hidden = true };
    focus_ring_frame(*ctx, *theme, -1, -1, false);
    n, _, _, _, _ = ring_ops(*ctx, red);
    expect(state, n == 0, "hidden 不画");
    theme.focus = UI_Focus_Style.{ color = red };
    focus_ring_frame(*ctx, *theme, -1, -1, false, UI_Widget_Options.{ no_focus_ring = true });
    n, _, _, _, _ = ring_ops(*ctx, red);
    expect(state, n == 0, "no_focus_ring 不画");
    theme.focus = UI_Focus_Style.{ color = red, keyboard_only = true };
    focus_ring_frame(*ctx, *theme, -1, -1, false);
    n, _, _, _, _ = ring_ops(*ctx, red);
    expect(state, n == 4, "keyboard_only 对 ui_focus 的焦点仍画");
    cx := rect.x + rect.w * 0.5;
    cy := rect.y + rect.h * 0.5;
    focus_ring_frame(*ctx, *theme, cx, cy, false);
    focus_ring_frame(*ctx, *theme, cx, cy, true);
    focus_ring_frame(*ctx, *theme, cx, cy, false);
    n, _, _, _, _ = ring_ops(*ctx, red);
    expect(state, ctx.focused_id == clay.ID("ring").id && n == 0,
    "鼠标点击获得焦点不画 keyboard_only 框");
}

focus_ring_text_frame :: (ctx: *UI_Context, theme: *UI_Theme, buffer: *[..] u8) {
    ui_begin(ctx, 1.0 / 60);
    clay.UI(clay.ElementDeclaration.{ layout = .{ padding = clay.PaddingAll(20) } }, #code {
        _ = ui_text_input(ctx, theme, "name", buffer);
    });
    ui_translate_into(ctx, ui_end(ctx), *ctx.ops);
}

focus_ring_on_clipped_text_input_is_outside_its_own_clip :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 400, 300), "ui_init");
    defer ui_dispose(*ctx);
    theme := UI_THEME_DARK;
    red := F.Color.{ 255, 0, 0, 255 };
    theme.focus = UI_Focus_Style.{ color = red, offset = 3 };
    buffer: [..] u8;
    defer array_free(buffer);
    ui_focus(*ctx, "name");
    for _: 0..1 focus_ring_text_frame(*ctx, *theme, *buffer);
    depth, ring := 0, 0;
    for op: ctx.ops {
        if op.kind == .Scissor_Start depth += 1;
        if op.kind == .Scissor_End depth -= 1;
        if op.kind == .Quad && color_eq(op.color, red) {
            ring += 1;
            expect(state, depth == 0, "焦点框不在文本框自己的裁剪内");
        }
    }
    expect(state, ring == 4, "文本框焦点框仍是四边");
}
//@endregion

//@region 状态驱动动效

MOTION_TEST :: UI_Motion.{ time = 0.2 };

motion_test_frame :: (ctx: *UI_Context, target: UI_Visual, declare := true) -> UI_Visual {
    ui_begin(ctx, 1.0 / 60);
    value: UI_Visual;
    if declare value = ui_motion(ctx, "motion", target, MOTION_TEST);
    ui_end(ctx);
    return value;
}

motion_follows_target_and_keeps_velocity_when_interrupted :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    rest := UI_VISUAL_DEFAULT;
    lift := UI_VISUAL_DEFAULT;
    lift.offset = F.Vector2.{ 0, -20 };
    first := motion_test_frame(*ctx, rest);
    expect(state, visual_eq(first, rest), "首次声明直接取目标");
    found, stored := table_find(*ctx.visuals, clay.ID("motion").id);
    expect(state, found && visual_eq(stored, rest), "视觉表里就是目标值");
    value := motion_test_frame(*ctx, lift);
    expectf(state, value.offset.y < 0 && value.offset.y > -20, "第一帧开始上升: %", value.offset.y);
    value = motion_test_frame(*ctx, lift); // 第二帧：仍在加速上升
    _, velocity, has_state := ui_motion_state(*ctx, "motion");
    expect(state, has_state && velocity.offset.y < 0, "第二帧速度朝目标");
    // 中途改回：保留向上的速度，下一帧仍继续向上一点，不跳变。
    before := value.offset.y;
    value = motion_test_frame(*ctx, rest);
    expectf(state, value.offset.y <= before && before - value.offset.y < 5,
    "中断时保留速度不跳变: % -> %", before, value.offset.y);
    for _: 0..59 value = motion_test_frame(*ctx, rest);
    expectf(state, fabs(value.offset.y) < 0.01, "最终回到目标: %", value.offset.y);
}

motion_kick_springs_back_and_undeclared_state_is_dropped :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    rest := UI_VISUAL_DEFAULT;
    ui_motion_kick(*ctx, "motion", UI_Visual.{ scale = .{ -2, -2 } }); // 尚无状态：忽略
    motion_test_frame(*ctx, rest);
    ui_motion_kick(*ctx, "motion", UI_Visual.{ scale = .{ -2, -2 } });
    value := motion_test_frame(*ctx, rest);
    expectf(state, value.scale.x < 1, "冲击先缩小: %", value.scale.x);
    for _: 0..59 value = motion_test_frame(*ctx, rest);
    expectf(state, fabs(value.scale.x - 1) < 0.001, "弹簧回到 1: %", value.scale.x);
    motion_test_frame(*ctx, rest, false);
    _, _, has_state := ui_motion_state(*ctx, "motion");
    expect(state, !has_state, "一帧不声明就丢掉状态");
    fresh := motion_test_frame(*ctx, rest);
    expect(state, visual_eq(fresh, rest), "重新出现仍从目标开始");
}

presence_test_frame :: (ctx: *UI_Context, open: bool) -> (alive: bool, progress: float32,
state: UI_Interaction) {
    ui_begin(ctx, 1.0 / 60);
    alive, progress = ui_presence(ctx, "popup", open, MOTION_TEST, MOTION_TEST);
    if alive {
        state = ui_interact(ctx, "popup-button");
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("popup"),
            layout = .{
                sizing = .{ width = clay.SizingFixed(100), height = clay.SizingFixed(60) },
                padding = clay.PaddingAll(10),
            },
        }, #code {
            clay.UI(clay.ElementDeclaration.{
                id = clay.ID("popup-button"),
                layout = .{ sizing = .{ width = clay.SizingFixed(40), height = clay.SizingFixed(20) } },
            });
        });
    }
    ui_end(ctx);
}

presence_progress_and_exit_isolates_input :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 800, 600), "ui_init");
    defer ui_dispose(*ctx);
    ui_set_pointer(*ctx, 20, 20, false);
    alive, progress, widget := presence_test_frame(*ctx, false);
    expect(state, !alive && progress == 0, "从未打开就没什么可声明");
    alive, progress, widget = presence_test_frame(*ctx, true);
    expectf(state, alive && progress > 0 && progress < 1, "入场从 0 开始: %", progress);
    for _: 0..29 alive, progress, widget = presence_test_frame(*ctx, true);
    expectf(state, progress > 0.99, "入场完成: %", progress);
    expect(state, widget.hovered, "展开的浮层接受指针");
    expect(state, ctx.previous_widgets.count == 1, "只有浮层内的控件参与导航");
    alive, progress, _ = presence_test_frame(*ctx, false);
    expect(state, alive && progress < 1, "退场第一帧仍在");
    alive, _, widget = presence_test_frame(*ctx, false);
    expect(state, alive, "退场中仍继续声明");
    // ui_interact 与 clay.PointerOver 全走 kit 装的命中回调（ui_visual_hit，它跳过 inert 子树），
    // 所以两者都必须拒绝退场子树。
    expect(state, !widget.hovered, "退场子树不再接受 ui_interact 命中");
    expect(state, !clay.PointerOver(clay.ID("popup-button")), "退场子树不在命中链里");
    expect(state, ctx.previous_widgets.count == 0, "退场子树被导航跳过");
    expect(state, !ctx.input.pointer, "退场子树不消费指针");
    frames := 0;
    while alive && frames < 120 {
        alive, progress, _ = presence_test_frame(*ctx, false);
        frames += 1;
    }
    expect(state, !alive && progress == 0, "退场结束");
    // 重新打开从 0 开始入场，且可以交互。
    alive, progress, _ = presence_test_frame(*ctx, true);
    expectf(state, alive && progress < 0.5, "重新打开从 0 开始入场: %", progress);
    alive, progress, widget = presence_test_frame(*ctx, true);
    expect(state, widget.hovered, "重新打开后又可交互");
}
//@endregion

//@region 翻译层字段 / 操作流插入

ui_translate_translates_command_fields :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 200, 100), "ui_init");
    defer ui_dispose(*ctx);
    commands: [4] clay.RenderCommand;
    commands[0] = rect_command(clay.ID("a").id, 10, 20, 30, 40, .[1.0, 0.5, 0.25, 1.0], 6);
    // 描边：四边宽度不同，各出一条 op。clay 0.14 的 BorderRenderData 是一个 color
    // 加一份 BorderWidth（left/right/top/bottom/betweenChildren）。
    commands[1] = clay.RenderCommand.{
        commandType = .BORDER,
        boundingBox = bbox(0, 0, 100, 50),
        renderData = .{ border = .{
            color = .[1, 0, 0, 1],
            width = .{ left = 2, right = 3, top = 4, bottom = 5 },
        } },
    };
    commands[2] = clay.RenderCommand.{
        commandType = .SCISSOR_START,
        boundingBox = bbox(5, 6, 70, 80),
        id = clay.ID("clip").id,
    };
    commands[3] = clay.RenderCommand.{ commandType = .SCISSOR_END, id = clay.ID("clip").id };
    ops := translate_commands(*ctx, commands);
    defer array_free(ops);
    expectf(state, ops.count == 7, "矩形 1 + 描边 4 + 裁剪 2: %", ops.count);
    expect(state, ops[0].kind == .Quad && ops[0].x0 == 10 && ops[0].y0 == 20 &&
    ops[0].x1 == 40 && ops[0].y1 == 60, "矩形坐标取自 boundingBox");
    expect(state, color_eq(ops[0].color, F.Color.{ 255, 128, 64, 255 }), "颜色换算且预乘 alpha");
    expect(state, ops[0].radius == 6 && ops[0].texture == null, "圆角与纯色标记");
    // 四边顺序：上、下、左、右。
    expect(state, ops[1].x0 == 0 && ops[1].y0 == 0 && ops[1].x1 == 100 && ops[1].y1 == 4, "上边");
    // 0.14 的 BorderRenderData 只有一个 color，四边天然同色。
    expect(state, color_eq(ops[1].color, F.Color.{ 255, 0, 0, 255 }), "四边共用同一个颜色");
    expect(state, ops[2].y0 == 45 && ops[2].y1 == 50, "下边");
    expect(state, ops[3].x0 == 0 && ops[3].x1 == 2 && ops[3].y1 == 50, "左边");
    expect(state, ops[4].x0 == 97 && ops[4].x1 == 100, "右边");
    expect(state, ops[5].kind == .Scissor_Start && ops[5].clip_x == 5 && ops[5].clip_y == 6 &&
    ops[5].clip_w == 70 && ops[5].clip_h == 80, "裁剪起点取 boundingBox");
    expect(state, ops[6].kind == .Scissor_End, "裁剪终点");
    // ui_translate_into 复用输出容量，不清空调用方数组以外的状态。
    array := clay.ClayArray(clay.RenderCommand).{
        capacity = cast(s32) commands.count,
        length = cast(s32) commands.count,
        internalArray = commands.data,
    };
    reuse: [..] UI_Op;
    defer array_free(reuse);
    ui_translate_into(*ctx, array, *reuse);
    storage := reuse.data;
    ui_translate_into(*ctx, array, *reuse);
    expect(state, reuse.count == 7 && reuse.data == storage, "重复翻译复用容量");
}

ui_ops_insert_splices_in_the_middle :: (state: *Test_State) {
    ops: [..] UI_Op;
    defer array_free(ops);
    white := F.Color.{ 255, 255, 255, 255 };
    for i: 0..4 array_add(*ops, quad(cast(float32) i, 0, 1, 1, white));
    pair: [2] UI_Op;
    pair[0] = quad(100, 0, 1, 1, white);
    pair[1] = quad(101, 0, 1, 1, white);
    ui_ops_insert(*ops, 2, pair);
    expectf(state, ops.count == 7, "中间插入后长度: %", ops.count);
    expect(state, ops[2].x0 == 100 && ops[3].x0 == 101, "插入到指定位置");
    expect(state, ops[1].x0 == 1 && ops[4].x0 == 2, "前后元素保持顺序");
    expect(state, ops[0].x0 == 0 && ops[6].x0 == 4, "两端不受影响");
    one: [1] UI_Op;
    one[0] = quad(200, 0, 1, 1, white);
    ui_ops_insert(*ops, -5, one);
    expect(state, ops[0].x0 == 200 && ops.count == 8, "负数下标插到最前");
    ui_ops_insert(*ops, 999, one);
    expect(state, ops[ops.count - 1].x0 == 200 && ops.count == 9, "超出长度插到最后");
    empty: [] UI_Op;
    ui_ops_insert(*ops, 0, empty);
    expect(state, ops.count == 9, "空插入不改长度");
}

// 焦点框插在焦点元素自己的最后一条 op 之后、后续兄弟之前（焦点元素带描边 + 子块）。
focus_ring_insert_position_between_siblings :: (state: *Test_State) {
    ctx: UI_Context;
    expect(state, ui_init(*ctx, 200, 100), "ui_init");
    defer ui_dispose(*ctx);
    theme := UI_THEME_DARK;
    red := F.Color.{ 255, 0, 0, 255 };
    cyan := F.Color.{ 0, 255, 255, 255 };
    magenta := F.Color.{ 255, 0, 255, 255 };
    theme.focus = UI_Focus_Style.{ color = red, width = 2 };
    ui_focus(*ctx, "first");
    ui_begin(*ctx, 1.0 / 60);
    ctxp := *ctx; // #code 里看到的是调用方名字，不是宏里的 ctx
    themep := *theme;
    clay.UI(ui_row_decl(0), #code {
        // 自定义控件：ui_interact 之后自己登记焦点框样式，否则沿用零值（无色）。
        ring_state := ui_interact(ctxp, "first");
        ui_focus_style(ctxp, themep, ring_state);
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("first"),
            layout = .{ sizing = .{ width = clay.SizingFixed(50), height = clay.SizingFixed(50) } },
            backgroundColor = .[1, 1, 1, 1],
            border = .{ color = .[0, 0, 0, 1],
            width = .{ left = 1, right = 1, top = 1, bottom = 1 } },
        }, #code {
            clay.UI(clay.ElementDeclaration.{
                id = clay.ID("first-child"),
                layout = .{ sizing = .{ width = clay.SizingFixed(10), height = clay.SizingFixed(10) } },
                backgroundColor = .[0, 1, 1, 1],
            });
        });
        clay.UI(clay.ElementDeclaration.{
            id = clay.ID("second"),
            layout = .{ sizing = .{ width = clay.SizingFixed(50), height = clay.SizingFixed(50) } },
            backgroundColor = .[1, 0, 1, 1],
        });
    });
    ui_translate_into(*ctx, ui_end(*ctx), *ctx.ops);
    ops := ctx.ops;
    first_red := -1;
    ring := 0;
    for op, i: ops {
        if !color_eq(op.color, red) continue;
        if first_red < 0 first_red = i;
        ring += 1;
    }
    expectf(state, ring == 4 && first_red > 0, "焦点框是四条连续的边: % 起点 %", ring, first_red);
    expectf(state, first_red + 4 == ops.count - 1, "焦点框紧跟在焦点元素之后、兄弟之前: % / %",
    first_red, ops.count);
    expect(state, color_eq(ops[ops.count - 1].color, magenta), "兄弟元素排在焦点框之后");
    expect(state, color_eq(ops[0].color, F.Color.{ 255, 255, 255, 255 }), "焦点元素底色在最前");
    // 焦点元素的子内容与描边也排在焦点框之前。
    child_before, ring_after_child := false, true;
    for op, i: ops {
        if color_eq(op.color, cyan) && i < first_red child_before = true;
        if color_eq(op.color, cyan) && i > first_red + 3 ring_after_child = false;
    }
    expect(state, child_before && ring_after_child, "焦点框画在焦点元素的子内容之后");
    expect(state, ctx.focused_id == clay.ID("first").id, "焦点没有被兄弟抢走");
}

ui_visual_lerp_interpolates_every_field :: (state: *Test_State) {
    a := UI_Visual.{ offset = .{ 0, -20 }, scale = .{ 1, 1 }, rotation = 0, pivot = .{ 0.5, 0.5 }, opacity = 1 };
    b := UI_Visual.{ offset = .{ 10, 20 }, scale = .{ 2, 3 }, rotation = PI_F / 2, pivot = .{ 0, 1 }, opacity = 0 };
    expect(state, visual_eq(ui_visual_lerp(a, b, 0), a), "t=0 等于起点");
    expect(state, visual_eq(ui_visual_lerp(a, b, 1), b), "t=1 等于终点");
    mid := ui_visual_lerp(a, b, 0.5);
    expect(state, mid.offset.x == 5 && mid.offset.y == 0, "offset 线性插值");
    expect(state, mid.scale.x == 1.5 && mid.scale.y == 2, "scale 线性插值");
    expectf(state, near(mid.rotation, PI_F / 4), "rotation 线性插值: %", mid.rotation);
    expect(state, mid.pivot.x == 0.25 && mid.pivot.y == 0.75, "pivot 线性插值");
    expect(state, mid.opacity == 0.5, "opacity 线性插值");
    // t 超出 0..1 不钳制：弹性曲线靠它做过冲。
    over := ui_visual_lerp(a, b, 1.5);
    expect(state, over.offset.x == 15 && over.opacity == -0.5, "t>1 不钳制");
    under := ui_visual_lerp(a, b, -0.5);
    expect(state, under.offset.x == -5 && under.opacity == 1.5, "t<0 不钳制");
}

utf8_scan_and_buffer_splicing :: (state: *Test_State) {
    // 1/2/3/4 字节字符的往返编解码。
    codes: [5] u32 = .[65, 0x00E9, 0x4E2D, 0x20AC, 0x1F600];
    sizes: [5] int = .[1, 2, 3, 3, 4];
    bytes: [4] u8;
    buf: [..] u8;
    defer array_free(buf);
    for code, i: codes {
        n := ui_utf8_encode(*bytes, code);
        expectf(state, n == sizes[i], "第 % 个字符的编码长度: %", i, n);
        for j: 0..n - 1 array_add(*buf, bytes[j]);
    }
    expectf(state, buf.count == 13, "编码后总字节数: %", buf.count);
    text := cast(string) buf;
    rest := text;
    total := 0;
    for code, i: codes {
        got, n := ui_utf8_next(*rest);
        expectf(state, got == code && n == sizes[i], "解码第 % 个字符", i);
        total += n;
    }
    expect(state, total == buf.count && rest.count == 0, "整串解码到底");
    // 回退总落在字符边界上。
    pos := buf.count;
    for i: codes.count - 1..0 {
        if i < 0 break;
        pos = ui_utf8_prev(text, pos);
        expectf(state, pos == total - sizes[i], "第 % 个字符的起点: %", i, pos);
        total -= sizes[i];
    }
    expect(state, ui_utf8_prev(text, 0) == 0 && ui_utf8_prev(text, -3) == 0, "回退到 0 就停");
    // 缓冲拼接：中间插入/删除保持尾部字节。
    b2: [..] u8;
    defer array_free(b2);
    hello: [5] u8 = .[104, 101, 108, 108, 111]; // "hello"
    ui_buffer_insert(*b2, 0, hello);
    expect(state, cast(string) b2 == "hello", "整段插入");
    cjk: [3] u8 = .[0xE4, 0xB8, 0xAD]; // "中"
    ui_buffer_insert(*b2, 2, cjk);
    expect(state, cast(string) b2 == "he中llo", "中间插入多字节字符");
    ui_buffer_remove(*b2, 2, 5);
    expect(state, cast(string) b2 == "hello", "删除多字节字符");
    ui_buffer_insert(*b2, 99, hello);
    expect(state, cast(string) b2 == "hellohello", "越界插入追加到末尾");
    ui_buffer_insert(*b2, -4, cjk);
    expect(state, cast(string) b2 == "中hellohello", "负数下标插到最前");
    ui_buffer_remove(*b2, -3, 99);
    expectf(state, b2.count == 0, "越界删除清空: %", b2.count);
    // 前缀/后缀按字节切，越界钳制。
    expect(state, ui_str_prefix(text, 3) == "Aé", "前缀按字节切");
    expect(state, ui_str_suffix(text, 3) == "中€😀", "后缀按字节切");
    expect(state, ui_str_prefix(text, 999).count == text.count, "前缀越界钳到整串");
    expect(state, ui_str_prefix(text, -1).count == 0 && ui_str_suffix(text, -1).count == text.count,
    "越界钳制到两端");
}
//@endregion

// Loop scopes adapted.
