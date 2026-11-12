// watch —— 源码监听 + 后台编译。文件扫描在 scan.jai 的后台线程里进行，主线程每帧只读取结果。
// 一比一移植自 olib core/hotreload/watch.odin。
//
// Jai 侧差异（本文件）：
//   - **默认扩展名从 `.odin` 换成 `.jai`**（本仓库监听的是 Jai 源码；字段语义不变）。
//   - odin 的 `context.allocator = runtime.heap_allocator()` 在本文件统一写成
//     push_allocator(context.default_allocator)：jacket 的 free 用**当前** allocator，push 之后
//     分配与释放落在同一把尺子上（odin 是显式传 allocator 给 delete）。
//   - `os.make_directory_temp(parent, "olib_hotreload_")` → 自己拼唯一目录名（计数器 + 单调纳秒）
//     再用 FILE.make_directory_if_it_does_not_exist 建；parent 为空时取 %TEMP%/%TMP%
//     （Extensions/Environment）。odin 会保证唯一，Jai 侧靠「先查存在再建」。
//   - `filepath.abs` → FILE.get_absolute_path（返回 (路径, ok)，分隔符统一 `/`）；
//     `filepath.dir` → STRING.path_strip_filename（**带结尾分隔符**），`filepath.stem` → 本文件的
//     watch_file_stem（截掉最后一个 `.` 之后的部分），拼 sidecar 路径时不补 `/`。
//   - `strings.replace_all(arg, "{output}", output, alloc)` → STRING.replace（总是新分配一份，
//     所以 odin 里 `allocated ? expanded : clone(expanded)` 的分支在 Jai 侧不需要）。
//   - `os.read_all_directory_by_path` + 逐个 remove → FU.file_list + FILE.file_delete；
//     `os.remove` → FILE.file_delete（返回 bool，失败时保留，与 odin 一致）。
//   - `thread.create/start/join/destroy` → New(Thread) + THREAD.thread_init/thread_start/
//     THREAD.thread_is_done(thread, -1)（-1 = 阻塞等待）/ THREAD.thread_deinit + free。
//     odin 的 thread.create 里带优先级参数，jacket 的 thread_init 没有，编译器线程不再降优先级
//     （扫描线程的降优先级在 scan.jai 里自己做，见那里）。
//   - `intrinsics.atomic_load/store` → ATOMICS.atomic_read/atomic_write。
//   - `time.sleep(time.Millisecond)` → sleep_milliseconds(1)。
//   - devbuild.exec({command, working_dir}, alloc) 的调用形状与 olib 相同（见 core/devbuild/process.jai）。
//   - odin 的 `fmt.aprintf`（分配在新内存）→ sprint（用当前 allocator）；需要长期持有就先 push。
//   - `max(dt, 0)` 在 Jai 里要写 `max(dt, 0.0)`（字面量是无类型整数）。
//   - odin 的 `w^ = {}` → `w.* = Watch.{}`；命名返回值（`watch_fingerprint`）照 odin 用多返回值。
#import "Basic";
W_ATOMICS :: #import "Atomics";
W_ENV :: #import "Extensions/Environment";
W_FILE :: #import "File";
W_FU :: #import "File_Utilities";
W_STRING :: #import "String";
W_THREAD :: #import "Thread";
DB :: #import "core/devbuild";

Build_Status :: enum u8 {
    Waiting;
    Compiling;
    Ready;
    Live;
    Error;
}

Watch_Mode :: enum u8 {
    Auto;   // 后台线程增量扫描 roots，保存后自动编译
    Manual; // 不扫描源码：启动时编译一次，之后由 watch_retry 或 trigger_file 触发
}

Watch_Config :: struct {
    // 参数数组，不经过 shell；至少一个参数含 {output}，如 -exe {output}。
    command: [] string;
    // 可选：每次编译前在同一后台线程运行，如代码生成器；失败则不编译。不展开 {output}。
    // 写入被监听文件时，这次编译结果作废并按新内容重编一次，所以内容不变时不要改写文件。
    pre_command: [] string;
    working_directory: string;
    // 显式列出游戏代码/共享定义/#load 资产所在目录或文件；不自动解析 import。Manual 可以为空。
    roots: [] string;
    extensions: [] string; // 空时只监听 .jai；显式文件不受扩展名过滤。
    cache_parent: string; // 空时使用系统临时目录；目录内依赖须由宿主/系统解决。
    poll_seconds: float64; // 后台扫描与触发文件的检查间隔；<=0 使用 0.25 秒。
    debounce_seconds: float64; // <=0 使用 0.25 秒。
    mode: Watch_Mode;
    // Manual：修改时间变化即触发编译，供编辑器任务或脚本使用；按 working_directory 解析，空为不用。
    trigger_file: string;
}

// 必须在常驻宿主中创建，地址稳定。只允许一个线程调用公开接口。
// 后台线程只扫描文件和编译，不调用模块/UI/GPU。持久内存固定使用宿主 default_allocator。
Watch :: struct {
    status: Build_Status;
    diagnostic: string;
    initialized: bool;
    mode: Watch_Mode;
    command: [] string;
    pre_command: [] string;
    roots: [] string;
    extensions: [] string;
    working_directory: string;
    cache: string;
    trigger_file: string;
    poll_seconds: float64;
    debounce_seconds: float64;
    poll: float64;
    stable: float64;
    observed: u64;
    attempted: u64;
    has_observed: bool;
    has_attempted: bool;
    build_invalidated: bool;
    verifying: bool; // 编译已结束，等待一次在其后开始的完整扫描确认源码未变
    verify_ticket: u64;
    pending: bool; // Manual：已请求编译
    trigger_modified: s64;
    generation: u64;
    worker: *W_THREAD.Thread;
    job: Build_Job;
    scanner: Scanner;
}

// olib 的 @(private) Build_Job。
Build_Job :: struct {
    command: [] string;
    pre_command: [] string;
    working_directory: string;
    output: string;
    fingerprint: u64;
    diagnostic: string;
    succeeded: bool;
    done: bool;
}

WATCH_UNREADABLE :: "Cannot read watched sources; live module retained";

//@region 生命周期

watch_init :: (w: *Watch, config: Watch_Config) -> bool {
    if w.initialized return false;
    push_allocator(context.default_allocator);
    w.* = Watch.{};
    if config.command.count == 0 || (config.mode == .Auto && config.roots.count == 0) return false;
    has_output := false;
    for arg: config.command {
        has_output = has_output || W_STRING.contains(arg, "{output}");
    }
    if !has_output return false;
    w.initialized = true;
    // odin: defer if !success do watch_dispose(w)。Jai 的 defer 留在同一块里也能改写 success，
    // 但这里用显式收尾，读起来更直白。
    if !watch_init_body(w, config) {
        watch_dispose(w);
        return false;
    }
    return true;
}

// watch_init 的实体；失败时由 watch_init 负责 watch_dispose（对应 odin 的 defer）。
watch_init_body :: (w: *Watch, config: Watch_Config) -> bool {
    w.mode = config.mode;
    w.command = watch_clone_strings(config.command);
    w.pre_command = watch_clone_strings(config.pre_command);
    if config.extensions.count == 0 {
        // odin: []string{".odin"}；Jai 侧默认监听 .jai。
        w.extensions.count = 1;
        w.extensions.data = cast(*string) alloc(1);
        w.extensions.data[0] = copy_string(".jai");
    } else {
        w.extensions = watch_clone_strings(config.extensions);
    }
    work := ifx config.working_directory.count == 0 then "." else config.working_directory;
    working_directory, resolved := W_FILE.get_absolute_path(work);
    if !resolved return false;
    w.working_directory = working_directory;
    w.roots.count = config.roots.count;
    if config.roots.count > 0 w.roots.data = cast(*string) alloc(config.roots.count);
    for root, i: config.roots {
        absolute, ok := watch_path(w.working_directory, root);
        if !ok return false;
        w.roots.data[i] = absolute;
    }
    if config.trigger_file.count > 0 {
        trigger, ok := watch_path(w.working_directory, config.trigger_file);
        if !ok return false;
        w.trigger_file = trigger;
        // 已有的触发文件不算请求，只有之后的修改才触发。
        entry, stat_ok := scan_stat(w.trigger_file);
        if stat_ok w.trigger_modified = entry.modified;
    }
    cache, cache_ok := watch_make_cache_directory(config.cache_parent);
    if !cache_ok return false;
    w.cache = cache;
    w.poll_seconds = ifx config.poll_seconds > 0 then config.poll_seconds else 0.25;
    w.debounce_seconds = ifx config.debounce_seconds > 0 then config.debounce_seconds else 0.25;
    scan_init(*w.scanner, w.roots, w.extensions, cast(s64) (w.poll_seconds * 1000000000.0));
    if w.mode == .Auto && !scan_start(*w.scanner) return false;
    w.pending = w.mode == .Manual; // 启动时还没有可运行的版本
    return true;
}

// 退出时停止扫描线程并等待正在运行的编译器完成；先 dispose Session，再 dispose Watch。
watch_dispose :: (w: *Watch) {
    if !w.initialized return;
    push_allocator(context.default_allocator);
    scan_destroy(*w.scanner);
    if w.worker != null {
        // odin: thread.join + thread.destroy
        _ = W_THREAD.thread_is_done(w.worker, -1);
        W_THREAD.thread_deinit(w.worker);
        free(w.worker);
        w.worker = null;
    }
    job_dispose(*w.job);
    watch_delete_strings(w.command);
    watch_delete_strings(w.pre_command);
    watch_delete_strings(w.roots);
    watch_delete_strings(w.extensions);
    watch_free_string(*w.working_directory);
    watch_free_string(*w.trigger_file);
    watch_free_string(*w.diagnostic);
    if w.cache.count > 0 {
        // 只删除本会话创建的独占目录内的文件；不跟随链接或递归删除外部路径。
        files := W_FU.file_list(w.cache);
        for files W_FILE.file_delete(it);
        for files if it.data != null free(it);
        if files.data != null free(files.data);
        W_FILE.delete_directory(w.cache);
        watch_free_string(*w.cache);
    }
    w.* = Watch.{};
}
//@endregion

//@region 公开接口

// 编译当前源码：Auto 用于修好环境后重试，Manual 就是手动触发。
// 编译中调用时丢弃这次结果，结束后按最新源码再编。
watch_retry :: (w: *Watch) {
    if !w.initialized return;
    w.has_attempted = false;
    if w.mode == .Manual w.pending = true;
    if w.worker != null w.build_invalidated = true;
}

// 同步得到一次完整扫描的指纹，供测试和工具使用；帧循环不要调用。
// Auto 请求后台扫描并阻塞到完成；Manual 没有扫描线程，在调用线程上扫描。
watch_fingerprint :: (w: *Watch) -> (u64, bool) {
    push_allocator(context.default_allocator);
    if w.scanner.thread != null {
        ticket := scan_request(*w.scanner);
        while true {
            latest := scan_result(*w.scanner);
            if latest.served >= ticket {
                if !latest.readable return 0, false;
                return latest.fingerprint, true;
            }
            sleep_milliseconds(1);
        }
    }
    scan_sweep(*w.scanner);
    if !w.scanner.readable return 0, false;
    return scan_fingerprint(*w.scanner), true;
}

// 每帧调用；只读取后台扫描结果和编译状态，不在调用线程上读文件。编译期间游戏继续运行。
// 失败版本只尝试一次，修改源码或 retry 后重试。
watch_update :: (w: *Watch, dt: float64) {
    if !w.initialized return;
    push_allocator(context.default_allocator);
    w.stable += max(dt, 0.0);
    if w.mode == .Manual {
        watch_update_manual(w, dt);
        return;
    }
    latest := scan_result(*w.scanner);
    if latest.sweeps == 0 return;
    hash := latest.fingerprint;
    readable := latest.readable;
    if readable && (!w.has_observed || hash != w.observed) {
        w.observed = hash;
        w.has_observed = true;
        w.stable = 0;
        if w.worker == null && !w.verifying {
            w.status = .Waiting;
            w.has_attempted = false;
        }
    }
    if w.worker != null {
        if !readable || hash != w.job.fingerprint w.build_invalidated = true;
        if !watch_join(w) return;
        // 编译结束后等一次在此之后开始的完整扫描，拒绝用过期源码编出的产物。
        w.verify_ticket = scan_request(*w.scanner);
        w.verifying = true;
        return;
    }
    if w.verifying {
        if latest.served < w.verify_ticket return;
        w.verifying = false;
        if readable && hash == w.job.fingerprint && !w.build_invalidated {
            watch_diagnostic(w, w.job.diagnostic);
            w.status = ifx w.job.succeeded then .Ready else .Error;
        } else {
            w.status = .Waiting;
            w.has_attempted = false;
        }
    }
    if w.status == .Ready && (!readable || hash != w.job.fingerprint) {
        w.status = .Waiting;
        w.has_attempted = false;
    }
    if !readable {
        w.has_observed = false;
        w.has_attempted = false;
        if w.status != .Error || w.diagnostic != WATCH_UNREADABLE {
            w.status = .Error;
            watch_diagnostic(w, WATCH_UNREADABLE);
        }
        return;
    }
    if w.stable < w.debounce_seconds || (w.has_attempted && w.attempted == hash) return;
    watch_start(w, hash);
}

// 与 reload 相同的帧边界要求。Auto 再核对最新扫描结果，拒绝编译期间或 Ready 之后过期的产物。
watch_apply :: (w: *Watch, s: *Session, policy: State_Policy = .Compatible) -> Result {
    if w.status != .Ready return .Not_Initialized;
    if w.mode == .Auto {
        latest := scan_result(*w.scanner);
        if !latest.readable || latest.fingerprint != w.job.fingerprint {
            w.status = .Waiting;
            w.has_attempted = false;
            return .Busy;
        }
    }
    result := reload(s, w.job.output, policy);
    if result == .Busy return result;
    w.status = ifx result == .Success then .Live else .Error;
    watch_diagnostic(w, s.diagnostic);
    return result;
}
//@endregion

//@region 编译线程

// Manual：只在请求时编译。触发文件按 poll_seconds 查询一次修改时间，不扫描源码。
watch_update_manual :: (w: *Watch, dt: float64) {
    w.poll += max(dt, 0.0);
    if w.trigger_file.count > 0 && w.poll >= w.poll_seconds {
        w.poll = 0;
        entry, ok := scan_stat(w.trigger_file);
        if ok && entry.modified != w.trigger_modified {
            w.trigger_modified = entry.modified;
            watch_retry(w);
        }
    }
    if w.worker != null {
        if !watch_join(w) return;
        if w.build_invalidated {
            w.status = .Waiting;
        } else {
            watch_diagnostic(w, w.job.diagnostic);
            w.status = ifx w.job.succeeded then .Ready else .Error;
        }
    }
    if !w.pending return;
    w.pending = false;
    watch_start(w, 0);
}

// 编译线程结束时回收；返回是否已结束。
watch_join :: (w: *Watch) -> bool {
    if !W_ATOMICS.atomic_read(*w.job.done) return false;
    _ = W_THREAD.thread_is_done(w.worker, -1);
    W_THREAD.thread_deinit(w.worker);
    free(w.worker);
    w.worker = null;
    return true;
}

// 按当前源码启动后台编译；fingerprint 是启动时的源码指纹（Manual 为 0）。
watch_start :: (w: *Watch, fingerprint: u64) {
    job_dispose(*w.job);
    w.generation += 1;
    push_allocator(context.default_allocator);
    output := sprint("%/game_%.%", w.cache, w.generation, LIBRARY_FILE_EXTENSION);
    w.job = Build_Job.{
        working_directory = w.working_directory,
        output = output,
        fingerprint = fingerprint,
    };
    w.build_invalidated = false;
    w.job.command.count = w.command.count;
    if w.command.count > 0 w.job.command.data = cast(*string) alloc(w.command.count);
    for arg, i: w.command {
        // odin: strings.replace_all(arg, "{output}", output, context.allocator)；
        // jacket 的 replace 总是返回新分配的字符串，正好由 job_dispose 释放。
        expanded, _ := W_STRING.replace(arg, "{output}", output);
        w.job.command.data[i] = expanded;
    }
    w.job.pre_command = watch_clone_strings(w.pre_command);
    w.attempted = fingerprint;
    w.has_attempted = true;
    w.worker = New(W_THREAD.Thread);
    if w.worker == null || !W_THREAD.thread_init(w.worker, build_worker, name = "hotreload.build") {
        if w.worker != null {
            free(w.worker);
            w.worker = null;
        }
        w.status = .Error;
        watch_diagnostic(w, "Cannot create compiler worker");
        return;
    }
    w.worker.data = *w.job;
    w.status = .Compiling;
    watch_diagnostic(w, "");
    W_THREAD.thread_start(w.worker);
}

build_worker :: (t: *W_THREAD.Thread) -> s64 {
    push_allocator(context.default_allocator);
    j := cast(*Build_Job) t.data;
    if j.pre_command.count > 0 {
        state, out, errout, error := DB.exec(
            DB.Process_Desc.{ command = j.pre_command, working_dir = j.working_directory },
            context.default_allocator);
        failed := error != .None || !state.exited || state.exit_code != 0;
        if failed {
            j.diagnostic = sprint("Game generate failed (%, exit %)\n%%", error, state.exit_code,
                                  out, errout);
        }
        watch_free_string(*out);
        watch_free_string(*errout);
        if failed {
            W_ATOMICS.atomic_write(*j.done, true);
            return 0;
        }
    }
    state, out, errout, error := DB.exec(
        DB.Process_Desc.{ command = j.command, working_dir = j.working_directory },
        context.default_allocator);
    j.succeeded = error == .None && state.exited && state.exit_code == 0 && W_FU.file_exists(j.output);
    if !j.succeeded {
        j.diagnostic = sprint("Game build failed (%, exit %)\n%%", error, state.exit_code, out, errout);
    }
    watch_free_string(*out);
    watch_free_string(*errout);
    W_ATOMICS.atomic_write(*j.done, true);
    return 0;
}
//@endregion

//@region 内部辅助

// odin: filepath.abs 之于 working_directory + path。空 working_directory 表示当前目录。
watch_path :: (working_directory: string, path: string) -> (string, bool) {
    joined := path;
    if !W_STRING.is_absolute_path(joined) joined = tprint("%/%", working_directory, path);
    return W_FILE.get_absolute_path(joined);
}

// odin: os.make_directory_temp(parent, "olib_hotreload_")。parent 为空时用系统临时目录。
watch_make_cache_directory :: (cache_parent: string) -> (string, bool) {
    base := cache_parent;
    if base.count == 0 {
        base = W_ENV.environment_variable("TEMP");
        if base.count == 0 base = W_ENV.environment_variable("TMP");
        if base.count == 0 base = ".";
    }
    for 0..1023 {
        attempt := watch_temp_counter;
        watch_temp_counter += 1;
        candidate := tprint("%/olib_hotreload_%_%", base, attempt, scan_monotonic_nano());
        if W_FU.is_directory(candidate) continue;
        if !W_FILE.make_directory_if_it_does_not_exist(candidate) continue;
        return copy_string(candidate), true;
    }
    return "", false;
}

// odin: filepath.stem —— 去掉最后一个 `.` 及其后面部分（没有点就原样返回）。
watch_file_stem :: (name: string) -> string {
    i := name.count - 1;
    while i >= 0 {
        if name[i] == #char "." return to_string(name.data, i);
        i -= 1;
    }
    return name;
}

// 删除 build 产物旁边的同名 sidecar（odin 用 filepath.dir + filepath.stem 拼）。
watch_remove_sidecar :: (directory: string, stem: string, extension: string) {
    // directory 由 STRING.path_strip_filename 给出，已经带结尾分隔符。
    path := tprint("%%%", directory, stem, extension);
    W_FILE.file_delete(path);
}

watch_clone_strings :: (values: [] string) -> [] string {
    result: [] string;
    if values.count == 0 return result;
    result.count = values.count;
    result.data = cast(*string) alloc(values.count);
    for value, i: values {
        result.data[i] = copy_string(value);
    }
    return result;
}

watch_delete_strings :: (values: [] string) {
    for value: values {
        if value.data != null free(value);
    }
    if values.data != null free(values.data);
}

// jacket 的 free 不接受空指针（调试构建会断言），释放字符串统一走这里。
watch_free_string :: (value: *string) {
    if value.data != null free(value.data);
    value.* = "";
}

job_dispose :: (j: *Build_Job) {
    push_allocator(context.default_allocator);
    if j.output.count > 0 {
        W_FILE.file_delete(j.output);
        directory := W_STRING.path_strip_filename(j.output);
        stem := watch_file_stem(W_STRING.path_filename(j.output));
        watch_remove_sidecar(directory, stem, ".pdb");
        watch_remove_sidecar(directory, stem, ".lib");
        watch_remove_sidecar(directory, stem, ".exp");
    }
    watch_free_string(*j.output);
    watch_free_string(*j.diagnostic);
    watch_delete_strings(j.command);
    watch_delete_strings(j.pre_command);
    j.* = Build_Job.{};
}

watch_diagnostic :: (w: *Watch, value: string) {
    push_allocator(context.default_allocator);
    watch_free_string(*w.diagnostic);
    w.diagnostic = ifx value.count > 0 then copy_string(value) else "";
}

watch_temp_counter: int;
//@endregion
