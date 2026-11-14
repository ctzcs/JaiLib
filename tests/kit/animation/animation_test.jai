// kit/animation 回归测试 —— 一比一移植自 olib `tests/kit/animation/animation_test.odin`（211 行）。
//
// 组织方式与 olib 对位：每个 @(test) 对应一个过程，过程名不变，断言顺序与 olib
// 一一对应；签名统一 `(state: *Test_State)`（由 Tests/kit/run_kit_tests.jai 调度），
// 用 Tests/test_support.jai 的 expect。本文件不写 main。
//
// Jai 侧差异（断言语义不变）：
//   | olib (Odin)                                | 这里 (Jai)                                              |
//   | ------------------------------------------ | ------------------------------------------------------- |
//   | testing.expect(t, cond)                     | expect(state, cond, "说明")                              |
//   | testing.expectf(t, cond, fmt, ..)           | expect(state, cond, "说明 %", args)                      |
//   | math.abs / math.sqrt                        | math.abs / math.sqrt（具名导入 Math）                    |
//   | make([]T, n) + defer delete                 | anim_test_make(T, n)（[..] T + array_resize）+ array_free |
//   | append(&skel.joints, joint)                  | array_add(*skel.joints, joint)                           |
//   | m: [16]f32（Odin 零值初始化）                 | 显式写满 16 个 0 的字面量（Jai 不保证局部变量清零）        |
//   | a == b（[3]f32 逐元素）                       | anim_test_v3_equal(a, b) 逐分量比较                       |
//   | Joint_Pose 逐字段 ==                          | A.joint_pose_equal / A.operator ==（见 animation.jai）     |
//   | sample_pose(&skel, nil, 0, pose)             | sample_pose(*skel, null, 0, pose)                        |
//   | skinned_bounds(bb, nil)                      | 传一个零值切片变量（Jai 的切片零值即 count=0）             |
//   | f32 字面量（0.25、1、-0.3）隐式转 f32           | 同形；speed/duration 位置上的整数字面量按 f32 常量收窄     |
#import "Basic";
math :: #import "Math";
#import "test_support";
A :: #import "kit/animation";
D :: #import "core/dasset";
W :: #import "kit/world";

//@region 夹具

// 两关节链：root(bind 平移 1,0,0) -> child(bind 平移 0,2,0)，均单位逆绑定。
make_chain :: () -> D.Dasset_Skeleton {
    skel: D.Dasset_Skeleton;

    root: D.Dasset_Joint;
    root.name = "root";
    root.parent_index = -1;
    root.bind_translation = .[1, 0, 0];
    root.bind_rotation = .[0, 0, 0, 1];
    root.bind_scale = .[1, 1, 1];
    root.inverse_bind_matrix = translation16(-1, 0, 0); // bind 全局 T(1,0,0) 的逆
    array_add(*skel.joints, root);

    child: D.Dasset_Joint;
    child.name = "child";
    child.parent_index = 0;
    child.bind_translation = .[0, 2, 0];
    child.bind_rotation = .[0, 0, 0, 1];
    child.bind_scale = .[1, 1, 1];
    child.inverse_bind_matrix = translation16(-1, -2, 0); // bind 全局 T(1,2,0) 的逆
    array_add(*skel.joints, child);
    return skel;
}

translation16 :: (x: float32, y: float32, z: float32) -> [16] float32 {
    // System.Numerics 行主序：平移在 row4（下标 12/13/14）
    m: [16] float32 = .[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    m[0] = 1;
    m[5] = 1;
    m[10] = 1;
    m[15] = 1;
    m[12] = x;
    m[13] = y;
    m[14] = z;
    return m;
}

// olib 的 make([]T, n)：[..] T + array_resize（initialize=true，与 Odin 的 make 一样清零）。
anim_test_make :: ($T: Type, count: int) -> [..] T {
    result: [..] T;
    if count > 0 {
        array_resize(*result, count);
    }
    return result;
}

// Jai 的数组不能用 ==：定点数组逐分量比较（NaN 各自不相等，与 Odin 的 == 一致）。
anim_test_v3_equal :: (a: [3] float32, b: [3] float32) -> bool {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}

anim_test_quat_len :: (q: [4] float32) -> float32 {
    return math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
}

expect_identity :: (state: *Test_State, m: W.Matrix4) {
    for col: 0..3 {
        for row: 0..3 {
            want: float32 = 0;
            if col == row {
                want = 1;
            }
            got := W.matrix4_column(m, col)[row];
            expect(state, math.abs(got - want) < 1e-5, "(%d,%d) % != %", row, col, got, want);
        }
    }
}
//@endregion

//@region 采样

sample_pose_bind_and_override :: (state: *Test_State) {
    skel := make_chain();
    defer {
        if skel.joints.data != null {
            array_free(skel.joints);
        }
    }

    pose := anim_test_make(A.Joint_Pose, 2);
    defer {
        if pose.data != null {
            array_free(pose);
        }
    }

    // 无 clip：纯 bind pose
    A.sample_pose(*skel, null, 0, pose);
    expect(state, anim_test_v3_equal(pose[0].translation, .[1, 0, 0]), "root bind 平移: %", pose[0].translation);
    expect(state, anim_test_v3_equal(pose[1].translation, .[0, 2, 0]), "child bind 平移: %", pose[1].translation);

    // clip：root 的平移 channel，两键 0s(0,0,0) -> 1s(10,0,0)
    clip: D.Dasset_Animation_Clip;
    clip.duration = 1;
    ch: D.Dasset_Animation_Channel;
    ch.joint_index = 0;
    ch.path = .Translation;
    ch.interpolation = .Linear;
    ch.times = anim_test_make(float32, 2);
    ch.times[1] = 1;
    ch.values = anim_test_make([4] float32, 2);
    ch.values[1] = .[10, 0, 0, 0];
    defer {
        if ch.times.data != null {
            array_free(ch.times);
        }
        if ch.values.data != null {
            array_free(ch.values);
        }
        if clip.channels.data != null {
            array_free(clip.channels);
        }
    }
    array_add(*clip.channels, ch);

    A.sample_pose(*skel, *clip, 0.25, pose);
    expect(state, math.abs(pose[0].translation[0] - 2.5) < 1e-5, "线性插值 25\%: %", pose[0].translation);

    // 越界 clamp 到端点
    A.sample_pose(*skel, *clip, 99, pose);
    expect(state, pose[0].translation[0] == 10, "越界右端应 clamp 到 10: %", pose[0].translation[0]);
    A.sample_pose(*skel, *clip, -1, pose);
    expect(state, pose[0].translation[0] == 0, "越界左端应 clamp 到 0: %", pose[0].translation[0]);
}

sample_channel_interpolations :: (state: *Test_State) {
    // 平移线性
    lin: D.Dasset_Animation_Channel;
    lin.path = .Translation;
    lin.interpolation = .Linear;
    lin.times = anim_test_make(float32, 3);
    lin.times[1] = 1;
    lin.times[2] = 2;
    lin.values = anim_test_make([4] float32, 3);
    lin.values[1] = .[10, 0, 0, 0];
    lin.values[2] = .[20, 0, 0, 0];
    defer {
        if lin.times.data != null {
            array_free(lin.times);
        }
        if lin.values.data != null {
            array_free(lin.values);
        }
    }

    v := A.sample_channel(*lin, 1.5);
    expect(state, math.abs(v[0] - 15) < 1e-5, "线性中点应 15: %", v[0]);

    // Step 保持前键
    lin.interpolation = .Step;
    vs := A.sample_channel(*lin, 1.9);
    expect(state, vs[0] == 10, "Step 应保持前键 10: %", vs[0]);

    // 旋转走最短弧：180° 绕 Z 的两键，t=0.5 应得到 ~127°（不是绕远路）
    rot: D.Dasset_Animation_Channel;
    rot.path = .Rotation;
    rot.interpolation = .Linear;
    rot.times = anim_test_make(float32, 2);
    rot.times[1] = 1;
    rot.values = anim_test_make([4] float32, 2);
    // jacket 会提示 0.70710678 收窄成 f32 的 0.7071067690849304；cast 后与 Odin 的隐式转换同值
    rot.values[1] = .[0, 0, cast(float32) 0.70710678, cast(float32) 0.70710678]; // 90° 绕 Z
    defer {
        if rot.times.data != null {
            array_free(rot.times);
        }
        if rot.values.data != null {
            array_free(rot.values);
        }
    }
    vr := A.sample_channel(*rot, 0.5);
    half: float32 = 0.38268343; // sin(22.5°)：0->90° 绕 Z 的半程
    expect(state, math.abs(math.abs(vr[2]) - half) < 1e-4, "半程应约 45°: %", vr);
    expect(state, math.abs(anim_test_quat_len(vr) - 1) < 1e-5, "四元数应已归一化: %", anim_test_quat_len(vr));

    // 翻转分支：b 取负四元数应走同一弧
    rot.values[1] = .[0, 0, cast(float32) -0.70710678, cast(float32) -0.70710678];
    vf := A.sample_channel(*rot, 0.5);
    expect(state, math.abs(math.abs(vf[2]) - half) < 1e-4, "翻转后端半程应同样约 45°: %", vf);
}
//@endregion

//@region palette

compute_palette_identity_when_pose_matches_bind :: (state: *Test_State) {
    skel := make_chain();
    defer {
        if skel.joints.data != null {
            array_free(skel.joints);
        }
    }

    palette := anim_test_make(W.Matrix4, 2);
    defer {
        if palette.data != null {
            array_free(palette);
        }
    }
    n := A.compute_palette_sampled(*skel, null, 0, palette);
    expect(state, n == 2, "compute_palette_sampled 应返回 2: %", n);

    // bind pose 采样 + 单位逆绑定 => 每个 palette 都应是单位阵
    for i: 0..1 {
        expect_identity(state, palette[i]);
    }
}
//@endregion

//@region 时间与混合

advance_time_loop_and_clamp :: (state: *Test_State) {
    expect(state, math.abs(A.advance_time(0.75, 0.5, 1, true, 1) - 0.25) < 1e-6, "回绕应回到 0.25");
    expect(state, math.abs(A.advance_time(0.2, 1, 1, false, 1) - 1) < 1e-6, "非循环应钳到末尾 1");
    expect(state, math.abs(A.advance_time(0, 1, -0.3, true, 1) - 0.7) < 1e-6, "负速度应回绕到 0.7");
    expect(state, math.abs(A.advance_time(0, 5, 1, false, 0) - 5) < 1e-6, "零时长不动，应为 5");
}

blend_poses_and_bounds :: (state: *Test_State) {
    a := anim_test_make(A.Joint_Pose, 1);
    b := anim_test_make(A.Joint_Pose, 1);
    r := anim_test_make(A.Joint_Pose, 1);
    defer {
        if a.data != null {
            array_free(a);
        }
        if b.data != null {
            array_free(b);
        }
        if r.data != null {
            array_free(r);
        }
    }
    a[0].translation = .[0, 0, 0];
    b[0].translation = .[10, 0, 0];
    a[0].scale = .[1, 1, 1];
    b[0].scale = .[1, 1, 1];
    a[0].rotation = .[0, 0, 0, 1];
    b[0].rotation = .[0, 0, 0, 1];

    A.blend_poses(a, b, 0.25, r);
    expect(state, math.abs(r[0].translation[0] - 2.5) < 1e-5, "混合 25\% 应 2.5: %", r[0].translation);

    // 蒙皮包围盒：bind 盒 {0..1} 经单位 palette 变换不变
    bb: D.Dasset_Bounds = .{ min = .[0, 0, 0], max = .[1, 1, 1] };
    palette := anim_test_make(W.Matrix4, 1);
    defer {
        if palette.data != null {
            array_free(palette);
        }
    }
    palette[0] = W.MATRIX4_IDENTITY;
    sb := A.skinned_bounds(bb, palette);
    expect(state, anim_test_v3_equal(sb.min, bb.min) && anim_test_v3_equal(sb.max, bb.max),
    "单位 palette 下包围盒不变: % - %", sb.min, sb.max);

    // olib 的 skinned_bounds(bb, nil)
    empty_palette: [] W.Matrix4;
    empty := A.skinned_bounds(bb, empty_palette);
    expect(state, anim_test_v3_equal(empty.min, bb.min), "空 palette 应原样返回 bind 盒: %", empty.min);
}
//@endregion

// Loop scopes adapted.
