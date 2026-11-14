// csv.jai
// 一比一移植自 olib core/encoding/csv.odin。
//
// 表驱动配置读取（CSV -> struct）。按字段名把表头映射到 struct 字段，支持多行表
// （每行一个 struct）与单行配置。数组字段在单元格内用 '|' 分隔。
//
// 用法：
//     m: Csv_Manager;
//     csv_manager_init(*m);
//     defer csv_manager_destroy(*m);
//     tables, err := csv_manager_load_table(*m, "leaf.csv", Leaf_Config);
//
// Jai 侧差异（对外语义不变）：
//   - olib 用 core:encoding/csv 的 read_all_from_string；Jai 没有对应标准库，这里自带
//     RFC 4180 解析器（csv_parse_*），并按 Odin reader 的默认配置对齐错误语义：
//       * 空行跳过；行尾 \r\n 归一为 \n；引号字段内的换行保留为多行字段；
//       * 非引号字段里出现裸引号 -> Parse_Error（Odin: Bare_Quote）；
//       * 闭引号后既不是 ',' 也不是行尾 -> Parse_Error（Odin: Quote）；
//       * 引号字段到 EOF 仍未闭合：只有"当前行已经读到内容"时才按 Odin 的行为接受残值，
//         停在行首则算 Parse_Error；
//       * 字段数必须与首条记录一致 -> Parse_Error（Odin 的 fields_per_record 语义）。
//   - odin 的 `csv` struct tag 无法对位（Jai 没有 tag），列名一律等于字段名。
//   - 文档内的字符串在解析时克隆（copy_string），随 csv_manager_destroy 释放；
//     olib 注释里的同一约定在这里是可执行的（不是只靠 GC）。
//   - strconv.parse_i64 -> Basic 的 string_to_int(base = 10)；Odin 侧不检查溢出，
//     这里同样只做 cast（差异：Jai 的 string_to_int 对超界输入会返回失败，字段保持原值）。
//   - reflect.enum_from_name_any -> 遍历 Type_Info_Enum 的 names/values。
//   - `[][]string` -> `[..] [] string`，len(x) -> x.count。
#import "Basic";
#import "Hash_Table";
#import "String";
#import "File";

//@region 数据类型 —— 错误码 / 文档 / 管理器

Csv_Error :: enum u32 {
    None;
    File_Not_Found;
    Empty;
    Parse_Error;
}

// 一份解析后的 CSV：首行是 headers，其余为数据行。
// rows 内的字符串克隆自解析结果，随文档销毁释放。
Csv_Document :: struct {
    headers: [] string;
    rows: [..][] string;
}

// 文档缓存（path -> 文档）。文档由 manager 持有，销毁时统一释放。
Csv_Manager :: struct {
    documents: Table(string, *Csv_Document);
}

csv_manager_init :: (m: *Csv_Manager) {
    <<m = .{};
}

csv_manager_destroy :: (m: *Csv_Manager) {
    for m.documents {
        doc := it;
        for h: doc.headers {
            if h.count > 0 free(h);
        }
        array_free(doc.headers);
        for row_index: 0..doc.rows.count - 1 {
            row := doc.rows[row_index];
            for field_index: 0..row.count - 1 {
                field := row[field_index];
                if field.count > 0 free(field);
            }
            array_free(row);
        }
        array_free(doc.rows);
        free(cast(*void) doc);
    }
    deinit(*m.documents);
}
//@endregion

//@region 解析器 —— RFC 4180，语义对齐 Odin core:encoding/csv

Csv_Parser :: struct {
    text: string;
    pos: int;
}

csv_is_eol :: (p: *Csv_Parser) -> bool {
    if p.pos >= p.text.count return false;
    if p.text[p.pos] == "\n"[0] return true;
    return p.text[p.pos] == "\r"[0] && p.pos + 1 < p.text.count && p.text[p.pos + 1] == "\n"[0];
}

csv_consume_eol :: (p: *Csv_Parser) {
    if p.text[p.pos] == "\n"[0] {
        p.pos += 1;
    } else {
        p.pos += 2;
    }
}

// 非引号字段：读到 ',' 或行尾为止；出现裸引号算错（Odin 的 lazy_quotes = false）。
csv_parse_bare_field :: (p: *Csv_Parser) -> (string, bool) {
    start := p.pos;
    while p.pos < p.text.count {
        c := p.text[p.pos];
        if c == ","[0] || c == "\n"[0] break;
        if c == "\""[0] return "", false;
        p.pos += 1;
    }
    end := p.pos;
    if end > start && p.text[end - 1] == "\r"[0] end -= 1;
    return copy_string(slice(p.text, start, end - start)), true;
}

// 引号字段：'' 转义为 '"'，字段内换行原样保留（多行字段）。
// 到 EOF 未闭合时，若当前行已有内容则按 Odin 的行为接受残值，否则算错。
csv_parse_quoted_field :: (p: *Csv_Parser) -> (string, bool) {
    p.pos += 1; // 开引号
    b: String_Builder;
    defer free_buffers(*b);
    line_has_content := false;
    while true {
        if p.pos >= p.text.count {
            if !line_has_content return "", false;
            return builder_to_string(*b), true;
        }
        c := p.text[p.pos];
        if c == "\""[0] {
            if p.pos + 1 < p.text.count && p.text[p.pos + 1] == "\""[0] {
                append(*b, "\"");
                p.pos += 2;
                line_has_content = true;
                continue;
            }
            p.pos += 1; // 闭引号
            return builder_to_string(*b), true;
        }
        if csv_is_eol(p) {
            append(*b, "\n"); // 行尾归一为 \n
            csv_consume_eol(p);
            line_has_content = false;
            continue;
        }
        append(*b, c);
        p.pos += 1;
        line_has_content = true;
    }
    return "", false; // 不可达：循环只在 return 处退出
}

csv_free_records :: (records: *[..][] string) {
    all := records.*;
    for record_index: 0..all.count - 1 {
        record := all[record_index];
        for field_index: 0..record.count - 1 {
            field := record[field_index];
            if field.count > 0 free(field);
        }
        array_free(record);
    }
    array_free(all);
}

// 解析整个 CSV。空行跳过；字段数与首条记录不一致算错。
csv_parse :: (text: string) -> (records: [..][] string, ok: bool) {
    p: Csv_Parser;
    p.text = text;
    expected := 0; // 0 = 还没定下字段数（Odin 的 fields_per_record = 0）
    while true {
        while p.pos < text.count {
            if csv_is_eol(*p) {
                csv_consume_eol(*p);
                continue;
            }
            break;
        }
        if p.pos >= text.count break;

        fields: [..] string;
        record_ok := true;
        while true {
            field: string;
            if p.text[p.pos] == "\""[0] {
                field, record_ok = csv_parse_quoted_field(*p);
            } else {
                field, record_ok = csv_parse_bare_field(*p);
            }
            if !record_ok break;
            array_add(*fields, field);
            if p.pos >= p.text.count break;
            c := p.text[p.pos];
            if c == ","[0] {
                p.pos += 1;
                continue;
            }
            if csv_is_eol(*p) {
                csv_consume_eol(*p);
                break;
            }
            // 闭引号后面既不是逗号也不是行尾
            record_ok = false;
            break;
        }
        if !record_ok {
            for field: fields {
                if field.count > 0 free(field);
            }
            array_free(fields);
            csv_free_records(*records);
            return records, false;
        }
        if expected == 0 {
            expected = fields.count;
        } else if fields.count != expected {
            for field: fields {
                if field.count > 0 free(field);
            }
            array_free(fields);
            csv_free_records(*records);
            return records, false;
        }
        array_add(*records, fields);
    }
    return records, true;
}
//@endregion

//@region 加载 —— 文件读取与缓存

// 读 CSV 文件并缓存到 manager；重复 load 同一路径直接命中缓存。
// headers 与各行字符串均克隆，不持有文件缓冲。
csv_manager_load :: (m: *Csv_Manager, path: string) -> (*Csv_Document, Csv_Error) {
    found, doc := table_find(*m.documents, path);
    if found {
        return doc, .None;
    }

    data, read_ok := read_entire_file(path);
    if !read_ok {
        return null, .File_Not_Found;
    }
    defer free(data);

    records, parse_ok := csv_parse(data);
    if !parse_ok {
        return null, .Parse_Error;
    }
    if records.count == 0 {
        array_free(records);
        return null, .Empty;
    }

    doc = New(Csv_Document);
    doc.headers = records[0];
    for i: 1..records.count - 1 {
        array_add(*doc.rows, records[i]);
    }
    array_free(records);

    table_add(*m.documents, path, doc);
    return doc, .None;
}

// 单行配置：把第一个数据行填进 struct。
csv_manager_load_struct :: (m: *Csv_Manager, path: string, $T: Type) -> (T, Csv_Error) {
    result: T;
    doc, err := csv_manager_load(m, path);
    if err != .None {
        return result, err;
    }
    if doc.rows.count == 0 {
        return result, .Empty;
    }
    csv_fill_struct(*result, T, doc.headers, doc.rows[0]);
    return result, .None;
}

// 多行表：每行一个 struct，返回切片（刚好大小的分配，用 free(list.data) 归还）。
csv_manager_load_table :: (m: *Csv_Manager, path: string, $T: Type) -> ([] T, Csv_Error) {
    doc, err := csv_manager_load(m, path);
    if err != .None {
        empty: [] T;
        return empty, err;
    }

    result: [..] T;
    array_reserve(*result, doc.rows.count);
    for row: doc.rows {
        item: T;
        csv_fill_struct(*item, T, doc.headers, row);
        array_add(*result, item);
    }
    list: [] T;
    list.data = result.data;
    list.count = result.count;
    return list, .None;
}
//@endregion

// 多行表的返回值由调用方归还（对位 odin 的 delete(tables)）。
csv_free_table :: (rows: [] $T) {
    if rows.count > 0 && rows.data free(cast(*void) rows.data);
}

//@region Struct 映射 —— 表头映射与按类型写入

// 把一行 CSV 数据按表头映射到 struct 字段：
// 列名 = 字段名（Jai 没有 struct tag）；缺列或空单元格跳过。
csv_fill_struct :: (dst: *void, $T: Type, headers: [] string, row: [] string) {
    col_map: Table(string, int);
    defer deinit(*col_map);
    for h, i: headers {
        table_add(*col_map, trim(h), cast(int) i);
    }

    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(T);
    for *member: info.members {
        found, col_idx := table_find(*col_map, member.name);
        if !found || col_idx >= row.count {
            continue;
        }

        str := trim(row[cast(s64) col_idx]);
        if str.count == 0 {
            continue;
        }

        csv_set_field(dst, member, str);
    }
}

// 按字段偏移取指针，再按类型写入。
csv_set_field :: (struct_ptr: *void, member: *Type_Info_Struct_Member, str: string) -> bool {
    ptr := cast(*u8) struct_ptr + member.offset_in_bytes;
    return csv_set_value(cast(*void) ptr, member.type, str);
}

// 按类型把字符串写入 ptr 指向的内存。
// 支持：整数/浮点/布尔/string/enum/定长数组/命名类型。
// 数组单元格内用 '|' 分隔元素，例如 "10|20|30"；不足补零，超出截断。
csv_set_value :: (ptr: *void, ti: *Type_Info, str: string) -> bool {
    if ti.type == .INTEGER {
        int_info := cast(*Type_Info_Integer) ti;
        v, ok, _ := string_to_int(str, base = 10);
        if !ok {
            return false;
        }
        if int_info.signed {
            if ti.runtime_size == {
                case 1;
                    <<(cast(*s8) ptr) = cast(s8) v;
                case 2;
                    <<(cast(*s16) ptr) = cast(s16) v;
                case 4;
                    <<(cast(*s32) ptr) = cast(s32) v;
                case 8;
                    <<(cast(*s64) ptr) = v;
                case;
                    return false;
            }
        } else {
            if ti.runtime_size == {
                case 1;
                    <<(cast(*u8) ptr) = cast(u8) v;
                case 2;
                    <<(cast(*u16) ptr) = cast(u16) v;
                case 4;
                    <<(cast(*u32) ptr) = cast(u32) v;
                case 8;
                    <<(cast(*u64) ptr) = cast(u64) v;
                case;
                    return false;
            }
        }
        return true;
    }

    if ti.type == .FLOAT {
        v, ok, _ := string_to_float64(str);
        if !ok {
            return false;
        }
        if ti.runtime_size == {
            case 4;
                <<(cast(*float32) ptr) = cast(float32) v;
            case 8;
                <<(cast(*float64) ptr) = v;
            case;
                return false;
        }
        return true;
    }

    if ti.type == .BOOL {
        lower := to_lower_copy(str);
        defer free(lower);
        v := (lower == "true") || (str == "1");
        <<(cast(*bool) ptr) = v;
        return true;
    }

    if ti.type == .STRING {
        <<(cast(*string) ptr) = str;
        return true;
    }

    if ti.type == .ENUM {
        enum_info := cast(*Type_Info_Enum) ti;
        for i: 0..enum_info.names.count - 1 {
            if enum_info.names[i] == str {
                val := enum_info.values[i];
                if enum_info.internal_type.runtime_size == {
                    case 1;
                        <<(cast(*u8) ptr) = cast(u8) val;
                    case 2;
                        <<(cast(*u16) ptr) = cast(u16) val;
                    case 4;
                        <<(cast(*u32) ptr) = cast(u32) val;
                    case 8;
                        <<(cast(*u64) ptr) = cast(u64) val;
                    case;
                        return false;
                }
                return true;
            }
        }
        return false;
    }

    if ti.type == .ARRAY {
        array_info := cast(*Type_Info_Array) ti;
        if array_info.array_type != .FIXED {
            return false;
        }
        elem_size := array_info.element_type.runtime_size;
        if elem_size <= 0 {
            return false;
        }
        count := array_info.array_count;
        parts := split(str, "|"[0]);
        defer array_free(parts);
        for p, i: parts {
            if i >= count {
                break;
            }
            ep := cast(*u8) ptr + cast(s64) i * elem_size;
            _ = csv_set_value(cast(*void) ep, array_info.element_type, trim(p));
        }
        return true;
    }

    if ti.type == .VARIANT {
        // distinct / 命名类型：解包到基础类型后递归处理（枚举等会落到 .ENUM 分支）
        variant_info := cast(*Type_Info_Variant) ti;
        return csv_set_value(ptr, variant_info.variant_of, str);
    }

    return false;
}
//@endregion
