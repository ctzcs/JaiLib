// csv.jai
// Port of Ascension/tlib/encoding/csv.odin
// Minimal CSV loading with reflection-driven struct filling.
//
// Odin used core:encoding/csv + reflect; the Jai port provides its own small
// CSV parser (quotes, commas, \r\n) and uses Type_Info reflection to fill
// struct fields by name. Jai has no struct tags, so the CSV column name must
// match the field name.

#import "Basic";
#import "Hash_Table";
#import "String";
#import "File";

Csv_Error :: enum u32 {
    None;
    File_Not_Found;
    Empty;
    Parse_Error;
}

Csv_Document :: struct {
    headers: [] string;
    rows:    [..] [] string;
}

Csv_Manager :: struct {
    documents: Table(string, *Csv_Document);
}

csv_manager_init :: (m: *Csv_Manager) {
    <<m = .{};
}

csv_manager_destroy :: (m: *Csv_Manager) {
    for m.documents {
        array_free(it.rows);
        free(it);
    }
    deinit(*m.documents);
}

// Minimal CSV parser: handles quoted fields, doubled-quote escapes, commas
// and \r\n / \n line endings.
csv_parse :: (text: string) -> [..] [] string {
    result: [..] [] string;
    current_row: [..] string;
    field_start := 0;
    in_quotes := false;
    i := 0;
    while i <= text.count {
        at_end := i == text.count;
        c: u8 = 0;
        if !at_end {
            c = text[i];
        }

        if in_quotes {
            if at_end {
                array_add(*current_row, slice(text, field_start, text.count - field_start));
                array_add(*result, current_row);
                break;
            }
            if c == "\""[0] {
                if i + 1 < text.count && text[i + 1] == "\""[0] {
                    i += 2;
                    continue;
                }
                in_quotes = false;
            }
        } else {
            if c == "\""[0] {
                in_quotes = true;
            } else if c == ","[0] || c == "\n"[0] || at_end {
                // Skip a phantom empty field at the very end (trailing newline).
                if !(at_end && field_start == i) {
                    end := i;
                    if c == "\n"[0] && end > 0 && text[end - 1] == "\r"[0] {
                        end -= 1;
                    }
                    field := slice(text, field_start, end - field_start);
                    if field.count >= 2 && field[0] == "\""[0] && field[field.count - 1] == "\""[0] {
                        field = slice(field, 1, field.count - 2);
                    }
                    array_add(*current_row, field);
                }
                field_start = i + 1;

                if c == "\n"[0] || at_end {
                    if current_row.count > 0 {
                        // Deep-copy the row: [..] arrays share their data pointer,
                        // and current_row is reused for subsequent rows.
                        new_row: [..] string;
                        array_copy(*new_row, cast([] string) current_row);
                        array_add(*result, new_row);
                        array_reset_keeping_memory(*current_row);
                    }
                    field_start = i + 1;
                }
            }
        }
        i += 1;
    }
    return result;
}

// Reads a CSV file, caching the parsed document in the manager.
csv_manager_load :: (m: *Csv_Manager, path: string) -> (*Csv_Document, Csv_Error) {
    doc, found := table_find(*m.documents, path);
    if found {
        return doc, .None;
    }

    data, ok := read_entire_file(path);
    if !ok {
        return null, .File_Not_Found;
    }

    records := csv_parse(data);
    if records.count == 0 {
        return null, .Empty;
    }

    doc = New(Csv_Document);
    doc.headers = records[0];
    for i: 1..records.count-1 {
        array_add(*doc.rows, records[i]);
    }

    table_add(*m.documents, path, doc);
    return doc, .None;
}

// Single-row config: fills the first data row into a struct.
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

// Multi-row table: one struct per data row.
csv_manager_load_table :: (m: *Csv_Manager, path: string, $T: Type) -> ([] T, Csv_Error) {
    doc, err := csv_manager_load(m, path);
    if err != .None {
        zero: [] T;
        return zero, err;
    }

    result: [..] T;
    array_reserve(*result, doc.rows.count);
    for row: doc.rows {
        item: T;
        csv_fill_struct(*item, T, doc.headers, row);
        array_add(*result, item);
    }
    return cast([] T) result, .None;
}

// Maps a row of CSV data onto struct fields, by header name.
csv_fill_struct :: (dst: *void, $T: Type, headers: [] string, row: [] string) {
    col_map: Table(string, int);
    for h, i: headers {
        table_add(*col_map, trim(h), cast(int) i);
    }

    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(T);
    for * member: info.members {
        col_name := member.name;
        col_idx, found := table_find(*col_map, col_name);
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

csv_set_field :: (struct_ptr: *void, member: *Type_Info_Struct_Member, str: string) -> bool {
    ptr := cast(*u8) struct_ptr + member.offset_in_bytes;
    return csv_set_value(cast(*void) ptr, member.type, str);
}

// Writes str into the memory pointed to by ptr, based on the reflected type.
// Supported: integers / floats / bools / strings / enums / fixed arrays.
// Array cells use "|"[0] as the element separator, e.g. "10|20|30".
csv_set_value :: (ptr: *void, ti: *Type_Info, str: string) -> bool {
    if ti.type == .INTEGER {
        int_info := cast(*Type_Info_Integer) ti;
        v, ok, _ := string_to_int(str, base = 10);
        if !ok {
            return false;
        }
        if int_info.signed {
            if ti.runtime_size == {
                case 1; <<(cast(*s8) ptr) = cast(s8) v;
                case 2; <<(cast(*s16) ptr) = cast(s16) v;
                case 4; <<(cast(*s32) ptr) = cast(s32) v;
                case 8; <<(cast(*s64) ptr) = v;
                case; return false;
            }
        } else {
            if ti.runtime_size == {
                case 1; <<(cast(*u8) ptr) = cast(u8) v;
                case 2; <<(cast(*u16) ptr) = cast(u16) v;
                case 4; <<(cast(*u32) ptr) = cast(u32) v;
                case 8; <<(cast(*u64) ptr) = cast(u64) v;
                case; return false;
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
            case 4; <<(cast(*float32) ptr) = cast(float32) v;
            case 8; <<(cast(*float64) ptr) = v;
            case; return false;
        }
        return true;
    }

    if ti.type == .BOOL {
        lower := to_lower_copy(str);
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
        for i: 0..enum_info.names.count-1 {
            if enum_info.names[i] == str {
                val := enum_info.values[i];
                if enum_info.internal_type.runtime_size == {
                    case 1; <<(cast(*u8) ptr) = cast(u8) val;
                    case 2; <<(cast(*u16) ptr) = cast(u16) val;
                    case 4; <<(cast(*u32) ptr) = cast(u32) val;
                    case 8; <<(cast(*u64) ptr) = cast(u64) val;
                    case; return false;
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
        // Distinct / named types: unwrap to the base type and recurse.
        variant_info := cast(*Type_Info_Variant) ti;
        return csv_set_value(ptr, variant_info.variant_of, str);
    }

    return false;
}
