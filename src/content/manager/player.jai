// manager/player.jai — 玩家管理器（斩击线）
// （原 managers.jai 拆分：Player_Manager + player_manager_*）

#import "Basic";
#import "bindings/raylib";
#import "content/entity/player";
#import "content/game";
#import "content/core/utils";

Player_Manager :: struct {
    player: Player;
}

player_manager_init :: (pm: *Player_Manager, hit_radius: float32, max_age: float32) {
    <<pm = .{ player = Player.{ slash = .{ hit_radius = hit_radius, max_age = max_age } } };
}

player_manager_destroy :: (pm: *Player_Manager) {
    array_free(pm.player.slash.points);
}

player_manager_clear_slash :: (pm: *Player_Manager) {
    clear_player_slash(*pm.player.slash);
}

// Only samples and ages the slash line; hit detection is orchestrated in
// game.jai.
player_manager_update :: (pm: *Player_Manager, mouse_world: Vector2, current_time: float32, dt: float32, input_enabled: bool) {
    slash := *pm.player.slash;
    if !input_enabled {
        clear_player_slash(slash);
        return;
    }

    if IsMouseButtonPressed(.LEFT) {
        clear_player_slash(slash);
        slash.active = true;
        append_slash_point(slash, mouse_world, current_time);
    }

    if IsMouseButtonDown(.LEFT) {
        slash.active = true;
        append_slash_point(slash, mouse_world, current_time);
    }

    if IsMouseButtonReleased(.LEFT) {
        slash.active = false;
    }

    slash.age += dt;
    keep_from := 0;
    i := 0;
    while i < slash.points.count {
        if current_time - slash.points[cast(s64) i].time <= slash.max_age {
            keep_from = i;
            break;
        }
        keep_from = i + 1;
        i += 1;
    }
    if keep_from > 0 && keep_from <= slash.points.count {
        compact_slash_points(*slash.points, keep_from);
    }
}

player_manager_draw_slash :: (pm: *Player_Manager, current_time: float32) {
    points := pm.player.slash.points;
    if points.count < 2 {
        return;
    }

    i := 1;
    while i < points.count {
        a := points[cast(s64) i - 1];
        b := points[cast(s64) i];
        age_ratio := 1.0 - clamp01((current_time - a.time) / pm.player.slash.max_age);
        if age_ratio > 0 {
            color := color_with_alpha(SKYBLUE, age_ratio);
            DrawLineEx(a.pos, b.pos, 8 * age_ratio + 2, color);
        }
        i += 1;
    }
}
