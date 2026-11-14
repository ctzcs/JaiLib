// world:camera3d —— 透视相机（对位 DragonLib World.Camera3D）。
//
// look-at 右手系（看 -Z）、垂直 FOV、D3D 深度 [0,1]，矩阵惰性重建。
// 直接 3D 渲染用；约定细节见 matrix4.jai 的包文档。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   | olib (Odin)                        | JaiLib (Jai)                                        |
//   | foster.Vec3 / foster.Vec2          | Vec3 / Vec2（matrix4.jai 里的 Math 类型别名）        |
//   | foster.Point2（s32 x, y）          | jfoster Point2（`F.Point2`，字段 .x/.y，s32）        |
//   | foster.Vec3{0, 2, 8}               | Vec3.{ 0, 2, 8 }                                    |
//   | viewport_w, viewport_h: int        | s32（Point2 的字段是 s32；Jai 没有 Odin 的 int）      |
//   | cam^ = {...}                       | cam.* = .{...}                                      |
//   | math.PI / 3、16.0 / 9.0（f64）     | cast(float32) (JM.PI64 / 3)、(16.0 / 9.0)         |
//   | cam.position != position           | !vec3_equal(cam.position, position)（Jai 结构体要显式比较） |
//   | `return {}, false`                 | `return zero_ray3d(), false`（见 ray3d.jai）         |
//   | `if !ok do return`                 | `if !ok return`（Jai 没有 do）                       |
#import "Basic";

//@region 类型与初始化

Camera3D :: struct {
    position: Vec3;
    target: Vec3;
    up: Vec3;

    field_of_view: float32; // 垂直 FOV（弧度）
    near_clip: float32;
    far_clip: float32;
    viewport_size: F.Point2;

    aspect_ratio: float32;

    dirty: bool;
    view: Matrix4;
    projection: Matrix4;
    view_projection: Matrix4;
}

camera3d_init :: (cam: *Camera3D, viewport_w: s32, viewport_h: s32) {
    cam.* = .{
        position = Vec3.{ 0, 2, 8 },
        target = Vec3.{ 0, 0, 0 },
        up = Vec3.{ 0, 1, 0 },
        field_of_view = cast(float32) (JM.PI64 / 3),
        near_clip = 0.05,
        far_clip = 250,
        viewport_size = F.Point2.{ viewport_w, viewport_h },
        aspect_ratio = cast(float32) (16.0 / 9.0),
        dirty = true,
    };
}
//@endregion

//@region 设值 —— 值变化才弄脏

camera3d_set_position :: (cam: *Camera3D, position: Vec3) {
    if !vec3_equal(cam.position, position) {
        cam.position = position;
        cam.dirty = true;
    }
}

camera3d_set_target :: (cam: *Camera3D, target: Vec3) {
    if !vec3_equal(cam.target, target) {
        cam.target = target;
        cam.dirty = true;
    }
}

camera3d_set_up :: (cam: *Camera3D, up: Vec3) {
    if !vec3_equal(cam.up, up) {
        cam.up = up;
        cam.dirty = true;
    }
}

camera3d_set_field_of_view :: (cam: *Camera3D, radians: float32) {
    if cam.field_of_view != radians {
        cam.field_of_view = radians;
        cam.dirty = true;
    }
}

camera3d_set_near_clip :: (cam: *Camera3D, near: float32) {
    if cam.near_clip != near {
        cam.near_clip = near;
        cam.dirty = true;
    }
}

camera3d_set_far_clip :: (cam: *Camera3D, far: float32) {
    if cam.far_clip != far {
        cam.far_clip = far;
        cam.dirty = true;
    }
}

camera3d_set_viewport :: (cam: *Camera3D, w: s32, h: s32) {
    if cam.viewport_size.x != w || cam.viewport_size.y != h {
        cam.viewport_size = F.Point2.{ w, h };
        cam.dirty = true;
    }
}
//@endregion

//@region 矩阵与派生量

// 状态变化时重建矩阵；视口无效（<=0）时保持原状。每帧调用也无所谓。
camera3d_update :: (cam: *Camera3D) {
    if cam.viewport_size.x <= 0 || cam.viewport_size.y <= 0 return;
    if !cam.dirty return;

    cam.aspect_ratio = cast(float32) cam.viewport_size.x / cast(float32) cam.viewport_size.y;
    cam.view = matrix4_look_at(cam.position, cam.target, cam.up);
    cam.projection = matrix4_perspective_fov(cam.field_of_view, cam.aspect_ratio, cam.near_clip, cam.far_clip);
    cam.view_projection = matrix4_multiply(cam.view, cam.projection);
    cam.dirty = false;
}

camera3d_view :: (cam: *Camera3D) -> Matrix4 {
    camera3d_update(cam);
    return cam.view;
}

camera3d_projection :: (cam: *Camera3D) -> Matrix4 {
    camera3d_update(cam);
    return cam.projection;
}

camera3d_view_projection :: (cam: *Camera3D) -> Matrix4 {
    camera3d_update(cam);
    return cam.view_projection;
}

// 单位前向（position -> target）；退化时返回 -Z。
camera3d_forward :: (cam: *Camera3D) -> Vec3 {
    direction := v3_sub(cam.target, cam.position);
    if v3_dot(direction, direction) <= cast(float32) 1.0e-8 {
        return Vec3.{ 0, 0, -1 };
    }
    return v3_normalize(direction);
}

camera3d_right :: (cam: *Camera3D) -> Vec3 {
    return v3_normalize(v3_cross(camera3d_forward(cam), cam.up));
}
//@endregion

//@region 拾取 —— 视锥 / 屏幕点射线

// 由当前 view_projection 提取的视锥（6 平面朝内），供视锥剔除使用。
camera3d_frustum :: (cam: *Camera3D) -> Frustum3D {
    return frustum_from_view_projection(camera3d_view_projection(cam));
}

// 屏幕像素坐标 -> 世界射线（拾取用）。视口无效或矩阵不可逆返回 false。
camera3d_screen_point_to_ray :: (cam: *Camera3D, pixel: Vec2) -> (Ray3D, bool) {
    if cam.viewport_size.x <= 0 || cam.viewport_size.y <= 0 return zero_ray3d(), false;
    inverse, ok := matrix4_inverse(camera3d_view_projection(cam));
    if !ok return zero_ray3d(), false;

    x := pixel.x / cast(float32) cam.viewport_size.x * 2 - 1;
    y := 1 - pixel.y / cast(float32) cam.viewport_size.y * 2;

    near_h := matrix4_transform_vec4(inverse, vec4(x, y, 0, 1));
    far_h := matrix4_transform_vec4(inverse, vec4(x, y, 1, 1));
    if JM.abs(near_h[3]) < cast(float32) 1.0e-8 || JM.abs(far_h[3]) < cast(float32) 1.0e-8 {
        return zero_ray3d(), false;
    }

    a := Vec3.{ near_h[0] / near_h[3], near_h[1] / near_h[3], near_h[2] / near_h[3] };
    b := Vec3.{ far_h[0] / far_h[3], far_h[1] / far_h[3], far_h[2] / far_h[3] };
    return ray3d_make(a, v3_sub(b, a));
}
//@endregion
