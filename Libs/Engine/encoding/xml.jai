// Owned UTF-8 XML tree: elements, attributes and ordered mixed text content.
// No DTD/external entities. Namespace prefixes are preserved verbatim.
#import "Basic";
XF :: #import "File";
Xml_Error :: enum { None; Invalid; Unsupported; Too_Deep; File_Error; }
Xml_Attribute :: struct { name, value: string; }
Xml_Node :: struct {
    name: string; // Empty name denotes a text node.
    text: string;
    attributes: [..] Xml_Attribute;
    children: [..] *Xml_Node;
}
Xml_Parser :: struct { input: string; pos: s64; error: Xml_Error; }
xml_valid_utf8 :: (input: string) -> bool {
    i: s64;
    while i < input.count {
        c := input[i]; cp: u32; n: s64; minimum: u32;
        if c < 128 { cp = c; n = 1; }
        else if c >= 194 && c <= 223 { cp = c & 31; n = 2; minimum = 128; }
        else if c >= 224 && c <= 239 { cp = c & 15; n = 3; minimum = 2048; }
        else if c >= 240 && c <= 244 { cp = c & 7; n = 4; minimum = 65536; }
        else return false;
        if i + n > input.count return false;
        for j: 1..n-1 {
            b := input[i+j]; if (b & 192) != 128 return false;
            cp = (cp << 6) | (b & 63);
        }
        if cp < minimum || !(cp == 9 || cp == 10 || cp == 13 || (cp >= 32 && cp <= 0xd7ff) || (cp >= 0xe000 && cp <= 0xfffd) || (cp >= 0x10000 && cp <= 0x10ffff)) return false;
        i += n;
    }
    return true;
}
xml_destroy :: (node: *Xml_Node) {
    if node == null return;
    for child: node.children xml_destroy(child);
    for a: node.attributes { free(a.name); free(a.value); }
    array_free(node.children); array_free(node.attributes);
    free(node.name); free(node.text); free(node);
}
xml_at :: (p: *Xml_Parser, token: string) -> bool {
    if p.pos + token.count > p.input.count return false;
    for c, i: token if p.input[p.pos + i] != c return false;
    return true;
}
xml_slice :: (p: *Xml_Parser, start: s64, end: s64) -> string { return .{data = p.input.data + start, count = end - start}; }
xml_space :: (c: u8) -> bool { return c == 32 || c == 9 || c == 10 || c == 13; }
xml_skip_space :: (p: *Xml_Parser) { while p.pos < p.input.count && xml_space(p.input[p.pos]) p.pos += 1; }
xml_name :: (p: *Xml_Parser) -> string {
    start := p.pos;
    while p.pos < p.input.count {
        c := p.input[p.pos];
        valid := c >= 128 || c == 95 || c == 58 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
        if p.pos > start valid = valid || c == 45 || c == 46 || (c >= 48 && c <= 57);
        if !valid break;
        p.pos += 1;
    }
    if p.pos == start p.error = .Invalid;
    return copy_string(xml_slice(p, start, p.pos));
}
xml_append_rune :: (b: *String_Builder, cp: u32) -> bool {
    if !(cp == 9 || cp == 10 || cp == 13 || (cp >= 32 && cp <= 0xd7ff) || (cp >= 0xe000 && cp <= 0xfffd) || (cp >= 0x10000 && cp <= 0x10ffff)) return false;
    if cp < 128 append(b, cast(u8) cp);
    else if cp < 2048 { append(b, cast(u8) (192 | (cp >> 6))); append(b, cast(u8) (128 | (cp & 63))); }
    else if cp < 65536 {
        append(b, cast(u8) (224 | (cp >> 12))); append(b, cast(u8) (128 | ((cp >> 6) & 63))); append(b, cast(u8) (128 | (cp & 63)));
    } else {
        append(b, cast(u8) (240 | (cp >> 18))); append(b, cast(u8) (128 | ((cp >> 12) & 63)));
        append(b, cast(u8) (128 | ((cp >> 6) & 63))); append(b, cast(u8) (128 | (cp & 63)));
    }
    return true;
}
xml_decode :: (value: string) -> (string, bool) {
    b: String_Builder; defer free_buffers(*b);
    pos: s64;
    while pos < value.count {
        c := value[pos]; pos += 1;
        if c != 38 {
            if c < 32 && !xml_space(c) return "", false;
            append(*b, c); continue;
        }
        start := pos;
        while pos < value.count && value[pos] != 59 pos += 1;
        if pos == value.count return "", false;
        entity := string.{data = value.data + start, count = pos - start}; pos += 1;
        cp: u32;
        if entity == "amp" cp = 38;
        else if entity == "lt" cp = 60;
        else if entity == "gt" cp = 62;
        else if entity == "quot" cp = 34;
        else if entity == "apos" cp = 39;
        else if entity.count > 1 && entity[0] == 35 {
            base: u32 = 10; offset: s64 = 1;
            if entity[1] == 120 { base = 16; offset = 2; }
            if offset == entity.count return "", false;
            while offset < entity.count {
                ch := entity[offset]; digit: u32 = 100;
                if ch >= 48 && ch <= 57 digit = ch - 48;
                else if ch >= 65 && ch <= 70 digit = ch - 65 + 10;
                else if ch >= 97 && ch <= 102 digit = ch - 97 + 10;
                if digit >= base || cp > 0x10ffff / base return "", false;
                cp = cp * base + digit; offset += 1;
            }
        } else return "", false;
        if !xml_append_rune(*b, cp) return "", false;
    }
    return builder_to_string(*b), true;
}
xml_skip_until :: (p: *Xml_Parser, terminator: string) -> bool {
    while p.pos < p.input.count {
        if xml_at(p, terminator) { p.pos += terminator.count; return true; }
        p.pos += 1;
    }
    p.error = .Invalid; return false;
}
xml_skip_comment :: (p: *Xml_Parser) -> bool {
    p.pos += 4;
    while p.pos < p.input.count {
        if xml_at(p, "-->") { p.pos += 3; return true; }
        if xml_at(p, "--") { p.error = .Invalid; return false; }
        p.pos += 1;
    }
    p.error = .Invalid; return false;
}
xml_misc :: (p: *Xml_Parser) {
    while true {
        xml_skip_space(p);
        if xml_at(p, "<!--") { if !xml_skip_comment(p) return; }
        else if xml_at(p, "<?") { p.pos += 2; if !xml_skip_until(p, "?>") return; }
        else break;
    }
}
xml_element :: (p: *Xml_Parser, depth: s64) -> *Xml_Node {
    if depth > 128 { p.error = .Too_Deep; return null; }
    if xml_at(p, "<!") { p.error = .Unsupported; return null; }
    if !xml_at(p, "<") { p.error = .Invalid; return null; }
    p.pos += 1;
    node := New(Xml_Node); node.name = xml_name(p);
    while p.error == .None {
        before_space := p.pos; xml_skip_space(p);
        if xml_at(p, "/>") { p.pos += 2; return node; }
        if xml_at(p, ">") { p.pos += 1; break; }
        if p.pos == before_space { p.error = .Invalid; break; }
        a: Xml_Attribute; a.name = xml_name(p); xml_skip_space(p);
        if !xml_at(p, "=") { free(a.name); p.error = .Invalid; break; }
        p.pos += 1; xml_skip_space(p);
        if p.pos >= p.input.count || (p.input[p.pos] != 34 && p.input[p.pos] != 39) { free(a.name); p.error = .Invalid; break; }
        quote := p.input[p.pos]; p.pos += 1; start := p.pos;
        while p.pos < p.input.count && p.input[p.pos] != quote && p.input[p.pos] != 60 p.pos += 1;
        if p.pos >= p.input.count || p.input[p.pos] != quote { free(a.name); p.error = .Invalid; break; }
        decoded, ok := xml_decode(xml_slice(p, start, p.pos)); p.pos += 1;
        if !ok { free(a.name); p.error = .Invalid; break; }
        a.value = decoded;
        for prior: node.attributes if prior.name == a.name p.error = .Invalid;
        array_add(*node.attributes, a);
    }
    while p.error == .None {
        if xml_at(p, "</") {
            p.pos += 2; ending := xml_name(p); defer free(ending);
            xml_skip_space(p);
            if ending != node.name || !xml_at(p, ">") { p.error = .Invalid; break; }
            p.pos += 1; return node;
        }
        if xml_at(p, "<!--") { if !xml_skip_comment(p) break; continue; }
        if xml_at(p, "<?") { p.pos += 2; if !xml_skip_until(p, "?>") break; continue; }
        if xml_at(p, "<![CDATA[") {
            p.pos += 9; start := p.pos;
            if !xml_skip_until(p, "]]>") break;
            child := New(Xml_Node); child.text = copy_string(xml_slice(p, start, p.pos - 3));
            array_add(*node.children, child); continue;
        }
        if xml_at(p, "<") {
            child := xml_element(p, depth + 1);
            if child == null break;
            array_add(*node.children, child); continue;
        }
        start := p.pos;
        while p.pos < p.input.count && p.input[p.pos] != 60 {
            if xml_at(p, "]]>") { p.error = .Invalid; break; }
            p.pos += 1;
        }
        if p.error != .None break;
        if p.pos == start { p.error = .Invalid; break; }
        value, ok := xml_decode(xml_slice(p, start, p.pos));
        if !ok { p.error = .Invalid; break; }
        child := New(Xml_Node); child.text = value; array_add(*node.children, child);
    }
    xml_destroy(node); return null;
}
xml_parse :: (input: string) -> (*Xml_Node, Xml_Error) {
    if !xml_valid_utf8(input) return null, .Invalid;
    p := Xml_Parser.{input = input};
    if input.count >= 3 && input[0] == 239 && input[1] == 187 && input[2] == 191 p.pos = 3;
    xml_misc(*p);
    if p.error != .None return null, p.error;
    root := xml_element(*p, 0);
    if root == null return null, p.error;
    xml_misc(*p);
    if p.error != .None || p.pos != input.count { xml_destroy(root); return null, .Invalid; }
    return root, .None;
}
xml_attribute :: (node: *Xml_Node, name: string) -> (string, bool) {
    for a: node.attributes if a.name == name return a.value, true;
    return "", false;
}
xml_child :: (node: *Xml_Node, name: string) -> *Xml_Node {
    for child: node.children if child.name == name return child;
    return null;
}
xml_escape :: (b: *String_Builder, value: string, attribute: bool) {
    for c: value {
        if c == 38 append(b, "&amp;");
        else if c == 60 append(b, "&lt;");
        else if c == 62 append(b, "&gt;");
        else if attribute && c == 34 append(b, "&quot;");
        else append(b, c);
    }
}
xml_write_node :: (b: *String_Builder, node: *Xml_Node) {
    if node.name == "" { xml_escape(b, node.text, false); return; }
    append(b, "<"); append(b, node.name);
    for a: node.attributes { append(b, " "); append(b, a.name); append(b, "=\""); xml_escape(b, a.value, true); append(b, "\""); }
    if node.children.count == 0 { append(b, "/>"); return; }
    append(b, ">"); for child: node.children xml_write_node(b, child);
    append(b, "</"); append(b, node.name); append(b, ">");
}
xml_string :: (node: *Xml_Node) -> string {
    b: String_Builder; defer free_buffers(*b);
    xml_write_node(*b, node); return builder_to_string(*b);
}
xml_load :: (path: string) -> (*Xml_Node, Xml_Error) {
    bytes, ok := XF.read_entire_file(path);
    if !ok return null, .File_Error;
    defer free(bytes);
    root, error := xml_parse(bytes); return root, error;
}
xml_save :: (path: string, node: *Xml_Node) -> Xml_Error {
    value := xml_string(node); defer free(value);
    if !XF.write_entire_file(path, value) return .File_Error;
    return .None;
}
