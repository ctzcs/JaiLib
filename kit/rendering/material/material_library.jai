// material:material_library —— 材质库：登记 Shader，集中持有并复用 Shader/纹理；实例见 material.jai。
// 一比一移植自 olib kit/rendering/material/material_library.odin。
//
// Jai 侧差异（逐条对应 olib 的写法，登记/缓存/释放语义不变）：
//   | olib (Odin)                                    | JaiLib (Jai)                                           |
//   | ---------------------------------------------- | ------------------------------------------------------ |
//   | foster.GraphicsDevice / StorageContainer       | F.Graphics_Device / F.Storage_Container                |
//   | foster.Texture（值 + .Resource）                 | *F.Texture（jfoster 的贴图是 texture_create 里 New 出来  |
//   |                                                | 的堆对象；dispose 只还 GPU 资源，指针要自己 free）        |
//   | []foster.Shader / []foster.Material             | []*F.Shader / []*F.Material                            |
//   | shader.vertex[i].Resource == nil               | material_shader_ready(program)：handle != 0 且未 dispose |
//   | foster.ShaderInit(&s, dev, {Stage, Code, …}, n) | F.shader_create(dev, stage, code, sampler_count=…,      |
//   |                                                | uniform_buffer_count=…, storage_buffer_count=…,        |
//   |                                                | entry_point=…, name=…)                                 |
//   | foster.MaterialInitWithShaders(&m, &vs, &fs)    | F.material_create(vs, fs)                              |
//   | foster.MaterialDispose / ShaderDispose /        | F.material_destroy / F.shader_dispose + free /         |
//   | TextureDispose                                 | F.texture_dispose + free（见 material_texture_release）  |
//   | foster.TextureInit(&t, dev, 1, 1, .Color, name) | F.texture_create(dev, 1, 1, .COLOR, name = …)          |
//   | foster.TextureSetData(&t, &pixel[0], 4)         | F.texture_set_data(*t, array_view(pixel, 0, 4))        |
//   | foster.ImageFromEncoded / ImagePremultiply /    | F.image_decode / F.image_premultiply /                 |
//   | TextureFromImage                               | F.texture_create_from_colors                           |
//   | foster.ReadAllBytes(storage, path, temp)       | F.storage_read_all_bytes（没有 allocator 形参，走        |
//   |                                                | context.allocator；读完立即 free，语义同 temp 借用）      |
//   | device.Driver                                  | device.driver（jfoster 全小写字段）                      |
//   | device.Defaults.Initialized / .VertexShader     | device.defaults（F.Default_Resources）的 batch_material / |
//   | / .MsdfVertexShader                            | msdf_material：jfoster 没有 Initialized 标志，也没把       |
//   |                                                | 默认 Shader 单独摊开，只有整份默认 Material               |
//   | make([]T, n) / delete(x)                       | sh.shader_alloc_array(T, n) / free(x.data)（先判 null）  |
//   | append(&dynamic, x)                            | array_add(*dynamic, x)                                 |
//   | `when ODIN_OS == .JS`                          | `#if OS == .WASM`（jfoster 没有 Web 后端，见 module.jai 第 5 条）|
//   | @(private)                                     | 去掉标注，内部过程加 material_ / builtin_ 前缀            |
#import "Basic";

//@region 类型与所有权

// 使用当前设备后端的预编译代码；借用字节至 material_library_dispose，通常来自 #load。
Material_Program_Code :: struct {
    vertex, fragment: [] u8;
    instanced_vertex: [] u8; // instanced 精灵 Shader 的缓冲变体顶点，供常驻 Sprite_Buffer；其余 Shader 为空
}

Material_Library :: struct {
    device: *F.Graphics_Device;
    storage: *F.Storage_Container;
    // 以下缓存由库维护；库地址、device/storage 须在存活期间保持稳定。
    shaders: [..] *Material_Shader;
    textures: [..] *Material_Texture;
    instances: [..] *Material;
    white: *F.Texture;
}

Material_Shader :: struct {
    desc: sh.Shader_Desc;
    schemas: [] sh.Schema;
    code: [] Material_Program_Code;
    vertex, fragment: [] *F.Shader;
    instanced_vertex: [] *F.Shader; // 只有 instanced 精灵 Shader 有，与 gpu 同序
    gpu: [] *F.Material;
    ready: bool;
}
Material_Texture :: struct {
    path: string;
    texture: *F.Texture;
}

material_library_dispose :: (library: *Material_Library) {
    for instance: library.instances {
        material_instance_clear(instance);
        free(instance);
    }
    for shader: library.shaders {
        material_shader_gpu_clear(shader);
        for *schema: shader.schemas sh.schema_dispose(schema);
        sh.shader_dispose(*shader.desc);
        if shader.schemas.data != null free(shader.schemas.data);
        if shader.code.data != null free(shader.code.data);
        free(shader);
    }
    for texture: library.textures {
        material_texture_release(texture.texture);
        if texture.path.data != null free(texture.path.data);
        free(texture);
    }
    material_texture_release(library.white);
    if library.instances.data != null array_free(library.instances);
    if library.shaders.data != null array_free(library.shaders);
    if library.textures.data != null array_free(library.textures);
    library.* = Material_Library.{};
}

// olib: forge/ShaderDispose 只还对 GPU 资源；jfoster 的 Shader 是 New 出来的，结构体要自己 free。
// 没建过（handle == 0）或设备已销毁时只 free 结构体，不碰 SDL。
material_shader_release :: (program: *F.Shader) {
    if program == null return;
    if program.handle != 0 && program.device != null && !program.device.disposed {
        F.shader_dispose(program);
    }
    free(program);
}

// olib: foster.TextureDispose(&tex)；同样要把 jfoster 的堆对象一起还掉。
material_texture_release :: (texture: *F.Texture) {
    if texture == null return;
    if texture.handle != 0 && texture.device != null && !texture.device.disposed {
        F.texture_dispose(texture);
    }
    free(texture);
}

// Shader 的 GPU 程序是否可用（olib: `Shader.Resource != nil`）。
material_shader_ready :: (program: *F.Shader) -> bool {
    return program != null && program.handle != 0 && !program.is_disposed;
}

// Material 的两个阶段是否都挂上了可用程序（olib: Vertex.Shader/Fragment.Shader 及其 Resource）。
material_program_ready :: (material: *F.Material) -> bool {
    if material == null return false;
    return material_shader_ready(material.Vertex.shader) && material_shader_ready(material.Fragment.shader);
}

material_shader_gpu_clear :: (shader: *Material_Shader) {
    for gpu: shader.gpu {
        if gpu == null continue;
        F.material_destroy(gpu); // Material 是 New 出来的，material_destroy 内部已 free
    }
    for program: shader.vertex {
        material_shader_release(program);
    }
    for program: shader.fragment {
        material_shader_release(program);
    }
    for program: shader.instanced_vertex {
        material_shader_release(program);
    }
    for *program: shader.code {
        if program.vertex.data != null free(program.vertex.data);
        if program.fragment.data != null free(program.fragment.data);
        if program.instanced_vertex.data != null free(program.instanced_vertex.data);
        program.* = Material_Program_Code.{};
    }
    if shader.code.data != null free(shader.code.data);
    shader.code = .[];
    if shader.gpu.data != null array_free(shader.gpu);
    if shader.vertex.data != null array_free(shader.vertex);
    if shader.fragment.data != null array_free(shader.fragment);
    if shader.instanced_vertex.data != null array_free(shader.instanced_vertex);
    shader.gpu = .[];
    shader.vertex = .[];
    shader.fragment = .[];
    shader.instanced_vertex = .[];
    shader.ready = false;
}
//@endregion

//@region Shader 登记 —— 资源初始化调用一次；深复制描述，惰性创建 GPU 资源。

material_register :: (library: *Material_Library, shader: sh.Shader_Desc, schemas: [] sh.Schema,
                      code: [] Material_Program_Code) -> string {
    #if OS == .WASM {
        reason := material_web_check(shader, schemas);
        if reason != "" return reason;
    }
    if !sh.shader_is_material(shader) return "Expected Model or Sprite material shader";
    if schemas.count != code.count return "Shader code count differs from schema count";
    for prior: library.shaders {
        if prior.desc.name == shader.name return "Shader already registered";
    }
    for schema, i: schemas {
        for prior: array_view(schemas, 0, i) {
            if prior.name == schema.name return "Duplicate shader group";
        }
        if code[i].vertex.count == 0 || code[i].fragment.count == 0 return "Missing compiled shader code";
        if shader.instanced && sh.shader_is_sprite(shader) && code[i].instanced_vertex.count == 0 {
            return "Missing instanced sprite vertex code";
        }
        if sh.texture_count(schema) > sh.MAX_TEXTURES return "Too many texture bindings";
    }
    order, reason := sh.shader_order(shader, schemas);
    if order.data != null free(order.data);
    if reason != "" return reason;
    entry := New(Material_Shader);
    entry.desc = sh.shader_clone(shader);
    entry.schemas = sh.shader_alloc_array(sh.Schema, schemas.count);
    entry.code = sh.shader_alloc_array(Material_Program_Code, code.count);
    if code.count > 0 memcpy(entry.code.data, code.data, code.count * size_of(Material_Program_Code));
    // 0.35.1 没有 #load_directory，字节码通常由 material_load_directory 在运行期读入；
    // olib 那份是 #load 的静态数据，可以借用，这里必须自己持有一份，否则调用方释放
    // 目录缓冲后惰性创建的 Shader 会读到已释放内存（SDl 报 "not valid DXIL/SPIR-V"）。
    for *program: entry.code {
        program.vertex = material_owned_bytes(program.vertex);
        program.fragment = material_owned_bytes(program.fragment);
        program.instanced_vertex = material_owned_bytes(program.instanced_vertex);
    }
    for schema, i: schemas entry.schemas[i] = sh.schema_clone(schema);
    array_add(*library.shaders, entry);
    return "";
}

// 复制一段字节码；空切片返回空切片（dispose 用 .data != null 判空）。
material_owned_bytes :: (source: [] u8) -> [] u8 {
    if source.count <= 0 return .[];
    dest := sh.shader_alloc_array(u8, source.count);
    memcpy(dest.data, source.data, source.count);
    return dest;
}

// Web 后端只支持 foster 的 uniform 布局（矩阵与一个片元 float），没有 storage buffer 与实例缓冲。
// 只在 Web 构建时调用；独立成函数以便在桌面上测试。
material_web_check :: (shader: sh.Shader_Desc, schemas: [] sh.Schema) -> string {
    for schema: schemas {
        if sh.instance_count(schema) > 0 return "Web does not support Instance storage buffers";
    }
    if shader.instanced return "Web does not support instanced materials";
    if shader.uniforms != .Foster return "Web requires Foster uniform layout; Olib Clock and parameter blocks are unsupported";
    return "";
}

// 宿主为每阶段提交的 uniform 槽数（精灵缓冲变体另有自己的顶点 Shader，不在此列）。
// Olib：顶点 b0 帧块，精灵 b1 Pass 偏移；片元 b0 帧块、b1 参数。Model 另有顶点 b1 / 片元 b2 视图块，
// 蒙皮顶点 b2/b3 各 64 个关节。Foster 布局只有顶点 b0 与片元 b0 参数。
// Shader 可以少声明，不能多于这里的槽数。
material_uniform_counts :: (desc: sh.Shader_Desc) -> (vertex: int, fragment: int) {
    if desc.uniforms == .Foster return 1, 1;
    if desc.skinned return 4, 3;
    if sh.shader_is_model(desc) return 2, 3;
    if sh.shader_is_sprite(desc) return 2, 2;
    return 1, 2;
}

material_shader_prepare :: (library: *Material_Library, shader: *Material_Shader) -> bool {
    if shader.ready return true;
    if library.device == null return false;
    shader.vertex = sh.shader_alloc_array(*F.Shader, shader.code.count);
    shader.fragment = sh.shader_alloc_array(*F.Shader, shader.code.count);
    shader.gpu = sh.shader_alloc_array(*F.Material, shader.code.count);
    sprite := sh.shader_is_sprite(shader.desc);
    if sprite && shader.desc.instanced {
        shader.instanced_vertex = sh.shader_alloc_array(*F.Shader, shader.code.count);
    }
    vertex_uniforms, fragment_uniforms := material_uniform_counts(shader.desc);
    for code, i: shader.code {
        // 精灵批量变体从顶点 storage buffer 读两条轴和 [Instance] 字段（见 hlsl 的 Sprite_Batch）。
        storage := 0;
        if sprite && shader.desc.uniforms == .Olib storage = 1;
        shader.vertex[i] = F.shader_create(library.device, .VERTEX, code.vertex,
            uniform_buffer_count = cast(s32) vertex_uniforms,
            storage_buffer_count = cast(s32) storage,
            entry_point = "vertex_main",
            name = shader.schemas[i].name);
        if shader.instanced_vertex.data != null {
            // 缓冲变体：b0 投影与 Clock，b1 变换栈（见 hlsl 的 Sprite）。
            shader.instanced_vertex[i] = F.shader_create(library.device, .VERTEX, code.instanced_vertex,
                uniform_buffer_count = 2,
                entry_point = "vertex_main",
                name = shader.schemas[i].name);
            if !material_shader_ready(shader.instanced_vertex[i]) {
                material_shader_gpu_clear(shader);
                return false;
            }
        }
        shader.fragment[i] = F.shader_create(library.device, .FRAGMENT, code.fragment,
            sampler_count = cast(s32) sh.texture_count(shader.schemas[i]),
            uniform_buffer_count = cast(s32) fragment_uniforms,
            entry_point = "fragment_main",
            name = shader.schemas[i].name);
        if !material_shader_ready(shader.vertex[i]) || !material_shader_ready(shader.fragment[i]) {
            material_shader_gpu_clear(shader);
            return false;
        }
        shader.gpu[i] = F.material_create(shader.vertex[i], shader.fragment[i]);
    }
    shader.ready = true;
    return true;
}
//@endregion

//@region 贴图缓存 —— 同路径只上传一次，由库统一释放。

material_texture :: (library: *Material_Library, source: string) -> (*F.Texture, string) {
    for entry: library.textures {
        if entry.path == source return entry.texture, "";
    }
    bytes := F.storage_read_all_bytes(library.storage, source);
    image := F.image_decode(bytes);
    if bytes.data != null free(bytes.data); // olib 用 temp_allocator 读，这里读完立即还
    defer F.image_destroy(*image);
    if image.Width == 0 || image.Height == 0 return null, tprint("Cannot read material texture: %", source);
    F.image_premultiply(*image);
    texture := F.texture_create_from_colors(library.device, image.Width, image.Height, image.Data, name = source);
    if texture == null || texture.handle == 0 {
        material_texture_release(texture);
        return null, tprint("Cannot upload material texture: %", source);
    }
    entry := New(Material_Texture);
    entry.texture = texture;
    entry.path = copy_string(source);
    array_add(*library.textures, entry);
    return entry.texture, "";
}
//@endregion

//@region 内置 2D Shader

// 内置 2D Shader：直接借用设备的默认 Shader（Batcher、Msdf），jfoster 已按驱动选好字节码。
// 它们沿用 foster 的 uniform 布局（Uniform_Layout.Foster）。
// 首次用名字创建材质（material_create）或 2D 渲染器初始化时自动登记，调用方不用手动 register。
//
// olib 读 device.Defaults.Initialized + 摊开的 VertexShader/FragmentShader/MsdfVertexShader/
// MsdfFragmentShader；jfoster 的默认资源只有整份默认 Material（batch_material / msdf_material），
// 没有 Initialized 标志。所以“未初始化”的判据变成 device.defaults == null 或所需默认 Material 缺失，
// 诊断文本保持 olib 的原文。

//@region 名字与参数组

// 默认精灵：贴图 × 顶点色；顶点 mode 字节选 Normal / Wash / Fill（与 foster Batcher 相同）。
BUILTIN_SPRITE :: "Sprite_Default";
// MSDF 文字：参数 distance_range 为字体图集的距离范围（像素）。
BUILTIN_TEXT :: "Text_Msdf";

builtin_is :: (name: string) -> bool {
    return name == BUILTIN_SPRITE || name == BUILTIN_TEXT;
}
//@endregion

//@region 登记 —— 幂等；设备默认资源未初始化时返回原因。

builtin_register :: (library: *Material_Library, name: string) -> string {
    for shader: library.shaders {
        if shader.desc.name == name return "";
    }
    device := library.device;
    if device == null return "Missing graphics device";
    if device.defaults == null return "Graphics device defaults are not initialized";
    text := name == BUILTIN_TEXT;
    source := device.defaults.batch_material;
    if text source = device.defaults.msdf_material;
    if source == null || source.Vertex.shader == null || source.Fragment.shader == null {
        return "Graphics device defaults are not initialized";
    }

    fields := material_temp_array(sh.Field, ifx text then 2 else 1);
    fields[0] = sh.Field.{ id = "texture", name = "texture", label = "Texture", kind = .Texture };
    if text {
        fields[1] = sh.Field.{ id = "distance_range", name = "distance_range", label = "Distance range",
            kind = .Scalar, minimum = 0, maximum = 64, step = 0.1, initial = .[4, 0, 0, 0] };
    }
    schemas := material_temp_array(sh.Schema, 1);
    schemas[0] = sh.Schema.{ name = name, preview = "2d", fields = fields };
    passes := material_temp_array(sh.Pass_Desc, 1);
    passes[0] = sh.Pass_Desc.{ id = "main", params = name, output = "color", draw = .Sprite,
        sprite_texture = "texture" };
    desc := sh.Shader_Desc.{ name = name, output = "color", passes = passes, preview = "2d", uniforms = .Foster };
    order, reason := sh.shader_order(desc, schemas);
    if order.data != null free(order.data);
    if reason != "" return reason;
    entry := New(Material_Shader);
    entry.desc = sh.shader_clone(desc);
    entry.schemas = sh.shader_alloc_array(sh.Schema, 1);
    entry.schemas[0] = sh.schema_clone(schemas[0]);
    // GPU 程序归设备所有：vertex/fragment 留空，material_shader_gpu_clear 只释放 gpu 里的 Material。
    entry.gpu = sh.shader_alloc_array(*F.Material, 1);
    entry.gpu[0] = F.material_create(source.Vertex.shader, source.Fragment.shader);
    entry.ready = true;
    array_add(*library.shaders, entry);
    return "";
}
//@endregion
//@endregion
