Text_Atlas_Page :: struct { texture: *TF.Texture; x, y, row_height: s32; }
Text_Direction :: enum s32 { Auto :: 0; Left_To_Right :: 4; Right_To_Left :: 5; }
Text_Options :: struct { direction: Text_Direction; script: u32; language: string; }
Text_Placed_Glyph :: struct {
    font: *Text_Font; character: TF.Sprite_Font_Character;
    position: TF.Vector2; scale: float32; cluster: u32; glyph_id: u32;
}
// Layout owns the array, borrows fonts/pages. Reuse it for static labels;
// appending glyphs to a font never moves existing atlas regions.
Text_Layout :: struct { glyphs: [..] Text_Placed_Glyph; size: TF.Vector2; }
text_layout_destroy :: (layout: *Text_Layout) { array_free(layout.glyphs); <<layout = .{}; }

text_font_add_fallback :: (font: *Text_Font, fallback: *Text_Font) -> bool {
    if font == null || fallback == null || font == fallback return false;
    for existing: font.fallback_fonts if existing == fallback return false;
    array_add(*font.fallback_fonts, fallback); return true;
}
text_font_remove_fallback :: (font: *Text_Font, fallback: *Text_Font) {
    for item, i: font.fallback_fonts if item == fallback {
        for j: i..font.fallback_fonts.count-2 font.fallback_fonts[j] = font.fallback_fonts[j+1];
        font.fallback_fonts.count -= 1; return;
    }
}
text_font_has :: (font: *Text_Font, cp: s32) -> bool {
    if font.source != null return TF.font_get_glyph_index(font.source, cp) != 0;
    index := text_glyph_index(font, cp);
    return index >= 0 && font.glyphs[index].Codepoint == cp;
}
text_font_for :: (font: *Text_Font, cp: s32) -> *Text_Font {
    if text_font_has(font, cp) return font;
    for fallback: font.fallback_fonts if text_font_has(fallback, cp) return fallback;
    return font;
}
text_cache_glyph :: (font: *Text_Font, glyph: s32) -> TF.Sprite_Font_Character {
    result, cached := table_find(*font.glyph_ids, glyph); if cached return result;
    c := TF.font_get_character_of_glyph(font.source, glyph, font.sprite.Size);
    result = .{Advance = c.Advance, Offset = c.Offset, Exists = true};
    if c.Visible && c.Width > 0 && c.Height > 0 {
        w := c.Width + 2; h := c.Height + 2;
        page: *Text_Atlas_Page;
        if font.pages.count > 0 page = *font.pages[font.pages.count-1];
        if page != null && page.x + w > page.texture.Width { page.x = 0; page.y += page.row_height; page.row_height = 0; }
        if page == null || page.y + h > page.texture.Height || w > page.texture.Width {
            side := max(cast(s32) 512, w, h);
            blank := TF.image_create(side, side, .{});
            texture := TF.texture_create_from_colors(font.sprite.device, side, side, blank.Data);
            TF.image_destroy(*blank);
            array_add(*font.pages, .{texture = texture}); page = *font.pages[font.pages.count-1];
        }
        pixels := NewArray(c.Width * c.Height, TF.Color);
        TF.font_get_pixels(font.source, pixels, glyph, c.Width, c.Height, c.Scale, true);
        TF.texture_set_data_region(page.texture, pixels, .{page.x + 1, page.y + 1, c.Width, c.Height});
        free(pixels.data);
        result.Subtex = TF.subtexture_make_source(page.texture, .{cast(float32) (page.x+1), cast(float32) (page.y+1), cast(float32) c.Width, cast(float32) c.Height});
        page.x += w; page.row_height = max(page.row_height, h);
    }
    table_set(*font.glyph_ids, glyph, result); return result;
}

// Explicitly warm Unicode glyphs. Shaping also warms substituted glyph IDs
// (ligatures/contextual forms) automatically; extra_glyphs is only a preload.
text_font_prepare :: (font: *Text_Font, value: string) {
    cursor: s64;
    while cursor < value.count {
        cp := text_next_codepoint(value.data, value.count, *cursor);
        chosen := text_font_for(font, cp);
        if chosen.source == null || !text_font_has(chosen, cp) continue;
        index := text_glyph_index(chosen, cp);
        if index >= 0 && chosen.glyphs[index].Codepoint == cp continue;
        ch := text_cache_glyph(chosen, TF.font_get_glyph_index(chosen.source, cp)); ch.Codepoint = cp;
        array_add(*chosen.glyphs, ch);
        j := chosen.glyphs.count - 1;
        while j > 0 && chosen.glyphs[j-1].Codepoint > cp { chosen.glyphs[j] = chosen.glyphs[j-1]; j -= 1; }
        chosen.glyphs[j] = ch;
        chosen.fallback = -1; chosen.fallback = text_glyph_index(chosen, 63);
    }
}

// Appends one script/direction run. HarfBuzz handles GSUB/GPOS, kerning,
// ligatures, combining marks and RTL glyph order. Full paragraph bidi/run
// segmentation belongs to the caller: pass separately ordered runs for mixed
// directions, with explicit script/language where automatic guessing is ambiguous.
text_layout_run :: (layout: *Text_Layout, font: *Text_Font, value: string, size: float32, spacing: float32,
                    x: *float32, baseline: float32, column: *s64, byte_offset: s64, options: Text_Options) {
    scale := size / font.sprite.Size;
    if font.hb_font != null {
        buffer := hb_buffer_create(); defer hb_buffer_destroy(buffer);
        hb_buffer_add_utf8(buffer, value.data, cast(s32) value.count, 0, cast(s32) value.count);
        if options.direction != .Auto hb_buffer_set_direction(buffer, cast(s32) options.direction);
        if options.script != 0 hb_buffer_set_script(buffer, options.script);
        if options.language.count > 0 hb_buffer_set_language(buffer, hb_language_from_string(options.language.data, cast(s32) options.language.count));
        hb_buffer_guess_segment_properties(buffer);
        hb_shape(font.hb_font, buffer, null, 0);
        count: u32;
        infos := hb_buffer_get_glyph_infos(buffer, *count);
        positions := hb_buffer_get_glyph_positions(buffer, *count);
        factor := size / font.units_per_em;
        previous: u32 = 0xffffffff;
        for i: 0..cast(s64) count-1 {
            info := infos[i]; pos := positions[i];
            if info.cluster != previous {
                if <<column > 0 { <<x += spacing; }
                <<column += 1; previous = info.cluster;
            }
            id := cast(s32) info.codepoint;
            if id == 0 id = TF.font_get_glyph_index(font.source, 63);
            ch := text_cache_glyph(font, id);
            array_add(*layout.glyphs, .{font = font, character = ch, scale = scale,
                position = .{<<x + cast(float32) pos.x_offset * factor, baseline - cast(float32) pos.y_offset * factor},
                cluster = cast(u32) byte_offset + info.cluster, glyph_id = info.codepoint});
            if info.codepoint == 0 { <<x += ch.Advance * scale; }
            else { <<x += cast(float32) pos.x_advance * factor; }
        }
    } else {
        cursor: s64;
        while cursor < value.count {
            start := cursor; cp := text_next_codepoint(value.data, value.count, *cursor);
            index := text_glyph_index(font, cp); if index < 0 continue;
            ch := font.glyphs[index];
            if <<column > 0 { <<x += spacing; }
            array_add(*layout.glyphs, .{font = font, character = ch, scale = scale,
                position = .{<<x, baseline}, cluster = cast(u32) (byte_offset + start), glyph_id = cast(u32) ch.Codepoint});
            <<x += ch.Advance * scale; <<column += 1;
        }
    }
}

text_layout_create :: (font: *Text_Font, value: string, size: float32, spacing: float32 = 0, line_height: float32 = 0,
                       options: Text_Options = .{}) -> Text_Layout {
    result: Text_Layout;
    if font == null || size <= 0 || value.count <= 0 || value.count > 0x7fffffff return result;
    text_font_prepare(font, value);
    step := line_height; ascent := font.sprite.Ascent * size / font.sprite.Size;
    if step <= 0 {
        step = font.line_height * size / font.sprite.Size;
        for fallback: font.fallback_fonts {
            step = max(step, fallback.line_height * size / fallback.sprite.Size);
            ascent = max(ascent, fallback.sprite.Ascent * size / fallback.sprite.Size);
        }
    }
    cursor: s64; column: s64; x: float32; y: float32;
    result.size.y = step;
    while cursor < value.count {
        start := cursor; cp := text_next_codepoint(value.data, value.count, *cursor);
        if cp == 13 continue;
        if cp == 10 {
            result.size.x = max(result.size.x, x); x = 0; column = 0; y += step; result.size.y += step; continue;
        }
        if cp == 9 {
            text_layout_run(*result, text_font_for(font, 32), "    ", size, spacing, *x, y + ascent, *column, start, options); continue;
        }
        chosen := text_font_for(font, cp);
        while cursor < value.count {
            next := cursor; next_cp := text_next_codepoint(value.data, value.count, *next);
            if next_cp == 10 || next_cp == 13 || next_cp == 9 break;
            // Joiners and variation selectors belong to the preceding run.
            ignorable := next_cp == 0x200c || next_cp == 0x200d || (next_cp >= 0xfe00 && next_cp <= 0xfe0f);
            if !ignorable && text_font_for(font, next_cp) != chosen break;
            cursor = next;
        }
        run := string.{data = value.data + start, count = cursor - start};
        text_layout_run(*result, chosen, run, size, spacing, *x, y + ascent, *column, start, options);
    }
    result.size.x = max(result.size.x, x); return result;
}

text_layout_draw :: (layout: *Text_Layout, batcher: *TF.Batcher, position: TF.Vector2, color: TF.Color) {
    TF.batcher_push_matrix_trs(batcher, position, .{}, .{1, 1}, 0);
    TF.batcher_push_blend(batcher, TF.Blend_Mode_Premultiply);
    tint := TF.Color.{cast(u8) (cast(u32) color.r * color.a / 255), cast(u8) (cast(u32) color.g * color.a / 255), cast(u8) (cast(u32) color.b * color.a / 255), color.a};
    active: *Text_Font;
    for item: layout.glyphs {
        if item.font != active {
            if active != null { TF.batcher_pop_sampler(batcher); TF.batcher_pop_material(batcher); }
            active = item.font;
            TF.batcher_push_material(batcher, active.sprite.Mat); TF.batcher_push_sampler(batcher, active.sprite.Sampler);
        }
        ch := item.character;
        p := TF.Vector2.{item.position.x + ch.Offset.x * item.scale, item.position.y + ch.Offset.y * item.scale};
        TF.batcher_subtexture_trs(batcher, ch.Subtex, p, .{}, .{item.scale, item.scale}, 0, tint);
    }
    if active != null { TF.batcher_pop_sampler(batcher); TF.batcher_pop_material(batcher); }
    TF.batcher_pop_blend(batcher); TF.batcher_pop_matrix(batcher);
}
