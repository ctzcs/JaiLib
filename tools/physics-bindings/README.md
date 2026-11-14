# Physics bindings

Builds Box2D/Box3D static libraries for Windows x64, Linux x64/ARM64 and macOS
x64/ARM64 from the pinned sources in `thirdparty/<library>/upstream`. Normal
consumers use the bundled libraries and only need jacket and the platform runtime.

## Build native libraries

Python 3 is required. Windows builds use MSVC/Windows SDK; Visual Studio is discovered
automatically, or use an x64 Native Tools prompt. Linux/macOS builds use Zig (validated
with 0.17.0), on any host. Put `zig` on `PATH`, set `ZIG`, or pass `--zig <executable>`.
Cross compilation does not require a separate Linux sysroot or macOS SDK.

```powershell
python tools/physics-bindings/build.py --target all          # from Windows with MSVC + Zig
python tools/physics-bindings/build.py --target linux_x64
python tools/physics-bindings/build.py box3d --target macos_arm64
python tools/physics-bindings/build.py --run                 # build + C smoke on the current host
python tools/check/main.py --only box2d
python tools/check/main.py --only box3d
```

Targets are `windows_x64`, `linux_x64`, `linux_arm64`, `macos_x64`, `macos_arm64`.
`--target` defaults to the current host. `--run` rejects foreign targets instead of
silently skipping execution. Windows cross builds from Unix are not provided.

Windows uses `/MD /O2 /DNDEBUG`. Unix targets use PIC, single precision, `-O2 -g0`,
disabled FP contraction, and baseline CPU features (SSE2 on x64, NEON on ARM64).
Linux targets glibc 2.28+, macOS targets 11+. No fast-math or AVX2 requirement is added.
Each native directory has a `BUILD.json` with compiler/version/flags, source-manifest
and helper hashes, archive hashes, and the build-time verification results.

Every build compiles C layout assertions matching the Jai declarations and links
every exported procedure, including inline bridges, into a target executable. The
optional native smoke runs layout probes, creates a world, steps a falling body and
checks allocation accounting. The Jai behavior suite is the stronger runtime check.

`tools/check/main.py --only box2d` (or `box3d`) validates all source/archive hashes,
checks Jai declarations for all five targets with `-no_dce`, then builds and runs
the behavior tests on the current host. To run only the package/target checks:

```sh
python tools/physics-bindings/check.py --jaic /path/to/jaic
```

Windows x64 and WSL Ubuntu x64 Jai behavior tests passed with jacket 0.35.1. macOS
and Linux ARM64 have passed cross compilation/layout/link/declaration checks, but
have not been runtime-tested on target machines. Run the unified checks on those
hosts before treating their behavior as validated.

## Regenerate Jai declarations

The canonical header translation currently runs on Windows x64 using jacket
`jaic`/`jaifmt` (validated with 0.35.1) and the MSVC/Windows SDK headers. Put jacket
on `PATH` or set `JAIC`; `JAIFMT` optionally selects a different formatter.

```powershell
python tools/physics-bindings/generate.py          # both libraries + Windows binaries
python tools/physics-bindings/generate.py box2d
python tools/physics-bindings/build.py --target all # refresh every target after regeneration
```

The generator runs jacket's `Bindings_Generator` in interpreter mode. It normalizes
C zero initialization, procedure-pointer typedefs and the Box3D manifold forward
declaration, adds inline exports, then formats generated Jai files. The same public
layouts are verified against each target's C compiler rather than assumed from
Windows. `BINDINGS.json` records API counts and excluded declarations.

Logs and intermediate files go to `build/physics`. Generated sources are
`bindings.jai`, `helpers.c` and `tests/abi.jai`; native builds replace the selected
target's `.lib`/`.a` files. Stale helpers or archives fail checksum verification.
The tool does not download or update upstream sources. To update a snapshot, review
the API changes, licenses and `SOURCE.json` hashes explicitly, then regenerate and
run the behavior tests. Static archives can have different hashes after rebuilding
because the native tools include timestamps.
