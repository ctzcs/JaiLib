// scan_windows —— Windows 扫描平台层（对位 olib core/hotreload/scan_windows.odin）。
// 一比一移植自 olib core/hotreload/scan_windows.odin。
//
// Windows 扫描平台层：FindFirstFileW 随目录项返回大小和修改时间，不逐个打开文件；
// jacket 的 core 目录遍历（File_Utilities.visit_files）会给每一项再取一次属性，
// 打开时又不带 FILE_SHARE_DELETE，所以这里直接用 Win32。
//
// Jai 侧差异（本文件，行为不变）：
//   - odin 的 `#+build windows` 文件切分在 Jai 里是文件级的 `#if OS == .WINDOWS {}`：
//     非 Windows 目标下整块跳过（不类型检查），scan_other.jai 提供同一组过程；
//   - odin 用 core:sys/windows 的现成声明；Jai 侧在文件里用 `#foreign kernel32` 自备
//     最小声明集（WIN32_FIND_DATAW / WIN32_FILE_ATTRIBUTE_DATA / FILETIME 等），
//     避免依赖 jacket Windows 模块的命名；
//   - odin 的 `utf8_to_wstring_alloc` / `wstring_to_utf8_alloc` 换成 jacket 的
//     Windows_Utf8（utf8_to_wide_new 走 context.allocator，所以 scan_list 先
//     push_allocator(allocator)，名字就落在调用方给的分配器上，语义同 odin）；
//   - odin 的 `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` 在 Jai 里用
//     get_temporary_storage_mark / set_temporary_storage_mark 显式配对；
//   - odin 的 `s64(high) << 32 | s64(low)` 在 Jai 里要显式逐段 cast；
//   - FILETIME_as_unix_nanoseconds 是 odin core:sys/windows 的辅助过程，Jai 侧在这里
//     自己实现（100ns 刻度减去 1601→1970 的偏移，再乘 100 得纳秒，与 odin 完全一致）。
//
// 另外两个 Jai 侧新增的平台辅助（odin 用标准库直接做的事）：scan_now_unix_nano、
// hotreload_create_exclusive_file。
#if OS == .WINDOWS {
    #import "Basic";
    WU :: #import "Windows_Utf8";

    //@region Win32 最小声明集

    // odin 的 `#foreign kernel32` 在 Jai 里要先声明库；`#library,system` = 链接系统的 kernel32。
    kernel32 :: #library,system "kernel32";

    FILETIME :: struct {
        dwLowDateTime: u32;
        dwHighDateTime: u32;
    }

    WIN32_FIND_DATAW :: struct {
        dwFileAttributes: u32;
        ftCreationTime: FILETIME;
        ftLastAccessTime: FILETIME;
        ftLastWriteTime: FILETIME;
        nFileSizeHigh: u32;
        nFileSizeLow: u32;
        dwReserved0: u32;
        dwReserved1: u32;
        cFileName: [260] u16;
        cAlternateFileName: [14] u16;
    }

    WIN32_FILE_ATTRIBUTE_DATA :: struct {
        dwFileAttributes: u32;
        ftCreationTime: FILETIME;
        ftLastAccessTime: FILETIME;
        ftLastWriteTime: FILETIME;
        nFileSizeHigh: u32;
        nFileSizeLow: u32;
    }

    INVALID_HANDLE_VALUE :: cast(*void) cast(s64) -1;

    // Win32 常量必须显式声明类型：Jai 的无类型整数字面量是 s64，直接当 u32 参数传会报类型不符。
    FILE_ATTRIBUTE_DIRECTORY: u32 : 0x10;
    FILE_ATTRIBUTE_REPARSE_POINT: u32 : 0x400;
    FILE_ATTRIBUTE_NORMAL: u32 : 0x80;
    FILE_SHARE_READ: u32 : 0x1;
    FILE_SHARE_WRITE: u32 : 0x2;
    FILE_SHARE_DELETE: u32 : 0x4;
    GENERIC_READ: u32 : 0x80000000;
    GENERIC_WRITE: u32 : 0x40000000;
    OPEN_EXISTING: u32 : 3;
    CREATE_NEW: u32 : 1;
    FILE_FLAG_SEQUENTIAL_SCAN: u32 : 0x08000000;
    GET_FILE_EX_INFO_STANDARD: u32 : 0;
    ERROR_NO_MORE_FILES: u32 : 18;
    THREAD_PRIORITY_LOWEST: s32 : -2;

    find_first_file_w :: (file_name: *u16, data: *WIN32_FIND_DATAW) -> *void #foreign kernel32 "FindFirstFileW";
    find_next_file_w :: (handle: *void, data: *WIN32_FIND_DATAW) -> s32 #foreign kernel32 "FindNextFileW";
    find_close :: (handle: *void) -> s32 #foreign kernel32 "FindClose";
    get_file_attributes_ex_w :: (file_name: *u16, level: u32, data: *WIN32_FILE_ATTRIBUTE_DATA) -> s32 #foreign kernel32 "GetFileAttributesExW";
    create_file_w :: (file_name: *u16, access: u32, share: u32, security: *void, creation: u32, flags: u32, template: *void) -> *void #foreign kernel32 "CreateFileW";
    read_file :: (handle: *void, buffer: *void, to_read: u32, did_read: *u32, overlapped: *void) -> s32 #foreign kernel32 "ReadFile";
    close_handle :: (handle: *void) -> s32 #foreign kernel32 "CloseHandle";
    get_last_error :: () -> u32 #foreign kernel32 "GetLastError";
    get_system_time_precise_as_file_time :: (ft: *FILETIME) #foreign kernel32 "GetSystemTimePreciseAsFileTime";
    set_thread_priority :: (handle: *void, priority: s32) -> s32 #foreign kernel32 "SetThreadPriority";
    get_current_thread :: () -> *void #foreign kernel32 "GetCurrentThread";
    //@endregion

    //@region 时间

    // odin core:sys/windows 的 FILETIME_as_unix_nanoseconds：100ns 刻度（1601 起）→ Unix 纳秒。
    scan_filetime_as_unix_nanoseconds :: (ft: FILETIME) -> s64 {
        ticks := (cast(u64) ft.dwHighDateTime) << 32 | cast(u64) ft.dwLowDateTime;
        return cast(s64) (ticks - 116444736000000000) * 100;
    }

    // 墙钟的 Unix 纳秒。odin 版在 scan.odin 里用 time.time_to_unix_nano(time.now())，
    // Jai 侧把「墙钟」也放到平台层，保证与 mtime 是同一把尺子（都来自 FILETIME）。
    scan_now_unix_nano :: () -> s64 {
        ft: FILETIME;
        get_system_time_precise_as_file_time(*ft);
        return scan_filetime_as_unix_nanoseconds(ft);
    }
    //@endregion

    //@region 平台层

    // 列出目录项（不含 . 和 ..），名字分配在 allocator 上；目录不存在或读取中断时返回 false。
    scan_list :: (dir: string, entries: *[..] Scan_Entry, allocator: Allocator) -> bool {
        push_allocator(allocator);
        // odin: strings.concatenate({dir, `\*`})；Jai 侧同样拼上反斜杠通配符。
        pattern := tprint("%\\*", dir);
        wide := WU.utf8_to_wide_new(pattern);
        if !wide return false;
        data: WIN32_FIND_DATAW;
        handle := find_first_file_w(wide, *data);
        if handle == INVALID_HANDLE_VALUE return false;
        defer find_close(handle);
        while true {
            name, converted := WU.wide_to_utf8(*data.cFileName[0]);
            if !converted return false;
            // 转换失败（非法 UTF-16 名字）时得到空串，跳过。
            if name != "" && name != "." && name != ".." {
                array_add(entries, scan_entry(name, data.dwFileAttributes, data.ftLastWriteTime,
                                             data.nFileSizeHigh, data.nFileSizeLow));
            }
            if !find_next_file_w(handle, *data) break;
        }
        return get_last_error() == ERROR_NO_MORE_FILES;
    }

    // 查询单个路径的元数据；GetFileAttributesExW 返回链接自身的属性，不跟随符号链接。
    scan_stat :: (path: string) -> (Scan_Entry, bool) {
        mark := get_temporary_storage_mark();
        defer set_temporary_storage_mark(mark);
        data: WIN32_FILE_ATTRIBUTE_DATA;
        wide := WU.utf8_to_wide_new(path);
        if !wide return Scan_Entry.{}, false;
        if !get_file_attributes_ex_w(wide, GET_FILE_EX_INFO_STANDARD, *data) return Scan_Entry.{}, false;
        entry := scan_entry("", data.dwFileAttributes, data.ftLastWriteTime, data.nFileSizeHigh,
                            data.nFileSizeLow);
        return entry, true;
    }

    // 分块读取并计算内容哈希（长度参与）。共享读写、删除和改名，扫描不会让编辑器保存或原子替换失败。
    scan_hash_file :: (path: string) -> (u64, bool) {
        mark := get_temporary_storage_mark();
        defer set_temporary_storage_mark(mark);
        wide := WU.utf8_to_wide_new(path);
        if !wide return 0, false;
        share := FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        handle := create_file_w(wide, GENERIC_READ, share, null, OPEN_EXISTING,
                                FILE_FLAG_SEQUENTIAL_SCAN, null);
        if handle == INVALID_HANDLE_VALUE return 0, false;
        defer close_handle(handle);
        buffer: [32 * 1024] u8;
        hash := FNV_OFFSET;
        total: u64;
        while true {
            read: u32;
            if !read_file(handle, *buffer, cast(u32) buffer.count, *read, null) return 0, false;
            if read == 0 break;
            // Jai 没有 odin 的 buffer[:read] 切片语法：固定数组先隐式转成切片，再把长度缩到实读数。
            chunk: [] u8 = buffer;
            chunk.count = cast(int) read;
            hash = fnv_bytes(hash, chunk);
            total += cast(u64) read;
        }
        return (hash ^ total) * FNV_PRIME, true;
    }

    scan_entry :: (name: string, attributes: u32, modified: FILETIME, high, low: u32) -> Scan_Entry {
        kind := Scan_Kind.File;
        if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            kind = Scan_Kind.Other;
        } else if attributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
            kind = Scan_Kind.Directory;
        }
        return Scan_Entry.{
            name = name,
            kind = kind,
            size = (cast(s64) high) << 32 | cast(s64) low,
            modified = scan_filetime_as_unix_nanoseconds(modified),
        };
    }

    // odin 的 os.create_temp_file(dir, ".olib-reload-*.dll")：在 dir 里独占创建一个新文件。
    // 返回 (路径, ok)；路径用调用方的 allocator？—— 不，路径借用传入的 candidate 缓冲区写法不同，
    // 这里只回答「是否成功独占创建了这个路径」，名字由调用方生成（见 session.jai 的重试循环）。
    hotreload_create_exclusive_file :: (path: string) -> bool {
        mark := get_temporary_storage_mark();
        defer set_temporary_storage_mark(mark);
        wide := WU.utf8_to_wide_new(path);
        if !wide return false;
        share := FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        handle := create_file_w(wide, GENERIC_READ | GENERIC_WRITE, share, null, CREATE_NEW,
                                FILE_ATTRIBUTE_NORMAL, null);
        if handle == INVALID_HANDLE_VALUE return false;
        close_handle(handle);
        return true;
    }

    // 扫描线程降优先级（odin: thread.create(scan_worker, .Low)）；在 worker 内部设置，
    // 因为 jacket 的 thread_init 没有优先级参数。
    scan_thread_demote :: () {
        set_thread_priority(get_current_thread(), THREAD_PRIORITY_LOWEST);
    }
    //@endregion
}
