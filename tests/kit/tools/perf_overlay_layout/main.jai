#import "Basic";
F :: #import "foster";
UI :: #import "kit/ui";
PERF :: #import "kit/tools/perf_overlay";

overlay: PERF.Overlay;
font: F.Msdf_Font;
font_texture: *F.Texture;
target: *F.Target;
case_index: int;

main :: () {
    F.App.startup = start;
    F.App.render = render;
    F.App.shutdown = stop;
    F.app_run(.{ application_name = "Performance overlay regression", width = 800, height = 600, update_mode = F.update_mode_unlocked() });
    F.app_destroy();
}

start :: () {
    _ = F.defaults_batch_material(F.App.device);
    _ = F.defaults_msdf_material(F.App.device);
    source := F.defaults_msdf_font(F.App.device);
    font = source.*;
    font.Glyphs = .{};
    font.LineHeight = source.LineHeight * source.Size;
    for glyph: source.Glyphs {
        g := glyph;
        g.al /= cast(float32) source.Atlas.Width;
        g.ar /= cast(float32) source.Atlas.Width;
        g.at /= cast(float32) source.Atlas.Height;
        g.ab /= cast(float32) source.Atlas.Height;
        array_add(*font.Glyphs, g);
    }
    font_texture = F.texture_create_from_colors(F.App.device, source.Atlas.Width, source.Atlas.Height, source.Atlas.Data);
    assert(PERF.init(*overlay, F.App.device, *font, font_texture));
    target = F.target_create(F.App.device, 800, 600);
}

render :: () {
    scale: float32 = ifx case_index % 2 == 0 then 1 else 1.25;
    overlay.corner = cast(PERF.Corner) (case_index / 6);
    overlay.visible = true;
    overlay.head = 0;
    overlay.count = 0;
    overlay.summary = .{};
    overlay.elapsed = 0;
    overlay.scope_count = 0;
    samples := int.[0, 5, 240][(case_index % 6) / 2];
    for i: 0..samples - 1 PERF.frame(*overlay, cast(float32) (8 + i % 40) / 1000);
    if samples == 240 {
        overlay.scope_count = 2;
        overlay.scopes[0] = .{ name = "A long profiler scope name that must be clipped", ms_per_frame = 1.23456, calls_per_frame = 3.25 };
        overlay.scopes[1] = .{ name = "render", ms_per_frame = .01789, calls_per_frame = 1 };
    }
    surface := F.drawable_target_target(target);
    background := F.Color.{ 7, 11, 19, 255 };
    F.graphics_device_clear_color(F.App.device, surface, background);
    PERF.draw(*overlay, surface, scale);
    assert(overlay.ctx.error_count == 0 && !overlay.ctx.pool_overflow);
    panel, ok := UI.ui_element_rect(*overlay.ctx, "perf-panel");
    assert(ok);
    graph, found := UI.ui_element_rect(*overlay.ctx, "perf-graph");
    assert(found);
    assert(graph.x >= panel.x && graph.x + graph.w <= panel.x + panel.w + .01);
    assert(graph.y >= panel.y && graph.y + graph.h <= panel.y + panel.h + .01);
    image := F.image_create(target.Width, target.Height);
    defer F.image_destroy(*image);
    F.texture_get_data(F.target_texture(target), image.Data);
    white, outside: int;
    for p, i: image.Data {
        x := cast(float32) (i % target.Width);
        y := cast(float32) (i / target.Width);
        if x < panel.x * scale - 1 || x > (panel.x + panel.w) * scale + 1 || y < panel.y * scale - 1 || y > (panel.y + panel.h) * scale + 1 {
            if p.r != background.r || p.g != background.g || p.b != background.b outside += 1;
        }
        if y >= (panel.y + 8) * scale && y < (panel.y + 36) * scale && p.r > 160 && p.g > 160 && p.b > 160 white += 1;
    }
    assert(outside == 0, "Performance graph escaped its panel: case %, % pixels", case_index, outside);
    assert(white > 20, "Performance labels did not render: case %", case_index);
    overlay.visible = false;
    F.graphics_device_clear_color(F.App.device, surface, background);
    PERF.draw(*overlay, surface, scale);
    F.texture_get_data(F.target_texture(target), image.Data);
    for p: image.Data assert(p.r == background.r && p.g == background.g && p.b == background.b, "Hidden overlay still drew pixels");
    case_index += 1;
    if case_index == 24 {
        print("perf_overlay_regression: PASS (four corners, two scales, empty/partial/full history, text, bounds, hidden)\n");
        F.app_exit();
    }
}

stop :: () {
    PERF.dispose(*overlay);
    array_free(font.Glyphs);
    F.texture_dispose(font_texture);
    free(font_texture);
    F.target_dispose(target);
    free(target);
}
