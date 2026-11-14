// shader:instance —— 对象材质实例拥有参数和贴图路径；Shader 定义与 GPU 资源由资源管理器共享。
// 一比一移植自 olib kit/rendering/shader/instance.odin。
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                              | JaiLib (Jai)                                     |
//   | ---------------------------------------- | ------------------------------------------------ |
//   | shader: string `json:"effect"`           | 文件键仍是 "effect"（写出/读入都在本文件显式写死）  |
//   | json.unmarshal / json.marshal            | JSON.json_parse + shader_json_* 写出器             |
//   | make([]Instance_Group, n)                | shader_alloc_array(Instance_Group, n)             |
//   | append(&dynamic, x) / delete(dynamic)     | array_add(*dynamic, x) / free(dynamic.data)       |
//   | copy(result.groups, groups[:])           | memcpy(result.groups.data, groups.data, n * size) |
//   | delete(group.values) / delete(schema)     | values_dispose / schema_dispose                  |
//   | `{}`（零值）                              | Instance.{}                                      |
#import "Basic";

Instance_Group :: struct {
    schema: Schema;
    values: [] Value;
}

Instance :: struct {
    shader: string;
    groups: [] Instance_Group;
}

Instance_Resource :: struct {
    version: int;
    shader: string; // 文件里的键是 "effect"（见 shader_json_write_instance / read_instance）
    groups: [] Resource;
}

instance_dispose :: (instance: *Instance) {
    for *group: instance.groups {
        values_dispose(group.values);
        schema_dispose(*group.schema);
    }
    if instance.groups.data != null free(instance.groups.data);
    shader_free_string(instance.shader);
    instance.* = Instance.{};
}

// 返回 (instance, error)；成功时 error 为空，instance 用 instance_dispose 释放。
instance_make :: (shader: Shader_Desc, schemas: [] Schema) -> (Instance, string) {
    order, reason := shader_order(shader, schemas);
    if order.data != null free(order.data);
    if reason != "" return Instance.{}, reason;
    if !shader_is_material(shader) return Instance.{}, "Material instance requires Model or Sprite passes";
    groups: [..] Instance_Group;
    for p: shader.passes {
        found := false;
        for group: groups found = found || group.schema.name == p.params;
        if found continue;
        for schema: schemas {
            if schema.name != p.params continue;
            array_add(*groups, Instance_Group.{ schema_clone(schema), values_make(schema) });
        }
    }
    result := Instance.{ shader = copy_string(shader.name),
                         groups = shader_alloc_array(Instance_Group, groups.count) };
    if groups.count > 0 {
        memcpy(result.groups.data, groups.data, groups.count * size_of(Instance_Group));
        free(groups.data);
    }
    return result, "";
}

// Decode 成功才交给调用方替换；缺少的新组/字段保留默认值。
instance_decode :: (shader: Shader_Desc, schemas: [] Schema, bytes: [] u8) -> (Instance, string) {
    if bytes.count > MAX_RESOURCE_BYTES return Instance.{}, "Material resource exceeds 1 MiB";
    document, parsed := JSON.json_parse(shader_bytes_to_string(bytes), temp);
    if !parsed || document.kind != .Object return Instance.{}, "Invalid material JSON";
    resource: Instance_Resource;
    value: JSON.Json_Value;
    if shader_json_member(document, "version", *value) {
        if !shader_json_int(value, *resource.version) return Instance.{}, "Invalid material JSON";
    }
    if shader_json_member(document, "effect", *value) {
        if !shader_json_string(value, *resource.shader) return Instance.{}, "Invalid material JSON";
    }
    if shader_json_member(document, "groups", *value) {
        if value.kind != .Array return Instance.{}, "Invalid material JSON";
        resource.groups = shader_alloc_array(Resource, value.array_val.count);
        for element, i: value.array_val {
            if !shader_json_resource(<<element, *resource.groups[i]) {
                if resource.groups.data != null free(resource.groups.data);
                return Instance.{}, "Invalid material JSON";
            }
        }
    }
    defer {
        if resource.groups.data != null {
            for group: resource.groups {
                if group.fields.data != null free(group.fields.data);
            }
            free(resource.groups.data);
        }
    }
    if resource.version != 2 || resource.shader != shader.name {
        return Instance.{}, "Material version or shader differs";
    }
    result, reason := instance_make(shader, schemas);
    if reason != "" return Instance.{}, reason;
    for saved, i: resource.groups {
        for prior: array_view(resource.groups, 0, i) {
            if prior.group == saved.group {
                instance_dispose(*result);
                return Instance.{}, "Duplicate material group";
            }
        }
        found := false;
        for *group: result.groups {
            if group.schema.name != saved.group continue;
            found = true;
            values, error := values_overlay(group.schema, group.values, saved.fields);
            if error != "" || saved.version != 1 {
                values_dispose(values);
                instance_dispose(*result);
                // odin 的 `error != "" ? error : "..."`：Jai 没有三目运算符。
                if error != "" return Instance.{}, error;
                return Instance.{}, "Invalid material group version";
            }
            values_dispose(group.values);
            group.values = values;
        }
        if !found {
            instance_dispose(*result);
            return Instance.{}, "Unknown material group";
        }
    }
    return result, "";
}

// 返回 (bytes, error)；成功时 bytes 用 free(bytes.data) 释放。
instance_encode :: (instance: Instance) -> ([] u8, string) {
    if instance.shader == "" || instance.groups.count == 0 || instance.groups.count > MAX_PASSES {
        return .[], "Invalid material instance";
    }
    resource := Instance_Resource.{ version = 2, shader = instance.shader,
                                    groups = shader_alloc_array(Resource, instance.groups.count) };
    defer {
        if resource.groups.data != null {
            for group: resource.groups {
                if group.fields.data != null free(group.fields.data);
            }
            free(resource.groups.data);
        }
    }
    for group, i: instance.groups {
        for prior: array_view(instance.groups, 0, i) {
            if prior.schema.name == group.schema.name return .[], "Duplicate material group";
        }
        // odin 走 resource_encode → json.unmarshal 回到 Resource（借这一趟做校验）。
        // 这里直接按同一规则组装 Resource，再走一遍 values_overlay 校验，结果等价。
        resource.groups[i] = Resource.{ version = 1, group = group.schema.name,
                                       fields = shader_alloc_array(Resource_Field, group.values.count) };
        for f, j: group.schema.fields {
            resource.groups[i].fields[j] = Resource_Field.{ id = f.id, kind = f.kind,
                                                            number = group.values[j].number,
                                                            texture = group.values[j].texture };
        }
        validated, reason := values_overlay(group.schema, group.values, resource.groups[i].fields);
        values_dispose(validated);
        if reason != "" return .[], reason;
    }
    b: String_Builder;
    shader_json_write_instance(*b, resource);
    text := builder_to_string(*b);
    free_buffers(*b);
    bytes := shader_alloc_array(u8, text.count);
    memcpy(bytes.data, text.data, text.count);
    free(text.data);
    return bytes, "";
}

//@region 实例资源的 JSON（键序/键名与 olib 相同；文件里的键是 "effect"）

shader_json_resource :: (value: JSON.Json_Value, out: *Resource) -> bool {
    if value.kind != .Object return false;
    resource: Resource;
    member: JSON.Json_Value;
    if shader_json_member(value, "version", *member) {
        if !shader_json_int(member, *resource.version) return false;
    }
    if shader_json_member(value, "group", *member) {
        if !shader_json_string(member, *resource.group) return false;
    }
    if shader_json_member(value, "fields", *member) {
        if member.kind != .Array return false;
        resource.fields = shader_alloc_array(Resource_Field, member.array_val.count);
        for element, i: member.array_val {
            if !shader_json_resource_field(<<element, *resource.fields[i]) {
                if resource.fields.data != null free(resource.fields.data);
                return false;
            }
        }
    }
    out.* = resource;
    return true;
}

shader_json_write_instance :: (b: *String_Builder, resource: Instance_Resource) {
    print_to_builder(b, "{\n    \"version\": %,\n    \"effect\": ", resource.version);
    shader_json_write_quoted(b, resource.shader);
    print_to_builder(b, ",\n    \"groups\": [");
    for group, i: resource.groups {
        if i > 0 print_to_builder(b, ",");
        print_to_builder(b, "\n");
        shader_json_write_resource(b, group, 2);
    }
    if resource.groups.count > 0 print_to_builder(b, "\n    ");
    print_to_builder(b, "]\n}");
}
//@endregion
