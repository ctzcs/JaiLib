#scope_module
using Basic; // module-private
using Math;
#scope_export

// Port of Foster Framework/Spatial/Point2.cs (core subset; completed in M6).

Point2 :: struct {
    x, y: s32;
}

Point2_Zero :: Point2.{ 0, 0 };
Point2_One :: Point2.{ 1, 1 };
Point2_UnitX :: Point2.{ 1, 0 };
Point2_UnitY :: Point2.{ 0, 1 };
Point2_Right :: Point2.{ 1, 0 };
Point2_Left :: Point2.{ -1, 0 };
Point2_Up :: Point2.{ 0, -1 };
Point2_Down :: Point2.{ 0, 1 };

point2_length :: (p: Point2) -> float64 {
    return sqrt(cast(float64) p.x * p.x + cast(float64) p.y * p.y);
}

point2_length_squared :: (p: Point2) -> s64 {
    return cast(s64) p.x * p.x + cast(s64) p.y * p.y;
}

point2_distance :: (a: Point2, b: Point2) -> float64 {
    dx := cast(float64) (a.x - b.x);
    dy := cast(float64) (a.y - b.y);
    return sqrt(dx * dx + dy * dy);
}

operator + :: (a: Point2, b: Point2) -> Point2 {
    return .{ a.x + b.x, a.y + b.y };
}

operator - :: (a: Point2, b: Point2) -> Point2 {
    return .{ a.x - b.x, a.y - b.y };
}

operator == :: (a: Point2, b: Point2) -> bool {
    return a.x == b.x && a.y == b.y;
}

operator != :: (a: Point2, b: Point2) -> bool {
    return a.x != b.x || a.y != b.y;
}
