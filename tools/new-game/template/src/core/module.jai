#import "Basic";
F :: #import "foster";
#load "world.jai";
#load "services.jai";
render :: (world: *World, services: *Services) {
    target := F.drawable_target_window(F.App.window);
    F.graphics_device_clear_color(F.App.device, target, .{24, 28, 36, 255});
    F.batcher_clear(services.batcher);
    F.batcher_rect(services.batcher, F.Rect.{100, 100, 180, 100}, F.Color.{90, 180, 255, 255});
    F.batcher_render(services.batcher, target);
}
