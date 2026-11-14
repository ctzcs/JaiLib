#import "Basic";
F :: #import "foster";
File :: #import "File";

embed_asset :: (name: string) -> string {
    bytes, ok := File.read_entire_file(tprint("%/../../../assets/fonts/msdf/%", #filepath, name));
    assert(ok);
    return bytes;
}

FONT_JSON :: #run embed_asset("ui.json");
FONT_PNG :: #run embed_asset("ui.png");

main :: () {
    font := F.msdf_font_load_bytes(cast([] u8) FONT_JSON, cast([] u8) FONT_PNG);
    assert(font != null);
    defer F.msdf_font_destroy(font);
    assert(font.Atlas != null && font.Atlas.Width == 1152 && font.Atlas.Height == 1152);
    assert(font.Glyphs.count == 509 && font.Size == 48 && font.DistanceRange == 8);
    // ASCII plus the Chinese characters for "Chinese", "game", and "settings".
    for code: int.[65, 20013, 25991, 28216, 25103, 35774, 32622] {
        found := false;
        for glyph: font.Glyphs {
            if glyph.Unicode == code {
                assert(glyph.Advance > 0 && glyph.ar > glyph.al && glyph.ab > glyph.at);
                assert(glyph.al >= 0 && glyph.at >= 0 && glyph.ar <= 1152 && glyph.ab <= 1152);
                found = true;
            }
        }
        assert(found, "Missing built-in glyph %", code);
    }
    print("PASS builtin MSDF: 509 glyphs, decoded 1152x1152 PNG\n");
}
