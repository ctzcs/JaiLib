# JaiLib

A collection of Jai game libraries, with olib as the reference for functionality and scope.
The Foster runtime is included in `foster/`; libraries, tests, and tools import directly
from this repository. No sibling jfoster checkout is required.
Validated with jacket `jaic` 0.35.1 on Windows.

## Repository layout

| Path | Contents |
| --- | --- |
| core/ | Handles, containers, encoding, geometry, coroutines, tweening, asset formats, and development utilities |
| foster/ | Foster runtime for Jai: SDL3/SDL_GPU desktop and wasm64/WebGL2 backends, native dependencies, and default resources |
| kit/ | Worlds and cameras, 2D/3D rendering, shaders and materials, UI, audio, assets, and development panels |
| thirdparty/clay/ | Pure Jai port of Clay and its license |
| thirdparty/imgui/ | Jai bindings, Foster backend, and matching ImGui.dll and imgui.lib |
| thirdparty/onet/ | Network replication, UDP/ENet transports, scenes, prediction, and replay |
| thirdparty/voice/ | Opus/RNNoise bindings, PCM buffering, and voice send/receive pipelines |
| assets/ | Fonts, icons, provenance, and licenses |
| tests/ | First-party and integration tests; Foster regressions live in foster/tests |
| tools/ | Unified checks, Jai tool runner, shader/font/icon tools, project scaffolding, and wasm builds |
| prompts/ | Jai guidelines for new projects, data and dependencies, and editor tools |
| docs/ | Coding conventions, porting notes, and current parity status |

[onet](thirdparty/onet/README.md) and [voice](thirdparty/voice/README.md) include Jai
implementations and behavior tests. Voice tests require native Opus and RNNoise libraries;
set `VOICE_LIB_DIR` to their directory. See the [parity report](docs/OLIB_PARITY.md)
for implemented features and remaining gaps.

## Building and checking

```powershell
python tools/check/main.py
python tools/check/main.py --only core
python tools/check/main.py --only kit
python tools/check/main.py --only onet
python tools/check/main.py --only voice
python tools/check/main.py --web
```

The checker resolves repository paths relative to its own location and can be invoked
from any working directory. Set `JAIC` to the compiler executable, or put `jaic` on `PATH`.
It also recognizes the local installation at `D:/Lib/jacket-windows-x64/jaic.exe`.
All checks use the Foster and ImGui copies in this repository.

Module checks use `-no_dce` and inspect both diagnostics and exit codes. Test executables
and logs are written to `build/check`. Native network tests require local UDP/IPv6
loopback access. Voice tests fail if the required native libraries are unavailable.
The optional `--web` checks require a wasm linker and Chrome or Edge; see the
[wasm build script](tools/wasm/build.py) for options.

The checker also builds `build/check/hello_kit.exe`. Run it with `auto` to perform GPU
pixel checks and exit after 120 frames. Bundled Windows runtime DLLs are copied to the
build directory automatically. The unified checker replaces the four former root-level
`run_*.bat` scripts.

Application imports:

```jai
F :: #import "foster";
World :: #import "kit/world";
```

Compile with `-import_dir <absolute-path-to-JaiLib>`. `JFOSTER_PARENT` is no longer used.
The bindings in `thirdparty/imgui` match the ABI of its bundled binaries; use these
bindings instead of declarations from the compiler's global ImGui module.

## Tools

- [tools/check](tools/check/README.md): module checks, core/kit/onet/voice behavior tests, and optional Web validation.
- [tools/new-game](tools/new-game/README.md): standalone Jai game scaffolding with core/core_editor/editor/game modules, state tests, and a build entry point.
- [tools/shaders](tools/shaders/README.md): .oshader/HLSL compilation, manifest readback, and stale-output checks using the shared Jai parser.
- [tools/auto_gen](tools/auto_gen/README.md): enum generation CLI using the existing Jai declaration scanner.
- [tools/fonts](tools/fonts/README.md) and [tools/icons](tools/icons/README.md): offline asset tools with validation.
- [tools/zed-shader](tools/zed-shader/README.md): editor syntax support for the .oshader format.

```powershell
python tools/new-game/main.py ../MyGame MyGame
python tools/wasm/build.py
python foster/tests/wasm/verify_webgl.py --gpu
```

New projects provide runnable, statically linked desktop game and editor entry points.
The validated jacket CLI has no shared-library output option, so the template does not
provide a DLL hot-reload build command. Publishing a Web game from the template still
requires additional integration; the Foster Web regression suite validates the runtime.

## Development guidelines

[AGENTS](AGENTS.md) · [Coding conventions](docs/CODE_STYLE.md) · [Jai porting notes](docs/PORTING.md) ·
[New projects](prompts/new-project.md) · [Data guidelines](prompts/dod-guidelines.md) · [Editor tools](prompts/editor-guidelines.md)

Keep shipped assets in `assets/`, build outputs in `build/`, and diagnostics and screenshots
in the appropriate `library/` subdirectories. Do not copy dependency checkouts or temporary
build trees into the repository. Foster provenance and local changes are documented in
[LOCAL_CHANGES](foster/docs/LOCAL_CHANGES.md).
