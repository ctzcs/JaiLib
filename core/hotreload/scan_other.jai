// scan_other —— 非 Windows 扫描平台层（对位 olib core/hotreload/scan_other.odin）。
// 一比一移植自 olib core/hotreload/scan_other.odin。
//
// Linux/macOS 等的扫描平台层：列目录时用 jacket 的 File_Utilities.visit_files（一次遍历就带回
// 名字、类型、大小和修改时间，不读取文件内容）；POSIX 打开文件不会阻止其他进程写入、删除或改名。
//
// Jai 侧差异（本文件，行为不变）：
//   - odin 的 `#+build !windows` 文件切分在 Jai 里是文件级的 `#if OS != .WINDOWS {}`：
//     Windows 目标下整块跳过（不类型检查），scan_windows.jai 提供同一组过程；
//   - odin 的 os.read_all_directory_by_path 换成 File_Utilities.visit_files 的
//     visit_directories = true（一次遍历带回元数据，等价于 fstatat）；
//   - odin 的 os.stat_do_not_follow_links 同样走 visit_files：只查父目录里那一项，
//     is_symlink 即 Other，与 odin 的「不跟随链接」一致（不额外 stat 目标）；
//   - odin 的 time.time_to_unix_nano 换成 Apollo_Time → to_nanoseconds 再减
//     APOLLO_TIME_FOR_JAN_1_1970 的偏移（jacket 的时间原点不是 Unix 纪元）；
//   - odin 的 os.read_entire_file 换成 File.read_entire_file（返回 string，按字节视图算哈希）；
//   - odin 的 os.File_Info.name 只在调用方给的名字分配器上有效：这里同样 push_allocator；
//   - scan_other 侧没有线程优先级参数（odin 的 .Low 在 POSIX 上是 pthread 属性），
//     jacket 的 thread_init 也没有，所以 scan_thread_demote 在非 Windows 上是空实现（与 olib
//     不降优先级的实际效果一致）。
//
// 本文件的 Jai 侧补充平台辅助（与 scan_windows.jai 同名同语义）：scan_now_unix_nano、
// hotreload_create_exclusive_file、scan_thread_demote。
//
// 注：非 Windows 分支只保证与 olib 逐一对应、不参与本次验收（验收在 Windows 上跑）。
#if OS != .WINDOWS {
#import "Basic";
STRING :: #import "String";
FILE :: #import "File";
FU :: #import "File_Utilities";
POSIX :: #import "POSIX";

//@region 时间

// Apollo_Time → Unix 纳秒；odin 的 time.time_to_unix_nano。
scan_other_unix_nano :: (t: Apollo_Time) -> s64 {
    nanoseconds, ok := to_nanoseconds(t);
    if !ok return 0;
    // jacket 的时间原点不是 Unix 纪元，减去 1970-01-01 的偏移。
    epoch, epoch_ok := to_nanoseconds(APOLLO_TIME_FOR_JAN_1_1970);
    if !epoch_ok return 0;
    return nanoseconds - epoch;
}

// 墙钟的 Unix 纳秒（odin 版在 scan.odin 里用 time.time_to_unix_nano(time.now())）。
scan_now_unix_nano :: () -> s64 {
    return scan_other_unix_nano(current_time_consensus());
}
//@endregion

//@region 平台层

// visit_files 的收集状态：名字要落到调用方给的分配器上。
Scan_Other_Collect :: struct {
    entries: *[..] Scan_Entry;
    allocator: Allocator;
}

scan_other_collect :: (info: *FU.File_Visit_Info, collect: Scan_Other_Collect) {
    if info.had_error return;
    push_allocator(collect.allocator);
    name := copy_string(info.short_name);
    array_add(collect.entries, Scan_Entry.{
        name = name,
        kind = scan_other_kind(info),
        size = info.size,
        modified = scan_other_unix_nano(info.modification_time),
    });
}

scan_other_kind :: (info: *FU.File_Visit_Info) -> Scan_Kind {
    if info.is_symlink return Scan_Kind.Other; // 符号链接、挂载点等，不跟随
    if info.is_directory return Scan_Kind.Directory;
    return Scan_Kind.File;
}

// 列出目录项（不含 . 和 ..），名字分配在 allocator 上；目录不存在或无法读取时返回 false。
scan_list :: (dir: string, entries: *[..] Scan_Entry, allocator: Allocator) -> bool {
    collect := Scan_Other_Collect.{ entries = entries, allocator = allocator };
    return FU.visit_files(dir, false, collect, scan_other_collect,
                          visit_files = true, visit_directories = true,
                          visit_symlinks = true, follow_directory_symlinks = false);
}

// 查一项元数据的状态：按「父目录里叫这个名字的那一项」找，不跟随符号链接。
Scan_Other_Stat :: struct {
    name: string;
    found: bool;
    entry: Scan_Entry;
}

scan_other_stat_find :: (info: *FU.File_Visit_Info, stat: *Scan_Other_Stat) {
    if stat.found || info.had_error || info.short_name != stat.name return;
    stat.entry = Scan_Entry.{
        name = "", // odin 的 stat_do_not_follow_links 返回的 name 为空
        kind = scan_other_kind(info),
        size = info.size,
        modified = scan_other_unix_nano(info.modification_time),
    };
    stat.found = true;
}

// 查询单个路径的元数据，不跟随符号链接；返回的 name 为空。
scan_stat :: (path: string) -> (Scan_Entry, bool) {
    parent := STRING.path_strip_filename(path);
    if parent.count == 0 parent = ".";
    stat := Scan_Other_Stat.{ name = STRING.path_filename(path) };
    _ = FU.visit_files(parent, false, *stat, scan_other_stat_find,
                       visit_files = true, visit_directories = true,
                       visit_symlinks = true, follow_directory_symlinks = false);
    if !stat.found return Scan_Entry.{}, false;
    return stat.entry, true;
}

// 读取整个文件计算内容哈希（长度参与）。
scan_hash_file :: (path: string) -> (u64, bool) {
    mark := get_temporary_storage_mark();
    defer set_temporary_storage_mark(mark);
    data, ok := FILE.read_entire_file(path);
    if !ok return 0, false;
    defer free(data);
    // Jai 的 string 与 [] u8 是不同类型：按字节视图算哈希，不复制。
    return (fnv_bytes(FNV_OFFSET, cast([] u8) data) ^ cast(u64) data.count) * FNV_PRIME, true;
}

// odin 的 os.create_temp_file(dir, ".olib-reload-*.dll")：在 dir 里独占创建一个新文件。
// 名字由调用方生成（见 session.jai 的重试循环），这里只回答「是否成功独占创建了这个路径」。
hotreload_create_exclusive_file :: (path: string) -> bool {
    mark := get_temporary_storage_mark();
    defer set_temporary_storage_mark(mark);
    name := to_c_string(path);
    defer free(name);
    // O_CREAT | O_EXCL：已存在就失败，语义同 odin 的独占创建。
    fd := POSIX.open(name, POSIX.O_CREAT | POSIX.O_EXCL | POSIX.O_WRONLY, cast(s32) 0x180);
    if fd < 0 return false;
    _ = POSIX.close(fd);
    return true;
}

// 扫描线程降优先级：odin 在 thread.create 里给 .Low；jacket 的 thread_init 没有优先级参数，
// POSIX 侧无法只改一个线程的 nice，所以这里保持与 olib 的实际效果一致（不降优先级）。
scan_thread_demote :: () {
}
//@endregion
}
