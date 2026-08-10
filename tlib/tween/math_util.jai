// math_util.jai
// Thin wrapper around the Math module so its Vector2 type never leaks into
// the global namespace (Jai's #import is not transitive and Math defines its
// own Vector2 which would clash with raylib's).

M :: #import "Math";

math_floor :: (x: float32) -> float32 { return M.floor(x); }
math_sin   :: (x: float32) -> float32 { return M.sin(x); }
math_cos   :: (x: float32) -> float32 { return M.cos(x); }
math_pow   :: (x: float32, p: float32) -> float32 { return M.pow(x, p); }
math_abs   :: (x: float32) -> float32 { return M.abs(x); }
math_atan2 :: (y: float32, x: float32) -> float32 { return M.atan2(y, x); }
