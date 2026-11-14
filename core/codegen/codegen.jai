// codegen —— 编译前代码生成：扫描 Jai 包，暂存输出，全部成功才写入 *_generated.jai。
// 一比一移植自 olib core/codegen/codegen.odin。仅供开发工具（项目的 tools/gen 与
// tools/auto_gen），不属于游戏运行时。接口与示例见 olib core/codegen/README.md。
//
// ── 与 odin 的文件/目录 API 映射（本文件所有 IO 都走右侧这一列） ──────────────
//
//   odin                                   jacket / Jai
//   os.read_entire_file(path)              File.read_entire_file(path) -> (text, ok)
//   os.write_entire_file(path, data)       File.write_entire_file(path, text) -> bool
//   os.write + os.close + 长度校验         File.write_entire_file（内部写满 + flush）
//   os.create_temp_file(dir, ".codegen-*") 自拼 <dir>/.codegen-<n>.tmp，再 write_entire_file
//   os.rename(old, new)（覆盖目标）        File.file_move（Windows 上是 MoveFileW，**不覆盖**
//                                          已存在目标）→ 先 file_delete 再 file_move，见
//                                          codegen_write_output
//   os.remove(path)                        File.file_delete(path) -> bool
//   os.exists(path)                        File_Utilities.file_exists(path) -> bool
//   os.read_all_directory_by_path(dir)     File_Utilities.visit_files(dir, false, ...)
//   filepath.abs(path)                     File.get_absolute_path(path) -> (path, ok)
//   filepath.base(path)                    String.path_filename(path)
//   filepath.dir(path)                     codegen_dir(path)（String.path_strip_filename + 去尾分隔符）
//   filepath.join({dir, name})             tprint("%/%", dir, name)
//   strings.builder_make / sbprintf        String_Builder + append(*builder, tprint(...))
//   strings.replace_all(s, "\r\n", "\n")   String.replace(s, "\r\n", "\n")
//   strings.has_prefix / has_suffix        String.starts_with / String.ends_with
//   strings.contains_any(s, "\r\n")        String.contains 两次（\r 与 \n）
//   slice.sort_by(paths, ...)              Sort.quick_sort + Sort.compare_strings
//   virtual.Arena                          Arena（本文件自带的块链 bump 分配器，见「内存」）
//   core:odin/tokenizer + parser + ast     本文件自带的 codegen 词法器 + 顶层语句切分
//
// ── Jai 侧差异（逐条对应 olib 的写法，行为不变） ─────────────────────────────
//
//   - **标记语法**：odin 用属性 `@(tag = "component")`；Jai 的等价物是 note
//     `@tag("component")`（jacket 的 `@name(args)`，可写在声明之后，也可单独一行写在声明
//     之前）。语义一一对应：名字 tag、值是字符串字面量、附着在同一条包级声明上。
//     同一行尾随的 note 归前一条声明，独占一行的前导 note 归后一条声明（见
//     codegen_collect_range / codegen_collect_decl）。
//   - **没有 Odin 解析器**：odin 直接把 core:odin/parser 的 AST 当扫描结果用；Jai 侧没有可
//     复用的编译器前端，所以本文件自带一个只认「包级语句 + note + 字符串字面量」的词法器与
//     切分器（@region 词法）。Decl.node / Decl.value 因此不是 AST，而是「源码字节区间 + 粗略
//     分类」（Decl_Node / Decl_Value），自定义生成器按区间取文本即可；kind_table 需要的
//     「是不是 proc 字面量」由分类承担（值以 `(` 开头且带顶层花括号组 = proc 字面量）。
//   - **生成文件后缀**：`_generated.odin` → `_generated.jai`（Jai 源码扩展名）。
//   - **生成头**：GENERATED_PREFIX / GENERATED_HEADER 的文本与 olib 完全一致（它是注释，
//     照抄才能照样识别旧的 auto_gen 产物）。emit 不再写 `package <name>` 行（Jai 没有包
//     声明），改成生成头 + generator 说明 + 空行 + body；包名改由目录名给出（Jai 的包名就是
//     目录名），仍用于 emit 的「没有手写源码」诊断。
//   - **被 #load 聚合**：odin 里同目录的 .odin 自动属于同一个包，新生成的文件自动参与编译；
//     Jai 只有 #import / #load 到的文件才参与编译，所以生成文件要由所属包的 module.jai
//     显式 `#load`（见 core/codegen/module.jai 的写法）。
//   - **条件编译**：odin 的 `when` / `foreign` 块 / `#+build` / 平台后缀文件 → Jai 只有
//     `#if`/`#ifx`（含 `else` 分支）。所以 conditional_filename（平台后缀文件）**没有移植**：
//     Jai 没有「按文件名后缀选目标」的构建规则，把 `*_windows.jai` 当条件编译会误报。其余
//     规则不变：`#if` 分支里的标记声明一律报错，不模拟目标平台。
//   - **测试文件跳过**：odin 跳过 `*_test.odin` 与带 `#+test`/`#+ignore` 的文件；Jai 只按
//     文件名跳过 `*_test.jai`（Jai 没有文件级 tag）。
//   - **包名一致性**：odin 比对每个文件的 `package` 行，不一致就报错；Jai 没有包声明
//     （包名 = 目录名），这一项无从比较，所以该诊断不存在。
//   - **错误对象**：odin 的 `%v`（os.File_Error 等）在 Jai 里没有等价物（IO 只返回 bool），
//     诊断保留同样的前缀与位置，失败原因写成固定的短句。
//   - **分配器**：odin 用 `virtual.Arena` + context.allocator 接管全部中间数据，finish 后
//     失效。这里用 Arena（同样的块链 bump 语义）+ push_allocator 实现，所有权约定不变：
//     扫描结果与读入的文本借用 arena，finish 后失效。
//   - **包内私有**：Jai 没有 odin 的 `@(private)`，内部过程统一加 `codegen_` 前缀区分；
//     olib 里 `@(private)` 但测试用到的（collect_source、decls_tagged 之外的 emit/scan/
//     finish/fail/read_input、Generator/Package_Scan 字段）保持原名，与 olib 对齐。
//   - **@(rodata)**：odin 的 `@(rodata)` 在 Jai 里没有对应 note，kind_table 生成的是普通
//     常量表；枚举索引数组也有差异，见 kind_table 的注释。
#import "Basic";
STRING :: #import "String";
FILE :: #import "File";
FU :: #import "File_Utilities";
SORT :: #import "Sort";
SYS :: #import "System";

//@region 内存

// 对应 odin 的 virtual.Arena（growing）：块链 + 顶部指针，一次释放全部；FREE 是空操作，
// RESIZE 在「刚好是最后一块的最后一次分配」时原地扩展，否则新分配 + 拷贝。
// 块本身从建立时捕获的 base 分配器拿，所以 arena 里可以放心地用 push_allocator。
Codegen_Arena_Block :: struct {
    previous: *Codegen_Arena_Block;
    size: s64; // 本块可用字节数（不含块头）
    used: s64;
}

Arena :: struct {
    base: Allocator; // 建立时的 context.allocator，块的来源
    head: *Codegen_Arena_Block;
    capacity: s64; // 下一个新块的字节数（每次翻倍）
}

// 分配对齐：odin 的 arena 默认按 16 字节对齐，这里相同（jacket 的分配器协议不传对齐）。
CODEGEN_ARENA_ALIGN :: 16;

codegen_align_up :: (size: s64) -> s64 {
    return (size + CODEGEN_ARENA_ALIGN - 1) & ~(CODEGEN_ARENA_ALIGN - 1);
}

codegen_arena_grow :: (arena: *Arena, minimum: s64) -> bool {
    size := arena.capacity;
    if size < minimum + size_of(Codegen_Arena_Block) + CODEGEN_ARENA_ALIGN {
        size = minimum + size_of(Codegen_Arena_Block) + CODEGEN_ARENA_ALIGN;
    }
    raw := arena.base.proc(.ALLOCATE, size, 0, null, arena.base.data);
    if !raw return false;
    block := cast(*Codegen_Arena_Block) raw;
    block.previous = arena.head;
    block.size = size - size_of(Codegen_Arena_Block);
    block.used = 0;
    arena.head = block;
    arena.capacity = size * 2;
    return true;
}

codegen_arena_alloc_raw :: (arena: *Arena, size: s64) -> *void {
    aligned := codegen_align_up(size);
    if !arena.head || arena.head.used + aligned > arena.head.size {
        if !codegen_arena_grow(arena, aligned) return null;
    }
    memory := cast(*u8) arena.head + size_of(Codegen_Arena_Block) + arena.head.used;
    arena.head.used += aligned;
    return memory;
}

// 对应 virtual.arena_allocator：把 Arena 包成 jacket 的 Allocator。
codegen_arena_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, data: *void) -> *void {
    arena := cast(*Arena) data;
    if mode == {
        case .ALLOCATE;
            return codegen_arena_alloc_raw(arena, size);
        case .FREE;
            // arena 不逐项释放，整块销毁时才还给 base。
            return null;
        case .CAPS;
            return null;
        case .RESIZE;
            aligned_old := codegen_align_up(old_size);
            aligned_new := codegen_align_up(size);
            if old_memory && arena.head {
                end := cast(*u8) old_memory + aligned_old;
                head_end := cast(*u8) arena.head + size_of(Codegen_Arena_Block) + arena.head.used;
                if end == head_end && arena.head.used - aligned_old + aligned_new <= arena.head.size {
                    arena.head.used = arena.head.used - aligned_old + aligned_new;
                    return old_memory;
                }
            }
            memory := codegen_arena_alloc_raw(arena, size);
            if memory && old_memory memcpy(memory, old_memory, min(size, old_size));
            return memory;
    }
    return null;
}

codegen_arena_allocator :: (g: *Generator) -> Allocator {
    return .{ codegen_arena_proc, *g.arena };
}

// 对应 virtual.arena_init_growing：成功时返回 true。
codegen_arena_init :: (arena: *Arena) -> bool {
    arena.* = .{};
    arena.base = context.allocator;
    arena.capacity = 64 * 1024;
    return codegen_arena_grow(arena, 1024);
}

// 对应 virtual.arena_destroy：把块还给 base。重复调用无副作用。
codegen_arena_destroy :: (arena: *Arena) {
    block := arena.head;
    while block {
        previous := block.previous;
        arena.base.proc(.FREE, 0, 0, block, arena.base.data);
        block = previous;
    }
    arena.head = null;
}
//@endregion

//@region 接口类型

// 对应 odin 的 tokenizer.Pos：只保留打印诊断需要的位置（按字节的 offset/column）。
Pos :: struct {
    file: string;
    offset: int;
    line: int; // 1 起
    column: int; // 1 起
}

// 声明值的粗略分类（odin 侧是 ast 节点类型；Jai 没有语法树，只能给分类）。
Decl_Kind :: enum u8 {
    Other; // 常量、变量、类型别名等
    Proc; // proc 字面量：值以 `(` 开头且带顶层花括号组
    Struct;
    Enum;
    Union;
}

// 对应 odin 的 ast.Value_Decl：一条包级声明在源码里的区间 [start, end)（字节偏移）。
// 自定义生成器要读具体文本时，用 start/end 到扫描时的 source 里切（见 read_input 的说明）。
Decl_Node :: struct {
    kind: Decl_Kind;
    start: int;
    end: int;
}

// 对应 odin 的 ast.Expr（声明对应的值）：同一区间 + 同一个分类。
Decl_Value :: struct {
    kind: Decl_Kind;
    start: int;
    end: int;
}

// 一个包级名字。一条声明有多个名字时拆成多个 Decl，共用 node。
Decl :: struct {
    name: string;
    tags: [] string;
    pos: Pos;
    conditional: bool; // 位于 #if/#ifx、#if 的 else 分支或顶层花括号块中
    node: *Decl_Node;
    value: *Decl_Value; // 与名字对应的值；没有初始值时（如 `x: int;`）为 null
}

Package_Scan :: struct {
    package_name: string;
    dir: string; // 绝对路径
    decls: [..] Decl;
    generated: [..] string; // 目录里已有的生成文件，不参与解析
}

// 地址须稳定。扫描结果和读入的文本都借用内部 arena，finish 后失效。
Generator :: struct {
    check: bool; // -check：只比对，不写盘
    prune: bool; // 删除已扫描目录里本次没有产出的生成文件；begin 默认开启
    strict_syntax: bool; // 语法错误也算失败；默认交给随后的编译器报告
    bad_argument: string;
    init_failed: bool;
    syntax_failed: bool;
    arena: Arena;
    scans: [..] *Package_Scan;
    outputs: [..] Codegen_Output;
    errors: [..] string;
}

// 对应 olib 的 @(private) Output。Jai 没有包内私有，用前缀标注。
Codegen_Output :: struct {
    path: string;
    content: string;
}
//@endregion

//@region 生成流程

GENERATED_PREFIX :: "// Code generated by olib "; // 也用来识别旧的 auto_gen 文件
// odin: GENERATED_PREFIX + "core/codegen. DO NOT EDIT.\n"；Jai 没有字符串 +，写成同一个字面量。
GENERATED_HEADER :: "// Code generated by olib core/codegen. DO NOT EDIT.\n";
GENERATED_SUFFIX :: "_generated.jai";

// args 只认 -check；其他参数由 finish 报告并返回 2。
begin :: (g: *Generator, args: [] string = .[]) {
    g.* = .{};
    g.prune = true;
    if !codegen_arena_init(*g.arena) {
        g.init_failed = true;
        return;
    }
    push_allocator(codegen_arena_allocator(g));
    for arg: args {
        if arg == "-check" {
            g.check = true;
        } else if g.bad_argument == "" {
            g.bad_argument = copy_string(arg);
        }
    }
}

// 校验、写盘、清理并释放 arena。退出码：成功 0，生成/检查/I/O 失败 1，参数错误 2。
finish :: (g: *Generator) -> int {
    if g.init_failed {
        codegen_eprint("无法初始化代码生成内存。");
        return 1;
    }
    defer codegen_arena_destroy(*g.arena);
    push_allocator(codegen_arena_allocator(g));
    if g.bad_argument != "" {
        codegen_eprint(tprint("未知参数: %（只支持 -check）", g.bad_argument));
        return 2;
    }
    // 语法错误时扫描结果不完整，其他错误可能只是它的连带结果。
    if g.syntax_failed {
        if g.check || g.strict_syntax {
            codegen_eprint("Jai 语法解析失败，没有写入生成文件。");
            return 1;
        }
        codegen_eprint("Jai 语法解析失败，跳过生成，保留已有生成文件。");
        return 0;
    }
    if g.errors.count > 0 {
        for message: g.errors codegen_eprint(message);
        return 1;
    }
    return codegen_commit(g);
}

// 记录一条错误；有任何错误时 finish 都不写盘。pos 为零值时只输出 message。
fail :: (g: *Generator, pos: Pos, message: string) {
    push_allocator(codegen_arena_allocator(g));
    array_add(*g.errors, codegen_at(pos, message));
}

// 读自定义格式的输入文件，失败时记错误。路径相对当前工作目录，文本借用 arena。
read_input :: (g: *Generator, path: string) -> (text: string, ok: bool) {
    push_allocator(codegen_arena_allocator(g));
    text, read_ok := FILE.read_entire_file(path);
    if !read_ok {
        // odin: fmt.aprintf("无法读取 %s: %v", path, err)；Jai 的 IO 不返回错误对象。
        fail(g, .{}, tprint("无法读取 %", path));
        return "", false;
    }
    return text, true;
}

// 暂存一个生成文件：自动加生成头。out 是所属包目录内的文件名，必须以 _generated.jai 结尾。
// generator 写在生成头下一行，说明由谁、按什么规则生成，不能换行。
emit :: (g: *Generator, s: *Package_Scan, out: string, generator: string, body: string) {
    push_allocator(codegen_arena_allocator(g));
    if g.syntax_failed return;
    if STRING.path_filename(out) != out || !STRING.ends_with(out, GENERATED_SUFFIX) || out == GENERATED_SUFFIX {
        fail(g, .{}, tprint("输出必须是包目录内以 % 结尾的文件名: %", GENERATED_SUFFIX, out));
        return;
    }
    if STRING.contains(generator, "\n") || STRING.contains(generator, "\r") {
        fail(g, .{}, tprint("generator 说明不能换行: %", codegen_quote(generator)));
        return;
    }
    if s.package_name == "" {
        fail(g, .{}, tprint("% 没有手写 Jai 源码，无法确定包名", s.dir));
        return;
    }
    // odin 侧同样经 filepath 规范化，分隔符一致才能比对旧文件。
    path := tprint("%/%", s.dir, out);
    for output: g.outputs {
        if codegen_same_path(output.path, path) {
            fail(g, .{}, tprint("重复输出: %", path));
            return;
        }
    }
    // odin: "%s// generator: %s\npackage %s\n\n%s"；Jai 没有 package 行，保留空行分隔。
    content := tprint("%// generator: %\n\n%", GENERATED_HEADER, generator, body);
    array_add(*g.outputs, Codegen_Output.{ path, content });
}
//@endregion

//@region 词法

// 词法单元分类：只保留「切分包级语句 + 读 tag」需要的部分。
Codegen_Token_Kind :: enum u8 {
    Ident; // 标识符与关键字
    Number; // 数值字面量
    String; // "..."；raw 为 true 时是 #string here-string
    Note; // @name（text 只有名字，不含 @）
    Hash; // # 指令引导符
    Punct; // 其余符号
    Invalid; // 未终止的字符串/字符/块注释
}

Codegen_Token :: struct {
    kind: Codegen_Token_Kind;
    text: string; // 借用 source；String 含引号，Note 只有名字
    pos: Pos;
    raw: bool; // String：是否为 #string 原始串（tag 不接受它，见 codegen_note_tag）
}

codegen_slice :: (text: string, from: int, to: int) -> string {
    if from < 0 from = 0;
    if to > text.count to = text.count;
    if from >= to return "";
    return to_string(text.data + from, cast(s64) (to - from));
}

codegen_is_ident_start :: (c: u8) -> bool {
    if c >= #char "a" && c <= #char "z" return true;
    if c >= #char "A" && c <= #char "Z" return true;
    return c == #char "_";
}

codegen_is_ident_char :: (c: u8) -> bool {
    if codegen_is_ident_start(c) return true;
    return c >= #char "0" && c <= #char "9";
}

codegen_is_digit :: (c: u8) -> bool {
    return c >= #char "0" && c <= #char "9";
}

codegen_is_space :: (c: u8) -> bool {
    if c == #char " " || c == #char "\t" || c == #char "\r" return true;
    return c == #char "\v" || c == #char "\f";
}

// text[at..] 是否正好以 word 开头，且后面不再接标识符字符。
codegen_word_at :: (text: string, at: int, word: string) -> bool {
    if at + word.count > text.count return false;
    k := 0;
    while k < word.count {
        if text[at + k] != word[k] return false;
        k += 1;
    }
    if at + word.count < text.count && codegen_is_ident_char(text[at + word.count]) return false;
    return true;
}

// 从 from 到 to 消费的文本里补上行/列基准（多行 token 与注释用）。
codegen_advance_lines :: (text: string, from: int, to: int, line: *int, line_start: *int) {
    i := from;
    while i < to {
        if text[i] == #char "\n" {
            line.* += 1;
            line_start.* = i + 1;
        }
        i += 1;
    }
}

// 把源码切成 token。ok 为 false 表示出现未终止的字符串/字符/块注释（对应 odin tokenizer 的
// error_count != 0，也对应 olib 的 syntax_failed）。
codegen_lex :: (text: string, path: string) -> ([..] Codegen_Token, bool) {
    tokens: [..] Codegen_Token;
    ok := true;
    i := 0;
    line := 1;
    line_start := 0;
    consumed := 0; // 已补过行列的偏移
    while i < text.count {
        // 上一轮消费掉的空白/注释/多行 token 在这里补上行/列基准：
        // 位置必须基于「已经消费到这里」的 line/line_start。
        codegen_advance_lines(text, consumed, i, *line, *line_start);
        consumed = i;
        from := i;
        c := text[i];
        // 空白
        if codegen_is_space(c) || c == #char "\n" {
            i += 1;
            continue;
        }
        // 注释不进入结果（odin 侧同样过滤 .Comment）
        if c == #char "/" && i + 1 < text.count && text[i + 1] == #char "/" {
            while i < text.count && text[i] != #char "\n" i += 1;
            continue;
        }
        if c == #char "/" && i + 1 < text.count && text[i + 1] == #char "*" {
            start := i;
            depth := 0;
            while i < text.count {
                if text[i] == #char "/" && i + 1 < text.count && text[i + 1] == #char "*" {
                    depth += 1;
                    i += 2;
                    continue;
                }
                if text[i] == #char "*" && i + 1 < text.count && text[i + 1] == #char "/" {
                    depth -= 1;
                    i += 2;
                    if depth == 0 break;
                    continue;
                }
                i += 1;
            }
            if depth != 0 {
                ok = false;
                array_add(*tokens, Codegen_Token.{ kind = .Invalid, text = codegen_slice(text, start, i), pos = codegen_pos(text, path, start, line, line_start) });
            }
            continue;
        }
        token_pos := codegen_pos(text, path, i, line, line_start);

        if c == #char "\"" {
            i += 1;
            closed := false;
            while i < text.count {
                if text[i] == #char "\\" {
                    i += 2;
                    continue;
                }
                if text[i] == #char "\n" break; // Jai 的普通字符串不跨行
                if text[i] == #char "\"" {
                    i += 1;
                    closed = true;
                    break;
                }
                i += 1;
            }
            if !closed {
                ok = false;
                array_add(*tokens, Codegen_Token.{ kind = .Invalid, text = codegen_slice(text, from, min(i, text.count)), pos = token_pos });
            } else {
                array_add(*tokens, Codegen_Token.{ kind = .String, text = codegen_slice(text, from, i), pos = token_pos });
            }
            continue;
        }

        // #string ... <terminator>：原始多行字符串，整段吞掉（content 里可以出现 @tag( ... )）
        if c == #char "#" && codegen_word_at(text, i + 1, "string") {
            start := i;
            j := i + 7;
            while j < text.count && codegen_is_space(text[j]) j += 1;
            while j < text.count && text[j] == #char "," {
                j += 1;
                while j < text.count && codegen_is_ident_char(text[j]) j += 1;
                while j < text.count && codegen_is_space(text[j]) j += 1;
            }
            term_start := j;
            while j < text.count && codegen_is_ident_char(text[j]) j += 1;
            term := codegen_slice(text, term_start, j);
            closed := false;
            if term.count > 0 {
                while j < text.count && text[j] != #char "\n" j += 1;
                if j < text.count j += 1;
                while j < text.count {
                    if codegen_word_at(text, j, term) {
                        j += term.count;
                        while j < text.count && text[j] != #char "\n" j += 1;
                        closed = true;
                        break;
                    }
                    while j < text.count && text[j] != #char "\n" j += 1;
                    if j < text.count j += 1;
                }
            }
            i = j;
            if !closed {
                ok = false;
                array_add(*tokens, Codegen_Token.{ kind = .Invalid, text = codegen_slice(text, start, i), pos = token_pos });
            } else {
                array_add(*tokens, Codegen_Token.{ kind = .String, text = codegen_slice(text, start, i), pos = token_pos, raw = true });
            }
            continue;
        }

        if c == #char "#" {
            i += 1;
            array_add(*tokens, Codegen_Token.{ kind = .Hash, text = codegen_slice(text, from, i), pos = token_pos });
            continue;
        }

        // note：@name，参数照常切成后面的 token（codegen_note_tag 只认 tag）
        if c == #char "@" {
            i += 1;
            name_start := i;
            while i < text.count && codegen_is_ident_char(text[i]) i += 1;
            if i == name_start {
                array_add(*tokens, Codegen_Token.{ kind = .Punct, text = codegen_slice(text, from, i), pos = token_pos });
                continue;
            }
            array_add(*tokens, Codegen_Token.{ kind = .Note, text = codegen_slice(text, name_start, i), pos = token_pos });
            continue;
        }

        // 反引号标识符（Jai 用 `x` 拒绝关键字当名字）：按标识符处理，text 去掉反引号
        if c == #char "`" {
            i += 1;
            name_start := i;
            while i < text.count && text[i] != #char "`" i += 1;
            name := codegen_slice(text, name_start, i);
            if i < text.count i += 1;
            array_add(*tokens, Codegen_Token.{ kind = .Ident, text = name, pos = token_pos });
            continue;
        }

        if codegen_is_ident_start(c) {
            while i < text.count && codegen_is_ident_char(text[i]) i += 1;
            array_add(*tokens, Codegen_Token.{ kind = .Ident, text = codegen_slice(text, from, i), pos = token_pos });
            continue;
        }
        if codegen_is_digit(c) {
            while i < text.count && (codegen_is_ident_char(text[i]) || text[i] == #char ".") i += 1;
            array_add(*tokens, Codegen_Token.{ kind = .Number, text = codegen_slice(text, from, i), pos = token_pos });
            continue;
        }

        // 其余符号：多字符运算符整体成一个 Punct，便于识别 '::'
        width := 1;
        if i + 1 < text.count {
            pair := codegen_slice(text, i, i + 2);
            if pair == "::" || pair == "->" || pair == ":=" || pair == "==" || pair == "!=" || pair == "<=" ||
               pair == ">=" || pair == "&&" || pair == "||" || pair == "+=" || pair == "-=" || pair == "*=" ||
               pair == "/=" || pair == "<<" || pair == ">>" || pair == "++" || pair == "--" || pair == ".." {
                width = 2;
            }
        }
        i += width;
        array_add(*tokens, Codegen_Token.{ kind = .Punct, text = codegen_slice(text, from, i), pos = token_pos });
        continue;
    }
    _ = consumed;
    return tokens, ok;
}

// 由「消费到 i 之前的 text[consumed..i]」推出 i 处的行列；consumed 只用于内部推进。
codegen_pos :: (text: string, path: string, at: int, line: int, line_start: int) -> Pos {
    return .{ file = path, offset = at, line = line, column = at - line_start + 1 };
}

// 括号是否配平（未闭合的结构体/块 = odin 侧的 parser 失败）。不同括号共用一个计数器：
// 只做「明显不平衡」的判定，足够挡住 olib 测试里那类截断源码。
codegen_balanced :: (tokens: [] Codegen_Token) -> bool {
    depth := 0;
    for token: tokens {
        if token.kind != .Punct continue;
        if token.text == "(" || token.text == "[" || token.text == "{" {
            depth += 1;
        } else if token.text == ")" || token.text == "]" || token.text == "}" {
            depth -= 1;
            if depth < 0 return false;
        }
    }
    return depth == 0;
}

// index 处括号的配对下标；找不到返回 -1。
codegen_matching :: (tokens: [] Codegen_Token, index: int) -> int {
    if index < 0 || index >= tokens.count return -1;
    opener := tokens[index].text;
    closer := "}";
    if opener == "(" closer = ")";
    else if opener == "[" closer = "]";
    depth := 0;
    i := index;
    while i < tokens.count {
        token := tokens[i];
        if token.kind == .Punct {
            if token.text == opener depth += 1;
            else if token.text == closer {
                depth -= 1;
                if depth == 0 return i;
            }
        }
        i += 1;
    }
    return -1;
}

// 对应 odin strconv.unquote_string：解码 Jai 普通字符串的转义（含 \x \u \U）。
// literal 含两端引号；返回 (value, ok)。
codegen_unquote_string :: (literal: string) -> (string, bool) {
    if literal.count < 2 || literal[0] != #char "\"" || literal[literal.count - 1] != #char "\"" {
        return "", false;
    }
    builder: String_Builder;
    value_ok := true;
    i := 1;
    end := literal.count - 1;
    while i < end {
        c := literal[i];
        if c != #char "\\" {
            append(*builder, c);
            i += 1;
            continue;
        }
        i += 1;
        if i >= end {
            value_ok = false;
            break;
        }
        escape := literal[i];
        i += 1;
        if escape == #char "n" {
            append(*builder, #char "\n");
        } else if escape == #char "r" {
            append(*builder, #char "\r");
        } else if escape == #char "t" {
            append(*builder, #char "\t");
        } else if escape == #char "0" {
            append(*builder, 0);
        } else if escape == #char "\\" || escape == #char "\"" || escape == #char "\'" {
            append(*builder, escape);
        } else if escape == #char "x" || escape == #char "u" || escape == #char "U" {
            digits := 2;
            if escape == #char "u" digits = 4;
            if escape == #char "U" digits = 8;
            codepoint: u32;
            valid := true;
            for 0..digits - 1 {
                if i >= end || codegen_hex_value(literal[i]) < 0 {
                    valid = false;
                    break;
                }
                codepoint = (codepoint << 4) | cast(u32) codegen_hex_value(literal[i]);
                i += 1;
            }
            if !valid || codepoint > 0x10ffff {
                value_ok = false;
                break;
            }
            codegen_append_codepoint(*builder, codepoint);
        } else {
            value_ok = false;
            break;
        }
    }
    value := builder_to_string(*builder);
    free_buffers(*builder);
    return value, value_ok;
}

codegen_hex_value :: (c: u8) -> int {
    if c >= #char "0" && c <= #char "9" return cast(int) (c - #char "0");
    if c >= #char "a" && c <= #char "f" return cast(int) (c - #char "a") + 10;
    if c >= #char "A" && c <= #char "F" return cast(int) (c - #char "A") + 10;
    return -1;
}

// 把 code point 按 UTF-8 写进 builder（对应 odin 的 utf8 编码）。
codegen_append_codepoint :: (builder: *String_Builder, codepoint: u32) {
    if codepoint < 0x80 {
        append(builder, cast(u8) codepoint);
    } else if codepoint < 0x800 {
        append(builder, cast(u8) (0xc0 | (codepoint >> 6)));
        append(builder, cast(u8) (0x80 | (codepoint & 0x3f)));
    } else if codepoint < 0x10000 {
        append(builder, cast(u8) (0xe0 | (codepoint >> 12)));
        append(builder, cast(u8) (0x80 | ((codepoint >> 6) & 0x3f)));
        append(builder, cast(u8) (0x80 | (codepoint & 0x3f)));
    } else {
        append(builder, cast(u8) (0xf0 | (codepoint >> 18)));
        append(builder, cast(u8) (0x80 | ((codepoint >> 12) & 0x3f)));
        append(builder, cast(u8) (0x80 | ((codepoint >> 6) & 0x3f)));
        append(builder, cast(u8) (0x80 | (codepoint & 0x3f)));
    }
}

// 对应 fmt 的 %q：只用于诊断文本，转义反斜杠、引号与换行/制表符。
codegen_quote :: (text: string) -> string {
    builder: String_Builder;
    append(*builder, #char "\"");
    for c: text {
        if c == #char "\\" {
            append(*builder, "\\\\");
        } else if c == #char "\"" {
            append(*builder, "\\\"");
        } else if c == #char "\n" {
            append(*builder, "\\n");
        } else if c == #char "\r" {
            append(*builder, "\\r");
        } else if c == #char "\t" {
            append(*builder, "\\t");
        } else {
            append(*builder, c);
        }
    }
    append(*builder, #char "\"");
    value := builder_to_string(*builder);
    free_buffers(*builder);
    return value;
}
//@endregion

//@region 扫描

// 解析一个包目录，只读本层 .jai。同一目录只解析一次。路径相对当前工作目录。
scan :: (g: *Generator, dir: string) -> *Package_Scan {
    push_allocator(codegen_arena_allocator(g));
    absolute, resolved := FILE.get_absolute_path(dir);
    if !resolved {
        absolute = copy_string(dir);
        fail(g, .{}, tprint("无法解析路径 %", dir));
    }
    for existing: g.scans {
        if codegen_same_path(existing.dir, absolute) return existing;
    }
    s := New(Package_Scan);
    s.* = .{ dir = absolute };
    array_add(*g.scans, s);

    entries: [..] FU.File_Visit_Info;
    // odin 的 read_all_directory_by_path：失败即错误（visit_files 的 false 语义相同）。
    if !FU.visit_files(absolute, false, *entries, codegen_collect_entry) {
        fail(g, .{}, tprint("无法读取目录 %", absolute));
        return s;
    }
    paths: [..] string;
    for entry: entries {
        // odin: entry.type != .Regular 跳过；链接在这里也跳过。
        if entry.is_directory || entry.is_symlink continue;
        if !STRING.ends_with(entry.short_name, ".jai") continue;
        if STRING.ends_with(entry.short_name, "_test.jai") continue;
        full, ok := FILE.get_absolute_path(entry.full_name);
        if !ok full = copy_string(entry.full_name);
        array_add(*paths, full);
    }
    SORT.quick_sort(paths, (a: string, b: string) -> s64 {
        return SORT.compare_strings(a, b);
    });
    for path: paths {
        source, read_ok := FILE.read_entire_file(path);
        if !read_ok {
            fail(g, .{}, tprint("无法读取 %", path));
            continue;
        }
        if STRING.starts_with(source, GENERATED_PREFIX) {
            array_add(*s.generated, path);
            continue;
        }
        // Jai 没有 package 声明：包名就是目录名（odin 从第一个文件的 package 行取）。
        if s.package_name == "" s.package_name = copy_string(STRING.path_filename(absolute));
        collect_source(g, s, source, path);
    }
    return s;
}

codegen_collect_entry :: (entry: *FU.File_Visit_Info, entries: *[..] FU.File_Visit_Info) {
    // odin 侧 entry.name/fullpath 借用扫描结果；visit_files 的字符串只在回调里有效，必须复制。
    copy := entry.*;
    copy.short_name = copy_string(entry.short_name);
    copy.full_name = copy_string(entry.full_name);
    array_add(entries, copy);
}

// 带 tag 的声明，按名字排序。重复名字、条件编译内的匹配和无效名字都记错误。结果借用 arena。
decls_tagged :: (g: *Generator, s: *Package_Scan, tag: string) -> [] Decl {
    push_allocator(codegen_arena_allocator(g));
    result: [..] Decl;
    for decl: s.decls {
        if !codegen_contains(decl.tags, tag) continue;
        if decl.conditional {
            fail(g, decl.pos, "标记声明位于条件编译中；请移到无条件声明文件");
            continue;
        }
        if !valid_identifier(decl.name) {
            fail(g, decl.pos, "无法作为成员的声明名");
            continue;
        }
        duplicate := false;
        for previous: result {
            if previous.name != decl.name continue;
            fail(g, decl.pos, tprint("重复成员 %；首次声明在 %:%", decl.name, previous.pos.file, previous.pos.line));
            duplicate = true;
            break;
        }
        if !duplicate array_add(*result, decl);
    }
    SORT.quick_sort(result, (a: Decl, b: Decl) -> s64 {
        return SORT.compare_strings(a.name, b.name);
    });
    return result;
}

// 解析一个源码文本（对应 olib 的 collect_source）。路径只用于诊断。
collect_source :: (g: *Generator, s: *Package_Scan, source: string, path: string) {
    push_allocator(codegen_arena_allocator(g));
    tokens, lexed := codegen_lex(source, path);
    if !lexed || !codegen_balanced(tokens) {
        g.syntax_failed = true;
        fail(g, .{}, tprint("Jai 语法解析失败: %", path));
        return;
    }
    codegen_collect_range(g, s, source, tokens, 0, tokens.count, false);
}

// 遍历 [start, end) 的包级语句；对应 odin 的 collect_statement（只走包级，不进函数体）。
codegen_collect_range :: (g: *Generator, s: *Package_Scan, source: string, tokens: [] Codegen_Token, start: int, end: int, conditional: bool) {
    pending: [..] string; // 独占一行的前导 note 的 tag，归下一条声明
    i := start;
    while i < end {
        token := tokens[i];
        if token.kind == .Note {
            codegen_note_tag(g, tokens, *i, *pending);
            continue;
        }
        // odin 的 Block_Stmt：按同一 conditional 继续
        if token.kind == .Punct && token.text == "{" {
            close := codegen_matching(tokens, i);
            if close >= 0 codegen_collect_range(g, s, source, tokens, i + 1, close, conditional);
            i = ifx close >= 0 then close + 1 else end;
            array_reset(*pending);
            continue;
        }
        if token.kind == .Hash {
            name := "";
            if i + 1 < end && tokens[i + 1].kind == .Ident name = tokens[i + 1].text;
            if name == "if" || name == "ifx" {
                i = codegen_collect_conditional(g, s, source, tokens, i, end);
            } else {
                i = codegen_skip_directive(tokens, i, end);
            }
            array_reset(*pending);
            continue;
        }
        if codegen_decl_starts_at(tokens, i, end) {
            i = codegen_collect_decl(g, s, source, tokens, i, end, conditional, pending);
            array_reset(*pending);
            continue;
        }
        i += 1;
        array_reset(*pending);
    }
}

// #if / #ifx 条件编译块：分支内的声明一律算条件编译（odin 的 when）。返回下一个 token 下标。
codegen_collect_conditional :: (g: *Generator, s: *Package_Scan, source: string, tokens: [] Codegen_Token, start: int, end: int) -> int {
    i := start + 2; // 跳过 '#' 与 if/ifx
    branch_start := i;
    depth := 0;
    while i < end {
        token := tokens[i];
        if token.kind == .Punct {
            if token.text == "(" || token.text == "[" {
                depth += 1;
            } else if token.text == ")" || token.text == "]" {
                depth -= 1;
            } else if depth == 0 && (token.text == "{" || token.text == ";") {
                break;
            }
        }
        i += 1;
    }
    if i >= end return end;
    if tokens[i].text == ";" {
        // 无花括号形式：`#if cond decl;`
        codegen_collect_range(g, s, source, tokens, branch_start, i, true);
        i += 1;
    } else {
        close := codegen_matching(tokens, i);
        if close < 0 return end;
        codegen_collect_range(g, s, source, tokens, i + 1, close, true);
        i = close + 1;
    }
    // else / else #if 分支同样算条件编译
    while i < end {
        token := tokens[i];
        if !(token.kind == .Ident && token.text == "else") break;
        i += 1;
        if i < end && tokens[i].kind == .Hash {
            i = codegen_collect_conditional(g, s, source, tokens, i, end);
            continue;
        }
        if i < end && tokens[i].kind == .Punct && tokens[i].text == "{" {
            close := codegen_matching(tokens, i);
            if close < 0 return end;
            codegen_collect_range(g, s, source, tokens, i + 1, close, true);
            i = close + 1;
            continue;
        }
        // 单条语句形式：`else decl;`
        branch := i;
        depth = 0;
        while i < end {
            t := tokens[i];
            if t.kind == .Punct {
                if t.text == "(" || t.text == "[" || t.text == "{" {
                    depth += 1;
                } else if t.text == ")" || t.text == "]" || t.text == "}" {
                    depth -= 1;
                } else if depth == 0 && t.text == ";" {
                    break;
                }
            }
            i += 1;
        }
        codegen_collect_range(g, s, source, tokens, branch, i, true);
        if i < end i += 1;
    }
    return i;
}

// 跳过一条非条件编译的 # 指令（#import / #load / #module_parameters / #scope_file …）。
codegen_skip_directive :: (tokens: [] Codegen_Token, start: int, end: int) -> int {
    depth := 0;
    i := start + 1;
    while i < end {
        token := tokens[i];
        if token.kind == .Punct {
            if token.text == "(" || token.text == "[" || token.text == "{" {
                depth += 1;
            } else if token.text == ")" || token.text == "]" || token.text == "}" {
                depth -= 1;
                if depth <= 0 return i + 1;
            } else if depth == 0 && token.text == ";" {
                return i + 1;
            }
        }
        // #scope_file 这类不带分号的指令：下一行开始新声明时停
        if depth == 0 && i > start + 1 && token.pos.line > tokens[i - 1].pos.line && codegen_decl_starts_at(tokens, i, end) {
            return i;
        }
        i += 1;
    }
    return end;
}

// 是否是包级声明的起点：Ident (',' Ident)* ('::' | ':')。
codegen_decl_starts_at :: (tokens: [] Codegen_Token, index: int, end: int) -> bool {
    i := index;
    while i < end {
        if tokens[i].kind != .Ident return false;
        i += 1;
        if i >= end return false;
        token := tokens[i];
        if token.kind != .Punct return false;
        if token.text == "::" || token.text == ":" return true;
        if token.text == "," {
            i += 1;
            continue;
        }
        return false;
    }
    return false;
}

// 一条声明的名字及其位置。
Codegen_Name :: struct {
    text: string;
    pos: Pos;
}

// 收集一条声明：拆出名字、值区间、tag；返回下一个 token 的下标。
// leading_tags 是独占一行的前导 note 归属的 tag（见文件头「标记语法」）。
codegen_collect_decl :: (g: *Generator, s: *Package_Scan, source: string, tokens: [] Codegen_Token, start: int, end: int, conditional: bool, leading_tags: [] string) -> int {
    names: [..] Codegen_Name;
    i := start;
    while i < end {
        if tokens[i].kind != .Ident return start + 1;
        array_add(*names, Codegen_Name.{ tokens[i].text, tokens[i].pos });
        i += 1;
        if i >= end return start + 1;
        token := tokens[i];
        if token.kind != .Punct return start + 1;
        if token.text == "," {
            i += 1;
            continue;
        }
        if token.text == "::" || token.text == ":" {
            i += 1;
            break;
        }
        return start + 1;
    }
    value_start := i;

    tags: [..] string;
    for tag: leading_tags array_add(*tags, tag);

    has_value := value_start < end && !(tokens[value_start].kind == .Punct && tokens[value_start].text == ";");
    value_end := source.count;
    if value_start < end value_end = tokens[value_start].pos.offset;
    has_body_brace := false;
    depth := 0;
    last := value_start - 1;
    k := value_start;
    done := false;
    while k < end && !done {
        token := tokens[k];
        if token.kind == .Note {
            // 声明内部的 note（成员 note）不属于这条声明；仍要跳过它的参数，否则原地打转。
            if depth == 0 {
                codegen_note_tag(g, tokens, *k, *tags);
            } else {
                codegen_skip_note(tokens, *k);
            }
            continue;
        }
        if token.kind == .Punct {
            if token.text == "(" || token.text == "[" || token.text == "{" {
                if depth == 0 && token.text == "{" has_body_brace = true;
                depth += 1;
            } else if token.text == ")" || token.text == "]" || token.text == "}" {
                if depth > 0 depth -= 1;
                if depth == 0 {
                    value_end = token.pos.offset + token.text.count;
                    if token.text == "}" {
                        // 顶层花括号组闭合：只有 ';' 或延续符号（成员访问等）才算语句没结束
                        next := k + 1;
                        if next >= end {
                            k = next;
                            done = true;
                        } else {
                            nt := tokens[next];
                            if nt.kind == .Punct && nt.text == ";" {
                                k = next + 1;
                                done = true;
                            } else if nt.kind == .Punct && (nt.text == "." || nt.text == "(" || nt.text == "[" || nt.text == "::") {
                                // 继续（例如 `A :: struct {}.{...}` 这类延伸写法）
                            } else {
                                k = next;
                                done = true;
                            }
                        }
                        if done break;
                    }
                }
            } else if token.text == ";" && depth == 0 {
                value_end = token.pos.offset;
                k += 1;
                done = true;
                break;
            }
        }
        last = k;
        k += 1;
    }
    // 同一行尾随的 note 归本声明；下一行开头的前导 note 归下一条（交给上层 pending）。
    while k < end && last >= 0 && tokens[k].kind == .Note && tokens[k].pos.line == tokens[last].pos.line {
        codegen_note_tag(g, tokens, *k, *tags);
    }

    kind := Decl_Kind.Other;
    if has_value {
        first := tokens[value_start];
        if first.kind == .Ident {
            if first.text == "struct" {
                kind = .Struct;
            } else if first.text == "enum" || first.text == "enum_flags" {
                kind = .Enum;
            } else if first.text == "union" {
                kind = .Union;
            }
        } else if first.kind == .Punct && first.text == "(" && has_body_brace {
            kind = .Proc;
        }
    }
    node := New(Decl_Node);
    node.* = .{ kind = kind, start = tokens[start].pos.offset, end = value_end };
    value: *Decl_Value = null;
    if has_value {
        value = New(Decl_Value);
        value.* = .{ kind = kind, start = tokens[value_start].pos.offset, end = value_end };
    }
    for name: names {
        array_add(*s.decls, Decl.{
            name = name.text,
            tags = tags,
            pos = name.pos,
            conditional = conditional,
            node = node,
            value = value,
        });
    }
    return k;
}

// 跳过 note 及其括号参数（成员 note 用）。返回时 index 指向 note 之后。
codegen_skip_note :: (tokens: [] Codegen_Token, index: *int) {
    index.* += 1;
    if index.* >= tokens.count || tokens[index.*].kind != .Punct || tokens[index.*].text != "(" return;
    depth := 0;
    while index.* < tokens.count {
        token := tokens[index.*];
        if token.kind == .Punct && token.text == "(" depth += 1;
        if token.kind == .Punct && token.text == ")" {
            depth -= 1;
            if depth == 0 {
                index.* += 1;
                return;
            }
        }
        index.* += 1;
    }
}

// 读取一个 note；名字为 tag 时把字符串参数收进 tags。对应 odin 的 attribute_tags。
// 返回时 index 指向 note 之后。
codegen_note_tag :: (g: *Generator, tokens: [] Codegen_Token, index: *int, tags: *[..] string) {
    note := tokens[index.*];
    index.* += 1;
    if note.text != "tag" return; // 其他 note（@UseResult 等）与 odin 的非 tag 属性一样忽略
    if index.* >= tokens.count || tokens[index.*].kind != .Punct || tokens[index.*].text != "(" {
        fail(g, note.pos, "tag 必须使用字符串字面量");
        return;
    }
    index.* += 1;
    if index.* >= tokens.count {
        fail(g, note.pos, "tag 必须使用字符串字面量");
        return;
    }
    literal := tokens[index.*];
    // odin 只接受字符串字面量；Jai 的 #string here-string 无法写在单行 note 里，同样拒绝。
    if literal.kind != .String || literal.raw {
        fail(g, literal.pos, "tag 必须使用字符串字面量");
    } else {
        value, decoded := codegen_unquote_string(literal.text);
        if !decoded {
            fail(g, literal.pos, "无法解码 tag 字符串");
        } else {
            array_add(tags, value);
        }
        index.* += 1;
    }
    // 跳到配对的 ')'
    depth := 1;
    while index.* < tokens.count {
        token := tokens[index.*];
        if token.kind == .Punct && token.text == "(" depth += 1;
        if token.kind == .Punct && token.text == ")" {
            depth -= 1;
            if depth == 0 {
                index.* += 1;
                return;
            }
        }
        index.* += 1;
    }
}

// 对应 odin 里用 tokenizer 判定「能否当成员名」。Jai 侧：标识符规则 + 关键字表。
valid_identifier :: (name: string) -> bool {
    if name == "" || name == "_" return false;
    if !codegen_is_ident_start(name[0]) return false;
    i := 1;
    while i < name.count {
        if !codegen_is_ident_char(name[i]) return false;
        i += 1;
    }
    for keyword: codegen_keywords {
        if name == keyword return false;
    }
    return true;
}

codegen_keywords: [35] string = .[
    "for", "if", "ifx", "then", "else", "case", "return", "struct", "while", "break",
    "continue", "remove", "using", "defer", "size_of", "type_of", "code_of", "initializer_of",
    "type_info", "null", "enum", "true", "false", "inline", "no_inline", "cast", "auto_cast",
    "context", "push_context", "operator", "is_constant", "enum_flags", "union", "interface",
    "import",
];

codegen_contains :: (values: [] string, value: string) -> bool {
    for item: values {
        if item == value return true;
    }
    return false;
}

codegen_at :: (pos: Pos, message: string) -> string {
    if pos.file == "" return copy_string(message);
    return tprint("%:%:%: %", pos.file, pos.line, pos.column, message);
}

// odin: Windows 上用 strings.equal_fold（大小写不敏感），其他平台直接比。
codegen_same_path :: (a: string, b: string) -> bool {
    #if OS == .WINDOWS {
        return STRING.equal_nocase(a, b);
    } else {
        return a == b;
    }
}

// odin 的 filepath.dir：去掉最后一级名字，也不保留结尾分隔符。
codegen_dir :: (path: string) -> string {
    stripped := STRING.path_strip_filename(path);
    end := stripped.count;
    while end > 0 && (stripped[end - 1] == #char "/" || stripped[end - 1] == #char "\\") {
        if end == 3 && stripped[1] == #char ":" break; // "D:/" 是根
        end -= 1;
    }
    return codegen_slice(stripped, 0, end);
}

codegen_eprint :: (message: string) {
    print("%\n", message, to_standard_error = true);
}
//@endregion

//@region 内置生成器

// 生成同包枚举，成员是带 tag 的声明名，按名字排序。序号不保证跨版本稳定，不要写进存档或网络协议。
kind_enum :: (g: *Generator, s: *Package_Scan, tag: string, name: string, out: string) {
    push_allocator(codegen_arena_allocator(g));
    if g.syntax_failed return;
    if !codegen_kind_name_available(g, s, name) return;
    decls := decls_tagged(g, s, tag);
    if decls.count == 0 {
        // 有标记却一个都没收集到时，decls_tagged 已经报过原因。
        if !codegen_tag_declared(s, tag) fail(g, .{}, tprint("% 未找到 tag=% 的声明。", s.dir, codegen_quote(tag)));
        return;
    }
    builder: String_Builder;
    // odin: "%s :: enum {{\n" + "\t%s,\n"；Jai 的枚举成员用 ';' 分隔。
    append(*builder, tprint("% :: enum {\n", name));
    for decl: decls append(*builder, tprint("\t%;\n", decl.name));
    append(*builder, "}\n");
    generator := tprint("kind_enum; tag = %; members sorted by declaration name.", codegen_quote(tag));
    emit(g, s, out, generator, builder_to_string(*builder));
    free_buffers(*builder);
}

// 生成按枚举索引的只读 proc 表，成员是带 tag 的 proc，顺序与同 tag 的 kind_enum 一致。
// 枚举由 kind_enum 生成，这里不生成；signature 与实际声明不一致时由编译器报错。
//
// Jai 差异（相对 odin 的 "@(rodata) %s := [%s]%s {...}"）：
//   - Jai 不能用枚举类型当数组长度（[Kind] 不是常量），所以长度写成成员数；
//   - Jai 的数组字面量没有 `.member = value` 形式，按名字顺序位置初始化——kind_enum 与
//     本表用同一套排序，下标因此一一对应，读取时写 `TABLE[Kind.member]`；
//   - @(rodata) 在 Jai 没有对应 note，生成的是普通常量。
kind_table :: (g: *Generator, s: *Package_Scan, tag: string, kind: string, name: string, signature: string, out: string) {
    push_allocator(codegen_arena_allocator(g));
    if g.syntax_failed return;
    if !codegen_kind_name_available(g, s, name) return;
    if !valid_identifier(kind) {
        fail(g, .{}, tprint("无效的枚举名: %", codegen_quote(kind)));
        return;
    }
    // odin 要求 signature 以 "proc" 开头；Jai 的 proc 类型以 "(" 开头，如 "(w: *World, dt: float)"。
    if !STRING.starts_with(signature, "(") {
        fail(g, .{}, tprint("signature 必须是 proc 类型: %", codegen_quote(signature)));
        return;
    }
    decls := decls_tagged(g, s, tag);
    if decls.count == 0 {
        if !codegen_tag_declared(s, tag) fail(g, .{}, tprint("% 未找到 tag=% 的声明。", s.dir, codegen_quote(tag)));
        return;
    }
    builder: String_Builder;
    append(*builder, tprint("% : [%] % = .[\n", name, decls.count, signature));
    for decl: decls {
        if decl.value == null || decl.value.kind != .Proc {
            fail(g, decl.pos, tprint("kind_table 的成员 % 必须是 proc 声明", decl.name));
            continue;
        }
        append(*builder, tprint("\t%,\n", decl.name));
    }
    append(*builder, "];\n");
    generator := tprint("kind_table; tag = %; members sorted by declaration name.", codegen_quote(tag));
    emit(g, s, out, generator, builder_to_string(*builder));
    free_buffers(*builder);
}

codegen_tag_declared :: (s: *Package_Scan, tag: string) -> bool {
    for decl: s.decls {
        if codegen_contains(decl.tags, tag) return true;
    }
    return false;
}

codegen_kind_name_available :: (g: *Generator, s: *Package_Scan, name: string) -> bool {
    if !valid_identifier(name) {
        fail(g, .{}, tprint("无效的 Jai 标识符: %", codegen_quote(name)));
        return false;
    }
    for decl: s.decls {
        if decl.name == name {
            fail(g, decl.pos, tprint("生成名 % 与现有声明冲突", name));
            return false;
        }
    }
    return true;
}
//@endregion

//@region 写盘

// 先校验全部输出再动文件：手写文件冲突时一个文件都不改。
codegen_commit :: (g: *Generator) -> (exit_code: int) {
    changed: [..] Codegen_Output;
    stale: [..] string;
    refused := false;
    for output: g.outputs {
        if FU.file_exists(output.path) {
            previous, read_ok := FILE.read_entire_file(output.path);
            if !read_ok {
                codegen_eprint(tprint("无法读取 %", output.path));
                refused = true;
                continue;
            }
            // Git autocrlf 可能转换正式生成源码；仅换行差异不应触发重写或覆盖保护。
            normalized, _ := STRING.replace(previous, "\r\n", "\n");
            if normalized == output.content continue;
            if !STRING.starts_with(normalized, GENERATED_PREFIX) {
                codegen_eprint(tprint("拒绝覆盖手写文件: %", output.path));
                refused = true;
                continue;
            }
        }
        array_add(*changed, output);
    }
    if refused return 1;
    if g.prune {
        for s: g.scans {
            for path: s.generated {
                if !codegen_output_exists(g, path) array_add(*stale, path);
            }
        }
    }
    if g.check {
        for output: changed codegen_eprint(tprint("生成文件缺失或已过期: %", output.path));
        for path: stale codegen_eprint(tprint("生成文件已没有来源: %", path));
        return ifx changed.count + stale.count > 0 then 1 else 0;
    }
    for output: changed {
        error := codegen_write_output(output);
        if error != "" {
            codegen_eprint(error);
            return 1;
        }
        print("已生成: %\n", output.path);
    }
    for path: stale {
        if !FILE.file_delete(path) {
            codegen_eprint(tprint("无法删除 %", path));
            return 1;
        }
        print("已删除: %\n", path);
    }
    if changed.count + stale.count == 0 print("生成文件已是最新\n");
    return 0;
}

codegen_output_exists :: (g: *Generator, path: string) -> bool {
    for output: g.outputs {
        if codegen_same_path(output.path, path) return true;
    }
    return false;
}

codegen_temp_counter: s64;

// 临时文件在目标同目录，写完再一次替换（odin 侧是 create_temp_file + 一次 rename）。
codegen_write_output :: (output: Codegen_Output) -> (error: string) {
    dir := codegen_dir(output.path);
    if dir == "" dir = ".";
    counter := codegen_temp_counter;
    codegen_temp_counter += 1;
    temporary := tprint("%/.codegen-%-%.tmp", dir, counter, SYS.read_cpu_counter());
    if !FILE.write_entire_file(temporary, output.content) {
        // odin: fmt.aprintf("无法创建临时文件: %v", create_error)
        return tprint("无法创建临时文件: %", temporary);
    }
    // write_entire_file 内部写满并 flush，等价于 odin 的「写满 + 校验长度 + close」。
    if FILE.file_move(temporary, output.path) return "";
    // jacket 的 file_move 在 Windows 上是 MoveFileW，不覆盖已存在的目标；odin 的 os.rename
    // 是覆盖语义，所以这里先删目标再改名，结果相同。
    if FU.file_exists(output.path) && FILE.file_delete(output.path) && FILE.file_move(temporary, output.path) return "";
    FILE.file_delete(temporary);
    return tprint("无法替换 %", output.path);
}
//@endregion
