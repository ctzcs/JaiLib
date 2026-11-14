// lang —— 单文件 Shader 描述：声明式参数、Pass 与原样 HLSL；解析过程不读取文件、不创建设备或执行 GPU 操作。
// 一比一移植自 olib kit/rendering/shader/lang/lang.odin。
//
// .oshader 的语法、每个 Pass 生成的 HLSL、参数打包是**字节级契约**：本文件的
// shader_programs / shader_program 产出的文本（首行注释、缩进、#line 指令、
// VideoRegister 风格绑定点、swizzle、include 顺序）与 olib 逐字节相同，
// 用 olib tests/kit/rendering/shader/lang/lang_test.odin 的 SOURCE 比对过。
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                                | JaiLib (Jai)                                        |
//   | ------------------------------------------ | --------------------------------------------------- |
//   | INCLUDE_DIRECTORY :: #directory + "/include"| INCLUDE_DIRECTORY :: #filepath + "include"          |
//   |   （#directory 不带结尾分隔符）               |   （jacket 的 #filepath 是当前文件目录、**带**结尾分隔符）|
//   | 全部内部数据放 mem.Dynamic_Arena             | push_allocator(temp)，结束时按调用方 allocator 重建   |
//   | map[string]bool（seen / attributes）        | [..] string + lang_list_has（指令数很少，线性查找）    |
//   | switch key { case "...": }                 | if / else if 链（字符串键顺序无关）                    |
//   | strconv.unquote_string(s)                  | lang_unquote（同样是「非法转义 -> ok=false」）        |
//   | strconv.parse_f32(s)                       | string_to_float32（Basic，ok=false 语义相同）         |
//   | math.is_nan / math.is_inf                   | JM.isnan / JM.isinf                                 |
//   | math.floor                                  | floor（Basic）                                      |
//   | reflect.enum_from_name(T, name)            | enum_names / enum_values_as_s64（Basic 的枚举反射）   |
//   | strings.Builder + fmt.sbprintf              | String_Builder + print_to_builder                   |
//   | strings.replace_all(path, "\\", "/")        | STRING.replace（总是新分配，归 temp）                 |
//   | fmt.sbprintf("%q", path)                    | lang_quoted（转义规则同 odin 的 %q：引号与反斜杠）      |
//   | strings.split / trim_space / has_prefix     | STRING.split / trim / begins_with                   |
//   | strings.index_byte / last_index_byte / count | lang_index_of / lang_last_index_of / lang_count    |
//   | 字符串切片 s[a:]，raw_data                   | 手动构造 string.{count, data + a}（Jai 无切片语法）   |
//   | @(private) 顶层过程                          | 加 lang_ 前缀（Jai 没有 private，聚合后要防重名）       |
//   | 命名的命名返回值 (`-> (pass, code, dim)`)     | 多返回值；名字写在各过程上方的注释里                     |
//   | 过程内嵌套 proc（lang_test 里的 read）        | 提到模块级 lang_* 过程                                |
#import "Basic";

// 标准 include 的根目录：作者写 #include "olib/<Draw>.hlsli"（model / sprite / fullscreen），引擎 b0 块都声明在那里。
// shadercross 只接受一个 -I，tools/shaders 与 Shader Lab 编译前把 <INCLUDE_DIRECTORY>/olib 复制到各自的临时目录。
// odin 是编译期常量 `#directory + "/include"`；Jai 的 string 没有 `+`、也没有编译期字符串拼接，
// 所以改成「全局变量 + 启动期初始化」，运行期值完全相同（jakcet 的 #filepath 带结尾分隔符，
// odin 的 #directory 不带，因此这里不再补 "/"）。
INCLUDE_DIRECTORY: string = tprint("%include", #filepath);

Document :: struct {
    schemas: [] sh.Schema;
    shader: sh.Shader_Desc;
    // 与 schemas 一一对应，已包含参数布局、共享代码和原文件 #line。
    // Sprite Pass 的 programs 是批量变体（foster BatcherVertex 输入，Render2D 逐个绘制用）；
    // instanced Shader 另有 instanced_programs：缓冲变体（实例记录 + 角点，常驻 Sprite_Buffer 用），只需编译顶点阶段。
    // 其他 Pass 或非 instanced Shader 对应项为空串。
    programs: [] string;
    instanced_programs: [] string;
    error: string;
}

dispose :: (d: *Document) {
    for *s: d.schemas {
        sh.schema_dispose(s);
    }
    if d.schemas.data != null free(d.schemas.data);
    sh.shader_dispose(*d.shader);
    for text: d.programs lang_free_string(text);
    if d.programs.data != null free(d.programs.data);
    for text: d.instanced_programs lang_free_string(text);
    if d.instanced_programs.data != null free(d.instanced_programs.data);
    lang_free_string(d.error);
    d.* = Document.{};
}

Token :: struct {
    text: string;
    quoted: bool;
    line, column: int;
}

Parser :: struct {
    text, path: string;
    pos: int;
    line, column: int;
    token: Token;
    error: string;
}

Hlsl_Code :: struct {
    text: string;
    line: int;
}

// 顶层 Shader { ... } 解析出的原始部分；passes 与 codes、previews 一一对应。
Shader_Source :: struct {
    shader: sh.Shader_Desc;
    fields: [] sh.Field;
    passes: [..] sh.Pass_Desc;
    codes: [..] Hlsl_Code;
    previews: [..] string; // 每个 Pass 显式声明的预览维度，空值由 shader_programs 推断。
    shared: Hlsl_Code; // HLSLINCLUDE 共享代码。
}

// source_path 同时写入诊断和 HLSL #line；返回文档独立拥有全部数据。
// 返回 Document；成功时 error 为空串。
parse :: (text: string, source_path: string, allocator_in: Allocator = context.allocator) -> Document {
    // odin 的 context.allocator 是隐式的；Jai 侧显式收尾参数。默认参数在函数体首次使用时求值，
    // 必须在 push_allocator 之前捕获。
    allocator := allocator_in;
    error_message: string;
    source: Shader_Source;
    schemas: [] sh.Schema;
    programs: [] string;
    instanced_programs: [] string;

    // ---- 解析阶段：全部中间数据落在 temp（对应 odin 的 Dynamic_Arena）。
    // jacket 的 push_allocator 是「作用域内生效」（自带 defer），所以用一个内嵌块把临时分配收起来。
    {
        push_allocator(temp);
        p := Parser.{ text = text, path = source_path, line = 1, column = 1 };
        lang_next(*p);
        lang_expect(*p, "Shader");
        name := lang_string_value(*p);
        if !lang_identifier(name) {
            lang_fail(*p, "Shader name must be an identifier; use Label for display names");
        }
        source = shader_body(*p, name);
        for pass, i: source.passes {
            hlsl_rules_check(*p, pass, source.shader.instanced, source.shader.skinned, source.shared,
                             source.codes[i]);
        }
        schemas, programs, instanced_programs = shader_programs(*source, name, source_path);
        if p.error == "" {
            order, error := sh.shader_order(source.shader, schemas);
            if order.data != null free(order.data);
            if error != "" lang_fail(*p, error);
        }
        error_message = p.error;
    }

    // ---- 所有权阶段：按调用方 allocator 重建（对应 odin 的 arena -> clone）。
    push_allocator(allocator);
    result: Document;
    if error_message != "" {
        result.error = copy_string(error_message);
        return result;
    }
    result.shader = sh.shader_clone(source.shader);
    result.schemas = sh.shader_alloc_array(sh.Schema, schemas.count);
    result.programs = sh.shader_alloc_array(string, programs.count);
    result.instanced_programs = sh.shader_alloc_array(string, programs.count);
    for s, i: schemas {
        result.schemas[i] = sh.schema_clone(s);
        result.programs[i] = copy_string(programs[i]);
        result.instanced_programs[i] = copy_string(instanced_programs[i]);
    }
    return result;
}

// 解析 `{ 指令... }`：每个指令至多一次（Pass 除外），并补全默认 Output。
shader_body :: (p: *Parser, name: string) -> Shader_Source {
    lang_expect(p, "{");
    source: Shader_Source;
    source.shader = sh.Shader_Desc.{ name = name };
    seen: [..] string;
    while p.error == "" && p.token.text != "}" {
        key := p.token.text;
        if key != "HLSLINCLUDE" lang_next(p);
        if key != "Pass" && lang_list_has(seen, key) {
            lang_fail(p, "Duplicate Shader directive");
            break;
        }
        array_add(*seen, key);
        if key == "Label" {
            source.shader.label = lang_string_value(p);
        } else if key == "Preview" {
            source.shader.preview = lang_preview(p);
        } else if key == "Output" {
            source.shader.output = lang_string_value(p);
        } else if key == "Instanced" {
            source.shader.instanced = true;
        } else if key == "Skinned" {
            source.shader.skinned = true;
        } else if key == "Properties" {
            source.fields = properties(p);
        } else if key == "HLSLINCLUDE" {
            source.shared = lang_code_block(p);
        } else if key == "Pass" {
            pass, code, dimension := pass_block(p);
            array_add(*source.passes, pass);
            array_add(*source.codes, code);
            array_add(*source.previews, dimension);
        } else {
            lang_fail(p, "Expected Properties, Pass, HLSLINCLUDE, Label, Preview, Output, Instanced or Skinned");
        }
    }
    lang_expect(p, "}");
    if p.token.text != "" {
        lang_fail(p, "Unexpected content after Shader");
    }
    if source.passes.count == 0 {
        lang_fail(p, "Shader requires at least one Pass");
    }
    if source.shader.output == "" && source.passes.count > 0 {
        source.shader.output = source.passes[source.passes.count - 1].output;
    }
    for field: source.fields source.shader.instanced = source.shader.instanced || field.instance;
    source.shader.passes = source.passes;
    return source;
}

// 每个 Pass 一份参数组 Schema 和候选 HLSL（参数布局 + 共享代码 + Pass 代码，带原文件 #line）。
// 会把 Pass 的 params 指向生成的组名 `<Shader>_<Pass>`。Sprite Pass 生成批量变体，instanced Shader 再生成缓冲变体。
// 返回 (schemas, programs, instanced_programs)，三者一一对应。
shader_programs :: (source: *Shader_Source, name, source_path: string) -> ([] sh.Schema, [] string, [] string) {
    schemas := sh.shader_alloc_array(sh.Schema, source.passes.count);
    programs := sh.shader_alloc_array(string, source.passes.count);
    instanced_programs := sh.shader_alloc_array(string, source.passes.count);
    for *pass, i: source.passes {
        group := tprint("%_%", name, pass.id);
        pass.params = group;
        dimension := source.previews[i];
        if dimension == "" {
            dimension = "2d";
            if pass.draw == .Model dimension = "3d";
            if pass.draw == .Preview_Model && source.shader.preview != "" {
                dimension = source.shader.preview;
            }
        }
        schemas[i] = sh.Schema.{ name = group, shader = source_path, preview = dimension,
                                label = pass.label, fields = source.fields };
        if pass.draw == .Sprite {
            programs[i] = shader_program(source, i, schemas[i], .Sprite_Batch, source_path);
            if source.shader.instanced {
                instanced_programs[i] = shader_program(source, i, schemas[i], .Sprite, source_path);
            }
        } else {
            programs[i] = shader_program(source, i, schemas[i], sh.shader_instancing(source.shader), source_path);
        }
    }
    return schemas, programs, instanced_programs;
}

shader_program :: (source: *Shader_Source, index: int, schema: sh.Schema, mode: sh.Instancing,
                   source_path: string) -> string {
    b: String_Builder;
    print_to_builder(*b, "%", sh.hlsl(schema, mode));
    blocks: [2] Hlsl_Code = .[source.shared, source.codes[index]];
    for block: blocks {
        if block.text == "" continue;
        path, _ := STRING.replace(source_path, "\\", "/");
        print_to_builder(*b, "\n#line % %\n%\n", block.line, lang_quoted(path), block.text);
    }
    text := builder_to_string(*b);
    free_buffers(*b);
    return text;
}

//@region 属性与 Pass

properties :: (p: *Parser) -> [] sh.Field {
    lang_expect(p, "{");
    fields: [..] sh.Field;
    textures, instances := 0, 0;
    while p.error == "" && p.token.text != "}" {
        attributes := property_attributes(p);
        name := p.token.text;
        if p.token.quoted || !STRING.begins_with(name, "_") ||
           !lang_identifier(lang_slice(name, 1, name.count)) || STRING.begins_with(name, "_olib_") {
            lang_fail(p, "Property name must start with _ followed by an identifier; _olib_ is reserved");
            break;
        }
        lang_next(p);
        field := property_declaration(p, lang_slice(name, 1, name.count), attributes.id, attributes.step);
        field.instance = attributes.instance;
        field.filter = attributes.filter;
        field.wrap = attributes.wrap;
        field.filter_declared = attributes.filter_declared;
        field.wrap_declared = attributes.wrap_declared;
        if (field.filter_declared || field.wrap_declared) && field.kind != .Texture {
            lang_fail(p, "Filter and Wrap apply only to 2D properties");
        }
        if field.kind == .Texture textures += 1;
        if field.instance instances += 1;
        property_check(p, field, fields, textures, instances);
        array_add(*fields, field);
    }
    lang_expect(p, "}");
    return fields;
}

// 属性前的 [Id("...")] [Step(n)] [Instance] [Filter(Linear|Nearest)] [Wrap(Clamp|Repeat|Mirror)] 特性，
// 每种至多一次；Instance 没有参数。结果放在 Field 的 id/step/instance/filter/wrap 与 *_declared。
property_attributes :: (p: *Parser) -> sh.Field {
    result: sh.Field;
    result.step = 0.01;
    attributes: [..] string;
    while p.token.text == "[" && p.error == "" {
        lang_next(p);
        key := p.token.text;
        lang_next(p);
        if lang_list_has(attributes, key) {
            lang_fail(p, "Duplicate property attribute");
        }
        array_add(*attributes, key);
        if key == "Instance" {
            result.instance = true;
            lang_expect(p, "]");
            continue;
        }
        lang_expect(p, "(");
        if key == "Id" {
            result.id = lang_string_value(p);
        } else if key == "Step" {
            result.step = lang_number(p);
        } else if key == "Filter" {
            result.filter_declared = true;
            if p.token.text == "Linear" {
                result.filter = .Linear;
            } else if p.token.text == "Nearest" {
                result.filter = .Nearest;
            } else {
                lang_fail(p, "Filter must be Linear or Nearest");
            }
            lang_next(p);
        } else if key == "Wrap" {
            result.wrap_declared = true;
            if p.token.text == "Clamp" {
                result.wrap = .Clamp;
            } else if p.token.text == "Repeat" {
                result.wrap = .Repeat;
            } else if p.token.text == "Mirror" {
                result.wrap = .Mirror;
            } else {
                lang_fail(p, "Wrap must be Clamp, Repeat or Mirror");
            }
            lang_next(p);
        } else {
            lang_fail(p, "Expected Id, Step, Instance, Filter or Wrap attribute");
        }
        lang_expect(p, ")");
        lang_expect(p, "]");
    }
    return result;
}

// 解析 `(标签, 类型[(最小, 最大)]) = 默认值`；向量/颜色可显式指定控件范围，Float 默认 -10000..10000。
property_declaration :: (p: *Parser, name, id: string, step: float32) -> sh.Field {
    field: sh.Field;
    field.name = name;
    field.minimum = 0;
    field.maximum = 1;
    field.step = step;
    // odin: `field.id = id == "" ? field.name : id`；Jai 没有三目运算符。
    field.id = id;
    if field.id == "" field.id = field.name;
    lang_expect(p, "(");
    field.label = lang_string_value(p);
    lang_expect(p, ",");
    kind := p.token.text;
    lang_next(p);
    if kind == "Range" || kind == "Float" {
        field.kind = .Scalar;
    } else if kind == "Vector2" {
        field.kind = .Vector2;
    } else if kind == "Vector3" {
        field.kind = .Vector3;
    } else if kind == "Color" {
        field.kind = .Color;
    } else if kind == "2D" {
        field.kind = .Texture;
    } else {
        lang_fail(p, "Expected Range, Float, Vector2, Vector3, Color or 2D");
    }
    if kind == "Float" {
        field.minimum = -10000;
        field.maximum = 10000;
    }
    if kind == "Range" || p.token.text == "(" {
        if field.kind == .Texture {
            lang_fail(p, "Texture cannot have a numeric range");
        }
        lang_expect(p, "(");
        field.minimum = lang_number(p);
        lang_expect(p, ",");
        field.maximum = lang_number(p);
        lang_expect(p, ")");
    }
    lang_expect(p, ")");
    lang_expect(p, "=");
    if field.kind == .Texture {
        field.texture = lang_string_value(p);
    } else {
        field.initial = lang_vector(p, sh.components(field.kind));
    }
    return field;
}

// 范围、纹理数量、默认值区间，以及与已有属性的重名/采样器冲突。
property_check :: (p: *Parser, field: sh.Field, prior_fields: [] sh.Field, textures, instances: int) {
    if field.instance && field.kind == .Texture {
        lang_fail(p, "Texture cannot be Instance");
    }
    if instances > sh.MAX_INSTANCE_FIELDS {
        lang_fail(p, "More than 4 Instance properties");
    }
    if field.minimum > field.maximum || field.step <= 0 || textures > sh.MAX_TEXTURES {
        lang_fail(p, "Invalid property range/step or more than 16 textures");
    }
    for c: 0..sh.components(field.kind) - 1 {
        if field.initial[c] < field.minimum || field.initial[c] > field.maximum {
            lang_fail(p, "Property default is outside its range");
        }
    }
    for prior: prior_fields {
        if prior.id == field.id || prior.name == field.name {
            lang_fail(p, "Duplicate property name or Id");
        }
        if (prior.kind == .Texture && field.name == tprint("%Sampler", prior.name)) ||
           (field.kind == .Texture && prior.name == tprint("%Sampler", field.name)) {
            lang_fail(p, "Property collides with a generated sampler");
        }
    }
}

// 返回 (pass, code, dimension)；dimension 是该 Pass 显式声明的预览维度（空串表示由 shader_programs 推断）。
pass_block :: (p: *Parser) -> (sh.Pass_Desc, Hlsl_Code, string) {
    pass: sh.Pass_Desc;
    code: Hlsl_Code;
    dimension := "";
    pass.id = lang_string_value(p);
    if !lang_identifier(pass.id) {
        lang_fail(p, "Pass name must be an identifier");
    }
    pass.output = "color";
    lang_expect(p, "{");
    seen: [..] string;
    inputs: [..] sh.Pass_Input;
    values: [..] sh.Pass_Value;
    while p.error == "" && p.token.text != "}" {
        key := p.token.text;
        if key != "HLSLPROGRAM" lang_next(p);
        if key != "Input" && key != "Value" && lang_list_has(seen, key) {
            lang_fail(p, "Duplicate Pass directive");
            break;
        }
        array_add(*seen, key);
        if key == "Label" {
            pass.label = lang_string_value(p);
        } else if key == "Preview" {
            dimension = lang_preview(p);
        } else if key == "Draw" {
            pass.draw = lang_enum_value(p, sh.Pass_Draw);
        } else if key == "Cull" {
            pass.state.cull = lang_enum_value(p, sh.Pass_Cull);
        } else if key == "Blend" {
            pass.state.blend = lang_enum_value(p, sh.Pass_Blend);
        } else if key == "ZTest" {
            pass.state.depth = lang_enum_value(p, sh.Pass_Depth);
        } else if key == "ZWrite" {
            pass.state.depth_write = lang_enum_value(p, sh.Pass_Write);
        } else if key == "Disabled" {
            pass.disabled = lang_enum_value(p, sh.Pass_Write) == .On;
        } else if key == "Output" {
            pass.output = lang_string_value(p);
        } else if key == "SpriteTexture" {
            pass.sprite_texture = lang_field_ref(p);
        } else if key == "Target" {
            pass.target = target_block(p);
        } else if key == "Input" {
            input: sh.Pass_Input;
            input.field = lang_field_ref(p);
            input.target = lang_string_value(p);
            input.frame = lang_enum_value(p, sh.Pass_Frame);
            array_add(*inputs, input);
        } else if key == "Value" {
            value: sh.Pass_Value;
            value.field = lang_field_ref(p);
            value.number = lang_vector(p, 0);
            array_add(*values, value);
        } else if key == "HLSLPROGRAM" {
            code = lang_code_block(p);
        } else {
            lang_fail(p, "Unknown Pass directive");
        }
    }
    lang_expect(p, "}");
    if STRING.trim(code.text) == "" {
        lang_fail(p, "Pass requires a nonempty HLSLPROGRAM");
    }
    pass.inputs = inputs;
    pass.values = values;
    return pass, code, dimension;
}

target_block :: (p: *Parser) -> sh.Target_Desc {
    target: sh.Target_Desc;
    lang_expect(p, "{");
    seen: [..] string;
    while p.error == "" && p.token.text != "}" {
        key := p.token.text;
        lang_next(p);
        if lang_list_has(seen, key) {
            lang_fail(p, "Duplicate Target directive");
        }
        array_add(*seen, key);
        if key == "Scale" {
            target.scale = lang_number(p);
        } else if key == "Format" {
            target.format = lang_enum_value(p, sh.Target_Format);
        } else if key == "Depth" {
            target.depth = lang_enum_value(p, sh.Pass_Write) == .On;
        } else if key == "Samples" {
            target.samples = lang_integer(p);
        } else if key == "Size" {
            target.width = lang_integer(p);
            target.height = lang_integer(p);
        } else if key == "Clear" {
            target.clear = lang_vector(p, 4);
        } else {
            lang_fail(p, "Unknown Target directive");
        }
    }
    lang_expect(p, "}");
    return target;
}
//@endregion

//@region 词法与诊断

lang_fail :: (p: *Parser, message: string) {
    if p.error == "" {
        p.error = tprint("%:%:%: % (at '%')", p.path, p.token.line, p.token.column, message, p.token.text);
    }
}

lang_advance :: (p: *Parser) {
    if p.pos >= p.text.count {
        return;
    }
    if p.text[p.pos] == #char "\n" {
        p.line += 1;
        p.column = 1;
    } else {
        p.column += 1;
    }
    p.pos += 1;
}

lang_next :: (p: *Parser) {
    if p.error != "" {
        return;
    }
    while p.pos < p.text.count {
        c := p.text[p.pos];
        if c == #char " " || c == #char "\t" || c == #char "\r" || c == #char "\n" {
            lang_advance(p);
        } else if STRING.begins_with(lang_slice(p.text, p.pos, p.text.count), "//") {
            while p.pos < p.text.count && p.text[p.pos] != #char "\n" {
                lang_advance(p);
            }
        } else if STRING.begins_with(lang_slice(p.text, p.pos, p.text.count), "/*") {
            lang_advance(p);
            lang_advance(p);
            while p.pos < p.text.count && !STRING.begins_with(lang_slice(p.text, p.pos, p.text.count), "*/") {
                lang_advance(p);
            }
            if p.pos == p.text.count {
                lang_fail(p, "Unterminated comment");
                return;
            }
            lang_advance(p);
            lang_advance(p);
        } else {
            break;
        }
    }
    p.token = Token.{ line = p.line, column = p.column };
    if p.pos == p.text.count {
        return;
    }
    start := p.pos;
    c := p.text[p.pos];
    lang_advance(p);
    if c == #char "\"" {
        while p.pos < p.text.count && p.text[p.pos] != #char "\"" {
            if p.text[p.pos] == #char "\\" {
                lang_advance(p);
            }
            lang_advance(p);
        }
        if p.pos == p.text.count {
            lang_fail(p, "Unterminated string");
            return;
        }
        lang_advance(p);
        value, ok := lang_unquote(lang_slice(p.text, start, p.pos));
        if !ok {
            lang_fail(p, "Invalid string escape");
            return;
        }
        p.token.text = value;
        p.token.quoted = true;
    } else if lang_is_punctuation(c) {
        p.token.text = lang_slice(p.text, start, p.pos);
    } else {
        while p.pos < p.text.count {
            c = p.text[p.pos];
            if lang_is_delimiter(c) {
                break;
            }
            lang_advance(p);
        }
        p.token.text = lang_slice(p.text, start, p.pos);
    }
}

lang_expect :: (p: *Parser, value: string) {
    if p.token.quoted || p.token.text != value {
        lang_fail(p, tprint("Expected %", value));
        return;
    }
    lang_next(p);
}

lang_string_value :: (p: *Parser) -> string {
    if !p.token.quoted {
        lang_fail(p, "Expected quoted string");
    }
    value := p.token.text;
    lang_next(p);
    return value;
}

lang_number :: (p: *Parser) -> float32 {
    value, ok := string_to_float(p.token.text);
    if !ok || p.token.quoted || JM.isnan(value) || JM.isinf(value) {
        lang_fail(p, "Expected finite number");
    }
    lang_next(p);
    return value;
}

lang_integer :: (p: *Parser) -> int {
    value := lang_number(p);
    if value < 0 || value > 8192 || value != JM.floor(value) {
        lang_fail(p, "Expected integer within 0..8192");
        return 0;
    }
    return cast(int) value;
}

lang_vector :: (p: *Parser, count: int) -> [4] float32 {
    value: [4] float32;
    if count == 1 || (count == 0 && p.token.text != "(") {
        value[0] = lang_number(p);
        return value;
    }
    lang_expect(p, "(");
    n := 0;
    while p.error == "" && n < 4 {
        value[n] = lang_number(p);
        n += 1;
        if p.token.text != "," {
            break;
        }
        lang_next(p);
    }
    lang_expect(p, ")");
    if count != 0 && n != count {
        lang_fail(p, "Wrong number of vector components");
    }
    return value;
}

lang_identifier :: (value: string) -> bool {
    if value.count == 0 {
        return false;
    }
    for c, i: value {
        if c == #char "_" || (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") ||
           (i > 0 && c >= #char "0" && c <= #char "9") {
            continue;
        }
        return false;
    }
    return true;
}

// odin 的 reflect.enum_from_name：按枚举成员名精确匹配；Jai 用 Basic 的枚举反射（names 与 values 平行）。
lang_enum_value :: (p: *Parser, $T: Type) -> T {
    result: T;
    names := enum_names(T);
    numbers := enum_values_as_s64(T);
    found := false;
    for name, i: names {
        if name == p.token.text {
            result = cast(T) numbers[i];
            found = true;
            break;
        }
    }
    if !found || p.token.quoted {
        lang_fail(p, tprint("Invalid % value", p.token.text));
    }
    lang_next(p);
    return result;
}

lang_preview :: (p: *Parser) -> string {
    value := p.token.text;
    if p.token.quoted || (value != "2D" && value != "3D") {
        lang_fail(p, "Expected 2D or 3D");
    }
    lang_next(p);
    if value == "3D" return "3d";
    return "2d";
}

lang_field_ref :: (p: *Parser) -> string {
    if p.token.quoted {
        return lang_string_value(p); // 字符串引用稳定 Id。
    }
    value := p.token.text;
    if !STRING.begins_with(value, "_") || !lang_identifier(lang_slice(value, 1, value.count)) {
        lang_fail(p, "Expected _property or quoted stable Id");
        return "";
    }
    lang_next(p);
    return lang_slice(value, 1, value.count);
}

// HLSL 保持原文；ENDHLSL 必须单独成行，注释和字符串中的同名文字不是结束标记。
// 调用方停在起始标记；不把 HLSL 交给外层词法器，保留开头注释和预处理指令。
lang_code_block :: (p: *Parser) -> Hlsl_Code {
    result: Hlsl_Code;
    start := p.pos;
    first_line := p.line;
    block_comment := false;
    quote: u8;
    while p.pos < p.text.count && p.error == "" {
        line_start := p.pos;
        line_end := line_start;
        while line_end < p.text.count && p.text[line_end] != #char "\n" {
            line_end += 1;
        }
        if !block_comment && quote == 0 && STRING.trim(lang_slice(p.text, line_start, line_end)) == "ENDHLSL" {
            result = Hlsl_Code.{ lang_slice(p.text, start, line_start), first_line };
            while p.pos < line_end {
                lang_advance(p);
            }
            lang_next(p);
            return result;
        }
        while p.pos < line_end {
            c := p.text[p.pos];
            if block_comment {
                if STRING.begins_with(lang_slice(p.text, p.pos, p.text.count), "*/") {
                    lang_advance(p);
                    block_comment = false;
                }
            } else if quote != 0 {
                if c == #char "\\" {
                    lang_advance(p);
                } else if c == quote {
                    quote = 0;
                }
            } else if STRING.begins_with(lang_slice(p.text, p.pos, p.text.count), "//") {
                while p.pos < line_end {
                    lang_advance(p);
                }
                break;
            } else if STRING.begins_with(lang_slice(p.text, p.pos, p.text.count), "/*") {
                block_comment = true;
                lang_advance(p);
            } else if c == #char "\"" || c == #char "'" {
                quote = c;
            }
            lang_advance(p);
        }
        lang_advance(p);
    }
    lang_fail(p, "Missing ENDHLSL on its own line");
    return .{};
}
//@endregion

//@region 字符串与容器桥接（Jai 没有 odin 的切片/字符串工具）

// 字符串视图（Jai 没有 s[a:b] 语法）；边界与空串按 odin 的切片语义。
lang_slice :: (text: string, start: int, end: int) -> string {
    if end <= start || start >= text.count return "";
    if end > text.count end = text.count;
    return string.{ end - start, text.data + start };
}

lang_free_string :: (value: string) {
    if value.data != null free(value.data);
}

// odin 的 strings.contains_rune("{}()[]=,", c)：词法器的标点集合。
lang_is_punctuation :: (c: u8) -> bool {
    if c == #char "{" || c == #char "}" || c == #char "(" || c == #char ")" return true;
    if c == #char "[" || c == #char "]" || c == #char "=" || c == #char "," return true;
    return false;
}

// odin 词法器里非标点 token 的结束字符（空白、标点、引号、斜杠）。
lang_is_delimiter :: (c: u8) -> bool {
    if c == #char " " || c == #char "\t" || c == #char "\r" || c == #char "\n" return true;
    return lang_is_punctuation(c) || c == #char "\"" || c == #char "/";
}

// [..] string 的线性包含判断（替代 odin 的 map[string]bool；指令数很少）。
lang_list_has :: (list: [] string, value: string) -> bool {
    for item: list {
        if item == value return true;
    }
    return false;
}

// odin 的 strconv.unquote_string：去掉引号并解码转义；返回 (value, ok)，非法转义 ok=false。
lang_unquote :: (text: string) -> (string, bool) {
    if text.count < 2 return "", false;
    if text[0] != #char "\"" || text[text.count - 1] != #char "\"" return "", false;
    body := lang_slice(text, 1, text.count - 1);
    out: [..] u8;
    i := 0;
    while i < body.count {
        c := body[i];
        if c != #char "\\" {
            array_add(*out, c);
            i += 1;
            continue;
        }
        if i + 1 >= body.count return "", false;
        escaped := body[i + 1];
        i += 2;
        if escaped == #char "n" {
            array_add(*out, #char "\n");
            continue;
        }
        if escaped == #char "r" {
            array_add(*out, #char "\r");
            continue;
        }
        if escaped == #char "t" {
            array_add(*out, #char "\t");
            continue;
        }
        if escaped == #char "a" {
            array_add(*out, #char "\a");
            continue;
        }
        if escaped == #char "b" {
            array_add(*out, #char "\b");
            continue;
        }
        if escaped == #char "e" {
            array_add(*out, cast(u8) 0x1B);
            continue;
        }
        if escaped == #char "f" {
            array_add(*out, #char "\f");
            continue;
        }
        if escaped == #char "v" {
            array_add(*out, #char "\v");
            continue;
        }
        if escaped == #char "0" {
            array_add(*out, cast(u8) 0);
            continue;
        }
        if escaped == #char "\\" || escaped == #char "\"" || escaped == #char "\'" {
            array_add(*out, escaped);
            continue;
        }
        digits := 0;
        if escaped == #char "x" {
            digits = 2;
        } else if escaped == #char "u" {
            digits = 4;
        } else if escaped == #char "U" {
            digits = 8;
        }
        if digits == 0 return "", false;
        if i + digits > body.count return "", false;
        codepoint := 0;
        for k: 0..digits - 1 {
            hex := lang_hex_value(body[i + k]);
            if hex < 0 return "", false;
            codepoint = codepoint * 16 + hex;
        }
        i += digits;
        lang_append_utf8(*out, codepoint);
    }
    if out.count == 0 return "", true;
    return string.{ out.count, out.data }, true;
}

lang_hex_value :: (c: u8) -> int {
    if c >= #char "0" && c <= #char "9" return cast(int) (c - #char "0");
    if c >= #char "a" && c <= #char "f" return cast(int) (c - #char "a") + 10;
    if c >= #char "A" && c <= #char "F" return cast(int) (c - #char "A") + 10;
    return -1;
}

lang_append_utf8 :: (out: *[..] u8, codepoint: int) {
    if codepoint < 0x80 {
        array_add(out, cast(u8) codepoint);
        return;
    }
    if codepoint < 0x800 {
        array_add(out, cast(u8) (0xC0 | (codepoint >> 6)));
        array_add(out, cast(u8) (0x80 | (codepoint & 0x3F)));
        return;
    }
    if codepoint < 0x10000 {
        array_add(out, cast(u8) (0xE0 | (codepoint >> 12)));
        array_add(out, cast(u8) (0x80 | ((codepoint >> 6) & 0x3F)));
        array_add(out, cast(u8) (0x80 | (codepoint & 0x3F)));
        return;
    }
    array_add(out, cast(u8) (0xF0 | (codepoint >> 18)));
    array_add(out, cast(u8) (0x80 | ((codepoint >> 12) & 0x3F)));
    array_add(out, cast(u8) (0x80 | ((codepoint >> 6) & 0x3F)));
    array_add(out, cast(u8) (0x80 | (codepoint & 0x3F)));
}

// odin 的 sbprintf("%q", path)：加双引号并转义引号与反斜杠。
lang_quoted :: (value: string) -> string {
    b: String_Builder;
    print_to_builder(*b, "\"");
    for c: value {
        if c == #char "\"" || c == #char "\\" print_to_builder(*b, "\\");
        // jacket 的 "%" 对 u8 打印的是数值（不是字符）；这里按字节追加，才能得到 "water.oshader"。
        append(*b, c);
    }
    print_to_builder(*b, "\"");
    text := builder_to_string(*b);
    free_buffers(*b);
    return text;
}
//@endregion
