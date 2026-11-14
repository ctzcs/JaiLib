// app —— CLI 参数与后台调试控制台（对位 DragonLib CliConsole）。
// 一比一移植自 olib `kit/app/cli_console.odin`（314 行）。
//
// 后台线程读 stdin，原始行经加锁的待处理列表转到主线程——游戏每帧调一次
// cli_update（在 UpdateProc 里），handler 里可以安全读写游戏状态。
//
// 线程边界：读取线程只做“克隆一行、加锁入列”，不读命令表；查找命令、
// 转小写和未知命令提示都在主线程。跨线程的字符串与列表固定用 init 时记下的
// 堆分配器（线程安全），不用任一侧的 context.allocator——调用方的
// Tracking_Allocator 等不是线程安全的，也不认另一线程分配的内存。
//
// 与 DragonLib 的差异：
//   - 不走 App.RunOnMainThread（jfoster 的 AppCallback 无 userdata 参数），
//     改用互斥锁保护的待处理列表 + 每帧取出执行，语义相同；
//   - cli_open / cli_register_quit 可把 quit 接到 jfoster 的退出标志。
//
// 本文件还带包内的 CLI 参数判断（has_arg）。
//
// Jai 侧差异（对外行为不变，逐条对应 olib 的写法）：
//   | olib (Odin)                              | JaiLib (Jai)                                            |
//   | ---------------------------------------- | ------------------------------------------------------- |
//   | map[string]Cli_Command                   | HASH.Table(string, Cli_Command)                         |
//   | sync.Mutex（零值即可用）                   | THREAD.Mutex（必须先 init）；多一个 mutex_ready 字段守卫， |
//   |                                          | 于是零值 console 上的 update/enqueue/dispose 依旧安全     |
//   | runtime.heap_allocator()                 | DEFAULT.allocator_proc（context.allocator 背后的通用堆）  |
//   | os.stdin / os.read(os.stdin, buf[:])     | cli_stdin（惰性解析的 STD_INPUT_HANDLE）+ ReadFile       |
//   | os.stdin = nil（测试）                     | cli_stdin_unavailable = true（测试）                     |
//   | thread.create_and_start_with_data(...,   | New(THREAD.Thread) + thread_init / thread_start；线程在  |
//   |   self_cleanup = true)                   | dispose 后随下一行或进程退出结束，Jai 侧不 join 也不 deinit|
//   | context.allocator（线程自己的）            | 读取线程的行缓冲改用本线程 temp（同样线程私有，且绝不会    |
//   |                                          | 碰到调用方在主线程设置的分配器）                          |
//   | strings.to_lower / trim_space / index     | cli_ascii_lower_copy / cli_trim_space / cli_index_of（都  |
//   |                                          | 是 ASCII 语义，与 odin 一致；UTF-8 参数原样保留）          |
//   | fmt.eprintf（stderr）                     | print（Basic 没有裸 stderr 写出）                        |
//   | foster.App / foster.Exit                 | F.App_State / app.running 时置 app.exiting               |
//   | delete(slice) / clear(&slice)             | array_free / array_reset / array_reset_keeping_memory    |
//   | for i in 0..<n / for x in slice           | for 0..n-1（闭区间）/ for x: slice                       |
//   | @(private)                               | cli_ 前缀的包内过程                                      |
//
// Jai 侧新增（olib 的 kit/app 没有；都为向后兼容的增量）：
//   - cli_close：等价于 olib 的 cli_dispose（cli_dispose 也保留）；
//   - 内置命令 history：olib 的 history 在 game_app 层打印 jfoster 日志；kit/app 没有
//     日志系统，这里记录并回放本控制台已执行的命令行（Cli_Console.history，上限 256 条）；
//   - Cli_Console 多两个字段：mutex_ready（见上）、reader（读取线程指针，便于诊断）。
#import "Basic";

//@region CLI 参数 —— has_arg

// 判断命令行参数里是否存在 name（--flag / -f / /f / 裸词均可，大小写不敏感）。
has_arg :: (args: [] string, name: string) -> bool {
    for arg: args {
        if cli_eq_ignore_case(cli_trim_leading_dashes(arg), name) return true;
    }
    return false;
}

cli_eq_ignore_case :: (a: string, b: string) -> bool {
    if a.count != b.count return false;
    i := 0;
    while i < a.count {
        if cli_ascii_lower(a[i]) != cli_ascii_lower(b[i]) return false;
        i += 1;
    }
    return true;
}

cli_trim_leading_dashes :: (s: string) -> string {
    i := 0;
    while i < s.count && (s[i] == #char "-" || s[i] == #char "/") i += 1;
    return cli_substring(s, i, s.count);
}
//@endregion

//@region 类型与注册

// 命令处理函数：args 是命令名之后的剩余文本（已裁剪空白）。
Cli_Handler :: #type (args: string, userdata: *void);

Cli_Command :: struct {
    description: string;
    handler: Cli_Handler;
    userdata: *void;
}

Cli_Console :: struct {
    commands: HASH.Table(string, Cli_Command); // key 为小写命令名（克隆）；只在主线程读写

    // 以下四项跨线程，由 mutex 保护；pending 及其字符串归 allocator。
    mutex: THREAD.Mutex;
    mutex_ready: bool; // Jai 侧：odin 的 Mutex 零值即可用，Jai 的必须先 init
    allocator: Allocator; // 零值表示未初始化或已 dispose，入列直接丢弃
    pending: [..] string; // 读取线程送来、尚未执行的原始行
    accepting: bool; // cli_stop 后不再接收，读取线程随下一行退出

    executing: [..] string; // 主线程独占：cli_update 与 pending 交换后逐条执行
    started: bool; // 读取线程已启动（线程自清理，不 join）

    reader: *THREAD.Thread; // Jai 侧：读取线程句柄（odin 的线程自清理，不留句柄）
    history: [..] string; // Jai 侧：已执行命令的历史（内置 history 命令用）
}

cli_init :: (console: *Cli_Console) {
    // olib 的 runtime.heap_allocator()：Jai 侧是 context.allocator 背后的通用堆，
    // Default_Allocator 保证它线程安全，也不经过调用方的追踪分配器。
    heap := Allocator.{ DEFAULT.allocator_proc, null };
    // odin 的 sync.Mutex 零值可用；Jai 的必须先 init。mutex 之后不再 destroy：
    // 读取线程可能仍阻塞在 stdin 上，dispose 不 join 它（见文件头）。
    THREAD.init(*console.mutex, "kit.app.cli_console");
    console.mutex_ready = true;
    console.allocator = heap;
    console.accepting = true;
    console.started = false;
    cli_register(console, "help", "列出全部命令", cli_builtin_help, console);
    cli_register(console, "quit", "退出程序（游戏应覆盖注册真正的退出）", cli_builtin_quit, null);
    cli_register(console, "history", "列出已执行的命令历史", cli_builtin_history, console);
}

// 一步开启控制台；quit_app 非 null 时 quit 调用 jfoster 的退出。
// 开启前 console 应为零值或已 dispose；失败时释放资源，update / dispose 可安全调用。
cli_open :: (console: *Cli_Console, quit_app: *F.App_State = null) -> bool {
    cli_init(console);
    if quit_app != null {
        cli_register_quit(console, quit_app);
    }
    if !cli_start(console) {
        cli_dispose(console);
        return false;
    }
    return true;
}

// 将 quit 命令接到 jfoster 的退出；app 必须在控制台使用期间保持有效。
// （olib 的 foster.Exit 只置退出标志，这里同样只写字段，不动 jfoster 的全局 App。）
cli_register_quit :: (console: *Cli_Console, app: *F.App_State) {
    cli_register(console, "quit", "退出程序", cli_quit_app, app);
}

// 释放全部资源。读取线程可能仍阻塞在 stdin 上：它之后送来的行被丢弃，
// 线程随即退出。mutex 不清零，console 须保持地址有效直到进程退出或线程结束。
cli_dispose :: (console: *Cli_Console) {
    if cli_lock(console) {
        // pending 归 allocator：可能仍与读取线程并发，必须在锁内释放并清掉 allocator。
        heap := console.allocator;
        if heap.proc != null {
            push_allocator(heap);
            for line: console.pending {
                if line.data != null free(line.data);
            }
        }
        array_reset(*console.pending);
        console.allocator = Allocator.{};
        console.accepting = false;
        THREAD.unlock(*console.mutex);
    }

    // 主线程独占的数据（commands 的键与描述、executing / history 的行）：与 olib 一样
    // 用 context.allocator 释放——它们在主线程用同一个 allocator 分配。
    for line: console.executing {
        if line.data != null free(line.data);
    }
    array_reset(*console.executing);
    for line: console.history {
        if line.data != null free(line.data);
    }
    array_reset(*console.history);
    for entry: console.commands.entries {
        if entry.hash < HASH.FIRST_VALID_HASH continue;
        if entry.key.data != null free(entry.key.data);
        if entry.value.description.data != null free(entry.value.description.data);
    }
    HASH.deinit(*console.commands);
    console.commands = .{};
    console.started = false;
}

// 等价于 olib 的 cli_dispose（见文件头「Jai 侧新增」）。
cli_close :: (console: *Cli_Console) {
    cli_dispose(console);
}

// 注册命令（名字大小写不敏感，重复注册覆盖）。只在主线程调用。
cli_register :: (console: *Cli_Console, name: string, description: string, handler: Cli_Handler, userdata: *void = null) {
    lower := cli_ascii_lower_copy(name);
    command := Cli_Command.{
        description = copy_string(description),
        handler = handler,
        userdata = userdata,
    };
    slot := HASH.table_find_pointer(*console.commands, lower);
    if slot != null {
        // 复用注册表持有的键，覆盖时不遗留旧键或新克隆（olib 同义）。
        if slot.description.data != null free(slot.description.data);
        slot.* = command;
        if lower.data != null free(lower.data);
        return;
    }
    HASH.table_add(*console.commands, lower, command);
}
//@endregion

//@region 生命周期 —— start / stop

// 启动后台读取线程（幂等）。stdin 不可用或未 init 时返回 false。
cli_start :: (console: *Cli_Console) -> bool {
    if console.started return true;
    if cli_stdin_handle() == null || console.allocator.proc == null return false;
    // 自清理：线程退出时随进程结束，dispose 不必 join 阻塞中的 stdin 读取。
    thread := New(THREAD.Thread);
    if !THREAD.thread_init(thread, cli_reader_loop, name = "kit.app.cli_reader") {
        free(thread);
        return false;
    }
    thread.data = console;
    console.reader = thread;
    THREAD.thread_start(thread);
    console.started = true;
    print("[cli] CLI 调试控制台已启动，输入 help 查看命令\n");
    return true;
}

// 停止接收输入。阻塞中的 stdin 读取要等到下一行输入或 EOF 才返回，
// 那一行被丢弃，线程随即退出；进程退出时线程随进程结束。
cli_stop :: (console: *Cli_Console) {
    if !cli_lock(console) return;
    console.accepting = false;
    THREAD.unlock(*console.mutex);
}
//@endregion

//@region 主线程消费 —— cli_update

// 每帧调用：取出读取线程送来的行，在主线程逐条执行。
// 只处理本次开始时已送达的行；handler 期间新到的留到下一次。
cli_update :: (console: *Cli_Console) {
    // 零值或已 dispose：没有可交换的待处理列表（olib 交换两个 nil 后什么也不做）。
    if !cli_lock(console) return;
    allocator := console.allocator;
    console.pending, console.executing = console.executing, console.pending;
    THREAD.unlock(*console.mutex);
    if allocator.proc == null return;

    for line: console.executing {
        cli_execute(console, line);
        // 行来自读取线程，固定用 init 时记下的分配器释放（不用调用方的 context）。
        cli_free_owned(line, allocator);
    }
    // olib 的 clear：保留容量，下一帧直接复用。
    array_reset_keeping_memory(*console.executing);
}

// 主线程：解析一行，查找命令并执行；未知命令提示。
cli_execute :: (console: *Cli_Console, line: string) {
    trimmed := cli_trim_space(line);
    if trimmed.count == 0 return;
    name, args, ok := cli_parse_line(trimmed);
    if !ok return;

    lower := cli_ascii_lower_copy(name);
    defer {
        if lower.data != null free(lower.data);
    }
    slot := HASH.table_find_pointer(*console.commands, lower);
    if slot == null {
        print("[cli] 未知命令 '%'，输入 help 查看命令列表\n", name);
        return;
    }
    if slot.handler != null {
        slot.handler(args, slot.userdata);
    }
    cli_history_append(console, trimmed);
}
//@endregion

//@region 后台读取线程

// 任意线程：克隆一行送给主线程（line 只借用）。控制台未初始化、已 stop
// 或已 dispose 时丢弃并返回 false。
cli_enqueue_line :: (console: *Cli_Console, line: string) -> bool {
    if !cli_lock(console) return false;
    defer THREAD.unlock(*console.mutex);
    if !console.accepting || console.allocator.proc == null return false;
    push_allocator(console.allocator);
    owned := copy_string(line);
    array_add(*console.pending, owned);
    return true;
}

cli_reader_loop :: (thread: *THREAD.Thread) -> s64 {
    console := cast(*Cli_Console) thread.data;
    handle := cli_stdin_handle();

    // 行缓冲只在本线程使用：用本线程的 temp（线程私有，绝不碰调用方的分配器）。
    push_allocator(temp);
    buf: [256] u8;
    pending: [..] u8;
    defer array_free(pending);

    while true {
        count := cli_platform_read(handle, buf.data, buf.count);
        if count <= 0 {
            return 0; // stdin 关闭（管道结束 / 无控制台）
        }
        i := 0;
        while i < count {
            byte := buf[i];
            i += 1;
            if byte == #char "\n" {
                if !cli_enqueue_line(console, cli_string_of(pending)) return 0;
                pending.count = 0; // odin 的 clear(&pending)
                continue;
            }
            if byte != #char "\r" {
                array_add(*pending, byte);
            }
        }
    }
    return 0;
}
//@endregion

//@region 行解析

// "cmd rest of line" -> ("cmd", "rest of line")；输入保证非空。
cli_parse_line :: (line_in: string) -> (string, string, bool) {
    line := cli_trim_space(line_in);
    sep := cli_index_of(line, #char " ");
    if sep < 0 {
        return line, "", true;
    }
    name := cli_trim_space(cli_substring(line, 0, sep));
    args := cli_trim_space(cli_substring(line, sep + 1, line.count));
    if name.count == 0 return "", "", false;
    return name, args, true;
}
//@endregion

//@region 内建命令

cli_builtin_help :: (args: string, ud: *void) {
    console := cast(*Cli_Console) ud;
    builder: String_Builder;
    defer free_buffers(*builder);
    append(*builder, "[cli] 命令列表:\n");
    for entry: console.commands.entries {
        if entry.hash < HASH.FIRST_VALID_HASH continue;
        append(*builder, "  ");
        append(*builder, entry.key);
        // olib 的 "  %-12s %s"：名字不足 12 列时补空格。
        columns := entry.key.count;
        while columns < 12 {
            append(*builder, " ");
            columns += 1;
        }
        append(*builder, " ");
        append(*builder, entry.value.description);
        append(*builder, "\n");
    }
    text := builder_to_string(*builder);
    print(text);
    if text.data != null free(text.data);
}

cli_builtin_quit :: (args: string, ud: *void) {
    print("[cli] （默认 quit：请用 cli_register_quit 接入 jfoster.App）\n");
}

cli_quit_app :: (args: string, ud: *void) {
    app := cast(*F.App_State) ud;
    // olib 的 foster.Exit：只在 App 运行时置退出标志。
    if app != null && app.running {
        app.exiting = true;
    }
}

// Jai 侧新增的命令：回放本控制台已执行的命令行（见文件头）。
cli_builtin_history :: (args: string, ud: *void) {
    console := cast(*Cli_Console) ud;
    builder: String_Builder;
    defer free_buffers(*builder);
    append(*builder, "[cli] 命令历史:\n");
    for line, index: console.history {
        append(*builder, tprint("  % %\n", index + 1, line));
    }
    text := builder_to_string(*builder);
    print(text);
    if text.data != null free(text.data);
}
//@endregion

//@region 内部

CLI_HISTORY_LIMIT :: 256;

// 记录一条已执行的命令行；超过上限时丢弃最旧的一条。
cli_history_append :: (console: *Cli_Console, line: string) {
    while console.history.count >= CLI_HISTORY_LIMIT {
        if console.history[0].data != null free(console.history[0].data);
        i := 0;
        while i + 1 < console.history.count {
            console.history[i] = console.history[i + 1];
            i += 1;
        }
        console.history.count -= 1;
    }
    array_add(*console.history, copy_string(line));
}

// 零值 console 也能安全调用：只有 cli_init 过的 console 才有可用的互斥体。
cli_lock :: (console: *Cli_Console) -> bool {
    if !console.mutex_ready return false;
    THREAD.lock(*console.mutex);
    return true;
}

// 释放读取线程送来的字符串（固定用 init 时记下的分配器）。
cli_free_owned :: (line: string, allocator: Allocator) {
    if line.data == null return;
    push_allocator(allocator);
    free(line.data);
}

// odin strings.trim_space 的等价物（ASCII 空白）。
cli_trim_space :: (s: string) -> string {
    start := 0;
    end := s.count;
    while start < end && cli_is_space(s[start]) start += 1;
    while end > start && cli_is_space(s[end - 1]) end -= 1;
    return cli_substring(s, start, end);
}

cli_is_space :: (c: u8) -> bool {
    return c == #char " " || c == #char "\t" || c == #char "\n" ||
           c == #char "\r" || c == #char "\v" || c == #char "\f";
}

// odin strings.index(s, " ") 的等价物（找不到返回 -1）。
cli_index_of :: (s: string, needle: u8) -> int {
    i := 0;
    while i < s.count {
        if s[i] == needle return i;
        i += 1;
    }
    return -1;
}

// Jai 没有 s[a:b] 语法。
cli_substring :: (source: string, start: int, end: int) -> string {
    if end <= start || start >= source.count return "";
    return string.{ end - start, source.data + start };
}

// odin strings.to_lower：只映射 ASCII A-Z（UTF-8 多字节序列原样保留）。
cli_ascii_lower_copy :: (s: string) -> string {
    out := copy_string(s);
    i := 0;
    while i < out.count {
        out.data[i] = cli_ascii_lower(out.data[i]);
        i += 1;
    }
    return out;
}

cli_ascii_lower :: (c: u8) -> u8 {
    if c >= #char "A" && c <= #char "Z" return c + (#char "a" - #char "A");
    return c;
}

// odin 的 dynamic 数组视图 -> string（count + data）。
cli_string_of :: (bytes: [..] u8) -> string {
    if bytes.count == 0 return "";
    return string.{ bytes.count, bytes.data };
}
//@endregion

//@region 平台 —— stdin

// 对应 odin 的 os.stdin：标准输入句柄；null 表示不可用。
// 惰性解析一次（odin 里由 os 包在启动时填好）。
cli_stdin: *void;
// 对应 odin 测试里的 `os.stdin = nil`：置 true 让控制台认为 stdin 不可用。
cli_stdin_unavailable: bool;

cli_stdin_handle :: () -> *void {
    if cli_stdin_unavailable return null;
    if cli_stdin == null cli_stdin = cli_platform_stdin();
    return cli_stdin;
}

#if OS == .WINDOWS {
    CLI_KERNEL32 :: #library,system "kernel32";
    cli_platform_get_std_handle :: (identifier: s32) -> *void #foreign CLI_KERNEL32 "GetStdHandle";
    cli_platform_read_file :: (handle: *void, buffer: *void, count: u32, read: *u32, overlapped: *void) -> s32 #foreign CLI_KERNEL32 "ReadFile";
    CLI_STD_INPUT_HANDLE :: -10;

    // odin 的 os.stdin 在无控制台时为 nil；这里同步拒绝无效句柄。
    cli_platform_stdin :: () -> *void {
        handle := cli_platform_get_std_handle(CLI_STD_INPUT_HANDLE);
        if handle == null || handle == cast(*void) -1 return null;
        return handle;
    }

    // 返回本次读到的字节数；0 / 负数表示 stdin 关闭（管道结束 / 无控制台）。
    cli_platform_read :: (handle: *void, buffer: *u8, count: int) -> int {
        got: u32;
        if cli_platform_read_file(handle, buffer, cast(u32) count, *got, null) == 0 return 0;
        return cast(int) got;
    }
} else {
    CLI_LIBC :: #library,system "c";
    cli_platform_posix_read :: (fd: s32, buffer: *void, count: u64) -> s64 #foreign CLI_LIBC "read";

    // odin 在非 Windows 上把 os.stdin 指向 fd 0；这里用一个非空哨兵表示“可用”。
    cli_platform_stdin :: () -> *void {
        return cast(*void) 1;
    }

    cli_platform_read :: (handle: *void, buffer: *u8, count: int) -> int {
        result := cli_platform_posix_read(0, buffer, cast(u64) count);
        if result <= 0 return 0;
        return cast(int) result;
    }
}
//@endregion
