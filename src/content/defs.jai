// defs.jai
// Port of Ascension/src/content/defs.odin

#import "bindings/raylib";

Leaf_Kind :: enum u8 {
    Normal;
    Enlightenment_Fruit;
}

Leaf_State :: enum u8 {
    Flying;
    Cut;
    Dead;
}

Leaf_Config :: struct {
    radius:       float32;
    score:        s32;
    sword_intent: s32;
}

leaf_config_for_kind :: (kind: Leaf_Kind) -> Leaf_Config {
    if kind == .Normal {
        return .{ radius = 14, score = 10, sword_intent = 1 };
    } else if kind == .Enlightenment_Fruit {
        return .{ radius = 18, score = 25, sword_intent = 3 };
    }
    return Leaf_Config.{};
}

Leaf_Spawn_Config :: struct {
    count:        s32;
    min_speed:    float32;
    max_speed:    float32;
    spawn_radius: float32;
    fruit_chance: float32;
}

Round_Phase :: enum u8 {
    Tree_Burst;
    Playing;
    Settlement;
    Insight_Screen;
}

Growth_Node_Kind :: enum u8 {
    Slash_Range_Up;
    Slash_Penetrate;
    Combo_Window_Up;
    Fruit_Chance_Up;
    Time_Refund_On_Combo;
}

Growth_Node_Def :: struct {
    id:         s32;
    kind:       Growth_Node_Kind;
    cost:       s32;
    pos:        Vector2;
    prereq_ids: [] s32;
}

Growth_Tree :: struct {
    nodes: [] Growth_Node_Def;
}
