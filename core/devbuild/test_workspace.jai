// test_workspace —— 集中测试的只读发现与独占源码工作区。仅供开发工具；不属于游戏运行时。
// 一比一移植自 olib core/devbuild/test_workspace.odin。
//
// 返回的字符串/切片归调用方 allocator；Workspace 必须且只需 dispose 一次。
//
// 生产代码放原包，测试放 tests/<包路径>；工作区由 test_workspace_prepare 独占创建，
// 生产代码始终只读（只复制 .jai 源码，资源仍在原目录里）。prepare/run 的诊断由 allocator
// 拥有；test_source_paths 的成功结果独立拥有。工作区只存平面源码，不递归删除源树。
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   - 编译器：odin 的 `test <dir>` 一次完成「整目录编译 + 运行」；jacket 的 jaic 一次只编译
//     一个入口文件、也没有 test 子命令。所以 test_workspace_run 把命令拼成
//     `jaic <入口> <调用方给出的参数>`，入口按字典序取工作区里第一个声明了 main 的 .jai
//     （都没有 main 时退回第一个 .jai）；「编译+运行」由调用方传 `-interp` 完成（解释执行
//     main），编译失败/未知选项与 olib 一样表现为非零退出码 + 非空诊断；
//   - import 映射：odin 用 collection（`-collection:name=root`，源码里写 `name:rel`）
//     把相对 import 指到包根；Jai 没有 collection 语法，`#import` 一律由 `-import_dir`
//     顺序查找。所以这里映射成「相对 collection root 的普通路径」（不带 name: 前缀），
//     Test_Collection.name 仅为与 olib 的 API 对齐而保留、不参与映射；调用方按同样顺序
//     把每个 collection.root 传给 `-import_dir`。判定「是不是相对 import」也不同：
//     odin 看路径里有没有 `:`，Jai 看是否以 `./`、`../` 开头（其余交给 -import_dir）；
//   - 源码聚合：Jai 用 `#load "x.jai";`（不带括号）把一个文件并进当前文件，odin 没有这种
//     形式。olib 对不带括号的 #load 报 "Invalid #load"，这里原样保留（不重写），否则
//     Jai 的包聚合文件根本无法通过 prepare；带括号的资源指令判定与 olib 完全相同；
//   - token：本文件自带一个最小词法分析器（test_tokens）替代 core:odin/tokenizer，
//     保留 odin 的 token 分类、注释过滤与换行处的自动分号插入（Insert_Semicolon），
//     只关心重写用得到的 token；od方案的 tokenizer.error_count 换成「是否出现 Invalid
//     token」（未终止的字符串/注释/字符）；
//   - package 名：Jai 没有 package 声明（包名就是目录名），所以 test_source_info 在 token
//     有效时 ok 为 true，name 为空；test_collect 遇到空 name 时用目录名补上；
//   - 错误信息：odin 的 `%v`（错误对象）在 Jai 里没有等价物（IO 只返回 bool），诊断文本
//     保留同样的前缀与位置，失败原因写成固定的短句；
//   - 分配器：odin 用 context.allocator + context.temp_allocator 双轨；本移植把内部数据
//     统一放 temp，返回值用 test_alloc_string/test_alloc_array 显式按 allocator 复制一份。
//     dispose 用 workspace.allocator 释放，与 olib 的所有权约定一致；
//   - Jai 没有具名返回值：返回值里的名字写在各过程上方的注释里，顺序与 olib 相同。
#import "Basic";
STRING :: #import "String";
FILE :: #import "File";
FU :: #import "File_Utilities";
SORT :: #import "Sort";
HASH :: #import "Hash_Table";
ENV :: #import "Extensions/Environment";
SYS :: #import "System";

//@region 发现与声明

Test_Package :: struct {
    path: string;
    name: string;
    has_tests: bool;
    diagnostic: string; // 发现/读取失败必须由消费者报告，不能跳过坏测试。
}

Test_Collection :: struct {
    name: string;
    root: string; // 绝对路径；相对 import 必须落在其中一个 root 内。
}

// 返回 (name, has_tests, ok)。
// name 借用 source；仅识别 token，不把注释或字符串里的 @(test) 当声明。
test_source_info :: (source: string, path: string) -> (string, bool, bool) {
    tokens, valid := test_tokens(source, path);
    if !valid return "", false, false;
    name := "";
    has_tests := false;
    for token, i: tokens {
        if token.kind == .Package && i + 1 < tokens.count && tokens[i + 1].kind == .Ident {
            name = tokens[i + 1].text;
        }
        if token.kind != .At || i + 1 >= tokens.count || tokens[i + 1].kind != .Open_Paren {
            continue;
        }
        depth := 0;
        j := i + 1;
        while j < tokens.count {
            next := tokens[j];
            if next.kind == .Open_Paren {
                depth += 1;
            }
            if next.kind == .Close_Paren {
                depth -= 1;
            }
            if depth == 0 break;
            if depth == 1 && next.kind == .Ident && next.text == "test" {
                has_tests = true;
            }
            j += 1;
        }
    }
    // odin 版是 `return name, has_tests, name != ""`；Jai 没有 package 声明，缺名字不再是
    // 失败（包名交给目录名补），只有坏 token 才算失败。见文件头。
    return name, has_tests, true;
}

// 返回 (packages)。结果归 allocator，用 test_packages_dispose 释放。
test_discover :: (root: string, dirs: [] string, allocator_in: Allocator = context.allocator) -> [] Test_Package {
    // 默认参数里的 context.allocator 在函数体首次使用时求值；必须在 push 之前捕获。
    allocator := allocator_in;
    push_allocator(temp);
    collected: [..] Test_Package;
    for dir: dirs {
        test_collect(root, dir, *collected);
    }
    SORT.quick_sort(collected, (a: Test_Package, b: Test_Package) -> s32 {
        return cast(s32) STRING.compare_nocase(a.path, b.path);
    });
    // 内部在 temp 上收集（odin 直接分配在 allocator 上）；返回前按 allocator 复制一份，
    // 这样 test_packages_dispose 用同一个 allocator 释放是对的。
    packages := test_alloc_array(Test_Package, collected.count, allocator);
    for p, k: collected {
        packages[k] = Test_Package.{
            path = test_alloc_string(p.path, allocator),
            name = test_alloc_string(p.name, allocator),
            has_tests = p.has_tests,
            diagnostic = test_alloc_string(p.diagnostic, allocator),
        };
    }
    return packages;
}

// 释放 discover 的所有结果（path/name 以及切片）。
test_packages_dispose :: (packages: [] Test_Package, allocator: Allocator = context.allocator) {
    for p: packages {
        test_free_string(p.path, allocator);
        test_free_string(p.name, allocator);
        test_free_string(p.diagnostic, allocator);
    }
    if packages.data != null {
        allocator.proc(.FREE, 0, 0, packages.data, allocator.data);
    }
}

test_collect :: (root: string, relative: string, result: *[..] Test_Package) {
    entries, read_ok := test_read_directory(test_join(root, relative));
    if !read_ok {
        array_add(result, Test_Package.{
            path = copy_temporary_string(relative),
            diagnostic = tprint("Cannot discover %: read_all_directory failed", relative),
        });
        return;
    }
    name := "";
    diagnostic := "";
    has_source := false;
    has_tests := false;
    for entry: entries {
        if entry.is_directory {
            test_collect(root, tprint("%/%", relative, entry.name), result);
            continue;
        }
        if !STRING.ends_with(entry.name, ".jai") continue;
        has_source = true;
        bytes, read_error := FILE.read_entire_file(entry.full_path);
        if !read_error {
            diagnostic = tprint("Cannot read %: read_entire_file failed", entry.full_path);
            continue;
        }
        declared, tests, info_ok := test_source_info(bytes, entry.full_path);
        if !info_ok {
            diagnostic = tprint("Invalid source tokens or package declaration: %", entry.full_path);
            continue;
        }
        if name == "" {
            // Jai：没有 package 声明就退回目录名（Jai 的包名就是目录名）。
            if declared != "" {
                name = copy_temporary_string(declared);
            } else {
                name = copy_temporary_string(test_base_name(relative));
            }
        }
        has_tests = has_tests || tests;
    }
    if has_source {
        array_add(result, Test_Package.{
            path = copy_temporary_string(relative),
            name = copy_temporary_string(name),
            has_tests = has_tests,
            diagnostic = copy_temporary_string(diagnostic),
        });
    }
}
//@endregion

//@region 生命周期与执行

Test_Workspace :: struct {
    directory: string;
    allocator: Allocator;
}

// 生产目录与镜像测试目录必须存在；同名文件与坏 token 均失败，不回写源文件。
// 失败已清理工作区；error 字符串独立拥有，成功时为空。
test_workspace_prepare :: (
    source_directory: string,
    test_directory: string,
    collections: [] Test_Collection,
    allocator_in: Allocator = context.allocator,
) -> (Test_Workspace, string) {
    // 默认参数里的 context.allocator 在函数体首次使用时求值；必须在 push 之前捕获。
    allocator := allocator_in;
    push_allocator(temp);
    directory, created := test_make_directory_temp("olib_unit_");
    if !created {
        return Test_Workspace.{}, test_alloc_string("Cannot create test workspace: temporary directory", allocator);
    }
    // directory 是 temp；工作区自己持有一份 allocator 上的拷贝，dispose 用它释放。
    candidate := Test_Workspace.{ directory = test_alloc_string(directory, allocator), allocator = allocator };
    error_message := test_workspace_fill(candidate, source_directory, test_directory, collections);
    if error_message != "" {
        // odin 用 defer + success 标志做同一件事：失败时清掉刚建的工作区。
        test_workspace_dispose(*candidate);
        return Test_Workspace.{}, test_alloc_string(error_message, allocator);
    }
    return candidate, "";
}

// odin 版 prepare 里的双层循环：把两个目录下的 .jai 复制进工作区（平面）。
// 返回空串表示成功，否则是 temp 上的诊断。
test_workspace_fill :: (
    workspace: Test_Workspace,
    source_directory: string,
    test_directory: string,
    collections: [] Test_Collection,
) -> string {
    push_allocator(temp);
    inputs: [2] string = .[source_directory, test_directory];
    for input: inputs {
        entries, read_error := test_read_directory(input);
        if !read_error return tprint("Cannot read %: read_all_directory failed", input);
        for entry: entries {
            if entry.is_directory || !STRING.ends_with(entry.name, ".jai") continue;
            if entry.is_symlink return tprint("Not a regular source: %", entry.full_path);
            destination := test_join(workspace.directory, entry.name);
            if FU.file_exists(destination) {
                return tprint("Duplicate source/test filename: %", entry.name);
            }
            bytes, source_error := FILE.read_entire_file(entry.full_path);
            if !source_error return tprint("Cannot read %: read_entire_file failed", entry.full_path);
            content, rewrite_error := test_source_paths(bytes, entry.full_path, collections, temp);
            if rewrite_error != "" return rewrite_error;
            if !FILE.write_entire_file(destination, content) {
                return tprint("Cannot write %: write_entire_file failed", destination);
            }
        }
    }
    return "";
}

// 只删除本机制创建的平面文件；不递归、不跟随链接，不接受任意目录路径。
test_workspace_dispose :: (workspace: *Test_Workspace) -> bool {
    if workspace.directory == "" return true;
    push_allocator(temp);
    entries, err := test_read_directory(workspace.directory);
    ok := err;
    if err {
        for entry: entries {
            if entry.is_directory {
                ok = false;
                continue;
            }
            if !FILE.file_delete(entry.full_path) ok = false;
        }
    }
    if !FILE.delete_directory(workspace.directory) ok = false;
    test_free_string(workspace.directory, workspace.allocator);
    workspace.* = Test_Workspace.{};
    return ok;
}

// 先 prepare/defer dispose 再执行；即使编译器/测试失败，调用方也能可靠清理。
// 返回 (ok, diagnostic)；诊断归 allocator，命令行不经过 shell。
test_workspace_run :: (
    workspace: *Test_Workspace,
    root: string,
    arguments: [] string,
    allocator_in: Allocator = context.allocator,
) -> (bool, string) {
    // 默认参数里的 context.allocator 在函数体首次使用时求值；必须在 push 之前捕获。
    allocator := allocator_in;
    push_allocator(temp);
    // odin: `odin test <workspace.directory> <arguments>`
    // Jai : `jaic <工作区入口文件> <arguments>`
    command: [..] string;
    array_add(*command, "jaic");
    entry := test_entry_file(workspace.directory);
    if entry != "" array_add(*command, entry);
    for argument: arguments {
        array_add(*command, argument);
    }
    state, out, errout, err := exec(Process_Desc.{ working_dir = root, command = command }, temp);
    tail := "";
    if err != .None tail = "process launch failed";
    ok := err == .None && state.exited && state.exit_code == 0;
    return ok, test_alloc_string(tprint("%%%", out, errout, tail), allocator);
}
//@endregion

//@region 路径 token 重写

// 支持字符串（含 raw/转义）、#directory、简单字符串常量、括号与 +。
// 资源指令未知表达式明确失败；不改变普通字符串、注释或生产文件。
// 返回 (result, error)；成功结果归 allocator、错误也归 allocator，成功时 error 为空。
test_source_paths :: (
    source: string,
    path: string,
    collections: [] Test_Collection,
    allocator_in: Allocator = context.allocator,
) -> (string, string) {
    // 默认参数里的 context.allocator 在函数体首次使用时求值；必须在 push 之前捕获。
    allocator := allocator_in;
    push_allocator(temp);
    directory := test_dir(path);

    tokens, valid := test_tokens(source, path);
    if !valid return "", test_alloc_string(tprint("Invalid Odin tokens: %", path), allocator);

    // 文件级简单常量：Ident 紧跟 :: 且不在任何块内。重复声明记 -1（拒绝），
    // 与 olib 的 map[string]int 语义相同。
    constants: HASH.Table(string, int);
    constant_depth := 0;
    for token, i: tokens {
        if token.kind == .Open_Brace {
            constant_depth += 1;
        }
        if token.kind == .Close_Brace {
            constant_depth -= 1;
        }
        if constant_depth != 0 continue;
        if token.kind == .Ident && i + 2 < tokens.count &&
           tokens[i + 1].kind == .Colon && tokens[i + 2].kind == .Colon {
            found, _ := HASH.table_find(*constants, token.text);
            if found {
                HASH.table_add(*constants, token.text, -1);
            } else {
                HASH.table_add(*constants, token.text, i + 3);
            }
        }
    }

    builder: String_Builder;
    defer free_buffers(*builder);

    last := 0;
    import_path := false;
    brace_depth := 0;
    error_message := "";
    i := 0;
    while i < tokens.count && error_message == "" {
        token := tokens[i];
        if token.kind == .Open_Brace {
            brace_depth += 1;
        }
        if token.kind == .Close_Brace {
            brace_depth -= 1;
        }
        start := token.offset;
        end := start + token.text.count;
        replacement := "";
        if token.kind == .Import {
            import_path = true;
        }
        if token.kind == .Semicolon {
            import_path = false;
        }
        if import_path && token.kind == .String_Literal {
            value, unquoted := test_unquote_string(token.text);
            if !unquoted {
                error_message = tprint("Invalid import string: %", path);
                break;
            }
            // odin 看路径里有没有 `:`；Jai 只看 `./`、`../`（见文件头）。
            if test_is_relative_import(value) {
                resolved := test_join(directory, value);
                mapped := "";
                for collection: collections {
                    rel, rel_ok := test_rel(collection.root, resolved);
                    if !rel_ok continue;
                    if test_is_abs(rel) || rel == ".." ||
                       STRING.begins_with(rel, "../") || STRING.begins_with(rel, "..\\") continue;
                    mapped = test_to_slashes(rel);
                    break;
                }
                if mapped == "" {
                    error_message = tprint("Relative import outside collections in %: %", path, value);
                    break;
                }
                replacement = test_quote(mapped);
            }
            import_path = false;
        }
        if token.kind == .Hash && i + 1 < tokens.count {
            directive := tokens[i + 1].text;
            if directive == "directory" {
                replacement = test_quote(directory);
                end = tokens[i + 1].offset + tokens[i + 1].text.count;
                i += 1;
            } else if directive == "load" || directive == "load_directory" || directive == "exists" {
                position := i + 2;
                if position >= tokens.count || tokens[position].kind != .Open_Paren {
                    // Jai 的源码聚合形式（#load "x.jai"，不带括号）不是资源指令：原样保留。
                    // odin 版在这里报 "Invalid #load"；Jai 只能这样并文件，故放行（见文件头）。
                    if directive != "load" {
                        error_message = tprint("Invalid #% in %", directive, path);
                        break;
                    }
                } else {
                    position += 1;
                    first := position;
                    // 块内不尝试推断局部遮蔽；字面量/#directory 仍支持，常量标识符明确拒绝。
                    path_constants: *HASH.Table(string, int) = *constants;
                    if brace_depth != 0 path_constants = null;
                    value, ok := test_path_expression(tokens, *position, path_constants, directory, 0);
                    if !ok || position >= tokens.count ||
                       (tokens[position].kind != .Close_Paren && tokens[position].kind != .Comma) {
                        error_message = tprint("Unsupported #% path expression in %", directive, path);
                        break;
                    }
                    start = tokens[first].offset;
                    end = tokens[position - 1].offset + tokens[position - 1].text.count;
                    replacement = test_quote(test_join(directory, value));
                    i = position - 1;
                }
            }
        }
        if replacement != "" {
            append(*builder, test_substring(source, last, start));
            append(*builder, replacement);
            last = end;
        }
        i += 1;
    }
    if error_message != "" return "", test_alloc_string(error_message, allocator);
    append(*builder, test_substring(source, last, source.count));
    return test_alloc_string(builder_to_string(*builder), allocator), "";
}

// 返回 (value, ok)。constants 为 null 表示「块内，拒绝常量标识符」。
test_path_expression :: (
    tokens: [] Token,
    position: *int,
    constants: *HASH.Table(string, int),
    directory: string,
    depth: int,
) -> (string, bool) {
    if depth >= 32 || position.* >= tokens.count return "", false;
    token := tokens[position.*];
    position.* += 1;
    value := "";
    ok := false;
    if token.kind == .String_Literal {
        value, ok = test_unquote_string(token.text);
        if !ok return "", false;
    } else if token.kind == .Hash {
        if position.* >= tokens.count || tokens[position.*].text != "directory" return "", false;
        position.* += 1;
        value = directory;
        ok = true;
    } else if token.kind == .Ident {
        if constants == null return "", false;
        found, index := HASH.table_find(constants, token.text);
        if !found || index < 0 return "", false;
        value, ok = test_path_expression(tokens, *index, constants, directory, depth + 1);
        if !ok || index >= tokens.count || tokens[index].kind != .Semicolon return "", false;
    } else if token.kind == .Open_Paren {
        value, ok = test_path_expression(tokens, position, constants, directory, depth + 1);
        if !ok || position.* >= tokens.count || tokens[position.*].kind != .Close_Paren return "", false;
        position.* += 1;
    } else {
        // odin 的 #partial switch 无匹配时 ok 保持 false，等价。
        return "", false;
    }
    if position.* < tokens.count && tokens[position.*].kind == .Add {
        position.* += 1;
        right, right_ok := test_path_expression(tokens, position, constants, directory, depth + 1);
        if !right_ok return "", false;
        value = tprint("%%", value, right);
    }
    return value, ok;
}

// 返回 (tokens, ok)。ok 对应 odin tokenizer 的 error_count == 0。
// 替代 core:odin/tokenizer：保留 token 分类、注释过滤与换行处的自动分号插入。
test_tokens :: (source: string, path: string) -> ([..] Token, bool) {
    push_allocator(temp);
    tokens: [..] Token;
    ok := true;
    has_last := false;
    last := Token_Kind.Invalid;
    i := 0;
    while i < source.count {
        c := source[i];

        // 换行：odin 只在「上一 token 能结束语句」时插分号。
        if c == #char "\n" {
            if has_last && test_can_end_statement(last) {
                array_add(*tokens, Token.{ kind = .Semicolon, text = "", offset = i });
                last = .Semicolon;
            }
            i += 1;
            continue;
        }
        if c == #char " " || c == #char "\t" || c == #char "\r" || c == #char "\v" || c == #char "\f" {
            i += 1;
            continue;
        }
        // 注释不进入结果（olib 过滤 .Comment）。
        if c == #char "/" && i + 1 < source.count && source[i + 1] == #char "/" {
            i += 2;
            while i < source.count && source[i] != #char "\n" i += 1;
            continue;
        }
        if c == #char "/" && i + 1 < source.count && source[i + 1] == #char "*" {
            block_start := i;
            depth := 0;
            while i < source.count {
                if source[i] == #char "/" && i + 1 < source.count && source[i + 1] == #char "*" {
                    depth += 1;
                    i += 2;
                    continue;
                }
                if source[i] == #char "*" && i + 1 < source.count && source[i + 1] == #char "/" {
                    depth -= 1;
                    i += 2;
                    if depth == 0 break;
                    continue;
                }
                i += 1;
            }
            if depth != 0 {
                ok = false;
                array_add(*tokens, Token.{ kind = .Invalid, text = test_substring(source, block_start, i), offset = block_start });
            }
            continue;
        }
        if c == #char "\"" {
            string_start := i;
            i += 1;
            closed := false;
            while i < source.count {
                if source[i] == #char "\\" {
                    i += 2;
                    continue;
                }
                if source[i] == #char "\"" {
                    i += 1;
                    closed = true;
                    break;
                }
                if source[i] == #char "\n" break; // odin 的普通字符串不跨行
                i += 1;
            }
            if !closed {
                ok = false;
                array_add(*tokens, Token.{ kind = .Invalid, text = test_substring(source, string_start, min(i, source.count)), offset = string_start });
                continue;
            }
            array_add(*tokens, Token.{ kind = .String_Literal, text = test_substring(source, string_start, i), offset = string_start });
            last = .String_Literal;
            has_last = true;
            continue;
        }
        if c == #char "`" {
            string_start := i;
            i += 1;
            closed := false;
            while i < source.count {
                if source[i] == #char "`" {
                    i += 1;
                    closed = true;
                    break;
                }
                i += 1;
            }
            if !closed {
                ok = false;
                array_add(*tokens, Token.{ kind = .Invalid, text = test_substring(source, string_start, source.count), offset = string_start });
                continue;
            }
            array_add(*tokens, Token.{ kind = .String_Literal, text = test_substring(source, string_start, i), offset = string_start });
            last = .String_Literal;
            has_last = true;
            continue;
        }
        if c == #char "'" {
            char_start := i;
            i += 1;
            closed := false;
            while i < source.count {
                if source[i] == #char "\\" {
                    i += 2;
                    continue;
                }
                if source[i] == #char "'" {
                    i += 1;
                    closed = true;
                    break;
                }
                i += 1;
            }
            if !closed {
                ok = false;
                array_add(*tokens, Token.{ kind = .Invalid, text = test_substring(source, char_start, min(i, source.count)), offset = char_start });
                continue;
            }
            array_add(*tokens, Token.{ kind = .Char_Literal, text = test_substring(source, char_start, i), offset = char_start });
            last = .Char_Literal;
            has_last = true;
            continue;
        }
        if test_is_ident_start(c) {
            ident_start := i;
            while i < source.count && test_is_ident_char(source[i]) i += 1;
            text := test_substring(source, ident_start, i);
            kind := Token_Kind.Ident;
            if text == "import" {
                kind = .Import;
            } else if text == "package" {
                kind = .Package;
            }
            array_add(*tokens, Token.{ kind = kind, text = text, offset = ident_start });
            last = kind;
            has_last = true;
            continue;
        }
        if test_is_digit(c) {
            number_start := i;
            while i < source.count &&
                  (test_is_ident_char(source[i]) || source[i] == #char ".") i += 1;
            array_add(*tokens, Token.{ kind = .Number, text = test_substring(source, number_start, i), offset = number_start });
            last = .Number;
            has_last = true;
            continue;
        }

        kind := Token_Kind.Other;
        width := 1;
        if c == #char "(" {
            kind = .Open_Paren;
        } else if c == #char ")" {
            kind = .Close_Paren;
        } else if c == #char "{" {
            kind = .Open_Brace;
        } else if c == #char "}" {
            kind = .Close_Brace;
        } else if c == #char "[" {
            kind = .Open_Bracket;
        } else if c == #char "]" {
            kind = .Close_Bracket;
        } else if c == #char "," {
            kind = .Comma;
        } else if c == #char ";" {
            kind = .Semicolon;
        } else if c == #char ":" {
            kind = .Colon;
        } else if c == #char "+" {
            kind = .Add;
        } else if c == #char "@" {
            kind = .At;
        } else if c == #char "#" {
            // Jai 的 #import 与 odin 的 import 在重写里是同一件事：合并成一个 Import token。
            if test_word_at(source, i + 1, "import") {
                kind = .Import;
                width = 7;
            } else {
                kind = .Hash;
            }
        }
        array_add(*tokens, Token.{ kind = kind, text = test_substring(source, i, i + width), offset = i });
        last = kind;
        has_last = true;
        i += width;
    }
    if has_last && test_can_end_statement(last) {
        array_add(*tokens, Token.{ kind = .Semicolon, text = "", offset = source.count });
    }
    return tokens, ok;
}

// 返回 (path)。odin 的 filepath.join + filepath.clean（第二次调用时绝对路径直接 clean）。
test_join :: (parts: ..string) -> string {
    if parts.count == 2 && test_is_abs(parts[1]) return test_clean(parts[1]);
    builder: String_Builder;
    for part, k: parts {
        if k > 0 append(*builder, "/");
        append(*builder, part);
    }
    return test_clean(builder_to_string(*builder));
}
//@endregion

//@region 内部桥接（Jai 没有 stdlib 等价物的部分）

// 词法 token：只保留重写与发现用得到的分类。
Token_Kind :: enum u8 {
    Invalid; // 未终止的字符串/字符/块注释
    Ident;
    Number;
    String_Literal;
    Char_Literal;
    Hash;
    At;
    Import; // odin 的 import 关键字；Jai 的 #import 合并成同一个 token
    Package; // odin 的 package 关键字
    Open_Paren;
    Close_Paren;
    Open_Brace;
    Close_Brace;
    Open_Bracket;
    Close_Bracket;
    Comma;
    Semicolon;
    Colon;
    Add;
    Other; // 其余运算符/分隔符：只占位，不参与重写
}

Token :: struct {
    kind: Token_Kind;
    text: string;
    offset: int; // odin 的 token.pos.offset
}

// 能结束一条语句的 token（odin tokenizer 插分号的条件）。
test_can_end_statement :: (kind: Token_Kind) -> bool {
    if kind == .Ident return true;
    if kind == .Number return true;
    if kind == .String_Literal return true;
    if kind == .Char_Literal return true;
    if kind == .Close_Paren return true;
    if kind == .Close_Brace return true;
    if kind == .Close_Bracket return true;
    return false;
}

test_is_ident_start :: (c: u8) -> bool {
    if c >= #char "a" && c <= #char "z" return true;
    if c >= #char "A" && c <= #char "Z" return true;
    return c == #char "_";
}

test_is_ident_char :: (c: u8) -> bool {
    return test_is_ident_start(c) || test_is_digit(c);
}

test_is_digit :: (c: u8) -> bool {
    return c >= #char "0" && c <= #char "9";
}

test_hex_value :: (c: u8) -> int {
    if c >= #char "0" && c <= #char "9" return cast(int) (c - #char "0");
    if c >= #char "a" && c <= #char "f" return cast(int) (c - #char "a") + 10;
    if c >= #char "A" && c <= #char "F" return cast(int) (c - #char "A") + 10;
    return -1;
}

// source[at..at+word.count] 是否正好是 word（且后面不再接标识符字符）。
test_word_at :: (source: string, at: int, word: string) -> bool {
    if at + word.count > source.count return false;
    for k: 0..word.count - 1 {
        if source[at + k] != word[k] return false;
    }
    if at + word.count < source.count && test_is_ident_char(source[at + word.count]) return false;
    return true;
}

// 字符串视图（Jai 没有 s[a:b] 语法）。
test_substring :: (source: string, start: int, end: int) -> string {
    if end <= start || start >= source.count return "";
    return string.{ end - start, source.data + start };
}

// 按指定 allocator 复制字符串（odin 的 fmt.aprintf / strings.clone 带 allocator）。
test_alloc_string :: (value: string, allocator: Allocator) -> string {
    if value.count == 0 return "";
    data := cast(*u8) allocator.proc(.ALLOCATE, value.count, 0, null, allocator.data);
    if data == null return "";
    memcpy(data, value.data, value.count);
    return string.{ value.count, data };
}

test_free_string :: (value: string, allocator: Allocator) {
    if value.data == null || value.count == 0 return;
    allocator.proc(.FREE, 0, 0, value.data, allocator.data);
}

test_alloc_array :: ($T: Type, count: int, allocator: Allocator) -> [] T {
    result: [] T;
    if count <= 0 return result;
    data := cast(*T) allocator.proc(.ALLOCATE, count * size_of(T), 0, null, allocator.data);
    if data == null return result;
    result.data = data;
    result.count = count;
    return result;
}

// %q 的等价物：加双引号并转义引号与反斜杠（Windows 路径里全是反斜杠）。
test_quote :: (value: string) -> string {
    out: [..] u8;
    array_add(*out, #char "\"");
    for c: value {
        if c == #char "\"" || c == #char "\\" array_add(*out, #char "\\");
        array_add(*out, c);
    }
    array_add(*out, #char "\"");
    return string.{ out.count, out.data };
}

// odin 的 strconv.unquote_string：去掉引号并解码转义；反引号原样串。
// 返回 (value, ok)。
test_unquote_string :: (text: string) -> (string, bool) {
    if text.count < 2 return "", false;
    if text[0] == #char "`" {
        if text[text.count - 1] != #char "`" return "", false;
        return test_substring(text, 1, text.count - 1), true;
    }
    if text[0] != #char "\"" return "", false;
    if text[text.count - 1] != #char "\"" return "", false;
    body := test_substring(text, 1, text.count - 1);
    out: [..] u8;
    i := 0;
    while i < body.count {
        c := body[i];
        if c != #char "\\" {
            array_add(*out, c);
            i += 1;
            continue;
        }
        if i + 1 >= body.count return "", false;
        escaped := body[i + 1];
        i += 2;
        if escaped == #char "n" {
            array_add(*out, #char "\n");
            continue;
        }
        if escaped == #char "r" {
            array_add(*out, #char "\r");
            continue;
        }
        if escaped == #char "t" {
            array_add(*out, #char "\t");
            continue;
        }
        if escaped == #char "a" {
            array_add(*out, #char "\a");
            continue;
        }
        if escaped == #char "b" {
            array_add(*out, #char "\b");
            continue;
        }
        if escaped == #char "e" {
            array_add(*out, cast(u8) 0x1B);
            continue;
        }
        if escaped == #char "f" {
            array_add(*out, #char "\f");
            continue;
        }
        if escaped == #char "v" {
            array_add(*out, #char "\v");
            continue;
        }
        if escaped == #char "0" {
            array_add(*out, cast(u8) 0);
            continue;
        }
        if escaped == #char "\\" || escaped == #char "\"" || escaped == #char "'" {
            array_add(*out, escaped);
            continue;
        }
        digits := 0;
        if escaped == #char "x" {
            digits = 2;
        } else if escaped == #char "u" {
            digits = 4;
        } else if escaped == #char "U" {
            digits = 8;
        }
        if digits == 0 return "", false;
        if i + digits > body.count return "", false;
        codepoint := 0;
        for k: 0..digits - 1 {
            hex := test_hex_value(body[i + k]);
            if hex < 0 return "", false;
            codepoint = codepoint * 16 + hex;
        }
        i += digits;
        test_append_utf8(*out, codepoint);
    }
    return string.{ out.count, out.data }, true;
}

test_append_utf8 :: (out: *[..] u8, codepoint: int) {
    if codepoint < 0x80 {
        array_add(out, cast(u8) codepoint);
        return;
    }
    if codepoint < 0x800 {
        array_add(out, cast(u8) (0xC0 | (codepoint >> 6)));
        array_add(out, cast(u8) (0x80 | (codepoint & 0x3F)));
        return;
    }
    if codepoint < 0x10000 {
        array_add(out, cast(u8) (0xE0 | (codepoint >> 12)));
        array_add(out, cast(u8) (0x80 | ((codepoint >> 6) & 0x3F)));
        array_add(out, cast(u8) (0x80 | (codepoint & 0x3F)));
        return;
    }
    array_add(out, cast(u8) (0xF0 | (codepoint >> 18)));
    array_add(out, cast(u8) (0x80 | ((codepoint >> 12) & 0x3F)));
    array_add(out, cast(u8) (0x80 | ((codepoint >> 6) & 0x3F)));
    array_add(out, cast(u8) (0x80 | (codepoint & 0x3F)));
}

// odin 的 filepath.dir：去掉最后一个分量，没有分隔符时返回 "."。
test_dir :: (path: string) -> string {
    i := path.count;
    while i > 0 {
        c := path[i - 1];
        if c == #char "/" || c == #char "\\" {
            i -= 1;
            if i == 0 return test_substring(path, 0, 1);
            return test_substring(path, 0, i);
        }
        i -= 1;
    }
    return ".";
}

// odin 的 filepath.is_abs（Windows：盘符或前导分隔符）。
test_is_abs :: (path: string) -> bool {
    if path.count == 0 return false;
    if path[0] == #char "/" || path[0] == #char "\\" return true;
    return path.count >= 2 && path[1] == #char ":";
}

// odin 的 filepath.clean。
test_clean :: (path: string) -> string {
    if path.count == 0 return "";
    parsed := FU.parse_path(path);
    defer array_free(parsed.words);
    return copy_temporary_string(FU.path_to_string(parsed));
}

// 目录名（Jai 的包名就是目录名）。
test_base_name :: (path: string) -> string {
    trimmed := path;
    while trimmed.count > 0 {
        c := trimmed[trimmed.count - 1];
        if c != #char "/" && c != #char "\\" break;
        trimmed = test_substring(trimmed, 0, trimmed.count - 1);
    }
    i := trimmed.count;
    while i > 0 {
        c := trimmed[i - 1];
        if c == #char "/" || c == #char "\\" return test_substring(trimmed, i, trimmed.count);
        i -= 1;
    }
    return trimmed;
}

// odin 的 filepath.rel(base, target)：返回 (rel, ok)，ok 为 false 表示盘符/根不同。
test_rel :: (base: string, target: string) -> (string, bool) {
    base_path := FU.parse_path(base);
    defer array_free(base_path.words);
    target_path := FU.parse_path(target);
    defer array_free(target_path.words);
    if !STRING.equal_nocase(base_path.header_string, target_path.header_string) return "", false;
    common := 0;
    while common < base_path.words.count && common < target_path.words.count &&
          STRING.equal_nocase(base_path.words[common], target_path.words[common]) {
        common += 1;
    }
    builder: String_Builder;
    pieces := 0;
    up := base_path.words.count - common;
    for k: 0..up - 1 {
        if pieces > 0 append(*builder, "/");
        append(*builder, "..");
        pieces += 1;
    }
    for k: common..target_path.words.count - 1 {
        if pieces > 0 append(*builder, "/");
        append(*builder, target_path.words[k]);
        pieces += 1;
    }
    if pieces == 0 return ".", true;
    return copy_temporary_string(builder_to_string(*builder)), true;
}

// 反斜杠换成 `/`（odin 的 strings.replace_all(rel, "\\", "/")）。
test_to_slashes :: (path: string) -> string {
    result := copy_temporary_string(path);
    if result.count == 0 return result;
    for i: 0..result.count - 1 {
        if result.data[i] == #char "\\" result.data[i] = #char "/";
    }
    return result;
}

// odin 用「路径里含 `:`」判定 collection import；Jai 只有 ./ ../ 是文件相对路径。
test_is_relative_import :: (value: string) -> bool {
    if value.count >= 2 && value[0] == #char "." &&
       (value[1] == #char "/" || value[1] == #char "\\") return true;
    if value.count >= 3 && value[0] == #char "." && value[1] == #char "." &&
       (value[2] == #char "/" || value[2] == #char "\\") return true;
    return false;
}

// odin 的 os.read_all_directory_by_path：只读一层，条目归调用方（调用点用 temp）。
// 返回 (entries, ok)。
test_read_directory :: (path: string) -> ([] Test_Dir_Entry, bool) {
    entries: [..] Test_Dir_Entry;
    collect :: (info: *FU.File_Visit_Info, entries: *[..] Test_Dir_Entry) {
        array_add(entries, Test_Dir_Entry.{
            name = copy_temporary_string(info.short_name),
            full_path = copy_temporary_string(info.full_name),
            is_directory = info.is_directory,
            is_symlink = info.is_symlink,
        });
    }
    ok := FU.visit_files(path, false, *entries, collect, visit_directories = true);
    return entries, ok;
}

Test_Dir_Entry :: struct {
    name: string;
    full_path: string;
    is_directory: bool;
    is_symlink: bool;
}

// odin 的 os.make_directory_temp("", prefix)：在 %TEMP% 下建唯一目录。
// 返回 (path, ok)；path 是 temp。
test_temp_counter: int;

test_make_directory_temp :: (prefix: string) -> (string, bool) {
    base := ENV.environment_variable("TEMP");
    if base == "" base = ENV.environment_variable("TMP");
    if base == "" return "", false;
    for 0..999 {
        attempt := test_temp_counter;
        test_temp_counter += 1;
        candidate := tprint("%/%_%_%", base, prefix, SYS.read_cpu_counter(), attempt);
        exists, _ := FU.is_directory(candidate);
        if exists continue;
        if !FILE.make_directory_if_it_does_not_exist(candidate) continue;
        return candidate, true;
    }
    return "", false;
}

// jaic 一次只编译一个入口文件（odin 的 `test <dir>` 编译整个目录）。工作区是平面目录：
// 按字典序取第一个声明了 main 的 .jai（Jai 的测试入口就是带 main 的文件），都没有 main
// 时退回字典序第一个 .jai；没有 .jai 时返回 ""。见文件头。
test_entry_file :: (directory: string) -> string {
    push_allocator(temp);
    entries, ok := test_read_directory(directory);
    if !ok return "";
    names: [..] string;
    for entry: entries {
        if entry.is_directory || !STRING.ends_with(entry.name, ".jai") continue;
        array_add(*names, entry.name);
    }
    if names.count == 0 return "";
    SORT.quick_sort(names, (a: string, b: string) -> s32 {
        return cast(s32) STRING.compare_nocase(a, b);
    });
    for name: names {
        path := test_join(directory, name);
        content, read_ok := FILE.read_entire_file(path);
        if !read_ok continue;
        tokens, valid := test_tokens(content, path);
        if !valid continue;
        if test_declares_main(tokens) return path;
    }
    return test_join(directory, names[0]);
}

// 顶层（brace 深度 0）的 `main ::` / `main :` 声明。
test_declares_main :: (tokens: [] Token) -> bool {
    depth := 0;
    for token, i: tokens {
        if token.kind == .Open_Brace {
            depth += 1;
        }
        if token.kind == .Close_Brace {
            depth -= 1;
        }
        if depth != 0 continue;
        if token.kind != .Ident || token.text != "main" continue;
        if i + 1 < tokens.count && tokens[i + 1].kind == .Colon return true;
    }
    return false;
}
//@endregion
