// game.jai
// Port of Ascension/src/content/game.odin
// Game orchestration: burst flow, round state, slash-hit detection, draw.
//
// The Odin original had a DEV-only ImGui in-game debugger (draw_ingame_editor);
// that part is wired to the Jai ImGui module in Phase 5.

#import "Basic";
#import "bindings/raylib";
#import "core/build";
#import "core/frame";
#import "core/screen";
#import "tween";
#import "encoding/csv";
#import "content";
#import "core/libs";

// --- Burst Tuning ---
Burst_Tuning :: struct {
    burst_leaf_count:           s32;
    spawn_radius:               float32;
    min_speed:                  float32;
    max_speed:                  float32;
    angle_min:                  float32;
    angle_max:                  float32;
    fruit_chance:               float32;
    burst_cooldown:             float32;
    spawn_stagger:              float32;
    cut_particle_count:         int;
    particle_soft_cap:          int;
    popup_soft_cap:             int;
    popup_draw_limit:           int;
    leaf_simple_draw_threshold: int;
}

BURST_TUNING :: Burst_Tuning.{
    burst_leaf_count           = 8000,
    spawn_radius               = 300,
    min_speed                  = 320,
    max_speed                  = 620,
    angle_min                  = -2.05,
    angle_max                  = -1.15,
    fruit_chance               = 0.18,
    burst_cooldown             = 1.8,
    spawn_stagger              = 0.001,
    cut_particle_count         = 7,
    particle_soft_cap          = 640,
    popup_soft_cap             = 64,
    popup_draw_limit           = 48,
    leaf_simple_draw_threshold = 2500,
};

// --- Game Resources ---
Resource :: struct {
    atlas:  Texture;
    shader: Shader;
    ink:    Ink_Post;
    fluid:  Ink_Fluid;
}

init_resource :: (gs: *GameState) {
    gs.resources = .{
        atlas  = load_atlas(),
        shader = load_shader_pair(.WaveVs, .WaveFs),
    };
    ink_post_init(*gs.resources.ink);
    ink_fluid_init(*gs.resources.fluid);
}

destroy_resource :: (gs: *GameState) {
    ink_fluid_destroy(*gs.resources.fluid);
    ink_post_destroy(*gs.resources.ink);
    UnloadTexture(gs.resources.atlas);
    UnloadShader(gs.resources.shader);
}

// --- Runtime Data ---
GameState :: struct {
    is_debugger_open:  bool;
    tween_manager:     Tween_Manager;
    players:           Player_Manager;
    trees:             Tree_Manager;
    leaves:            Leaf_Manager;
    popups:            Popup_Manager;
    particles:         Particle_System;
    leaf_spawn_config: Leaf_Spawn_Config;
    spawner:           Leaf_Spawner_Runtime;
    round:             Round_State;
    camera:            CameraState;
    resources:         Resource;
    ink_tuning:        Ink_Tuning;
    csv_mgr:           Csv_Manager;
    tables:            Csv_Tables;
}

// --- Helpers ---
game_camera :: (gs: *GameState) -> Camera2D {
    return to_camera2d(gs.camera);
}

popup_label :: (value: s32) -> *u8 {
    if value == 25 {
        return "+25".data;
    } else if value == 10 {
        return "+10".data;
    }
    return "+1".data;
}

safe_kill :: (manager: *Tween_Manager, handle: Tween_Handle) {
    if manager_is_handle_valid(<<manager, handle) {
        _ = manager_kill(manager, handle);
    }
}

clear_player_slash :: (slash: *Slash_Stroke) {
    array_reset_keeping_memory(*slash.points);
    slash.active = false;
    slash.age = 0;
}

compact_slash_points :: (points: *[..] Slash_Point, remove_count: int) {
    if remove_count <= 0 {
        return;
    }
    if remove_count >= points.count {
        array_reset_keeping_memory(points);
        return;
    }

    remaining := points.count - remove_count;
    i := 0;
    while i < remaining {
        (<<points)[cast(s64) i] = (<<points)[cast(s64) i + remove_count];
        i += 1;
    }
    points.count = remaining;
}

append_slash_point :: (slash: *Slash_Stroke, pos: Vector2, now: float32) {
    if slash.points.count > 0 {
        last := slash.points[slash.points.count - 1];
        dx := pos.x - last.pos.x;
        dy := pos.y - last.pos.y;
        if dx * dx + dy * dy < 64 {
            return;
        }
    }
    array_add(*slash.points, .{ pos = pos, time = now });
    if slash.points.count > MAX_SLASH_POINTS {
        compact_slash_points(*slash.points, cast(int) slash.points.count - MAX_SLASH_POINTS);
    }
}

// --- Tree Burst Flow ---
emit_leaf_cut_particles :: (gs: *GameState, leaf: *Leaf) {
    active_particles := particle_system_active_count(*gs.particles);
    particle_count := BURST_TUNING.cut_particle_count;
    if active_particles >= BURST_TUNING.particle_soft_cap {
        particle_count = max(1, particle_count / 2);
    }
    if active_particles >= BURST_TUNING.particle_soft_cap + BURST_TUNING.particle_soft_cap / 3 {
        particle_count = 1;
    }

    i := 0;
    while i < particle_count {
        _ = particle_system_emit(*gs.particles, .{
            pos = leaf.pos,
            vel = Vector2.{ x = random_range_f32(-120, 120), y = random_range_f32(-180, -40) },
            life = random_range_f32(0.25, 0.55),
            size = Vector2.{ x = random_range_f32(6, 14), y = random_range_f32(4, 10) },
            color = color_with_alpha(leaf.tint, 0.95),
            render_kind = .Rect,
            gravity = 520,
            drag = 0.96,
            angle = random_range_f32(0, 360),
            rotate_speed = random_range_f32(-420, 420),
        });
        i += 1;
    }
}

trigger_tree_burst :: (gs: *GameState) {
    leaf_manager_clear(*gs.leaves);
    popup_manager_clear(*gs.popups);
    player_manager_clear_slash(*gs.players);
    particle_system_clear(*gs.particles);
    safe_kill(*gs.tween_manager, gs.trees.state.burst_handle);

    gs.trees.state.canopy_scale = 0.82;
    gs.trees.state.glow_alpha = 0.0;
    gs.trees.state.shake_x = 0.0;
    gs.trees.state.cooldown = BURST_TUNING.burst_cooldown;

    gs.spawner.spawned = 0;
    gs.spawner.finished = false;
    gs.round.phase = .Tree_Burst;
    gs.round.current_time = 0;
    gs.round.cut_leaf_count = 0;
    gs.round.score = 0;
    gs.round.combo.count = 0;
    gs.round.combo.best = 0;
    gs.round.combo.timer = 0;
    gs.round.combo.multiplier = 1.0;

    seq := manager_add_sequence(*gs.tween_manager);
    _, _ = sequence_append_tween_to(
        *gs.tween_manager,
        seq,
        make_ex(0.82, 1.18, 0, Tween_Config.{ duration = 0.12, transition = .EaseInBack }, lerp_f32),
        *gs.trees.state.canopy_scale,
    );
    _, _ = sequence_join_tween_to(
        *gs.tween_manager,
        seq,
        make_ex(0.0, 0.95, 0, Tween_Config.{ duration = 0.12, transition = .EaseOut }, lerp_f32),
        *gs.trees.state.glow_alpha,
    );
    _, _ = sequence_append_tween_to(
        *gs.tween_manager,
        seq,
        make_ex(1.18, 1.0, 0, Tween_Config.{ duration = 0.30, transition = .EaseOutElastic }, lerp_f32),
        *gs.trees.state.canopy_scale,
    );
    _, _ = sequence_join_tween_to(
        *gs.tween_manager,
        seq,
        make_ex(0.95, 0.0, 0, Tween_Config.{ duration = 0.24, transition = .EaseOut }, lerp_f32),
        *gs.trees.state.glow_alpha,
    );
    _, _ = sequence_join_tween_to(
        *gs.tween_manager,
        seq,
        make_ex(0.0, 12, 0, Tween_Config.{ duration = 0.08, repeat_mode = .PingPong, transition = .EaseInOut }, lerp_f32),
        *gs.trees.state.shake_x,
    );
    _ = manager_set_loops(*gs.tween_manager, seq, 2, .PingPong);
    gs.trees.state.burst_handle = seq;

    i: s32 = 0;
    while i < gs.leaf_spawn_config.count {
        is_fruit := random_range_f32(0, 1) < gs.leaf_spawn_config.fruit_chance;
        angle := random_range_f32(BURST_TUNING.angle_min, BURST_TUNING.angle_max);
        speed := random_range_f32(gs.leaf_spawn_config.min_speed, gs.leaf_spawn_config.max_speed);
        spawn_offset := Vector2.{
            x = random_range_f32(-gs.leaf_spawn_config.spawn_radius, gs.leaf_spawn_config.spawn_radius),
            y = random_range_f32(-18, 18),
        };
        leaf_pos := Vector2.{ x = gs.trees.state.pos.x + gs.spawner.origin.x + spawn_offset.x, y = gs.trees.state.pos.y + gs.spawner.origin.y + spawn_offset.y };
        leaf_kind := Leaf_Kind.Normal;
        leaf_tint := Color.{ r = 90, g = 210, b = 120, a = 255 };
        if is_fruit {
            leaf_kind = .Enlightenment_Fruit;
            leaf_tint = GOLD;
        }
        leaf_vel := Vector2.{ x = math_cos(angle) * speed, y = math_sin(angle) * speed };
        if leaf_manager_spawn(
            *gs.leaves,
            leaf_pos,
            leaf_vel,
            leaf_kind,
            leaf_tint,
            cast(float32) i * BURST_TUNING.spawn_stagger,
        ) {
            gs.spawner.spawned += 1;
        }
        i += 1;
    }
    gs.spawner.finished = true;
}

on_leaf_cut :: (kind: Leaf_Kind, player: *Player) {
    _ = player;
    _ = kind;
}

cut_leaf :: (gs: *GameState, leaf: *Leaf) {
    if !leaf.active || leaf.state != .Flying {
        return;
    }

    leaf.state = .Cut;
    leaf.vel = Vector2.{};
    leaf.angular_vel = 0;
    leaf.cut_elapsed = 0;
    leaf.cut_duration = 0.18;
    leaf.cut_start_pos = leaf.pos;
    leaf.cut_target_pos = Vector2.{
        x = leaf.pos.x + random_range_f32(-26, 26),
        y = leaf.pos.y + random_range_f32(-36, -18),
    };
    leaf.cut_start_scale = leaf.render_scale;
    leaf.cut_target_scale = leaf.render_scale * 1.25;

    emit_leaf_cut_particles(gs, leaf);
    popup_manager_spawn(*gs.popups, leaf.pos, leaf.config.score, leaf.tint);

    gs.round.cut_leaf_count += 1;
    gs.round.score += leaf.config.score;
    gs.round.combo.count += 1;
    gs.round.combo.best = max(gs.round.combo.best, gs.round.combo.count);
    gs.round.combo.timer = 0;
    gs.round.combo.multiplier = 1.0 + cast(float32) gs.round.combo.count * 0.05;
    on_leaf_cut(leaf.kind, *gs.players.player);
}

// --- Update ---
update_round :: (gs: *GameState, dt: float32) {
    gs.round.current_time += dt;
    tree_manager_tick_cooldown(*gs.trees, dt);

    if gs.round.combo.count > 0 {
        gs.round.combo.timer += dt;
        if gs.round.combo.timer >= gs.round.combo.break_time {
            gs.round.combo.count = 0;
            gs.round.combo.timer = 0;
            gs.round.combo.multiplier = 1.0;
        }
    }

    if gs.round.current_time > 0.28 {
        gs.round.phase = .Playing;
    }

    if IsKeyPressed(.SPACE) {
        trigger_tree_burst(gs);
    }
}

// Orchestration: player slash <-> leaf hit detection.
update_slash_hits :: (gs: *GameState, frame: *FrameContext) {
    slash := *gs.players.player.slash;
    if !slash.active || slash.points.count == 0 {
        return;
    }
    mouse_world := world_mouse_pos(frame.input, gs.camera);
    radius := slash.hit_radius;

    i := 0;
    while i < gs.leaves.pool.active_indices.count {
        leaf := *gs.leaves.pool.storage[cast(s64) gs.leaves.pool.active_indices[cast(s64) i]];
        if leaf.state != .Flying {
            i += 1;
            continue;
        }

        dx := leaf.pos.x - mouse_world.x;
        dy := leaf.pos.y - mouse_world.y;
        hit_radius := leaf.config.radius + radius;
        if math_abs(dx) > hit_radius || math_abs(dy) > hit_radius {
            i += 1;
            continue;
        }
        if dx * dx + dy * dy <= hit_radius * hit_radius {
            cut_leaf(gs, leaf);
        }
        i += 1;
    }
}

// --- Draw ---
draw_hud :: () {
    DrawRectangle(18, 18, 720, 182, color_with_alpha(BLACK, 0.45));
    DrawText("Tree Burst", 32, 30, 28, RAYWHITE);
    DrawText("Space: replay burst", 32, 66, 22, LIGHTGRAY);
    DrawText("Hold LMB: cut leaves", 32, 92, 22, LIGHTGRAY);
    DrawText("Watch popup scores and leaf feedback", 32, 124, 22, GOLD);
    DrawText("Edit BURST_TUNING in game.jai to try different burst presets", 32, 154, 20, SKYBLUE);
}

// --- Lifecycle ---
init_game :: (gs: *GameState) {
    init_resource(gs);
    gs.camera = .{
        offset   = Vector2.{ x = cast(float32) SCREEN_WIDTH * 0.5, y = cast(float32) SCREEN_HEIGHT * 0.5 },
        rotation = 0.0,
        zoom     = 1,
        target   = Vector2.{ x = 0.0, y = 0.0 },
    };

    gs.tween_manager = manager_make();
    gs.leaf_spawn_config = .{
        count        = BURST_TUNING.burst_leaf_count,
        min_speed    = BURST_TUNING.min_speed,
        max_speed    = BURST_TUNING.max_speed,
        spawn_radius = BURST_TUNING.spawn_radius,
        fruit_chance = BURST_TUNING.fruit_chance,
    };
    gs.spawner = .{ origin = Vector2.{ x = 0, y = -10 }, finished = true };
    gs.round = .{ phase = .Tree_Burst, duration = 8.0, combo = .{ break_time = 0.85, multiplier = 1.0 } };

    player_manager_init(*gs.players, 42, 0.12);
    tree_manager_init(*gs.trees, Vector2.{ x = 0, y = 30 });
    leaf_manager_init(*gs.leaves);
    popup_manager_init(*gs.popups);
    particle_system_init(*gs.particles);

    csv_manager_init(*gs.csv_mgr);
    gs.tables = load_csv_tables(*gs.csv_mgr);

    gs.ink_tuning = INK_TUNING_DEFAULT;
    ink_fluid_reset(*gs.resources.fluid, *gs.ink_tuning);

    trigger_tree_burst(gs);
}

destroy_game :: (gs: *GameState) {
    destroy_resource(gs);
    player_manager_destroy(*gs.players);
    leaf_manager_destroy(*gs.leaves);
    popup_manager_destroy(*gs.popups);
    manager_delete(*gs.tween_manager);

    destroy_csv_tables(*gs.tables);
    csv_manager_destroy(*gs.csv_mgr);
}

update_game :: (gs: *GameState, frame: *FrameContext) {
    dt := frame.dt;

    #if DEV {
        imgui_begin_frame();
        draw_ingame_editor(gs);
    }

    input_enabled := true;

    manager_update(*gs.tween_manager, dt);
    update_round(gs, dt);

    mouse_world := world_mouse_pos(frame.input, gs.camera);
    player_manager_update(*gs.players, mouse_world, gs.round.current_time, dt, input_enabled);
    update_slash_hits(gs, frame);
    leaf_manager_update(*gs.leaves, dt);
    popup_manager_update(*gs.popups, dt);
    particle_system_update(*gs.particles, dt);

    if leaf_manager_active_count(*gs.leaves) == 0 && gs.trees.state.cooldown <= 0 {
        trigger_tree_burst(gs);
    }
}

draw_game :: (gs: *GameState) {
    camera := game_camera(gs);
    simple_draw := leaf_manager_active_count(*gs.leaves) >= BURST_TUNING.leaf_simple_draw_threshold;

    ink_post_begin_scene(*gs.resources.ink);
    BeginMode2D(camera);
    DrawRectangle(-1400, cast(s32) GROUND_Y, 2800, 600, Color.{ r = 22, g = 42, b = 26, a = 255 });

    tree_manager_draw(*gs.trees);
    leaf_manager_draw(*gs.leaves, simple_draw);
    particle_system_draw(*gs.particles);
    player_manager_draw_slash(*gs.players, gs.round.current_time);
    popup_manager_draw(*gs.popups);
    draw_atlas_sprite_ex(
        gs.resources.atlas,
        .Cha_Frog_Knight,
        Vector2.{ x = 0, y = 0 },
        Vector2.{ x = 4, y = 4 },
        90,
        ANCHOR_BOTTOM_CENTER,
    );
    draw_atlas_sprite_ex(gs.resources.atlas, .Ui_Green, Vector2.{ x = 100, y = 100 }, Vector2.{ x = 2, y = 2 });
    EndMode2D();
    ink_post_end_scene(*gs.resources.ink);

    ink_post_render_stylized(*gs.resources.ink, *gs.ink_tuning);

    ClearBackground(PAPER_COLOR);
    ink_post_draw_stylized(*gs.resources.ink);
    if gs.ink_tuning.fluid_enabled {
        ink_fluid_step(*gs.resources.fluid, *gs.ink_tuning, GetFrameTime());
        ink_fluid_draw_overlay(*gs.resources.fluid, *gs.ink_tuning);
    }

    DrawFPS(20, 20);
    draw_hud();
    #if DEV {
        imgui_end_frame();
    }
}

// --- ingame editor (Phase 5 wires the Jai ImGui module here) ---
#if DEV {
    draw_ingame_editor :: (gs: *GameState) {
        // TODO(Phase 5): ImGui in-game debugger (F2 toggle + tuning sliders).
        _ = gs;
    }
}
