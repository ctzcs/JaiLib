// entity/leaf.jai — 叶片实体与对象池
// （原 entity.jai 拆分：Leaf / Leaf_Pool）

#import "bindings/raylib";
#import "content/core/const";
#import "content/core/defs";

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

Leaf_Pool :: struct {
    storage:        [MAX_LEAVES] Leaf;
    active_indices: [..] int;
    free_indices:   [..] int;
}
