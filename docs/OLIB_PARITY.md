# olib 一比一对位表

目标：JaiLib 以 [olib](../../olib)（Odin 游戏库集合）为唯一参照，逐模块复刻
目录、公开 API 形状、行为与测试；`foster/` 由相邻的 jfoster 承担。

参照版本：

| 项 | 版本 |
| --- | --- |
| olib | `d3943f1`（2026-11-11） |
| jfoster | `d291f4c`（2026-09-29），12,725 行 |
| 编译器 | jacket `jaic 0.35.1`（`D:\Lib\jacket-windows-x64`）；官方 Jai `beta 0.2.009` 仍作为回归基线 |

## 规模

| 层 | olib | JaiLib 现状 | 覆盖 |
| --- | --- | --- | --- |
| core | 16 模块 / 9,672 行 | 9 个对应目录 / ~5,300 行 | ~55% |
| kit | 10 模块 / 19,416 行 | ~2,100 行（asset / audio / storage / scene_router） | ~11% |
| tests | 65 文件 / 13,877 行 | 散落在 `Tests/`，非按模块对位 | 未对位 |

## core 对位

| olib 模块 | 行数 | JaiLib | 状态 |
| --- | --- | --- | --- |
| `core/handle` | 1,560 | `core/handle`（新建） | 已移植：soa/array/fixed/growing/virtual 五种（413 断言）；旧 `Libs/Engine/handle` 保留 |
| `core/entities` | 550 | `core/entities` | 已移植（137 断言） |
| `core/encoding` | 913 | `core/encoding` | 已移植：csv/json/ordered_json（584 断言）；XML 为扩展 |
| `core/tween` | 1,770 | `core/tween` | 已移植（64 断言，缓动位级对拍） |
| `core/messaging` | 112 | `core/messaging` | 已移植（27 断言） |
| `core/profiler` | 64 | `core/profiler` | 已移植（30 断言） |
| `core/debug` | 43 | `core/debug` | 已移植（40 断言） |
| `core/curve` | 121 | `core/curve` | 已移植（168 断言） |
| `core/coroutine` | 140 | `core/coroutine` | 已移植（58 断言） |
| `core/localization` | 211 | `core/localization` | 已移植（211 断言） |
| `core/geometry` | 465 | `core/geometry` | 已移植（9,590 断言，含网格对位） |
| `core/codegen` | 518 | `core/codegen`（不纳入） | 按 2026-11-12 决定跳过；代码保留未验收 |
| `core/devbuild` | 379 | `core/devbuild` | 已移植（32 断言） |
| `core/dasset` | 696 | `core/dasset` | 已移植（108 断言，与 Odin 输出逐字节一致） |
| `core/meshutil` | 777 | `core/meshutil` | 已移植（60 断言，索引/误差位模式一致） |
| `core/hotreload` | 1,180 | `core/hotreload` | 已移植并验证：api / scan（含 Windows 分支）/ session / watch / hot / simple + 102 断言。**真实 DLL 往返未跑**：jaic 只产可执行文件、不产共享库；`hot_command` 拼的仍是 `odin build -build-mode:dll`（换 Jai 编译器要改这一处或走 `Watch_Config.command`） |

## foster 对位（jfoster）

jfoster 是 **Foster 原版（C#，baseline `956da85` / post-v0.4.2）的 Jai 移植**，
不是 olib `foster/` 的逐行移植。所以比对要分两层。

| 项 | olib foster | jfoster |
| --- | --- | --- |
| 顶层库代码 | 22,499 行（14 个 .odin） | ~8,400 行（42 个 .jai，拆得更碎） |
| 测试 | 1,968 行 | 582 行（samples） |
| 平台层 | SDL3 + 自写 native/web 两套 | SDL3（native only） |
| 公开 proc（graphics） | 90（集中在 graphics.odin） | 207（按文件拆分 + getter） |

功能面基本对齐：gamepad / joystick / IME / stencil / scissor / uniform buffer
两边都有。**缺的是三类：**

1. **Web 目标**：olib 有 `platform_web.odin` + `web.odin`（701 行），jfoster
   整个仓库没有 wasm 相关代码。
2. **olib 在 Foster 之上加的扩展**（不属于 Foster 原版）：
   `olib_ext.odin`（167 行，`AppGetUserDataAs`、纹理采样等，登记在 olib
   `docs/LOCAL_CHANGES.md`）、`olib_shader_reload.odin`（56 行，`ShaderPairTryReplace`
   原位热替换）、`olib_storage.odin`（58 行）。
3. **命名/切分**：olib 把 batcher 的 solid/gradient 变体平铺成独立 proc，jfoster
   按 Foster 的 API 用参数表达；两者不能按符号名直接 diff。

对 kit 的意义：kit 依赖的 graphics / input / spatial / storage 核心面 jfoster 都有，
所以 kit 不必等 jfoster 补齐；只有 `kit/rendering/shader/dev`（着色器热重载）与
Web 发布需要先补上面 1、2 两项。

### jfoster 相对 Foster 原版的缺口（2026-11-12 补齐）

上一轮核对出的缺口已经补上：

| 模块 | 补了什么 | 验证 |
| --- | --- | --- |
| Input | `input/bindings.jai`（Binding/BindingState/BindingAxisOverlap + 5 种绑定）、`input/cursor.jai`、`input/sets.jai`（Action/Axis/Stick BindingSet + 过滤器）、`input/virtual.jai`（Virtual Input/Action/Axis/Stick/Device） | 17 + 176 条运行时断言，两个编译器都跑过 |
| Utility | `pool.jai`（Pool/Frame_Pool）、`stack_list.jai`（Stack_List + 4/8/16/32/64 构造）、`update_mode.jai`（从 app.jai 抽出） | 102 条断言 |
| Spatial | `point3.jai`、`ray.jai` | 89 条断言（含运算符、换算、归一化） |
| Storage | `content_storage.jai` + `internal/sdl3/SDL_storage.jai`（SDL_Storage 绑定） | 文件后端往返、只读拒绝、失败诊断 |

仍未移植：`InputProvider`（C# 的接口抽象，jfoster 直接吃 SDL 事件，没有对应层）；
`input.jai` 未把 `virtual_inputs_update` / 控制器通知接进 `Input` 结构体，应用层需手动串线。

### jfoster 的 SDL3 绑定策略（2026-11-12）

两条路，**不要混用**：

| | jfoster 自带（`internal/sdl3/`，1,910 行 / 183 个函数） | jacket `Extensions/SDL3`（7,619 行，SDL 3.4.18） |
| --- | --- | --- |
| 引入方式 | `#import "jfoster"`（`SDL3 :: #library` 在根 module.jai，单独 import internal/sdl3 会报 unknown library） | `#import "Extensions/SDL3"`，`#system_library` |
| DLL | 必须把 `SDL3.dll` 放在 exe 旁边（3.4.12） | jacket 自带 `native-libs/.../SDL3.dll`（3.4.18），不用带 |
| 编译器 | 官方 Jai + jacket 都能用 | 只有 jacket |
| 覆盖 | 只到 Foster 用到的子集 | 完整 API |

已补：`internal/sdl3/SDL_audio.jai`（设备流、转换流、WAV 解码，21 个函数）。
实测：`SDL_Init(AUDIO)` → 默认播放设备流 → 队列 76,800 B → 120 ms 后剩 35,840 B（确实在播）。
音频、线程、对话框这类 jfoster 没有的子系统，要么在 jfoster 里继续补（几十行），要么整体切 jacket 扩展——
但一个进程里只能有**一套** SDL 绑定，两套会加载两份 DLL（3.4.12 / 3.4.18），事件泵和 GPU 设备会各持一份。

### jfoster 的编译器兼容层（同日）

jfoster 原来只用官方 Jai 构建，而官方只编译被引用的代码，所以一批未被调用的代码里藏着错误；jacket 的 `-check` 会检查全部代码。已修：

- `graphics/batcher.jai`：`ifx x == { case }` → 运行时 `if`；`batcher_batch_count` 的 s64→s32
- `utility/calc.jai`：`**`（Jai 无幂运算符）展开、字面量窄化、运行时 `ifx`
- `spatial/shapes.jai`：`**`、`ifx`、`Vector2.{...}` 显式类型
- `internal/graphics_device_sdl.jai`：过程参数不可变 → 局部变量
- `graphics/texture_sampler.jai`：补 `Bound_Sampler` 的 `operator ==/!=`
- **`table_find`**：官方返回 `(value, found)`，jacket 返回 `(found, value)`。新增 `utility/table_compat.jai` 的 `map_get()`（走两边签名一致的 `table_find_pointer`），9 处调用已切换
- **`folder_exists / file_exists` 等**：两边 stdlib 都没有或签名不同，新增 `utility/folder.jai`（用 SDL 文件系统接口）与 `jf_file_exists/jf_file_delete`
- `utility/pool.jai`：官方 Jai 对「多行签名 + 泛型返回 + 过程类型字段」解析失败，改成单行签名 + `*Pool(T)`

现状：`jaic -check jfoster/module.jai` **0 error**；官方 Jai 仍能编译 `samples/window`；
JaiLib 的 `run_tests.bat` 照旧全绿。

## 第三方库（thirdparty/）

对齐 olib 的 `thirdparty/`：第三方绑定不再放在 `Libs/Engine/bindings`，已搬到仓库根的
`thirdparty/`（2026-11-12）。

| 目录 | 内容 | 对应 olib |
| --- | --- | --- |
| `thirdparty/clay/` | **Clay v0.14 纯 Jai 移植**（7 文件 / 约 7,000 行，不再链接 C 库）；与 Odin 版逐字节对拍：8 普通帧 1616 行 + 属性面板 1767 行 + 折叠行 973 行 **diff 全为空**，`MinMemorySize() == 6460992` 两侧相同 | `thirdparty/clay/`（Odin 移植） |
| `thirdparty/clay_foster.jai` | clay → jfoster 的渲染/输入后端 | olib 的 `kit/ui/ui_backend` 一侧 |
| `thirdparty/imgui_foster.jai` | ImGui → jfoster 后端（绘制/键位/剪贴板/光标） | `thirdparty/imgui/`（dcimgui 绑定） |

引用方式：`#import "thirdparty/clay/module"` / `"thirdparty/clay_foster"` / `"thirdparty/imgui_foster"`，
`-import_dir` 要包含仓库根。构建脚本已同步（`run_clay_demo.bat` 等）。

## kit 对位

| olib 模块 | 行数 | JaiLib | 状态 |
| --- | --- | --- | --- |
| `kit/world` | 855 | `kit/world` | 已移植：Matrix4 / Camera2D / Camera3D / Frustum3D / Ray3D / SceneRouter（108 断言） |
| `kit/animation` | 282 | `kit/animation` | 已移植（50 断言，与 Odin 707 个 float32 位模式对拍一致） |
| `kit/app` | 314 | `kit/app` | 已移植（51 断言，含真实 stdin 端到端） |
| `kit/asset` | 1,177 | `kit/asset` | 已移植：.meta/blob/manifest 契约（92 断言） |
| `kit/audio` | 412 | `kit/audio` | 已移植：设备/设备流/WAV 解码/目标 PCM/排队播放（37,680 断言，测试第一批 8/15 用例） |
| `kit/storage` | 163 | `kit/storage` | 已移植（49 断言） |
| `kit/rendering/2d` | 1,612 | `kit/rendering/2d` | 已移植：Render2D / Sprite 图集（Grid·Kenney·Aseprite）/ 动画集（116 断言） |
| `kit/rendering/shader` | 2,770 | `kit/rendering/shader` | 已移植并验证（1,030 断言，含 HLSL 逐字节黄金文本）；外部 shadercross/dxc 走可注入过程指针 |
| `kit/rendering/3d` | 1,628 | `kit/rendering/3d` | 已移植：Mesh/渲染队列/LOD/DebugDraw3D/uniform 打包（727 断言） |
| `kit/rendering/material` | 1,136 | `kit/rendering/material` | 已移植并验证（334 断言） |
| `kit/ui` | 2,762 | `kit/ui` | 已迁到 clay 0.14 原生 API（ElementDeclaration + UI 宏 + ClipElementConfig + clay 自带 `SetPointerHitTestFunction` 命中回调）；543,119 断言全绿 |
| `kit/gizmo` | 1,285 | `kit/gizmo` | 已移植：平移/旋转/缩放 gizmo、2D 变换、线框（99,010 断言） |
| `kit/tools` | 5,020 | `kit/tools` | 已移植：shader_lab / perf_overlay / scene_notes / tween_preview + lab_imgui 包装层；`-no_dce` 零 error，**测试未写** |

## 建议批次

1. **core 补齐**（纯 CPU，无平台依赖，先做）：curve → coroutine → localization →
   geometry → codegen → devbuild → dasset → meshutil → handle.virtual，并把
   entities / encoding / tween / messaging 按 olib 签名对齐，测试同批移植。
2. **core 平台件**：hotreload（Win32 文件监听 + devbuild 互斥）。
3. **kit/world**：Matrix4 / Camera2D / Camera3D / Frustum3D / Ray3D。
4. **kit/rendering**：shader 工具链 → 2d（Sprite/Atlas/Render2D）→ 3d →
   material。全部接 jfoster 的 SDL_GPU。
5. **kit/ui**：clay 布局 + 文本 + 控件 + 输入。
6. **kit/gizmo / animation / app / audio / storage 对齐**。
7. **kit/tools**：shader_lab、perf_overlay、scene_notes、tween_preview。
8. **tests 对位**：`tests/core/<module>` 与 `tests/kit/<module>` 一比一落位，
   用 `jaic` 编译、按 olib 的断言数验收。

## 移植约定

- 目录与包名照 olib（`core/xxx`、`kit/xxx/yyy`），一个包一个 `module.jai` 聚合入口。
- 公开符号名照 olib 的 snake_case；仅当 Jai 保留字冲突时改名并在文件头注明。
- 结构体字段顺序与含义照搬；Odin 的 `enum`/`union`/`bit_set` 用 Jai 等价物表达。
- Jai 无 `using`、无 `switch`、参数不可变、跨模块运算符不可见等差异，按仓库
  README「Jai 移植说明」处理，不做接口发明。
- 每个模块移植同时移植其测试，断言语义不变；测试通过 `jaic` 与官方编译器双跑。

## 老树退役（2026-11-13）

`Libs/Engine` 已删除。删除前的快照在 git commit `f672218`（"checkpoint: core/ + kit/ 一比一移植完成"），
需要找回旧实现或旧 demo 时 `git checkout f672218 -- Libs/Engine Tests/`。

同一批删掉的还有：

| 删除项 | 原因 |
| --- | --- |
| `Libs/Engine/**`（63 个 .jai） | 全部由 `core/` + `kit/` 覆盖；`container` / `threading` / `gfx` / `text` / `editor` / `game_app` 按决定不移植 |
| `Tests/*.jai`（18 个老 demo/测试） | 建在旧 `gfx` / `text` / `editor` / `game_app` 上；新树的测试在 `Tests/core` / `Tests/kit`，示例是 `hello_kit` |
| `Tests/{fluid2d,gutwall,web_probe}` | 同上（fluid2d 的 shader 走的是老渲染栈） |
| `thirdparty/clay_foster.jai` | 只被 `Tests/clay_demo.jai` 使用；`kit/ui` 有自己的 clay 后端 |
| `Tools/*`（shader 编译、harfbuzz 构建、web 探针等 8 个脚本） | 服务于已删除的旧 demo |
| 6 个 `run_*_demo.bat` | 同上 |
| `jails.json` | 引用已删除的 `Libs/Engine` 路径 |

`run_tests.bat` 改为依次调用 `run_core_tests.bat` 与 `run_kit_tests.bat`。

