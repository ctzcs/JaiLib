#import "Basic";
F :: #import "foster";

main :: () {
    assert(F.color_premultiply(.{ 100, 200, 50, 128 }) == F.Color.{ 50, 100, 25, 128 });
    assert(F.color_lerp(F.Color_White, F.Color_Black, 0.5) == F.Color.{ 127, 127, 127, 255 });
    assert(F.color_from_hex(0x123456) == F.Color.{ 18, 52, 86, 255 });
    assert(F.color_rgba(.{ 0x12, 0x34, 0x56, 0x78 }) == 0x12345678);
    assert(F.color_abgr(.{ 0x12, 0x34, 0x56, 0x78 }) == 0x78563412);
    assert(F.color_from_rgba(0x12345678) == F.Color.{ 0x12, 0x34, 0x56, 0x78 });
    // Full channels, changing alpha, INDEX, DIFF, LUMA, RGB, RGBA and RUN.
    colors := F.Color.[.{ 0, 0, 0, 255 }, .{ 1, 1, 1, 255 }, .{ 0, 0, 0, 255 }, .{ 20, 24, 26, 255 },
        .{ 10, 14, 16, 255 }, .{ 255, 0, 200, 255 }, .{ 255, 0, 200, 0 }, .{ 255, 0, 200, 128 },
        .{ 255, 0, 200, 128 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 255 }, .{ 255, 255, 255, 255 }];
    image := F.image_create(513, 257);
    defer F.image_destroy(*image);
    for *pixel, i: image.Data pixel.* = colors[(i / 3) % colors.count];
    encoded := F.image_encode_qoi(image);
    defer free(encoded.data);
    decoded := F.qoi_decode(encoded);
    defer F.image_destroy(*decoded);
    assert(decoded.Width == image.Width && decoded.Height == image.Height);
    for pixel, i: image.Data assert(pixel == decoded.Data[i], "QOI pixel mismatch at %", i);
    // Decoder conformance vector with wrapped DIFF (-2) and LUMA (-32).
    vector := u8.[113, 111, 105, 102, 0, 0, 0, 2, 0, 0, 0, 1, 4, 0, 64, 128, 136, 0, 0, 0, 0, 0, 0, 0, 1];
    reference := F.qoi_decode(vector);
    defer F.image_destroy(*reference);
    assert(reference.Width == 2 && reference.Height == 1);
    assert(reference.Data[0] == F.Color.{ 254, 254, 254, 255 });
    assert(reference.Data[1] == F.Color.{ 222, 222, 222, 255 });
    print("image_bytes: PASS (RGBA/ABGR, QOI opcodes, alpha and multi-byte dimensions)\n");
}
