#scope_module
using Basic;
using Math;
#scope_export

// jfoster — ShaderPairTryReplace, web (wasm64) version. W4.
//
// ===========================================================================
// 为什么这个文件现在有真实现了
// ===========================================================================
// W1/W2/W3 时它是「校验完就拒绝」的桩，理由写得很直白：桌面那套方法的核心是
// **为每条 probe command 真建一个 graphics pipeline**，而当时 web 后端
// `sdl_create_shader` 只是登记一个 handle、不编译任何东西，于是「探针」没有可探
// 的对象。W4 把那条路补上了：
//
//   * `sdl_create_shader`（graphics_device_web.jai）现在真的把 GLSL ES 3.00 文本
//     送进 compileShader，失败时 `res.shader` 留 null；
//   * `web_gl_probe_pipeline`（graphics_device_web.jai）能建一个**不入缓存**的
//     program + VAO，并在失败时把半成品清掉；
//   * `web_gl_release_probe_pipeline` 把探针（VAO + 它独占的 program）收回；
//   * `web_gl_purge_programs_for`（web_gl.jai）保证旧 shader 一销毁，由它链出来
//     的 program 立刻出缓存 —— 这正是「换掉 shader 的 GPU 资源但保留 *Shader 的
//     地址」不会让下一次 draw 摸到死 program 的原因。
//
// 于是桌面那套流程可以**逐条照搬**，只是把「SDL pipeline 探针」换成「WebGL2
// program+VAO 探针」。语义完全一致：
//
//   1. 校验参数契约（两个不同的 shader、顶点+片元阶段、非空 probes、不能换设备）；
//   2. 用 shader_create 建两个候选（web：编译失败时 handle 里没有 GL 对象）；
//   3. 包一个**一次性的 Material**，让候选也走和真 draw 一模一样的路径；
//   4. 每条 probe 用 web_gl_probe_pipeline 试建一个 pipeline，任何一条被拒就整体
//      失败并保留旧 pair；
//   5. 全过才提交：销毁旧 pair，把候选的内容**挪进** *vertex / *fragment
//      （地址不变，借用这两个指针的 Material / Draw_Command 全部继续有效）；
//   6. 失败则 discard 候选，并返回原因。
//
// ===========================================================================
// 和桌面的差异（只有一处半）
// ===========================================================================
//   | 桌面                                          | web
//   | --------------------------------------------- | ---------------------------------------------
//   | shader_create → SDL_CreateGPUShader           | shader_create → compileShader
//   |   （SPIR-V/DXIL/MSL 二进制，创建时不报错）      |   （GLSL 文本，**创建时就编译**）
//   | 失败只可能发生在 pipeline 探针里                | 失败可能落在更早的 shader_create 上
//   | pipeline_for_draw_command / _release          | web_gl_probe_pipeline / web_gl_release_probe_pipeline
//   | 探针 pipeline 有自己的 shader 对象             | 探针 program 引用候选 shader 的 GL 对象
//
// 第 2 行是唯一实质差别，也是它**更好**的地方：GLSL 语法错在建候选那一步就暴露，
// 不必等到链接。两种情况对调用方的表现完全一样（false + 原因 + 旧 pair 仍然活着），
// 所以跨平台的游戏代码不需要分支。
//
// 需要注意的一个后果：`shader_create` 在编译失败时**仍然返回一个非 null 的
// *Shader**（handle 有效，只是 handle 背后没有 GL shader）。这是 graphics/
// 层的既有契约（它 assert 的是「SDL 创建失败」，而 web 侧没有那个 assert），
// 所以下面判断「候选到底有没有可用的 GL 对象」是靠 probe 的返回值，而不是靠
// `candidate_vertex == null`。这也和桌面一致：桌面同样靠 pipeline 探针说话。

// Discards candidates that never made it into the live pair. Identical to the
// desktop version and fully portable: material_destroy / shader_dispose are the
// shared graphics functions, and the dispose-then-free order is the same one
// defaults_destroy uses.
//
// web 侧的一个细节：候选的 GL shader 可能根本没建起来（编译失败），此时
// handle 里的指针是 null，`web_gl_id(null) == 0`，host.js 的 gl_destroy_shader(0)
// 直接返回 -1 —— 不会误删别人的对象，也不需要在这里特判。
shader_pair_discard :: (material: *Material, vertex, fragment: *Shader) {
    if material != null material_destroy(material);
    if vertex != null {
        shader_dispose(vertex);
        free(vertex);
    }
    if fragment != null {
        shader_dispose(fragment);
        free(fragment);
    }
}

// Same pre-flight as desktop: catches an obviously malformed blob before it can
// reach the backend. Returns "" when nothing is wrong.
//
// web 上这里多做一件小事：GLSL ES 3.00 文本必须真的以 `#version` 开头。桌面的
// 二进制路径靠驱动报错，web 的 `sdl_create_shader` 则要先用这个判据决定「这是
// GLSL 文本」还是「这是桌面形状的二进制、去查内置表」。在这个函数里提前说清楚，
// 比让候选悄悄退回内置表（那会「替换成功」但内容没变）安全得多。
shader_pair_bytecode_problem :: (info: Shader_Create_Info, driver: Graphics_Driver) -> string {
    if info.Bytes.data == null || info.Bytes.count <= 0 {
        return "Shader replacement requires non-empty bytecode";
    }
    // [W4] 判据的顺序在这里很关键。
    //
    // web 后端把 `device.driver` 设成 `.PRIVATE`（没有 SDL driver 名字可报，
    // graphics_device_web.jai 的注释说了），而 `.PRIVATE` 在桌面语义里是「SPIR-V
    // 兜底枚举」—— 于是桌面那条「必须是 4 的倍数」会**误伤**合法的 GLSL 文本：
    // 一段 189 字节的片元源会被判成「SPIR-V 没对齐」直接拒掉。第一次跑 W4 的
    // 热替换演示时就是这么挂的（候选 189/190/156 字节全部被拒）。
    //
    // 所以先问「这段字节到底是不是 GLSL」：是的话就没有任何对齐要求（GLSL ES
    // 3.00 是文本），对齐规则只属于二进制路径。
    if web_shader_code_is_glsl(info.Bytes) return "";
    if driver == .VULKAN || driver == .PRIVATE {
        if (info.Bytes.count % 4) != 0 {
            return "SPIR-V bytecode must be a multiple of 4 bytes";
        }
    }
    return "";
}

ShaderPairTryReplace :: (
    vertex, fragment: *Shader,
    device: *Graphics_Device,
    vertex_info, fragment_info: Shader_Create_Info,
    probes: [] Draw_Command
) -> (ok: bool, error: string) {
    // 1. argument contract — byte-for-byte the desktop checks, so a caller that
    //    passes something wrong gets the same message on both targets.
    if vertex == null || fragment == null || vertex == fragment || probes.count == 0 {
        return false, "Shader replacement requires two shaders and draw probes";
    }
    if device == null || device.disposed || device.device == null {
        return false, "Shader replacement requires a created Graphics Device";
    }
    if vertex_info.Stage != .VERTEX || fragment_info.Stage != .FRAGMENT {
        return false, "Shader replacement requires vertex and fragment stages";
    }
    if (vertex.handle != 0 && vertex.device != device) ||
       (fragment.handle != 0 && fragment.device != device) {
        return false, "Shader replacement cannot change graphics device";
    }
    if device.render_pass != null {
        return false, "Shader replacement must be called outside an active render pass";
    }

    // 2. blob pre-flight
    problem := shader_pair_bytecode_problem(vertex_info, device.driver);
    if problem != "" return false, problem;
    problem = shader_pair_bytecode_problem(fragment_info, device.driver);
    if problem != "" return false, problem;

    // 3. candidate shaders. Names are inherited from the live pair (same as
    //    desktop) so every log line about the candidate is attributable.
    log_info(tprint("web/hot-replace: 开始 —— pair 现在是 '%/%'（vs=% fs=%），候选 % / % 字节",
                    vertex.Name, fragment.Name, vertex.handle, fragment.handle,
                    cast(s32) vertex_info.Bytes.count, cast(s32) fragment_info.Bytes.count));

    candidate_vertex := shader_create(
        device, .VERTEX, vertex_info.Bytes,
        sampler_count = vertex_info.SamplerCount,
        uniform_buffer_count = vertex_info.UniformBufferCount,
        storage_buffer_count = vertex_info.StorageBufferCount,
        entry_point = vertex_info.EntryPoint,
        name = vertex.Name);
    if candidate_vertex == null {
        log_error("web/hot-replace: 候选顶点 shader 建不起来 —— 旧 pair 保留");
        return false, "Failed to create candidate vertex shader";
    }

    candidate_fragment := shader_create(
        device, .FRAGMENT, fragment_info.Bytes,
        sampler_count = fragment_info.SamplerCount,
        uniform_buffer_count = fragment_info.UniformBufferCount,
        storage_buffer_count = fragment_info.StorageBufferCount,
        entry_point = fragment_info.EntryPoint,
        name = fragment.Name);
    if candidate_fragment == null {
        shader_pair_discard(null, candidate_vertex, null);
        log_error("web/hot-replace: 候选片元 shader 建不起来 —— 旧 pair 保留");
        return false, "Failed to create candidate fragment shader";
    }

    // 4. throw-away material so the pair is exercised exactly like a real draw.
    //    Its own uniform buffers stay empty and the probe's bindings are kept, so
    //    the caller's uniforms/samplers/textures are neither cloned nor destroyed.
    material := material_create(candidate_vertex, candidate_fragment);
    if material == null {
        shader_pair_discard(null, candidate_vertex, candidate_fragment);
        log_error("web/hot-replace: 一次性 Material 建不起来 —— 旧 pair 保留");
        return false, "Failed to create candidate material";
    }

    // 5. one real pipeline per probe against the candidate pair.
    //
    //    web_gl_probe_pipeline 返回 0 覆盖三种失败，日志里能分辨是哪种：
    //      a. 候选 shader 编译失败（handle 里没有 GL 对象）—— host.js 已经打了
    //         "`<stage> shader '<name>' 编译失败：<info log>`"；
    //      b. linkProgram 失败（varying 不匹配、attribute 不兼容……）—— host.js
    //         已经打了 "`program '<name>' 链接失败：<info log>`"；
    //      c. createVertexArray 失败 —— web_gl_check_error 会记一条 GL error。
    probe_index := 0;
    for probe: probes {
        probe_index += 1;
        command := probe;
        command.VertexShader = material.Vertex.shader;
        command.FragmentShader = material.Fragment.shader;

        pipeline := web_gl_probe_pipeline(device, command);
        if pipeline <= 0 {
            // 诊断：probe 返回 0 的三条来路，尽量说清是哪一条。返回给调用方的
            // error 字符串保持和桌面逐字一致（上面第 5 条注），细节进日志。
            if !web_gl_shader_compiled(device, candidate_vertex) {
                log_error(tprint("web/hot-replace: 候选**顶点** shader 编译失败 —— 第 %/% 条 probe 被拒，候选丢弃，旧 pair '%/%' 保留",
                                 probe_index, cast(s32) probes.count, vertex.Name, fragment.Name));
            } else if !web_gl_shader_compiled(device, candidate_fragment) {
                log_error(tprint("web/hot-replace: 候选**片元** shader 编译失败 —— 第 %/% 条 probe 被拒，候选丢弃，旧 pair '%/%' 保留",
                                 probe_index, cast(s32) probes.count, vertex.Name, fragment.Name));
            } else {
                log_error(tprint("web/hot-replace: 两个候选都编译通过，但 program 链接 / VAO 创建失败 —— 第 %/% 条 probe 被拒，候选丢弃，旧 pair '%/%' 保留",
                                 probe_index, cast(s32) probes.count, vertex.Name, fragment.Name));
            }
            shader_pair_discard(material, candidate_vertex, candidate_fragment);
            return false, tprint("Candidate shader pipeline rejected at probe %/%; previous shader retained (see GPU log)",
                                 probe_index, cast(s32) probes.count);
        }
        // Probe pipelines are validation only: they are never bound and never
        // cached, so they are released immediately and cannot dangle.
        web_gl_release_probe_pipeline(pipeline);
    }
    log_info(tprint("web/hot-replace: % 条 probe 全部通过（program + VAO 都建起来了）", probe_index));

    // 6. commit: destroy the old pair, move the candidates into the caller's
    //    Shader structs (same addresses — borrowed pointers stay valid).
    //
    //    shader_dispose 会顺带 release 掉「依赖这对 shader 的 graphics pipeline」
    //    和「由这对 shader 链出来的 program」（sdl_destroy_resource →
    //    sdl_release_graphics_pipelines_associated_with + web_gl_purge_programs_for）。
    //    所以交换之后第一次 draw 一定要重新链接 —— 这正是我们要的：新的 GLSL 真的
    //    被编译、被链接、被画出来，而不是复用旧 program。
    shader_dispose(vertex);
    shader_dispose(fragment);
    vertex.* = candidate_vertex.*;
    fragment.* = candidate_fragment.*;

    // The GPU handles now belong to *vertex / *fragment; only the wrapper structs
    // shader_create allocated are freed here (same pattern as defaults_destroy).
    material_destroy(material);
    free(candidate_vertex);
    free(candidate_fragment);

    log_info(tprint("web/hot-replace: 提交 —— '%/%' 的 GPU 资源已换成新候选（地址不变），旧 program 已被回收",
                    vertex.Name, fragment.Name));
    return true, "";
}
