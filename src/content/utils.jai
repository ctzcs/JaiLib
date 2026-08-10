// utils.jai
// Port of Ascension/src/content/utils.odin

#import "Basic";
#import "bindings/raylib";

lerp_f32 :: (a: float32, b: float32, ratio: float32) -> float32 {
    return a + (b - a) * ratio;
}

lerp_vec2 :: (a: Vector2, b: Vector2, ratio: float32) -> Vector2 {
    return .{ x = a.x + (b.x - a.x) * ratio, y = a.y + (b.y - a.y) * ratio };
}

clamp01 :: (v: float32) -> float32 {
    return clamp(v, 0.0, 1.0);
}

ease_out_cubic :: (t: float32) -> float32 {
    x := 1.0 - clamp01(t);
    return 1.0 - x * x * x;
}

ease_in_quad :: (t: float32) -> float32 {
    x := clamp01(t);
    return x * x;
}

ease_out_back :: (t: float32) -> float32 {
    x := clamp01(t);
    c1: float32 = 1.70158;
    c3 := c1 + 1.0;
    y := x - 1.0;
    return 1.0 + c3 * y * y * y + c1 * y * y;
}

random_range_f32 :: (min: float32, max: float32) -> float32 {
    t := cast(float32) GetRandomValue(0, 1000) / 1000.0;
    return min + (max - min) * t;
}

color_with_alpha :: (color: Color, alpha: float32) -> Color {
    out := color;
    out.a = cast(u8) (clamp01(alpha) * 255.0);
    return out;
}

random_color :: () -> Color {
    return .{
        r = cast(u8) GetRandomValue(0, 255),
        g = cast(u8) GetRandomValue(0, 255),
        b = cast(u8) GetRandomValue(0, 255),
        a = 255,
    };
}
