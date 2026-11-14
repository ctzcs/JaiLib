using Basic;
using Math;
using Hash_Table;

// wasm 目标下没有 miniz 原生库：走 internal/web 的空实现（解压恒失败，调用方已有的
// 「cel 解压失败」路径会跑，不会崩）。
#if OS != .WASM {
    jf_mz_uncompress :: (pDest: *u8, pDest_len: *s64, pSource: *u8, source_len: s64) -> s32 #foreign miniz_impl;
} else {
    jf_mz_uncompress :: (pDest: *u8, pDest_len: *s64, pSource: *u8, source_len: s64) -> s32 {
        return -1;
    }
}

#scope_export

// Port of Foster Framework/Images/Aseprite.cs — the .ase/.aseprite file
// parser (header magic 0xA5E0, frame magic 0xF1FA). Cel decompression uses
// zlib via the vendored miniz.

ASEPRITE_OLD_PALETTE_CHUNK :: 0x0004;
ASEPRITE_OLD_PALETTE2_CHUNK :: 0x0011;
ASEPRITE_LAYER_CHUNK :: 0x2004;
ASEPRITE_CEL_CHUNK :: 0x2005;
ASEPRITE_CEL_EXTRA_CHUNK :: 0x2006;
ASEPRITE_COLOR_PROFILE_CHUNK :: 0x2007;
ASEPRITE_EXTERNAL_FILES_CHUNK :: 0x2008;
ASEPRITE_MASK_CHUNK :: 0x2016;
ASEPRITE_TAGS_CHUNK :: 0x2018;
ASEPRITE_PALETTE_CHUNK :: 0x2019;
ASEPRITE_USER_DATA_CHUNK :: 0x2020;
ASEPRITE_SLICE_CHUNK :: 0x2022;
ASEPRITE_TILESET_CHUNK :: 0x2023;

ASEPRITE_FORMAT_RGBA :: 32;
ASEPRITE_FORMAT_GRAY :: 16;
ASEPRITE_FORMAT_INDEXED :: 8;

Aseprite_Blend_Mode :: enum u16 {
    NORMAL;
    SRC;
    MULTIPLY;
    SCREEN;
    OVERLAY;
    DARKEN;
    LIGHTEN;
    COLOR_DODGE;
    COLOR_BURN;
    HARD_LIGHT;
    SOFT_LIGHT;
    DIFFERENCE;
    EXCLUSION;
    HUE;
    SATURATION;
    COLOR;
    LUMINOSITY;
    ADDITION;
    SUBTRACT;
    DIVIDE;
}

Aseprite_Layer_Flags :: enum_flags u16 {
    VISIBLE :: 1 << 0;
    EDITABLE :: 1 << 1;
    LOCK_MOVEMENT :: 1 << 2;
    BACKGROUND :: 1 << 3;
    PREFER_LINKED_CELS :: 1 << 4;
    DISPLAY_COLLAPSED :: 1 << 5;
    REFERENCE :: 1 << 6;
}

Aseprite_Layer_Type :: enum u16 {
    NORMAL;
    GROUP;
    TILEMAP;
}

Aseprite_Layer :: struct {
    Flags: Aseprite_Layer_Flags;
    Type: Aseprite_Layer_Type;
    ChildLevel: s32;
    DefaultWidth: u16;
    DefaultHeight: u16;
    BlendMode: Aseprite_Blend_Mode;
    Opacity: u8;
    Name: string;
    TilesetIndex: u32;
    UserData: Aseprite_User_Data;
}

Aseprite_User_Data :: struct {
    Text: string;
    Col: Color; // renamed from Color (shadows type)
}

Aseprite_Cel_Type :: enum u16 {
    RAW_IMAGE_DATA :: 0;
    LINKED_CEL :: 1;
    COMPRESSED_IMAGE :: 2;
    COMPRESSED_TILEMAP :: 3;
}

Aseprite_Cel :: struct {
    Layer: s32;
    Position: Point2;
    Opacity: u8;
    ZIndex: s16;
    Img: Image; // renamed from Image (field shadows type)
    UserData: Aseprite_User_Data;
}

Aseprite_Loop_Direction :: enum u8 {
    FORWARD;
    REVERSE;
    PINGPONG;
    PINGPONG_REVERSE;
}

Aseprite_Tag :: struct {
    From: u16;
    To: u16;
    LoopDirection: Aseprite_Loop_Direction;
    Repeat: u16;
    Col: Color; // renamed from Color (shadows type)
    Name: string;
    UserData: Aseprite_User_Data;
}

Aseprite_Slice_Key :: struct {
    FrameStart: u32;
    Bounds: Rect_Int;
    // 9-slice center (optional)
    HasCenter: bool;
    CenterX: s32;
    CenterY: s32;
    CenterWidth: s32;
    CenterHeight: s32;
    // pivot (optional)
    HasPivot: bool;
    PivotX: s32;
    PivotY: s32;
}

Aseprite_Slice :: struct {
    Name: string;
    Keys: [..] Aseprite_Slice_Key;
    UserData: Aseprite_User_Data;
}

Aseprite_Frame :: struct {
    DurationMS: u16;
    Cels: [..] Aseprite_Cel;
    UserData: Aseprite_User_Data;
}

Aseprite :: struct {
    Format: u16;
    Frames: [..] Aseprite_Frame;
    Layers: [..] Aseprite_Layer;
    Tags: [..] Aseprite_Tag;
    Slices: [..] Aseprite_Slice;
    Palette: [..] Color;
    TransparentColorIndex: u32;
    Width: u32;
    Height: u32;
}

aseprite_destroy :: (a: *Aseprite) {
    // `*f` so the frame's Cels array can be cleared (the source referenced `c`,
    // which is out of scope here — the loop above shadows it).
    for *f: a.Frames {
        for c: f.Cels image_destroy(*c.Img);
        f.Cels.count = 0;
    }
    a.Frames.count = 0;
    a.Layers.count = 0;
    a.Tags.count = 0;
    a.Slices.count = 0;
    a.Palette.count = 0;
    free(a);
}

//
// reader helpers
//

As_Reader :: struct {
    data: [] u8;
    pos: s32 = 0;
}

as_ok :: (r: *As_Reader, count: s32) -> bool {
    return r.pos + count <= r.data.count;
}

as_u8 :: (r: *As_Reader) -> u8 {
    v := r.data[r.pos];
    r.pos += 1;
    return v;
}

as_u16 :: (r: *As_Reader) -> u16 {
    lo: u16 = r.data[r.pos];
    hi: u16 = r.data[r.pos + 1];
    v: u16 = lo | (hi << 8);
    r.pos += 2;
    return v;
}

as_s16 :: (r: *As_Reader) -> s16 {
    return cast(s16) as_u16(r);
}

as_u32 :: (r: *As_Reader) -> u32 {
    b0: u32 = r.data[r.pos];
    b1: u32 = r.data[r.pos + 1];
    b2: u32 = r.data[r.pos + 2];
    b3: u32 = r.data[r.pos + 3];
    v: u32 = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
    r.pos += 4;
    return v;
}

as_s32 :: (r: *As_Reader) -> s32 {
    return cast(s32) as_u32(r);
}

as_string :: (r: *As_Reader) -> string {
    // Aseprite strings are length-prefixed and NOT NUL-terminated — copy
    // exactly len bytes.
    len := as_u16(r);
    out := cast(*u8) alloc(len);
    if len > 0 memcpy(out, r.data.data + r.pos, len);
    r.pos += len;
    return .{ data = out, count = cast(s64) len };
}

as_skip :: (r: *As_Reader, count: s32) {
    r.pos += count;
}

//
// parsing
//

aseprite_load :: (path: string) -> *Aseprite {
    data, ok := json_read_file(path);
    if !ok return null;
    return aseprite_parse(cast([] u8) data);
}

aseprite_parse :: (data: [] u8) -> *Aseprite {
    r: As_Reader;
    r.data = data;
    reader := *r;

    // header (116 bytes)
    file_size := as_u32(reader);
    magic := as_u16(reader);
    if magic != 0xA5E0 return null;

    frame_count := as_u16(reader);
    width := as_u16(reader);
    height := as_u16(reader);
    format := as_u16(reader);
    as_skip(reader, 2); // flags
    as_skip(reader, 2); // speed (deprecated)
    transparent_index := as_u32(reader);
    as_skip(reader, 4); // color count
    as_skip(reader, 2); // pixel ratio (byte x2)
    as_skip(reader, 4); // grid (byte x4)
    as_skip(reader, 84); // reserved

    a := New(Aseprite);
    a.Format = format;
    a.Width = width;
    a.Height = height;
    a.TransparentColorIndex = transparent_index;

    // per-layer slices used to route cels (open groups multiply nesting)
    layers_open: [..] bool;

    current_frame: s32 = -1;

    // frames
    while current_frame + 1 < frame_count {
        // frame header
        frame_size := as_u32(reader);
        frame_magic := as_u16(reader);
        if frame_magic != 0xF1FA return null;
        old_chunks := as_u16(reader);
        frame_duration := as_u16(reader);
        as_skip(reader, 2 + 4); // unused, new-chunks-32bit

        chunk_count := cast(s32) old_chunks;
        if old_chunks == 0xFFFF chunk_count = cast(s32) as_u32(reader);

        current_frame += 1;
        frame: *Aseprite_Frame;
        {
            f: Aseprite_Frame;
            f.DurationMS = frame_duration;
            array_add(*a.Frames, f);
            frame = *a.Frames[current_frame];
        }

        for c: 0..(chunk_count - 1) {
            chunk_size := as_u32(reader);
            chunk_type := as_u16(reader);
            chunk_end := r.pos + cast(s32) chunk_size - 6;

            if chunk_type == {
                case ASEPRITE_LAYER_CHUNK;
                    layer := aseprite_parse_layer_chunk(reader);

                    // route into group nesting via ChildLevel
                    if layer.ChildLevel == 0 {
                        array_add(*a.Layers, layer);
                    } else {
                        // nested (group) layers are flattened out — Foster
                        // stores only top-level; nested go to the parent's list
                        array_add(*a.Layers, layer);
                    }

                case ASEPRITE_CEL_CHUNK;
                    cel := aseprite_parse_cel_chunk(reader, a);
                    array_add(*frame.Cels, cel);

                case ASEPRITE_TAGS_CHUNK;
                    aseprite_parse_tags_chunk(reader, a);

                case ASEPRITE_PALETTE_CHUNK;
                    aseprite_parse_palette_chunk(reader, a);

                case ASEPRITE_USER_DATA_CHUNK;
                    aseprite_parse_user_data_chunk(reader, a, cast(s32) current_frame);

                case ASEPRITE_SLICE_CHUNK;
                    aseprite_parse_slice_chunk(reader, a);

                case; // old palette / others: skipped below
            }

            // skip to the end of the chunk
            if r.pos != chunk_end r.pos = chunk_end;
        }
    }

    return a;
}

aseprite_parse_layer_chunk :: (r: *As_Reader) -> Aseprite_Layer {
    l: Aseprite_Layer;
    l.Flags = cast(Aseprite_Layer_Flags) as_u16(r);
    l.Type = cast(Aseprite_Layer_Type) as_u16(r);
    l.ChildLevel = as_s16(r);
    l.DefaultWidth = as_u16(r);
    l.DefaultHeight = as_u16(r);
    l.BlendMode = cast(Aseprite_Blend_Mode) as_u16(r);
    l.Opacity = as_u8(r);
    as_skip(r, 3); // reserved
    l.Name = as_string(r);

    // tileset index follows for tilemap layers
    if l.Type == .TILEMAP {
        l.TilesetIndex = as_u32(r);
    }
    return l;
}

aseprite_parse_cel_chunk :: (r: *As_Reader, a: *Aseprite) -> Aseprite_Cel {
    cel: Aseprite_Cel;
    cel.Layer = as_s16(r);
    pos_x := as_s16(r);
    pos_y := as_s16(r);
    cel.Position = .{ pos_x, pos_y };
    cel.Opacity = as_u8(r);
    cel.ZIndex = as_s16(r);
    as_skip(r, 5); // reserved
    cel_type := cast(Aseprite_Cel_Type) as_u16(r);

    if cel_type == .LINKED_CEL {
        // linked cel references another frame's cel — look it up by layer
        linked_frame := as_s16(r);
        if linked_frame >= 0 && linked_frame < a.Frames.count {
            for other: a.Frames[linked_frame].Cels {
                if other.Layer == cel.Layer {
                    cel.Img = image_create(other.Img.Width, other.Img.Height);
                    memcpy(cel.Img.Data.data, other.Img.Data.data, cast(s64) other.Img.Width * other.Img.Height * 4);
                    return cel;
                }
            }
        }
        // no source — empty
        cel.Img = image_create(0, 0);
    } else if cel_type == .RAW_IMAGE_DATA || cel_type == .COMPRESSED_IMAGE {
        w := as_u16(r);
        h := as_u16(r);
        cel.Img = image_create(w, h);

        if cel_type == .RAW_IMAGE_DATA {
            aseprite_read_pixels(r, cel.Img, a);
        } else {
            as_skip(r, 2); // zlib placeholder
            compressed: [] u8 = .{ data = r.data.data + r.pos, count = r.data.count - r.pos };
            aseprite_inflate_pixels(compressed, *cel.Img, a);
        }
    } else if cel_type == .COMPRESSED_TILEMAP {
        log_warning("aseprite: compressed tilemap cels not supported");
        cel.Img = image_create(0, 0);
    }

    return cel;
}

aseprite_read_pixels :: (r: *As_Reader, img: Image, a: *Aseprite) {
    count := img.Width * img.Height;
    if !as_ok(r, cast(s32) count * (cast(s32) a.Format / 8)) return;
    for i: 0..count - 1 {
        img.Data[i] = aseprite_read_pixel(r, a);
    }
}

aseprite_read_pixel :: (r: *As_Reader, a: *Aseprite) -> Color {
    px: Color;
    if a.Format == ASEPRITE_FORMAT_RGBA {
        px.r = as_u8(r);
        px.g = as_u8(r);
        px.b = as_u8(r);
        px.a = as_u8(r);
    } else if a.Format == ASEPRITE_FORMAT_GRAY {
        v := as_u8(r);
        alpha := as_u8(r);
        px.r = v;
        px.g = v;
        px.b = v;
        px.a = alpha;
    } else if a.Format == ASEPRITE_FORMAT_INDEXED {
        index := as_u8(r);
        if cast(u32) index < a.Palette.count px = a.Palette[index];
        else px = Color_Transparent;
    }
    return px;
}

aseprite_inflate_pixels :: (compressed: [] u8, img: *Image, a: *Aseprite) {
    count := img.Width * img.Height;
    needed := count * (cast(s32) a.Format / 8);
    if needed <= 0 return;

    buffer := cast(*u8) alloc(needed);
    dest_len: s64 = needed;
    ok := jf_mz_uncompress(buffer, *dest_len, compressed.data, compressed.count);
    if ok != 0 { // MZ_OK == 0 in miniz
        log_warning("aseprite: cel zlib inflate failed");
        free(buffer);
        return;
    }

    for i: 0..7 print(" %", buffer[i]);
    print("\n");

    sub: As_Reader;
    sub.data = .{ data = buffer, count = needed };
    for i: 0..(count - 1) {
        img.Data[i] = aseprite_read_pixel(*sub, a);
    }
    free(buffer);
}

aseprite_parse_tags_chunk :: (r: *As_Reader, a: *Aseprite) {
    count := as_u16(r);
    as_skip(r, 8); // reserved
    for i: 0..(cast(s32) count) - 1 {
        tag: Aseprite_Tag;
        tag.From = as_u16(r);
        tag.To = as_u16(r);
        tag.LoopDirection = cast(Aseprite_Loop_Direction) as_u8(r);
        tag.Repeat = as_u16(r);
        as_skip(r, 6 + 4); // future + reserved
        tag.Col = Color.{ as_u8(r), as_u8(r), as_u8(r), as_u8(r) };
        tag.Name = as_string(r);
        array_add(*a.Tags, tag);
    }
}

aseprite_parse_palette_chunk :: (r: *As_Reader, a: *Aseprite) {
    new_size := as_u32(r);
    from := as_u32(r);
    as_skip(r, 8 + 4); // to, future
    count := as_u32(r);
    for i: 0..(cast(s64) count) - 1 {
        flags := as_u16(r);
        c := Color.{ as_u8(r), as_u8(r), as_u8(r), as_u8(r) };
        if (flags & 1) != 0 {
            as_string(r);
        } // name
        as_skip(r, 8); // future
        index := cast(s64) from + i;
        if index >= a.Palette.count {
            while a.Palette.count <= index array_add(*a.Palette, Color_Transparent);
        }
        a.Palette[index] = c;
    }
}

aseprite_parse_user_data_chunk :: (r: *As_Reader, a: *Aseprite, current_frame: s32) {
    ud := aseprite_read_user_data(r);
    if a.Layers.count > 0 {
        a.Layers[a.Layers.count - 1].UserData = ud;
    } else if current_frame >= 0 && current_frame < cast(s32) a.Frames.count {
        a.Frames[current_frame].UserData = ud;
    }
}

aseprite_read_user_data :: (r: *As_Reader) -> Aseprite_User_Data {
    ud: Aseprite_User_Data;
    flags := as_u32(r);
    if (flags & 1) != 0 {
        ud.Text = as_string(r);
    }
    if (flags & 2) != 0 {
        ud.Col = Color.{ as_u8(r), as_u8(r), as_u8(r), as_u8(r) };
    }
    return ud;
}

aseprite_parse_slice_chunk :: (r: *As_Reader, a: *Aseprite) {
    count := as_u32(r);
    flags := as_u32(r);
    as_skip(r, 4); // reserved
    name := as_string(r);

    slice: Aseprite_Slice;
    slice.Name = name;

    for i: 0..(cast(s32) count) - 1 {
        key: Aseprite_Slice_Key;
        key.FrameStart = as_u32(r);
        x := as_s32(r);
        y := as_s32(r);
        w := as_s32(r);
        h := as_s32(r);
        key.Bounds = .{ x, y, w, h };

        if (flags & 2) != 0 {
            key.HasCenter = true;
            key.CenterX = as_s32(r);
            key.CenterY = as_s32(r);
            key.CenterWidth = as_s32(r);
            key.CenterHeight = as_s32(r);
        }
        if (flags & 4) != 0 {
            key.HasPivot = true;
            key.PivotX = as_s32(r);
            key.PivotY = as_s32(r);
        }

        array_add(*slice.Keys, key);
    }

    array_add(*a.Slices, slice);
}

//
// rendering (Foster: per-layer, first cel per layer, Normal blend only)
//

aseprite_render_frame :: (a: *Aseprite, frame_index: s32, layer_filter: (layer: Aseprite_Layer) -> bool = null) -> Image {
    img := image_create(cast(s32) a.Width, cast(s32) a.Height);
    if frame_index < 0 || frame_index >= a.Frames.count return img;
    aseprite_render_frame_into(a, frame_index, *img, layer_filter);
    return img;
}

aseprite_render_frame_into :: (a: *Aseprite, frame_index: s32, img: *Image, layer_filter: (layer: Aseprite_Layer) -> bool) {
    frame := *a.Frames[frame_index];
    for layer: a.Layers {
        if (layer.Flags & .VISIBLE) == 0 continue;
        if layer.Type != .NORMAL continue;
        if layer_filter != null && !layer_filter(layer) continue;

        // first cel on this layer
        for cel: frame.Cels {
            if cel.Layer != index_of_layer(a, layer) continue;
            aseprite_composite_cel(img, cel, layer);
            break;
        }
    }
}

index_of_layer :: (a: *Aseprite, layer: Aseprite_Layer) -> s32 {
    for l, i: a.Layers {
        if l.Name == layer.Name return cast(s32) i;
    }
    return -1;
}

aseprite_composite_cel :: (img: *Image, cel: Aseprite_Cel, layer: Aseprite_Layer) {
    alpha := cast(float) (cast(u32) cel.Opacity * cast(u32) layer.Opacity) / (255.0 * 255.0);
    if alpha <= 0 return;

    for y: 0..cel.Img.Height - 1 {
        for x: 0..cel.Img.Width - 1 {
            dx := cel.Position.x + x;
            dy := cel.Position.y + y;
            if dx < 0 || dy < 0 || dx >= img.Width || dy >= img.Height continue;

            src := cel.Img.Data[y * cel.Img.Width + x];
            dst := *img.Data[dy * img.Width + dx];
            img.Data[dy * img.Width + dx] = aseprite_blend_normal(src, dst, alpha);
        }
    }
}

aseprite_blend_normal :: (src: Color, dst: Color, opacity: float) -> Color {
    if src.a == 0 return dst;
    if dst.a == 0 {
        out := src;
        out.a = cast(u8) (cast(float) src.a * opacity);
        return color_premultiply(out);
    }

    sa := (cast(float) src.a / 255.0) * opacity;
    da := cast(float) dst.a / 255.0;
    // standard over with integer rounding (Foster's BlendNormal)
    t := cast(u32) (sa * 255.0 * dst.a + 0x80);
    blend := cast(u8) ((t >> 8) + t >> 8);

    inv := 255 - blend;
    out: Color;
    out.r = cast(u8) ((cast(u32) src.r * dst.a + cast(u32) dst.r * inv + 127) / 255);
    out.g = cast(u8) ((cast(u32) src.g * dst.a + cast(u32) dst.g * inv + 127) / 255);
    out.b = cast(u8) ((cast(u32) src.b * dst.a + cast(u32) dst.b * inv + 127) / 255);
    out.a = max(dst.a, cast(u8) (sa * 255.0));
    out = color_premultiply(out);
    return out;
}
