// manager/leaf.jai — 叶片管理器（对象池）
// （原 managers.jai 拆分：Leaf_Manager + leaf_manager_*）

#import "Basic";
#import "bindings/raylib";
#import "content/entity/leaf";
#import "content/core/const";
#import "content/core/defs";
#import "content/manager/util";
#import "content/core/utils";

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
