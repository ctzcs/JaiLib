// rendering2d:animation_set —— 帧动画集合（对位 DragonLib Engine.Rendering.Sprite）。
// 一比一移植自 olib kit/rendering/2d/animation_set.odin。
//
// 一个 Animation_Set = 若干帧（图集子图 + 时长）+ 若干命名动画（帧区间）。
// 与图集的关联只体现在 Subtexture 上；帧通常来自 aseprite_build 产出的
// Built_Clip（区域名 -> 图集子图）。
//
// Jai 侧差异（逐条对应 olib 的写法，帧/区间/采样语义不变）：
//   | olib (Odin)                            | JaiLib (Jai)                                            |
//   | -------------------------------------- | ------------------------------------------------------- |
//   | `foster.Subtexture`                    | `F.Subtexture`（字段 Tex / Source / Frame / TexCoords）  |
//   | `foster.Vec2`                          | `F.Vector2`                                             |
//   | `[dynamic]Animation_Frame` / `append`  | `[..] Animation_Frame` / `array_add`                     |
//   | `delete(sprite.frames)` / `delete(str)`| `array_free(...)` / `free(str.data)`（先判 null）         |
//   | `strings.clone(s)`                     | `copy_string(s)`（= atlas.jai 的 clone_owned）            |
//   | `for &anim in sprite.animations`       | `for *anim: sprite.animations`（同样拿到元素指针）         |
//   | `math.mod(x, y)`                       | `animation_set_mod`（同一条截断取余：jacket 的 Math 只有   |
//   |                                        | `fmod_cycling`，符号规则与 Odin 的 mod 不同）             |
//   | `sprite^ = {…}`                        | `sprite.* = Animation_Set.{…}`                          |
#import "Basic";

//@region 类型 —— 帧 / 动画 / Animation_Set

// 一帧：可绘制子图 + 停留时长（秒）。
Animation_Frame :: struct {
    subtexture: F.Subtexture;
    duration:   float32;
}

// 一段命名动画：frames 数组里 [frame_start, frame_start+frame_count) 的帧。
Animation :: struct {
    name:        string;
    frame_start: int;
    frame_count: int;
    duration:    float32; // 区间内帧时长总和（add 时累计）
}

// 包含动画的集合。名称与动画名为克隆字符串，dispose 统一释放。
Animation_Set :: struct {
    name:   string;
    origin: F.Vector2; // 绘制锚点（像素）

    frames:     [..] Animation_Frame;
    animations: [..] Animation;
}

animation_set_init :: (sprite: *Animation_Set, name: string, origin := F.Vector2.{0, 0}) {
    sprite.* = Animation_Set.{
        name   = clone_owned(name),
        origin = origin,
    };
}

animation_set_dispose :: (sprite: *Animation_Set) {
    if sprite.name.data != null free(sprite.name.data);
    for *anim: sprite.animations {
        if anim.name.data != null free(anim.name.data);
    }
    if sprite.animations.data != null array_free(sprite.animations);
    if sprite.frames.data != null array_free(sprite.frames);
    sprite.* = Animation_Set.{};
}

// 追加一帧。
animation_set_add_frame :: (sprite: *Animation_Set, subtexture: F.Subtexture, duration: float32) {
    array_add(*sprite.frames, Animation_Frame.{ subtexture = subtexture, duration = duration });
}
//@endregion

//@region 动画注册 —— add_animation / get_animation

// 注册一段动画并累计时长。区间越界时只收有效部分。
animation_set_add_animation :: (sprite: *Animation_Set, name: string, frame_start: int, frame_count: int) {
    if frame_count <= 0 return;

    duration: float32 = 0;
    end := min(frame_start + frame_count, sprite.frames.count);
    for i: max(frame_start, 0)..end - 1 {
        duration += sprite.frames[i].duration;
    }

    array_add(*sprite.animations, Animation.{
        name        = clone_owned(name),
        frame_start = frame_start,
        frame_count = frame_count,
        duration    = duration,
    });
}

// 按名字查动画（线性扫描；动画数量级很小）。找不到返回 null。
animation_set_get_animation :: (sprite: *Animation_Set, name: string) -> *Animation {
    for *anim: sprite.animations {
        if anim.name == name return anim;
    }
    return null;
}
//@endregion

//@region 采样 —— get_frame_at

// olib: math.mod(x, y) —— 截断取余（x - y*trunc(x/y)），结果的量值小于 |y|、符号随 x，
// 与 C 的 fmod 相同。jacket 的 Math 只有 fmod_cycling（符号随 divisor），语义不同，所以这里自带。
animation_set_mod :: (x: float32, y: float32) -> float32 {
    if y == 0 return x;
    z := y;
    if z < 0 z = -z;
    // cast(int) 是向零截断，结果与 C 的 fmod 同值（量值 < |y|、符号随 x）。
    return x - z * cast(float32) cast(int) (x / z);
}

// 取动画在 second 时刻应显示的帧。
// loop=false 且超出总时长时夹到最后有效帧；loop=true 循环取模。
// 区间帧时长为 0 时兜底返回区间首帧。
animation_set_get_frame_at :: (sprite: *Animation_Set, animation: *Animation, second: float32, loop: bool) -> (Animation_Frame, bool) {
    if animation == null || animation.frame_count <= 0 return Animation_Frame.{}, false;
    if sprite.frames.count == 0 return Animation_Frame.{}, false;

    end := min(animation.frame_start + animation.frame_count, sprite.frames.count);
    start := max(animation.frame_start, 0);
    if end <= start return Animation_Frame.{}, false;

    if !loop && second >= animation.duration {
        return sprite.frames[end - 1], true;
    }

    t := second;
    if animation.duration > 0 {
        t = animation_set_mod(second, animation.duration);
    }
    for i: start..end - 1 {
        t -= sprite.frames[i].duration;
        if t <= 0 {
            return sprite.frames[i], true;
        }
    }
    return sprite.frames[start], true;
}
//@endregion
