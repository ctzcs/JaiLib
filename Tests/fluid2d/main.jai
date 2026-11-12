// fluid2d — 多 Target / 多 pass / 自定义 shader 的端到端技术示例。
//
// 压测路径：gfx 阶段式 pass（scene -> stylize -> composite）、
// gfx_blit_pass 片元材质（10 个流体 pass + 1 个水墨后处理 pass）、
// ping-pong RenderTarget、相机矩阵栈、内嵌 MSDF 文本。
// 这些路径依赖 jfoster 的 Batcher mesh 环形补丁（见 README）。
//
// Build: build_fluid2d.bat（或按其内注释手工调 jai）
// Run from any CWD; build stages custom shader blobs next to the executable:
//   bin\fluid2d.exe            交互窗口（A/D/W/S 或方向键平移相机）
//   bin\fluid2d.exe auto       跑 240 帧后退出（CI 冒烟）

#import "Basic";
#import "File";
#import "gfx";

#load "ink_post.jai";
#load "ink_fluid.jai";

WIN_W :: 1280;
WIN_H :: 720;
TAU2 :: 6.2831853;

// 命令行注入（main 先于 app_run 执行，startup 读取）。
auto_arg_frames: s64;

Fluid2d_State :: struct {
    post:    Ink_Post;
    fluid:   Ink_Fluid;
    tuning:  Ink_Tuning;
    camera:  CameraState;
    time:    float32;
    frame:   s64;
    auto_frames: s64;   // >0 = auto 模式
}

state: *Fluid2d_State;

// HUD uses embedded Roboto MSDF.
startup :: () {
    gfx_shader_dir = copy_string(gfx_executable_asset_path("fluid2d/shaders"));
    gfx_init();

    state = New(Fluid2d_State);
    state.tuning  = INK_TUNING_DEFAULT;
    state.auto_frames = auto_arg_frames;
    state.camera = .{
        offset = .{ x = WIN_W * 0.5, y = WIN_H * 0.5 },
        rotation = 0,
        zoom = 1,
        target = .{ x = 0, y = 0 },
    };
    ink_post_init(*state.post, WIN_W, WIN_H);
    ink_fluid_init(*state.fluid, WIN_W, WIN_H);
    ink_fluid_reset(*state.fluid, *state.tuning);
}

shutdown :: () {
    if state != null {
        ink_fluid_destroy(*state.fluid);
        ink_post_destroy(*state.post);
        free(state);
        state = null;
    }
    gfx_shutdown();
    free(gfx_shader_dir.data);
}

update_camera :: (dt: float32) {
    speed := 420.0 * dt;
    if IsKeyDown(.A) || IsKeyDown(.LEFT)  state.camera.target.x -= speed;
    if IsKeyDown(.D) || IsKeyDown(.RIGHT) state.camera.target.x += speed;
    if IsKeyDown(.W) || IsKeyDown(.UP)    state.camera.target.y -= speed;
    if IsKeyDown(.S) || IsKeyDown(.DOWN)  state.camera.target.y += speed;
    if IsKeyDown(.Q) state.camera.rotation += dt * 0.6;
    if IsKeyDown(.E) state.camera.rotation -= dt * 0.6;
}

render :: () {
    state.frame += 1;
    gfx_begin_frame();
    dt := GetFrameTime();
    state.time += dt;
    update_camera(dt);

    // 1. 场景 pass：白纸 + 相机下的简单动画几何。
    ink_post_begin_scene(*state.post);
    BeginMode2D(state.camera);
    t := state.time;

    DrawRectangle(-2400, 240, 4800, 600, Color.{ r = 22, g = 42, b = 26, a = 255 });  // 地面

    // “树冠”：一圈呼吸的圆。
    for i: 0..7 {
        ang := cast(float32) i * TAU2 / 8.0 + t * 0.3;
        r := 70.0 + 30.0 * GM.sin(t * 1.3 + cast(float) i);
        c := ifx i % 2 == 0 then DARKGREEN else Color.{ r = 60, g = 130, b = 90, a = 255 };
        DrawCircleV(.{ x = GM.cos(ang) * 150, y = -160 + GM.sin(ang) * 70 }, r, c);
    }
    DrawRectangleRec(.{ x = -26, y = 0, width = 52, height = 250 }, Color.{ r = 48, g = 36, b = 30, a = 255 });  // 树干

    // 旋转的悬浮方块（相机旋转语义可见）。
    DrawRectanglePro(.{ x = 320, y = -220, width = 120, height = 60 }, .{ x = 60, y = 30 }, t * 0.8, GOLD);
    DrawRectanglePro(.{ x = -380, y = -140, width = 120, height = 60 }, .{ x = 60, y = 30 }, -t * 0.5, SKYBLUE);

    EndMode2D();
    ink_post_end_scene(*state.post);

    // 2. 水墨风格化 pass。
    ink_post_render_stylized(*state.post, *state.tuning);

    // 3. 流体模拟（各 pass 自带 clear + batcher_clear——必须在合成 pass 之外跑）。
    if state.tuning.fluid_enabled {
        ink_fluid_step(*state.fluid, *state.tuning, dt);
    }

    // 4. 屏幕合成：风格化结果 -> 流体覆盖层 -> HUD。
    // 窗口为 HIGH_PIXEL_DENSITY：按 backbuffer 实际（物理）尺寸合成。
    bw := F.drawable_target_width_in_pixels(gfx_backbuffer());
    bh := F.drawable_target_height_in_pixels(gfx_backbuffer());
    state.camera.offset = .{ x = cast(float32) bw * 0.5, y = cast(float32) bh * 0.5 };
    gfx_pass_begin(gfx_backbuffer(), PAPER_COLOR);
    ink_post_draw_stylized(*state.post, bw, bh);
    if state.tuning.fluid_enabled {
        ink_fluid_draw_overlay(*state.fluid, *state.tuning, bw, bh);
    }
    DrawFPS(10, 10);
    DrawTextHUD("fluid2d: multi-target / multi-pass / custom shaders (WASD pan, Q/E rotate)", 10, 40, LIGHTGRAY);
    gfx_pass_end(gfx_backbuffer());

    if state.auto_frames > 0 && state.frame >= state.auto_frames {
        F.app_exit();
    }
}

main :: () {
    for get_command_line_arguments() {
        // 注：Jai 词法不接受 it[5..it.count]（5. 浮点吞点），数字档位就别切片了
        if it == "auto" auto_arg_frames = 240;
        else if it == "auto-long" auto_arg_frames = 1140;
    }

    F.App.startup  = startup;
    F.App.update   = () => {};
    F.App.render   = render;
    F.App.shutdown = shutdown;

    F.app_run(.{
        application_name = "fluid2d",
        window_title     = "fluid2d (JaiLib gfx sample)",
        width  = WIN_W,
        height = WIN_H,
        resizable = true,
    });

    F.app_destroy();
}
