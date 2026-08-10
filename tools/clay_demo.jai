// clay_demo.jai
// Standalone demo of the clay UI binding (bindings/clay) rendered through
// raylib (bindings/clay_raylib.jai). Not part of the game build.
//
// Build (from repo root):
//   jai -no_cwd -import_dir tlib -import_dir bindings -import_dir . -exe clay_demo tools/clay_demo.jai
// Run:
//   bin/clay_demo.exe            interactive window
//   bin/clay_demo.exe auto       run 180 frames then exit (CI smoke test)

#import "Basic";

rl :: #import "bindings/raylib";
clay :: #import "clay/module";
cr :: #import "bindings/clay_raylib";

ARENA_BYTES :: 16 * 1024 * 1024;
arena_memory: [ARENA_BYTES] u8 #align 16;

COLOR_BG     :: clay.Color.{ r = 30.0,  g = 32.0,  b = 40.0,  a = 255.0 };
COLOR_PANEL  :: clay.Color.{ r = 44.0,  g = 47.0,  b = 58.0,  a = 255.0 };
COLOR_PANEL2 :: clay.Color.{ r = 54.0,  g = 58.0,  b = 70.0,  a = 255.0 };
COLOR_TEXT   :: clay.Color.{ r = 220.0, g = 220.0, b = 225.0, a = 255.0 };
COLOR_ACCENT :: clay.Color.{ r = 90.0,  g = 160.0, b = 255.0, a = 255.0 };

main :: () {
    auto_frames: s64 = 0;
    args := get_command_line_arguments();
    for args {
        if it == "auto" {
            auto_frames = 180;
        }
    }

    rl.SetConfigFlags(.WINDOW_RESIZABLE);
    rl.InitWindow(800, 600, "clay demo (JaiLib)");
    defer rl.CloseWindow();

    arena := clay.CreateArenaWithCapacityAndMemory(clay.MinMemorySize(), *arena_memory[0]);
    clay.Initialize(arena, .{ width = 800.0, height = 600.0 }, .{});
    clay.SetMeasureTextFunction(cr.measure_text, 0);

    body_config := clay.StoreTextElementConfig(.{
        fontSize = 16,
        fontId = 1,
        textColor = COLOR_TEXT,
    });
    title_config := clay.StoreTextElementConfig(.{
        fontSize = 26,
        fontId = 1,
        textColor = COLOR_ACCENT,
    });

    frame: s64 = 0;
    while !rl.WindowShouldClose() {
        frame += 1;

        mouse := rl.GetMousePosition();
        clay.SetPointerState(.{ x = mouse.x, y = mouse.y }, rl.IsMouseButtonDown(.LEFT));
        clay.SetLayoutDimensions(.{ width = cast(float32) rl.GetScreenWidth(), height = cast(float32) rl.GetScreenHeight() });

        clay.BeginLayout();
        build_ui(body_config, title_config);
        commands := clay.EndLayout();

        rl.BeginDrawing();
        rl.ClearBackground(color_bg_rl());
        cr.clay_raylib_begin_frame();
        cr.clay_raylib_render(*commands);
        rl.DrawFPS(10, 10);
        rl.EndDrawing();

        if auto_frames > 0 && frame >= auto_frames {
            break;
        }
    }
}

color_bg_rl :: () -> rl.Color {
    return .{ r = 30, g = 32, b = 40, a = 255 };
}

// clay.Hovered() must be evaluated while the button element is open, which is
// the case both here (config phase) and in button_label (children phase).
button_color :: () -> clay.Color {
    if clay.Hovered() {
        return COLOR_ACCENT;
    }
    return COLOR_PANEL2;
}

button_label :: () -> string {
    if clay.Hovered() {
        return "Hovered!";
    }
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
