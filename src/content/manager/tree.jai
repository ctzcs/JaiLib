// manager/tree.jai — 圣树管理器
// （原 managers.jai 拆分：Tree_Manager + tree_manager_*）

#import "Basic";
#import "bindings/raylib";
#import "content/entity/round";
#import "content/core/const";
#import "content/core/utils";
#import "tween/manager";

Tree_Manager :: struct {
    state: Tree_State;
}

tree_manager_init :: (tm: *Tree_Manager, pos: Vector2) {
    <<tm = .{ state = .{ pos = pos, canopy_scale = 1.0, glow_alpha = 0.0, shake_x = 0.0, burst_handle = TWEEN_HANDLE_NONE } };
}

tree_manager_tick_cooldown :: (tm: *Tree_Manager, dt: float32) {
    tm.state.cooldown -= dt;
}

tree_manager_draw :: (tm: *Tree_Manager) {
    trunk_x := tm.state.pos.x - 34 + tm.state.shake_x;
    trunk_top := tm.state.pos.y + 52;
    trunk_h := GROUND_Y - trunk_top;

    DrawRectangleRounded(
        Rectangle.{ x = trunk_x, y = trunk_top, width = 68, height = trunk_h },
        0.22,
        12,
        Color.{ r = 95, g = 61, b = 41, a = 255 },
    );

    glow_color := color_with_alpha(Color.{ r = 255, g = 240, b = 150, a = 255 }, tm.state.glow_alpha * 0.5);
    if glow_color.a > 0 {
        DrawCircleV(Vector2.{ x = tm.state.pos.x + tm.state.shake_x, y = tm.state.pos.y - 16 }, 124 * tm.state.canopy_scale, glow_color);
    }

    DrawCircleV(Vector2.{ x = tm.state.pos.x + tm.state.shake_x, y = tm.state.pos.y - 10 }, 94 * tm.state.canopy_scale, Color.{ r = 58, g = 120, b = 70, a = 255 });
    DrawCircleV(Vector2.{ x = tm.state.pos.x + tm.state.shake_x - 44, y = tm.state.pos.y + 8 }, 58 * tm.state.canopy_scale, Color.{ r = 72, g = 150, b = 86, a = 255 });
    DrawCircleV(Vector2.{ x = tm.state.pos.x + tm.state.shake_x + 46, y = tm.state.pos.y + 4 }, 54 * tm.state.canopy_scale, Color.{ r = 82, g = 165, b = 98, a = 255 });
}
