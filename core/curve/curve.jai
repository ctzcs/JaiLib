// curve 提供无分配的三次曲线采样；参数与控制点由调用方持有。
// 一比一移植自 olib core/curve/curve.odin（改编自 Ravn 的 curve 模块）。
//
// Jai 侧差异（行为不变）：
//   - 无 switch，Kind 分派用 if 链；
//   - Jai 没有数组算术，T 为 float32 或 [N] float32 的加/缩放走 curve_add /
//     curve_scale，编译期按 T 分派（ifx），标量路径保持原生运算；
//   - int 字面量不自动转 float32，权重里显式 cast。
#import "Basic";

//@region 向量运算桥接

// 只在 T 为定长数组时实例化；标量由 curve_scale / curve_add 直接处理。
_curve_array_scale :: (a: $T, s: float32) -> T {
    result: T;
    for x, i: a {
        result[i] = x * s;
    }
    return result;
}

_curve_array_add :: (a: $T, b: T) -> T {
    result: T;
    for x, i: a {
        result[i] = x + b[i];
    }
    return result;
}

// a * s，标量与定长数组都适用。
curve_scale :: (a: $T, s: float32) -> T {
    #if T == float32 {
        return a * s;
    } else {
        return _curve_array_scale(a, s);
    }
}

// a + b，标量与定长数组都适用。
curve_add :: (a: $T, b: T) -> T {
    #if T == float32 {
        return a + b;
    } else {
        return _curve_array_add(a, b);
    }
}
//@endregion

//@region 曲线选择

Kind :: enum u8 {
    Linear;
    Bezier;
    Hermite;
    Catmull_Rom;
    B_Spline;
}

sample :: (curve: Kind, points: [4] $T, t: float32) -> T {
    if curve == {
        case .Linear;
            return curve_add(curve_scale(points[0], cast(float32) 1 - t), curve_scale(points[3], t));
        case .Bezier; return sample_bezier(points, t);
        case .Hermite; return sample_hermite_points(points, t);
        case .Catmull_Rom; return sample_catmull_rom(points, t);
        case .B_Spline; return sample_b_spline(points, t);
    }
    return points[0];
}
//@endregion

//@region 三次多项式与采样

// m 的每一列为对应控制值的常数、一次、二次、三次系数。
sample_cubic :: (points: [4] $T, t: float32, m: [4][4] float32) -> T {
    t2 := t * t;
    t3 := t2 * t;
    // olib 的矩阵是 matrix[4,4]，索引 [控制点][幂]；字面量按幂分行。
    // Jai 的 [4][4] 是 [行][列]，因此这里用 m[幂][控制点] 取同一元素。
    result := curve_scale(points[0], m[3][0] * t3 + m[2][0] * t2 + m[1][0] * t + m[0][0]);
    result = curve_add(result, curve_scale(points[1], m[3][1] * t3 + m[2][1] * t2 + m[1][1] * t + m[0][1]));
    result = curve_add(result, curve_scale(points[2], m[3][2] * t3 + m[2][2] * t2 + m[1][2] * t + m[0][2]));
    result = curve_add(result, curve_scale(points[3], m[3][3] * t3 + m[2][3] * t2 + m[1][3] * t + m[0][3]));
    return result;
}

// Shapes, fonts, vector graphics.
// C0/C1 continuity.
// Manual tangents.
sample_bezier :: (points: [4] $T, t: float32) -> T {
    M: [4][4] float32 = .[
        .[+1, +0, +0, +0],
        .[-3, +3, +0, +0],
        .[+3, -6, +3, +0],
        .[-1, +3, -3, +1],
    ];
    return sample_cubic(points, t, M);
}

// Animation, physics sim, interpolation.
// C0/C1 continuity.
sample_hermite_points :: (points: [4] $T, t: float32) -> T {
    // Jai 没有数组减法，用 + 乘 -1 表达同一语义（标量与向量都适用）。
    values: [4] T = .[
        points[0],
        curve_add(points[1], curve_scale(points[0], -1)),
        points[3],
        curve_add(points[3], curve_scale(points[2], -1)),
    ];
    return sample_hermite_tangents(values, t);
}

// Based on two points with velocities.
// Explicit tangents.
// Values are [p0, v0, p1, v1]
sample_hermite_tangents :: (values: [4] $T, t: float32) -> T {
    M: [4][4] float32 = .[
        .[+1, +0, +0, +0],
        .[+0, +1, +0, +0],
        .[-3, -2, +3, -1],
        .[+2, +1, -2, +1],
    ];
    return sample_cubic(values, t, M);
}

sample_hermite :: (pos0, vel0, pos1, vel1: $T, t: float32) -> T {
    values: [4] T = .[pos0, vel0, pos1, vel1];
    return sample_hermite_tangents(values, t);
}

// Animation and paths.
// C1 continuity.
// Automatic tangents.
sample_catmull_rom :: (points: [4] $T, t: float32) -> T {
    M: [4][4] float32 = .[
        .[+0, +2, +0, +0],
        .[-1, +0, +1, +0],
        .[+2, -5, +4, -1],
        .[-1, +3, -3, +1],
    ];
    return curve_scale(sample_cubic(points, t, M), 0.5);
}

// Catmull rom with configurable scale factor.
sample_cardinal :: (points: [4] $T, t: float32, scale: float32) -> T {
    s := scale;
    two_s := s * 2;
    two := cast(float32) 2;
    three := cast(float32) 3;
    m: [4][4] float32 = .[
        .[0, 1, 0, 0],
        .[-s, 0, s, 0],
        .[two_s, s - three, three - two_s, -s],
        .[-s, two - s, s - two, s],
    ];
    return sample_cubic(points, t, m);
}

// Curvature-sensitive shapes, animations, camera paths.
// C2 continuity.
// Automatic tangents.
sample_b_spline :: (points: [4] $T, t: float32) -> T {
    M: [4][4] float32 = .[
        .[+1, +4, +1, +0],
        .[-3, +0, +3, +0],
        .[+3, -6, +3, +0],
        .[-1, +3, -3, +1],
    ];
    return curve_scale(sample_cubic(points, t, M), cast(float32) (1.0 / 6.0));
}
//@endregion
