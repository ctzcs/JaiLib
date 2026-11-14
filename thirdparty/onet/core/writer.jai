#scope_file

#scope_export
// onet core: bit-oriented Writer.
//
// Packs bits directly into bytes (bit order: MSB-first, sequential).
//
// Note: Odin has no implicit method-call syntax; all procedures are called
// explicitly as write_xxx(w, ...).

DEFAULT_ACCURACY :: (cast(float32) (0.001));

// Sentinel written in place of a quantized value to signal that the value's
// raw bits follow. Reserved: quantization never emits it.

RAW_SINGLE_MARKER :: wire_cast(s32, (-2147483647)) - 1;
RAW_DOUBLE_MARKER :: wire_cast(s64, (-9223372036854775807)) - 1;

// Collection count protocol constants:
//   0 = null collection, 1 = invalid count, otherwise count = written - 2.

NULL_COLLECTION_COUNT :: wire_cast(u32, (0));
INVALID_COLLECTION_COUNT :: wire_cast(u32, (1));
COUNT_OFFSET_AFTER_VALIDITY :: 2;

// Largest zigzagged byte delta that still packs into 4 bits.

LARGEST_LOWER_HALF_U8 :: wire_cast(u8, (15));

// Writes data to a packed bit buffer.

Writer :: struct {
    buffer: [..] u8;
    bit_count: int;
    err: Codec_Error;
}

writer_init :: (w: *Writer, byte_capacity: int = 64) {
    w.buffer = new_dynamic(u8, 0, byte_capacity);
    w.bit_count = 0;
    w.err = .None;
}

writer_destroy :: (w: *Writer) {
    release(w.buffer);
    w.* = .{
    };
}

// Resets state while keeping capacity, mirroring Writer.ResetState/OnReturn.

writer_reset :: (w: *Writer) {
    array_reset_keeping_memory(*w.buffer);
    w.bit_count = 0;
    w.err = .None;
}

writer_error :: (w: *Writer) -> Codec_Error {
    return w.err;
}

writer_failed :: (w: *Writer) -> bool {
    return w.err != .None;
}

writer_bits_written :: (w: *Writer) -> int {
    return w.bit_count;
}

writer_bytes_written :: (w: *Writer) -> int {
    return (w.bit_count + 7) / 8;
}

// Packs what has been written into a fresh byte array (partial final byte is
// zero-padded), mirroring Writer.ToArray/ToPackedBytes.

writer_to_array :: (w: *Writer, allocator := context.allocator) -> [] u8 {
    n := writer_bytes_written(w);
    out := new_slice(u8, n, allocator);
    copy_samples(out, view(w.buffer, 0, n));
    return out;
}

fail_writer :: (w: *Writer, err: Codec_Error) {
    if w.err == .None {
        w.err = err;
    }
}

ensure_bit_capacity :: (w: *Writer, bit_index_end: int) {
    bytes_needed := (bit_index_end + 7) / 8;
    while (w.buffer).count < bytes_needed {
        array_add(*w.buffer, 0);
    }
}

// ---------------------------------------------------------------------------
// Primitive bit writes
// ---------------------------------------------------------------------------

write_bit :: (w: *Writer, bit: bool) {
    ensure_bit_capacity(w, w.bit_count + 1);
    if bit {
        w.buffer[w.bit_count / 8] |= wire_cast(u8, (0x80)) >> wire_cast(u8, (w.bit_count % 8));
    }

    w.bit_count += 1;
}

// Writes a value over a number of bits, MSB-first. Fails (and writes nothing)
// when the value needs more bits than requested, mirroring Writer.WriteBits.

write_bits :: (w: *Writer, value: u64, bit_count: u32) {
    if bit_count > 64 {
        fail_writer(w, .Value_Too_Large);
        return;
    }

    if bit_count < 64 && value >= 1 << bit_count {
        fail_writer(w, .Value_Too_Large);
        return;
    }

    write_bits_unsafe(w, value, bit_count);
}

// Writes a value over a number of bits starting at an absolute bit position
// (used to reserve and later rewrite header bits). Advances the write cursor
// only when the write passes the current end.

write_bits_at :: (w: *Writer, value: u64, bit_count: u32, position: int) {
    if bit_count > 64 {
        fail_writer(w, .Value_Too_Large);
        return;
    }

    if bit_count < 64 && value >= 1 << bit_count {
        fail_writer(w, .Value_Too_Large);
        return;
    }

    ensure_bit_capacity(w, position + (cast(int) (bit_count)));
    {
        i := (cast(int) (bit_count)) - 1;
        while i >= 0 {
            defer i -= 1;

            p := position + ((cast(int) (bit_count)) - 1 - i);
            if (value >> wire_cast(u64, (i))) & 1 == 1 {
                w.buffer[p / 8] |= wire_cast(u8, (0x80)) >> wire_cast(u8, (p % 8));
            }
        }
    }

    if position + (cast(int) (bit_count)) > w.bit_count {
        w.bit_count = position + (cast(int) (bit_count));
    }
}

write_bits_unsafe :: (w: *Writer, value: u64, bit_count: u32) {
    ensure_bit_capacity(w, w.bit_count + (cast(int) (bit_count)));
    {
        i := (cast(int) (bit_count)) - 1;
        while i >= 0 {
            defer i -= 1;

            if (value >> wire_cast(u64, (i))) & 1 == 1 {
                w.buffer[w.bit_count / 8] |= wire_cast(u8, (0x80)) >> wire_cast(u8, (w.bit_count % 8));
            }

            w.bit_count += 1;
        }
    }
}

write_boolean :: (w: *Writer, value: bool) {
    write_bit(w, value);
}

write_char :: (w: *Writer, value: s32, level: Compression_Level) {
    write_uint16(w, wire_cast(u16, value), level);
}

// ---------------------------------------------------------------------------
// Numbers — exact-length compressed encoding
// ---------------------------------------------------------------------------

write_unsigned_with_length :: (w: *Writer, t: Numeric_Value_Type, value: u64) {
    bits_needed := bits_needed_for(value);
    write_bits_unsafe(w, wire_cast(u64, (bits_needed - 1)), indicator_bits(t));
    write_bits_unsafe(w, value, bits_needed);
}

write_signed_with_length :: (w: *Writer, t: Numeric_Value_Type, zigzagged: u64) {
    bits_needed := bits_needed_for(zigzagged);
    write_bits_unsafe(w, wire_cast(u64, (bits_needed - 1)), indicator_bits(t));
    write_bits_unsafe(w, zigzagged, bits_needed);
}

write_uint8 :: (w: *Writer, value: u8, level: Compression_Level) {
    if level == .Uncompressed {
        write_bits(w, wire_cast(u64, value), 8);
        return;
    }

    write_unsigned_with_length(w, .UInt8, wire_cast(u64, value));
}

write_uint16 :: (w: *Writer, value: u16, level: Compression_Level) {
    if level == .Uncompressed {
        write_bits(w, wire_cast(u64, value), 16);
        return;
    }

    write_unsigned_with_length(w, .UInt16, wire_cast(u64, value));
}

write_uint32 :: (w: *Writer, value: u32, level: Compression_Level) {
    if level == .Uncompressed {
        write_bits(w, wire_cast(u64, value), 32);
        return;
    }

    write_unsigned_with_length(w, .UInt32, wire_cast(u64, value));
}

write_uint64 :: (w: *Writer, value: u64, level: Compression_Level) {
    if level == .Uncompressed {
        write_bits(w, value, 64);
        return;
    }

    write_unsigned_with_length(w, .UInt64, value);
}

write_int8 :: (w: *Writer, value: s8, level: Compression_Level) {
    if level == .Uncompressed {
        write_bits(w, zigzag_i8(value), 8);
        return;
    }

    write_signed_with_length(w, .Int8, zigzag_i8(value));
}

write_int16 :: (w: *Writer, value: s16, level: Compression_Level) {
    if level == .Uncompressed {
        write_bits(w, zigzag_i16(value), 16);
        return;
    }

    write_signed_with_length(w, .Int16, zigzag_i16(value));
}

write_int32 :: (w: *Writer, value: s32, level: Compression_Level) {
    if level == .Uncompressed {
        write_bits(w, zigzag_i32(value), 32);
        return;
    }

    write_signed_with_length(w, .Int32, zigzag_i32(value));
}

write_int64 :: (w: *Writer, value: s64, level: Compression_Level) {
    if level == .Uncompressed {
        write_bits(w, zigzag_i64(value), 64);
        return;
    }

    write_signed_with_length(w, .Int64, zigzag_i64(value));
}

// ---------------------------------------------------------------------------
// Floating point — quantized, raw-bits fallback
// ---------------------------------------------------------------------------

write_single :: (w: *Writer, value: float32, level: Compression_Level, accuracy: float32) {
    quantized: s32;
    if try_quantize_single(value, accuracy, *quantized) {
        write_int32(w, quantized, level);
        return;
    }

    write_int32(w, RAW_SINGLE_MARKER, level);
    write_raw_single(w, value);
}

write_double :: (w: *Writer, value: float64, level: Compression_Level, accuracy: float32) {
    quantized: s64;
    if try_quantize_double(value, accuracy, *quantized) {
        write_int64(w, quantized, level);
        return;
    }

    write_int64(w, RAW_DOUBLE_MARKER, level);
    write_raw_double(w, value);
}

write_raw_single :: (w: *Writer, value: float32) {
    write_bits(w, wire_cast(u64, bit_cast(u32, value)), 32);
}

write_raw_double :: (w: *Writer, value: float64) {
    write_bits(w, bit_cast(u64, value), 64);
}

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------
// Writes the count header shared by all collections:
// null -> 0, invalid -> 1, otherwise count + 2, as a Tight uint32.

write_collection_count :: (w: *Writer, offset: int, write_count: int, collection_count: int) -> bool {
    if write_count < 0 {
        write_uint32(w, INVALID_COLLECTION_COUNT, .Tight);
        fail_writer(w, .Invalid_Count);
        return false;
    }

    if offset + write_count > collection_count {
        write_uint32(w, INVALID_COLLECTION_COUNT, .Tight);
        fail_writer(w, .Invalid_Count);
        return false;
    }

    write_uint32(w, wire_cast(u32, (write_count + COUNT_OFFSET_AFTER_VALIDITY)), .Tight);
    return true;
}

// Writes a byte array plus its count.
// Aggressive/Tight pack consecutive deltas zigzagged with a 4-or-8 bit
// selector (mirrors WriteUInt8ArrayAsBytesUnsafe); Loose/Uncompressed write
// raw bytes.

write_u8_array_with_count :: (w: *Writer, bytes: [] u8, level: Compression_Level) {
    if !write_collection_count(w, 0, (bytes).count, (bytes).count) {
        return;
    }

    write_u8_array_as_bytes_unsafe(w, bytes, level);
}

write_u8_array_as_bytes_unsafe :: (w: *Writer, bytes: [] u8, level: Compression_Level) {
    if (bytes).count == 0 {
        return;
    }

    if level == .Aggressive || level == .Tight {
        write_bits_unsafe(w, wire_cast(u64, bytes[0]), 8);
        {
            i := 1;
            while i < (bytes).count {
                defer i += 1;

                // Delta is (sbyte)(b[i] - b[i-1]): compute in i16, wrap back into i8.

                delta := wire_cast(s16, wire_cast(s8, bytes[i])) - wire_cast(s16, wire_cast(s8, bytes[i - 1]));
                signed_delta := wire_cast(s8, delta);
                zigzag_delta := wire_cast(u8, ((wire_cast(s16, signed_delta) << 1) ^ wire_cast(s16, (signed_delta >> 7))));
                is_lower_half := zigzag_delta <= LARGEST_LOWER_HALF_U8;
                write_boolean(w, is_lower_half);
                if is_lower_half {
                    write_bits_unsafe(w, wire_cast(u64, zigzag_delta), 4);
                } else {
                    write_bits_unsafe(w, wire_cast(u64, zigzag_delta), 8);
                }
            }
        }

        return;
    }

    for b: bytes {
        write_bits_unsafe(w, wire_cast(u64, b), 8);
    }
}

// Writes a UTF-8 string with its count. Odin strings are already UTF-8 bytes.

write_string :: (w: *Writer, value: string, level: Compression_Level) {
    bytes := bit_cast([] u8, value);
    if !write_collection_count(w, 0, (bytes).count, (bytes).count) {
        return;
    }

    write_u8_array_as_bytes_unsafe(w, bytes, level);
}

// ---------------------------------------------------------------------------
// Guid, quaternion
// ---------------------------------------------------------------------------
// Writes a 128-bit guid as 16 raw bytes, little-endian in the u128.

write_guid :: (w: *Writer, value: u128) {
    for i: 0..7 write_bits_unsafe(w, (value.low >> (i * 8)) & 0xff, 8);
    for i: 0..7 write_bits_unsafe(w, (value.high >> (i * 8)) & 0xff, 8);
}

// Writes a quaternion using smallest-three encoding:
// 2 bits naming the largest axis, 1 bit for its sign, then the three
// remaining components, each quantized against accuracy and written with an
// Int32-width exact-length prefix. Mirrors Writer.WriteQuaternion.

write_quaternion :: (w: *Writer, x, y, z, qw: float32, level: Compression_Level, accuracy: float32) {
    axes := float32.[x, y, z, qw];
    largest_index := 0;
    largest_abs := Math.abs(x);
    if Math.abs(y) > largest_abs {
        largest_abs = Math.abs(y);
        largest_index = 1;
    }

    if Math.abs(z) > largest_abs {
        largest_abs = Math.abs(z);
        largest_index = 2;
    }

    if Math.abs(qw) > largest_abs {
        largest_abs = Math.abs(qw);
        largest_index = 3;
    }

    is_largest_positive := axes[largest_index] >= 0;
    write_bits(w, wire_cast(u64, largest_index), 2);
    write_bit(w, is_largest_positive);

    // Swap trick: the largest is replaced by W, leaving
    // slots 0..2 holding exactly the three smallest values.

    axes[largest_index] = axes[3];
    {
        i := 0;
        while i < 3 {
            defer i += 1;

            write_quaternion_single(w, axes[i], accuracy);
        }
    }
}

write_quaternion_single :: (w: *Writer, value: float32, accuracy: float32) {
    quantized: s32;
    if !try_quantize_single(value, accuracy, *quantized) {
        // Components live in [-1/sqrt(2), 1/sqrt(2)]; unreachable unless the
        // caller passed a degenerate accuracy. Degrade to zero rather than
        // emit the raw marker inside a quaternion.

        fail_writer(w, .Value_Too_Large);
        quantized = 0;
    }

    unsigned := wire_cast(u32, quantized);
    bits_needed := bits_needed_for(wire_cast(u64, unsigned));
    write_bits_unsafe(w, wire_cast(u64, (bits_needed - 1)), indicator_bits(.Int32));
    write_bits_unsafe(w, wire_cast(u64, unsigned), bits_needed);
}

// ---------------------------------------------------------------------------
// Deltas — used by synchronized members for change compression
// ---------------------------------------------------------------------------
// Writes the difference between two floats, quantized. Returns whether a
// value was written; callers write their own "changed" bit. Non-finite next
// values are refused (caller keeps the previous value).

write_delta_single :: (w: *Writer, previous, next: float32, accuracy: float32) -> bool {
    if !is_finite_single(next) {
        return false;
    }

    if Math.abs(next - previous) <= accuracy {
        return false;
    }

    quantized: s32;
    if try_quantize_single(next - previous, accuracy, *quantized) {
        write_int32(w, quantized, .Tight);
        return true;
    }

    write_int32(w, RAW_SINGLE_MARKER, .Tight);
    write_raw_single(w, next);
    return true;
}

write_delta_double :: (w: *Writer, previous, next: float64, accuracy: float32) -> bool {
    if !is_finite_double(next) {
        return false;
    }

    if Math.abs(next - previous) <= (cast(float64) accuracy) {
        return false;
    }

    quantized: s64;
    if try_quantize_double(next - previous, accuracy, *quantized) {
        write_int64(w, quantized, .Tight);
        return true;
    }

    write_int64(w, RAW_DOUBLE_MARKER, .Tight);
    write_raw_double(w, next);
    return true;
}

// Generic integer delta: one procedure covers every integer width.

write_delta_int :: (w: *Writer, previous, next: $T, level: Compression_Level) -> bool {
    if previous == next {
        return false;
    }

    diff := wire_cast(s64, next) - wire_cast(s64, previous);
    write_int_for_type(w, wire_cast(T, diff), level);
    return true;
}

write_int_for_type :: (w: *Writer, value: $T, level: Compression_Level) {
    #if T == s8 {
        write_int8(w, value, level);
    } else #if T == s16 {
        write_int16(w, value, level);
    } else #if T == s32 {
        write_int32(w, value, level);
    } else #if T == s64 {
        write_int64(w, value, level);
    } else {
        #assert (false, "write_int_for_type expects a signed integer type");
    }
}

// Cast semantics adapted.
// Loop scopes adapted.
