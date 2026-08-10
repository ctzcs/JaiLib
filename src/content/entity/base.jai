// entity/base.jai — 基础实体与连击数据结构
// （原 entity.jai 拆分：Entity / Slash_Point / Slash_Stroke）

#import "bindings/raylib";

Entity :: struct {
    id:  s32;
    pos: Vector2;
    vel: Vector2;
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
