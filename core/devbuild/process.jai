// process —— 开发期编译子进程的共享入口。只在后台线程使用，不要阻塞游戏帧。
// 一比一移植自 olib core/devbuild/process.odin。
//
// odin:os.process_start 会修改句柄继承属性，不支持并发；游戏 DLL、Shader 与参数生成器
// 共用这把锁，exec 的结果归调用方的 allocator。子进程不经过 shell。
//
// Jai 侧差异（行为不变，逐条对应 olib）：
//   - odin 的 sync.Mutex 零值即可用；jacket 的 Thread.Mutex（Windows 下是临界区）必须先
//     init。这里用 jacket 的 Atomics 做一个零值即可用的「命名互斥体」process_mutex：第一个
//     调用的线程用 compare_and_swap 抢到建立权，init 一次（名字 "devbuild.process_mutex"
//     只在 THREAD_DEBUG 构建里给调试器看），其余线程等它就绪再 lock。互斥语义与 odin 相同：
//     同一时刻只有一个线程在 exec 之内，且可重入（Windows 临界区本来就允许同线程重入）。
//     互斥体是进程内唯一的包级变量，与 odin 的 @(private) process_mutex 一样不跨进程；
//   - 四返回值 (state, stdout, stderr, err) 的形态保留，但类型换成 Jai 能表达的：
//     os.Process_State → Process_State（只用 odin 侧读的 exited / exit_code 两个字段），
//     os.Error → Process_Error（Jai 的 IO 不返回错误对象，只可能失败在「进程起不来」，
//     所以枚举只有 None / Launch_Failed，None 对应 odin 的 err == nil）；
//   - os.Process_Desc 的字段 (working_dir, command) 原样保留。command 仍是切片 [] string
//     （odin 的 []string）；jacket 的 run_command 收 ..string，exec 内部摊平成动态数组；
//   - os.process_exec → jacket 的 Process.run_command(capture_and_return_output = true)：
//     两者都把子进程 stdout/stderr 全量收进返回的字符串（归传入的 allocator），都不经过
//     shell，都以「启动失败」表示起不来；
//   - 超时：odin 的 process_exec 没有超时；jacket 的 run_command 有 timeout_ms。这里不传
//     （默认 -1，等到进程结束），行为与 olib 一致：绝对不设期限。run_command 的
//     timeout_reached 因此必然为 false，用 `_` 丢弃；
//   - 空 command：odin 会让 process_exec 返回 err；jacket 的 run_command 在空参数上不可
//     依赖，这里显式按 Launch_Failed 返回（不 bring down 断言），语义相同。
#import "Basic";
THREAD :: #import "Thread";
ATOMICS :: #import "Atomics";
PROC :: #import "Process";

//@region 描述与结果

// 对应 odin 的 os.Process_Desc（本模块只用这两个字段）。
Process_Desc :: struct {
    working_dir: string;
    command: [] string;
}

// 对应 odin 的 os.Process_State 里 exec 的调用方会读的部分。
Process_State :: struct {
    exited: bool;
    exit_code: int;
}

// 对应 odin 的 os.Error：None 即 err == nil。
Process_Error :: enum u8 {
    None;
    Launch_Failed;
}
//@endregion

//@region 命名互斥体

// 建立状态：0 = 未建立，1 = 建立中，2 = 已建立。
process_mutex_state: s32;
// 命名互斥体本身（odin 的 process_mutex: sync.Mutex）。
process_mutex: THREAD.Mutex;

// 零值即可用的命名互斥体：首次调用时 init 一次，之后复用。
process_mutex_get :: () -> *THREAD.Mutex {
    state := ATOMICS.atomic_read(*process_mutex_state);
    if state == 2 return *process_mutex;
    if state == 0 && compare_and_swap(*process_mutex_state, 0, 1) {
        THREAD.init(*process_mutex, "devbuild.process_mutex");
        ATOMICS.atomic_write(*process_mutex_state, 2);
        return *process_mutex;
    }
    // 另一个线程正在建立（只有几条指令的窗口）：等它就绪。
    while ATOMICS.atomic_read(*process_mutex_state) != 2 {}
    return *process_mutex;
}
//@endregion

// 与 olib 的 exec 同形：串行化子进程启动，结果（stdout/stderr）归 allocator。
exec :: (desc: Process_Desc, allocator: Allocator = context.allocator) -> (Process_State, string, string, Process_Error) {
    mutex := process_mutex_get();
    THREAD.lock(mutex);
    defer THREAD.unlock(mutex);

    if desc.command.count == 0 {
        return Process_State.{ exited = false, exit_code = -1 }, "", "", .Launch_Failed;
    }

    push_allocator(allocator);

    command: [..] string;
    for argument: desc.command {
        array_add(*command, argument);
    }

    result, out, errout, _ := PROC.run_command(
        ..command,
        working_directory = desc.working_dir,
        capture_and_return_output = true,
    );

    state := Process_State.{ exited = result.type == .EXITED, exit_code = cast(int) result.exit_code };
    if result.type == .FAILED_TO_LAUNCH {
        return state, out, errout, .Launch_Failed;
    }
    return state, out, errout, .None;
}
