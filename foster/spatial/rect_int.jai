#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Spatial/RectInt.cs (core subset; completed in M6).

Rect_Int :: struct {
    x, y, w, h: s32;
}

Rect_Int_Empty :: Rect_Int.{ 0, 0, 0, 0 };

rect_int_position :: (r: Rect_Int) -> Point2 {
    return .{ r.x, r.y };
}

rect_int_size :: (r: Rect_Int) -> Point2 {
    return .{ r.w, r.h };
}

rect_int_left :: (r: Rect_Int) -> s32 {
    return r.x;
}

rect_int_right :: (r: Rect_Int) -> s32 {
    return r.x + r.w;
}

rect_int_top :: (r: Rect_Int) -> s32 {
    return r.y;
}

rect_int_bottom :: (r: Rect_Int) -> s32 {
    return r.y + r.h;
}

rect_int_center :: (r: Rect_Int) -> Point2 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

rect_int_top_left :: (r: Rect_Int) -> Point2 {
    return .{ r.x, r.y };
}

rect_int_top_right :: (r: Rect_Int) -> Point2 {
    return .{ r.x + r.w, r.y };
}

rect_int_bottom_left :: (r: Rect_Int) -> Point2 {
    return .{ r.x, r.y + r.h };
}

rect_int_bottom_right :: (r: Rect_Int) -> Point2 {
    return .{ r.x + r.w, r.y + r.h };
}

rect_int_is_empty :: (r: Rect_Int) -> bool {
    return r.w == 0 && r.h == 0;
}

rect_int_contains :: (r: Rect_Int, px: s32, py: s32) -> bool {
    return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
}

rect_int_contains_point :: (r: Rect_Int, p: Point2) -> bool {
    return rect_int_contains(r, p.x, p.y);
}

rect_int_overlaps :: (a: Rect_Int, b: Rect_Int) -> bool {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

rect_int_get_intersection :: (a: Rect_Int, b: Rect_Int) -> Rect_Int {
    x1 := max(a.x, b.x);
    y1 := max(a.y, b.y);
    x2 := min(a.x + a.w, b.x + b.w);
    y2 := min(a.y + a.h, b.y + b.h);
    if x2 < x1 || y2 < y1 return Rect_Int_Empty;
    return .{ x1, y1, x2 - x1, y2 - y1 };
}

operator == :: (a: Rect_Int, b: Rect_Int) -> bool {
    return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

operator != :: (a: Rect_Int, b: Rect_Int) -> bool {
    return !(a == b);
}
