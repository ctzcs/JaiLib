// kit/rendering/shader 回归测试 —— 一比一移植自 olib `tests/kit/rendering/shader/`（shader 相关部分）：
//
//   parameters_test.odin      -> 5 个用例（参数迁移 / std140 打包 / 资源编解码 / 采样器）
//   instance_test.odin        -> 3 个用例（精灵与模型材质实例、编码往返、拒绝半截数据）
//   shader_validate_test.odin -> 8 个用例（声明校验、目标、输入/覆盖值、拓扑排序）
//   lang/lang_test.odin       -> 9 个用例（.oshader 解析、每个 Pass 的 HLSL、两条 D3D12 规则、include ABI）
//   compile/compile_test.odin -> 4 个用例（命令行、工具身份、缺少工具链的诊断）
//   dev/compiler_test.odin    -> 3 个用例      dev/dev_test.odin      -> 3 个用例
//   dev/shader_files_test.odin-> 2 个用例
//
// 组织方式与 olib 对位：每个 @(test) 对应一个过程，签名 `(state: *Test_State)`，用例名与 olib 同名，
// 断言顺序保持原样；用 Tests/test_support.jai 的 expect / test_summary。本文件不写 main。
//
// ============================ 字节级契约（本文件的重点） ============================
// `hlsl()` 与 `lang.parse()` 生成的 HLSL 是逐字节契约。下面的 GOLDEN_* 常量**不是手写的**：
// 它们是把同一批 Schema / .oshader 输入喂给 olib 的 kit/rendering/shader/lang（odin run）后
// 原样导出的文本，逐字节与本包的输出比对（首行注释、缩进、register 绑定点、#define 顺序、
// OLIB_INSTANCE_DATA 槽位、include 顺序、`#line` 的行号与文件名、注释里的 ENDHLSL 都不允许漂移）。
//
// ============================ 不假装能编译 ============================
// shadercross / dxc 不在 JaiLib 里：compile.run 默认返回 COMPILER_UNAVAILABLE（没有注入执行器），
// dev.compile / stage_compile / reflect 因此只断言「诊断字符串 + 没有产物 + 没有 provenance」，
// 绝不假装编译成功。dev.Session.apply 是未实现的 seam（jfoster 没有 ShaderPairTryReplace），
// 只断言返回 false + SHADER_PAIR_REPLACE_UNAVAILABLE。
//
// Jai 侧差异（断言语义不变）：
//   | olib (Odin)                                   | 这里 (Jai)                                            |
//   | --------------------------------------------- | ----------------------------------------------------- |
//   | testing.expect / expectf / expect_value       | expect(state, cond, tprint("说明 %", args))                    |
//   | for invalid in ([]T{...})                     | 具名数组常量 + for（Jai 的 for 不接受类型标注）          |
//   | strings.replace_all(s, a, b, temp)            | ST_STRING.replace(s, a, b)（归 context，用完 free）      |
//   | strings.contains / has_prefix                 | ST_STRING.contains / begins_with                      |
//   | raw_data(x) / x == nil                        | x.data / x.data == null                               |
//   | mem.Tracking_Allocator 查泄漏                  | 无对应实现（jacket 无 tracking allocator），跳过该断言   |
//   | os.make_directory_temp                        | 固定夹具目录 .test_tmp/shader_test/（每个用例开头清空）    |
//   | transmute([]u8)str                            | cast([] u8) str                                       |
//   | [4]f32 的 ==                                  | shader_test_number_is（逐分量比较）                     |
//   | foster.TextureSampler 的 ==                    | shader_test_sampler_is（跨模块运算符不可见）             |
//   | fmt.tprint(enum) 之后比字符串                    | 直接比枚举值（Pass_Depth / Pass_Cull 成员一一对应）        |
#import "Basic";
#import "test_support";
ST_SH     :: #import "kit/rendering/shader";
ST_LANG   :: #import "kit/rendering/shader/lang";
ST_COMP   :: #import "kit/rendering/shader/compile";
ST_DEV    :: #import "kit/rendering/shader/dev";
ST_F      :: #import "jfoster";
ST_STRING :: #import "String";
ST_FILE   :: #import "File";
ST_FU     :: #import "File_Utilities";

//@region 夹具 helper（同目录另有 material_test.jai，全部用 shader_test_ 前缀防重名）

// olib 的 testing.expect_value(actual, want)。
shader_test_expect_value :: (state: *Test_State, actual: string, want: string) -> bool {
    expect(state, actual == want, tprint("expect_value: want \"%\", got \"%\"", want, actual));
    return actual == want;
}

// [4]f32 逐分量相等（Jai 的数组没有 ==）。
shader_test_number_is :: (a: [4] float32, b: [4] float32) -> bool {
    for value, i: a {
        if value != b[i] return false;
    }
    return true;
}

// jfoster 的 operator == 声明在 jfoster 模块里，跨模块不可见；按字段比较。
shader_test_sampler_is :: (a: ST_F.Texture_Sampler, b: ST_F.Texture_Sampler) -> bool {
    return a.Filter == b.Filter && a.WrapX == b.WrapX && a.WrapY == b.WrapY;
}

shader_test_free :: (text: string) {
    if text.data != null free(text.data);
}

// 一段文本里 offset 附近的上下文（换行写成 \n，便于在单行消息里看清）。
shader_test_window :: (text: string, offset: int) -> string {
    start := max(0, offset - 24);
    end := min(text.count, offset + 48);
    if end <= start return "";
    b: String_Builder;
    for i: start..end - 1 {
        c := text[i];
        if c == #char "\n" {
            append(*b, #char "\\");
            append(*b, #char "n");
        } else {
            append(*b, c);
        }
    }
    result := builder_to_string(*b);
    free_buffers(*b);
    return result;
}

// 逐字节比对生成文本（HLSL 契约）。失败时报告长度与首个不同字节的上下文。
shader_test_expect_bytes :: (state: *Test_State, actual: string, want: string, what: string) -> bool {
    if actual == want {
        expect(state, true, tprint("%", what));
        return true;
    }
    offset := 0;
    while offset < min(actual.count, want.count) && actual[offset] == want[offset] offset += 1;
    expect(state, false, tprint("% 逐字节不同：长度 want=% got=%，首个不同字节 #%；want=\"%\" got=\"%\"", what, want.count, actual.count, offset, shader_test_window(want, offset), shader_test_window(actual, offset)));
    return false;
}

// 字符串前缀视图（Jai 没有 s[a:b]）。
shader_test_prefix :: (text: string, count: int) -> string {
    if count <= 0 return "";
    if count >= text.count return text;
    return string.{ count, text.data };
}

// ---- 目录夹具：olib 用 os.make_directory_temp，这里用已 gitignore 的固定目录，用例开头清空。
shader_test_root :: () -> string {
    ST_FILE.make_directory_if_it_does_not_exist(".test_tmp/shader_test", true);
    return ".test_tmp/shader_test";
}

shader_test_fresh_dir :: (name: string) -> string {
    dir := tprint("%/%", shader_test_root(), name);
    _ = ST_FU.delete_directory_tree(dir); // 不存在时返回 false，无所谓
    ST_FILE.make_directory_if_it_does_not_exist(dir, true);
    return dir;
}

shader_test_write :: (path: string, text: string) -> bool {
    return ST_FILE.write_entire_file(path, text);
}

shader_test_read :: (path: string) -> string {
    data, ok := ST_FILE.read_entire_file(path);
    if !ok return "";
    return cast(string) data;
}

// ---- shader_validate_test 的公共夹具（olib 的实现用 temp_allocator；这里显式分配并释放）。
shader_test_make_validate_schemas :: () -> [] ST_SH.Schema {
    fields := ST_SH.shader_alloc_array(ST_SH.Field, 2);
    fields[0] = ST_SH.Field.{ id = "image", name = "image", kind = .Texture };
    fields[1] = ST_SH.Field.{ id = "amount", name = "amount", kind = .Scalar, maximum = 1 };
    schemas := ST_SH.shader_alloc_array(ST_SH.Schema, 1);
    schemas[0] = ST_SH.Schema.{ name = "Body", preview = "2d", fields = fields };
    return schemas;
}

shader_test_dispose_schemas :: (schemas: [] ST_SH.Schema) {
    for *schema: schemas {
        if schema.fields.data != null free(schema.fields.data);
    }
    if schemas.data != null free(schemas.data);
}

shader_test_base_pass :: () -> ST_SH.Pass_Desc {
    return ST_SH.Pass_Desc.{ id = "a", params = "Body", draw = .Fullscreen, output = "color" };
}

// 注意：`.{ pass }` 会指向函数栈上的临时数组，返回后失效；这里显式分配，
// 用完由 shader_test_dispose_shader 释放（字符串都是字面量，不能交给 shader_dispose）。
shader_test_single_pass_shader :: (pass: ST_SH.Pass_Desc) -> ST_SH.Shader_Desc {
    passes := ST_SH.shader_alloc_array(ST_SH.Pass_Desc, 1);
    passes[0] = pass;
    return ST_SH.Shader_Desc.{ name = "E", output = "color", passes = passes };
}

shader_test_dispose_shader :: (shader: ST_SH.Shader_Desc) {
    if shader.passes.data != null free(shader.passes.data);
}

// olib 的 expect_invalid：诊断里必须出现 expected 片段。
shader_test_expect_invalid :: (state: *Test_State, shader: ST_SH.Shader_Desc, expected: string) {
    schemas := shader_test_make_validate_schemas();
    reason := ST_SH.shader_validate(shader, schemas);
    expect(state, ST_STRING.contains(reason, expected), tprint("诊断应包含 \"%\"，实际 \"%\"", expected, reason));
    shader_test_dispose_schemas(schemas);
}

// 两段字符串替换（olib 的 [2]string 表在 Jai 里用结构体表达）。
Shader_Test_Change :: struct {
    from, to: string;
}

shader_test_replace :: (text: string, from: string, to: string) -> string {
    replaced, _ := ST_STRING.replace(text, from, to);
    return replaced;
}
//@endregion

//@region .oshader 输入（与 olib lang_test.odin 的 SOURCE 逐字节相同）

SHADER_SOURCE ::
"Shader \"Water\" {\nLabel \"Water demo\"\nProperties {\n    [Id(\"velocity\")] [Step(0.1)] _Speed (\"Speed\", Range(0, 5)) = 1\n    _Tint (\"Tint\", Color) = (0.2, 0.5, 0.8, 1)\n    [Filter(Nearest)] [Wrap(Repeat)] _Source (\"Source\", 2D) = \"\"\n}\nHLSLINCLUDE\nfloat4 shared_color() { return _Tint; }\nENDHLSL\nPass \"scene\" {\n    Output \"scene\"\n    Target { Scale 0.5 Format Float16 }\n    HLSLPROGRAM\n// ENDHLSL in a comment is ordinary HLSL.\n/*\nENDHLSL\n*/\nfloat4 fragment_main() : SV_Target0 { return shared_color(); }\nENDHLSL\n}\nPass \"compose\" {\n    Output \"color\"\n    Input _Source \"scene\" Current\n    Value \"velocity\" 2\n    HLSLPROGRAM\nfloat4 fragment_main() : SV_Target0 { return _Source.Load(int3(0, 0, 0)); }\nENDHLSL\n}\n}";

SHADER_GLOW ::
"Shader \"Glow\" {\nPreview 2D\nProperties {\n    [Instance] _Hue (\"Hue\", Range(0, 1)) = 0.2\n    _Image (\"Image\", 2D) = \"\"\n    [Id(\"amount\")] [Instance] _Amount (\"Amount\", Range(0, 2)) = 1\n}\nPass \"body\" {\n    Draw Sprite\n    SpriteTexture _Image\n    HLSLPROGRAM\nfloat4 fragment_main() : SV_Target0 { return float4(_Hue, _Amount, 0, 1); }\nENDHLSL\n}\n}";

SHADER_TINTED ::
"Shader \"Tinted\" {\nInstanced\nPass \"body\" {\n    Draw Sprite\n    HLSLPROGRAM\nfloat4 fragment_main() : SV_Target0 { return InstanceTint; }\nENDHLSL\n}\n}";

SHADER_SKIN ::
"Shader \"Skin\" {\nSkinned\nPass \"body\" { Draw Model\nHLSLPROGRAM\n#include \"olib/skinning.hlsli\"\nstruct Input { OlibSkinnedInput Skin; };\nfloat4 vertex_main(Input v) : SV_Position {\n    return mul(float4(olib_skin_vertex(v.Skin).position, 1), Wvp);\n}\nfloat4 fragment_main() : SV_Target0 { return Tint; }\nENDHLSL\n}\n}";

SHADER_MODEL ::
"Shader \"Outlined\" {\nProperties { _Color (\"Color\", Color) = (1, 1, 1, 1) }\nPass \"body\" { Draw Model Cull Back Blend Opaque ZTest Less ZWrite On\nHLSLPROGRAM\nfloat4 fragment_main() : SV_Target0 { return _Color; }\nENDHLSL\n}\nPass \"outline\" { Draw Model Cull Front ZTest Less_Equal ZWrite Off\nHLSLPROGRAM\nfloat4 fragment_main() : SV_Target0 { return _Color; }\nENDHLSL\n}\n}";

// D3D12 两条规则的检查夹具（注释用 ASCII，行号与 olib 的样例一致）。
SHADER_SWARM ::
"Shader \"Swarm\" {\nInstanced\nPass \"body\" { Draw Model\nHLSLPROGRAM\nstruct Input {\n    OlibInstanceInput Instance; // instance input first\n    float3 Position : TEXCOORD0;\n};\nstruct Output {\n    float4 Position : SV_Position;\n    float3 Normal : TEXCOORD0;\n    OlibInstance Instance;\n};\nOutput vertex_main(Input v)\n{\n    Output o;\n    o.Position = mul(float4(v.Position, 1), olib_world(v.Instance));\n    o.Normal = v.Position;\n    o.Instance = olib_instance_from(v.Instance);\n    return o;\n}\nfloat4 fragment_main(Output v) : SV_Target0\n{\n    olib_instance = v.Instance;\n    return float4(v.Normal, 1) * InstanceTint;\n}\nENDHLSL\n}\n}";

SHADER_SWARM_INPUT_MOVED ::
"    float3 Position : TEXCOORD0;\n    OlibInstanceInput Instance;";

SHADER_SWARM_INPUT_HEAD :: "    OlibInstanceInput Instance; // instance input first\n    float3 Position : TEXCOORD0;";

SHADER_SPRITE_BAD ::
"Shader \"Glow\" {\nPass \"main\" { Draw Sprite\nHLSLPROGRAM\nstruct Input { float2 Extra : TEXCOORD5; OlibSpriteInput Sprite; };\nstruct Output { float4 Position : SV_Position; };\nOutput vertex_main(Input v) { Output o; o.Position = float4(olib_sprite(v.Sprite).position, 0, 1); return o; }\nfloat4 fragment_main(Output v) : SV_Target0 { return 1; }\nENDHLSL\n}\n}";

SHADER_SINGLE_FILE ::
"Shader \"Single\" {\nProperties { _Tint (\"Tint\", Color) = (0.2, 0.4, 0.8, 1) }\nPass \"main\" { Draw Fullscreen\nHLSLPROGRAM\nstruct Input { float2 position : TEXCOORD0; float2 uv : TEXCOORD1; };\nfloat4 vertex_main(Input v) : SV_Position { return float4(v.position, 0, 1); }\nfloat4 fragment_main() : SV_Target0 { return _Tint; }\nENDHLSL\n}\n}";

// 深度比较的四种补全取值（ZTest 按枚举名解析）。
SHADER_DEPTH ::
"Shader \"Depth\" {\nPass \"silhouette\" { Draw Model ZTest NAME ZWrite Off\nHLSLPROGRAM\nfloat4 fragment_main() : SV_Target0 { return 1; }\nENDHLSL\n}\n}";
//@endregion

//@region 字节级黄金文本（由 olib 的同一批输入导出，见文件头）

GOLDEN_WATER_PROGRAM_0 :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_param_0;\n    float4 _olib_param_1;\n};\n#define _Speed (_olib_param_0.x)\n#define _Tint (_olib_param_1.xyzw)\nTexture2D _Source : register(t0, space2);\nSamplerState _SourceSampler : register(s0, space2);\n\n#line 8 \"water.oshader\"\n\nfloat4 shared_color() { return _Tint; }\n\n\n#line 14 \"water.oshader\"\n\n// ENDHLSL in a comment is ordinary HLSL.\n/*\nENDHLSL\n*/\nfloat4 fragment_main() : SV_Target0 { return shared_color(); }\n\n";
GOLDEN_WATER_PROGRAM_1 :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_param_0;\n    float4 _olib_param_1;\n};\n#define _Speed (_olib_param_0.x)\n#define _Tint (_olib_param_1.xyzw)\nTexture2D _Source : register(t0, space2);\nSamplerState _SourceSampler : register(s0, space2);\n\n#line 8 \"water.oshader\"\n\nfloat4 shared_color() { return _Tint; }\n\n\n#line 26 \"water.oshader\"\n\nfloat4 fragment_main() : SV_Target0 { return _Source.Load(int3(0, 0, 0)); }\n\n";
GOLDEN_WATER_SCHEMA0_HLSL :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_param_0;\n    float4 _olib_param_1;\n};\n#define _Speed (_olib_param_0.x)\n#define _Tint (_olib_param_1.xyzw)\nTexture2D _Source : register(t0, space2);\nSamplerState _SourceSampler : register(s0, space2);\n";
GOLDEN_GLOW_PROGRAM_0 :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_unused;\n};\n#define OLIB_INSTANCE_SLOTS 2\n#define OLIB_INSTANCE_DATA(X) X(0, 11, 9) X(1, 12, 10)\n#define OLIB_SPRITE_BATCH\n#include \"olib/instance.hlsli\"\n#include \"olib/sprite_vertex.hlsli\"\n#define _Hue (olib_instance.data0.x)\nTexture2D _Image : register(t0, space2);\nSamplerState _ImageSampler : register(s0, space2);\n#define _Amount (olib_instance.data1.x)\n\n#line 11 \"glow.oshader\"\n\nfloat4 fragment_main() : SV_Target0 { return float4(_Hue, _Amount, 0, 1); }\n\n";
GOLDEN_GLOW_INSTANCED_0 :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_unused;\n};\n#define OLIB_INSTANCE_SLOTS 2\n#define OLIB_INSTANCE_DATA(X) X(0, 11, 9) X(1, 12, 10)\n#define OLIB_INSTANCE_SPRITE\n#include \"olib/instance.hlsli\"\n#include \"olib/sprite_vertex.hlsli\"\n#define _Hue (olib_instance.data0.x)\nTexture2D _Image : register(t0, space2);\nSamplerState _ImageSampler : register(s0, space2);\n#define _Amount (olib_instance.data1.x)\n\n#line 11 \"glow.oshader\"\n\nfloat4 fragment_main() : SV_Target0 { return float4(_Hue, _Amount, 0, 1); }\n\n";
GOLDEN_TINTED_PROGRAM_0 :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_unused;\n};\n#define OLIB_INSTANCE_SLOTS 0\n#define OLIB_INSTANCE_DATA(X)\n#define OLIB_SPRITE_BATCH\n#include \"olib/instance.hlsli\"\n#include \"olib/sprite_vertex.hlsli\"\n\n#line 5 \"tinted.oshader\"\n\nfloat4 fragment_main() : SV_Target0 { return InstanceTint; }\n\n";
GOLDEN_TINTED_INSTANCED_0 :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_unused;\n};\n#define OLIB_INSTANCE_SLOTS 0\n#define OLIB_INSTANCE_DATA(X)\n#define OLIB_INSTANCE_SPRITE\n#include \"olib/instance.hlsli\"\n#include \"olib/sprite_vertex.hlsli\"\n\n#line 5 \"tinted.oshader\"\n\nfloat4 fragment_main() : SV_Target0 { return InstanceTint; }\n\n";
GOLDEN_SKIN_PROGRAM_0 :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_unused;\n};\n\n#line 4 \"skin.oshader\"\n\n#include \"olib/skinning.hlsli\"\nstruct Input { OlibSkinnedInput Skin; };\nfloat4 vertex_main(Input v) : SV_Position {\n    return mul(float4(olib_skin_vertex(v.Skin).position, 1), Wvp);\n}\nfloat4 fragment_main() : SV_Target0 { return Tint; }\n\n";
GOLDEN_OUTLINED_PROGRAM_1 :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_param_0;\n};\n#define _Color (_olib_param_0.xyzw)\n\n#line 9 \"model.oshader\"\n\nfloat4 fragment_main() : SV_Target0 { return _Color; }\n\n";
GOLDEN_MIGRATE_HLSL :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_param_0;\n    float4 _olib_param_1;\n    float4 _olib_param_2;\n};\n#define _tint (_olib_param_0.xyzw)\nTexture2D _albedo : register(t0, space2);\nSamplerState _albedoSampler : register(s0, space2);\n#define _strength (_olib_param_1.x)\n#define _offset (_olib_param_2.xy)\n";
GOLDEN_TEXTURE_ONLY_HLSL :: "// Generated from Odin; do not edit.\ncbuffer MaterialParams : register(b1, space3) {\n    float4 _olib_unused;\n};\nTexture2D _image : register(t0, space2);\nSamplerState _imageSampler : register(s0, space2);\n";
//@endregion

//@region parameters_test.odin

shader_pass_graph_orders_current_dependencies_and_owns_nested_data :: (state: *Test_State) {
    schemas := ST_SH.Schema.[ ST_SH.Schema.{ name = "Image", preview = "2d",
                                             fields = .[ {id = "source", kind = .Texture} ] } ];
    e := ST_SH.Shader_Desc.{ name = "Trail", output = "result", passes = .[
        {id = "final", params = "Image", output = "result",
         inputs = .[ {field = "source", target = "scene"} ]},
        {id = "seed", params = "Image", output = "scene",
         inputs = .[ {field = "source", target = "result", frame = .Previous} ]} ] };

    order, error := ST_SH.shader_order(e, schemas);
    expect(state, error == "" && order.count == 2 && order[0] == 1 && order[1] == 0, tprint("当前帧依赖排序（seed 先于 final）：error=\"%\"", error));
    if order.data != null free(order.data);

    owned := ST_SH.shader_clone(e);
    expect(state, owned.passes[0].inputs.data != e.passes[0].inputs.data, "clone 深复制 inputs");
    owned.passes[1].inputs[0].frame = .Current;
    bad, cycle := ST_SH.shader_order(owned, schemas);
    expect(state, bad.count == 0 && ST_STRING.contains(cycle, "cycle"), tprint("当前帧环：\"%\"", cycle));
    if bad.data != null free(bad.data);

    owned.passes[1].inputs[0].frame = .Previous;
    ST_SH.shader_free_string(owned.passes[0].inputs[0].field);
    owned.passes[0].inputs[0].field = ST_SH.clone_text("missing");
    missing_order, missing := ST_SH.shader_order(owned, schemas);
    expect(state, ST_STRING.contains(missing, "Texture field"), tprint("缺失字段诊断：\"%\"", missing));
    if missing_order.data != null free(missing_order.data);

    expect(state, e.passes[0].inputs[0].field == "source" && e.passes[1].inputs[0].frame == .Previous,
           "原声明未被 clone/排序修改");
    ST_SH.shader_dispose(*owned);
}

shader_migrate_ids_and_pack_independent_gpu_slots :: (state: *Test_State) {
    before := ST_SH.Schema.{ fields = .[
        {id = "strength", name = "old_name", kind = .Scalar, maximum = 5, initial = .[ 2, 0, 0, 0 ]},
        {id = "image", name = "image", kind = .Texture, texture = "old.png"},
        {id = "color", name = "color", kind = .Color, maximum = 1, initial = .[ 1, 0.5, 0.25, 1 ]} ] };
    previous := ST_SH.values_make(before);
    after := ST_SH.Schema.{ fields = .[
        {id = "color", name = "tint", kind = .Color, maximum = 1},
        {id = "image", name = "albedo", kind = .Texture},
        {id = "strength", name = "strength", kind = .Scalar, maximum = 1},
        {id = "new", name = "offset", kind = .Vector2, minimum = -1, maximum = 1,
         initial = .[ 0.2, -0.5, 0, 0 ]} ] };
    values := ST_SH.values_make(after, before, previous);

    expect(state, shader_test_number_is(values[0].number, previous[2].number), "按 ID 迁移保留颜色数值");
    expect(state, values[1].texture == "old.png" && values[1].texture.data != previous[1].texture.data,
           "贴图路径迁移且字符串独立复制");
    expect(state, values[2].number[0] == 1 && values[3].number[1] == -0.5,
           "收窄范围钳制到 1，新字段用默认值");

    bytes: [48] u8;
    expect(state, ST_SH.uniform_size(after) == 48 && ST_SH.texture_count(after) == 1,
           "uniform_size=48 / texture_count=1");
    expect(state, ST_SH.pack(after, values, .{ 48, cast(*u8) *bytes }), "pack 成功");

    slots: [3][4] float32;
    memcpy(*slots, cast(*u8) *bytes, 48);
    expect(state, shader_test_number_is(slots[0], values[0].number) && slots[1][0] == 1 && slots[2][1] == -0.5,
           "std140 槽序与 swizzle：slot0=color slot1=strength slot2=offset");

    expect(state, !ST_SH.pack(after, values, .{ 16, cast(*u8) *bytes }), "长度不符时 pack 失败");

    text := ST_SH.hlsl(after);
    expect(state, ST_STRING.contains(text, "Texture2D _albedo : register(t0, space2)"), "贴图绑定点 t0/space2");
    expect(state, ST_STRING.contains(text, "#define _offset (_olib_param_2.xy)"), "Vector2 取 xy swizzle");
    shader_test_expect_bytes(state, text, GOLDEN_MIGRATE_HLSL, "migrate 后参数组的 HLSL");
    shader_test_free(text);

    ST_SH.values_dispose(values);
    ST_SH.values_dispose(previous);
}

shader_changed_type_uses_defaults :: (state: *Test_State) {
    old := ST_SH.Schema.{ fields = .[ {id = "value", kind = .Scalar, maximum = 5,
                                       initial = .[ 3, 0, 0, 0 ]} ] };
    next := ST_SH.Schema.{ fields = .[ {id = "value", kind = .Vector3, maximum = 1,
                                        initial = .[ 0.1, 0.2, 0.3, 0 ]} ] };
    previous := ST_SH.values_make(old);
    values := ST_SH.values_make(next, old, previous);
    expect(state, shader_test_number_is(values[0].number, next.fields[0].initial),
           "类型改变后取新默认值而不是旧数值");
    ST_SH.values_dispose(values);
    ST_SH.values_dispose(previous);
}

shader_resource_roundtrip_isolation_and_validation :: (state: *Test_State) {
    // olib 这里用 mem.Tracking_Allocator 断言「零泄漏」；jacket 没有 tracking allocator，
    // 该断言未移植（见报告「未覆盖」）。
    schema := ST_SH.schema_clone(ST_SH.Schema.{ name = "Standard", shader = "surface.hlsl", preview = "3d",
                                                fields = .[
        {id = "metallic", name = "metallic", label = "metallic", kind = .Scalar, maximum = 1, step = 0.01},
        {id = "color", name = "color", label = "color", kind = .Color, maximum = 1, step = 0.01,
         initial = .[ 1, 1, 1, 1 ]},
        {id = "image", name = "image", label = "image", kind = .Texture} ] });
    base := ST_SH.values_make(schema);
    base[0].number[0] = 0.7;

    changed, error := ST_SH.values_overlay(schema, base, .[ {id = "color", kind = .Color,
                                                             number = .[ 0.1, 0.8, 0.3, 1 ]} ]);
    expect(state, error == "" && base[1].number[0] == 1 && changed[1].number[0] == 0.1, tprint("overlay 不修改共享 base：error=\"%\"", error));

    bytes, encode_error := ST_SH.resource_encode(schema, changed);
    expect(state, encode_error == "", tprint("resource_encode：\"%\"", encode_error));
    loaded, decode_error := ST_SH.resource_decode(schema, bytes);
    expect(state, encode_error == "" && decode_error == "" && loaded[0].number[0] == 0.7, tprint("resource 编解码往返：decode=\"%\"", decode_error));

    packed: [32] u8;
    expect(state, ST_SH.pack(schema, loaded, .{ 32, cast(*u8) *packed }), "解码后的值可以打包");

    // JSON 键名/枚举拼写是往返的一部分（olib 的 json 字节格式不同，见报告）。
    encoded := cast(string) bytes;
    expect(state, ST_STRING.contains(encoded, "\"version\": 1") &&
                   ST_STRING.contains(encoded, "\"group\": \"Standard\"") &&
                   ST_STRING.contains(encoded, "\"kind\": \"Scalar\"") &&
                   ST_STRING.contains(encoded, "\"id\": \"metallic\""),
           "材质 JSON 的键名与枚举拼写");

    bad_jsons: [5] string = .[ "broken",
                               "{\"version\":2,\"group\":\"Standard\"}",
                               "{\"version\":1,\"group\":\"Other\"}",
                               "{\"version\":1,\"group\":\"Standard\",\"fields\":[{\"id\":\"metallic\",\"kind\":\"Scalar\",\"number\":[2,0,0,0]}]}",
                               "{\"version\":1,\"group\":\"Standard\",\"fields\":[{\"id\":\"metallic\"},{\"id\":\"metallic\"}]}" ];
    for bad: bad_jsons {
        invalid, message := ST_SH.resource_decode(schema, cast([] u8) bad);
        expect(state, invalid.data == null && message != "", tprint("拒绝无效材质 JSON：%", bad));
    }

    ST_SH.values_dispose(loaded);
    if bytes.data != null free(bytes.data);
    ST_SH.values_dispose(changed);
    ST_SH.values_dispose(base);
    ST_SH.schema_dispose(*schema);
}

// 精灵纹理只用显式写了的部分，其余沿用 Render2D 的 push_sampler；普通贴图字段按声明，缺省线性、钳制。
shader_sprite_sampler_uses_only_declared_parts :: (state: *Test_State) {
    inherited := ST_F.texture_sampler_make(.NEAREST, .CLAMP);
    plain := ST_SH.Field.{ kind = .Texture };
    expect(state, shader_test_sampler_is(ST_SH.field_sampler(plain), ST_F.texture_sampler_make(.LINEAR, .CLAMP)),
           "普通贴图字段：线性 + 钳制");
    expect(state, shader_test_sampler_is(ST_SH.field_sprite_sampler(plain, inherited), inherited),
           "精灵纹理：都没写时沿用 push_sampler");
    only_wrap := ST_SH.Field.{ kind = .Texture, wrap = .Repeat, wrap_declared = true };
    expect(state, shader_test_sampler_is(ST_SH.field_sprite_sampler(only_wrap, inherited),
                                         ST_F.texture_sampler_make(.NEAREST, .REPEAT)),
           "只写了 Wrap：过滤沿用 inherited");
    only_filter := ST_SH.Field.{ kind = .Texture, filter = .Linear, filter_declared = true };
    expect(state, shader_test_sampler_is(ST_SH.field_sprite_sampler(only_filter, inherited),
                                         ST_F.texture_sampler_make(.LINEAR, .CLAMP)),
           "只写了 Filter：寻址沿用 inherited");
}
//@endregion

//@region instance_test.odin

shader_sprite_material_contract_and_roundtrip :: (state: *Test_State) {
    schemas := ST_SH.Schema.[ ST_SH.Schema.{ name = "Sprite", preview = "2d",
                                             fields = .[ {id = "mask", kind = .Texture},
                                                          {id = "frame", kind = .Texture} ] } ];
    shader := ST_SH.Shader_Desc.{ name = "Sprite", output = "color", passes = .[
        {id = "shadow", params = "Sprite", draw = .Sprite, output = "color", sprite_texture = "frame"},
        {id = "body", params = "Sprite", draw = .Sprite, output = "color", sprite_texture = "frame"} ] };
    instance, reason := ST_SH.instance_make(shader, schemas);
    expect(state, reason == "" && instance.groups.count == 1, tprint("精灵实例只有一个参数组：\"%\"", reason));

    bytes, encode_error := ST_SH.instance_encode(instance);
    loaded, decode_error := ST_SH.instance_decode(shader, schemas, bytes);
    expect(state, encode_error == "" && decode_error == "", tprint("实例编解码往返：encode=\"%\" decode=\"%\"", encode_error, decode_error));

    copied := ST_SH.shader_clone(shader);
    expect(state, ST_SH.shader_clone(shader).passes[0].sprite_texture == "frame", "clone 保留 sprite_texture");

    invalids: [3] ST_SH.Pass_Desc = .[
        ST_SH.Pass_Desc.{ id = "body", params = "Sprite", draw = .Model, output = "color" },
        ST_SH.Pass_Desc.{ id = "body", params = "Sprite", draw = .Fullscreen, output = "color" },
        ST_SH.Pass_Desc.{ id = "body", params = "Sprite", draw = .Sprite, output = "color",
                          sprite_texture = "missing" } ];
    for invalid: invalids {
        shader.passes[1] = invalid;
        order, error := ST_SH.shader_order(shader, schemas);
        if order.data != null free(order.data);
        expect(state, error != "", tprint("非法 Sprite Pass 应被拒绝：\"%\"", error));
    }

    shader.passes[1] = shader.passes[0];
    shader.passes[1].id = "body";
    schemas[0].preview = "3d";
    order, error := ST_SH.shader_order(shader, schemas);
    if order.data != null free(order.data);
    expect(state, error != "", tprint("精灵 Pass 用 3d 参数组应被拒绝：\"%\"", error));

    ST_SH.shader_dispose(*copied);
    ST_SH.instance_dispose(*loaded);
    if bytes.data != null free(bytes.data);
    ST_SH.instance_dispose(*instance);
}

shader_model_passes_share_depth_target_without_relaxing_image_graph :: (state: *Test_State) {
    schemas := ST_SH.Schema.[ ST_SH.Schema.{ name = "Surface", preview = "3d" } ];
    e := ST_SH.Shader_Desc.{ name = "Outline", output = "scene", passes = .[
        {id = "body", params = "Surface", draw = .Model, output = "scene"},
        {id = "outline", params = "Surface", draw = .Model, output = "scene",
         state = .{ cull = .Front, depth_write = .Off }} ] };

    order, reason := ST_SH.shader_order(e, schemas);
    expect(state, reason == "" && order.count == 2 && order[0] == 0 && order[1] == 1, tprint("两个 Model Pass 共享目标且顺序保持：\"%\"", reason));
    if order.data != null free(order.data);

    copied := ST_SH.shader_clone(e);
    expect(state, copied.passes[1].state.cull == .Front, "clone 保留渲染状态");

    copied.passes[1].draw = .Preview_Model;
    bad, mix_error := ST_SH.shader_order(copied, schemas);
    if bad.data != null free(bad.data);
    expect(state, mix_error != "", tprint("Model 与 Preview_Model 不能混用：\"%\"", mix_error));

    copied.passes[0].draw = .Preview_Model;
    duplicate, duplicate_error := ST_SH.shader_order(copied, schemas);
    if duplicate.data != null free(duplicate.data);
    expect(state, ST_STRING.contains(duplicate_error, "unique"), tprint("重复绘制种类必须唯一：\"%\"", duplicate_error));

    copied.passes[0].draw = .Model;
    copied.passes[1].draw = .Model;
    copied.passes[1].target.samples = 4;
    target, target_error := ST_SH.shader_order(copied, schemas);
    if target.data != null free(target.data);
    expect(state, target_error != "", tprint("Material Pass 必须共享同一目标描述：\"%\"", target_error));

    ST_SH.shader_dispose(*copied);
}

shader_model_instance_roundtrip_groups_and_reject_partial_decode :: (state: *Test_State) {
    schemas := ST_SH.Schema.[
        ST_SH.Schema.{ name = "Body", preview = "3d",
                       fields = .[ {id = "amount", kind = .Scalar, maximum = 1, initial = .[ 0.3, 0, 0, 0 ]} ] },
        ST_SH.Schema.{ name = "Outline", preview = "3d",
                       fields = .[ {id = "image", kind = .Texture, texture = "edge.png"} ] } ];
    e := ST_SH.Shader_Desc.{ name = "Outlined", output = "color", passes = .[
        {id = "body", draw = .Model, output = "color", params = "Body"},
        {id = "outline", draw = .Model, output = "color", params = "Outline"} ] };

    a, reason := ST_SH.instance_make(e, schemas);
    expect(state, reason == "", tprint("两个参数组的模型实例：\"%\"", reason));
    a.groups[0].values[0].number[0] = 0.75;

    bytes, encode_error := ST_SH.instance_encode(a);
    b, decode_error := ST_SH.instance_decode(e, schemas, bytes);
    expect(state, encode_error == "" && decode_error == "" && b.groups[0].values[0].number[0] == 0.75, tprint("模型实例编解码往返：encode=\"%\" decode=\"%\"", encode_error, decode_error));

    b.groups[0].values[0].number[0] = 0.1;
    expect(state, a.groups[0].values[0].number[0] == 0.75, "解码结果是独立副本");
    expect(state, b.groups[1].values[0].texture.data != a.groups[1].values[0].texture.data,
           "解码时贴图字符串各自拥有");

    bad_jsons: [3] string = .[
        "{\"version\":2,\"effect\":\"Other\"}",
        "{\"version\":2,\"effect\":\"Outlined\",\"groups\":[{\"version\":1,\"group\":\"Body\"},{\"version\":1,\"group\":\"Body\"}]}",
        "{\"version\":2,\"effect\":\"Outlined\",\"groups\":[{\"version\":1,\"group\":\"Body\"},{\"version\":1,\"group\":\"Outline\",\"fields\":[{\"id\":\"image\",\"kind\":\"Scalar\"}]}]}" ];
    for bad: bad_jsons {
        invalid, message := ST_SH.instance_decode(e, schemas, cast([] u8) bad);
        expect(state, invalid.groups.data == null && message != "", tprint("拒绝半截/无效实例 JSON：%", bad));
    }

    expect(state, a.groups[0].values[0].number[0] == 0.75, "失败的解码不修改原实例");

    ST_SH.instance_dispose(*b);
    if bytes.data != null free(bytes.data);
    ST_SH.instance_dispose(*a);
}
//@endregion

//@region shader_validate_test.odin

shader_shader_validate_accepts_baseline :: (state: *Test_State) {
    schemas := shader_test_make_validate_schemas();
    expect(state, ST_SH.shader_validate(shader_test_single_pass_shader(shader_test_base_pass()), schemas) == "",
           "单 Pass 全屏基线应当合法");
    shader_test_dispose_schemas(schemas);
}

shader_shader_validate_rejects_bad_shader_header :: (state: *Test_State) {
    shader := shader_test_single_pass_shader(shader_test_base_pass());
    shader.preview = "4d";
    shader_test_expect_invalid(state, shader, "Preview must be 2d or 3d");

    shader = shader_test_single_pass_shader(shader_test_base_pass());
    shader.name = "";
    shader_test_expect_invalid(state, shader, "requires a name");

    shader = shader_test_single_pass_shader(shader_test_base_pass());
    shader.passes = .[];
    shader_test_expect_invalid(state, shader, "requires a name");

    shader = shader_test_single_pass_shader(shader_test_base_pass());
    shader.output = "missing";
    shader_test_expect_invalid(state, shader, "Shader output must name a pass target");
}

shader_shader_validate_rejects_bad_pass_declarations :: (state: *Test_State) {
    pass := shader_test_base_pass();
    pass.draw = cast(ST_SH.Pass_Draw) 9;
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "Invalid pass draw kind");

    pass = shader_test_base_pass();
    pass.state.cull = cast(ST_SH.Pass_Cull) 9;
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "Invalid pass render state");

    pass = shader_test_base_pass();
    pass.id = "";
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "cannot be empty");

    pass = shader_test_base_pass();
    pass.params = "Nope";
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "unknown parameter group");

    twice := ST_SH.Pass_Desc.[ shader_test_base_pass(), shader_test_base_pass() ];
    shader_test_expect_invalid(state, ST_SH.Shader_Desc.{ name = "E", output = "color", passes = twice },
                               "must be unique");
}

shader_shader_validate_rejects_bad_targets :: (state: *Test_State) {
    pass := shader_test_base_pass();
    pass.target.width = 10;
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "invalid target");

    pass = shader_test_base_pass();
    pass.target.samples = 3;
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "invalid target");

    pass = shader_test_base_pass();
    pass.target.width = ST_SH.MAX_TARGET_SIZE + 1;
    pass.target.height = 8;
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "invalid target");

    pass = shader_test_base_pass();
    pass.target.clear = .[ 2, 0, 0, 0 ];
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "clear color");
}

shader_shader_validate_rejects_bad_inputs_and_values :: (state: *Test_State) {
    pass := shader_test_base_pass();
    pass.inputs = .[ {field = "nope", target = "color"} ];
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "no Texture field");

    pass.inputs = .[ {field = "image", target = "ghost"} ];
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "unknown target");

    pass.inputs = .[ {field = "image", target = "color"}, {field = "image", target = "color"} ];
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "Duplicate pass texture binding");

    pass = shader_test_base_pass();
    pass.values = .[ {field = "amount", number = .[ 5, 0, 0, 0 ]} ];
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "outside field range");

    pass.values = .[ {field = "amount"}, {field = "amount"} ];
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "Duplicate pass value override");

    pass.values = .[ {field = "image"} ];
    shader_test_expect_invalid(state, shader_test_single_pass_shader(pass), "no numeric field");
}

shader_shader_sort_detects_current_frame_cycle :: (state: *Test_State) {
    passes := ST_SH.Pass_Desc.[
        ST_SH.Pass_Desc.{ id = "a", params = "Body", draw = .Fullscreen, output = "x",
                          inputs = .[ {field = "image", target = "y"} ] },
        ST_SH.Pass_Desc.{ id = "b", params = "Body", draw = .Fullscreen, output = "y",
                          inputs = .[ {field = "image", target = "x"} ] } ];
    shader := ST_SH.Shader_Desc.{ name = "E", output = "x", passes = passes };

    schemas := shader_test_make_validate_schemas();
    // 各 Pass 单独合法：环只有排序才发现。
    expect(state, ST_SH.shader_validate(shader, schemas) == "", "环里的每个 Pass 单独看都合法");
    shader_test_dispose_schemas(schemas);

    order, reason := ST_SH.shader_sort(shader);
    expect(state, order.data == null && ST_STRING.contains(reason, "cycle"), tprint("当前帧环：\"%\"", reason));

    passes[1].inputs[0].frame = .Previous;
    order, reason = ST_SH.shader_sort(shader);
    expect(state, reason == "" && order.count == 2 && order[0] == 1 && order[1] == 0, tprint("Previous 不参与依赖：b 先输出 y 再 a：\"%\"", reason));
    if order.data != null free(order.data);
}

// 每个参数组的统一参数不超过 MAX_UNIFORM_BYTES：每个数值字段占 16 字节，1024 个正好到上限。
shader_shader_validate_limits_uniform_bytes :: (state: *Test_State) {
    limit := ST_SH.MAX_UNIFORM_BYTES / ST_SH.PARAM_SLOT_BYTES;
    fields := ST_SH.shader_alloc_array(ST_SH.Field, limit + 1);
    for 0..limit {
        name := tprint("f%", it);
        fields[it] = ST_SH.Field.{ id = name, name = name, kind = .Scalar, maximum = 1 };
    }
    schemas := ST_SH.shader_alloc_array(ST_SH.Schema, 1);
    schemas[0] = ST_SH.Schema.{ name = "Body", preview = "2d", fields = array_view(fields, 0, limit) };
    expect(state, ST_SH.shader_validate(shader_test_single_pass_shader(shader_test_base_pass()), schemas) == "",
           "1024 个数值字段正好在上限内");

    schemas[0].fields = fields;
    expect(state, ST_STRING.contains(ST_SH.shader_validate(shader_test_single_pass_shader(shader_test_base_pass()),
                                                           schemas),
                                     "parameters exceed 16384 bytes"),
           "1025 个数值字段超过 16 KiB 上限");

    if schemas.data != null free(schemas.data);
    if fields.data != null free(fields.data);
}

shader_skinned_model_validation_and_clone :: (state: *Test_State) {
    schemas := shader_test_make_validate_schemas();
    schemas[0].preview = "3d";
    pass := shader_test_base_pass();
    pass.draw = .Model;
    e := shader_test_single_pass_shader(pass);
    e.skinned = true;
    expect(state, ST_SH.shader_validate(e, schemas) == "", "Skinned + Olib + Model 合法");

    copied := ST_SH.shader_clone(e);
    expect(state, copied.skinned && !copied.instanced && copied.uniforms == .Olib,
           "clone 保留 skinned/instanced/uniforms");

    draws: [3] ST_SH.Pass_Draw = .[ .Sprite, .Preview_Model, .Fullscreen ];
    for draw: draws {
        e.passes[0].draw = draw;
        expect(state, ST_STRING.contains(ST_SH.shader_validate(e, schemas), "Skinned"), tprint("非 Model 绘制种类的 Skinned 应被拒绝：%", cast(int) draw));
    }

    e.passes[0].draw = .Model;
    e.uniforms = .Foster;
    expect(state, ST_STRING.contains(ST_SH.shader_validate(e, schemas), "Skinned"), "Skinned 要求 Olib 布局");

    e.uniforms = .Olib;
    e.instanced = true;
    expect(state, ST_STRING.contains(ST_SH.shader_validate(e, schemas), "Skinned"), "Skinned 不能 instanced");

    e.instanced = false;
    schemas[0].fields[1].instance = true;
    expect(state, ST_STRING.contains(ST_SH.shader_validate(e, schemas), "Skinned cannot use Instance"),
           "Skinned 不能用 Instance 字段");

    ST_SH.shader_dispose(*copied);
    shader_test_dispose_schemas(schemas);
}
//@endregion

//@region lang/lang_test.odin

shader_properties_passes_and_original_hlsl_locations :: (state: *Test_State) {
    doc := ST_LANG.parse(SHADER_SOURCE, "water.oshader");
    expect(state, doc.error == "", tprint("解析应成功：\"%\"", doc.error));
    if doc.error != "" {
        ST_LANG.dispose(*doc);
        return;
    }

    expect(state, doc.schemas.count == 2 && doc.programs.count == 2, "两个 Pass 各一份 Schema/program");
    expect(state, doc.schemas[0].name == "Water_scene", "参数组名 = <Shader>_<Pass>");
    expect(state, doc.schemas[0].fields[0].id == "velocity", "[Id(...)] 覆盖稳定 ID");
    expect(state, doc.schemas[0].fields[0].step == cast(float32) 0.1, "[Step(0.1)] 生效");
    // 贴图的采样方式随 Schema 发布；未声明的贴图保持线性、钳制。
    expect(state, doc.schemas[0].fields[2].filter == .Nearest && doc.schemas[0].fields[2].wrap == .Repeat,
           "[Filter(Nearest)] [Wrap(Repeat)] 生效");
    expect(state, doc.schemas[0].fields[1].filter == .Linear && doc.schemas[0].fields[1].wrap == .Clamp,
           "未声明的贴图保持线性、钳制");
    expect(state, doc.schemas[0].fields[2].filter_declared && doc.schemas[0].fields[2].wrap_declared,
           "显式声明被记录");
    expect(state, !doc.schemas[0].fields[1].filter_declared && !doc.schemas[0].fields[1].wrap_declared,
           "未声明不记 declared");
    expect(state, doc.shader.output == "color", "顶层 Output");
    expect(state, doc.shader.passes[0].target.scale == cast(float32) 0.5, "Target Scale");
    expect(state, doc.shader.passes[1].inputs[0].target == "scene", "Input 目标");
    expect(state, doc.shader.passes[1].values[0].field == "velocity", "Value 覆盖值");
    expect(state, ST_STRING.contains(doc.programs[0], "#define _Speed"), "生成的参数 #define");
    expect(state, ST_STRING.contains(doc.programs[0], "#line 8 \"water.oshader\""),
           "共享 HLSLINCLUDE 的 #line 指向原文件行号");
    expect(state, ST_STRING.contains(doc.programs[0], "/*\nENDHLSL\n*/"),
           "注释里的 ENDHLSL 不是结束标记");
    expect(state, ST_STRING.contains(doc.programs[1], "Texture2D _Source"), "贴图声明");

    // 字节级契约：两个 Pass 的完整程序文本与 olib 逐字节相同。
    shader_test_expect_bytes(state, doc.programs[0], GOLDEN_WATER_PROGRAM_0, "Water/scene 的完整 HLSL");
    shader_test_expect_bytes(state, doc.programs[1], GOLDEN_WATER_PROGRAM_1, "Water/compose 的完整 HLSL");
    shader_test_expect_bytes(state, ST_SH.hlsl(doc.schemas[0]), GOLDEN_WATER_SCHEMA0_HLSL,
                             "Water_scene 参数块的 HLSL");

    ST_LANG.dispose(*doc);
}

shader_invalid_declarations_fail_without_partial_document :: (state: *Test_State) {
    changes: [..] Shader_Test_Change;
    array_add(*changes, Shader_Test_Change.{ "Range(0, 5)", "Range(5, 0)" });
    array_add(*changes, Shader_Test_Change.{ "Range(0, 5)", "Range(0, 0.5)" });
    array_add(*changes, Shader_Test_Change.{ "Step(0.1)", "Step(0)" });
    array_add(*changes, Shader_Test_Change.{ "_Tint (", "_Speed (" });
    array_add(*changes, Shader_Test_Change.{ "_Tint (", "_SourceSampler (" });
    array_add(*changes, Shader_Test_Change.{ "Input _Source \"scene\" Current", "Input _Source \"color\" Current" });
    array_add(*changes, Shader_Test_Change.{ "Input _Source \"scene\" Current", "Input _Speed \"scene\" Current" });
    array_add(*changes, Shader_Test_Change.{ "Value \"velocity\" 2", "Value \"velocity\" 9" });
    array_add(*changes, Shader_Test_Change.{ "Scale 0.5", "Scale nan" });
    array_add(*changes, Shader_Test_Change.{ "Scale 0.5", "Unknown 1" });
    array_add(*changes, Shader_Test_Change.{ "Pass \"compose\"", "Pass \"scene\"" });
    array_add(*changes, Shader_Test_Change.{ "Pass \"compose\"", "Pass \"../bad\"" });
    array_add(*changes, Shader_Test_Change.{ "Label \"Water demo\"", "Label \"Water demo\" Label \"Other\"" });
    array_add(*changes, Shader_Test_Change.{ "[Wrap(Repeat)]", "[Wrap(Tile)]" });
    array_add(*changes, Shader_Test_Change.{ "[Filter(Nearest)]", "[Filter(Point)]" });
    array_add(*changes, Shader_Test_Change.{ "[Wrap(Repeat)]", "[Wrap(Repeat)] [Wrap(Clamp)]" });
    // 采样方式只用于 2D 属性。
    array_add(*changes, Shader_Test_Change.{ "[Step(0.1)]", "[Step(0.1)] [Filter(Nearest)]" });

    for change: changes {
        bad := shader_test_replace(SHADER_SOURCE, change.from, change.to);
        doc := ST_LANG.parse(bad, "broken.oshader");
        expect(state, doc.error != "" && doc.schemas.count == 0, tprint("必须拒绝 %：\"%\"", change.to, doc.error));
        expect(state, ST_STRING.begins_with(doc.error, "broken.oshader:"), tprint("诊断带文件名前缀：\"%\"", doc.error));
        ST_LANG.dispose(*doc);
        shader_test_free(bad);
    }

    // 任何长度截断的输入都必须报错（且只有 error，没有半截文档）。
    for 0..SHADER_SOURCE.count - 1 {
        doc := ST_LANG.parse(shader_test_prefix(SHADER_SOURCE, it), "truncated.oshader");
        expect(state, doc.error != "", tprint("截断到 % 字节仍应报错", it));
        ST_LANG.dispose(*doc);
        // parse 的中间数据都在 temp 里；定期回收，避免 1000 次循环把临时存储撑爆。
        if it > 0 && it % 128 == 0 reset_temporary_storage();
    }
}

// ZTest 按枚举名解析，补全的四种比较与原有取值同样可用。
shader_model_depth_compare_names :: (state: *Test_State) {
    // olib 用 fmt.tprint(枚举) 之后比字符串；Jai 直接比枚举值，成员一一对应。
    depths: [4] ST_SH.Pass_Depth = .[ .Greater, .Greater_Equal, .Not_Equal, .Never ];
    names: [4] string = .[ "Greater", "Greater_Equal", "Not_Equal", "Never" ];
    for depth, i: depths {
        text := shader_test_replace(SHADER_DEPTH, "NAME", names[i]);
        doc := ST_LANG.parse(text, "depth.oshader");
        expect(state, doc.error == "", tprint("%：\"%\"", names[i], doc.error));
        expect(state, doc.shader.passes[0].state.depth == depth, tprint("ZTest % 按枚举名解析", names[i]));
        ST_LANG.dispose(*doc);
        shader_test_free(text);
    }
}

shader_model_render_states_and_previous_frame_graph :: (state: *Test_State) {
    doc := ST_LANG.parse(SHADER_MODEL, "model.oshader");
    expect(state, doc.error == "", tprint("模型声明应解析成功：\"%\"", doc.error));
    if doc.error == "" {
        expect(state, doc.schemas[0].preview == "3d", "Model Pass 的参数组预览是 3d");
        expect(state, doc.shader.passes[1].state.cull == .Front, "Cull Front");
        expect(state, doc.shader.passes[1].state.depth_write == .Off, "ZWrite Off");
        // 逐字节：outline Pass 的完整程序文本。
        shader_test_expect_bytes(state, doc.programs[1], GOLDEN_OUTLINED_PROGRAM_1, "Outlined/outline 的完整 HLSL");
    }
    ST_LANG.dispose(*doc);

    feedback := shader_test_replace(SHADER_SOURCE, "\"scene\" Current", "\"color\" Previous");
    history := ST_LANG.parse(feedback, "feedback.oshader");
    expect(state, history.error == "", tprint("Previous 反馈合法：\"%\"", history.error));
    ST_LANG.dispose(*history);
    shader_test_free(feedback);
}

shader_instance_properties_and_instanced_directive :: (state: *Test_State) {
    doc := ST_LANG.parse(SHADER_GLOW, "glow.oshader");
    expect(state, doc.error == "", tprint("instanced 精灵声明应解析成功：\"%\"", doc.error));
    if doc.error != "" {
        ST_LANG.dispose(*doc);
        return;
    }
    expect(state, doc.shader.instanced, "[Instance] 字段会自动打开 Instanced");
    expect(state, doc.schemas[0].fields[0].instance && !doc.schemas[0].fields[1].instance,
           "只有带 [Instance] 的字段是 per-instance");
    expect(state, doc.schemas[0].fields[2].instance && doc.schemas[0].fields[2].id == "amount",
           "[Id] + [Instance] 同时生效");
    expect(state, ST_STRING.contains(doc.programs[0], "#define _Hue (olib_instance.data0.x)"), "槽 0 的 define");
    expect(state, ST_STRING.contains(doc.programs[0], "#define _Amount (olib_instance.data1.x)"), "槽 1 的 define");

    // Sprite Pass：programs 是批量变体，instanced Shader 另有缓冲变体；两者都 include 精灵接口。
    batch := doc.programs[0];
    buffer := doc.instanced_programs[0];
    expect(state, ST_STRING.contains(batch, "#define OLIB_SPRITE_BATCH\n") &&
                   !ST_STRING.contains(batch, "OLIB_INSTANCE_SPRITE"),
           "批量变体只定义 OLIB_SPRITE_BATCH");
    expect(state, ST_STRING.contains(buffer, "#define OLIB_INSTANCE_SPRITE\n") &&
                   !ST_STRING.contains(buffer, "OLIB_SPRITE_BATCH"),
           "缓冲变体只定义 OLIB_INSTANCE_SPRITE");

    programs: [2] string = .[ batch, buffer ];
    for program: programs {
        expect(state, ST_STRING.contains(program, "#define OLIB_INSTANCE_DATA(X) X(0, 11, 9) X(1, 12, 10)\n"),
               "实例槽位的语义号（BASE+5 / VARYING+1）");
        expect(state, ST_STRING.contains(program,
                                         "#include \"olib/instance.hlsli\"\n#include \"olib/sprite_vertex.hlsli\"\n"),
               "两个 include 的顺序");
    }

    // 字节级：批量与缓冲两个变体的完整文本。
    shader_test_expect_bytes(state, batch, GOLDEN_GLOW_PROGRAM_0, "Glow 批量变体");
    shader_test_expect_bytes(state, buffer, GOLDEN_GLOW_INSTANCED_0, "Glow 缓冲变体");
    ST_LANG.dispose(*doc);

    // 只写 Instanced：Shader 启用顶点 tint，没有实例字段。
    tinted := ST_LANG.parse(SHADER_TINTED, "tinted.oshader");
    expect(state, tinted.error == "" && tinted.shader.instanced, tprint("只写 Instanced 也合法：\"%\"", tinted.error));
    if (tinted.error == "") {
        expect(state, ST_STRING.contains(tinted.programs[0],
                                         "#define OLIB_INSTANCE_SLOTS 0\n#define OLIB_INSTANCE_DATA(X)\n"),
               "没有实例字段时槽位为空");
        expect(state, ST_STRING.contains(tinted.instanced_programs[0], "#define OLIB_INSTANCE_SPRITE\n"),
               "空槽位仍有缓冲变体");
        shader_test_expect_bytes(state, tinted.programs[0], GOLDEN_TINTED_PROGRAM_0, "Tinted 批量变体");
        shader_test_expect_bytes(state, tinted.instanced_programs[0], GOLDEN_TINTED_INSTANCED_0, "Tinted 缓冲变体");
    }
    ST_LANG.dispose(*tinted);

    // 非 Sprite 的 Shader 没有缓冲变体。
    water := ST_LANG.parse(SHADER_SOURCE, "water.oshader");
    for program: water.instanced_programs {
        expect(state, program == "", "非 Sprite Shader 的缓冲变体为空");
    }
    ST_LANG.dispose(*water);

    // Texture 不能是 Instance。
    bad := ST_LANG.parse("Shader \"Bad\" {\nProperties { [Instance] _Image (\"Image\", 2D) = \"\" }\nPass \"p\" { HLSLPROGRAM\nfloat4 fragment_main() : SV_Target0 { return 0; }\nENDHLSL }\n}", "bad.oshader");
    expect(state, ST_STRING.contains(bad.error, "Texture cannot be Instance"), tprint("贴图不能 per-instance：\"%\"", bad.error));
    ST_LANG.dispose(*bad);
}

// 生成代码 include 的两个文件提供作者用到的接口；批量变体读 storage buffer，缓冲变体在 GPU 上套用变换栈（b1）。
shader_generator_includes_provide_sprite_and_instance_interfaces :: (state: *Test_State) {
    instance := shader_test_read(tprint("%/olib/instance.hlsli", ST_LANG.INCLUDE_DIRECTORY));
    sprite := shader_test_read(tprint("%/olib/sprite_vertex.hlsli", ST_LANG.INCLUDE_DIRECTORY));
    expect(state, instance != "" && sprite != "", tprint("标准 include 可读：instance=% sprite=%", instance.count, sprite.count));

    instance_needles: [7] string = .[ "struct OlibInstance {", "OLIB_INSTANCE_DATA(OLIB_INSTANCE_VARYING)",
                                      "#define InstanceTint (olib_instance.tint)", "struct OlibInstanceInput {",
                                      "float4x4 olib_world(OlibInstanceInput i)",
                                      "void olib_sprite_vertex(OlibInstanceInput i,",
                                      "OlibInstance olib_instance_from(OlibInstanceInput i)" ];
    for needle: instance_needles {
        expect(state, ST_STRING.contains(instance, needle), tprint("instance.hlsli 缺少 %", needle));
    }
    sprite_needles: [6] string = .[ "#ifdef OLIB_INSTANCE_SPRITE", "OlibInstanceInput Instance;", "_olib_view_axes",
                                    "StructuredBuffer<float4> OlibInstanceValues", "#if OLIB_INSTANCE_SLOTS > 0",
                                    "OlibSprite olib_sprite(OlibSpriteInput i)" ];
    for needle: sprite_needles {
        expect(state, ST_STRING.contains(sprite, needle), tprint("sprite_vertex.hlsli 缺少 %", needle));
    }
}

// D3D12 的两条规则在解析时报错并指向源码行：实例输入在前、传给片元的成员都要用到。
shader_d3d12_rules_point_at_the_offending_line :: (state: *Test_State) {
    doc := ST_LANG.parse(SHADER_SWARM, "swarm.oshader");
    expect(state, doc.error == "", tprint("合规的实例输入应通过：\"%\"", doc.error));
    ST_LANG.dispose(*doc);

    // 网格属性写在实例输入前面：报在第一个成员那一行。
    moved := shader_test_replace(SHADER_SWARM, SHADER_SWARM_INPUT_HEAD, SHADER_SWARM_INPUT_MOVED);
    doc = ST_LANG.parse(moved, "swarm.oshader");
    expect(state, ST_STRING.begins_with(doc.error, "swarm.oshader:6:1:") &&
                   ST_STRING.contains(doc.error, "Input must start with OlibInstanceInput"), tprint("实例输入必须在最前（第 6 行）：\"%\"", doc.error));
    ST_LANG.dispose(*doc);

    // 不是 instanced 的模型没有实例输入，不检查顺序。
    plain := shader_test_replace(moved, "Instanced\n", "");
    doc = ST_LANG.parse(plain, "swarm.oshader");
    expect(state, !ST_STRING.contains(doc.error, "must start with"), tprint("非 instanced 不检查实例输入顺序：\"%\"", doc.error));
    ST_LANG.dispose(*doc);

    // Normal 传给片元却没用到（注释里的 v.Normal 不算）：报在 Output 的这个成员。
    unused := shader_test_replace(SHADER_SWARM, "return float4(v.Normal, 1) * InstanceTint;",
                                  "return InstanceTint; // v.Normal");
    doc = ST_LANG.parse(unused, "swarm.oshader");
    expect(state, ST_STRING.begins_with(doc.error, "swarm.oshader:11:1:") &&
                   ST_STRING.contains(doc.error, "Output.Normal is passed to fragment_main but never used"), tprint("未使用的片元输入（第 11 行）：\"%\"", doc.error));
    ST_LANG.dispose(*doc);

    // 整个输入交给别的函数时无法判断，不报错。
    whole := shader_test_replace(unused, "olib_instance = v.Instance;", "olib_instance = v.Instance; shade(v);");
    doc = ST_LANG.parse(whole, "swarm.oshader");
    expect(state, !ST_STRING.contains(doc.error, "never used"), tprint("整个输入传给别的函数时不报错：\"%\"", doc.error));
    ST_LANG.dispose(*doc);

    // 精灵：Input 以 OlibSpriteInput 开头。
    doc = ST_LANG.parse(SHADER_SPRITE_BAD, "glow.oshader");
    expect(state, ST_STRING.contains(doc.error, "Input must start with OlibSpriteInput"), tprint("精灵输入必须以 OlibSpriteInput 开头：\"%\"", doc.error));
    ST_LANG.dispose(*doc);

    shader_test_free(moved);
    shader_test_free(plain);
    shader_test_free(unused);
    shader_test_free(whole);
}

shader_explicit_skinned_model_and_illegal_combinations :: (state: *Test_State) {
    doc := ST_LANG.parse(SHADER_SKIN, "skin.oshader");
    expect(state, doc.error == "", tprint("显式 Skinned 声明应解析成功：\"%\"", doc.error));
    if doc.error != "" {
        ST_LANG.dispose(*doc);
        return;
    }
    expect(state, doc.shader.skinned && !doc.shader.instanced, "skinned 且非 instanced");
    expect(state, doc.instanced_programs[0] == "", "skinned 没有缓冲变体");
    expect(state, ST_STRING.contains(doc.programs[0], "#include \"olib/skinning.hlsli\""), "保留作者 include");
    shader_test_expect_bytes(state, doc.programs[0], GOLDEN_SKIN_PROGRAM_0, "Skin 的完整 HLSL");
    ST_LANG.dispose(*doc);

    changes: [..] Shader_Test_Change;
    array_add(*changes, Shader_Test_Change.{ "Draw Model", "Draw Sprite" });
    array_add(*changes, Shader_Test_Change.{ "Draw Model", "Draw Preview_Model" });
    array_add(*changes, Shader_Test_Change.{ "Draw Model", "Draw Fullscreen" });
    array_add(*changes, Shader_Test_Change.{ "Skinned\n", "Skinned\nInstanced\n" });
    array_add(*changes, Shader_Test_Change.{ "Skinned\n",
                                             "Skinned\nProperties { [Instance] _X (\"X\", Float) = 1 }\n" });
    array_add(*changes, Shader_Test_Change.{ "Skinned\n", "Skinned\nSkinned\n" });
    array_add(*changes, Shader_Test_Change.{ "OlibSkinnedInput Skin;",
                                             "float3 Extra : TEXCOORD6; OlibSkinnedInput Skin;" });
    for change: changes {
        bad := shader_test_replace(SHADER_SKIN, change.from, change.to);
        invalid := ST_LANG.parse(bad, "skin.oshader");
        expect(state, invalid.error != "", tprint("必须拒绝 %：\"%\"", change.to, invalid.error));
        ST_LANG.dispose(*invalid);
        shader_test_free(bad);
    }

    // 也允许直接用完整引擎接口作为入口参数。
    direct := shader_test_replace(SHADER_SKIN, "vertex_main(Input v)", "vertex_main(OlibSkinnedInput v)");
    direct_doc := ST_LANG.parse(shader_test_replace(direct, "v.Skin", "v"), "direct.oshader");
    expect(state, direct_doc.error == "", tprint("直接以 OlibSkinnedInput 作参数也应合法：\"%\"", direct_doc.error));
    ST_LANG.dispose(*direct_doc);
    shader_test_free(direct);
}

shader_skinning_include_abi_and_helpers :: (state: *Test_State) {
    text := shader_test_read(tprint("%/olib/skinning.hlsli", ST_LANG.INCLUDE_DIRECTORY));
    expect(state, text != "", tprint("skinning.hlsli 可读（% 字节）", text.count));
    if text == "" return;

    declarations: [6] string = .[ "float3 position", "float3 normal", "float2 uv", "float4 tangent", "uint4 joints",
                                   "float4 weights" ];
    for declaration, i: declarations {
        line := tprint("[[vk::location(%)]] % : TEXCOORD%;", i, declaration, i);
        expect(state, ST_STRING.contains(text, line), tprint("skinning.hlsli 缺少 %", line));
    }

    required: [14] string = .[ "#include \"model.hlsli\"", "register(b2, space1)", "register(b3, space1)",
                                "float4x4 OlibJoints0[64]", "float4x4 OlibJoints1[64]", "if (index >= 128)",
                                "if (index < 64)", "OlibJoints1[index - 64]", "if (total <= 0)", "weights /= total;",
                                "mul(float4(v.position, 1), skin)", "mul(v.normal, (float3x3)skin)",
                                "mul(v.tangent.xyz, (float3x3)skin)", "direction * rsqrt(length_squared)" ];
    for needle: required {
        expect(state, ST_STRING.contains(text, needle), tprint("skinning.hlsli 缺少 %", needle));
    }
    expect(state, !ST_STRING.contains(text, "v.tangent.w ="), "不改写切线手性");
}
//@endregion

//@region compile/compile_test.odin

shader_commands_preserve_both_stages_and_other_backends :: (state: *Test_State) {
    tc: ST_COMP.Toolchain;
    tc.options.dxil = .Direct;
    tc.identity.shadercross.path = "shadercross";
    tc.identity.dxc.path = "dxc";

    stages: [2] string = .[ "vertex", "fragment" ];
    for stage: stages {
        rows := ST_COMP.commands(tc, "source with spaces.hlsl", "includes", stage, "output", true, true, temp);
        expect(state, rows.count == 3, tprint("% 阶段生成三条命令：%", stage, rows.count));
        if rows.count == 3 {
            expect(state, rows[0][0] == "shadercross", "第一条走 shadercross");
            expect(state, rows[0][5] == "SPIRV", "先出 SPIR-V");
            expect(state, rows[1][0] == "dxc", "Direct 的第二条走 dxc");
            expect(state, rows[1][1] == "source with spaces.hlsl", "源码参数原样传递（含空格）");
            profile := "ps_6_0";
            if stage == "vertex" profile = "vs_6_0";
            expect(state, rows[1][3] == profile, tprint("% 的 dxc profile 是 %", stage, profile));
            expect(state, rows[1][5] == tprint("%_main", stage), "dxc 入口名");
            expect(state, rows[2][1] == "output.spv", "MSL 由 SPIR-V 生成");
            expect(state, rows[2][5] == "MSL", "第三条输出 MSL");
        }
    }

    tc.options.dxil = .Spirv;
    legacy := ST_COMP.commands(tc, "source", "include", "vertex", "output", true, true, temp);
    expect(state, legacy.count == 3, "Spirv 策略也是三条命令");
    if legacy.count == 3 {
        expect(state, legacy[1][0] == "shadercross", "Spirv 策略的 DXIL 走 shadercross");
        expect(state, legacy[1][1] == "output.spv", "由 SPIR-V 转 DXIL");
        expect(state, legacy[1][5] == "DXIL", "目标是 DXIL");
    }

    // 不忽略二进制里的 CR。
    with_cr := "a\rb";
    without_cr := "ab";
    expect(state, ST_COMP.bytes_hash(cast([] u8) with_cr, temp) != ST_COMP.bytes_hash(cast([] u8) without_cr, temp),
           "bytes_hash 区分 CR");
}

shader_missing_compiler_is_an_error_without_fallback :: (state: *Test_State) {
    _, error := ST_COMP.identify(ST_COMP.Options.{ dxil = .Direct, shadercross = "/olib_missing/shadercross" }, temp);
    expect(state, error != "", tprint("找不到 shadercross 时 identify 报错：\"%\"", error));

    diagnostic := ST_COMP.run(.[ "olib_nonexistent_shader_compiler_9b6" ]);
    expect(state, ST_STRING.contains(diagnostic, "Shader compiler failed"), tprint("run 的失败诊断带完整命令：\"%\"", diagnostic));
}

// olib 的这个用例要真的跑 shadercross/dxc，并对 DXIL 签名做 -dumpbin 比对。
// jfoster/JaiLib 不带这条工具链，所以这里只断言「诊断路径」：绝不假装编译成功。
shader_sparse_signatures_and_portable_outputs :: (state: *Test_State) {
    options := ST_COMP.Options.{ dxil = .Direct };
    tc, identify_error := ST_COMP.identify(options, temp);
    if identify_error != "" {
        // 没有工具链：identify 明确报错，identity 保持空。
        expect(state, ST_STRING.contains(identify_error, "Cannot find compiler"), tprint("缺少工具链时给出 Cannot find compiler：\"%\"", identify_error));
        expect(state, tc.identity.shadercross.path == "" && tc.identity.dxc.path == "",
               "identify 失败时不返回半截 identity");
    } else {
        // 有工具但没有注入执行器：stage_compile / reflect 同样明确失败。
        stage := ST_COMP.stage_compile(tc, "Sparse.hlsl", ".", "vertex",
                                       tprint("%/sparse/vertex", shader_test_root()), true, true);
        expect(state, ST_STRING.contains(stage, "Shader compiler failed") &&
                       ST_STRING.contains(stage, ST_COMP.COMPILER_UNAVAILABLE), tprint("未注入执行器时 stage_compile 明确失败：\"%\"", stage));
        reflection := ST_COMP.reflect(tc, "vertex.spv", "vertex", "vertex.json");
        expect(state, ST_STRING.contains(reflection, ST_COMP.COMPILER_UNAVAILABLE), tprint("未注入执行器时 reflect 明确失败：\"%\"", reflection));
    }

    // 无论上面走哪条路径：没有执行器时 run 一定给出 COMPILER_UNAVAILABLE。
    diagnostic := ST_COMP.run(.[ "shadercross", "-s", "HLSL", "-d", "SPIRV" ]);
    expect(state, ST_STRING.contains(diagnostic, "no external process runner") &&
                   ST_STRING.contains(diagnostic, ST_COMP.COMPILER_UNAVAILABLE), tprint("默认 run 返回 COMPILER_UNAVAILABLE：\"%\"", diagnostic));
    expect(state, ST_COMP.command_runner == null, "默认没有注入执行器");
}

shader_tool_identity_covers_executable_and_sibling_libraries :: (state: *Test_State) {
    root := shader_test_fresh_dir("identity");
    exe := tprint("%/compiler.exe", root);
    lib := tprint("%/compiler.dll", root);
    expect(state, shader_test_write(exe, "executable A"), "写出 executable A");
    expect(state, shader_test_write(lib, "library A"), "写出 library A");

    a, error := ST_COMP.identify(ST_COMP.Options.{ shadercross = exe }, temp);
    expect(state, error == "", tprint("identify 成功：\"%\"", error));
    if error == "" {
        expect(state, ST_STRING.contains(a.identity.shadercross.version, "distribution-fnv1a64:"), tprint("工具身份是内容指纹：\"%\"", a.identity.shadercross.version));
        expect(state, a.identity.policy == ST_COMP.POLICY, "identity 带上 POLICY");
        expect(state, a.identity.dxil == "spirv", "默认策略标记为 spirv");

        expect(state, shader_test_write(lib, "library B"), "改写 library B");
        b, _ := ST_COMP.identify(ST_COMP.Options.{ shadercross = exe }, temp);
        expect(state, a.identity.shadercross.version != b.identity.shadercross.version,
               "相邻动态库变化会改变工具身份");

        expect(state, shader_test_write(exe, "executable B"), "改写 executable B");
        c, _ := ST_COMP.identify(ST_COMP.Options.{ shadercross = exe }, temp);
        expect(state, b.identity.shadercross.version != c.identity.shadercross.version,
               "可执行文件变化会改变工具身份");
    }

    _, missing := ST_COMP.identify(ST_COMP.Options.{ shadercross = exe, dxil = .Direct, dxc = "/olib_missing/dxc" },
                                   temp);
    expect(state, missing != "", tprint("缺少 dxc 时 identify 报错：\"%\"", missing));
}
//@endregion

//@region dev/compiler_test.odin

shader_failed_compile_has_no_success_provenance :: (state: *Test_State) {
    result := ST_DEV.compile("/olib_missing/Sparse.hlsl", "dxil", "",
                             ST_COMP.Options.{ dxil = .Direct, shadercross = "/olib_missing/shadercross" });
    expect(state, result.error != "" && result.provenance == "", tprint("失败时没有 provenance：\"%\"", result.error));
    expect(state, result.code[0].count == 0 && result.code[1].count == 0, "失败时没有产物字节");
    ST_DEV.build_dispose(*result);
}

// olib 的这个用例在 OLIB_SHADER_COMPILER_TESTS=1 时真跑编译器并读资源反射。
// 这里没有工具链：三种 format 都必须明确失败，且不留下产物/provenance。
shader_dev_sparse_pair_and_resource_reflection :: (state: *Test_State) {
    root := shader_test_fresh_dir("sparse");
    source := tprint("%/Sparse.hlsl", root);
    expect(state, shader_test_write(source, "float4 vertex_main() : SV_Position { return 0; }\n"), "写出 Sparse.hlsl");

    formats: [3] string = .[ "dxil", "spv", "msl" ];
    for format: formats {
        result := ST_DEV.compile(source, format, "", ST_COMP.Options.{ dxil = .Direct });
        expect(state, result.error != "", tprint("% 在没有工具链时必须失败", format));
        expect(state, result.provenance == "", tprint("% 失败时不写 provenance", format));
        expect(state, result.code[0].count == 0 && result.code[1].count == 0, tprint("% 失败时没有产物", format));
        ST_DEV.build_dispose(*result);
    }

    unsupported := ST_DEV.compile(source, "pexe", "");
    expect(state, ST_STRING.contains(unsupported.error, "Unsupported shader format"), tprint("未知 format 直接拒绝：\"%\"", unsupported.error));
    ST_DEV.build_dispose(*unsupported);
}

shader_session_owns_compiler_path_options :: (state: *Test_State) {
    path: [3] u8 = .[ #char "d", #char "x", #char "c" ];
    view: [] u8 = .{ 3, cast(*u8) *path };
    dxc := cast(string) view;
    s: ST_DEV.Session;
    expect(state, ST_DEV.init(*s, "missing/Sparse.hlsl", ST_F.Graphics_Driver.VULKAN, ST_DEV.Resources.{},
                              ST_DEV.Resources.{}, ST_COMP.Options.{ dxc = dxc }),
           "init 成功（源文件不必存在）");
    path[0] = #char "X";
    shader_test_expect_value(state, s.compiler_options.dxc, "dxc");
    ST_DEV.dispose(*s);
}
//@endregion

//@region dev/dev_test.odin

shader_source_changes_include_same_length_and_deletion :: (state: *Test_State) {
    root := shader_test_fresh_dir("fingerprint");
    sub := tprint("%/include", root);
    ST_FILE.make_directory_if_it_does_not_exist(sub, true);
    file := tprint("%/math.hlsli", sub);
    ignored := tprint("%/notes.txt", root);

    expect(state, shader_test_write(file, "AAA"), "写出 math.hlsli");
    a, ok := ST_DEV.source_fingerprint(root);
    expect(state, ok, "指纹可算");

    expect(state, shader_test_write(file, "BBB"), "同长度改写");
    b, _ := ST_DEV.source_fingerprint(root);
    expect(state, a != b, "同长度内容变化改变指纹");

    expect(state, shader_test_write(ignored, "ignored"), "写出无关的 .txt");
    c, _ := ST_DEV.source_fingerprint(root);
    expect(state, b == c, "非 shader 文件不参与指纹");

    ST_FILE.file_delete(file);
    d, _ := ST_DEV.source_fingerprint(root);
    expect(state, c != d, "删除文件改变指纹");
}

shader_reject_stale_candidate_without_touching_live_state :: (state: *Test_State) {
    s: ST_DEV.Session;
    expect(state, ST_DEV.init(*s, "missing/shader.hlsl", ST_F.Graphics_Driver.VULKAN, ST_DEV.Resources.{},
                              ST_DEV.Resources.{}), "init 成功");
    s.status = .Ready;
    s.revision = 7;
    s.has_attempted = true;

    probes: [] ST_F.Draw_Command;
    expect(state, !ST_DEV.apply(*s, null, probes), "过期候选不能被 apply");
    expect(state, s.status == .Waiting && s.revision == 7 && !s.has_attempted,
           "拒绝过期候选只回到 Waiting，不改 revision");
    ST_DEV.dispose(*s);
}

shader_safe_creation_reports_errors_without_gpu :: (state: *Test_State) {
    // olib 还断言 foster.ShaderTryInit 失败后 shader.Resource == nil；jfoster 没有
    // ShaderTryInit（shader_create 要 *Graphics_Device），该断言未移植（见报告）。
    s: ST_DEV.Session;
    expect(state, !ST_DEV.init(*s, "shader.hlsl", ST_F.Graphics_Driver.NONE, ST_DEV.Resources.{},
                               ST_DEV.Resources.{}), "没有图形后端时 init 失败");
    expect(state, ST_STRING.contains(s.diagnostic, "requires"), tprint("诊断说明需要 Vulkan/D3D12/Metal：\"%\"", s.diagnostic));
    ST_DEV.dispose(*s);
}

// dev.Session.apply 是未实现的 seam：候选有效、资源契约一致，也必须返回 false 并给出固定诊断，
// 绝不把 status 推进到 Live、绝不改 revision。
shader_apply_reports_unimplemented_seam :: (state: *Test_State) {
    root := shader_test_fresh_dir("seam");
    source := tprint("%/seam.oshader", root);
    expect(state, shader_test_write(source, SHADER_SINGLE_FILE), "写出 seam.oshader");

    s: ST_DEV.Session;
    expect(state, ST_DEV.init(*s, source, ST_F.Graphics_Driver.VULKAN, ST_DEV.Resources.{},
                              ST_DEV.Resources.{}), "init 成功");
    // 让候选看起来是当前源码编译出来的（不启动后台线程）。
    current, readable := ST_DEV.session_fingerprint(*s);
    expect(state, readable, "指纹可算");
    s.job.fingerprint = current;
    s.job.source = copy_string(s.source);
    s.job.result = ST_DEV.Build.{};
    s.status = .Ready;
    s.revision = 3;

    probes: [] ST_F.Draw_Command;
    expect(state, !ST_DEV.apply(*s, null, probes), "apply 在 jfoster 上必须失败");
    shader_test_expect_value(state, s.diagnostic, ST_DEV.SHADER_PAIR_REPLACE_UNAVAILABLE);
    expect(state, s.status == .Error && s.revision == 3 && s.vertex == null && s.fragment == null,
           "seam 不推进到 Live、不改 revision、不造 Shader");
    ST_DEV.dispose(*s);
}
//@endregion

//@region dev/shader_files_test.odin

shader_single_file_build_snapshot_and_stale_watch_result :: (state: *Test_State) {
    root := shader_test_fresh_dir("files");
    path := tprint("%/single.oshader", root);
    expect(state, shader_test_write(path, SHADER_SINGLE_FILE), "写出 single.oshader");

    before, ok := ST_DEV.parameters_fingerprint(root);
    expect(state, ok, "包指纹可算");
    // Odin 声明已退出发现流程：即使同目录存在无效 Odin 文件，也不解析或执行。
    expect(state, shader_test_write(tprint("%/unused.odin", root), "not an Odin package"), "写出无关的 .odin");
    ignored, _ := ST_DEV.parameters_fingerprint(root);
    expect(state, ignored == before, ".odin 不参与包指纹");

    build := ST_DEV.parameters_compile(root);
    expect(state, build.error == "", tprint("候选包应编译成功：\"%\"", build.error));
    if build.error == "" {
        expect(state, build.schemas.count == 1 && build.shaders.count == 1 && build.programs.count == 1,
               "一个 Pass => 一份 schema/shader/program");
        shader_test_expect_value(state, build.programs[0].group, "Single_main");
        shader_test_expect_value(state, build.schemas[0].shader, "single.oshader");
        expect(state, build.schemas[0].fields[0].initial[0] == cast(float32) 0.2, "参数默认值来自 .oshader");

        changed := shader_test_replace(SHADER_SINGLE_FILE, "0.2", "0.3");
        expect(state, shader_test_write(path, changed), "改写 single.oshader");
        after, _ := ST_DEV.parameters_fingerprint(root);
        expect(state, before != after && build.schemas[0].fields[0].initial[0] == cast(float32) 0.2,
               "改源码改变指纹，但已编译的候选不受影响");
        shader_test_free(changed);

        // 后台监听：候选过期时 take 必须给空包。
        watch: ST_DEV.Parameter_Watch;
        ST_DEV.parameters_init(*watch, root);
        watch.status = .Ready;
        watch.job.fingerprint = before;
        stale := ST_DEV.parameters_take(*watch);
        expect(state, stale.schemas.count == 0, "过期候选不会被 take");
        ST_DEV.parameter_build_dispose(*stale);
        ST_DEV.parameters_dispose(*watch);

        // 编译已提取的程序（不重新读取被修改的属性）。没有 shadercross/dxc 时只断言诊断：
        // 原用例还要求错误文本指向 single.oshader 的 missing_symbol——没有工具链无法验证。
        compiled := ST_DEV.compile(path, "spv", build.programs[0].text);
        expect(state, compiled.error != "" && compiled.provenance == "", tprint("无工具链时编译明确失败（不假装成功）：\"%\"", compiled.error));
        ST_DEV.build_dispose(*compiled);

        // includes 变化也使整包候选过期。
        expect(state, shader_test_write(tprint("%/common.hlsli", root), "// changed"), "写出 common.hlsli");
        include_hash, _ := ST_DEV.parameters_fingerprint(root);
        expect(state, include_hash != after, ".hlsli 变化改变包指纹");

        expect(state, shader_test_write(tprint("%/duplicate.oshader", root), SHADER_SINGLE_FILE),
               "写出重复的 .oshader");
        duplicate := ST_DEV.parameters_compile(root);
        expect(state, ST_STRING.contains(duplicate.error, "duplicate shader"), tprint("重复 Shader 名报错：\"%\"", duplicate.error));
        ST_DEV.parameter_build_dispose(*duplicate);

        ST_FILE.file_delete(path);
        ST_FILE.file_delete(tprint("%/duplicate.oshader", root));
        empty := ST_DEV.parameters_compile(root);
        expect(state, empty.error == "" && empty.schemas.count == 0 && empty.shaders.count == 0, tprint("没有 .oshader 时给出空包：\"%\"", empty.error));
        ST_DEV.parameter_build_dispose(*empty);
    }
    ST_DEV.parameter_build_dispose(*build);
}

// 编译目录里要有 olib 标准 include，且 olib/ 子目录能随临时目录一起删掉。
shader_snapshot_includes_copies_standard_include :: (state: *Test_State) {
    directory, created := ST_DEV.dev_temp_directory("olib_include_test_");
    expect(state, created, "创建临时目录");
    if !created return;

    expect(state, ST_DEV.dev_snapshot_includes(directory), "复制标准 include");
    names: [3] string = .[ "model.hlsli", "sprite.hlsli", "fullscreen.hlsli" ];
    for name: names {
        expect(state, ST_FU.file_exists(tprint("%/olib/%", directory, name)), tprint("缺少 olib/%", name));
    }

    ST_DEV.dev_remove_workspace(directory);
    expect(state, !ST_FU.file_exists(directory), "工作目录连同 olib/ 一起删掉");
}
//@endregion
