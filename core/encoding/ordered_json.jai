// ordered_json.jai
// 一比一移植自 olib core/encoding/ordered_json/ordered_json.odin（package ordered_json）。
//
// 有序、独占所有权的 JSON 树；不借用输入。字段只供读取，修改走下列 API。
// Value 不可按值复制后分别释放；allocator 必须活到 dispose，错误枚举无需释放。
//
// Jai 侧差异（对外语义不变）：
//   - olib 是独立包（package ordered_json），调用写成 ordered_json.decode(...)。
//     Jai 一个目录一个包、module.jai 只做 #load 聚合，所以这些名字进到 encoding 包里，
//     调用写成 encoding.decode(...)。公开名字（Kind / Error / Value / Member / Mode /
//     MAX_DEPTH / get / at / set / remove / insert / replace / erase / decode /
//     decode_replace / encode / dispose / clone / make_* / as_i64 / as_u64）照 olib 不改名；
//     内部辅助一律加 oj_ 前缀，避免与同包的 csv_* / json_* / xml_* 撞名。
//   - olib 用 Odin 的 core:encoding/json tokenizer 做词法、strconv 做数字词法。Jai 没有对应
//     标准库，这里自带词法器（oj_*）：严格 RFC 8259 + （Comments_And_Trailing_Commas 模式）
//     /* */ 与 // 注释 + 尾随逗号，token 的 offset/text 语义与 Odin tokenizer 一致。
//     JSON 词法（数字、字符串转义、gap 只认 RFC 空白）与 olib 逐条对齐，测试里 bad/good 清单
//     即验收标准；json.jai 复用同一套词法器，保证两个入口的词法完全一致。
//   - mem.Allocator → Allocator。Jai 的 Allocator 只有 proc/data 两个字段，失败时返回 null。
//     因此所有分配点都检查 null 并返回 .Allocation（olib 的 Error.Allocation 得以保留），
//     动态数组 items/members 用 oj_array_push 手写增长，不用 array_add（后者在 OOM 时断言终止，
//     无法把失败交回调用方）。olib 的两个 Allocator 失败用例因而可以逐条移植。
//   - `[dynamic]Value` → `[..] Value`（Jai 的动态数组），len(x) → x.count；
//     `delete(v.items)` → oj_array_free(*v.items)；`delete(str, alloc)` →
//     oj_free(alloc, str.data, str.count)。
//   - encode 返回 [] u8（与 olib 的 []byte 对位），并保证它是"刚好"大小的分配：
//     写完后用一次 RESIZE 截到实际长度，调用方用 free_bytes(allocator, data) 归还
//     （对位 Odin 的 `delete(data, allocator)`）。
//   - Odin 的 min(i64) / max(u64) 常量在 Jai 里写成十进制字面量。
#import "Basic";

//@region 数据与生命周期

MAX_DEPTH :: 64;

Kind :: enum u32 {
    Null;
    Boolean;
    Number;
    String;
    Array;
    Object;
}

Mode :: enum u32 {
    Strict;
    Comments_And_Trailing_Commas;
}

Error :: enum u32 {
    None;
    Syntax;
    Invalid_String;
    Invalid_Number;
    Duplicate_Key;
    Depth_Limit;
    Allocation;
    Type_Mismatch;
    Index_Out_Of_Range;
}

// String 的 UTF-8 或 Number 的原始 JSON 词法（text），Array/Object 用 items/members。
Member :: struct {
    key: string;
    value: Value;
}

Value :: struct {
    kind: Kind;
    allocator: Allocator;
    text: string; // String 的 UTF-8 或 Number 的原始 JSON 词法。
    boolean: bool;
    items: [..] Value;
    members: [..] Member;
}

// ---- 分配桥接：Jai 的 Allocator 失败返回 null，全部经这里检查 ----

oj_allocator :: (allocator: Allocator) -> Allocator {
    a := allocator;
    if !a.proc a = context.allocator;
    return a;
}

oj_alloc :: (allocator: Allocator, size: s64) -> *void {
    if size <= 0 return null;
    a := oj_allocator(allocator);
    return a.proc(.ALLOCATE, size, 0, null, a.data);
}

oj_free :: (allocator: Allocator, memory: *void, size: s64) {
    if !memory return;
    a := oj_allocator(allocator);
    a.proc(.FREE, 0, size, memory, a.data);
}

oj_free_string :: (allocator: Allocator, s: string) {
    oj_free(allocator, cast(*void) s.data, s.count);
}

// 对位 olib 的 append(&dynamic, element)：失败返回 false 而不是终止进程。
oj_array_push :: (array: *[..] $T, item: T) -> bool {
    if array.count >= array.allocated {
        new_alloc: s64 = 8;
        if array.allocated > 0 new_alloc = array.allocated * 2;
        a := oj_allocator(array.allocator);
        new_data := a.proc(.RESIZE, new_alloc * size_of(T), array.allocated * size_of(T), array.data, a.data);
        if !new_data return false;
        array.data = cast(*T) new_data;
        array.allocated = new_alloc;
        array.allocator = a;
    }
    array.data[array.count] = item;
    array.count += 1;
    return true;
}

// 对位 olib 的 delete(dynamic_array)。
oj_array_free :: (array: *[..] $T) {
    if array.allocated > 0 && array.data {
        a := oj_allocator(array.allocator);
        a.proc(.FREE, 0, array.allocated * size_of(T), array.data, a.data);
    }
    array.count = 0;
    array.allocated = 0;
    array.data = null;
    array.allocator = .{};
}

// 对位 Odin 的 `delete(data, allocator)`：encode 的返回值用同长度的 allocator 归还。
free_bytes :: (allocator: Allocator, data: [] u8) {
    oj_free(allocator, cast(*void) data.data, data.count);
}

oj_clone_string :: (s: string, allocator: Allocator) -> (string, bool) {
    if s.count == 0 return "", true;
    memory := oj_alloc(allocator, s.count);
    if !memory return "", false;
    memcpy(memory, cast(*void) s.data, s.count);
    return string.{ data = cast(*u8) memory, count = s.count }, true;
}

make_value :: (kind: Kind, allocator: Allocator) -> Value {
    a := oj_allocator(allocator);
    v: Value;
    v.kind = kind;
    v.allocator = a;
    v.items.allocator = a;
    v.members.allocator = a;
    return v;
}

make_boolean :: (value: bool, allocator: Allocator) -> Value {
    v := make_value(.Boolean, allocator);
    v.boolean = value;
    return v;
}

make_string :: (text: string, allocator: Allocator) -> (Value, Error) {
    if !oj_valid_utf8(text) return Value.{}, .Invalid_String;
    owned, ok := oj_clone_string(text, allocator);
    if !ok return Value.{}, .Allocation;
    v := make_value(.String, allocator);
    v.text = owned;
    return v, .None;
}

make_number :: (lexeme: string, allocator: Allocator) -> (Value, Error) {
    if !oj_valid_number(lexeme) return Value.{}, .Invalid_Number;
    owned, ok := oj_clone_string(lexeme, allocator);
    if !ok return Value.{}, .Allocation;
    v := make_value(.Number, allocator);
    v.text = owned;
    return v, .None;
}

// 无符号十进制词法：从 32 字节缓冲尾部往前写，返回起始下标。
// 注意：Jai 不能对 *[32] u8 做元素索引（会按 [32] u8 大小做指针算术），所以走 *u8。
oj_write_u64 :: (digits: *u8, n: u64) -> int {
    i := 32;
    if n == 0 {
        i -= 1;
        digits[i] = cast(u8) 48;
    }
    while n > 0 {
        i -= 1;
        digits[i] = cast(u8) (48 + cast(int) (n % 10));
        n /= 10;
    }
    return i;
}

make_i64 :: (n: s64, allocator: Allocator) -> (Value, Error) {
    buffer: [32] u8;
    digits := cast(*u8) *buffer[0];
    // min(i64) 不能直接 cast(u64)（常量折叠会判定溢出），负数先 -(n+1) 再 +1。
    start: int;
    if n < 0 {
        magnitude := cast(u64) (-(n + 1)) + 1;
        start = oj_write_u64(digits, magnitude) - 1;
        digits[start] = cast(u8) 45; // '-'
    } else {
        start = oj_write_u64(digits, cast(u64) n);
    }
    lexeme := string.{ data = digits + start, count = 32 - start };
    return make_number(lexeme, allocator);
}

make_u64 :: (n: u64, allocator: Allocator) -> (Value, Error) {
    buffer: [32] u8;
    digits := cast(*u8) *buffer[0];
    start := oj_write_u64(digits, n);
    lexeme := string.{ data = digits + start, count = 32 - start };
    return make_number(lexeme, allocator);
}

dispose :: (v: *Value) {
    for *item: v.items {
        dispose(item);
    }
    for *member: v.members {
        oj_free_string(v.allocator, member.key);
        dispose(*member.value);
    }
    oj_array_free(*v.items);
    oj_array_free(*v.members);
    if v.kind == .String || v.kind == .Number {
        oj_free_string(v.allocator, v.text);
    }
    v.* = .{};
}

clone :: (source: *Value, allocator: Allocator) -> (Value, Error) {
    return oj_clone_at(source, allocator, 0);
}

oj_clone_at :: (source: *Value, allocator: Allocator, depth: int) -> (Value, Error) {
    if (source.kind == .Array || source.kind == .Object) && depth >= MAX_DEPTH {
        return Value.{}, .Depth_Limit;
    }
    v := make_value(source.kind, allocator);
    if source.kind == .String {
        text, ok := oj_clone_string(source.text, allocator);
        if !ok return Value.{}, .Allocation;
        v.text = text;
        return v, .None;
    }
    if source.kind == .Number {
        if !oj_valid_number(source.text) return Value.{}, .Invalid_Number;
        text, ok := oj_clone_string(source.text, allocator);
        if !ok return Value.{}, .Allocation;
        v.text = text;
        return v, .None;
    }
    if source.kind == .Boolean {
        v.boolean = source.boolean;
        return v, .None;
    }
    if source.kind == .Array {
        for *item: source.items {
            child, err := oj_clone_at(item, allocator, depth + 1);
            if err != .None {
                dispose(*v);
                return Value.{}, err;
            }
            if !oj_array_push(*v.items, child) {
                dispose(*child);
                dispose(*v);
                return Value.{}, .Allocation;
            }
        }
        return v, .None;
    }
    if source.kind == .Object {
        for *member: source.members {
            key, key_ok := oj_clone_string(member.key, allocator);
            if !key_ok {
                dispose(*v);
                return Value.{}, .Allocation;
            }
            child, err := oj_clone_at(*member.value, allocator, depth + 1);
            if err != .None {
                oj_free_string(allocator, key);
                dispose(*v);
                return Value.{}, err;
            }
            if !oj_array_push(*v.members, Member.{ key = key, value = child }) {
                oj_free_string(allocator, key);
                dispose(*child);
                dispose(*v);
                return Value.{}, .Allocation;
            }
        }
        return v, .None;
    }
    return v, .None; // .Null
}
//@endregion

//@region 查询与事务修改

// 返回借用指针；任何结构性修改、替换或 dispose 后失效。空键合法。
get :: (object: *Value, key: string) -> *Value {
    if object == null || object.kind != .Object return null;
    for *member: object.members {
        if member.key == key return *member.value;
    }
    return null;
}

at :: (array: *Value, index: int) -> *Value {
    if array == null || array.kind != .Array || index < 0 || index >= array.items.count return null;
    return *array.items[index];
}

// 只接受无小数/指数的整数词法，溢出不截断；不经 f64。
as_i64 :: (v: *Value) -> (s64, bool) {
    if v == null || v.kind != .Number || v.text.count == 0 return 0, false;
    negative := v.text[0] == 45; // '-'
    digits := v.text;
    if negative digits = string.{ data = v.text.data + 1, count = v.text.count - 1 };
    limit: u64 = 9223372036854775807;
    if negative limit = 9223372036854775808;
    n, ok := oj_magnitude(digits, limit);
    if !ok return 0, false;
    if negative && n > 0 return -cast(s64) (n - 1) - 1, true;
    return cast(s64) n, true;
}

as_u64 :: (v: *Value) -> (u64, bool) {
    if v == null || v.kind != .Number || v.text.count == 0 || v.text[0] == 45 {
        return 0, false;
    }
    return oj_magnitude(v.text, 18446744073709551615);
}

// 标准 strconv.parse_[iu]64 在当前工具链不检测溢出，读取需显式限界。
oj_magnitude :: (digits: string, limit: u64) -> (u64, bool) {
    if digits.count == 0 return 0, false;
    n: u64 = 0;
    for c: digits {
        if c < 48 || c > 57 return 0, false;
        digit := cast(u64) (c - 48);
        if n > (limit - digit) / 10 return 0, false;
        n = n * 10 + digit;
    }
    return n, true;
}

// 克隆 source（允许自覆盖）；成功覆盖保留键位置，新键追加；失败保旧。
set :: (object: *Value, key: string, source: *Value) -> Error {
    if object.kind != .Object return .Type_Mismatch;
    if !oj_valid_utf8(key) return .Invalid_String;
    child, err := clone(source, object.allocator);
    if err != .None return err;
    old := get(object, key);
    if old != null {
        dispose(old);
        old.* = child;
        return .None;
    }
    owned, key_ok := oj_clone_string(key, object.allocator);
    if !key_ok {
        dispose(*child);
        return .Allocation;
    }
    if !oj_array_push(*object.members, Member.{ key = owned, value = child }) {
        oj_free_string(object.allocator, owned);
        dispose(*child);
        return .Allocation;
    }
    return .None;
}

remove_key :: (object: *Value, key: string) -> bool {
    if object.kind != .Object return false;
    i := 0;
    while i < object.members.count {
        if object.members[i].key == key {
            oj_free_string(object.allocator, object.members[i].key);
            dispose(*object.members[i].value);
            j := i;
            while j < object.members.count - 1 {
                object.members[j] = object.members[j + 1];
                j += 1;
            }
            object.members.count -= 1;
            return true;
        }
        i += 1;
    }
    return false;
}

insert :: (array: *Value, index: int, source: *Value) -> Error {
    if array.kind != .Array return .Type_Mismatch;
    if index < 0 || index > array.items.count return .Index_Out_Of_Range;
    child, err := clone(source, array.allocator);
    if err != .None return err;
    zero: Value;
    if !oj_array_push(*array.items, zero) {
        dispose(*child);
        return .Allocation;
    }
    i := array.items.count - 1;
    while i > index {
        array.items[i] = array.items[i - 1];
        i -= 1;
    }
    array.items[index] = child;
    return .None;
}

replace :: (array: *Value, index: int, source: *Value) -> Error {
    if array.kind != .Array return .Type_Mismatch;
    if index < 0 || index >= array.items.count return .Index_Out_Of_Range;
    child, err := clone(source, array.allocator);
    if err != .None return err;
    dispose(*array.items[index]);
    array.items[index] = child;
    return .None;
}

erase :: (array: *Value, index: int) -> bool {
    if array.kind != .Array || index < 0 || index >= array.items.count return false;
    dispose(*array.items[index]);
    i := index;
    while i < array.items.count - 1 {
        array.items[i] = array.items[i + 1];
        i += 1;
    }
    array.items.count -= 1;
    return true;
}
//@endregion

//@region 词法 —— UTF-8 / 数字 / 字符串（对位 Odin core:encoding/json 的严格子集）

oj_valid_utf8 :: (input: string) -> bool {
    i := 0;
    while i < input.count {
        c := input[i];
        cp: u32;
        n: int;
        minimum: u32;
        if c < 128 {
            cp = c;
            n = 1;
        } else if c >= 194 && c <= 223 {
            cp = c & 31;
            n = 2;
            minimum = 128;
        } else if c >= 224 && c <= 239 {
            cp = c & 15;
            n = 3;
            minimum = 2048;
        } else if c >= 240 && c <= 244 {
            cp = c & 7;
            n = 4;
            minimum = 65536;
        } else {
            return false;
        }
        if i + n > input.count return false;
        j := 1;
        while j < n {
            b := input[i + j];
            if (b & 192) != 128 return false;
            cp = (cp << 6) | (b & 63);
            j += 1;
        }
        if cp < minimum return false;
        // 对位 odin utf8.valid_string：允许控制字符（NUL 等在 JSON 字符串里由
        // oj_valid_string_literal 另行拒绝），但拒绝代理区与超范围码点。
        if (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff return false;
        i += n;
    }
    return true;
}

oj_is_digit :: (c: u8) -> bool {
    return c >= 48 && c <= 57;
}

// 严格 RFC 8259 数字词法（对位 odin json.is_valid_number(s, .JSON)）：
//   -? (0 | [1-9][0-9]*) ( '.' [0-9]+ )? ( [eE] [+-]? [0-9]+ )?
// 不接受 '+'、十六进制、前导/尾随小数点、'NaN'/'Infinity'、下划线。
oj_valid_number :: (str: string) -> bool {
    if str.count == 0 return false;
    i := 0;
    if str[0] == 45 { // '-'
        i = 1;
        if i >= str.count return false;
    }
    if oj_is_digit(str[i]) == false return false;
    if str[i] == 48 {
        i += 1; // 单个 '0'
    } else {
        while i < str.count && oj_is_digit(str[i]) i += 1;
    }
    if i < str.count && str[i] == 46 { // '.'
        i += 1;
        if i >= str.count || !oj_is_digit(str[i]) return false;
        while i < str.count && oj_is_digit(str[i]) i += 1;
    }
    if i < str.count && (str[i] == 101 || str[i] == 69) { // 'e' / 'E'
        i += 1;
        if i < str.count && (str[i] == 43 || str[i] == 45) i += 1;
        if i >= str.count || !oj_is_digit(str[i]) return false;
        while i < str.count && oj_is_digit(str[i]) i += 1;
    }
    return i == str.count;
}

oj_is_hex :: (c: u8) -> bool {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
}

// 4 位十六进制，返回 -1 表示不合法。
oj_hex4 :: (s: string, at: int) -> int {
    if at + 4 > s.count return -1;
    n := 0;
    j := 0;
    while j < 4 {
        c := s[at + j];
        if c >= 48 && c <= 57 n = n * 16 + cast(int) (c - 48);
        else if c >= 65 && c <= 70 n = n * 16 + cast(int) (c - 65) + 10;
        else if c >= 97 && c <= 102 n = n * 16 + cast(int) (c - 97) + 10;
        else return -1;
        j += 1;
    }
    return n;
}

// 对位 odin json.is_valid_string_literal(s, .JSON)：引号成对、转义合法、
// 不含裸控制字符（< 0x20）。`"\'"` 在这里合法，由 oj_valid_string_token 拒掉。
oj_valid_string_literal :: (s: string) -> bool {
    if s.count < 2 return false;
    if s[0] != 34 || s[s.count - 1] != 34 return false;
    i := 1;
    end := s.count - 1;
    while i < end {
        c := s[i];
        if c == 92 { // '\\'
            i += 1;
            if i >= end return false;
            e := s[i];
            if e == 34 || e == 92 || e == 47 || e == 98 || e == 110 || e == 114 || e == 116 || e == 102 {
                i += 1;
                continue;
            }
            if e == 117 { // 'u'
                if i + 4 >= s.count return false;
                j := 1;
                while j <= 4 {
                    if !oj_is_hex(s[i + j]) return false;
                    j += 1;
                }
                i += 5;
                continue;
            }
            return false;
        }
        if c < 32 return false;
        i += 1;
    }
    return true;
}

// 对位 olib 的 valid_string_token：在 literal 合法之上再拒绝
//   - `\'`（JSON 无此转义）
//   - 孤立的低代理、以及没有配对低代理的高代理（标准库会替换成 U+FFFD）
oj_valid_string_token :: (s: string) -> bool {
    if !oj_valid_string_literal(s) return false;
    i := 1;
    end := s.count - 1;
    while i < end {
        if s[i] != 92 {
            i += 1;
            continue;
        }
        i += 1; // 转义字符
        if s[i] == 39 return false; // '\''
        if s[i] != 117 { // 非 'u'
            i += 1;
            continue;
        }
        if i + 4 >= s.count return false;
        r := oj_hex4(s, i + 1);
        if r < 0 return false;
        i += 4; // 最后一位十六进制
        if r >= 0xdc00 && r <= 0xdfff return false;
        if r < 0xd800 || r > 0xdbff {
            i += 1;
            continue;
        }
        if i + 6 >= s.count return false;
        if s[i + 1] != 92 || s[i + 2] != 117 return false;
        low := oj_hex4(s, i + 3);
        if low < 0xdc00 || low > 0xdfff return false;
        i += 6;
        i += 1;
    }
    return true;
}

oj_utf8_encode_at :: (out: *u8, cp: int) -> int {
    if cp < 128 {
        out[0] = cast(u8) cp;
        return 1;
    }
    if cp < 2048 {
        out[0] = cast(u8) (192 | (cp >> 6));
        out[1] = cast(u8) (128 | (cp & 63));
        return 2;
    }
    if cp < 65536 {
        out[0] = cast(u8) (224 | (cp >> 12));
        out[1] = cast(u8) (128 | ((cp >> 6) & 63));
        out[2] = cast(u8) (128 | (cp & 63));
        return 3;
    }
    out[0] = cast(u8) (240 | (cp >> 18));
    out[1] = cast(u8) (128 | ((cp >> 12) & 63));
    out[2] = cast(u8) (128 | ((cp >> 6) & 63));
    out[3] = cast(u8) (128 | (cp & 63));
    return 4;
}
//@endregion

//@region 词法器 —— token 流（对位 odin json.Tokenizer 的严格子集）

Oj_Token_Kind :: enum u32 {
    EOF;
    Invalid;
    Open_Brace;
    Close_Brace;
    Open_Bracket;
    Close_Bracket;
    Colon;
    Comma;
    String;
    Integer;
    Float;
    True;
    False;
    Null;
}

Oj_Token :: struct {
    kind: Oj_Token_Kind;
    offset: int;
    text: string;
}

Oj_Decoder :: struct {
    data: string;
    pos: int;
    mode: Mode;
    token: Oj_Token;
}

// 只认 RFC 8259 空白；Comments_And_Trailing_Commas 模式额外接受 /* */ 与 //。
// 标准 tokenizer 还会跳过 BOM / JSON5 空白、把 NUL 当 EOF；这里不继承这些扩展。
oj_skip_gap :: (d: *Oj_Decoder) -> bool {
    while true {
        if d.pos >= d.data.count return true;
        c := d.data[d.pos];
        if c == 32 || c == 9 || c == 10 || c == 13 {
            d.pos += 1;
            continue;
        }
        if c == 47 && d.mode != .Strict { // '/'
            if d.pos + 1 >= d.data.count return false;
            next := d.data[d.pos + 1];
            if next == 47 { // 单行注释
                d.pos += 2;
                while d.pos < d.data.count && d.data[d.pos] != 10 && d.data[d.pos] != 13 d.pos += 1;
                continue;
            }
            if next == 42 { // 多行注释（不嵌套）
                d.pos += 2;
                found := false;
                while d.pos + 1 < d.data.count {
                    if d.data[d.pos] == 42 && d.data[d.pos + 1] == 47 {
                        d.pos += 2;
                        found = true;
                        break;
                    }
                    d.pos += 1;
                }
                if !found return false;
                continue;
            }
            return false;
        }
        return true;
    }
}

oj_scan_string_token :: (d: *Oj_Decoder, start: int) -> (Oj_Token, Error) {
    d.pos += 1; // 开引号
    closed := false;
    while d.pos < d.data.count {
        c := d.data[d.pos];
        if c == 34 {
            d.pos += 1;
            closed = true;
            break;
        }
        if c == 92 { // '\\'
            d.pos += 2;
            continue;
        }
        d.pos += 1;
    }
    if !closed return Oj_Token.{ kind = .Invalid }, .Syntax;
    token: Oj_Token;
    token.kind = .String;
    token.offset = start;
    token.text = string.{ data = d.data.data + start, count = d.pos - start };
    if !oj_valid_string_token(token.text) return Oj_Token.{ kind = .Invalid }, .Syntax;
    return token, .None;
}

oj_next_token :: (d: *Oj_Decoder) -> (Oj_Token, Error) {
    if !oj_skip_gap(d) return Oj_Token.{ kind = .Invalid }, .Syntax;
    token: Oj_Token;
    token.offset = d.pos;
    if d.pos >= d.data.count {
        token.kind = .EOF;
        return token, .None;
    }
    c := d.data[d.pos];
    if c == 123 {
        d.pos += 1;
        token.kind = .Open_Brace;
    } else if c == 125 {
        d.pos += 1;
        token.kind = .Close_Brace;
    } else if c == 91 {
        d.pos += 1;
        token.kind = .Open_Bracket;
    } else if c == 93 {
        d.pos += 1;
        token.kind = .Close_Bracket;
    } else if c == 58 {
        d.pos += 1;
        token.kind = .Colon;
    } else if c == 44 {
        d.pos += 1;
        token.kind = .Comma;
    } else if c == 34 {
        return oj_scan_string_token(d, token.offset);
    } else if c == 45 || oj_is_digit(c) {
        // 数字：先取最长的 [0-9 + - . e E] 串，再用 oj_valid_number 判定词法。
        d.pos += 1;
        while d.pos < d.data.count {
            n := d.data[d.pos];
            if oj_is_digit(n) || n == 45 || n == 43 || n == 46 || n == 101 || n == 69 {
                d.pos += 1;
                continue;
            }
            break;
        }
        token.text = string.{ data = d.data.data + token.offset, count = d.pos - token.offset };
        if !oj_valid_number(token.text) return Oj_Token.{ kind = .Invalid }, .Syntax;
        is_integer := true;
        for ch: token.text {
            if ch == 46 || ch == 101 || ch == 69 {
                is_integer = false;
                break;
            }
        }
        if is_integer {
            token.kind = .Integer;
        } else {
            token.kind = .Float;
        }
    } else if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 {
        // 标识符串：null / true / false 之外一律非法（NaN、Infinity 走这里）。
        d.pos += 1;
        while d.pos < d.data.count {
            n := d.data[d.pos];
            if (n >= 65 && n <= 90) || (n >= 97 && n <= 122) || oj_is_digit(n) || n == 95 || n == 36 {
                d.pos += 1;
                continue;
            }
            break;
        }
        word := string.{ data = d.data.data + token.offset, count = d.pos - token.offset };
        if word == "null" token.kind = .Null;
        else if word == "true" token.kind = .True;
        else if word == "false" token.kind = .False;
        else return Oj_Token.{ kind = .Invalid }, .Syntax;
        token.text = word;
    } else {
        return Oj_Token.{ kind = .Invalid }, .Syntax;
    }
    if token.text.count == 0 {
        token.text = string.{ data = d.data.data + token.offset, count = d.pos - token.offset };
    }
    return token, .None;
}

oj_advance :: (d: *Oj_Decoder) -> Error {
    token, err := oj_next_token(d);
    if err != .None return err;
    d.token = token;
    return .None;
}
//@endregion

//@region 解码 —— 标准 token 适配与内存解码

// 标准 unquote_string 假定输入大体有效，会替换孤立 surrogate；token 已在词法层严格验证。
oj_read_string :: (d: *Oj_Decoder, allocator: Allocator) -> (string, Error) {
    if d.token.kind != .String return "", .Invalid_String;
    s := d.token.text;
    inner := s.count - 2;
    if inner <= 0 return "", .None;
    memory := oj_alloc(allocator, inner);
    if !memory return "", .Allocation;
    out := cast(*u8) memory;
    n := 0;
    i := 1;
    end := s.count - 1;
    while i < end {
        c := s[i];
        if c != 92 {
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        i += 1; // 转义字符
        if s[i] == 117 { // 'u'
            cp := oj_hex4(s, i + 1);
            i += 5;
            if cp >= 0xd800 && cp <= 0xdbff {
                // 低代理已由 oj_valid_string_token 保证存在
                low := oj_hex4(s, i + 2);
                i += 6;
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
            }
            n += oj_utf8_encode_at(out + n, cp);
            continue;
        }
        e := s[i];
        if e == 98 out[n] = 8;
        else if e == 102 out[n] = 12;
        else if e == 110 out[n] = 10;
        else if e == 114 out[n] = 13;
        else if e == 116 out[n] = 9;
        else out[n] = e; // '"'、'\\'、'/'
        n += 1;
        i += 1;
    }
    if n == 0 {
        oj_free(allocator, memory, inner);
        return "", .None;
    }
    if n < inner {
        // 截到实际长度，dispose 时按 count 归还。
        a := oj_allocator(allocator);
        trimmed := a.proc(.RESIZE, n, inner, memory, a.data);
        if trimmed && trimmed != memory out = cast(*u8) trimmed;
    }
    return string.{ data = out, count = n }, .None;
}

oj_read_value :: (d: *Oj_Decoder, allocator: Allocator, depth: int) -> (Value, Error) {
    v := make_value(.Null, allocator);
    err: Error;
    kind := d.token.kind;
    if kind == .True || kind == .False {
        v.kind = .Boolean;
        v.boolean = kind == .True;
    } else if kind == .Integer || kind == .Float {
        text, ok := oj_clone_string(d.token.text, allocator);
        if !ok return Value.{}, .Allocation;
        v.kind = .Number;
        v.text = text;
    } else if kind == .String {
        text, str_err := oj_read_string(d, allocator);
        if str_err != .None return Value.{}, str_err;
        v.kind = .String;
        v.text = text;
    } else if kind == .Open_Brace || kind == .Open_Bracket {
        if depth >= MAX_DEPTH return Value.{}, .Depth_Limit;
        object := kind == .Open_Brace;
        close: Oj_Token_Kind = .Close_Bracket;
        if object {
            v.kind = .Object;
            close = .Close_Brace;
        } else {
            v.kind = .Array;
        }
        err = oj_advance(d);
        if err != .None {
            dispose(*v);
            return Value.{}, err;
        }
        while d.token.kind != close {
            key: string;
            key_owned := false;
            if object {
                if d.token.kind != .String {
                    dispose(*v);
                    return Value.{}, .Invalid_String;
                }
                key, err = oj_read_string(d, allocator);
                if err != .None {
                    dispose(*v);
                    return Value.{}, err;
                }
                key_owned = true;
                if get(*v, key) != null {
                    oj_free_string(allocator, key);
                    dispose(*v);
                    return Value.{}, .Duplicate_Key;
                }
                err = oj_advance(d);
                if err == .None && d.token.kind != .Colon err = .Syntax;
                if err != .None {
                    oj_free_string(allocator, key);
                    dispose(*v);
                    return Value.{}, err;
                }
                err = oj_advance(d);
                if err != .None {
                    oj_free_string(allocator, key);
                    dispose(*v);
                    return Value.{}, err;
                }
            }
            child, child_err := oj_read_value(d, allocator, depth + 1);
            if child_err != .None {
                if key_owned oj_free_string(allocator, key);
                dispose(*v);
                return Value.{}, child_err;
            }
            pushed := true;
            if object {
                pushed = oj_array_push(*v.members, Member.{ key = key, value = child });
                if pushed key_owned = false; // 键已交给 member，只有成功时才转移所有权
            } else {
                pushed = oj_array_push(*v.items, child);
            }
            if !pushed {
                if key_owned oj_free_string(allocator, key);
                dispose(*child);
                dispose(*v);
                return Value.{}, .Allocation;
            }
            if d.token.kind == close break;
            if d.token.kind != .Comma {
                dispose(*v);
                return Value.{}, .Syntax;
            }
            err = oj_advance(d);
            if err != .None {
                dispose(*v);
                return Value.{}, err;
            }
            if d.token.kind == close && d.mode == .Strict {
                dispose(*v);
                return Value.{}, .Syntax;
            }
        }
    } else if kind != .Null {
        return Value.{}, .Syntax;
    }
    err = oj_advance(d);
    if err != .None {
        dispose(*v);
        return Value.{}, err;
    }
    return v, .None;
}

// 完整消费输入；64 层只计算容器，根容器为第 1 层。失败返回零值。
decode :: (data: string, allocator: Allocator, mode := Mode.Strict) -> (Value, Error) {
    if !oj_valid_utf8(data) return Value.{}, .Invalid_String;
    d: Oj_Decoder;
    d.data = data;
    d.mode = mode;
    err := oj_advance(*d);
    if err != .None return Value.{}, err;
    candidate, read_err := oj_read_value(*d, allocator, 0);
    if read_err != .None return Value.{}, read_err;
    if d.token.kind != .EOF {
        dispose(*candidate);
        return Value.{}, .Syntax;
    }
    return candidate, .None;
}

// dst 可为零值；仅成功后释放旧树，输入可借用旧树中的字符串。
decode_replace :: (dst: *Value, data: string, allocator: Allocator, mode := Mode.Strict) -> Error {
    candidate, err := decode(data, allocator, mode);
    if err != .None return err;
    dispose(dst);
    dst.* = candidate;
    return .None;
}
//@endregion

//@region 内存编码与 pretty

oj_write :: (buf: *[..] u8, s: string) -> Error {
    for c: s {
        if !oj_array_push(buf, c) return .Allocation;
    }
    return .None;
}

oj_write_string :: (buf: *[..] u8, s: string) -> Error {
    if !oj_valid_utf8(s) return .Invalid_String;
    if !oj_array_push(buf, 34) return .Allocation;
    for c: s {
        if c == 34 {
            if !oj_array_push(buf, 92) return .Allocation;
            if !oj_array_push(buf, 34) return .Allocation;
        } else if c == 92 {
            if !oj_array_push(buf, 92) return .Allocation;
            if !oj_array_push(buf, 92) return .Allocation;
        } else if c == 10 {
            if !oj_array_push(buf, 92) return .Allocation;
            if !oj_array_push(buf, 110) return .Allocation;
        } else if c == 13 {
            if !oj_array_push(buf, 92) return .Allocation;
            if !oj_array_push(buf, 114) return .Allocation;
        } else if c == 9 {
            if !oj_array_push(buf, 92) return .Allocation;
            if !oj_array_push(buf, 116) return .Allocation;
        } else if c == 8 {
            if !oj_array_push(buf, 92) return .Allocation;
            if !oj_array_push(buf, 98) return .Allocation;
        } else if c == 12 {
            if !oj_array_push(buf, 92) return .Allocation;
            if !oj_array_push(buf, 102) return .Allocation;
        } else if c < 32 {
            // 其余控制字符统一写成 \u00XX
            hex_digits: [16] u8 = .[48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 65, 66, 67, 68, 69, 70];
            if !oj_array_push(buf, 92) return .Allocation;
            if !oj_array_push(buf, 117) return .Allocation;
            if !oj_array_push(buf, 48) return .Allocation;
            if !oj_array_push(buf, 48) return .Allocation;
            if !oj_array_push(buf, hex_digits[(c >> 4) & 15]) return .Allocation;
            if !oj_array_push(buf, hex_digits[c & 15]) return .Allocation;
        } else {
            if !oj_array_push(buf, c) return .Allocation;
        }
    }
    if !oj_array_push(buf, 34) return .Allocation;
    return .None;
}

oj_indent :: (buf: *[..] u8, depth: int) -> Error {
    if !oj_array_push(buf, 10) return .Allocation;
    i := 0;
    while i < depth {
        if !oj_array_push(buf, 32) return .Allocation;
        if !oj_array_push(buf, 32) return .Allocation;
        i += 1;
    }
    return .None;
}

oj_write_value :: (buf: *[..] u8, v: *Value, depth: int, pretty: bool) -> Error {
    if v.kind == .Null return oj_write(buf, "null");
    if v.kind == .Boolean {
        if v.boolean return oj_write(buf, "true");
        return oj_write(buf, "false");
    }
    if v.kind == .Number {
        if !oj_valid_number(v.text) return .Invalid_Number;
        return oj_write(buf, v.text);
    }
    if v.kind == .String return oj_write_string(buf, v.text);
    if v.kind != .Array && v.kind != .Object return .Syntax;

    if depth >= MAX_DEPTH return .Depth_Limit;
    object := v.kind == .Object;
    open_char: u8 = 91;
    if object open_char = 123;
    if !oj_array_push(buf, open_char) return .Allocation;
    count: int = v.items.count;
    if object count = v.members.count;
    i := 0;
    while i < count {
        if i > 0 {
            if !oj_array_push(buf, 44) return .Allocation;
        }
        if pretty {
            err := oj_indent(buf, depth + 1);
            if err != .None return err;
        }
        if object {
            err := oj_write_string(buf, v.members[i].key);
            if err != .None return err;
            if pretty {
                if !oj_array_push(buf, 58) return .Allocation;
                if !oj_array_push(buf, 32) return .Allocation;
            } else {
                if !oj_array_push(buf, 58) return .Allocation;
            }
            err = oj_write_value(buf, *v.members[i].value, depth + 1, pretty);
            if err != .None return err;
        } else {
            err := oj_write_value(buf, *v.items[i], depth + 1, pretty);
            if err != .None return err;
        }
        i += 1;
    }
    if pretty && count > 0 {
        err := oj_indent(buf, depth);
        if err != .None return err;
    }
    close_char: u8 = 93;
    if object close_char = 125;
    if !oj_array_push(buf, close_char) return .Allocation;
    return .None;
}

// 返回独立 [] u8，调用方用 free_bytes(allocator, data) 归还；无末尾换行。
encode :: (v: *Value, allocator: Allocator, pretty := false) -> (data: [] u8, err: Error) {
    buf: [..] u8;
    buf.allocator = oj_allocator(allocator);
    err = oj_write_value(*buf, v, 0, pretty);
    if err != .None {
        oj_array_free(*buf);
        empty: [] u8;
        return empty, err;
    }
    if buf.count > 0 && buf.allocated > buf.count {
        // 截成刚好大小：调用方按 count 归还，账目才对得上。
        a := oj_allocator(buf.allocator);
        trimmed := a.proc(.RESIZE, buf.count, buf.allocated, buf.data, a.data);
        if trimmed {
            buf.data = cast(*u8) trimmed;
            buf.allocated = buf.count;
        }
    }
    result: [] u8;
    result.data = buf.data;
    result.count = buf.count;
    return result, .None;
}
//@endregion
