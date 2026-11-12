// Port of DragonLib/Tests/Game0/Content/Demos/DualCamera2DDemo.cs.
// One world, follow + overview viewports, one shared Batcher (three renders).
// auto: deterministic movement, camera checks, GPU readback, bounded mesh checks.
#import "Basic";
#import "gfx";

auto_mode: bool;
preferred_driver: F.Graphics_Driver = .NONE;
failed: bool;
frame: s64;
elapsed: float32;
player: Vector2;
facing: Vector2 = .{1, 0};
follow: CameraState;
overview: CameraState;
follow_zoom: float32 = 1;
overview_zoom: float32 = 1;
rotate_overview: bool;
probe: *F.Target;
checks: s64;

check :: (ok: bool, message: string) {
    checks += 1;
    if !ok { failed = true; print("[FAIL] %\n", message); }
}

reset :: () {
    player = .{}; facing = .{1, 0}; follow.target = .{};
    follow_zoom = 1; overview_zoom = 1; rotate_overview = false; elapsed = 0;
}

startup :: () {
    gfx_init();
    if auto_mode probe = F.target_create(F.App.device, 64, 32, "multi-render-regression");
    reset();
}

shutdown :: () {
    if probe != null { F.target_dispose(probe); free(probe); }
    gfx_shutdown();
}

draw_world :: () {
    DrawRectangleRec(.{-12, -7, 24, 14}, .{23, 36, 43, 255});
    for x: -12..12 DrawLineEx(.{cast(float) x, -7}, .{cast(float) x, 7}, 0.025, .{38, 56, 65, 255});
    for y: -7..7 DrawLineEx(.{-12, cast(float) y}, .{12, cast(float) y}, 0.025, .{38, 56, 65, 255});
    DrawLineEx(.{-12, -7}, .{12, -7}, 0.12, WHITE);
    DrawLineEx(.{12, -7}, .{12, 7}, 0.12, WHITE);
    DrawLineEx(.{12, 7}, .{-12, 7}, 0.12, WHITE);
    DrawLineEx(.{-12, 7}, .{-12, -7}, 0.12, WHITE);
    DrawRectangleRec(.{-9.4, -4.4, 2.8, 1.8}, .{217, 108, 75, 255});
    DrawRectangleRec(.{5.7, -4.9, 2.2, 2.2}, .{227, 179, 65, 255});
    DrawRectangleRec(.{-8.4, 3.4, 2.4, 1.6}, .{74, 166, 161, 255});
    DrawRectangleRec(.{5.9, 3.1, 3, 1.4}, .{114, 137, 218, 255});
    for i: 0..4 {
        phase := elapsed * (0.45 + cast(float) i * 0.06) + cast(float) i * 1.25;
        position := Vector2.{GM.cos(phase) * (4.2 + cast(float) i * 0.75), GM.sin(phase * 1.3) * (2.4 + cast(float) i * 0.35)};
        DrawCircleV(position, 0.3, ifx i % 2 == 0 then .{240, 138, 93, 255} else SKYBLUE);
    }
    DrawCircleV(player, 0.48, GOLD);
    DrawLineEx(player, .{player.x + facing.x * 0.72, player.y + facing.y * 0.72}, 0.16, WHITE);
}

draw_view :: (camera: CameraState, viewport: F.Rect_Int, background: Color) {
    F.batcher_clear(gfx_batcher);
    DrawRectangle(0, 0, viewport.w, viewport.h, background);
    BeginMode2D(camera); draw_world(); EndMode2D();
    F.batcher_render(gfx_batcher, gfx_backbuffer(), viewport, true, viewport, true);
}

gpu_regression :: () {
    target := F.drawable_target_target(probe);
    gfx_pass_begin(target, BLACK);
    DrawRectangle(0, 0, 32, 32, .{255, 0, 0, 255});
    // Render identical CPU geometry twice without Clear: the second mesh must upload too.
    F.batcher_render(gfx_batcher, target, .{0, 0, 32, 32}, true, .{0, 0, 32, 32}, true);
    F.batcher_render(gfx_batcher, target, .{32, 0, 32, 32}, true, .{32, 0, 32, 32}, true);
    F.batcher_clear(gfx_batcher);
    DrawRectangle(0, 0, 16, 16, .{0, 0, 255, 255});
    F.batcher_render(gfx_batcher, target, .{32, 0, 32, 32}, true, .{32, 0, 32, 32}, true);
    pixels: [64 * 32] Color;
    F.texture_get_data(F.target_texture(probe), pixels);
    a := pixels[8 * 64 + 8]; b := pixels[8 * 64 + 40]; c := pixels[24 * 64 + 56];
    check(a.r == 255 && a.b == 0, "earlier render retains its vertices");
    check(b.b == 255 && b.r == 0, "later render uses its own vertices");
    check(c.r == 255 && c.b == 0, "same geometry can render twice without clear");
}

render :: () {
    frame += 1; gfx_begin_frame();
    // Exercise resize and an odd-width split; the next event pump updates the backbuffer.
    if auto_mode && frame == 40 F.window_set_size(F.App.window, .{1279, 721});
    if auto_mode && frame == 80 F.window_set_size(F.App.window, .{1280, 720});
    dt := ifx auto_mode then cast(float32) (1.0 / 60.0) else min(GetFrameTime(), cast(float32) (1.0 / 15.0));
    elapsed += dt;
    if IsKeyPressed(.ESCAPE) F.app_exit();
    if IsKeyPressed(.R) reset();
    if IsKeyPressed(.SPACE) rotate_overview = !rotate_overview;
    movement: Vector2;
    if auto_mode {
        movement = .{GM.cos(elapsed), GM.sin(elapsed)};
        rotate_overview = true;
    } else {
        if IsKeyDown(.A) movement.x -= 1;
        if IsKeyDown(.D) movement.x += 1;
        if IsKeyDown(.W) movement.y -= 1;
        if IsKeyDown(.S) movement.y += 1;
        wheel := F.mouse_wheel(F.input_mouse(F.App.input)).y;
        follow_zoom = clamp(follow_zoom + wheel * 0.1, 0.6, 2.2);
        if IsKeyDown(.Q) overview_zoom = max(0.7, overview_zoom - dt);
        if IsKeyDown(.E) overview_zoom = min(1.35, overview_zoom + dt);
    }
    length := GM.sqrt(movement.x * movement.x + movement.y * movement.y);
    if length > 0 {
        facing = .{movement.x / length, movement.y / length};
        player.x = clamp(player.x + facing.x * 6 * dt, -11.4, 11.4);
        player.y = clamp(player.y + facing.y * 6 * dt, -6.4, 6.4);
    }
    amount := 1 - GM.exp(-7 * dt);
    follow.target.x += (player.x - follow.target.x) * amount;
    follow.target.y += (player.y - follow.target.y) * amount;
    width := F.drawable_target_width_in_pixels(gfx_backbuffer());
    height := F.drawable_target_height_in_pixels(gfx_backbuffer());
    left := width / 2; right := width - left;
    if left <= 0 || right <= 0 || height <= 0 return;
    follow.offset = .{cast(float) left * 0.5, cast(float) height * 0.5};
    follow.zoom = 78 * follow_zoom;
    overview = .{offset = .{cast(float) right * 0.5, cast(float) height * 0.5}, zoom = max(1.0, min(cast(float) right / 27, cast(float) height / 17)) * overview_zoom,
        rotation = ifx rotate_overview then GM.sin(elapsed * 0.35) * 0.08 else 0};
    if auto_mode {
        center := F.vector2_transform(follow.target, camera_matrix(follow));
        check(GM.abs(center.x - follow.offset.x) < 0.002 && GM.abs(center.y - follow.offset.y) < 0.002, "follow target stays at viewport center");
        gpu_regression();
    }
    F.graphics_device_clear_color(F.App.device, gfx_backbuffer(), BLACK);
    draw_view(follow, .{0, 0, left, height}, .{16, 24, 32, 255});
    draw_view(overview, .{left, 0, right, height}, .{24, 32, 22, 255});
    F.batcher_clear(gfx_batcher);
    DrawRectangle(left - 2, 0, 4, height, WHITE);
    DrawRectangle(0, 0, left, 5, GOLD); DrawRectangle(left, 0, right, 5, SKYBLUE);
    DrawTextHUD("Follow | WASD move, wheel zoom", 16, 16, WHITE);
    DrawTextHUD("Overview | Space rotate, Q/E zoom", left + 16, 16, WHITE);
    DrawTextHUD("R reset | Esc exit", 16, height - 32, WHITE);
    gfx_pass_end(gfx_backbuffer());
    if auto_mode {
        check(gfx_batcher.meshes.count <= 6, "mesh slots stay bounded over successive frames");
        check(gfx_batcher.materials_pool.count <= 6, "material pool stays bounded over successive frames");
        if failed || frame >= 120 {
            print("DualCamera2D: % (% checks, % frames, % mesh slots)\n", ifx failed then "FAIL" else "PASS", checks, frame, gfx_batcher.meshes.count);
            F.app_exit();
        }
    }
}

main :: () {
    for get_command_line_arguments() {
        if it == "auto" auto_mode = true;
        if it == "vulkan" preferred_driver = .VULKAN;
        if it == "d3d12" preferred_driver = .D3D12;
    }
    F.App.startup = startup; F.App.render = render; F.App.shutdown = shutdown;
    F.app_run(.{application_name = "dual_camera2d", window_title = "DragonLib DualCamera2D - JaiLib", width = 1280, height = 720, resizable = true,
        preferred_graphics_driver = preferred_driver});
    F.app_destroy();
    if failed exit(1);
}
