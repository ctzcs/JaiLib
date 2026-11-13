#scope_module
using Basic;
using Math;
#scope_export

// 2D affine matrix, equivalent to System.Numerics.Matrix3x2 (which Foster's
// Batcher/Spatial use). Layout matches Foster's usage: row-major
// [M11 M12]   translation in row 3.
// [M21 M22]
// [M31 M32]

Matrix3x2 :: struct {
    m11, m12: float;
    m21, m22: float;
    m31, m32: float;
}

Matrix3x2_Identity :: Matrix3x2.{ 1, 0, 0, 1, 0, 0 };

matrix3x2_create_translation :: (x: float, y: float) -> Matrix3x2 {
    return .{ 1, 0, 0, 1, x, y };
}

matrix3x2_create_rotation :: (radians: float) -> Matrix3x2 {
    c := cos(radians);
    s := sin(radians);
    return .{ c, s, -s, c, 0, 0 };
}

matrix3x2_create_scale :: (x: float, y: float) -> Matrix3x2 {
    return .{ x, 0, 0, y, 0, 0 };
}

// Foster: Transform.CreateMatrix(position, origin, scale, rotation) —
// Row vectors: translate(-origin) * scale * rotate * translate(position).
matrix3x2_create_transform :: (position: Vector2, origin: Vector2, scale: Vector2, rotation: float) -> Matrix3x2 {
    if rotation != 0 {
        c := cos(rotation);
        s := sin(rotation);
        mx := position.x - origin.x * scale.x * c + origin.y * scale.y * s;
        my := position.y - origin.x * scale.x * s - origin.y * scale.y * c;
        return .{ c * scale.x, s * scale.x, -s * scale.y, c * scale.y, mx, my };
    }
    return .{
        scale.x, 0,
        0, scale.y,
        position.x - origin.x * scale.x,
        position.y - origin.y * scale.y,
    };
}

matrix3x2_translation :: (m: Matrix3x2) -> Vector2 {
    return .{ m.m31, m.m32 };
}

// Matrix product a*b (Foster's operator*, applied left-to-right)
operator * :: (a: Matrix3x2, b: Matrix3x2) -> Matrix3x2 {
    return .{
        a.m11 * b.m11 + a.m12 * b.m21,
        a.m11 * b.m12 + a.m12 * b.m22,
        a.m21 * b.m11 + a.m22 * b.m21,
        a.m21 * b.m12 + a.m22 * b.m22,
        a.m31 * b.m11 + a.m32 * b.m21 + b.m31,
        a.m31 * b.m12 + a.m32 * b.m22 + b.m32,
    };
}

// Vector2.Transform(v, m)
vector2_transform :: (v: Vector2, m: Matrix3x2) -> Vector2 {
    return .{
        v.x * m.m11 + v.y * m.m21 + m.m31,
        v.x * m.m12 + v.y * m.m22 + m.m32,
    };
}

operator == :: (a: Matrix3x2, b: Matrix3x2) -> bool {
    return a.m11 == b.m11 && a.m12 == b.m12 && a.m21 == b.m21 &&
           a.m22 == b.m22 && a.m31 == b.m31 && a.m32 == b.m32;
}
