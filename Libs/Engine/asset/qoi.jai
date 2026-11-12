// qoi.jai
// Pure-Jai QOI encoder/decoder ("Quite OK Image", https://qoiformat.org).
// Replaces olib's foster.ImageFromEncoded / foster.ImageWriteQoi so the asset
// pipeline has no graphics-framework dependency. Handles 3-channel (RGB,
// alpha forced to 255 on decode) and 4-channel (RGBA) files; all multi-byte
// integers are big-endian per the spec.

#import "Basic";

QOI_MAGIC :: "qoif";
QOI_HEADER_SIZE :: 14;
QOI_END_MARKER :: u8.[ 0, 0, 0, 0, 0, 0, 0, 1 ];
QOI_PIXELS_MAX :: 400_000_000; // spec sanity limit

Qoi_Image :: struct {
    width:  int;
    height: int;
    pixels: []u8; // RGBA8, width*height*4 bytes
}

// ---- encode ----

// pixels: RGBA8 bytes, width*height*4 long. Returns the QOI file bytes
// (context allocator; caller frees).
qoi_encode :: (width: int, height: int, pixels: []u8) -> string {
    assert(pixels.count == width * height * 4);
    assert(width > 0 && height > 0);

    out: String_Builder;
    append(*out, QOI_MAGIC);
    write_be32(*out, width);
    write_be32(*out, height);
    append(*out, 4); // channels
    append(*out, 0); // colorspace: sRGB with linear alpha

    index: [64] [4]u8;
    for 0..63 {
        index[it] = .[0, 0, 0, 0];
    }

    prev := u8.[0, 0, 0, 255];
    run := 0;

    px := 0;
    while px < width * height {
        c := u8.[
            pixels[px * 4 + 0],
            pixels[px * 4 + 1],
            pixels[px * 4 + 2],
            pixels[px * 4 + 3],
        ];

        if c[0] == prev[0] && c[1] == prev[1] && c[2] == prev[2] && c[3] == prev[3] {
            run += 1;
            if run == 62 || px == width * height - 1 {
                append(*out, cast(u8) (0xC0 | (run - 1))); // QOI_OP_RUN
                run = 0;
            }
        } else {
            if run > 0 {
                append(*out, cast(u8) (0xC0 | (run - 1)));
                run = 0;
            }

            slot := (cast(int) c[0] * 3 + cast(int) c[1] * 5 + cast(int) c[2] * 7 + cast(int) c[3] * 11) % 64;
            if index[slot][0] == c[0] && index[slot][1] == c[1] && index[slot][2] == c[2] && index[slot][3] == c[3] {
                append(*out, cast(u8) slot); // QOI_OP_INDEX
            } else {
                index[slot] = c;

                vr := wrap_delta(c[0], prev[0]);
                vg := wrap_delta(c[1], prev[1]);
                vb := wrap_delta(c[2], prev[2]);

                if c[3] == prev[3] && in_range(vr, -2, 1) && in_range(vg, -2, 1) && in_range(vb, -2, 1) {
                    // QOI_OP_DIFF: 2-bit two's-complement deltas packed in one byte.
                    append(*out, cast(u8) (0x40 | ((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2)));
                } else if c[3] == prev[3] && in_range(vg, -32, 31) && in_range(vr - vg, -8, 7) && in_range(vb - vg, -8, 7) {
                    // QOI_OP_LUMA: green delta plus red/blue deltas relative to green.
                    append(*out, cast(u8) (0x80 | (vg + 32)));
                    append(*out, cast(u8) (((vr - vg + 8) << 4) | (vb - vg + 8)));
                } else if c[3] == 255 {
                    append(*out, 0xFE); // QOI_OP_RGB (alpha implicitly 255)
                    append(*out, c[0]);
                    append(*out, c[1]);
                    append(*out, c[2]);
                } else {
                    append(*out, 0xFF); // QOI_OP_RGBA
                    append(*out, c[0]);
                    append(*out, c[1]);
                    append(*out, c[2]);
                    append(*out, c[3]);
                }
            }
        }

        prev = c;
        px += 1;
    }

    if run > 0 {
        append(*out, cast(u8) (0xC0 | (run - 1)));
    }
    for QOI_END_MARKER append(*out, it);

    return builder_to_string(*out);
}

// Signed channel delta with 8-bit wraparound.
wrap_delta :: (a: u8, b: u8) -> int {
    d := (cast(int) a - cast(int) b) & 0xFF;
    if d > 127 return d - 256;
    return d;
}

in_range :: (v: int, lo: int, hi: int) -> bool {
    return v >= lo && v <= hi;
}

write_be32 :: (buf: *String_Builder, v: int) {
    append(buf, cast(u8) (v >> 24) & 0xFF);
    append(buf, cast(u8) (v >> 16) & 0xFF);
    append(buf, cast(u8) (v >>  8) & 0xFF);
    append(buf, cast(u8)  v        & 0xFF);
}

read_be32 :: (data: string, offset: int) -> int {
    return (cast(int) data[offset    ] << 24)
         | (cast(int) data[offset + 1] << 16)
         | (cast(int) data[offset + 2] <<  8)
         |  cast(int) data[offset + 3];
}

// ---- decode ----

// Decodes QOI bytes into an RGBA8 image (context allocator; caller frees
// image.pixels). Three-channel files are expanded with alpha 255.
qoi_decode :: (data: string) -> (Qoi_Image, bool) {
    fail: Qoi_Image;
    if data.count < QOI_HEADER_SIZE + 8 return fail, false;
    if slice(data, 0, 4) != QOI_MAGIC return fail, false;

    width  := read_be32(data, 4);
    height := read_be32(data, 8);
    channels := data[12];
    if width <= 0 || height <= 0 return fail, false;
    if width * height > QOI_PIXELS_MAX return fail, false;
    if channels != 3 && channels != 4 return fail, false;

    pixel_count := width * height;
    pixels := alloc_bytes(pixel_count * 4);

    index: [64] [4]u8;
    for 0..63 {
        index[it] = .[0, 0, 0, 0];
    }

    c := u8.[0, 0, 0, 255];
    out := 0; // pixels written
    pos := QOI_HEADER_SIZE;

    while out < pixel_count {
        if pos >= data.count - 8 { // only the end marker may remain
            free_bytes(pixels);
            return fail, false;
        }

        b1 := data[pos];
        pos += 1;

        if b1 == 0xFE { // QOI_OP_RGB
            c[0] = data[pos]; c[1] = data[pos + 1]; c[2] = data[pos + 2];
            c[3] = 255;
            pos += 3;
        } else if b1 == 0xFF { // QOI_OP_RGBA
            c[0] = data[pos]; c[1] = data[pos + 1]; c[2] = data[pos + 2]; c[3] = data[pos + 3];
            pos += 4;
        } else if (b1 & 0xC0) == 0x00 { // QOI_OP_INDEX
            c = index[b1 & 0x3F];
        } else if (b1 & 0xC0) == 0x40 { // QOI_OP_DIFF
            c[0] += cast,trunc(u8) (((b1 >> 4) & 0x03) - 2);
            c[1] += cast,trunc(u8) (((b1 >> 2) & 0x03) - 2);
            c[2] += cast,trunc(u8) ( (b1       & 0x03) - 2);
        } else if (b1 & 0xC0) == 0x80 { // QOI_OP_LUMA
            b2 := data[pos];
            pos += 1;
            dg := cast(int) ((b1 & 0x3F)) - 32;
            dr := (((b2 >> 4) & 0x0F) - 8) + dg;
            db := ( (b2       & 0x0F) - 8) + dg;
            c[0] += cast,trunc(u8) dr;
            c[1] += cast,trunc(u8) dg;
            c[2] += cast,trunc(u8) db;
        } else { // QOI_OP_RUN
            run := (b1 & 0x3F) + 1;
            if out + run > pixel_count {
                free_bytes(pixels);
                return fail, false;
            }
            for 0..run-1 {
                pixels[(out + it) * 4 + 0] = c[0];
                pixels[(out + it) * 4 + 1] = c[1];
                pixels[(out + it) * 4 + 2] = c[2];
                pixels[(out + it) * 4 + 3] = c[3];
            }
            out += run;
            continue;
        }

        slot := (cast(int) c[0] * 3 + cast(int) c[1] * 5 + cast(int) c[2] * 7 + cast(int) c[3] * 11) % 64;
        index[slot] = c;

        pixels[out * 4 + 0] = c[0];
        pixels[out * 4 + 1] = c[1];
        pixels[out * 4 + 2] = c[2];
        pixels[out * 4 + 3] = c[3];
        out += 1;
    }

    return .{ width = width, height = height, pixels = pixels }, true;
}

qoi_free :: (image: *Qoi_Image) {
    if image.pixels.count > 0 free_bytes(image.pixels);
    image.pixels = .[];
    image.width = 0;
    image.height = 0;
}
