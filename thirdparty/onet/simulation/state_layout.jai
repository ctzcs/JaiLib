#scope_file

#scope_export

//@region 定长状态布局
// capture/restore/validate 共用的小端定长读写。at 是字节偏移，成功后前移；
// 越界时返回 false，不写入、读取返回零值且 at 不变。布局变化必须换 schema。

state_put_u8 :: (dst: [] u8, at: *int, v: u8) -> bool {
    return state_put_bits(dst, at, (cast, trunc(u32)(v)), 1);
}

state_put_u16 :: (dst: [] u8, at: *int, v: u16) -> bool {
    return state_put_bits(dst, at, (cast, trunc(u32)(v)), 2);
}

state_put_u32 :: (dst: [] u8, at: *int, v: u32) -> bool {
    return state_put_bits(dst, at, v, 4);
}

state_put_f32 :: (dst: [] u8, at: *int, v: float32) -> bool {
    return state_put_bits(dst, at, bit_cast(u32, v), 4);
}

state_put_vec2 :: (dst: [] u8, at: *int, v: [2] float32) -> bool {
    if at.* < 0 || at.* > (dst).count - 8 {
        return false;
    }

    return state_put_f32(dst, at, v[0]) && state_put_f32(dst, at, v[1]);
}

state_get_u8 :: (src: [] u8, at: *int) -> (u8, bool) {
    v, ok := state_get_bits(src, at, 1);
    return (cast, trunc(u8)(v)), ok;
}

state_get_u16 :: (src: [] u8, at: *int) -> (u16, bool) {
    v, ok := state_get_bits(src, at, 2);
    return (cast, trunc(u16)(v)), ok;
}

state_get_u32 :: (src: [] u8, at: *int) -> (u32, bool) {
    return state_get_bits(src, at, 4);
}

state_get_f32 :: (src: [] u8, at: *int) -> (float32, bool) {
    v, ok := state_get_bits(src, at, 4);
    return bit_cast(float32, v), ok;
}

state_get_vec2 :: (src: [] u8, at: *int) -> ([2] float32, bool) {
    if at.* < 0 || at.* > (src).count - 8 {
        return .{
        }, false;
    };

    x, _ := state_get_f32(src, at);
    y, _ := state_get_f32(src, at);
    return .[x, y], true;
};

state_put_bits :: (dst: [] u8, at: *int, v: u32, size: int) -> bool {
    if at.* < 0 || at.* > (dst).count - size {
        return false;
    }

    {
        i := 0;
        while i < size {
            defer i += 1;
            dst[at.* + i] = (cast, trunc(u8)(v >> (cast, trunc(u64)(i * 8))));
        }
    }

    at.* += size;
    return true;
}

state_get_bits :: (src: [] u8, at: *int, size: int) -> (u32, bool) {
    if at.* < 0 || at.* > (src).count - size {
        return 0, false;
    }

    v: u32;
    {
        i := 0;
        while i < size {
            defer i += 1;
            v |= ((cast, trunc(u32) src[at.* + i])) << (cast, trunc(u64)(i * 8));
        }
    }

    at.* += size;
    return v, true;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
