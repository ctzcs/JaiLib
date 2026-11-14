// ui —— clay 布局引擎的 jfoster 集成 + 控件/主题层。
//
// 分层（自底向上，与 olib kit/ui 一一对位）：
//   ui.jai          UI_Context：clay 初始化/帧流程（指针/滚动/输入边沿）、字体表
//   ui_text.jai     msdf 字体测量（clay 回调）、字形四边形生成、Font 位图烘焙
//   ui_backend.jai  clay RenderCommand -> UI_Op 翻译（CPU 可测）+ Render2D 发射
//   ui_visual.jai   子树视觉变换 / Tween 插值 / 命中反算 / 按 ID 的状态驱动动效
//   ui_input.jai    鼠标捕获 / 导航焦点与自动滚动 / 禁用态 / 模态 / 输入消费
//   ui_widgets.jai  主题、基础控件、图像、滑条、进度和容器
//   ui_controls.jai 下拉框 / 虚拟列表 / 拖放
//   ui_text_input.jai 单行文本输入 / 输入法候选框位置
//
// 公开过程/结构体/字段名、参数顺序、返回语义与 olib 一致，clay 侧用的也是同一套 0.14
// 声明 API（thirdparty/clay/module.jai 是 clay v0.14 的纯 Jai 移植）：元素一律写成
//
//   clay.UI(clay.ElementDeclaration.{ ... }, #code { 子内容 });
//   clay.UI(clay.ElementDeclaration.{ ... });                      // 无子内容
//   clay.ElementDeclaration.{ ... }                                // 声明完整性由 clay 判（presence 见下）
//
// 与 olib 之间只剩下面这些「语言/库形态」差异：
//
//   A. 声明辅助：olib 的 `if clay.UI()(decl) { … }` → `clay.UI(decl, #code { … })`（宏，#expand）。
//      返回 clay.ElementDeclaration 的 *decl 辅助过程（ui_row_decl / ui_panel_decl / ui_scroll_decl /
//      ui_modal_decl / ui_image_decl / ui_nine_slice_decl）名字与参数不变。
//      0.14 的 ElementDeclaration 没有 has_* 标志，presence 全由字段值决定（与 olib 一致）：
//      backgroundColor[3] > 0、cornerRadius != 0、border.width != 0、clip.horizontal/vertical、
//      floating.attachTo != .NONE、image.imageData != null、custom.customData != null。
//   B. 视觉变换树直接取 clay.GetLayoutElementInfo（EndLayout 之后整棵元素树带 parentId/clipId/
//      包围盒），不再需要声明期自己的 UI_Element_Info 记录。
//   C. 命中测试用 clay.SetPointerHitTestFunction 装自己的回调（ui_visual.jai 的「命中测试」区）：
//      clay 的 PointerOver / 滚动优先级 / 悬停回调全部走这条回调，于是交互判定一律用
//      clay.PointerOver(clay.ID(id))，与 olib 逐字一致，而且跟随 ui_set_visual 的变换。
//   D. 裁剪/滚动用 ClipElementConfig（olib 一样）：ui_scroll_decl 返回 clip = {vertical, horizontal,
//      childOffset}；childOffset 是每帧声明时写入的滚动位置（clay 的布局按它偏移子元素），
//      ui_end/UI_Scroll_Entry 只负责把上一帧读到的 scrollPosition 回灌。
//   E. foster（值类型 + .Resource）→ jfoster（堆对象 + .handle）：
//      Texture 为 *F.Texture、MsdfFont → *F.Msdf_Font、Vec2 → F.Vector2、Color 通道为小写 r/g/b/a、
//      Matrix3x2 字段为 m11..m32、Subtexture.Texture → Subtexture.Tex。
//   F. Odin 的 map / [dynamic]T → Table / [..]T（Table 作形参要传指针：table_find(*t, k)，
//      增删用 table_set / table_remove，清空用 table_reset）。
//   G. 没有 allocator 参数：Jai 的堆分配走默认分配器，ui_init 不再收 allocator（其余签名不变）。
//   H. 内置图标/图集烘焙用 jfoster 的 Font（stb_truetype）重写：ui_font_bake 返回 *F.Msdf_Font。
//
// 导入说明（#load 进来的文件共享 module.jai 这一层的名字，各文件里不再 #import）：
//   Basic —— alloc / free / memcpy / memset / array_add / array_free / array_resize / New /
//            tprint / clamp / max / min / abs / floor / ceil
//   STRING —— String：compare / trim / join ...
//   JM —— Math：sqrt / cos / sin / floor / PI
//   UNI —— Unicode：utf8_next_character
//   F —— jfoster：Texture / Msdf_Font / Font / Image / Color / Vector2 / Matrix3x2 / Rect / Rect_Int
//   r2d —— kit/rendering/2d：Render2D + push_* / quad_texture / rect
//   mat —— kit/rendering/material：Material / Material_Library / material_create / material_set_number
//   tw —— core/tween：spring
//   clay —— thirdparty/clay/module（clay v0.14 纯 Jai 移植）

UI_TEXT_CONFIG_CAP :: 1024;
//@region 类型

UI_Context :: struct {
    arena_memory: [] u8;
    clay_context: *clay.Context;

    // fontId -> 字体元数据、GPU 纹理、渲染配置，三表平行。
    fonts: [..] *F.Msdf_Font;
    font_textures: [..] *F.Texture;
    font_renderers: [..] UI_Font_Renderer;
    image_pool: [] UI_Image_Data;
    image_len: int;
    ops: [..] UI_Op;
    visuals: Table(u32, UI_Visual);
    visual_elements: Table(u32, UI_Visual_Element);
    // EndLayout 之后 clay 导出的整棵元素树（id / parentId / clipId / boundingBox），
    // 视觉变换与命中回调都读它，见 ui_visual_snapshot。
    visual_layout: [..] clay.LayoutElementInfo;
    motions: Table(u32, UI_Motion_State);
    presences: Table(u32, UI_Presence_State);
    inert: Table(u32, u32); // 本帧退场中的 ID；快照时按子树继承
    delta_time: float32; // ui_begin 传入，动效推进用

    // 帧内 TextElementConfig bump 池：clay 把文本配置存裸指针、EndLayout 才回读，
    // 调用侧栈上 config 会悬垂，必须由 ctx 保活（同 olib）。
    text_config_pool: [] clay.TextElementConfig;
    text_config_len: int;

    // 圆角渲染用的单位圆盘纹理（预乘 alpha），ui_render 首次调用时懒建。
    corner_texture: *F.Texture;
    corner_texture_ok: bool;

    width, height: float32;
    scale: float32;
    viewport_origin: F.Vector2;
    pointer_pixels: F.Vector2;
    active_id, focused_id: u32;
    modal_id, scope_id: u32;
    modal_changed: bool;
    active_seen: bool;
    widgets: [..] UI_Focus_Entry;
    previous_widgets: [..] UI_Focus_Entry;
    scrolls: [..] UI_Scroll_Entry;
    navigation: UI_Navigation;
    focus_scroll: bool; // 焦点由导航或 ui_focus 改变：下一次 begin 把它滚进可见范围
    focus_style: UI_Focus_Style; // 焦点控件所用主题的焦点框样式，见 ui_focus_style
    focus_by_pointer, focus_ring_hidden: bool;
    dropdown_id: u32; // 当前展开的下拉框；同一时间只展开一个
    drag: UI_Drag;
    text_edit: UI_Text_Edit; // 宿主本帧传入的编辑输入，ui_end 清空
    text: UI_Text_State;
    input: UI_Input_Capture;
    pool_overflow: bool;
    error_count: int;
    last_error: clay.ErrorType;

    pointer_x, pointer_y: float32;
    pointer_down: bool;
    pointer_down_prev: bool; // 上一帧状态（点击边沿检测）
    pointer_edges_explicit: bool;
    pointer_pressed, pointer_released: bool; // 调用方收集的边沿，ui_end 消费
    pointer_press_owner: u32; // 显式边沿帧开始时的捕获者，禁止重按转交

    scroll_delta: [2] float32; // 每帧累计，begin 时消费清零
    // clay 的测量/错误/命中回调是 C 调用，Jai 要求显式恢复拥有线程的 context（同 Libs/Engine/text）。
    callback_context: #Context;
}
//@endregion

//@region 生命周期

// clay 的回调 userData 是 *void；这里直接放 UI_Context 指针（0.14 移植没有 u64 中间层）。
ui_context_of :: (user: *void) -> *UI_Context #no_context {
    return cast(*UI_Context) user;
}

// clay.MinMemorySize() 依赖「当前 context」：没有 context 时按默认的
// maxMeasureTextCacheWordCount（= 2 * maxElementCount）估算，有 context 时改用它的
// maxElementCount（少算一半词缓存）；而 Clay_Initialize 又会从上一个 context 继承
// maxMeasureTextCacheWordCount。于是同一进程里的**第二个** context 拿到的 arena 比实际
// 需求少 8192*20 字节，布局时越界写坏堆——表现为第二个窗口/第二份 UI 首次 EndLayout
// 直接段错误。这里取两种估算里较大的一个，再留 1/4 余量，与 clay 自己的继承逻辑无关。
ui_arena_capacity :: () -> u32 {
    previous := clay.GetCurrentContext();
    if previous != null clay.SetCurrentContext(null);
    base := clay.MinMemorySize();
    if previous != null {
        clay.SetCurrentContext(previous);
        inherited := clay.MinMemorySize();
        if inherited > base base = inherited;
    }
    return base + base / 4;
}

// 初始化 clay（arena 容量见 ui_arena_capacity）。可多次 init 同一 ctx。
ui_init :: (ctx: *UI_Context, width: float32, height: float32) -> bool {
    if ctx.clay_context != null ui_dispose(ctx);
    ctx.* = UI_Context.{
        width = width,
        height = height,
        scale = 1,
        callback_context = context,
        focus_style = UI_Focus_Style.{ color = UI_THEME_DARK.accent, width = 2 },
    };

    capacity := ui_arena_capacity();
    memory := NewArray(cast(s64) capacity, u8, true);
    if memory.data == null return false;
    ctx.arena_memory = memory;

    ctx.text_config_pool = NewArray(UI_TEXT_CONFIG_CAP, clay.TextElementConfig, true);
    if ctx.text_config_pool.data == null {
        ui_dispose(ctx);
        return false;
    }
    ctx.image_pool = NewArray(UI_TEXT_CONFIG_CAP, UI_Image_Data, true);
    if ctx.image_pool.data == null {
        ui_dispose(ctx);
        return false;
    }

    arena := clay.CreateArenaWithCapacityAndMemory(capacity, memory.data);
    ctx.clay_context = clay.Initialize(arena, .{ width, height }, .{
        handler = ui_error_record,
        userData = cast(*void) ctx,
    });
    clay.SetMeasureTextFunction(ui_measure_trampoline, cast(*void) ctx);
    // 命中测试交给 kit 的变换感知回调（ui_visual.jai 的「命中测试」区），于是 clay 自己的
    // PointerOver / 滚动优先级 / onHover 全都按显示变换判定。
    clay.SetPointerHitTestFunction(ui_visual_hit, cast(*void) ctx);
    return true;
}

ui_dispose :: (ctx: *UI_Context) {
    // context 活在 arena 里；先断开 clay 全局指针，避免下一个
    // Initialize 读到已释放的 oldContext（UB/挂死）
    if ctx.clay_context != null && clay.GetCurrentContext() == ctx.clay_context {
        clay.SetCurrentContext(null);
    }
    if ctx.corner_texture_ok && ctx.corner_texture != null {
        F.texture_dispose(ctx.corner_texture);
        free(ctx.corner_texture);
    }
    ctx.corner_texture = null;
    ctx.corner_texture_ok = false;
    array_free(ctx.fonts);
    array_free(ctx.font_textures);
    // MSDF 字体材质归材质库所有，随 material_library_dispose 释放。
    array_free(ctx.font_renderers);
    array_free(ctx.widgets);
    array_free(ctx.previous_widgets);
    array_free(ctx.scrolls);
    array_free(ctx.ops);
    array_free(ctx.visual_layout);
    deinit(*ctx.visuals);
    deinit(*ctx.visual_elements);
    deinit(*ctx.motions);
    deinit(*ctx.presences);
    deinit(*ctx.inert);
    if ctx.image_pool.data != null free(ctx.image_pool.data);
    if ctx.text_config_pool.data != null free(ctx.text_config_pool.data);
    if ctx.arena_memory.data != null free(ctx.arena_memory.data);
    ctx.* = .{};
}

// 注册字体（fontId 即下标）；texture 为图集的 GPU 纹理（由调用侧上传）。
// 返回 fontId。测量在字体注册前调用会按零宽处理。
// 字体/纹理由调用者持有到 ui_dispose 之后；注册只在帧外进行。
// 默认 Bitmap 保持旧位图图集兼容；真正的多通道 MSDF 图集必须显式传 .MSDF。
ui_register_font :: (ctx: *UI_Context, font: *F.Msdf_Font, texture: *F.Texture,
                     kind: UI_Font_Kind = .Bitmap) -> int {
    array_add(*ctx.fonts, font);
    array_add(*ctx.font_textures, texture);
    array_add(*ctx.font_renderers, UI_Font_Renderer.{ kind = kind });
    clay.SetCurrentContext(ctx.clay_context);
    clay.ResetMeasureTextCache();
    return ctx.fonts.count - 1;
}
//@endregion

//@region 帧流程 —— 输入 -> begin -> 声明 -> end

ui_set_dimensions :: (ctx: *UI_Context, width: float32, height: float32) {
    ctx.width = width;
    ctx.height = height;
    clay.SetCurrentContext(ctx.clay_context);
    clay.SetLayoutDimensions(.{ width, height });
}

// 更新指针状态（可在帧内多次调用，取最后一次）。down 的上一帧值在
// ui_end 快照——ui_clicked 的边沿依据与是否调用过本 proc 无关。
ui_set_pointer :: (ctx: *UI_Context, x: float32, y: float32, down: bool) {
    ctx.pointer_pixels = .{ x, y };
    ctx.pointer_down = down;
    ctx.pointer_edges_explicit = false;
    ctx.pointer_pressed = false;
    ctx.pointer_released = false;
}

// 在 ui_begin 前提交自上次 UI 帧以来收集的边沿；坐标为渲染目标像素。
// 多次提交合并边沿，位置/down 取最后一次；不是完整事件历史，ui_end 消费清空。
ui_set_pointer_edges :: (ctx: *UI_Context, x: float32, y: float32, down: bool,
                         pressed: bool, released: bool) {
    ctx.pointer_pixels = .{ x, y };
    ctx.pointer_down = down;
    ctx.pointer_edges_explicit = true;
    ctx.pointer_pressed = ctx.pointer_pressed || pressed;
    ctx.pointer_released = ctx.pointer_released || released;
}

ui_add_scroll :: (ctx: *UI_Context, dx: float32, dy: float32) {
    ctx.scroll_delta[0] += dx;
    ctx.scroll_delta[1] += dy;
}

// 帧开始：提交指针/滚动状态并进入布局。delta_time 驱动滚动惯性。
// 一次只允许一个 context 在 begin/end 区间内声明布局，不支持线程并发。
ui_begin :: (ctx: *UI_Context, delta_time: float32) {
    clay.SetCurrentContext(ctx.clay_context);
    clay.SetLayoutDimensions(.{ ctx.width, ctx.height });
    ctx.text_config_len = 0; // 文本配置池按帧重置（池内存跨帧保活，见结构体注释）
    ctx.image_len = 0;
    table_reset(*ctx.visuals);
    table_reset(*ctx.inert);
    ctx.delta_time = delta_time;
    ctx.pool_overflow = false;
    ctx.scope_id = 0;
    ctx.active_seen = false;
    ctx.pointer_press_owner = 0;
    if ctx.pointer_edges_explicit ctx.pointer_press_owner = ctx.active_id;
    // 合并的松开再按下不重放旧拖动；最终仍按住时保留原控件捕获。
    if ctx.pointer_edges_explicit && ctx.pointer_released && ctx.pointer_down {
        ctx.drag = .{};
    }
    ctx.text.seen = false;
    ctx.text.blink += delta_time;
    ctx.focus_ring_hidden = false;
    ctx.input = UI_Input_Capture.{
        pointer = ctx.modal_id != 0 || ctx.active_id != 0,
        keyboard = ctx.modal_id != 0,
    };
    ctx.pointer_x = (ctx.pointer_pixels.x - ctx.viewport_origin.x) / ctx.scale;
    ctx.pointer_y = (ctx.pointer_pixels.y - ctx.viewport_origin.y) / ctx.scale;
    ui_navigation_begin(ctx);
    ui_focus_scroll(ctx);
    // SetPointerState 会用上一帧的布局重算 pointerOverIds（经 kit 的命中回调，见
    // SetPointerHitTestFunction），本帧 ui_interact 读到的悬停状态与 clay 的时序一致。
    clay.SetPointerState(.[ctx.pointer_x, ctx.pointer_y], ctx.pointer_down);
    // 拖动由控件捕获；列表使用滚轮，避免按按钮时同时拖动父滚动区。
    // 模态切换帧的命中仍基于旧布局，禁止滚轮穿过刚打开/关闭的遮罩。
    if !ctx.modal_changed {
        clay.UpdateScrollContainers(false, .[ctx.scroll_delta[0], ctx.scroll_delta[1]], delta_time);
    }
    ctx.modal_changed = false;
    ctx.scroll_delta = .[0, 0];
    // 在 BeginLayout/OpenElement 重建内部元素表之前快照滚动状态，使
    // clay.UI(ui_scroll_decl(...)) 的内联求值安全（声明时把 offset 写回 clip.childOffset）。
    for *scroll: ctx.scrolls {
        data := clay.GetScrollContainerData(.{ id = scroll.id });
        if data.found && data.scrollPosition != null scroll.offset = data.scrollPosition.*;
        else scroll.offset = .[0, 0];
        scroll.seen = false;
    }
    clay.BeginLayout();
}

// 从帧内池取一个存活的 TextElementConfig 指针。池满返回 null。
ui_text_config :: (ctx: *UI_Context, config: clay.TextElementConfig) -> *clay.TextElementConfig {
    if ctx.text_config_len >= ctx.text_config_pool.count {
        ctx.pool_overflow = true;
        return null;
    }
    ptr := *ctx.text_config_pool[ctx.text_config_len];
    ctx.text_config_len += 1;
    ptr.* = config;
    return ptr;
}

// 帧结束：返回 clay 的渲染命令数组（送 ui_translate / ui_render）。
// 同时快照本帧的按住状态，作为下一帧 ui_clicked 的边沿依据。
ui_end :: (ctx: *UI_Context) -> clay.ClayArray(clay.RenderCommand) {
    // 视觉变换可能把布局外元素移入视口，不能先按原布局剔除。
    culling_disabled := ctx.clay_context.disableCulling;
    if ctx.visuals.count > 0 clay.SetCullingEnabled(false);
    commands := clay.EndLayout();
    clay.SetCullingEnabled(!culling_disabled);
    ui_visual_snapshot(ctx); // 视觉树 + 命中回调的数据源；必须在 EndLayout 之后
    ui_motion_end(ctx);
    if !ctx.pointer_down || !ctx.active_seen ctx.active_id = 0;
    focus_found := false;
    for entry: ctx.widgets if entry.id == ctx.focused_id focus_found = true;
    if !focus_found ctx.focused_id = 0;
    swap(*ctx.widgets, *ctx.previous_widgets);
    ctx.widgets.count = 0;
    ctx.navigation = .{};
    // 本帧没有声明正在编辑的文本框（失焦、被移除或 Escape）就结束编辑。
    ctx.text.editing = ctx.text.seen;
    if !ctx.text.seen ctx.text.id = 0;
    ctx.text_edit = .{};
    // 松开那帧的放置已由 ui_drop_target 读取，之后结束拖动。
    if !ctx.pointer_down ctx.drag = .{};
    for i: ctx.scrolls.count - 1..0 {
        if i < 0 break;
        if !ctx.scrolls[i].seen {
            if i < ctx.scrolls.count - 1 ctx.scrolls[i] = ctx.scrolls[ctx.scrolls.count - 1];
            ctx.scrolls.count -= 1;
        }
    }
    ctx.pointer_down_prev = ctx.pointer_down;
    ctx.pointer_pressed = false;
    ctx.pointer_released = false;
    ctx.pointer_press_owner = 0;
    return commands;
}
//@endregion

//@region 输入查询

// 本帧刚按下（点击边沿）。
ui_clicked :: (ctx: *UI_Context) -> bool {
    if ctx.pointer_edges_explicit return ctx.pointer_pressed;
    return ctx.pointer_down && !ctx.pointer_down_prev;
}

// 本帧刚松开。
ui_released :: (ctx: *UI_Context) -> bool {
    if ctx.pointer_edges_explicit return ctx.pointer_released;
    return !ctx.pointer_down && ctx.pointer_down_prev;
}
//@endregion

//@region 内部 —— clay 回调

// 静态文本测量入口（clay 每帧多次调用；userData 是 UI_Context）。
ui_measure_trampoline :: (text: clay.StringSlice, config: *clay.TextElementConfig, user_data: *void) -> clay.Dimensions {
    ctx := cast(*UI_Context) user_data;
    if ctx == null || config == null return .{ 0, 0 };
    push_context ctx.callback_context {
        font := ui_font_of(ctx, cast(int) config.fontId);
        if font == null return .{ 0, 0 };
        s := string.{ count = cast(s64) text.length, data = cast(*u8) text.chars };
        return ui_measure_text(font, s, config.fontSize, config.letterSpacing, config.lineHeight);
    }
}

ui_error_record :: (error_data: clay.ErrorData) {
    ctx := ui_context_of(error_data.userData);
    if ctx != null {
        push_context ctx.callback_context {
            ctx.error_count += 1;
            ctx.last_error = error_data.errorType;
            // clay 的默认处理器会把错误打到 stderr；这里保持它的行为。
            clay._ErrorHandlerFunctionDefault(error_data);
        }
    } else {
        clay._ErrorHandlerFunctionDefault(error_data);
    }
}

ui_font_of :: (ctx: *UI_Context, font_id: int) -> *F.Msdf_Font {
    if font_id < 0 || font_id >= ctx.fonts.count return null;
    return ctx.fonts[font_id];
}

ui_texture_of :: (ctx: *UI_Context, font_id: int) -> *F.Texture {
    if font_id < 0 || font_id >= ctx.font_textures.count return null;
    return ctx.font_textures[font_id];
}
//@endregion
