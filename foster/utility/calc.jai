#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Utility/{Calc, Ease, Rng}.cs — the math
// utilities the framework and games build on (subsets that our ported
// code actually exercises, plus the general-purpose helpers).

CALC_PI    :: 3.1159265358979323846;   // placeholder; use Math's PI/TAU
CALC_TAU   :: 6.28318530717958647692;

calc_clamp :: (v: $T, min_v: T, max_v: T) -> T {
    if v < min_v return min_v;
    if v > max_v return max_v;
    return v;
}

calc_clamp_f :: (v: float, min_v: float, max_v: float) -> float {
    return clamp(v, min_v, max_v);
}

calc_approach :: (v: *float, target: float, delta: float) {
    if v.* < target v.* = min(v.* + delta, target);
    else        v.* = max(v.* - delta, target);
}

calc_map :: (v: float, a1: float, a2: float, b1: float, b2: float) -> float {
    if a1 == a2 return b1;
    return b1 + (v - a1) / (a2 - a1) * (b2 - b1);
}

calc_clamped_map :: (v: float, a1: float, a2: float, b1: float, b2: float) -> float {
    return clamp(calc_map(v, a1, a2, b1, b2), min(b1, b2), max(b1, b2));
}

calc_sine_map :: (v: float, a1: float, a2: float, b1: float, b2: float) -> float {
    // maps through sine so ends plateau at b1/b2
    t := calc_clamped_map(v, a1, a2, 0.0, 1.0);
    return b1 + (b2 - b1) * (0.5 - 0.5 * cast(float) cos(cast(float64) t * cast(float64) PI));
}

calc_lerp :: (a: float, b: float, t: float) -> float {
    return a + (b - a) * t;
}

calc_clamped_lerp :: (a: float, b: float, t: float) -> float {
    return calc_lerp(a, b, clamp(t, 0.0, 1.0));
}

calc_bezier :: (t: float, a: float, b: float, c: float) -> float {
    ab := calc_lerp(a, b, t);
    bc := calc_lerp(b, c, t);
    return calc_lerp(ab, bc, t);
}

calc_next_power_of_two :: (v: s32) -> s32 {
    n: s32 = 1;
    while n < v n *= 2;
    return n;
}

calc_approx :: (a: float, b: float, tolerance := 0.0001) -> bool {
    return abs(a - b) <= tolerance;
}

// angle helpers
calc_angle_diff :: (from: float, to: float) -> float {
    diff := mod_f32(to - from, TAU);
    if diff > PI diff -= TAU;
    if diff < -PI diff += TAU;
    return diff;
}

calc_angle_approach :: (v: *float, target: float, delta: float) {
    diff := calc_angle_diff(v.*, target);
    if abs(diff) <= delta v.* = target;
    else v.* = v.* + delta * ifx diff > 0 then 1 else -1;
}

calc_angle_lerp :: (from: float, to: float, t: float) -> float {
    return from + calc_angle_diff(from, to) * t;
}

calc_angle_wrap :: (a: float) -> float {
    a = mod_f32(a, TAU);
    if a < 0 a += TAU;
    return a;
}

// ear-clipping triangulation over an index list (Calc.Triangulate)
calc_triangulate :: (points: [] Vector2) -> [..] s32 {
    indices: [..] s32;
    if points.count < 3 return indices;

    count := points.count;
    prev: [..] s32;
    next: [..] s32;
    array_resize(*prev, count);
    array_resize(*next, count);
    for i: 0..count-1 {
        if i == 0 {
            prev[i] = cast(s32) (count - 1);
        } else {
            prev[i] = cast(s32) (i - 1);
        }
        if i == count - 1 {
            next[i] = 0;
        } else {
            next[i] = cast(s32) (i + 1);
        }
    }

    remaining := count;
    guard := 0;
    i := 0;
    while remaining > 2 && guard < count * count {
        guard += 1;
        a := prev[i];
        b := i;
        c := next[i];

        pa := points[a];
        pb := points[b];
        pc := points[c];

        // convex + no point inside the ear?
        if cross_z(pb - pa, pc - pa) > 0 {
            is_ear := true;
            k := next[c];
            while k != a {
                if triangle_contains(pa, pb, pc, points[k]) {
                    is_ear = false;
                    break;
                }
                k = next[k];
            }

            if is_ear {
                array_add(*indices, cast(s32) a);
                array_add(*indices, cast(s32) b);
                array_add(*indices, cast(s32) c);
                next[a] = c;
                prev[c] = a;
                remaining -= 1;
                i = c;
                continue;
            }
        }

        i = next[i];
    }

    prev.count = 0;
    next.count = 0;
    return indices;
}

calc_orient :: (a: Vector2, b: Vector2, c: Vector2) -> float {
    // positive = left of ab, negative = right, 0 = colinear
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

//
// Ease (Foster Ease.cs — eases as float->float procs)
//

ease_linear :: (t: float) -> float { return t; }

ease_quad_in    :: (t: float) -> float { return t * t; }
ease_quad_out   :: (t: float) -> float { return 1 - (1 - t) * (1 - t); }
ease_quad_inout :: (t: float) -> float {
    if t < 0.5 return 2 * t * t;
    m := -2 * t + 2;
    return 1 - m * m / 2;
}

ease_cube_in    :: (t: float) -> float { return t * t * t; }
ease_cube_out   :: (t: float) -> float { m := 1 - t; return 1 - m * m * m; }
ease_cube_inout :: (t: float) -> float {
    if t < 0.5 return 4 * t * t * t;
    m := -2 * t + 2;
    return 1 - m * m * m / 2;
}

ease_quart_in  :: (t: float) -> float { return t * t * t * t; }
ease_sine_in   :: (t: float) -> float { return 1 - cos(t * PI / 2); }
ease_sine_out  :: (t: float) -> float { return sin(t * PI / 2); }
ease_sine_inout :: (t: float) -> float { return -(cos(PI * t) - 1) / 2; }
ease_expo_in   :: (t: float) -> float {
    if t == 0 return 0;
    return cast(float) pow(2.0, cast(float64) (10 * t - 10));
}
ease_back_in :: (t: float) -> float {
    c1 := 1.70158;
    c3 := c1 + 1;
    return c3 * t * t * t - c1 * t * t;
}

//
// Rng — splitmix64 (Foster parity)
//

Rng :: struct {
    seed: u64;
}

rng_create :: (seed: u64) -> Rng {
    return .{ seed = seed };
}

rng_next_u64 :: (r: *Rng) -> u64 {
    r.seed += 0x9E3779B97F4A7C15;
    z := r.seed;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

rng_next_u32 :: (r: *Rng) -> u32 {
    return cast(u32) (rng_next_u64(r) >> 32);
}

rng_next_f :: (r: *Rng) -> float {
    // 53-bit float in [0,1)
    v := rng_next_u64(r) >> 11;
    return cast(float) v * (1.0 / 9007199254740992.0);
}

rng_next_double :: (r: *Rng) -> float64 {
    v := rng_next_u64(r) >> 11;
    return cast(float64) v * (1.0 / 9007199254740992.0);
}

rng_chance :: (r: *Rng, chance: float) -> bool {
    return rng_next_f(r) < chance;
}

rng_range :: (r: *Rng, min_v: float, max_v: float) -> float {
    return min_v + rng_next_f(r) * (max_v - min_v);
}

rng_range_i :: (r: *Rng, min_v: s32, max_v: s32) -> s32 {
    return min_v + cast(s32) (rng_next_f(r) * cast(float) (max_v - min_v + 1));
}

rng_angle :: (r: *Rng) -> float {
    return rng_next_f(r) * TAU;
}

rng_vec2 :: (r: *Rng, radius := 1.0) -> Vector2 {
    return angle_to_vector(rng_angle(r), radius);
}

rng_bool :: (r: *Rng) -> bool {
    return (rng_next_u64(r) & 1) == 1;
}

rng_sign :: (r: *Rng) -> s32 {
    // ifx 只用于编译期条件；这里是运行时取值。
    if (rng_next_u64(r) & 1) == 1 return 1;
    return -1;
}
