// entity/ui_flow.jai — 得分弹字与洞察界面状态
// （原 entity.jai 拆分：Score_Popup / Popup_Pool / Insight_State）
// Score_Popup 被同目录 Popup_Pool 使用（module 合并作用域）。

#import "bindings/raylib";
#import "content/core/const";

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

Popup_Pool :: struct {
    storage:        [MAX_POPUPS] Score_Popup;
    active_indices: [..] int;
    free_indices:   [..] int;
}

Insight_State :: struct {
    active:           bool;
    hovered_node_id:  s32;
    selected_node_id: s32;
}
