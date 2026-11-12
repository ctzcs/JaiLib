// 目标追随：不建 Tween 节点、每帧直接追向可能随时变化的目标。
// 适合拖动归位、悬停抬起、按压回弹、容器伸缩这类目标随状态变化、无需时间轴的动画；
// 有固定时长和编排需求时仍用 Tween / Sequence。
// 一比一移植自 olib core/tween/damp.odin。
//
// Jai 侧差异（数值与语义不变）：
//   - math.exp / math.sqrt / math.cos / math.sin / math.clamp / math.PI
//     → Math 的 exp / sqrt / cos / sin、Basic 的 clamp、Math 的 PI（float32）；
//   - Jai 没有数组算术：olib 里 T 上的 + - * 全部走 tween_add / tween_sub /
//     tween_scale 三个桥接，编译期按 T 分派（float32 走原生运算，
//     [N] float32 走逐分量循环），所以 approach / smooth_damp / spring
//     对 f32 与 [N]f32 都可用，与 olib 的泛型覆盖面一致。
#import "Basic";
#import "Math";

//@region 数组运算桥接（对应 olib 中 T 上的 + - * 标量运算）

// 只在 T 为定长数组时实例化；标量由 tween_add / tween_sub / tween_scale 直接处理。
_tween_array_add :: (a: $T, b: T) -> T {
    result: T;
    for x, i : a {
        result[i] = x + b[i];
    }
    return result;
}

_tween_array_sub :: (a: $T, b: T) -> T {
    result: T;
    for x, i : a {
        result[i] = x - b[i];
    }
    return result;
}

_tween_array_scale :: (a: $T, s: float32) -> T {
    result: T;
    for x, i : a {
        result[i] = x * s;
    }
    return result;
}

// a + b，标量与定长数组都适用。
tween_add :: (a: $T, b: T) -> T {
    #if T == float32 {
        return a + b;
    } else {
        return _tween_array_add(a, b);
    }
}

// a - b，标量与定长数组都适用。
tween_sub :: (a: $T, b: T) -> T {
    #if T == float32 {
        return a - b;
    } else {
        return _tween_array_sub(a, b);
    }
}

// a * s，标量与定长数组都适用。
tween_scale :: (a: $T, s: float32) -> T {
    #if T == float32 {
        return a * s;
    } else {
        return _tween_array_scale(a, s);
    }
}
//@endregion

// 指数逼近：每秒剩余差距按 exp(-rate) 衰减，帧率无关、不会过冲。
// T 可为 f32 或 [N]f32（如 foster.Vec2）；rate 越大越快，约 4/rate 秒基本到位。
approach :: (current: $T, target: T, rate: float32, dt: float32) -> T {
    return tween_add(current, tween_scale(tween_sub(target, current), 1.0 - exp(-rate * dt)));
}

// 临界阻尼弹簧（同 Unity SmoothDamp）：保留速度，目标移动时平滑转向，任意 dt 下稳定。
// smooth_time 约为到达目标所需时间；velocity 由调用方跨帧保存。dt <= 0 时原样返回。
smooth_damp :: (current: $T, velocity: T, target: T, smooth_time: float32, dt: float32) -> (value: T, next_velocity: T) {
    if dt <= 0 || smooth_time <= 0 {
        // olib: smooth_time <= 0 ? target : current, smooth_time <= 0 ? T{} : velocity
        if smooth_time <= 0 {
            zero: T;
            return target, zero;
        }
        return current, velocity;
    }
    omega := 2.0 / smooth_time;
    x := omega * dt;
    decay := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x);
    change := tween_sub(current, target);
    temp := tween_scale(tween_add(velocity, tween_scale(change, omega)), dt);
    return tween_add(target, tween_scale(tween_add(change, temp), decay)),
           tween_scale(tween_sub(velocity, tween_scale(temp, omega)), decay);
}

// 阻尼弹簧（解析解，任意 dt 稳定）：time 约为到位所需秒数，bounce 0 为临界阻尼不过冲，
// 越接近 1 越弹（阻尼比 = 1 - bounce，上限按 0.95 处理，负值按 0）。
// 与 smooth_damp 同样由调用方跨帧保存 velocity；time <= 0 时立即到位，dt <= 0 时原样返回。
spring :: (current: $T, velocity: T, target: T, time: float32, bounce: float32, dt: float32) -> (value: T, next_velocity: T) {
    if time <= 0 {
        zero: T;
        return target, zero;
    }
    if dt <= 0 {
        return current, velocity;
    }
    omega := 2.0 * PI / time;
    zeta := 1.0 - clamp(bounce, 0.0, 0.95);
    x := tween_sub(current, target);
    decay := exp(-zeta * omega * dt);
    if zeta >= 1.0 {
        c := tween_add(velocity, tween_scale(x, omega));
        return tween_add(target, tween_scale(tween_add(x, tween_scale(c, dt)), decay)),
               tween_scale(tween_sub(velocity, tween_scale(c, omega * dt)), decay);
    }
    wd := omega * sqrt(1.0 - zeta * zeta);
    cs := cos(wd * dt);
    sn := sin(wd * dt);
    b := tween_scale(tween_add(velocity, tween_scale(x, zeta * omega)), 1.0 / wd);
    value := tween_add(target, tween_scale(tween_add(tween_scale(x, cs), tween_scale(b, sn)), decay));
    next_velocity := tween_scale(tween_sub(tween_scale(velocity, cs),
        tween_scale(tween_add(tween_scale(velocity, zeta * omega), tween_scale(x, omega * omega)), sn / wd)), decay);
    return value, next_velocity;
}
