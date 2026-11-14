// 一比一移植自 olib tests/kit/rendering/material/*.odin
// （std140_test / instance_fields_test / draw_test / material_library_test / builtin_test）。
//
// 断言顺序、数值与诊断文本与 olib 一一对应。Jai 侧的写法差异：
//   | olib (Odin, core:testing)                  | 这里 (Jai, Tests/test_support.jai)                     |
//   | ------------------------------------------ | ------------------------------------------------------ |
//   | testing.expect(t, cond)                    | expect(state, cond, "说明")                             |
//   | testing.expect_value(t, a, b)              | expect(state, a == b, "说明")                           |
//   | testing.expectf(t, cond, "%v", a)          | expect(state, cond, "% -> %", a, b)                     |
//   | 每个测试文件自己的 package                 | 单文件、单一 `*_test` 入口，过程名与 olib 测试名相同       |
//   | `foster.GraphicsDevice{…}` 当假设备         | `F.Graphics_Device` + `disposed = false`（jfoster 的零值  |
//   |                                            | 设备是“已销毁”，texture_is_disposed 会因此判 false）      |
//   | `Texture{Resource = 1}`                    | `*F.Texture` + `handle = 1`                             |
//   | `foster.Shader{GraphicsDevice = …}`        | `*F.Shader` + `handle = 1`、`Stage` 与 material_create 的  |
//   |                                            | 断言一致（jfoster 的 material_create 校验阶段，olib 不校验）|
//   | `foster.StorageContainer{ZipEntries = …}`  | 真实目录容器：F.Storage_Container.Root（jfoster 没有内存容器）|
//   | `make([]T, n, context.temp_allocator)`     | sh.shader_alloc_array（测试内部不回收，进程随即退出）        |
//   | `world.Matrix4{…} == m`                    | W.matrix4_equal（Jai 的数组/结构体不做 ==）               |
//   | `{1, -2, 0.5, 8}` 向量字面量                | `.[1.0, -2.0, 0.5, 8.0]`                                |
//   | `transmute(f32)u32(0x7fc00000)`            | `bits: u32 = …; value: float32 = xx bits;`              |
#import "Basic";
STRING :: #import "String";
FILE :: #import "File";
#import "test_support";
sh :: #import "kit/rendering/shader";
mat :: #import "kit/rendering/material";
F :: #import "foster";
W :: #import "kit/world";

//@region 工具

vec4_eq :: (a: [4] float32, b: [4] float32) -> bool {
    for i: 0..3 {
        if a[i] != b[i] return false;
    }
    return true;
}

float32_from_bits :: (bits: u32) -> float32 {
    // jacket 的 `xx` 是数值转换，不是位型重解释（官方 Jai 才是 bitcast），
    // 这里用 memcpy 做位拷贝。
    b := bits;
    value: float32;
    memcpy(*value, *b, 4);
    return value;
}

enum_name :: (value: $E) -> string {
    names := enum_names(E);
    numbers := enum_values_as_s64(E);
    for name, i: names {
        if numbers[i] == cast(s64) value return name;
    }
    return "";
}

// std140 的字节按小端读回一个 vec4（测试自己的解码，不借用被测算法的代码）。
std140_read_vec4 :: (buf: [] u8, offset: int) -> [4] float32 {
    v: [4] float32;
    for i: 0..3 {
        base := offset + i * 4;
        bits := (cast(u32) buf[base]) | ((cast(u32) buf[base + 1]) << 8) |
        ((cast(u32) buf[base + 2]) << 16) | ((cast(u32) buf[base + 3]) << 24);
        v[i] = float32_from_bits(bits);
    }
    return v;
}

// olib 的 instance_schema()：Body 组，两个 [Instance] 字段（hue / tint）、一张贴图、一个统一参数。
// olib 用 make(..., context.temp_allocator)；这里用 shader 包的分配器，测试结束不回收。
instance_schema :: () -> sh.Schema {
    fields := sh.shader_alloc_array(sh.Field, 4);
    fields[0] = sh.Field.{ id = "hue", name = "hue", kind = .Scalar, maximum = 1,
    initial = .[0.15, 0, 0, 0], instance = true };
    fields[1] = sh.Field.{ id = "image", name = "image", kind = .Texture };
    fields[2] = sh.Field.{ id = "strength", name = "strength", kind = .Scalar, maximum = 5,
    initial = .[2, 0, 0, 0] };
    fields[3] = sh.Field.{ id = "tint", name = "tint", kind = .Color, maximum = 1,
    initial = .[1, 1, 1, 1], instance = true };
    return sh.Schema.{ name = "Body", preview = "2d", fields = fields };
}

// 一个 1 字节的字节码（borrowed）。测试共用一个 64 字节小仓库，每个用例开头重置。
TEST_BYTES: [64] u8;
test_bytes_at: int;

reset_test_bytes :: () {
    test_bytes_at = 0;
}

byte_code :: (value: u8) -> [] u8 {
    at := test_bytes_at;
    test_bytes_at += 1;
    TEST_BYTES[at] = value;
    return array_view(TEST_BYTES, at, 1);
}

//@endregion

//@region std140（olib std140_test.odin）

std140_writes_little_endian_and_skips_out_of_range :: (state: *Test_State) {
    buf: [80] u8;
    full := array_view(buf, 0, 80);
    m := W.matrix4_translation(1, 2, 3);
    mat.std140_write_matrix(full, 0, m);
    mat.std140_write_vec4(full, 64, .[1.0, -2.0, 0.5, 8.0]);
    read_back := W.Matrix4.{ std140_read_vec4(full, 0), std140_read_vec4(full, 16),
    std140_read_vec4(full, 32), std140_read_vec4(full, 48) };
    expect(state, W.matrix4_equal(read_back, m), "矩阵按列写出后应与原值相同");
    expect(state, vec4_eq(std140_read_vec4(full, 64), .[1.0, -2.0, 0.5, 8.0]), "vec4 写在 offset 64");

    // 越界的 vec4 不写，矩阵只写放得下的列
    mat.std140_write_vec4(array_view(buf, 0, 8), 0, .[9.0, 9.0, 9.0, 9.0]);
    mat.std140_write_vec4(full, -16, .[9.0, 9.0, 9.0, 9.0]);
    expect(state, vec4_eq(std140_read_vec4(full, 0), m.c0), "越界写入不改变已有字节");
    mat.std140_write_matrix(array_view(buf, 0, 40), 0, W.MATRIX4_IDENTITY);
    expect(state, vec4_eq(std140_read_vec4(full, 0), W.MATRIX4_IDENTITY.c0) &&
    vec4_eq(std140_read_vec4(full, 32), m.c2),
    "40 字节的缓冲只写下放得下的前两列");
}

//@endregion

//@region 每实例值（olib instance_fields_test.odin）

instance_fields_leave_uniform_layout_and_define_olib_instance :: (state: *Test_State) {
    schema := instance_schema();
    // 只有 strength 占 uniform 槽；hue / tint 随顶点。
    expect(state, sh.uniform_size(schema) == 16, "统一参数只有 strength 一个槽");
    expect(state, sh.instance_count(schema) == 2, "两个 [Instance] 字段");
    values := sh.values_make(schema);
    defer sh.values_dispose(values);
    bytes: [16] u8;
    expect(state, sh.pack(schema, values, array_view(bytes, 0, 16)), "pack 应成功");
    packed: [4] float32;
    memcpy(*packed, *bytes, 16);
    expect(state, packed[0] == 2, "第一个槽是 strength 的初值");

    text := sh.hlsl(schema, .Sprite);
    defer {
        if text.data != null free(text.data);
    }
    expect(state, STRING.contains(text, "_olib_param_0;") && !STRING.contains(text, "_olib_param_1"),
    "只有一个 uniform 槽");
    // 精灵常驻缓冲：固定代码在 olib/instance.hlsli 与 olib/sprite_vertex.hlsli；生成器只给变体与槽位。
    // 每个槽位 X(槽位, 顶点输入语义号, 传给片元的语义号)：输入在 sprite0..3 + tint（TEXCOORD6..10）之后，
    // 片元在 tint（TEXCOORD8）之后。
    expect(state, STRING.contains(text, "#define OLIB_INSTANCE_SLOTS 2\n"), "槽数写在生成文本里");
    expect(state, STRING.contains(text, "#define OLIB_INSTANCE_DATA(X) X(0, 11, 9) X(1, 12, 10)\n"),
    "语义号与 olib 逐字相同");
    expect(state, STRING.contains(text, "#define OLIB_INSTANCE_SPRITE\n#include \"olib/instance.hlsli\"\n#include \"olib/sprite_vertex.hlsli\""),
    "精灵变体 include");
    expect(state, !STRING.contains(text, "OLIB_INSTANCE_MODEL"), "精灵不带模型变体");
    expect(state, STRING.contains(text, "#define _hue (olib_instance.data0.x)"), "hue 走实例数据");
    expect(state, STRING.contains(text, "#define _tint (olib_instance.data1.xyzw)"), "tint 走实例数据");
    expect(state, STRING.contains(text, "#define _strength (_olib_param_0.x)"), "strength 走参数块");
    expect(state, STRING.contains(text, "register(t0, space2)"), "贴图槽");
    expect(state, !STRING.contains(text, "%!"), "格式串里的花括号不能被吃掉");

    // 没有 instance 字段且 Shader 不是 instanced：不 include 实例代码，只有参数块。
    plain_fields := sh.shader_alloc_array(sh.Field, 1);
    plain_fields[0] = sh.Field.{ id = "a", name = "a", kind = .Scalar, maximum = 1 };
    plain := sh.Schema.{ name = "Plain", fields = plain_fields };
    plain_text := sh.hlsl(plain);
    defer {
        if plain_text.data != null free(plain_text.data);
    }
    expect(state, !STRING.contains(plain_text, "OLIB_INSTANCE") && !STRING.contains(plain_text, "#include"),
    "没有实例字段就不 include");
    // 仅 instanced（只用 tint）也 include，槽位为空。
    tint_only := sh.hlsl(plain, .Sprite);
    defer {
        if tint_only.data != null free(tint_only.data);
    }
    expect(state, STRING.contains(tint_only, "#define OLIB_INSTANCE_DATA(X)\n") &&
    STRING.contains(tint_only, "olib/instance.hlsli"), "空槽位也 include");
    // 批量变体：不声明实例顶点输入，只 include 精灵接口。
    batch := sh.hlsl(plain, .Sprite_Batch);
    defer {
        if batch.data != null free(batch.data);
    }
    expect(state, STRING.contains(batch, "#define OLIB_SPRITE_BATCH\n") &&
    STRING.contains(batch, "olib/sprite_vertex.hlsli"), "批量变体只 include 精灵接口");
}

instanced_shader_rules :: (state: *Test_State) {
    schemas := sh.shader_alloc_array(sh.Schema, 1);
    schemas[0] = instance_schema();
    schemas[0].fields = array_view(schemas[0].fields, 0, 3); // 去掉第二个 instance 字段，保留一个
    passes: [1] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Sprite, output = "color" };
    shader := sh.Shader_Desc.{ name = "E", output = "color", passes = array_view(passes, 0, 1) };
    // 有 instance 字段但 Shader 没声明 instanced。
    expect(state, STRING.contains(sh.shader_validate(shader, schemas), "Instanced shader"),
    "实例字段要求 instanced");
    shader.instanced = true;
    expect(state, sh.shader_validate(shader, schemas) == "", "声明 instanced 后合法");
    // instanced 支持 Sprite 和 Model；图像（全屏）Shader 不支持。
    model_passes: [1] sh.Pass_Desc;
    model_passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model, output = "color" };
    model_schemas := sh.shader_alloc_array(sh.Schema, 1);
    model_schemas[0] = instance_schema();
    model_schemas[0].preview = "3d";
    model_shader := sh.Shader_Desc.{ name = "E", output = "color", passes = array_view(model_passes, 0, 1), instanced = true };
    expect(state, sh.shader_validate(model_shader, model_schemas) == "", "Model 也支持 instanced");
    expect(state, sh.shader_instancing(model_shader) == sh.Instancing.Model, "模型实例化");
    expect(state, sh.shader_instancing(shader) == sh.Instancing.Sprite, "精灵实例化");
    expect(state, sh.shader_instancing(sh.Shader_Desc.{}) == sh.Instancing.None, "没有 instanced");
    graph_passes: [1] sh.Pass_Desc;
    graph_passes[0] = sh.Pass_Desc.{ id = "a", params = "Body", draw = .Fullscreen, output = "color" };
    graph := sh.Shader_Desc.{ name = "E", output = "color", instanced = true, passes = array_view(graph_passes, 0, 1) };
    expect(state, STRING.contains(sh.shader_validate(graph, schemas), "Sprite or Model passes"),
    "全屏 Shader 不能 instanced");
    // Texture 不能是 instance；数量有上限。
    bad_fields := sh.shader_alloc_array(sh.Field, 1);
    bad_fields[0] = sh.Field.{ id = "image", name = "image", kind = .Texture, instance = true };
    bad_schemas := sh.shader_alloc_array(sh.Schema, 1);
    bad_schemas[0] = sh.Schema.{ name = "Body", preview = "2d", fields = bad_fields };
    expect(state, STRING.contains(sh.shader_validate(shader, bad_schemas), "Texture cannot be Instance"),
    "贴图不能是实例字段");
    many := sh.shader_alloc_array(sh.Field, sh.MAX_INSTANCE_FIELDS + 1);
    for *f, i: many {
        name := tprint("f%", i);
        f.* = sh.Field.{ id = name, name = name, kind = .Scalar, maximum = 1, instance = true };
    }
    many_schemas := sh.shader_alloc_array(sh.Schema, 1);
    many_schemas[0] = sh.Schema.{ name = "Body", preview = "2d", fields = many };
    expect(state, STRING.contains(sh.shader_validate(shader, many_schemas), "more than 16 Instance fields"),
    "实例字段数有上限");
    // clone 保留 instanced。
    copy := sh.shader_clone(shader);
    defer sh.shader_dispose(*copy);
    expect(state, copy.instanced, "clone 保留 instanced");
}

// olib: slot_material —— 两个同名结构、不同组名的参数组。
// olib 从栈上返回 Material 值；这里借用一个静态槽位（同一个测试内只有一个使用者）。
slot_schemas: [2] sh.Schema;
SLOT_MATERIAL: mat.Material;

slot_material :: (shader: *mat.Material_Shader) -> *mat.Material {
    slot_schemas[0] = instance_schema();
    slot_schemas[1] = instance_schema();
    slot_schemas[1].name = "Other";
    shader.schemas = array_view(slot_schemas, 0, 2);
    SLOT_MATERIAL = mat.Material.{ shader = shader };
    return *SLOT_MATERIAL;
}

instance_slot_resolves_once_and_rejects_bad_names :: (state: *Test_State) {
    shader: mat.Material_Shader;
    material := slot_material(*shader);
    hue := mat.instance_slot(material, "hue");
    tint := mat.instance_slot(material, "tint");
    expect(state, hue.valid && hue.index == 0 && tint.valid && tint.index == 1, "槽位按声明顺序");
    expect(state, !mat.instance_slot(material, "strength").valid, "统一参数不是实例字段");
    expect(state, !mat.instance_slot(material, "image").valid, "贴图不是实例字段");
    expect(state, !mat.instance_slot(material, "nope").valid, "不存在的字段");
    expect(state, !mat.instance_slot(null, "hue").valid, "null 材质");
    empty: mat.Material;
    expect(state, !mat.instance_slot(*empty, "hue").valid, "没有 shader 的材质");
    // 不同参数组里槽位不一致时无法用同一个句柄。
    a := shader.schemas[1].fields[0];
    shader.schemas[1].fields[0] = shader.schemas[1].fields[3];
    shader.schemas[1].fields[3] = a;
    expect(state, !mat.instance_slot(material, "hue").valid, "各组槽位不一致时句柄无效");
}

instance_values_set_marks_slots_and_apply_overrides_only_those :: (state: *Test_State) {
    schema := instance_schema();
    values := sh.values_make(schema);
    defer sh.values_dispose(values);
    overrides: mat.Instance_Values;
    expect(state, mat.instance_values_set(*overrides, mat.Instance_Slot.{ 0, true }, 0.7), "设置槽位 0");
    expect(state, overrides.set == 0b1, "掩码记下槽位 0");
    expect(state, overrides.count == 1, "count 随最大槽位增长");
    expect(state, !mat.instance_values_set(*overrides, mat.Instance_Slot.{}, 1), "句柄无效");
    expect(state, !mat.instance_values_set(*overrides, mat.Instance_Slot.{ sh.MAX_INSTANCE_FIELDS, true }, 1), "越界");
    expect(state, !mat.instance_values_set(null, mat.Instance_Slot.{ 0, true }, 1), "null 覆盖值");
    mat.instance_values_apply(*overrides, schema, values);
    expect(state, values[0].number[0] == 0.7, "hue 被覆盖");
    expect(state, vec4_eq(values[3].number, .[1.0, 1.0, 1.0, 1.0]), "tint 没设置，沿用材质值");
    // 超出范围的值钳制到字段范围；非有限值忽略。
    mat.instance_values_set(*overrides, mat.Instance_Slot.{ 0, true }, 5);
    mat.instance_values_apply(*overrides, schema, values);
    expect(state, values[0].number[0] == 1, "超范围钳制到 maximum");
    mat.instance_values_set(*overrides, mat.Instance_Slot.{ 0, true }, float32_from_bits(0x7f800000)); // +inf
    mat.instance_values_apply(*overrides, schema, values);
    expect(state, values[0].number[0] == 1, "非有限值忽略，保留上一个值");
    // 没有显式设置任何槽位，或传 null：什么都不改。
    untouched := sh.values_make(schema);
    defer sh.values_dispose(untouched);
    mat.instance_values_apply(null, schema, untouched);
    empty_overrides: mat.Instance_Values;
    mat.instance_values_apply(*empty_overrides, schema, untouched);
    expect(state, untouched[0].number[0] == 0.15, "没有覆盖时保持材质值");
}

// 只写用到的分量，其余补 0；超过 4 个分量拒绝且不写入；平铺数组的一个实例转成整套覆盖值。
instance_values_take_only_needed_components :: (state: *Test_State) {
    overrides: mat.Instance_Values;
    expect(state, mat.instance_values_set(*overrides, mat.Instance_Slot.{ 1, true }, 0.1, 0.2, 0.3, 0.4), "写 4 个分量");
    expect(state, mat.instance_values_set(*overrides, mat.Instance_Slot.{ 1, true }, 0.5, 0.6), "写 2 个分量");
    expect(state, vec4_eq(overrides.numbers[1], .[0.5, 0.6, 0.0, 0.0]), "其余分量补 0");
    expect(state, !mat.instance_values_set(*overrides, mat.Instance_Slot.{ 1, true }, 1, 2, 3, 4, 5),
    "超过 4 个分量拒绝");
    expect(state, vec4_eq(overrides.numbers[1], .[0.5, 0.6, 0.0, 0.0]), "拒绝时不写入");

    flat: [2][4] float32 = .[.[0.2, 0, 0, 0], .[1.0, 2.0, 3.0, 0.0]];
    from := mat.instance_values_from(array_view(flat, 0, 2));
    expect(state, from.count == 2, "两个槽位");
    expect(state, from.set == 0b11, "全部算显式设置");
    expect(state, vec4_eq(from.numbers[1], .[1.0, 2.0, 3.0, 0.0]), "平铺数组按序拷入");
    empty: [][4] float32 = .[];
    expect(state, mat.instance_values_from(empty).set == 0, "空数组没有掩码位");
}

draw_collects_instance_values_in_field_order :: (state: *Test_State) {
    // 与 material_pass_submit 相同的规则：材质值 < Instance_Values < Pass 固定覆盖。
    schema := instance_schema();
    values := sh.values_make(schema);
    defer sh.values_dispose(values);
    overrides: mat.Instance_Values;
    mat.instance_values_set(*overrides, mat.Instance_Slot.{ 0, true }, 0.6);
    mat.instance_values_set(*overrides, mat.Instance_Slot.{ 1, true }, 0.1, 0.2, 0.3, 0.4);
    mat.instance_values_apply(*overrides, schema, values);
    fixed: [1] sh.Pass_Value;
    fixed[0] = sh.Pass_Value.{ field = "hue", number = .[0.9, 0, 0, 0] };
    values[sh.field_index(schema, fixed[0].field)].number = fixed[0].number;
    instance: mat.Instance_Values;
    for f, i: schema.fields {
        if !f.instance continue;
        instance.numbers[instance.count] = values[i].number;
        instance.count += 1;
    }
    expect(state, instance.count == 2, "两个实例槽");
    expect(state, instance.numbers[0][0] == 0.9, "Pass 固定值最后生效");
    expect(state, vec4_eq(instance.numbers[1], .[0.1, 0.2, 0.3, 0.4]), "第二个槽是 tint 的覆盖值");
    expect(state, values[2].number[0] == 2, "统一参数保持材质里的值");
}

model_instancing_hlsl_declares_input_world_and_varyings :: (state: *Test_State) {
    schema := instance_schema();
    schema.preview = "3d";
    text := sh.hlsl(schema, .Model);
    defer {
        if text.data != null free(text.data);
    }
    expect(state, !STRING.contains(text, "%!"), "没有格式化残留");
    // 模型实例：世界矩阵、olib_world 与 olib_instance_from 在 olib/instance.hlsli；语义号与精灵相同。
    expect(state, STRING.contains(text, "#define OLIB_INSTANCE_DATA(X) X(0, 11, 9) X(1, 12, 10)\n"),
    "模型与精灵的语义号相同");
    expect(state, STRING.contains(text, "#define OLIB_INSTANCE_MODEL\n#include \"olib/instance.hlsli\"\n"),
    "模型变体 include");
    expect(state, !STRING.contains(text, "sprite_vertex.hlsli"), "模型不 include 精灵接口");
    expect(state, STRING.contains(text, "#define _hue (olib_instance.data0.x)"), "hue 走实例数据");
    // 精灵没有世界矩阵输入。
    sprite := sh.hlsl(schema, .Sprite);
    defer {
        if sprite.data != null free(sprite.data);
    }
    expect(state, STRING.contains(sprite, "OLIB_INSTANCE_SPRITE") && !STRING.contains(sprite, "OLIB_INSTANCE_MODEL"),
    "精灵变体没有模型输入");
}

instance_slot_count_requires_consistent_groups :: (state: *Test_State) {
    fields := sh.shader_alloc_array(sh.Field, 3);
    fields[0] = sh.Field.{ id = "hue", instance = true };
    fields[1] = sh.Field.{ id = "tint" };
    fields[2] = sh.Field.{ id = "glow", instance = true };
    schemas := sh.shader_alloc_array(sh.Schema, 2);
    schemas[0] = sh.Schema.{ fields = fields };
    schemas[1] = sh.Schema.{ fields = fields };
    shader := mat.Material_Shader.{ schemas = schemas };
    material := mat.Material.{ shader = *shader };
    expect(state, mat.instance_slot_count(*material) == 2, "两个实例槽");
    shader.schemas[1].fields = array_view(fields, 0, 1);
    expect(state, mat.instance_slot_count(*material) == -1, "各组字段数不同时无法共用一个缓冲布局");
    expect(state, mat.instance_slot_count(null) == 0, "null 材质");
    expect(state, mat.instance_slot_count(*mat.Material.{}) == 0, "没有 shader 的材质");
}

//@endregion

//@region 绘制选择与登记（olib draw_test.odin）

// 这些用例都在提交任何 Draw 之前返回，不需要真实 GPU：设备/网格只当作非空指针。
model_passes: [2] sh.Pass_Desc;

model_shader :: () -> sh.Shader_Desc {
    model_passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model, output = "color" };
    model_passes[1] = sh.Pass_Desc.{ id = "outline", params = "Body", draw = .Model, output = "color", disabled = true };
    return sh.Shader_Desc.{ name = "E", output = "color", passes = array_view(model_passes, 0, 2) };
}

// 选择阶段：未知 ID、Pass 过多；绑定阶段：种类不符、缺绑定、绑定不完整。
material_select_reports_why_it_refused :: (state: *Test_State) {
    shader := model_shader();
    selection: mat.Pass_Selection;
    expect(state, mat.material_select(shader, .[], .Model, "ghost", null, *selection) == mat.Draw_Error.Unknown_Pass,
    "未知 Pass ID");
    crowded := shader;
    crowded_passes := sh.shader_alloc_array(sh.Pass_Desc, sh.MAX_PASSES + 1);
    for *p: crowded_passes {
        p.* = sh.Pass_Desc.{ id = "p", params = "Body", draw = .Model, output = "color" };
    }
    crowded.passes = crowded_passes;
    expect(state, mat.material_select(crowded, .[], .Model, "", null, *selection) == mat.Draw_Error.Too_Many_Passes,
    "超过 MAX_PASSES");
    expect(state, mat.material_select(shader, .[], .Sprite, "", null, *selection) == mat.Draw_Error.Wrong_Pass_Kind,
    "Pass 种类不符");
    expect(state, mat.material_select(shader, .[], .Model, "", null, *selection) == mat.Draw_Error.Missing_Binding,
    "没有绑定");
    broken_bindings: [1] mat.Material_Binding;
    broken_bindings[0] = mat.Material_Binding.{ schema = sh.Schema.{ name = "Body" } };
    expect(state, mat.material_select(shader, array_view(broken_bindings, 0, 1), .Model, "", null, *selection) ==
    mat.Draw_Error.Invalid_Binding, "绑定不完整");
    // outline 被声明禁用：按 ID 选中它成功，但不选出任何 Pass，也不需要绑定。
    expect(state, mat.material_select(shader, .[], .Model, "outline", null, *selection) == mat.Draw_Error.None,
    "禁用的 Pass 按 ID 选中不报错");
    expect(state, selection.count == 0, "禁用的 Pass 不选出");
}

// 视图块整块补零，超长拒绝且不改动；Model 比 Sprite 多出顶点 b1 / 片元 b2 两个槽。
view_globals_padding_and_slot_counts :: (state: *Test_State) {
    block: [mat.VIEW_GLOBALS_SIZE] u8;
    block[mat.VIEW_GLOBALS_SIZE - 1] = 9;
    globals: [3] u8 = .[1, 2, 3];
    expect(state, mat.view_globals_pack(*block, array_view(globals, 0, 3)), "短数据补零成功");
    expect(state, block[2] == 3 && block[3] == 0 && block[mat.VIEW_GLOBALS_SIZE - 1] == 0, "余下补零");
    too_long := sh.shader_alloc_array(u8, mat.VIEW_GLOBALS_SIZE + 16);
    expect(state, !mat.view_globals_pack(*block, too_long), "超长拒绝");
    expect(state, block[0] == 1, "失败不改 block");

    vertex, fragment := mat.material_uniform_counts(model_shader());
    expect(state, vertex == 2 && fragment == 3, "Model：顶点 2、片元 3");
    skinned := model_shader();
    skinned.skinned = true;
    vertex, fragment = mat.material_uniform_counts(skinned);
    expect(state, vertex == 4 && fragment == 3, "蒙皮 Model：顶点 4、片元 3");
    sprite_passes: [1] sh.Pass_Desc;
    sprite_passes[0] = sh.Pass_Desc.{ draw = .Sprite };
    sprite := sh.Shader_Desc.{ passes = array_view(sprite_passes, 0, 1) };
    vertex, fragment = mat.material_uniform_counts(sprite);
    expect(state, vertex == 2 && fragment == 2, "Sprite：顶点 2、片元 2");
    sprite.uniforms = .Foster;
    vertex, fragment = mat.material_uniform_counts(sprite);
    expect(state, vertex == 1 && fragment == 1, "Foster 布局只有 b0");
}

// 每种 ZTest 都映射到 jfoster 的比较；Off 关闭测试，Default 不改调用方状态。
pass_depth_maps_every_compare :: (state: *Test_State) {
    // olib 用 `[sh.Pass_Depth]DepthCompare` 表；Jai 不能按枚举值建数组，这里用同序的两个数组。
    depths: [10] sh.Pass_Depth = .[.Default, .Off, .Less, .Less_Equal, .Equal,
    .Always, .Greater, .Greater_Equal, .Not_Equal, .Never];
    expected: [10] F.Depth_Compare = .[.EQUAL, .EQUAL, .LESS, .LESS_OR_EQUAL, .EQUAL,
    .ALWAYS, .GREATER, .GREATER_OR_EQUAL, .NOT_EQUAL, .NEVER];
    for depth, i: depths {
        // 起始状态用 Equal、测试开启，便于看出 Default 不改、Off 只关测试。
        command: F.Draw_Command;
        command.DepthTestEnabled = true;
        command.DepthCompare = .EQUAL;
        mat.pass_state_apply(*command, sh.Pass_State.{ depth = depth });
        expect(state, command.DepthCompare == expected[i], "深度比较 % -> %", depth, command.DepthCompare);
        expect(state, command.DepthTestEnabled == (depth != .Off), "深度测试开关 %", depth);
    }
}

draw_error_text_covers_every_error :: (state: *Test_State) {
    expect(state, mat.draw_error_text(.None) == "", "None 没有文本");
    errors: [20] mat.Draw_Error = .[.Missing_Device, .Missing_Material, .Device_Mismatch, .Missing_Mesh,
    .Invalid_Target, .Not_Material_Shader, .Too_Many_Passes, .Unknown_Pass, .Wrong_Pass_Kind,
    .Missing_Binding, .Invalid_Binding, .Missing_Sprite_Texture, .Instance_Buffer_Required,
    .Not_Instanced_Shader, .Instance_Mismatch, .Unsupported_Mesh, .Missing_View_Matrix,
    .View_Globals_Too_Large, .Skin_Mismatch, .Invalid_Joint_Palette];
    for error: errors {
        expect(state, mat.draw_error_text(error) != "", "% 有可读说明", error);
    }
}

shader_pick_follows_driver :: (state: *Test_State) {
    binaries: mat.Shader_Binaries;
    binaries.spv = byte_code(1);
    binaries.dxil = byte_code(2);
    binaries.msl = byte_code(3);
    // 原生 Private 驱动需要平台私有格式，olib 不提供。
    expect(state, mat.shader_pick(.PRIVATE, binaries).count == 0, "Private 驱动没有字节码");
    expect(state, !mat.shader_driver_supported(.PRIVATE), "Private 驱动不支持");
    expect(state, mat.shader_pick(.VULKAN, binaries)[0] == 1, "Vulkan 选 spv");
    expect(state, mat.shader_pick(.D3D12, binaries)[0] == 2, "D3D12 选 dxil");
    expect(state, mat.shader_pick(.METAL, binaries)[0] == 3, "Metal 选 msl");
    missing: mat.Shader_Binaries;
    missing.spv = byte_code(1);
    missing.dxil = byte_code(2);
    expect(state, mat.shader_pick(.METAL, missing).count == 0, "缺格式返回空切片");
    expect(state, mat.shader_driver_supported(.METAL) && !mat.shader_driver_supported(.NONE), "驱动白名单");
}

material_register_manifest_selects_backend_and_validates :: (state: *Test_State) {
    reset_test_bytes();
    schemas := sh.shader_alloc_array(sh.Schema, 1);
    schemas[0] = sh.Schema.{ name = "Body", preview = "3d" };
    passes_desc: [1] sh.Pass_Desc;
    passes_desc[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model, output = "color" };
    shader := sh.Shader_Desc.{ name = "E", output = "color", passes = array_view(passes_desc, 0, 1) };
    manifest := manifest_json(shader, schemas, mat.MANIFEST_VERSION);
    // 旧约定生成的清单不能登记，否则旧字节码按新布局读数据会无声画错。
    outdated := manifest_json(shader, schemas, mat.MANIFEST_VERSION - 1);
    passes: [1] mat.Pass_Binaries;
    passes[0].vertex.spv = byte_code(1);
    passes[0].vertex.dxil = byte_code(2);
    passes[0].vertex.msl = byte_code(3);
    passes[0].fragment.spv = byte_code(4);
    passes[0].fragment.dxil = byte_code(5);
    passes[0].fragment.msl = byte_code(6);

    library: mat.Material_Library;
    expect(state, mat.material_register_manifest(*library, manifest_bytes(manifest),
    array_view(passes, 0, 1)) == "Missing graphics device", "没有设备");
    device: F.Graphics_Device;
    device.driver = .D3D12; // olib: foster.GraphicsDevice{Driver = .D3D12}
    library.device = *device;
    defer mat.material_library_dispose(*library);
    bogus: [1] u8 = .[120]; // 'x'：Jai 不支持字符字面量，直接写码位
    expect(state, mat.material_register_manifest(*library, array_view(bogus, 0, 1), array_view(passes, 0, 1)) ==
    "Invalid compiled shader manifest", "坏 JSON");
    expect(state, mat.material_register_manifest(*library, manifest_bytes(outdated), array_view(passes, 0, 1)) ==
    "Compiled shader manifest is outdated; re-run tools/shaders", "旧清单");
    expect(state, mat.material_register_manifest(*library, manifest_bytes(manifest), .[]) ==
    "Shader code count differs from schema count", "字节码数与参数组数不符");
    expect(state, mat.material_register_manifest(*library, manifest_bytes(manifest), array_view(passes, 0, 1)) == "",
    "D3D12 登记成功");
    expect(state, library.shaders.count == 1, "库里有 1 个 Shader");
    // D3D12 选 dxil：顶点 2、片元 5。
    expect(state, library.shaders[0].code[0].vertex[0] == 2 && library.shaders[0].code[0].fragment[0] == 5,
    "按驱动选 dxil");
    device.driver = .NONE;
    expect(state, mat.material_register_manifest(*library, manifest_bytes(manifest), array_view(passes, 0, 1)) ==
    "Unsupported shader backend", "未知驱动");
}

// 内存里的目录清单：Model Shader、instanced Sprite Shader、只供预览的 Fullscreen Shader 和无关文件。
material_register_directory_finds_compiled_files :: (state: *Test_State) {
    reset_test_bytes();
    hero_schemas := sh.shader_alloc_array(sh.Schema, 1);
    hero_schemas[0] = sh.Schema.{ name = "Hero_body", preview = "3d" };
    hero_passes: [1] sh.Pass_Desc;
    hero_passes[0] = sh.Pass_Desc.{ id = "body", params = "Hero_body", draw = .Model, output = "color" };
    hero := sh.Shader_Desc.{ name = "Hero", output = "color", passes = array_view(hero_passes, 0, 1) };

    spark_schemas := sh.shader_alloc_array(sh.Schema, 1);
    spark_schemas[0] = sh.Schema.{ name = "Spark_main", preview = "2d" };
    spark_passes: [1] sh.Pass_Desc;
    spark_passes[0] = sh.Pass_Desc.{ id = "main", params = "Spark_main", draw = .Sprite, output = "color" };
    spark := sh.Shader_Desc.{ name = "Spark", output = "color", instanced = true,
    passes = array_view(spark_passes, 0, 1) };

    trail_schemas := sh.shader_alloc_array(sh.Schema, 1);
    trail_schemas[0] = sh.Schema.{ name = "Trail_blur" };
    trail_passes: [1] sh.Pass_Desc;
    trail_passes[0] = sh.Pass_Desc.{ id = "blur", params = "Trail_blur", draw = .Fullscreen, output = "color" };
    trail := sh.Shader_Desc.{ name = "Trail", output = "color", passes = array_view(trail_passes, 0, 1) };

    files: [..] mat.Load_Directory_File;
    defer {
        if files.data != null array_free(files);
    };
    add_file(*files, "Hero.shader.json", manifest_bytes(manifest_json(hero, hero_schemas)));
    add_file(*files, "Hero_body.vertex.dxil", byte_code(1));
    add_file(*files, "Hero_body.vertex.spv", byte_code(11));
    add_file(*files, "Hero_body.fragment.dxil", byte_code(2));
    add_file(*files, "Hero_body.fragment.spv", byte_code(12));
    add_file(*files, "Spark.shader.json", manifest_bytes(manifest_json(spark, spark_schemas)));
    add_file(*files, "Spark_main.vertex.dxil", byte_code(3));
    add_file(*files, "Spark_main.fragment.dxil", byte_code(4));
    add_file(*files, "Spark_main.instanced.vertex.dxil", byte_code(5));
    add_file(*files, "Trail.shader.json", manifest_bytes(manifest_json(trail, trail_schemas)));
    add_file(*files, "notes.txt", byte_code(0));

    device: F.Graphics_Device;
    device.driver = .D3D12;
    library: mat.Material_Library;
    library.device = *device;
    defer mat.material_library_dispose(*library);
    expect(state, mat.material_register_directory(*library, files) == "", "D3D12 目录登记成功");
    // Trail 只供预览，跳过；D3D12 选 dxil，instanced 精灵带上缓冲变体顶点。
    expect(state, library.shaders.count == 2, "只登记 2 个材质 Shader");
    if library.shaders.count == 2 {
        body := library.shaders[0].code[0];
        expect(state, library.shaders[0].desc.name == "Hero" && body.vertex[0] == 1 && body.fragment[0] == 2,
        "Hero 用 dxil 字节码");
        main := library.shaders[1].code[0];
        expect(state, library.shaders[1].desc.name == "Spark" && main.vertex[0] == 3 && main.instanced_vertex[0] == 5,
        "Spark 带缓冲变体顶点");
    }

    // 换成 Vulkan 选 spv。
    vulkan_device: F.Graphics_Device;
    vulkan_device.driver = .VULKAN;
    vulkan: mat.Material_Library;
    vulkan.device = *vulkan_device;
    defer mat.material_library_dispose(*vulkan);
    expect(state, mat.material_register_directory(*vulkan, array_view(files, 0, 5)) == "", "Vulkan 目录登记成功");
    expect(state, vulkan.shaders.count == 1 && vulkan.shaders[0].code[0].vertex[0] == 11 &&
    vulkan.shaders[0].code[0].fragment[0] == 12, "Vulkan 选 spv");
}

material_register_directory_names_what_is_missing :: (state: *Test_State) {
    reset_test_bytes();
    hero_schemas := sh.shader_alloc_array(sh.Schema, 1);
    hero_schemas[0] = sh.Schema.{ name = "Hero_body", preview = "3d" };
    hero_passes: [1] sh.Pass_Desc;
    hero_passes[0] = sh.Pass_Desc.{ id = "body", params = "Hero_body", draw = .Model, output = "color" };
    hero := sh.Shader_Desc.{ name = "Hero", output = "color", passes = array_view(hero_passes, 0, 1) };
    spark_schemas := sh.shader_alloc_array(sh.Schema, 1);
    spark_schemas[0] = sh.Schema.{ name = "Spark_main", preview = "2d" };
    spark_passes: [1] sh.Pass_Desc;
    spark_passes[0] = sh.Pass_Desc.{ id = "main", params = "Spark_main", draw = .Sprite, output = "color" };
    spark := sh.Shader_Desc.{ name = "Spark", output = "color", instanced = true,
    passes = array_view(spark_passes, 0, 1) };
    hero_manifest := manifest_bytes(manifest_json(hero, hero_schemas));

    device: F.Graphics_Device;
    device.driver = .D3D12;
    library: mat.Material_Library;
    library.device = *device;
    defer mat.material_library_dispose(*library);

    no_fragment: [2] mat.Load_Directory_File;
    no_fragment[0] = mat.Load_Directory_File.{ name = "Hero.shader.json", data = hero_manifest };
    no_fragment[1] = mat.Load_Directory_File.{ name = "Hero_body.vertex.dxil", data = byte_code(1) };
    expect(state, mat.material_register_directory(*library, array_view(no_fragment, 0, 2)) ==
    "Hero_body.fragment.dxil: missing compiled shader; re-run tools/shaders", "缺片元字节码");
    // 只有别的后端格式也算缺失。
    other_backend: [3] mat.Load_Directory_File;
    other_backend[0] = mat.Load_Directory_File.{ name = "Hero.shader.json", data = hero_manifest };
    other_backend[1] = mat.Load_Directory_File.{ name = "Hero_body.vertex.spv", data = byte_code(1) };
    other_backend[2] = mat.Load_Directory_File.{ name = "Hero_body.fragment.spv", data = byte_code(2) };
    expect(state, mat.material_register_directory(*library, array_view(other_backend, 0, 3)) ==
    "Hero_body.vertex.dxil: missing compiled shader; re-run tools/shaders", "别的后端也算缺失");
    no_instanced: [3] mat.Load_Directory_File;
    no_instanced[0] = mat.Load_Directory_File.{ name = "Spark.shader.json",
    data = manifest_bytes(manifest_json(spark, spark_schemas)) };
    no_instanced[1] = mat.Load_Directory_File.{ name = "Spark_main.vertex.dxil", data = byte_code(3) };
    no_instanced[2] = mat.Load_Directory_File.{ name = "Spark_main.fragment.dxil", data = byte_code(4) };
    expect(state, mat.material_register_directory(*library, array_view(no_instanced, 0, 3)) ==
    "Spark_main.instanced.vertex.dxil: missing compiled shader; re-run tools/shaders",
    "缺缓冲变体顶点");
    outdated: [1] mat.Load_Directory_File;
    outdated[0] = mat.Load_Directory_File.{ name = "Hero.shader.json",
    data = manifest_bytes(manifest_json(hero, hero_schemas,
    mat.MANIFEST_VERSION - 1)) };
    expect(state, mat.material_register_directory(*library, array_view(outdated, 0, 1)) ==
    "Hero.shader.json: Compiled shader manifest is outdated; re-run tools/shaders", "旧清单带文件名");
    only_bytecode: [1] mat.Load_Directory_File;
    only_bytecode[0] = mat.Load_Directory_File.{ name = "Hero_body.vertex.dxil", data = byte_code(1) };
    expect(state, mat.material_register_directory(*library, array_view(only_bytecode, 0, 1)) ==
    "No compiled shader manifest (*.shader.json) in directory", "没有清单");
    expect(state, library.shaders.count == 0, "失败不留下 Shader");

    // 设备与后端检查与 material_register_manifest 的文本一致。
    empty: mat.Material_Library;
    expect(state, mat.material_register_directory(*empty, array_view(no_fragment, 0, 2)) == "Missing graphics device",
    "没有设备");
    device.driver = .NONE;
    expect(state, mat.material_register_directory(*library, array_view(no_fragment, 0, 2)) ==
    "Unsupported shader backend", "未知驱动");
}

// 实例值表与 material_pass_values（逐字段按名字套用的原路径）结果逐值相同：各种字段类型与范围、
// Pass 固定值（含同一字段多次，取最后一次）、部分与全部覆盖、用到的分量非有限、未用到的分量非有限、
// 超出槽数的掩码位。
instance_table_matches_pass_values :: (state: *Test_State) {
    nan := float32_from_bits(0x7fc00000);
    inf := float32_from_bits(0x7f800000);
    fields := sh.shader_alloc_array(sh.Field, 5);
    fields[0] = sh.Field.{ id = "a", kind = .Scalar, instance = true, minimum = 0, maximum = 1 };
    fields[1] = sh.Field.{ id = "gain", kind = .Scalar, maximum = 1 };
    fields[2] = sh.Field.{ id = "b", kind = .Vector2, instance = true, minimum = -2, maximum = 2 };
    fields[3] = sh.Field.{ id = "c", kind = .Color, instance = true, minimum = 0, maximum = 1 };
    fields[4] = sh.Field.{ id = "d", kind = .Vector3, instance = true, minimum = -1, maximum = 5 };
    values := sh.shader_alloc_array(sh.Value, 5);
    values[0] = sh.Value.{ number = .[0.3, 9, 9, 9] };
    values[1] = sh.Value.{ number = .[0.5, 0, 0, 0] };
    values[2] = sh.Value.{ number = .[1.0, -1.0, 7.0, 7.0] };
    values[3] = sh.Value.{ number = .[0.1, 0.2, 0.3, 0.4] };
    values[4] = sh.Value.{ number = .[1.0, 2.0, 3.0, 4.0] };
    binding := mat.Material_Binding.{ schema = sh.Schema.{ name = "S", fields = fields }, values = values };
    pass_list := sh.shader_alloc_array(sh.Pass_Desc, 3);
    fixed_b: [1] sh.Pass_Value;
    fixed_b[0] = sh.Pass_Value.{ field = "b", number = .[0.5, 0.5, 0, 0] };
    fixed_a: [3] sh.Pass_Value;
    fixed_a[0] = sh.Pass_Value.{ field = "a", number = .[0.9, 0, 0, 0] };
    fixed_a[1] = sh.Pass_Value.{ field = "a", number = .[0.7, 0, 0, 0] };
    fixed_a[2] = sh.Pass_Value.{ field = "gain", number = .[1.0, 0, 0, 0] };
    pass_list[1].values = array_view(fixed_b, 0, 1);
    pass_list[2].values = array_view(fixed_a, 0, 3);
    overrides: [6] mat.Instance_Values;
    overrides[1].numbers[0] = .[2.0, 0, 0, 0];
    overrides[1].set = 0b0001; // 钳制
    overrides[2].numbers[0] = .[-1.0, 0, 0, 0];
    overrides[2].numbers[1] = .[3.0, -3.0, 0, 0];
    overrides[2].numbers[2] = .[0.5, 1.5, -0.5, 2.0];
    overrides[2].numbers[3] = .[6.0, 0, -2.0, 9.0];
    overrides[2].set = 0b1111;
    overrides[3].numbers[1] = .[nan, 0, 0, 0];
    overrides[3].numbers[2] = .[0.2, 0.3, 0.4, inf]; // 整个值忽略
    overrides[3].set = 0b0110;
    overrides[4].numbers[1] = .[1.0, 1.0, inf, 0];
    overrides[4].set = 0b0010; // Vector2 不用第三个分量：照常套用
    overrides[5].numbers[3] = .[4.0, 4.0, 4.0, 0];
    overrides[5].set = 0b1000 | (cast(u32) 1 << 10); // 超出槽数的位忽略
    for pass_index: 0..2 {
        p := pass_list[pass_index];
        table := mat.instance_table_make(p, binding);
        expect(state, table.count == 4, "4 个实例槽");
        for o, case_index: overrides {
            override: *mat.Instance_Values = *o;
            if case_index == 0 override = null;
            expected_uniform, expected := mat.material_pass_values(p, binding, override);
            got := mat.material_pass_instance(p, binding, override);
            expect(state, got.count == expected.count, "pass % case % 槽数相同", pass_index, case_index);
            for slot: 0..expected.count - 1 {
                expect(state, vec4_eq(got.numbers[slot], expected.numbers[slot]),
                "pass % case % slot %: % != %", pass_index, case_index, slot,
                got.numbers[slot], expected.numbers[slot]);
            }
            // 平铺数组的写法（每个槽位都算覆盖）与带全掩码的 Instance_Values 相同。
            if case_index == 2 {
                out: [4][4] float32;
                mat.instance_table_write(*table, array_view(o.numbers, 0, 4), 0b1111, array_view(out, 0, 4));
                for slot: 0..3 {
                    expect(state, vec4_eq(out[slot], expected.numbers[slot]), "平铺写法与掩码写法一致");
                }
            }
        }
    }
}

//@endregion

//@region 材质库与材质（olib material_library_test.odin）

// Pass 选择在提交前完成；不存在的 ID 不能退回“全部”。
material_pass_selection_preserves_order_and_disabled_flags :: (state: *Test_State) {
    passes: [3] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ id = "shadow" };
    passes[1] = sh.Pass_Desc.{ id = "body" };
    passes[2] = sh.Pass_Desc.{ id = "outline", disabled = true };
    shader := sh.Shader_Desc.{ passes = array_view(passes, 0, 3) };
    indices: [sh.MAX_PASSES] int;
    count, error := mat.material_pass_indices(shader, "", *indices);
    expect(state, error == .None && count == 2 && indices[0] == 0 && indices[1] == 1, "按声明顺序、跳过禁用");
    count, error = mat.material_pass_indices(shader, "body", *indices);
    expect(state, error == .None && count == 1 && indices[0] == 1, "按 ID 选一个");
    count, error = mat.material_pass_indices(shader, "missing", *indices);
    expect(state, error == .Unknown_Pass && count == 0, "未知 ID 报错");
    // 声明为 disabled 的 Pass 按 ID 选中也不画。
    count, error = mat.material_pass_indices(shader, "outline", *indices);
    expect(state, error == .None && count == 0, "禁用的 Pass 不画");
}

// 用真实 StorageContainer 目录验证文件 -> Shader 解析，不创建窗口或伪造 GPU。
// jfoster 只有文件系统容器（没有 ZipEntries 内存容器），所以这里把材质文件写到
// .test_tmp/material_test_storage/ 下。
material_library_resolves_shader_and_preserves_failed_reload :: (state: *Test_State) {
    root := ".test_tmp/material_test_storage";
    materials_dir := ".test_tmp/material_test_storage/materials";
    FILE.make_directory_if_it_does_not_exist(root, true);
    FILE.make_directory_if_it_does_not_exist(materials_dir, true);
    json := "{\"version\":2,\"effect\":\"Outlined\",\"groups\":[{\"version\":1,\"group\":\"Body\",\"fields\":[{\"id\":\"amount\",\"kind\":\"Scalar\",\"number\":[0.7,0,0,0]}]}]}";
    left := ".test_tmp/material_test_storage/materials/left.json";
    expect(state, FILE.write_entire_file(left, json), "写出材质文件");
    storage: F.Storage_Container;
    storage.Root = root;
    storage.Writable = true;
    library: mat.Material_Library;
    library.storage = *storage;
    defer mat.material_library_dispose(*library);

    schemas := sh.shader_alloc_array(sh.Schema, 2);
    schemas[0] = sh.Schema.{ name = "Outline", preview = "3d" };
    fields := sh.shader_alloc_array(sh.Field, 1);
    fields[0] = sh.Field.{ id = "amount", kind = .Scalar, maximum = 1 };
    schemas[1] = sh.Schema.{ name = "Body", preview = "3d", fields = fields };
    passes: [2] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model, output = "color" };
    passes[1] = sh.Pass_Desc.{ id = "outline", params = "Outline", draw = .Model, output = "color" };
    shader := sh.Shader_Desc.{ name = "Outlined", output = "color", passes = array_view(passes, 0, 2) };
    code := sh.shader_alloc_array(mat.Material_Program_Code, 2);
    code[0].vertex = byte_code(1);
    code[0].fragment = byte_code(2);
    code[1].vertex = byte_code(3);
    code[1].fragment = byte_code(4);
    expect(state, mat.material_register(*library, shader, schemas, code) == "", "登记 Shader");
    expect(state, mat.material_register(*library, shader, schemas, code) != "", "重复登记被拒绝");
    expect(state, library.shaders.count == 1, "只登记一次");
    a, selected, reason := mat.material_read(*library, "materials/left.json");
    defer sh.instance_dispose(*a);
    b, _, second_error := mat.material_read(*library, "materials/left.json");
    defer sh.instance_dispose(*b);
    expect(state, reason == "" && second_error == "" && selected == library.shaders[0], "解析到所属 Shader");
    expect(state, a.groups[0].schema.name == "Body", "第一个参数组是 Body");
    expect(state, a.groups[0].values[0].number[0] == 0.7, "读到文件里的数值");
    // 借用实例只用于无 GPU 的参数/失败测试，清理由 a 的所有者完成。
    material := mat.Material.{ owner = *library, shader = selected, instance = a };
    expect(state, mat.material_set_number(*material, "Body", "amount", .[0.2, 0, 0, 0]), "改数值成功");
    expect(state, material.revision == 1, "成功修改才递增");
    expect(state, b.groups[0].values[0].number[0] == 0.7, "另一份实例不受影响");
    expect(state, !mat.material_set_number(*material, "Body", "amount", .[2.0, 0, 0, 0]), "超范围拒绝");
    expect(state, !mat.material_set_number(*material, "Body", "missing", .[0.0, 0, 0, 0]), "未知字段拒绝");
    expect(state, mat.material_reload(*library, *material, "missing.json") != "", "读不到文件报错");
    expect(state, material.instance.groups[0].values[0].number[0] == 0.2, "失败的重载不改数值");
    // 无 device，不发布半份 GPU 资源。
    expect(state, mat.material_reload(*library, *material, "materials/left.json") != "", "没有设备时重载失败");
    expect(state, material.instance.groups[0].values[0].number[0] == 0.2, "失败的重载不改数值（第二次）");
    expect(state, material.revision == 1, "失败不递增 revision");
    failed, load_error := mat.material_load(*library, "materials/left.json");
    expect(state, failed == null && load_error != "" && library.instances.count == 0, "load 失败不入库");
    name := selected.desc.name;
    selected.desc.name = "Different";
    missing, _, unknown_error := mat.material_read(*library, "materials/left.json");
    selected.desc.name = name;
    expect(state, unknown_error != "" && missing.groups.data == null, "未知 Shader 报错");
    sh.instance_dispose(*missing);
}

// 运行时贴图（阴影图等）绑到 Texture 字段：采样器取字段声明，非贴图字段、外设备贴图拒绝，null 恢复白图。
material_set_texture_binds_runtime_texture_with_field_sampler :: (state: *Test_State) {
    device: F.Graphics_Device;
    device.disposed = false; // jfoster 的零值设备是“已销毁”，假设备要显式标成存活
    other: F.Graphics_Device;
    other.disposed = false;
    library: mat.Material_Library;
    library.device = *device;
    white := New(F.Texture);
    white.device = *device;
    white.handle = 1;
    library.white = white;
    fields := sh.shader_alloc_array(sh.Field, 3);
    fields[0] = sh.Field.{ id = "albedo", kind = .Texture };
    fields[1] = sh.Field.{ id = "amount", kind = .Scalar, maximum = 1 };
    fields[2] = sh.Field.{ id = "shadow", kind = .Texture, filter = .Nearest, wrap = .Repeat };
    schema := sh.Schema.{ name = "Body", fields = fields };
    samplers := sh.shader_alloc_array([sh.MAX_TEXTURES] F.Bound_Sampler, 1);
    groups := sh.shader_alloc_array(sh.Instance_Group, 1);
    groups[0] = sh.Instance_Group.{ schema = schema };
    material := mat.Material.{ owner = *library, samplers = samplers };
    material.instance.groups = groups;
    shadow := New(F.Texture);
    shadow.device = *device;
    shadow.handle = 1;
    expect(state, mat.material_set_texture(*material, "Body", "shadow", shadow), "绑定运行时贴图");
    expect(state, samplers[0][1].Tex == shadow, "采样器指向传入的贴图");
    expect(state, samplers[0][1].Sampler == F.texture_sampler_make(.NEAREST, .REPEAT), "采样方式取字段声明");
    expect(state, material.revision == 1, "成功绑定才递增");
    expect(state, !mat.material_set_texture(*material, "Body", "amount", shadow), "非贴图字段拒绝");
    expect(state, !mat.material_set_texture(*material, "Other", "shadow", shadow), "未知参数组拒绝");
    alien := New(F.Texture);
    alien.device = *other;
    alien.handle = 1;
    expect(state, !mat.material_set_texture(*material, "Body", "albedo", alien), "外设备贴图拒绝");
    // 多采样深度附件没有解析纹理，不能采样；拒绝而不是交给 SDL 报错。
    msaa_depth := New(F.Texture);
    msaa_depth.device = *device;
    msaa_depth.handle = 1;
    msaa_depth.Format = .DEPTH32;
    msaa_depth.SampleCount = .FOUR;
    msaa_depth.IsTargetAttachment = true;
    expect(state, !mat.material_set_texture(*material, "Body", "shadow", msaa_depth),
    "多采样深度附件拒绝");
    expect(state, material.revision == 1, "拒绝时不递增");
    expect(state, mat.material_set_texture(*material, "Body", "albedo", null), "null 恢复白图");
    expect(state, samplers[0][0].Tex == library.white, "采样器指向库里的白图");
    expect(state, samplers[0][0].Sampler == F.texture_sampler_make(.LINEAR, .CLAMP), "字段零值即默认采样");
    mirror := sh.Field.{ wrap = .Mirror };
    expect(state, sh.field_sampler(mirror) == F.texture_sampler_make(.LINEAR, .MIRRORED_REPEAT), "Mirror 映射");
    mat.material_texture_release(white);
    mat.material_texture_release(shadow);
    mat.material_texture_release(alien);
    mat.material_texture_release(msaa_depth);
    if samplers.data != null array_free(samplers);
    if groups.data != null array_free(groups);
}

material_texture_paths_are_relative_and_canonical :: (state: *Test_State) {
    resolved, reason := mat.material_path("materials/characters/hero.json", "..\\..\\textures/./cloth.png");
    expect(state, reason == "" && resolved == "textures/cloth.png", "反斜杠与 ./ ../ 都折叠: %", resolved);
    other, other_error := mat.material_path("materials/hero.json", "../textures/cloth.png");
    expect(state, other_error == "" && other == resolved, "两条路径归一到同一份纹理");
    invalid: [3] string;
    invalid[0] = "";
    invalid[1] = "/absolute.png";
    invalid[2] = "C:\\absolute.png";
    for path: invalid {
        _, error := mat.material_path("materials/hero.json", path);
        expect(state, error != "", "拒绝绝对路径");
    }
}

// 借用调用方的 GPU 绑定组成 Material：拒绝非材质 Shader、绑定数或顺序不符、缺 Shader、别的设备；
// 成功时能被 material_select 选中。
material_from_bindings_borrows_tool_bindings :: (state: *Test_State) {
    device: F.Graphics_Device;
    device.disposed = false;
    other_device: F.Graphics_Device;
    other_device.disposed = false;
    library: mat.Material_Library;
    library.device = *device;
    white := New(F.Texture);
    white.device = *device;
    white.handle = 1; // 仅验证组装；不调用 GPU
    library.white = white;
    program := New(F.Shader);
    program.device = *device;
    program.handle = 1;
    program.Stage = .VERTEX;
    fragment_program := New(F.Shader);
    fragment_program.device = *device;
    fragment_program.handle = 1;
    fragment_program.Stage = .FRAGMENT;
    alien := New(F.Shader);
    alien.device = *other_device;
    alien.handle = 1;
    alien.Stage = .VERTEX;
    gpu := F.material_create(program, fragment_program);
    schemas := sh.shader_alloc_array(sh.Schema, 1);
    schemas[0] = sh.Schema.{ name = "Body", preview = "3d" };
    tool_shader := mat.Material_Shader.{ desc = model_shader(), schemas = schemas };
    bindings: [1] mat.Material_Binding;
    bindings[0] = mat.Material_Binding.{ schema = schemas[0], material = gpu };

    material, reason := mat.material_from_bindings(*library, *tool_shader, array_view(bindings, 0, 1));
    expect(state, reason == "", "组装成功");
    expect(state, material.owner == *library && material.shader == *tool_shader && material.bindings.count == 1,
    "材质借用调用方的 shader 与绑定");
    selection: mat.Pass_Selection;
    expect(state, mat.material_select(material.shader.desc, material.bindings, .Model, "", null, *selection) ==
    mat.Draw_Error.None, "能被 material_select 选中");
    expect(state, selection.count == 1, "outline 声明为禁用");

    empty_library: mat.Material_Library;
    _, missing_device := mat.material_from_bindings(*empty_library, *tool_shader, array_view(bindings, 0, 1));
    expect(state, missing_device == "Missing graphics device", "没有设备");
    fullscreen_passes: [1] sh.Pass_Desc;
    fullscreen_passes[0] = sh.Pass_Desc.{ id = "main", params = "Body", output = "color" };
    fullscreen := mat.Material_Shader.{ desc = sh.Shader_Desc.{ name = "F", output = "color",
    passes = array_view(fullscreen_passes, 0, 1) }, schemas = schemas };
    _, not_material := mat.material_from_bindings(*library, *fullscreen, array_view(bindings, 0, 1));
    expect(state, not_material == "Expected Model or Sprite material shader", "不是材质 Shader");
    _, count_error := mat.material_from_bindings(*library, *tool_shader, .[]);
    expect(state, count_error == "Binding count differs from schema count", "绑定数不符");
    wrong_order: [1] mat.Material_Binding;
    wrong_order[0] = mat.Material_Binding.{ schema = sh.Schema.{ name = "Other" }, material = gpu };
    _, order_error := mat.material_from_bindings(*library, *tool_shader, array_view(wrong_order, 0, 1));
    expect(state, order_error == "Bindings must follow the shader's schema order", "绑定顺序不符");
    no_shader := F.material_create();
    empty_bindings: [1] mat.Material_Binding;
    empty_bindings[0] = mat.Material_Binding.{ schema = schemas[0], material = no_shader };
    _, missing_shader := mat.material_from_bindings(*library, *tool_shader, array_view(empty_bindings, 0, 1));
    expect(state, missing_shader == "Missing compiled shader", "缺 Shader");
    elsewhere := F.material_create(alien, fragment_program);
    alien_bindings: [1] mat.Material_Binding;
    alien_bindings[0] = mat.Material_Binding.{ schema = schemas[0], material = elsewhere };
    _, other_error := mat.material_from_bindings(*library, *tool_shader, array_view(alien_bindings, 0, 1));
    expect(state, other_error == "Shader belongs to another graphics device", "别的设备");
}

//@endregion

//@region 内置 2D Shader（olib builtin_test.odin）

// 内置 Shader 借用设备的默认 Shader：没有 GPU 时用带假默认 Material 的设备检查登记逻辑。
builtin_shaders_register_once_with_foster_uniforms :: (state: *Test_State) {
    library: mat.Material_Library;
    defer mat.material_library_dispose(*library);
    expect(state, mat.builtin_register(*library, mat.BUILTIN_SPRITE) == "Missing graphics device", "没有设备");

    device: F.Graphics_Device;
    library.device = *device;
    expect(state, mat.builtin_register(*library, mat.BUILTIN_SPRITE) ==
    "Graphics device defaults are not initialized", "默认资源未初始化");

    // jfoster 的默认资源是整份默认 Material（batch / msdf）；这里直接放假的 Shader，不碰 GPU。
    defaults := F.defaults_get(*device);
    batch_vs := New(F.Shader);
    batch_vs.Stage = .VERTEX;
    batch_vs.handle = 1;
    batch_fs := New(F.Shader);
    batch_fs.Stage = .FRAGMENT;
    batch_fs.handle = 1;
    defaults.batch_material = F.material_create(batch_vs, batch_fs);
    msdf_vs := New(F.Shader);
    msdf_vs.Stage = .VERTEX;
    msdf_vs.handle = 1;
    msdf_fs := New(F.Shader);
    msdf_fs.Stage = .FRAGMENT;
    msdf_fs.handle = 1;
    defaults.msdf_material = F.material_create(msdf_vs, msdf_fs);

    expect(state, mat.builtin_register(*library, mat.BUILTIN_SPRITE) == "", "登记内置精灵");
    expect(state, mat.builtin_register(*library, mat.BUILTIN_SPRITE) == "", "幂等");
    expect(state, mat.builtin_register(*library, mat.BUILTIN_TEXT) == "", "登记内置文字");
    expect(state, library.shaders.count == 2, "两个内置 Shader");

    sprite := library.shaders[0];
    text := library.shaders[1];
    expect(state, sprite.ready && sh.shader_is_sprite(sprite.desc), "精灵 Shader 已就绪");
    expect(state, sprite.desc.uniforms == sh.Uniform_Layout.Foster, "内置 Shader 用 Foster 布局");
    expect(state, sprite.gpu[0].Fragment.shader == batch_fs, "片元程序借用设备默认 Shader");
    expect(state, sprite.vertex.data == null && sprite.fragment.data == null, "Shader 归设备所有，库不释放");
    expect(state, text.gpu[0].Fragment.shader == msdf_fs, "文字用 MSDF 默认程序");
    expect(state, sh.field_index(text.schemas[0], "distance_range") == 1, "distance_range 是第二个字段");
    expect(state, text.desc.passes[0].sprite_texture == "texture", "Pass 用 texture 字段作精灵贴图");

    F.material_destroy(defaults.batch_material);
    F.material_destroy(defaults.msdf_material);
    defaults.batch_material = null;
    defaults.msdf_material = null;
    free(defaults);
    device.defaults = null;
    mat.material_shader_release(batch_vs);
    mat.material_shader_release(batch_fs);
    mat.material_shader_release(msdf_vs);
    mat.material_shader_release(msdf_fs);
}

material_create_reports_unknown_shaders :: (state: *Test_State) {
    material, reason := mat.material_create(null, mat.BUILTIN_SPRITE);
    expect(state, material == null && reason == "Missing material library", "没有库");
    library: mat.Material_Library;
    defer mat.material_library_dispose(*library);
    material, reason = mat.material_create(*library, "Nope");
    expect(state, material == null && reason == "Unknown material shader: Nope", "未知 Shader 名字");
    material, reason = mat.material_create(*library, mat.BUILTIN_TEXT);
    expect(state, material == null && reason == "Missing graphics device", "内置 Shader 需要设备");
    expect(state, library.instances.count == 0, "失败不入库");
}

// Web 构建登记 Shader 时的限制（material_register 只在 OS == .WASM 时调用它）。
web_check_rejects_unsupported_shaders :: (state: *Test_State) {
    fields := sh.shader_alloc_array(sh.Field, 1);
    fields[0] = sh.Field.{ kind = .Scalar, instance = true };
    schemas := sh.shader_alloc_array(sh.Schema, 1);
    schemas[0] = sh.Schema.{ fields = fields };
    expect(state, mat.material_web_check(sh.Shader_Desc.{}, schemas) ==
    "Web does not support Instance storage buffers", "实例字段");
    expect(state, mat.material_web_check(sh.Shader_Desc.{ instanced = true }, .[]) ==
    "Web does not support instanced materials", "instanced");
    expect(state, mat.material_web_check(sh.Shader_Desc.{}, .[]) ==
    "Web requires Foster uniform layout; Olib Clock and parameter blocks are unsupported", "uniform 布局");
    expect(state, mat.material_web_check(sh.Shader_Desc.{ uniforms = .Foster }, .[]) == "", "Foster 布局可用");
}

//@endregion

//@region 清单 JSON 生成（测试用；形状与 tools/shaders + odin 的 json.marshal 相同）

manifest_json :: (shader: sh.Shader_Desc, schemas: [] sh.Schema, version := mat.MANIFEST_VERSION) -> string {
    b: String_Builder;
    print_to_builder(*b, "{\n    \"version\": %,\n    \"schemas\": [", version);
    for schema, i: schemas {
        if i > 0 print_to_builder(*b, ",");
        print_to_builder(*b, "\n        {\"name\": \"%\", \"shader\": \"%\", \"preview\": \"%\", \"label\": \"%\", \"folder\": \"%\", \"fields\": [",
        schema.name, schema.shader, schema.preview, schema.label, schema.folder);
        for f, j: schema.fields {
            if j > 0 print_to_builder(*b, ",");
            print_to_builder(*b, "{\"id\": \"%\", \"name\": \"%\", \"label\": \"%\", \"kind\": \"%\", \"minimum\": %, \"maximum\": %, \"step\": %, \"initial\": [%, %, %, %], \"texture\": \"%\", \"instance\": %, \"filter\": \"%\", \"wrap\": \"%\", \"filter_declared\": %, \"wrap_declared\": %}",
            f.id, f.name, f.label, sh.shader_kind_name(f.kind), f.minimum, f.maximum, f.step,
            f.initial[0], f.initial[1], f.initial[2], f.initial[3], f.texture,
            bool_text(f.instance), enum_name(f.filter), enum_name(f.wrap),
            bool_text(f.filter_declared), bool_text(f.wrap_declared));
        }
        print_to_builder(*b, "]}");
    }
    print_to_builder(*b, "\n    ],\n    \"effect\": {\"name\": \"%\", \"output\": \"%\", \"label\": \"%\", \"preview\": \"%\", \"instanced\": %, \"skinned\": %, \"uniforms\": \"%\", \"passes\": [",
    shader.name, shader.output, shader.label, shader.preview, bool_text(shader.instanced),
    bool_text(shader.skinned), enum_name(shader.uniforms));
    for p, i: shader.passes {
        if i > 0 print_to_builder(*b, ",");
        print_to_builder(*b, "{\"id\": \"%\", \"params\": \"%\", \"output\": \"%\", \"label\": \"%\", \"disabled\": %, \"draw\": \"%\", \"sprite_texture\": \"%\", \"inputs\": [], \"values\": [], \"target\": {\"width\": %, \"height\": %, \"scale\": %, \"format\": \"%\", \"depth\": %, \"samples\": %, \"clear\": [%, %, %, %]}, \"state\": {\"cull\": \"%\", \"blend\": \"%\", \"depth\": \"%\", \"depth_write\": \"%\"}}",
        p.id, p.params, p.output, p.label, bool_text(p.disabled), enum_name(p.draw),
        p.sprite_texture, p.target.width, p.target.height, p.target.scale,
        enum_name(p.target.format), bool_text(p.target.depth), p.target.samples,
        p.target.clear[0], p.target.clear[1], p.target.clear[2], p.target.clear[3],
        enum_name(p.state.cull), enum_name(p.state.blend), enum_name(p.state.depth),
        enum_name(p.state.depth_write));
    }
    print_to_builder(*b, "]}\n}");
    text := builder_to_string(*b);
    free_buffers(*b);
    return text;
}

bool_text :: (value: bool) -> string {
    return ifx value then "true" else "false";
}

// JSON 文本借给解析器用一次；测试不回收（进程随即退出）。
manifest_bytes :: (text: string) -> [] u8 {
    return cast([] u8) text;
}

add_file :: (files: *[..] mat.Load_Directory_File, name: string, data: [] u8) {
    array_add(files, mat.Load_Directory_File.{ name = name, data = data });
}

//@endregion

// Loop scopes adapted.
