// shader_lab:bank —— 参数包和所有 Shader 作为一个候选整体切换；Shader/Material 地址在 bank 存活期间固定。
// 一比一移植自 olib kit/tools/shader_lab/bank.odin。Jai 差异（除 module.jai 的全局六条外）：
//   | olib (Odin)                                          | JaiLib (Jai)                                          |
//   | ---------------------------------------------------- | ----------------------------------------------------- |
//   | `materials: []foster.Material`                       | `[..] *F.Material`（F.material_create / material_destroy）|
//   | `programs/parameters/shaders` 为 `[]T`                | `[..] T` + array_resize / array_free                  |
//   | `make([]dev.Session, n)`                             | array_resize（零初始化，dev.init 需要地址稳定：数组不扩容）|
//   | `foster.MaterialInitWithShaders(&m, &program.vertex, &program.fragment)` | F.material_create()（jfoster 侧 vertex/fragment 恒为 null，见 module.jai 第 4 条） |
//   | `foster.DrawCommandDispose(&probe)`                  | 无需释放（Draw_Command 不含动态数组）                    |
//   | `foster.ShaderPairTryReplace(...)`（只换目标的复核）    | 同样走 dev.apply：jfoster 没有原位替换，两次路径都返回 false + 诊断 |
//   | `program.vertex.Resource != nil`                     | `program.vertex != null`（恒为 null ⇒ 该复核分支永不触发）|
//   | `for &program, i in b.programs[:count]`              | for *program, i: array_view(b.programs, 0, count)     |
//   | `s.bank_error == error` / `delete(s.bank_error)`     | 字符串比较相同；释放走 free(data)                       |
//   | `for old in s.shaders`（值拷贝）                       | for old: s.bank.shaders（值拷贝，与本包其余迭代一致）     |
// 导入由 module.jai 提供。

Parameter_Bank :: struct {
    // 按构建结果一次分配，之后不再增长，Material 才能长期指向 programs 里的着色器。
    programs: [..] dev.Session;
    materials: [..] *F.Material;
    parameters: [..] Parameter_State;
    program_count: int;
    program_used: [..] bool;
    last_status: [..] dev.Status;
    shaders: [..] Shader_Runtime;
    fingerprint: u64;
    candidate_failed: bool;
}

// Session 上的两个转发：olib 的 `using bank` 让 `s.program_count` / `len(s.shaders)` 直接可用。
shader_count :: (s: *Session) -> int {
    if s.bank == null return 0;
    return s.bank.shaders.count;
}

bank_error :: (s: *Session, error: string) {
    if s.bank_error == error return;
    if s.bank_error.data != null free(s.bank_error.data);
    s.bank_error = copy_string(error);
    if error != "" print("%\n", error);
}

bank_dispose :: (b: *Parameter_Bank) {
    if b == null return;
    for material: b.materials {
        if material != null {
            F.material_destroy(material);
            free(material);
        }
    }
    for *p: b.parameters parameter_dispose(p);
    for *program: b.programs dev.dispose(program);
    for *shader: b.shaders shader_dispose(shader);
    if b.programs.data != null array_free(b.programs);
    if b.materials.data != null array_free(b.materials);
    if b.parameters.data != null array_free(b.parameters);
    if b.program_used.data != null array_free(b.program_used);
    if b.last_status.data != null array_free(b.last_status);
    if b.shaders.data != null array_free(b.shaders);
    free(b);
}

bank_index :: (b: *Parameter_Bank, name: string) -> int {
    if b == null return -1;
    for p, i: array_view(b.parameters, 0, b.program_count) {
        if p.name == name return i;
    }
    return -1;
}

bank_make :: (s: *Session, build: dev.Parameter_Build) -> *Parameter_Bank {
    b := New(Parameter_Bank);
    b.fingerprint = s.parameter_watch.attempted;
    count := build.schemas.count;
    b.program_count = count;
    array_resize(*b.programs, count);
    array_resize(*b.materials, count);
    array_resize(*b.parameters, count);
    array_resize(*b.program_used, count);
    array_resize(*b.last_status, count);
    for schema, i: build.schemas {
        p := *b.parameters[i];
        p.name = copy_string(schema.name);
        p.live = sh.schema_clone(schema);
        p.available = true;
        p.values = sh.values_make(p.live);
        array_resize(*p.buffer, sh.uniform_size(p.live));
        program := build.programs[i];
        source := program.source;
        program_text := program.text;
        // Sprite Pass 的批量变体从顶点 storage buffer 读两条轴和 [Instance] 字段（见 sh.hlsl 的 Sprite_Batch）。
        // Model Pass 另有顶点 b1 / 片元 b2 视图块（见 mat.VIEW_GLOBALS_SIZE），与材质库的槽数一致。
        storage := 0;
        if bank_group_draws(build.shaders, schema.name, .Sprite) storage = 1;
        view := 0;
        if bank_group_draws(build.shaders, schema.name, .Model) view = 1;
        _ = dev.init(*b.programs[i], source, s.device.driver,
                     dev.Resources.{ uniform_buffers = 1 + storage + view, storage_buffers = storage },
                     dev.Resources.{ uniform_buffers = 2 + view });
        // dev.Session 的源码由 dev 自己的堆分配器释放，与后台编译使用同一所有者。
        b.programs[i].source_text = copy_string(program_text);
        prior := bank_index(s.bank, schema.name);
        if prior >= 0 {
            b.programs[i].revision = s.bank.programs[prior].revision;
            b.last_status[i] = s.bank.last_status[prior];
        }
        // olib: foster.MaterialInitWithShaders(&b.materials[i], &program.vertex, &program.fragment)。
        // jfoster 侧 dev.Session.vertex / .fragment 恒为 null（apply 是未实现的 seam），
        // 所以这里建的是空材质：Pass 一旦安装成功就会写入这两个 stage（见 dev.apply 的诊断）。
        b.materials[i] = F.material_create();
        dev.configure_parameters(*b.programs[i], sh.texture_count(schema));
    }
    // 参数组只是 Shader 资源；每个 .oshader 创建一个 Shader 及其 Pass 目标。
    array_resize(*b.shaders, build.shaders.count);
    for desc, i: build.shaders {
        e := *b.shaders[i];
        e.desc = sh.shader_clone(desc);
        order, order_error := sh.shader_order(e.desc, build.schemas);
        e.order = order;
        if order_error != "" print("shader_lab: %\n", order_error);
        array_resize(*e.targets, desc.passes.count);
        array_resize(*e.validated_revision, count);
        array_resize(*e.rejected_revision, count);
        for p, j: desc.passes {
            e.enabled[j] = !p.disabled;
            e.expanded[j] = true;
        }
        for input_pass: desc.passes {
            for input: input_pass.inputs {
                if input.frame != .Previous continue;
                for p, j: desc.passes {
                    if p.output == input.target e.targets[j].history = true;
                }
            }
        }
    }
    return b;
}

// 候选包跟随当前选择，按稳定 ID 映射；当前 Shader 被删除后使用该工作区书签或首项。
bank_selected_shader :: (s: *Session, b: *Parameter_Bank) -> int {
    if b == s.bank return s.selected_shader;
    name := s.workspaces[s.workspace].shader;
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < s.bank.shaders.count {
        name = s.bank.shaders[s.selected_shader].desc.name;
    }
    chosen := -1;
    for e, i: b.shaders {
        if bank_shader_has_3d(b, i) != (s.workspace == 1) continue;
        if chosen < 0 chosen = i;
        if e.desc.name == name return i;
    }
    return chosen;
}

// 只为选中 Shader 分配目标、验证管线；其他 Shader 仅保留编译结果。
// 注意：jfoster 没有 ShaderPairTryReplace，dev.apply 是未实现的 seam（固定返回 false + 诊断），
// 所以候选包在这里不会变成 .Live —— 本函数的控制流与 olib 一致，只是 apply 永远失败，
// bank_error 会显示 dev.SHADER_PAIR_REPLACE_UNAVAILABLE（见 module.jai 第 4 条与报告）。
bank_apply :: (s: *Session, b: *Parameter_Bank, selected: int, apply_updates := true) -> bool {
    if b == null || b.candidate_failed return false;
    if !shader_targets_prepare(s, b, selected) {
        if selected >= 0 && selected < b.shaders.count b.shaders[selected].ready = false;
        return false;
    }
    ready := true;
    drawable := true;
    for *program, i: array_view(b.programs, 0, b.program_count) {
        if b.program_used[i] {
            if selected < 0 || selected >= b.shaders.count continue;
            e := *b.shaders[selected];
            needs_apply := program.status == .Ready && apply_updates;
            needs_check := program.vertex != null && e.validated_revision[i] != program.revision &&
                           e.rejected_revision[i] != program.revision;
            if needs_apply || needs_check {
                probes: [sh.MAX_PASSES] F.Draw_Command;
                probe_count := 0;
                for p, j: e.desc.passes {
                    if p.params != b.parameters[i].name continue;
                    if j >= e.targets.count continue;
                    if e.targets[j].buffers[0] == null continue;
                    index := 0;
                    if !sh.shader_is_material(e.desc) index = j;
                    target := F.drawable_target_target(e.targets[index].buffers[0]);
                    command := pass_command(s, b, i, p.draw, target, e.desc.instanced);
                    mat.pass_state_apply(*command, p.state);
                    probes[probe_count] = command;
                    probe_count += 1;
                }
                applied := false;
                if needs_apply {
                    applied = dev.apply(program, s.device, array_view(probes, 0, probe_count));
                } else {
                    // 切到另一套目标/网格时，olib 用缓存代码验证实际管线，无需重新编译 HLSL。
                    // jfoster 没有 Foster 的 ShaderPairTryReplace：这一支同样只能得到 apply 的诊断。
                    applied = dev.apply(program, s.device, array_view(probes, 0, probe_count));
                    if !applied {
                        e.rejected_revision[i] = program.revision;
                        bank_error(s, program.diagnostic);
                    }
                }
                if applied {
                    e.validated_revision[i] = program.revision;
                    e.rejected_revision[i] = 0;
                    if b == s.bank {
                        shader_reset(s, e);
                        if s.pending_bank == null bank_error(s, "");
                    }
                }
            }
            drawable = drawable && program.vertex != null && program.fragment != null &&
                       e.validated_revision[i] == program.revision;
        }
        if program.status == .Error && b == s.pending_bank {
            bank_error(s, tprint("%: %", b.parameters[i].name, program.diagnostic));
            b.candidate_failed = true;
        }
        // 候选包仍等待源码编译成功；未选中 Shader 不分配目标或创建 GPU 程序。
        ready = ready && (program.status == .Live || (!b.program_used[i] && program.status == .Ready));
    }
    if selected >= 0 && selected < b.shaders.count b.shaders[selected].ready = drawable;
    if b == s.pending_bank return ready && drawable;
    return drawable;
}

bank_commit :: (s: *Session) {
    b := s.pending_bank;
    current, ok := dev.parameters_fingerprint(s.source_root);
    if !ok || current != b.fingerprint return;
    workspace_save(s);
    cancel(s);
    // 最后时刻迁移值，编译期间用户继续调参数也不会被旧快照覆盖。
    for *p: array_view(b.parameters, 0, b.program_count) {
        for *texture: p.textures {
            if texture.* != null {
                F.texture_dispose(texture.*);
                free(texture.*);
            }
            texture.* = null;
        }
        prior := bank_index(s.bank, p.name);
        sh.values_dispose(p.values);
        if prior >= 0 {
            old := *s.bank.parameters[prior];
            p.folder_closed = old.folder_closed;
            p.values = sh.values_make(p.live, old.live, old.values);
        } else {
            p.values = sh.values_make(p.live);
        }
        slot := 0;
        for f, j: p.live.fields {
            if f.kind != .Texture continue;
            texture, valid := load_parameter_texture(s, s.device, p.values[j].texture);
            p.textures[slot] = texture;
            if !valid {
                bank_error(s, tprint("%: cannot load texture; previous shader retained", p.name));
                b.candidate_failed = true;
                return;
            }
            slot += 1;
        }
        s.schema_generation += 1;
        p.generation = s.schema_generation;
        texture_stamps_reset(s, p);
    }
    selected := -1;
    if s.bank != null && s.selected >= 0 && s.selected < s.bank.program_count {
        selected = bank_index(b, s.bank.parameters[s.selected].name);
    }
    new_selected := -1;
    new_pass := -1;
    new_preview := -1;
    for *e: b.shaders {
        for old: s.bank.shaders {
            if old.desc.name != e.desc.name continue;
            for p, i: e.desc.passes {
                for prior, j: old.desc.passes {
                    if prior.id != p.id continue;
                    e.expanded[i] = old.expanded[j];
                    if prior.disabled == p.disabled e.enabled[i] = old.enabled[j];
                }
            }
        }
    }
    if s.selected_shader >= 0 && s.bank != null && s.selected_shader < s.bank.shaders.count {
        name := s.bank.shaders[s.selected_shader].desc.name;
        for e, i: b.shaders {
            if e.desc.name != name continue;
            new_selected = i;
            if s.preview_pass >= 0 && s.preview_pass < s.bank.shaders[s.selected_shader].desc.passes.count {
                id := s.bank.shaders[s.selected_shader].desc.passes[s.preview_pass].id;
                for p, j: e.desc.passes {
                    if p.id == id new_preview = j;
                }
            }
            if s.inspect_pass >= 0 && s.inspect_pass < s.bank.shaders[s.selected_shader].desc.passes.count {
                id := s.bank.shaders[s.selected_shader].desc.passes[s.inspect_pass].id;
                for p, j: e.desc.passes {
                    if p.id == id new_pass = j;
                }
            }
        }
    }
    bank_dispose(s.bank);
    s.bank = b;
    s.pending_bank = null;
    s.selected = max(0, selected);
    s.selected_shader = new_selected;
    s.inspect_pass = -1;
    s.preview_pass = new_preview;
    if new_selected >= 0 && shader_has_3d(s, new_selected) == (s.workspace == 1) {
        select_shader(s, new_selected, new_pass);
        if (s.mode >= 2) != shader_has_3d(s, new_selected) {
            s.mode = 0;
            if shader_has_3d(s, new_selected) s.mode = 2;
        }
    } else {
        workspace_restore(s);
    }
    s.fonts_dirty = true;
    bank_error(s, "");
}

// 参数组是否被某种 Pass（Sprite / Model）使用。
bank_group_draws :: (shaders: [] sh.Shader_Desc, group: string, draw: sh.Pass_Draw) -> bool {
    for shader: shaders {
        for pass: shader.passes {
            if pass.draw == draw && pass.params == group return true;
        }
    }
    return false;
}
