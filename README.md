# JaiLib

[olib](https://github.com/ctzcs/olib)（Odin 游戏库集合）的 Jai 复刻。
目录、模块边界、公开 API 与行为逐一对位；平台/图形层走相邻的
[jfoster](../jfoster)（Foster 框架的 Jai 移植：SDL3 + SDL_GPU）。

验收编译器是 **jacket `jaic` 0.35.1**（`D:\Lib\jacket-windows-x64`）。

## 结构

```
core/            基础库（无引擎依赖）
  handle/          句柄池 soa / array / fixed / growing / virtual
  entities/        轻量实体容器（union 变体 + 按组件迭代）
  encoding/        csv / json / ordered_json（xml 是 JaiLib 扩展）
  curve/           三次曲线采样（Linear/Bezier/Hermite/Catmull-Rom/B-Spline）
  coroutine/       单线程无栈协程（Flow / Cursor）
  localization/    字符串表、fallback、复合格式
  geometry/        最近点 / 距离与梯度 / 重叠 / 扫掠
  meshutil/        网格统计、拓扑边、焊接、压缩、QEM 简化
  dasset/          .dasset 模型格式（比特兼容 DragonLib v4）
  tween/           damp / interpolated / managed tween / sequence
  messaging/       CommandQueue / BroadcastChannel
  profiler/        作用域计时
  debug/           Tracking_Allocator
  devbuild/        开发期编译互斥、集中测试工作区、token 路径重写
  hotreload/       桌面 DLL 热重载：api / scan / session / watch / hot / simple
  codegen/         编译前代码生成（按决定跳过：不纳入对位范围）

kit/             扩展层（依赖 jfoster + core）
  world/           Matrix4 / Camera2D / Camera3D / Frustum3D / Ray3D / SceneRouter
  rendering/
    shader/        .oshader 解析、HLSL 生成、参数打包、编译/dev 热重载
    material/      材质库、std140、实例值
    2d/            Render2D、Sprite 图集（Grid / Kenney / Aseprite）、动画集
    3d/            Mesh、渲染队列、LOD、DebugDraw3D、uniform 打包
  ui/              clay 布局 + 位图/MSDF 字体 + 控件 + 变换感知命中测试
  gizmo/           平移 / 旋转-缩放 / 2D 变换 / 线框
  animation/       骨骼采样、palette、blend、蒙皮包围盒
  asset/           .meta 管身份、blob 边界、manifest 打包
  audio/           SDL3 设备流 + WAV 解码 + 目标 PCM 转换
  storage/         资源根 / 用户存档路径策略
  app/             CLI 参数 + 调试控制台
  tools/           shader_lab / perf_overlay / scene_notes / tween_preview

thirdparty/      第三方绑定（对齐 olib 的 thirdparty/）
  clay/            Clay v0.14 的纯 Jai 移植（不再链接 C 库）
  imgui_foster.jai ImGui → jfoster 后端（含 kit/tools 用的 lab_imgui 包装层在 kit/tools/）

Tests/
  core/<module>/   与 olib tests/core 对位
  kit/<module>/    与 olib tests/kit 对位
  kit/hello_kit.jai 新树最小示例（窗口 + 相机 + 2D 绘制）
  test_support.jai 共用的 expect / test_summary

docs/
  OLIB_PARITY.md   逐模块对位表（行数、状态、缺口）
  PORTING.md       olib → Jai 移植手册（Jai/jacket 的坑）
```

## 构建与运行

```bat
run_tests.bat          :: core + kit 全量回归（core 14 模块 11,594 断言；kit 13 模块 682,581 断言）
run_core_tests.bat     :: 只跑 core
run_kit_tests.bat      :: 只跑 kit
run_hello_kit.bat      :: 构建并运行新树最小示例（auto = 120 帧 + GPU 像素自检）
```

三个脚本都会自己 `cd /d "%~dp0"`，可以从任意目录调用或直接双击。
依赖两个路径，均有默认值、可用环境变量覆盖：

```
JAI              默认 D:\MySpace\RefProject\jai\jai\bin\jai.exe   （仅 legacy 构建用）
JAIC             默认 D:\Lib\jacket-windows-x64\jaic.exe          （验收编译器）
JFOSTER_PARENT   默认 D:\MySpace\Github                           （jfoster 的父目录）
```

## 最小示例

`run_hello_kit.bat auto` 只用新树：

```
jfoster            窗口 / SDL_GPU 设备 / 生命周期（App.startup/update/render/shutdown）
kit/world          Camera2D（世界 → 屏幕矩阵）
kit/rendering/material  材质库 + 内置 Sprite 材质（借用 jfoster 的默认 Batcher 着色器）
kit/rendering/2d        Render2D 合批绘制
```

`auto` 模式会画 120 帧，并在离屏 Target 上做一次 GPU 像素自检（画白色方块 → 读回中心/角落），
实测 `center=(255,255,255,255) corner=(0,0,0,255)`。

## 工具链约定

- **验收用 `jaic`，且必须带 `-no_dce`**：`jaic -check` 默认只检查 DCE 后可达的代码，
  不加这个参数时未被引用的过程体根本不会被检查。
- `jaic` 的 `-check` **退出码恒为 0**，有 error 也不会变成非零——脚本里必须 grep 输出里的 `error[`。
- 官方 Jai `beta 0.2.009` 只用于历史遗留脚本，不作为新代码的验收门槛。

## 移植说明

与 Odin 的差异（命名空间、无 `switch`、无数组算术、`a..b` 闭区间、运算符按词法作用域解析、
`\`defer` 是调用方作用域、`table_find` 返回顺序、`STRING.slice` 第三参是长度等）见
[docs/PORTING.md](docs/PORTING.md)；逐模块对位与缺口见 [docs/OLIB_PARITY.md](docs/OLIB_PARITY.md)。

## 历史

前身是 Ascension（Odin + raylib 2D 游戏）的完整 Jai 移植，2026-09 退役后转为
“对标 DragonLib / olib 的库集合”。2026-11 起按 olib 一比一重建为 `core/` + `kit/`，
旧的 `Libs/Engine`（raylib 风格 gfx、text、editor、game_app、container、threading）
已在移植完成后删除，历史见 git。
