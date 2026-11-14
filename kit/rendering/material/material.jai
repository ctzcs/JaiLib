// material:material —— 对象材质实例：每次 load 创建独立数值实例，GPU 程序与贴图在 Material_Library 中共享。
// 一比一移植自 olib kit/rendering/material/material.odin。
//
// Jai 侧差异（逐条对应 olib 的写法，加载/替换/修改语义不变）：
//   | olib (Odin)                                     | JaiLib (Jai)                                           |
//   | ----------------------------------------------- | ------------------------------------------------------ |
//   | `strings.replace_all(s, "\\\\", "/", temp)`        | material_slash_normalize（talloc，逐字节换分隔符）        |
//   | `strings.has_prefix / strings.contains`          | STRING.begins_with / STRING.contains                   |
//   | `path.clean(p, temp)` / `path.dir` / `path.join` | material_path_clean / material_path_dir /              |
//   | （core:path/slashpath）                           | material_path_join：同一条 Go 式词法规则（折叠 //、去掉  |
//   |                                                 | ./、按栈消掉 ..、空路径归一成 "."），Jai 没有 path 模块   |
//   | `json.unmarshal(bytes, &header, allocator = temp)`| JSON.json_parse + 逐键取（缺键 = 零值、未知键忽略）      |
//   | `foster.ReadAllBytes(storage, path, temp)`        | F.storage_read_all_bytes（没有 allocator 形参）+ 立即 free |
//   | `sh.instance_decode(desc, schemas, bytes)`        | 同名（kit/rendering/shader）                            |
//   | `foster.TextureInit / TextureSetData`             | F.texture_create / F.texture_set_data                  |
//   | `foster.TextureIsSampleable(tex)`                 | material_texture_is_sampleable（jfoster 没有这个扩展，见下）|
//   | `sampler.Texture != nil`                          | `sampler.Tex != null`                                  |
//   | `texture.GraphicsDevice`                          | `texture.device`                                       |
//   | `material.samplers[g][slot] = {…}` 结构体字面量     | `F.Bound_Sampler.{ Tex = …, Sampler = … }`             |
//   | `material^ = {}` / `next := Material{…}`         | `material.* = Material.{}` / `Material.{ … }`           |
//   | `defer material_instance_clear(&next)` + 末尾交换  | 失败分支显式 clear、成功分支直接接管（同一结果，见       |
//   |                                                 | material_replace 的注释）                                |
//   | `nil`                                            | `null`（Jai 的指针零值）                                 |
//   | `@(private)`                                     | 去掉标注，内部过程加 material_ 前缀                       |
#import "Basic";

//@region 类型

// 返回的指针借用至 material_library_dispose；reload 保持地址不变，模型不需要重新接线。
// 不直接修改这些字段；数值使用 material_set_number，运行时贴图使用 material_set_texture，
// 资源变更通过 material_reload。
Material :: struct {
    owner: *Material_Library;
    shader: *Material_Shader;
    instance: sh.Instance;
    source: string;
    bindings: [] Material_Binding;
    samplers: [][sh.MAX_TEXTURES] F.Bound_Sampler;
    // 数值、贴图或重载每次成功修改都递增；绘制器据此判断已记录的参数与贴图快照能否继续合批。
    revision: u64;
}

// 记录与提交时选 Pass 用的 ID（r2d.image、r3d.submit 等的 pass_id）；定义在 Shader 描述层，
// 游戏用 mat.Pass_Id 即可（olib: Pass_Id :: sh.Pass_Id，Jai 侧同样是别名）。
Pass_Id :: sh.Pass_Id;

material_instance_clear :: (material: *Material) {
    sh.instance_dispose(*material.instance);
    if material.source.data != null free(material.source.data);
    if material.bindings.data != null free(material.bindings.data);
    if material.samplers.data != null free(material.samplers.data);
    material.* = Material.{};
}
//@endregion

//@region 加载与替换 —— JSON、贴图都走同一 StorageContainer。

// 每次 load 创建独立数值实例；底层资源在库中共享。失败返回 null，诊断借用至本帧结束。
material_load :: (library: *Material_Library, file: string) -> (*Material, string) {
    result := New(Material);
    reason := material_replace(library, result, file);
    if reason != "" {
        free(result);
        return null, reason;
    }
    array_add(*library.instances, result);
    return result, "";
}

// 主线程、提交绘制之外调用；整份候选成功后一次替换，所有对象材质槽指针保持有效。
// 同路径贴图复用缓存；此接口重载材质参数，不监听或重载 Shader/贴图内容。
material_reload :: (library: *Material_Library, material: *Material, file := "") -> string {
    if material == null || material.owner != library return "Material belongs to another library";
    return material_replace(library, material, file);
}

// 逻辑路径相对于容器根；贴图相对于材质文件。统一斜杠、折叠 ./ 和 ../ 以复用纹理。
material_path :: (file: string, relative: string) -> (string, string) {
    normalized := material_slash_normalize(relative);
    if normalized == "" || STRING.begins_with(normalized, "/") || STRING.contains(normalized, ":") {
        return "", "Material paths must be relative to the storage root";
    }
    if file == "" return material_path_clean(normalized), "";
    directory := material_path_dir(file);
    return material_path_clean(material_path_join(directory, normalized)), "";
}

// 读取并解码材质文件：返回实例数值与它所属的 Shader，不创建 GPU 资源。
material_read :: (library: *Material_Library, source: string) -> (sh.Instance, *Material_Shader, string) {
    if library.storage == null return sh.Instance.{}, null, "Missing material storage";
    bytes := F.storage_read_all_bytes(library.storage, source);
    defer {
        if bytes.data != null free(bytes.data);
    }
    if bytes.count == 0 || bytes.count > sh.MAX_RESOURCE_BYTES {
        return sh.Instance.{}, null, "Cannot read material or resource exceeds 1 MiB";
    }
    // 文件里的键仍是 "effect"（olib 用 json 标签映射到 header.shader）。
    document, parsed := JSON.json_parse(sh.shader_bytes_to_string(bytes), temp);
    if !parsed || document.kind != .Object return sh.Instance.{}, null, "Invalid material resource";
    version := 0;
    header_shader := "";
    member: JSON.Json_Value;
    if sh.shader_json_member(document, "version", *member) {
        if !sh.shader_json_int(member, *version) return sh.Instance.{}, null, "Invalid material resource";
    }
    if sh.shader_json_member(document, "effect", *member) {
        if !sh.shader_json_string(member, *header_shader) return sh.Instance.{}, null, "Invalid material resource";
    }
    if version != 2 return sh.Instance.{}, null, "Invalid material resource";
    for shader: library.shaders {
        if shader.desc.name != header_shader continue;
        instance, reason := sh.instance_decode(shader.desc, shader.schemas, bytes);
        return instance, shader, reason;
    }
    return sh.Instance.{}, null, tprint("Unknown material shader: %", header_shader);
}

// 确保库内有 1x1 白色默认贴图，供没有指定图片的 Texture 字段使用。
material_white_texture :: (library: *Material_Library) -> string {
    if library.white != null && library.white.handle != 0 return "";
    if library.device == null return "Cannot create default material texture";
    texture := F.texture_create(library.device, 1, 1, .COLOR, name = "material default");
    library.white = texture;
    if texture == null || texture.handle == 0 return "Cannot create default material texture";
    pixel: [4] u8 = .[255, 255, 255, 255];
    F.texture_set_data(texture, array_view(pixel, 0, 4));
    return "";
}

// 工具用（Shader Lab）：把调用方持有的 Shader 与 GPU 绑定组成 Material，交给 Render2D / Render3D 记录。
// 不登记、不复制、不拥有资源：shader 与 bindings 借用到调用方释放，返回值不用释放。
// shader 只需填 desc 与 schemas；bindings 与 schemas 一一对应，数值和采样器在记录时读取。
material_from_bindings :: (library: *Material_Library, shader: *Material_Shader,
                           bindings: [] Material_Binding) -> (material: Material, reason: string) {
    if library == null || library.device == null return Material.{}, "Missing graphics device";
    if shader == null || !sh.shader_is_material(shader.desc) return Material.{}, "Expected Model or Sprite material shader";
    if bindings.count != shader.schemas.count return Material.{}, "Binding count differs from schema count";
    for binding, i: bindings {
        if binding.schema.name != shader.schemas[i].name {
            return Material.{}, "Bindings must follow the shader's schema order";
        }
        gpu := binding.material;
        if gpu == null || gpu.Vertex.shader == null || gpu.Fragment.shader == null {
            return Material.{}, "Missing compiled shader";
        }
        if gpu.Vertex.shader.device != library.device || gpu.Fragment.shader.device != library.device {
            return Material.{}, "Shader belongs to another graphics device";
        }
    }
    reason = material_white_texture(library);
    if reason != "" return Material.{}, reason;
    return Material.{ owner = library, shader = shader, bindings = bindings }, "";
}

// 为一个参数组解析全部 Texture 字段，返回按字段顺序排列的采样器数量；缺省贴图用白图。
material_group_samplers :: (library: *Material_Library, source: string, group: sh.Instance_Group,
                            samplers: *[sh.MAX_TEXTURES] F.Bound_Sampler) -> (count: int, reason: string) {
    for field, j: group.schema.fields {
        if field.kind != .Texture continue;
        texture := library.white;
        if group.values[j].texture != "" {
            resolved, path_reason := material_path(source, group.values[j].texture);
            if path_reason != "" return 0, path_reason;
            texture, reason = material_texture(library, resolved);
            if reason != "" return 0, reason;
        }
        samplers.*[count] = F.Bound_Sampler.{ Tex = texture, Sampler = sh.field_sampler(field) };
        count += 1;
    }
    return count, "";
}

material_replace :: (library: *Material_Library, material: *Material, file: string) -> string {
    target := file;
    if target == "" target = material.source;
    source, reason := material_path("", target);
    if reason != "" return reason;
    instance, shader, read_reason := material_read(library, source);
    if read_reason != "" return read_reason;
    next := Material.{ owner = library, instance = instance, shader = shader };
    // olib 用 defer material_instance_clear(&next) + 末尾交换来保证失败路径不泄漏；
    // Jai 这里在每条失败分支显式 clear，成功后由 material 接管，结果相同。
    reason = material_bind(library, *next, source);
    if reason != "" {
        material_instance_clear(*next);
        return reason;
    }
    next.revision = material.revision + 1;
    material_instance_clear(material);
    material.* = next;
    return "";
}

// 用默认参数值在代码里创建材质实例，不读材质文件；内置 Shader（BUILTIN_SPRITE / BUILTIN_TEXT）首次使用时自动登记。
// 数值用 material_set_number 修改；没有来源文件，material_reload 会返回错误。指针借用至 material_library_dispose。
material_create :: (library: *Material_Library, shader_name: string) -> (*Material, string) {
    if library == null return null, "Missing material library";
    if builtin_is(shader_name) {
        reason := builtin_register(library, shader_name);
        if reason != "" return null, reason;
    }
    shader: *Material_Shader = null;
    for candidate: library.shaders {
        if candidate.desc.name == shader_name shader = candidate;
    }
    if shader == null return null, tprint("Unknown material shader: %", shader_name);
    next := Material.{ owner = library, shader = shader };
    instance, reason := sh.instance_make(shader.desc, shader.schemas);
    next.instance = instance;
    if reason == "" reason = material_bind(library, *next, "");
    if reason != "" {
        material_instance_clear(*next);
        return null, reason;
    }
    result := New(Material);
    result.* = next;
    array_add(*library.instances, result);
    return result, "";
}

// 准备 Shader 的 GPU 资源并按参数组建立绑定；贴图路径相对于 source（为空时相对于容器根）。
material_bind :: (library: *Material_Library, material: *Material, source: string) -> string {
    if !material_shader_prepare(library, material.shader) return "Cannot prepare material shaders";
    reason := material_white_texture(library);
    if reason != "" return reason;
    material.source = copy_string(source);
    material.bindings = sh.shader_alloc_array(Material_Binding, material.instance.groups.count);
    material.samplers = sh.shader_alloc_array([sh.MAX_TEXTURES] F.Bound_Sampler, material.instance.groups.count);
    for group, i: material.instance.groups {
        count, group_reason := material_group_samplers(library, source, group, *material.samplers[i]);
        if group_reason != "" return group_reason;
        for schema, j: material.shader.schemas {
            if schema.name != group.schema.name continue;
            material.bindings[i] = Material_Binding.{ schema = group.schema, values = group.values,
                material = material.shader.gpu[j], samplers = array_view(material.samplers[i], 0, count) };
        }
    }
    return "";
}
//@endregion

//@region 数值修改

// 常用业务数值修改；按稳定组名/字段 ID 定位，失败不改变任何值。
material_set_number :: (material: *Material, group: string, field: string, value: [4] float32) -> bool {
    if material == null return false;
    for *parameters: material.instance.groups {
        if parameters.schema.name != group continue;
        i := sh.field_index(parameters.schema, field);
        if i < 0 || parameters.schema.fields[i].kind == .Texture return false;
        f := parameters.schema.fields[i];
        for x: value {
            if JM.isnan(x) || JM.isinf(x) return false;
        }
        for c: 0..sh.components(f.kind) - 1 {
            if value[c] < f.minimum || value[c] > f.maximum return false;
        }
        parameters.values[i].number = value;
        material.revision += 1;
        return true;
    }
    return false;
}

// jfoster 没有 olib 的 foster.TextureIsSampleable（olib_ext.odin 的扩展）。
// 规则照 olib：普通贴图总能采样；颜色附件在多采样时要看有没有解析纹理——jfoster 把解析纹理放在
// GPU_Resource.multi_sample_resolve 里，Texture 上取不到，所以多采样颜色附件一律按“不可采样”处理（更严格）；
// 深度附件要求单采样且设备支持该格式（同 olib 的 depth_attachment_sampleable）。
material_texture_is_sampleable :: (texture: *F.Texture) -> bool {
    if texture == null || texture.handle == 0 || texture.is_disposed return false;
    if texture.device != null && texture.device.disposed return false;
    if !texture.IsTargetAttachment return true;
    if F.texture_format_is_color(texture.Format) return texture.SampleCount == .ONE;
    if texture.SampleCount != .ONE return false;
    if texture.device == null return false;
    return F.graphics_device_is_texture_format_supported(texture.device, texture.Format);
}

// 把运行时贴图（阴影图、反射等 Target 附件）绑定到 Texture 字段，采样方式取字段声明；null 恢复白色默认贴图。
// 贴图借用：Render2D 至 submit、Render3D 至 clear 前保持有效。不修改材质文件里的路径，material_reload 会恢复文件里的贴图。
// 不能采样的贴图（多采样深度附件等，见 material_texture_is_sampleable）返回 false。
material_set_texture :: (material: *Material, group: string, field: string, texture: *F.Texture) -> bool {
    if material == null || material.owner == null return false;
    if texture != null && (texture.device != material.owner.device || !material_texture_is_sampleable(texture)) {
        return false;
    }
    for *parameters, g: material.instance.groups {
        if parameters.schema.name != group continue;
        slot := 0;
        for f: parameters.schema.fields {
            if f.kind != .Texture continue;
            if f.id == field {
                bound := texture;
                if bound == null bound = material.owner.white;
                material.samplers[g][slot] = F.Bound_Sampler.{ Tex = bound, Sampler = sh.field_sampler(f) };
                material.revision += 1;
                return true;
            }
            slot += 1;
        }
        return false;
    }
    return false;
}
//@endregion

//@region 路径词法（olib core:path/slashpath 的替身）

// olib: strings.replace_all(relative, "\\", "/", context.temp_allocator)。返回临时存储里的字符串。
material_slash_normalize :: (relative: string) -> string {
    out := talloc_string(relative.count);
    for c, i: relative {
        out[i] = ifx c == #char "\\" then #char "/" else c;
    }
    return out;
}

// 字符串视图（不复制）；Jai 的 Basic 没有 substring。
material_substring :: (s: string, start: int, end: int) -> string {
    if end <= start return "";
    return string.{ end - start, s.data + start };
}

// olib: path.dir(file, temp)。材质路径在 material_path 里已归一成 '/'，这里只看最后一个 '/'。
material_path_dir :: (file: string) -> string {
    last := -1;
    for c, i: file {
        if c == #char "/" last = i;
    }
    if last < 0 return "";
    return material_substring(file, 0, last);
}

// olib: path.join({directory, normalized}, temp)——只有一段时就是它自己。
material_path_join :: (directory: string, normalized: string) -> string {
    if directory == "" return normalized;
    out := talloc_string(directory.count + 1 + normalized.count);
    memcpy(out.data, directory.data, directory.count);
    out[directory.count] = #char "/";
    memcpy(out.data + directory.count + 1, normalized.data, normalized.count);
    return out;
}

// olib: path.clean(path, temp)。与 Go 的 path.Clean 同规则（odin 的 slashpath 就是它的移植）：
// 折叠重复 '/'、去掉 '.' 段、'..' 消掉前一非 '..' 段、空结果归一成 "."。
// 材质路径在 material_path 里已保证是相对路径，所以不处理开头的 '/'。
material_path_clean :: (path: string) -> string {
    if path == "" return "";
    parts: [..] string;
    defer {
        if parts.data != null array_free(parts);
    }
    i := 0;
    while i < path.count {
        while i < path.count && path[i] == #char "/" i += 1;
        if i >= path.count break;
        start := i;
        while i < path.count && path[i] != #char "/" i += 1;
        element := material_substring(path, start, i);
        if element == "." continue;
        if element == ".." && parts.count > 0 && parts[parts.count - 1] != ".." {
            parts.count -= 1;
            continue;
        }
        array_add(*parts, element);
    }
    if parts.count == 0 return ".";
    total := parts.count - 1;
    for part: parts total += part.count;
    out := talloc_string(total);
    at := 0;
    for part, index: parts {
        if index > 0 {
            out[at] = #char "/";
            at += 1;
        }
        memcpy(out.data + at, part.data, part.count);
        at += part.count;
    }
    return out;
}
//@endregion
