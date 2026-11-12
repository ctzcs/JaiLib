// localization 提供纯数据字符串表与受限复合格式；语言选择、资源来源和缓存失效由调用方决定。
// 一比一移植自 olib core/localization/localization.odin（含它依赖的 ordered_json 中 load 用到的
// 严格 JSON 校验与单层字符串对象解码）。
//
// Jai 侧差异（对外语义不变）：
//   - 无 switch：Error / 类型分派一律用 if 链；枚举比较直接写 .Name。
//   - 无 map：olib 的表本来就是「有序成员数组 + 线性扫描」（README 明确不维护 map、不拷贝资源），
//     这里把成员数组和解码后的字符串字节放进同一块分配，dispose 一次释放。
//   - 字符串是 string（count + *u8，UTF-8），没有 Odin 的 len/raw_data 组合；lookup 返回的
//     仍是借用视图，有效到该表下次成功 load 或 dispose。
//   - 分配器是 Allocator{proc, data}，只有 .ALLOCATE / .FREE 两种模式，失败返回 null 而不是
//     mem.Allocator_Error；所有分配失败统一映射到 Error.Allocation，且保证不留分配。
//   - Odin 的 i64 / u64 / f64 在 Jai 写作 s64 / u64 / float64。
//   - Odin 的 Arg union 在 Jai 里没有运行时标签，这里用标准库 Extensions/Variant 生成等价的
//     带标签联合 Arg；它多一个 void 分支，使零值仍报 .Argument_Type（Odin 的零 union 同样报错）。
//     代价是不能像 Odin 那样直接用聚合字面量构造，写 variant(Arg, 值) 或 set(*arg, 值)。
//   - 浮点文本用标准 Basic 的 FormatFloat：定小数位时与 Odin 的 strconv.write_float 一样，对实际
//     二进制 f64 值做 ties-to-even 十进制舍入；短最短 'g' 的指数阈值 Jai 与 Odin 不同，由
//     localization_g_layout 按 Odin 的规则（exp < -4 || exp >= 6）重排。
//   - 表是调用方 allocator 上的一次整块分配，释放时按块大小归还；Odin 侧则是一棵节点树。
#import "Basic";                     // Allocator / String_Builder / FormatFloat / memcpy
#import "Math";                      // isnan / isinf
#import "Extensions/Variant";        // Arg 的带标签联合

//@region 字符串表与显式回退

Table :: struct {
    root: localization_Value;        // 只读；零值为空表，禁止复制后分别释放。
}

Error :: enum {
    None;
    Invalid_JSON;
    Invalid_Table;
    Invalid_UTF8;
    Syntax;
    Argument_Index;
    Invalid_Format;
    Argument_Type;
    Non_Finite;
    Allocation;
}

// 严格 JSON 的单层对象，所有值必须为字符串（空键、空值合法）。失败保旧。
load :: (table: *Table, data: string, allocator: Allocator) -> Error {
    if !table return .Invalid_Table;

    survey: localization_Root;
    kind, next, ok := localization_json_scan_value(data, 0, 0, *survey);
    if !ok return .Invalid_JSON;
    next = localization_json_skip_space(data, next);
    if next != data.count return .Invalid_JSON;   // 尾随输入
    if kind != .Object return .Invalid_Table;
    if !survey.all_strings return .Invalid_Table;

    // 一次整块分配：成员数组 + 解码后的字符串字节（转义只会变短，data.count 是上界）。
    members_size := localization_align_up(survey.count * size_of(localization_Member), 16);
    block_size := members_size + data.count + 8;
    block := localization_allocate(allocator, block_size);
    if !block return .Allocation;

    candidate: localization_Value;
    candidate.kind = .Object;
    candidate.allocator = allocator;
    candidate.block = block;
    candidate.block_size = block_size;
    candidate.members.count = survey.count;
    candidate.members.data = cast(*localization_Member) block;

    if !localization_json_fill(data, 0, *candidate, cast(*u8) block + members_size) {
        // 校验阶段已排除语法问题，这里只可能是解码后重复的键（如 "k" 与 "\u006b"）。
        localization_release(allocator, block, block_size);
        return .Invalid_JSON;
    }

    dispose(table);
    table.root = candidate;
    return .None;
}

dispose :: (table: *Table) {
    if !table return;
    root := table.root;
    if root.block localization_release(root.allocator, root.block, root.block_size);
    table.root = .{};
}

// 借用结果，只在该表下次成功 load 或 dispose 前有效。空字符串不表示缺键。
lookup :: (table: *Table, key: string) -> (string, bool) {
    if !table return "", false;
    if table.root.kind != .Object return "", false;
    if table.root.members.count > 0 {
        for 0..table.root.members.count - 1 {
            member := table.root.members[it];
            if member.key == key return member.value.text, true;
        }
    }
    return "", false;
}

// 不隐式用 key 当文本；primary/fallback 均可为 nil，没有语言或默认资源策略。
lookup_fallback :: (primary: *Table, fallback: *Table, key: string) -> (string, bool) {
    text, found := lookup(primary, key);
    if found return text, true;
    return lookup(fallback, key);
}
//@endregion

//@region 受限复合格式

// 显式类型避免把整数先转 f64；string 参数只允许无数字 format 的 {n}。
// Odin 侧是 string/i64/u64/f64 的 union；Jai 的 union 没有运行时标签，改用 Variant。
Arg :: Variant(void, string, s64, u64, float64);

// 成功返回独立拥有的 UTF-8 字符串（可为空），用传入的 allocator 释放。
// 失败返回空字符串并释放候选；Error 不拥有内存。参数与格式文本只借用至返回。
format :: (text: string, args: [] Arg, allocator: Allocator) -> (string, Error) {
    if !localization_utf8_valid(text) return "", .Invalid_UTF8;

    buffer: localization_Buffer;
    buffer.allocator = allocator;

    i: s64;
    while i < text.count {
        start := i;
        while i < text.count && text[i] != #char "{" && text[i] != #char "}" i += 1;
        if !localization_buffer_append(*buffer, localization_slice(text, start, i)) {
            localization_buffer_free(*buffer);
            return "", .Allocation;
        }
        if i == text.count break;

        brace := text[i];
        if i + 1 < text.count && text[i + 1] == brace {
            if !localization_buffer_append_byte(*buffer, brace) {
                localization_buffer_free(*buffer);
                return "", .Allocation;
            }
            i += 2;
            continue;
        }
        if brace == #char "}" {
            localization_buffer_free(*buffer);
            return "", .Syntax;
        }
        i += 1;
        if i >= text.count || text[i] < #char "0" || text[i] > #char "9" {
            localization_buffer_free(*buffer);
            return "", .Syntax;
        }

        index: s64;
        overflow := false;
        while i < text.count && text[i] >= #char "0" && text[i] <= #char "9" {
            digit := cast(s64) (text[i] - #char "0");
            if index > (LOCALIZATION_MAX_S64 - digit) / 10 {
                overflow = true;
                break;
            }
            index = index * 10 + digit;
            i += 1;
        }
        if overflow {
            localization_buffer_free(*buffer);
            return "", .Argument_Index;
        }

        pattern := "";
        if i < text.count && text[i] == #char ":" {
            i += 1;
            pattern_start := i;
            while i < text.count && text[i] != #char "}" i += 1;
            pattern = localization_slice(text, pattern_start, i);
            if pattern == "" {
                localization_buffer_free(*buffer);
                return "", .Invalid_Format;
            }
        }

        if i >= text.count || text[i] != #char "}" {
            localization_buffer_free(*buffer);
            return "", .Syntax;
        }
        if index >= args.count {
            localization_buffer_free(*buffer);
            return "", .Argument_Index;
        }
        err := localization_write_arg(*buffer, args[index], pattern);
        if err != Error.None {
            localization_buffer_free(*buffer);
            return "", err;
        }
        i += 1;
    }

    // 成功：字节区整体交给调用方，独立拥有（结果可为空串，此时 data 为空、无需释放）。
    result := string.{ buffer.count, buffer.data };
    return result, .None;
}

// 写一个参数：{n} 只接受 string，{n:0} / {n:0.#} / {n:0.##} / {n:0.00} 的语义与 olib 一致。
localization_write_arg :: (buffer: *localization_Buffer, arg: Arg, pattern: string) -> Error {
    precision: s64 = -1;
    optional := false;
    if pattern == "" {
    } else if pattern == "0" {
        precision = 0;
    } else if pattern == "0.#" {
        precision = 1;
        optional = true;
    } else if pattern == "0.##" {
        precision = 2;
        optional = true;
    } else if pattern == "0.00" {
        precision = 2;
    } else {
        return .Invalid_Format;
    }

    if arg.which == .NONE return .Argument_Type;

    if arg.which == .STRING {
        if pattern != "" return .Argument_Type;
        if !localization_utf8_valid(arg.string_) return .Invalid_UTF8;
        if !localization_buffer_append(buffer, arg.string_) return .Allocation;
        return .None;
    }

    // 整数全程精确，不转浮点；0.00 在整数后补 ".00"，其他格式输出整数原值。
    if arg.which == .S64 {
        scratch: [32] u8;
        text := localization_write_s64(*scratch, arg.s64_);
        if !localization_buffer_append(buffer, text) return .Allocation;
        if pattern == "0.00" {
            if !localization_buffer_append(buffer, ".00") return .Allocation;
        }
        return .None;
    }

    if arg.which == .U64 {
        scratch: [32] u8;
        text := localization_write_u64(*scratch, arg.u64_);
        if !localization_buffer_append(buffer, text) return .Allocation;
        if pattern == "0.00" {
            if !localization_buffer_append(buffer, ".00") return .Allocation;
        }
        return .None;
    }

    if arg.which == .FLOAT64 {
        if isnan(arg.float64_) || isinf(arg.float64_) return .Non_Finite;
        // 最大有限 f64 的固定两位输出 312 字节，加符号仍在栈内；不转整数或乘 100。
        scratch: [LOCALIZATION_FLOAT_TEXT] u8;
        text := localization_write_f64(*scratch, arg.float64_, precision, optional);
        if !localization_buffer_append(buffer, text) return .Allocation;
        return .None;
    }

    return .Argument_Type;
}
//@endregion

//@region 数字文本

LOCALIZATION_FLOAT_TEXT :: 384;
LOCALIZATION_MAX_S64 :: 0x7fff_ffff_ffff_ffff;

// f64 的十进制文本；precision < 0 是最短 'g'，否则是固定小数位的 'f'。
// 收尾顺序与 olib 的 write_arg 一致：先去掉可选尾零，再去掉负零的号。
localization_write_f64 :: (scratch: *[LOCALIZATION_FLOAT_TEXT] u8, value: float64, precision: s64, optional: bool) -> string {
    builder: String_Builder;
    number: FormatFloat;
    number.value = value;
    number.zero_removal = .NO;               // '#' 的收尾由本函数按 olib 的顺序做
    if precision < 0 {
        number.mode = .SHORTEST;
    } else {
        number.mode = .DECIMAL;
        number.trailing_width = precision;
    }
    print_float(*builder, number);

    raw := localization_builder_text(*builder);
    s: string;
    if precision < 0 {
        s = localization_g_layout(raw, scratch);
    } else {
        count := raw.count;
        if count > scratch.count count = scratch.count;
        memcpy(scratch, raw.data, count);
        s = string.{ count, scratch.data };
    }
    free_buffers(*builder);

    if optional {
        while s.count > 0 && s[s.count - 1] == #char "0" s = localization_slice(s, 0, s.count - 1);
        if s.count > 0 && s[s.count - 1] == #char "." s = localization_slice(s, 0, s.count - 1);
    }

    if s.count > 0 && s[0] == #char "-" {
        zero := true;
        if s.count > 1 {
            for 1..s.count - 1 {
                if s[it] != #char "0" && s[it] != #char "." zero = false;
            }
        }
        if zero s = localization_slice(s, 1, s.count);
    }

    return s;
}

// 借用 builder 的连续字节。最短浮点文本不超过 24 字节，固定位最多 313 字节，都落在首块内。
localization_builder_text :: (builder: *String_Builder) -> string {
    count := builder_string_length(builder);
    data := get_buffer_data(get_base_buffer(builder));
    return string.{ count, data };
}

// Odin 的 write_float 用 eprec = 6 决定 'g' 是否转科学计数，Jai 的 SHORTEST 用另一套阈值，
// 所以这里把最短表示的数字与十进制指数取出来，按 Odin 的规则重排（不重新取舍数字）。
localization_g_layout :: (text: string, out: *[LOCALIZATION_FLOAT_TEXT] u8) -> string {
    body := text;
    negative := false;
    if body.count > 0 && body[0] == #char "-" {
        negative = true;
        body = localization_slice(body, 1, body.count);
    }

    exponent_at := body.count;
    if body.count > 0 {
        for 0..body.count - 1 {
            if body[it] == #char "e" || body[it] == #char "E" {
                exponent_at = it;
                break;
            }
        }
    }
    mantissa := localization_slice(body, 0, exponent_at);

    exponent: s64;
    if exponent_at < body.count {
        i := exponent_at + 1;
        negative_exponent := false;
        if i < body.count && (body[i] == #char "+" || body[i] == #char "-") {
            negative_exponent = body[i] == #char "-";
            i += 1;
        }
        while i < body.count && localization_json_is_digit(body[i]) {
            exponent = exponent * 10 + cast(s64) (body[i] - #char "0");
            i += 1;
        }
        if negative_exponent exponent = -exponent;
    }

    point := mantissa.count;
    if mantissa.count > 0 {
        for 0..mantissa.count - 1 {
            if mantissa[it] == #char "." {
                point = it;
                break;
            }
        }
    }
    integer_count := point;

    digits: [32] u8;              // 最短表示最多 17 位有效数字
    digit_count: s64;
    if mantissa.count > 0 {
        for 0..mantissa.count - 1 {
            if mantissa[it] == #char "." continue;
            if digit_count >= digits.count break;
            digits[digit_count] = mantissa[it];
            digit_count += 1;
        }
    }
    decimal_point := integer_count + exponent;

    leading: s64;
    while leading < digit_count && digits[leading] == #char "0" {
        leading += 1;
        decimal_point -= 1;
    }
    while digit_count > leading && digits[digit_count - 1] == #char "0" digit_count -= 1;

    used: s64;
    if negative {
        out.*[used] = #char "-";
        used += 1;
    }

    if digit_count == leading {   // 0 与 -0：全部数字都是零
        out.*[used] = #char "0";
        return string.{ used + 1, out.data };
    }

    count := digit_count - leading;
    single := decimal_point - 1;   // 首位有效数字的十进制指数
    if single < -4 || single >= 6 {
        out.*[used] = digits[leading];
        used += 1;
        if count > 1 {
            out.*[used] = #char ".";
            used += 1;
            if count > 1 {
                for leading + 1..digit_count - 1 {
                    out.*[used] = digits[it];
                    used += 1;
                }
            }
        }
        out.*[used] = #char "e";
        used += 1;
        magnitude := single;
        if magnitude < 0 {
            out.*[used] = #char "-";
            magnitude = -magnitude;
        } else {
            out.*[used] = #char "+";
        }
        used += 1;
        if magnitude >= 100 {
            out.*[used] = cast(u8) (cast(s64) #char "0" + magnitude / 100);
            used += 1;
        }
        out.*[used] = cast(u8) (cast(s64) #char "0" + (magnitude / 10) % 10);
        out.*[used + 1] = cast(u8) (cast(s64) #char "0" + magnitude % 10);
        used += 2;
        return string.{ used, out.data };
    }

    if decimal_point <= 0 {
        out.*[used] = #char "0";
        out.*[used + 1] = #char ".";
        used += 2;
        for 0..(-decimal_point) - 1 {
            out.*[used] = #char "0";
            used += 1;
        }
        for leading..digit_count - 1 {
            out.*[used] = digits[it];
            used += 1;
        }
        return string.{ used, out.data };
    }

    if decimal_point >= count {
        for leading..digit_count - 1 {
            out.*[used] = digits[it];
            used += 1;
        }
        for 0..(decimal_point - count) - 1 {
            out.*[used] = #char "0";
            used += 1;
        }
        return string.{ used, out.data };
    }

    for leading..leading + decimal_point - 1 {
        out.*[used] = digits[it];
        used += 1;
    }
    out.*[used] = #char ".";
    used += 1;
    for leading + decimal_point..digit_count - 1 {
        out.*[used] = digits[it];
        used += 1;
    }
    return string.{ used, out.data };
}

localization_write_s64 :: (scratch: *[32] u8, value: s64) -> string {
    if value < 0 {
        scratch.*[0] = #char "-";
        // 补码取反：Jai 的 cast 会检查溢出，负 s64 不能用 cast(u64) 取位型。
        count := localization_u64_text(scratch.data + 1, (~localization_bits_u64(value)) + 1);
        return string.{ count + 1, scratch.data };
    }
    count := localization_u64_text(scratch.data, cast(u64) value);
    return string.{ count, scratch.data };
}

localization_bits_u64 :: (value: s64) -> u64 {
    return (cast(*u64) *value).*;
}

localization_write_u64 :: (scratch: *[32] u8, value: u64) -> string {
    count := localization_u64_text(scratch.data, value);
    return string.{ count, scratch.data };
}

// 十进制无符号文本，写到 dst，返回字节数。
localization_u64_text :: (dst: *u8, value: u64) -> s64 {
    if value == 0 {
        dst[0] = #char "0";
        return 1;
    }
    digits: [24] u8;
    count: s64;
    rest := value;
    while rest != 0 {
        digits[count] = cast(u8) (cast(u64) #char "0" + rest % 10);
        rest /= 10;
        count += 1;
    }
    for 0..count - 1 dst[it] = digits[count - 1 - it];
    return count;
}
//@endregion

//@region 严格 JSON（load 用到的子集）

localization_Kind :: enum {
    Null;
    Boolean;
    Number;
    String;
    Array;
    Object;
}

localization_Member :: struct {
    key: string;
    value: localization_Value;
}

localization_Value :: struct {
    kind: localization_Kind;          // 表内只有 .Object（根）与 .String（成员值）
    text: string;                     // .String 的解码文本
    members: [] localization_Member;  // .Object 的有序成员，线性扫描
    allocator: Allocator;             // 整块分配的分配器
    block: *void;                     // 成员数组 + 字符串字节
    block_size: s64;
}

// 校验阶段顺带统计的根对象信息（对应 olib 里 oj.Value 的 members 与分配结果）。
localization_Root :: struct {
    count: s64;
    all_strings: bool;
}

// 与 ordered_json 的 MAX_DEPTH 一致：只计容器，根容器为第 1 层。
LOCALIZATION_MAX_DEPTH :: 64;

localization_align_up :: (value: s64, alignment: s64) -> s64 {
    return (value + alignment - 1) / alignment * alignment;
}

localization_slice :: (text: string, begin: s64, end: s64) -> string {
    if end <= begin return string.{ 0, text.data + begin };
    return string.{ end - begin, text.data + begin };
}

localization_allocate :: (allocator: Allocator, size: s64) -> *void {
    if !allocator.proc return null;
    return allocator.proc(.ALLOCATE, size, 0, null, allocator.data);
}

localization_release :: (allocator: Allocator, memory: *void, size: s64) {
    if !allocator.proc || !memory return;
    allocator.proc(.FREE, 0, size, memory, allocator.data);
}

localization_json_skip_space :: (text: string, at: s64) -> s64 {
    while at < text.count {
        byte := text[at];
        if byte != #char " " && byte != #char "\t" && byte != #char "\r" && byte != #char "\n" break;
        at += 1;
    }
    return at;
}

localization_json_is_digit :: (byte: u8) -> bool {
    return byte >= #char "0" && byte <= #char "9";
}

localization_json_hex4 :: (text: string, at: s64) -> (u32, bool) {
    if at + 4 > text.count return 0, false;
    value: u32;
    for 0..3 {
        byte := text[at + it];
        if byte >= #char "0" && byte <= #char "9" {
            value = value * 16 + cast(u32) (byte - #char "0");
        } else if byte >= #char "a" && byte <= #char "f" {
            value = value * 16 + cast(u32) (byte - #char "a") + 10;
        } else if byte >= #char "A" && byte <= #char "F" {
            value = value * 16 + cast(u32) (byte - #char "A") + 10;
        } else {
            return 0, false;
        }
    }
    return value, true;
}

// 校验整个 JSON 文档；根容器的成员数与「值是否全为字符串」通过 collect 带回。
localization_json_scan_value :: (text: string, at: s64, depth: s64, collect: *localization_Root) -> (localization_Kind, s64, bool) {
    at = localization_json_skip_space(text, at);
    if at >= text.count return .Null, at, false;
    byte := text[at];

    if byte == #char "{" {
        if depth >= LOCALIZATION_MAX_DEPTH return .Null, at, false;
        at = localization_json_skip_space(text, at + 1);
        count: s64;
        all_strings := true;
        if at < text.count && text[at] == #char "}" {
            at += 1;
        } else {
            while true {
                if at >= text.count || text[at] != #char "\"" return .Null, at, false;
                key_end, key_ok := localization_json_scan_string(text, at);
                if !key_ok return .Null, key_end, false;
                at = localization_json_skip_space(text, key_end);
                if at >= text.count || text[at] != #char ":" return .Null, at, false;
                kind, value_end, value_ok := localization_json_scan_value(text, at + 1, depth + 1, null);
                if !value_ok return .Null, value_end, false;
                if kind != .String all_strings = false;
                count += 1;
                at = localization_json_skip_space(text, value_end);
                if at < text.count && text[at] == #char "," {
                    // 尾逗号不允许：逗号后必须紧跟键。
                    at = localization_json_skip_space(text, at + 1);
                    if at >= text.count || text[at] != #char "\"" return .Null, at, false;
                    continue;
                }
                if at < text.count && text[at] == #char "}" {
                    at += 1;
                    break;
                }
                return .Null, at, false;
            }
        }
        if depth == 0 && collect {
            collect.count = count;
            collect.all_strings = all_strings;
        }
        return .Object, at, true;
    }

    if byte == #char "[" {
        if depth >= LOCALIZATION_MAX_DEPTH return .Null, at, false;
        at = localization_json_skip_space(text, at + 1);
        if at < text.count && text[at] == #char "]" return .Array, at + 1, true;
        while true {
            kind, value_end, value_ok := localization_json_scan_value(text, at, depth + 1, null);
            if !value_ok return .Null, value_end, false;
            at = localization_json_skip_space(text, value_end);
            if at < text.count && text[at] == #char "," {
                at = localization_json_skip_space(text, at + 1);
                if at >= text.count || text[at] == #char "]" return .Null, at, false;
                continue;
            }
            if at < text.count && text[at] == #char "]" return .Array, at + 1, true;
            return .Null, at, false;
        }
    }

    if byte == #char "\"" {
        end, ok := localization_json_scan_string(text, at);
        return .String, end, ok;
    }

    if byte == #char "-" || localization_json_is_digit(byte) {
        end, ok := localization_json_scan_number(text, at);
        return .Number, end, ok;
    }

    if localization_json_word_at(text, at, "true") return .Boolean, at + 4, true;
    if localization_json_word_at(text, at, "false") return .Boolean, at + 5, true;
    if localization_json_word_at(text, at, "null") return .Null, at + 4, true;

    return .Null, at, false;
}

// 严格 JSON 数字：-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
localization_json_scan_number :: (text: string, at: s64) -> (s64, bool) {
    if at < text.count && text[at] == #char "-" at += 1;
    if at >= text.count return at, false;
    if text[at] == #char "0" {
        at += 1;
    } else if text[at] >= #char "1" && text[at] <= #char "9" {
        while at < text.count && localization_json_is_digit(text[at]) at += 1;
    } else {
        return at, false;
    }
    if at < text.count && text[at] == #char "." {
        at += 1;
        if at >= text.count || !localization_json_is_digit(text[at]) return at, false;
        while at < text.count && localization_json_is_digit(text[at]) at += 1;
    }
    if at < text.count && (text[at] == #char "e" || text[at] == #char "E") {
        at += 1;
        if at < text.count && (text[at] == #char "+" || text[at] == #char "-") at += 1;
        if at >= text.count || !localization_json_is_digit(text[at]) return at, false;
        while at < text.count && localization_json_is_digit(text[at]) at += 1;
    }
    return at, true;
}

localization_json_word_at :: (text: string, at: s64, word: string) -> bool {
    if word.count == 0 return false;
    if at + word.count > text.count return false;
    for 0..word.count - 1 {
        if text[at + it] != word[it] return false;
    }
    return true;
}

// 校验字符串字面量（at 指向开引号）；返回闭合引号之后的位置。
// 逃逸、控制字符、孤立代理项与非法 UTF-8 都判为失败，与 ordered_json 的 valid_string_token 一致。
localization_json_scan_string :: (text: string, at: s64) -> (s64, bool) {
    if at >= text.count || text[at] != #char "\"" return at, false;
    i := at + 1;
    while i < text.count {
        byte := text[i];
        if byte == #char "\"" return i + 1, true;
        if byte < 0x20 return i, false;
        if byte == #char "\\" {
            i += 1;
            if i >= text.count return i, false;
            escape := text[i];
            if escape == #char "u" {
                code, code_ok := localization_json_hex4(text, i + 1);
                if !code_ok return i, false;
                i += 5;
                if code >= 0xdc00 && code <= 0xdfff return i, false;
                if code >= 0xd800 && code <= 0xdbff {
                    if i + 6 > text.count return i, false;
                    if text[i] != #char "\\" || text[i + 1] != #char "u" return i, false;
                    low, low_ok := localization_json_hex4(text, i + 2);
                    if !low_ok || low < 0xdc00 || low > 0xdfff return i, false;
                    i += 6;
                }
                continue;
            }
            if escape == #char "\"" || escape == #char "\\" || escape == #char "/" ||
               escape == #char "b" || escape == #char "f" || escape == #char "n" ||
               escape == #char "r" || escape == #char "t" {
                i += 1;
                continue;
            }
            return i, false;
        }
        length, length_ok := localization_utf8_length(text, i);
        if !length_ok return i, false;
        i += length;
    }
    return i, false;
}

// 把根对象的成员解码进已经分配好的成员数组与字符串字节区；失败只表示解码后重复键。
localization_json_fill :: (text: string, at: s64, value: *localization_Value, data: *u8) -> bool {
    i := localization_json_skip_space(text, at);
    if i >= text.count || text[i] != #char "{" return false;
    i = localization_json_skip_space(text, i + 1);
    if i < text.count && text[i] == #char "}" return value.members.count == 0;

    used: s64;
    index: s64;
    while true {
        if i >= text.count || text[i] != #char "\"" return false;
        key_start := used;
        key_end, key_written := localization_json_decode_string(text, i, data + used);
        used += key_written;
        key := string.{ key_written, data + key_start };

        if index > 0 {
            for 0..index - 1 {
                if value.members[it].key == key return false;
            }
        }

        i = localization_json_skip_space(text, key_end);
        if i >= text.count || text[i] != #char ":" return false;
        i = localization_json_skip_space(text, i + 1);
        if i >= text.count || text[i] != #char "\"" return false;
        value_start := used;
        value_end, value_written := localization_json_decode_string(text, i, data + used);
        used += value_written;

        if index >= value.members.count return false;
        value.members[index].key = key;
        value.members[index].value.kind = .String;
        value.members[index].value.text = string.{ value_written, data + value_start };
        index += 1;

        i = localization_json_skip_space(text, value_end);
        if i < text.count && text[i] == #char "," {
            i = localization_json_skip_space(text, i + 1);
            continue;
        }
        if i < text.count && text[i] == #char "}" break;
        return false;
    }
    return index == value.members.count;
}

// 解码一个已校验过的字符串字面量到 dst；返回闭合引号之后的位置与写入字节数。
localization_json_decode_string :: (text: string, at: s64, dst: *u8) -> (s64, s64) {
    i := at + 1;
    written: s64;
    while i < text.count {
        byte := text[i];
        if byte == #char "\"" {
            i += 1;
            break;
        }
        if byte == #char "\\" {
            escape := text[i + 1];
            i += 2;
            if escape == #char "u" {
                code, _ := localization_json_hex4(text, i);
                i += 4;
                if code >= 0xd800 && code <= 0xdbff {
                    low, _ := localization_json_hex4(text, i + 2);
                    i += 6;
                    code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
                }
                written += localization_utf8_encode(code, dst + written);
                continue;
            }
            (dst + written).* = localization_json_escape_byte(escape);
            written += 1;
            continue;
        }
        length, _ := localization_utf8_length(text, i);
        memcpy(dst + written, text.data + i, length);
        written += length;
        i += length;
    }
    return i, written;
}

localization_json_escape_byte :: (escape: u8) -> u8 {
    if escape == #char "b" return 0x08;
    if escape == #char "f" return 0x0c;
    if escape == #char "n" return 0x0a;
    if escape == #char "r" return 0x0d;
    if escape == #char "t" return 0x09;
    return escape;   // \" \\ \/ 原样
}
//@endregion

//@region UTF-8

// 单个 UTF-8 序列的长度；非法字节、过短编码、代理项与超范围都返回失败。
localization_utf8_length :: (text: string, at: s64) -> (s64, bool) {
    first := text[at];
    if first < 0x80 return 1, true;
    need: s64;
    code: u32;
    if first >= 0xc2 && first <= 0xdf {
        need = 1;
        code = cast(u32) (first & 0x1f);
    } else if first >= 0xe0 && first <= 0xef {
        need = 2;
        code = cast(u32) (first & 0x0f);
    } else if first >= 0xf0 && first <= 0xf4 {
        need = 3;
        code = cast(u32) (first & 0x07);
    } else {
        return 1, false;
    }
    if at + need >= text.count return 1, false;
    for 1..need {
        next := text[at + it];
        if (next & 0xc0) != 0x80 return 1, false;
        code = (code << 6) | cast(u32) (next & 0x3f);
    }
    if need == 1 && code < 0x80 return 1, false;
    if need == 2 && code < 0x800 return 1, false;
    if need == 3 && code < 0x10000 return 1, false;
    if code > 0x10ffff return 1, false;
    if code >= 0xd800 && code <= 0xdfff return 1, false;
    return need + 1, true;
}

localization_utf8_valid :: (text: string) -> bool {
    at: s64;
    while at < text.count {
        length, ok := localization_utf8_length(text, at);
        if !ok return false;
        at += length;
    }
    return true;
}

localization_utf8_encode :: (code: u32, out: *u8) -> s64 {
    if code < 0x80 {
        out[0] = cast(u8) code;
        return 1;
    }
    if code < 0x800 {
        out[0] = cast(u8) (0xc0 | (code >> 6));
        out[1] = cast(u8) (0x80 | (code & 0x3f));
        return 2;
    }
    if code < 0x10000 {
        out[0] = cast(u8) (0xe0 | (code >> 12));
        out[1] = cast(u8) (0x80 | ((code >> 6) & 0x3f));
        out[2] = cast(u8) (0x80 | (code & 0x3f));
        return 3;
    }
    out[0] = cast(u8) (0xf0 | (code >> 18));
    out[1] = cast(u8) (0x80 | ((code >> 12) & 0x3f));
    out[2] = cast(u8) (0x80 | ((code >> 6) & 0x3f));
    out[3] = cast(u8) (0x80 | (code & 0x3f));
    return 4;
}
//@endregion

//@region 输出缓冲（对应 Odin 的 [dynamic]byte）

localization_Buffer :: struct {
    data: *u8;
    count: s64;
    capacity: s64;
    allocator: Allocator;
}

localization_buffer_reserve :: (buffer: *localization_Buffer, extra: s64) -> bool {
    if buffer.count + extra <= buffer.capacity return true;
    needed := buffer.count + extra;
    capacity := buffer.capacity * 2;
    if capacity < needed capacity = needed;
    if capacity < 64 capacity = 64;
    block := localization_allocate(buffer.allocator, capacity);
    if !block return false;
    if buffer.data {
        memcpy(block, buffer.data, buffer.count);
        localization_release(buffer.allocator, buffer.data, buffer.capacity);
    }
    buffer.data = cast(*u8) block;
    buffer.capacity = capacity;
    return true;
}

localization_buffer_append :: (buffer: *localization_Buffer, bytes: string) -> bool {
    if bytes.count == 0 return true;
    if !localization_buffer_reserve(buffer, bytes.count) return false;
    memcpy(buffer.data + buffer.count, bytes.data, bytes.count);
    buffer.count += bytes.count;
    return true;
}

localization_buffer_append_byte :: (buffer: *localization_Buffer, byte: u8) -> bool {
    if !localization_buffer_reserve(buffer, 1) return false;
    (buffer.data + buffer.count).* = byte;
    buffer.count += 1;
    return true;
}

localization_buffer_free :: (buffer: *localization_Buffer) {
    if buffer.data localization_release(buffer.allocator, buffer.data, buffer.capacity);
    buffer.* = .{};
}
//@endregion
