using Basic;
using Math;
#scope_module
// image_load reads bytes via the module-level File alias (utility/json.jai).

// Port of Foster Framework/Images/Image.cs + Internal/ThirdParty/Qoi.cs.
// CPU-side RGBA image. PNG decode/encode goes through SDL3 (bindings below);
// QOI is a direct port of the reference codec.

Image :: struct {
    Width: s32;
    Height: s32;
    Data: [] Color; // Width * Height RGBA
}

image_create :: (width: s32, height: s32, color := Color_Transparent) -> Image {
    img: Image;
    img.Width = width;
    img.Height = height;
    img.Data = .{
        data = cast(*Color) alloc(size_of(Color) * width * height),
        count = cast(s64) width * height,
    };
    for *p: img.Data p.* = color;
    return img;
}

image_destroy :: (img: *Image) {
    if img.Data.count > 0 {
        free(img.Data.data);
        img.Data = .[];
    }
    img.Width = 0;
    img.Height = 0;
}

image_is_empty :: (img: Image) -> bool {
    return img.Width <= 0 || img.Height <= 0;
}

image_pixel :: (img: *Image, x: s32, y: s32) -> Color {
    return img.Data[y * img.Width + x];
}

image_set_pixel :: (img: *Image, x: s32, y: s32, c: Color) {
    img.Data[y * img.Width + x] = c;
}

// Foster Image(path/stream) — decode via QOI or PNG (SDL_LoadPNG_IO)
image_load :: (path: string) -> Image {
    bytes, ok := File.read_entire_file(path);
    if !ok return .{};
    return image_decode(cast([] u8) bytes);
}

image_decode :: (bytes: [] u8) -> Image {
    if qoi_is_format(bytes) return qoi_decode(bytes);
    return image_decode_png(bytes);
}

image_encode_qoi :: (img: Image) -> [] u8 {
    return qoi_encode(img.Data, img.Width, img.Height);
}

image_encode_png :: (img: Image) -> [] u8 {
    return image_encode_png_impl(img);
}

// Premultiplies alpha in place (integer math per Foster).
image_premultiply :: (img: *Image) {
    for *p: img.Data p.* = color_premultiply(p.*);
}

// Blit: copies a region of src into this image at dest (clipped), with
// optional per-pixel blend (Foster CopyPixels).
image_copy_pixels :: (dest: *Image, source_px: [] Color, src_w: s32, src_h: s32,
                      src_x: s32, src_y: s32, src_rect_w: s32, src_rect_h: s32,
                      dest_x: s32, dest_y: s32) {
    // clip
    if dest_x < 0 {
        src_rect_w += dest_x;
        src_x -= dest_x;
        dest_x = 0;
    }
    if dest_y < 0 {
        src_rect_h += dest_y;
        src_y -= dest_y;
        dest_y = 0;
    }
    if dest_x + src_rect_w > dest.Width src_rect_w = dest.Width - dest_x;
    if dest_y + src_rect_h > dest.Height src_rect_h = dest.Height - dest_y;
    if src_rect_w <= 0 || src_rect_h <= 0 return;

    for y: 0..src_rect_h - 1 {
        src_row := (src_y + y) * src_w + src_x;
        dst_row := (dest_y + y) * dest.Width + dest_x;
        memcpy(dest.Data.data + dst_row, source_px.data + src_row, src_rect_w * size_of(Color));
    }
}

//
// QOI codec (port of https://github.com/phoboslab/qoi, zlib license)
//

qoi_is_format :: (bytes: [] u8) -> bool {
    return bytes.count >= 4 && bytes[0] == #char "q" && bytes[1] == #char "o" && bytes[2] == #char "i" && bytes[3] == #char "f";
}

qoi_hash :: (c: Color) -> u32 {
    return (cast(u32) c.r * 3 + cast(u32) c.g * 5 + cast(u32) c.b * 7 + cast(u32) c.a * 11) & 63;
}

QOI_OP_INDEX :: 0x00;
QOI_OP_DIFF :: 0x40;
QOI_OP_LUMA :: 0x80;
QOI_OP_RUN :: 0xc0;
QOI_OP_RGB :: 0xfe;
QOI_OP_RGBA :: 0xff;
QOI_MASK_2 :: 0xc0;

qoi_decode :: (bytes: [] u8) -> Image {
    if bytes.count < 14 + 8 return .{};
    w := cast(s32) (((cast(u32) bytes[4]) << 24) | ((cast(u32) bytes[5]) << 16) | ((cast(u32) bytes[6]) << 8) | cast(u32) bytes[7]);
    h := cast(s32) (((cast(u32) bytes[8]) << 24) | ((cast(u32) bytes[9]) << 16) | ((cast(u32) bytes[10]) << 8) | cast(u32) bytes[11]);
    channels := bytes[12];
    if w <= 0 || h <= 0 || channels < 3 || channels > 4 return .{};

    img := image_create(w, h);
    index: [64] Color;
    px := Color.{ 0, 0, 0, 255 };
    p := 14;
    run := 0;
    chunks_len := bytes.count - 8;

    px_len := w * h;
    for i: 0..px_len - 1 {
        if run > 0 {
            run -= 1;
        } else if p < chunks_len {
            b1 := bytes[p];
            p += 1;

            if b1 == QOI_OP_RGB {
                px.r = bytes[p];
                px.g = bytes[p + 1];
                px.b = bytes[p + 2];
                p += 3;
            } else if b1 == QOI_OP_RGBA {
                px.r = bytes[p];
                px.g = bytes[p + 1];
                px.b = bytes[p + 2];
                px.a = bytes[p + 3];
                p += 4;
            } else if (b1 & QOI_MASK_2) == QOI_OP_INDEX {
                px = index[b1];
            } else if (b1 & QOI_MASK_2) == QOI_OP_DIFF {
                px.r = cast(u8) (((cast(s32) px.r) + (cast(s32) ((b1 >> 4) & 0x03)) - 2) & 255);
                px.g = cast(u8) (((cast(s32) px.g) + (cast(s32) ((b1 >> 2) & 0x03)) - 2) & 255);
                px.b = cast(u8) (((cast(s32) px.b) + (cast(s32) (b1 & 0x03)) - 2) & 255);
            } else if (b1 & QOI_MASK_2) == QOI_OP_LUMA {
                b2 := cast(s32) bytes[p];
                p += 1;
                vg := (cast(s32) (b1 & 0x3f)) - 32;
                px.r = cast(u8) (((cast(s32) px.r) + vg - 8 + ((b2 >> 4) & 0x0f)) & 255);
                px.g = cast(u8) (((cast(s32) px.g) + vg) & 255);
                px.b = cast(u8) (((cast(s32) px.b) + vg - 8 + (b2 & 0x0f)) & 255);
            } else if (b1 & QOI_MASK_2) == QOI_OP_RUN {
                run = cast(s32) (b1 & 0x3f);
            }

            index[qoi_hash(px)] = px;
        }

        img.Data[i] = px;
    }

    return img;
}

qoi_encode :: (pixels: [] Color, w: s32, h: s32) -> [] u8 {
    if pixels.count < cast(s64) w * h return .[];
    buf: String_Builder;

    write32 :: (b: *String_Builder, v: u32) {
        append(b, cast(u8) ((v >> 24) & 255));
        append(b, cast(u8) ((v >> 16) & 255));
        append(b, cast(u8) ((v >> 8) & 255));
        append(b, cast(u8) (v & 255));
    }

    append(*buf, "qoif");
    write32(*buf, cast(u32) w);
    write32(*buf, cast(u32) h);
    append(*buf, 4); // channels
    append(*buf, 0); // srgb

    index: [64] Color;
    prev := Color.{ 0, 0, 0, 255 };
    run := 0;

    total := w * h;
    for i: 0..total - 1 {
        px := pixels[i];

        if px == prev {
            run += 1;
            if run == 62 || i == total - 1 {
                append(*buf, cast(u8) (QOI_OP_RUN | (run - 1)));
                run = 0;
            }
        } else {
            if run > 0 {
                append(*buf, cast(u8) (QOI_OP_RUN | (run - 1)));
                run = 0;
            }

            idx := qoi_hash(px);
            if index[idx] == px {
                append(*buf, cast(u8) (QOI_OP_INDEX | idx));
            } else {
                vr := (cast(s32) px.r) - (cast(s32) prev.r);
                vg := (cast(s32) px.g) - (cast(s32) prev.g);
                vb := (cast(s32) px.b) - (cast(s32) prev.b);

                if px.a != prev.a {
                    append(*buf, QOI_OP_RGBA);
                    append(*buf, px.r);
                    append(*buf, px.g);
                    append(*buf, px.b);
                    append(*buf, px.a);
                } else if vr >= -2 && vr <= 1 && vg >= -2 && vg <= 1 && vb >= -2 && vb <= 1 {
                    append(*buf, cast(u8) (QOI_OP_DIFF | ((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2)));
                } else if vg >= -32 && vg <= 31 && (vr - vg) >= -8 && (vr - vg) <= 7 && (vb - vg) >= -8 && (vb - vg) <= 7 {
                    append(*buf, cast(u8) (QOI_OP_LUMA | (vg + 32)));
                    append(*buf, cast(u8) (((vr - vg + 8) << 4) | (vb - vg + 8)));
                } else {
                    append(*buf, QOI_OP_RGB);
                    append(*buf, px.r);
                    append(*buf, px.g);
                    append(*buf, px.b);
                }
                index[idx] = px;
            }
        }

        prev = px;
    }

    for i: 0..6 append(*buf, 0);
    append(*buf, 1);

    return cast([] u8) builder_to_string(*buf);
}

//
// PNG via SDL3 (Foster's ImageData path)
//
// [W1] This is the only SDL dependency left in images/: SDL3's PNG decoder and
// encoder (SDL_LoadPNG_IO / SDL_SavePNG_IO / the SDL_IOStream pair). The wasm
// build gets an honest "cannot decode here" pair instead of a stub that pretends
// to succeed — an empty Image is what the desktop version returns when the file
// is not a PNG at all, so callers already handle it (images/msdf_font.jai checks
// image_is_empty). QOI is decoded by the pure-Jai qoi_decode above and keeps
// working on both targets.
//
// W2/W3 options, in internal/web/README.md §8: the browser's ImageDecoder API
// (async, needs a bridge call and a callback into Jai), or a pure-Jai inflate +
// PNG unfilter (roughly 300 lines, no bridge round-trip).
//
#if OS != .WASM {

    image_decode_png :: (bytes: [] u8) -> Image {
        io := SDL_IOFromConstMem(bytes.data, cast(u64) bytes.count);
        if io == null return .{};
        surface := SDL_LoadPNG_IO(io);
        SDL_CloseIO(io);
        if surface == null return .{};

        // convert to RGBA32 if needed
        converted: *SDL_Surface;
        if surface.format != .RGBA32 {
            converted = SDL_ConvertSurface(surface, .RGBA32);
            SDL_DestroySurface(surface);
            surface = converted;
            if surface == null return .{};
        }

        img := image_create(surface.w, surface.h);
        if surface.pitch == surface.w * 4 {
            memcpy(img.Data.data, surface.pixels, cast(s64) surface.w * surface.h * 4);
        } else {
            // copy row by row
            src := cast(*u8) surface.pixels;
            for y: 0..surface.h - 1 {
                memcpy(img.Data.data + y * surface.w, src + y * surface.pitch, surface.w * 4);
            }
        }

        SDL_DestroySurface(surface);
        return img;
    }

    image_encode_png_impl :: (img: Image) -> [] u8 {
        surface := SDL_CreateSurfaceFrom(img.Width, img.Height, .RGBA32, img.Data.data, img.Width * 4);
        if surface == null return .[];

        io := SDL_IOFromDynamicMem();
        if io == null {
            SDL_DestroySurface(surface);
            return .[];
        }

        result: [] u8 = .[];
        if SDL_SavePNG_IO(surface, io) {
            size := SDL_GetIOSize(io);
            if size > 0 {
                props := SDL_GetIOProperties(io);
                mem := cast(*u8) SDL_GetPointerProperty(props, to_cstr(SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER), null);
                if mem != null {
                    // The stream owns mem and releases it in SDL_CloseIO.
                    // Return a separate Jai allocation owned by the caller.
                    result = .{ data = cast(*u8) alloc(cast(s64) size), count = cast(s64) size };
                    memcpy(result.data, mem, cast(s64) size);
                }
            }
        }

        SDL_CloseIO(io);
        SDL_DestroySurface(surface);
        return result;
    }

} else {

    // [W1] Web: no SDL surface/IOStream layer, so PNG is not available yet. Both
    // halves report failure the same way the desktop versions do when SDL rejects the
    // input (empty Image / empty byte slice), which means the callers' existing
    // "failed to load" paths run instead of a bogus success.
    image_decode_png :: (bytes: [] u8) -> Image {
        if bytes.data == null || bytes.count <= 0 return .{};
        // Jai 不做相邻字符串字面量拼接，写成一个字符串。
        log_warning("image_decode_png: web 目标下没有 PNG 解码器（SDL_Surface 是 native 链路）；需要 ImageDecoder 桥或纯 Jai inflate —— W2/W3 接上");
        return .{};
    }

    image_encode_png_impl :: (img: Image) -> [] u8 {
        if image_is_empty(img) return .[];
        log_warning("image_encode_png_impl: web 目标下没有 PNG 编码器，W3 接上");
        return .[];
    }

}
