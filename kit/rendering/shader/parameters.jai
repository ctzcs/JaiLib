// shader:parameters —— 材质参数：Schema（参数声明）、Value（实例数值）及其 GPU 布局。
// 一比一移植自 olib kit/rendering/shader/parameters.odin。
//
// 数据布局不依赖 Jai 结构体内存布局；本包不依赖编辑器。
// 每个数字参数占一个 float4 槽（16 字节），贴图单独编号、不占 uniform 空间——这就是
// 本包的 "std140 对位面"：槽大小、槽序、字段偏移与 olib 逐字节相同，
// pack() 的输出可以直接上传成 uniform 缓冲（foster/jfoster 的 b1/space3 参数块）。
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                              | JaiLib (Jai)                                   |
//   | ---------------------------------------- | ---------------------------------------------- |
//   | foster.TextureSampler / TextureFilter    | F.Texture_Sampler / F.Texture_Filter（jfoster） |
//   | foster.TextureSamplerMake(f, w)          | F.texture_sampler_make(f, w)                   |
//   | .Nearest / .Linear（foster 枚举）         | .NEAREST / .LINEAR（jfoster 全大写成员）         |
//   | .Clamp / .Repeat / .MirroredRepeat        | .CLAMP / .REPEAT / .MIRRORED_REPEAT            |
//   | sampler.Filter / .WrapX / .WrapY          | 同名（jfoster 与 Foster 原版同名）              |
//   | make([]Field, n)                          | shader_alloc_array(Field, n)（alloc + 清零）    |
//   | delete(x) / delete(x.data)                | free(x.data)（先判 null）                       |
//   | strings.clone(s)                          | copy_string(s)（当前 allocator）                |
//   | mem.copy(dst, src, n)                     | memcpy(dst, src, n)                            |
//   | mem.zero_slice(b)                         | memset(b.data, 0, b.count)                     |
//   | raw_data(x)                               | x.data                                         |
//   | max(1, count) * PARAM_SLOT_BYTES          | 同形（Basic.max / Basic.clamp）                 |
//   | fmt.sbprintf(&b, fmt, ...)                | print_to_builder(*b, fmt, ...)                 |
//   | [Instancing]string{...} 枚举→字符串表      | if/else 链（Jai 没有枚举下标数组，结果相同）      |
//   | for slot in 0..<slots                     | for slot: 0..slots - 1（含终点；slots=0 时跳过） |
//   | `\t` 缩进                                  | 无（本文件的生成文本用空格，与 olib 生成文本一致） |
#import "Basic";

//@region 上限与枚举

// GPU 绑定上限与布局：每个数字参数占一个 float4 槽。
MAX_TEXTURES :: 16;
// 每个参数组的统一参数字节上限：Vulkan 只保证 16 KiB 的 uniform 缓冲；shader_validate 检查。
MAX_UNIFORM_BYTES :: 16384;
PARAM_SLOT_BYTES :: 16;
// 每个绘制对象自带的数值字段（[Instance]）的硬上限；它们随顶点而不是 uniform 传给 Shader。
// 每个实例占 INSTANCE_FIXED_ATTRIBUTES + 字段数个顶点属性，再加网格自己的属性，桌面 GPU 通常支持 16～32 个，
// 所以取 16。实际用几个由 Shader 里的 [Instance] 字段数和缓冲的 slots 决定，库里没有全局配置；
// 更多的值请改用把几个标量打包进同一个 float4。
MAX_INSTANCE_FIELDS :: 16;

Kind :: enum {
    Scalar;
    Vector2;
    Vector3;
    Color;
    Texture;
}

// 贴图字段的采样方式；零值即默认的线性过滤与边缘钳制。
Texture_Filter :: enum u8 {
    Linear;
    Nearest;
}

Texture_Wrap :: enum u8 {
    Clamp;
    Repeat;
    Mirror;
}

Field :: struct {
    id, name, label: string;
    kind: Kind;
    minimum, maximum, step: float32;
    initial: [4] float32;
    texture: string;
    // 仅数值字段。true 时不占 uniform 槽，值随每个绘制对象的顶点传入，
    // 因此不同取值的对象仍可合批。Shader 里照常用 _name 读取。
    instance: bool;
    // 仅 Texture 字段：采样器的过滤与两个方向的寻址方式。*_declared 记录 .oshader / 标签里是否显式写了，
    // 精灵纹理只用写了的部分，其余跟随 Render2D 的 push_sampler。
    filter: Texture_Filter;
    wrap: Texture_Wrap;
    filter_declared, wrap_declared: bool;
}

Schema :: struct {
    name, shader, preview: string;
    label, folder: string; // 仅用于显示；name 仍是绑定和迁移的稳定 ID。
    fields: [] Field;
}

// 每个数字参数占一个 float4 槽；Texture 单独编号，不占 uniform 空间。
// instance 字段同样保存在这里，但随顶点（见 Instance_Values）而不是 uniform 传给 Shader。
Value :: struct {
    number: [4] float32;
    texture: string;
}

components :: (kind: Kind) -> int {
    if kind == {
        case .Scalar; return 1;
        case .Vector2; return 2;
        case .Vector3; return 3;
        case .Color; return 4;
        case .Texture; return 0;
    }
    return 0;
}
//@endregion

//@region 生命周期与迁移：所有字符串和切片由调用方 allocator 持有

schema_dispose :: (s: *Schema) {
    shader_free_string(s.name);
    shader_free_string(s.shader);
    shader_free_string(s.preview);
    shader_free_string(s.label);
    shader_free_string(s.folder);
    for *f: s.fields {
        shader_free_string(f.id);
        shader_free_string(f.name);
        shader_free_string(f.label);
        shader_free_string(f.texture);
    }
    if s.fields.data != null free(s.fields.data);
    s.* = Schema.{};
}

schema_clone :: (s: Schema) -> Schema {
    r := s;
    r.name = copy_string(s.name);
    r.shader = copy_string(s.shader);
    r.preview = copy_string(s.preview);
    r.label = copy_string(s.label);
    r.folder = copy_string(s.folder);
    r.fields = shader_alloc_array(Field, s.fields.count);
    for f, i: s.fields {
        r.fields[i] = f;
        r.fields[i].id = copy_string(f.id);
        r.fields[i].name = copy_string(f.name);
        r.fields[i].label = copy_string(f.label);
        r.fields[i].texture = copy_string(f.texture);
    }
    return r;
}

values_dispose :: (values: [] Value) {
    for value: values shader_free_string(value.texture);
    if values.data != null free(values.data);
}

// 字段 ID + 类型相同才迁移；新增/变更类型取默认值，范围收窄时钳制旧值。
values_make :: (schema: Schema, old := Schema.{}, previous: [] Value = .[]) -> [] Value {
    values := shader_alloc_array(Value, schema.fields.count);
    for f, i: schema.fields {
        v := Value.{ number = f.initial, texture = f.texture };
        for prior, j: old.fields {
            if j < previous.count && prior.id == f.id && prior.kind == f.kind {
                v = previous[j];
                break;
            }
        }
        for c: 0..components(f.kind) - 1 {
            v.number[c] = clamp(v.number[c], f.minimum, f.maximum);
        }
        v.texture = copy_string(v.texture);
        values[i] = v;
    }
    return values;
}
//@endregion

//@region GPU 布局：fragment b1/space3；引擎公共输入保留 b0

// 字段是否占 fragment uniform 槽：数值且不是 per-instance。
uniform_field :: (f: Field) -> bool {
    return f.kind != .Texture && !f.instance;
}

uniform_size :: (schema: Schema) -> int {
    count := 0;
    for f: schema.fields count += cast(int) uniform_field(f);
    return max(1, count) * PARAM_SLOT_BYTES;
}

// per-instance 字段个数，即每个对象顶点里携带的 float4 数据槽数。
instance_count :: (schema: Schema) -> int {
    count := 0;
    for f: schema.fields count += cast(int) f.instance;
    return count;
}

texture_count :: (schema: Schema) -> int {
    count := 0;
    for f: schema.fields count += cast(int) (f.kind == .Texture);
    return count;
}

// Texture 字段声明的采样器；材质库、material_set_texture 与 Shader Lab 预览共用。
field_sampler :: (f: Field) -> F.Texture_Sampler {
    filter: F.Texture_Filter = .LINEAR;
    if f.filter == .Nearest filter = .NEAREST;
    wrap: F.Texture_Wrap = .CLAMP;
    if f.wrap == {
        case .Clamp; wrap = .CLAMP;
        case .Repeat; wrap = .REPEAT;
        case .Mirror; wrap = .MIRRORED_REPEAT;
    }
    return F.texture_sampler_make(filter, wrap);
}

// 精灵纹理字段的采样器：字段显式写了 Filter / Wrap 的部分按字段，没写的部分沿用 inherited（Render2D 的 push_sampler）。
field_sprite_sampler :: (f: Field, inherited: F.Texture_Sampler) -> F.Texture_Sampler {
    sampler := inherited;
    declared := field_sampler(f);
    if f.filter_declared sampler.Filter = declared.Filter;
    if f.wrap_declared {
        sampler.WrapX = declared.WrapX;
        sampler.WrapY = declared.WrapY;
    }
    return sampler;
}

// 返回 (ok)。成功时 buffer 已清零并按槽序写入；长度不符直接失败，不改 buffer。
pack :: (schema: Schema, values: [] Value, buffer: [] u8) -> bool {
    if values.count != schema.fields.count || buffer.count != uniform_size(schema) return false;
    memset(buffer.data, 0, buffer.count);
    offset := 0;
    for f, i: schema.fields {
        if !uniform_field(f) continue;
        memcpy(buffer.data + offset, *values[i].number, PARAM_SLOT_BYTES);
        offset += PARAM_SLOT_BYTES;
    }
    return true;
}

// instanced Shader 按绘制种类生成不同的 per-instance 接口。两种都由调用方或渲染器提供一个
// 按实例步进的顶点缓冲，一次 Draw 画出全部实例。
Instancing :: enum {
    None;
    Sprite; // 精灵缓冲变体：实例记录含 2D 变换与图集矩形，单位四边形角点展开（常驻 Sprite_Buffer 用）
    Model; // 模型：实例数据含世界矩阵，着色器用 olib_world 取得
    Sprite_Batch; // 精灵批量变体：foster BatcherVertex 输入，[Instance] 字段从顶点 storage buffer 按 mode 偏移读取
}

// instanced 顶点输入的语义号起点（只需与网格属性的语义号不重复）；位置由声明顺序决定。
// 固定成员 world / sprite 0..3 与 tint 的语义号写在 olib/instance.hlsli，[Instance] 字段从 BASE + 5 起。
INSTANCE_SEMANTIC_BASE :: 6;
// 传给片元的变量从 TEXCOORD8 起（tint、字段），避开常见的 TEXCOORD0..7 自定义变量；同样与 olib/instance.hlsli 一致。
INSTANCE_VARYING_BASE :: 8;
// 每个实例固定的顶点属性数（4 个 float4 的变换/几何 + tint），其后是每个 [Instance] 字段一个 float4。
INSTANCE_FIXED_ATTRIBUTES :: 5;

// 返回的字符串归调用方；由 lang 直接放入每个 Pass 的候选 HLSL。
// 参数块与字段的 #define 随 Schema 生成；实例与精灵的固定代码在 olib 标准 include 里，这里只定义变体与槽位后 include：
// - olib/instance.hlsli：OlibInstanceInput（顶点输入，必须是 Input 的第一个成员）、传给片元的 OlibInstance、
//   olib_instance_from、olib_world（Model）、olib_sprite_vertex（Sprite 常驻缓冲）；
// - olib/sprite_vertex.hlsli：Sprite Pass 的 OlibSpriteInput / olib_sprite，批量与常驻缓冲两种变体。
// 非 None（或存在 per-instance 字段）时才 include；没有实例的 Model / 全屏 Shader 只有参数块。
//
// 生成文本是字节级契约：首行注释、空格缩进、`register(b1, space3)`、槽序与 swizzle 都与 olib 逐字节相同。
hlsl :: (schema: Schema, mode := Instancing.None) -> string {
    b: String_Builder;
    print_to_builder(*b, "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n");
    index := 0;
    for f: schema.fields {
        if !uniform_field(f) continue;
        print_to_builder(*b, "    float4 _olib_param_%;\n", index);
        index += 1;
    }
    if index == 0 print_to_builder(*b, "    float4 _olib_unused;\n");
    print_to_builder(*b, "};\n");
    slots := instance_count(schema);
    kind := mode;
    if kind == .None && slots > 0 kind = .Sprite;
    if kind != .None {
        // 每个槽位：X(槽位, 顶点输入语义号, 传给片元的语义号)。
        print_to_builder(*b, "#define OLIB_INSTANCE_SLOTS %\n#define OLIB_INSTANCE_DATA(X)", slots);
        for slot: 0..slots - 1 {
            print_to_builder(*b, " X(%, %, %)", slot, INSTANCE_SEMANTIC_BASE + INSTANCE_FIXED_ATTRIBUTES + slot,
                             INSTANCE_VARYING_BASE + 1 + slot);
        }
        variant := "";
        if kind == .Model variant = "OLIB_INSTANCE_MODEL";
        else if kind == .Sprite variant = "OLIB_INSTANCE_SPRITE";
        else if kind == .Sprite_Batch variant = "OLIB_SPRITE_BATCH";
        print_to_builder(*b, "\n#define %\n#include \"olib/instance.hlsli\"\n", variant);
        if kind != .Model print_to_builder(*b, "#include \"olib/sprite_vertex.hlsli\"\n");
    }
    swizzles: [4] string = .["x", "xy", "xyz", "xyzw"];
    index = 0;
    slot := 0;
    texture_slot := 0;
    for f: schema.fields {
        if f.kind == .Texture {
            print_to_builder(*b, "Texture2D _% : register(t%, space2);\n", f.name, texture_slot);
            print_to_builder(*b, "SamplerState _%Sampler : register(s%, space2);\n", f.name, texture_slot);
            texture_slot += 1;
        } else if f.instance {
            print_to_builder(*b, "#define _% (olib_instance.data%.%)\n", f.name, slot,
                             swizzles[components(f.kind) - 1]);
            slot += 1;
        } else {
            print_to_builder(*b, "#define _% (_olib_param_%.%)\n", f.name, index,
                             swizzles[components(f.kind) - 1]);
            index += 1;
        }
    }
    // odin 的 strings.to_string 直接把 Builder 转成字符串；jacket 的 builder_to_string 复制一份，
    // 之后必须 free_buffers 释放 Builder 自己的块（见 core/dasset 的同一写法）。
    text := builder_to_string(*b);
    free_buffers(*b);
    return text;
}
//@endregion
