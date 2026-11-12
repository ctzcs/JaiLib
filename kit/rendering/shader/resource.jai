// shader:resource —— 材质资源复用 Schema/Value；字节编解码无编辑器或文件系统依赖。
// 一比一移植自 olib kit/rendering/shader/resource.odin。
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                                    | JaiLib (Jai)                                          |
//   | ---------------------------------------------- | ----------------------------------------------------- |
//   | json.unmarshal(bytes, &resource, allocator=temp) | JSON.json_parse（core/encoding）+ 逐键走 Json_Value   |
//   | json.marshal(resource, {pretty = true})        | 本文件的 shader_json_* 写出器（4 空格缩进，键序同结构体）|
//   | 枚举自动序列化为成员名（"Scalar"）               | shader_kind_name 走 type_info(Kind) 取成员名，逐字相同   |
//   | err != nil（错误对象）                           | bool 返回（Jai 的 IO/解析只有 bool）                    |
//   | make([]Resource_Field, n, temp)                | shader_alloc_array(Resource_Field, n)                  |
//   | delete(bytes) / delete(texture)                | free(bytes.data) / shader_free_string(texture)         |
//   | 反射反序列化（缺键 = 零值、未知键忽略）            | shader_json_* 显式取键；缺键同样保持零值                 |
//   | 过程参数可写（out 风格）                          | Jai 参数不可变，所有 out 参数写成 *T                     |
//
// JSON 字节不是本包的契约面（olib 侧同样只保证往返与校验），但键名、键序、枚举拼写、
// 结构层级与 olib 完全相同：`version` / `group` / `fields[{id, kind, number, texture}]`。
#import "Basic";

// 单个材质文件的字节数与字段数上限，防止异常资源占满内存。
MAX_RESOURCE_BYTES :: 1024 * 1024;
MAX_RESOURCE_FIELDS :: 256;

Resource_Field :: struct {
    id: string;
    kind: Kind;
    number: [4] float32;
    texture: string;
}

// version=1 与既有 Shader Lab 预设兼容。group 是稳定 Schema.name，不是 HLSL 路径。
Resource :: struct {
    version: int;
    group: string;
    fields: [] Resource_Field;
}

field_index :: (schema: Schema, id: string) -> int {
    for f, i: schema.fields {
        if f.id == id return i;
    }
    return -1;
}

// 返回独立拥有的值；只按字段覆盖，不修改共享 base。失败返回空切片，原实例不变。
// 返回 (values, error)；成功时 error 为空，values 用 values_dispose 释放。
values_overlay :: (schema: Schema, base: [] Value, fields: [] Resource_Field) -> ([] Value, string) {
    if base.count != schema.fields.count return .[], "Material value count differs from schema";
    if fields.count > MAX_RESOURCE_FIELDS return .[], "Too many material fields";
    for saved, i: fields {
        if saved.id == "" return .[], "Empty material field ID";
        for prior: array_view(fields, 0, i) {
            if prior.id == saved.id return .[], tprint("Duplicate material field: %", saved.id);
        }
        if saved.kind < .Scalar || saved.kind > .Texture return .[], "Invalid material field kind";
        for number: saved.number {
            if JM.isnan(number) || JM.isinf(number) return .[], "Non-finite material value";
        }
        j := field_index(schema, saved.id);
        if j < 0 continue; // 删除的字段忽略；新增字段由默认值提供。
        f := schema.fields[j];
        if f.kind != saved.kind return .[], tprint("Material field type differs: %", f.id);
        for c: 0..components(f.kind) - 1 {
            if saved.number[c] < f.minimum || saved.number[c] > f.maximum {
                return .[], tprint("Material field out of range: %", f.id);
            }
        }
    }
    result := values_make(schema, schema, base);
    for saved: fields {
        i := field_index(schema, saved.id);
        if i < 0 continue;
        shader_free_string(result[i].texture);
        result[i] = Value.{ number = saved.number, texture = copy_string(saved.texture) };
    }
    return result, "";
}

// 结果由调用方 allocator 持有；诊断字符串仅在本帧有效。
// 返回 (values, error)；成功时 error 为空，values 用 values_dispose 释放。
resource_decode :: (schema: Schema, bytes: [] u8) -> ([] Value, string) {
    if bytes.count > MAX_RESOURCE_BYTES return .[], "Material resource exceeds 1 MiB";
    // odin 的 json.unmarshal 直接把 JSON 填进 struct；这里解析成 Json_Value 树后逐键取，
    // 缺键保持零值、未知键忽略，语义与 odin 的反射反序列化相同。
    document, parsed := JSON.json_parse(shader_bytes_to_string(bytes), temp);
    if !parsed || document.kind != .Object return .[], "Invalid material JSON";
    resource: Resource;
    value: JSON.Json_Value;
    if shader_json_member(document, "version", *value) {
        if !shader_json_int(value, *resource.version) return .[], "Invalid material JSON";
    }
    if shader_json_member(document, "group", *value) {
        if !shader_json_string(value, *resource.group) return .[], "Invalid material JSON";
    }
    if shader_json_member(document, "fields", *value) {
        if value.kind != .Array return .[], "Invalid material JSON";
        resource.fields = shader_alloc_array(Resource_Field, value.array_val.count);
        for element, i: value.array_val {
            if !shader_json_resource_field(<<element, *resource.fields[i]) {
                if resource.fields.data != null free(resource.fields.data);
                return .[], "Invalid material JSON";
            }
        }
    }
    defer {
        if resource.fields.data != null free(resource.fields.data);
    }
    if resource.version != 1 return .[], "Unsupported material resource version";
    if resource.group != schema.name return .[], "Material shader group differs from schema";
    defaults := values_make(schema);
    defer values_dispose(defaults);
    return values_overlay(schema, defaults, resource.fields);
}

// 返回拥有的 JSON 字节；贴图路径保持传入值，路径转换由资源宿主负责。
// 返回 (bytes, error)；成功时 bytes 用 free(bytes.data) 释放。
resource_encode :: (schema: Schema, values: [] Value) -> ([] u8, string) {
    if values.count != schema.fields.count return .[], "Material value count differs from schema";
    resource := Resource.{ version = 1, group = schema.name,
                           fields = shader_alloc_array(Resource_Field, values.count) };
    defer {
        if resource.fields.data != null free(resource.fields.data);
    }
    for f, i: schema.fields {
        resource.fields[i] = Resource_Field.{ id = f.id, kind = f.kind,
                                             number = values[i].number, texture = values[i].texture };
    }
    validated, reason := values_overlay(schema, values, resource.fields);
    defer values_dispose(validated);
    if reason != "" return .[], reason;
    b: String_Builder;
    shader_json_write_resource(*b, resource, 0);
    text := builder_to_string(*b);
    free_buffers(*b);
    // odin 的 json.marshal 直接返回 []u8；这里把文本搬进刚好大小的字节数组。
    bytes := shader_alloc_array(u8, text.count);
    memcpy(bytes.data, text.data, text.count);
    free(text.data);
    return bytes, "";
}
//@endregion

//@region JSON 编解码桥接（替代 odin core:encoding/json 的反射）

// []u8 -> string 视图（不复制）。
shader_bytes_to_string :: (bytes: [] u8) -> string {
    if bytes.count == 0 return "";
    return string.{ bytes.count, bytes.data };
}

// 取对象的成员；不是对象或没有该键时返回 false。
shader_json_member :: (object: JSON.Json_Value, key: string, out: *JSON.Json_Value) -> bool {
    if object.kind != .Object return false;
    // jacket 的 table_find 返回 (found, value)，与官方 Jai 的顺序相反（见 docs/OLIB_PARITY.md）。
    found, value := HASH.table_find(*object.object_val, key);
    if !found return false;
    out.* = <<value;
    return true;
}

shader_json_string :: (value: JSON.Json_Value, out: *string) -> bool {
    if value.kind != .String return false;
    out.* = value.string_val;
    return true;
}

shader_json_int :: (value: JSON.Json_Value, out: *int) -> bool {
    if value.kind == .Integer {
        out.* = cast(int) value.int_val;
        return true;
    }
    if value.kind == .Float {
        if JM.isnan(value.number_val) || JM.isinf(value.number_val) return false;
        out.* = cast(int) value.number_val;
        return true;
    }
    return false;
}

shader_json_float32 :: (value: JSON.Json_Value, out: *float32) -> bool {
    if value.kind == .Integer {
        out.* = cast(float32) value.int_val;
        return true;
    }
    if value.kind == .Float {
        out.* = cast(float32) value.number_val;
        return true;
    }
    return false;
}

// [4]f32：odin 的反射要求数组长度正好 4（多/少都算无效 JSON）。
shader_json_numbers4 :: (value: JSON.Json_Value, out: *[4] float32) -> bool {
    if value.kind != .Array || value.array_val.count != 4 return false;
    result: [4] float32;
    for element, i: value.array_val {
        if !shader_json_float32(<<element, *result[i]) return false;
    }
    out.* = result;
    return true;
}

// Kind 的成员名 / 由成员名反查（与 odin 枚举反射的拼写逐字相同）。
// jacket 的 Type_Info_Enum 是 (names, values) 平行数组（不是 odin 的 members），
// Basic 已提供 enum_names / enum_values_as_s64，直接用它俩。
shader_kind_name :: (kind: Kind) -> string {
    names := enum_names(Kind);
    numbers := enum_values_as_s64(Kind);
    for name, i: names {
        if numbers[i] == cast(s64) kind return name;
    }
    return "";
}

shader_kind_from_name :: (name: string, out: *Kind) -> bool {
    names := enum_names(Kind);
    numbers := enum_values_as_s64(Kind);
    for candidate, i: names {
        if candidate == name {
            out.* = cast(Kind) numbers[i];
            return true;
        }
    }
    return false;
}

shader_json_resource_field :: (value: JSON.Json_Value, out: *Resource_Field) -> bool {
    if value.kind != .Object return false;
    field: Resource_Field;
    member: JSON.Json_Value;
    if shader_json_member(value, "id", *member) {
        if !shader_json_string(member, *field.id) return false;
    }
    if shader_json_member(value, "kind", *member) {
        name: string;
        if !shader_json_string(member, *name) return false;
        if !shader_kind_from_name(name, *field.kind) return false;
    }
    if shader_json_member(value, "number", *member) {
        if !shader_json_numbers4(member, *field.number) return false;
    }
    if shader_json_member(value, "texture", *member) {
        if !shader_json_string(member, *field.texture) return false;
    }
    out.* = field;
    return true;
}

shader_json_indent :: (b: *String_Builder, depth: int) {
    for 0..depth - 1 print_to_builder(b, "    ");
}

shader_json_write_quoted :: (b: *String_Builder, value: string) {
    print_to_builder(b, "\"");
    for c: value {
        if c == #char "\"" {
            print_to_builder(b, "\\\"");
        } else if c == #char "\\" {
            print_to_builder(b, "\\\\");
        } else if c == #char "\n" {
            print_to_builder(b, "\\n");
        } else if c == #char "\r" {
            print_to_builder(b, "\\r");
        } else if c == #char "\t" {
            print_to_builder(b, "\\t");
        } else if c < 32 {
            print_to_builder(b, "\\u00%", c);
        } else {
            append(b, c);
        }
    }
    print_to_builder(b, "\"");
}

// f32 的最短往返写法（Jai 的 "%" 与 odin 的 "%v" 都是最短表示）。
shader_json_write_numbers4 :: (b: *String_Builder, number: [4] float32) {
    print_to_builder(b, "[%, %, %, %]", number[0], number[1], number[2], number[3]);
}

// 与 odin 的 json.marshal({pretty = true}) 同形的缩进；键序固定为结构体顺序。
shader_json_write_resource :: (b: *String_Builder, resource: Resource, depth: int) {
    shader_json_indent(b, depth);
    print_to_builder(b, "{\n");
    shader_json_indent(b, depth + 1);
    print_to_builder(b, "\"version\": %,\n", resource.version);
    shader_json_indent(b, depth + 1);
    print_to_builder(b, "\"group\": ");
    shader_json_write_quoted(b, resource.group);
    print_to_builder(b, ",\n");
    shader_json_indent(b, depth + 1);
    print_to_builder(b, "\"fields\": [");
    for field, i: resource.fields {
        if i > 0 print_to_builder(b, ",");
        print_to_builder(b, "\n");
        shader_json_indent(b, depth + 2);
        print_to_builder(b, "{\n");
        shader_json_indent(b, depth + 3);
        print_to_builder(b, "\"id\": ");
        shader_json_write_quoted(b, field.id);
        print_to_builder(b, ",\n");
        shader_json_indent(b, depth + 3);
        print_to_builder(b, "\"kind\": ");
        shader_json_write_quoted(b, shader_kind_name(field.kind));
        print_to_builder(b, ",\n");
        shader_json_indent(b, depth + 3);
        print_to_builder(b, "\"number\": ");
        shader_json_write_numbers4(b, field.number);
        print_to_builder(b, ",\n");
        shader_json_indent(b, depth + 3);
        print_to_builder(b, "\"texture\": ");
        shader_json_write_quoted(b, field.texture);
        print_to_builder(b, "\n");
        shader_json_indent(b, depth + 2);
        print_to_builder(b, "}");
    }
    if resource.fields.count > 0 {
        print_to_builder(b, "\n");
        shader_json_indent(b, depth + 1);
    }
    print_to_builder(b, "]\n");
    shader_json_indent(b, depth);
    print_to_builder(b, "}");
}
//@endregion
