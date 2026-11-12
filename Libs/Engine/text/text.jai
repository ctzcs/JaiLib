// Shared UTF-8 text layout for gfx and clay. Owns GPU font resources.
#import "Basic";
#import "Hash_Table";
TF :: #import "jfoster";

Text_Font :: struct {
    sprite: *TF.Sprite_Font;
    source: *TF.Font;
    glyphs: [..] TF.Sprite_Font_Character; // sorted Unicode cache
    fallback: s64 = -1;
    line_height: float32;
    callback_context: #Context;
    hb_font: *void;
    units_per_em: float32;
    glyph_ids: Table(s32, TF.Sprite_Font_Character);
    fallback_fonts: [..] *Text_Font; // borrowed, ordered; no recursive traversal
    pages: [..] Text_Atlas_Page;
}

// Empty path selects embedded MSDF. TTF/TTC paths are explicit; extra_glyphs
// optionally preloads glyphs. New glyphs are added on demand by text layout.
text_font_create :: (device: *TF.Graphics_Device, path: string = "", extra_glyphs: string = "", bake_size: float32 = 24) -> *Text_Font {
    if bake_size <= 0 return null;
    font := New(Text_Font);
    font.callback_context = context;
    codepoints: [..] s32;
    defer array_free(codepoints);
    for cp: TF.ASCII_CODEPOINTS array_add(*codepoints, cp);
    if path != "" {
        font.source = TF.font_load(path);
        if font.source == null { free(font); return null; }
        cursor: s64;
        while cursor < extra_glyphs.count {
            cp := text_next_codepoint(extra_glyphs.data, extra_glyphs.count, *cursor);
            if cp < 32 continue;
            found := false;
            for existing: codepoints if existing == cp { found = true; break; }
            if !found array_add(*codepoints, cp);
        }
        font.sprite = TF.sprite_font_create_from_font(device, font.source, bake_size, codepoints);
    } else {
        font.sprite = TF.sprite_font_create_from_msdf(device, TF.defaults_msdf_font(device));
    }
    for cp: codepoints {
        ch := TF.sprite_font_get_character(font.sprite, cp);
        if font.source != null && TF.font_get_glyph_index(font.source, cp) == 0 continue;
        // Invisible glyphs such as space still have a valid advance.
        ch.Exists = true;
        array_add(*font.glyphs, ch);
    }
    for i: 1..font.glyphs.count-1 {
        ch := font.glyphs[i]; j := i;
        while j > 0 && font.glyphs[j-1].Codepoint > ch.Codepoint {
            font.glyphs[j] = font.glyphs[j-1]; j -= 1;
        }
        font.glyphs[j] = ch;
    }
    font.fallback = text_glyph_index(font, 63);
    font.line_height = TF.sprite_font_line_height(font.sprite);
    if font.source != null {
        blob := hb_blob_create(font.source.data.data, cast(u32) font.source.data.count, 1, null, null);
        face := hb_face_create(blob, 0);
        font.units_per_em = cast(float32) hb_face_get_upem(face);
        font.hb_font = hb_font_create(face);
        hb_ot_font_set_funcs(font.hb_font);
        hb_font_set_scale(font.hb_font, cast(s32) font.units_per_em, cast(s32) font.units_per_em);
        hb_face_destroy(face); hb_blob_destroy(blob);
        for ch: font.glyphs table_set(*font.glyph_ids, TF.font_get_glyph_index(font.source, ch.Codepoint), ch);
    }
    return font;
}

text_font_destroy :: (font: *Text_Font) {
    if font == null return;
    TF.sprite_font_destroy(font.sprite);
    if font.hb_font != null hb_font_destroy(font.hb_font);
    if font.source != null TF.font_destroy(font.source);
    for page: font.pages { TF.texture_dispose(page.texture); free(page.texture); }
    array_free(font.pages); array_free(font.fallback_fonts); deinit(*font.glyph_ids);
    array_free(font.glyphs);
    free(font);
}

// UTF-8 decoding and lookup use the C ABI without allocation or Jai context.
text_next_codepoint :: (data: *u8, length: s64, cursor: *s64) -> s32 #c_call {
    start := <<cursor;
    if start >= length return 0;
    first := data[start];
    <<cursor = start + 1;
    if first < 128 return cast(s32) first;
    count: s64; cp: u32; minimum: u32;
    if first >= 194 && first <= 223 { count = 2; cp = first & 31; minimum = 128; }
    else if first >= 224 && first <= 239 { count = 3; cp = first & 15; minimum = 2048; }
    else if first >= 240 && first <= 244 { count = 4; cp = first & 7; minimum = 65536; }
    else return 63;
    if start + count > length return 63;
    offset: s64 = 1;
    while offset < count {
        b := data[start + offset];
        if (b & 192) != 128 return 63;
        cp = (cp << 6) | (b & 63);
        offset += 1;
    }
    if cp < minimum || cp > 1114111 || (cp >= 55296 && cp <= 57343) return 63;
    <<cursor = start + count;
    return cast(s32) cp;
}

text_glyph_index :: (font: *Text_Font, cp: s32) -> s64 #c_call {
    low: s64; high := font.glyphs.count;
    while low < high {
        mid := (low + high) / 2;
        value := font.glyphs[mid].Codepoint;
        if value < cp low = mid + 1;
        else if value > cp high = mid;
        else return mid;
    }
    return font.fallback;
}

// Native callbacks restore the explicit owning render-thread context. Font
// creation, measurement, preparation and drawing must use that same thread.
text_measure_raw :: (font: *Text_Font, data: *u8, length: s64, size: float32, spacing: float32 = 0, line_height: float32 = 0) -> TF.Vector2 #c_call {
    if font == null return .{};
    push_context font.callback_context {
        return text_measure(font, .{data = data, count = length}, size, spacing, line_height);
    }
}
text_measure :: (font: *Text_Font, value: string, size: float32, spacing: float32 = 0, line_height: float32 = 0) -> TF.Vector2 {
    layout := text_layout_create(font, value, size, spacing, line_height);
    defer text_layout_destroy(*layout); return layout.size;
}
text_draw :: (font: *Text_Font, batcher: *TF.Batcher, value: string, position: TF.Vector2, size: float32, color: TF.Color, spacing: float32 = 0, line_height: float32 = 0) {
    layout := text_layout_create(font, value, size, spacing, line_height);
    defer text_layout_destroy(*layout); text_layout_draw(*layout, batcher, position, color);
}
