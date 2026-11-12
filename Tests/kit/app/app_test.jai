// kit/app 回归测试 —— 一比一移植自 olib `tests/kit/app/app_test.odin`（164 行）。
//
// 组织方式与 olib 对位：每个 @(test) 对应一个过程，过程名不变，断言顺序与 olib
// 一一对应；签名统一 `(state: *Test_State)`（由 Tests/kit/run_kit_tests.jai 调度），
// 用 Tests/test_support.jai 的 expect / test_summary。本文件不写 main。
//
// Jai 侧差异（断言语义不变）：
//   | olib (Odin)                                    | 这里 (Jai)                                            |
//   | ---------------------------------------------- | ---------------------------------------------------- |
//   | testing.expect(t, cond)                         | expect(state, cond, "说明")                           |
//   | testing.expect_value(t, a, b)                   | expect(state, a == b, "说明")                         |
//   | testing.expectf(t, cond, fmt, ..)               | expect(state, cond, "说明 %", args)                    |
//   | len(slice)                                      | slice.count                                          |
//   | 同包内可直接用的 @(private) helper               | 测试在另一个模块，只能走公开 API + copy_string/free     |
//   | @(test) / @(private)                            | 无等价物；夹具一律 app_test_ 前缀，测试过程名照 olib    |
//   | os.stdin = nil                                  | APP.cli_stdin_unavailable = true                     |
//   | mem.Tracking_Allocator + allocation_map /        | App_Test_Counter（指针账本：活块数 + 越界释放计数，      |
//   |   bad_free_array                                | 等价 allocation_map 为空 / bad_free_array 为空）        |
//   | thread.create_and_start_with_data / is_done      | New(THREAD.Thread) + thread_init/thread_start/       |
//   |                                                 | thread_is_done(thread, 0) + thread_deinit             |
//   | foster.App{ Running = true } / a.Exiting        | F.App_State{ running = true } / a.exiting             |
//   | delete(slice)                                   | array_reset / free                                    |
//
// 真实 stdin（后台读取线程从 STD_INPUT_HANDLE 读字节）在无人值守下无法验证：
// 涉及读取线程的用例只到「open 失败即清理」这一层，入列/分发/退出码这一层用
// cli_enqueue_line + 生产者线程直测——与 olib 的测试策略一致（olib 也不启动真实
// stdin 线程）。读取循环本身（字节拼行、\r 丢弃、EOF 退出）因此不在断言覆盖内。
#import "Basic";
F :: #import "jfoster";
THREAD :: #import "Thread";

APP :: #import "kit/app";
#import "test_support";

//@region 夹具 helper

App_Test_Echo_State :: struct {
    console: *APP.Cli_Console;
    got:     string;
}

app_test_echo_handler :: (args: string, ud: *void) {
    state := cast(*App_Test_Echo_State) ud;
    if state.got.data != null free(state.got.data);
    state.got = copy_string(args);
}

// 记账分配器（olib 的 mem.Tracking_Allocator）：记下自己发出去的每个块，
// 释放不属于自己的指针时只记账、不转交（转交会污染真实堆）。
App_Test_Counter :: struct {
    backing:       Allocator;
    allocations:   int;
    bad_free:      int; // 等价 odin 的 bad_free_array
    tracked:       [4096] *void;
    tracked_count: int; // 等价 odin 的 allocation_map 大小
    overflow:      bool;
}

app_test_counter_find :: (counter: *App_Test_Counter, memory: *void) -> int {
    i := 0;
    while i < counter.tracked_count {
        if counter.tracked[i] == memory return i;
        i += 1;
    }
    return -1;
}

app_test_counter_untrack :: (counter: *App_Test_Counter, memory: *void) -> bool {
    index := app_test_counter_find(counter, memory);
    if index < 0 return false;
    counter.tracked_count -= 1;
    counter.tracked[index] = counter.tracked[counter.tracked_count];
    return true;
}

app_test_counter_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, data: *void) -> *void {
    counter := cast(*App_Test_Counter) data;
    if mode == .ALLOCATE {
        memory := counter.backing.proc(.ALLOCATE, size, 0, null, counter.backing.data);
        if memory {
            counter.allocations += 1;
            if counter.tracked_count < counter.tracked.count {
                counter.tracked[counter.tracked_count] = memory;
                counter.tracked_count += 1;
            } else {
                counter.overflow = true;
            }
        }
        return memory;
    }
    if mode == .FREE {
        if old_memory == null return null;
        if !app_test_counter_untrack(counter, old_memory) {
            counter.bad_free += 1;
            return null;
        }
        return counter.backing.proc(.FREE, 0, 0, old_memory, counter.backing.data);
    }
    // 其它模式（RESIZE 等）：转交 backing，并保持指针账本一致。
    result := counter.backing.proc(mode, size, old_size, old_memory, counter.backing.data);
    if old_memory != null app_test_counter_untrack(counter, old_memory);
    if result != null {
        if counter.tracked_count < counter.tracked.count {
            counter.tracked[counter.tracked_count] = result;
            counter.tracked_count += 1;
        } else {
            counter.overflow = true;
        }
    }
    return result;
}

CLI_THREAD_LINES :: 64;

// 读取线程的替身：只调 cli_enqueue_line（与 olib 的生产者线程一致）。
// 行文本由主线程预先备好，线程里不分配——odin 的 tracking allocator 也不是线程安全的。
App_Test_Producer :: struct {
    console: *APP.Cli_Console;
    lines:   [] string;
}

app_test_producer :: (thread: *THREAD.Thread) -> s64 {
    producer := cast(*App_Test_Producer) thread.data;
    for line: producer.lines {
        APP.cli_enqueue_line(producer.console, line);
    }
    return 0;
}

// 顺序/计数：handler 记下收到的序号，交错就计数。
App_Test_Count :: struct {
    console:      *APP.Cli_Console;
    count:        int;
    out_of_order: int;
}

app_test_count_handler :: (args: string, ud: *void) {
    state := cast(*App_Test_Count) ud;
    value, ok, _ := string_to_int(args, 10, int);
    if !ok || value != state.count state.out_of_order += 1;
    state.count += 1;
}

// 链式入列：handler 内部再送一行。
App_Test_Chain :: struct {
    console: *APP.Cli_Console;
    lines:   [..] string;
}

app_test_chain_handler :: (args: string, ud: *void) {
    state := cast(*App_Test_Chain) ud;
    array_add(*state.lines, copy_string(args));
    if args == "kick" {
        // 同一次 update 里入列：本次不执行（olib：handler 期间新到的留到下一次）。
        APP.cli_enqueue_line(state.console, "chain second");
    }
}

app_test_chain_dispose :: (state: *App_Test_Chain) {
    for line: state.lines {
        if line.data != null free(line.data);
    }
    array_reset(*state.lines);
}

App_Test_Marker :: struct {
    hits: int;
    last: string;
}

app_test_marker_handler :: (args: string, ud: *void) {
    marker := cast(*App_Test_Marker) ud;
    marker.hits += 1;
    if marker.last.data != null free(marker.last.data);
    marker.last = copy_string(args);
}

app_test_marker_dispose :: (marker: *App_Test_Marker) {
    if marker.last.data != null free(marker.last.data);
    marker.last = "";
}
//@endregion

//@region olib 原有测试用例

has_arg_matches_flags :: (state: *Test_State) {
    // 最后一项是追加的 Windows 风格参数（前 5 条断言与 olib 完全相同）。
    args: [] string = .[ "game.exe", "--Verbose", "-nofocus", "level1", "/Urgent" ];

    expect(state, APP.has_arg(args, "verbose"), "// -- 前缀 + 大小写");
    expect(state, APP.has_arg(args, "nofocus"), "// - 前缀");
    expect(state, APP.has_arg(args, "level1"), "// 裸词");
    expect(state, !APP.has_arg(args, "missing"), "");
    expect(state, !APP.has_arg(args, "level"), "// 前缀匹配不算");

    // 追加：odin 的 trim_leading_dashes 也接受 Windows 风格的 /flag。
    expect(state, APP.has_arg(args, "urgent"), "// / 前缀（odin 的 trim_leading_dashes）");
    expect(state, !APP.has_arg(args, ""), "// 空名字不匹配");
}

cli_parse_line_splits :: (state: *Test_State) {
    name, arguments, ok := APP.cli_parse_line("spawn goblin 3 4");
    expect(state, ok && name == "spawn" && arguments == "goblin 3 4", "spawn goblin 3 4");

    name2, args2, ok2 := APP.cli_parse_line("help");
    expect(state, ok2 && name2 == "help" && args2 == "", "help");

    name3, args3, ok3 := APP.cli_parse_line("  cmd   spaced  ");
    expect(state, ok3 && name3 == "cmd" && args3 == "spaced", "  cmd   spaced  ");

    // 追加：内部空格与 UTF-8 原样保留；纯空白行裁剪后为空。
    name4, args4, ok4 := APP.cli_parse_line("say 你好 世界  x");
    expect(state, ok4 && name4 == "say" && args4 == "你好 世界  x", "UTF-8 参数与内部空格: %", args4);

    name5, args5, ok5 := APP.cli_parse_line("     ");
    expect(state, ok5 && name5 == "" && args5 == "", "纯空白行：裁剪后为空，ok 仍为 true（与 olib 一致）");
}

cli_enqueue_and_update_roundtrip :: (state: *Test_State) {
    console: APP.Cli_Console;
    APP.cli_init(*console);
    defer APP.cli_dispose(*console);

    echo: App_Test_Echo_State;
    defer { if echo.got.data != null free(echo.got.data); }
    echo.console = *console;
    APP.cli_register(*console, "Echo", "回显参数", app_test_echo_handler, *echo);

    // 模拟读取线程收到一行：原样入列，主线程消费前不可见
    expect(state, APP.cli_enqueue_line(*console, "echo hello world"), "入列成功");
    expect(state, console.pending.count == 1, "pending 有 1 行，实际 %", console.pending.count);
    expect(state, echo.got == "", "执行前看不到参数");

    APP.cli_update(*console);
    expect(state, echo.got == "hello world", "执行后可见: %", echo.got);
    expect(state, console.pending.count == 0, "pending 清空，实际 %", console.pending.count);

    // 大小写不敏感注册键；未知命令只提示、不执行
    expect(state, APP.cli_enqueue_line(*console, "ECHO again"), "入列 ECHO again");
    expect(state, APP.cli_enqueue_line(*console, "missing arg"), "入列 missing arg");
    APP.cli_update(*console);
    expect(state, echo.got == "again", "小写键查找: %", echo.got);

    // stop 后不再接收
    APP.cli_stop(*console);
    expect(state, !APP.cli_enqueue_line(*console, "echo late"), "stop 之后入列失败");
}

// 回归：读取线程分配的行由主线程释放；主线程开内存追踪时不得 bad free 或泄漏。
cli_lines_from_another_thread_free_cleanly_under_tracking :: (state: *Test_State) {
    counter: App_Test_Counter = .{ backing = context.allocator };
    allocator := Allocator.{ app_test_counter_proc, *counter };
    // 与 olib 的 Tracking_Allocator 同义：主线程换成会被记账的分配器。
    push_allocator(allocator);

    // 「count 0」…「count 63」由主线程备好（temp 上，本过程内有效）。
    line_views: [CLI_THREAD_LINES] string;
    for 0..CLI_THREAD_LINES - 1 {
        line_views[it] = tprint("count %", it);
    }

    count: App_Test_Count;
    {
        console: APP.Cli_Console;
        APP.cli_init(*console);
        count.console = *console;
        APP.cli_register(*console, "count", "计数", app_test_count_handler, *count);

        producer_data: App_Test_Producer = .{ console = *console, lines = line_views };
        producer := New(THREAD.Thread);
        assert(THREAD.thread_init(producer, app_test_producer), "无法启动生产者线程");
        producer.data = *producer_data;
        THREAD.thread_start(producer);
        while !THREAD.thread_is_done(producer, 0) {
            APP.cli_update(*console);
        }
        THREAD.thread_deinit(producer);
        free(producer);
        APP.cli_update(*console);

        // 再送一行不执行，验证 dispose 释放未执行的行
        expect(state, APP.cli_enqueue_line(*console, "count"), "dispose 前留一行未执行");
        APP.cli_dispose(*console);
    }

    expect(state, count.count == CLI_THREAD_LINES, "执行次数 % / %", count.count, CLI_THREAD_LINES);
    expect(state, count.out_of_order == 0, "跨线程顺序保持，实际乱序 %", count.out_of_order);
    expect(state, !counter.overflow, "指针账本没有溢出");
    expect(state, counter.bad_free == 0, "没有 bad free（olib 的 bad_free_array 为空），实际 %", counter.bad_free);
    expect(state, counter.tracked_count == 0, "没有泄漏（olib 的 allocation_map 为空），剩余块 %", counter.tracked_count);
    expect(state, counter.allocations > 0, "主线程确实用了调用方分配器，实际 %", counter.allocations);
}

cli_quit_exits_foster_app :: (state: *Test_State) {
    console: APP.Cli_Console;
    APP.cli_init(*console);
    defer APP.cli_dispose(*console);

    app: F.App_State;
    app.running = true;
    APP.cli_register_quit(*console, *app);
    APP.cli_enqueue_line(*console, "quit");
    expect(state, !app.exiting, "quit 之前退出标志为 false");
    APP.cli_update(*console);
    expect(state, app.exiting, "quit 之后 App 退出");
}

cli_zero_value_lifecycle :: (state: *Test_State) {
    console: APP.Cli_Console;
    expect(state, !APP.cli_enqueue_line(*console, "help"), "零值 console 入列失败");
    APP.cli_update(*console);
    APP.cli_dispose(*console);
    APP.cli_dispose(*console);
    expect(state, console.commands.count == 0 && !console.started && !console.accepting,
           "清空后 commands 空、未启动、不再接收");
    expect(state, console.pending.data == null && console.executing.data == null, "pending / executing 为空");
}

cli_open_without_stdin_cleans_up :: (state: *Test_State) {
    previous := APP.cli_stdin_unavailable;
    APP.cli_stdin_unavailable = true;
    defer APP.cli_stdin_unavailable = previous;

    console: APP.Cli_Console;
    app: F.App_State;
    expect(state, !APP.cli_open(*console, *app), "stdin 不可用时 cli_open 返回 false");
    APP.cli_update(*console);
    APP.cli_dispose(*console);
    expect(state, console.commands.count == 0 && !console.started && !console.accepting,
           "失败的 open 已清理：commands 空、未启动、不再接收");
}
//@endregion

//@region 追加用例（olib 没有；补 Jai 侧差异点与内置命令）

// 内置命令：help / quit / history 都在；重复注册（含大小写不同）只覆盖不新增。
cli_builtin_commands_registered :: (state: *Test_State) {
    console: APP.Cli_Console;
    APP.cli_init(*console);
    defer APP.cli_dispose(*console);

    expect(state, console.commands.count == 3, "内置 3 条命令，实际 %", console.commands.count);

    app: F.App_State;
    APP.cli_register_quit(*console, *app);
    expect(state, console.commands.count == 3, "cli_register_quit 覆盖 quit，不新增条目");

    // 三条内置命令都能被分发（help / history 只打印，quit 走默认提示）。
    expect(state, APP.cli_enqueue_line(*console, "help"), "help 入列");
    expect(state, APP.cli_enqueue_line(*console, "history"), "history 入列");
    expect(state, APP.cli_enqueue_line(*console, "quit"), "quit 入列");
    APP.cli_update(*console);
    expect(state, console.pending.count == 0, "内置命令全部分发完毕");

    // 同名（只差大小写）重复注册只覆盖，不新增条目，且覆盖立即生效。
    marker: App_Test_Marker;
    defer app_test_marker_dispose(*marker);
    APP.cli_register(*console, "Help", "覆盖 help", app_test_marker_handler, *marker);
    APP.cli_register(*console, "HELP", "再覆盖 help", app_test_marker_handler, *marker);
    expect(state, console.commands.count == 3, "同名（大小写不同）重复注册只覆盖，实际 %", console.commands.count);
    expect(state, APP.cli_enqueue_line(*console, "help"), "覆盖后的 help 入列");
    APP.cli_update(*console);
    expect(state, marker.hits == 1, "覆盖后的 handler 生效，实际命中 %", marker.hits);
}

// history：只记录执行成功的命令（trim 后的原文），未知命令不入历史。
cli_history_records_executed_lines :: (state: *Test_State) {
    console: APP.Cli_Console;
    APP.cli_init(*console);
    defer APP.cli_dispose(*console);

    marker: App_Test_Marker;
    defer app_test_marker_dispose(*marker);
    APP.cli_register(*console, "marker", "记录参数", app_test_marker_handler, *marker);

    APP.cli_enqueue_line(*console, "  marker  一二三  ");
    APP.cli_enqueue_line(*console, "missing");
    APP.cli_update(*console);

    expect(state, marker.hits == 1 && marker.last == "一二三", "UTF-8 参数与内部空格保留：%", marker.last);
    expect(state, console.history.count == 1, "未知命令不入历史，实际 %", console.history.count);
    expect(state, console.history[0] == "marker  一二三", "历史记录 trim 后的原文：%", console.history[0]);
}

// 顺序：入列的先后就是执行的先后；handler 期间新到的留到下一次 update。
cli_order_and_deferred_enqueue :: (state: *Test_State) {
    console: APP.Cli_Console;
    APP.cli_init(*console);
    defer APP.cli_dispose(*console);

    chain: App_Test_Chain;
    chain.console = *console;
    defer app_test_chain_dispose(*chain);
    APP.cli_register(*console, "chain", "链式入列", app_test_chain_handler, *chain);

    APP.cli_enqueue_line(*console, "chain one");
    APP.cli_enqueue_line(*console, "chain two");
    APP.cli_update(*console);
    expect(state, chain.lines.count == 2 && chain.lines[0] == "one" && chain.lines[1] == "two",
           "同一批按入列顺序执行：%", chain.lines);

    APP.cli_enqueue_line(*console, "chain kick");
    APP.cli_update(*console);
    expect(state, chain.lines.count == 3, "handler 里入列的行本次不执行，实际 %", chain.lines.count);
    APP.cli_update(*console);
    expect(state, chain.lines.count == 4 && chain.lines[3] == "second", "下一次 update 才执行：%", chain.lines);

    // 命令名按 ASCII 不区分大小写，参数不动。
    APP.cli_enqueue_line(*console, "CHAIN MiXeD 大小写");
    APP.cli_update(*console);
    expect(state, chain.lines.count == 5 && chain.lines[4] == "MiXeD 大小写",
           "命令名不区分大小写、参数原样：%", chain.lines[4]);
}
//@endregion
