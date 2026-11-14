// hlsl_rules —— 两条来自 shadercross 的 D3D12 规则（解析期文本检查）。
// 一比一移植自 olib kit/rendering/shader/lang/hlsl_rules.odin。
//
// D3D12 按「实际用到的」属性重新编号语义，Vulkan 不会，二者不一致时
// 创建管线失败或画错，而且只在 D3D12 上出现、很难从现象找到原因。解析时按文本检查，给出指向源码行的错误：
//   1. 顶点入口的输入结构体以引擎接口开头：Sprite / instanced Model / skinned Model 各有固定接口；
//   2. 顶点输出里除 SV_ 语义外的成员，都要在片元入口里用到。
// 只认 vertex_main / fragment_main 和 HLSLINCLUDE、HLSLPROGRAM 里的 struct；结构体定义在 #include 的文件里、
// 或片元把整个输入传给别的函数时无法判断，不报错。
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                              | JaiLib (Jai)                                    |
//   | ---------------------------------------- | ----------------------------------------------- |
//   | strings.clone(code.text, temp) + transmute | cast([]u8) copy_string(code.text)（可变副本）     |
//   | strings.index / index_byte                | STRING.find_index_from_left / lang_index_of     |
//   | strings.count(s[:off], "\n")              | lang_count_newlines（逐字节数）                   |
//   | strings.split(text, ",", temp)            | STRING.split(text, ",")（归 temp）               |
//   | strings.trim_space / trim_left_space       | STRING.trim / STRING.trim_left                  |
//   | strings.to_upper(s, temp)                 | STRING.to_upper_copy(s)                         |
//   | strings.has_prefix                        | STRING.begins_with                              |
//   | text[a:b] 切片                             | lang_slice（lang.jai 的字符串视图帮手）            |
//   | min / max（内建）                          | Basic.min / Basic.max                           |
//   | for w in words[:len(words)-1]             | for w: array_view(words, 0, words.count - 1)    |
//   | @(private)                                | 加 hlsl_ 前缀（Jai 没有 private）                  |
#import "Basic";

hlsl_rules_check :: (p: *Parser, pass: sh.Pass_Desc, instanced, skinned: bool, shared, code: Hlsl_Code) {
    if p.error != "" return;
    blocks: [2] Hlsl_Code = .[hlsl_strip_comments(shared), hlsl_strip_comments(code)];
    vertex, vertex_ok := hlsl_entry(blocks, "vertex_main");
    if !vertex_ok return;

    // 规则 1：输入以引擎接口开头。
    head := "";
    if pass.draw == .Sprite {
        head = "OlibSpriteInput";
    } else if pass.draw == .Model && skinned {
        head = "OlibSkinnedInput";
    } else if pass.draw == .Model && instanced {
        head = "OlibInstanceInput";
    }
    if head != "" && vertex.params.count > 0 && vertex.params[0].type != head {
        input, ok := hlsl_struct(blocks, vertex.params[0].type);
        if ok {
            first, has_first := hlsl_first_attribute(input.members);
            if !has_first || first.type != head {
                line := input.line;
                if has_first line = first.line;
                hlsl_fail(p, line, tprint("Pass %: % must start with % (D3D12 renumbers vertex attributes by use, so the engine attributes have to come first)",
                                          pass.id, input.name, head));
                return;
            }
        }
    }

    // 规则 2：传给片元的成员都要用到。
    output, output_ok := hlsl_struct(blocks, vertex.return_type);
    fragment, fragment_ok := hlsl_entry(blocks, "fragment_main");
    if !output_ok || !fragment_ok return;
    name := "";
    for param: fragment.params {
        if param.type == output.name name = param.name;
    }
    if name == "" || hlsl_used_whole(fragment.body, name) return;
    for member: output.members {
        if STRING.begins_with(STRING.to_upper_copy(member.semantic), "SV_") continue;
        if !hlsl_contains_access(fragment.body, name, member.name) {
            hlsl_fail(p, member.line, tprint("Pass %: %.% is passed to fragment_main but never used there (D3D12 drops unused inputs and the stages no longer match); use it or remove it", pass.id, output.name, member.name));
            return;
        }
    }
}

//@region 文本解析：只认这两条规则需要的形状

Hlsl_Param :: struct {
    type, name: string;
}

Hlsl_Entry :: struct {
    return_type: string;
    params: [] Hlsl_Param;
    body: string;
}

Hlsl_Member :: struct {
    type, name, semantic: string;
    line: int; // 源文件行号
}

Hlsl_Struct :: struct {
    name: string;
    members: [] Hlsl_Member;
    line: int;
}

hlsl_fail :: (p: *Parser, line: int, message: string) {
    if p.error == "" p.error = tprint("%:%:1: %", p.path, line, message);
}

// 注释换成空格（保留换行），之后的查找不会命中注释里的文字，行号不变。
hlsl_strip_comments :: (code: Hlsl_Code) -> Hlsl_Code {
    out := cast([] u8) copy_string(code.text);
    i := 0;
    while i < out.count {
        if out[i] == #char "\"" {
            i += 1;
            while i < out.count && out[i] != #char "\"" && out[i] != #char "\n" i += 1;
            i += 1;
        } else if i + 1 < out.count && out[i] == #char "/" && out[i + 1] == #char "/" {
            while i < out.count && out[i] != #char "\n" {
                out[i] = #char " ";
                i += 1;
            }
        } else if i + 1 < out.count && out[i] == #char "/" && out[i + 1] == #char "*" {
            while i < out.count && !(i + 1 < out.count && out[i] == #char "*" && out[i + 1] == #char "/") {
                if out[i] != #char "\n" out[i] = #char " ";
                i += 1;
            }
            for 0..1 {
                if i < out.count {
                    out[i] = #char " ";
                    i += 1;
                }
            }
        } else {
            i += 1;
        }
    }
    return Hlsl_Code.{ cast(string) out, code.line };
}

hlsl_is_word :: (c: u8) -> bool {
    if c == #char "_" return true;
    if c >= #char "a" && c <= #char "z" return true;
    if c >= #char "A" && c <= #char "Z" return true;
    return c >= #char "0" && c <= #char "9";
}

// text 里独立单词 word 的位置（前后不是标识符字符），从 from 开始找。
hlsl_find_word :: (text, word: string, from := 0) -> int {
    start := from;
    while start <= text.count {
        found := STRING.find_index_from_left(lang_slice(text, start, text.count), word);
        if found < 0 return -1;
        at := start + cast(int) found;
        end := at + word.count;
        if (at == 0 || !hlsl_is_word(text[at - 1])) && (end >= text.count || !hlsl_is_word(text[end])) return at;
        start = at + 1;
    }
    return -1;
}

// 从 open（'{' 或 '('）开始找配对的闭括号；找不到返回 -1。
hlsl_match :: (text: string, open: int) -> int {
    opening := text[open];
    closing: u8 = #char ")";
    if opening == #char "{" closing = #char "}";
    depth := 0;
    for i: open..text.count - 1 {
        if text[i] == opening {
            depth += 1;
        } else if text[i] == closing {
            depth -= 1;
            if depth == 0 return i;
        }
    }
    return -1;
}

hlsl_words :: (text: string) -> [] string {
    words: [..] string;
    i := 0;
    while i < text.count {
        if !hlsl_is_word(text[i]) {
            i += 1;
            continue;
        }
        start := i;
        while i < text.count && hlsl_is_word(text[i]) i += 1;
        array_add(*words, lang_slice(text, start, i));
    }
    return words;
}

// odin 的 strings.count(code.text[:offset], "\n")：offset 之前有多少个换行。
hlsl_line_at :: (code: Hlsl_Code, offset: int) -> int {
    lines := 0;
    for i: 0..offset - 1 {
        if i >= code.text.count break;
        if code.text[i] == #char "\n" lines += 1;
    }
    return code.line + lines;
}

// 入口函数：返回类型、形参（去掉 in / out / 语义）与函数体。
hlsl_entry :: (blocks: [] Hlsl_Code, name: string) -> (Hlsl_Entry, bool) {
    entry: Hlsl_Entry;
    for block: blocks {
        text := block.text;
        at := hlsl_find_word(text, name);
        while at >= 0 {
            open := at + name.count;
            while open < text.count && (text[open] == #char " " || text[open] == #char "\t") open += 1;
            if open < text.count && text[open] == #char "(" {
                close := hlsl_match(text, open);
                brace := -1;
                if close >= 0 {
                    offset := lang_index_of(lang_slice(text, close, text.count), #char "{");
                    if offset >= 0 brace = close + offset;
                }
                if brace < 0 return Hlsl_Entry.{}, false;
                end := hlsl_match(text, brace);
                if end < 0 return Hlsl_Entry.{}, false;
                before := hlsl_words(lang_slice(text, max(0, lang_last_index_of(text, #char "\n", at)), at));
                if before.count > 0 entry.return_type = before[before.count - 1];
                params: [..] Hlsl_Param;
                for part: STRING.split(lang_slice(text, open + 1, close), ",") {
                    declaration := part;
                    colon := lang_index_of(declaration, #char ":");
                    if colon >= 0 declaration = lang_slice(declaration, 0, colon);
                    words := hlsl_words(declaration);
                    if words.count >= 2 {
                        array_add(*params, Hlsl_Param.{ words[words.count - 2], words[words.count - 1] });
                    }
                }
                entry.params = params;
                entry.body = lang_slice(text, brace, end + 1);
                return entry, true;
            }
            at = hlsl_find_word(text, name, at + 1);
        }
    }
    return Hlsl_Entry.{}, false;
}

// struct name { ... }：成员的类型、名字、语义与源文件行号（修饰词如 nointerpolation 忽略）。
hlsl_struct :: (blocks: [] Hlsl_Code, name: string) -> (Hlsl_Struct, bool) {
    result: Hlsl_Struct;
    for block: blocks {
        text := block.text;
        at := hlsl_find_word(text, "struct");
        while at >= 0 {
            window := min(text.count, at + 6 + name.count + 64);
            words := hlsl_words(lang_slice(text, at, window));
            brace := -1;
            offset_in_text := lang_index_of(lang_slice(text, at, text.count), #char "{");
            if offset_in_text >= 0 brace = at + offset_in_text;
            if words.count >= 2 && words[1] == name && brace >= 0 {
                end := hlsl_match(text, brace);
                if end < 0 return Hlsl_Struct.{}, false;
                members: [..] Hlsl_Member;
                offset := brace + 1;
                for part: STRING.split(lang_slice(text, brace + 1, end), ";") {
                    declaration := part;
                    semantic := "";
                    colon := lang_index_of(part, #char ":");
                    if colon >= 0 {
                        declaration = lang_slice(part, 0, colon);
                        semantic = STRING.trim(lang_slice(part, colon + 1, part.count));
                    }
                    names := hlsl_words(declaration);
                    if names.count >= 2 {
                        first := STRING.find_index_from_left(part, names[0]);
                        array_add(*members, Hlsl_Member.{ type = hlsl_member_type(names), name = names[names.count - 1],
                                                          semantic = semantic,
                                                          line = hlsl_line_at(block, offset + max(cast(int) first, 0)) });
                    }
                    offset += part.count + 1;
                }
                result = Hlsl_Struct.{ name, members, hlsl_line_at(block, at) };
                return result, true;
            }
            at = hlsl_find_word(text, "struct", at + 1);
        }
    }
    return Hlsl_Struct.{}, false;
}

// 去掉插值与存储修饰词后的类型名。
hlsl_member_type :: (words: [] string) -> string {
    for word: array_view(words, 0, words.count - 1) {
        if word == "nointerpolation" || word == "linear" || word == "centroid" || word == "noperspective" ||
           word == "sample" || word == "precise" || word == "const" || word == "static" || word == "uniform" {
            continue;
        }
        return word;
    }
    return words[0];
}

// 第一个占顶点属性的成员（SV_ 语义的系统值不占）。
hlsl_first_attribute :: (members: [] Hlsl_Member) -> (Hlsl_Member, bool) {
    for member: members {
        if STRING.begins_with(STRING.to_upper_copy(member.semantic), "SV_") continue;
        return member, true;
    }
    return Hlsl_Member.{}, false;
}

// body 里有 name.member 访问。
hlsl_contains_access :: (body, name, member: string) -> bool {
    at := hlsl_find_word(body, name);
    while at >= 0 {
        rest := STRING.trim_left(lang_slice(body, at + name.count, body.count));
        if STRING.begins_with(rest, ".") {
            field := STRING.trim_left(lang_slice(rest, 1, rest.count));
            if STRING.begins_with(field, member) && (field.count == member.count || !hlsl_is_word(field[member.count])) {
                return true;
            }
        }
        at = hlsl_find_word(body, name, at + 1);
    }
    return false;
}

// 片元把整个输入（不带 .成员）交给别处时，无法判断哪些成员被用到。
hlsl_used_whole :: (body, name: string) -> bool {
    at := hlsl_find_word(body, name);
    while at >= 0 {
        rest := STRING.trim_left(lang_slice(body, at + name.count, body.count));
        if !STRING.begins_with(rest, ".") return true;
        at = hlsl_find_word(body, name, at + 1);
    }
    return false;
}

// odin 的 strings.index_byte（找不到返回 -1）。
lang_index_of :: (text: string, c: u8) -> int {
    for i: 0..text.count - 1 {
        if text[i] == c return i;
    }
    return -1;
}

// odin 的 strings.last_index_byte(text[:before], c)：在 before 之前最后一次出现的位置，找不到返回 -1。
lang_last_index_of :: (text: string, c: u8, before: int) -> int {
    limit := min(before, text.count);
    i := limit;
    while i > 0 {
        i -= 1;
        if text[i] == c return i;
    }
    return -1;
}
//@endregion
