#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Images/Color.cs.
// RGBA, one byte per channel, in R,G,B,A memory order.

Color :: struct {
    r, g, b, a: u8;
}

Color_White :: Color.{ 255, 255, 255, 255 };
Color_Black :: Color.{   0,   0,   0, 255 };
Color_Transparent :: Color.{ 0, 0, 0, 0 };
Color_Red   :: Color.{ 255, 0, 0, 255 };
Color_Green :: Color.{ 0, 255, 0, 255 };
Color_Blue  :: Color.{ 0, 0, 255, 255 };
Color_Yellow :: Color.{ 255, 255, 0, 255 };
Color_Cyan :: Color.{ 0, 255, 255, 255 };
Color_Magenta :: Color.{ 255, 0, 255, 255 };
Color_CornflowerBlue :: Color.{ 100, 149, 237, 255 };
Color_MediumPurple :: Color.{ 147, 112, 219, 255 };
Color_OrangeRed :: Color.{ 255, 69, 0, 255 };
Color_PaleGreen :: Color.{ 152, 251, 152, 255 };

color_lerp :: (a: Color, b: Color, t: float) -> Color {
    return .{
        cast(u8) (a.r + ((cast(float) b.r) - (cast(float) a.r)) * t),
        cast(u8) (a.g + ((cast(float) b.g) - (cast(float) a.g)) * t),
        cast(u8) (a.b + ((cast(float) b.b) - (cast(float) a.b)) * t),
        cast(u8) (a.a + ((cast(float) b.a) - (cast(float) a.a)) * t),
    };
}

// Premultiplies alpha using the same integer math as Foster:
// (byte)(R * a / 255) per channel.
color_premultiply :: (c: Color) -> Color {
    return .{
        cast(u8) (cast(u32) c.r * cast(u32) c.a / 255),
        cast(u8) (cast(u32) c.g * cast(u32) c.a / 255),
        cast(u8) (cast(u32) c.b * cast(u32) c.a / 255),
        c.a,
    };
}

// Packs to (R<<24)|(G<<16)|(B<<8)|A (Foster: RGBA).
color_rgba :: (c: Color) -> u32 {
    return ((cast(u32) c.r) << 24) | ((cast(u32) c.g) << 16) | ((cast(u32) c.b) << 8) | cast(u32) c.a;
}

// Packs to (A<<24)|(B<<16)|(G<<8)|R (Foster: ABGR).
color_abgr :: (c: Color) -> u32 {
    return ((cast(u32) c.a) << 24) | ((cast(u32) c.b) << 16) | ((cast(u32) c.g) << 8) | cast(u32) c.r;
}

color_from_rgba :: (packed: u32) -> Color {
    return .{
        cast(u8) ((packed >> 24) & 0xFF),
        cast(u8) ((packed >> 16) & 0xFF),
        cast(u8) ((packed >> 8)  & 0xFF),
        cast(u8)  (packed        & 0xFF),
    };
}

// From RGB bytes with alpha (Foster: Color(byte r, byte g, byte b, float alpha))
color_rgba_f :: (r: u8, g: u8, b: u8, alpha: float) -> Color {
    return .{ r, g, b, cast(u8) (clamp(alpha, 0, 1) * 255 + 0.5) };
}

color_from_hex :: (hex: u32, alpha := 1.0) -> Color {
    return color_rgba_f(cast(u8) ((hex >> 16) & 255), cast(u8) ((hex >> 8) & 255), cast(u8) (hex & 255), alpha);
}

color_to_vector4 :: (c: Color) -> Vector4 {
    return .{
        cast(float) c.r / 255,
        cast(float) c.g / 255,
        cast(float) c.b / 255,
        cast(float) c.a / 255,
    };
}

color_from_vector4 :: (v: Vector4) -> Color {
    return .{
        cast(u8) (clamp(v.x, 0, 1) * 255 + 0.5),
        cast(u8) (clamp(v.y, 0, 1) * 255 + 0.5),
        cast(u8) (clamp(v.z, 0, 1) * 255 + 0.5),
        cast(u8) (clamp(v.w, 0, 1) * 255 + 0.5),
    };
}

operator == :: (a: Color, b: Color) -> bool { return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a; }
operator != :: (a: Color, b: Color) -> bool { return !(a == b); }
