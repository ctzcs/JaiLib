// managers.jai
// Port of Ascension/src/content/managers.odin
// Player (slash), tree, leaf and popup managers.

#import "Basic";
#import "bindings/raylib";
#import "tween/manager";
#import "content/const";
#import "content/defs";
#import "content/entity";
#import "content/utils";
#import "content/game";

pool_swap_remove :: (items: *[..] int, index: int) -> int {
    last_index := items.count - 1;
    removed := (<<items)[cast(s64) index];
    (<<items)[cast(s64) index] = (<<items)[cast(s64) last_index];
    items.count -= 1;
    return removed;
}

// --- Player Manager ---

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

// --- Tree Manager ---

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

// --- Leaf Manager ---

Leaf_Manager :: struct {
    pool: Leaf_Pool;
}

leaf_manager_init :: (lm: *Leaf_Manager) {
    i := MAX_LEAVES - 1;
    while i >= 0 {
        array_add(*lm.pool.free_indices, i);
        i -= 1;
    }
}

leaf_manager_destroy :: (lm: *Leaf_Manager) {
    array_free(lm.pool.active_indices);
    array_free(lm.pool.free_indices);
}

leaf_manager_active_count :: (lm: *Leaf_Manager) -> int {
    return cast(int) lm.pool.active_indices.count;
}

leaf_manager_clear :: (lm: *Leaf_Manager) {
    while lm.pool.active_indices.count > 0 {
        leaf_index := lm.pool.active_indices[lm.pool.active_indices.count - 1];
        leaf_manager_release(lm, *lm.pool.storage[cast(s64) leaf_index]);
    }
}

leaf_manager_release :: (lm: *Leaf_Manager, leaf: *Leaf) {
    if !leaf.active {
        return;
    }

    _ = pool_swap_remove(*lm.pool.active_indices, leaf.active_slot);
    if leaf.active_slot < lm.pool.active_indices.count {
        moved := *lm.pool.storage[cast(s64) lm.pool.active_indices[cast(s64) leaf.active_slot]];
        moved.active_slot = leaf.active_slot;
    }

    array_add(*lm.pool.free_indices, leaf.pool_index);
    <<leaf = Leaf.{};
}

leaf_manager_spawn :: (lm: *Leaf_Manager, pos: Vector2, vel: Vector2, kind: Leaf_Kind, tint: Color, delay: float32) -> bool {
    if lm.pool.free_indices.count == 0 {
        return false;
    }

    leaf_index := lm.pool.free_indices[lm.pool.free_indices.count - 1];
    lm.pool.free_indices.count -= 1;
    leaf := *lm.pool.storage[cast(s64) leaf_index];
    leaf_slot := cast(int) lm.pool.active_indices.count;
    array_add(*lm.pool.active_indices, leaf_index);

    <<leaf = Leaf.{
        active        = true,
        pool_index    = leaf_index,
        active_slot   = leaf_slot,
        kind          = kind,
        state         = .Flying,
        config        = leaf_config_for_kind(kind),
        pos           = pos,
        vel           = vel,
        rotation      = random_range_f32(-30, 30),
        angular_vel   = random_range_f32(-180, 180),
        render_scale  = 0.2,
        render_alpha  = 0,
        tint          = tint,
        spawn_delay   = delay,
        spawn_elapsed = 0,
    };

    return true;
}

leaf_manager_update :: (lm: *Leaf_Manager, dt: float32) {
    i := 0;
    while i < lm.pool.active_indices.count {
        leaf := *lm.pool.storage[cast(s64) lm.pool.active_indices[cast(s64) i]];
        leaf.spawn_elapsed += dt;
        if leaf.spawn_elapsed < leaf.spawn_delay {
            i += 1;
            continue;
        }

        spawn_t := (leaf.spawn_elapsed - leaf.spawn_delay) / 0.28;
        leaf.render_scale = lerp_f32(0.2, 1.0, ease_out_back(spawn_t));
        leaf.render_alpha = lerp_f32(0.0, 1.0, ease_out_cubic((leaf.spawn_elapsed - leaf.spawn_delay) / 0.16));

        if leaf.state == .Flying {
            leaf.vel.y += 340 * dt;
            leaf.pos.x += leaf.vel.x * dt;
            leaf.pos.y += leaf.vel.y * dt;
            leaf.rotation += leaf.angular_vel * dt;
        } else if leaf.state == .Cut {
            leaf.cut_elapsed += dt;
            cut_t := clamp01(leaf.cut_elapsed / leaf.cut_duration);
            leaf.pos = lerp_vec2(leaf.cut_start_pos, leaf.cut_target_pos, ease_out_cubic(cut_t));
            leaf.render_scale = lerp_f32(leaf.cut_start_scale, leaf.cut_target_scale, ease_out_cubic(cut_t));
            leaf.render_alpha = lerp_f32(1.0, 0.0, ease_in_quad(cut_t));
            leaf.rotation += 420 * dt;
            if leaf.render_alpha <= 0.02 {
                leaf_manager_release(lm, leaf);
                continue;
            }
        }

        if leaf.pos.y > GROUND_Y + 120 {
            leaf_manager_release(lm, leaf);
            continue;
        }
        i += 1;
    }
}

leaf_manager_draw :: (lm: *Leaf_Manager, simple_draw: bool) {
    i := 0;
    while i < lm.pool.active_indices.count {
        leaf := lm.pool.storage[cast(s64) lm.pool.active_indices[cast(s64) i]];
        if !leaf.active {
            i += 1;
            continue;
        }

        color := color_with_alpha(leaf.tint, leaf.render_alpha);
        if leaf.kind == .Normal {
            size := Vector2.{
                x = leaf.config.radius * 2.2 * leaf.render_scale,
                y = leaf.config.radius * 1.3 * leaf.render_scale,
            };
            dest := Rectangle.{ x = leaf.pos.x, y = leaf.pos.y, width = size.x, height = size.y };
            origin := Vector2.{ x = size.x * 0.5, y = size.y * 0.5 };
            DrawRectanglePro(dest, origin, leaf.rotation, color);
            if !simple_draw {
                stem_dest := Rectangle.{
                    x = leaf.pos.x,
                    y = leaf.pos.y,
                    width = 4 * leaf.render_scale,
                    height = 14 * leaf.render_scale,
                };
                DrawRectanglePro(
                    stem_dest,
                    Vector2.{ x = 2 * leaf.render_scale, y = 2 * leaf.render_scale },
                    leaf.rotation - 24,
                    color_with_alpha(DARKGREEN, leaf.render_alpha),
                );
            }
        } else if leaf.kind == .Enlightenment_Fruit {
            DrawCircleV(leaf.pos, leaf.config.radius * leaf.render_scale, color);
            if !simple_draw {
                DrawCircleV(
                    Vector2.{ x = leaf.pos.x - leaf.config.radius * 0.24, y = leaf.pos.y - leaf.config.radius * 0.28 },
                    leaf.config.radius * 0.34 * leaf.render_scale,
                    color_with_alpha(WHITE, leaf.render_alpha * 0.35),
                );
            }
        }
        i += 1;
    }
}

// --- Popup Manager ---

Popup_Manager :: struct {
    pool: Popup_Pool;
}

popup_manager_init :: (pm: *Popup_Manager) {
    i := MAX_POPUPS - 1;
    while i >= 0 {
        array_add(*pm.pool.free_indices, i);
        i -= 1;
    }
}

popup_manager_destroy :: (pm: *Popup_Manager) {
    array_free(pm.pool.active_indices);
    array_free(pm.pool.free_indices);
}

popup_manager_clear :: (pm: *Popup_Manager) {
    while pm.pool.active_indices.count > 0 {
        popup_index := pm.pool.active_indices[pm.pool.active_indices.count - 1];
        popup_manager_release(pm, *pm.pool.storage[cast(s64) popup_index]);
    }
}

popup_manager_release :: (pm: *Popup_Manager, popup: *Score_Popup) {
    if !popup.active {
        return;
    }

    _ = pool_swap_remove(*pm.pool.active_indices, popup.active_slot);
    if popup.active_slot < pm.pool.active_indices.count {
        moved := *pm.pool.storage[cast(s64) pm.pool.active_indices[cast(s64) popup.active_slot]];
        moved.active_slot = popup.active_slot;
    }

    array_add(*pm.pool.free_indices, popup.pool_index);
    <<popup = Score_Popup.{};
}

popup_manager_spawn :: (pm: *Popup_Manager, pos: Vector2, value: s32, color: Color) {
    if pm.pool.active_indices.count >= BURST_TUNING.popup_soft_cap || pm.pool.free_indices.count == 0 {
        return;
    }

    popup_index := pm.pool.free_indices[pm.pool.free_indices.count - 1];
    pm.pool.free_indices.count -= 1;
    popup := *pm.pool.storage[cast(s64) popup_index];
    popup_slot := cast(int) pm.pool.active_indices.count;
    array_add(*pm.pool.active_indices, popup_index);

    <<popup = Score_Popup.{
        active      = true,
        pool_index  = popup_index,
        active_slot = popup_slot,
        pos         = pos,
        value       = value,
        y_offset    = 0,
        alpha       = 1,
        scale       = 0.85,
        color       = color,
        elapsed     = 0,
        life        = 0.45,
    };
}

popup_manager_update :: (pm: *Popup_Manager, dt: float32) {
    i := 0;
    while i < pm.pool.active_indices.count {
        popup := *pm.pool.storage[cast(s64) pm.pool.active_indices[cast(s64) i]];
        popup.elapsed += dt;
        ratio := clamp01(popup.elapsed / popup.life);
        popup.y_offset = lerp_f32(0.0, -44.0, ease_out_cubic(ratio));
        popup.alpha = lerp_f32(1.0, 0.0, ease_in_quad(ratio));
        if ratio < 0.24 {
            popup.scale = lerp_f32(0.85, 1.15, ease_out_back(ratio / 0.24));
        } else {
            settle_ratio := (ratio - 0.24) / 0.76;
            popup.scale = lerp_f32(1.15, 1.0, ease_out_cubic(settle_ratio));
        }

        if popup.alpha <= 0.02 || popup.elapsed >= popup.life {
            popup_manager_release(pm, popup);
            continue;
        }
        i += 1;
    }
}

popup_manager_draw :: (pm: *Popup_Manager) {
    drawn_count := 0;
    i := 0;
    while i < pm.pool.active_indices.count {
        if drawn_count >= BURST_TUNING.popup_draw_limit {
            break;
        }
        popup := pm.pool.storage[cast(s64) pm.pool.active_indices[cast(s64) i]];

        font_size := cast(s32) (28 * popup.scale);
        if font_size < 12 {
            font_size = 12;
        }
        pos := Vector2.{ x = popup.pos.x - 18, y = popup.pos.y + popup.y_offset };
        color := color_with_alpha(popup.color, popup.alpha);
        shadow := color_with_alpha(BLACK, popup.alpha * 0.45);
        label := popup_label(popup.value);
        if drawn_count < 16 {
            DrawText(label, cast(s32) pos.x + 2, cast(s32) pos.y + 2, font_size, shadow);
        }
        DrawText(label, cast(s32) pos.x, cast(s32) pos.y, font_size, color);
        drawn_count += 1;
        i += 1;
    }
}
