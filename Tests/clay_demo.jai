// clay_demo.jai
// Standalone demo of the clay UI binding (bindings/clay/module) rendered
// through jfoster (bindings/clay_foster.jai). Not part of the game build.
//
// Build: build_clay_demo.bat（或按其内注释手工调 jai）
// Run:
//   bin\clay_demo.exe            interactive window
//   bin\clay_demo.exe auto       run 180 frames then exit (CI smoke test)
//
// 依赖：core/gfx 提供全局 Batcher 与阶段式 pass；clay_foster 提供渲染
// 后端；clay 模块经 clay_foster 顶层导出（`clay`），jfoster 经 gfx 的 `F`。

#import "Basic";
#import "File";

gfx :: #import "gfx";
cr  :: #import "thirdparty/clay_foster";
JF   :: #import "jfoster";
clay :: #import "thirdparty/clay/module";   // 回调挂接走本模块的引用（gfx.F 常量路径不可赋值）

ARENA_BYTES :: 16 * 1024 * 1024;
arena_memory: [ARENA_BYTES] u8 #align(16);

COLOR_BG     :: clay.Color.{ r = 30.0,  g = 32.0,  b = 40.0,  a = 255.0 };
COLOR_PANEL  :: clay.Color.{ r = 44.0,  g = 47.0,  b = 58.0,  a = 255.0 };
COLOR_PANEL2 :: clay.Color.{ r = 54.0,  g = 58.0,  b = 70.0,  a = 255.0 };
COLOR_TEXT   :: clay.Color.{ r = 220.0, g = 220.0, b = 225.0, a = 255.0 };
COLOR_ACCENT :: clay.Color.{ r = 90.0,  g = 160.0, b = 255.0, a = 255.0 };

demo_frame:    s64;
demo_autoframes: s64;

startup :: () {
    gfx.gfx_init();
    _ := cr.clay_foster_setup(JF.App.device);

    arena := clay.CreateArenaWithCapacityAndMemory(clay.MinMemorySize(), *arena_memory[0]);
    clay.Initialize(arena, .{ width = 800.0, height = 600.0 }, .{});
    clay.SetMeasureTextFunction(cr.measure_text, 0);

    body_config  = clay.StoreTextElementConfig(.{ fontSize = 16, fontId = 1, textColor = COLOR_TEXT });
    title_config = clay.StoreTextElementConfig(.{ fontSize = 26, fontId = 1, textColor = COLOR_ACCENT });
}

body_config: *clay.TextElementConfig;
title_config: *clay.TextElementConfig;

render :: () {
    demo_frame += 1;
    gfx.gfx_begin_frame();

    mouse := JF.window_mouse_position(JF.App.window);
    lmb   := JF.mouse_down(JF.input_mouse(JF.App.input), .LEFT);
    clay.SetPointerState(.{ x = mouse.x, y = mouse.y }, lmb);
    clay.SetLayoutDimensions(.{
        width  = cast(float32) JF.window_width_in_pixels(JF.App.window),
        height = cast(float32) JF.window_height_in_pixels(JF.App.window),
    });

    clay.BeginLayout();
    build_ui(body_config, title_config);
    commands := clay.EndLayout();

    gfx.gfx_pass_begin(gfx.gfx_backbuffer(), .{ r = 30, g = 32, b = 40, a = 255 });
    cr.clay_foster_render(gfx.gfx_batcher, *commands);
    gfx.DrawFPS(10, 10);
    gfx.gfx_pass_end(gfx.gfx_backbuffer());

    if demo_autoframes > 0 && demo_frame >= demo_autoframes {
        JF.app_exit();
    }
}

shutdown :: () {
    cr.clay_foster_shutdown();
    gfx.gfx_shutdown();
}

// clay.Hovered() must be evaluated while the button element is open, which is
// the case both here (config phase) and in button_label (children phase).
button_color :: () -> clay.Color {
    if clay.Hovered() return COLOR_ACCENT;
    return COLOR_PANEL2;
}

button_label :: () -> string {
    if clay.Hovered() return "Hovered!";
    return "Hover me";
}

build_ui :: (body: *clay.TextElementConfig, title: *clay.TextElementConfig) {
    clay.Element(clay.ID("Root"),
        clay.Layout(.{
            sizing = .{ width = clay.SizingGrow(), height = clay.SizingGrow() },
            padding = .{ left = 16, right = 16, top = 16, bottom = 16 },
            childGap = 12,
            layoutDirection = .TOP_TO_BOTTOM,
        }),
        children = #code {
            clay.Text("JaiLib clay demo", title);
            clay.Element(clay.ID("Panel"),
                clay.Layout(.{
                    sizing = .{ width = clay.SizingGrow(), height = clay.SizingFit(.{ min = 220.0 }) },
                    padding = .{ left = 12, right = 12, top = 12, bottom = 12 },
                }),
                clay.Rectangle(.{ color = COLOR_PANEL, cornerRadius = .{ 8.0, 8.0, 8.0, 8.0 } }),
                children = #code {
                    clay.Text("A panel with text", body);
                    clay.Element(clay.ID("Button"),
                        clay.Layout(.{
                            sizing = .{ width = clay.SizingFixed(180.0), height = clay.SizingFixed(40.0) },
                            childAlignment = .{ .CENTER, .CENTER },
                        }),
                        clay.Rectangle(.{
                            color = button_color(),
                            cornerRadius = .{ 6.0, 6.0, 6.0, 6.0 },
                        }),
                        children = #code {
                            clay.Text(button_label(), body);
                        },
                    );
                },
            );

            clay.Element(clay.ID("Row"),
                clay.Layout(.{
                    sizing = .{ width = clay.SizingGrow(), height = clay.SizingFixed(48.0) },
                    childGap = 8,
                }),
                children = #code {
                    clay.Element(clay.ID("BoxA"),
                        clay.Layout(.{ sizing = .{ width = clay.SizingGrow(), height = clay.SizingGrow() } }),
                        clay.Rectangle(.{ color = COLOR_PANEL, cornerRadius = .{ 4.0, 4.0, 4.0, 4.0 } }),
                    );
                    clay.Element(clay.ID("BoxB"),
                        clay.Layout(.{ sizing = .{ width = clay.SizingFixed(200.0), height = clay.SizingGrow() } }),
                        clay.Rectangle(.{ color = COLOR_PANEL, cornerRadius = .{ 4.0, 4.0, 4.0, 4.0 } }),
                        children = #code {
                            clay.Text("Fixed-width box", body);
                        },
                    );
                },
            );
        },
    );
}

main :: () {
    for get_command_line_arguments() {
        if it == "auto" demo_autoframes = 180;
    }

    JF.App.startup  = startup;
    JF.App.render   = render;
    JF.App.shutdown = shutdown;

    JF.app_run(.{
        application_name = "clay_demo",
        window_title     = "clay demo (JaiLib)",
        width  = 800,
        height = 600,
        resizable = true,
    });

    JF.app_destroy();
}
