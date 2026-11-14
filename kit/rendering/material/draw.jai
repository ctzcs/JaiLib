// material:draw —— 共享实现：Render2D / Render3D 记录绘制时用的绑定、Pass 选择、Pass 状态与参数打包，
// 不是业务绘制入口。一比一移植自 olib kit/rendering/material/draw.odin。
//
// 因跨包复用保留这些接口；普通业务使用 material_load + r2d.image / r3d.model。
//
// Jai 侧差异（逐条对应 olib 的写法，选择/打包/返回语义不变）：
//   | olib (Odin)                                   | JaiLib (Jai)                                          |
//   | --------------------------------------------- | ----------------------------------------------------- |
//   | `foster.BoundSampler.Texture`                 | `F.Bound_Sampler.Tex`（jfoster 的字段名）               |
//   | `foster.DrawCommand`                          | `F.Draw_Command`                                      |
//   | `.None / .Front / .Back`（foster.CullMode）     | `.NONE / .FRONT / .BACK`（jfoster 全大写成员）          |
//   | `foster.BlendModeDisabled`                    | `BLEND_MODE_DISABLED`（jfoster 没有 Disabled：          |
//   |                                               | SDL 后端固定 enable_blend，用 (ONE, ZERO) 表达同一结果） |
//   | `foster.BlendModeNonPremultiplied`            | `F.Blend_Mode_NonPremultiplied`                        |
//   | `foster.BlendModePremultiply`                 | `F.Blend_Mode_Premultiply`                             |
//   | `foster.BlendModeMake(.Add, .One, .One)`      | `F.blend_mode_make(.ADD, .ONE, .ONE)`                  |
//   | `foster.DepthCompare{.LessOrEqual, …}`        | `F.Depth_Compare{.LESS_OR_EQUAL, …}`（olib 侧拼写       |
//   | `.GreatorOrEqual`（foster 的拼写错误）          | 错误的 `.GreatorOrEqual` 在 jfoster 是 `.GREATER_OR_EQUAL`）|
//   | `command.DepthTestEnabled, command.DepthCompare = true, .Less` | 拆成两条赋值（Jai 对「成员 + 多值赋值」更保守）|
//   | `b.material.Vertex.Shader.Resource == nil`    | `material_program_ready(b.material)`：handle != 0 且未释放 |
//   | `sampler.Texture == nil \|\| sampler.Texture.Resource == nil` | `sampler.Tex == null \|\| sampler.Tex.handle == 0` |
//   | `make([]Value, n, context.temp_allocator)`    | `material_temp_array(Value, n)`（talloc，olib 的 temp 语义）|
//   | `copy(dst[:], src)`                           | `memcpy(dst.data, src.data, n * size_of(T))`           |
//   | `indices: ^[MAX_PASSES]int` 的 `indices[count]` | `indices.*[count]`（Jai 的 `*x` 是取地址，指针到数组     |
//   |                                               | 的元素下标要写 `p.*[i]`）                               |
//   | `for p, i in e.passes`                        | `for p, i: e.passes`（值拷贝，只读）                     |
//   | `@(private)`                                  | 去掉标注，内部过程加 material_ 前缀                      |
#import "Basic";

//@region 绑定与错误

Material_Binding :: struct {
    schema: sh.Schema;
    values: [] sh.Value;
    material: *F.Material;
    samplers: [] F.Bound_Sampler; // 按 Schema 的 Texture 字段顺序，含默认纹理。
}

// 绘制请求被拒绝的原因；.None 表示已提交（可能 0 个 Pass：全部被禁用）。
// 出错时不会发出任何 Draw，调用方可用 draw_error_text 得到可读说明。
Draw_Error :: enum {
    None;
    Missing_Device; // 没有图形设备
    Missing_Material; // 精灵/模型没有材质，或材质尚未成功加载
    Device_Mismatch; // 材质属于另一个设备
    Missing_Mesh; // 没有可绘制的网格
    Invalid_Target; // 绘制目标尺寸无效
    Not_Material_Shader; // Shader 不是 Sprite/Model 对象材质
    Too_Many_Passes; // Shader 没有 Pass 或超过 MAX_PASSES
    Unknown_Pass; // 指定的 Pass ID 不存在
    Wrong_Pass_Kind; // Pass 种类与本次绘制（Sprite/Model）不符
    Missing_Binding; // 某个 Pass 的参数组没有绑定
    Invalid_Binding; // 绑定的 Shader、数值或贴图不完整
    Missing_Sprite_Texture; // Pass 需要当前帧贴图，但没有提供或字段不是 Texture
    Instance_Buffer_Required; // r2d/r3d.buffer 传了未创建的缓冲，或自动实例化的缓冲创建失败
    Not_Instanced_Shader; // 用实例缓冲绘制，但 Shader 没有声明 instanced
    Instance_Mismatch; // 实例缓冲的字段数与 Shader 的 [Instance] 字段数不一致
    Unsupported_Mesh; // 网格顶点格式与本次静态/蒙皮绘制入口不符
    Missing_View_Matrix; // 3D 视图没有设置视矩阵（view_matrix 为零矩阵）
    View_Globals_Too_Large; // 视图块超过 VIEW_GLOBALS_SIZE 字节

    Skin_Mismatch; // 蒙皮入口与 Shader 声明不符，或请求了不支持的蒙皮实例化

    Invalid_Joint_Palette; // 蒙皮 palette 必须有 1..128 个矩阵
}

draw_error_text :: (error: Draw_Error) -> string {
    if error == {
        case .None; return "";
        case .Missing_Device; return "No graphics device";
        case .Missing_Material; return "Sprite or model has no loaded material";
        case .Device_Mismatch; return "Material belongs to a different graphics device";
        case .Missing_Mesh; return "No mesh to draw";
        case .Invalid_Target; return "Draw target has no pixels";
        case .Not_Material_Shader; return "Shader is not a Sprite or Model material";
        case .Too_Many_Passes; return "Shader has no passes or too many passes";
        case .Unknown_Pass; return "Unknown pass ID";
        case .Wrong_Pass_Kind; return "Pass kind does not match this draw call";
        case .Missing_Binding; return "A pass has no parameter group binding";
        case .Invalid_Binding; return "A binding has missing shaders, values or textures";
        case .Missing_Sprite_Texture; return "Pass needs a frame texture that was not provided";
        case .Instance_Buffer_Required; return "Instanced shaders must be drawn with an instance buffer";
        case .Not_Instanced_Shader; return "Shader is not instanced; it cannot use an instance buffer";
        case .Instance_Mismatch; return "Instance buffer field count differs from the shader's Instance fields";
        case .Unsupported_Mesh; return "Mesh vertex format does not match the static or skinned draw path";

        case .Skin_Mismatch; return "Skinning requires a Skinned, non-instanced Olib Model shader and skinned_model";

        case .Invalid_Joint_Palette; return "Skinning requires 1..128 joint matrices";
        case .Missing_View_Matrix; return "3D view needs a view matrix (for example camera3d_view)";
        case .View_Globals_Too_Large; return "View globals exceed VIEW_GLOBALS_SIZE bytes";
    }
    return "";
}

//@endregion

//@region 视图块与 Pass 状态

// Model Pass（Olib 布局）的视图块：游戏按 std140 打包的视图级数据，库不定义其中字段。
// 顶点 b1/space1 与片元 b2/space3 是同一份字节；每次 Draw 整块提交 VIEW_GLOBALS_SIZE 字节，
// 不足部分补零，Shader 声明的块不能超过这个大小。Skinned Model 的顶点 b2/b3 为蒙皮 palette。
VIEW_GLOBALS_SIZE :: 1024;
MODEL_VIEW_VERTEX_SLOT :: 1;
MODEL_VIEW_FRAGMENT_SLOT :: 2;

// 把 globals 拷进 block、余下补零；超过 VIEW_GLOBALS_SIZE 返回 false 且不改 block。
view_globals_pack :: (block: *[VIEW_GLOBALS_SIZE] u8, globals: [] u8) -> bool {
    if globals.count > VIEW_GLOBALS_SIZE return false;
    memset(block, 0, VIEW_GLOBALS_SIZE);
    if globals.count > 0 memcpy(block, globals.data, globals.count);
    return true;
}

// jfoster 的 SDL 后端固定 enable_blend = true，没有 foster.BlendModeDisabled；
// (ONE, ZERO) 的加法混合与关闭混合结果相同：目标像素被源像素完全替换。
BLEND_MODE_DISABLED :: F.Blend_Mode.{
    ColorOperation = .ADD, ColorSource = .ONE, ColorDestination = .ZERO,
    AlphaOperation = .ADD, AlphaSource = .ONE, AlphaDestination = .ZERO,
    Mask = .RGBA, BlendColor = F.Color_White,
};

pass_state_apply :: (command: *F.Draw_Command, state: sh.Pass_State) {
    if state.cull == {
        case .Default;
        case .None; command.CullMode = .NONE;
        case .Front; command.CullMode = .FRONT;
        case .Back; command.CullMode = .BACK;
    }
    if state.blend == {
        case .Default;
        case .Opaque; command.BlendMode = BLEND_MODE_DISABLED;
        case .Alpha; command.BlendMode = F.Blend_Mode_NonPremultiplied;
        case .Premultiplied; command.BlendMode = F.Blend_Mode_Premultiply;
        case .Additive; command.BlendMode = F.blend_mode_make(.ADD, .ONE, .ONE);
    }
    if state.depth == {
        case .Default;
        case .Off;
        case .Less;
            command.DepthTestEnabled = true;
            command.DepthCompare = .LESS;
        case .Less_Equal;
            command.DepthTestEnabled = true;
            command.DepthCompare = .LESS_OR_EQUAL;
        case .Equal;
            command.DepthTestEnabled = true;
            command.DepthCompare = .EQUAL;
        case .Always;
            command.DepthTestEnabled = true;
            command.DepthCompare = .ALWAYS;
        case .Greater;
            command.DepthTestEnabled = true;
            command.DepthCompare = .GREATER;
        case .Greater_Equal;
            command.DepthTestEnabled = true;
            command.DepthCompare = .GREATER_OR_EQUAL;
        case .Not_Equal;
            command.DepthTestEnabled = true;
            command.DepthCompare = .NOT_EQUAL;
        case .Never;
            command.DepthTestEnabled = true;
            command.DepthCompare = .NEVER;
    }
    if state.depth == .Off command.DepthTestEnabled = false;
    if state.depth_write != .Default command.DepthWriteEnabled = state.depth_write == .On;
}

//@endregion

//@region 临时分配（olib 的 context.temp_allocator）

// olib: make([]T, count, context.temp_allocator)。Jai 的对应物是 talloc：不逐块释放，
// 随下次 reset_temporary_storage 一起回收，因此返回值可以借到本帧结束（与 olib 的契约相同）。
material_temp_array :: ($T: Type, count: int) -> [] T {
    if count <= 0 return .[];
    memory := talloc(cast(s64) (count * size_of(T)));
    assert(memory != null, "material: 临时分配失败");
    memset(memory, 0, cast(s64) (count * size_of(T)));
    return .{ count, cast(*T) memory };
}

//@endregion

//@region Pass 选择与绑定检查

// 按声明顺序列出要画的 Pass：pass_id 为空选全部，非空只选该 Pass；声明为 disabled 的 Pass 都不画。
material_pass_indices :: (shader: sh.Shader_Desc, pass_id: Pass_Id, indices: *[sh.MAX_PASSES] int) -> (count: int, error: Draw_Error) {
    if shader.passes.count == 0 || shader.passes.count > sh.MAX_PASSES return 0, .Too_Many_Passes;
    found := pass_id == "";
    for p, i: shader.passes {
        if pass_id != "" && p.id != pass_id continue;
        found = true;
        if p.disabled continue;
        indices.*[count] = i;
        count += 1;
    }
    if !found return 0, .Unknown_Pass;
    return count, .None;
}

// 找到 Pass 参数组对应的绑定并检查其可用于提交；多个同名绑定时取最后一个。
material_binding_find :: (p: sh.Pass_Desc, kind: sh.Pass_Draw, sprite_texture: *F.Texture, bindings: [] Material_Binding) -> (index: int, error: Draw_Error) {
    index = -1;
    for b, j: bindings {
        if b.schema.name != p.params continue;
        if b.material == null || b.values.count != b.schema.fields.count ||
           b.samplers.count != sh.texture_count(b.schema) || b.samplers.count > sh.MAX_TEXTURES {
            return -1, .Invalid_Binding;
        }
        if !material_program_ready(b.material) return -1, .Invalid_Binding;
        for sampler: b.samplers {
            if sampler.Tex == null || sampler.Tex.handle == 0 return -1, .Invalid_Binding;
        }
        index = j;
    }
    if index < 0 return -1, .Missing_Binding;
    if p.sprite_texture != "" {
        if kind != .Sprite || sprite_texture == null || sprite_texture.handle == 0 {
            return -1, .Missing_Sprite_Texture;
        }
        schema := bindings[index].schema;
        field := sh.field_index(schema, p.sprite_texture);
        if field < 0 || schema.fields[field].kind != .Texture return -1, .Missing_Sprite_Texture;
    }
    return index, .None;
}

//@endregion

//@region Pass 参数

// 一个 Pass 本次绘制的参数：参数 uniform（按 uniform_size 打包，借用 temp）与 [Instance] 字段数值。
// 不分配内存的实例值解析，供批量记录模型逐实例使用；与 material_pass_values 的覆盖顺序相同。
// 逐实例重复求值时先用 instance_table_make 建表，再对每个实例调 instance_table_write。
material_pass_instance :: (p: sh.Pass_Desc, b: Material_Binding, overrides: *Instance_Values) -> (instance: Instance_Values) {
    table := instance_table_make(p, b);
    instance.count = table.count;
    if overrides != null {
        instance_table_write(*table, array_view(overrides.numbers, 0, sh.MAX_INSTANCE_FIELDS), overrides.set,
                             array_view(instance.numbers, 0, instance.count));
    } else {
        instance_table_write(*table, .[], 0, array_view(instance.numbers, 0, instance.count));
    }
    return instance;
}

// 参数 uniform 借用 temp，实例值按值返回。
// 套用顺序：材质实例值 < overrides（instance_values）< Pass 的固定 values。
material_pass_values :: (p: sh.Pass_Desc, b: Material_Binding, overrides: *Instance_Values) -> (uniform: [] u8, instance: Instance_Values) {
    values := material_temp_array(sh.Value, b.values.count);
    if b.values.count > 0 memcpy(values.data, b.values.data, b.values.count * size_of(sh.Value));
    instance_values_apply(overrides, b.schema, values);
    for value: p.values {
        j := sh.field_index(b.schema, value.field);
        if j >= 0 values[j].number = value.number;
    }
    uniform = material_temp_array(u8, sh.uniform_size(b.schema));
    _ = sh.pack(b.schema, values, uniform);
    for f, i: b.schema.fields {
        if !f.instance || instance.count >= sh.MAX_INSTANCE_FIELDS continue;
        instance.numbers[instance.count] = values[i].number;
        instance.count += 1;
    }
    return uniform, instance;
}

// 本次绘制要画的 Pass（按声明顺序）及各自的绑定下标。
Pass_Selection :: struct {
    count: int;
    passes, bindings: [sh.MAX_PASSES] int;
}

// 解析选择并检查 Pass 种类与绑定，不提交、不改动绑定；渲染器记录绘制时用它提前得到错误。
// kind 是本次绘制的种类（Sprite / Model），sprite_texture 是精灵的当前帧（Model 传 null）。
material_select :: (shader: sh.Shader_Desc, bindings: [] Material_Binding, kind: sh.Pass_Draw, pass_id: Pass_Id,
                    sprite_texture: *F.Texture, selection: *Pass_Selection) -> Draw_Error {
    selection.* = Pass_Selection.{};
    selected: [sh.MAX_PASSES] int;
    count, error := material_pass_indices(shader, pass_id, *selected);
    if error != .None return error;
    for i: 0..count - 1 {
        index := selected[i];
        if shader.passes[index].draw != kind return .Wrong_Pass_Kind;
        bound, bound_error := material_binding_find(shader.passes[index], kind, sprite_texture, bindings);
        if bound_error != .None return bound_error;
        selection.passes[selection.count] = index;
        selection.bindings[selection.count] = bound;
        selection.count += 1;
    }
    return .None;
}

//@endregion
