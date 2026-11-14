# Dear ImGui (Jai)

The Jai bindings and Windows binaries are paired with **Dear ImGui 1.89.6 docking**,
upstream commit [`823a1385a269d923d35b82b2f470f3ae1fa8b5a3`](https://github.com/ocornut/imgui/tree/823a1385a269d923d35b82b2f470f3ae1fa8b5a3).
The base declarations originated in jacket 0.35.1. Docking changes the IO, Style,
Viewport and ImDrawData layouts; these declarations include those changes.
The backend checks sizes and key field offsets against the DLL before setup.
Do not substitute another ImGui DLL or the original jacket mainline DLL.

```jai
IG :: #import "thirdparty/imgui";
GUI :: #import "thirdparty/imgui/imgui_foster";
Dock :: #import "thirdparty/imgui/docking";
```

After setup, set `IG.GetIO().ConfigFlags_ |= .DockingEnable`. Call
`Dock.DockSpaceOverViewport()` before submitting the dockable windows. Use the
builder once to arrange the initial split; do not force window positions each
frame. See JaiLibSample's Shader Lab for split, undock, tab merge and redock checks.
Multi-viewport OS windows are not implemented by this Foster backend; leave
`ViewportsEnable` off. In-window docking is supported.

`native/` contains the unmodified pinned upstream sources and MIT license, plus
`jailib_docking.cpp`, a small C ABI bridge for the docking builder and ABI checks.
Rebuild with Visual Studio C++ build tools:

```sh
python tools/imgui/build.py
python tools/check/main.py --only kit
```

The build writes scratch files under `build/imgui-docking` and installs the paired
`ImGui.dll` and `imgui.lib` here. Stage the DLL beside every rebuilt executable.
`imgui.lib` is an import library, not an additional runtime DLL. The rest of the
API uses the existing C++ symbol bindings. This distribution targets Windows ABI.
