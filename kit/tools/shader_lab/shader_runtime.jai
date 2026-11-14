// shader_lab:shader_runtime —— 每个 Shader 的 Pass 目标与逐 Pass 绘制。
// 一比一移植自 olib kit/tools/shader_lab/shader_runtime.odin；Jai 差异（除 module.jai 的全局六条外）：
//   | olib (Odin)                                        | JaiLib (Jai)                                          |
//   | -------------------------------------------------- | ----------------------------------------------------- |
//   | `foster.Target` / `TargetAttachment` / `TargetInit` | *F.Target / F.target_texture / F.target_create_attachments |
//   | `foster.DrawableTargetFromTarget(t)`                | F.drawable_target_target(t)                            |
//   | `foster.GraphicsDeviceClear(dev, t, colors, 1, 0, mask)` | F.graphics_device_clear(dev, F.drawable_target_target(t), colors, 0, 0, mask) |
//   | `foster.GraphicsDeviceDraw(dev, &cmd)` + `DrawCommandDispose` | F.graphics_device_draw(dev, cmd)（按值；无释放） |
//   | `foster.MaterialStageSetUniformBuffer(&st, buf[, slot])` | F.material_stage_set_uniform(&st, slot, buf)     |
//   | formats = {.Color, .R16G16B16A16_FLOAT, .R32G32B32A32_FLOAT} | F.R16G16B16A16_FLOAT / F.R32G32B32A32_FLOAT，保留 HDR |
//   | MSAA 的 ResolveResource 检查                         | jfoster 的 Target 不含 Resolve 资源，只检查附件句柄非空       |
//   | `make([]Pass_Target, n)` / `delete`                 | 「先全建成 next，成功再换掉 e.targets」用两块 [..] 完成    |
//   | `command.CullMode = .Back / .None`                   | .BACK / .NONE                                         |
//   | `r3d.model_instanced_command(&cmd, geometry, buf, new(foster.VertexBuffer))` | 同样调用（shifted 用临时存放的 *F.Graphics_Buffer） |
// 导入由 module.jai 提供。

Pass_Target :: struct {
    buffers: [2] *F.Target;
    history: bool;
}

Shader_Runtime :: struct {
    desc: sh.Shader_Desc;
    order: [] int;
    targets: [] Pass_Target;
    current: int;
    frame: u64;
    time, last_clock, last_delta: float32;
    last_tick: u64;
    clear_pending: bool;
    ready: bool;
    // 按参数组下标记录，长度等于所属 bank 的 program_count。
    validated_revision: [] u64;
    rejected_revision: [] u64;
    enabled, expanded: [sh.MAX_PASSES] bool;
}

// 启停是会话预览状态；同时重置反馈，避免切换后混入旧历史。
set_pass_enabled :: (s: *Session, shader: int, pass: int, enabled: bool) {
    if !s.initialized || shader < 0 || shader >= shader_count(s) return;
    e := *s.bank.shaders[shader];
    if pass < 0 || pass >= e.desc.passes.count || e.enabled[pass] == enabled return;
    cancel(s);
    e.enabled[pass] = enabled;
    shader_reset(s, e);
}

// 唯一 Current 输入自动直通；无输入或多个 Current 输入时使用声明的清屏色。
pass_bypass :: (s: *Session, e: *Shader_Runtime, pass: int, target: *F.Target) {
    p := *e.desc.passes[pass];
    target_clear(s, target, p.target.clear);
    source_name: sh.Target_Ref;
    count := 0;
    for input: p.inputs {
        if input.frame != .Current continue;
        source_name = input.target;
        count += 1;
    }
    if count != 1 return;
    for producer, i: e.desc.passes {
        if producer.output != source_name continue;
        t := *e.targets[i];
        buffer := 0;
        if t.history buffer = e.current;
        texture := F.target_texture(t.buffers[buffer]);
        r2d.push_blend(*s.render, mat.BLEND_MODE_DISABLED);
        quad(*s.render, texture, F.Rect.{ 0, 0, cast(float32) target.Width, cast(float32) target.Height });
        r2d.submit(*s.render, r2d.View.{ target = F.drawable_target_target(target) });
        return;
    }
}

shader_dispose :: (e: *Shader_Runtime) {
    shader_targets_release(e);
    if e.targets.data != null array_free(e.targets);
    if e.order.data != null array_free(e.order);
    if e.validated_revision.data != null array_free(e.validated_revision);
    if e.rejected_revision.data != null array_free(e.rejected_revision);
    sh.shader_dispose(*e.desc);
    e.* = Shader_Runtime.{};
}

// 仅释放 GPU 目标，保留声明、Pass 启停和折叠状态。
// `buffers` 的元素本身是 *F.Target，`for *buffer:` 拿到的是 **F.Target；
// 判空、释放、清槽都要走 `buffer.*`（OLib 的 `^foster.Target` 同样是指针数组）。
pass_targets_release :: (targets: [] Pass_Target) {
    for *target: targets {
        for *buffer: target.buffers {
            if buffer.* != null {
                F.target_dispose(buffer.*);
                free(buffer.*);
                buffer.* = null;
            }
        }
    }
}

shader_targets_release :: (e: *Shader_Runtime) {
    pass_targets_release(e.targets);
    e.ready = false;
    for *r: e.validated_revision r.* = 0;
    for *r: e.rejected_revision r.* = 0;
}

shader_targets_trim :: (bank: *Parameter_Bank, selected: int) {
    if bank == null return;
    for *e, i: bank.shaders {
        if i != selected shader_targets_release(e);
    }
}

target_size :: (t: sh.Target_Desc, w: int, h: int) -> (int, int) {
    if t.width > 0 return t.width, t.height;
    scale := t.scale;
    if scale == 0 scale = 1;
    return max(1, cast(int) (cast(float32) w * scale)), max(1, cast(int) (cast(float32) h * scale));
}

target_clear :: (s: *Session, target: *F.Target, color: [4] float32) {
    if target == null return;
    colors: [1] F.Color;
    colors[0] = F.Color.{ cast(u8) (color[0] * 255), cast(u8) (color[1] * 255),
                           cast(u8) (color[2] * 255), cast(u8) (color[3] * 255) };
    F.graphics_device_clear(s.device, F.drawable_target_target(target), colors, 1, 0,
                            F.Clear_Mask.COLOR | F.Clear_Mask.DEPTH);
}

// Preserve declared floating-point targets through the Foster format mapping.
// No silent downgrade: HDR feedback retains its values between passes.
shader_target_format :: (format: sh.Target_Format) -> F.Texture_Format {
    if format == .Float16 return .R16G16B16A16_FLOAT;
    if format == .Float32 return .R32G32B32A32_FLOAT;
    return .COLOR;
}

// Resize 先分配整套新目标，失败保留该 Shader 旧目标。历史目标始终两张，其余只分配一张。
shader_targets_prepare :: (s: *Session, bank: *Parameter_Bank, selected: int) -> bool {
    shader_targets_trim(bank, selected);
    for *used: bank.program_used used.* = false;
    for *e, shader_index: bank.shaders {
        if shader_index != selected continue;
        model := sh.shader_is_material(e.desc);
        changed := false;
        for p, i: e.desc.passes {
            index := bank_index(bank, p.params);
            if index >= 0 && index < bank.program_used.count bank.program_used[index] = true;
            if model && i > 0 continue;
            w, h := target_size(p.target, cast(int) s.viewport.w, cast(int) s.viewport.h);
            if w > sh.MAX_TARGET_SIZE || h > sh.MAX_TARGET_SIZE {
                bank_error(s, "RenderTexture exceeds 8192 pixels per axis");
                return false;
            }
            if i >= e.targets.count continue;
            old := e.targets[i].buffers[0];
            if old == null || old.Width != cast(s32) w || old.Height != cast(s32) h changed = true;
        }
        if !changed continue;
        next: [..] Pass_Target;
        array_resize(*next, e.targets.count);
        valid := true;
        for p, i: e.desc.passes {
            if i >= next.count continue;
            if model && i > 0 continue;
            w, h := target_size(p.target, cast(int) s.viewport.w, cast(int) s.viewport.h);
            if i < e.targets.count next[i].history = e.targets[i].history;
            samples := F.Sample_Count.ONE;
            if p.target.samples == 4 || (p.target.samples == 0 && p.draw != .Fullscreen) samples = .FOUR;
            index := bank_index(bank, p.params);
            preview3d := index >= 0 && bank.parameters[index].live.preview == "3d";
            depth := p.target.depth || (p.draw != .Fullscreen && preview3d);
            infos: [2] F.Target_Attachment_Info;
            infos[0] = F.Target_Attachment_Info.{ Format = shader_target_format(p.target.format),
                                                   Flags = .NONE, SampleCount = samples };
            infos[1] = F.Target_Attachment_Info.{ Format = .DEPTH32, Flags = .NONE, SampleCount = samples };
            count := 1;
            if depth count = 2;
            buffer_count := 1;
            if next[i].history buffer_count = 2;
            for j: 0..buffer_count - 1 {
                target := F.target_create_attachments(s.device, cast(s32) w, cast(s32) h,
                                                      array_view(infos, 0, count), p.output);
                next[i].buffers[j] = target;
                if target == null || target.Attachments.count == 0 || target.Attachments[0].handle == 0 valid = false;
            }
        }
        if !valid {
            pass_targets_release(next);
            array_free(next);
            bank_error(s, "Cannot allocate shader targets; previous targets retained");
            return false;
        }
        pass_targets_release(e.targets);
        if e.targets.data != null array_free(e.targets);
        e.targets = next;
        shader_reset(s, e);
    }
    return true;
}

shader_reset :: (s: *Session, e: *Shader_Runtime) {
    e.current = 0;
    e.frame = 0;
    e.time = 0;
    e.last_delta = 0;
    e.last_clock = s.clock;
    e.last_tick = s.tick_serial;
    // reset_history 允许从 Update 调用；GPU 清屏必须等到下一次 Render 的有效帧内。
    e.clear_pending = true;
}

reset_history :: (s: *Session) {
    if !s.initialized return;
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < shader_count(s) {
        shader_reset(s, *s.bank.shaders[s.selected_shader]);
    }
}

step :: (s: *Session) {
    if !s.initialized return;
    s.paused = true;
    s.step_requested = true;
}

// 热重载的管线探测用内置几何；实际绘制时 host_mesh 让 3D Preview_Model 改用宿主网格（同一顶点格式）。
// instanced 模型的探测与 Render3D 一样把网格属性排在实例属性之后并绑定实例缓冲；
// 改了属性位置的网格副本放在临时内存里，探测在本帧内用完。
pass_command :: (s: *Session, bank: *Parameter_Bank, index: int, draw: sh.Pass_Draw,
                 target: F.Drawable_Target, instanced := false, host_mesh := false) -> F.Draw_Command {
    preview3d := draw != .Fullscreen && index >= 0 && index < bank.parameters.count &&
                 bank.parameters[index].live.preview == "3d";
    mesh := 0;
    if preview3d {
        mesh = 1;
        if s.mode == 3 mesh = 2;
    }
    geometry := s.meshes[mesh];
    if host_mesh && preview3d && draw == .Preview_Model && s.custom_preview && s.preview_hooks.mesh != null {
        geometry = s.preview_hooks.mesh;
    }
    // 精灵 Pass 只用于管线探测（材质预览走 Render2D），需要的是 Batcher_Vertex 布局。
    if draw == .Sprite geometry = s.sprite_mesh;
    command := F.draw_command_from_mesh(target, geometry, bank.materials[index]);
    if draw == .Model && instanced {
        slots := sh.instance_count(bank.parameters[index].live);
        buf := *s.probe_instances[slots];
        if buf.capacity == 0 r3d.model_buffer_create(buf, s.device, slots, 1, "shader lab instance probe");
        shifted := New(F.Graphics_Buffer);
        r3d.model_instanced_command(*command, geometry, buf, shifted);
    }
    command.DepthTestEnabled = preview3d;
    command.DepthWriteEnabled = preview3d;
    if preview3d command.CullMode = .BACK; else command.CullMode = .NONE;
    if draw != .Preview_Model && draw != .Sprite command.BlendMode = mat.BLEND_MODE_DISABLED;
    return command;
}

pass_uniforms :: (s: *Session, index: int, draw: sh.Pass_Draw, target: F.Drawable_Target,
                  time: float32, dt: float32, frame: u64) {
    material := s.bank.materials[index];
    w := F.drawable_target_width_in_pixels(target);
    h := F.drawable_target_height_in_pixels(target);
    pointer := float32.[
        (s.pointer.x - s.viewport.x) / s.viewport.w,
        (s.pointer.y - s.viewport.y) / s.viewport.h,
    ];
    block: [r3d.MATERIAL_FRAME_BLOCK_SIZE] u8;
    preview3d := draw != .Fullscreen && s.bank.parameters[index].live.preview == "3d";
    if preview3d {
        // 3D 预览（model.hlsli 布局）与 Render3D 用同一个打包函数。
        W.camera3d_set_viewport(*s.camera, w, h);
        W.camera3d_set_position(*s.camera, W.Vec3.{
            JM.sin(s.yaw) * JM.cos(s.pitch) * s.distance,
            JM.sin(s.pitch) * s.distance,
            JM.cos(s.yaw) * JM.cos(s.pitch) * s.distance,
        });
        matrices: [r3d.MATERIAL_VERTEX_BLOCK_SIZE] u8;
        view := r3d.View.{ target = target, time = time, delta_time = dt, frame = frame };
        r3d.pack_material_blocks(matrices, block, W.camera3d_view_projection(*s.camera), W.MATRIX4_IDENTITY,
                                 view, r3d.camera_position(W.camera3d_view(*s.camera)), pointer, .[1, 1, 1, 1]);
        F.material_stage_set_uniform(*material.Fragment, 0, block);
        F.material_stage_set_uniform(*material.Vertex, 0, matrices);
        return;
    }
    // Fullscreen 与 2D 预览（fullscreen.hlsli 布局）只有 Shader Lab 一个宿主：Clock.w 为精灵预览模式标记。
    sprite := draw == .Preview_Model && s.mode == 1;
    clock_w: float32 = 0;
    if sprite clock_w = 1;
    mat.std140_write_vec4(block, 0, .[time, dt, cast(float32) frame, clock_w]);
    mat.std140_write_vec4(block, 16, .[pointer[0], pointer[1], cast(float32) w, cast(float32) h]);
    mat.std140_write_vec4(block, 32, .[1, 1, 1, 1]);
    F.material_stage_set_uniform(*material.Fragment, 0, block);
    view: [16] u8;
    scale: float32 = 1;
    if sprite scale = 0.7;
    xscale := scale;
    if sprite xscale = scale * cast(float32) h / cast(float32) w;
    mat.std140_write_vec4(view, 0, .[xscale, scale, 0, 0]);
    F.material_stage_set_uniform(*material.Vertex, 0, view);
}

// 暂停时重绘当前输出但保持 Previous 不动，因此调参数不会偷偷推进反馈模拟。
shader_render :: (s: *Session, e: *Shader_Runtime) -> *F.Texture {
    if e.clear_pending {
        for p, i: e.desc.passes {
            if sh.shader_is_material(e.desc) && i > 0 continue;
            if i >= e.targets.count continue;
            buffer_count := 1;
            if e.targets[i].history buffer_count = 2;
            for j: 0..buffer_count - 1 {
                target_clear(s, e.targets[i].buffers[j], p.target.clear);
            }
        }
        e.clear_pending = false;
    }
    advance := s.step_requested || (!s.paused && e.last_tick != s.tick_serial);
    dt := e.last_delta;
    if advance {
        if s.step_requested dt = cast(float32) (1.0 / 60.0);
        else dt = max(cast(float32) 0, s.clock - e.last_clock);
        e.current = 1 - e.current;
        e.time += dt;
        e.frame += 1;
        e.last_delta = dt;
    }
    e.last_tick = s.tick_serial;
    e.last_clock = s.clock;
    s.step_requested = false;
    if sh.shader_is_material(e.desc) return material_shader_render(s, e);
    for i: e.order {
        p := *e.desc.passes[i];
        index := bank_index(s.bank, p.params);
        if index < 0 || i >= e.targets.count continue;
        t := *e.targets[i];
        buffer := 0;
        if t.history buffer = e.current;
        target := t.buffers[buffer];
        if !e.enabled[i] {
            pass_bypass(s, e, i, target);
            continue;
        }
        drawable := F.drawable_target_target(target);
        command := pass_command(s, s.bank, index, p.draw, drawable, host_mesh = true);
        mat.pass_state_apply(*command, p.state);
        pass_uniforms(s, index, p.draw, drawable, e.time, dt, e.frame);
        parameters_bind(s, index);
        parameter := *s.bank.parameters[index];
        if p.values.count > 0 {
            values := array_view(parameter.values, 0, parameter.values.count);
            for value: p.values {
                for f, j: parameter.live.fields {
                    if f.id == value.field values[j].number = value.number;
                }
            }
            _ = sh.pack(parameter.live, values, parameter.buffer);
            F.material_stage_set_uniform(*s.bank.materials[index].Fragment, 1, parameter.buffer);
        }
        for input: p.inputs {
            slot := 0;
            for f: parameter.live.fields {
                if f.kind != .Texture continue;
                if f.id == input.field {
                    for producer, j: e.desc.passes {
                        if producer.output != input.target continue;
                        if j >= e.targets.count continue;
                        source := *e.targets[j];
                        src_buffer := 0;
                        if source.history {
                            src_buffer = e.current;
                            if input.frame == .Previous src_buffer = 1 - e.current;
                        }
                        s.bank.materials[index].Fragment.Samplers[slot].Tex = F.target_texture(source.buffers[src_buffer]);
                    }
                }
                slot += 1;
            }
        }
        target_clear(s, target, p.target.clear);
        F.graphics_device_draw(s.device, command);
    }
    for p, i: e.desc.passes {
        if (s.preview_pass < 0 && p.output == e.desc.output) || s.preview_pass == i {
            if i >= e.targets.count continue;
            t := *e.targets[i];
            buffer := 0;
            if t.history buffer = e.current;
            return F.target_texture(t.buffers[buffer]);
        }
    }
    return s.texture;
}
