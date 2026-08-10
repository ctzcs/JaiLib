// interpolated.jai
// Port of Ascension/tlib/tween/interpolated.odin
// Time-based interpolation between two values of type T.

#import "Basic";
#import "tween/math_util";

Transition :: enum u8 {
    None;
    Linear;
    Custom;
    EaseIn;
    EaseInOut;
    EaseOut;
    EaseInBack;
    EaseOutElastic;
}

Interpolated :: struct(T: Type) {
    start:           T;
    finish:          T;
    start_time:      float32;
    speed:           float32;
    transition:      Transition;
    transition_proc: (t: float32) -> float32;
    lerp:            (a: T, b: T, ratio: float32) -> T;
}

interp_get_ratio_internal :: (interp: *Interpolated($T), t: float32) -> float32 {
    time := clamp(t, 0.0, 1.0);

    if interp.transition == .None {
        return 1;
    } else if interp.transition == .Linear {
        return time;
    } else if interp.transition == .Custom {
        if interp.transition_proc != null {
            return clamp(interp.transition_proc(time), 0.0, 1.0);
        }
        return time;
    } else if interp.transition == .EaseIn {
        return time * time * time;
    } else if interp.transition == .EaseInOut {
        if time < 0.5 {
            return 4 * time * time * time;
        }
        x := -2 * time + 2;
        return 1 - (x * x * x) * 0.5;
    } else if interp.transition == .EaseOut {
        x := 1 - time;
        return 1 - x * x * x;
    } else if interp.transition == .EaseInBack {
        c1: float32 = 1.70158;
        c3 := c1 + 1;
        return c3 * time * time * time - c1 * time * time;
    } else if interp.transition == .EaseOutElastic {
        if time <= 0 {
            return 0;
        }
        if time >= 1 {
            return 1;
        }
        c4: float32 = 2.0943952; // 2*pi/3
        return math_pow(2.0, -10.0 * time) * math_sin((time * 10.0 - 0.75) * c4) + 1.0;
    }

    return time;
}

interp_set_transition_proc :: (interp: *Interpolated($T), transition_proc: (t: float32) -> float32) {
    interp.transition = .Custom;
    interp.transition_proc = transition_proc;
}

// Set the duration of the interpolation.
interp_set_duration :: (interp: *Interpolated($T), duration: float32) {
    if duration <= 0 {
        interp.speed = 1.0e30;
        return;
    }
    interp.speed = 1.0 / duration;
}

interp_get_elapsed_seconds :: (interp: *Interpolated($T), current_time: float32) -> float32 {
    return current_time - interp.start_time;
}

// Get the value at the given time.
interp_get_value :: (interp: *Interpolated($T), current_time: float32) -> T {
    t := interp_get_elapsed_seconds(interp, current_time) * interp.speed;

    if t <= 0 {
        return interp.start;
    }
    if t >= 1 {
        return interp.finish;
    }

    ratio := interp_get_ratio_internal(interp, t);
    return interp.lerp(interp.start, interp.finish, ratio);
}

// Continue interpolating from the current value toward a new target value.
interp_set_value :: (interp: *Interpolated($T), new_value: T, current_time: float32) {
    interp.start = interp_get_value(interp, current_time);
    interp.finish = new_value;
    interp.start_time = current_time;
}

// Continue from the current value toward a new target, with a new transition.
interp_set_value_full :: (interp: *Interpolated($T), now_value: T, new_value: T, current_time: float32, transition: Transition, lerp: (a: T, b: T, ratio: float32) -> T) {
    interp.start = now_value;
    interp.finish = new_value;
    interp.start_time = current_time;
    interp.transition = transition;
    interp.transition_proc = null;
    interp.lerp = lerp;
}
