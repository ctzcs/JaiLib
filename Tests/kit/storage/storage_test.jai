// kit/storage 回归测试 —— 一比一移植自 olib `tests/kit/storage/storage_test.odin`（153 行，
// 桌面 #+build !js 的 5 个用例）。
//
// 组织方式与 olib 对位：每个 @(test) 对应一个过程，断言顺序尽量保持原样；签名统一
// `(state: *Test_State)`（由 Tests/kit/run_kit_tests.jai 调度），用 Tests/test_support.jai
// 的 expect / test_summary。本文件不写 main。
//
// Jai 侧差异（断言语义不变）：
//   | olib (Odin)                                    | 这里 (Jai)                                              |
//   | ---------------------------------------------- | ------------------------------------------------------- |
//   | testing.expect / expect_value / expectf        | expect(state, cond, "说明 %", args)                      |
//   | os.make_directory_temp("", prefix, alloc)       | 固定目录 .test_tmp/storage_test/（已 gitignore），用例开头清空 |
//   | os.remove / remove_tree（递归）                  | storage_test_remove_tree（File_Utilities 遍历 + file_delete + rmdir）|
//   | foster.StorageContainer{Root, Writable}         | ST_F.Storage_Container（字段同名）                          |
//   | foster.WriteAllTextAtomic / WriteAllBytesAtomic | ST_F.storage_write_all_text / storage_write_all_bytes      |
//   |                                                 | （jfoster 没有原子写变体：见下面第 1 个用例的说明）        |
//   | foster.ReadAllText / ReadAllBytes               | ST_F.storage_read_all_text / storage_read_all_bytes        |
//   | foster.FileExists / EnumerateDirectory          | ST_F.storage_file_exists / ST_F.storage_enumerate             |
//   | foster.DirectoryStorageContainer(ds)            | ds 本身（jfoster 的容器就是 Storage_Container）           |
//   | ud: rawptr（传 &state）                          | ud: *void（同样传 &state；Jai 隐式转 *void）              |
//   | os.exists(full) / os.read_entire_file_from_path  | file_exists(full) / ST_FILE.read_entire_file(full)          |
//   | os.is_directory(path)                          | ST_FU.is_directory(path)                                    |
//   | strings.join({a, b}, "/", temp)                 | tprint("%/%", a, b)                                      |
//   | delete(s)                                       | free(s.data)                                             |
//
// 无法一比一移植的断言（jfoster 侧没有对应语义，已在用例内注明）：
//   - 原子写（WriteAllTextAtomic / WriteAllBytesAtomic）：jfoster 的 storage_write_all_*
//     是直接写，没有「同目录临时文件 + 替换」的实现；因此「失败后不留候选文件」
//     「Windows 打开句柄导致替换失败」「nil 容器」「ZIP 容器拒绝写」这 4 组断言不移植。
//   - WriteAllTextAtomic(nil, ...)：jfoster 的 storage_write_all_* 不做空指针检查（会崩），
//     没有可断言的返回值。
//   - 自动建父目录：olib 的 Foster 写文件时会建父目录，jfoster 不建；用例里显式建目录后
//     其余断言顺序不变。
#import "Basic";
// 具名导入一律带 ST_ 前缀：kit 的测试最终会被 run_kit_tests 具名/不具名导入到同一个模块，
// 裸的 F / M / W 之类会和 audio_test（F、M）、world_test（W）重名。
ST        :: #import "kit/storage";
ST_F      :: #import "jfoster";
ST_FILE   :: #import "File";
ST_FU     :: #import "File_Utilities";
#import "test_support";

//@region 夹具 helper（聚合进 run_kit_tests 后不会重名）

// olib 用 os.make_directory_temp 拿独占临时目录；这里用已 gitignore 的固定目录，
// 用例开头清空、结束再清，保证不碰真实工程目录。
storage_test_temp_root :: () -> string {
    ST_FILE.make_directory_if_it_does_not_exist(".test_tmp/storage_test", true);
    return ".test_tmp/storage_test";
}

storage_test_temp_dir :: (name: string) -> string {
    return tprint("%/%", storage_test_temp_root(), name);
}

// olib 的 @(private) TEST_APP：真实用户目录下的测试命名空间。
// 名字带 storage_test_ 前缀，聚合进 run_kit_tests 后不会与其它 kit 测试重名。
STORAGE_TEST_APP :: "jailib_storage_test_app";

// 目录删除（olib remove_tree 的对位）。透视遍历靠 File_Utilities，删除目录用系统调用：
// Basic / File / File_Utilities 都没有「删目录」，jfoster 的 folder_delete 走 SDL
// （本模块测试不引入 SDL 运行期依赖），所以这里补两个声明。
#if OS == .WINDOWS {
storage_test_kernel32 :: #library,system "kernel32";
storage_test_remove_directory_a :: (path: *u8) -> bool #foreign storage_test_kernel32 "RemoveDirectoryA";
} else {
storage_test_libc :: #library,system "c";
storage_test_rmdir :: (path: *u8) -> s32 #foreign storage_test_libc "rmdir";
}

storage_test_remove_directory :: (path: string) -> bool {
    #if OS == .WINDOWS {
        return storage_test_remove_directory_a(temp_c_string(path));
    } else {
        return storage_test_rmdir(temp_c_string(path)) == 0;
    }
}

Storage_Test_Tree :: struct {
    files: [..] string;
    dirs:  [..] string;
}

storage_test_collect :: (info: *ST_FU.File_Visit_Info, user_data: *Storage_Test_Tree) {
    if info.is_directory {
        array_add(*user_data.dirs, copy_string(info.full_name));
    } else {
        array_add(*user_data.files, copy_string(info.full_name));
    }
}

// 递归删除；路径不存在也算成功（olib 的 remove_tree 对 Not_Exist 返回 nil）。
storage_test_remove_tree :: (path: string) -> bool {
    if !ST_FU.is_directory(path) {
        if ST_FU.file_exists(path) return ST_FILE.file_delete(path);
        return true;
    }

    tree: Storage_Test_Tree;
    ok := ST_FU.visit_files(path, true, *tree, storage_test_collect, visit_directories = true);
    if !ok return false;

    all_ok := true;
    for tree.files {
        if !ST_FILE.file_delete(it) all_ok = false;
        free(it.data);
    }
    free(tree.files.data);

    // visit_files 是先序遍历：倒着删，子目录先于父目录。
    i := tree.dirs.count - 1;
    while i >= 0 {
        if !storage_test_remove_directory(tree.dirs[i]) all_ok = false;
        free(tree.dirs[i].data);
        i -= 1;
    }
    free(tree.dirs.data);

    if !storage_test_remove_directory(path) all_ok = false;
    return all_ok;
}

// 列出目录下的条目名（olib 用 foster.EnumerateDirectory；这里不用 SDL 的 GlobDirectory）。
storage_test_list :: (path: string) -> [..] string {
    names: [..] string;

    collect :: (info: *ST_FU.File_Visit_Info, user_data: *[..] string) {
        if info.is_directory return;
        array_add(user_data, copy_string(info.short_name));
    }

    ST_FU.visit_files(path, false, *names, collect);
    return names;
}

storage_test_free_names :: (names: [..] string) {
    for names free(it.data);
    free(names.data);
}
//@endregion

//@region 用例

// olib: atomic_storage_replace_and_failure_preserve_previous
//
// 改名说明：jfoster 没有 storage_write_all_*_atomic，本用例断言的是同一容器上的
// 「替换 + 输入校验 + 失败后旧内容保留」，原子性本身无从断言（见文件头的差异说明）。
storage_container_replace_and_failure_preserve_previous :: (state: *Test_State) {
    directory := storage_test_temp_dir("container");
    storage_test_remove_tree(directory);
    made := ST_FILE.make_directory_if_it_does_not_exist(directory, true);
    expect(state, made, "应能建临时目录: %", directory);
    if !made return;
    defer storage_test_remove_tree(directory);

    storage: ST_F.Storage_Container;
    storage.Root = directory;
    storage.Writable = true;

    path := "nested/state.json";
    // jfoster 写文件不建父目录（olib 的 Foster 会），先显式建；其余与 olib 同序。
    expect(state, ST_F.storage_create_directory(*storage, "nested"), "应能建 nested 目录");

    expect(state, ST_F.storage_write_all_text(*storage, path, "original"), "首次写入应成功");
    expect(state, ST_F.storage_write_all_text(*storage, path, "replacement"), "替换写入应成功");
    {
        text := ST_F.storage_read_all_text(*storage, path);
        expect(state, text == "replacement", "应读到替换后的内容: %", text);
        free(text.data);
    }

    // 空路径 / 只读容器都必须拒绝，不回退到目录写入。
    // （olib 还有 nil 容器与 ZIP 容器的断言：jfoster 的写接口没有空指针检查，
    //   Zip_Storage 是独立类型、没有可以“传进来的 ZipEntries 字段”，故不移植。）
    expect(state, !ST_F.storage_write_all_text(*storage, "", "bad"), "空路径应拒绝");
    readonly := storage;
    readonly.Writable = false;
    expect(state, !ST_F.storage_write_all_text(*readonly, path, "bad"), "只读容器应拒绝");
    expect(state, !ST_F.storage_write_all_text(*storage, "nested", "bad"), "目录当文件应拒绝");
    expect(state, !ST_F.storage_write_all_text(*storage, tprint("%/child", path), "bad"), "文件当目录应拒绝");
    {
        text := ST_F.storage_read_all_text(*storage, path);
        expect(state, text == "replacement", "失败后旧内容应保留: %", text);
        free(text.data);
    }

    // 失败后同目录不能留下多余条目。
    names := storage_test_list(tprint("%/nested", directory));
    expect(state, names.count == 1 && names[0] == "state.json", "nested 里应只有 state.json（实得 % 项）", names.count);
    storage_test_free_names(names);

    // 空文件允许写入（olib: WriteAllBytesAtomic(&storage, path, nil)）。
    empty: [0] u8;
    expect(state, ST_F.storage_write_all_bytes(*storage, path, empty), "空内容应允许写入");
    expect(state, ST_F.storage_file_exists(*storage, path), "空文件应存在");
    {
        data := ST_F.storage_read_all_bytes(*storage, path);
        expect(state, data.count == 0, "空文件应读回 0 字节（实得 %）", data.count);
        if data.data != null free(data.data);
    }

    // 二进制内容按字节原样往返。
    binary: [4] u8 = .[0, 255, 42, 0];
    expect(state, ST_F.storage_write_all_bytes(*storage, path, binary), "二进制写入应成功");
    {
        loaded := ST_F.storage_read_all_bytes(*storage, path);
        length_ok := loaded.count == binary.count;
        expect(state, length_ok, "读回长度应一致（实得 %）", loaded.count);
        if length_ok {
            for 0..binary.count - 1 {
                expect(state, loaded[it] == binary[it], "第 % 字节应一致", it);
            }
        }
        if loaded.data != null free(loaded.data);
    }
}

// olib: user_root_creates_platform_dir
user_root_creates_platform_dir :: (state: *Test_State) {
    root := ST.user_root(STORAGE_TEST_APP);
    // olib: expectf(t, root != "", "应得到用户根目录（APPDATA/HOME 应存在）")
    has_root := root != "";
    expect(state, has_root, "应得到用户根目录（APPDATA/HOME/XDG 应存在）");
    if !has_root return;
    defer ST.storage_free(root, context.allocator);
    defer storage_test_remove_tree(root);

    // olib: expectf(t, os.is_directory(root), "user_root 应已建目录: %s", root)
    expect(state, ST_FU.is_directory(root), "user_root 应已建目录: %", root);
    // 二次调用幂等
    again := ST.user_root(STORAGE_TEST_APP);
    expect(state, again == root, "二次调用应得到同一路径: % / %", again, root);
    ST.storage_free(again, context.allocator);
}

Storage_Test_Write_State :: struct {
    written: bool;
}

// olib: write_then_check（foster.WriteAllBytes(ds, "saves/save1.dat", []u8{1,2,3,4})）。
// jfoster 不自动建父目录，先建 saves 再写，其余一致。
storage_test_write_then_check :: (ds: *ST_F.Storage_Container, ud: *void) {
    state := cast(*Storage_Test_Write_State) ud;
    if !ST_F.storage_create_directory(ds, "saves") {
        state.written = false;
        return;
    }
    bytes: [4] u8 = .[1, 2, 3, 4];
    state.written = ST_F.storage_write_all_bytes(ds, "saves/save1.dat", bytes);
}

// olib: with_user_storage_roundtrip
with_user_storage_roundtrip :: (state: *Test_State) {
    root := ST.user_root(STORAGE_TEST_APP);
    has_root := root != "";
    expect(state, has_root, "无用户根目录");
    if !has_root return;
    defer ST.storage_free(root, context.allocator);
    saves_dir := tprint("%/saves", root);
    defer storage_test_remove_tree(saves_dir);
    // olib 只删 saves，把空的应用根留在用户目录里；这里连根一起删（跑完不留痕）。
    defer storage_test_remove_tree(root);

    // 写
    write_state: Storage_Test_Write_State;
    ok := ST.with_user_storage(STORAGE_TEST_APP, storage_test_write_then_check, *write_state);
    expect(state, ok && write_state.written, "with_user_storage 写入应成功: ok=% written=%", ok, write_state.written);

    // 读回（直接读文件系统，与 olib 相同）
    full := ST.user_file_path(STORAGE_TEST_APP, "saves/save1.dat");
    expect(state, ST_FU.file_exists(full), "文件应存在: %", full);
    {
        data, read_ok := ST_FILE.read_entire_file(full);
        content_ok := read_ok && data.count == 4 && data[0] == 1 && data[3] == 4;
        expect(state, content_ok, "读回内容应一致（% 字节）", data.count);
        if read_ok free(data.data);
    }
}

// olib: resources_roots_resolve
resources_roots_resolve :: (state: *Test_State) {
    dev := ST.resources_root_dev();
    expect(state, dev != "", "dev 根 = cwd 应非空");
    expect(state, ST_FU.is_directory(dev), "dev 根应是目录: %", dev);
    ST.storage_free(dev, context.allocator);

    rel := ST.resources_root_release();
    expect(state, rel != "", "release 根 = exe 目录应非空");
    expect(state, ST_FU.is_directory(rel), "release 根应是目录: %", rel);
    ST.storage_free(rel, context.allocator);
}

// olib: invalid_namespace_does_not_fall_back_to_working_directory
invalid_namespace_does_not_fall_back_to_working_directory :: (state: *Test_State) {
    invalid: [8] string = .["", ".", "..", "../outside", "a/b", "a\\b", "C:outside", "bad\nname"];
    for invalid {
        root := ST.user_root(it);
        expect(state, root == "", "invalid namespace: %", it);
        if root != "" ST.storage_free(root, context.allocator);
        user_file := ST.user_file_path(it, "save.json");
        expect(state, user_file == "", "invalid namespace 的 user_file_path 应为空: %", it);
    }
    expect(state, ST.valid_app_name("MyGame"), "MyGame 应是合法命名空间");
    expect(state, ST.valid_app_name("My Game_2"), "My Game_2 应是合法命名空间");
}
//@endregion
