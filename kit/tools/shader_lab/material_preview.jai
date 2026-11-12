// shader_lab:material_preview —— 材质预览：2D/3D 对象与游戏共用绘制实现；本文件负责预览接入和材质存取。
// 一比一移植自 olib kit/tools/shader_lab/material_preview.odin。Jai 差异：
//   | olib (Odin)                                        | JaiLib (Jai)                                          |
//   | -------------------------------------------------- | ----------------------------------------------------- |
//   | `foster.BoundSampler`                              | F.Bound_Sampler（.Tex / .Sampler）                      |
//   | `mat.Material_Shader{desc, schemas}`               | 同名字段（Jai 需要具名初始化）                            |
//   | `mat.material_from_bindings(&lib, &shader, b)`     | 同（返回 (Material, reason)，取址后传给 r2d/r3d）         |
//   | `foster.SubtextureFromTexture(t)`                  | F.subtexture_make_full(t)                             |
//   | `{scale,0,0,scale, cx, cy}`（Matrix3x2 字面量）      | F.Matrix3x2.{ m11 = scale, m12 = 0, m21 = 0, m22 = scale, m31 = cx, m32 = cy } |
//   | `r2d.image(..., origin = …, material = …)`         | 同名具名实参                                             |
//   | `r3d.View{... draw_debug = false ...}`             | `has_draw_debug = false`（Jai 没有 Maybe）               |
//   | `#dynamic` 的 groups/schemas/bindings               | 定长数组 + array_view（Pass 数有 MAX_PASSES 上界）        |
//   | `[][sh.MAX_TEXTURES]foster.Texture`（材质贴图）      | `[] *F.Texture` + 按下标释放（见 load_material）           |
// 导入由 module.jai 提供。

// 材质 Shader 的预览：借用 bank 的 GPU 绑定组成材质，用 Render2D / Render3D 记录后提交到预览目标，
// 渲染状态与游戏一致。Pass 启停与“只预览到第 N 个 Pass”在这里逐 Pass 处理。
material_shader_render :: (s: *Session, e: *Shader_Runtime) -> *F.Texture {
    if e.targets.count == 0 || e.targets[0].buffers[0] == null return s.texture;
    target := e.targets[0].buffers[0];
    target_clear(s, target, e.desc.passes[0].target.clear);
    // 每帧组装：编辑或载入参数时，数值切片会被替换。绑定按 Pass 首次引用参数组的顺序排列。
    groups: [sh.MAX_PASSES] int;
    group_count := 0;
    for pass: e.desc.passes {
        index := bank_index(s.bank, pass.params);
        known := index < 0;
        for k: 0..group_count - 1 {
            if groups[k] == index known = true;
        }
        if !known {
            groups[group_count] = index;
            group_count += 1;
        }
    }
    schemas: [sh.MAX_PASSES] sh.Schema;
    bindings: [sh.MAX_PASSES] mat.Material_Binding;
    samplers: [sh.MAX_PASSES][sh.MAX_TEXTURES] F.Bound_Sampler;
    for k: 0..group_count - 1 {
        index := groups[k];
        if index < 0 || index >= s.bank.program_count return s.texture;
        p := *s.bank.parameters[index];
        j := 0;
        for field: p.live.fields {
            if field.kind != .Texture continue;
            texture := s.texture;
            if p.textures[j] != null && p.textures[j].handle != 0 texture = p.textures[j];
            samplers[k][j] = F.Bound_Sampler.{ Tex = texture, Sampler = sh.field_sampler(field) };
            j += 1;
        }
        schemas[k] = p.live;
        bindings[k] = mat.Material_Binding.{
            schema = p.live,
            values = p.values,
            material = s.bank.materials[index],
            samplers = array_view(samplers[k], 0, sh.texture_count(p.live)),
        };
    }
    shader := mat.Material_Shader.{ desc = e.desc, schemas = array_view(schemas, 0, group_count) };
    material, reason := mat.material_from_bindings(*s.library, *shader, array_view(bindings, 0, group_count));
    if reason != "" {
        bank_error(s, tprint("Cannot bind material: %", reason));
        return F.target_texture(target);
    }
    drawable := F.drawable_target_target(target);
    pointer := float32.[
        (s.pointer.x - s.viewport.x) / s.viewport.w,
        (s.pointer.y - s.viewport.y) / s.viewport.h,
    ];
    limit := e.desc.passes.count;
    if s.preview_pass >= 0 limit = min(s.preview_pass + 1, e.desc.passes.count);
    sprite := sh.shader_is_sprite(e.desc);
    custom := s.custom_preview && s.preview_hooks.record != null;
    frame := Preview_Frame.{
        dimension = "3d",
        time = e.time,
        delta_time = e.last_delta,
        frame_index = e.frame,
        width = target.Width,
        height = target.Height,
    };
    if sprite frame.dimension = "2d";
    draw_error := mat.Draw_Error.None;
    tex_width := 1;
    tex_height := 1;
    if sprite {
        texture := preview_sprite_texture(s, e);
        if texture == null return F.target_texture(target);
        tex_width = texture.Width;
        tex_height = texture.Height;
    }
    if sprite {
        texture := preview_sprite_texture(s, e);
        size := cast(float32) min(target.Width, target.Height) * 0.7;
        scale := size / cast(float32) max(tex_width, tex_height);
        view := r2d.View.{
            target = drawable,
            time = e.time,
            delta_time = e.last_delta,
            frame = e.frame,
            pointer = pointer,
        };
        for pass, i: array_view(e.desc.passes, 0, limit) {
            if !e.enabled[i] continue;
            frame.pass = pass.id;
            frame.group = pass.params;
            recorded := false;
            if custom {
                recorded = s.preview_hooks.record(s.preview_hooks.user_data, frame, *material,
                                                  *s.preview_sprites, null);
            }
            if !recorded {
                transform := F.Matrix3x2.{
                    m11 = scale, m12 = 0, m21 = 0, m22 = scale,
                    m31 = cast(float32) target.Width / 2, m32 = cast(float32) target.Height / 2,
                };
                draw_error = r2d.image(*s.preview_sprites, F.subtexture_make_full(texture), transform,
                                       F.Color_White,
                                       JM.Vector2.{ cast(float32) tex_width / 2, cast(float32) tex_height / 2 },
                                       *material, null, pass.id);
            }
            if draw_error == .None draw_error = r2d.submit(*s.preview_sprites, view);
            if draw_error != .None break;
        }
    } else {
        W.camera3d_set_viewport(*s.camera, target.Width, target.Height);
        W.camera3d_set_position(*s.camera, W.Vec3.{
            JM.sin(s.yaw) * JM.cos(s.pitch) * s.distance,
            JM.sin(s.pitch) * s.distance,
            JM.cos(s.yaw) * JM.cos(s.pitch) * s.distance,
        });
        view := r3d.View.{
            target = drawable,
            view_projection = W.camera3d_view_projection(*s.camera),
            view_matrix = W.camera3d_view(*s.camera),
            draw_debug = false,
            has_draw_debug = false,
            time = e.time,
            delta_time = e.last_delta,
            frame = e.frame,
        };
        for pass, i: array_view(e.desc.passes, 0, limit) {
            if !e.enabled[i] continue;
            r3d.clear(*s.preview_models);
            frame.pass = pass.id;
            frame.group = pass.params;
            recorded := false;
            if custom {
                recorded = s.preview_hooks.record(s.preview_hooks.user_data, frame, *material,
                                                  null, *s.preview_models);
            }
            if !recorded {
                mesh_index := 1;
                if s.mode == 3 mesh_index = 2;
                draw_error = r3d.model(*s.preview_models, s.meshes[mesh_index], *material, W.MATRIX4_IDENTITY);
            }
            if draw_error == .None draw_error = r3d.submit(*s.preview_models, view, pass.id);
            if draw_error != .None break;
        }
        r3d.clear(*s.preview_models); // 记录借用本帧组装的材质，不留到下一帧
    }
    if draw_error != .None {
        kind := "model";
        if sprite kind = "sprite";
        bank_error(s, tprint("Cannot draw % material: %", kind, mat.draw_error_text(draw_error)));
    }
    return F.target_texture(target);
}

// 被检查 Pass 的帧字段可选预览图片；业务运行时该字段由 Sprite 当前帧覆盖。
preview_sprite_texture :: (s: *Session, e: *Shader_Runtime) -> *F.Texture {
    texture := s.sprite_texture;
    for pass, i: e.desc.passes {
        if i != s.inspect_pass || pass.sprite_texture == "" continue;
        index := bank_index(s.bank, pass.params);
        if index < 0 || index >= s.bank.program_count continue;
        parameter := *s.bank.parameters[index];
        slot := 0;
        for field: parameter.live.fields {
            if field.kind != .Texture continue;
            if field.id == pass.sprite_texture && parameter.textures[slot] != null &&
               parameter.textures[slot].handle != 0 {
                texture = parameter.textures[slot];
            }
            slot += 1;
        }
    }
    return texture;
}

// 保存整个对象 Shader 的参数；临时借用组和数值，文件保存函数内部复制路径。
save_material :: (s: *Session, shader: int, path: string) -> bool {
    if s.bank == null || shader < 0 || shader >= s.bank.shaders.count return false;
    if !sh.shader_is_material(s.bank.shaders[shader].desc) return false;
    color_picker_close(s, true);
    e := s.bank.shaders[shader].desc;
    groups: [sh.MAX_PASSES] sh.Instance_Group;
    group_count := 0;
    for pass: e.passes {
        found := false;
        for k: 0..group_count - 1 {
            if groups[k].schema.name == pass.params found = true;
        }
        if found continue;
        index := bank_index(s.bank, pass.params);
        if index < 0 || index >= s.bank.program_count return false;
        p := *s.bank.parameters[index];
        groups[group_count] = sh.Instance_Group.{ schema = p.live, values = p.values };
        group_count += 1;
    }
    instance := sh.Instance.{ shader = e.name, groups = array_view(groups, 0, group_count) };
    reason := material_file_save(instance, path, s.source_root);
    if e.passes.count > 0 {
        index := bank_index(s.bank, e.passes[0].params);
        if index >= 0 && index < s.bank.program_count parameter_error(*s.bank.parameters[index], reason);
    }
    return reason == "";
}

// 所有参数和贴图准备完成再提交；任一组失败都保留整个旧材质。
load_material :: (s: *Session, shader: int, path: string) -> bool {
    if s.bank == null || shader < 0 || shader >= s.bank.shaders.count return false;
    e := s.bank.shaders[shader].desc;
    schemas: [..] sh.Schema;
    array_resize(*schemas, s.bank.program_count);
    defer array_free(schemas);
    for p, i: array_view(s.bank.parameters, 0, s.bank.program_count) schemas[i] = p.live;
    next, reason := material_file_load(e, schemas, path);
    defer sh.instance_dispose(*next);
    if e.passes.count == 0 return false;
    reporter_index := bank_index(s.bank, e.passes[0].params);
    if reporter_index < 0 || reporter_index >= s.bank.program_count return false;
    reporter := *s.bank.parameters[reporter_index];
    if reason != "" {
        parameter_error(reporter, reason);
        return false;
    }
    // 每组最多 MAX_TEXTURES 张贴图；按组拍平成一维，便于统一释放与迁移。
    textures: [..] *F.Texture;
    defer {
        for texture: textures {
            if texture != null {
                F.texture_dispose(texture);
                free(texture);
            }
        }
        array_free(textures);
    }
    array_resize(*textures, next.groups.count * sh.MAX_TEXTURES);
    for group, i: next.groups {
        slot := 0;
        for f, j: group.schema.fields {
            if f.kind != .Texture continue;
            texture, ok := load_parameter_texture(s, s.device, group.values[j].texture);
            textures[i * sh.MAX_TEXTURES + slot] = texture;
            if !ok {
                parameter_error(reporter, "Cannot load material texture; previous material retained");
                return false;
            }
            slot += 1;
        }
    }
    cancel(s);
    color_picker_close(s, false);
    for *group, i: next.groups {
        index := bank_index(s.bank, group.schema.name);
        if index < 0 || index >= s.bank.program_count continue;
        p := *s.bank.parameters[index];
        sh.values_dispose(p.values);
        p.values = group.values;
        group.values = .[];
        for j: 0..sh.MAX_TEXTURES - 1 {
            texture := textures[i * sh.MAX_TEXTURES + j];
            parameter_texture_replace(s, *p.textures[j], texture);
            textures[i * sh.MAX_TEXTURES + j] = null;
        }
        texture_stamps_reset(s, p);
        parameter_error(p, "");
    }
    return true;
}
