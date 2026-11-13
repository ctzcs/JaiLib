// material:shader_code —— 预编译 Shader 字节码：按图形驱动选择格式，并用 tools/shaders 生成的清单登记
// Shader；一次登记整个产物目录。一比一移植自 olib kit/rendering/material/shader_code.odin。
//
// Jai 侧差异（逐条对应 olib 的写法，选择/登记语义不变）：
//   | olib (Odin)                                          | JaiLib (Jai)                                            |
//   | ---------------------------------------------------- | ------------------------------------------------------- |
//   | foster.GraphicsDriver                                | F.Graphics_Driver                                       |
//   | `.Vulkan / .D3D12 / .Metal / .None / .Private`        | `.VULKAN / .D3D12 / .METAL / .NONE / .PRIVATE`           |
//   | `when ODIN_OS == .JS { return false }`               | `#if OS == .WASM { … }`（本模块尚未接 GLSL 清单）          |
//   | `runtime.Load_Directory_File`（#load_directory 元素）  | 本包自带的同名结构 + material_load_directory（jacket      |
//   |                                                      | 0.35.1 不支持 #load_directory；见下面的说明）              |
//   | `json.unmarshal(manifest, &Compiled_Manifest)`       | JSON.json_parse 树 + 逐键取的 material_json_*（本文件     |
//   |                                                      | 末），键名/枚举拼写/缺键=零值/未知键忽略与反射一致          |
//   | `shader: sh.Shader_Desc \`json:"effect"\``             | 同一个键 "effect"（读取时显式写死）                       |
//   | `strings.has_suffix` / `fmt.tprintf`                 | STRING.ends_with / tprint                              |
//   | `make([]Material_Program_Code, n, temp)`             | material_temp_array(Material_Program_Code, n)           |
//   | `delete(order)` / `delete(parsed.schemas)`           | free(order.data) / array_free（先判 null）               |
//   | `defer compiled_manifest_dispose(&parsed)`（循环体内）  | 循环体内每条出口显式 dispose（Jai 的 defer 是作用域级的， |
//   |                                                      | 显式写更好读，顺序与 olib 相同）                          |
//   | `@(private)`                                          | 去掉标注，内部过程加 material_ / compiled_ / shader_ 前缀  |
#import "Basic";

//@region 驱动与字节码选择

// 同一份着色器由 tools/shaders 编译出的三种后端格式；通常三个字段都来自 #load。
// Metal 驱动需要 msl，没有时 shader_pick 返回空切片。
Shader_Binaries :: struct {
    spv, dxil, msl: [] u8;
}

// 一个 Pass 的顶点与片元字节码，顺序与 Shader 声明里的 Schema（参数组）一致。
// instanced_vertex 是 instanced 精灵 Shader 的缓冲变体顶点（tools/shaders 产出的 <组名>.instanced.vertex.*），
// 其余 Shader 留空。
Pass_Binaries :: struct {
    vertex, fragment: Shader_Binaries;
    instanced_vertex: Shader_Binaries;
}

// 驱动是否走预编译字节码（SPIR-V / DXIL / MSL）。Web（WebGL2）只有 foster 默认 Shader 的手写 GLSL，
// 原生的 Private 驱动需要平台私有格式，两者都不在此列；内置 Shader 借用设备默认 Shader，不经过这里。
shader_driver_supported :: (driver: F.Graphics_Driver) -> bool {
    #if OS == .WASM {
        return false;
    } else {
        return driver == .VULKAN || driver == .D3D12 || driver == .METAL;
    }
}

// 按驱动取代码；借用调用方的切片，不复制。未知驱动和缺失格式都返回空切片。
shader_pick :: (driver: F.Graphics_Driver, binaries: Shader_Binaries) -> [] u8 {
    if driver == .D3D12 return binaries.dxil;
    if driver == .METAL return binaries.msl;
    if driver == .VULKAN return binaries.spv;
    return .[];
}

// 产物文件的格式扩展名，与 shader_pick 的选择一致；未知驱动返回空串。
shader_format :: (driver: F.Graphics_Driver) -> string {
    if driver == .D3D12 return "dxil";
    if driver == .METAL return "msl";
    if driver == .VULKAN return "spv";
    return "";
}
//@endregion

//@region 目录登记

// olib 的 runtime.Load_Directory_File 是 #load_directory 的元素类型。jacket 0.35.1 不支持
// #load_directory，所以这里自带同名结构：name 是**相对目录**的文件名，data 借用至库释放。
Load_Directory_File :: struct {
    name: string;
    data: [] u8;
}

// 读出目录里的全部文件（name 是相对于 directory 的文件名；name 与 data 都归调用方，
// 用 material_load_directory_free 释放）。这是 #load_directory 的运行时替身：
// 只需要 *.shader.json 与编译产物，其余文件由 material_register_directory 忽略。
material_load_directory :: (directory: string) -> [] Load_Directory_File {
    files: [..] Load_Directory_File;
    paths := FU.file_list(directory, false, true);
    defer {
        for path: paths {
            if path.data != null free(path.data);
        }
        if paths.data != null array_free(paths);
    }
    for path: paths {
        contents, readable := FILE.read_entire_file(path);
        if !readable continue;
        entry: Load_Directory_File;
        entry.name = copy_string(material_file_name(path));
        entry.data = cast([] u8) contents;
        array_add(*files, entry);
    }
    return files;
}

material_load_directory_free :: (files: [] Load_Directory_File) {
    for file: files {
        if file.name.data != null free(file.name.data);
        if file.data.data != null free(file.data.data);
    }
    if files.data != null free(files.data);
}

// 路径里的最后一段（不复制；调用方要用就 copy_string）。
material_file_name :: (path: string) -> string {
    last := -1;
    for c, i: path {
        if c == #char "/" || c == #char "\\" last = i;
    }
    if last < 0 return path;
    return material_substring(path, last + 1, path.count);
}

// 登记一个目录里的全部材质 Shader。files 是目录里的所有文件（olib 用 #load_directory，
// 本包用 material_load_directory 或调用方自己拼的数组）。每个 *.shader.json 按参数组名找当前后端的
// <组名>.vertex / .fragment，instanced 精灵再找 <组名>.instanced.vertex；其他文件忽略。
// 首个 Pass 不是 Model / Sprite 的 Shader 只供 Shader Lab 预览，跳过。遇到第一个错误即返回，
// 诊断以文件名开头，之前已登记的 Shader 保留；一个清单都没有时报错（多半是目录写错）。
// 字节码借用嵌入数据，不复制。返回空串表示成功，诊断文本借用至本帧结束。
material_register_directory :: (library: *Material_Library, files: [] Load_Directory_File) -> string {
    reason := shader_backend_check(library);
    if reason != "" return reason;
    format := shader_format(library.device.driver);
    manifests := 0;
    for file: files {
        if !STRING.ends_with(file.name, ".shader.json") continue;
        manifests += 1;
        parsed: Compiled_Manifest;
        reason = compiled_manifest_parse(file.data, *parsed);
        if reason == "" {
            if !sh.shader_is_material(parsed.shader) {
                compiled_manifest_dispose(*parsed);
                continue;
            }
            instanced := parsed.shader.instanced && sh.shader_is_sprite(parsed.shader);
            code := material_temp_array(Material_Program_Code, parsed.schemas.count);
            for schema, i: parsed.schemas {
                vertex, fragment, instanced_vertex: [] u8;
                missing: string;
                vertex, missing = compiled_file(files, schema.name, "vertex", format);
                if missing == "" fragment, missing = compiled_file(files, schema.name, "fragment", format);
                if missing == "" && instanced {
                    instanced_vertex, missing = compiled_file(files, schema.name, "instanced.vertex", format);
                }
                if missing != "" {
                    // olib 在这里直接返回：这条诊断以**缺失的文件名**开头，不套清单文件名。
                    compiled_manifest_dispose(*parsed);
                    return tprint("%: missing compiled shader; re-run tools/shaders", missing);
                }
                code[i] = Material_Program_Code.{ vertex = vertex, fragment = fragment,
                                                 instanced_vertex = instanced_vertex };
            }
            if reason == "" reason = material_register(library, parsed.shader, parsed.schemas, code);
        }
        compiled_manifest_dispose(*parsed);
        if reason != "" return tprint("%: %", file.name, reason);
    }
    if manifests == 0 return "No compiled shader manifest (*.shader.json) in directory";
    return "";
}

// 清单由 tools/shaders 生成（schemas + shader），passes 与 schemas 一一对应。
// 内部完成选择后端、解析、material_register 与临时数据释放；库深复制 Shader，字节码借用至
// material_library_dispose。返回空串表示成功，诊断文本借用至本帧结束。
// 字节码就在 tools/shaders 的产物目录里时，用 material_register_directory 一次登记整个目录；
// 这里用于字节码来自别处（自定义打包等）的情况。
material_register_manifest :: (library: *Material_Library, manifest: [] u8, passes: [] Pass_Binaries) -> string {
    reason := shader_backend_check(library);
    if reason != "" return reason;
    // 解析失败时也要能安全 dispose：先清零（olib 的 zero 值同样是 nil 切片）。
    parsed: Compiled_Manifest = .{};
    reason = compiled_manifest_parse(manifest, *parsed);
    if reason != "" {
        compiled_manifest_dispose(*parsed);
        return reason;
    }
    driver := library.device.driver;
    code := material_temp_array(Material_Program_Code, passes.count);
    for pass, i: passes {
        code[i] = Material_Program_Code.{ vertex = shader_pick(driver, pass.vertex),
                                          fragment = shader_pick(driver, pass.fragment),
                                          instanced_vertex = shader_pick(driver, pass.instanced_vertex) };
    }
    reason = material_register(library, parsed.shader, parsed.schemas, code);
    compiled_manifest_dispose(*parsed);
    return reason;
}

// tools/shaders 写出的清单：各参数组的 Schema 与 Shader。
Compiled_Manifest :: struct {
    version: int;
    schemas: [] sh.Schema;
    shader: sh.Shader_Desc; // 清单里的键仍是 "effect"（见 compiled_manifest_parse）
}

// 两种登记共用：设备与后端在解析清单之前检查。
shader_backend_check :: (library: *Material_Library) -> string {
    if library.device == null return "Missing graphics device";
    if !shader_driver_supported(library.device.driver) return "Unsupported shader backend";
    return "";
}

// 清单版本即生成代码与宿主的绑定约定版本，约定变化时递增，旧产物登记时报错而不是画错。
// 2：精灵记录首项为两条轴；精灵缓冲变体顶点 b1 为变换栈；顶点 b0 在投影/矩阵后接 Clock。
MANIFEST_VERSION :: 2;

// 解析并检查版本；无论成败都用 compiled_manifest_dispose 释放。两种登记共用这里的诊断文本。
compiled_manifest_parse :: (data: [] u8, parsed: *Compiled_Manifest) -> string {
    document, ok := JSON.json_parse(sh.shader_bytes_to_string(data), temp);
    if !ok || document.kind != .Object return "Invalid compiled shader manifest";
    // 必须清零：失败路径会 compiled_manifest_dispose(*manifest)，
    // 未初始化的 schema 槽位会让它 free 垃圾指针（jacket 会直接崩）。
    manifest := Compiled_Manifest.{};
    member: JSON.Json_Value;
    if sh.shader_json_member(document, "version", *member) {
        if !sh.shader_json_int(member, *manifest.version) return "Invalid compiled shader manifest";
    }
    if sh.shader_json_member(document, "schemas", *member) {
        if member.kind != .Array return "Invalid compiled shader manifest";
        manifest.schemas = sh.shader_alloc_array(sh.Schema, member.array_val.count);
        for *slot: manifest.schemas slot.* = sh.Schema.{};
        for element, i: member.array_val {
            if !material_json_schema(<<element, *manifest.schemas[i]) {
                // 借用 JSON 文档的字符串不能 dispose（它们不归本函数所有）。
                return "Invalid compiled shader manifest";
            }
        }
    }
    if sh.shader_json_member(document, "effect", *member) {
        if !material_json_shader(member, *manifest.shader) {
            return "Invalid compiled shader manifest";
        }
    }
    // 到这里为止所有字符串都借用 JSON 文档（temp）；登记与释放都要求自有内存，
    // 所以统一克隆一份（olib 的 json.unmarshal 本来就为字符串分配新内存）。
    if manifest.schemas.count > 0 {
        owned := sh.shader_alloc_array(sh.Schema, manifest.schemas.count);
        for *slot: owned slot.* = sh.Schema.{};
        for schema, i: manifest.schemas owned[i] = sh.schema_clone(schema);
        manifest.schemas = owned;
    }
    manifest.shader = sh.shader_clone(manifest.shader);

    parsed.* = manifest;
    if parsed.version != MANIFEST_VERSION return "Compiled shader manifest is outdated; re-run tools/shaders";
    return "";
}

compiled_manifest_dispose :: (parsed: *Compiled_Manifest) {
    if parsed.schemas.data != null {
        for *schema: parsed.schemas sh.schema_dispose(schema);
        array_free(parsed.schemas);
    }
    parsed.schemas = .[];
    sh.shader_dispose(*parsed.shader);
}

// 在嵌入的目录里找 <组名>.<阶段>.<格式>；找不到时返回期望的文件名，供诊断使用。
compiled_file :: (files: [] Load_Directory_File, group: string, stage: string, format: string) -> (data: [] u8, missing: string) {
    name := tprint("%.%.%", group, stage, format);
    for file: files {
        if file.name == name return file.data, "";
    }
    return .[], name;
}
//@endregion

//@region 清单 JSON 读取（替代 odin 的反射反序列化）

// olib 用 json.unmarshal 把清单直接填进 sh.Schema / sh.Shader_Desc：缺键 = 零值、未知键忽略、
// 类型不符 = 失败。这里逐键取，规则相同；键名与枚举拼写（成员名）与 odin 的反射一致，
// 因此同一份 tools/shaders 清单在两个仓库里读出的内容逐字段相同。

material_json_bool :: (value: JSON.Json_Value, out: *bool) -> bool {
    if value.kind != .Boolean return false;
    out.* = value.bool_val;
    return true;
}

// 枚举按成员名读写（odin 的 json 编码同样写成员名，例如 "Scalar" / "Less_Equal"）。
material_json_enum :: (value: JSON.Json_Value, out: *$E) -> bool {
    if value.kind != .String return false;
    names := enum_names(E);
    numbers := enum_values_as_s64(E);
    for name, i: names {
        if name == value.string_val {
            out.* = cast(E) numbers[i];
            return true;
        }
    }
    return false;
}

material_json_field :: (value: JSON.Json_Value, out: *sh.Field) -> bool {
    if value.kind != .Object return false;
    field: sh.Field;
    member: JSON.Json_Value;
    if sh.shader_json_member(value, "id", *member) {
        if !sh.shader_json_string(member, *field.id) return false;
    }
    if sh.shader_json_member(value, "name", *member) {
        if !sh.shader_json_string(member, *field.name) return false;
    }
    if sh.shader_json_member(value, "label", *member) {
        if !sh.shader_json_string(member, *field.label) return false;
    }
    if sh.shader_json_member(value, "kind", *member) {
        if !material_json_enum(member, *field.kind) return false;
    }
    if sh.shader_json_member(value, "minimum", *member) {
        if !sh.shader_json_float32(member, *field.minimum) return false;
    }
    if sh.shader_json_member(value, "maximum", *member) {
        if !sh.shader_json_float32(member, *field.maximum) return false;
    }
    if sh.shader_json_member(value, "step", *member) {
        if !sh.shader_json_float32(member, *field.step) return false;
    }
    if sh.shader_json_member(value, "initial", *member) {
        if !sh.shader_json_numbers4(member, *field.initial) return false;
    }
    if sh.shader_json_member(value, "texture", *member) {
        if !sh.shader_json_string(member, *field.texture) return false;
    }
    if sh.shader_json_member(value, "instance", *member) {
        if !material_json_bool(member, *field.instance) return false;
    }
    if sh.shader_json_member(value, "filter", *member) {
        if !material_json_enum(member, *field.filter) return false;
    }
    if sh.shader_json_member(value, "wrap", *member) {
        if !material_json_enum(member, *field.wrap) return false;
    }
    if sh.shader_json_member(value, "filter_declared", *member) {
        if !material_json_bool(member, *field.filter_declared) return false;
    }
    if sh.shader_json_member(value, "wrap_declared", *member) {
        if !material_json_bool(member, *field.wrap_declared) return false;
    }
    out.* = field;
    return true;
}

material_json_schema :: (value: JSON.Json_Value, out: *sh.Schema) -> bool {
    if value.kind != .Object return false;
    schema: sh.Schema;
    member: JSON.Json_Value;
    if sh.shader_json_member(value, "name", *member) {
        if !sh.shader_json_string(member, *schema.name) return false;
    }
    if sh.shader_json_member(value, "shader", *member) {
        if !sh.shader_json_string(member, *schema.shader) return false;
    }
    if sh.shader_json_member(value, "preview", *member) {
        if !sh.shader_json_string(member, *schema.preview) return false;
    }
    if sh.shader_json_member(value, "label", *member) {
        if !sh.shader_json_string(member, *schema.label) return false;
    }
    if sh.shader_json_member(value, "folder", *member) {
        if !sh.shader_json_string(member, *schema.folder) return false;
    }
    if sh.shader_json_member(value, "fields", *member) {
        if member.kind != .Array return false;
        schema.fields = sh.shader_alloc_array(sh.Field, member.array_val.count);
        for element, i: member.array_val {
            if !material_json_field(<<element, *schema.fields[i]) {
                sh.schema_dispose(*schema);
                return false;
            }
        }
    }
    out.* = schema;
    return true;
}

material_json_pass_input :: (value: JSON.Json_Value, out: *sh.Pass_Input) -> bool {
    if value.kind != .Object return false;
    input: sh.Pass_Input;
    member: JSON.Json_Value;
    if sh.shader_json_member(value, "field", *member) {
        if !sh.shader_json_string(member, *input.field) return false;
    }
    if sh.shader_json_member(value, "target", *member) {
        if !sh.shader_json_string(member, *input.target) return false;
    }
    if sh.shader_json_member(value, "frame", *member) {
        if !material_json_enum(member, *input.frame) return false;
    }
    out.* = input;
    return true;
}

material_json_pass_value :: (value: JSON.Json_Value, out: *sh.Pass_Value) -> bool {
    if value.kind != .Object return false;
    entry: sh.Pass_Value;
    member: JSON.Json_Value;
    if sh.shader_json_member(value, "field", *member) {
        if !sh.shader_json_string(member, *entry.field) return false;
    }
    if sh.shader_json_member(value, "number", *member) {
        if !sh.shader_json_numbers4(member, *entry.number) return false;
    }
    out.* = entry;
    return true;
}

material_json_target :: (value: JSON.Json_Value, out: *sh.Target_Desc) -> bool {
    if value.kind != .Object return false;
    target: sh.Target_Desc;
    member: JSON.Json_Value;
    if sh.shader_json_member(value, "width", *member) {
        if !sh.shader_json_int(member, *target.width) return false;
    }
    if sh.shader_json_member(value, "height", *member) {
        if !sh.shader_json_int(member, *target.height) return false;
    }
    if sh.shader_json_member(value, "scale", *member) {
        if !sh.shader_json_float32(member, *target.scale) return false;
    }
    if sh.shader_json_member(value, "format", *member) {
        if !material_json_enum(member, *target.format) return false;
    }
    if sh.shader_json_member(value, "depth", *member) {
        if !material_json_bool(member, *target.depth) return false;
    }
    if sh.shader_json_member(value, "samples", *member) {
        if !sh.shader_json_int(member, *target.samples) return false;
    }
    if sh.shader_json_member(value, "clear", *member) {
        if !sh.shader_json_numbers4(member, *target.clear) return false;
    }
    out.* = target;
    return true;
}

material_json_state :: (value: JSON.Json_Value, out: *sh.Pass_State) -> bool {
    if value.kind != .Object return false;
    state: sh.Pass_State;
    member: JSON.Json_Value;
    if sh.shader_json_member(value, "cull", *member) {
        if !material_json_enum(member, *state.cull) return false;
    }
    if sh.shader_json_member(value, "blend", *member) {
        if !material_json_enum(member, *state.blend) return false;
    }
    if sh.shader_json_member(value, "depth", *member) {
        if !material_json_enum(member, *state.depth) return false;
    }
    if sh.shader_json_member(value, "depth_write", *member) {
        if !material_json_enum(member, *state.depth_write) return false;
    }
    out.* = state;
    return true;
}

material_json_pass :: (value: JSON.Json_Value, out: *sh.Pass_Desc) -> bool {
    if value.kind != .Object return false;
    pass: sh.Pass_Desc;
    member: JSON.Json_Value;
    if sh.shader_json_member(value, "id", *member) {
        if !sh.shader_json_string(member, *pass.id) return false;
    }
    if sh.shader_json_member(value, "params", *member) {
        if !sh.shader_json_string(member, *pass.params) return false;
    }
    if sh.shader_json_member(value, "output", *member) {
        if !sh.shader_json_string(member, *pass.output) return false;
    }
    if sh.shader_json_member(value, "label", *member) {
        if !sh.shader_json_string(member, *pass.label) return false;
    }
    if sh.shader_json_member(value, "disabled", *member) {
        if !material_json_bool(member, *pass.disabled) return false;
    }
    if sh.shader_json_member(value, "draw", *member) {
        if !material_json_enum(member, *pass.draw) return false;
    }
    if sh.shader_json_member(value, "inputs", *member) {
        if member.kind != .Array return false;
        pass.inputs = sh.shader_alloc_array(sh.Pass_Input, member.array_val.count);
        for element, i: member.array_val {
            if !material_json_pass_input(<<element, *pass.inputs[i]) {
                material_pass_dispose(*pass);
                return false;
            }
        }
    }
    if sh.shader_json_member(value, "sprite_texture", *member) {
        if !sh.shader_json_string(member, *pass.sprite_texture) return false;
    }
    if sh.shader_json_member(value, "values", *member) {
        if member.kind != .Array return false;
        pass.values = sh.shader_alloc_array(sh.Pass_Value, member.array_val.count);
        for element, i: member.array_val {
            if !material_json_pass_value(<<element, *pass.values[i]) {
                material_pass_dispose(*pass);
                return false;
            }
        }
    }
    if sh.shader_json_member(value, "target", *member) {
        if !material_json_target(member, *pass.target) {
            material_pass_dispose(*pass);
            return false;
        }
    }
    if sh.shader_json_member(value, "state", *member) {
        if !material_json_state(member, *pass.state) {
            material_pass_dispose(*pass);
            return false;
        }
    }
    out.* = pass;
    return true;
}

// 释放一个 Pass_Desc 的嵌套字符串与切片（shader_dispose 内部那一小段；清单解析失败时要单独用）。
material_pass_dispose :: (pass: *sh.Pass_Desc) {
    sh.shader_free_string(pass.id);
    sh.shader_free_string(pass.params);
    sh.shader_free_string(pass.output);
    sh.shader_free_string(pass.label);
    sh.shader_free_string(pass.sprite_texture);
    for *input: pass.inputs {
        sh.shader_free_string(input.field);
        sh.shader_free_string(input.target);
    }
    for *entry: pass.values sh.shader_free_string(entry.field);
    if pass.inputs.data != null array_free(pass.inputs);
    if pass.values.data != null array_free(pass.values);
    pass.* = sh.Pass_Desc.{};
}

material_json_shader :: (value: JSON.Json_Value, out: *sh.Shader_Desc) -> bool {
    if value.kind != .Object return false;
    verts: sh.Shader_Desc;
    member: JSON.Json_Value;
    if sh.shader_json_member(value, "name", *member) {
        if !sh.shader_json_string(member, *verts.name) return false;
    }
    if sh.shader_json_member(value, "output", *member) {
        if !sh.shader_json_string(member, *verts.output) return false;
    }
    if sh.shader_json_member(value, "label", *member) {
        if !sh.shader_json_string(member, *verts.label) return false;
    }
    if sh.shader_json_member(value, "passes", *member) {
        if member.kind != .Array return false;
        verts.passes = sh.shader_alloc_array(sh.Pass_Desc, member.array_val.count);
        for element, i: member.array_val {
            if !material_json_pass(<<element, *verts.passes[i]) {
                sh.shader_dispose(*verts);
                return false;
            }
        }
    }
    if sh.shader_json_member(value, "preview", *member) {
        if !sh.shader_json_string(member, *verts.preview) return false;
    }
    if sh.shader_json_member(value, "instanced", *member) {
        if !material_json_bool(member, *verts.instanced) return false;
    }
    if sh.shader_json_member(value, "skinned", *member) {
        if !material_json_bool(member, *verts.skinned) return false;
    }
    if sh.shader_json_member(value, "uniforms", *member) {
        if !material_json_enum(member, *verts.uniforms) return false;
    }
    out.* = verts;
    return true;
}
//@endregion
