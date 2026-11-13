#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Spatial/Rect.cs (core subset; completed in M6).

Rect :: struct {
    x, y: float;
    w, h: float;
}

Rect_Empty :: Rect.{ 0, 0, 0, 0 };

rect_position :: (r: Rect) -> Vector2 { return .{ r.x, r.y }; }
rect_size     :: (r: Rect) -> Vector2 { return .{ r.w, r.h }; }

rect_left   :: (r: Rect) -> float { return r.x; }
rect_right  :: (r: Rect) -> float { return r.x + r.w; }
rect_top    :: (r: Rect) -> float { return r.y; }
rect_bottom :: (r: Rect) -> float { return r.y + r.h; }

rect_center  :: (r: Rect) -> Vector2 { return .{ r.x + r.w / 2, r.y + r.h / 2 }; }
rect_top_left     :: (r: Rect) -> Vector2 { return .{ r.x, r.y }; }
rect_top_right    :: (r: Rect) -> Vector2 { return .{ r.x + r.w, r.y }; }
rect_bottom_left  :: (r: Rect) -> Vector2 { return .{ r.x, r.y + r.h }; }
rect_bottom_right :: (r: Rect) -> Vector2 { return .{ r.x + r.w, r.y + r.h }; }

rect_is_empty :: (r: Rect) -> bool { return r.w == 0 && r.h == 0; }

rect_contains :: (r: Rect, px: float, py: float) -> bool {
    return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
}

rect_contains_point :: (r: Rect, p: Vector2) -> bool {
    return rect_contains(r, p.x, p.y);
}

rect_overlaps :: (a: Rect, b: Rect) -> bool {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

rect_get_intersection :: (a: Rect, b: Rect) -> Rect {
    x1 := max(a.x, b.x);
    y1 := max(a.y, b.y);
    x2 := min(a.x + a.w, b.x + b.w);
    y2 := min(a.y + a.h, b.y + b.h);
    if x2 < x1 || y2 < y1 return Rect_Empty;
    return .{ x1, y1, x2 - x1, y2 - y1 };
}

operator == :: (a: Rect, b: Rect) -> bool { return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h; }
operator != :: (a: Rect, b: Rect) -> bool { return !(a == b); }
operator + :: (a: Rect, b: Vector2) -> Rect { return .{ a.x + b.x, a.y + b.y, a.w, a.h }; }
operator - :: (a: Rect, b: Vector2) -> Rect { return .{ a.x - b.x, a.y - b.y, a.w, a.h }; }
