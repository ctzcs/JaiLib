// ui:text —— msdf 字体测量与字形四边形生成。
//
// 与 olib 的差异（jfoster 的 Msdf_Font 没有 Characters/Kerning/SourceRect/Offset）：
//   - 字形查找用 Msdf_Font.lookup（codepoint -> 下标）+ Glyphs[i]；
//   - 字形矩形取 msdf-atlas-gen 的 plane bounds（pl/pt/pr/pb，em 归一化）与
//     atlas bounds（al/at/ar/ab，0..1），不再是像素 SourceRect/Offset；
//   - MsdfFontGetKerning 在 jfoster 里没有对应物，字距恒为 0（烘焙出的位图字体同样如此）。
// 这些差异只影响字距与字形边界的取法，measure/quad 的对外语义（尺寸、笔尖推进、UV）不变。

//@region 测量

// 单行文本尺寸（clay 回调与自用）。
// lineHeight 配置为 0 时用字体默认行高；字距按字符间计数。
ui_measure_text :: (font: *F.Msdf_Font, text: string, font_size: u16,
                    letter_spacing: u16, line_height: u16) -> clay.Dimensions {
    if font == null || text.count == 0 || font.Size <= 0 return .{ 0, 0 };
    scale := cast(float32) font_size / font.Size;

    width: float32;
    prev: s32 = -1;
    rest := text;
    while true {
        code, size := ui_utf8_next(*rest);
        if size <= 0 break;
        if prev >= 0 {
            width += ui_msdf_kerning(font, prev, cast(s32) code) * scale;
            width += cast(float32) letter_spacing;
        }
        found, glyph := ui_msdf_glyph(font, cast(s32) code);
        if found width += glyph.Advance * scale;
        else width += font.Size * scale * 0.5; // 未知字形给半宽
        prev = cast(s32) code;
    }

    h := cast(float32) line_height;
    if h <= 0 h = font.LineHeight * scale;
    return .{ width, h };
}
//@endregion

//@region 字形四边形

// 一个字形的绘制数据：屏幕四点 + 图集 UV + 颜色。
// 位图采样或 MSDF 解码由注册时的 Bitmap/MSDF 类型决定。
UI_Glyph_Quad :: struct {
    x0, y0: float32; // 左上（屏幕像素）
    x1, y1: float32; // 右下
    u0, v0: float32; // UV 左上
    u1, v1: float32; // UV 右下
    color: F.Color;
}

// 从笔尖 (pen_x, pen_y 为基线原点) 推进生成全部字形四边形。
// 返回推进后的笔尖 x。
ui_push_glyph_quads :: (font: *F.Msdf_Font, text: string, pen_x: float32, pen_y: float32,
                        font_size: u16, letter_spacing: u16, color: F.Color,
                        out: *[..] UI_Glyph_Quad) -> float32 {
    if font == null || font.Size <= 0 return pen_x;
    atlas_w, atlas_h := ui_msdf_atlas_size(font);
    if atlas_w <= 0 || atlas_h <= 0 return pen_x;
    scale := cast(float32) font_size / font.Size;
    em := cast(float32) font_size;

    x := pen_x;
    prev: s32 = -1;
    rest := text;
    while true {
        code, size := ui_utf8_next(*rest);
        if size <= 0 break;
        if prev >= 0 {
            x += ui_msdf_kerning(font, prev, cast(s32) code) * scale;
            x += cast(float32) letter_spacing;
        }
        found, glyph := ui_msdf_glyph(font, cast(s32) code);
        if found {
            gx := x + glyph.pl * em;
            gy := pen_y + glyph.pt * em;
            gw := (glyph.pr - glyph.pl) * em;
            gh := (glyph.pb - glyph.pt) * em;
            array_add(out, UI_Glyph_Quad.{
                x0 = gx, y0 = gy,
                x1 = gx + gw, y1 = gy + gh,
                u0 = glyph.al, v0 = glyph.at,
                u1 = glyph.ar, v1 = glyph.ab,
                color = color,
            });
            x += glyph.Advance * scale;
        } else {
            x += font.Size * scale * 0.5;
        }
        prev = cast(s32) code;
    }
    return x;
}
//@endregion

//@region 字体查询助手（jfoster Msdf_Font 没有 Foster 的 Character/Kerning API）

ui_msdf_glyph :: (font: *F.Msdf_Font, codepoint: s32) -> (found: bool, glyph: F.Msdf_Font_Glyph) {
    if font == null return false, .{};
    ok, index := table_find(*font.lookup, codepoint);
    if !ok return false, .{};
    if index < 0 return false, .{};
    if cast(s64) index >= font.Glyphs.count return false, .{};
    return true, font.Glyphs[index];
}

// jfoster 的 Msdf_Font 不保存 kerning 表；留出钩子，未移植时恒为 0。
ui_msdf_kerning :: (font: *F.Msdf_Font, first: s32, second: s32) -> float32 {
    return 0;
}

ui_msdf_atlas_size :: (font: *F.Msdf_Font) -> (float32, float32) {
    if font == null || font.Atlas == null return 0, 0;
    return cast(float32) font.Atlas.Width, cast(float32) font.Atlas.Height;
}

//@region UTF-8

// 读一个码点并推进 s；返回消耗的字节数（0 表示空串）。
ui_utf8_next :: (s: *string) -> (code: u32, size: int) {
    if s.count <= 0 return 0, 0;
    before := s.count;
    code, _ := UNI.utf8_next_character(s);
    return code, cast(int) (before - s.count);
}

// 把码点写进 buf（最多 4 字节），返回字节数。
ui_utf8_encode :: (buf: *[4] u8, ch_in: u32) -> int {
    ch := ch_in;
    if ch < 0x80 {
        buf.*[0] = cast(u8) ch;
        return 1;
    }
    if ch < 0x800 {
        buf.*[0] = cast(u8) (0xC0 | (ch >> 6));
        buf.*[1] = cast(u8) (0x80 | (ch & 0x3F));
        return 2;
    }
    if ch < 0x10000 {
        buf.*[0] = cast(u8) (0xE0 | (ch >> 12));
        buf.*[1] = cast(u8) (0x80 | ((ch >> 6) & 0x3F));
        buf.*[2] = cast(u8) (0x80 | (ch & 0x3F));
        return 3;
    }
    buf.*[0] = cast(u8) (0xF0 | (ch >> 18));
    buf.*[1] = cast(u8) (0x80 | ((ch >> 12) & 0x3F));
    buf.*[2] = cast(u8) (0x80 | ((ch >> 6) & 0x3F));
    buf.*[3] = cast(u8) (0x80 | (ch & 0x3F));
    return 4;
}

// 字符串里第 i 字节所在字符的起始字节（pos 为字节偏移，落在字符中间时退回边界）。
ui_utf8_prev :: (text: string, pos: int) -> int {
    if pos <= 0 return 0;
    i := pos - 1;
    while i > 0 && (text.data[i] & 0xC0) == 0x80 i -= 1;
    return i;
}
//@endregion
//@endregion

//@region 字体烘焙

// 用 jfoster 的 Font（stb_truetype）烘焙预乘 alpha 位图字体；codepoints 为空时用 ASCII 32..126。
// 返回的 msdf 拥有 Atlas（Atlas.Data），须用 ui_font_dispose 释放；texture 须由调用方释放。
// 源 Font 由调用方管理，可在烘焙后释放。
ui_font_bake :: (device: *F.Graphics_Device, font: *F.Font, size: float32,
                 codepoints: [] s32 = .[], label := "ui font") -> (msdf: *F.Msdf_Font, texture: *F.Texture, ok: bool) {
    if device == null return null, null, false;
    built, image_ok := ui_font_bake_image(font, size, codepoints);
    if !image_ok return null, null, false;
    texture = F.texture_create_from_colors(device, built.Atlas.Width, built.Atlas.Height, built.Atlas.Data,
                                          .NONE, label);
    if texture == null || texture.handle == 0 {
        ui_font_dispose(built);
        return null, null, false;
    }
    return built, texture, true;
}

// 独立于 GPU 的生成阶段，便于工具链与单测验证像素、度量和打包。
ui_font_bake_image :: (font: *F.Font, size: float32, codepoints: [] s32 = .[]) -> (*F.Msdf_Font, bool) {
    if font == null || size <= 0 || font.data.count == 0 return null, false;
    scale := F.font_get_scale(font, size);
    if scale <= 0 return null, false;

    ascii: [95] s32;
    points := codepoints;
    if points.count == 0 {
        for *cp, i: ascii cp.* = cast(s32) (32 + i);
        points = ascii;
    }

    glyphs := NewArray(points.count, F.Font_Character, true);
    if glyphs.data == null return null, false;
    defer free(glyphs.data);

    atlas_w, atlas_h := 1024, 512;
    for cp, i: points {
        glyphs[i] = F.font_get_character(font, cp, size);
        while glyphs[i].Width + 4 > atlas_w atlas_w *= 2;
    }

    msdf := New(F.Msdf_Font);
    if msdf == null return null, false;
    msdf.* = .{};
    msdf.Size = size;
    msdf.EmSize = size;
    msdf.Ascent = cast(float32) font.Ascent * scale;
    // FontMake 在 line gap 非正时把负 Descent 移到 LineGap。
    // 恢复这类字体的下降量；scale 按 em 映射，不能用于逆算度量高度。
    descent := font.Descent;
    if descent == 0 && font.LineGap > 0 descent = -font.LineGap;
    msdf.Descent = cast(float32) descent * scale;
    msdf.LineHeight = msdf.Ascent - msdf.Descent;
    msdf.DistanceRange = 4;
    msdf.DistanceRangeMiddle = 2;

    x, y, row_h := 2, 2, 0;
    for cp, i: points {
        ch := glyphs[i];
        glyph: F.Msdf_Font_Glyph;
        glyph.Unicode = cp;
        glyph.Advance = ch.Advance;
        if ch.Visible {
            if x + ch.Width + 2 > atlas_w {
                x = 2;
                y += row_h + 2;
                row_h = 0;
            }
            if ch.Height > row_h row_h = ch.Height;
            while y + ch.Height + 2 > atlas_h atlas_h *= 2;
            // 图集区域（像素）
            glyph.al = cast(float32) x;
            glyph.at = cast(float32) y;
            glyph.ar = cast(float32) (x + ch.Width);
            glyph.ab = cast(float32) (y + ch.Height);
            // 平面区域（em 归一化，供 ui_push_glyph_quads / 后端共用）
            glyph.pl = ch.Offset.x / size;
            glyph.pt = ch.Offset.y / size;
            glyph.pr = (ch.Offset.x + cast(float32) ch.Width) / size;
            glyph.pb = (ch.Offset.y + cast(float32) ch.Height) / size;
            x += ch.Width + 2;
        }
        table_set(*msdf.lookup, cp, cast(s32) msdf.Glyphs.count);
        array_add(*msdf.Glyphs, glyph);
    }

    msdf.Atlas = New(F.Image);
    msdf.Atlas.* = F.image_create(cast(s32) atlas_w, cast(s32) atlas_h);
    for ch, i: glyphs {
        if !ch.Visible continue;
        pixels := NewArray(ch.Width * ch.Height, F.Color, true);
        if pixels.data == null {
            ui_font_dispose(msdf);
            return null, false;
        }
        F.font_get_pixels(font, pixels, ch.GlyphIndex, ch.Width, ch.Height, scale, true);
        rect_x := cast(s32) msdf.Glyphs[i].al;
        rect_y := cast(s32) msdf.Glyphs[i].at;
        for by: 0..ch.Height - 1 {
            for bx: 0..ch.Width - 1 {
                msdf.Atlas.Data[(rect_y + by) * atlas_w + rect_x + bx] = pixels[by * ch.Width + bx];
            }
        }
        free(pixels.data);
    }
    // 平面/图集边界归一化（图集尺寸烘焙后才确定）
    for *glyph: msdf.Glyphs {
        if glyph.ar <= 0 && glyph.ab <= 0 continue;
        glyph.al /= cast(float32) atlas_w;
        glyph.ar /= cast(float32) atlas_w;
        glyph.at /= cast(float32) atlas_h;
        glyph.ab /= cast(float32) atlas_h;
    }
    return msdf, true;
}

// 释放 ui_font_bake / ui_font_bake_image 的产物（纹理由调用方另管）。
ui_font_dispose :: (font: *F.Msdf_Font) {
    if font == null return;
    if font.Atlas != null {
        F.image_destroy(font.Atlas);
        free(font.Atlas);
    }
    array_free(font.Glyphs);
    deinit(*font.lookup);
    free(font);
}
//@endregion
