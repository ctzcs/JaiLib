// tween.jai
// Port of Ascension/tlib/tween/tween.odin
// A self-contained tween (value + timing + repeat mode).
//
// The Odin original embedded Interpolated via `using`; Jai has no `using`, so
// the embedded value is accessed as tween.value.*.

#import "Basic";
#import "tween/math_util";
#import "tween/interpolated";

Repeat_Mode :: enum u8 {
    Once;
    Loop;
    PingPong;
}

Tween :: struct(T: Type) {
    value:       Interpolated(T);
    delay:       float32;
    repeat_mode: Repeat_Mode;
}

Tween_Config :: struct {
    duration:    float32;
    delay:       float32;
    repeat_mode: Repeat_Mode;
    transition:  Transition;
}

TWEEN_CONFIG_DEFAULT :: Tween_Config.{ duration = 1.0, delay = 0.0, repeat_mode = .Once, transition = .Linear };

make :: (start: $T, finish: T, current_time: float32, transition: Transition, lerp: (a: T, b: T, ratio: float32) -> T) -> Tween(T) {
    result: Tween(T);
    result.value = .{ start = start, finish = finish, start_time = current_time, speed = 1.0, transition = transition, lerp = lerp };
    result.delay = 0;
    result.repeat_mode = .Once;
    return result;
}

make_ex :: (start: $T, finish: T, current_time: float32, config: Tween_Config, lerp: (a: T, b: T, ratio: float32) -> T) -> Tween(T) {
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

tween_set_duration :: (tween: *Tween($T), duration: float32) {
    interp_set_duration(*tween.value, duration);
}

tween_set_delay :: (tween: *Tween($T), delay: float32) {
    tween.delay = max(delay, 0.0);
}

tween_set_repeat_mode :: (tween: *Tween($T), repeat_mode: Repeat_Mode) {
    tween.repeat_mode = repeat_mode;
}

tween_get_elapsed_seconds :: (tween: *Tween($T), current_time: float32) -> float32 {
    return current_time - tween.value.start_time;
}

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
        local_t := normalized_t - math_floor(normalized_t);
        ratio := interp_get_ratio_internal(*tween.value, local_t);
        return tween.value.lerp(tween.value.start, tween.value.finish, ratio);
    } else if tween.repeat_mode == .PingPong {
        cycle := cast(int) math_floor(normalized_t);
        local_t := normalized_t - cast(float32) cycle;
        ratio := interp_get_ratio_internal(*tween.value, local_t);

        if cycle % 2 == 0 {
            return tween.value.lerp(tween.value.start, tween.value.finish, ratio);
        }
        return tween.value.lerp(tween.value.finish, tween.value.start, ratio);
    }

    return tween.value.finish;
}

tween_set_value :: (tween: *Tween($T), new_value: T, current_time: float32) {
    tween.value.start = interp_get_value(tween.value, current_time);
    tween.value.finish = new_value;
    tween.value.start_time = current_time;
}

tween_set_transition_proc :: (tween: *Tween($T), transition_proc: (t: float32) -> float32) {
    interp_set_transition_proc(*tween.value, transition_proc);
}

tween_set_value_full :: (tween: *Tween($T), now_value: T, new_value: T, current_time: float32, transition: Transition, lerp: (a: T, b: T, ratio: float32) -> T) {
    tween.value.start = now_value;
    tween.value.finish = new_value;
    tween.value.start_time = current_time;
    tween.value.transition = transition;
    tween.value.transition_proc = null;
    tween.value.lerp = lerp;
}
