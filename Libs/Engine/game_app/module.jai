#scope_module
Basic :: #import "Basic";
using Basic;
F :: #import "jfoster";
S :: #import "String";
TH :: #import "Thread"(LOAD_THREAD_GROUP = false);
#scope_export

// DragonLib Engine/GameApp.cs. Jai callbacks replace the inherited App methods.
// Like the C# class, this owns no renderer, fonts, scenes, or game resources.
Game_App :: struct {
    config: F.App_Config;
    startup: () = null;
    update: () = null;
    render: () = null;
    shutdown: () = null;
    cli: *Cli_Console;
}

game_app_has_arg :: (args: [] string, name: string) -> bool {
    for args if S.equal_nocase(it, name) return true;
    return false;
}

game_app_apply_cli_args :: (config: F.App_Config, args: [] string) -> F.App_Config {
    result := config;
    if game_app_has_arg(args, "--no-focus") result.flags |= .NO_WINDOW_FOCUS;
    return result;
}

game_app_enable_cli :: (app: *Game_App) -> *Cli_Console {
    if app.cli == null {
        app.cli = New(Cli_Console);
        TH.init(*app.cli.mutex);
        cli_register(app.cli, "help", "列出全部命令", cli_help, app.cli);
        cli_register(app.cli, "quit", "退出程序", cli_quit);
        cli_register(app.cli, "history", "输出完整日志历史", cli_history);
    }
    cli_start(app.cli);
    return app.cli;
}

game_app_run :: (app: *Game_App) {
    assert(active_app == null, "jfoster supports one active application");
    active_app = app;
    defer active_app = null;
    F.App.startup = app_startup;
    F.App.update = app_update;
    F.App.render = app_render;
    F.App.shutdown = app_shutdown;
    F.app_run(app.config);
}

// Call after run returns, while app and command handler data are still alive.
game_app_destroy :: (app: *Game_App) {
    assert(active_app != app, "Cannot destroy a running application");
    if app.cli != null {
        cli_stop(app.cli);
        for app.cli.commands { free(it.name.data); free(it.description.data); }
        array_free(app.cli.commands);
        for app.cli.pending free(it.data);
        array_free(app.cli.pending);
        TH.destroy(*app.cli.mutex);
        free(app.cli);
        app.cli = null;
    }
    F.app_destroy();
    F.App.startup = null; F.App.update = null;
    F.App.render = null; F.App.shutdown = null;
}

// DragonLib Engine/Core/CliConsole.cs. Handler args are borrowed for the call.
// The optional data pointer replaces a C# delegate's captured instance.
Cli_Command_Handler :: #type (args: string, data: *void);
Cli_Command :: struct {
    name: string;
    description: string;
    handler: Cli_Command_Handler;
    data: *void;
}
Cli_Console :: struct {
    commands: [..] Cli_Command;
    thread: TH.Thread;
    mutex: TH.Mutex;
    pending: [..] string;
    started: bool;
    joined: bool;
    running: bool;
}

// Register before Start or on the application's main thread; replaces by name.
cli_register :: (cli: *Cli_Console, name: string, description: string, handler: Cli_Command_Handler, data: *void = null) {
    assert(handler != null);
    for *command: cli.commands if S.equal_nocase(command.name, name) {
        free(command.description.data);
        command.description = copy_string(description);
        command.handler = handler; command.data = data;
        return;
    }
    array_add(*cli.commands, .{copy_string(name), copy_string(description), handler, data});
}

cli_start :: (cli: *Cli_Console) {
    if cli.started return;
    cli.running = true;
    if !TH.thread_init(*cli.thread, cli_loop) {
        cli.running = false;
        F.log_warning("[cli] 无法启动 stdin 读取线程");
        return;
    }
    cli.thread.data = cli;
    cli.started = true;
    TH.thread_start(*cli.thread);
    F.log_info("[cli] CLI 调试控制台已启动,输入 help 查看命令");
}

cli_stop :: (cli: *Cli_Console) {
    if !cli.started || cli.joined return;
    TH.lock(*cli.mutex); cli.running = false; TH.unlock(*cli.mutex);
    // Unlike a GC-managed background thread, this thread must finish before free.
    #if OS == .WINDOWS {
        while !TH.thread_is_done(*cli.thread) {
            _ := CancelSynchronousIo(cli.thread.windows_thread);
            _ := TH.thread_is_done(*cli.thread, 20);
        }
    } else {
        _ := TH.thread_is_done(*cli.thread, -1);
    }
    TH.thread_deinit(*cli.thread);
    cli.joined = true;
    // Keep started true: DragonLib Start is idempotent, including after Stop.
}

#scope_module
active_app: *Game_App;
app_startup :: () { if active_app.startup != null active_app.startup(); }
app_update :: () {
    if active_app.cli != null cli_drain(active_app.cli);
    if active_app.update != null active_app.update();
}
app_render :: () { if active_app.render != null active_app.render(); }
app_shutdown :: () {
    if active_app.cli != null { cli_stop(active_app.cli); cli_drain(active_app.cli); }
    if active_app.shutdown != null active_app.shutdown();
}

cli_is_running :: (cli: *Cli_Console) -> bool {
    TH.lock(*cli.mutex); defer TH.unlock(*cli.mutex);
    return cli.running;
}
cli_queue :: (cli: *Cli_Console, line: string) {
    trimmed := S.trim(line);
    if trimmed.count == 0 return;
    TH.lock(*cli.mutex); defer TH.unlock(*cli.mutex);
    if cli.running array_add(*cli.pending, copy_string(trimmed));
}
cli_drain :: (cli: *Cli_Console) {
    // jfoster's main-thread queue is initialized by app_run. Use an owned queue
    // here so EnableCli before Run has the same first-frame behavior as C#.
    TH.lock(*cli.mutex);
    pending := cli.pending;
    empty: [..] string;
    cli.pending = empty;
    TH.unlock(*cli.mutex);
    defer array_free(pending);
    for line: pending {
        defer free(line.data);
        separator := line.count;
        for byte, index: line if byte == #char " " { separator = index; break; }
        name := S.slice(line, 0, separator);
        args := ifx separator < line.count then S.trim(S.slice(line, separator + 1, line.count - separator - 1)) else "";
        found := false;
        for command: cli.commands if S.equal_nocase(command.name, name) {
            command.handler(args, command.data);
            found = true; break;
        }
        if !found F.log_warning(tprint("[cli] 未知命令 '%',输入 help 查看命令列表", name));
    }
}
cli_help :: (args: string, data: *void) {
    cli := cast(*Cli_Console) data;
    builder: String_Builder;
    defer free_buffers(*builder);
    append(*builder, "[cli] 命令列表:");
    for cli.commands append(*builder, tprint("\n  %  %", it.name, it.description));
    text := builder_to_string(*builder); defer free(text.data);
    F.log_info(text);
}
cli_quit :: (args: string, data: *void) { F.app_exit(); }
cli_history :: (args: string, data: *void) {
    history := F.log_get_history(); defer free(history.data);
    F.log_info(history);
}
cli_feed :: (cli: *Cli_Console, builder: *String_Builder, chunk: string) {
    for byte: chunk {
        if byte == #char "\n" {
            line := builder_to_string(builder); defer free(line.data);
            cli_queue(cli, line);
        } else append(builder, byte);
    }
}
cli_loop :: (thread: *TH.Thread) -> s64 {
    cli := cast(*Cli_Console) thread.data;
    builder: String_Builder;
    defer free_buffers(*builder);
    bytes: [1024] u8;
    #if OS == .WINDOWS {
        input := GetStdHandle(0xFFFFFFF6);
        mode: u32;
        console := GetConsoleMode(input, *mode) != 0;
        wide: [1024] u16;
        while cli_is_running(cli) {
            read: u32;
            if console {
                if ReadConsoleW(input, wide.data, 1024, *read, null) == 0 || read == 0 break;
                chunk, ok := WU.wide_to_utf8(wide.data, cast(s32) read);
                defer free(chunk.data);
                if ok cli_feed(cli, *builder, chunk);
            } else {
                if ReadFile(input, bytes.data, 1024, *read, null) == 0 || read == 0 break;
                cli_feed(cli, *builder, .{count = read, data = bytes.data});
            }
        }
    } else {
        while cli_is_running(cli) {
            fd: Poll_Fd = .{fd = 0, events = 1};
            ready := poll(*fd, 1, 100);
            if ready < 0 break;
            if ready == 0 continue;
            read := posix_read(0, bytes.data, 1024);
            if read <= 0 break;
            cli_feed(cli, *builder, .{count = read, data = bytes.data});
        }
    }
    line := builder_to_string(*builder); defer free(line.data);
    cli_queue(cli, line); // ReadLine returns a final line even without a newline.
    return 0;
}

#if OS == .WINDOWS {
    WU :: #import "Windows_Utf8";
    Kernel32 :: #system_library "kernel32";
    GetStdHandle :: (kind: u32) -> *void #foreign Kernel32;
    GetConsoleMode :: (handle: *void, mode: *u32) -> s32 #foreign Kernel32;
    ReadConsoleW :: (handle: *void, buffer: *u16, size: u32, read: *u32, reserved: *void) -> s32 #foreign Kernel32;
    ReadFile :: (handle: *void, buffer: *u8, size: u32, read: *u32, overlapped: *void) -> s32 #foreign Kernel32;
    CancelSynchronousIo :: (thread: *void) -> s32 #foreign Kernel32;
} else {
    Libc :: #system_library "c";
    Poll_Fd :: struct { fd: s32; events: s16; revents: s16; }
    poll :: (fds: *Poll_Fd, count: u64, timeout: s32) -> s32 #foreign Libc;
    posix_read :: (fd: s32, buffer: *u8, size: u64) -> s64 #foreign Libc "read";
}
