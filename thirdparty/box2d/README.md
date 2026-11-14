# Box2D for Jai

Box2D **3.1.1** C ABI bindings for jacket Jai, following the native-library model of
[Odin vendor/box2d](https://github.com/odin-lang/Odin/tree/master/vendor/box2d).
The physics solver is the upstream C implementation. No Odin installation is needed
to use this package.

```jai
P :: #import "thirdparty/box2d";

main :: () {
    world_def := P.b2DefaultWorldDef();
    world_def.gravity = .{0, -10};
    world := P.b2CreateWorld(*world_def);
    defer P.b2DestroyWorld(world);

    body_def := P.b2DefaultBodyDef();
    body_def.type = .b2_dynamicBody;
    body_def.position = .{0, 4};
    body := P.b2CreateBody(world, *body_def);
    shape_def := P.b2DefaultShapeDef();
    circle: P.b2Circle = .{radius = 0.5};
    P.b2CreateCircleShape(body, *shape_def, *circle);
    P.b2World_Step(world, 1.0 / 60.0, 4);
}
```

Compile with `jaic -import_dir <JaiLib> <file.jai>`. `native.jai` selects the bundled
static libraries from the target OS and CPU; no manual path edits are needed.

| Platform | Architectures | Native build / runtime |
| --- | --- | --- |
| Windows | x64 | MSVC `/MD`, Microsoft Visual C++ runtime |
| Linux | x64, ARM64 | Zig C, glibc 2.28+, system libm/pthreads |
| macOS | x64 (Intel), ARM64 (Apple Silicon) | Zig C, macOS 11+, system libSystem |

The solver and inline helpers are statically linked; no physics DLL/shared library
is needed. All builds use single precision, optimization and assertions disabled
(`NDEBUG`). Windows ARM64, 32-bit, mobile and Web targets are not supplied and fail
explicitly. Do not replace a native archive with a different version or precision.

The API keeps the C names (`b2CreateWorld`, `b2BodyDef`, etc.), enum members and
field names. Use `b2Default*Def()` before changing creation parameters. The generated
file retains upstream API documentation. `B2_IS_NULL`, `B2_IS_NON_NULL` and
`B2_ID_EQUALS` are Jai equivalents of the C ID macros; null and stale IDs differ.

C callbacks use Jai `#c_call` procedures and the supplied `*void` context. Callback
data must outlive its registration; do not retain event arrays across a world step
or object destruction. The default world runs synchronously; applications providing
task callbacks are responsible for scheduling, completion and thread safety.

## Verification and coverage

```powershell
python tools/check/main.py --only box2d
```

The tests compare 570 size/alignment/offset values against an independently compiled
C probe, link all 494 exported procedures (including 73 inline-function bridges),
and run collision settling, contact events, filtered ray casts, overlap callbacks,
sensor entry/exit, distance joints, ID serialization/invalidation and repeated
world destruction with native allocation accounting. These are representative
behavior tests, not exhaustive tests of every solver feature.

The release build excludes the debug-only `b2InternalAssertFcn` declaration. Other
preprocessor configuration/assertion macros are not Jai APIs. There are no placeholder
solver functions. See [BINDINGS.json](BINDINGS.json) for API counts and `native/<target>/BUILD.json`
for toolchain flags and binary hashes.

Known upstream behavior: in 3.1.1, `b2ShapeDistance` only subtracts shape radii when
the initial distance exceeds `0.1 * B2_LINEAR_SLOP`. Two overlapping sensor circles
with nearly coincident centers can therefore miss an overlap (reproduced in pure C
as well as Jai). The sensor regression uses separated centers. This package preserves
the upstream implementation, including this limitation.

All five target combinations have passed C layout assertions, full symbol linking
and Jai `-check -no_dce` checks. The unified command also verifies every bundled
source/archive hash and runs the behavior tests on the **current host**. Windows x64
and Linux x64 (WSL Ubuntu) behavior tests passed with jacket 0.35.1. macOS and Linux
ARM64 binaries were cross-built and linked, but their runtime behavior has not been
executed on those target systems. Cross checks do not count as runtime passes.

## Source and rebuilding

`upstream/include` and `upstream/src` come from the official
[v3.1.1 archive](https://github.com/erincatto/box2d/tree/v3.1.1).
[SOURCE.json](SOURCE.json) records the archive hash, source hashes and the original
Odin reference hashes. The shipped libraries are rebuilt from these sources, not
linked from the machine's Odin installation. [LICENSE](LICENSE) covers upstream
Box2D; [ODIN-LICENSE](ODIN-LICENSE) preserves the reference project's notice.

Rebuild and regenerate with [tools/physics-bindings](../../tools/physics-bindings/README.md).
The handwritten ID macros and tests live separately from generated bindings.
