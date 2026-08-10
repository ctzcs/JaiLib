// entity.jai
// Port of Ascension/src/content/entity.odin
// Runtime state: scene objects + in-run flow / out-of-run progress.
//
// Odin used `using` embeddings; Jai accesses them as explicit fields
// (player.base.*, leaf.config.*).

#import "bindings/raylib";
#import "tween/manager";
#import "content/const";
#import "content/defs";

Entity :: struct {
    id:  s32;
    pos: Vector2;
    vel: Vector2;
}

Leaf :: struct {
    active:      bool;
    pool_index:  int;
    active_slot: int;
    kind:        Leaf_Kind;
    state:       Leaf_State;
    config:      Leaf_Config;
    pos:         Vector2;
    vel:         Vector2;
    rotation:    float32;
    angular_vel: float32;
    render_scale: float32;
    render_alpha: float32;
    tint:        Color;
    spawn_delay: float32;
    spawn_elapsed: float32;
    cut_elapsed: float32;
    cut_duration: float32;
    cut_start_pos: Vector2;
    cut_target_pos: Vector2;
    cut_start_scale: float32;
    cut_target_scale: float32;
}

Slash_Point :: struct {
    pos:  Vector2;
    time: float32;
}

Slash_Stroke :: struct {
    points:     [..] Slash_Point;
    active:     bool;
    hit_radius: float32;
    max_age:    float32;
    age:        float32;
}

Player :: struct {
    base:  Entity;
    slash: Slash_Stroke;
}

Tree_State :: struct {
    pos:          Vector2;
    canopy_scale: float32;
    glow_alpha:   float32;
    shake_x:      float32;
    burst_handle: Tween_Handle;
    cooldown:     float32;
}

Score_Popup :: struct {
    active:      bool;
    pool_index:  int;
    active_slot: int;
    pos:         Vector2;
    value:       s32;
    y_offset:    float32;
    alpha:       float32;
    scale:       float32;
    color:       Color;
    elapsed:     float32;
    life:        float32;
}

Leaf_Pool :: struct {
    storage:        [MAX_LEAVES] Leaf;
    active_indices: [..] int;
    free_indices:   [..] int;
}

Popup_Pool :: struct {
    storage:        [MAX_POPUPS] Score_Popup;
    active_indices: [..] int;
    free_indices:   [..] int;
}

Combo_State :: struct {
    count:      s32;
    best:       s32;
    timer:      float32;
    break_time: float32;
    multiplier: float32;
}

Round_State :: struct {
    phase:             Round_Phase;
    duration:          float32;
    current_time:      float32;
    stage:             s32;
    target_leaf_count: s32;
    cut_leaf_count:    s32;
    score:             s32;
    sword_intent_gain: s32;
    combo:             Combo_State;
    finished:          bool;
}

Leaf_Spawner_Runtime :: struct {
    origin:   Vector2;
    spawned:  s32;
    finished: bool;
}

Player_Progress :: struct {
    sword_intent:       s32;
    purchased_node_ids: [] s32;
}

Insight_State :: struct {
    active:           bool;
    hovered_node_id:  s32;
    selected_node_id: s32;
}
