// M5 sample: text rendering — bakes a TTF through stb_truetype into a
// SpriteFont and renders through the Batcher. ESC or window close exits.
// Build from the repo root:  jai first.jai - text
// Uses the system console/arial font, or font.ttf next to the exe if present.

#import "Basic";
#import "File";
#import "Math";
#import "foster";

main :: () {
    App.startup = startup;
    App.render  = render;
    App.update  = update;

    app_run(.{
        application_name = "jfoster text sample",
        window_title     = "jfoster text (ESC to quit)",
        width  = 1280,
        height = 720,
    });

    app_destroy();
}

State :: struct {
    batcher: *Batcher;
    font:    *Sprite_Font;
}

S: State;

WAVE_TEXT :: "sine wave text";

startup :: () {
    S.batcher = batcher_create(App.device, "ui");

    font := font_load("font.ttf");
    if font == null font = font_load("C:/Windows/Fonts/consola.ttf");
    if font == null font = font_load("C:/Windows/Fonts/arial.ttf");
    assert(font != null, "no font found (place a font.ttf next to the exe)");

    S.font = sprite_font_create_from_font(App.device, font, 48, ASCII_CODEPOINTS);
    window_start_text_input(App.window);
}

update :: () {
    kb := input_keyboard(App.input);
    if keyboard_pressed(kb, .ESCAPE) app_exit();
}

char_str :: (c: u8) -> string {
    str: string = .{ data = c_buffer_ptr(c), count = 1 };
    return str;
}

c_buffer_ptr :: (c: u8) -> *u8 {
    buf := New(u8);
    buf.* = c;
    return buf;
}

render :: () {
    t := App.time.elapsed;

    batcher_clear(S.batcher);
    b := S.batcher;

    // background
    batcher_rect_gradient(b, .{ 0, 0, 1280, 720 },
        Color.{ 20, 22, 28, 255 }, Color.{ 20, 22, 28, 255 },
        Color.{ 40, 36, 52, 255 }, Color.{ 28, 34, 46, 255 });

    // big title + colored line
    sprite_font_draw(S.font, b, "jfoster", .{ 100, 100 }, Color_White);
    sprite_font_draw(S.font, b, "Hello, Foster!", .{ 100, 220 }, Color.{ 120, 220, 255, 255 });

    // wave text (per-char advance)
    x := 100.0;
    for i: 0..WAVE_TEXT.count-1 {
        ch := WAVE_TEXT[i];
        y := cast(float) (380 + sin(t * 3.0 + cast(float) i * 0.4) * 20);
        sprite_font_draw(S.font, b, char_str(ch), Vector2.{ x, y }, Color.{ 255, 200, 120, 255 });
        c := sprite_font_get_character(S.font, ch);
        x += c.Advance + 2;
    }

    // scaled text via matrix
    batcher_push_matrix(b, matrix3x2_create_scale(0.6, 0.6));
    sprite_font_draw(S.font, b, "scaled text at 0.6x matrix", .{ 166, 520 }, Color.{ 180, 255, 180, 255 });
    batcher_pop_matrix(b);

    // measured box around it
    size := sprite_font_size_of(S.font, "scaled text at 0.6x matrix");
    batcher_rect_line(b, .{ 100, 520, size.x * 0.6, size.y * 0.6 }, 1, Color.{ 255, 120, 120, 180 });

    batcher_render(b, drawable_target_window(App.window));
}
