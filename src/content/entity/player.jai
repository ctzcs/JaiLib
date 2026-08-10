// entity/player.jai — 玩家、连击与进度
// （原 entity.jai 拆分：Player / Combo_State / Player_Progress）
// Entity / Slash_Stroke 来自同目录 base.jai，显式导入保持文件自足。

#import "content/entity/base";

Player :: struct {
    base:  Entity;
    slash: Slash_Stroke;
}

Combo_State :: struct {
    count:      s32;
    best:       s32;
    timer:      float32;
    break_time: float32;
    multiplier: float32;
}

Player_Progress :: struct {
    sword_intent:       s32;
    purchased_node_ids: [] s32;
}
