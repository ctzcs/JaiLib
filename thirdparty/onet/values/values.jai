#scope_file
core :: #import "thirdparty/onet/core";
wire :: #import "thirdparty/onet/wire";

#scope_export
operator == :: (a: Reference, b: Reference) -> bool {
    return a.id == b.id && a.generation == b.generation;
}

value_member_finished :: (r: *core.Reader) -> bool {
    return wire.finished(r);
}

//@region Explicit codecs

MAX_BYTES :: 1024 * 1024;
CUSTOM_SCHEMA_MIN :: wire_cast(u32, (65536));

// All callbacks are required. read receives a zero value; it may leave owned
// partial state on failure (read_new destroys it). clone must deep-copy owners.
// Each encoded value must consume at least one bit (also for an empty struct).
// Use the same context allocator for the complete lifetime of an owner.

Codec :: struct(T: Type) {
    schema: u32;

    write: #type (*core.Writer, *T) -> bool;

    read: #type (*core.Reader, *T) -> bool;

    equal: #type (*T, *T) -> bool;

    clone: #type (*T) -> T;

    destroy: #type (*T);
}

valid :: (c: Codec($T)) -> bool {
    return c.schema != 0 && c.write != null && c.read != null && c.equal != null && c.clone != null && c.destroy != null;
}

// Registration is explicit, typed and immutable: keep the returned codec in
// your application's schema table. No reflection or fallback memory copying.

register :: (c: Codec($T)) -> (Codec(T), bool) {
    if c.schema < CUSTOM_SCHEMA_MIN || !valid(c) {
        return .{
        }, false;
    };

    return c, true;
}

// Optional application-owned schema registry. It detects duplicate custom
// schemas, including collisions across different T. It owns no value instances.

Registry :: struct {
    schemas: H.Table(u32, Type);
    initialized: bool;
}

registry_init :: (r: *Registry) {
    r.* = .{
        schemas = new_table(u32, Type), initialized = true,
    };
}

registry_destroy :: (r: *Registry) {
    release(r.schemas);
    r.* = .{
    };
}

register_in :: (r: *Registry, c: Codec($T)) -> (Codec(T), bool) {
    checked, ok := register(c);
    if !ok || !r.initialized {
        return .{
        }, false;
    };

    _, exists := table_get(*r.schemas, c.schema);
    if exists {
        return .{
        }, false;
    };

    H.table_set(*r.schemas, c.schema, T);
    return checked, true;
}

registered_type :: (r: *Registry, schema: u32) -> (Type, bool) {
    t, ok := table_get(*r.schemas, schema);
    return t, ok;
}

reject_read :: (r: *core.Reader) -> bool {
    if r.err == .None {
        r.err = .Malformed;
    }

    return false;
}

reject_write :: (w: *core.Writer) -> bool {
    if w.err == .None {
        w.err = .Malformed;
    }

    return false;
}

write :: (c: Codec($T), w: *core.Writer, v: *T) -> bool {
    if w.err != .None {
        return false;
    }

    if !valid(c) {
        return reject_write(w);
    }

    before := w.bit_count;
    if !c.write(w, v) || w.bit_count <= before {
        return reject_write(w);
    }

    return w.err == .None;
}

read_new :: (c: Codec($T), r: *core.Reader) -> T, bool {
    v: T;
    ok: bool;

    if r.err != .None {
        return v, ok;
    }

    if !valid(c) {
        reject_read(r);
        return v, ok;
    }

    before := r.bit_position;
    if !c.read(r, *v) || r.err != .None || r.bit_position <= before {
        c.destroy(*v);
        v = .{
        };

        reject_read(r);
        return v, ok;
    }

    return v, true;
}

// Atomic replacement of an already initialized owned value.

read :: (c: Codec($T), r: *core.Reader, dst: *T) -> bool {
    v, ok := read_new(c, r);
    if !ok {
        return false;
    }

    c.destroy(dst);
    dst.* = v;
    return true;
}

//@endregion
//@region Built-in schema

Vec2 :: [2] float32;
Vec3 :: [3] float32;
Vec4 :: [4] float32;
Quaternion :: #type,distinct[4] float32;
// Stable IDs only, never process pointers. id == 0 is the null reference.

Reference :: struct {
    id: u64;
    generation: u32;
}

builtin :: ($T: Type) -> Codec(T) {
    schema: u32;
    #if T == bool {
        schema = 1;
    } else #if T == u8 {
        schema = 2;
    } else #if T == u16 {
        schema = 3;
    } else #if T == u32 {
        schema = 4;
    } else #if T == u64 {
        schema = 5;
    } else #if T == s8 {
        schema = 6;
    } else #if T == s16 {
        schema = 7;
    } else #if T == s32 {
        schema = 8;
    } else #if T == s64 {
        schema = 9;
    } else #if T == float32 {
        schema = 10;
    } else #if T == float64 {
        schema = 11;
    } else #if T == string {
        schema = 12;
    } else #if T == [] u8 {
        schema = 13;
    } else #if T == Vec2 {
        schema = 14;
    } else #if T == Vec3 {
        schema = 15;
    } else #if T == Vec4 {
        schema = 16;
    } else #if T == Quaternion {
        schema = 17;
    } else #if T == Reference {
        schema = 18;
    } else {
        return .{
        };
    }

    return .{
        schema, builtin_write(T), builtin_read(T), builtin_equal(T), builtin_clone(T), builtin_destroy(T),
    };
}

builtin_write :: ($T: Type) -> ((*core.Writer, *T) -> bool) {
    return (w: *core.Writer, v: *T) -> bool {
        #if T == bool {
            core.write_boolean(w, v.*);
        } else #if T == u8 || T == u16 || T == u32 || T == u64 {
            core.write_bits(w, wire_cast(u64, (v.*)), wire_cast(u32, (size_of(T) * 8)));
        } else #if T == s8 || T == s16 || T == s32 || T == s64 {
            core.write_bits(w, wire_cast(u64, (v.*)) & (0xffffffffffffffff >> (64 - size_of(T) * 8)), wire_cast(u32, (size_of(T) * 8)));
        } else #if T == float32 {
            core.write_bits(w, wire_cast(u64, (bit_cast(u32, v.*))), 32);
        } else #if T == float64 {
            core.write_bits(w, bit_cast(u64, v.*), 64);
        } else #if T == string || T == [] u8 {
            if (v.*).count > MAX_BYTES {
                return reject_write(w);
            }

            core.write_bits(w, wire_cast(u64, ((v.*).count)), 32);
            #if T == string {
                for b: bit_cast([] u8, v.*) {
                    core.write_bits(w, wire_cast(u64, (b)), 8);
                }
            } else {
                for b: v.* {
                    core.write_bits(w, wire_cast(u64, (b)), 8);
                }
            }
        } else #if T == Vec2 || T == Vec3 || T == Vec4 || T == Quaternion {
            for f: v.* {
                core.write_bits(w, wire_cast(u64, (bit_cast(u32, f))), 32);
            }
        } else #if T == Reference {
            core.write_bits(w, v.id, 64);
            core.write_bits(w, wire_cast(u64, (v.generation)), 32);
        } else {
            return reject_write(w);
        }

        return w.err == .None;
    }
}

builtin_read :: ($T: Type) -> ((*core.Reader, *T) -> bool) {
    return (r: *core.Reader, v: *T) -> bool {
        #if T == bool {
            v.* = core.read_boolean(r);
        } else #if T == u8 || T == u16 || T == u32 || T == u64 || T == s8 || T == s16 || T == s32 || T == s64 {
            v.* = wire_cast(T, (core.read_bits(r, wire_cast(u32, (size_of(T) * 8)))));
        } else #if T == float32 {
            v.* = bit_cast(float32, wire_cast(u32, (core.read_bits(r, 32))));
        } else #if T == float64 {
            v.* = bit_cast(float64, core.read_bits(r, 64));
        } else #if T == string || T == [] u8 {
            n := core.read_bits(r, 32);
            if r.err != .None || n > MAX_BYTES || n > wire_cast(u64, (core.reader_remaining_bits(r) / 8)) {
                return reject_read(r);
            }

            if n == 0 {
                v.* = .{
                };
                return true;
            };

            b := new_slice(u8, (cast(int) (n)));
            for *x: b {
                x.* = wire_cast(u8, (core.read_bits(r, 8)));
            }

            #if T == string {
                v.* = (cast(string) (b));
            } else {
                v.* = b;
            }
        } else #if T == Vec2 || T == Vec3 || T == Vec4 || T == Quaternion {
            for *f: v.* {
                f.* = bit_cast(float32, wire_cast(u32, (core.read_bits(r, 32))));
            }
        } else #if T == Reference {
            v.id = core.read_bits(r, 64);
            v.generation = wire_cast(u32, (core.read_bits(r, 32)));
        } else {
            return reject_read(r);
        }

        return r.err == .None;
    }
}

builtin_equal :: ($T: Type) -> ((*T, *T) -> bool) {
    return (a, b: *T) -> bool {
        #if T == [] u8 {
            if (a.*).count != (b.*).count {
                return false;
            }

            for x, i: a.* {
                if x != b.*[i] {
                    return false;
                }
            }

            return true;
        } else #if T == float32 {
            return bit_cast(u32, a.*) == bit_cast(u32, b.*);
        } else #if T == float64 {
            return bit_cast(u64, a.*) == bit_cast(u64, b.*);
        } else #if T == Vec2 || T == Vec3 || T == Vec4 || T == Quaternion {
            for x, i: a.* {
                if bit_cast(u32, x) != bit_cast(u32, b.*[i]) {
                    return false;
                }
            }

            return true;
        } else #if T == bool || T == u8 || T == u16 || T == u32 || T == u64 || T == s8 || T == s16 || T == s32 || T == s64 || T == string || T == Reference {
            return a.* == b.*;
        } else {
            return false;
        }
    }
}

builtin_clone :: ($T: Type) -> ((*T) -> T) {
    return (v: *T) -> T {
        #if T == string || T == [] u8 {
            if (v.*).count == 0 {
                return .{
                };
            }

            b := new_slice(u8, (v.*).count);
            #if T == string {
                copy_samples(b, bit_cast([] u8, v.*));
                return (cast(string) (b));
            } else {
                copy_samples(b, v.*);
                return b;
            }
        } else #if T == bool || T == u8 || T == u16 || T == u32 || T == u64 || T == s8 || T == s16 || T == s32 || T == s64 || T == float32 || T == float64 || T == Vec2 || T == Vec3 || T == Vec4 || T == Quaternion || T == Reference {
            return v.*;
        } else {
            assert(false, "unsupported builtin codec type");
            return .{};
        }
    }
}

builtin_destroy :: ($T: Type) -> (#type (*T)) {
    return (v: *T) {
        #if T == string {
            release(v.*);
        } else #if T == [] u8 {
            release(v.*);
        }

        v.* = .{
        };
    }
}

//@endregion
//@region Object adapter (no objects import)

Binding :: struct(T: Type) {
    codec: Codec(T);
    value: T;
}

Bridge :: struct {
    schema: u32;

    write: #type (*core.Writer, *void);

    read: #type (*core.Reader, *void) -> bool;

    destroy: #type (*void);
}

// Pass ^Binding(T) as member_custom's value pointer. Copy these four fields
// into objects.Value_Codec. The binding must outlive the registered member.

bridge :: (c: Codec($T)) -> Bridge {
    if !valid(c) {
        return .{
        };
    }

    return .{
        schema = c.schema,
        write = (w: *core.Writer, p: *void) {
            b := (cast(*Binding(T)) p);
            write(b.codec, w, *b.value);
        },
        read = (r: *core.Reader, p: *void) -> bool {
            b := (cast(*Binding(T)) p);
            value, ok := read_new(b.codec, r);
            if !ok {
                return false;
            }

            if !value_member_finished(r) {
                b.codec.destroy(*value);
                return reject_read(r);
            }

            b.codec.destroy(*b.value);
            b.value = value;
            return true;
        },
        destroy = (p: *void) {
            b := (cast(*Binding(T)) p);
            b.codec.destroy(*b.value);
        },
    }
}

//@endregion
// Cast semantics adapted.
