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
// 公开过程/结构体/字段名、参数顺序、返回语义与 olib 一致；只在下面几处不得不变：
//
//   A. clay 版本：本仓库绑定的是 clay 0.12（thirdparty/clay/module.jai），olib 用的是
//      0.14（Clay_ElementDeclaration + Clay_UI + Clay_TextDynamic + Clay_GetLayoutElementInfo
//      + Clay_SetPointerHitTestFunction + ClipElementConfig）。因此本包自带一层很薄的声明适配：
//        - olib 的 `if clay.UI()(decl) { 子内容 }` → `ui_element(ctx, decl, children = #code { ... })`
//        - 返回 clay.ElementDeclaration 的 *decl 辅助过程 → 返回 UI_Decl（ui_row_decl / ui_panel_decl /
//          ui_scroll_decl / ui_modal_decl / ui_image_decl / ui_nine_slice_decl 名字与参数不变）
//        - Rectangle 配置在 0.12 里是 {color, cornerRadius}（olib 是 {backgroundColor, cornerRadius}），
//          由 UI_Decl.has_rect/rect 承载；border / scroll / floating / image / custom 同理。
//   B. 没有 Clay_GetLayoutElementInfo：视觉变换树改为在声明期由 ui_element 自己记录
//      （UI_Element_Info{id, parent, clip}），EndLayout 后用 Clay_GetElementData 补包围盒。
//      父节点取 Clay__GetParentElementId()，所以匿名容器也能正确串联。
//   C. 没有 Clay_SetPointerHitTestFunction：命中测试改由本包自己实现（ui_visual.jai 的
//      「命中测试」区）：帧末快照每个元素的布局框 + 合成变换，帧开始用 ui_pointer_local 的
//      逆变换把指针反算进元素局部空间，落在框内即命中，并逐级检查裁剪祖先；浮动层按 zIndex
//      优先、其余按声明序（后者在上层）。查询入口是 ui_hovered(ctx, id)，语义与
//      clay.PointerOver 相同（元素本身或其祖先被覆盖）。clay 自己的 PointerOver 仍是布局
//      轴对齐矩形，只用于它内部的滚动/裁剪逻辑，交互判定一律不再依赖它。
//   D. 没有 ClipElementConfig：滚动/裁剪一律用 0.12 的 Scroll 容器（Clay_Scroll 配置）。
//      滚动位置由 clay 自己维护，ui_scroll_decl 只登记 UI_Scroll_Entry 供虚拟列表与焦点滚动读取；
//      文本输入框的水平偏移通过 decl.scroll_offset 在声明时写进 clay 的 scrollPosition。
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
//   clay —— thirdparty/clay/module（clay 0.12 绑定）

UI_TEXT_CONFIG_CAP :: 1024;
// 当前正在声明的 context（ui_begin 设置、ui_end 清空）。ui_element 宏靠它记录视觉树与
// 分配匿名 id，这样 ui_spacer() / ui_row_decl() 这些不带 ctx 的签名能与 olib 保持一致。
ui_current: *UI_Context;
// 匿名元素（没写 id 的容器）的自有 id 前缀；配合帧内递增下标保持帧间稳定。
UI_ANONYMOUS_ID :: "ui#anonymous";
// clay 0.12 的根容器 id（floating.parentId 指它即“挂到 root”）。
UI_ROOT_ID :: "Clay__RootContainer";

//@region 类型

// 一帧的声明快照：视觉树需要的 id / 父 id / 是否裁剪容器 / 浮动层 z。
UI_Element_Info :: struct {
    id:      u32;
    parent:  u32;
    clip:    bool;
    z:       float32; // 浮动元素的 zIndex（非浮动为 0），命中测试用来判定上下层
    is_text: bool; // clay 隐式开的文本元素（`clay.Text`），见 ui_text_element
    // clay 把浮动元素挂成布局树的**独立根**（clay.c:1888，且不加入父的 children:2017），
    // 所以浮动子树的祖先不算「指针覆盖」（Clay_PointerOver 语义）。命中链走到它为止。
    floating: bool;
}

UI_Context :: struct {
    arena_memory: [] u8;
    clay_context: *clay.Context;

    // fontId -> 字体元数据、GPU 纹理、渲染配置，三表平行。
    fonts:          [..] *F.Msdf_Font;
    font_textures:  [..] *F.Texture;
    font_renderers: [..] UI_Font_Renderer;
    image_pool:     [] UI_Image_Data;
    image_len:      int;
    ops:            [..] UI_Op;
    visuals: Table(u32, UI_Visual);
    visual_elements: Table(u32, UI_Visual_Element);
    frame_elements: [..] UI_Element_Info;
    // 命中测试（见 ui_visual.jai 的「命中测试」区）：上一帧的元素快照 + id 索引，
    // 以及本帧算出的命中链（命中的最上层元素 + 它的祖先，语义同 clay 的 pointerOverIds）。
    hit_elements: [..] UI_Hit_Element;
    hit_index:    Table(u32, u32);
    hover_path:   [..] u32;
    hover_id:     u32;
    // clay 隐式开的文本元素：本帧登记过的文本元素 id（视觉树 + 文字命令回查）。
    text_ids:       [..] u32;
    // 渲染命令 id -> 元素 id。clay 的命令 id 有两种派生：文字是 HashNumber(行号, 文本元素 id)，
    // 描边/裁剪是 RehashWithNumber(元素 id, 4/10/11)。视觉树里登记的是元素 id，
    // 翻译时先把命令 id 换回来，描边和裁剪才能和底/文字一样继承子树变换与透明度。
    cmd_owner_map:  Table(u32, u32);
    child_counts:   Table(u32, u32); // 声明期父元素 -> 已声明子元素数（复算 clay 的文本元素 id）
    open_ids:       [..] u32;        // 声明期打开的元素栈（clay 的 openLayoutElementStack 镜像）
    motions: Table(u32, UI_Motion_State);
    presences:      Table(u32, UI_Presence_State);
    inert:          Table(u32, u32); // 本帧退场中的 ID；快照时按子树继承
    delta_time:     float32;         // ui_begin 传入，动效推进用

    // 帧内 TextElementConfig bump 池。clay 0.12 的 StoreTextElementConfig 会复制，
    // 池只是保持与 olib 相同的 API 与“帧内独占指针”语义。
    text_config_pool: [] clay.TextElementConfig;
    text_config_len:  int;

    // 圆角渲染用的单位圆盘纹理（预乘 alpha），ui_render 首次调用时懒建。
    corner_texture:    *F.Texture;
    corner_texture_ok: bool;

    width, height:  float32;
    scale:          float32;
    viewport_origin: F.Vector2;
    pointer_pixels:  F.Vector2;
    active_id, focused_id: u32;
    modal_id, scope_id:    u32;
    modal_changed: bool;
    active_seen:   bool;
    widgets:          [..] UI_Focus_Entry;
    previous_widgets: [..] UI_Focus_Entry;
    scrolls:          [..] UI_Scroll_Entry;
    navigation:       UI_Navigation;
    focus_scroll:     bool; // 焦点由导航或 ui_focus 改变：下一次 begin 把它滚进可见范围
    focus_style:      UI_Focus_Style; // 焦点控件所用主题的焦点框样式，见 ui_focus_style
    focus_by_pointer, focus_ring_hidden: bool;
    dropdown_id: u32; // 当前展开的下拉框；同一时间只展开一个
    drag:        UI_Drag;
    text_edit:   UI_Text_Edit; // 宿主本帧传入的编辑输入，ui_end 清空
    text:        UI_Text_State;
    input:       UI_Input_Capture;
    pool_overflow: bool;
    error_count:   int;
    last_error:    clay.ErrorType;

    pointer_x, pointer_y: float32;
    pointer_down:         bool;
    pointer_down_prev:    bool; // 上一帧状态（点击边沿检测）
    pointer_edges_explicit: bool;
    pointer_pressed, pointer_released: bool; // 调用方收集的边沿，ui_end 消费
    pointer_press_owner: u32; // 显式边沿帧开始时的捕获者，禁止重按转交

    scroll_delta: [2] float32; // 每帧累计，begin 时消费清零
    anon_index:   u32;         // 本帧匿名元素计数（ui_element 用）
    // clay 的测量/错误回调是 C 调用，Jai 要求显式恢复拥有线程的 context（同 Libs/Engine/text）。
    callback_context: #Context;
}
//@endregion

//@region clay 0.12 声明适配（对应 olib 的 clay.ElementDeclaration + clay.UI()）

// 一次元素声明的全部可选配置；字段名对应 clay 0.12 的 *ElementConfig。
UI_Decl :: struct {
    id:     clay.ElementId;   // id.id == 0 时由 ui_element 自动分配匿名声明的 id
    layout: clay.LayoutConfig;
    rect:   clay.RectangleElementConfig;
    border: clay.BorderElementConfig;
    scroll: clay.ScrollElementConfig;
    floating: clay.FloatingElementConfig;
    image:    clay.ImageElementConfig;
    custom:   *void;
    scroll_offset: clay.Vector2;
    has_rect, has_border, has_scroll, has_floating, has_image, has_custom, has_scroll_offset: bool;
    // 记录用：强制指定“这是裁剪容器”（通常等于 has_scroll）。
    force_clip: bool;
}

// olib: `if clay.UI()(decl) { 子内容 }`。
// 这里：`ui_element(ctx, decl, children = #code { 子内容 });`（无子内容时省略 children）。
// 整个宏体放在一个块里，`d` 等局部名不会与外层同名变量冲突。
ui_element :: (decl: UI_Decl, $children := #code,null, cc := #caller_code) #expand {
    {
        d := decl;
        ctx := ui_current;
        assert(ctx != null, "ui_element 必须在 ui_begin/ui_end 之间调用");
        if !d.id.id {
            d.id = clay.ID(UI_ANONYMOUS_ID, ctx.anon_index);
            ctx.anon_index += 1;
        }
        clay.OpenElement();
        clay.AttachId(d.id);
        array_add(*ctx.open_ids, d.id.id); // 供 ui_text_element 找「当前打开的元素」
        clay.AttachLayoutConfig(clay.StoreLayoutConfig(d.layout));
        if d.has_rect {
            clay.AttachElementConfig(.{ rectangleElementConfig = clay.StoreRectangleElementConfig(d.rect) }, .RECTANGLE);
        }
        if d.has_border {
            clay.AttachElementConfig(.{ borderElementConfig = clay.StoreBorderElementConfig(d.border) }, .BORDER_CONTAINER);
        }
        if d.has_scroll {
            clay.AttachElementConfig(.{ scrollElementConfig = clay.StoreScrollElementConfig(d.scroll) }, .SCROLL_CONTAINER);
        }
        if d.has_floating {
            clay.AttachElementConfig(.{ floatingElementConfig = clay.StoreFloatingElementConfig(d.floating) }, .FLOATING_CONTAINER);
        }
        if d.has_image {
            clay.AttachElementConfig(.{ imageElementConfig = clay.StoreImageElementConfig(d.image) }, .IMAGE);
        }
        if d.has_custom {
            clay.AttachElementConfig(.{ customElementConfig = clay.StoreCustomElementConfig(.{ customData = d.custom }) }, .CUSTOM);
        }
        clay.ElementPostConfiguration();
        // 滚动容器刚登记完 scroll 数据，此时写入偏移会影响本帧布局。
        if d.has_scroll && d.has_scroll_offset {
            data := clay.GetScrollContainerData(d.id);
            if data.found && data.scrollPosition != null data.scrollPosition.* = d.scroll_offset;
        }
        parent_id := clay.GetParentElementId();
        z: float32;
        if d.has_floating z = d.floating.zIndex;
        array_add(*ctx.frame_elements, UI_Element_Info.{
            id = d.id.id, parent = parent_id, clip = d.has_scroll || d.force_clip, z = z,
            floating = d.has_floating,
        });
        #if children {
            #insert,scope(cc) children;
            clay.CloseElement();
            if !d.has_floating ui_child_declared(ctx, parent_id);
            if ctx.open_ids.count > 0 ctx.open_ids.count -= 1;
        } else {
            // 无子内容：立即关闭。
            // 这里不能用 `defer（也不能用普通 defer 的块作用域形式）：`` `defer `` 会推迟到**调用方作用域**
            // 结束时才执行，于是 `ui_element(decl);` 这种裸语句会把元素留到帧末才 CloseElement，
            // 使 clay 的 openLayoutElementStack 失衡——EndLayout 里那次 CloseElement 关掉的是
            // 最后一个裸元素而不是根容器，根的 children.elements 留在 NULL，
            // 随后 Clay__SizeContainersAlongAxis 读 children.elements[0] 段错误。
            clay.CloseElement();
            if !d.has_floating ui_child_declared(ctx, parent_id);
            if ctx.open_ids.count > 0 ctx.open_ids.count -= 1;
        }
    }
}

// 子元素声明完毕：累加父元素的子元素计数（对应 clay 的 children.length）。
ui_child_declared :: (ctx: *UI_Context, parent: u32) {
    count := table_find_pointer(*ctx.child_counts, parent);
    if count == null { table_set(*ctx.child_counts, parent, 1); return; }
    count.* += 1;
}

// 开一个 clay 文本元素，并把它登记进本帧的视觉树。
// clay 的文本元素 id = HashString("Text", 父元素本帧第几个子元素, 父元素 id)，而文字渲染命令的 id
// 又是 HashNumber(行号, 文本元素 id)：两者都能在声明期算出来，于是视觉树能包含文本元素，
// 文本才会跟着子树一起平移/缩放/淡出（否则 ui_visual_apply_ops 按命令 id 查不到，文字停在布局位置）。
// 所有发文本的地方都应走这里而不是直接 clay.Text。
ui_text_element :: (ctx: *UI_Context, text: string, config: *clay.TextElementConfig) {
    if config == null return;
    parent := clay.ID(UI_ROOT_ID).id; // 顶层文本：父元素就是 clay 的根容器
    if ctx.open_ids.count > 0 parent = ctx.open_ids[ctx.open_ids.count - 1];
    index: u32 = 1;
    count := table_find_pointer(*ctx.child_counts, parent);
    if count != null index = count.* + 1;
    clay.Text(text, config);
    ui_child_declared(ctx, parent); // clay 在 OpenTextElement 里也把父的 children.length +1
    id := clay.HashString(.{ xx "Text".count, "Text".data }, index, parent).id;
    array_add(*ctx.frame_elements, UI_Element_Info.{ id = id, parent = parent, is_text = true });
    array_add(*ctx.text_ids, id);
}

// 元素 id：olib 的 clay.ID(string) 保持一致（clay 0.12 的同名助手）。
ui_id :: (id: string) -> clay.ElementId { return clay.ID(id); }
//@endregion

//@region 生命周期

ui_user_data :: (ctx: *UI_Context) -> u64 { return cast(u64) ctx; }
ui_context_of :: (user: u64) -> *UI_Context #no_context { return cast(*UI_Context) cast(*void) user; }

// clay 0.12 的 Clay_MinMemorySize() 依赖「当前 context」：没有 context 时按默认的
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
        width  = width,
        height = height,
        scale  = 1,
        callback_context = context,
        focus_style = UI_Focus_Style.{ color = UI_THEME_DARK.accent, width = 2 },
    };

    capacity := ui_arena_capacity();
    memory := NewArray(cast(s64) capacity, u8, true);
    if memory.data == null return false;
    ctx.arena_memory = memory;

    ctx.text_config_pool = NewArray(UI_TEXT_CONFIG_CAP, clay.TextElementConfig, true);
    if ctx.text_config_pool.data == null { ui_dispose(ctx); return false; }
    ctx.image_pool = NewArray(UI_TEXT_CONFIG_CAP, UI_Image_Data, true);
    if ctx.image_pool.data == null { ui_dispose(ctx); return false; }

    arena := clay.CreateArenaWithCapacityAndMemory(capacity, memory.data);
    ctx.clay_context = clay.Initialize(arena, .{ width, height }, .{
        errorHandlerFunction = ui_error_record,
        userData = ui_user_data(ctx),
    });
    clay.SetMeasureTextFunction(ui_measure_trampoline, ui_user_data(ctx));
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
    array_free(ctx.frame_elements);
    array_free(ctx.text_ids);
    array_free(ctx.open_ids);
    array_free(ctx.hit_elements);
    array_free(ctx.hover_path);
    deinit(*ctx.hit_index);
    deinit(*ctx.cmd_owner_map);
    deinit(*ctx.child_counts);
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
    ctx.anon_index = 0;
    ctx.frame_elements.count = 0;
    ctx.text_ids.count = 0;
    ctx.open_ids.count = 0;
    table_reset(*ctx.child_counts);
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
        pointer  = ctx.modal_id != 0 || ctx.active_id != 0,
        keyboard = ctx.modal_id != 0,
    };
    ctx.pointer_x = (ctx.pointer_pixels.x - ctx.viewport_origin.x) / ctx.scale;
    ctx.pointer_y = (ctx.pointer_pixels.y - ctx.viewport_origin.y) / ctx.scale;
    // 命中测试按上一帧快照 + 本帧指针；必须在 ui_navigation_begin 之前算出，
    // 这样本帧的 ui_interact 读到的悬停状态与 clay 的「按上一帧布局」一致。
    ui_hit_update(ctx);
    ui_navigation_begin(ctx);
    ui_focus_scroll(ctx);
    clay.SetPointerState(.{ ctx.pointer_x, ctx.pointer_y }, ctx.pointer_down);
    // 拖动由控件捕获；列表使用滚轮，避免按按钮时同时拖动父滚动区。
    // 模态切换帧的命中仍基于旧布局，禁止滚轮穿过刚打开/关闭的遮罩。
    if !ctx.modal_changed {
        clay.UpdateScrollContainers(false, .{ ctx.scroll_delta[0], ctx.scroll_delta[1] }, delta_time);
    }
    ctx.modal_changed = false;
    ctx.scroll_delta = .[ 0, 0 ];
    // 在 BeginLayout/OpenElement 重建内部元素表之前快照滚动状态，
    // 使 ui_element(ctx, ui_scroll_decl(...)) 的内联求值安全。
    for *scroll: ctx.scrolls {
        data := clay.GetScrollContainerData(.{ id = scroll.id });
        if data.found && data.scrollPosition != null scroll.offset = data.scrollPosition.*;
        else scroll.offset = .{ 0, 0 };
        scroll.seen = false;
    }
    ui_current = ctx;
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
ui_end :: (ctx: *UI_Context) -> clay.RenderCommandArray {
    // 视觉变换可能把布局外元素移入视口，不能先按原布局剔除。
    culling_disabled := ctx.clay_context.disableCulling;
    if ctx.visuals.count > 0 clay.SetCullingEnabled(false);
    commands := clay.EndLayout();
    clay.SetCullingEnabled(!culling_disabled);
    ui_visual_snapshot(ctx);
    ui_hit_snapshot(ctx); // 下一帧命中测试的数据源；必须在 EndLayout 与视觉解析之后
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
    for i: ctx.scrolls.count - 1 .. 0 {
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
    ui_current = null;
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
ui_measure_trampoline :: (text: clay.StringSlice, config: *clay.TextElementConfig, user_data: u64) -> clay.Dimensions #c_call {
    ctx := ui_context_of(user_data);
    if ctx == null || config == null return .{ 0, 0 };
    push_context ctx.callback_context {
        font := ui_font_of(ctx, cast(int) config.fontId);
        if font == null return .{ 0, 0 };
        s := string.{ count = cast(s64) text.length, data = cast(*u8) text.chars };
        return ui_measure_text(font, s, config.fontSize, config.letterSpacing, config.lineHeight);
    }
}

ui_error_record :: (error_data: clay.ErrorData) #c_call {
    ctx := ui_context_of(error_data.userData);
    if ctx != null {
        push_context ctx.callback_context {
            ctx.error_count += 1;
            ctx.last_error = error_data.errorType;
            // clay 的默认处理器会把错误打到 stderr；这里保持它的行为。
            clay.ErrorHandlerFunctionDefault(error_data);
        }
    } else {
        clay.ErrorHandlerFunctionDefault(error_data);
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
