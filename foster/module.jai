// jfoster — a Jai port of the Foster 2D game framework.
// Port baseline: Foster main @ 956da85 (2026-09-24), SDL 3.4.12.
//
// [JaiLib L-001] Embedded module: #import "foster", build with -import_dir <JaiLib>.

Basic :: #import "Basic";
Math :: #import "Math";
Hash_Table :: #import "Hash_Table";
String_Mod :: #import "String";

#scope_module
// Framework-internal convenience; NOT re-exported. Users `#import "Math"`
// themselves when they need Vector2 etc. (standard Jai library practice).
using Basic;
using Math;
using Hash_Table; // Map (used by the graphics device registries)
using String_Mod; // begins_with etc.
#scope_export

// Hash_Table 返回顺序兼容层（见文件头）
#load "utility/table_compat.jai";

// utility
#load "utility/log.jai";
#load "utility/platform.jai";
#load "utility/time.jai";
#load "utility/matrix3x2.jai";
#load "utility/json.jai";
#load "utility/calc.jai";
#load "utility/pool.jai";
#load "utility/stack_list.jai";
#load "utility/update_mode.jai";

// spatial (core subsets; completed in M6)
#load "spatial/point2.jai";
#load "spatial/rect_int.jai";
#load "spatial/rect.jai";
#load "spatial/shapes.jai";
#load "spatial/point3.jai";
#load "spatial/ray.jai";

// images (Color is needed early; the rest lands in M5)
#load "images/color.jai";
#load "images/image.jai";
#load "images/packer.jai";
#load "images/font.jai";

// framework
//
// [W1] App and Window are the two modules whose whole body is native window
// plumbing (SDL_Init / SDL_CreateWindow / SDL_PollEvent), so the web target gets
// its own implementation of the same public API. `App` / `Window` / the
// window_* / app_* names are identical on both sides, which is what lets the
// kit layer (JaiLib) compile without a single `#if`.
#if OS != .WASM {
    #load "app.jai";
    #load "window.jai";
} else {
    #load "internal/web/app_web.jai";
    #load "internal/web/window_web.jai";
}

// graphics
#load "graphics/enums.jai";
#load "graphics/blend_mode.jai";
#load "graphics/texture_sampler.jai";
#load "graphics/stencil_state.jai";
#load "graphics/vertex_format.jai";
#load "graphics/uniform_buffer.jai";
#load "graphics/draw_command.jai";
#load "graphics/shader.jai";
#load "graphics/texture.jai";
#load "graphics/target.jai";
#load "graphics/buffer.jai";
#load "graphics/material.jai";
#load "graphics/mesh.jai";
#load "graphics/graphics_device.jai";
#load "graphics/batcher_vertex.jai";
#load "graphics/subtexture.jai";
#load "graphics/default_resource_data.jai";
#load "graphics/defaults.jai";
#load "graphics/batcher.jai";
#load "graphics/sprite_font.jai";
#load "images/msdf_font.jai";
#load "images/aseprite.jai";

// graphics backend (SDL_GPU)
//
// [W1] The desktop backend is two files / ~1900 lines of SDL_GPU calls; the web
// backend is a stub that holds the same `sdl_*` contract (graphics_device.jai is
// the public layer and is shared verbatim). WebGL2 lands in W3.
#if OS != .WASM {
    #load "internal/graphics_device_sdl.jai";
    #load "internal/graphics_device_sdl_draw.jai";
} else {
    #load "internal/web/graphics_device_web.jai";
}

// input
#load "input/enums.jai";
#load "input/states.jai";

#if OS != .WASM {
    #load "input/input.jai";
} else {
    #load "internal/web/input_web.jai";
}

#load "input/bindings.jai";

#if OS != .WASM {
    #load "input/cursor.jai";
} else {
    #load "internal/web/cursor_web.jai";
}

#load "input/sets.jai";
#load "input/virtual.jai";

// storage
#load "storage/storage.jai";

#if OS != .WASM {
    #load "storage/miniz_zip.jai";
} else {
    #load "internal/web/miniz_zip_web.jai";
}

#load "storage/content_storage.jai";

// SDL3 bindings (the native library link declarations stay in this root file:
// Windows LoadLibrary rejects paths containing "..", so the #library paths are
// relative to the module root)
//
// [W1] The bindings are loadable on every target: the type half (opaque handle
// typedefs, structs, enums) is unconditional, and each `#foreign SDL3` entry
// point sits in its own `#if OS != .WASM` (2-4 lines per file, inserted
// mechanically by tools/wrap_sdl3_foreign.py). The web target therefore gets the
// full SDL type surface — which keeps every public struct that mentions an SDL
// type (Window.handle, Graphics_Device.device, GPU_Resource.format, ...)
// byte-identical across targets — without ever declaring a native import.
#load "internal/sdl3/module.jai";
#load "internal/sdl3/SDL_filesystem_paths.jai";

// 目录操作兼容层（SDL 文件系统）
#if OS != .WASM {
    #load "utility/folder.jai";
} else {
    // Web: SDL-free stand-ins for the same public API (folder_*).
    #load "internal/web/folder_web.jai";
}

// stb_truetype ships precompiled (stb_impl.dll/.lib); rebuild with:
//   internal/third_party/stb/build.bat  (cl /O2 /LD /DEF:stb_impl.def stb_impl.c)
//
// [W1] Precompiled native .dll/.lib cannot be linked into a wasm module, so the
// two `#library` directives are desktop-only. images/image.jai (stb_truetype for
// raster fonts) and storage/miniz_zip.jai get wasm-side replacements instead.
#if OS != .WASM {
    stb_impl :: #library "internal/third_party/stb/stb_impl";
    miniz_impl :: #library "internal/third_party/miniz/miniz_impl";

    #if OS == .WINDOWS {
        SDL3 :: #library "internal/native/windows/SDL3";
    } else #if OS == .MACOS {
        SDL3 :: #library "internal/native/osx/libSDL3";
    } else #if OS == .LINUX {
        #if TARGET_BUILD == .ARM64 {
            SDL3 :: #library "internal/native/linux_arm64/libSDL3";
        } else {
            SDL3 :: #library "internal/native/linux_x64/libSDL3";
        }

        #library,system,link_always "libdl";
        #library,system,link_always "libm";
        #library,system,link_always "libpthread";
    }
}

// Shader pair hot replacement (olib extension: in-place, pipeline-probed):
// the reusable non-fatal pipeline builder + ShaderPairTryReplace itself.
#if OS != .WASM {
    #load "internal/pipeline_for_draw_command.jai";
    #load "graphics/shader_pair_replace.jai";
} else {
    // Web: no SDL_GPU pipeline object exists yet, so both are honest stubs that
    // report "cannot replace" and leave the working pair untouched.
    #load "internal/web/shader_pair_replace_web.jai";
}

// olib extensions that have no upstream Foster counterpart. Each file's header
// names the olib registration numbers it implements (docs/LOCAL_CHANGES.md in
// the olib repo); nothing above this block is modified by them.
#load "app_ext.jai"; // L-004 user data, L-020 LOGICAL_SIZE, L-023 logical window size
#load "storage_ext.jai"; // L-024 read results, L-015 atomic write
#load "graphics/texture_ext.jai"; // L-018 texture sampleability

// Web (wasm64) 的 JS 桥。文件自身也用 #if OS == .WASM 包着，桌面构建看不到任何
// 声明——这里再用 #if 隔一次，#load 本身也不会被桌面构建读到。
// 注意：jfoster 目前还没法整体为 wasm 编译（SDL/stb 链路未隔离，见
// internal/web/README.md §7.1），所以这一行现在对任何构建都是惰性的；
// W1 把 SDL 链路按平台隔开之后它才会真正生效。
#if OS == .WASM {
    // 桥（env 导入声明 + 持久 context + 帧驱动）
    #load "internal/web/web_bridge.jai";
    // DOM 事件记录布局 → Web_Event、Gamepad API 快照（跨语言 ABI 在这里）
    #load "internal/web/web_events.jai";
    // 存档后端：内存 + localStorage + OPFS 镜像的虚拟键空间
    #load "internal/web/storage_web.jai";
    // wasm 目标下程序入口归模块所有（native 的 -check 不要求 main，wasm 的
    // build 路径要求）。见文件头。
    #load "internal/web/web_entry.jai";
}
