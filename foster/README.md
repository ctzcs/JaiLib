# Foster（JaiLib 内置）

A port of [Foster](https://github.com/FosterFramework/Foster) — the small cross-platform
2D game framework by Noel Berry & Maddy Thorson — to the [Jai](https://compiler.subassembly.com/)
programming language.

- **Port baseline:** Foster main @ `956da85` (2026-09-24, post v0.4.2), kept as a reference clone in `ref/Foster` (not checked in).
- **Platform layer:** SDL3 (same native binaries Foster ships, currently 3.4.12).
- **Graphics:** SDL_GPU, ported 1:1 from Foster's `GraphicsDeviceSDL`; the precompiled
  shader blobs (SPIR-V / DXIL / MSL) are reused as-is from Foster.
- **Status:** all core milestones complete (M0-M8). See module reference below.

来源和本地调整见 [LOCAL_CHANGES](docs/LOCAL_CHANGES.md)。统一构建/验收从 JaiLib 的 tools/check 与 tools/wasm 进入。

## Layout

```
module.jai        module entry (#import "foster" with -import_dir <JaiLib>)
app.jai window.jai
content/          built-in shader/font source assets (embedded at compile time)
graphics/ images/ input/ spatial/ storage/ utility/
internal/         SDL backend, hand-written SDL3 bindings, vendored C sources, SDL3 runtimes
tests/          native and Web regression entries
tools/            content generation, ABI check, shader recompile helpers
```

## Usage

```
jaic -import_dir <path/to/JaiLib> your_main.jai
```

```jai
#import "foster";
...
app_run();
```

Default Batcher, Textured and MSDF shader blobs for D3D12/Vulkan/Metal are
embedded by `graphics/default_resource_data.jai` using source-relative `#run`
reads. Roboto MSDF JSON/PNG and its license are embedded too. Consumers do not
need a runtime `content/` directory, and default resources do not change CWD.
Custom game/demo assets remain the host application's responsibility.
`defaults_msdf_font(device)` lazily decodes and caches the embedded Roboto atlas;
`defaults_font_license()` returns its license text. Device shutdown releases the
cached default materials and font.

`sprite_font_create_from_msdf(device, defaults_msdf_font(device))` uploads the
embedded atlas and creates an owned Sprite_Font with the MSDF material and
distance-range uniform. Destroy it with `sprite_font_destroy` before destroying
the device. Its CPU source remains owned by the device defaults.
TTF loading also supports the first face of TTC files; glyph repertoires are
supplied to `sprite_font_create_from_font` by the host.

## Licenses

jfoster port: MIT (same as Foster). Vendored components keep their own licenses:
SDL3 (zlib), stb_truetype (public domain / MIT), miniz (MIT), Roboto (Apache-2.0).
