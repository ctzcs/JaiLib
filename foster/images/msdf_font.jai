using Basic;
using Math;
using Hash_Table;

#scope_module

// Port of Foster Framework/Images/MsdfFont.cs — loads a msdf-atlas-gen JSON
// + PNG atlas. Generation is external (msdf-atlas-gen), as upstream.

Msdf_Font_Glyph :: struct {
    Unicode: s32;
    Advance: float;
    PlaneBounds: Rect; // l/t/r/b stored as x/y/w/h-ish rect fields below
    AtlasBounds: Rect;
    pl: float;
    pt: float;
    pr: float;
    pb: float; // plane l/t/r/b
    al: float;
    at: float;
    ar: float;
    ab: float; // atlas l/t/r/b
}

Msdf_Font :: struct {
    Atlas: *Image = null;
    Glyphs: [..] Msdf_Font_Glyph;
    lookup: Table(s32, s32); // codepoint -> glyph index

    EmSize: float;
    LineHeight: float;
    Ascender: float;
    Descender: float;
    UnderlineY: float;
    UnderlineThickness: float;

    Size: float;
    Ascent: float;
    Descent: float;
    LineGap: float;
    DistanceRange: float;
    DistanceRangeMiddle: float;
}

msdf_font_load :: (json_path: string) -> *Msdf_Font {
    // Foster: image next to the json, same basename with .png
    png_path := tprint("%", sub_string(json_path, 0, find_string_from_end(json_path, ".")));
    png_path = tprint("%.png", png_path);
    return msdf_font_load_paths(json_path, png_path);
}

msdf_font_load_paths :: (json_path: string, png_path: string) -> *Msdf_Font {
    json_bytes, json_ok := File.read_entire_file(json_path);
    if !json_ok {
        log_warning(tprint("msdf font json not found: %", json_path));
        return null;
    }
    defer free(json_bytes.data);
    png_bytes, png_ok := File.read_entire_file(png_path);
    if !png_ok {
        log_warning(tprint("msdf font atlas png not found: %", png_path));
        return null;
    }
    defer free(png_bytes.data);
    return msdf_font_load_bytes(cast([] u8) json_bytes, cast([] u8) png_bytes);
}

// Decode caller-owned bytes; works for files and embedded resources alike.
msdf_font_load_bytes :: (json_bytes: [] u8, png_bytes: [] u8) -> *Msdf_Font {
    root, ok := json_parse(cast(string) json_bytes);
    if !ok {
        log_warning("Invalid MSDF font JSON");
        return null;
    }
    defer json_destroy(root);

    f := New(Msdf_Font);

    atlas := json_get(root, "atlas");
    f.DistanceRange = cast(float) json_get_number(atlas, "distanceRange");
    f.DistanceRangeMiddle = cast(float) json_get_number(atlas, "distanceRangeMiddle");
    f.Size = cast(float) json_get_number(atlas, "size");

    metrics := json_get(root, "metrics");
    f.EmSize = cast(float) json_get_number(metrics, "emSize");
    f.LineHeight = cast(float) json_get_number(metrics, "lineHeight");
    f.Ascender = cast(float) json_get_number(metrics, "ascender");
    f.Descender = cast(float) json_get_number(metrics, "descender");
    f.UnderlineY = cast(float) json_get_number(metrics, "underlineY");
    f.UnderlineThickness = cast(float) json_get_number(metrics, "underlineThickness");

    f.Ascent = abs(f.Size * f.Ascender);
    f.Descent = -abs(f.Size * f.Descender);
    f.LineGap = f.Size * f.LineHeight - (f.Ascent - f.Descent);

    glyphs := json_get(root, "glyphs");
    count := json_array_count(glyphs);
    array_reserve(*f.Glyphs, count);
    for i: 0..count - 1 {
        g := json_array_at(glyphs, i);
        glyph: Msdf_Font_Glyph;
        glyph.Unicode = cast(s32) json_get_number(g, "unicode");
        glyph.Advance = cast(float) json_get_number(g, "advance") * f.Size;

        plane := json_get(g, "planeBounds");
        glyph.pl = cast(float) json_get_number(plane, "left");
        glyph.pt = cast(float) json_get_number(plane, "top");
        glyph.pr = cast(float) json_get_number(plane, "right");
        glyph.pb = cast(float) json_get_number(plane, "bottom");

        ab := json_get(g, "atlasBounds");
        glyph.al = cast(float) json_get_number(ab, "left");
        glyph.at = cast(float) json_get_number(ab, "top");
        glyph.ar = cast(float) json_get_number(ab, "right");
        glyph.ab = cast(float) json_get_number(ab, "bottom");

        table_set(*f.lookup, glyph.Unicode, cast(s32) f.Glyphs.count);
        array_add(*f.Glyphs, glyph);
    }

    // load the atlas image
    img := image_decode(png_bytes);
    if img.Width <= 0 {
        log_warning("Invalid MSDF font atlas PNG");
        msdf_font_destroy(f);
        return null;
    }
    f.Atlas = New(Image);
    f.Atlas.* = img;

    return f;
}

msdf_font_destroy :: (f: *Msdf_Font) {
    if f.Atlas != null {
        image_destroy(f.Atlas);
        free(f.Atlas);
    }
    array_free(f.Glyphs);
    deinit(*f.lookup);
    free(f);
}

find_string_from_end :: (s: string, needle: string) -> s32 {
    // Both bounds are typed so the loop variable is s32 (`0` alone infers s64).
    for i: (cast(s32) s.count - cast(s32) needle.count)..cast(s32) 0 {
        if sub_string(s, i, cast(s32) needle.count) == needle return i;
    }
    return -1;
}

sub_string :: (s: string, start: s32, count: s32) -> string {
    if start < 0 start = 0;
    if start + count > cast(s32) s.count count = cast(s32) s.count - start;
    if count <= 0 return "";
    return .{ data = s.data + start, count = count };
}
