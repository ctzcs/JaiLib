#scope_module
using Basic; // module-private
using Math;
#scope_export

// Port of Foster Framework/Spatial/Point3.cs.
//
// Laid out exactly like point2.jai: a plain { x, y, z } struct, the C# `static
// readonly` fields as module-level constants, the C# members as free
// procedures, and the C# operators as Jai `operator` overloads.
//
// C# conversions:
//   implicit (int, int, int) -> Point3   ...  struct literal Point3.{ x, y, z }
//   explicit Vector3 -> Point3           ...  vector3_to_point3   (truncating)
//   implicit Point3 -> Vector3           ...  point3_to_vector3
// C# has three constructors (xyz / x,y / x,y,z); a Jai struct literal needs all
// three fields, so point3_splat and point3_from_xy cover the first two.
//
// Equality: `operator ==` / `!=` mirror C#'s operators; point3_hash stands in
// for GetHashCode.

Point3 :: struct {
    x, y, z: s32;
}

Point3_Zero :: Point3.{ 0, 0, 0 };
Point3_One :: Point3.{ 1, 1, 1 };
Point3_Left :: Point3.{ -1, 0, 0 };
Point3_Right :: Point3.{ 1, 0, 0 };
Point3_Up :: Point3.{ 0, -1, 0 }; // +Y points down, as in Foster's 2D space
Point3_Down :: Point3.{ 0, 1, 0 };
Point3_Forward :: Point3.{ 0, 0, 1 };
Point3_Backward :: Point3.{ 0, 0, -1 };

// C# `new Point3(int xyz)` — every component gets the same value.
point3_splat :: (xyz: s32) -> Point3 {
    return .{ xyz, xyz, xyz };
}

// C# `new Point3(int x, int y)` — z defaults to 0.
point3_from_xy :: (x: s32, y: s32) -> Point3 {
    return .{ x, y, 0 };
}

// C# Point3.Length() (Vector3.Length). Carried as float64 like point2_length;
// C# returns the vector's float.
point3_length :: (p: Point3) -> float64 {
    x := cast(float64) p.x;
    y := cast(float64) p.y;
    z := cast(float64) p.z;
    return sqrt(x * x + y * y + z * z);
}

point3_length_squared :: (p: Point3) -> s64 {
    return cast(s64) p.x * p.x + cast(s64) p.y * p.y + cast(s64) p.z * p.z;
}

point3_distance :: (a: Point3, b: Point3) -> float64 {
    return point3_length(a - b);
}

point3_dot :: (a: Point3, b: Point3) -> s64 {
    return cast(s64) a.x * b.x + cast(s64) a.y * b.y + cast(s64) a.z * b.z;
}

// C# Point3.Normalized() (Vector3.Normalized). Like the C# version this does not
// guard against a zero-length point: that yields a NaN/inf vector.
point3_normalized :: (p: Point3) -> Vector3 {
    return unit_vector(point3_to_vector3(p));
}

// C# implicit Point3 -> Vector3.
point3_to_vector3 :: (p: Point3) -> Vector3 {
    return xyz(cast(float) p.x, cast(float) p.y, cast(float) p.z);
}

// C# explicit Vector3 -> Point3: truncates toward zero, like (int)vector.X.
vector3_to_point3 :: (v: Vector3) -> Point3 {
    return .{ cast(s32) v.x, cast(s32) v.y, cast(s32) v.z };
}

// C# ToString(): "[X, Y, Z]". Result lives in temporary storage — copy it
// (copy_string) if it has to outlive the current scope.
point3_to_string :: (p: Point3) -> string {
    return tprint("[%, %, %]", p.x, p.y, p.z);
}

// Stand-in for C# GetHashCode (HashCode.Combine(X, Y, Z)). Same purpose, not a
// bit-compatible port of .NET's hash.
point3_hash :: (p: Point3) -> u32 {
    h := cast(u32) 17;
    h = h * 31 + cast(u32) p.x;
    h = h * 31 + cast(u32) p.y;
    h = h * 31 + cast(u32) p.z;
    return h;
}

// C# `%` on floats is the remainder with the sign of the dividend; Jai has no
// builtin float modulo, so this uses the same floor-mod as mod_f32 (utility /
// batcher) — identical results for the non-negative operands Point3 sees in
// practice, sign-flipped for negative ones.
point3_fmod_f32 :: (a: float, b: float) -> float {
    if b == 0 return 0;
    return a - b * floor(a / b);
}

//
// Operators (one-to-one with the C# operator overloads)
//

operator - :: (p: Point3) -> Point3 {
    return .{ -p.x, -p.y, -p.z };
}

operator + :: (a: Point3, b: Point3) -> Point3 {
    return .{ a.x + b.x, a.y + b.y, a.z + b.z };
}

operator - :: (a: Point3, b: Point3) -> Point3 {
    return .{ a.x - b.x, a.y - b.y, a.z - b.z };
}

// Point3 op int -> Point3
operator * :: (p: Point3, scaler: s32) -> Point3 {
    return .{ p.x * scaler, p.y * scaler, p.z * scaler };
}

operator / :: (p: Point3, scaler: s32) -> Point3 {
    return .{ p.x / scaler, p.y / scaler, p.z / scaler };
}

operator % :: (p: Point3, scaler: s32) -> Point3 {
    return .{ p.x % scaler, p.y % scaler, p.z % scaler };
}

// Point3 op float -> Vector3 (C# returns a Vector3 from these three)
operator * :: (p: Point3, scaler: float) -> Vector3 {
    return .{ cast(float) p.x * scaler, cast(float) p.y * scaler, cast(float) p.z * scaler };
}

operator / :: (p: Point3, scaler: float) -> Vector3 {
    return .{ cast(float) p.x / scaler, cast(float) p.y / scaler, cast(float) p.z / scaler };
}

operator % :: (p: Point3, scaler: float) -> Vector3 {
    return .{
        point3_fmod_f32(cast(float) p.x, scaler),
        point3_fmod_f32(cast(float) p.y, scaler),
        point3_fmod_f32(cast(float) p.z, scaler),
    };
}

operator == :: (a: Point3, b: Point3) -> bool {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

operator != :: (a: Point3, b: Point3) -> bool {
    return a.x != b.x || a.y != b.y || a.z != b.z;
}
