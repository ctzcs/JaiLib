using Basic;
using Math;
using Hash_Table;

// Port of Foster Framework/Graphics/SpriteFont.cs — bakes a Font into
// texture pages and renders text through the Batcher.

Sprite_Font_Character :: struct {
    Codepoint: s32;
    Subtex: Subtexture; // renamed from Subtexture (shadows type)
    Advance: float;
    Offset: Vector2;
    Exists: bool;
}

Sprite_Font :: struct {
    device: *Graphics_Device;

    Size: float;
    Ascent: float;
    Descent: float;
    LineGap: float;

    characters: Table(s32, Sprite_Font_Character);
    generated_textures: [..] *Texture;
    kerning: Table(s64, float);

    NewlineCharacters: string = "\n";
    WordbreakCharacters: string = "\n ";

    Mat: *Material = null; // renamed from Material (shadows type)
    IsMsdf: bool;
    Sampler: Texture_Sampler;
    Kerning_Provider: *Font = null;

    font: *Font = null;
    font_size: float;
}

ASCII_CODEPOINTS :: #run generate_ascii();

generate_ascii :: () -> [95] s32 {
    r: [95] s32;
    for i: 0..94 r[i] = 32 + cast(s32) i;
    return r;
}

sprite_font_create_from_font :: (device: *Graphics_Device, font: *Font, size: float,
                                 codepoints: [] s32,
                                 pixel_perfect := false) -> *Sprite_Font {
    sf := New(Sprite_Font);
    sf.device = device;
    sf.font = font;
    sf.font_size = size;
    sf.Kerning_Provider = font;

    sf.Size = size;
    sf.Ascent = font.Ascent * size;
    sf.Descent = font.Descent * size;
    sf.LineGap = font.LineGap * size;

    sf.Sampler = texture_sampler_make(.LINEAR, .CLAMP);

    // pass 1: rasterize + collect characters
    Glyph_Entry :: struct {
        codepoint: s32;
        advance: float;
        offset: Vector2;
        pixels: [] Color;
        w: s32;
        h: s32;
        exists: bool;
    };
    glyphs: [..] Glyph_Entry;

    for cp: codepoints {
        c := font_get_character(font, cp, size);
        g: Glyph_Entry;
        g.codepoint = cp;
        g.advance = c.Advance;
        g.offset = c.Offset;
        g.w = c.Width;
        g.h = c.Height;
        g.exists = c.Visible;
        if c.Visible {
            px: [] Color = .{
                data = cast(*Color) alloc(size_of(Color) * c.Width * c.Height),
                count = cast(s64) c.Width * c.Height,
            };
            font_get_pixels(font, px, c.GlyphIndex, c.Width, c.Height, c.Scale, true);
            if pixel_perfect {
                for *p: px {
                    if p.a < 128 p.* = Color_Transparent;
                    else p.* = Color_White;
                }
            }
            g.pixels = px;
        }
        array_add(*glyphs, g);
    }

    // pass 2: pack
    p := packer_create(.{ Trim = false, Padding = 1, MaxSize = 8192 });
    for g, i: glyphs {
        if g.exists {
            packer_add(*p, tprint("glyph%", g.codepoint), g.pixels, g.w, g.h);
        }
    }
    packer_pack(*p);

    // pass 3: create textures + character table
    for page: p.Pages {
        tex := texture_create_from_colors(device, page.Width, page.Height, page.Data);
        array_add(*sf.generated_textures, tex);
    }

    glyph_index := 0;
    for g: glyphs {
        ch: Sprite_Font_Character;
        ch.Codepoint = g.codepoint;
        ch.Advance = g.advance;
        ch.Offset = g.offset;
        ch.Exists = g.exists;

        if g.exists {
            entry := p.Output[glyph_index];
            page_tex := sf.generated_textures[entry.Page];
            src := Rect.{
                cast(float) entry.Source.x, cast(float) entry.Source.y,
                cast(float) entry.Source.w, cast(float) entry.Source.h,
            };
            frame := Rect.{
                cast(float) entry.Frame.x, cast(float) entry.Frame.y,
                cast(float) entry.Frame.w, cast(float) entry.Frame.h,
            };
            ch.Subtex = subtexture_make(page_tex, src, frame);
            glyph_index += 1;
        }

        table_set(*sf.characters, g.codepoint, ch);
        if g.pixels.count > 0 free(g.pixels.data);
    }

    // default material
    sf.Mat = material_clone(defaults_textured_material(device));

    packer_destroy(*p);
    array_free(glyphs);

    return sf;
}

sprite_font_destroy :: (sf: *Sprite_Font) {
    for t: sf.generated_textures {
        texture_dispose(t);
        free(t);
    }
    array_free(sf.generated_textures);
    deinit(*sf.characters);
    deinit(*sf.kerning);
    if sf.Mat != null material_destroy(sf.Mat);
    free(sf);
}

// Atlas and metrics are copied/uploaded; the caller retains the CPU Msdf_Font.
// The embedded atlas uses top-origin plane and texture bounds, as Foster does.
sprite_font_create_from_msdf :: (device: *Graphics_Device, msdf: *Msdf_Font) -> *Sprite_Font {
    sf := New(Sprite_Font);
    sf.device = device;
    sf.Size = msdf.Size;
    sf.Ascent = msdf.Ascent;
    sf.Descent = msdf.Descent;
    sf.LineGap = msdf.LineGap;
    sf.IsMsdf = true;
    sf.Sampler = texture_sampler_make(.LINEAR, .CLAMP);
    sf.Mat = material_clone(defaults_msdf_material(device));
    params: [4] float32 = .[msdf.DistanceRange, 0, 0, 0];
    bytes := ([] u8).{ data = cast(*u8) *params, count = size_of([4] float32) };
    material_stage_set_uniform(*sf.Mat.Fragment, 0, bytes);
    tex := texture_create_from_colors(device, msdf.Atlas.Width, msdf.Atlas.Height, msdf.Atlas.Data);
    array_add(*sf.generated_textures, tex);
    for g: msdf.Glyphs {
        ch: Sprite_Font_Character;
        ch.Codepoint = g.Unicode;
        ch.Advance = g.Advance;
        ch.Offset = .{ g.pl * msdf.Size, g.pt * msdf.Size };
        ch.Exists = true; // Space has advance but no drawable quad.
        if g.ar > g.al && g.ab > g.at {
            ch.Subtex = subtexture_make_source(tex, .{ g.al, g.at, g.ar - g.al, g.ab - g.at });
        }
        table_set(*sf.characters, g.Unicode, ch);
    }
    return sf;
}

sprite_font_height :: (sf: *Sprite_Font) -> float {
    return sf.Ascent - sf.Descent;
}

sprite_font_line_height :: (sf: *Sprite_Font) -> float {
    return sf.Ascent - sf.Descent + sf.LineGap;
}

sprite_font_get_character :: (sf: *Sprite_Font, codepoint: s32) -> Sprite_Font_Character {
    ch := table_find_pointer(*sf.characters, codepoint);
    if ch != null return <<ch;
    return .{ Codepoint = codepoint, Exists = false };
}

sprite_font_try_get_character :: (sf: *Sprite_Font, codepoint: s32) -> Sprite_Font_Character, bool {
    ch := table_find_pointer(*sf.characters, codepoint);
    if ch != null return <<ch, true;
    return .{ Codepoint = codepoint, Exists = false }, false;
}

sprite_font_set_kerning :: (sf: *Sprite_Font, first: s32, second: s32, amount: float) {
    key := (cast(s64) first << 32) | cast(s64) cast(u32) second;
    table_set(*sf.kerning, key, amount);
}

sprite_font_get_kerning :: (sf: *Sprite_Font, first: s32, second: s32) -> float {
    key := (cast(s64) first << 32) | cast(s64) cast(u32) second;
    cached := table_find_pointer(*sf.kerning, key);
    if cached != null return <<cached;

    amount: float = 0;
    if sf.Kerning_Provider != null {
        amount = font_get_kerning(sf.Kerning_Provider, first, second, sf.font_size);
    }
    table_set(*sf.kerning, key, amount);
    return amount;
}

sprite_font_width_of_char :: (sf: *Sprite_Font, ch: Sprite_Font_Character, last_codepoint: s32 = 0) -> float {
    width := ch.Advance;
    // (float addition below)
    if last_codepoint != 0 {
        width += sprite_font_get_kerning(sf, last_codepoint, ch.Codepoint);
    }
    return width;
}

sprite_font_width_of_line :: (sf: *Sprite_Font, text: string) -> float {
    width := 0.0;
    last: s32 = 0;
    it := rune_iterator(text);
    while true {
        r, i := rune_next(*it);
        if i >= text.count break;
        ch := sprite_font_get_character(sf, r);
        if ch.Exists {
            width += sprite_font_width_of_char(sf, ch, last);
            last = r;
        }
    }
    return width;
}

sprite_font_height_of :: (sf: *Sprite_Font, text: string) -> float {
    return sprite_font_line_height(sf);
}

sprite_font_size_of :: (sf: *Sprite_Font, text: string) -> Vector2 {
    return Vector2.{ sprite_font_width_of_line(sf, text), sprite_font_line_height(sf) };
}

sprite_font_draw :: (sf: *Sprite_Font, b: *Batcher, text: string, position: Vector2, color: Color, justify: Vector2 = Vector2.{ 0, 0 }) {
    at := Vector2.{ 0, sf.Ascent };
    at.x -= justify.x * sprite_font_width_of_line(sf, text);
    at.y -= justify.y * sprite_font_height_of(sf, text);

    batcher_push_matrix(b, matrix3x2_create_translation(position.x, position.y));
    batcher_push_material(b, sf.Mat);
    batcher_push_sampler(b, sf.Sampler);

    last: s32 = 0;
    it := rune_iterator(text);
    while true {
        r, i := rune_next(*it);
        if i >= text.count break;
        if r == #char "\n" {
            at.x = -justify.x * sprite_font_width_of_line(sf, text);
            at.y += sprite_font_line_height(sf);
            last = 0;
            continue;
        }
        ch := sprite_font_get_character(sf, r);
        if ch.Exists {
            if last != 0 at.x += sprite_font_get_kerning(sf, last, r);
            batcher_subtexture_at(b, ch.Subtex, at + ch.Offset, color);
            at.x += ch.Advance;
            last = r;
        }
    }

    batcher_pop_sampler(b);
    batcher_pop_material(b);
    batcher_pop_matrix(b);
}

// utf-8 rune iteration
rune_iterator :: (text: string) -> Rune_Iterator {
    return .{ text = text };
}

Rune_Iterator :: struct {
    text: string;
    pos: s32 = 0;
}

rune_next :: (it: *Rune_Iterator) -> s32, s32 {
    if it.pos >= it.text.count return 0, it.pos;
    c := it.text[it.pos];
    if c < 0x80 {
        it.pos += 1;
        return cast(s32) c, it.pos - 1;
    }
    len := 1;
    rune: u32 = 0;
    if c & 0xE0 == 0xC0 {
        len = 2;
        rune = c & 0x1F;
    } else if c & 0xF0 == 0xE0 {
        len = 3;
        rune = c & 0x0F;
    } else if c & 0xF8 == 0xF0 {
        len = 4;
        rune = c & 0x07;
    } else {
        it.pos += 1;
        return #char "?", it.pos - 1;
    }

    for i: 1..len - 1 {
        if it.pos + cast(s32) i >= it.text.count break;
        rune = (rune << 6) | (it.text[it.pos + cast(s32) i] & 0x3F);
    }
    start := it.pos;
    it.pos += cast(s32) len;
    return cast(s32) rune, start;
}
