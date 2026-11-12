#import "Basic";
#import "test_support";
#import "demo_console";
F :: #import "jfoster";
GM :: #import "Math";
Vector2 :: GM.Vector2;
// Test the CPU camera functions without initializing gfx or a GPU.
#load "../Libs/Engine/gfx/camera.jai";

gfx_batcher: *F.Batcher;

near :: (a: Vector2, b: Vector2) -> bool {
    return GM.abs(a.x - b.x) < 0.002 && GM.abs(a.y - b.y) < 0.002;
}

main :: () {
    st := test_begin();
    for angle: float32.[0, 0.7, -1.2] {
        for scale: float32.[1, 2.3, 0.6] {
            cam := CameraState.{ offset = .{320, 180}, target = .{12, -8}, rotation = angle, zoom = scale };
            matrix := camera_matrix(cam);
            expect(*st, near(F.vector2_transform(cam.target, matrix), cam.offset), "camera target maps to viewport center");
            for point: Vector2.[.{0, 0}, .{17, -3}, .{-8, 13}] {
                screen := F.vector2_transform(point, matrix);
                expect(*st, near(world_mouse_pos(screen, cam), point), "screen/world round trip");
            }
        }
    }
    for angle: float32.[0, 0.7, -1.2] {
        for scale: Vector2.[.{1, 1}, .{2.3, 0.6}, .{-1, 2}] {
            origin := Vector2.{12, -8}; position := Vector2.{320, 180};
            transform := F.matrix3x2_create_transform(position, origin, scale, angle);
            expect(*st, near(F.vector2_transform(origin, transform), position), "TRS maps pivot to position even with rotation/nonuniform scale");
        }
    }
    demo_console_finish(test_summary("camera", *st));
}
