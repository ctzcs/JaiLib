// frame.jai
// Port of Ascension/src/core/frame.odin
// Input snapshot sampled from the window each frame (written by the app,
// read-only for the game).

#import "Basic";
#import "bindings/raylib";

// Per-frame input snapshot.
InputState :: struct {
    mouse_pos:   Vector2;
    mouse_delta: Vector2;
    mouse_wheel: Vector2;
}

// 2D world camera (owned by the game; defined in core for sharing).
CameraState :: struct {
    offset:   Vector2;
    rotation: float32;
    zoom:     float32;
    target:   Vector2;
}

// Read-only frame context passed from the shell to game / editor.
FrameContext :: struct {
    dt:    float32;
    input: InputState;
}

to_camera2d :: (camera: CameraState) -> Camera2D {
    return .{ offset = camera.offset, rotation = camera.rotation, zoom = camera.zoom, target = camera.target };
}

world_mouse_pos :: (input: InputState, camera: CameraState) -> Vector2 {
    return GetScreenToWorld2D(input.mouse_pos, to_camera2d(camera));
}

poll_input :: (input: *InputState) {
    input.mouse_pos = GetMousePosition();
    input.mouse_delta = GetMouseDelta();
    input.mouse_wheel = GetMouseWheelMoveV();
}
