// tween 核心：一次插值的值语义类型（不含 manager）。
// 包装 Interpolated(T)，补上 delay 与 Repeat_Mode；manager 侧的运行时
// 节点见 manager.jai，托管包装见 managed_tween.jai。
// 一比一移植自 olib core/tween/tween.odin。
//
// Jai 侧差异（行为不变）：
//   - olib 的 `using value: Interpolated(T)` 会把插值器字段提升到 Tween 上
//     （tween.start / tween.speed …）。Jai 没有 using，统一写成 tween.value.start，
//     interp_* 调用相应写 *tween.value（字段地址）；
//   - math.max / math.floor → Basic 的 max、Math 的 floor；
//   - 过程名、参数顺序、返回语义与 olib 完全一致。
#import "Basic";
#import "Math";

//@region 类型 —— Repeat_Mode / Tween / Tween_Config

Repeat_Mode :: enum u8 {
    Once;
    Loop;
    PingPong;
}

// 值语义的一次插值：start -> finish，可带 delay 与循环模式。
Tween :: struct(T: Type) {
    value: Interpolated(T);
    delay: float32;
    repeat_mode: Repeat_Mode;
}

Tween_Config :: struct {
    duration: float32;
    delay: float32;
    repeat_mode: Repeat_Mode;
    transition: Transition;
}

TWEEN_CONFIG_DEFAULT :: Tween_Config.{
    duration = 1.0,
    delay = 0.0,
    repeat_mode = .Once,
    transition = .Linear,
};
//@endregion

//@region 构造 —— make / make_ex

make :: (
    start: $T,
    finish: T,
    current_time: float32,
    transition: Transition,
    lerp: (a: T, b: T, ratio: float32) -> T,
) -> Tween(T) {
    result: Tween(T);
    result.value = Interpolated(T).{
        start = start,
        finish = finish,
        start_time = current_time,
        speed = 1.0,
        transition = transition,
        lerp = lerp,
    };
    result.delay = 0;
    result.repeat_mode = .Once;
    return result;
}

// 按 config 构造：duration<=0 / transition==.None 沿用默认值，delay 钳到 >= 0。
make_ex :: (
    start: $T,
    finish: T,
    current_time: float32,
    config: Tween_Config,
    lerp: (a: T, b: T, ratio: float32) -> T,
) -> Tween(T) {
    cfg := TWEEN_CONFIG_DEFAULT;

    if config.duration > 0 {
        cfg.duration = config.duration;
    }
    cfg.delay = max(config.delay, 0.0);
    cfg.repeat_mode = config.repeat_mode;
    if config.transition != .None {
        cfg.transition = config.transition;
    }

    tween := make(start, finish, current_time, cfg.transition, lerp);
    tween_set_duration(*tween, cfg.duration);
    tween_set_delay(*tween, cfg.delay);
    tween_set_repeat_mode(*tween, cfg.repeat_mode);
    return tween;
}
//@endregion

//@region 配置 —— set_duration / set_delay / set_repeat_mode / set_transition_proc

tween_set_duration :: (tween: *Tween($T), duration: float32) {
    interp_set_duration(*tween.value, duration);
}

tween_set_delay :: (tween: *Tween($T), delay: float32) {
    tween.delay = max(delay, 0.0);
}

tween_set_repeat_mode :: (tween: *Tween($T), repeat_mode: Repeat_Mode) {
    tween.repeat_mode = repeat_mode;
}

tween_set_transition_proc :: (tween: *Tween($T), transition_proc: (t: float32) -> float32) {
    interp_set_transition_proc(*tween.value, transition_proc);
}
//@endregion

//@region 采样 —— get_value / get_elapsed_seconds / is_finished / set_value*

tween_get_elapsed_seconds :: (tween: *Tween($T), current_time: float32) -> float32 {
    return current_time - tween.value.start_time;
}

// 只有 .Once 模式会结束；Loop / PingPong 永远返回 false。
tween_is_finished :: (tween: *Tween($T), current_time: float32) -> bool {
    if tween.repeat_mode != .Once {
        return false;
    }

    elapsed := tween_get_elapsed_seconds(tween, current_time) - tween.delay;
    if elapsed <= 0 {
        return false;
    }

    if tween.value.speed >= 1.0e20 {
        return true;
    }

    return elapsed * tween.value.speed >= 1.0;
}

// 按 repeat_mode 采样当前值（Once 出界取 finish，Loop 取小数部分，
// PingPong 奇偶周期反向）。
tween_get_value :: (tween: *Tween($T), current_time: float32) -> T {
    elapsed := tween_get_elapsed_seconds(tween, current_time) - tween.delay;
    if elapsed <= 0 {
        return tween.value.start;
    }

    if tween.value.speed >= 1.0e20 {
        return tween.value.finish;
    }

    normalized_t := elapsed * tween.value.speed;

    if tween.repeat_mode == .Once {
        if normalized_t >= 1.0 {
            return tween.value.finish;
        }
        ratio := interp_get_ratio_internal(*tween.value, normalized_t);
        return tween.value.lerp(tween.value.start, tween.value.finish, ratio);
    } else if tween.repeat_mode == .Loop {
        local_t := normalized_t - floor(normalized_t);
        ratio := interp_get_ratio_internal(*tween.value, local_t);
        return tween.value.lerp(tween.value.start, tween.value.finish, ratio);
    } else if tween.repeat_mode == .PingPong {
        cycle := cast(int) floor(normalized_t);
        local_t := normalized_t - (cast(float32) cycle);
        ratio := interp_get_ratio_internal(*tween.value, local_t);

        if cycle % 2 == 0 {
            return tween.value.lerp(tween.value.start, tween.value.finish, ratio);
        }
        return tween.value.lerp(tween.value.finish, tween.value.start, ratio);
    }

    return tween.value.finish;
}

// 中途改目标：以当前采样值为新起点，从当前时刻重新出发。
tween_set_value :: (tween: *Tween($T), new_value: T, current_time: float32) {
    tween.value.start = interp_get_value(*tween.value, current_time);
    tween.value.finish = new_value;
    tween.value.start_time = current_time;
}

tween_set_value_full :: (
    tween: *Tween($T),
    now_value: T,
    new_value: T,
    current_time: float32,
    transition: Transition,
    lerp: (a: T, b: T, ratio: float32) -> T,
) {
    tween.value.start = now_value;
    tween.value.finish = new_value;
    tween.value.start_time = current_time;
    tween.value.transition = transition;
    tween.value.transition_proc = null;
    tween.value.lerp = lerp;
}
//@endregion
