// .oshader extraction uses the same parser as Shader Lab; no second grammar.
#import "Basic";
FILE :: #import "File";
J :: #import "core/encoding";
H :: #import "Hash_Table";
L :: #import "kit/rendering/shader/lang";
S :: #import "kit/rendering/shader";
M :: #import "kit/rendering/material";

Manifest :: struct { version: int = M.MANIFEST_VERSION; schemas: [] S.Schema; effect: S.Shader_Desc; }

// Material manifests require enum names, while general core JSON writes numbers.
manifest_value :: (ptr: *void, ti: *Type_Info) -> J.Json_Value {
    if ti.type == .ENUM {
        numeric := J.json_member_to_value(ptr, ti);
        info := cast(*Type_Info_Enum) ti;
        for name, i: info.names if info.values[i] == numeric.int_val {
            return .{kind=.String, string_val=copy_string(name)};
        }
        assert(false, "Unknown enum value in shader manifest");
    }
    if ti.type == .STRUCT {
        info := cast(*Type_Info_Struct) ti;
        result: J.Json_Value; result.kind = .Object;
        for member: info.members {
            node := J.json_node_new(context.allocator);
            node.* = manifest_value((cast(*u8) ptr) + member.offset_in_bytes, member.type);
            H.table_set(*result.object_val, copy_string(member.name), node);
        }
        return result;
    }
    if ti.type == .ARRAY {
        info := cast(*Type_Info_Array) ti;
        count := info.array_count;
        data := cast(*u8) ptr;
        if info.array_type != .FIXED {
            array := cast(*Resizable_Array) ptr;
            count = array.count; data = cast(*u8) array.data;
        }
        result: J.Json_Value; result.kind = .Array;
        i: s64 = 0;
        while i < count {
            node := J.json_node_new(context.allocator);
            node.* = manifest_value(data + i * info.element_type.runtime_size, info.element_type);
            array_add(*result.array_val, node); i += 1;
        }
        return result;
    }
    return J.json_member_to_value(ptr, ti);
}

main :: () {
    args := get_command_line_arguments();
    if args.count != 3 { print("shaders INPUT.oshader EXISTING_OUTPUT_DIRECTORY\n"); exit(2); }
    text, ok := FILE.read_entire_file(args[1]);
    if !ok { print("Cannot read %\n", args[1]); exit(1); }
    defer free(text);
    doc := L.parse(text, args[1]); defer L.dispose(*doc);
    if doc.error != "" { print("%\n", doc.error); exit(1); }
    for *schema, i: doc.schemas {
        if !FILE.write_entire_file(tprint("%/%.hlsl", args[2], schema.name), doc.programs[i]) exit(1);
        if doc.instanced_programs[i] != "" {
            if !FILE.write_entire_file(tprint("%/%.instanced.hlsl", args[2], schema.name), doc.instanced_programs[i]) exit(1);
        }
        free(schema.shader); schema.shader = copy_string(schema.name);
    }
    manifest := Manifest.{schemas=doc.schemas, effect=doc.shader};
    value := manifest_value(*manifest, type_info(Manifest));
    defer J.json_destroy_value(value);
    json := J.json_marshal(value, J.DEFAULT_MARSHAL_OPT); defer free(json);
    // Round-trip with the runtime reader before publishing a description.
    parsed: M.Compiled_Manifest;
    bytes := [] u8.{json.count, json.data};
    error := M.compiled_manifest_parse(bytes, *parsed);
    defer M.compiled_manifest_dispose(*parsed);
    if error != "" { print("%\n", error); exit(1); }
    if !FILE.write_entire_file(tprint("%/%.shader.json", args[2], doc.shader.name), json) exit(1);
}
