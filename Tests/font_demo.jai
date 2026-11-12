// Embedded MSDF + explicit Chinese TTF, with actual GPU text readback.
#import "Basic";
#import "File";
#import "gfx";
#import "test_support";
CF :: #import "thirdparty/clay_foster";

state: Test_State;
auto_mode: bool;
frame: s64;
driver: F.Graphics_Driver = .NONE;
chinese: *TXT.Text_Font;
font_path: string;
snapshot_path: string;
shaping_font: *TXT.Text_Font;
dynamic_font: *TXT.Text_Font;
CHINESE :: "你好，世界！中文字体测试：空格 换行 缩放";
WIDTH :: 1000;
HEIGHT :: 720;
canvas: *F.Target;

near :: (a: float32, b: float32) -> bool { return GM.abs(a - b) < 0.01; }

read_probe :: (probe: *F.Target) -> [] Color {
    pixels := NewArray(probe.Width * probe.Height, Color);
    F.texture_get_data(F.target_texture(probe), pixels);
    return pixels;
}

lit_pixels :: (pixels: [] Color) -> s64 {
    count: s64;
    for p: pixels if p.r > 10 || p.g > 10 || p.b > 10 count += 1;
    return count;
}

verify_fonts :: () {
    sample := F.image_create(2, 2, .{23, 87, 201, 128});
    png := F.image_encode_png(sample);
    decoded := F.image_decode(png);
    expect(*state, decoded.Width == 2 && decoded.Height == 2 && decoded.Data[0].r == 23 && decoded.Data[0].b == 201 && decoded.Data[0].a == 128,
        "PNG ownership and RGBA channels survive encode/decode");
    F.image_destroy(*sample); F.image_destroy(*decoded); free(png.data);
    expect(*state, gfx_hud_font.IsMsdf && gfx_hud_source_font == null, "gfx default is embedded MSDF");
    expect(*state, CF.clay_sprite_font.IsMsdf, "clay default is embedded MSDF");
    one := MeasureText("A", 32);
    spaced := MeasureText("A A", 32);
    expect(*state, spaced.x > one.x * 2, "space advances without a visible quad");
    expect(*state, near(MeasureText("A\nA", 32).y, one.y * 2), "newline advances line height");
    expect(*state, near(MeasureText("😀", 32).x, MeasureText("?", 32).x), "missing Unicode scalar uses one fallback glyph");
    expect(*state, MeasureText("", 32).x == 0 && MeasureText("A", 0).x == 0, "empty and zero-size text");
    invalid: [2] u8 = .[0xe4, 0xbd]; cursor: s64;
    _ := TXT.text_next_codepoint(*invalid[0], 2, *cursor);
    expect(*state, cursor == 1, "truncated UTF-8 stays in bounds and makes progress");
    label := "Ag 1?";
    cfg := CF.clay.TextElementConfig.{fontSize = 32, textColor = .{255, 255, 255, 255}};
    slice := CF.clay.StringSlice.{length = cast(s32) label.count, chars = label.data, baseChars = label.data};
    measured := CF.measure_text(slice, *cfg, 0);
    expect(*state, near(measured.width, MeasureText(label, 32).x) && measured.height > 0, "native clay measurement matches gfx; automatic line height");
    cfg.letterSpacing = 3;
    measured_spaced := CF.measure_text(slice, *cfg, 0);
    expect(*state, near(measured_spaced.width - measured.width, 12), "letter spacing applied once between glyphs");
    cfg.letterSpacing = 0;

    probe := F.target_create(F.App.device, 256, 128, "font-readback");
    defer { F.target_dispose(probe); free(probe); }
    target := F.drawable_target_target(probe);
    gfx_pass_begin(target, BLACK);
    DrawText(label, 8, 8, 32, WHITE);
    gfx_pass_end(target);
    pixels := read_probe(probe); defer free(pixels.data);
    expect(*state, lit_pixels(pixels) > 150 && lit_pixels(pixels) < 2000, "MSDF produces glyph coverage, not blank or solid quads");
    gfx_pass_begin(target, BLACK);
    CF.draw_text(gfx_batcher, .{x = 8, y = 8, width = 200, height = 80},
        .{length = cast(s32) label.count, chars = label.data}, *cfg);
    gfx_pass_end(target);
    clay_pixels := read_probe(probe); defer free(clay_pixels.data);
    expect(*state, memcmp(pixels.data, clay_pixels.data, pixels.count * size_of(Color)) == 0, "clay and gfx draw identical default text pixels");
    for size: s32.[12, 24, 64] {
        gfx_pass_begin(target, BLACK);
        DrawText("Ag", 4, 4, size, WHITE);
        gfx_pass_end(target);
        scaled := read_probe(probe);
        expect(*state, lit_pixels(scaled) > size, "MSDF draws at size %", size);
        free(scaled.data);
    }
    gfx_pass_begin(target, BLACK);
    DrawText("MMMM", 4, 4, 48, .{255, 255, 255, 128});
    DrawRectangle(240, 0, 16, 16, .{255, 0, 0, 255});
    gfx_pass_end(target);
    alpha := read_probe(probe); defer free(alpha.data);
    peak: u8;
    for y: 0..100 for x: 0..200 peak = max(peak, alpha[y * 256 + x].r);
    expect(*state, peak >= 120 && peak <= 130, "translucent text uses premultiplied color once");
    expect(*state, alpha[4 * 256 + 244].r == 255 && alpha[4 * 256 + 244].g == 0, "text restores material and blend for subsequent shapes");
    gfx_pass_begin(target, BLACK);
    BeginMode2D(.{offset = .{100, 30}, zoom = 1});
    DrawText("A", 0, 0, 32, WHITE);
    EndMode2D();
    expect(*state, gfx_batcher.matrixDepth == 0, "text balances the matrix stack");
    gfx_pass_end(target);
    transformed := read_probe(probe); defer free(transformed.data);
    outside: s64; inside: s64;
    for p, i: transformed {
        if p.r > 10 {
            x := i % 256; y := i / 256;
            if x >= 98 && x < 150 && y >= 30 && y < 80 inside += 1;
            else outside += 1;
        }
    }
    expect(*state, inside > 30 && outside == 0, "text respects the active camera transform");
}

verify_chinese :: () {
    gfx_shutdown();
    gfx_init(font_path, extra_glyphs = CHINESE);
    expect(*state, !gfx_hud_font.IsMsdf && gfx_hud_source_font != null, "gfx accepts a custom Chinese TTF/TTC repertoire");
    expect(*state, size_of(F.STBTT_Font_Info) == 160, "stb font info matches x64 C ABI");
    glyph := F.font_get_character(chinese.source, 20320, 24); // 你
    expect(*state, glyph.Visible && glyph.Advance >= 12 && glyph.Advance <= 36, "Chinese TTF has a real glyph and valid metrics");
    label := "你好 世界";
    cfg := CF.clay.TextElementConfig.{fontSize = 32, letterSpacing = 2, lineHeight = 44, textColor = .{255, 255, 255, 255}};
    measured := CF.measure_text(.{length = cast(s32) label.count, chars = label.data, baseChars = label.data}, *cfg, 0);
    exact := TXT.text_measure(chinese, label, 32, 2, 44);
    expect(*state, near(measured.width, exact.x) && near(measured.height, 44), "Chinese clay layout decodes UTF-8 codepoints");
    a := TXT.text_measure(chinese, "你", 32);
    expect(*state, near(TXT.text_measure(chinese, "你你", 32).x, 2 * a.x), "Chinese advances once per scalar, not once per byte");
    expect(*state, near(MeasureText(label, 32).x, TXT.text_measure(chinese, label, 32).x), "gfx Chinese measurement uses configured repertoire");
    probe := F.target_create(F.App.device, 256, 96, "chinese-readback");
    defer { F.target_dispose(probe); free(probe); }
    target := F.drawable_target_target(probe);
    gfx_pass_begin(target, BLACK);
    TXT.text_draw(chinese, gfx_batcher, label, .{8, 8}, 32, WHITE, 2, 44);
    gfx_pass_end(target);
    reference := read_probe(probe); defer free(reference.data);
    expect(*state, lit_pixels(reference) > 200, "Chinese glyphs produce actual GPU pixels");
    gfx_pass_begin(target, BLACK);
    CF.draw_text(gfx_batcher, .{x = 8, y = 8, width = 240, height = 80}, .{length = cast(s32) label.count, chars = label.data}, *cfg);
    gfx_pass_end(target);
    actual := read_probe(probe); defer free(actual.data);
    expect(*state, memcmp(reference.data, actual.data, reference.count * size_of(Color)) == 0, "clay Chinese draw uses the same layout as text module");
    gfx_shutdown();
    gfx_init();
}

verify_dynamic_fonts :: () {
    dynamic_font = TXT.text_font_create(F.App.device, font_path);
    before := dynamic_font.glyphs.count;
    dynamic_label := "动态补字汉字";
    _ := TXT.text_measure(dynamic_font, dynamic_label, 32);
    expect(*state, dynamic_font.glyphs.count == before + 5 && dynamic_font.pages.count == 1, "unlisted Chinese characters are packed on demand into a shared page");
    before = dynamic_font.glyphs.count;
    _ := TXT.text_measure(dynamic_font, dynamic_label, 32);
    expect(*state, dynamic_font.glyphs.count == before && dynamic_font.pages.count == 1, "repeated layout reuses dynamic glyph cache");
    _ := TXT.text_font_add_fallback(gfx_text_font, dynamic_font);
    mixed := TXT.text_layout_create(gfx_text_font, "A汉B", 32);
    expect(*state, mixed.glyphs.count == 3 && mixed.glyphs[0].font == gfx_text_font && mixed.glyphs[1].font == dynamic_font && mixed.glyphs[2].font == gfx_text_font,
        "fallback chain changes font only for unavailable glyphs");
    TXT.text_layout_destroy(*mixed);
    _ := CF.clay_foster_set_font(7, dynamic_font);
    cfg := CF.clay.TextElementConfig.{fontId = 7, fontSize = 32, textColor = .{255, 255, 255, 255}};
    measured := CF.measure_text(.{length = cast(s32) dynamic_label.count, chars = dynamic_label.data}, *cfg, 0);
    exact := TXT.text_measure(dynamic_font, dynamic_label, 32);
    expect(*state, near(measured.width, exact.x) && near(measured.height, exact.y), "clay fontId measures registered dynamic font");
    probe := F.target_create(F.App.device, 256, 96, "dynamic-font-test");
    defer { F.target_dispose(probe); free(probe); }
    target := F.drawable_target_target(probe);
    gfx_pass_begin(target, BLACK);
    TXT.text_draw(dynamic_font, gfx_batcher, dynamic_label, .{4, 4}, 32, WHITE);
    gfx_pass_end(target);
    before_pixels := read_probe(probe); defer free(before_pixels.data);
    // Fill several additional rows; prior texture coordinates must stay valid.
    TXT.text_font_prepare(dynamic_font, "天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏");
    gfx_pass_begin(target, BLACK);
    CF.draw_text(gfx_batcher, .{x = 4, y = 4, width = 248, height = 88}, .{length = cast(s32) dynamic_label.count, chars = dynamic_label.data}, *cfg);
    gfx_pass_end(target);
    after_pixels := read_probe(probe); defer free(after_pixels.data);
    expect(*state, lit_pixels(before_pixels) > 400 && memcmp(before_pixels.data, after_pixels.data, before_pixels.count * size_of(Color)) == 0,
        "appending dynamic glyphs preserves previous pixels; clay fontId drawing agrees");
    shaping_font = TXT.text_font_create(F.App.device, "C:/Windows/Fonts/arial.ttf", bake_size = 40);
    expect(*state, shaping_font != null, "load OpenType shaping fixture");
    if shaping_font == null return;
    av := TXT.text_measure(shaping_font, "AV", 40);
    separate := TXT.text_measure(shaping_font, "A", 40).x + TXT.text_measure(shaping_font, "V", 40).x;
    expect(*state, av.x < separate, "HarfBuzz applies OpenType pair kerning");
    arabic := TXT.text_layout_create(shaping_font, "سلام", 40, options = .{direction = .Right_To_Left, language = "ar"});
    expect(*state, arabic.glyphs.count == 3 && arabic.glyphs[0].cluster > arabic.glyphs[2].cluster,
        "Arabic contextual shaping, lam-alef ligature and RTL glyph order");
    nominal := F.font_get_glyph_index(shaping_font.source, 0x633);
    expect(*state, arabic.glyphs[2].glyph_id != cast(u32) nominal && arabic.glyphs[2].glyph_id != 0, "contextual glyph differs from isolated Arabic form");
    gfx_pass_begin(target, BLACK);
    TXT.text_layout_draw(*arabic, gfx_batcher, .{4, 4}, WHITE);
    gfx_pass_end(target);
    shaped_pixels := read_probe(probe); defer free(shaped_pixels.data);
    expect(*state, lit_pixels(shaped_pixels) > 200, "shaped glyph IDs are rasterized and rendered");
    TXT.text_layout_destroy(*arabic);
    accents := TXT.text_layout_create(shaping_font, "x\u0301", 40);
    expect(*state, accents.glyphs.count == 2 && accents.glyphs[0].cluster == accents.glyphs[1].cluster, "combining mark keeps base cluster");
    TXT.text_layout_destroy(*accents);
}

startup :: () {
    gfx_init();
    _ := CF.clay_foster_setup(F.App.device);
    verify_fonts();
    CF.clay_foster_shutdown();
    if font_path != "" {
        chinese = TXT.text_font_create(F.App.device, font_path, CHINESE, 24);
        if chinese != null {
            _ := CF.clay_foster_setup(F.App.device, font_path, CHINESE);
            verify_chinese();
            verify_dynamic_fonts();
        } else expect(*state, false, "requested Chinese font loads");
    } else {
        print("Chinese tests skipped: supply a TTF/TTC path as an argument.\n");
        _ := CF.clay_foster_setup(F.App.device);
    }
    canvas = F.target_create(F.App.device, WIDTH, HEIGHT, "font-demo");
}

render :: () {
    frame += 1;
    gfx_begin_frame();
    target := F.drawable_target_target(canvas);
    gfx_pass_begin(target, .{20, 25, 34, 255});
    DrawText("JaiLib / Font rendering", 30, 18, 36, WHITE);
    DrawText("Embedded Roboto MSDF - no external font files", 30, 72, 22, SKYBLUE);
    DrawText("12 px: The quick brown fox 0123456789", 30, 118, 12, WHITE);
    DrawText("24 px: The quick brown fox 0123456789", 30, 155, 24, WHITE);
    DrawText("48 px: Smooth scaling", 30, 204, 48, GOLD);
    DrawText("Spaces stay visible.\nNew lines share the same line metrics.", 30, 288, 24, WHITE);
    DrawText("50% alpha", 680, 288, 28, .{255, 255, 255, 128});
    DrawRectangle(30, 380, 940, 2, SKYBLUE);
    if chinese != null {
        TXT.text_draw(chinese, gfx_batcher, "你好，世界！中文字体测试", .{30, 404}, 32, WHITE);
        TXT.text_draw(chinese, gfx_batcher, "空格 换行\n缩放", .{30, 455}, 28, GOLD);
        value := "你好，世界！";
        cfg := CF.clay.TextElementConfig.{fontSize = 40, letterSpacing = 3, textColor = .{102, 191, 255, 255}};
        CF.draw_text(gfx_batcher, .{x = 540, y = 455, width = 400, height = 80},
            .{length = cast(s32) value.count, chars = value.data}, *cfg);
        DrawText("clay UTF-8 / 3 px letter spacing", 540, 525, 20, SKYBLUE);
    } else DrawText("Pass a Chinese TTF/TTC path to enable CJK samples.", 30, 410, 22, WHITE);
    if dynamic_font != null DrawText("Fallback: 动态补字汉字", 30, 577, 24, WHITE);
    if shaping_font != null TXT.text_draw(shaping_font, gfx_batcher, "سلام", .{680, 570}, 40, GOLD);
    DrawText(tprint("GPU tests: % passed / % failed   |   Esc to exit", state.passed, state.failed), 30, 647, 22, WHITE);
    gfx_pass_end(target);
    if frame == 1 && snapshot_path != "" {
        pixels := read_probe(canvas);
        img := F.Image.{Width = WIDTH, Height = HEIGHT, Data = pixels};
        png := F.image_encode_png(img);
        _ := write_entire_file(snapshot_path, cast(string) png);
        free(png.data);
        free(pixels.data);
    }
    gfx_blit_pass(gfx_backbuffer(), null, F.target_texture(canvas),
        F.drawable_target_width_in_pixels(gfx_backbuffer()), F.drawable_target_height_in_pixels(gfx_backbuffer()), BLACK);
    if IsKeyPressed(.ESCAPE) || (auto_mode && frame >= 60) F.app_exit();
}

shutdown :: () {
    CF.clay_foster_shutdown();
    if dynamic_font != null TXT.text_font_remove_fallback(gfx_text_font, dynamic_font);
    TXT.text_font_destroy(dynamic_font);
    TXT.text_font_destroy(shaping_font);
    TXT.text_font_destroy(chinese);
    F.target_dispose(canvas); free(canvas);
    gfx_shutdown();
}

main :: () {
    state = test_begin();
    for arg: get_command_line_arguments() {
        if arg == "auto" auto_mode = true;
        if arg == "vulkan" driver = .VULKAN;
        if arg == "d3d12" driver = .D3D12;
        if arg.count > 4 {
            ext := arg; ext.data += ext.count - 4; ext.count = 4;
            if ext == ".ttf" || ext == ".ttc" font_path = arg;
            if ext == ".png" snapshot_path = arg;
        }
    }
    if font_path == "" {
        f, ok := file_open("C:/Windows/Fonts/simhei.ttf");
        if ok { file_close(*f); font_path = "C:/Windows/Fonts/simhei.ttf"; }
    }
    F.App.startup = startup; F.App.render = render; F.App.shutdown = shutdown;
    F.app_run(.{application_name = "font_demo", window_title = "JaiLib Fonts - MSDF and Chinese", width = WIDTH, height = HEIGHT, resizable = true, preferred_graphics_driver = driver});
    F.app_destroy();
    if !test_summary("font rendering", *state) exit(1);
}
