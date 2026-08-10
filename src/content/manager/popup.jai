// manager/popup.jai — 得分弹字管理器（对象池）
// （原 managers.jai 拆分：Popup_Manager + popup_manager_*）

#import "Basic";
#import "bindings/raylib";
#import "content/entity/ui_flow";
#import "content/core/const";
#import "content/game";
#import "content/manager/util";
#import "content/core/utils";

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
