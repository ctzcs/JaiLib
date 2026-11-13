#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Spatial/{Circle, Line, LineInt, Triangle, Quad,
// Polygon, ConvexPolygon, Transform, Cardinal, Signs}.cs — the shape math
// the framework itself uses (Contains/Overlaps/Closest points/transforms).

//
// Circle
//

Circle :: struct {
    position: Vector2;
    radius:   float;
}

circle_contains :: (c: Circle, p: Vector2) -> bool {
    dx := p.x - c.position.x;
    dy := p.y - c.position.y;
    return dx * dx + dy * dy < c.radius * c.radius;
}

circle_overlaps :: (a: Circle, b: Circle) -> bool, Vector2 {
    dx := a.position.x - b.position.x;
    dy := a.position.y - b.position.y;
    dist2 := dx * dx + dy * dy;
    r := a.radius + b.radius;
    if dist2 >= r * r return false, Vector2.{ 0, 0 };

    dist := sqrt(dist2);
    if dist == 0 return true, Vector2.{ 0, 0 };
    overlap := cast(float) (r - dist);
    dir : Vector2 = .{ (b.position.x - a.position.x) / cast(float) dist, (b.position.y - a.position.y) / cast(float) dist };
    return true, dir * overlap;
}

circle_overlaps_line :: (c: Circle, a: Vector2, b: Vector2) -> bool {
    _, closest := line_closest_point(a, b, c.position);
    dx := c.position.x - closest.x;
    dy := c.position.y - closest.y;
    return dx * dx + dy * dy < c.radius * c.radius;
}

circle_overlaps_triangle :: (c: Circle, a: Vector2, b: Vector2, d: Vector2) -> bool {
    if triangle_contains(a, b, d, c.position) return true;
    if circle_overlaps_line(c, a, b) return true;
    if circle_overlaps_line(c, b, d) return true;
    if circle_overlaps_line(c, d, a) return true;
    return false;
}

circle_area :: (c: Circle) -> float { return PI * c.radius * c.radius; }
circle_circumference :: (c: Circle) -> float { return TAU * c.radius; }
circle_bounds :: (c: Circle) -> Rect {
    return .{ c.position.x - c.radius, c.position.y - c.radius, c.radius * 2, c.radius * 2 };
}

//
// Line / LineInt
//

Line :: struct {
    from: Vector2;
    to:   Vector2;
}

Line_Int :: struct {
    from: Point2;
    to:   Point2;
}

line_length :: (l: Line) -> float {
    return vector2_length(l.to - l.from);
}

line_direction :: (l: Line) -> Vector2 {
    return vector2_normalize(l.to - l.from);
}

line_point_at :: (l: Line, percent: float) -> Vector2 {
    return l.from + (l.to - l.from) * percent;
}

line_closest_t :: (l: Line, p: Vector2) -> float {
    d := l.to - l.from;
    len2 := d.x * d.x + d.y * d.y;
    if len2 == 0 return 0;
    t := ((p.x - l.from.x) * d.x + (p.y - l.from.y) * d.y) / len2;
    return clamp(t, 0.0, 1.0);
}

line_closest_point :: (a: Vector2, b: Vector2, p: Vector2) -> float, Vector2 {
    l := Line.{ a, b };
    t := line_closest_t(l, p);
    return t, a + (b - a) * t;
}

line_closest_distance :: (a: Vector2, b: Vector2, p: Vector2) -> float {
    _, closest := line_closest_point(a, b, p);
    return vector2_length(p - closest);
}

// segment-segment intersection; returns hit point
line_intersects_line :: (a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> bool, Vector2 {
    d1 := a2 - a1;
    d2 := b2 - b1;
    denom := d1.x * d2.y - d1.y * d2.x;
    if denom == 0 return false, .{ 0, 0 };

    t := ((b1.x - a1.x) * d2.y - (b1.y - a1.y) * d2.x) / denom;
    u := ((b1.x - a1.x) * d1.y - (b1.y - a1.y) * d1.x) / denom;
    if t >= 0 && t <= 1 && u >= 0 && u <= 1 {
        return true, a1 + d1 * cast(float) t;
    }
    return false, .{ 0, 0 };
}

line_intersects_rect :: (a: Vector2, b: Vector2, r: Rect) -> bool {
    if rect_contains_point(r, a) || rect_contains_point(r, b) return true;
    tl := rect_top_left(r);
    tr := rect_top_right(r);
    br := rect_bottom_right(r);
    bl := rect_bottom_left(r);
    hit, _ := line_intersects_line(a, b, tl, tr);
    if hit return true;
    hit, _ = line_intersects_line(a, b, tr, br);
    if hit return true;
    hit, _ = line_intersects_line(a, b, br, bl);
    if hit return true;
    hit, _ = line_intersects_line(a, b, bl, tl);
    return hit;
}

line_intersects_circle :: (a: Vector2, b: Vector2, c: Circle) -> bool {
    return circle_overlaps_line(c, a, b);
}

//
// Triangle
//

Triangle :: struct {
    a: Vector2;
    b: Vector2;
    c: Vector2;
}

triangle_contains :: (a: Vector2, b: Vector2, c: Vector2, p: Vector2) -> bool {
    d1 := sign_cross(p, a, b);
    d2 := sign_cross(p, b, c);
    d3 := sign_cross(p, c, a);
    has_neg := d1 < 0 || d2 < 0 || d3 < 0;
    has_pos := d1 > 0 || d2 > 0 || d3 > 0;
    return !(has_neg && has_pos);
}

sign_cross :: (p: Vector2, a: Vector2, b: Vector2) -> float {
    return (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y);
}

triangle_area :: (t: Triangle) -> float {
    return abs(cross_z(t.b - t.a, t.c - t.a)) * 0.5;
}

cross_z :: (a: Vector2, b: Vector2) -> float {
    return a.x * b.y - a.y * b.x;
}

triangle_bounds :: (t: Triangle) -> Rect {
    x := min(t.a.x, min(t.b.x, t.c.x));
    y := min(t.a.y, min(t.b.y, t.c.y));
    w := max(t.a.x, max(t.b.x, t.c.x)) - x;
    h := max(t.a.y, max(t.b.y, t.c.y)) - y;
    return .{ x, y, w, h };
}

triangle_transform :: (t: Triangle, m: Matrix3x2) -> Triangle {
    return .{
        vector2_transform(t.a, m),
        vector2_transform(t.b, m),
        vector2_transform(t.c, m),
    };
}

triangle_centroid :: (t: Triangle) -> Vector2 {
    return (t.a + t.b + t.c) / 3.0;
}

//
// Quad
//

Quad :: struct {
    a, b, c, d: Vector2;
}

quad_bounds :: (q: Quad) -> Rect {
    x := min(q.a.x, min(q.b.x, min(q.c.x, q.d.x)));
    y := min(q.a.y, min(q.b.y, min(q.c.y, q.d.y)));
    w := max(q.a.x, max(q.b.x, max(q.c.x, q.d.x))) - x;
    h := max(q.a.y, max(q.b.y, max(q.c.y, q.d.y))) - y;
    return .{ x, y, w, h };
}

quad_center :: (q: Quad) -> Vector2 {
    return (q.a + q.b + q.c + q.d) / 4.0;
}

quad_transform :: (q: Quad, m: Matrix3x2) -> Quad {
    return .{
        vector2_transform(q.a, m),
        vector2_transform(q.b, m),
        vector2_transform(q.c, m),
        vector2_transform(q.d, m),
    };
}

//
// ConvexPolygon (max 32 vertices, fan triangulation)
//

CONVEX_POLYGON_MAX :: 32;

Convex_Polygon :: struct {
    points: [CONVEX_POLYGON_MAX] Vector2;
    count:  s32;
}

convex_polygon_clear :: (p: *Convex_Polygon) { p.count = 0; }
convex_polygon_add :: (p: *Convex_Polygon, v: Vector2) {
    assert(p.count < CONVEX_POLYGON_MAX);
    p.points[p.count] = v;
    p.count += 1;
}

convex_polygon_get_point :: (p: Convex_Polygon, index: s32) -> Vector2 {
    return p.points[(index % p.count + p.count) % p.count];
}

convex_polygon_get_axis :: (p: Convex_Polygon, index: s32) -> Vector2 {
    a := convex_polygon_get_point(p, index);
    b := convex_polygon_get_point(p, index + 1);
    edge := b - a;
    return .{ -edge.y, edge.x };
}

convex_polygon_contains :: (p: Convex_Polygon, v: Vector2) -> bool {
    if p.count < 3 return false;
    total: float = 0;
    for i: 0..p.count-1 {
        a := convex_polygon_get_point(p, i);
        b := convex_polygon_get_point(p, i + 1);
        total += cross_z(b - a, v - a);
    }
    // winding sum: consistent sign means inside (Calc.Orient approach)
    return total != 0 && (total > 0) == (cross_z(convex_polygon_get_point(p, 1) - p.points[0], convex_polygon_get_point(p, 2) - p.points[0]) > 0);
}

convex_polygon_project :: (p: Convex_Polygon, axis: Vector2) -> float, float {
    min_v: float = 3.4e38;
    max_v: float = -3.4e38;
    for i: 0..p.count-1 {
        v := dot(p.points[i], axis);
        if v < min_v min_v = v;
        if v > max_v max_v = v;
    }
    return min_v, max_v;
}

convex_polygon_transform :: (p: Convex_Polygon, m: Matrix3x2, maintain_winding := true) -> Convex_Polygon {
    out: Convex_Polygon;
    for i: 0..p.count-1 convex_polygon_add(*out, vector2_transform(p.points[i], m));
    // winding is maintained for rotations/translations/uniform scales; reflection flips it
    return out;
}

convex_polygon_create_hull :: (points: [] Vector2) -> Convex_Polygon {
    // Andrew monotone chain
    if points.count < 3 {
        out: Convex_Polygon;
        for p: points convex_polygon_add(*out, p);
        return out;
    }

    pts: [..] Vector2;
    for p: points array_add(*pts, p);

    // sort by x then y
    for i: 1..(pts.count - 1) {
        key := pts[i];
        j := i - 1;
        while j >= 0 && (pts[j].x > key.x || (pts[j].x == key.x && pts[j].y > key.y)) {
            pts[j + 1] = pts[j];
            j -= 1;
        }
        pts[j + 1] = key;
    }

    // dedupe
    unique: [..] Vector2;
    for p: pts {
        if unique.count == 0 || unique[unique.count - 1] != p {
            array_add(*unique, p);
        }
    }

    if unique.count < 3 {
        out: Convex_Polygon;
        for p: unique convex_polygon_add(*out, p);
        return unique_hull_result(out);
    }

    hull: [..] Vector2;
    // lower
    for p: unique {
        while hull.count >= 2 && cross_z(hull[hull.count - 1] - hull[hull.count - 2], p - hull[hull.count - 2]) <= 0 {
            hull.count -= 1;
        }
        array_add(*hull, p);
    }
    // upper
    lower_count := hull.count;
    for i: 1..(unique.count - 1) {
        p := unique[unique.count - 1 - i];
        while hull.count > lower_count && cross_z(hull[hull.count - 1] - hull[hull.count - 2], p - hull[hull.count - 2]) <= 0 {
            hull.count -= 1;
        }
        array_add(*hull, p);
    }
    hull.count -= 1;   // last point == first

    out: Convex_Polygon;
    for p: hull convex_polygon_add(*out, p);
    return unique_hull_result(out);
}

unique_hull_result :: (p: Convex_Polygon) -> Convex_Polygon { return p; }

//
// Polygon (concave, triangulated via ear clipping)
//

Polygon :: struct {
    points: [..] Vector2;
    bounds: Rect;
    triangles: [..] Triangle;
    triangles_dirty: bool = true;
    bounds_dirty: bool = true;
}

polygon_destroy :: (p: *Polygon) {
    p.points.count = 0;
    p.triangles.count = 0;
}

polygon_add :: (p: *Polygon, v: Vector2) {
    array_add(*p.points, v);
    p.triangles_dirty = true;
    p.bounds_dirty = true;
}

polygon_clear :: (p: *Polygon) {
    p.points.count = 0;
    p.triangles_dirty = true;
    p.bounds_dirty = true;
}

polygon_get_bounds :: (p: *Polygon) -> Rect {
    if p.bounds_dirty {
        if p.points.count == 0 {
            p.bounds = Rect_Empty;
        } else {
            min_x := p.points[0].x; max_x := p.points[0].x;
            min_y := p.points[0].y; max_y := p.points[0].y;
            for pt: p.points {
                if pt.x < min_x min_x = pt.x;
                if pt.x > max_x max_x = pt.x;
                if pt.y < min_y min_y = pt.y;
                if pt.y > max_y max_y = pt.y;
            }
            p.bounds = .{ min_x, min_y, max_x - min_x, max_y - min_y };
        }
        p.bounds_dirty = false;
    }
    return p.bounds;
}

polygon_triangulate :: (p: *Polygon) -> [] Triangle {
    if p.triangles_dirty {
        p.triangles.count = 0;
        if p.points.count >= 3 {
            // ear clipping via Calc.Triangulate (index-based)
            indices := calc_triangulate(p.points);
            for i: 0..(indices.count / 3 - 1) {
                array_add(*p.triangles, Triangle.{
                    p.points[indices[i * 3 + 0]],
                    p.points[indices[i * 3 + 1]],
                    p.points[indices[i * 3 + 2]],
                });
            }
            indices.count = 0;
        }
        p.triangles_dirty = false;
    }
    return p.triangles;
}

polygon_contains :: (p: *Polygon, v: Vector2) -> bool {
    tris := polygon_triangulate(p);
    for t: tris {
        if triangle_contains(t.a, t.b, t.c, v) return true;
    }
    return false;
}

polygon_overlaps :: (p: *Polygon, other: *Polygon) -> bool {
    tris_a := polygon_triangulate(p);
    tris_b := polygon_triangulate(other);
    for a: tris_a {
        if polygon_contains(other, a.a) || polygon_contains(other, a.b) || polygon_contains(other, a.c) return true;
    }
    for b: tris_b {
        if polygon_contains(p, b.a) || polygon_contains(p, b.b) || polygon_contains(p, b.c) return true;
    }
    return false;
}

polygon_area :: (p: *Polygon) -> float {
    total := 0.0;
    tris := polygon_triangulate(p);
    for t: tris total += triangle_area(t);
    return total;
}

//
// Transform (position/rotation/scale with lazy matrix)
//

Transform :: struct {
    position: Vector2;
    scale:    Vector2 = .{ 1, 1 };
    rotation: float;

    matrix_dirty: bool = true;
    matrix: Matrix3x2;
    matrix_inverse: Matrix3x2;
    index: s32;
}

transform_set_position :: (t: *Transform, position: Vector2) {
    if t.position != position { t.position = position; t.matrix_dirty = true; }
}

transform_set_scale :: (t: *Transform, scale: Vector2) {
    if t.scale != scale { t.scale = scale; t.matrix_dirty = true; }
}

transform_set_rotation :: (t: *Transform, rotation: float) {
    if t.rotation != rotation { t.rotation = rotation; t.matrix_dirty = true; }
}

transform_matrix :: (t: *Transform) -> Matrix3x2 {
    if t.matrix_dirty {
        t.matrix = matrix3x2_create_transform(t.position, .{ 0, 0 }, t.scale, t.rotation);
        inv_x := ifx t.scale.x != 0 then 1 / t.scale.x else 0;
        inv_y := ifx t.scale.y != 0 then 1 / t.scale.y else 0;
        inv_scale := Vector2.{ inv_x, inv_y };
        t.matrix_inverse = matrix3x2_create_transform(
            vector2_transform(-t.position * inv_scale, matrix3x2_create_rotation(-t.rotation)),
            .{ 0, 0 }, inv_scale, -t.rotation);
        t.matrix_dirty = false;
    }
    return t.matrix;
}

transform_matrix_inverse :: (t: *Transform) -> Matrix3x2 {
    if t.matrix_dirty transform_matrix(t);
    return t.matrix_inverse;
}

transform_apply :: (t: Transform, v: Vector2) -> Vector2 {
    m := transform_matrix(*t);
    return vector2_transform(v, m);
}

//
// Cardinal
//

Cardinal :: enum u32 {
    RIGHT :: 0;
    DOWN;
    LEFT;
    UP;
}

CARDINAL_ALL :: Cardinal.[ .RIGHT, .DOWN, .LEFT, .UP ];

cardinal_reverse :: (c: Cardinal) -> Cardinal {
    return cast(Cardinal) ((cast(u32) c + 2) % 4);
}

cardinal_turn_left :: (c: Cardinal) -> Cardinal {
    return cast(Cardinal) ((cast(u32) c + 3) % 4);
}

cardinal_turn_right :: (c: Cardinal) -> Cardinal {
    return cast(Cardinal) ((cast(u32) c + 1) % 4);
}

cardinal_is_horizontal :: (c: Cardinal) -> bool { return cast(u32) c % 2 == 0; }
cardinal_is_vertical   :: (c: Cardinal) -> bool { return cast(u32) c % 2 == 1; }

cardinal_point :: (c: Cardinal) -> Point2 {
    if c == {
        case .RIGHT; return .{  1,  0 };
        case .DOWN;  return .{  0,  1 };
        case .LEFT;  return .{ -1,  0 };
        case .UP;    return .{  0, -1 };
    }
    return .{ 0, 0 };
}

cardinal_normal :: (c: Cardinal) -> Vector2 {
    p := cardinal_point(c);
    return .{ cast(float) p.x, cast(float) p.y };
}

cardinal_angle :: (c: Cardinal) -> float {
    return cast(float) cast(u32) c * (PI / 2.0);
}

//
// Signs (binary +/-)
//

Signs :: struct {
    // default = positive; stored as "negative" flag
    neg: bool = false;
}

signs_as_int :: (s: Signs) -> s32 {
    if s.neg return -1;
    return 1;
}
signs_negate :: (s: *Signs) { s.neg = !s.neg; }

signs_from_int :: (v: s32) -> Signs {
    return .{ neg = v < 0 };
}

signs_from_float :: (v: float, if_zero := false) -> Signs {
    if v > 0 return .{ neg = false };
    if v < 0 return .{ neg = true };
    return .{ neg = if_zero };
}

SIGNS_POSITIVE :: Signs.{ neg = false };
SIGNS_NEGATIVE :: Signs.{ neg = true };
