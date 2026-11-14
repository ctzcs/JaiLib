# Box3D for Jai

Box3D **0.1.0**, using the C source snapshot distributed in
[Odin vendor/box3d](https://github.com/odin-lang/Odin/tree/master/vendor/box3d).
This is a Jai C ABI binding to the native 3D physics engine, not a Jai rewrite and
not a Jolt wrapper. No Odin installation is needed to use it.

```jai
P :: #import "thirdparty/box3d";

main :: () {
    world_def := P.b3DefaultWorldDef();
    world_def.gravity = .{0, -10, 0};
    world := P.b3CreateWorld(*world_def);
    defer P.b3DestroyWorld(world);

    body_def := P.b3DefaultBodyDef();
    body_def.type = .b3_dynamicBody;
    body_def.position = .{0, 4, 0};
    body := P.b3CreateBody(world, *body_def);
    shape_def := P.b3DefaultShapeDef();
    sphere: P.b3Sphere = .{radius = 0.5};
    P.b3CreateSphereShape(body, *shape_def, *sphere);
    P.b3World_Step(world, 1.0 / 60.0, 4);
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

The API preserves C names, enums, field names and documentation. Initialize creation
parameters using `b3Default*Def()`. The ID macros `B3_IS_NULL`, `B3_IS_NON_NULL` and
`B3_ID_EQUALS` are provided as Jai procedures. Box3D joint definitions use a `base`
field containing bodies and local frames; this differs from Box2D 3.1.1.

Callbacks must be `#c_call`; their context data must remain valid for the registration
lifetime. Keep hull/mesh/height-field data alive for the shape lifetime and release
it with the corresponding upstream destroy function when applicable. Event pointers
are borrowed and cannot be retained across stepping or destruction. Custom worker
callbacks must implement the upstream scheduling and completion contract.

## Verification and coverage

```powershell
python tools/check/main.py --only box3d
```

Tests compare 889 C size/alignment/offset values, link all 699 exported procedures
(including 121 inline-function bridges), check version and single precision, and
exercise a sphere falling onto a hull, contacts, filtered ray casts, Jai overlap
callbacks, sensor entry/exit, distance joints, ID round trips/invalidation and native
allocation accounting across repeated world creation/destruction.

Declarations also cover capsules, meshes, height fields, compounds, remaining joint
types, debug drawing, recording/replay and collision/math utilities. Linking and ABI
checks cover these APIs, but their complete behavior is not separately validated.
No renderer or Foster integration is imposed by this module.

Two upstream declarations are omitted: `b3InternalAssert` is absent from release
builds, and `b3World_DumpShapeBounds` has no implementation in this snapshot. They
are not silently stubbed. Other preprocessor configuration/assertion macros are not
Jai APIs. [BINDINGS.json](BINDINGS.json) lists exclusions and API counts;
`native/<target>/BUILD.json` records toolchain flags and binary hashes.

All five target combinations have passed C layout assertions, full symbol linking
and Jai `-check -no_dce` checks. The unified command also verifies every bundled
source/archive hash and runs the behavior tests on the **current host**. Windows x64
and Linux x64 (WSL Ubuntu) behavior tests passed with jacket 0.35.1. macOS and Linux
ARM64 binaries were cross-built and linked, but their runtime behavior has not been
executed on those target systems. Cross checks do not count as runtime passes.

## Source and rebuilding

`upstream/` preserves the C headers and implementation from the installed Odin vendor
snapshot. The reported version alone does not uniquely identify Box3D development
snapshots: [SOURCE.json](SOURCE.json) pins the copied files by SHA-256 and records
the original Odin reference hashes. The bundled libraries are built from these
copied sources, rather than linked from an external installation.

Upstream SPDX notices remain intact. [LICENSE](LICENSE) is the Box3D MIT license;
[ODIN-LICENSE](ODIN-LICENSE) preserves the reference project's notice. Jai bindings,
inline bridges and ABI probes are generated adaptations; upstream C is unmodified.
See [tools/physics-bindings](../../tools/physics-bindings/README.md) to regenerate.
