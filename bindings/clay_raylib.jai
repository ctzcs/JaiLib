// clay_raylib.jai
// raylib renderer for the clay UI library (bindings/clay/module.jai).
//
// Renders clay's RenderCommandArray with raylib's high-level 2D drawing
// (DrawRectangle*/DrawTextEx/BeginScissorMode) inside BeginDrawing()/
// EndDrawing(). Also provides the text-measurement callback clay needs
// (SetMeasureTextFunction), built on the raylib default font.
//
// Limitations (v1): text is drawn top-left aligned per command bounding box
// (no wrap-aware vertical centering), borders ignore corner radius, and text
// strings are copied into a module-level buffer that resets each frame.

#import "Basic";

rl :: #import "bindings/raylib";
clay :: #import "clay/module";

// --- raylib Font / text API (kept here so bindings/raylib.jai stays free of
// types that could collide with the ImGui module; this file is only imported
// by clay demos) ---

Image :: struct {
    data:    *void;
    width:   s32;
    height:  s32;
    mipmaps: s32;
    format:  s32;
}

GlyphInfo :: struct {
    value:    s32;
    offsetX:  s32;
    offsetY:  s32;
    advanceX: s32;
    image:    Image;
}

Font :: struct {
    baseSize:     s32;
    glyphCount:   s32;
    glyphPadding: s32;
    texture:      rl.Texture;
    recs:         *rl.Rectangle;
    glyphs:       *GlyphInfo;
}

raylib_dll :: #system_library "raylib";
GetFontDefault :: () -> Font #foreign raylib_dll;
DrawTextEx :: (font: Font, text: *u8, position: rl.Vector2, font_size: float32, spacing: float32, tint: rl.Color) #foreign raylib_dll;
MeasureTextEx :: (font: Font, text: *u8, font_size: float32, spacing: float32) -> rl.Vector2 #foreign raylib_dll;
BeginScissorMode :: (x: s32, y: s32, width: s32, height: s32) #foreign raylib_dll;
EndScissorMode :: () #foreign raylib_dll;
DrawRectangleRounded :: (rec: rl.Rectangle, roundness: float32, segments: s32, color: rl.Color) #foreign raylib_dll;

// --- text buffer: clay strings are not null-terminated; copy into a
// module-level buffer that is reset once per frame ---

TEXT_BUFFER_SIZE :: 8192;
text_buffer: [TEXT_BUFFER_SIZE] u8;
text_buffer_pos: s64 = 0;

clay_string_cstr :: (s: clay.String) -> *u8 {
    n := cast(s64) s.length;
    if n <= 0 {
        text_buffer[text_buffer_pos] = 0;
        text_buffer_pos += 1;
        if text_buffer_pos >= TEXT_BUFFER_SIZE {
            text_buffer_pos = 0;
        }
        return *text_buffer[0];
    }
    if text_buffer_pos + n + 1 > TEXT_BUFFER_SIZE {
        text_buffer_pos = 0;   // wrap around within the frame (rare)
        if n + 1 > TEXT_BUFFER_SIZE {
            return "".data;
        }
    }
    start := text_buffer_pos;
    for i: 0..n-1 {
        text_buffer[start + i] = s.chars[cast(s64) i];
    }
    text_buffer[start + n] = 0;
    text_buffer_pos = start + n + 1;
    return *text_buffer[start];
}

clay_raylib_begin_frame :: () {
    text_buffer_pos = 0;
}

// --- color / rect helpers ---

color_to_rl :: (c: clay.Color) -> rl.Color {
    clamp8 :: (v: float) -> u8 {
        if v < 0.0 { return 0; }
        if v > 255.0 { return 255; }
        return cast(u8) cast(s64) (v + 0.5);
    }
    return .{ r = clamp8(c.r), g = clamp8(c.g), b = clamp8(c.b), a = clamp8(c.a) };
}

bound_to_rect :: (b: clay.BoundingBox) -> rl.Rectangle {
    return .{ x = b.x, y = b.y, width = b.width, height = b.height };
}

// --- text measurement callback for clay ---
// clay calls this to size text elements; we use the raylib default font.

measure_text :: (text: clay.StringSlice, config: *clay.TextElementConfig, user_data: u64) -> clay.Dimensions #c_call {
    // #c_call body runs without a Jai context: avoid calling local Jai
    // procedures (hence no push_context + clay_string_cstr here); copy into a
    // stack buffer and call the #foreign function directly.
    buf: [2048] u8;
    n := cast(s64) text.length;
    if n > 2047 {
        n = 2047;
    }
    i: s64 = 0;
    while i < n {
        buf[i] = text.chars[i];
        i += 1;
    }
    buf[n] = 0;
    font := GetFontDefault();
    size := MeasureTextEx(font, *buf[0], cast(float32) config.fontSize, cast(float32) config.letterSpacing);
    return .{ width = size.x, height = cast(float32) config.lineHeight };
}

// --- render ---

MAX_SCISSOR_DEPTH :: 16;
scissor_stack: [MAX_SCISSOR_DEPTH] rl.Rectangle;
scissor_depth: s64 = 0;

push_scissor :: (rect_in: rl.Rectangle) {
    rect := rect_in;
    // intersect with the parent scissor so nested clips stay correct
    if scissor_depth > 0 {
        parent := scissor_stack[scissor_depth - 1];
        x1 := max(rect.x, parent.x);
        y1 := max(rect.y, parent.y);
        x2 := min(rect.x + rect.width, parent.x + parent.width);
        y2 := min(rect.y + rect.height, parent.y + parent.height);
        rect = .{ x = x1, y = y1, width = max(0.0, x2 - x1), height = max(0.0, y2 - y1) };
    }
    if scissor_depth < MAX_SCISSOR_DEPTH {
        scissor_stack[scissor_depth] = rect;
        scissor_depth += 1;
    }
    BeginScissorMode(cast(s32) rect.x, cast(s32) rect.y, cast(s32) rect.width, cast(s32) rect.height);
}

pop_scissor :: () {
    if scissor_depth > 0 {
        scissor_depth -= 1;
    }
    EndScissorMode();
    if scissor_depth > 0 {
        top := scissor_stack[scissor_depth - 1];
        BeginScissorMode(cast(s32) top.x, cast(s32) top.y, cast(s32) top.width, cast(s32) top.height);
    }
}

draw_rectangle :: (bound: clay.BoundingBox, color: clay.Color, radius: float) {
    if radius > 0.5 && bound.width > 0.0 && bound.height > 0.0 {
        // absolute pixels -> raylib roundness (relative to the shorter side)
        roundness := radius * 2.0 / min(bound.width, bound.height);
        if roundness > 0.5 { roundness = 0.5; }
        DrawRectangleRounded(bound_to_rect(bound), roundness, 8, color_to_rl(color));
    } else {
        rl.DrawRectangleRec(bound_to_rect(bound), color_to_rl(color));
    }
}

draw_border :: (bound: clay.BoundingBox, config: *clay.BorderElementConfig) {
    col := color_to_rl(config.left.color);
    lw := cast(float32) config.left.width;
    rw := cast(float32) config.right.width;
    tw := cast(float32) config.top.width;
    bw := cast(float32) config.bottom.width;
    if lw > 0.0 {
        rl.DrawRectangleRec(.{ x = bound.x, y = bound.y, width = lw, height = bound.height }, col);
    }
    if rw > 0.0 {
        rl.DrawRectangleRec(.{ x = bound.x + bound.width - rw, y = bound.y, width = rw, height = bound.height }, color_to_rl(config.right.color));
    }
    if tw > 0.0 {
        rl.DrawRectangleRec(.{ x = bound.x, y = bound.y, width = bound.width, height = tw }, color_to_rl(config.top.color));
    }
    if bw > 0.0 {
        rl.DrawRectangleRec(.{ x = bound.x, y = bound.y + bound.height - bw, width = bound.width, height = bw }, color_to_rl(config.bottom.color));
    }
}

draw_text :: (bound: clay.BoundingBox, text: clay.String, config: *clay.TextElementConfig) {
    cstr := clay_string_cstr(text);
    font := GetFontDefault();
    font_size := cast(float32) config.fontSize;
    spacing := cast(float32) config.letterSpacing;
    DrawTextEx(font, cstr, .{ x = bound.x, y = bound.y }, font_size, spacing, color_to_rl(config.textColor));
}

clay_raylib_render :: (commands: *clay.RenderCommandArray) {
    if commands == null || commands.length <= 0 {
        return;
    }
    scissor_depth = 0;

    for i: 0..commands.length-1 {
        command := commands.internalArray[i];
        bound := command.boundingBox;

        if command.commandType == clay.RenderCommandType.SCISSOR_START {
            push_scissor(bound_to_rect(bound));
        } else if command.commandType == clay.RenderCommandType.SCISSOR_END {
            pop_scissor();
        } else if command.commandType == clay.RenderCommandType.RECTANGLE {
            config := command.config.rectangleElementConfig;
            radius: float = 0.0;
            if config != null {
                radius = config.cornerRadius.topLeft;
                draw_rectangle(bound, config.color, radius);
            } else {
                draw_rectangle(bound, .{ r = 255.0, g = 0.0, b = 255.0, a = 255.0 }, 0.0);
            }
        } else if command.commandType == clay.RenderCommandType.BORDER {
            config := command.config.borderElementConfig;
            if config != null {
                draw_border(bound, config);
            }
        } else if command.commandType == clay.RenderCommandType.TEXT {
            config := command.config.textElementConfig;
            if config != null {
                draw_text(bound, command.text, config);
            }
        } else if command.commandType == clay.RenderCommandType.IMAGE {
            config := command.config.imageElementConfig;
            if config != null {
                tex := cast(*rl.Texture) config.imageData;
                if tex != null {
                    source := rl.Rectangle.{ x = 0.0, y = 0.0, width = cast(float32) tex.width, height = cast(float32) tex.height };
                    rl.DrawTexturePro(<<tex, source, bound_to_rect(bound), .{ x = 0.0, y = 0.0 }, 0.0, rl.WHITE);
                }
            }
        }
        // CUSTOM / NONE: ignored
    }
}
