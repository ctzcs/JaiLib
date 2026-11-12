// json.jai
// Port of Ascension/tlib/encoding/json.odin
// JSON loading/saving for the editor and typed configs.
//
// Odin wrapped core:encoding/json; the Jai port provides a small self-contained
// JSON parser / serializer and reflection-driven struct mapping.

#import "Basic";
#import "Hash_Table";
#import "String";
#import "File";

Json_Error :: enum u32 {
    None;
    File_Not_Found;
    Parse_Error;
    Write_Error;
}

Json_Kind :: enum u32 {
    Null;
    Bool;
    Number;
    String;
    Array;
    Object;
}

Json_Value :: struct {
    kind:       Json_Kind;
    bool_val:   bool;
    number_val: float64;
    string_val: string;
    array_val:  [..] *Json_Value;
    object_val: Table(string, *Json_Value);
}

json_value_new :: () -> Json_Value {
    return .{ kind = .Null };
}

// ---- Parser ----

Json_Parser :: struct {
    text: string;
    pos:  int;
}

json_parser_skip_whitespace :: (p: *Json_Parser) {
    while p.pos < p.text.count {
        c := p.text[p.pos];
        if c == " "[0] || c == "\t"[0] || c == "\n"[0] || c == "\r"[0] {
            p.pos += 1;
        } else {
            break;
        }
    }
}

json_parser_parse_string :: (p: *Json_Parser) -> string {
    // p.text[p.pos] == "\""[0]
    p.pos += 1;
    builder: String_Builder;
    while p.pos < p.text.count {
        c := p.text[p.pos];
        if c == "\""[0] {
            p.pos += 1;
            return builder_to_string(*builder);
        } else if c == "\\"[0] {
            p.pos += 1;
            if p.pos >= p.text.count {
                break;
            }
            esc := p.text[p.pos];
            if esc == "u"[0] {
                if p.pos + 4 < p.text.count {
                    hex := slice(p.text, p.pos + 1, 4);
                    code := hex_to_u16(hex);
                    append_utf8(*builder, code);
                    p.pos += 5;
                    continue;
                }
            } else if esc == "n"[0] { print_to_builder(*builder, "\n"); }
            else if esc == "t"[0] { print_to_builder(*builder, "\t"); }
            else if esc == "r"[0] { print_to_builder(*builder, "\r"); }
            else if esc == "b"[0] { append(*builder, cast(u8) 8); }
            else if esc == "f"[0] { append(*builder, cast(u8) 12); }
            else if esc == "/"[0] { print_to_builder(*builder, "/"); }
            else if esc == "\\"[0] { print_to_builder(*builder, "\\"); }
            else if esc == "\""[0] { print_to_builder(*builder, "\""); }
            p.pos += 1;
        } else {
            append(*builder, c);
            p.pos += 1;
        }
    }
    return builder_to_string(*builder);
}

hex_to_u16 :: (hex: string) -> u16 {
    result := 0;
    for c: hex {
        result *= 16;
        if c >= "0"[0] && c <= "9"[0] { result += cast(int) (c - "0"[0]); }
        else if c >= "a"[0] && c <= "f"[0] { result += cast(int) (c - "a"[0]) + 10; }
        else if c >= "A"[0] && c <= "F"[0] { result += cast(int) (c - "A"[0]) + 10; }
    }
    return cast(u16) result;
}

append_utf8 :: (builder: *String_Builder, code: u16) {
    // Note: must append raw bytes. Jai's "%c" formats non-ASCII bytes as
    // "<decimal>c" text, which would corrupt UTF-8 output.
    if code < 0x80 {
        append(builder, cast(u8) code);
    } else if code < 0x800 {
        append(builder, cast(u8) (0xC0 | (code >> 6)));
        append(builder, cast(u8) (0x80 | (code & 0x3F)));
    } else {
        append(builder, cast(u8) (0xE0 | (code >> 12)));
        append(builder, cast(u8) (0x80 | ((code >> 6) & 0x3F)));
        append(builder, cast(u8) (0x80 | (code & 0x3F)));
    }
}

json_parser_parse_number :: (p: *Json_Parser) -> float64 {
    start := p.pos;
    while p.pos < p.text.count {
        c := p.text[p.pos];
        if (c >= "0"[0] && c <= "9"[0]) || c == "-"[0] || c == "+"[0] || c == "."[0] || c == "e"[0] || c == "E"[0] {
            p.pos += 1;
        } else {
            break;
        }
    }
    num_str := slice(p.text, start, p.pos - start);
    v, ok, _ := string_to_float64(num_str);
    if !ok {
        return 0;
    }
    return v;
}

json_parser_parse_value :: (p: *Json_Parser) -> (Json_Value, bool) {
    json_parser_skip_whitespace(p);
    if p.pos >= p.text.count {
        return json_value_new(), false;
    }

    c := p.text[p.pos];
    if c == "{"[0] {
        value, ok := json_parser_parse_object(p);
        return value, ok;
    } else if c == "["[0] {
        value, ok := json_parser_parse_array(p);
        return value, ok;
    } else if c == "\""[0] {
        s := json_parser_parse_string(p);
        return .{ kind = .String, string_val = s }, true;
    } else if c == "t"[0] {
        if p.pos + 4 <= p.text.count && slice(p.text, p.pos, 4) == "true" {
            p.pos += 4;
            return .{ kind = .Bool, bool_val = true }, true;
        }
        return json_value_new(), false;
    } else if c == "f"[0] {
        if p.pos + 5 <= p.text.count && slice(p.text, p.pos, 5) == "false" {
            p.pos += 5;
            return .{ kind = .Bool, bool_val = false }, true;
        }
        return json_value_new(), false;
    } else if c == "n"[0] {
        if p.pos + 4 <= p.text.count && slice(p.text, p.pos, 4) == "null" {
            p.pos += 4;
            return json_value_new(), true;
        }
        return json_value_new(), false;
    } else if (c >= "0"[0] && c <= "9"[0]) || c == "-"[0] {
        v := json_parser_parse_number(p);
        return .{ kind = .Number, number_val = v }, true;
    }

    return json_value_new(), false;
}

json_parser_parse_array :: (p: *Json_Parser) -> (Json_Value, bool) {
    // p.text[p.pos] == "["[0]
    p.pos += 1;
    result: Json_Value;
    result.kind = .Array;

    json_parser_skip_whitespace(p);
    if p.pos < p.text.count && p.text[p.pos] == "]"[0] {
        p.pos += 1;
        return result, true;
    }

    while p.pos < p.text.count {
        item, ok := json_parser_parse_value(p);
        if !ok {
            return json_value_new(), false;
        }
        item_ptr := New(Json_Value);
        <<item_ptr = item;
        array_add(*result.array_val, item_ptr);

        json_parser_skip_whitespace(p);
        if p.pos >= p.text.count {
            return json_value_new(), false;
        }
        if p.text[p.pos] == ","[0] {
            p.pos += 1;
        } else if p.text[p.pos] == "]"[0] {
            p.pos += 1;
            return result, true;
        } else {
            return json_value_new(), false;
        }
    }
    return json_value_new(), false;
}

json_parser_parse_object :: (p: *Json_Parser) -> (Json_Value, bool) {
    // p.text[p.pos] == "{"[0]
    p.pos += 1;
    result: Json_Value;
    result.kind = .Object;

    json_parser_skip_whitespace(p);
    if p.pos < p.text.count && p.text[p.pos] == "}"[0] {
        p.pos += 1;
        return result, true;
    }

    while p.pos < p.text.count {
        json_parser_skip_whitespace(p);
        if p.pos >= p.text.count || p.text[p.pos] != "\""[0] {
            return json_value_new(), false;
        }
        key := json_parser_parse_string(p);

        json_parser_skip_whitespace(p);
        if p.pos >= p.text.count || p.text[p.pos] != ":"[0] {
            return json_value_new(), false;
        }
        p.pos += 1;

        value, ok := json_parser_parse_value(p);
        if !ok {
            return json_value_new(), false;
        }
        value_ptr := New(Json_Value);
        <<value_ptr = value;
        table_add(*result.object_val, key, value_ptr);

        json_parser_skip_whitespace(p);
        if p.pos >= p.text.count {
            return json_value_new(), false;
        }
        if p.text[p.pos] == ","[0] {
            p.pos += 1;
        } else if p.text[p.pos] == "}"[0] {
            p.pos += 1;
            return result, true;
        } else {
            return json_value_new(), false;
        }
    }
    return json_value_new(), false;
}

// ---- Serializer ----

json_escape_string :: (s: string) -> string {
    builder: String_Builder;
    for c: s {
        if c == "\""[0] { print_to_builder(*builder, "\\\""); }
        else if c == "\\"[0] { print_to_builder(*builder, "\\\\"); }
        else if c == "\n"[0] { print_to_builder(*builder, "\\n"); }
        else if c == "\t"[0] { print_to_builder(*builder, "\\t"); }
        else if c == "\r"[0] { print_to_builder(*builder, "\\r"); }
        else { append(*builder, c); }
    }
    return builder_to_string(*builder);
}

json_marshal :: (v: Json_Value, indent: int, pretty: bool) -> string {
    builder: String_Builder;
    json_write_value(*builder, v, indent, pretty);
    return builder_to_string(*builder);
}

json_write_value :: (builder: *String_Builder, v: Json_Value, indent: int, pretty: bool) {
    if v.kind == .Null {
        print_to_builder(builder, "null");
    } else if v.kind == .Bool {
        if v.bool_val {
            print_to_builder(builder, "true");
        } else {
            print_to_builder(builder, "false");
        }
    } else if v.kind == .Number {
        print_to_builder(builder, "%", v.number_val);
    } else if v.kind == .String {
        print_to_builder(builder, "\"%\"", json_escape_string(v.string_val));
    } else if v.kind == .Array {
        if v.array_val.count == 0 {
            print_to_builder(builder, "[]");
            return;
        }
        print_to_builder(builder, "[\n");
        for item, i: v.array_val {
            json_write_indent(builder, indent + 1, pretty);
            json_write_value(builder, <<item, indent + 1, pretty);
            if i < v.array_val.count - 1 {
                print_to_builder(builder, ",");
            }
            print_to_builder(builder, "\n");
        }
        json_write_indent(builder, indent, pretty);
        print_to_builder(builder, "]");
    } else if v.kind == .Object {
        if v.object_val.count == 0 {
            print_to_builder(builder, "{}");
            return;
        }
        print_to_builder(builder, "{\n");
        i := 0;
        for v.object_val {
            json_write_indent(builder, indent + 1, pretty);
            print_to_builder(builder, "\"%\": ", json_escape_string(it_index));
            json_write_value(builder, <<it, indent + 1, pretty);
            if i < v.object_val.count - 1 {
                print_to_builder(builder, ",");
            }
            print_to_builder(builder, "\n");
            i += 1;
        }
        json_write_indent(builder, indent, pretty);
        print_to_builder(builder, "}");
    }
}

json_write_indent :: (builder: *String_Builder, indent: int, pretty: bool) {
    if pretty {
        for 0..indent*4-1 {
            print_to_builder(builder, " ");
        }
    }
}

// ---- Public API ----

// Parses a JSON file into a Json_Value tree.
json_load :: (path: string) -> (Json_Value, Json_Error) {
    data, ok := read_entire_file(path);
    if !ok {
        return json_value_new(), .File_Not_Found;
    }

    parser: Json_Parser;
    parser.text = data;
    value, p_ok := json_parser_parse_value(*parser);
    if !p_ok {
        return json_value_new(), .Parse_Error;
    }
    return value, .None;
}

// Writes a Json_Value tree to a file (pretty-printed).
json_save :: (path: string, root: Json_Value) -> Json_Error {
    out := json_marshal(root, 0, true);
    if !write_entire_file(path, out) {
        return .Write_Error;
    }
    return .None;
}

// Recursively frees a Json_Value tree.
json_destroy_value :: (v: Json_Value) {
    if v.kind == .Array {
        for item: v.array_val {
            json_destroy_value(<<item);
        }
        array_free(v.array_val);
    } else if v.kind == .Object {
        for v.object_val {
            json_destroy_value(<<it);
        }
        deinit(*v.object_val);
    }
}

// Clones a string onto the heap so it can safely be destroyed later.
json_string :: (s: string) -> string {
    result := alloc_string(s.count);
    memcpy(cast(*void) result.data, cast(*void) s.data, s.count);
    return result;
}

// ---- Reflection-driven struct mapping ----

// JSON file -> struct. The struct owns its data; dynamic allocations inside
// are managed by the caller.
json_load_struct :: (path: string, ptr: *$T) -> Json_Error {
    data, ok := read_entire_file(path);
    if !ok {
        return .File_Not_Found;
    }

    parser: Json_Parser;
    parser.text = data;
    value, p_ok := json_parser_parse_value(*parser);
    if !p_ok {
        return .Parse_Error;
    }

    if !json_value_to_struct(value, ptr, cast(*Type_Info_Struct) cast(*Type_Info) type_info(T)) {
        return .Parse_Error;
    }
    return .None;
}

// struct -> JSON file (pretty-printed).
json_save_struct :: (path: string, ptr: *$T) -> Json_Error {
    value := json_struct_to_value(ptr, cast(*Type_Info_Struct) cast(*Type_Info) type_info(T));
    out := json_marshal(value, 0, true);
    json_destroy_value(value);
    if !write_entire_file(path, out) {
        return .Write_Error;
    }
    return .None;
}

json_value_to_struct :: (v: Json_Value, ptr: *void, info: *Type_Info_Struct) -> bool {
    if v.kind != .Object {
        return false;
    }
    for * member: info.members {
        val, found := table_find(*v.object_val, member.name);
        if !found {
            continue;
        }
        member_ptr := cast(*u8) ptr + member.offset_in_bytes;
        if !json_set_member(cast(*void) member_ptr, member.type, val) {
            // ignore type mismatches for optional fields
        }
    }
    return true;
}

json_set_member :: (ptr: *void, ti: *Type_Info, v: Json_Value) -> bool {
    if ti.type == .INTEGER {
        if v.kind != .Number { return false; }
        int_info := cast(*Type_Info_Integer) ti;
        iv := cast(s64) v.number_val;
        if int_info.signed {
            if ti.runtime_size == {
                case 1; <<(cast(*s8) ptr) = cast(s8) iv;
                case 2; <<(cast(*s16) ptr) = cast(s16) iv;
                case 4; <<(cast(*s32) ptr) = cast(s32) iv;
                case 8; <<(cast(*s64) ptr) = iv;
                case; return false;
            }
        } else {
            if ti.runtime_size == {
                case 1; <<(cast(*u8) ptr) = cast(u8) iv;
                case 2; <<(cast(*u16) ptr) = cast(u16) iv;
                case 4; <<(cast(*u32) ptr) = cast(u32) iv;
                case 8; <<(cast(*u64) ptr) = cast(u64) iv;
                case; return false;
            }
        }
        return true;
    }

    if ti.type == .FLOAT {
        if v.kind != .Number { return false; }
        if ti.runtime_size == {
            case 4; <<(cast(*float32) ptr) = cast(float32) v.number_val;
            case 8; <<(cast(*float64) ptr) = v.number_val;
            case; return false;
        }
        return true;
    }

    if ti.type == .BOOL {
        if v.kind != .Bool { return false; }
        <<(cast(*bool) ptr) = v.bool_val;
        return true;
    }

    if ti.type == .STRING {
        if v.kind != .String { return false; }
        <<(cast(*string) ptr) = v.string_val;
        return true;
    }

    if ti.type == .ENUM {
        if v.kind != .Number { return false; }
        enum_info := cast(*Type_Info_Enum) ti;
        iv := cast(s64) v.number_val;
        if enum_info.internal_type.runtime_size == {
            case 1; <<(cast(*u8) ptr) = cast(u8) iv;
            case 2; <<(cast(*u16) ptr) = cast(u16) iv;
            case 4; <<(cast(*u32) ptr) = cast(u32) iv;
            case 8; <<(cast(*u64) ptr) = cast(u64) iv;
            case; return false;
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

// Array reflection (fixed [N] T, resizable [..] T, view [] T).
// Resizable_Array / Array_View_64 both start with { count: s64, data: *void }.
json_set_array_member :: (v: Json_Value, ptr: *void, info: *Type_Info_Array) -> bool {
    if v.kind != .Array {
        return false;
    }
    elem_size := info.element_type.runtime_size;
    if info.array_type == .FIXED {
        n := v.array_val.count;
        if n > info.array_count {
            n = info.array_count;
        }
        for i: 0..n-1 {
            _ = json_set_member(cast(*u8) ptr + i * elem_size, info.element_type, <<(v.array_val[i]));
        }
        return true;
    }

    // RESIZABLE / VIEW share the { count, data } prefix layout.
    ra := cast(*Resizable_Array) ptr;
    ra.count = 0;
    if !ra.allocator.proc {
        ra.allocator = context.allocator;
    }
    for i: 0..v.array_val.count-1 {
        if ra.count >= ra.allocated {
            new_allocated := ra.allocated * 2;
            if new_allocated < 8 {
                new_allocated = 8;
            }
            new_data := ra.allocator.proc(.RESIZE, new_allocated * elem_size, ra.allocated * elem_size, ra.data, ra.allocator.data);
            if new_data == null {
                return false;
            }
            ra.data = new_data;
            ra.allocated = new_allocated;
        }
        item_ptr := cast(*u8) ra.data + ra.count * elem_size;
        if !json_set_member(item_ptr, info.element_type, <<(v.array_val[i])) {
            return false;
        }
        ra.count += 1;
    }
    return true;
}

json_struct_to_value :: (ptr: *void, info: *Type_Info_Struct) -> Json_Value {
    result: Json_Value;
    result.kind = .Object;
    for * member: info.members {
        member_ptr := cast(*u8) ptr + member.offset_in_bytes;
        value := json_member_to_value(cast(*void) member_ptr, member.type);
        value_ptr := New(Json_Value);
        <<value_ptr = value;
        table_add(*result.object_val, member.name, value_ptr);
    }
    return result;
}

json_member_to_value :: (ptr: *void, ti: *Type_Info) -> Json_Value {
    if ti.type == .INTEGER {
        int_info := cast(*Type_Info_Integer) ti;
        iv: s64 = 0;
        if int_info.signed {
            if ti.runtime_size == {
                case 1; iv = cast(s64) <<(cast(*s8) ptr);
                case 2; iv = cast(s64) <<(cast(*s16) ptr);
                case 4; iv = cast(s64) <<(cast(*s32) ptr);
                case 8; iv = <<(cast(*s64) ptr);
            }
        } else {
            if ti.runtime_size == {
                case 1; iv = cast(s64) <<(cast(*u8) ptr);
                case 2; iv = cast(s64) <<(cast(*u16) ptr);
                case 4; iv = cast(s64) <<(cast(*u32) ptr);
                case 8; iv = cast(s64) <<(cast(*u64) ptr);
            }
        }
        return .{ kind = .Number, number_val = cast(float64) iv };
    }

    if ti.type == .FLOAT {
        if ti.runtime_size == {
            case 4; return .{ kind = .Number, number_val = cast(float64) <<(cast(*float32) ptr) };
            case 8; return .{ kind = .Number, number_val = <<(cast(*float64) ptr) };
        }
        return json_value_new();
    }

    if ti.type == .BOOL {
        return .{ kind = .Bool, bool_val = <<(cast(*bool) ptr) };
    }

    if ti.type == .STRING {
        return .{ kind = .String, string_val = <<(cast(*string) ptr) };
    }

    if ti.type == .ENUM {
        enum_info := cast(*Type_Info_Enum) ti;
        ev: s64 = 0;
        if enum_info.internal_type.runtime_size == {
            case 1; ev = cast(s64) <<(cast(*u8) ptr);
            case 2; ev = cast(s64) <<(cast(*u16) ptr);
            case 4; ev = cast(s64) <<(cast(*u32) ptr);
            case 8; ev = cast(s64) <<(cast(*u64) ptr);
        }
        return .{ kind = .Number, number_val = cast(float64) ev };
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
    result := json_value_new();
    result.kind = .Array;
    elem_size := info.element_type.runtime_size;
    if info.array_type == .FIXED {
        for i: 0..info.array_count-1 {
            item := json_member_to_value(cast(*u8) ptr + i * elem_size, info.element_type);
            item_ptr := New(Json_Value);
            <<item_ptr = item;
            array_add(*result.array_val, item_ptr);
        }
        return result;
    }

    ra := cast(*Resizable_Array) ptr;
    data := cast(*u8) ra.data;
    for i: 0..ra.count-1 {
        item := json_member_to_value(data + i * elem_size, info.element_type);
        item_ptr := New(Json_Value);
        <<item_ptr = item;
        array_add(*result.array_val, item_ptr);
    }
    return result;
}
