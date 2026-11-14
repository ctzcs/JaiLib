// json.jai
// 一比一移植自 olib core/encoding/json.odin。
//
// JSON 序列化工具（编辑器可用）：双向加载/保存，支持 Value 树和 struct 两种形态。
//
// 典型编辑器工作流（Value 树 + arena）：
//     root, err := json_load("maps/level1.json", /* allocator */);
//     // ... 编辑 root（.Object / .Array 分支）...
//     json_save("maps/level1.json", root);   // 写回，pretty 默认开
//
// 类型化配置/存档工作流：
//     cfg: Game_Save
//     json_load_struct("save/save1.json", *cfg)
//     // ... 游戏运行，修改 cfg ...
//     json_save_struct("save/save1.json", *cfg)
//
// Jai 侧差异（对外语义不变）：
//   - olib 把活都交给 core:encoding/json；Jai 没有对应标准库，这里自带解析/序列化。
//     词法器与 ordered_json.jai 共用（oj_*），因此数字词法（严格 RFC 8259）、字符串转义
//     （含 \uXXXX 代理对、拒绝 \'、拒绝孤立代理）、gap 只认 RFC 空白这三点与 ordered_json
//     完全同源；解析失败一律映射成 Json_Error.Parse_Error，与 olib 的 "jerr != .None ->
//     .Parse_Error" 一致。
//   - odin 的 json.Value 是 union（Null/Boolean/Integer/Float/String/Array/Object）；
//     Jai 这里用 kind + int_val/number_val/string_val 的求和结构，kind 取值与 odin 的
//     union 分支一一对应（.Integer 与 .Float 分开，parse_integers = true 的语义得以保留）。
//     整数词法超出 i64 时降级为 .Float（Odin 侧是静默回绕，这里不复制未定义行为）。
//   - json.Object 是 map[string]Value -> Table(string, *Json_Value)；Jai 没有 union 类型的
//     引用语义，节点一律用指针持有（与旧 JaiLib 版本一致，destroy 可递归释放）。
//     重复键按 odin map 语义覆盖（table_set）。
//   - json_string 在 olib 返回 json.String（distinct string）：Jai 没有对应的 union 变体，
//     返回克隆到堆上的 string，语义（"不要用字面量构造，克隆后可安全释放"）不变。
//   - Marshal_Options.spec 只支持 .JSON（Odin 侧还有 .JSON5/.MJSON）；pretty / use_spaces /
//     spaces 全部生效，默认值与 olib 的 DEFAULT_MARSHAL_OPT 相同（pretty、4 空格）。
//   - `json.Value{}` -> Json_Value.{ kind = .Null }；`delete(...)` -> free / deinit。
//   - 不做 OOM 检查：Jai 的 array_add / New 在分配失败时断言终止，没有可注入失败的分配器；
//     需要"失败即返回错误、且不泄漏"的语义请用 ordered_json.jai（它手写增长并返回 .Allocation）。
#import "Basic";
#import "Hash_Table";
#import "String";
#import "File";

//@region 错误码与序列化选项

Json_Error :: enum u32 {
    None;
    File_Not_Found;
    Parse_Error;
    Write_Error;
}

// 对位 odin json.Specification（当前只实现 .JSON）。
Specification :: enum u32 {
    JSON;
    JSON5;
    MJSON;
}

// 默认序列化选项：标准 JSON、pretty、4 空格缩进（编辑器人工可读 / diff 友好）。
Marshal_Options :: struct {
    spec: Specification;
    pretty: bool;
    use_spaces: bool;
    spaces: int;
}

DEFAULT_MARSHAL_OPT :: Marshal_Options.{
    spec = .JSON,
    pretty = true,
    use_spaces = true,
    spaces = 4,
}
//@endregion

//@region 数据类型 —— Value 树

Json_Kind :: enum u32 {
    Null;
    Boolean;
    Integer;
    Float;
    String;
    Array;
    Object;
}

Json_Value :: struct {
    kind: Json_Kind;
    bool_val: bool;
    int_val: s64;
    number_val: float64;
    string_val: string;
    array_val: [..] *Json_Value;
    object_val: Table(string, *Json_Value);
}

json_value_new :: () -> Json_Value {
    return .{ kind = .Null };
}

json_node_new :: (allocator: Allocator) -> *Json_Value {
    memory := oj_alloc(oj_allocator(allocator), size_of(Json_Value));
    if !memory return null;
    node := cast(*Json_Value) memory;
    <<node = .{ kind = .Null };
    return node;
}
//@endregion

//@region 解析 —— 复用 ordered_json 的严格词法器

json_lexeme_to_i64 :: (lexeme: string) -> (s64, bool) {
    negative := lexeme.count > 0 && lexeme[0] == 45;
    digits := lexeme;
    if negative digits = string.{ data = lexeme.data + 1, count = lexeme.count - 1 };
    limit: u64 = 9223372036854775807;
    if negative limit = 9223372036854775808;
    n, ok := oj_magnitude(digits, limit);
    if !ok return 0, false;
    if negative && n > 0 return -cast(s64) (n - 1) - 1, true;
    return cast(s64) n, true;
}

json_lexeme_to_f64 :: (lexeme: string) -> float64 {
    v, ok, _ := string_to_float64(lexeme);
    if !ok return 0;
    return v;
}

json_parse_value :: (d: *Oj_Decoder, allocator: Allocator) -> (Json_Value, bool) {
    kind := d.token.kind;
    if kind == .True || kind == .False {
        v: Json_Value;
        v.kind = .Boolean;
        v.bool_val = kind == .True;
        if oj_advance(d) != .None return json_value_new(), false;
        return v, true;
    }
    if kind == .Integer || kind == .Float {
        v: Json_Value;
        if kind == .Integer {
            iv, fits := json_lexeme_to_i64(d.token.text);
            if fits {
                v.kind = .Integer;
                v.int_val = iv;
            } else {
                v.kind = .Float;
                v.number_val = json_lexeme_to_f64(d.token.text);
            }
        } else {
            v.kind = .Float;
            v.number_val = json_lexeme_to_f64(d.token.text);
        }
        if oj_advance(d) != .None return json_value_new(), false;
        return v, true;
    }
    if kind == .String {
        text, err := oj_read_string(d, allocator);
        if err != .None return json_value_new(), false;
        v: Json_Value;
        v.kind = .String;
        v.string_val = text;
        if oj_advance(d) != .None {
            json_destroy_value(v);
            return json_value_new(), false;
        }
        return v, true;
    }
    if kind == .Open_Bracket {
        v: Json_Value;
        v.kind = .Array;
        v.array_val.allocator = oj_allocator(allocator);
        if oj_advance(d) != .None return json_value_new(), false;
        if d.token.kind == .Close_Bracket {
            if oj_advance(d) != .None return json_value_new(), false;
            return v, true;
        }
        while true {
            item, ok := json_parse_value(d, allocator);
            if !ok {
                json_destroy_value(v);
                return json_value_new(), false;
            }
            node := json_node_new(allocator);
            if node == null {
                json_destroy_value(item);
                json_destroy_value(v);
                return json_value_new(), false;
            }
            <<node = item;
            array_add(*v.array_val, node);
            if d.token.kind == .Comma {
                if oj_advance(d) != .None {
                    json_destroy_value(v);
                    return json_value_new(), false;
                }
                continue;
            }
            if d.token.kind == .Close_Bracket {
                if oj_advance(d) != .None {
                    json_destroy_value(v);
                    return json_value_new(), false;
                }
                return v, true;
            }
            json_destroy_value(v);
            return json_value_new(), false;
        }
    }
    if kind == .Open_Brace {
        v: Json_Value;
        v.kind = .Object;
        v.object_val.allocator = oj_allocator(allocator);
        if oj_advance(d) != .None return json_value_new(), false;
        if d.token.kind == .Close_Brace {
            if oj_advance(d) != .None return json_value_new(), false;
            return v, true;
        }
        while true {
            if d.token.kind != .String {
                json_destroy_value(v);
                return json_value_new(), false;
            }
            key, key_err := oj_read_string(d, allocator);
            if key_err != .None {
                json_destroy_value(v);
                return json_value_new(), false;
            }
            if oj_advance(d) != .None || d.token.kind != .Colon {
                oj_free_string(allocator, key);
                json_destroy_value(v);
                return json_value_new(), false;
            }
            if oj_advance(d) != .None {
                oj_free_string(allocator, key);
                json_destroy_value(v);
                return json_value_new(), false;
            }
            item, ok := json_parse_value(d, allocator);
            if !ok {
                oj_free_string(allocator, key);
                json_destroy_value(v);
                return json_value_new(), false;
            }
            node := json_node_new(allocator);
            if node == null {
                json_destroy_value(item);
                oj_free_string(allocator, key);
                json_destroy_value(v);
                return json_value_new(), false;
            }
            <<node = item;
            // odin 的 map 语义：同键覆盖
            table_set(*v.object_val, key, node);
            if d.token.kind == .Comma {
                if oj_advance(d) != .None {
                    json_destroy_value(v);
                    return json_value_new(), false;
                }
                continue;
            }
            if d.token.kind == .Close_Brace {
                if oj_advance(d) != .None {
                    json_destroy_value(v);
                    return json_value_new(), false;
                }
                return v, true;
            }
            json_destroy_value(v);
            return json_value_new(), false;
        }
    }
    return json_value_new(), false;
}

json_parse :: (data: string, allocator: Allocator) -> (Json_Value, bool) {
    if !oj_valid_utf8(data) return json_value_new(), false;
    d: Oj_Decoder;
    d.data = data;
    d.mode = .Strict;
    if oj_advance(*d) != .None return json_value_new(), false;
    value, ok := json_parse_value(*d, allocator);
    if !ok return json_value_new(), false;
    if d.token.kind != .EOF {
        json_destroy_value(value);
        return json_value_new(), false;
    }
    return value, true;
}
//@endregion

//@region 序列化 —— pretty / 缩进选项生效

json_write_indent :: (builder: *String_Builder, indent: int, opt: Marshal_Options) {
    if !opt.pretty return;
    for 0..indent - 1 {
        if opt.use_spaces {
            for 0..opt.spaces - 1 print_to_builder(builder, " ");
        } else {
            print_to_builder(builder, "\t");
        }
    }
}

json_escape_into :: (builder: *String_Builder, s: string) {
    for c: s {
        if c == "\""[0] {
            print_to_builder(builder, "\\\"");
        } else if c == "\\"[0] {
            print_to_builder(builder, "\\\\");
        } else if c == "\n"[0] {
            print_to_builder(builder, "\\n");
        } else if c == "\t"[0] {
            print_to_builder(builder, "\\t");
        } else if c == "\r"[0] {
            print_to_builder(builder, "\\r");
        } else if c == "\b"[0] {
            print_to_builder(builder, "\\b");
        } else if c == "\f"[0] {
            print_to_builder(builder, "\\f");
        } else if c < 32 {
            hex_digits: [16] u8 = .[48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 65, 66, 67, 68, 69, 70];
            print_to_builder(builder, "\\u00");
            append(builder, hex_digits[(c >> 4) & 15]);
            append(builder, hex_digits[c & 15]);
        } else {
            append(builder, c);
        }
    }
}

json_write_value :: (builder: *String_Builder, v: Json_Value, indent: int, opt: Marshal_Options) {
    if v.kind == .Null {
        print_to_builder(builder, "null");
        return;
    }
    if v.kind == .Boolean {
        if v.bool_val {
            print_to_builder(builder, "true");
        } else {
            print_to_builder(builder, "false");
        }
        return;
    }
    if v.kind == .Integer {
        print_to_builder(builder, "%", v.int_val);
        return;
    }
    if v.kind == .Float {
        print_to_builder(builder, "%", v.number_val);
        return;
    }
    if v.kind == .String {
        print_to_builder(builder, "\"");
        json_escape_into(builder, v.string_val);
        print_to_builder(builder, "\"");
        return;
    }
    if v.kind == .Array {
        if v.array_val.count == 0 {
            print_to_builder(builder, "[]");
            return;
        }
        print_to_builder(builder, "[");
        for i: 0..v.array_val.count - 1 {
            if i > 0 print_to_builder(builder, ",");
            if opt.pretty print_to_builder(builder, "\n");
            json_write_indent(builder, indent + 1, opt);
            json_write_value(builder, <<v.array_val[i], indent + 1, opt);
        }
        if opt.pretty print_to_builder(builder, "\n");
        json_write_indent(builder, indent, opt);
        print_to_builder(builder, "]");
        return;
    }
    if v.kind == .Object {
        if v.object_val.count == 0 {
            print_to_builder(builder, "{}");
            return;
        }
        print_to_builder(builder, "{");
        i := 0;
        for v.object_val {
            if i > 0 print_to_builder(builder, ",");
            if opt.pretty print_to_builder(builder, "\n");
            json_write_indent(builder, indent + 1, opt);
            print_to_builder(builder, "\"");
            json_escape_into(builder, it_index);
            print_to_builder(builder, "\":");
            if opt.pretty print_to_builder(builder, " ");
            json_write_value(builder, <<it, indent + 1, opt);
            i += 1;
        }
        if opt.pretty print_to_builder(builder, "\n");
        json_write_indent(builder, indent, opt);
        print_to_builder(builder, "}");
        return;
    }
}

json_marshal :: (root: Json_Value, opt: Marshal_Options) -> string {
    builder: String_Builder;
    json_write_value(*builder, root, 0, opt);
    return builder_to_string(*builder);
}
//@endregion

//@region Value 树 API —— 编辑器场景

// 把 JSON 文件解析为 Value 树。
// allocator 推荐传 arena（编辑器场景），释放时整体回收即可（此时不要调 json_destroy_value）。
json_load :: (path: string, allocator: Allocator = context.allocator) -> (Json_Value, Json_Error) {
    data, read_ok := read_entire_file(path);
    if !read_ok {
        return json_value_new(), .File_Not_Found;
    }
    defer free(data);

    value, ok := json_parse(data, allocator);
    if !ok return json_value_new(), .Parse_Error;
    return value, .None;
}

// 把 Value 树写回文件。pretty 默认开启。
json_save :: (path: string, root: Json_Value, opt := DEFAULT_MARSHAL_OPT) -> Json_Error {
    options := opt;
    if options.spec != .JSON options.spec = .JSON; // 只支持标准 JSON
    data := json_marshal(root, options);
    defer free(data);
    if !write_entire_file(path, data) return .Write_Error;
    return .None;
}

// 释放 Value 树（递归释放内部 Object/Array/String 的分配）。
//
// 所有权：只适用于"全树都由 json_load 在堆上解析、未混入字面量"的纯场景。
// 编辑器场景建议用 arena 装载（字面量键/值都安全），整体 arena_destroy 回收，不要调本 proc。
json_destroy_value :: (v: Json_Value) {
    if v.kind == .Array {
        for i: 0..v.array_val.count - 1 {
            json_destroy_value(<<v.array_val[i]);
            free(cast(*void) v.array_val[i]);
        }
        array_free(v.array_val);
    } else if v.kind == .Object {
        for v.object_val {
            json_destroy_value(<<it);
            free(cast(*void) it);
            if it_index.count > 0 free(it_index);
        }
        deinit(*v.object_val);
    } else if v.kind == .String {
        if v.string_val.count > 0 free(v.string_val);
    }
}

// 构造辅助（编辑器往树里塞值时用）。
// 直接用字符串字面量构造 .String 会在 destroy_value 时崩溃（字面量是静态内存，不能 free）；
// 用本 proc 克隆到堆。
json_string :: (s: string) -> string {
    return copy_string(s);
}
//@endregion

//@region Struct API —— 类型化配置/存档场景

// JSON 文件 -> struct。struct 自身持有数据；其内部动态分配由调用方管理。
json_load_struct :: (path: string, ptr: *$T) -> Json_Error {
    data, read_ok := read_entire_file(path);
    if !read_ok return .File_Not_Found;
    defer free(data);

    value, ok := json_parse(data, context.allocator);
    if !ok return .Parse_Error;

    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(T);
    if !json_value_to_struct(value, cast(*void) ptr, info) {
        json_destroy_value(value);
        return .Parse_Error;
    }
    return .None;
}

// struct -> JSON 文件。pretty 默认开启。
json_save_struct :: (path: string, ptr: *$T, opt := DEFAULT_MARSHAL_OPT) -> Json_Error {
    options := opt;
    if options.spec != .JSON options.spec = .JSON;
    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(T);
    value := json_struct_to_value(cast(*void) ptr, info);
    data := json_marshal(value, options);
    json_destroy_value(value);
    defer free(data);
    if !write_entire_file(path, data) return .Write_Error;
    return .None;
}

json_value_to_struct :: (v: Json_Value, ptr: *void, info: *Type_Info_Struct) -> bool {
    if v.kind != .Object {
        return false;
    }
    for *member: info.members {
        found, val := table_find(*v.object_val, member.name);
        if !found {
            continue;
        }
        member_ptr := cast(*u8) ptr + member.offset_in_bytes;
        if !json_set_member(cast(*void) member_ptr, member.type, <<val) {
            // 类型不匹配的可选字段直接跳过（与旧实现一致）
        }
    }
    return true;
}

json_set_member :: (ptr: *void, ti: *Type_Info, v: Json_Value) -> bool {
    if ti.type == .INTEGER {
        if v.kind != .Integer return false;
        int_info := cast(*Type_Info_Integer) ti;
        iv := v.int_val;
        if int_info.signed {
            if ti.runtime_size == {
                case 1;
                    <<(cast(*s8) ptr) = cast(s8) iv;
                case 2;
                    <<(cast(*s16) ptr) = cast(s16) iv;
                case 4;
                    <<(cast(*s32) ptr) = cast(s32) iv;
                case 8;
                    <<(cast(*s64) ptr) = iv;
                case;
                    return false;
            }
        } else {
            if ti.runtime_size == {
                case 1;
                    <<(cast(*u8) ptr) = cast(u8) iv;
                case 2;
                    <<(cast(*u16) ptr) = cast(u16) iv;
                case 4;
                    <<(cast(*u32) ptr) = cast(u32) iv;
                case 8;
                    <<(cast(*u64) ptr) = cast(u64) iv;
                case;
                    return false;
            }
        }
        return true;
    }

    if ti.type == .FLOAT {
        number: float64;
        if v.kind == .Integer {
            number = cast(float64) v.int_val;
        } else if v.kind == .Float {
            number = v.number_val;
        } else {
            return false;
        }
        if ti.runtime_size == {
            case 4;
                <<(cast(*float32) ptr) = cast(float32) number;
            case 8;
                <<(cast(*float64) ptr) = number;
            case;
                return false;
        }
        return true;
    }

    if ti.type == .BOOL {
        if v.kind != .Boolean return false;
        <<(cast(*bool) ptr) = v.bool_val;
        return true;
    }

    if ti.type == .STRING {
        if v.kind != .String return false;
        <<(cast(*string) ptr) = v.string_val;
        return true;
    }

    if ti.type == .ENUM {
        if v.kind != .Integer return false;
        enum_info := cast(*Type_Info_Enum) ti;
        iv := v.int_val;
        if enum_info.internal_type.runtime_size == {
            case 1;
                <<(cast(*u8) ptr) = cast(u8) iv;
            case 2;
                <<(cast(*u16) ptr) = cast(u16) iv;
            case 4;
                <<(cast(*u32) ptr) = cast(u32) iv;
            case 8;
                <<(cast(*u64) ptr) = cast(u64) iv;
            case;
                return false;
        }
        return true;
    }

    if ti.type == .STRUCT {
        return json_value_to_struct(v, ptr, cast(*Type_Info_Struct) ti);
    }

    if ti.type == .ARRAY {
        return json_set_array_member(v, ptr, cast(*Type_Info_Array) ti);
    }

    if ti.type == .VARIANT {
        variant_info := cast(*Type_Info_Variant) ti;
        return json_set_member(ptr, variant_info.variant_of, v);
    }

    return false;
}

// 数组反射（定长 [N] T、可增长 [..] T、视图 [] T）。
// 可增长数组与视图都以 { count: s64, data: *void } 开头。
json_set_array_member :: (v: Json_Value, ptr: *void, info: *Type_Info_Array) -> bool {
    if v.kind != .Array {
        return false;
    }
    elem_size := info.element_type.runtime_size;
    if info.array_type == .FIXED {
        n := v.array_val.count;
        if n > info.array_count n = info.array_count;
        for i: 0..n - 1 {
            _ = json_set_member(cast(*u8) ptr + i * elem_size, info.element_type, <<v.array_val[i]);
        }
        return true;
    }

    ra := cast(*Resizable_Array) ptr;
    ra.count = 0;
    if !ra.allocator.proc {
        ra.allocator = context.allocator;
    }
    for i: 0..v.array_val.count - 1 {
        if ra.count >= ra.allocated {
            new_allocated := ra.allocated * 2;
            if new_allocated < 8 new_allocated = 8;
            new_data := ra.allocator.proc(.RESIZE, new_allocated * elem_size, ra.allocated * elem_size, ra.data, ra.allocator.data);
            if new_data == null return false;
            ra.data = new_data;
            ra.allocated = new_allocated;
        }
        item_ptr := cast(*u8) ra.data + ra.count * elem_size;
        if !json_set_member(cast(*void) item_ptr, info.element_type, <<v.array_val[i]) {
            return false;
        }
        ra.count += 1;
    }
    return true;
}

json_struct_to_value :: (ptr: *void, info: *Type_Info_Struct) -> Json_Value {
    result: Json_Value;
    result.kind = .Object;
    for *member: info.members {
        member_ptr := cast(*u8) ptr + member.offset_in_bytes;
        value := json_member_to_value(cast(*void) member_ptr, member.type);
        node := json_node_new(context.allocator);
        <<node = value;
        // 键也复制到堆：json_destroy_value 统一按「键归 Value 树所有」释放。
        table_set(*result.object_val, copy_string(member.name), node);
    }
    return result;
}

json_member_to_value :: (ptr: *void, ti: *Type_Info) -> Json_Value {
    if ti.type == .INTEGER {
        int_info := cast(*Type_Info_Integer) ti;
        iv: s64 = 0;
        if int_info.signed {
            if ti.runtime_size == {
                case 1;
                    iv = cast(s64) <<(cast(*s8) ptr);
                case 2;
                    iv = cast(s64) <<(cast(*s16) ptr);
                case 4;
                    iv = cast(s64) <<(cast(*s32) ptr);
                case 8;
                    iv = <<(cast(*s64) ptr);
            }
        } else {
            if ti.runtime_size == {
                case 1;
                    iv = cast(s64) <<(cast(*u8) ptr);
                case 2;
                    iv = cast(s64) <<(cast(*u16) ptr);
                case 4;
                    iv = cast(s64) <<(cast(*u32) ptr);
                case 8;
                    iv = cast(s64) <<(cast(*u64) ptr);
            }
        }
        return .{ kind = .Integer, int_val = iv };
    }

    if ti.type == .FLOAT {
        if ti.runtime_size == {
            case 4;
                return .{ kind = .Float, number_val = cast(float64) <<(cast(*float32) ptr) };
            case 8;
                return .{ kind = .Float, number_val = <<(cast(*float64) ptr) };
        }
        return json_value_new();
    }

    if ti.type == .BOOL {
        return .{ kind = .Boolean, bool_val = <<(cast(*bool) ptr) };
    }

    if ti.type == .STRING {
        // 复制到堆：json_destroy_value 会释放 .String 的值，借用 struct 里的原字符串会变成非法 free。
        return .{ kind = .String, string_val = copy_string(<<(cast(*string) ptr)) };
    }

    if ti.type == .ENUM {
        enum_info := cast(*Type_Info_Enum) ti;
        ev: s64 = 0;
        if enum_info.internal_type.runtime_size == {
            case 1;
                ev = cast(s64) <<(cast(*u8) ptr);
            case 2;
                ev = cast(s64) <<(cast(*u16) ptr);
            case 4;
                ev = cast(s64) <<(cast(*u32) ptr);
            case 8;
                ev = cast(s64) <<(cast(*u64) ptr);
        }
        return .{ kind = .Integer, int_val = ev };
    }

    if ti.type == .STRUCT {
        return json_struct_to_value(ptr, cast(*Type_Info_Struct) ti);
    }

    if ti.type == .ARRAY {
        return json_array_to_value(ptr, cast(*Type_Info_Array) ti);
    }

    if ti.type == .VARIANT {
        variant_info := cast(*Type_Info_Variant) ti;
        return json_member_to_value(ptr, variant_info.variant_of);
    }

    return json_value_new();
}

json_array_to_value :: (ptr: *void, info: *Type_Info_Array) -> Json_Value {
    result: Json_Value;
    result.kind = .Array;
    elem_size := info.element_type.runtime_size;
    if info.array_type == .FIXED {
        for i: 0..info.array_count - 1 {
            item := json_member_to_value(cast(*u8) ptr + i * elem_size, info.element_type);
            node := json_node_new(context.allocator);
            <<node = item;
            array_add(*result.array_val, node);
        }
        return result;
    }

    ra := cast(*Resizable_Array) ptr;
    data := cast(*u8) ra.data;
    for i: 0..ra.count - 1 {
        item := json_member_to_value(data + i * elem_size, info.element_type);
        node := json_node_new(context.allocator);
        <<node = item;
        array_add(*result.array_val, node);
    }
    return result;
}
//@endregion
