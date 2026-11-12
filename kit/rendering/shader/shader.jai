// shader —— Shader 与多 Pass 的纯数据声明；不依赖编辑器或 GPU。
// 一比一移植自 olib kit/rendering/shader/shader.odin。
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                                  | JaiLib (Jai)                                      |
//   | -------------------------------------------- | ------------------------------------------------- |
//   | Params_Ref :: distinct string                | Params_Ref :: string（Jai 没有 distinct；         |
//   | Target_Ref / Field_Ref / Pass_Id 同理          | 退化成别名，丧失「不同用途不能互相赋值」的编译期保护）|
//   | clone_text :: proc(value: $T) -> T           | clone_text(value: string) -> string（别名后 T 恒为 string）|
//   | delete_text :: proc(value: $T)               | delete_text(value: *string)（Jai 只能按指针释放）  |
//   | strings.clone(s)                             | copy_string(s)                                    |
//   | delete(s) / delete(slice)                    | shader_free_string(s) / free(slice.data)         |
//   | make([]int, len(passes))                     | shader_alloc_array(int, n)                        |
//   | p^ = p; q^ = {...}                           | q.* = p; q.* = {...}                              |
//   | Pass_Input{field, target, frame}             | Pass_Input.{ field, target, frame }               |
//   | math.is_nan / math.is_inf                    | JM.isnan / JM.isinf                               |
//   | fmt.tprintf(...)                             | tprint(...)（归 temp）                             |
//   | switch { case ... }                          | if / else if 链                                    |
//   | for p, i in e.passes（左值引用）               | for *p, i: e.passes（指针迭代才能改 e）              |
//   | @(private)                                   | 去掉标注，内部过程加 shader_ 前缀                    |
#import "Basic";

// 单个 Shader 的 Pass 数与目标尺寸上限；声明校验和绘制选择共用。
MAX_PASSES :: 32;
MAX_TARGET_SIZE :: 8192;

Pass_Draw :: enum { Fullscreen; Preview_Model; Model; Sprite; }
Pass_Frame :: enum { Current; Previous; }
Target_Format :: enum { Color; Float16; Float32; }

// Default 保留调用方状态；Model 默认不透明、背面剔除、Less 深度读写。
Pass_Cull :: enum { Default; None; Front; Back; }
Pass_Blend :: enum { Default; Opaque; Alpha; Additive; Premultiplied; }
// Off 关闭深度测试；Always 开启测试但总是通过。新值只追加在末尾：编译清单按整数保存枚举。
Pass_Depth :: enum { Default; Off; Less; Less_Equal; Equal; Always; Greater; Greater_Equal; Not_Equal; Never; }
Pass_Write :: enum { Default; On; Off; }
Pass_State :: struct {
    cull: Pass_Cull;
    blend: Pass_Blend;
    depth: Pass_Depth;
    depth_write: Pass_Write;
}

Target_Desc :: struct {
    // width/height 同时为 0 时跟随预览尺寸；scale=0 表示 1。
    width, height: int;
    scale: float32;
    format: Target_Format;
    depth: bool;
    // 0 为自动：模型 4x，全屏 1x；也可显式指定 1 或 4。
    samples: int;
    clear: [4] float32;
}

Pass_Input :: struct {
    field: Field_Ref; // 使用参数的稳定 ID。
    target: Target_Ref;
    frame: Pass_Frame;
}

Pass_Value :: struct {
    field: Field_Ref;
    number: [4] float32;
}

Pass_Desc :: struct {
    id: Pass_Id;
    params: Params_Ref;
    output: Target_Ref;
    label: string;
    disabled: bool; // 缺省启用；运行时 checkbox 不改写源声明。
    draw: Pass_Draw;
    inputs: [] Pass_Input;
    // Sprite 当前帧绑定到此 Texture 字段；空值表示不使用帧贴图，不占用隐式槽位。
    sprite_texture: Field_Ref;
    // 同一参数组可重复使用；如横/纵模糊分别覆盖 direction。
    values: [] Pass_Value;
    target: Target_Desc;
    state: Pass_State;
}

// Model 是可挂在网格上的有序材质 Pass，共享外部颜色/深度目标。
// 全屏 Shader 仍使用 Preview_Model / Fullscreen 和各自独立的图目标。
shader_is_model :: (e: Shader_Desc) -> bool {
    return e.passes.count > 0 && e.passes[0].draw == .Model;
}

shader_is_sprite :: (e: Shader_Desc) -> bool {
    return e.passes.count > 0 && e.passes[0].draw == .Sprite;
}

shader_is_material :: (e: Shader_Desc) -> bool {
    return shader_is_model(e) || shader_is_sprite(e);
}

Shader_Desc :: struct {
    name: string;
    output: Target_Ref;
    label: string;
    passes: [] Pass_Desc;
    preview: string; // Shader 工作区：2d / 3d；空值兼容旧声明的模型 Pass 推断。
    // 每个绘制对象的 tint 与 [Instance] 字段随顶点传入（见 hlsl 的 OlibInstance），不同取值可合批。
    // Sprite 与 Model Shader 支持；模型需要用调用方持有的实例缓冲绘制（见 3d 包的 Model_Buffer）。
    instanced: bool;
    // 显式 GPU 蒙皮：仅 Olib Model、非 instanced；调用方绑定关节调色板。
    skinned: bool;
    // uniform 布局：Olib 为 .oshader 约定（顶点 b0 投影/矩阵块，片元 b0 Clock/Pointer/Tint、b1 参数）；
    // Foster 为借用 foster 默认 Shader 的内置 Shader（顶点 b0 矩阵，片元 b0 直接放参数，没有帧块）。
    uniforms: Uniform_Layout;
}

Uniform_Layout :: enum { Olib; Foster; }

// Shader 使用的 per-instance 接口种类，供 hlsl 与绘制路径选择。
shader_instancing :: (e: Shader_Desc) -> Instancing {
    if !e.instanced return .None;
    if shader_is_model(e) return .Model;
    return .Sprite;
}

//@region 校验与拓扑排序 —— shader_order = shader_validate + shader_sort

// 拓扑顺序归调用方；错误文本借用至 temp_allocator 重置。Previous 不参与当前帧排序。
// 返回 (order, error)；order 用 free(order.data) 释放，成功时 error 为空。
shader_order :: (e: Shader_Desc, schemas: [] Schema) -> ([] int, string) {
    reason := shader_validate(e, schemas);
    if reason != "" return .[], reason;
    return shader_sort(e);
}

// 只检查声明本身是否自洽，不分配结果。错误文本借用至 temp_allocator 重置。
shader_validate :: (e: Shader_Desc, schemas: [] Schema) -> string {
    if e.preview != "" && e.preview != "2d" && e.preview != "3d" return "Shader Preview must be 2d or 3d";
    if e.name == "" || e.passes.count == 0 || e.passes.count > MAX_PASSES {
        return "Shader requires a name and 1..32 passes";
    }
    if e.skinned && (e.uniforms != .Olib || !shader_is_model(e) || e.instanced) {
        return "Skinned requires Olib Model passes without Instanced";
    }
    output_found := false;
    for p, i: e.passes {
        reason := shader_pass_validate(e, i, schemas);
        if reason != "" return reason;
        output_found = output_found || p.output == e.output;
    }
    if !output_found return "Shader output must name a pass target";
    return "";
}

// 单个 Pass：种类/状态、与 Shader 其余部分的关系、参数组、目标，再检查输入和覆盖值。
shader_pass_validate :: (e: Shader_Desc, index: int, schemas: [] Schema) -> string {
    p := e.passes[index];
    model := shader_is_model(e);
    sprite := shader_is_sprite(e);
    object := model || sprite;
    if p.draw < .Fullscreen || p.draw > .Sprite return "Invalid pass draw kind";
    if (p.draw == .Model) != model || (p.draw == .Sprite) != sprite {
        return "Model, Sprite and image graph passes cannot mix";
    }
    if p.state.cull < .Default || p.state.cull > .Back ||
       p.state.blend < .Default || p.state.blend > .Premultiplied ||
       p.state.depth < .Default || p.state.depth > .Never ||
       p.state.depth_write < .Default || p.state.depth_write > .Off {
        return "Invalid pass render state";
    }
    if object && (p.output != e.output || p.inputs.count != 0 || p.target != e.passes[0].target) {
        return "Material passes must share one target description and cannot sample graph targets";
    }
    if p.id == "" || p.output == "" return "Pass id/output cannot be empty";
    for prior: array_view(e.passes, 0, index) {
        if p.id == prior.id || (!object && p.output == prior.output) {
            return "Pass IDs and output targets must be unique";
        }
    }
    schema: *Schema = null;
    for *candidate: schemas {
        if candidate.name == p.params schema = candidate;
    }
    if schema == null return tprint("%: unknown parameter group %", p.id, p.params);
    if model && (schema.preview != "3d" || e.preview == "2d") return "Model material requires 3d schemas and preview";
    if sprite && (schema.preview != "2d" || e.preview == "3d") {
        return "Sprite material requires 2d schemas and preview";
    }
    if e.instanced && !object return "Instanced shaders require Sprite or Model passes";
    if e.skinned && instance_count(schema.*) > 0 return "Skinned cannot use Instance fields";
    if instance_count(schema.*) > 0 && !e.instanced return "Instance fields require an Instanced shader";
    if uniform_size(schema.*) > MAX_UNIFORM_BYTES {
        return tprint("%: parameters exceed % bytes", p.id, MAX_UNIFORM_BYTES);
    }
    if instance_count(schema.*) > MAX_INSTANCE_FIELDS {
        return tprint("%: more than % Instance fields", p.id, MAX_INSTANCE_FIELDS);
    }
    for f: schema.fields {
        if f.instance && f.kind == .Texture return tprint("%: Texture cannot be Instance", f.id);
    }
    if p.sprite_texture != "" {
        field := field_index(schema.*, p.sprite_texture);
        if !sprite || field < 0 || schema.fields[field].kind != .Texture {
            return "sprite_texture requires a Sprite pass Texture field";
        }
    }
    if e.preview == "2d" && p.draw == .Preview_Model && schema.preview == "3d" {
        return "2d shader cannot contain a 3d model pass";
    }
    if p.draw == .Fullscreen && schema.preview != "2d" {
        return tprint("%: Fullscreen requires a 2d vertex interface", p.id);
    }
    reason := shader_target_validate(p);
    if reason != "" return reason;
    reason = shader_pass_inputs_validate(e, p, schema.*);
    if reason != "" return reason;
    return shader_pass_values_validate(p, schema.*);
}

shader_target_validate :: (p: Pass_Desc) -> string {
    t := p.target;
    if t.width < 0 || t.height < 0 || (t.width == 0) != (t.height == 0) ||
       t.width > MAX_TARGET_SIZE || t.height > MAX_TARGET_SIZE ||
       JM.isnan(t.scale) || JM.isinf(t.scale) ||
       t.scale < 0 || t.scale > 4 || (t.samples != 0 && t.samples != 1 && t.samples != 4) {
        return tprint("%: invalid target size/scale/samples", p.id);
    }
    for v: t.clear {
        if JM.isnan(v) || JM.isinf(v) || v < 0 || v > 1 {
            return "Target clear color must be finite and within 0..1";
        }
    }
    return "";
}

// 输入必须是本 Pass 参数组里的 Texture 字段，且目标由某个 Pass 产出。
shader_pass_inputs_validate :: (e: Shader_Desc, p: Pass_Desc, schema: Schema) -> string {
    for input, j: p.inputs {
        for prior: array_view(p.inputs, 0, j) {
            if prior.field == input.field return "Duplicate pass texture binding";
        }
        found := false;
        for f: schema.fields found = found || (f.id == input.field && f.kind == .Texture);
        if !found return tprint("%: no Texture field %", p.id, input.field);
        found = false;
        for producer: e.passes found = found || producer.output == input.target;
        if !found return tprint("%: unknown target %", p.id, input.target);
    }
    return "";
}

// 固定覆盖值必须指向本参数组的数值字段，且落在字段范围内。
shader_pass_values_validate :: (p: Pass_Desc, schema: Schema) -> string {
    for value, j: p.values {
        for prior: array_view(p.values, 0, j) {
            if prior.field == value.field return "Duplicate pass value override";
        }
        found := false;
        for f: schema.fields {
            if f.id != value.field || f.kind == .Texture continue;
            found = true;
            for c: 0..components(f.kind) - 1 {
                x := value.number[c];
                if JM.isnan(x) || JM.isinf(x) || x < f.minimum || x > f.maximum {
                    return tprint("%: override outside field range", p.id);
                }
            }
        }
        if !found return tprint("%: no numeric field %", p.id, value.field);
    }
    return "";
}

// 每轮选第一个所有当前帧输入都已产出的 Pass；Previous 输入不参与依赖。
// 结果由调用方持有；已校验的声明里出现无法排序的 Pass 即为当前帧环。
shader_sort :: (e: Shader_Desc) -> ([] int, string) {
    result := shader_alloc_array(int, e.passes.count);
    done: [MAX_PASSES] bool;
    for n: 0..e.passes.count - 1 {
        chosen := -1;
        for p, i: e.passes {
            if done[i] continue;
            ready := true;
            for input: p.inputs {
                if input.frame == .Previous continue;
                for producer, j: e.passes {
                    if producer.output == input.target && !done[j] ready = false;
                }
            }
            if ready {
                chosen = i;
                break;
            }
        }
        if chosen < 0 {
            if result.data != null free(result.data);
            return .[], "Current-frame pass cycle; use Previous for feedback";
        }
        result[n] = chosen;
        done[chosen] = true;
    }
    return result, "";
}
//@endregion

//@region 所有权 —— clone / dispose 深复制与释放全部嵌套字符串和切片

shader_clone :: (e: Shader_Desc) -> Shader_Desc {
    r := Shader_Desc.{
        name = clone_text(e.name), output = clone_text(e.output), label = clone_text(e.label),
        preview = clone_text(e.preview), passes = shader_alloc_array(Pass_Desc, e.passes.count),
        instanced = e.instanced, skinned = e.skinned, uniforms = e.uniforms,
    };
    for p, i: e.passes {
        q := p;
        q.id = clone_text(p.id);
        q.label = clone_text(p.label);
        q.sprite_texture = clone_text(p.sprite_texture);
        q.params = clone_text(p.params);
        q.output = clone_text(p.output);
        q.inputs = shader_alloc_array(Pass_Input, p.inputs.count);
        for input, j: p.inputs {
            q.inputs[j] = Pass_Input.{ field = clone_text(input.field), target = clone_text(input.target),
                                       frame = input.frame };
        }
        q.values = shader_alloc_array(Pass_Value, p.values.count);
        for value, j: p.values {
            q.values[j] = Pass_Value.{ field = clone_text(value.field), number = value.number };
        }
        r.passes[i] = q;
    }
    return r;
}

shader_dispose :: (e: *Shader_Desc) {
    shader_free_string(e.name);
    shader_free_string(e.label);
    shader_free_string(e.preview);
    shader_free_string(e.output);
    for *p: e.passes {
        shader_free_string(p.id);
        shader_free_string(p.label);
        shader_free_string(p.sprite_texture);
        shader_free_string(p.params);
        shader_free_string(p.output);
        for *input: p.inputs {
            shader_free_string(input.field);
            shader_free_string(input.target);
        }
        for *value: p.values shader_free_string(value.field);
        if p.inputs.data != null free(p.inputs.data);
        if p.values.data != null free(p.values.data);
    }
    if e.passes.data != null free(e.passes.data);
    e.* = Shader_Desc.{};
}
//@endregion

//@region 稳定引用

// Shader 声明里的稳定引用；不持有 GPU 资源。
//
// odin 用 `distinct string` 保证「不同用途的已命名值不能互相赋值」；Jai 没有 distinct，
// 这里退化成类型别名。字段名、语义、比较规则与 olib 完全相同，只是丢掉了那层编译期保护。
Params_Ref :: string;
Target_Ref :: string;
Field_Ref :: string;
Pass_Id :: string;

// 复制 / 释放字符串类声明：普通 string 与上面的别名通用，免去逐处强制转换。
// 新增拥有字符串的声明字段时，须同步 shader_clone / shader_dispose（Schema 见 schema_clone / schema_dispose）。
clone_text :: (value: string) -> string {
    return copy_string(value);
}

delete_text :: (value: *string) {
    if value.data != null free(value.data);
    value.* = "";
}

// odin 的 delete(str)（值语义、写回空串）：Jai 的 free 必须拿到指针，这里统一成一个桥接。
shader_free_string :: (value: string) {
    if value.data != null free(value.data);
}

// odin 的 make([]T, count)：alloc + 清零。返回的切片用 free(x.data) 释放。
shader_alloc_array :: ($T: Type, count: int) -> [] T {
    if count <= 0 return .[];
    memory := alloc(cast(s64) (count * size_of(T)));
    assert(memory != null, "shader: 分配失败");
    memset(memory, 0, cast(s64) (count * size_of(T)));
    return .{ count, cast(*T) memory };
}
//@endregion
