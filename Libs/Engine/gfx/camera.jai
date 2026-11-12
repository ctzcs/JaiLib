// camera.jai
// 2D 世界相机（raylib Camera2D 语义）：矩阵压栈 + 屏幕坐标逆变换。

// 2D 世界相机（offset = 世界原点在屏幕上的位置）。
CameraState :: struct {
    offset:   Vector2;
    rotation: float32;
    zoom:     float32;
    target:   Vector2;
}

// jfoster 的 Matrix3x2 operator * 是模块内的（Jai 按词法作用域解析运算符），
// 这用具名过程显式相乘。
matrix_mul :: (a: F.Matrix3x2, b: F.Matrix3x2) -> F.Matrix3x2 {
    return .{
        a.m11 * b.m11 + a.m12 * b.m21,
        a.m11 * b.m12 + a.m12 * b.m22,
        a.m21 * b.m11 + a.m22 * b.m21,
        a.m21 * b.m12 + a.m22 * b.m22,
        a.m31 * b.m11 + a.m32 * b.m21 + b.m31,
        a.m31 * b.m12 + a.m32 * b.m22 + b.m32,
    };
}

// Row vectors apply transforms left to right:
// screen = world * T(-target) * S(zoom) * R(-rot) * T(offset).
camera_matrix :: (camera: CameraState) -> F.Matrix3x2 {
    t_neg := F.matrix3x2_create_translation(-camera.target.x, -camera.target.y);
    s     := F.matrix3x2_create_scale(camera.zoom, camera.zoom);
    r     := F.matrix3x2_create_rotation(-camera.rotation);
    t     := F.matrix3x2_create_translation(camera.offset.x, camera.offset.y);
    return matrix_mul(matrix_mul(matrix_mul(t_neg, s), r), t);
}

BeginMode2D :: (camera: CameraState) {
    F.batcher_push_matrix(gfx_batcher, camera_matrix(camera), false);
}

EndMode2D :: () {
    F.batcher_pop_matrix(gfx_batcher);
}

// camera_matrix 的逆：world = R(+rot) * ((screen - offset) / zoom) + target
world_mouse_pos :: (mouse: Vector2, camera: CameraState) -> Vector2 {
    d := Vector2.{
        x = (mouse.x - camera.offset.x) / camera.zoom,
        y = (mouse.y - camera.offset.y) / camera.zoom,
    };
    c := GM.cos(camera.rotation);
    s := GM.sin(camera.rotation);
    return .{
        x = camera.target.x + d.x * c - d.y * s,
        y = camera.target.y + d.x * s + d.y * c,
    };
}
