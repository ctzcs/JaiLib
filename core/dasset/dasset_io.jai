// dasset:io —— .dasset 二进制读写（对位 DragonLib DassetReader / DassetWriter）。
// 一比一移植自 olib core/dasset/dasset_io.odin。
//
// 比特兼容 DragonLib 的 v4 布局（little-endian；字符串为 7-bit 变长前缀 +
// UTF-8，同 C# BinaryWriter.ReadString）。Reader 兼容 v1..v4：
// v1 无骨架/剪辑段、primitive 无布局前缀、材质无 v3 字段、channel 无 v4 插值。
// 计数与剩余长度做 sanity 检查，坏文件不产生巨额分配。
//
// 所有权：dasset_read 产出的 model 深拷贝全部字符串/数组，
// 用 dasset_model_dispose 释放；dasset_write 产出的字节块由调用方释放。
//
// Jai 侧差异（二进制布局与语义不变，逐条对应 olib）：
//   - i32 → s32，f32 → float32，[]T → [] T，[dynamic]T → [..] T，^T → *T，nil → null；
//     游标 `^int` 写 `*s64`（Jai 的 int 就是 64 位有符号，这里显式写 s64）；
//   - 指针取值写 `p.*`（Odin 的 `p^`），取址写 `*x`（Odin 的 `&x`）；传给 *T 形参时
//     直接传指针变量本身（Jai 不做隐式取址，`array_add(out, ...)` 而不是 `array_add(*out, ...)`）；
//   - **循环区间两端都含**：Odin 的 `for i in 0..<n` 在 Jai 里写 `for 0..n - 1`
//     （Jai 的 `a..b` 是闭区间，直接照抄 `0..n` 会多跑一次，n==0 时还会越界）；
//   - **没有 cast 的隐式截断**：Jai 的 cast 对编译期常量做溢出检查（魔数 0x54534144
//     进不了 u8、-1 进不了 u32），比特层面的截断/重解释一律写 `cast,trunc`；
//   - Jai 没有数组切片区间语法（`data[a:b]`），等价的视图用 array_view / slice 字面量
//     `.{count, data}` 构造；r_count 已保证区间在界内，语义与 olib 的切片相同；
//   - Jai 没有 `mem.copy`，字节拷贝用 memcpy；没有 `make`/`delete`，用
//     dasset_alloc_array（alloc + memset 清零，等价于 make）+ free；
//     Odin 的 strings.clone 用 copy_string；free 不接受空指针，dispose 逐个判空；
//   - f32 与 u32 的比特重解释没有 transmute，用 4 字节 union（与 odin transmute 等价）；
//   - Jai 没有三目运算符：`cond ? a : b` 改成分支语句；
//   - 没有 `if !proc(...) { return }` 这种「用无返回值过程做条件」的写法（见测试）；
//   - dasset_write 返回 `[..] u8`（Odin 返回 []u8 视图）；两者都指向同一块内存，
//     返回动态数组只是为了让调用方能按分配时的 allocator 调 array_free；
//   - `*x` 取址、`x.*` 取值；指针型结构体的字段里再取址（`*p.field`）会被解析成
//     `(*p).field`，所以读入时用「下标 + 本地切片」而不是「指针 + 取址」；
//   - 结构体字面量里两次读取（如 bounds 的 min/max）改成两条语句，不依赖字面量内的
//     求值顺序；其余读写顺序与 olib 逐行一致。
#import "Basic";

//@region 写出

// 把 model 编成 .dasset 字节块（当前 v4；分配于 context.allocator）。
dasset_write :: (model: *Dasset_Model) -> ([..] u8, bool) {
    out: [..] u8;

    dasset_w_u32(*out, DASSET_MAGIC);
    dasset_w_i32(*out, DASSET_VERSION);

    // 贴图表
    dasset_w_i32(*out, cast(s32) model.textures.count);
    for tex: model.textures {
        dasset_w_string(*out, tex.name);
        dasset_w_i32(*out, cast(s32) tex.codec);
        dasset_w_i32(*out, cast(s32) tex.bytes.count);
        for b: tex.bytes {
            array_add(*out, b);
        }
    }

    // 骨架表
    dasset_w_i32(*out, cast(s32) model.skeletons.count);
    for skel: model.skeletons {
        dasset_w_i32(*out, cast(s32) skel.joints.count);
        for joint: skel.joints {
            dasset_w_string(*out, joint.name);
            dasset_w_i32(*out, joint.parent_index);
            dasset_w_vec3(*out, joint.bind_translation);
            dasset_w_vec4(*out, joint.bind_rotation);
            dasset_w_vec3(*out, joint.bind_scale);
            for f: joint.inverse_bind_matrix {
                dasset_w_f32(*out, f);
            }
        }
    }

    // primitives
    dasset_w_i32(*out, cast(s32) model.primitives.count);
    for 0..model.primitives.count - 1 {
        p := *model.primitives[it];
        skinned := dasset_primitive_is_skinned(p);
        layout: Dasset_Vertex_Layout = .Position_Normal_Uv;
        if skinned layout = .Position_Normal_Uv_Skin;
        dasset_w_i32(*out, cast(s32) layout);
        dasset_w_i32(*out, p.skin_index);
        if skinned {
            dasset_w_i32(*out, cast(s32) p.skin_vertices.count);
            for v: p.skin_vertices {
                dasset_w_f32(*out, v.position[0]);
                dasset_w_f32(*out, v.position[1]);
                dasset_w_f32(*out, v.position[2]);
                dasset_w_f32(*out, v.normal[0]);
                dasset_w_f32(*out, v.normal[1]);
                dasset_w_f32(*out, v.normal[2]);
                dasset_w_f32(*out, v.uv[0]);
                dasset_w_f32(*out, v.uv[1]);
                for f: v.tangent {
                    dasset_w_f32(*out, f);
                }
                dasset_w_u32(*out, v.joints);
                for f: v.weights {
                    dasset_w_f32(*out, f);
                }
            }
        } else {
            dasset_w_i32(*out, cast(s32) p.vertices.count);
            for v: p.vertices {
                dasset_w_f32(*out, v.position[0]);
                dasset_w_f32(*out, v.position[1]);
                dasset_w_f32(*out, v.position[2]);
                dasset_w_f32(*out, v.normal[0]);
                dasset_w_f32(*out, v.normal[1]);
                dasset_w_f32(*out, v.normal[2]);
                dasset_w_f32(*out, v.uv[0]);
                dasset_w_f32(*out, v.uv[1]);
                for f: v.tangent {
                    dasset_w_f32(*out, f);
                }
            }
        }

        dasset_w_i32(*out, cast(s32) p.indices.count);
        for index: p.indices {
            dasset_w_u32(*out, index);
        }
        dasset_w_bounds(*out, p.bounds);
        dasset_w_material(*out, p.material);
    }

    dasset_w_bounds(*out, model.bounds);

    // 动画剪辑表
    dasset_w_i32(*out, cast(s32) model.clips.count);
    for clip: model.clips {
        dasset_w_string(*out, clip.name);
        dasset_w_i32(*out, clip.skin_index);
        dasset_w_f32(*out, clip.duration);
        dasset_w_i32(*out, cast(s32) clip.channels.count);
        for ch: clip.channels {
            dasset_w_i32(*out, ch.joint_index);
            dasset_w_i32(*out, cast(s32) ch.path);
            dasset_w_i32(*out, cast(s32) ch.interpolation);
            n := ch.times.count;
            dasset_w_i32(*out, cast(s32) n);
            for t: ch.times {
                dasset_w_f32(*out, t);
            }
            for v: ch.values {
                dasset_w_vec4(*out, v);
            }
            if ch.interpolation == Dasset_Interpolation.Cubic_Spline {
                for v: ch.in_tangents {
                    dasset_w_vec4(*out, v);
                }
                for v: ch.out_tangents {
                    dasset_w_vec4(*out, v);
                }
            }
        }
    }

    return out, true;
}
//@endregion

//@region 读入

Dasset_Error :: enum s32 {
    None;
    Not_Dasset; // magic 不符
    Bad_Version; // 版本超出 1..当前
    Truncated; // 数据不足/计数越界
    Bad_Value; // 枚举值非法
}

dasset_read :: (data: [] u8) -> (Dasset_Model, Dasset_Error) {
    model: Dasset_Model;

    if data.data == null || data.count < 8 {
        return model, .Truncated;
    }
    cur: s64 = 0;

    magic, ok := dasset_r_u32(data, *cur);
    if !ok || magic != DASSET_MAGIC return model, .Not_Dasset;
    version, ok2 := dasset_r_i32(data, *cur);
    if !ok2 || version < 1 || version > DASSET_VERSION return model, .Bad_Version;

    // 贴图表
    tex_count, ok3 := dasset_r_count(data, *cur, 8);
    if !ok3 return dasset_dispose_partial(*model), .Truncated;
    for 0..tex_count - 1 {
        name, okn := dasset_r_string(data, *cur);
        if !okn return dasset_dispose_partial(*model), .Truncated;
        codec_v, okc := dasset_r_i32(data, *cur);
        if !okc || codec_v < 0 || codec_v > 1 return dasset_dispose_partial(*model), .Bad_Value;
        byte_count, okb := dasset_r_count(data, *cur, 1);
        if !okb return dasset_dispose_partial(*model), .Truncated;
        bytes := dasset_clone_bytes(array_view(data, cur, byte_count));
        if bytes.count != byte_count return dasset_dispose_partial(*model), .Truncated;
        cur += byte_count;
        array_add(*model.textures, Dasset_Texture_Entry.{
            name = name,
            codec = cast(Dasset_Texture_Codec) codec_v,
            bytes = bytes,
        });
    }

    // 骨架表（v2+）
    if version >= 2 {
        skel_count, oks := dasset_r_count(data, *cur, 4);
        if !oks return dasset_dispose_partial(*model), .Truncated;
        for 0..skel_count - 1 {
            joint_count, okj := dasset_r_count(data, *cur, 4);
            if !okj return dasset_dispose_partial(*model), .Truncated;
            array_add(*model.skeletons, Dasset_Skeleton.{}); // 先挂进 model：中途失败也由 dispose 兜底
            skel_index := model.skeletons.count - 1;
            for 0..joint_count - 1 {
                joint: Dasset_Joint;
                j, ojn := dasset_r_string(data, *cur);
                if !ojn return dasset_dispose_partial(*model), .Truncated;
                joint.name = j;
                joint.parent_index, _ = dasset_r_i32(data, *cur);
                joint.bind_translation = dasset_r_vec3(data, *cur);
                joint.bind_rotation = dasset_r_vec4(data, *cur);
                joint.bind_scale = dasset_r_vec3(data, *cur);
                for 0..15 {
                    joint.inverse_bind_matrix[it] = dasset_r_f32(data, *cur);
                }
                // 骨架元素可能因 array_add 搬家，这里每次用下标重新取址。
                array_add(*model.skeletons[skel_index].joints, joint);
            }
        }
    }

    // primitives
    prim_count, okp := dasset_r_count(data, *cur, 8);
    if !okp return dasset_dispose_partial(*model), .Truncated;
    for 0..prim_count - 1 {
        array_add(*model.primitives, Dasset_Primitive.{
            skin_index = -1,
            material = DASSET_MATERIAL_DEFAULT,
        });
        p := *model.primitives[model.primitives.count - 1];
        layout: s32 = 0;
        if version >= 2 {
            layout, _ = dasset_r_i32(data, *cur);
            p.skin_index, _ = dasset_r_i32(data, *cur);
            if layout < 0 || layout > 1 return dasset_dispose_partial(*model), .Bad_Value;
        }
        skinned := layout == 1;
        stride: s64 = DASSET_VERTEX_STRIDE_STATIC;
        if skinned stride = DASSET_VERTEX_STRIDE_SKIN;
        vert_count, okv := dasset_r_count(data, *cur, stride);
        if !okv return dasset_dispose_partial(*model), .Truncated;
        if skinned {
            p.skin_vertices = dasset_alloc_array(Dasset_Skin_Vertex, vert_count);
            verts := p.skin_vertices;
            for 0..vert_count - 1 {
                verts[it].position = dasset_r_vec3(data, *cur);
                verts[it].normal = dasset_r_vec3(data, *cur);
                u := dasset_r_f32(data, *cur);
                v := dasset_r_f32(data, *cur);
                verts[it].uv = .[u, v];
                verts[it].tangent = dasset_r_vec4(data, *cur);
                jv, _ := dasset_r_u32(data, *cur);
                verts[it].joints = jv;
                verts[it].weights = dasset_r_vec4(data, *cur);
            }
        } else {
            p.vertices = dasset_alloc_array(Dasset_Vertex, vert_count);
            verts := p.vertices;
            for 0..vert_count - 1 {
                verts[it].position = dasset_r_vec3(data, *cur);
                verts[it].normal = dasset_r_vec3(data, *cur);
                u := dasset_r_f32(data, *cur);
                v := dasset_r_f32(data, *cur);
                verts[it].uv = .[u, v];
                verts[it].tangent = dasset_r_vec4(data, *cur);
            }
        }

        index_count, oki := dasset_r_count(data, *cur, 4);
        if !oki return dasset_dispose_partial(*model), .Truncated;
        p.indices = dasset_alloc_array(u32, index_count);
        for 0..index_count - 1 {
            index, _ := dasset_r_u32(data, *cur);
            p.indices[it] = index;
        }
        p.bounds.min = dasset_r_vec3(data, *cur);
        p.bounds.max = dasset_r_vec3(data, *cur);

        // 材质
        p.material.base_color_factor = dasset_r_vec4(data, *cur);
        p.material.metallic = dasset_r_f32(data, *cur);
        p.material.roughness = dasset_r_f32(data, *cur);
        dv, _ := dasset_r_u8(data, *cur);
        p.material.double_sided = dv != 0;
        alpha_v, oka := dasset_r_i32(data, *cur);
        if !oka || alpha_v < 0 || alpha_v > 2 return dasset_dispose_partial(*model), .Bad_Value;
        p.material.alpha_mode = cast(Dasset_Alpha_Mode) alpha_v;
        p.material.alpha_cutoff = dasset_r_f32(data, *cur);
        p.material.albedo_texture_index, _ = dasset_r_i32(data, *cur);
        p.material.normal_texture_index, _ = dasset_r_i32(data, *cur);
        if version >= 3 {
            p.material.metallic_roughness_texture_index, _ = dasset_r_i32(data, *cur);
            p.material.occlusion_texture_index, _ = dasset_r_i32(data, *cur);
            p.material.occlusion_strength = dasset_r_f32(data, *cur);
            p.material.emissive_texture_index, _ = dasset_r_i32(data, *cur);
            p.material.emissive_factor = dasset_r_vec3(data, *cur);
            p.material.normal_scale = dasset_r_f32(data, *cur);
        }
    }

    model.bounds.min = dasset_r_vec3(data, *cur);
    model.bounds.max = dasset_r_vec3(data, *cur);

    // 动画剪辑表（v2+）
    if version >= 2 {
        clip_count, okc := dasset_r_count(data, *cur, 8);
        if !okc return dasset_dispose_partial(*model), .Truncated;
        for 0..clip_count - 1 {
            array_add(*model.clips, Dasset_Animation_Clip.{}); // 先挂进 model：中途失败也由 dispose 兜底
            clip_index := model.clips.count - 1;
            n, okn := dasset_r_string(data, *cur);
            if !okn return dasset_dispose_partial(*model), .Truncated;
            model.clips[clip_index].name = n;
            model.clips[clip_index].skin_index, _ = dasset_r_i32(data, *cur);
            model.clips[clip_index].duration = dasset_r_f32(data, *cur);
            channel_count, okch := dasset_r_count(data, *cur, 8);
            if !okch return dasset_dispose_partial(*model), .Truncated;
            for 0..channel_count - 1 {
                ch: Dasset_Animation_Channel;
                ch.joint_index, _ = dasset_r_i32(data, *cur);
                path_v, okpv := dasset_r_i32(data, *cur);
                if !okpv || path_v < 0 || path_v > 2 return dasset_dispose_partial(*model), .Bad_Value;
                ch.path = cast(Dasset_Anim_Path) path_v;
                if version >= 4 {
                    interp_v, okiv := dasset_r_i32(data, *cur);
                    if !okiv || interp_v < 0 || interp_v > 2 return dasset_dispose_partial(*model), .Bad_Value;
                    ch.interpolation = cast(Dasset_Interpolation) interp_v;
                }
                cubic := ch.interpolation == Dasset_Interpolation.Cubic_Spline;
                key_stride: s64 = 20;
                if cubic key_stride = 52;
                key_count, okk := dasset_r_count(data, *cur, key_stride);
                if !okk return dasset_dispose_partial(*model), .Truncated;
                ch.times = dasset_alloc_array(float32, key_count);
                for 0..key_count - 1 {
                    ch.times[it] = dasset_r_f32(data, *cur);
                }
                ch.values = dasset_alloc_array([4] float32, key_count);
                for 0..key_count - 1 {
                    ch.values[it] = dasset_r_vec4(data, *cur);
                }
                if cubic {
                    ch.in_tangents = dasset_alloc_array([4] float32, key_count);
                    ch.out_tangents = dasset_alloc_array([4] float32, key_count);
                    for 0..key_count - 1 {
                        ch.in_tangents[it] = dasset_r_vec4(data, *cur);
                    }
                    for 0..key_count - 1 {
                        ch.out_tangents[it] = dasset_r_vec4(data, *cur);
                    }
                }
                array_add(*model.clips[clip_index].channels, ch);
            }
        }
    }

    return model, .None;
}

// 释放 model 的全部深拷贝数据。
dasset_model_dispose :: (model: *Dasset_Model) {
    for tex: model.textures {
        if tex.name.count > 0 free(tex.name); // 空串未分配（见 dasset_clone_owned）
        if tex.bytes.data != null free(tex.bytes.data);
    }
    array_free(model.textures);
    for p: model.primitives {
        // Jai 的 free 不接受空指针，逐个判空（等价于 Odin 的 delete(nil) 无副作用）。
        if p.vertices.data != null free(p.vertices.data);
        if p.skin_vertices.data != null free(p.skin_vertices.data);
        if p.indices.data != null free(p.indices.data);
    }
    array_free(model.primitives);
    for skel: model.skeletons {
        for joint: skel.joints {
            if joint.name.count > 0 free(joint.name);
        }
        array_free(skel.joints);
    }
    array_free(model.skeletons);
    for clip: model.clips {
        if clip.name.count > 0 free(clip.name);
        for ch: clip.channels {
            if ch.times.data != null free(ch.times.data);
            if ch.values.data != null free(ch.values.data);
            if ch.in_tangents.data != null free(ch.in_tangents.data);
            if ch.out_tangents.data != null free(ch.out_tangents.data);
        }
        array_free(clip.channels);
    }
    array_free(model.clips);
    model.* = .{};
}

dasset_dispose_partial :: (model: *Dasset_Model) -> Dasset_Model {
    dasset_model_dispose(model);
    return .{};
}
//@endregion

//@region 内部 —— 写辅助

dasset_w_u8 :: (out: *[..] u8, v: u8) {
    array_add(out, v);
}

dasset_w_u32 :: (out: *[..] u8, v: u32) {
    // Jai 的 cast 会对编译期常量做溢出检查（魔数常量进不来 u8），截断要显式写 cast,trunc。
    array_add(out, cast,trunc(u8) v);
    array_add(out, cast,trunc(u8) (v >> 8));
    array_add(out, cast,trunc(u8) (v >> 16));
    array_add(out, cast,trunc(u8) (v >> 24));
}

dasset_w_i32 :: (out: *[..] u8, v: s32) {
    // s32 -> u32 是比特层面的重解释（负数补码），用 cast,trunc；普通 cast 会对 -1 报溢出。
    dasset_w_u32(out, cast,trunc(u32) v);
}

// f32 -> u32 的比特重解释。Jai 没有 transmute，用 4 字节 union 取同一块内存的另一种读法。
dasset_f32_bits :: (v: float32) -> u32 {
    u: union {
        f: float32;
        i: u32;
    }
    u.f = v;
    return u.i;
}

// u32 -> f32 的比特重解释（dasset_f32_bits 的逆）。
dasset_bits_f32 :: (b: u32) -> float32 {
    u: union {
        f: float32;
        i: u32;
    }
    u.i = b;
    return u.f;
}

dasset_w_f32 :: (out: *[..] u8, v: float32) {
    dasset_w_u32(out, dasset_f32_bits(v));
}

dasset_w_vec3 :: (out: *[..] u8, v: [3] float32) {
    for f: v {
        dasset_w_f32(out, f);
    }
}

dasset_w_vec4 :: (out: *[..] u8, v: [4] float32) {
    for f: v {
        dasset_w_f32(out, f);
    }
}

dasset_w_bounds :: (out: *[..] u8, b: Dasset_Bounds) {
    dasset_w_vec3(out, b.min);
    dasset_w_vec3(out, b.max);
}

dasset_w_material :: (out: *[..] u8, m: Dasset_Material) {
    dasset_w_vec4(out, m.base_color_factor);
    dasset_w_f32(out, m.metallic);
    dasset_w_f32(out, m.roughness);
    // Odin: m.double_sided ? 1 : 0；Jai 没有三目运算符，改成分支。
    side: u8 = 0;
    if m.double_sided side = 1;
    dasset_w_u8(out, side);
    dasset_w_i32(out, cast(s32) m.alpha_mode);
    dasset_w_f32(out, m.alpha_cutoff);
    dasset_w_i32(out, m.albedo_texture_index);
    dasset_w_i32(out, m.normal_texture_index);
    // v3 字段（当前固定写 v4 布局）
    dasset_w_i32(out, m.metallic_roughness_texture_index);
    dasset_w_i32(out, m.occlusion_texture_index);
    dasset_w_f32(out, m.occlusion_strength);
    dasset_w_i32(out, m.emissive_texture_index);
    dasset_w_vec3(out, m.emissive_factor);
    dasset_w_f32(out, m.normal_scale);
}

// C# BinaryWriter.Write(string)：7-bit 变长长度前缀 + UTF-8 字节。
dasset_w_string :: (out: *[..] u8, s: string) {
    n := cast(u32) s.count;
    while n >= 0x80 {
        array_add(out, cast,trunc(u8) (n | 0x80));
        n >>= 7;
    }
    array_add(out, cast,trunc(u8) n);
    // Odin: append(out, ..transmute([]u8)s)
    for 0..s.count - 1 {
        array_add(out, s[it]);
    }
}
//@endregion

//@region 内部 —— 读辅助（游标越界返回零值/false）

dasset_r_u8 :: (data: [] u8, cur: *s64) -> (u8, bool) {
    if cur.* >= data.count {
        cur.* = data.count + 1; // 推进游标防止后续误读
        return 0, false;
    }
    v := data[cur.*];
    cur.* += 1;
    return v, true;
}

dasset_r_u32 :: (data: [] u8, cur: *s64) -> (u32, bool) {
    if cur.* + 4 > data.count {
        cur.* = data.count + 1;
        return 0, false;
    }
    // 先加宽到 u32 再移位（Jai 会把 u8 的移位按 u8 算，高位会丢）。
    v := ((cast(u32) data[cur.*])) | ((cast(u32) data[cur.* + 1]) << 8) |
         ((cast(u32) data[cur.* + 2]) << 16) | ((cast(u32) data[cur.* + 3]) << 24);
    cur.* += 4;
    return v, true;
}

dasset_r_i32 :: (data: [] u8, cur: *s64) -> (s32, bool) {
    v, ok := dasset_r_u32(data, cur);
    return cast,trunc(s32) v, ok; // 比特重解释，不检查范围
}

dasset_r_f32 :: (data: [] u8, cur: *s64) -> float32 {
    v, _ := dasset_r_u32(data, cur);
    return dasset_bits_f32(v);
}

dasset_r_vec3 :: (data: [] u8, cur: *s64) -> [3] float32 {
    // 逐个读出：不能用字面量里三次调用，求值顺序不保证。
    x := dasset_r_f32(data, cur);
    y := dasset_r_f32(data, cur);
    z := dasset_r_f32(data, cur);
    return .[x, y, z];
}

dasset_r_vec4 :: (data: [] u8, cur: *s64) -> [4] float32 {
    x := dasset_r_f32(data, cur);
    y := dasset_r_f32(data, cur);
    z := dasset_r_f32(data, cur);
    w := dasset_r_f32(data, cur);
    return .[x, y, z, w];
}

// 读元素计数并校验：非负，且按 element_size 换算不超过剩余字节。
dasset_r_count :: (data: [] u8, cur: *s64, element_size: s64) -> (s64, bool) {
    count, ok := dasset_r_i32(data, cur);
    if !ok || count < 0 {
        return 0, false;
    }
    remaining := data.count - cur.*;
    if cast(s64) count * element_size > remaining {
        return 0, false;
    }
    return cast(s64) count, true;
}

dasset_r_string :: (data: [] u8, cur: *s64) -> (string, bool) {
    // 7-bit 变长长度
    n := 0;
    shift := 0;
    while true {
        b, ok := dasset_r_u8(data, cur);
        if !ok return "", false;
        n |= (cast(s64) (b & 0x7F)) << shift;
        if b & 0x80 == 0 break;
        shift += 7;
        if shift > 28 return "", false;
    }
    if n < 0 || cur.* + n > data.count {
        return "", false;
    }
    // Odin: strings.clone(string(data[cur:cur+n]))；Jai 用 to_string 取视图再拷贝。
    s := dasset_clone_owned(to_string(data.data + cur.*, n));
    cur.* += n;
    return s, true;
}

dasset_clone_owned :: (s: string) -> string {
    return copy_string(s);
}

dasset_clone_bytes :: (b: [] u8) -> [] u8 {
    if b.data == null || b.count == 0 {
        return .{};
    }
    out := dasset_alloc_array(u8, b.count);
    memcpy(out.data, b.data, b.count);
    return out;
}

// make([]T, count) 的等价物：alloc + memset 清零。返回的切片用 free(x.data) 释放
// （dasset_alloc_array 的分配没有额外头部，data 就是 alloc 的返回值）。
dasset_alloc_array :: ($T: Type, count: s64) -> [] T {
    if count <= 0 return .{};
    memory := alloc(count * size_of(T));
    assert(memory != null, "dasset: 分配失败");
    assert(cast(u64) memory % align_of(T) == 0, "dasset: 分配器返回的对齐不足");
    memset(memory, 0, count * size_of(T));
    return .{ count, cast(*T) memory };
}
//@endregion
