#scope_module
using Basic;
using Math;

File :: #import "File";
#scope_export

// Minimal JSON module for the framework's needs (MsdfFont atlases, input
// binding persistence). Parses into a tree of Json values; serializes back.

Json_Kind :: enum {
    NULL_V;
    BOOL_V;
    NUMBER;
    STRING;
    ARRAY;
    OBJECT;
}

Json :: struct {
    kind: Json_Kind = .NULL_V;
    truthy: bool;
    number: float64;
    str: string;
    array: [] Json;
    object: [] Json_Field;
}

Json_Field :: struct {
    name: string;
    value: Json;
}

json_null :: () -> Json {
    return .{ kind = .NULL_V };
}

json_bool :: (v: bool) -> Json {
    return .{ kind = .BOOL_V, truthy = v };
}

json_number :: (v: float64) -> Json {
    return .{ kind = .NUMBER, number = v };
}

json_string :: (v: string) -> Json {
    return .{ kind = .STRING, str = v };
}

json_array :: (v: [] Json) -> Json {
    return .{ kind = .ARRAY, array = v };
}

json_object :: (v: [] Json_Field) -> Json {
    return .{ kind = .OBJECT, object = v };
}

json_is_null :: (v: Json) -> bool {
    return v.kind == .NULL_V;
}

json_parse :: (text: string, allocator := context.allocator) -> Json, bool {
    p: Json_Parser;
    p.text = text;
    p.allocator = allocator;
    v, ok := jp_parse_value(*p);
    if !ok return json_null(), false;
    jp_skip_ws(*p);
    if p.pos < p.text.count return json_null(), false;
    return v, true;
}

json_read_file :: (path: string) -> string, bool {
    text, ok := File.read_entire_file(path);
    return text, ok;
}

json_parse_file :: (path: string, allocator := context.allocator) -> Json, bool {
    text, ok := File.read_entire_file(path);
    if !ok return json_null(), false;
    defer free(text.data);
    value, parsed := json_parse(text, allocator);
    return value, parsed;
}

// Release an owned parse tree with the allocator used by json_parse.
json_destroy :: (value: Json) {
    if value.kind == .STRING {
        free(value.str.data);
    } else if value.kind == .ARRAY {
        for item: value.array json_destroy(item);
        free(value.array.data);
    } else if value.kind == .OBJECT {
        for field: value.object {
            free(field.name.data);
            json_destroy(field.value);
        }
        free(value.object.data);
    }
}

Json_Parser :: struct {
    text: string;
    pos: s32 = 0;
    allocator: Allocator;
}

jp_peek :: (p: *Json_Parser) -> u8 {
    if p.pos >= p.text.count return 0;
    return p.text[p.pos];
}

jp_advance :: (p: *Json_Parser) -> u8 {
    c := jp_peek(p);
    p.pos += 1;
    return c;
}

jp_skip_ws :: (p: *Json_Parser) {
    while p.pos < p.text.count {
        c := p.text[p.pos];
        if c == #char " " || c == #char "\t" || c == #char "\n" || c == #char "\r" p.pos += 1;
        else break;
    }
}

jp_parse_value :: (p: *Json_Parser) -> Json, bool {
    jp_skip_ws(p);
    if p.pos >= p.text.count return json_null(), false;
    c := jp_peek(p);

    if c == 0x7B {
        value, ok := jp_parse_object(p);
        return value, ok;
    }
    if c == 0x5B {
        value, ok := jp_parse_array(p);
        return value, ok;
    }
    if c == 0x22 {
        s, ok := jp_parse_string(p);
        if !ok return json_null(), false;
        return json_string(s), true;
    }
    if c == #char "t" {
        if jp_match(p, "true") return json_bool(true), true;
        return json_null(), false;
    }
    if c == #char "f" {
        if jp_match(p, "false") return json_bool(false), true;
        return json_null(), false;
    }
    if c == #char "n" {
        if jp_match(p, "null") return json_null(), true;
        return json_null(), false;
    }
    value, ok := jp_parse_number(p);
    return value, ok;
}

jp_match :: (p: *Json_Parser, word: string) -> bool {
    if p.pos + cast(s32) word.count > p.text.count return false;
    if memcmp(p.text.data + p.pos, word.data, word.count) != 0 return false;
    p.pos += cast(s32) word.count;
    return true;
}

jp_parse_object :: (p: *Json_Parser) -> Json, bool {
    jp_advance(p);
    fields: [..] Json_Field;
    array_reserve(*fields, 8);
    jp_skip_ws(p);
    if jp_peek(p) == 0x7D {
        jp_advance(p);
        return json_object(fields), true;
    }

    while true {
        jp_skip_ws(p);
        if jp_peek(p) != 0x22 return json_null(), false;
        name, ok := jp_parse_string(p);
        if !ok return json_null(), false;
        jp_skip_ws(p);
        if jp_advance(p) != 0x3A return json_null(), false;
        value, value_ok := jp_parse_value(p);
        if !value_ok return json_null(), false;
        array_add(*fields, .{ name = name, value = value });
        jp_skip_ws(p);
        c := jp_advance(p);
        if c == 0x2C continue;
        if c == 0x7D break;
        return json_null(), false;
    }
    return json_object(fields), true;
}

jp_parse_array :: (p: *Json_Parser) -> Json, bool {
    jp_advance(p);
    items: [..] Json;
    array_reserve(*items, 8);
    jp_skip_ws(p);
    if jp_peek(p) == 0x5D {
        jp_advance(p);
        return json_array(items), true;
    }

    while true {
        value, ok := jp_parse_value(p);
        if !ok return json_null(), false;
        array_add(*items, value);
        jp_skip_ws(p);
        c := jp_advance(p);
        if c == 0x2C continue;
        if c == 0x5D break;
        return json_null(), false;
    }
    return json_array(items), true;
}

jp_parse_string :: (p: *Json_Parser) -> string, bool {
    jp_advance(p);
    start := p.pos;
    while p.pos < p.text.count {
        c := p.text[p.pos];
        if c == 0x22 || c == 0x5C break;
        p.pos += 1;
    }
    if p.pos >= p.text.count return "", false;
    if p.text[p.pos] == 0x22 {
        s := cast(string) copy_slice(cast([] u8) str_slice(p.text, start, p.pos), p.allocator);
        jp_advance(p);
        return s, true;
    }
    buf: String_Builder;
    append(*buf, str_slice(p.text, start, p.pos));
    while true {
        if p.pos >= p.text.count return "", false;
        c := jp_advance(p);
        if c == 0x22 break;
        if c == 0x5C {
            e := jp_advance(p);
            if e == 0x22 append(*buf, 0x22);
            else if e == 0x5C append(*buf, 0x5C);
            else if e == 0x2F append(*buf, 0x2F);
            else if e == #char "b" append(*buf, 0x08);
            else if e == #char "f" append(*buf, 0x0C);
            else if e == #char "n" append(*buf, #char "\n");
            else if e == #char "r" append(*buf, #char "\r");
            else if e == #char "t" append(*buf, #char "\t");
            else if e == #char "u" {
                hex: u32 = 0;
                for i: 0..3 {
                    h := jp_advance(p);
                    hex <<= 4;
                    if h >= #char "0" && h <= #char "9" hex |= cast(u32) (h - #char "0");
                    else if h >= #char "a" && h <= #char "f" hex |= cast(u32) (h - #char "a" + 10);
                    else if h >= #char "A" && h <= #char "F" hex |= cast(u32) (h - #char "A" + 10);
                    else return "", false;
                }
                if hex < 0x80 {
                    append(*buf, cast(u8) hex);
                } else if hex < 0x800 {
                    append(*buf, cast(u8) (0xC0 | (hex >> 6)));
                    append(*buf, cast(u8) (0x80 | (hex & 0x3F)));
                } else {
                    append(*buf, cast(u8) (0xE0 | (hex >> 12)));
                    append(*buf, cast(u8) (0x80 | ((hex >> 6) & 0x3F)));
                    append(*buf, cast(u8) (0x80 | (hex & 0x3F)));
                }
            } else return "", false;
        } else {
            append(*buf, c);
        }
    }
    return builder_to_string(*buf,, allocator = p.allocator), true;
}

jp_parse_number :: (p: *Json_Parser) -> Json, bool {
    start := p.pos;
    if jp_peek(p) == #char "-" jp_advance(p);
    while p.pos < p.text.count {
        c := p.text[p.pos];
        if (c >= #char "0" && c <= #char "9") || c == #char "." || c == #char "e" || c == #char "E" || c == #char "+" || c == #char "-" {
            p.pos += 1;
        } else break;
    }
    if p.pos == start return json_null(), false;
    text := str_slice(p.text, start, p.pos);
    value, ok := string_to_float(text);
    if !ok return json_null(), false;
    return json_number(value), true;
}

str_slice :: (s: string, start: s32, end: s32) -> string {
    count := end - start;
    if start < 0 || count <= 0 || start + count > s.count return "";
    return .{ data = s.data + start, count = count };
}

copy_slice :: (s: [] $T, allocator: Allocator) -> [] T {
    out: [] T = .{ data = cast(*T) alloc(size_of(T) * s.count,, allocator = allocator), count = s.count };
    if s.count > 0 memcpy(out.data, s.data, size_of(T) * s.count);
    return out;
}

json_get :: (v: Json, name: string) -> Json {
    if v.kind == .OBJECT {
        for f: v.object if f.name == name return f.value;
    }
    return json_null();
}

json_get_number :: (v: Json, name: string, default := 0.0) -> float64 {
    f := json_get(v, name);
    if f.kind == .NUMBER return f.number;
    return default;
}

json_get_string :: (v: Json, name: string, default := "") -> string {
    f := json_get(v, name);
    if f.kind == .STRING return f.str;
    return default;
}

json_get_bool :: (v: Json, name: string, default := false) -> bool {
    f := json_get(v, name);
    if f.kind == .BOOL_V return f.truthy;
    return default;
}

json_array_count :: (v: Json) -> s32 {
    if v.kind == .ARRAY return cast(s32) v.array.count;
    return 0;
}

json_array_at :: (v: Json, index: s32) -> Json {
    if v.kind == .ARRAY && index >= 0 && index < v.array.count return v.array[index];
    return json_null();
}

json_write :: (v: Json, builder: *String_Builder) {
    if v.kind == .NULL_V {
        append(builder, "null");
    } else if v.kind == .BOOL_V {
        if v.truthy {
            append(builder, "true");
        } else {
            append(builder, "false");
        }
    } else if v.kind == .NUMBER {
        is_integral := v.number == floor(v.number) && abs(v.number) < 1000000000000000.0;
        if is_integral print(builder, "%", cast(s64) v.number);
        else print(builder, "%", v.number);
    } else if v.kind == .STRING {
        json_write_string(builder, v.str);
    } else if v.kind == .ARRAY {
        append(builder, "[");
        for item, i: v.array {
            if i > 0 append(builder, ",");
            json_write(item, builder);
        }
        append(builder, "]");
    } else if v.kind == .OBJECT {
        append(builder, "{");
        for f, i: v.object {
            if i > 0 append(builder, ",");
            json_write_string(builder, f.name);
            append(builder, ":");
            json_write(f.value, builder);
        }
        append(builder, "}");
    }
}

json_write_string :: (builder: *String_Builder, s: string) {
    append(builder, 0x22);
    for c: s {
        if c == 0x22 append(builder, "\\\"");
        else if c == 0x5C append(builder, "\\\\");
        else if c == #char "\n" append(builder, "\\n");
        else if c == #char "\r" append(builder, "\\r");
        else if c == #char "\t" append(builder, "\\t");
        else if c < 0x20 print(builder, "\\u%04x", cast(u32) c);
        else append(builder, c);
    }
    append(builder, 0x22);
}
