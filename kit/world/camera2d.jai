// world —— 相机与屏幕路由（对位 DragonLib Engine.World 的 2D 部分）。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   | olib (Odin)                          | JaiLib (Jai)                                        |
//   | foster.Vec2                          | Vec2（= Math.Vector2 别名，.x/.y）                   |
//   | foster.Vec2{x, y}                    | Vec2.{ x, y }                                       |
//   | foster.Point2（s32 x, y）            | jfoster Point2（`F.Point2`，字段 .x/.y）             |
//   | foster.Matrix3x2                     | jfoster Matrix3x2（`F.Matrix3x2`，字段 m11..m32）    |
//   | Matrix3x2Translation(x, y)           | F.matrix3x2_create_translation(x, y)                |
//   | Matrix3x2Rotation(radians)           | F.matrix3x2_create_rotation(radians)                |
//   | Matrix3x2Scaling(x, y)               | F.matrix3x2_create_scale(x, y)                      |
//   | Matrix3x2TransformPoint(m, p)        | F.vector2_transform(p, m)（注意实参顺序相反）        |
//   | Matrix3x2Multiply(a, b)              | camera2d_matrix3x2_multiply（jfoster 的 operator *  |
//   |                                      | 只在 jfoster 模块内可见，这里照抄同一公式）          |
//   | Matrix3x2Inverse(m) -> (m, bool)     | camera2d_matrix3x2_inverse（jfoster 没有对应过程，   |
//   |                                      | 按 foster spatial.odin 的 det<=1.0e-8 语义补齐）       |
//   | viewport_w, viewport_h: int          | s32（Point2 的字段是 s32，Jai 无 Odin 的 int）        |
//   | cam.position != position             | !vec2_equal(cam.position, position)（结构体要显式比较）|
//   | cam^ = {...}                         | cam.* = .{...}                                      |
#import "Basic";

// jfoster 的 `operator ==` 只在其自身模块内可见（Jai 运算符按词法作用域解析），
// 这里按仓库惯例用具名过程重声明，供本包与调用方比较缓存矩阵。
matrix3x2_equal :: (a: F.Matrix3x2, b: F.Matrix3x2) -> bool {
    return a.m11 == b.m11 && a.m12 == b.m12 &&
           a.m21 == b.m21 && a.m22 == b.m22 &&
           a.m31 == b.m31 && a.m32 == b.m32;
}

//@region Camera2D —— 屏幕空间 = 相机空间、y 向下的 2D 相机

// Camera2D 组合：World →(平移 -position)→(旋转 rotation)→(缩放 ppu*zoom)→
// (平移 viewport/2)→ Screen。矩阵惰性重建；直接改字段后请调 camera2d_set_dirty，
// 或一律使用 camera2d_set_* 设值（值未变化不会弄脏矩阵）。
Camera2D :: struct {
    position:      Vec2;      // 相机中心（世界单位）
    zoom:          float32;      // 相对 ppu 的额外缩放
    rotation:      float32;      // 弧度
    ppu:           float32;      // pixels per unit（32 = 一个世界单位 32 像素）
    viewport_size: F.Point2;     // 像素

    dirty:          bool;
    cached_matrix:  F.Matrix3x2;
    cached_inverse: F.Matrix3x2;
    inverse_ok:     bool;
}

// 初始化。zoom=1、ppu=32、相机在原点。之后每帧用 camera2d_set_viewport
// 同步窗口尺寸（值没变不会弄脏矩阵）。
camera2d_init :: (cam: *Camera2D, viewport_w: s32, viewport_h: s32) {
    cam.* = .{
        zoom          = 1,
        ppu           = 32,
        viewport_size = F.Point2.{ viewport_w, viewport_h },
        dirty         = true,
    };
}

camera2d_set_dirty :: (cam: *Camera2D) {
    cam.dirty = true;
}

camera2d_set_position :: (cam: *Camera2D, position: Vec2) {
    if !vec2_equal(cam.position, position) {
        cam.position = position;
        cam.dirty = true;
    }
}

camera2d_set_zoom :: (cam: *Camera2D, zoom: float32) {
    if cam.zoom != zoom {
        cam.zoom = zoom;
        cam.dirty = true;
    }
}

camera2d_set_rotation :: (cam: *Camera2D, radians: float32) {
    if cam.rotation != radians {
        cam.rotation = radians;
        cam.dirty = true;
    }
}

camera2d_set_ppu :: (cam: *Camera2D, ppu: float32) {
    if cam.ppu != ppu {
        cam.ppu = ppu;
        cam.dirty = true;
    }
}

camera2d_set_viewport :: (cam: *Camera2D, w: s32, h: s32) {
    if cam.viewport_size.x != w || cam.viewport_size.y != h {
        cam.viewport_size = F.Point2.{ w, h };
        cam.dirty = true;
    }
}

// 状态变化时重建矩阵/逆矩阵；无变化是空操作。每帧调用也无所谓。
camera2d_update :: (cam: *Camera2D) {
    if !cam.dirty return;

    // World -> View -> Screen（行向量约定：左结合 = 先应用）
    world_to_view := camera2d_matrix3x2_multiply(
        F.matrix3x2_create_translation(-cam.position.x, -cam.position.y),
        F.matrix3x2_create_rotation(cam.rotation),
    );
    scaled := cam.ppu * cam.zoom;
    view_to_screen := camera2d_matrix3x2_multiply(
        F.matrix3x2_create_scale(scaled, scaled),
        F.matrix3x2_create_translation(
            cast(float32) cam.viewport_size.x * 0.5, cast(float32) cam.viewport_size.y * 0.5,
        ),
    );
    cam.cached_matrix = camera2d_matrix3x2_multiply(world_to_view, view_to_screen);
    inverse, ok := camera2d_matrix3x2_inverse(cam.cached_matrix);
    cam.cached_inverse = inverse;
    cam.inverse_ok = ok;
    cam.dirty = false;
}

// 世界→屏幕矩阵（惰性更新）。
camera2d_matrix :: (cam: *Camera2D) -> F.Matrix3x2 {
    camera2d_update(cam);
    return cam.cached_matrix;
}

camera2d_world_to_screen :: (cam: *Camera2D, world: Vec2) -> Vec2 {
    return F.vector2_transform(world, camera2d_matrix(cam));
}

// 屏幕→世界。矩阵不可逆（如 zoom=0）返回 false。
camera2d_screen_to_world :: (cam: *Camera2D, screen: Vec2) -> (Vec2, bool) {
    camera2d_update(cam);
    if !cam.inverse_ok return Vec2.{ 0, 0 }, false;
    return F.vector2_transform(screen, cam.cached_inverse), true;
}
//@endregion

//@region 内部 —— Matrix3x2 桥接

// olib 的 foster.Matrix3x2Multiply（与 System.Numerics 的 Matrix3x2.Multiply 一致）。
// jfoster 的 operator * 是模块内可见的，这里用具名过程显式相乘，公式完全相同。
camera2d_matrix3x2_multiply :: (a: F.Matrix3x2, b: F.Matrix3x2) -> F.Matrix3x2 {
    return F.Matrix3x2.{
        a.m11 * b.m11 + a.m12 * b.m21,
        a.m11 * b.m12 + a.m12 * b.m22,
        a.m21 * b.m11 + a.m22 * b.m21,
        a.m21 * b.m12 + a.m22 * b.m22,
        a.m31 * b.m11 + a.m32 * b.m21 + b.m31,
        a.m31 * b.m12 + a.m32 * b.m22 + b.m32,
    };
}

// olib 的 foster.Matrix3x2Inverse：行列式绝对值 <= 1.0e-8 视为不可逆，
// 失败时返回单位阵 + false（foster spatial.odin 的语义）。
camera2d_matrix3x2_inverse :: (m: F.Matrix3x2) -> (F.Matrix3x2, bool) {
    determinant := m.m11 * m.m22 - m.m12 * m.m21;
    if JM.abs(determinant) <= cast(float32) 1.0e-8 {
        return F.Matrix3x2_Identity, false;
    }
    inv := 1 / determinant;
    result := F.Matrix3x2.{
        m11 = m.m22 * inv,
        m12 = -m.m12 * inv,
        m21 = -m.m21 * inv,
        m22 = m.m11 * inv,
    };
    result.m31 = -(m.m31 * result.m11 + m.m32 * result.m21);
    result.m32 = -(m.m31 * result.m12 + m.m32 * result.m22);
    return result, true;
}
//@endregion
