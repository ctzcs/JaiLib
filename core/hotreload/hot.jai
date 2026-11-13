// hot —— 宿主侧的一站式入口：把 Session、Watch 和「检查编译 → 等 GPU → 替换 →
// 转发 update/render」收成四个调用。需要自定义编译命令、替换策略或更细的控制时，
// 直接用 Session / Watch。一比一移植自 olib core/hotreload/hot.odin。
//
// **编译器命令行（重要）**：`hot_command` 拼的仍然是 odin 的命令行
// （`odin build <source> -build-mode:dll -collection:名字=路径 ... -out:{output}`），
// 这是 olib 的原样行为，本文件不改写它。Jai 侧由调用方传自己的构建入口：
// Watch_Config.command 是 `[] string`，完全由调用方决定。
//
// jaic 的命令行没有共享库开关，但**能**产出 DLL：用 Compiler 元编程 API 建一个工作区，
// 设 `Build_Options.output_type = .DYNAMIC_LIBRARY`，编译那个脚本就会在编译期写出 .dll
// （见示例 `JaiLibSample/src/hotreload/build.jai`）。所以 Jai 侧的 command 通常是
// `jaic -import_dir <lib> -exe build/hot_build <project>/hot/build.jai`，再由 Session
// 加载产物；正在运行的模块被映射着，重编要写新文件名，加载成功后再 FreeLibrary 旧的。
//
// Jai 侧差异（行为不变）：
//   - odin 的 `@(private) hot_command` 在 Jai 里没有包内私有，靠 hot_ 前缀约定；
//     测试同 olib 一样直接调它（见 Tests/core/hotreload/hotreload_test.jai）；
//   - odin 的 `append(&roots, ..config.roots)` → 没有 array_add_all，手写循环；
//     roots 用临时动态数组（odin 的 temp_allocator），用完 deinit 掉，watch_init 会复制；
//   - odin 的 `h^ = {}` → `h.* = Hot.{}`；取址 `&x` → `*x`；
//   - `fmt.printfln` → print；`fmt.eprintln` → print(.., to_standard_error = true)，
//     输出的内容与 odin 相同（诊断仍走 stderr）；
//   - odin 的三元 `a ? b : c` → `ifx a then b else c`；
//   - 新增 `hot_command_free`：odin 的命令行数组分配在 temp_allocator 上自动回收，
//     Jai 没有那种回收点，所以显式释放（hot_init 内部自己调，测试里也可以调）。
#import "Basic";

Hot_Config :: struct {
    source: string;         // 游戏模块的源码包目录，相对 working_directory
    collections: [] string; // "名字=路径"，如 {"olib=../olib"}，传给 -collection:
    args: [] string;        // 额外的编译参数，如 {"-vet"}
    pre_command: [] string; // 每次编译前运行的命令，如代码生成器；见 Watch_Config
    roots: [] string;       // 除 source 外还要监听的目录或文件（#load 的数据、共享包等）
    working_directory: string; // 空为当前目录
    services: *void;           // 宿主服务，原样交给游戏模块；地址必须稳定
    host_version: u64;         // 宿主协议版本，0 视为 1；协议或共享类型变化时加一
    // 新版本替换旧版本之前调用（帧开始，旧模块尚在）：通常在这里等 GPU 空闲。
    before_swap: (user_data: *void) -> void;
    user_data: *void;
    quiet: bool; // true 时不向终端输出 LIVE 版本号和编译错误
    // .Manual 不监听源码：启动时编译一次，之后调用 hot_retry 或修改 trigger_file 才编译。
    mode: Watch_Mode;
    trigger_file: string;
}

// 地址必须稳定（放在宿主堆分配状态中），不要复制。
Hot :: struct {
    session: Session;
    watch: Watch;
    version: u64; // 当前已加载的模块版本，0 表示还没有成功加载
    before_swap: (user_data: *void) -> void;
    user_data: *void;
    quiet: bool;
    last_status: Build_Status;
}

//@region 生命周期

// 失败时保持 h 未初始化。
hot_init :: (h: *Hot, config: Hot_Config) -> bool {
    if h.session.initialized || config.source.count == 0 return false;
    push_allocator(context.default_allocator);
    version := config.host_version;
    if version == 0 version = 1;
    if !init(*h.session, version, config.services) return false;
    // odin: roots := make([dynamic]string, context.temp_allocator);
    //       append(&roots, config.source); append(&roots, ..config.roots)
    roots: [..] string;
    array_add(*roots, config.source);
    // Jai 没有 array_add_all：手写逐个追加，顺序与 odin 相同（source 在最前）。
    for root: config.roots {
        array_add(*roots, root);
    }
    defer array_reset(*roots); // watch_init 复制了这些字符串，临时数组到此为止。
    command := hot_command(config);
    defer hot_command_free(*command);
    if !watch_init(*h.watch, Watch_Config.{
            command = command,
            pre_command = config.pre_command,
            working_directory = config.working_directory,
            roots = roots,
            mode = config.mode,
            trigger_file = config.trigger_file,
        }) {
        _ = dispose(*h.session);
        return false;
    }
    h.before_swap = config.before_swap;
    h.user_data = config.user_data;
    h.quiet = config.quiet;
    if !h.quiet {
        hint := ifx config.mode == .Manual then "call hot_retry to reload" else "edit and save to reload";
        print("hotreload: compiling % ... %\n", config.source, hint);
    }
    return true;
}

// 先卸载游戏模块，再等待编译任务结束。
hot_dispose :: (h: *Hot) {
    _ = dispose(*h.session);
    watch_dispose(*h.watch);
    h.* = Hot.{};
}
//@endregion

//@region 帧循环

// 放在宿主 UpdateProc 的开头：检查编译结果，成功就替换模块，然后转发游戏的 update。
hot_update :: (h: *Hot, dt: float64, frame: *void = null) {
    watch_update(*h.watch, dt);
    if h.watch.status == .Ready {
        if h.before_swap != null h.before_swap(h.user_data);
        result := watch_apply(*h.watch, *h.session);
        h.last_status = h.watch.status;
        if result == .Success {
            h.version = h.session.revision;
            if !h.quiet print("hotreload: LIVE version %\n", h.version);
        } else if !h.quiet && result != .Busy {
            print("%\n", h.session.diagnostic, to_standard_error = true);
        }
    }
    if h.watch.status == .Error && h.last_status != .Error && !h.quiet {
        print("%\n", h.watch.diagnostic, to_standard_error = true);
    }
    h.last_status = h.watch.status;
    update(*h.session, dt, frame);
}

// 放在宿主 RenderProc：转发游戏的 render。
hot_render :: (h: *Hot, dt: float64, frame: *void = null) {
    render(*h.session, dt, frame);
}
//@endregion

//@region 查询与重试

// 最近一次失败的原因（编译错误或加载被拒）；没有失败时为空。借用，下一次 hot_update 后失效。
hot_error :: (h: *Hot) -> string {
    if h.watch.status == .Error return h.watch.diagnostic;
    return "";
}

// 编译当前源码：Auto 用于修好编译环境而源码没变时重试，Manual 就是手动触发。
hot_retry :: (h: *Hot) {
    watch_retry(*h.watch);
}
//@endregion

//@region 命令行

// 用 context.allocator 分配；元素与数组都归调用方（hot_command_free），watch_init 会复制。
// 拼法是 olib 的原样 odin 命令行 —— 见文件头「编译器命令行」。
hot_command :: (config: Hot_Config) -> [] string {
    args: [..] string;
    array_add(*args, copy_string("odin"));
    array_add(*args, copy_string("build"));
    array_add(*args, copy_string(config.source));
    array_add(*args, copy_string("-build-mode:dll"));
    for collection: config.collections {
        // odin 这里是 fmt.tprintf（临时分配器代码，随作用域回收）；Jai 侧要能被 hot_command_free
        // 释放，所以用 sprint（context.allocator）。
        array_add(*args, sprint("-collection:%", collection));
    }
    for arg: config.args {
        array_add(*args, copy_string(arg));
    }
    array_add(*args, copy_string("-out:{output}"));
    return args;
}

// 释放 hot_command 的返回值（数组与每个元素）。
hot_command_free :: (args: *[] string) {
    for arg: args.* {
        if arg.data != null free(arg);
    }
    if args.data != null free(args.data);
    args.* = .{};
}
//@endregion
