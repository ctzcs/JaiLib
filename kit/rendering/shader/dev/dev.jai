// dev —— 开发专用 HLSL 热重载，2D/3D 共用。后台仅编译，GPU 替换由渲染线程提交。
// 一比一移植自 olib kit/rendering/shader/dev/dev.odin。
//
// ============================ apply 走真正的原位替换 ============================
// apply 调 F.ShaderPairTryReplace（jfoster graphics/shader_pair_replace.jai，olib
// olib_shader_reload.odin 的移植）：把两段新字节码装进**地址不变**的两个 *F.Shader，
// 并用真实 Draw_Command（probes）验证候选管线后原位替换——
// uniform、纹理、相机、预览时间都不重置，材质借用的指针也一直有效。
//
// 与 olib 唯一的形态差异来自「谁造那两个 Shader」：
//   - olib 的 Session.vertex/fragment 是 Shader **值**，init 时先填 Stage/Name、
//     Resource 为空，ShaderPairTryReplace 在同一个地址上 ShaderTryInit 出来。
//   - jfoster 的 Shader 是堆对象，且 ShaderPairTryReplace 要求两个**已存在**的 Shader
//     （它只替换内容）。所以第一次安装由 apply 用 shader_create 造出这一对
//     （地址从此固定），立刻交给 ShaderPairTryReplace 走同一条「候选 + probes 校验」路径；
//     校验失败就把这一对丢掉（此时还没有任何材质借用它）。之后每次 apply 都只换内容。
//   - dispose 释放这一对（shader_dispose + free 结构体），顺序与 defaults_destroy 一致。
//
// Jai 侧差异（逐条对应 olib 的写法，行为不变）：
//   | olib (Odin)                                   | JaiLib (Jai)                                            |
//   | --------------------------------------------- | ------------------------------------------------------- |
//   | session.vertex/fragment: foster.Shader         | *F.Shader（apply 首次安装时创建，地址此后不变）             |
//   | foster.ShaderPairTryReplace(&vertex,&fragment) | F.ShaderPairTryReplace(vertex, fragment, ...)（已是指针）  |
//   | shader.CreateInfo（foster 存在 Shader 上）      | shader_infos()：由 Build.code + 资源反射现拼              |
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

// Session 必须保持地址稳定；不要复制。init 后 dispose，退出时等待编译线程结束。
// 持有 shader 和字节码；material 借用 vertex/fragment（同一对 *F.Shader，地址不变），
// 须先于 Session 释放。vertex/fragment 在第一次 apply 成功前后者为 null。
Session :: struct {
    vertex, fragment: *F.Shader; // apply 首次安装时 F.shader_create 出来的活 Shader 对；地址此后不变。
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
    // 而 init 不接 *Graphics_Device，所以活 Shader 对留到第一次 apply（那里才拿到设备）。
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
    shader_pair_release(s);
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

// 把所有实际绘制和 Batcher 排队之前调用，probes 覆盖该 Shader 所有绘制配置。
// 成功：GPU 程序原位替换（地址不变、uniform/纹理/相机不重置）→ .Live，revision += 1。
// 返回 false 的四种情形：候选过期 / 资源契约变化 / 没有设备 / 候选管线被拒（诊断在 s.diagnostic）。
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
    // ---- 到这里 olib 调 foster.ShaderPairTryReplace（见文件头）。jfoster 的同名过程要两个
    // 已存在的 Shader：第一次安装先造出地址固定的这一对，之后就只换内容。
    infos := shader_infos(s, s.job.result.code, s.job.result.resources);
    if device == null {
        set_error(s, "Shader replacement requires a created Graphics Device");
        build_dispose(*s.job.result);
        return false;
    }
    primed := s.vertex == null || s.fragment == null;
    if primed && !shader_pair_prime(s, device, infos) {
        set_error(s, "Failed to create the live Shader pair");
        build_dispose(*s.job.result);
        return false;
    }
    ok, problem := F.ShaderPairTryReplace(s.vertex, s.fragment, device, infos[0], infos[1], probes);
    if !ok {
        // 第一次安装没有旧 Shader 可保留：这一对（以及它们的字节码借用）一起丢掉。
        // 之后的失败由 ShaderPairTryReplace 负责，旧 Shader/材质全部原样。
        if primed shader_pair_release(s);
        set_error(s, problem);
        build_dispose(*s.job.result);
        return false;
    }
    build_dispose(*s.live);
    s.live = s.job.result;
    s.job.result = Build.{};
    s.status = .Live;
    s.revision += 1;
    if s.diagnostic.data != null free(s.diagnostic.data);
    s.diagnostic = "";
    return true;
}

// 用已安装构建的字节码重新校验实际管线（切到另一套目标/网格时用），不重新编译 HLSL。
// 与 apply 的差别：不消耗候选、不改 status/revision；失败诊断交给调用方决定怎么显示。
revalidate :: (s: *Session, device: *F.Graphics_Device, probes: [] F.Draw_Command) -> (ok: bool, error: string) {
    push_allocator(dev_heap());
    if s.vertex == null || s.fragment == null {
        return false, "Shader revalidation requires an installed shader pair";
    }
    if device == null return false, "Shader replacement requires a created Graphics Device";
    infos := shader_infos(s, s.live.code, s.live.resources);
    return F.ShaderPairTryReplace(s.vertex, s.fragment, device, infos[0], infos[1], probes);
}

// 两份 Shader_Create_Info：olib 直接取 foster.Shader 上留存的 CreateInfo，jfoster 的 Shader
// 不留字节码，所以由调用方给出「哪一次构建的字节码」。槽位来源与 olib 一致：
// 生成参数布局时用 init/configure_parameters 约定的槽（反射可能因优化少报），否则用本次反射。
shader_infos :: (s: *Session, code: [2][] u8, resources: [2] Resources) -> [2] F.Shader_Create_Info {
    infos: [2] F.Shader_Create_Info;
    for i: 0..1 {
        r := resources[i];
        if s.parameter_layout r = s.expected[i];
        stage := F.Shader_Stage.VERTEX;
        entry := "vertex_main";
        if i == 1 {
            stage = .FRAGMENT;
            entry = "fragment_main";
        }
        infos[i] = F.Shader_Create_Info.{
            Stage = stage,
            Bytes = code[i],
            EntryPoint = entry,
            SamplerCount = cast(s32) r.samplers,
            UniformBufferCount = cast(s32) r.uniform_buffers,
            StorageBufferCount = cast(s32) r.storage_buffers,
        };
    }
    return infos;
}

// 第一次安装：jfoster 的 ShaderPairTryReplace 只替换已存在 Shader 的内容，而 shader_create
// 是唯一的造 Shader 途径。所以先用候选字节码造出这一对（地址从此固定），随即交给
// ShaderPairTryReplace 走同一条「候选 + probes 校验」路径——首装也不许绕过管线校验。
// 名字与 olib 的 init 一致（ShaderPairTryReplace 会沿用它给候选命名）。
shader_pair_prime :: (s: *Session, device: *F.Graphics_Device, infos: [2] F.Shader_Create_Info) -> bool {
    s.vertex = F.shader_create(device, .VERTEX, infos[0].Bytes,
        sampler_count = infos[0].SamplerCount,
        uniform_buffer_count = infos[0].UniformBufferCount,
        storage_buffer_count = infos[0].StorageBufferCount,
        entry_point = infos[0].EntryPoint,
        name = "live vertex");
    s.fragment = F.shader_create(device, .FRAGMENT, infos[1].Bytes,
        sampler_count = infos[1].SamplerCount,
        uniform_buffer_count = infos[1].UniformBufferCount,
        storage_buffer_count = infos[1].StorageBufferCount,
        entry_point = infos[1].EntryPoint,
        name = "live fragment");
    return s.vertex != null && s.fragment != null;
}

// 释放这一对（先 GPU 资源再结构体，与 jfoster 的 defaults_destroy / kit 各 renderer 同序）。
// 只给 dispose 和「首装校验失败」用：此时还没有材质借用这两个地址。
shader_pair_release :: (s: *Session) {
    if s.vertex != null {
        F.shader_dispose(s.vertex);
        free(s.vertex);
        s.vertex = null;
    }
    if s.fragment != null {
        F.shader_dispose(s.fragment);
        free(s.fragment);
        s.fragment = null;
    }
}

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
