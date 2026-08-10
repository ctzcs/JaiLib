// entity/round.jai — 回合/关卡运行时状态
// （原 entity.jai 拆分：Round_State / Tree_State / Leaf_Spawner_Runtime）
// Combo_State 来自同目录 player.jai，显式导入保持文件自足。

#import "bindings/raylib";
#import "content/core/defs";
#import "content/entity/player";
#import "tween/manager";

Tree_State :: struct {
    pos:          Vector2;
    canopy_scale: float32;
    glow_alpha:   float32;
    shake_x:      float32;
    burst_handle: Tween_Handle;
    cooldown:     float32;
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
