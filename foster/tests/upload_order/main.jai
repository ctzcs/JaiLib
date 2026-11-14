// Pixel regression: a later upload must not change an earlier draw in the frame.
#import "Basic";
F :: #import "foster";

batch: *F.Batcher;
target: *F.Target;
frames: int;

main :: () {
    F.App.startup = start;
    F.App.render = render;
    F.App.shutdown = stop;
    F.app_run(.{ application_name = "render regression", width = 64, height = 32, update_mode = F.update_mode_unlocked() });
    F.app_destroy();
}

start :: () {
    batch = F.batcher_create(F.App.device);
    target = F.target_create(F.App.device, 64, 32);
}

render :: () {
    surface := F.drawable_target_target(target);
    F.graphics_device_clear_color(F.App.device, surface, .{ 0, 0, 0, 255 });
    F.batcher_clear(batch);
    F.batcher_rect(batch, .{ 0, 0, 32, 32 }, .{ 255, 0, 0, 255 });
    F.batcher_render(batch, surface);
    F.batcher_clear(batch);
    F.batcher_rect(batch, .{ 32, 0, 32, 32 }, .{ 0, 0, 255, 255 });
    F.batcher_render(batch, surface);
    pixels: [2048] F.Color;
    F.texture_get_data(F.target_texture(target), pixels);
    assert(pixels[16 * 64 + 16].r == 255 && pixels[16 * 64 + 16].b == 0, "Later buffer upload overwrote first draw");
    assert(pixels[16 * 64 + 48].b == 255 && pixels[16 * 64 + 48].r == 0, "Second draw missing");
    F.graphics_device_clear_color(F.App.device, surface, .{ 0, 0, 0, 255 });
    F.batcher_clear(batch);
    F.batcher_rect(batch, .{ 0, 0, 32, 32 }, .{ 255, 0, 0, 255 });
    // Splitting and restoring state without geometry must preserve the previous span.
    F.batcher_set_scissor(batch, .{ 0, 0, 64, 32 }, true);
    F.batcher_set_scissor(batch, .{}, false);
    F.batcher_rect(batch, .{ 32, 0, 32, 32 }, .{ 0, 0, 255, 255 });
    F.batcher_render(batch, surface);
    F.texture_get_data(F.target_texture(target), pixels);
    assert(pixels[16 * 64 + 16].r == 255 && pixels[16 * 64 + 48].b == 255, "Batch merge lost an earlier element range");
    frames += 1;
    if frames == 3 {
        print("render_regression: PASS (upload order and merged batch ranges, three frames)\n");
        F.app_exit();
    }
}

stop :: () {
    F.batcher_destroy(batch);
    F.target_dispose(target);
    free(target);
}
