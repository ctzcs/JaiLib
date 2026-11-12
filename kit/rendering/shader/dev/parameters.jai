// dev:parameters —— .oshader 候选包的所有权与后台监听；GPU 验证成功后由调用方整体提交。
// 一比一移植自 olib kit/rendering/shader/dev/parameters.odin。
//
// Jai 侧差异（逐条对应）：
//   | olib (Odin)                                        | JaiLib (Jai)                                          |
//   | -------------------------------------------------- | ----------------------------------------------------- |
//   | context.allocator = runtime.heap_allocator()        | dev_heap() + push_allocator（系统堆）                   |
//   | thread.create / thread.join / thread.destroy        | New(THREAD.Thread) + thread_init/thread_start；        |
//   |                                                     | thread_is_done(t, -1) 当 join，thread_deinit + free    |
//   | intrinsics.atomic_load/store(&job.done)（bool）      | ATOMICS.atomic_read/atomic_write（s32，0/1）            |
//   | filepath.abs(source_directory)                      | FILE.get_absolute_path + dev_normalize_path           |
//   | delete(...)                                         | free(...data)（先判 null）                              |
//   | Parameter_Build 的切片（make/copy/delete）           | [..]（动态数组；dispose 里 array_free）                 |
#import "Basic";

Parameter_Build :: struct {
    schemas: [..] sh.Schema;
    shaders: [..] sh.Shader_Desc;
    programs: [..] Parameter_Program;
    error: string;
}

parameter_build_dispose :: (b: *Parameter_Build) {
    push_allocator(dev_heap());
    for *schema: b.schemas sh.schema_dispose(schema);
    if b.schemas.data != null array_free(b.schemas);
    for *e: b.shaders sh.shader_dispose(e);
    if b.shaders.data != null array_free(b.shaders);
    for program: b.programs {
        if program.group.data != null free(program.group.data);
        if program.source.data != null free(program.source.data);
        if program.text.data != null free(program.text.data);
    }
    if b.programs.data != null array_free(b.programs);
    if b.error.data != null free(b.error.data);
    b.* = Parameter_Build.{};
}

//@region 后台监听：结果由主线程 take，始终只有一个包生成任务

Parameter_Watch :: struct {
    source_directory: string;
    status: Status;
    diagnostic: string;
    worker: *THREAD.Thread;
    job: Parameter_Job;
    observed, attempted: u64;
    has_observed, has_attempted: bool;
    poll, stable: float64;
}

Parameter_Job :: struct {
    source_directory: string;
    fingerprint: u64;
    result: Parameter_Build;
    done: s32; // olib 的 bool；Jai 侧用 s32 走原子读写（0 = 未完成）。
}

parameters_init :: (w: *Parameter_Watch, source_directory: string) {
    push_allocator(dev_heap());
    w.* = Parameter_Watch.{};
    absolute, resolved := FILE.get_absolute_path(source_directory);
    if resolved && absolute != "" {
        w.source_directory = dev_normalize_path(absolute);
        free(absolute.data);
    } else {
        w.source_directory = dev_normalize_path(source_directory);
    }
}

parameters_dispose :: (w: *Parameter_Watch) {
    push_allocator(dev_heap());
    if w.worker != null {
        THREAD.thread_is_done(w.worker, -1);
        THREAD.thread_deinit(w.worker);
        free(w.worker);
        w.worker = null;
    }
    parameter_build_dispose(*w.job.result);
    if w.source_directory.data != null free(w.source_directory.data);
    if w.diagnostic.data != null free(w.diagnostic.data);
    w.* = Parameter_Watch.{};
}

parameters_worker :: (thread: *THREAD.Thread) -> s64 {
    job := cast(*Parameter_Job) thread.data;
    push_allocator(dev_heap());
    job.result = parameters_compile(job.source_directory);
    ATOMICS.atomic_write(*job.done, 1);
    return 0;
}

parameters_update :: (w: *Parameter_Watch, dt: float64) {
    push_allocator(dev_heap());
    w.poll += dt;
    w.stable += dt;
    if w.poll < 0.25 return;
    w.poll = 0;
    hash, ok := parameters_fingerprint(w.source_directory);
    if !ok {
        w.has_attempted = false;
        w.status = .Error;
        if w.diagnostic.data != null free(w.diagnostic.data);
        w.diagnostic = copy_string("Cannot read shader declaration directories");
        return;
    }
    if !w.has_observed || hash != w.observed {
        w.observed = hash;
        w.has_observed = true;
        w.stable = 0;
    }
    if w.worker != null {
        if ATOMICS.atomic_read(*w.job.done) == 0 return;
        THREAD.thread_is_done(w.worker, -1);
        THREAD.thread_deinit(w.worker);
        free(w.worker);
        w.worker = null;
        if w.job.fingerprint != hash {
            parameter_build_dispose(*w.job.result);
        } else {
            if w.diagnostic.data != null free(w.diagnostic.data);
            w.diagnostic = copy_string(w.job.result.error);
            if w.diagnostic == "" w.status = .Ready;
            else w.status = .Error;
        }
    }
    if w.stable < 0.25 || (w.has_attempted && w.attempted == hash) return;
    parameter_build_dispose(*w.job.result);
    w.job = Parameter_Job.{ source_directory = w.source_directory, fingerprint = hash };
    thread := New(THREAD.Thread);
    if thread == null || !THREAD.thread_init(thread, parameters_worker,
                                             name = "kit.rendering.shader.dev.parameters") {
        if thread != null free(thread);
        return;
    }
    thread.data = *w.job;
    w.worker = thread;
    w.attempted = hash;
    w.has_attempted = true;
    w.status = .Compiling;
    THREAD.thread_start(thread);
}

parameters_take :: (w: *Parameter_Watch) -> Parameter_Build {
    if w.status != .Ready return Parameter_Build.{};
    current, readable := parameters_fingerprint(w.source_directory);
    if !readable || current != w.job.fingerprint return Parameter_Build.{};
    result := w.job.result;
    w.job.result = Parameter_Build.{};
    w.status = .Live;
    return result;
}
//@endregion
