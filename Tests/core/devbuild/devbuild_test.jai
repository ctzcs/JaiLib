// 一比一移植自 olib tests/core/devbuild/test_workspace_test.odin。
// core:testing.expect / expectf 换成 test_support.expect（它自带格式化参数）；
// 断言顺序、拆分方式与 olib 一一对应。
//
// Jai 侧差异（逐条对应 olib 的写法）：
//   - odin 的 `#+test package devbuild` 直接测包内私有过程；Jai 没有 #+test/package，
//     这里通过 `#import "core/devbuild"` 只用公开过程（olib 的测试也只用了公开 API，
//     外加 #directory）；
//   - `#directory` → jacket 的 `#filepath`（当前文件所在目录，带结尾分隔符，绝对路径）；
//   - **资源指令**：`#load("data.bin")` / `#load_directory(...)` / `#exists("path")`
//     在 jacket 里没有等价物（core/devbuild 文件头已注明），所以自举夹具换成
//     「相对 #import 必须被重写」来端到端验证路径重写：工作区是平面副本，改写没生效时
//     `#import "../shared"` 会指到工作区之外（编译失败）；改写生效后按 collection
//     相对路径 + `-import_dir` 找到包（编译并运行成功）。字符串级的资源指令重写仍由
//     resource_paths_and_imports_keep_production_baseline 完整覆盖；
//   - `#load "source.jai";`（Jai 的源码聚合，odin 没有同目录自动合并）代替 olib 的
//     「同目录多文件即同包」；
//   - `@(private)`：Jai 没有包内私有声明，跨文件可见性由 #load 聚合保证，断言改为
//     「被 #load 的源里的符号在夹具里可用」；
//   - odin 的 `os.make_directory_temp` / `os.remove` / `os.write_entire_file` /
//     `os.read_entire_file` / `os.exists` 换成 File / File_Utilities 的等价过程（见
//     文件末尾的 devbuild_test_* 辅助过程）；
//   - odin 的 `odin test <dir> -vet -out:x` 换成 `jaic <入口> -interp -import_dir root`
//     （jaic 一次只编译一个入口文件，也没有 test 子命令；-interp 解释执行 main，
//     等价于「编译+运行」）。
#import "Basic";
#import "test_support";
STRING :: #import "String";
FILE :: #import "File";
FU :: #import "File_Utilities";
ENV :: #import "Extensions/Environment";
SYS :: #import "System";
DB :: #import "core/devbuild";

//@region token 与路径

source_declarations_ignore_comments_and_literals :: (state: *Test_State) {
    name, tests, ok := DB.test_source_info("// @(test) package wrong\npackage sample\nx :: `@(test)`\n", "fixture.odin");
    expect(state, ok && name == "sample" && !tests, "注释与字面量里的 @(test)/package 不算声明");
    _, tests2, ok2 := DB.test_source_info("package sample\n@(test)\nx :: proc() {}\n", "fixture.odin");
    expect(state, ok2 && tests2, "真正的 @(test) 属性被识别");
}

resource_paths_and_imports_keep_production_baseline :: (state: *Test_State) {
    // olib: root, _ := filepath.abs(#directory + "/../../..")
    // Jai : #filepath 是 Tests/core/devbuild/，上三级是仓库根。
    root := devbuild_test_clean(tprint("%/../../..", #filepath));
    path := devbuild_test_join_root(root, "core/devbuild/fixture.jai");
    // Jai 没有字符串 +：整段写成一个字面量（与 olib 的逐行拼接内容完全相同）。
    source := "package sample\n// #directory #load(\"fake\")\ntext :: `#directory #load(\"fake\")`\nBASE :: #directory + `/data`\nFILE :: BASE + \"/a\\u002ebin\"\nroot :: #directory\na :: #load(FILE)\nb := #load_directory(BASE)\nc :: #exists((BASE + `/missing`))\n#import \"../shared\"\nimport local \"../shared\"\nimport \"core:fmt\"\n";
    collections: [..] DB.Test_Collection;
    array_add(*collections, DB.Test_Collection.{ name = "olib", root = root });
    result, err := DB.test_source_paths(source, path, collections);
    defer devbuild_test_free(err);
    defer devbuild_test_free(result);
    expect(state, err == "", "重写不能失败: %", err);
    if err != "" return;
    expect(state, STRING.contains(result, "// #directory #load(\"fake\")"), "注释原样保留");
    expect(state, STRING.contains(result, "text :: `#directory #load(\"fake\")`"), "字面量原样保留");
    expect(state, !STRING.contains(result, "a :: #load(FILE)"), "#load(常量) 被替换");
    expect(state, !STRING.contains(result, "b := #load_directory(BASE)"), "#load_directory(常量) 被替换");
    expect(state, STRING.contains(result, "#import \"core/shared\""), "Jai 相对 import 映射到 collection");
    expect(state, STRING.contains(result, "import local \"core/shared\""), "odin 命名 import 也映射");
    expect(state, STRING.contains(result, "import \"core:fmt\""), "非相对 import 原样保留");
    expect(state, STRING.contains(result, "a.bin"), "转义解码后拼接成资源路径");
    expect(state, !STRING.contains(result, "devbuild/core/devbuild"), "路径没有重复拼接");
}

unknown_paths_and_unmapped_imports_are_rejected :: (state: *Test_State) {
    sources: [7] string = .[
        "package sample\nx :: #load(unknown)\n",
        "package sample\nx :: #exists(path())\n",
        "package sample\nA :: B\nB :: A\nx :: #load(A)\n",
        "package sample\nf :: proc() { P :: `wrong` }\nx :: #load(P)\n",
        "package sample\nP :: `global`\nf :: proc() { P :: `local`; x := #load(P) }\n",
        "package sample\nimport \"../outside\"\n",
        "package sample\nx :: \"unterminated",
    ];
    none: [..] DB.Test_Collection; // odin 的 nil 切片
    for source: sources {
        result, err := DB.test_source_paths(source, devbuild_test_join_root(#filepath, "fixture.jai"), none);
        defer devbuild_test_free(result);
        defer devbuild_test_free(err);
        expect(state, err != "", "必须拒绝 %", source);
    }
}
//@endregion

//@region 自举与失败清理

workspace_is_exclusive_private_and_never_writes_back :: (state: *Test_State) {
    root, created := devbuild_test_make_temp_dir("olib_workspace_test_");
    expect(state, created, "建立临时根目录");
    if !created return;
    defer FU.delete_directory_tree(root);

    production := devbuild_test_join(root, "Source With Spaces");
    tests := devbuild_test_join(root, "tests");
    shared := devbuild_test_join(root, "shared");
    assert(FILE.make_directory_if_it_does_not_exist(production));
    assert(FILE.make_directory_if_it_does_not_exist(tests));
    assert(FILE.make_directory_if_it_does_not_exist(shared));

    // olib 的夹具：source.odin（@(private) secret + #load/#exists 资源）+ unit.odin。
    // Jai 版：source.jai（secret）+ shared 包（相对 import 的落点）+ unit.jai（带 main）。
    original := "secret :: () -> int { return 42; }\n";
    source_path := devbuild_test_join_root(production, "source.jai");
    unit_path := devbuild_test_join_root(tests, "unit.jai");
    module_path := devbuild_test_join_root(shared, "module.jai");
    util_path := devbuild_test_join_root(shared, "util.jai");
    // 一次 #load 聚合 + 一次相对 #import（改写后落到 collection 相对路径）+ main。
    unit := "#import \"Basic\";\n#import \"../shared\";\n#load \"source.jai\";\nmain :: () {\n    assert(secret() == 42 && util_value() == 7);\n}\n";
    assert(FILE.write_entire_file(source_path, original));
    assert(FILE.write_entire_file(module_path, "#load \"util.jai\";\n"));
    assert(FILE.write_entire_file(util_path, "util_value :: () -> int { return 7; }\n"));
    assert(FILE.write_entire_file(unit_path, unit));

    collections: [..] DB.Test_Collection;
    array_add(*collections, DB.Test_Collection.{ name = "fixture", root = root });
    workspace, prepare_error := DB.test_workspace_prepare(production, tests, collections);
    defer devbuild_test_free(prepare_error);
    expect(state, prepare_error == "", "prepare 成功: %", prepare_error);
    if prepare_error != "" return;
    copy_path := copy_string(workspace.directory);
    defer devbuild_test_free(copy_path);

    // 独占：第二次 prepare 拿到另一个目录。
    other, other_error := DB.test_workspace_prepare(production, tests, collections);
    defer devbuild_test_free(other_error);
    expect(state, other_error == "" && other.directory != workspace.directory, "独占：两次 prepare 目录不同");
    expect(state, DB.test_workspace_dispose(*other), "dispose 第二个工作区");

    // 编译并运行：改写后的相对 import + #load 聚合都要成立。
    arguments: [..] string;
    array_add(*arguments, "-interp");
    array_add(*arguments, "-import_dir");
    array_add(*arguments, root);
    ok, diagnostic := DB.test_workspace_run(*workspace, root, arguments);
    defer devbuild_test_free(diagnostic);
    expect(state, ok, "工作区编译并运行: %", diagnostic);

    // 失败路径：编译器报错时 ok 为 false 且诊断非空，工作区不被破坏。
    failed_arguments: [..] string;
    array_add(*failed_arguments, "-definitely-invalid-flag");
    failed, failed_diagnostic := DB.test_workspace_run(*workspace, root, failed_arguments);
    defer devbuild_test_free(failed_diagnostic);
    expect(state, !failed && failed_diagnostic != "", "失败路径：坏参数 → ok=false 且有诊断");

    expect(state, DB.test_workspace_dispose(*workspace), "dispose 工作区");
    exists, _ := FU.is_directory(copy_path);
    expect(state, !exists, "工作区目录已删除");

    before, read_ok := FILE.read_entire_file(source_path);
    defer devbuild_test_free(before);
    expect(state, read_ok && before == original, "生产文件没有被回写");

    // 同名冲突与后续失败不留下可用的工作区。
    collision := devbuild_test_join_root(tests, "source.jai");
    assert(FILE.write_entire_file(collision, "// collision\n"));
    defer FILE.file_delete(collision);
    none: [..] DB.Test_Collection; // odin 的 nil 切片
    bad, bad_error := DB.test_workspace_prepare(production, tests, none);
    defer devbuild_test_free(bad_error);
    expect(state, bad_error != "" && bad.directory == "", "同名冲突被拒绝且不留工作区");
}
//@endregion

//@region 发现错误

broken_test_source_is_reported_in_discovery :: (state: *Test_State) {
    root, created := devbuild_test_make_temp_dir("olib_discover_test_");
    expect(state, created, "建立临时根目录（发现）");
    if !created return;
    defer FU.delete_directory_tree(root);
    path := devbuild_test_join_root(root, "broken_test.jai");
    assert(FILE.write_entire_file(path, "#+test\npackage broken\n@(test)\nx :: \"unterminated"));
    defer FILE.file_delete(path);
    dirs: [..] string;
    array_add(*dirs, ".");
    packages := DB.test_discover(root, dirs);
    defer DB.test_packages_dispose(packages);
    expect(state, packages.count == 1, "发现一个包");
    if packages.count == 1 {
        expect(state, packages[0].diagnostic != "", "坏 token 必须作为诊断报告，不能静默跳过");
    }
}
//@endregion

//@region 辅助（替代 odin 的 os / filepath / fmt 调用）

// 释放模块返回的字符串。
devbuild_test_free :: (value: string) {
    if value.data == null || value.count == 0 return;
    free(value.data);
}

// odin 的 filepath.clean。
devbuild_test_clean :: (path: string) -> string {
    parsed := FU.parse_path(path);
    defer array_free(parsed.words);
    return copy_string(FU.path_to_string(parsed));
}

// odin 的 filepath.join(一条路径, relative)，绝对路径直接 clean。
devbuild_test_join_root :: (base: string, relative: string) -> string {
    return devbuild_test_clean(tprint("%/%", base, relative));
}

// odin 的 filepath.join(a, b)。（保留两个入口只是为了读起来和 olib 一样。）
devbuild_test_join :: (base: string, relative: string) -> string {
    return devbuild_test_join_root(base, relative);
}

// odin 的 os.make_directory_temp("", prefix)：%TEMP% 下的唯一目录。
devbuild_test_temp_counter: int;

devbuild_test_make_temp_dir :: (prefix: string) -> (string, bool) {
    base := ENV.environment_variable("TEMP");
    if base == "" base = ENV.environment_variable("TMP");
    if base == "" return "", false;
    for 0..999 {
        attempt := devbuild_test_temp_counter;
        devbuild_test_temp_counter += 1;
        candidate := devbuild_test_clean(tprint("%/%_%_%", base, prefix, SYS.read_cpu_counter(), attempt));
        exists, _ := FU.is_directory(candidate);
        if exists continue;
        if !FILE.make_directory_if_it_does_not_exist(candidate) continue;
        return copy_string(candidate), true;
    }
    return "", false;
}
//@endregion
