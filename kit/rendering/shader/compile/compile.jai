// compile —— 离线与开发编译共用的原生工具链；不依赖 jfoster、材质或监听器。
// 一比一移植自 olib kit/rendering/shader/compile/compile.odin。
//
// ============================ 工具链可用性（先读这段） ============================
// olib 用 odin 的 os.process_exec 直接跑 shadercross / dxc；jfoster + JaiLib 侧
// **没有这条工具链**：仓库里既不带 shadercross/dxc 可执行文件，kit 层也不链接进程启动代码。
// 本包把「跑外部进程」抽成一个**可注入的过程指针**（Command_Run / compile_set_command_run），
// 因此下面这些路径分成「可编译 + 可运行」与「只能编译、运行期明确失败」两类：
//
//   可用（不碰外部进程，纯数据 / 纯文件系统）：
//     POLICY、identify、identify_tool（路径解析 + PATH 查找 + 可执行文件与相邻动态库的内容指纹）、
//     bytes_hash、commands（命令行生成）、run 的错误包装（未注入执行器时的诊断文本）。
//   不可用（必须真的启动编译器，运行期返回明确诊断而不是崩溃）：
//     stage_compile（SPIR-V/DXIL/MSL 产物）、reflect（shadercross 的 SPIRV->JSON 反射）、
//     以及建立在其上的 kit/rendering/shader/dev 的 compile()。
//
// 宿主想真正编译时，注入一个执行器即可，例如用 JaiLib 自己的 core/devbuild：
//
//     shader_compile_set_command_run((command: [] string) -> (int, string, string) {
//         state, out, errout, err := devbuild.exec({ command = command }, temp);
//         if err == .Launch_Failed return -1, out, errout;
//         return state.exit_code, out, errout;
//     });
//
// 注入前后 POLICY 与命令文本完全相同（回归靠 tests 的 commands 用例守着），
// 所以「能编译的这一半」不会因为工具缺失而漂移。
// ==============================================================================
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                                   | JaiLib (Jai)                                            |
//   | --------------------------------------------- | ------------------------------------------------------- |
//   | POLYGON 常量用 `+` 拼接多段字符串               | 单个长字面量（Jai 的 string 没有 +）                      |
//   | os.get_env("PATH", temp)                      | ENV.environment_variable("PATH")（本来就在 temp）         |
//   | filepath.ext / dir / base / abs / join        | STRING.path_extension / path_strip_filename /            |
//   |                                               | path_filename / FILE.get_absolute_path / path_join       |
//   | os.is_file / os.exists / os.remove            | FU.file_exists / FILE.file_delete                        |
//   | os.remove 返回 os.Error                       | file_delete 返回 bool                                    |
//   | read_all_directory_by_path + Dir_Entry        | FU.file_list(dir)（只列文件，含全名）                      |
//   | os.read_entire_file(path, heap)               | FILE.read_entire_file(path)（归 context.allocator）       |
//   | slice.sort(files[:])                          | SORT.quick_sort(files, compare_strings)                  |
//   | fmt.aprintf("%016x", h)                       | compile_hex16（jacket 的 % 无宽度/进制说明符）             |
//   | devbuild.exec(...)                            | tool_command_run 过程指针（默认 null = 未注入）           |
//   | make([][]string, n) + copy                    | NewArray(n, []string) + copy_string                      |
//   | delete(x) / delete(x.data)                    | free(x.data)（先判 null）                                 |
//   | 返回值归 allocator                            | 同上：identify/commands 归 allocator_in，诊断借用 temp     |
#import "Basic";

//@region 策略与工具身份

// 默认保持已发布资产的路径；Direct 必须对 vertex/fragment 一起使用，不做失败回退。
Dxil :: enum u8 {
    Spirv;
    Direct;
}

Options :: struct {
    dxil: Dxil;
    shadercross: string; // 空值从 PATH 查找。
    dxc: string;
}

// 修改任何固定参数或命令生成规则时必须更新此值。
POLICY :: "olib-shader-1;spv=shadercross:HLSL:SPIRV;msl=shadercross:SPIRV:MSL;legacy=shadercross:SPIRV:DXIL;direct=dxc:-T:vs_6_0/ps_6_0:-E:vertex_main/fragment_main:-HV:2021:-O3:-Ges;reflect=shadercross:SPIRV:JSON";

Tool :: struct {
    path: string;
    version: string; // executable + 相邻动态库的内容身份，shadercross CLI 无版本查询接口。
}

Identity :: struct {
    policy: string;
    dxil: string;
    shadercross: Tool;
    dxc: Tool;
}

Toolchain :: struct {
    options: Options;
    identity: Identity;
}

//@endregion

//@region 外部进程注入（olib 直接调用 devbuild.exec）

// 命令执行器：返回退出码与两条输出流，起不来返回 -1。stdout/stderr 归实现方（通常 temp）。
Command_Run :: (command: [] string) -> (exit_code: int, out: string, errout: string);

// olib 里 exec 是直接调用；这里默认没有执行器，run() 因此总是给出明确诊断。
command_runner: Command_Run = null;

// 注入/清空执行器（null 恢复「未注入」状态）。进程内全局，注入一次即可。
shader_compile_set_command_run :: (runner: Command_Run) {
    command_runner = runner;
}

// 未注入执行器时的诊断尾注：说明缺的是哪一环，而不是把空输出说成编译器错误。
COMPILER_UNAVAILABLE :: "kit/rendering/shader/compile: no external process runner installed; call shader_compile_set_command_run with a runner that executes shadercross/dxc (jfoster/JaiLib does not ship that toolchain)";

//@endregion

//@region 哈希（FNV-1a 64，与 olib 逐位相同）

// 单个 u64 的 16 位小写十六进制：olib 用 fmt 的 "%016x"，jacket 的 % 没有宽度/进制说明符。
compile_hex16 :: (value: u64) -> string {
    digits := "0123456789abcdef";
    buffer: [16] u8;
    rest := value;
    // jacket 的降序 range（15..0）是空循环，改为升序 + 反向下标。
    for i: 0..15 {
        buffer[15 - i] = digits[cast(int) (rest & 0xf)];
        rest = rest >> 4;
    }
    return tprint("%", string.{ 16, buffer.data });
}

// olib 的 h = (h ~ b) * prime 循环；base 是 FNV-1a 64 的 offset basis。
compile_fnv1a_update :: (hash: u64, bytes: [] u8) -> u64 {
    h := hash;
    for b: bytes h = (h ^ cast(u64) b) * 0x100000001b3;
    return h;
}

// 不忽略二进制中的 CR；只用于完整产物/工具字节，源码换行策略由拥有者决定。
// 返回数据归 allocator_in（olib 也是 aprintf 到 allocator）。
bytes_hash :: (data: [] u8, allocator_in: Allocator = context.allocator) -> string {
    allocator := allocator_in;
    h := compile_fnv1a_update(0xcbf29ce484222325, data);
    push_allocator(allocator);
    return copy_string(compile_hex16(h));
}

//@endregion

//@region 工具身份

// 返回数据归 allocator_in。调用方可用独占 arena 一次释放；不会改写 Options 或全局环境。
// 返回 (tc, error)；成功时 error 为空。
identify :: (options: Options, allocator_in: Allocator = context.allocator) -> (tc: Toolchain, error: string) {
    allocator := allocator_in;
    push_allocator(allocator);
    tc.options = options;
    tc.identity.policy = POLICY;
    if options.dxil == .Direct tc.identity.dxil = "direct";
    else tc.identity.dxil = "spirv";
    tc.identity.shadercross, error = identify_tool(options.shadercross, "shadercross");
    if error != "" return tc, error;
    if options.dxil == .Direct {
        tc.identity.dxc, error = identify_tool(options.dxc, "dxc");
    }
    return tc, error;
}

// 工具版本用内容身份而非时间戳；依赖目录须自包含，系统图形驱动不属于编译指纹。
// 返回 (tool, error)；成功时 error 为空，tool 的字符串归当前 allocator。
identify_tool :: (requested: string, fallback: string) -> (tool: Tool, error: string) {
    name := fallback;
    if requested != "" name = requested;
    path := name;
    #if OS == .WINDOWS {
        ext, found_extension := STRING.path_extension(path);
        if !found_extension path = tprint("%.exe", path);
    }
    directory := STRING.path_strip_filename(path);
    if directory == "" || directory == "." || directory == "./" {
        separator: u8 = #char ";";
        #if OS != .WINDOWS separator = #char ":";
        found := false;
        // PATH 拆分只在 temp 里做（每次 identify 都要扫一遍，不能落进调用方 allocator）。
        {
            push_allocator(temp);
            search_path := ENV.environment_variable("PATH");
            for entry: STRING.split(search_path, separator) {
                if entry.count == 0 continue;
                candidate := STRING.path_join(entry, path);
                if FU.file_exists(candidate) {
                    path = candidate;
                    found = true;
                    break;
                }
            }
        }
        if !found return Tool.{}, tprint("Cannot find compiler % on PATH", name);
    }
    absolute, resolved := FILE.get_absolute_path(path);
    if !resolved || !FU.file_exists(absolute) return Tool.{}, tprint("Cannot find compiler %", name);

    // 可执行文件 + 同目录的分发动态库；排序后逐个并入指纹（文件名参与，目录顺序无关）。
    files: [..] string;
    array_add(*files, copy_string(absolute));
    siblings := FU.file_list(STRING.path_strip_filename(absolute));
    for entry: siblings {
        lower := STRING.to_lower_copy(STRING.path_filename(entry));
        is_library := STRING.ends_with(lower, ".dll") || STRING.ends_with(lower, ".dylib") ||
                      STRING.ends_with(lower, ".so") || STRING.contains(lower, ".so.");
        if is_library array_add(*files, copy_string(entry));
        free(lower.data);
        free(entry.data);
    }
    if siblings.data != null free(siblings.data);
    SORT.quick_sort(files, (a: string, b: string) -> s64 { return SORT.compare_strings(a, b); });

    h: u64 = 0xcbf29ce484222325;
    failure: string;
    for file: files {
        data, readable := FILE.read_entire_file(file);
        if !readable {
            failure = tprint("Cannot identify compiler dependency %", file);
            break;
        }
        for b: STRING.path_filename(file) h = (h ^ cast(u64) b) * 0x100000001b3;
        h = (h ^ cast(u64) data.count) * 0x100000001b3;
        for b: data h = (h ^ cast(u64) b) * 0x100000001b3;
        if data.data != null free(data.data);
    }
    for file: files if file.data != null free(file.data);
    if files.data != null free(files.data);
    if failure != "" return Tool.{}, failure;

    return Tool.{ copy_string(absolute), tprint("distribution-fnv1a64:%", compile_hex16(h)) }, "";
}

//@endregion

//@region 阶段编译与诊断

// 生成命令是唯一参数来源；不接受任意附加 flags，避免两个入口的隐式差异。
// base 为带阶段名、不带扩展名的输出路径。始终先生成 SPIR-V（包括 Direct 的资源反射）。
// 返回的每一行都是独立拥有的 [] string，用 command_list_free 释放。
commands :: (tc: Toolchain, source: string, include: string, stage: string, base: string,
             dxil: bool, msl: bool, allocator_in: Allocator = context.allocator) -> [] [] string {
    allocator := allocator_in;
    push_allocator(allocator);

    entry := tprint("%_main", stage);
    spv := tprint("%.spv", base);
    list: [..][] string;
    cross := tc.identity.shadercross.path;
    array_add(*list, command_make(cross, source, "-s", "HLSL", "-d", "SPIRV", "-t", stage,
                                 "-e", entry, "-I", include, "-o", spv));
    if dxil {
        output := tprint("%.dxil", base);
        if tc.options.dxil == .Direct {
            profile := "ps_6_0";
            if stage == "vertex" profile = "vs_6_0";
            array_add(*list, command_make(tc.identity.dxc.path, source, "-T", profile, "-E", entry,
                                         "-HV", "2021", "-O3", "-Ges", "-I", include, "-Fo", output));
        } else {
            array_add(*list, command_make(cross, spv, "-s", "SPIRV", "-d", "DXIL", "-t", stage,
                                         "-e", entry, "-o", output));
        }
    }
    if msl {
        array_add(*list, command_make(cross, spv, "-s", "SPIRV", "-d", "MSL", "-t", stage,
                                     "-e", entry, "-o", tprint("%.msl", base)));
    }

    result: [] [] string;
    result, _ = NewArray(list.count, [] string);
    for row, i: list result[i] = row;
    if list.data != null free(list.data);
    return result;
}

// olib 的 make([]string, len) + copy：每个参数都复制到当前 allocator。
command_make :: (arguments: ..string) -> [] string {
    result: [] string;
    result, _ = NewArray(arguments.count, string);
    for argument, i: arguments result[i] = copy_string(argument);
    return result;
}

// commands 的结果释放（olib 侧 delete(rows)）。
command_list_free :: (rows: [] [] string, allocator: Allocator = context.allocator) {
    for row: rows {
        for argument: row if argument.data != null allocator.proc(.FREE, 0, 0, argument.data, allocator.data);
        if row.data != null allocator.proc(.FREE, 0, 0, row.data, allocator.data);
    }
    if rows.data != null allocator.proc(.FREE, 0, 0, rows.data, allocator.data);
}

// 供诊断用的单行命令文本（借用 temp）。
command_line :: (command: [] string) -> string {
    line: string;
    {
        push_allocator(temp);
        line = STRING.join(..command, separator = " ");
    }
    return line;
}

// 逐条执行；任何一步失败都返回诊断（借用 temp），成功返回空串。
// 未注入执行器时 run() 一定失败，因此本过程在 jfoster/JaiLib 里是「可编译、运行期不可用」。
stage_compile :: (tc: Toolchain, source: string, include: string, stage: string, base: string,
                  dxil: bool, msl: bool) -> string {
    if stage != "vertex" && stage != "fragment" return "Unsupported shader stage";
    rows := commands(tc, source, include, stage, base, dxil, msl, temp);
    defer command_list_free(rows, temp);
    for command: rows {
        output := command[command.count - 1];
        if FU.file_exists(output) {
            if !FILE.file_delete(output) return tprint("Cannot invalidate compiler output %", output);
        }
        error := run(command);
        if error != "" return error;
        data, readable := FILE.read_entire_file(output);
        if !readable || data.count == 0 return tprint("Compiler produced no output: %", output);
        if data.data != null free(data.data);
    }
    return "";
}

// 反射（shadercross 的 SPIRV->JSON）：同样需要真实工具链。
reflect :: (tc: Toolchain, spv: string, stage: string, output: string) -> string {
    return run(command_make(tc.identity.shadercross.path, spv, "-s", "SPIRV", "-d", "JSON",
                            "-t", stage, "-o", output));
}

// 所有子进程共用宿主的执行器；错误包含完整命令、退出码及两条输出流。
// 成功返回空串；诊断借用 temp（调用方需要保留就自己复制）。
run :: (command: [] string) -> string {
    if command_runner == null {
        return tprint("Shader compiler failed (%, exit %)\n%\n%\n", "no process runner", -1,
                      command_line(command), COMPILER_UNAVAILABLE);
    }
    exit_code, out, errout := command_runner(command);
    if exit_code != 0 || STRING.contains(errout, "error:") || STRING.contains(out, "error:") {
        return tprint("Shader compiler failed (exit %)\n%\n%%", exit_code, command_line(command),
                      out, errout);
    }
    return "";
}

//@endregion
