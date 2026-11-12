// clay_foster.jai
// jfoster (SDL3 + SDL_GPU) renderer for the clay UI library
// (bindings/clay/module.jai) — replaces clay_raylib.jai.
//
// Renders clay's RenderCommandArray through the game's shared Batcher:
// RECTANGLE -> batcher_rect_rounded, BORDER -> rect strips (corner radius
// honored via batcher_rect_rounded_line), TEXT -> SpriteFont, nested clips ->
// batcher scissor stack (intersected manually, mirroring the raylib backend).
//
// Text measurement restores the font's saved render-thread Jai context.

#import "Basic";

CLAYF :: #import "jfoster";   // 独特别名：gfx.jai 也导出 F
clay :: #import "thirdparty/clay/module";

// UTF-8 layout and drawing share the same font and advances.
TXT :: #import "text";
clay_text_font: *TXT.Text_Font;
clay_sprite_font: *CLAYF.Sprite_Font; // borrowed from clay_text_font
// Other font IDs borrow Text_Font instances; unregister before destroying them.
clay_fonts: [256] *TXT.Text_Font;
Clay_Custom_Draw :: #type (batcher: *CLAYF.Batcher, bounds: clay.BoundingBox, data: *void, user: *void);
clay_custom_draw: Clay_Custom_Draw;
clay_custom_user: *void;
// Call between layouts after changing a registered font's fallback chain.
clay_foster_invalidate_text :: () {
    if clay.GetCurrentContext() != null clay.ResetMeasureTextCache();
}
clay_foster_set_custom_draw :: (draw: Clay_Custom_Draw, user: *void = null) {
    clay_custom_draw = draw; clay_custom_user = user;
}
clay_foster_set_font :: (id: u16, font: *TXT.Text_Font) -> bool {
    if id == 0 || id >= 256 return false;
    if clay_fonts[id] != font {
        clay_fonts[id] = font;
        clay_foster_invalidate_text();
    }
    return true;
}
clay_foster_font :: (id: u16) -> *TXT.Text_Font #c_call {
    if id < 256 && clay_fonts[id] != null return clay_fonts[id];
    return clay_text_font;
}
CLAY_FONT_SIZE :: 24.0;

clay_foster_setup :: (device: *CLAYF.Graphics_Device, font_path: string = "", extra_glyphs: string = "") -> bool {
    clay_text_font = TXT.text_font_create(device, font_path, extra_glyphs, CLAY_FONT_SIZE);
    if clay_text_font == null {
        print("clay: font load failed %, using embedded Roboto MSDF\n", font_path);
        clay_text_font = TXT.text_font_create(device);
    }
    clay_sprite_font = clay_text_font.sprite;
    clay_fonts[0] = clay_text_font;
    clay_foster_invalidate_text();
    return true;
}

clay_foster_shutdown :: () {
    TXT.text_font_destroy(clay_text_font);
    clay_text_font = null;
    clay_sprite_font = null;
    for *font: clay_fonts { <<font = null; }
    clay_custom_draw = null; clay_custom_user = null;
    array_free(scissor_stack);
}
// --- color / rect helpers ---

color_to_f :: (c: clay.Color) -> CLAYF.Color {
    clamp8 :: (v: float) -> u8 {
        if v < 0.0 { return 0; }
        if v > 255.0 { return 255; }
        return cast(u8) cast(s64) (v + 0.5);
    }
    return .{ r = clamp8(c.r), g = clamp8(c.g), b = clamp8(c.b), a = clamp8(c.a) };
}

bound_to_rect :: (b: clay.BoundingBox) -> CLAYF.Rect {
    return .{ x = b.x, y = b.y, w = b.width, h = b.height };
}

// C ABI entry. text_measure_raw restores the explicitly saved font context.
measure_text :: (text: clay.StringSlice, config: *clay.TextElementConfig, user_data: u64) -> clay.Dimensions #c_call {
    if config == null return .{};
    size := TXT.text_measure_raw(clay_foster_font(config.fontId), text.chars, cast(s64) text.length,
        cast(float32) config.fontSize, cast(float32) config.letterSpacing, cast(float32) config.lineHeight);
    return .{size.x, size.y};
}
// --- render ---

scissor_stack: [..] CLAYF.Rect_Int;
scissor_depth: s32 = 0;

push_scissor :: (b: *CLAYF.Batcher, rect_in: CLAYF.Rect_Int) {
    rect := rect_in;
    // 与父剪裁求交，嵌套 clip 保持正确（镜像旧 raylib 后端的语义）
    if scissor_depth > 0 {
        parent := scissor_stack[scissor_depth - 1];
        x1 := max(rect.x, parent.x);
        y1 := max(rect.y, parent.y);
        x2 := min(rect.x + rect.w, parent.x + parent.w);
        y2 := min(rect.y + rect.h, parent.y + parent.h);
        rect = .{ x = x1, y = y1, w = max(cast(s32) 0, x2 - x1), h = max(cast(s32) 0, y2 - y1) };
    }
    array_add(*scissor_stack, rect);
    scissor_depth += 1;
    CLAYF.batcher_set_scissor(b, rect, true);
}

pop_scissor :: (b: *CLAYF.Batcher) {
    if scissor_depth > 0 {
        scissor_depth -= 1;
        scissor_stack.count -= 1;
    }
    if scissor_depth > 0 {
        top := scissor_stack[scissor_depth - 1];
        CLAYF.batcher_set_scissor(b, top, true);
    } else {
        CLAYF.batcher_set_scissor(b, .{}, false);
    }
}

draw_rectangle :: (b: *CLAYF.Batcher, bound: clay.BoundingBox, color: clay.Color, radius: float) {
    if bound.width <= 0.0 || bound.height <= 0.0 return;
    if radius > 0.5 {
        // Foster 的圆角是像素半径，直接用；钳到短边一半防止溢出。
        r := radius;
        if r > bound.width * 0.5  r = bound.width * 0.5;
        if r > bound.height * 0.5 r = bound.height * 0.5;
        CLAYF.batcher_rect_rounded(b, bound_to_rect(bound), r, color_to_f(color));
    } else {
        CLAYF.batcher_rect(b, bound_to_rect(bound), color_to_f(color));
    }
}

draw_border :: (b: *CLAYF.Batcher, bound: clay.BoundingBox, config: *clay.BorderElementConfig) {
    lw := cast(float) config.left.width;
    rw := cast(float) config.right.width;
    tw := cast(float) config.top.width;
    bw := cast(float) config.bottom.width;
    if lw > 0.0 {
        CLAYF.batcher_rect(b, .{ x = bound.x, y = bound.y, w = lw, h = bound.height }, color_to_f(config.left.color));
    }
    if rw > 0.0 {
        CLAYF.batcher_rect(b, .{ x = bound.x + bound.width - rw, y = bound.y, w = rw, h = bound.height }, color_to_f(config.right.color));
    }
    if tw > 0.0 {
        CLAYF.batcher_rect(b, .{ x = bound.x, y = bound.y, w = bound.width, h = tw }, color_to_f(config.top.color));
    }
    if bw > 0.0 {
        CLAYF.batcher_rect(b, .{ x = bound.x, y = bound.y + bound.height - bw, w = bound.width, h = bw }, color_to_f(config.bottom.color));
    }
}

// Top-left placement, matching the exact metrics returned to clay.
draw_text :: (b: *CLAYF.Batcher, bound: clay.BoundingBox, text: clay.String, config: *clay.TextElementConfig) {
    if config == null return;
    view := string.{count = cast(s64) text.length, data = cast(*u8) text.chars};
    TXT.text_draw(clay_foster_font(config.fontId), b, view, .{bound.x, bound.y}, cast(float32) config.fontSize,
        color_to_f(config.textColor), cast(float32) config.letterSpacing, cast(float32) config.lineHeight);
}
clay_foster_render :: (b: *CLAYF.Batcher, commands: *clay.RenderCommandArray) {
    if commands == null || commands.length <= 0 {
        return;
    }
    scissor_depth = 0;
    scissor_stack.count = 0;
    saved_scissor := b.current_batch.Scissor;
    saved_has_scissor := b.current_batch.HasScissor;
    defer CLAYF.batcher_set_scissor(b, saved_scissor, saved_has_scissor);
    if saved_has_scissor { array_add(*scissor_stack, saved_scissor); scissor_depth = 1; }

    for i: 0..commands.length-1 {
        command := commands.internalArray[i];
        bound := command.boundingBox;

        if command.commandType == clay.RenderCommandType.SCISSOR_START {
            push_scissor(b, .{
                x = cast(s32) bound.x,
                y = cast(s32) bound.y,
                w = cast(s32) bound.width,
                h = cast(s32) bound.height,
            });
        } else if command.commandType == clay.RenderCommandType.SCISSOR_END {
            pop_scissor(b);
        } else if command.commandType == clay.RenderCommandType.RECTANGLE {
            config := command.config.rectangleElementConfig;
            if config != null {
                draw_rectangle(b, bound, config.color, config.cornerRadius.topLeft);
            } else {
                draw_rectangle(b, bound, .{ r = 255.0, g = 0.0, b = 255.0, a = 255.0 }, 0.0);
            }
        } else if command.commandType == clay.RenderCommandType.BORDER {
            config := command.config.borderElementConfig;
            if config != null {
                draw_border(b, bound, config);
            }
        } else if command.commandType == clay.RenderCommandType.TEXT {
            config := command.config.textElementConfig;
            if config != null {
                draw_text(b, bound, command.text, config);
            }
        } else if command.commandType == clay.RenderCommandType.IMAGE {
            config := command.config.imageElementConfig;
            if config != null {
                tex := cast(*CLAYF.Texture) config.imageData;
                if tex != null && tex.Width > 0 && tex.Height > 0 && bound.width > 0 && bound.height > 0 {
                    CLAYF.batcher_image_trs(b, tex, .{bound.x, bound.y}, .{},
                        .{bound.width / cast(float32) tex.Width, bound.height / cast(float32) tex.Height}, 0, CLAYF.Color_White);
                }
            }
        } else if command.commandType == clay.RenderCommandType.CUSTOM && clay_custom_draw != null {
            config := command.config.customElementConfig;
            if config != null clay_custom_draw(b, bound, cast(*void) config.customData, clay_custom_user);
        }
    }
}
