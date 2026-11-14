#scope_module
using Basic;
using Math;
#scope_export

// ShaderPairTryReplace — in-place hot replacement of a vertex/fragment Shader pair.
// Port of olib/foster/olib_shader_reload.odin (ShaderPairTryReplace) onto jfoster.
//
// Call it *before* submitting any draw that uses the pair, and outside a render
// pass (the old shaders are destroyed here, which also releases the graphics
// pipelines that were compiled from them). `probes` must cover every way the pair
// is drawn: vertex format, target attachments, blend/depth/stencil, MSAA.
//
// Semantics (same as olib):
//   1. validate the argument contract (two distinct shaders, vertex+fragment
//      stages, non-empty probes, device may not change);
//   2. create both candidate shaders (with shader_create);
//   3. wrap them in a throw-away Material;
//   4. build a real graphics pipeline for every probe against the candidate pair —
//      one rejection fails the whole attempt and keeps the old shaders;
//   5. dispose the old shaders and copy the candidate structs into *vertex / *fragment,
//      so both pointers stay valid and every Material/Draw_Command that borrowed
//      them keeps working;
//   6. on failure, discard the candidates and report why.
//
// What is deliberately *not* copied or destroyed: the caller's Material uniform
// buffers, samplers and textures. The probe commands are copied, its shader fields
// re-pointed at the candidates, and everything else (vertex/index buffers, target,
// render state, uniform/sampler bindings) is left exactly as the real draw will use it.
//
// Borrowed for the lifetime of the new shader, same as shader_create:
//   * vertex_info.Bytes / fragment_info.Bytes — SDL copies the code, jfoster does not;
//   * the shader Name (the previous Name is reused when the caller leaves it empty);
//   * the entry point string (internal/sdl_device_sdl.jai keeps its cstr alive).
//
// jfoster differences from olib worth knowing:
//   | olib                                   | jfoster                                                     |
//   | -------------------------------------- | ----------------------------------------------------------- |
//   | ShaderTryInit(^Shader, ...) -> bool     | shader_create(...) -> *Shader (heap, asserts on SDL failure) |
//   | Shader is a value type                  | Shader is heap-allocated; contents are moved into *vertex/*fragment |
//   | create_pipeline_for_draw_command        | pipeline_for_draw_command (internal/pipeline_for_draw_command.jai:
//   |   (cached, doubles as the draw path)    |   non-fatal, probe-only, not cached)                        |
//   | command.Material = &material            | Draw_Command carries *Shader directly, so the candidates are
//   |                                         |   assigned to command.VertexShader/FragmentShader            |
//   | draw must not be pending                | additionally: no active render pass may be open (else the
//   |                                         |   released pipelines could still be bound)                   |

// Discards candidates that never made it into the live pair: releases their GPU
// resources and then the *Shader structs shader_create allocated (defaults_destroy
// uses the same dispose-then-free order). Any argument may be null.
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

// Cheap pre-flight so a malformed blob is reported instead of tripping the
// assert inside sdl_create_shader. Returns "" when nothing is wrong.
shader_pair_bytecode_problem :: (info: Shader_Create_Info, driver: Graphics_Driver) -> string {
    if info.Bytes.data == null || info.Bytes.count <= 0 {
        return "Shader replacement requires non-empty bytecode";
    }
    if driver == .VULKAN || driver == .PRIVATE {
        // SPIR-V is a stream of u32 words.
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
    // 1. argument contract -----------------------------------------------------
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
    // The old shaders are destroyed below, which releases every graphics pipeline
    // compiled from them; a pipeline still bound by the open render pass would be
    // a dangling handle from that point on.
    if device.render_pass != null {
        return false, "Shader replacement must be called outside an active render pass";
    }
    // NOTE: each probe's own VertexShader/FragmentShader is ignored and replaced by
    // the candidate pair below — only its target, buffers and render state matter.

    // 2. candidate shaders -----------------------------------------------------
    problem := shader_pair_bytecode_problem(vertex_info, device.driver);
    if problem != "" return false, problem;
    problem = shader_pair_bytecode_problem(fragment_info, device.driver);
    if problem != "" return false, problem;

    candidate_vertex := shader_create(
        device, .VERTEX, vertex_info.Bytes,
        sampler_count = vertex_info.SamplerCount,
        uniform_buffer_count = vertex_info.UniformBufferCount,
        storage_buffer_count = vertex_info.StorageBufferCount,
        entry_point = vertex_info.EntryPoint,
        name = vertex.Name);
    if candidate_vertex == null {
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
        return false, "Failed to create candidate fragment shader";
    }

    // 3. throw-away material so the pair is exercised exactly like a real draw.
    //    Its own uniform buffers stay empty and the probe's bindings are kept, so
    //    the caller's uniforms/samplers/textures are neither cloned nor destroyed.
    material := material_create(candidate_vertex, candidate_fragment);
    if material == null {
        shader_pair_discard(null, candidate_vertex, candidate_fragment);
        return false, "Failed to create candidate material";
    }

    // 4. one real pipeline per probe against the candidate pair -----------------
    for probe: probes {
        command := probe;
        command.VertexShader = material.Vertex.shader;
        command.FragmentShader = material.Fragment.shader;

        pipeline := pipeline_for_draw_command(device, command);
        if pipeline == null {
            shader_pair_discard(material, candidate_vertex, candidate_fragment);
            return false, "Candidate shader pipeline rejected; previous shader retained (see GPU log)";
        }
        // Probe pipelines are validation only: they are never bound and never
        // cached, so they are released immediately and cannot dangle.
        pipeline_release_for_draw_command(device, pipeline);
    }

    // 5. commit: destroy the old pair, move the candidates into the caller's
    //    Shader structs (same addresses — borrowed pointers stay valid).
    shader_dispose(vertex);
    shader_dispose(fragment);
    vertex.* = candidate_vertex.*;
    fragment.* = candidate_fragment.*;

    // The GPU handles now belong to *vertex / *fragment; only the wrapper structs
    // shader_create allocated are freed here (same pattern as defaults_destroy).
    material_destroy(material);
    free(candidate_vertex);
    free(candidate_fragment);
    return true, "";
}
