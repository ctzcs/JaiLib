using Basic;
using Math;


// Port of Foster Framework/Images/Font.cs over stb_truetype (compiled via
// BuildCpp from internal/third_party/stb). Covers the API surface Foster's
// trimmed StbTrueType.cs exposes: font init, v-metrics, glyph lookup, kerning
// (legacy kern + GPOS), glyph rasterization to RGBA.

STBTT_Buffer :: struct {
    data: *u8;
    cursor, size: s32;
}

// Exact stbtt_fontinfo ABI from our bundled stb_truetype.h.
STBTT_Font_Info :: struct {
    user_data: *void;
    data: *u8;
    fontstart, numGlyphs: s32;
    loca, head, glyf, hhea, hmtx, kern, gpos, svg: s32;
    index_map, indexToLocFormat: s32;
    cff, charstrings, gsubrs, subrs, fontdicts, fdselect: STBTT_Buffer;
}

STBTT_Vertex :: struct {
    x: s16;
    y: s16;
    cx: s16;
    cy: s16;
    cx1: s16;
    cy1: s16;
    type: u8;
    padding: u8;
}

// [W1] stb_truetype is a precompiled native library (stb_impl.dll/.lib) and
// cannot be linked into a wasm module, so the wasm build gets a no-op
// transcription of the same 11 entry points from internal/web/stbtt_web.jai
// instead. Everything below this block — Font, Font_Character, font_load,
// font_get_character, the sizing/kerning math — is portable and shared, which is
// what keeps the kit's bitmap/atlas font paths API-identical on both targets.
// font_load returns null on wasm because stbtt_InitFont reports failure, which is
// exactly how the desktop code reports an unparsable font file.
#if OS != .WASM {
stbtt_InitFont           :: (info: *STBTT_Font_Info, data: *u8, offset: s32) -> s32 #foreign stb_impl;
stbtt_GetNumberOfFonts   :: (data: *u8) -> s32 #foreign stb_impl;
stbtt_FindGlyphIndex     :: (info: *STBTT_Font_Info, unicode_codepoint: s32) -> s32 #foreign stb_impl;
stbtt_ScaleForPixelHeight :: (info: *STBTT_Font_Info, pixels: float) -> float #foreign stb_impl;
stbtt_ScaleForMappingEmToPixels :: (info: *STBTT_Font_Info, pixels: float) -> float #foreign stb_impl;
stbtt_GetFontVMetrics    :: (info: *STBTT_Font_Info, ascent: *s32, descent: *s32, lineGap: *s32) #foreign stb_impl;
stbtt_GetGlyphKernAdvance :: (info: *STBTT_Font_Info, glyph1: s32, glyph2: s32) -> s32 #foreign stb_impl;
stbtt_GetGlyphHMetrics   :: (info: *STBTT_Font_Info, glyph_index: s32, advance_width: *s32, left_side_bearing: *s32) #foreign stb_impl;
stbtt_GetGlyphBox        :: (info: *STBTT_Font_Info, glyph_index: s32, x0: *s32, y0: *s32, x1: *s32, y1: *s32) -> s32 #foreign stb_impl;
stbtt_IsGlyphEmpty       :: (info: *STBTT_Font_Info, glyph_index: s32) -> s32 #foreign stb_impl;
stbtt_MakeGlyphBitmapSubpixel :: (info: *STBTT_Font_Info, output: *u8, out_w: s32, out_h: s32, out_stride: s32, scale_x: float, scale_y: float, shift_x: float, shift_y: float, glyph_index: s32) #foreign stb_impl;
} else {
#load "../internal/web/stbtt_web.jai";  // #load 路径相对本文件
}

//
// Font — the Foster front-end
//

Font_Character :: struct {
    GlyphIndex: s32;
    Width:      s32;
    Height:     s32;
    Advance:    float;
    Offset:     Vector2;
    Scale:      float;
    Visible:    bool;
}

Font :: struct {
    data:  [] u8;           // owns the font file bytes
    info:  STBTT_Font_Info;
    Ascent:   float;
    Descent:  float;
    LineGap:  float;

    glyph_index_memo: Table(s32, s32);
    scale_memo:       Table(float, float);
}

font_load :: (path: string) -> *Font {
    data, ok := json_read_file(path);
    if !ok return null;
    result := font_load_bytes(cast([] u8) data);
    if result == null free(data.data);
    return result;
}

font_load_bytes :: (data: [] u8) -> *Font {
    if data.count < 12 return null;
    f := New(Font);
    f.data = data;

    count := stbtt_GetNumberOfFonts(f.data.data);
    if count <= 0 { free(f); return null; }
    // The bundled DLL does not export GetFontOffsetForIndex. TTC stores the
    // first face's big-endian offset immediately after its 12-byte header.
    offset: s32 = 0;
    if data[0] == 116 && data[1] == 116 && data[2] == 99 && data[3] == 102 {
        if data.count < 16 { free(f); return null; }
        raw := (cast(u32) data[12] << 24) | (cast(u32) data[13] << 16) | (cast(u32) data[14] << 8) | cast(u32) data[15];
        if raw > 0x7fffffff || cast(s64) raw + 12 > data.count { free(f); return null; }
        offset = cast(s32) raw;
    }
    if offset < 0 || stbtt_InitFont(*f.info, f.data.data, offset) == 0 { free(f); return null; }

    ascent, descent, line_gap: s32;
    stbtt_GetFontVMetrics(*f.info, *ascent, *descent, *line_gap);
    scale := stbtt_ScaleForMappingEmToPixels(*f.info, 1.0);

    f.Ascent  = cast(float) ascent  * scale;
    f.Descent = cast(float) descent * scale;
    f.LineGap = cast(float) line_gap * scale;

    // Foster quirk: if LineGap <= 0 and Descent < 0, fold descent into line gap
    if f.LineGap <= 0 && f.Descent < 0 {
        f.LineGap = -f.Descent;
        f.Descent = 0;
    }

    return f;
}

font_destroy :: (f: *Font) {
    if f.data.count > 0 free(f.data.data);
    deinit(*f.glyph_index_memo);
    deinit(*f.scale_memo);
    free(f);
}

font_get_glyph_index :: (f: *Font, codepoint: s32) -> s32 {
    cached := table_find_pointer(*f.glyph_index_memo, codepoint);
    if cached != null return <<cached;
    index := stbtt_FindGlyphIndex(*f.info, codepoint);
    table_set(*f.glyph_index_memo, codepoint, index);
    return index;
}

font_get_scale :: (f: *Font, size: float) -> float {
    cached := table_find_pointer(*f.scale_memo, size);
    if cached != null return <<cached;
    scale := stbtt_ScaleForMappingEmToPixels(*f.info, size);
    table_set(*f.scale_memo, size, scale);
    return scale;
}

font_get_kerning :: (f: *Font, first: s32, second: s32, size: float) -> float {
    glyph1 := font_get_glyph_index(f, first);
    glyph2 := font_get_glyph_index(f, second);
    return cast(float) stbtt_GetGlyphKernAdvance(*f.info, glyph1, glyph2) * font_get_scale(f, size);
}

font_get_kerning_between_glyphs :: (f: *Font, glyph1: s32, glyph2: s32, size: float) -> float {
    return cast(float) stbtt_GetGlyphKernAdvance(*f.info, glyph1, glyph2) * font_get_scale(f, size);
}

font_get_character_of_glyph :: (f: *Font, glyph: s32, size: float) -> Font_Character {
    scale := font_get_scale(f, size);
    advance, left_bearing: s32;
    x0, y0, x1, y1: s32;
    empty := stbtt_IsGlyphEmpty(*f.info, glyph);

    stbtt_GetGlyphHMetrics(*f.info, glyph, *advance, *left_bearing);
    stbtt_GetGlyphBox(*f.info, glyph, *x0, *y0, *x1, *y1);

    c: Font_Character;
    c.GlyphIndex = glyph;
    c.Advance = cast(float) advance * scale;
    c.Scale = scale;
    c.Visible = empty == 0 && glyph != 0;

    if c.Visible {
        c.Width  = cast(s32) ceil(cast(float) (x1 - x0) * scale);
        c.Height = cast(s32) ceil(cast(float) (y1 - y0) * scale);
        c.Offset = .{ cast(float) x0 * scale, -cast(float) y1 * scale };
    } else {
        c.Width = 0;
        c.Height = 0;
        c.Offset = .{ 0, 0 };
    }
    return c;
}

font_get_character :: (f: *Font, codepoint: s32, size: float) -> Font_Character {
    return font_get_character_of_glyph(f, font_get_glyph_index(f, codepoint), size);
}

// Rasterizes a glyph into dest as RGBA — alpha = coverage, RGB = white or
// premultiplied coverage (Foster's GetPixels expansion).
font_get_pixels :: (f: *Font, dest: [] Color, glyph: s32, width: s32, height: s32, scale: float, premultiply: bool) {
    if width <= 0 || height <= 0 return;
    coverage := cast(*u8) alloc(width * height);
    stbtt_MakeGlyphBitmapSubpixel(*f.info, coverage, width, height, width, scale, scale, 0, 0, glyph);

    for i: 0..width * height - 1 {
        v := coverage[i];
        if premultiply {
            dest[i] = .{ v, v, v, v };
        } else {
            dest[i] = .{ 255, 255, 255, v };
        }
    }
    free(coverage);
}
