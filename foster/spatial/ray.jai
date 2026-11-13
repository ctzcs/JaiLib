#scope_module
using Basic;   // module-private
using Math;
#scope_export

// Port of Foster Framework/Spatial/Ray.cs — a 2D ray.
//
// Foster's Ray is only the two fields below (upstream still carries
// "TODO: implement intersection tests"), so the struct is a 1:1 port and the
// helpers marked "port addition" are small conveniences this port adds; they do
// not change the C# shape.
//
// Foster does not normalize Direction (a ray can be any length), so ray_point_at
// uses whatever Direction the ray was built with; call ray_normalized if you
// want unit-length steps.

Ray :: struct {
    Position:  Vector2;   // origin of the Ray
    Direction: Vector2;   // direction of the Ray
}

// A ray at the origin pointing along +X (port addition: handy default value).
Ray_Zero :: Ray.{ .{ 0, 0 }, .{ 1, 0 } };

// C# primary constructor `Ray(Vector2 position, Vector2 direction)`.
ray_create :: (position: Vector2, direction: Vector2) -> Ray {
    return .{ position, direction };
}

// port addition: Position + Direction * t
ray_point_at :: (r: Ray, t: float) -> Vector2 {
    return r.Position + r.Direction * t;
}

// port addition: the same ray with a unit-length Direction. A zero-length
// direction is left untouched instead of becoming NaN.
ray_normalized :: (r: Ray) -> Ray {
    len := length(r.Direction);
    if len == 0 return r;
    return .{ r.Position, r.Direction / len };
}

// C# structs get field-wise equality from ValueType; spell it out here.
operator == :: (a: Ray, b: Ray) -> bool {
    return a.Position == b.Position && a.Direction == b.Direction;
}

operator != :: (a: Ray, b: Ray) -> bool {
    return !(a == b);
}
