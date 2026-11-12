// gfx.jai
// jfoster (SDL3 + SDL_GPU) 图形核心 + raylib 风格兼容绘制层。
//
// 结构：
//   - 全局唯一 Batcher：2D 内容、imgui、clay、全屏 shader pass 全部经它提交。
//   - gfx_pass_begin/end：阶段式渲染，每阶段 clear + 累积 + 单次 render。
//   - gfx_blit_pass：带自定义片元 shader 的全屏/拉伸 pass（多 Target
//     模拟 / 后处理），也走 Batcher（材质顶点 shader 为空 = 用 Batcher
//     自带顶点阶段；片元采样器槽 0 恰好就是主 blit 纹理）。
//   - raylib 同名兼容层（Draw*/IsKey*/GetRandomValue...）。
//
// 坐标约定：全链路左上原点、y 向下（SDL_GPU 一致）。
//
// 运行时资源寻址（由宿主程序显式配置；框架默认资源内嵌于 jfoster）：
//   - gfx_shader_dir：片元 shader blob 目录（<name>.fragment.{dxil,spv}）
//   - HUD 字体：gfx_init() 默认内嵌 MSDF；可传 TTF/TTC 与额外字符。
//     DrawText/DrawFPS 与 clay 共用 UTF-8 文本布局。

#import "Basic";
#import "File";

F   :: #import "jfoster";
GM  :: #import "Math";   // 独别名：tween 模块也导出 M，避免泄漏冲突
RND :: #import "Random";
GFX_SYS :: #import "System";
TXT :: #import "text";
GFX_STORAGE :: #import "storage";

// ---- 类型与常量 ----

Vector2 :: GM.Vector2;
Color   :: F.Color;
// Tex = 贴图指针别名（jfoster 已导出 Texture 结构体名，指针别名换名避免冲突）。
Tex     :: *F.Texture;

Rectangle :: struct {
    x, y:         float32;
    width, height: float32;
}

WHITE     :: Color.{ 255, 255, 255, 255 };
BLACK     :: Color.{   0,   0,   0, 255 };
BLANK     :: Color.{   0,   0,   0,   0 };
RAYWHITE  :: Color.{ 245, 245, 245, 255 };
LIGHTGRAY :: Color.{ 200, 200, 200, 255 };
GRAY      :: Color.{ 130, 130, 130, 255 };
GOLD      :: Color.{ 253, 249,   0, 255 };
SKYBLUE   :: Color.{ 102, 191, 255, 255 };

// ---- 全局图形状态 ----

gfx_batcher:  *F.Batcher;
gfx_hud_font: *F.Sprite_Font;
gfx_hud_source_font: *F.Font;
gfx_text_font: *TXT.Text_Font;

GFX_HUD_FONT_SIZE :: 24.0;

// 片元 shader blob 目录（<name>.fragment.{dxil,spv}）。
gfx_shader_dir: string = "shaders/compiled";

// 最近一次 render 帧的 dt（gfx_begin_frame 计算，GetFrameTime 读取）。
gfx_frame_dt: float32 = 1.0 / 60.0;
gfx_last_elapsed: float64;

// Resolve demo assets next to the actual executable, without changing CWD.
gfx_executable_asset_path :: (relative_path: string) -> string /* Temporary Storage */ {
    exe := GFX_SYS.get_path_of_running_executable();
    slash: s64 = -1;
    for c, i: exe if c == 47 || c == 92 slash = i;
    assert(slash >= 0, "Cannot resolve executable directory");
    directory := exe;
    directory.count = slash;
    return tprint("%/%", directory, relative_path);
}

// Empty/missing font path falls back to embedded Roboto MSDF.
// vsync 默认开启：不开时窗口程序会空转到上千 FPS 且画面横向撕裂。
gfx_init :: (font_path: string = "", vsync := true, extra_glyphs: string = "") {
    device := F.App.device;
    if vsync F.graphics_device_set_vsync(device, true);
    gfx_batcher = F.batcher_create(device);

    gfx_text_font = TXT.text_font_create(device, font_path, extra_glyphs, GFX_HUD_FONT_SIZE);
    if gfx_text_font == null {
        print("gfx: font load failed %, using embedded Roboto MSDF\n", font_path);
        gfx_text_font = TXT.text_font_create(device);
    }
    gfx_hud_font = gfx_text_font.sprite;
    gfx_hud_source_font = gfx_text_font.source;
}

gfx_shutdown :: () {
    TXT.text_font_destroy(gfx_text_font);
    gfx_text_font = null;
    gfx_hud_font = null;
    gfx_hud_source_font = null;
    if gfx_batcher != null {
        F.batcher_destroy(gfx_batcher);
        gfx_batcher = null;
    }
}

// 每个渲染帧最先调用（App.render 回调开头）。
gfx_begin_frame :: () {
    dt := F.App.time.elapsed - gfx_last_elapsed;
    gfx_last_elapsed = F.App.time.elapsed;
    if dt > 0.0 && dt < 10.0 {
        gfx_frame_dt = cast(float32) dt;
    }
}

// ---- 阶段式 pass ----

// 清屏 + 重置 batcher。内容统一用非预乘混合（jfoster 默认是预乘）。
gfx_pass_begin :: (target: F.Drawable_Target, clear: Color) {
    F.graphics_device_clear_color(F.App.device, target, clear);
    F.batcher_clear(gfx_batcher);
    F.batcher_push_blend(gfx_batcher, F.Blend_Mode_NonPremultiplied);
}

// 提交本阶段累积的全部几何。
gfx_pass_end :: (target: F.Drawable_Target) {
    F.batcher_render(gfx_batcher, target);
}

// ---- 自定义片元 shader 的全屏 pass ----

// blob 在 gfx_shader_dir/<name>.fragment.{dxil,spv}；HLSL 约定：
// cbuffer Params register(b0, space3)（槽 0），采样器
// register(t/s0..2, space2)（槽 0 = 主 blit 纹理，1..2 = 辅助纹理）。
Gfx_Shader :: struct {
    fragment: *F.Shader;
    material: *F.Material; // 顶点 shader 为空 -> 走 Batcher 自带顶点阶段
}

gfx_load_fragment_shader :: (name: string, sampler_count: s32, storage: *GFX_STORAGE.Storage = null, prefix: string = "") -> *Gfx_Shader {
    device := F.App.device;
    ext := F.graphics_driver_shader_extension(device.driver);
    path := tprint("%/%.fragment.%", gfx_shader_dir, name, ext);
    code: []u8;
    ok: bool;
    if storage != null {
        path = ifx prefix.count == 0 then tprint("%.fragment.%",name,ext) else tprint("%/%.fragment.%",prefix,name,ext);
        code, ok = GFX_STORAGE.storage_read(storage,path);
    } else {
        bytes, read_ok := read_entire_file(path, false, false);
        code=cast([]u8) bytes;ok=read_ok;
    }
    if !ok {
        print("gfx: 找不到 shader blob %\n", path);
        return null;
    }
    defer free(code.data);

    sh := New(Gfx_Shader);
    sh.fragment = F.shader_create(device, .FRAGMENT, cast([] u8) code, sampler_count = sampler_count, uniform_buffer_count = 1, entry_point = "fragment_main", name = name);
    if sh.fragment == null {
        free(sh);
        return null;
    }
    sh.material = F.material_create(null, sh.fragment);
    return sh;
}

gfx_shader_destroy :: (sh: *Gfx_Shader) {
    if sh == null return;
    F.material_destroy(sh.material);
    F.shader_dispose(sh.fragment);
    free(sh.fragment);
    free(sh);
}

// 片元 uniform 槽 0：params 结构体的字节布局必须与 HLSL cbuffer 一致
// （全 float4 对齐）。
gfx_shader_set_params :: (sh: *Gfx_Shader, params: *$T) {
    bytes: [] u8;
    bytes.data  = cast(*u8) params;
    bytes.count = size_of(T);
    F.material_stage_set_uniform(*sh.material.Fragment, 0, bytes);
}

// 辅助采样器（槽 1 起；槽 0 属于主 blit 纹理，由 pass 设置）。
gfx_shader_set_sampler :: (sh: *Gfx_Shader, slot: s32, texture: *F.Texture, linear := true) {
    filter := ifx linear then F.Texture_Filter.LINEAR else F.Texture_Filter.NEAREST;
    sh.material.Fragment.Samplers[slot] = .{
        Tex     = texture,
        Sampler = F.texture_sampler_make(filter, F.Texture_Wrap.CLAMP),
    };
}

// 全屏/拉伸 blit pass：clear target -> 主纹理(槽0)+shader -> (w,h) 目标区域。
// sh 为 null 时做普通纹理 blit（不带后处理）。
gfx_blit_pass :: (target: F.Drawable_Target, sh: *Gfx_Shader, primary: *F.Texture, dst_w: s32, dst_h: s32, clear: Color) {
    F.graphics_device_clear_color(F.App.device, target, clear);
    F.batcher_clear(gfx_batcher);
    F.batcher_push_blend(gfx_batcher, F.Blend_Mode_NonPremultiplied);

    if sh != null {
        // 槽 0 = 主纹理；线性采样 + CLAMP。
        sh.material.Fragment.Samplers[0] = .{
            Tex     = primary,
            Sampler = F.texture_sampler_make(.LINEAR, F.Texture_Wrap.CLAMP),
        };
        F.batcher_push_material(gfx_batcher, sh.material);
    }
    F.batcher_quad_textured(
        gfx_batcher,
        primary,
        .{ x = 0, y = 0 }, .{ x = cast(float) dst_w, y = 0 },
        .{ x = cast(float) dst_w, y = cast(float) dst_h }, .{ x = 0, y = cast(float) dst_h },
        .{ x = 0, y = 0 }, .{ x = 1, y = 0 },
        .{ x = 1, y = 1 }, .{ x = 0, y = 1 },
        WHITE,
    );
    if sh != null {
        F.batcher_pop_material(gfx_batcher);
    }
    F.batcher_pop_blend(gfx_batcher);

    F.batcher_render(gfx_batcher, target);
}

// ---- raylib 兼容绘制层（经由全局 batcher，处于当前相机矩阵下） ----

rect_to_f :: (r: Rectangle) -> F.Rect {
    return .{ x = r.x, y = r.y, w = r.width, h = r.height };
}

DrawRectangle :: (x: s32, y: s32, w: s32, h: s32, color: Color) {
    F.batcher_rect_xy(gfx_batcher, cast(float) x, cast(float) y, cast(float) w, cast(float) h, color);
}

DrawRectangleRec :: (rect: Rectangle, color: Color) {
    F.batcher_rect(gfx_batcher, rect_to_f(rect), color);
}

// rotation 为弧度（raylib DrawRectanglePro 语义）。
DrawRectanglePro :: (dest: Rectangle, origin: Vector2, rotation: float32, color: Color) {
    if rotation == 0 {
        DrawRectangleRec(.{ x = dest.x - origin.x, y = dest.y - origin.y, width = dest.width, height = dest.height }, color);
        return;
    }
    F.batcher_push_matrix_trs(
        gfx_batcher,
        .{ x = dest.x, y = dest.y },
        origin,
        .{ x = 1, y = 1 },
        rotation,
    );
    F.batcher_rect_xy(gfx_batcher, 0, 0, dest.width, dest.height, color);
    F.batcher_pop_matrix(gfx_batcher);
}

// raylib roundness 为相对短边比例（0..0.5）；Foster 圆角是像素半径。
DrawRectangleRounded :: (rect: Rectangle, roundness: float32, segments: s32, color: Color) {
    radius := roundness * min(rect.width, rect.height);
    if radius > 0.5 {
        F.batcher_rect_rounded(gfx_batcher, rect_to_f(rect), radius, color);
    } else {
        DrawRectangleRec(rect, color);
    }
}

DrawCircleV :: (center: Vector2, radius: float32, color: Color) {
    F.batcher_circle(gfx_batcher, center, radius, 24, color);
}

DrawLineEx :: (start_pos: Vector2, end_pos: Vector2, thick: float32, color: Color) {
    F.batcher_line(gfx_batcher, start_pos, end_pos, thick, color);
}

// 等价 DrawTexturePro：source(纹理像素) -> dest(当前坐标系)，绕 origin 旋转。
DrawTexturePro :: (texture: Tex, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: float32, tint: Color) {
    if texture == null || texture.Width <= 0 || texture.Height <= 0 return;

    tw := cast(float32) texture.Width;
    th := cast(float32) texture.Height;

    // 负 source 尺寸在 raylib 里表示翻转；SDL_GPU 语义下换成 UV 镜像。
    u0 := source.x / tw;
    v0 := source.y / th;
    u1 := (source.x + source.width) / tw;
    v1 := (source.y + source.height) / th;
    if source.width < 0 { u0 = (source.x + source.width) / tw; u1 = source.x / tw; }
    if source.height < 0 { v0 = (source.y + source.height) / th; v1 = source.y / th; }

    dx := -origin.x;
    dy := -origin.y;
    dw := dest.width;
    dh := dest.height;
    s := GM.sin(rotation);
    c := GM.cos(rotation);

    // dest 四角绕 origin 旋转（与 raylib DrawTexturePro 一致：origin 在 dest 空间）。
    F.batcher_quad_textured(
        gfx_batcher,
        texture,
        .{ x = dest.x +  dx      * c -  dy      * s, y = dest.y +  dx      * s +  dy      * c },
        .{ x = dest.x + (dx + dw) * c -  dy      * s, y = dest.y + (dx + dw) * s +  dy      * c },
        .{ x = dest.x + (dx + dw) * c - (dy + dh) * s, y = dest.y + (dx + dw) * s + (dy + dh) * c },
        .{ x = dest.x +  dx      * c - (dy + dh) * s, y = dest.y +  dx      * s + (dy + dh) * c },
        .{ x = u0, y = v0 }, .{ x = u1, y = v0 },
        .{ x = u1, y = v1 }, .{ x = u0, y = v1 },
        tint,
    );
}

DrawTextureRec :: (texture: Tex, source: Rectangle, position: Vector2, tint: Color) {
    DrawTexturePro(
        texture,
        source,
        .{ x = position.x, y = position.y, width = source.width, height = source.height },
        .{ x = 0, y = 0 },
        0,
        tint,
    );
}

// ---- Shared MSDF / TTF text; preserves the current camera transform ----
DrawText :: (text: string, x: s32, y: s32, font_size: s32, color: Color) {
    TXT.text_draw(gfx_text_font, gfx_batcher, text, .{cast(float32) x, cast(float32) y}, cast(float32) font_size, color);
}

MeasureText :: (text: string, font_size: s32) -> Vector2 {
    return TXT.text_measure(gfx_text_font, text, cast(float32) font_size);
}
// HUD 字号 + 1px 半透明黑影：亮纸底/深色流体染料上都能读。
DrawTextHUD :: (text: string, x: s32, y: s32, color: Color) {
    size := cast(s32) GFX_HUD_FONT_SIZE;
    DrawText(text, x + 1, y + 1, size, Color.{ 0, 0, 0, 170 });
    DrawText(text, x, y, size, color);
}

DrawFPS :: (x: s32, y: s32) {
    fps := 0.0;
    if gfx_frame_dt > 0.0001 fps = 1.0 / gfx_frame_dt;
    DrawTextHUD(tprint("FPS: %", cast(int) (fps + 0.5)), x, y, LIME_GREEN);
}

LIME_GREEN :: Color.{ 0, 255, 128, 255 };
DARKGRAY   :: Color.{ 80, 80, 80, 255 };
DARKGREEN  :: Color.{ 0, 117, 44, 255 };

// ---- 输入 / 杂项兼容层（直接转发 jfoster Input） ----

IsKeyPressed :: (key: F.Keys) -> bool {
    kb := F.input_keyboard(F.App.input);
    return F.keyboard_pressed(kb, key);
}

IsKeyDown :: (key: F.Keys) -> bool {
    kb := F.input_keyboard(F.App.input);
    return F.keyboard_down(kb, key);
}

IsMouseButtonDown :: (button: F.Mouse_Buttons) -> bool {
    mouse := F.input_mouse(F.App.input);
    return F.mouse_down(mouse, button);
}

IsMouseButtonPressed :: (button: F.Mouse_Buttons) -> bool {
    mouse := F.input_mouse(F.App.input);
    return F.mouse_pressed(mouse, button);
}

IsMouseButtonReleased :: (button: F.Mouse_Buttons) -> bool {
    mouse := F.input_mouse(F.App.input);
    return F.mouse_released(mouse, button);
}

GetMousePosition :: () -> Vector2 {
    return F.window_mouse_position(F.App.window);
}

GetFrameTime :: () -> float32 {
    return gfx_frame_dt;
}

GetRandomValue :: (min: s32, max: s32) -> s32 {
    // Random 模块只有 float 区间重载；+1 保持含端点语义。
    r := RND.random_get_within_range(cast(float) min, cast(float) max + 1.0);
    return cast(s32) r;
}

// 主窗口后台缓冲（composite 阶段的提交目标）。
gfx_backbuffer :: () -> F.Drawable_Target {
    return F.drawable_target_window(F.App.window);
}
