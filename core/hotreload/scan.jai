// scan —— 扫描表 + 后台扫描线程 + 完整扫描 + 热文件。扫描线程只读文件系统，主线程只读结果。
// 一比一移植自 olib core/hotreload/scan.odin。
//
// 平台层（scan_windows.jai / scan_other.jai）提供 scan_list、scan_stat、scan_hash_file，
// 以及 Jai 侧补充的 scan_now_unix_nano、hotreload_create_exclusive_file、scan_thread_demote。
//
// Jai 侧差异（本文件，行为不变）：
//   - 扫描表布局：odin 的 `#soa[dynamic]Scan_File` 在 Jai 里是普通动态数组 `[..] Scan_File`。
//     列布局只是内存排布，行语义（index 持路径、交换删除改行号、行号只在本次扫描内有效）
//     完全一致；指纹改成逐行读两个字段，结果与 odin 的按列读取相同；
//   - `map[string]int` 换成 jacket 的 Hash_Table.Table(string, int)：查找/插入/删除一一对应
//     （table_find / table_add / table_set / table_remove / deinit）；
//   - odin 的 sync.Mutex / sync.Sema 零值即可用；jacket 的 Thread.Mutex / Semaphore 必须
//     init，所以 scan_init 里建立它们，scan_destroy 里销毁（odin 版 scan_init 只存参数）；
//     sema_post → signal，sema_wait_with_timeout → wait_for(毫秒)；
//   - odin 的 thread.create/start/join/destroy 换成 jacket 的
//     New(Thread) + thread_init/thread_start/thread_is_done(thread, -1)/thread_deinit；
//     odin 创建时就给 .Low 优先级，jacket 的 thread_init 没有优先级参数，改为 worker
//     一开始调用 scan_thread_demote()（同样是 THREAD_PRIORITY_LOWEST）；
//   - `intrinsics.atomic_*` → jacket Atomics 的 atomic_read/atomic_write/atomic_add
//     （atomic_add 同样返回旧值，所以 +1 得到票号）；
//   - time.tick_now/tick_diff/tick_add 的单调时钟换成
//     to_nanoseconds(current_time_monotonic())；`time.Duration` 在这个模块里统一用 s64 纳秒；
//   - 墙钟（odin 的 time.time_to_unix_nano(time.now())）改用平台层的 scan_now_unix_nano，
//     与 mtime 出自同一把 FILETIME 尺子；
//   - `runtime.heap_allocator()` → context.default_allocator；
//     `free_all(context.temp_allocator)` → reset_temporary_storage()；
//     `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` → get_temporary_storage_mark/set_..._mark；
//   - odin 的具名返回值（如 scan_hot 的 refreshed）在 Jai 里写成局部变量 + return；
//   - Jai 没有 `for i := n-1; i >= 0; i -= 1` 也没有倒序范围（`3..0` 是空范围），写成 while；
//   - 指针后面的数组下标要显式解引用（`ptr.*[i]`）：对 `*[..] T` 用 `ptr[i]` 是指针算术；
//   - odin 的 `unordered_remove_soa` 在 Jai 里手写「末行搬到空位 + 缩短长度」；
//   - odin 的异或运算符 `~` 在 Jai 里是 `^`（`~` 只剩按位取反），指纹与 fnv_bytes 逐处改写。
#import "Basic";
HASH :: #import "Hash_Table";
THREAD :: #import "Thread";
ATOMICS :: #import "Atomics";
STRING :: #import "String";

//@region 扫描表

FNV_OFFSET: u64 : 1469598103934665603;
FNV_PRIME: u64 : 1099511628211;
// 指纹里用的混合常量（超过 s64 范围，必须显式声明成 u64）。
SCAN_CONTENT_SALT: u64 : 0x9e3779b97f4a7c15;
SCAN_MIX_1: u64 : 0xbf58476d1ce4e5b9;
SCAN_MIX_2: u64 : 0x94d049bb133111eb;

// 读取内容时，修改时间离读取时刻不足此余量的文件可能在同一时间戳内再次改写，下次扫描仍按内容复核。
// 覆盖 FAT 的 2 秒、HFS+ 的 1 秒精度和网络盘的元数据缓存；NTFS/ext4/APFS 只是多读几次刚改过的文件。
SCAN_RACY_NS: s64 : 3 * 1000 * 1000 * 1000;

// 内容变化后这段时间内算热文件：完整扫描间隔被拉长时，每次唤醒仍单独检查，最多 SCAN_HOT_LIMIT 个。
SCAN_HOT_NS: s64 : 30 * 1000 * 1000 * 1000;
SCAN_HOT_LIMIT :: 64;

// 完整扫描的间隔至少是其耗时的这个倍数：文件很多时后台最多占约十分之一个核心，检测延迟随之变长。
SCAN_COST_FACTOR :: 10;

Scan_Kind :: enum u8 {
    Other; // 符号链接、挂载点等，不跟随
    File;
    Directory;
}

// 平台层返回的一项元数据；name 只在调用方给的分配器上有效。
Scan_Entry :: struct {
    name: string;
    kind: Scan_Kind;
    size: s64;
    modified: s64; // 字节数；修改时间，Unix 纳秒
}

// 扫描表的一行，紧凑布局：0..<len 是最近一次完整扫描见到的文件。path 由扫描器持有并作为 index 的键；
// 交换删除会改变行号，行号只在当前扫描内使用。
Scan_File :: struct {
    path: string;
    path_hash: u64;
    content: u64;
    size: s64;
    modified: s64;
    checked: s64; // 最近一次读取内容的扫描开始时刻（Unix 纳秒），判断时间戳是否过近
    hot_until: s64; // 内容最近变化：此前每次唤醒都单独检查
    sweep: u32; // 最近一次见到它的完整扫描编号
}
//@endregion

//@region 扫描线程

// 主线程读取的结果，由 Scanner.lock 保护。
Scan_Result :: struct {
    fingerprint: u64;
    readable: bool;
    sweeps: u64; // 已完成的完整扫描次数；0 表示还没有结果
    served: u64; // 已满足的完整扫描请求号
}

// 内嵌在 Watch 中，地址稳定。主线程只调用 scan_result / scan_request；其余字段只由扫描线程读写
// （Manual 模式没有线程，由调用线程同步扫描），线程停止后由 scan_destroy 释放。roots / extensions 借用 Watch。
Scanner :: struct {
    lock: THREAD.Mutex;
    result: Scan_Result;
    wake: THREAD.Semaphore;
    requested: u64; // 原子：完整扫描请求号
    stop: bool; // 原子
    thread: *THREAD.Thread;
    roots: [] string;
    extensions: [] string;
    interval: s64; // odin 的 time.Duration：两次唤醒的间隔，纳秒
    files: [..] Scan_File;
    index: HASH.Table(string, int);
    sweep: u32;
    served: u64;
    readable: bool;
}

scan_init :: (sc: *Scanner, roots: [] string, extensions: [] string, interval: s64) {
    sc.roots = roots;
    sc.extensions = extensions;
    sc.interval = interval;
    // odin 的 sync.Mutex / sync.Sema 零值可用；jacket 的必须显式 init（见文件头）。
    THREAD.init(*sc.lock, "hotreload.scanner");
    THREAD.init(*sc.wake, 0);
}

// 启动后台扫描线程，低优先级，不与游戏主线程争抢。
scan_start :: (sc: *Scanner) -> bool {
    thread := New(THREAD.Thread);
    if thread == null return false;
    if !THREAD.thread_init(thread, scan_worker, name = "hotreload.scan") return false;
    thread.data = sc;
    THREAD.thread_start(thread);
    sc.thread = thread;
    return true;
}

// 停止并等待扫描线程，再释放扫描表。
scan_destroy :: (sc: *Scanner) {
    push_allocator(context.default_allocator);
    if sc.thread != null {
        ATOMICS.atomic_write(*sc.stop, true);
        THREAD.signal(*sc.wake);
        // odin: thread.join
        _ = THREAD.thread_is_done(sc.thread, -1);
        THREAD.thread_deinit(sc.thread);
        free(sc.thread);
        sc.thread = null;
    }
    // odin: for path in sc.files.path[:len] do delete(path); delete_soa(sc.files)
    for f: sc.files {
        free(f.path);
    }
    array_free(sc.files);
    HASH.deinit(*sc.index);
    THREAD.destroy(*sc.lock);
    THREAD.destroy(*sc.wake);
    sc.* = Scanner.{};
}

// 主线程读取最近一次发布的结果。
scan_result :: (sc: *Scanner) -> Scan_Result {
    THREAD.lock(*sc.lock);
    defer THREAD.unlock(*sc.lock);
    return sc.result;
}

// 请求一次在此之后开始的完整扫描并唤醒线程；结果的 served 达到返回值即已完成。
scan_request :: (sc: *Scanner) -> u64 {
    ticket := ATOMICS.atomic_add(*sc.requested, 1) + 1;
    THREAD.signal(*sc.wake);
    return ticket;
}

scan_worker :: (t: *THREAD.Thread) -> s64 {
    context.allocator = context.default_allocator;
    scan_thread_demote();
    sc := cast(*Scanner) t.data;
    next := scan_monotonic_nano();
    while !ATOMICS.atomic_read(*sc.stop) {
        ticket := ATOMICS.atomic_read(*sc.requested);
        start := scan_monotonic_nano();
        if ticket > sc.served || start >= next {
            scan_sweep(sc);
            sc.served = ticket;
            scan_publish(sc, true);
            next = start + max(sc.interval, (scan_monotonic_nano() - start) * SCAN_COST_FACTOR);
        } else if scan_hot(sc) {
            scan_publish(sc, false);
        }
        reset_temporary_storage();
        _ = THREAD.wait_for(*sc.wake, scan_interval_milliseconds(sc.interval));
    }
    return 0;
}

scan_publish :: (sc: *Scanner, complete: bool) {
    fingerprint := scan_fingerprint(sc);
    THREAD.lock(*sc.lock);
    defer THREAD.unlock(*sc.lock);
    sc.result.fingerprint = fingerprint;
    sc.result.readable = sc.readable;
    if complete {
        sc.result.sweeps += 1;
        sc.result.served = sc.served;
    }
}
//@endregion

//@region 完整扫描

// 列出全部 roots 并比较元数据，只读取新增、元数据变化或时间戳过近的文件；扫描完整时删除未见到的行。
// 显式 root 或任一目录无法读取时 readable = false，本次不删除行。
scan_sweep :: (sc: *Scanner) {
    sc.sweep += 1;
    now := scan_now_unix_nano();
    sc.readable = true;
    for root: sc.roots {
        entry, ok := scan_stat(root);
        if !ok {
            sc.readable = false; // 显式 root 也不跟随符号链接
        } else if entry.kind == Scan_Kind.File {
            sc.readable = scan_visit(sc, root, entry, now); // 显式文件不受扩展名过滤
        } else if entry.kind == Scan_Kind.Directory {
            sc.readable = scan_directory(sc, root, now);
        } else {
            sc.readable = false; // 显式 root 也不跟随符号链接
        }
        if !sc.readable return;
    }
    // 倒序交换删除：搬来的行已经检查过。
    i := sc.files.count - 1;
    while i >= 0 {
        if sc.files[i].sweep != sc.sweep scan_remove(sc, i);
        i -= 1;
    }
}

// 递归列目录，忽略隐藏目录、build、Library 和符号链接；本层的临时名字在返回前释放。
scan_directory :: (sc: *Scanner, dir: string, now: s64) -> bool {
    mark := get_temporary_storage_mark();
    defer set_temporary_storage_mark(mark);
    entries: [..] Scan_Entry;
    if !scan_list(dir, *entries, temp) return false;
    for entry: entries {
        // odin: strings.concatenate({dir, filepath.SEPARATOR_STRING, entry.name})；
        // Jai 侧统一用 `/`（get_absolute_path 也把分隔符规范成 `/`，index 的键因此稳定）。
        path := tprint("%/%", dir, entry.name);
        if entry.kind == Scan_Kind.Directory {
            if STRING.begins_with(entry.name, ".") || entry.name == "build" ||
               entry.name == "Library" {
                continue;
            }
            if !scan_directory(sc, path, now) return false;
        } else if entry.kind == Scan_Kind.File {
            if !scan_matches(sc.extensions, entry.name) continue;
            if !scan_visit(sc, path, entry, now) return false;
        }
    }
    return true;
}

scan_matches :: (extensions: [] string, name: string) -> bool {
    for extension: extensions {
        if STRING.ends_with(name, extension) return true;
    }
    return false;
}

// 查找或新增一行并记为本次已见；新文件、元数据变化或时间戳过近才读取内容。
// 首次扫描的文件不算热文件，之后新出现的才算。
scan_visit :: (sc: *Scanner, path: string, entry: Scan_Entry, now: s64) -> bool {
    found, row := HASH.table_find(*sc.index, path);
    if found {
        sc.files[row].sweep = sc.sweep;
        return !scan_stale(sc, row, entry) || scan_refresh(sc, row, entry, now);
    }
    content, hash_ok := scan_hash_file(path);
    if !hash_ok return false;
    owned := copy_string(path);
    HASH.table_add(*sc.index, owned, sc.files.count);
    array_add(*sc.files, Scan_File.{
        path = owned,
        path_hash = fnv_bytes(FNV_OFFSET, cast([] u8) owned),
        content = content,
        size = entry.size,
        modified = entry.modified,
        checked = now,
        hot_until = ifx sc.sweep > 1 then now + SCAN_HOT_NS else 0,
        sweep = sc.sweep,
    });
    return true;
}

// 大小和修改时间都没变，且上次读取时修改时间已早于余量，才沿用上次的内容哈希。
scan_stale :: (sc: *Scanner, row: int, entry: Scan_Entry) -> bool {
    return entry.size != sc.files[row].size || entry.modified != sc.files[row].modified ||
           entry.modified + SCAN_RACY_NS >= sc.files[row].checked;
}

// 重新读取一行的内容并记录元数据；内容变化时设为热文件。
scan_refresh :: (sc: *Scanner, row: int, entry: Scan_Entry, now: s64) -> bool {
    content, hash_ok := scan_hash_file(sc.files[row].path);
    if !hash_ok return false;
    if content != sc.files[row].content sc.files[row].hot_until = now + SCAN_HOT_NS;
    sc.files[row].content = content;
    sc.files[row].size = entry.size;
    sc.files[row].modified = entry.modified;
    sc.files[row].checked = now;
    return true;
}

scan_remove :: (sc: *Scanner, row: int) {
    path := sc.files[row].path;
    _ = HASH.table_remove(*sc.index, path);
    free(path);
    last := sc.files.count - 1;
    if row != last HASH.table_set(*sc.index, sc.files[last].path, row);
    // odin: unordered_remove_soa(&sc.files, row) —— 末行搬到空位，再缩短长度。
    sc.files[row] = sc.files[last];
    sc.files.count -= 1;
}

// 与顺序无关地合成全部行的路径与内容：增删改任一文件都会改变结果。
scan_fingerprint :: (sc: *Scanner) -> u64 {
    sum := cast(u64) sc.files.count * FNV_PRIME;
    for f: sc.files {
        sum += scan_mix(f.path_hash ^ (f.content * SCAN_CONTENT_SALT));
    }
    return sum;
}

// splitmix64 的末段混合，把相近的输入打散。
scan_mix :: (x: u64) -> u64 {
    z := (x ^ (x >> 30)) * SCAN_MIX_1;
    z = (z ^ (z >> 27)) * SCAN_MIX_2;
    return z ^ (z >> 31);
}

fnv_bytes :: (hash: u64, data: [] u8) -> u64 {
    h := hash;
    for b: data {
        h = (h ^ cast(u64) b) * FNV_PRIME;
    }
    return h;
}
//@endregion

//@region 热文件

// 两次完整扫描之间单独查询最近变化的文件；返回是否重读过内容。消失或读不到的文件留给下次完整扫描。
scan_hot :: (sc: *Scanner) -> bool {
    now := scan_now_unix_nano();
    refreshed := false;
    checked := 0;
    for f, i: sc.files {
        if f.hot_until <= now continue;
        if checked == SCAN_HOT_LIMIT break;
        checked += 1;
        entry, ok := scan_stat(f.path);
        if !ok || entry.kind != Scan_Kind.File || !scan_stale(sc, i, entry) continue;
        if scan_refresh(sc, i, entry, now) refreshed = true;
    }
    return refreshed;
}
//@endregion

//@region 时钟桥接

// odin: time.tick_now / tick_diff / tick_since —— jacket 的单调时钟（纳秒）。
scan_monotonic_nano :: () -> s64 {
    nanoseconds, ok := to_nanoseconds(current_time_monotonic());
    if !ok return 0;
    return nanoseconds;
}

// odin: time.Duration → sema_wait_with_timeout；jacket 的 wait_for 收毫秒，至少等 1 毫秒。
scan_interval_milliseconds :: (interval_ns: s64) -> s32 {
    milliseconds := cast(s32) (interval_ns / 1000000);
    return max(milliseconds, 1);
}
//@endregion
