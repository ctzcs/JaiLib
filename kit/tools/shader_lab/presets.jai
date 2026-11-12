// shader_lab:presets —— 预设是显式导入/导出的预览快照，不自动改写 .oshader 或宿主材质文档。
// 一比一移植自 olib kit/tools/shader_lab/presets.odin。Jai 差异：
//   | olib (Odin)                                   | JaiLib (Jai)                                          |
//   | --------------------------------------------- | ----------------------------------------------------- |
//   | `textures: [16]foster.Texture`                | `[16] *F.Texture`（null = 内置棋盘纹理）                 |
//   | `math.is_nan / math.is_inf`                   | JM.isnan / JM.isinf                                   |
//   | `for &texture, j in p.textures` + 按下标取替    | 显式下标循环（Jai 的 range-for 指针不能当下标用）          |
//   | `strings.clone(value.texture)`                | copy_string                                           |
// 导入由 module.jai 提供。

// 全部数值与纹理准备成功后一次切换；失败不改变旧值和 GPU 资源。
values_apply :: (s: *Session, index: int, values: [] sh.Value) -> bool {
    if index < 0 || index >= s.bank.program_count return false;
    p := *s.bank.parameters[index];
    if !p.available || values.count != p.live.fields.count return false;
    for f, i: p.live.fields {
        for c: 0..sh.components(f.kind) - 1 {
            if JM.isnan(values[i].number[c]) || JM.isinf(values[i].number[c]) {
                parameter_error(p, "Preset contains a non-finite value");
                return false;
            }
        }
    }
    textures: [sh.MAX_TEXTURES] *F.Texture;
    replaced: [sh.MAX_TEXTURES] bool;
    slot := 0;
    for f, i: p.live.fields {
        if f.kind != .Texture continue;
        // 单字段恢复不能因另一个纹理文件暂时丢失而失败，也不重建未变的 GPU 纹理。
        if values[i].texture == p.values[i].texture {
            textures[slot] = p.textures[slot];
            slot += 1;
            continue;
        }
        texture, ok := load_parameter_texture(s, s.device, values[i].texture);
        textures[slot] = texture;
        replaced[slot] = true;
        if !ok {
            for j: 0..sh.MAX_TEXTURES - 1 {
                if !replaced[j] continue;
                candidate := textures[j];
                if candidate != null {
                    F.texture_dispose(candidate);
                    free(candidate);
                }
                textures[j] = null;
            }
            parameter_error(p, "Cannot load preset texture; previous values retained");
            return false;
        }
        slot += 1;
    }
    owned := sh.values_make(p.live, p.live, values);
    color_picker_close(s, false);
    sh.values_dispose(p.values);
    p.values = owned;
    for j: 0..sh.MAX_TEXTURES - 1 {
        if !replaced[j] continue;
        parameter_texture_replace(s, *p.textures[j], textures[j]);
    }
    texture_stamps_reset(s, p);
    parameter_error(p, "");
    return true;
}

// field=-1 恢复整组；其他值只恢复该字段。
reset_defaults :: (s: *Session, index: int, field := -1) -> bool {
    if index < 0 || index >= s.bank.program_count return false;
    p := *s.bank.parameters[index];
    if !p.available || field < -1 || field >= p.live.fields.count return false;
    color_picker_close(s, false);
    values := sh.values_make(p.live);
    defer sh.values_dispose(values);
    if field >= 0 {
        for _, i: p.live.fields {
            if i == field continue;
            if values[i].texture.data != null free(values[i].texture.data);
            values[i] = sh.Value.{ number = p.values[i].number, texture = copy_string(p.values[i].texture) };
        }
    }
    return values_apply(s, index, values);
}

// 继续使用原有按钮与 API，保存结果同时是运行时材质资源。
save_preset :: (s: *Session, index: int, path: string) -> bool {
    if index < 0 || index >= s.bank.program_count || path == "" return false;
    p := *s.bank.parameters[index];
    if !p.available return false;
    color_picker_close(s, true);
    reason := preset_file_save(p.live, p.values, path, s.source_root);
    parameter_error(p, reason);
    return reason == "";
}

load_preset :: (s: *Session, index: int, path: string) -> bool {
    if index < 0 || index >= s.bank.program_count return false;
    p := *s.bank.parameters[index];
    if !p.available return false;
    values, reason := preset_file_load(p.live, path);
    defer sh.values_dispose(values);
    if reason != "" {
        parameter_error(p, reason);
        return false;
    }
    return values_apply(s, index, values);
}
