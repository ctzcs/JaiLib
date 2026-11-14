#scope_file
core :: #import "thirdparty/onet/core";
#scope_export

//@region Portable base-ten Decimal (no third-party memory layout)
// Decimal supports a 96-bit coefficient and scale 0..28. Signed
// zero/trailing scale compare numerically. Compressed precision uses decimal
// places (0..28), equivalent to accuracy 10^-places, without a binary-float cast.

Decimal :: struct {
    coefficient: u128;
    scale: u8;
    negative: bool;
}

DECIMAL_MAX :: u128.{ 0xffffffffffffffff, 0xffffffff };

decimal_valid :: (x: Decimal) -> bool {
    return x.coefficient <= DECIMAL_MAX && x.scale <= 28;
}

decimal_pow10 :: (n: int) -> u128 {
    out := wire_cast(u128, (1));
    loop_index := 0;
    while loop_index < n {
        defer loop_index += 1;
        out *= 10;
    };
    return out;
}

decimal_normalize :: (x: Decimal) -> Decimal {
    out := x;
    while out.scale > 0 && out.coefficient % 10 == 0 {
        out.coefficient /= 10;
        out.scale -= 1;
    }

    if out.coefficient == 0 {
        out.negative = false;
    }

    return out;
}

decimal_quantize :: (x: Decimal, places: u8) -> (Decimal, bool) {
    if !decimal_valid(x) || places > 28 {
        return .{
        }, false;
    };

    out := x;
    if out.scale > places {
        out.coefficient /= decimal_pow10((cast(int) (out.scale - places)));
        out.scale = places;
    }

    return decimal_normalize(out), true;
}

// 192-bit temporary arithmetic covers a 96-bit coefficient * 10^28 exactly.

Decimal_Wide :: [3] u64;

decimal_wide :: (x: Decimal, scale: u8) -> Decimal_Wide {
    a := u64.[
   wire_cast(u64, (x.coefficient)), wire_cast(u64, (x.coefficient >> 64)), 0,
   ];

    loop_index := (cast(int) (x.scale));
    while loop_index < (cast(int) (scale)) {
        defer loop_index += 1;

        carry: u128;
        for *limb: a {
            product := wire_cast(u128, (limb.*)) * 10 + carry;
            limb.* = wire_cast(u64, (product));
            carry = product >> 64;
        }
    }

    return a;
}

decimal_wide_compare :: (a, b: Decimal_Wide) -> int {
    i := 2;
    while i >= 0 {
        defer i -= 1;
        if a[i] > b[i] {
            return 1;
        };
        if a[i] < b[i] {
            return -1;
        }
    };
    return 0;
}

decimal_wide_div10 :: (a: *Decimal_Wide) -> u64 {
    remainder: u128;
    i := 2;
    while i >= 0 {
        defer i -= 1;
        value := (remainder << 64) | wire_cast(u128, (a.*[i]));
        a.*[i] = wire_cast(u64, (value / 10));
        remainder = value % 10;
    }

    return wire_cast(u64, (remainder));
}

// Add/subtract with nearest-even scale reduction when the exact
// coefficient exceeds 96 bits. An integral overflow fails; inputs are borrowed.

decimal_add :: (a, b: Decimal, subtract := false) -> (Decimal, bool) {
    if !decimal_valid(a) || !decimal_valid(b) {
        return .{
        }, false;
    };

    scale := max(a.scale, b.scale);
    av, bv := decimal_wide(a, scale), decimal_wide(b, scale);
    negative_b := b.negative != subtract;
    sign := a.negative;
    result: Decimal_Wide;
    if a.negative == negative_b {
        carry: u128;
        for x, i: av {
            total := wire_cast(u128, (x)) + wire_cast(u128, (bv[i])) + carry;
            result[i] = wire_cast(u64, (total));
            carry = total >> 64;
        }

        if carry != 0 {
            return .{
            }, false;
        };
    } else {
        if decimal_wide_compare(av, bv) < 0 {
            av, bv = bv, av;
            sign = negative_b;
        }

        borrow: u128;
        for x, i: av {
            right := wire_cast(u128, (bv[i])) + borrow;
            result[i] = wire_cast(u64, ((wire_cast(u128, (1)) << 64) + wire_cast(u128, (x)) - right));
            borrow = wide((cast, trunc(u64)(ifx wire_cast(u128, x) < right then 1 else 0)));
        }
    }

    digit: u64;
    sticky := false;
    while true {
        fits := result[2] == 0 && result[1] <= wire_cast(u64, (0xffffffff));
        coefficient := wire_cast(u128, (result[0])) | (wire_cast(u128, (result[1])) << 64);
        round_up := digit > 5 || (digit == 5 && (sticky || result[0] & 1 != 0));
        if fits && (!round_up || coefficient < DECIMAL_MAX) {
            if round_up {
                coefficient += 1;
            }

            return decimal_normalize(.{
                coefficient, scale, sign
            }), true;
        };

        if scale == 0 {
            return .{
            }, false;
        };

        sticky = sticky || digit != 0;
        digit = decimal_wide_div10(*result);
        scale -= 1;
    }

    assert(false, "unreachable decimal reduction");
    return .{}, false;
}

decimal_equal :: (a, b: Decimal) -> bool {
    if !decimal_valid(a) || !decimal_valid(b) {
        return false;
    }

    av, bv := decimal_normalize(a), decimal_normalize(b);
    return av.coefficient == bv.coefficient && av.scale == bv.scale && av.negative == bv.negative;
}

decimal_tolerance :: (a, b: Decimal, places: u8) -> bool {
    difference, ok := decimal_add(a, b, true);
    if !ok || places > 28 {
        return false;
    }

    scale := max(difference.scale, places);
    magnitude := decimal_wide(difference, scale);
    step := decimal_wide(Decimal.{
        coefficient = wide(1), scale = places
    }, scale);
    return decimal_wide_compare(magnitude, step) <= 0;
};

decimal_write :: (w: *core.Writer, x: Decimal, places: u8 = 3, level: core.Compression_Level = .Loose) -> bool {
    q, ok := decimal_quantize(x, places);
    if !ok {
        return reject_write(w);
    }

    // Semantic equivalent of DecimalPacked: sign, whole chunks and a scaled
    // fractional integer, field by field. No overlay on the host decimal type.

    divisor := decimal_pow10((cast(int) (q.scale)));
    whole, fraction := q.coefficient / divisor, q.coefficient % divisor;
    fraction *= decimal_pow10((cast(int) (places - q.scale)));
    core.write_boolean(w, q.negative);
    core.write_uint64(w, wire_cast(u64, (whole)), level);
    core.write_uint32(w, wire_cast(u32, (whole >> 64)), level);
    core.write_uint64(w, wire_cast(u64, (fraction)), level);
    core.write_uint32(w, wire_cast(u32, (fraction >> 64)), level);
    return w.err == .None;
}

decimal_read :: (r: *core.Reader, places: u8 = 3, level: core.Compression_Level = .Loose) -> (Decimal, bool) {
    if places > 28 {
        return .{
        }, reject_read(r);
    };

    negative := core.read_boolean(r);
    lo := core.read_uint64(r, level);
    hi := core.read_uint32(r, level);
    fraction_lo := core.read_uint64(r, level);
    fraction_hi := core.read_uint32(r, level);
    fraction := wire_cast(u128, (fraction_lo)) | (wire_cast(u128, (fraction_hi)) << 64);
    if r.err != .None || fraction >= decimal_pow10((cast(int) (places))) {
        return .{
        }, reject_read(r);
    };

    // Avoid overflowing a large integral coefficient with artificial zero scale.

    scale := places;
    remainder := wire_cast(u128, (fraction));
    while scale > 0 && remainder % 10 == 0 {
        remainder /= 10;
        scale -= 1;
    }

    whole := wire_cast(u128, (lo)) | (wire_cast(u128, (hi)) << 64);
    power := decimal_pow10((cast(int) (scale)));
    if whole > (DECIMAL_MAX - remainder) / power {
        return .{
        }, reject_read(r);
    };

    return decimal_normalize(.{
        whole * power + remainder, scale, negative
    }), true;
};

decimal_codec :: (schema: u32, $places: u8, $level: core.Compression_Level) -> Codec(Decimal) {
    if schema < CUSTOM_SCHEMA_MIN || places > 28 {
        return .{
        };
    }

    return .{
        schema = schema,
        write = (w: *core.Writer, x: *Decimal) -> bool {
            return decimal_write(w, x.*, places, level);
        },
        read = (r: *core.Reader, x: *Decimal) -> bool {
            value, ok := decimal_read(r, places, level);
            x.* = value;
            return ok;
        },
        equal = (a, b: *Decimal) -> bool {
            return decimal_tolerance(a.*, b.*, places);
        },
        clone = (x: *Decimal) -> Decimal {
            return x.*;
        },
        destroy = (x: *Decimal) {
            x.* = .{
            };
        },
    }
}

decimal_delta_codec :: (schema: u32, $places: u8) -> Delta_Codec(Decimal) {
    return .{
        full = decimal_codec(schema, places, .Loose),
        write = (w: *core.Writer, a, b: *Decimal, mode: core.Delta_Check_Mode) -> (bool, bool) {
            if mode == .Checked && decimal_tolerance(a.*, b.*, places) {
                return false, true;
            }

            difference, ok := decimal_add(b.*, a.*, true);
            if !ok {
                return false, reject_write(w);
            }

            return true, decimal_write(w, difference, places, .Tight);
        },
        read = (r: *core.Reader, a, out: *Decimal) -> bool {
            difference, ok := decimal_read(r, places, .Tight);
            if !ok {
                return false;
            }

            result, good := decimal_add(a.*, difference);
            if !good {
                return reject_read(r);
            }

            out.* = result;
            return true;
        },
    }
}

//@endregion
//@region Exact decimal opt-in (lossless extension, not the default packing)

decimal_exact_codec :: (schema: u32) -> Codec(Decimal) {
    if schema < CUSTOM_SCHEMA_MIN {
        return .{
        };
    }

    return .{
        schema = schema,
        write = (w: *core.Writer, x: *Decimal) -> bool {
            if !decimal_valid(x.*) {
                return reject_write(w);
            }

            core.write_bits(w, wire_cast(u64, (x.coefficient)), 64);
            core.write_bits(w, wire_cast(u64, (x.coefficient >> 64)), 32);
            core.write_bits(w, wire_cast(u64, (x.scale)), 5);
            core.write_boolean(w, x.negative);
            return w.err == .None;
        },
        read = (r: *core.Reader, x: *Decimal) -> bool {
            lo := core.read_bits(r, 64);
            hi := core.read_bits(r, 32);
            x.coefficient = wire_cast(u128, (lo)) | (wire_cast(u128, (hi)) << 64);
            x.scale = wire_cast(u8, (core.read_bits(r, 5)));
            x.negative = core.read_boolean(r);
            return (ifx decimal_valid(x.*) then r.err == .None else reject_read(r));
        },
        equal = (a, b: *Decimal) -> bool {
            return decimal_equal(a.*, b.*);
        },
        clone = (x: *Decimal) -> Decimal {
            return x.*;
        },
        destroy = (x: *Decimal) {
            x.* = .{
            };
        },
    }
}

//@endregion
//@region Arbitrary decimal accuracy steps (not restricted to powers of ten)

decimal_step_valid :: (step: Decimal) -> bool {
    return decimal_valid(step) && !step.negative && step.coefficient != 0;
}

decimal_step_tolerance :: (a, b, step: Decimal) -> bool {
    if !decimal_step_valid(step) {
        return false;
    }

    difference, ok := decimal_add(a, b, true);
    if !ok {
        return false;
    }

    scale := max(step.scale, difference.scale);
    return decimal_wide_compare(decimal_wide(difference, scale), decimal_wide(step, scale)) <= 0;
}

decimal_step_write :: (w: *core.Writer, x, step: Decimal, level: core.Compression_Level = .Loose) -> bool {
    if !decimal_valid(x) || !decimal_step_valid(step) {
        return reject_write(w);
    }

    divisor := decimal_pow10((cast(int) (x.scale)));
    whole, fraction := x.coefficient / divisor, x.coefficient % divisor;
    count: u128;
    if step.coefficient < decimal_pow10((cast(int) (step.scale))) {
        scale := max(step.scale, x.scale);
        // Each aligned fraction is <10^scale (scale<=28), so these products
        // fit u128 even though multiplying the two original denominators would
        // not. No binary floating-point conversion or precision loss occurs.

        numerator := fraction * decimal_pow10((cast(int) (scale - x.scale)));
        denominator := step.coefficient * decimal_pow10((cast(int) (scale - step.scale)));
        count = numerator / denominator;
    }

    core.write_boolean(w, x.negative && x.coefficient != 0);
    core.write_uint64(w, wire_cast(u64, (whole)), level);
    core.write_uint32(w, wire_cast(u32, (whole >> 64)), level);
    core.write_uint64(w, wire_cast(u64, (count)), level);
    core.write_uint32(w, wire_cast(u32, (count >> 64)), level);
    return w.err == .None;
}

decimal_step_read :: (r: *core.Reader, step: Decimal, level: core.Compression_Level = .Loose) -> (Decimal, bool) {
    if !decimal_step_valid(step) {
        return .{
        }, reject_read(r);
    };

    negative := core.read_boolean(r);
    lo := core.read_uint64(r, level);
    hi := core.read_uint32(r, level);
    count_lo := core.read_uint64(r, level);
    count_hi := core.read_uint32(r, level);
    count := wire_cast(u128, (count_lo)) | (wire_cast(u128, (count_hi)) << 64);
    power := decimal_pow10((cast(int) (step.scale)));
    if r.err != .None || count > (power - 1) / step.coefficient {
        return .{
        }, reject_read(r);
    };

    whole := Decimal.{
        wire_cast(u128, (lo)) | (wire_cast(u128, (hi)) << 64), 0, negative,
    };

    fraction := Decimal.{
        count * step.coefficient, step.scale, negative,
    };

    result, ok := decimal_add(whole, fraction);
    if !ok {
        return .{
        }, reject_read(r);
    };

    return result, true;
}

decimal_step_codec :: (schema: u32, $step_coefficient: u128, $step_scale: u8, $level: core.Compression_Level) -> Codec(Decimal) {
    if schema < CUSTOM_SCHEMA_MIN || !decimal_step_valid(.{
        step_coefficient, step_scale, false
    }) {
        return .{
        };
    }

    return .{
        schema = schema,
        write = (w: *core.Writer, x: *Decimal) -> bool {
            return decimal_step_write(w, x.*, .{
                step_coefficient, step_scale, false
            }, level);
        },
        read = (r: *core.Reader, x: *Decimal) -> bool {
            result, ok := decimal_step_read(r, .{
                step_coefficient, step_scale, false
            }, level);
            x.* = result;
            return ok;
        },
        equal = (a, b: *Decimal) -> bool {
            return decimal_step_tolerance(a.*, b.*, .{
                step_coefficient, step_scale, false
            });
        },
        clone = (x: *Decimal) -> Decimal {
            return x.*;
        },
        destroy = (x: *Decimal) {
            x.* = .{
            };
        },
    }
}

decimal_step_delta_codec :: (schema: u32, $step_coefficient: u128, $step_scale: u8) -> Delta_Codec(Decimal) {
    return .{
        full = decimal_step_codec(schema, step_coefficient, step_scale, .Loose),
        write = (w: *core.Writer, a, b: *Decimal, mode: core.Delta_Check_Mode) -> (bool, bool) {
            step := Decimal.{
                step_coefficient, step_scale, false,
            };

            if mode == .Checked && decimal_step_tolerance(a.*, b.*, step) {
                return false, true;
            }

            difference, ok := decimal_add(b.*, a.*, true);
            if !ok {
                return false, reject_write(w);
            }

            return true, decimal_step_write(w, difference, step, .Tight);
        },
        read = (r: *core.Reader, a, out: *Decimal) -> bool {
            difference, ok := decimal_step_read(r, .{
                step_coefficient, step_scale, false
            }, .Tight);
            if !ok {
                return false;
            }

            result, good := decimal_add(a.*, difference);
            if !good {
                return reject_read(r);
            }

            out.* = result;
            return true;
        },
    };
}

//@endregion
// Cast semantics adapted.
