// dev —— 开发专用 HLSL 热重载，2D/3D 共用。后台仅编译，GPU 替换由渲染线程提交。
// 一比一移植自 olib kit/rendering/shader/dev/dev.odin。
//
// ============================ apply 是未实现的 seam ============================
// olib 的 apply 调 foster.ShaderPairTryReplace：把两段新字节码装进**地址不变**的两个
// Shader，并由渲染线程用真实 DrawCommand（probes）验证管线后原位替换——
// uniform、纹理、相机、预览时间都不重置，材质借用的指针也一直有效。
//
// jfoster **没有** ShaderPairTryReplace（那是 olib 在 foster 之上的扩展）。jfoster 只有
// shader_create / shader_recreate：前者要 *Graphics_Device 造新对象（地址会变，材质借用的
// 指针全部失效），后者要求 Shader 已存在且不校验管线、也不保证资源槽位不变。
// 因此这里把 GPU 替换做成**明确的未实现 seam**：
//   - 候选是否过期、资源契约是否变化，全部照 olib 逐条检查（这些是纯数据，可移植、有测试）；
//   - 检查都通过后不假装成功：set_error 写入 SHADER_PAIR_REPLACE_UNAVAILABLE 并返回 false，
//     绝不把 status 推进到 .Live、也绝不改 revision。
//   - Session.vertex / fragment 因此永远是 null：宿主不能在 jfoster 上拿到「热替换后的
//     Shader 对」。等 jfoster 提供等价接口（地址不变 + probes 校验 + 资源槽位保留）时，
//     只需填 apply 的这一段，其余状态机不用动。
// ==============================================================================
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                                   | JaiLib (Jai)                                            |
//   | --------------------------------------------- | ------------------------------------------------------- |
//   | session.vertex/fragment: foster.Shader         | *F.Shader（null：原因见上面的 seam 说明）                 |
//   | .Vulkan / .D3D12 / .Metal                      | .VULKAN / .D3D12 / .METAL（jfoster 成员名全大写）          |
//   | .Vertex / .Fragment（foster 枚举）              | .VERTEX / .FRAGMENT                                     |
//   | thread.create_and_start_with_data              | New(THREAD.Thread) + thread_init/thread_start           |
//   | thread.join + thread.destroy                   | thread_is_done(t, -1) + thread_deinit + free            |
//   | intrinsics.atomic_load/store(&job.done)        | ATOMICS.atomic_read/atomic_write（s32 0/1）               |
//   | filepath.abs / dir                             | FILE.get_absolute_path / STRING.path_strip_filename     |
//   | strings.clone / delete                         | copy_string / free(x.data)                              |
//   | comp.POLICY（无类型字符串常量）                  | comp.POLICY                                             |
//   | for resources in ([2]Resources{...})           | for resources: [2] Resources.{ ... }                    |
//   | #partial switch driver                        | if / else if 链（.NONE 与 .PRIVATE 都按不支持处理）        |
#import "Basic";

//@region 会话与候选发布

Status :: enum {
    Waiting;
    Compiling;
    Ready;
    Live;
    Error;
}

// jfoster 侧没有「地址不变的 Shader 对」可持有，所以这里存指针（见文件头）。
// Session 必须保持地址稳定；不要复制。init 后 dispose，退出时等待编译线程结束。
// 持有 shader 和字节码；material 借用 &vertex/&fragment，须先于 Session 释放。
Session :: struct {
    vertex, fragment: *F.Shader; // 恒为 null：apply 是未实现的 seam，jfoster 不提供原位替换。
    status: Status;
    diagnostic: string;
    revision: u64;
    source: string;
    root: string;
    format: string;
    compiler_options: comp.Options; // Session 持有工具路径副本，后台任务只读。
    parameter_layout: bool;
    source_text: string;
    contract_revision: u64;
    expected: [2] Resources;
    live: Build;
    job: Job;
    worker: *THREAD.Thread;
    observed: u64;
    attempted: u64;
    has_observed, has_attempted: bool;
    poll_elapsed, stable_elapsed: float64;
}

Job :: struct {
    source, format: string;
    compiler_options: comp.Options;
    source_text: string;
    fingerprint: u64;
    result: Build;
    done: s32; // olib 的 bool（跨线程只做「写完」的发布，用原子读写保险）。
}

// 返回 false 时仍应调用 dispose。诊断借用至下一次状态变化/销毁。
init :: (s: *Session, source: string, driver: F.Graphics_Driver,
         vertex_resources: Resources, fragment_resources: Resources,
         compiler_options := comp.Options.{}) -> bool {
    push_allocator(dev_heap());
    s.* = Session.{};
    s.compiler_options = comp.Options.{ dxil = compiler_options.dxil,
                                       shadercross = copy_string(compiler_options.shadercross),
                                       dxc = copy_string(compiler_options.dxc) };
    both: [2] Resources = .[ vertex_resources, fragment_resources ];
    for resources: both {
        if resources.storage_textures != 0 || resources.storage_buffers < 0 ||
           resources.samplers < 0 || resources.samplers > 16 ||
           resources.uniform_buffers < 0 || resources.uniform_buffers > 8 {
            set_error(s, "Shader binding contract exceeds Foster graphics material support");
            return false;
        }
    }
    if driver == .VULKAN {
        s.format = "spv";
    } else if driver == .D3D12 {
        s.format = "dxil";
    } else if driver == .METAL {
        s.format = "msl";
    } else {
        set_error(s, "Shader development requires Vulkan, D3D12 or Metal");
        return false;
    }
    path, resolved := FILE.get_absolute_path(source);
    if !resolved || path == "" {
        set_error(s, "Cannot resolve shader source path");
        return false;
    }
    s.source = dev_normalize_path(path);
    free(path.data);
    s.root = copy_string(STRING.path_strip_filename(s.source));
    s.expected[0] = vertex_resources;
    s.expected[1] = fragment_resources;
    // olib 在这里把 s.vertex.Stage/.Name 预填好；jfoster 的 Shader 必须由 shader_create 造，
    // 而替换路径不可用（见文件头），所以不造对象，字段保持 null。
    return true;
}

dispose :: (s: *Session) {
    push_allocator(dev_heap());
    if s.worker != null {
        THREAD.thread_is_done(s.worker, -1);
        THREAD.thread_deinit(s.worker);
        free(s.worker);
        s.worker = null;
    }
    if s.vertex != null F.shader_dispose(s.vertex);
    if s.fragment != null F.shader_dispose(s.fragment);
    build_dispose(*s.live);
    build_dispose(*s.job.result);
    if s.job.source.data != null free(s.job.source.data);
    if s.job.source_text.data != null free(s.job.source_text.data);
    if s.job.compiler_options.shadercross.data != null free(s.job.compiler_options.shadercross.data);
    if s.job.compiler_options.dxc.data != null free(s.job.compiler_options.dxc.data);
    if s.source_text.data != null free(s.source_text.data);
    if s.source.data != null free(s.source.data);
    if s.compiler_options.shadercross.data != null free(s.compiler_options.shadercross.data);
    if s.compiler_options.dxc.data != null free(s.compiler_options.dxc.data);
    if s.root.data != null free(s.root.data);
    if s.diagnostic.data != null free(s.diagnostic.data);
    s.* = Session.{};
}

// 重新尝试当前源码（如编译器安装完成后）；不丢弃有效画面。
retry :: (s: *Session) {
    s.has_attempted = false;
}

// 主线程每帧调用。250ms 检测、250ms 稳定期；任务完成前不读取其结果。
update :: (s: *Session, dt: float64) {
    push_allocator(dev_heap());
    if s.source == "" return;
    s.poll_elapsed += max(dt, 0);
    s.stable_elapsed += max(dt, 0);
    if s.poll_elapsed < 0.25 return;
    s.poll_elapsed = 0;
    fingerprint, readable := session_fingerprint(s);
    if !readable {
        s.has_attempted = false;
        set_error(s, "Cannot read shader sources; previous shader retained");
        return;
    }
    if !s.has_observed || fingerprint != s.observed {
        s.observed = fingerprint;
        s.has_observed = true;
        s.stable_elapsed = 0;
    }
    if s.worker != null {
        if ATOMICS.atomic_read(*s.job.done) == 0 return;
        THREAD.thread_is_done(s.worker, -1);
        THREAD.thread_deinit(s.worker);
        free(s.worker);
        s.worker = null;
        if s.job.fingerprint != fingerprint {
            build_dispose(*s.job.result);
        } else if s.job.result.error != "" {
            set_error(s, s.job.result.error);
            build_dispose(*s.job.result);
        } else {
            s.status = .Ready;
        }
    }
    if s.stable_elapsed < 0.25 || (s.has_attempted && s.attempted == fingerprint) return;
    build_dispose(*s.job.result);
    if s.job.source.data != null free(s.job.source.data);
    if s.job.source_text.data != null free(s.job.source_text.data);
    if s.job.compiler_options.shadercross.data != null free(s.job.compiler_options.shadercross.data);
    if s.job.compiler_options.dxc.data != null free(s.job.compiler_options.dxc.data);
    s.job = Job.{ source = copy_string(s.source), format = s.format, source_text = copy_string(s.source_text),
                  fingerprint = fingerprint, compiler_options = s.compiler_options };
    thread := New(THREAD.Thread);
    if thread == null || !THREAD.thread_init(thread, compile_worker,
                                             name = "kit.rendering.shader.dev.compile") {
        if thread != null free(thread);
        set_error(s, "Cannot start shader compiler thread");
        return;
    }
    thread.data = *s.job;
    s.worker = thread;
    s.attempted = fingerprint;
    s.has_attempted = true;
    s.status = .Compiling;
    THREAD.thread_start(thread);
}

compile_worker :: (thread: *THREAD.Thread) -> s64 {
    job := cast(*Job) thread.data;
    push_allocator(dev_heap());
    job.result = compile(job.source, job.format, job.source_text, job.compiler_options);
    ATOMICS.atomic_write(*job.done, 1);
    return 0;
}

// 在所有实际绘制和 Batcher 排队之前调用，probes 覆盖该 Shader 所有绘制配置。
// 成功后的重启语义（地址不变、uniform/纹理/相机不重置）在 jfoster 上无法实现：见文件头。
// 返回 false 的两种情形：候选过期/资源契约变化（olib 原样）与「替换接口缺失」（Jai 侧专有）。
apply :: (s: *Session, device: *F.Graphics_Device, probes: [] F.Draw_Command) -> bool {
    push_allocator(dev_heap());
    if s.status != .Ready return false;
    current, readable := session_fingerprint(s);
    if !readable || current != s.job.fingerprint {
        build_dispose(*s.job.result);
        s.has_attempted = false;
        s.status = .Waiting;
        return false;
    }
    for expected, i: s.expected {
        actual := s.job.result.resources[i];
        compatible := actual == expected;
        if s.parameter_layout {
            compatible = actual.samplers <= expected.samplers &&
                         actual.uniform_buffers <= expected.uniform_buffers &&
                         actual.storage_buffers <= expected.storage_buffers &&
                         actual.storage_textures == expected.storage_textures;
        }
        if !compatible {
            set_error(s, "Shader resource bindings changed; update the host contract and restart");
            build_dispose(*s.job.result);
            return false;
        }
    }
    // ---- 到这里 olib 会调 foster.ShaderPairTryReplace（见文件头）。jfoster 没有等价接口：
    // 不创建 Shader、不改 status/revision，只留下可读的诊断。
    _ = device;
    _ = probes;
    set_error(s, SHADER_PAIR_REPLACE_UNAVAILABLE);
    build_dispose(*s.job.result);
    return false;
}

// 未实现 seam 的固定诊断文本（宿主可据此把热重载降级为「重启生效」）。
SHADER_PAIR_REPLACE_UNAVAILABLE :: "GPU shader replacement is unavailable: jfoster has no ShaderPairTryReplace; restart the host to load the compiled shader";

set_error :: (s: *Session, message: string) {
    if s.diagnostic.data != null free(s.diagnostic.data);
    s.diagnostic = copy_string(message);
    s.status = .Error;
}

// 保留生成参数布局的全部槽，包括被编译器优化掉的字段。片元至少两个 uniform 槽（b0 帧块、b1 参数），
// init 约定了更多槽（如 Model 的 b2 视图块）时保留。
configure_parameters :: (s: *Session, textures: int) {
    s.parameter_layout = true;
    s.contract_revision += 1;
    s.status = .Waiting;
    s.expected[1] = Resources.{ samplers = textures, uniform_buffers = max(s.expected[1].uniform_buffers, 2) };
    s.has_attempted = false;
}

session_fingerprint :: (s: *Session) -> (hash: u64, ok: bool) {
    hash, ok = source_fingerprint(s.root);
    for b: s.source hash = (hash ^ cast(u64) b) * 1099511628211;
    for b: s.source_text hash = (hash ^ cast(u64) b) * 1099511628211;
    for b: comp.POLICY hash = (hash ^ cast(u64) b) * 1099511628211;
    for b: s.format hash = (hash ^ cast(u64) b) * 1099511628211;
    for b: s.compiler_options.shadercross hash = (hash ^ cast(u64) b) * 1099511628211;
    for b: s.compiler_options.dxc hash = (hash ^ cast(u64) b) * 1099511628211;
    hash = (hash ^ cast(u64) s.compiler_options.dxil) * 1099511628211;
    includes, includes_ok := source_fingerprint(lang.INCLUDE_DIRECTORY);
    ok = ok && includes_ok;
    hash = (hash ^ includes) * 1099511628211;
    hash = (hash ^ s.contract_revision) * 1099511628211;
    return hash, ok;
}
//@endregion
