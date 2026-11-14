// Portable unsigned 128-bit arithmetic used by the 96-bit decimal codec.
// Arithmetic wraps modulo 2^128; decimal checks its narrower range explicitly.
u128 :: struct {
    low: u64;
    high: u64;
}

wide :: (low: u64, high: u64 = 0) -> u128 {
    return .{ low, high };
}

operator == :: (a: u128, b: u128) -> bool {
    return a.low == b.low && a.high == b.high;
}

operator == :: (a: u128, b: u64) -> bool {
    return a.high == 0 && a.low == b;
}

operator < :: (a: u128, b: u128) -> bool {
    return a.high < b.high || (a.high == b.high && a.low < b.low);
}

operator < :: (a: u128, b: u64) -> bool {
    return a.high == 0 && a.low < b;
}

operator <= :: (a: u128, b: u128) -> bool {
    return !(a > b);
}

operator > :: (a: u128, b: u128) -> bool {
    return b < a;
}

operator > :: (a: u128, b: u64) -> bool {
    return a.high > 0 || a.low > b;
}

operator >= :: (a: u128, b: u128) -> bool {
    return !(a < b);
}

operator + :: (a: u128, b: u128) -> u128 #no_aoc {
    low := a.low + b.low;
    carry: u64;
    if low < a.low carry = 1;
    return .{ low, a.high + b.high + carry };
}

operator + :: (a: u128, b: u64) -> u128 {
    return a + wide(b);
}

operator - :: (a: u128, b: u128) -> u128 #no_aoc {
    borrow: u64;
    if a.low < b.low borrow = 1;
    return .{ a.low - b.low, a.high - b.high - borrow };
}

operator - :: (a: u128, b: u64) -> u128 {
    return a - wide(b);
}

operator | :: (a: u128, b: u128) -> u128 {
    return .{ a.low | b.low, a.high | b.high };
}

operator & :: (a: u128, b: u128) -> u128 {
    return .{ a.low & b.low, a.high & b.high };
}

operator << :: (a: u128, n: int) -> u128 {
    assert(n >= 0);
    if n >= 128 return .{};
    if n == 0 return a;
    if n >= 64 return .{ 0, a.low << (n - 64) };
    return .{ a.low << n, (a.high << n) | (a.low >> (64 - n)) };
}

operator >> :: (a: u128, n: int) -> u128 {
    assert(n >= 0);
    if n >= 128 return .{};
    if n == 0 return a;
    if n >= 64 return .{ a.high >> (n - 64), 0 };
    return .{ (a.low >> n) | (a.high << (64 - n)), a.high >> n };
}

wide_product :: (a, b: u64) -> u128 #no_aoc {
    a0 := a & 0xffffffff;
    a1 := a >> 32;
    b0 := b & 0xffffffff;
    b1 := b >> 32;
    low := a0 * b0;
    middle := a1 * b0 + (low >> 32);
    upper := middle >> 32;
    middle = (middle & 0xffffffff) + a0 * b1;
    return .{ (middle << 32) | (low & 0xffffffff), a1 * b1 + upper + (middle >> 32) };
}

operator * :: (a, b: u128) -> u128 #no_aoc {
    p := wide_product(a.low, b.low);
    p.high += a.low * b.high + a.high * b.low;
    return p;
}

operator * :: (a: u128, b: u64) -> u128 {
    return a * wide(b);
}

wide_divmod :: (a, b: u128) -> u128, u128 {
    assert(b != 0);
    q, r: u128;
    i := 128;
    while i > 0 {
        i -= 1;
        overflow := (r.high >> 63) != 0;
        r = r << 1;
        if i >= 64 r.low |= (a.high >> (i - 64)) & 1;
        else r.low |= (a.low >> i) & 1;
        if overflow || r >= b {
            r = r - b;
            if i >= 64 q.high |= (cast(u64) 1) << (i - 64);
            else q.low |= (cast(u64) 1) << i;
        }
    }
    return q, r;
}

operator / :: (a, b: u128) -> u128 {
    q, r := wide_divmod(a, b);
    return q;
}

operator % :: (a, b: u128) -> u128 {
    q, r := wide_divmod(a, b);
    return r;
}

operator / :: (a: u128, b: u64) -> u128 {
    return a / wide(b);
}

operator % :: (a: u128, b: u64) -> u128 {
    return a % wide(b);
}
