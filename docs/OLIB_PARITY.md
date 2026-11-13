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

对 kit 的意义：kit 依赖的 graphics / input / spatial / storage 核心面 jfoster 都有。

### jfoster 相对 olib foster 的缺口（2026-11-13 更新）

**已补齐**：

| 项 | olib 源 | jfoster 落点 | 验证 |
| --- | --- | --- | --- |
| `ShaderPairTryReplace`（L-012，shader 原位热替换） | `olib_shader_reload.odin`（56 行） | `graphics/shader_pair_replace.jai` + `internal/pipeline_for_draw_command.jai` | 真跑 24 项断言：地址不变、句柄换新、坏 probe 保留旧 shader 且仍能画 |
| `AppGetUserDataAs`（L-004） | `olib_ext.odin` | `app_ext.jai` | 8 槽侧表，未设置返回 null |
| 窗口逻辑尺寸（L-023） | `olib_ext.odin` | `app_ext.jai` | 边界值断言（0 分量 / 负值 / NaN / 超 INT_MAX） |
| 原子写（L-015） | `olib_storage.odin` | `storage_ext.jai` | 临时文件 + rename，无 `.tmp` 残留 |
| 存储读结果（L-024） | `olib_storage.odin` | `storage_ext.jai` | 文件 / ZIP / SDL_Storage 三后端真跑 |
| 纹理采样（L-018） | `olib_ext.odin` | `graphics/texture_ext.jai` | 深度/多重采样判定 |

jfoster 侧 `-check -no_dce` 零 error；扩展测试 57 项 + shader 替换 24 项全部真跑通过。
顺带修了 `storage/miniz_zip.jai` 里 `zip_open_archive` 分配后不置零导致 `mz_zip_reader_init_file` 随机失败的问题。

**未移植**：

| 项 | 原因 |
| --- | --- |
| **Web 目标**（`platform_web.odin` + `web.odin`，701 行） | jfoster 整个仓库没有 wasm/emscripten 代码；要重写平台层，属独立立项 |
| `InputProvider` | C# 的接口抽象，jfoster 直接吃 SDL 事件，无对应层 |
| `virtual_inputs_update` 未接进 `Input` 结构体 | 应用层需手动串线 |
| L-020（创建时按逻辑尺寸的 App 开关） | 要给 `App_Flags` 加成员，需改 `app.jai`；当前用显式 `window_apply_logical_size` |
| L-022（`SetTextInputArea`） | 未在移植清单内 |

