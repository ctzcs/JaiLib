// animation —— 骨骼动画的采样与 palette 计算（对位 DragonLib Engine.Animation.SkeletonAnimator）。
// 一比一移植自 olib kit/animation/animation.odin（282 行）：过程名、参数顺序、返回语义、
// 分支顺序与数值阈值全部照抄，注释沿用 olib 的中文原文。
//
// 纯计算，无 GPU/ECS 依赖（可单测）。矩阵为行向量约定（v*M，同 kit/world）：
// 本地姿态 -> 沿拓扑序传播全局矩阵（global = local * parent_global）->
// palette[i] = InverseBind[i] * global[i]。
//
// 多剪辑状态机、morph target 和根运动由游戏层另行实现。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   | olib (Odin)                                   | JaiLib (Jai)                                               |
//   | --------------------------------------------- | ---------------------------------------------------------- |
//   | package animation + import dasset/world/math   | module.jai 里 `dasset :: #import "core/dasset"` 等三个      |
//   |                                               | 具名导入，限定符与 olib 同名                                |
//   | math.clamp(x, lo, hi)                         | clamp(x, lo, hi)（Basic 内建；Math 只导出 clamp_in_place）  |
//   | math.floor / acos / sin / sqrt / abs          | math.floor / acos / sin / sqrt / abs（jacket Math 同名）     |
//   | f32 常量 1e-12、0.1                           | 显式 `cast(float32) 1.0e-12`（避免 f64 常量参与比较的类型歧义）|
//   | switch x { case .A: }                         | if-switch：`if x == { case .A; ... }`                       |
//   | #partial switch x { case .Step: }             | 同上，且不写 `case;` 分支 —— 落空即走到末尾的线性实现（同义） |
//   | cond ? a : b                                  | 无三元运算：先声明变量再 if/else（语句块不能写成 ifx）        |
//   | a + b、a * s（向量加减/乘标量）                 | Jai 没有数组算术：olib 本模块的向量/四元数运算是手写逐分量，     |
//   |                                               | 这里保持逐下标手写（animation_v3_lerp / _quat_normalize）     |
//   | `ifx` 编译期选择                                | 本模块没有任何编译期分支，运行期一律 if/else —— ifx 只用于编译期 |
//   | len(slice) / len(array)                       | slice.count（[]T 与 [..]T 都是 {count, data}）              |
//   | for i in 0..<n                                | for i: 0..n - 1（Jai 的 a..b 含终点；n=0 时零次迭代）       |
//   | for &channel in clip.channels                 | for *channel: clip.channels（channel 是指针，字段自动解引用）|
//   | [3]f32{a, b, c} / [4]f32{...}                 | `.[a, b, c]`（有期望类型，省掉类型前缀）                     |
//   | Joint_Pose{...} / Dasset_Bounds{...}          | Joint_Pose.{...} / dasset.Dasset_Bounds.{...}               |
//   | a == b（[3]f32、[4]f32 逐元素）                | Jai 数组不能用 `==`：joint_pose_equal / operator == 逐分量比 |
//   | 结构体默认逐字段 ==                            | 同上（Jai 要求显式 operator，见 kit/world 的 matrix4_equal） |
//   | foster.Vec3（= [3]f32，可下标）                | world.Vec3（= Math.Vector3，字段 .x/.y/.z）—— 调用处拆/装分量 |
//   | 四元数就是裸 [4]f32（无专用类型）               | 同样是 [4] float32，slerp/nlerp 手写（不经 Math.Quaternion）  |
//   | pose == nil / palette 为 nil                   | 空切片判 `.count == 0`（Jai 的切片零值即 {count=0}）         |
//   | make([dynamic]T, 0, n) + append                | [..] T + array_reserve / array_add，末尾 array_free          |
//   | make([]T, n) + delete                          | [..] T + array_resize，末尾 array_free                      |
//   | 过程内嵌套 proc finish                          | 提到模块级 animation_finish_sample（Jai 不能嵌套过程）        |
//   | @(private) 内部过程                             | 加 animation_ 前缀（Jai 无 @(private)，见 docs/PORTING.md）  |
#import "Basic";

// shader 侧 joint palette 的容量上限（skinned shader 的 MAX_JOINTS）。
ANIMATION_MAX_JOINTS :: 128;

//@region 类型

// 一个关节某一帧的本地姿态（TRS）。
Joint_Pose :: struct {
    translation: [3] float32;
    rotation: [4] float32; // 四元数 xyzw
    scale: [3] float32;
}

// olib 里 `pose[i] == Joint_Pose{...}` 靠 Odin 为结构体生成的逐字段 ==；Jai 既不自动
// 生成结构体 ==，也不允许数组 ==，所以显式给出：逐分量比较（-0 与 +0 相等、NaN 各自
// 不相等，与 Odin 的 == 语义一致）。
joint_pose_equal :: (a: Joint_Pose, b: Joint_Pose) -> bool {
    return a.translation[0] == b.translation[0] &&
           a.translation[1] == b.translation[1] &&
           a.translation[2] == b.translation[2] &&
           a.rotation[0] == b.rotation[0] &&
           a.rotation[1] == b.rotation[1] &&
           a.rotation[2] == b.rotation[2] &&
           a.rotation[3] == b.rotation[3] &&
           a.scale[0] == b.scale[0] &&
           a.scale[1] == b.scale[1] &&
           a.scale[2] == b.scale[2];
}

// Jai 的运算符按词法作用域解析；跨模块使用要写 A.operator ==(...) 或直接调 equal。
operator == :: (a: Joint_Pose, b: Joint_Pose) -> bool {
    return joint_pose_equal(a, b);
}
//@endregion

//@region 采样

// 采样剪辑得到逐关节本地姿态：先填 bind pose，再按 channel 覆盖（时间越界
// clamp 到端点）。循环回绕由调用侧处理（time 先对 duration 取模）。
// clip 为 nil 时输出纯 bind pose。
sample_pose :: (
    skeleton: *dasset.Dasset_Skeleton,
    clip:     *dasset.Dasset_Animation_Clip,
    time:     float32,
    pose:     [] Joint_Pose,
) {
    if pose.count == 0 { return; }
    for i: 0..skeleton.joints.count - 1 {
        if i >= pose.count { break; }
        // olib 的 `joint := &skeleton.joints[i]`：只读，直接取字段即可。
        pose[i] = Joint_Pose.{
            translation = skeleton.joints[i].bind_translation,
            rotation    = skeleton.joints[i].bind_rotation,
            scale       = skeleton.joints[i].bind_scale,
        };
    }
    if clip == null { return; }

    for *channel: clip.channels {
        if channel.joint_index < 0 || cast(int) channel.joint_index >= skeleton.joints.count { continue; }
        if cast(int) channel.joint_index >= pose.count { continue; }
        value := sample_channel(channel, time);
        joint_pose := *pose[cast(int) channel.joint_index];
        if channel.path == {
            case .Translation;
                joint_pose.translation = .[value[0], value[1], value[2]];
            case .Rotation;
                joint_pose.rotation = value;
            case .Scale;
                joint_pose.scale = .[value[0], value[1], value[2]];
        }
    }
}

// 采样一条 channel。STEP 保持前键；cubic 切线按区间秒数缩放；
// 四元数按 glTF 要求插值后归一化。
sample_channel :: (channel: *dasset.Dasset_Animation_Channel, time: float32) -> [4] float32 {
    times := channel.times;
    values := channel.values;
    if times.count == 0 {
        // olib 的三元 `path == .Rotation ? {0,0,0,1} : {0,0,0,0}`
        if channel.path == .Rotation { return .[0, 0, 0, 1]; }
        return .[0, 0, 0, 0];
    }

    if times.count == 1 || time <= times[0] {
        return animation_finish_sample(values[0], channel.path == .Rotation);
    }
    last := times.count - 1;
    if time >= times[last] {
        return animation_finish_sample(values[last], channel.path == .Rotation);
    }

    segment := 0;
    // olib: for segment+1 < len(times) && times[segment+1] <= time
    while segment + 1 < times.count && times[segment + 1] <= time {
        segment += 1;
    }
    dt := times[segment + 1] - times[segment];
    t: float32;
    if dt > 0 { t = (time - times[segment]) / dt; } else { t = 0; }

    // olib 这里是 #partial switch（Linear 不列分支，落到末尾的线性实现）；
    // Jai 的 if-switch 不写 `case;` 即同样落空。
    if channel.interpolation == {
        case .Step;
            return animation_finish_sample(values[segment], channel.path == .Rotation);
        case .Cubic_Spline;
            // glTF cubic-spline hermite：切线按区间秒数缩放
            t2 := t * t;
            t3 := t2 * t;
            h00 := 2 * t3 - 3 * t2 + 1;
            h10 := t3 - 2 * t2 + t;
            h01 := -2 * t3 + 3 * t2;
            h11 := t3 - t2;
            res: [4] float32;
            for c: 0..3 {
                res[c] = h00 * values[segment][c] +
                    h10 * dt * channel.out_tangents[segment][c] +
                    h01 * values[segment + 1][c] +
                    h11 * dt * channel.in_tangents[segment + 1][c];
            }
            return animation_finish_sample(res, channel.path == .Rotation);
    }

    if channel.path == .Rotation {
        return animation_quat_shortest_slerp(values[segment], values[segment + 1], t);
    }
    // 线性
    res: [4] float32;
    for c: 0..3 {
        res[c] = values[segment][c] * (1 - t) + values[segment + 1][c] * t;
    }
    return res;
}
//@endregion

//@region palette

// 由本地姿态算 joint palette：joints 已按拓扑序（父先于子），一次线性扫描
// 传播。palette 长度不足关节数时只写前 len(palette) 个。
compute_palette :: (skeleton: *dasset.Dasset_Skeleton, pose: [] Joint_Pose, palette: [] world.Matrix4) {
    count := min(skeleton.joints.count, palette.count);
    // olib 的 make([dynamic]world.Matrix4, 0, len(skeleton.joints))
    globals: [..] world.Matrix4;
    if count > 0 { array_reserve(*globals, count); }
    defer { if globals.data != null { array_free(globals); } }

    for i: 0..count - 1 {
        local := world.matrix4_multiply(
            world.matrix4_scaling(pose[i].scale[0], pose[i].scale[1], pose[i].scale[2]),
            world.matrix4_multiply(
                world.matrix4_from_quaternion(pose[i].rotation),
                world.matrix4_translation(pose[i].translation[0], pose[i].translation[1], pose[i].translation[2]),
            ),
        );
        global := local;
        parent_index := skeleton.joints[i].parent_index;
        if parent_index >= 0 && cast(int) parent_index < i {
            global = world.matrix4_multiply(local, globals[cast(int) parent_index]);
        }
        array_add(*globals, global);
        palette[i] = world.matrix4_multiply(
            world.matrix4_from_row_major(skeleton.joints[i].inverse_bind_matrix),
            global,
        );
    }
}

// 一步到位：采样 + 传播 + palette。返回实际写入的矩阵数。
compute_palette_sampled :: (
    skeleton: *dasset.Dasset_Skeleton,
    clip:     *dasset.Dasset_Animation_Clip,
    time:     float32,
    palette:  [] world.Matrix4,
) -> int {
    // olib 的 make([]Joint_Pose, len(skeleton.joints)) + defer delete(pose)
    pose: [..] Joint_Pose;
    if skeleton.joints.count > 0 { array_resize(*pose, skeleton.joints.count); }
    defer { if pose.data != null { array_free(pose); } }

    sample_pose(skeleton, clip, time, pose);
    compute_palette(skeleton, pose, palette);
    return min(skeleton.joints.count, palette.count);
}
//@endregion

//@region 时间与混合

// 推进播放时间：循环回绕（负速度也落回 [0, duration)），
// 非循环钳到 [0, duration] 停住。
advance_time :: (time_: float32, delta: float32, speed: float32, loop: bool, duration: float32) -> float32 {
    time := time_;
    time += delta * speed;
    if duration <= cast(float32) 1.0e-6 { return time; }
    if loop {
        return time - math.floor(time / duration) * duration;
    }
    return clamp(time, 0, duration);
}

// 两姿态线性混合（旋转走最短弧 slerp）。t 钳到 [0,1]。
blend_poses :: (a_: [] Joint_Pose, b_: [] Joint_Pose, t_: float32, result: [] Joint_Pose) {
    if a_.count != b_.count || result.count < a_.count { return; }
    t := clamp(t_, 0, 1);
    for i: 0..a_.count - 1 {
        result[i] = Joint_Pose.{
            translation = animation_v3_lerp(a_[i].translation, b_[i].translation, t),
            scale       = animation_v3_lerp(a_[i].scale, b_[i].scale, t),
            rotation    = animation_quat_shortest_slerp(a_[i].rotation, b_[i].rotation, t),
        };
    }
}
//@endregion

//@region 蒙皮包围盒

// 保守包围当前蒙皮姿态：非负归一化混权是各关节变换点的凸组合，
// 落在联合 AABB 内。
skinned_bounds :: (bind_bounds: dasset.Dasset_Bounds, palette: [] world.Matrix4) -> dasset.Dasset_Bounds {
    if palette.count == 0 { return bind_bounds; }
    result := dasset.DASSET_BOUNDS_EMPTY;
    for *m: palette {
        result = animation_bounds_encapsulate(result, animation_bounds_transformed(bind_bounds, m));
    }
    return result;
}
//@endregion

//@region 内部 —— 四元数 / 向量辅助

// olib 里 sample_channel 内部嵌套的 proc finish（Jai 不能嵌套过程）。
animation_finish_sample :: (v: [4] float32, is_rotation: bool) -> [4] float32 {
    if !is_rotation { return v; }
    return animation_quat_normalize(v);
}

animation_quat_normalize :: (q: [4] float32) -> [4] float32 {
    l2 := q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    if l2 <= cast(float32) 1.0e-12 {
        return .[0, 0, 0, 1];
    }
    l := math.sqrt(l2);
    return .[q[0] / l, q[1] / l, q[2] / l, q[3] / l];
}

animation_quat_dot :: (a: [4] float32, b: [4] float32) -> float32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

// 最短弧 slerp：先归一化，负点积翻转 b，再 slerp 后归一化。
animation_quat_shortest_slerp :: (a_: [4] float32, b_: [4] float32, t: float32) -> [4] float32 {
    a := animation_quat_normalize(a_);
    b := animation_quat_normalize(b_);
    if animation_quat_dot(a, b) < 0 {
        b = .[-b[0], -b[1], -b[2], -b[3]];
    }
    cos_theta := clamp(animation_quat_dot(a, b), cast(float32) -1, cast(float32) 1);
    theta := math.acos(cos_theta);
    if theta < cast(float32) 1.0e-4 {
        // 角度极小走 nlerp，避免除零
        out: [4] float32 = .[
            a[0] * (1 - t) + b[0] * t,
            a[1] * (1 - t) + b[1] * t,
            a[2] * (1 - t) + b[2] * t,
            a[3] * (1 - t) + b[3] * t,
        ];
        return animation_quat_normalize(out);
    }
    sin_theta := math.sin(theta);
    wa := math.sin((1 - t) * theta) / sin_theta;
    wb := math.sin(t * theta) / sin_theta;
    return animation_quat_normalize(.[a[0] * wa + b[0] * wb, a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb]);
}

animation_v3_lerp :: (a: [3] float32, b: [3] float32, t: float32) -> [3] float32 {
    return .[a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

animation_bounds_encapsulate :: (a: dasset.Dasset_Bounds, b: dasset.Dasset_Bounds) -> dasset.Dasset_Bounds {
    // 结构体字面量的 key 也叫 min/max，与内建 min/max 同形；先算出再逐字段写更稳。
    result: dasset.Dasset_Bounds;
    result.min = .[min(a.min[0], b.min[0]), min(a.min[1], b.min[1]), min(a.min[2], b.min[2])];
    result.max = .[max(a.max[0], b.max[0]), max(a.max[1], b.max[1]), max(a.max[2], b.max[2])];
    return result;
}

// 8 角点逐个变换后重新包围（保守正确，供视锥剔除用）。
animation_bounds_transformed :: (b: dasset.Dasset_Bounds, m: world.Matrix4) -> dasset.Dasset_Bounds {
    result := dasset.DASSET_BOUNDS_EMPTY;
    for i: 0..7 {
        // olib 的 `(i & 1) == 0 ? b.min[0] : b.max[0]`（无三元运算）
        corner: [3] float32;
        if (i & 1) == 0 { corner[0] = b.min[0]; } else { corner[0] = b.max[0]; }
        if (i & 2) == 0 { corner[1] = b.min[1]; } else { corner[1] = b.max[1]; }
        if (i & 4) == 0 { corner[2] = b.min[2]; } else { corner[2] = b.max[2]; }
        p, ok := world.matrix4_transform_point(m, world.Vec3.{ corner[0], corner[1], corner[2] });
        if ok {
            point := dasset.Dasset_Bounds.{ min = .[p.x, p.y, p.z], max = .[p.x, p.y, p.z] };
            result = animation_bounds_encapsulate(result, point);
        }
    }
    return result;
}
//@endregion
