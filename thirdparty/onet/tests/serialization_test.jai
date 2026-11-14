#scope_file
core :: #import "thirdparty/onet/core";
#scope_export
// Round-trip tests for the serialization core.
//
// Run from onet/:
//   odin test thirdparty/onet/tests -collection:olib=. -vet

ACC :: (cast(float32) (0.001));

expect_f32_near :: (t: *Test, got, want, epsilon: float32, label: string) {
    expect(t, Math.abs(got - want) <= epsilon, label);
}

expect_ok :: (t: *Test, r: *core.Reader, label: string) {
    expect(t, r.err == .None, label);
}

bool_roundtrip :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    core.write_boolean(*w, true);
    core.write_boolean(*w, false);

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect_value(t, core.read_boolean(*r), true);
    expect_value(t, core.read_boolean(*r), false);
    expect_ok(t, *r, "bool stream");
}

unsigned_roundtrip_all_levels :: (t: *Test) {
    levels: [] core.Compression_Level = core.Compression_Level.[.Aggressive, .Tight, .Loose, .Uncompressed];
    for level: levels {
        w: core.Writer;
        core.writer_init(*w);
        core.write_uint8(*w, 0, level);
        core.write_uint8(*w, 255, level);
        core.write_uint16(*w, 0xA5A5, level);
        core.write_uint32(*w, 0xDEADBEEF, level);
        core.write_uint64(*w, 0xFFFFFFFFFFFFFFFF, level);

        r: core.Reader;
        core.reader_from_writer(*r, *w);
        expect_value(t, core.read_uint8(*r, level), (cast, trunc(u8)(0)));
        expect_value(t, core.read_uint8(*r, level), (cast, trunc(u8)(255)));
        expect_value(t, core.read_uint16(*r, level), (cast, trunc(u16)(0xA5A5)));
        expect_value(t, core.read_uint32(*r, level), (cast, trunc(u32)(0xDEADBEEF)));
        expect_value(t, core.read_uint64(*r, level), (cast, trunc(u64)(0xFFFFFFFFFFFFFFFF)));
        expect_ok(t, *r, "unsigned roundtrip");
        core.writer_destroy(*w);
    }
}

signed_roundtrip_all_levels :: (t: *Test) {
    levels: [] core.Compression_Level = core.Compression_Level.[.Aggressive, .Tight, .Loose, .Uncompressed];
    for level: levels {
        w: core.Writer;
        core.writer_init(*w);
        core.write_int8(*w, -1, level);
        core.write_int8(*w, -128, level);
        core.write_int8(*w, 127, level);
        core.write_int16(*w, -30000, level);
        core.write_int32(*w, -2147483647, level);
        core.write_int64(*w, -9223372036854775807, level);

        r: core.Reader;
        core.reader_from_writer(*r, *w);
        expect_value(t, core.read_int8(*r, level), (cast, trunc(s8)(-1)));
        expect_value(t, core.read_int8(*r, level), (cast, trunc(s8)(-128)));
        expect_value(t, core.read_int8(*r, level), (cast, trunc(s8)(127)));
        expect_value(t, core.read_int16(*r, level), (cast, trunc(s16)(-30000)));
        expect_value(t, core.read_int32(*r, level), (cast, trunc(s32)(-2147483647)));
        expect_value(t, core.read_int64(*r, level), (cast, trunc(s64)(-9223372036854775807)));
        expect_ok(t, *r, "signed roundtrip");
        core.writer_destroy(*w);
    }
}

compressed_length_is_small_for_small_values :: (t: *Test) {
    // A small uint32 at Tight costs the 5-bit indicator + a few value bits.

    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);
    core.write_uint32(*w, 3, .Tight); // 3 needs 2 bits

    expect(t, w.err == .None, "no error");
    expect_value(t, core.writer_bits_written(*w), 5 + 2);
}

single_roundtrip :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    core.write_single(*w, 0.5, .Loose, ACC);
    core.write_single(*w, -1234.567, .Loose, ACC);
    core.write_single(*w, 0.0, .Loose, ACC);

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect_f32_near(t, core.read_single(*r, .Loose, ACC), 0.5, 2 * ACC, "0.5");
    expect_f32_near(t, core.read_single(*r, .Loose, ACC), -1234.567, 2 * ACC, "-1234.567");
    expect_f32_near(t, core.read_single(*r, .Loose, ACC), 0.0, ACC, "0.0");
    expect_ok(t, *r, "single roundtrip");
}

single_raw_fallback :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    // 1.0e30 at 0.001 accuracy overflows the i32 carrier: raw fallback.

    core.write_single(*w, 1.0e30, .Loose, ACC);
    // NaN is refused by the reader, which returns the fallback (0 for absolute).

    core.write_single(*w, nan32(), .Loose, ACC);

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect_f32_near(t, core.read_single(*r, .Loose, ACC), 1.0e30, 1.0e22, "1e30 raw fallback");
    expect_f32_near(t, core.read_single(*r, .Loose, ACC), 0.0, ACC, "NaN refused");
    expect_ok(t, *r, "single fallback");
}

double_roundtrip_and_fallback :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    core.write_double(*w, 123.456, .Loose, ACC);
    core.write_double(*w, 1.0e300, .Loose, ACC);

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect(t, Math.abs(core.read_double(*r, .Loose, ACC) - 123.456) <= 0.001, "double roundtrip");
    expect(t, core.read_double(*r, .Loose, ACC) == 1.0e300, "double raw fallback");
    expect_ok(t, *r, "double fallback");
}

string_roundtrip :: (t: *Test) {
    levels: [] core.Compression_Level = core.Compression_Level.[core.Compression_Level.Tight, core.Compression_Level.Loose];
    for level: levels {
        w: core.Writer;
        core.writer_init(*w);
        core.write_string(*w, "hello", level);
        core.write_string(*w, "你好世界", level);
        core.write_string(*w, "", level);

        r: core.Reader;
        core.reader_from_writer(*r, *w);
        s1 := core.read_string(*r, level);
        s2 := core.read_string(*r, level);
        s3 := core.read_string(*r, level);
        expect_value(t, s1, "hello");
        expect_value(t, s2, "你好世界");
        expect_value(t, s3, "");
        expect_ok(t, *r, "string roundtrip");
        release(s1);
        release(s2);
        core.writer_destroy(*w);
    }
}

byte_array_roundtrip :: (t: *Test) {
    bytes: [] u8 = u8.[0, 1, 2, 250, 251, 0, 128, 127];
    levels: [] core.Compression_Level = core.Compression_Level.[core.Compression_Level.Aggressive, core.Compression_Level.Loose];
    for level: levels {
        w: core.Writer;
        core.writer_init(*w);
        core.write_u8_array_with_count(*w, bytes, level);

        r: core.Reader;
        core.reader_from_writer(*r, *w);
        got := core.read_u8_array_with_count(*r, level);
        expect(t, equal_slices(got, bytes), "byte array roundtrip");
        expect_ok(t, *r, "byte array roundtrip");
        release(got);
        core.writer_destroy(*w);
    }
}

equal_slices :: (a, b: [] u8) -> bool {
    if (a).count != (b).count {
        return false;
    }

    {
        i := 0;
        while i < (a).count {
            defer i += 1;

            if a[i] != b[i] {
                return false;
            }
        }
    }

    return true;
}

guid_roundtrip :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    value := U128.{ 0xfedcba9876543210, 0x0123456789abcdef };
    core.write_guid(*w, value);

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect(t, core.read_guid(*r) == value, "guid roundtrip");
    expect_ok(t, *r, "guid roundtrip");
}

quaternion_roundtrip :: (t: *Test) {
    s := (cast(float32) (Math.sqrt(cast(float64) 0.5)));
    cases := ([4] float32).[.[0, 0, 0, 1], .[0, s, 0, s], .[s, 0, 0, -s], .[0.3, 0.4, -0.5, s]];
    for c: cases {
        w: core.Writer;
        core.writer_init(*w);
        core.write_quaternion(*w, c[0], c[1], c[2], c[3], .Loose, ACC);

        r: core.Reader;
        core.reader_from_writer(*r, *w);
        x, y, z, qw := core.read_quaternion(*r, .Loose, ACC);
        expect_f32_near(t, x, c[0], 0.01, "quat x");
        expect_f32_near(t, y, c[1], 0.01, "quat y");
        expect_f32_near(t, z, c[2], 0.01, "quat z");
        expect_f32_near(t, qw, c[3], 0.01, "quat w");
        expect_ok(t, *r, "quat roundtrip");
        core.writer_destroy(*w);
    }
}

reserved_bits_rewrite :: (t: *Test) {
    // Reserve 8 header bits, append a payload, then rewrite the header —
    // the pattern PacketSegmentWriter uses.

    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    core.write_bits(*w, 0, 8); // reserved

    core.write_uint32(*w, 0xBEEF, .Loose);
    core.write_bits_at(*w, 7, 8, 0); // rewrite header in place

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect_value(t, core.read_bits(*r, 8), (cast, trunc(u64)(7)));
    expect_value(t, core.read_uint32(*r, .Loose), (cast, trunc(u32)(0xBEEF)));
    expect_ok(t, *r, "reserved bits");
}

write_bits_rejects_oversized_value :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    core.write_bits(*w, 3, 1); // 3 does not fit in 1 bit

    expect(t, w.err == .Value_Too_Large, "oversized value flagged");
    expect_value(t, core.writer_bits_written(*w), 0);
}

reader_truncation_is_sticky :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    core.write_uint32(*w, 0xDEADBEEF, .Loose);
    data := core.writer_to_array(*w);
    core.writer_destroy(*w);
    defer release(data);

    r: core.Reader;
    core.reader_init(*r, view(data, 0, 1)); // truncated

    expect_value(t, core.read_uint32(*r, .Loose), (cast, trunc(u32)(0)));
    expect(t, r.err == .Out_Of_Bounds, "truncation detected");
    // Sticky: further reads also fail with zero values.

    expect_value(t, core.read_uint32(*r, .Loose), (cast, trunc(u32)(0)));
    expect(t, core.reader_failed(*r), "failure is sticky");
}

writer_reset_reuses_capacity :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    core.write_uint32(*w, 123, .Loose);
    cap_before := w.buffer.allocated;
    core.writer_reset(*w);
    expect_value(t, core.writer_bits_written(*w), 0);
    expect(t, w.err == .None, "reset clears error");
    expect_value(t, w.buffer.allocated, cap_before);

    core.write_uint32(*w, 456, .Loose);
    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect_value(t, core.read_uint32(*r, .Loose), (cast, trunc(u32)(456)));
}

buffer_growth :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w, 1); // tiny capacity on purpose

    defer core.writer_destroy(*w);

    // Fixed-width writes (Uncompressed) so the byte count is exact; Loose
    // would use variable-length coding per value.

    {
        i := 0;
        while i < 10_000 {
            defer i += 1;

            core.write_uint8(*w, (cast, trunc(u8) i), .Uncompressed);
        }
    }

    expect(t, w.err == .None, "no growth errors");
    expect_value(t, core.writer_bytes_written(*w), 10_000);

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    {
        i := 0;
        while i < 10_000 {
            defer i += 1;

            got := core.read_uint8(*r, .Uncompressed);
            if got != (cast, trunc(u8) i) {
                expect(t, false, "mismatch during growth test");
                return;
            }
        }
    }

    expect_ok(t, *r, "growth roundtrip");
}

delta_single :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    // Small change: quantized delta is written.

    changed := core.write_delta_single(*w, 10.0, 10.5, ACC);
    expect(t, changed, "changed value should be written");
    // Below accuracy: nothing written.

    unchanged := core.write_delta_single(*w, 10.5, 10.5005, ACC);
    expect(t, !unchanged, "sub-accuracy change should be skipped");
    // Huge change: raw fallback inside the delta.

    changed_far := core.write_delta_single(*w, 10.5, 1.0e30, ACC);
    expect(t, changed_far, "large delta should be written");

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect_f32_near(t, core.read_delta_single(*r, 10.0, ACC), 10.5, 2 * ACC, "delta roundtrip");
    expect_f32_near(t, core.read_delta_single(*r, 1.0e30, ACC), 1.0e30, 1.0e22, "raw delta fallback");
    expect_ok(t, *r, "delta single");
}

delta_int_generic :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    defer core.writer_destroy(*w);

    changed32 := core.write_delta_int(*w, (cast, trunc(s32)(100)), (cast, trunc(s32)(90)), .Tight);
    changed16 := core.write_delta_int(*w, (cast, trunc(s16)(-5)), (cast, trunc(s16)(300)), .Loose);
    unchanged := core.write_delta_int(*w, (cast, trunc(s64)(7)), (cast, trunc(s64)(7)), .Tight);
    expect(t, changed32 && changed16 && !unchanged, "delta int changed flags");

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect_value(t, core.read_delta_int(*r, (cast, trunc(s32)(100)), .Tight), (cast, trunc(s32)(90)));
    expect_value(t, core.read_delta_int(*r, (cast, trunc(s16)(-5)), .Loose), (cast, trunc(s16)(300)));
    expect_ok(t, *r, "delta int");
}

mixed_packet_roundtrip :: (t: *Test) {
    w: core.Writer;
    core.writer_init(*w);
    core.write_boolean(*w, true);
    core.write_uint32(*w, 1337, .Loose);
    core.write_int32(*w, -4200, .Tight);
    core.write_single(*w, 3.14159, .Loose, ACC);
    core.write_string(*w, "onet->odin", .Loose);
    core.write_quaternion(*w, 0, s_half(), 0, s_half(), .Loose, ACC);
    core.write_guid(*w, U128.{ 42, 0 });
    expect(t, w.err == .None, "write clean");

    r: core.Reader;
    core.reader_from_writer(*r, *w);
    expect_value(t, core.read_boolean(*r), true);
    expect_value(t, core.read_uint32(*r, .Loose), (cast, trunc(u32)(1337)));
    expect_value(t, core.read_int32(*r, .Tight), (cast, trunc(s32)(-4200)));
    expect_f32_near(t, core.read_single(*r, .Loose, ACC), 3.14159, 2 * ACC, "pi");
    s := core.read_string(*r, .Loose);
    expect_value(t, s, "onet->odin");
    release(s);
    x, y, z, qw := core.read_quaternion(*r, .Loose, ACC);
    expect_f32_near(t, x, 0.0, 0.01, "packet quat x");
    expect_f32_near(t, y, s_half(), 0.01, "packet quat y");
    expect_f32_near(t, z, 0.0, 0.01, "packet quat z");
    expect_f32_near(t, qw, s_half(), 0.01, "packet quat w");
    expect(t, core.read_guid(*r) == U128.{ 42, 0 }, "packet guid");
    expect_ok(t, *r, "mixed packet");
    core.writer_destroy(*w);
}

s_half :: () -> float32 {
    return (cast(float32) (Math.sqrt(cast(float64) 0.5)));
}

pool_reuse :: (t: *Test) {
    pool: core.Writer_Pool;
    core.writer_pool_init(*pool);
    defer core.writer_pool_destroy(*pool);

    w := core.writer_pool_get(*pool);
    core.write_uint32(w, 12345, .Loose);
    core.writer_pool_put(*pool, w);

    w2 := core.writer_pool_get(*pool);
    expect(t, w2 == w, "pool should hand back the same writer");
    expect_value(t, core.writer_bits_written(w2), 0);
    core.write_uint32(w2, 999, .Loose);
    core.writer_pool_put(*pool, w2);
    expect_value(t, (pool.items).count, 1);
}

// Cast semantics adapted.
// Loop scopes adapted.
// Iterator semantics adapted.
