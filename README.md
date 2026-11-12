# JaiLib

Jai（beta 0.2.009）游戏/图形库集合，形状对标 [DragonLib](../DragonLib)
（C# 的 Foster 生态框架）：**纯库 + 示例 + 工具**，不带游戏工程。
图形/平台层走本地 [jfoster](../jfoster)（Foster 框架的 Jai 移植：
SDL3 + SDL_GPU，D3D12/Vulkan 后端）。

对标范围是 DragonLib 的 `Libs/Engine` 通用能力。DragonLib 已将 ECS
接入拆到可选的 `Libs/Engine.ECS`；JaiLib 不承担 DragonECS、System /
Pipeline、ECS 实体检查器或 ECS 预制体/关卡序列化的移植。

Engine 的导入、初始化、绘制及各模块用法见
[Engine 使用说明](Libs/Engine/README.md)。

> 前身是 Ascension（Odin + raylib 2D 游戏）的完整 Jai 移植，已完成历史
> 使命（验证整条渲染栈后于 2026-09 退役，git 历史可回溯）。

## 结构

```
Libs/
  Engine/                 # 引擎库（对标 DragonLib Libs/Engine）
    game_app/             #   对应 GameApp：生命周期入口、命令行参数与可选 CLI
    container/            #   纯 CPU 库（对标 Engine/Core 域，零图形依赖）：
    debug/                #     container 定长数组 / debug 分配器调试 /
    encoding/             #     encoding CSV+JSON+XML / entities 实体容器 /
    entities/             #     handle 句柄池（≈ SlotMap/SlotHandle）/
    handle/               #     asset 资源管线 v1 / audio Sound_Player 封装 /
    asset/                #     profiler 作用域计时 / tween 补间系统
    audio/                #   （各目录自带 module.jai，目录名即模块名）
    profiler/
    tween/
    world/                #   SceneRouter 与过渡计时
    messaging/            #   CommandQueue / BroadcastChannel
    threading/            #   持久 worker、有界队列、range jobs
    storage/              #   GameStorage 资源/存档接口、目录后端
    storage_assets/       #   GUID blob 资源加载适配器
    graphics_assets/      #   GPU 纹理引用缓存、JSON 图集和多页打包
    editor/               #   可选 ImGui 帧封装、反射属性编辑器与 GUID 资源选择器
    gfx/                  #   2D 图形库（依赖 jfoster，对标 Engine 渲染域）：
                          #     全局 Batcher + 阶段式 pass + 全屏 shader blit +
                          #     raylib 风格兼容层 + Camera2D（无需 ImGui）
    text/                 #   MSDF / TTF、动态补字、回退链、HarfBuzz run 排版
    bindings/             #   UI 绑定（渲染后端走 jfoster）：
                          #     imgui_foster（DrawData→Batcher/键位/剪贴板/光标）、
                          #     clay_foster（rect/border/text + scissor 栈）、
                          #     clay/（clay UI 库绑定 + 预编译 clay.lib）
Tests/                    # 测试 + 端到端示例（对标 DragonLib Tests/）
  game_app_demo.jai       #   新游戏起点，自持 Batcher 和字体，可选 CLI
  game_app_tests.jai      #   生命周期、启动前 CLI 排队与主线程执行验证
  run_tests.jai           #   单元测试入口（348 断言）+ test_support.jai
  dual_camera2d_demo.jai  #   对应 DragonLib DualCamera2DDemo（跟随/总览双视口）
  entities_demo.jai       #   对应 DragonLib EntitiesDemo 的 8 类性能测试
  camera_tests.jai        #   相机往返变换 + jfoster TRS 枢轴回归（45 断言）
  default_resources_tests.jai # 默认 shader / Roboto 内嵌与 GPU 像素回归（32 断言）
  font_demo.jai            #   默认 MSDF / 中文 TTF 的可视化示例与 GPU 像素回归
  engine_core_tests.jai   #   大容量句柄、场景/消息/Job/XML 回归
  engine_graphics_tests.jai # GPU 引用/图集像素、clay 图片和自定义绘制
  editor_demo.jai         #   可交互属性抽屉与资源选择器，auto 键盘验证
  gutwall_demo.jai        #   Gray-Scott 纹理生成、法线/湿润光照、PNG 导出
  web_probe/              #   WASM64 CPU 编译与执行探针
  fluid2d/                #   多 Target/多 pass/自定义 shader 技术示例
                          #  （GPU 流体 + 水墨后处理 + 相机，main.jai + shaders/）
  imgui_demo.jai          #   ImGui 回归示例（"auto" = SDL 事件注入端到端断言：
                          #    聚焦→你/a/b→Backspace，PASS/FAIL + 退出码；
                          #    "ime" = 打印真实输入法文本事件的调试模式）
  clay_demo.jai           #   clay UI demo（"auto" = 180 帧退出）
  audio_demo.jai          #   程序生成正弦 WAV 播放（无窗口）
Tools/
  compile_shaders.bat     # HLSL → DXIL + SPIR-V（借 DragonLib 的 shadercross）
  build_harfbuzz.ps1      # 固定上游版本重建 HarfBuzz Windows DLL
  Build-Shaders.ps1      # 临时编译成功后发布 shader 与 SHA-256 清单
  Verify-Shaders.ps1     # 构建前拒绝过期源码、损坏或缺失产物
  probe_web.ps1          # WASM64 CPU 可行性；可附加 gfx 编译诊断
  stage_runtime.bat      # SDL3/stb/miniz/HarfBuzz；参数 editor 才复制 ImGui
```

## 新树最小示例（core/ + kit/）

`run_hello_kit.bat` 只用新树，不碰 `Libs/Engine`：

```
jfoster           窗口 / SDL_GPU 设备 / 生命周期
kit/world         Camera2D（世界 → 屏幕矩阵）
kit/rendering/material  材质库 + 内置 Sprite 材质（借用 jfoster 的默认 Batcher 着色器）
kit/rendering/2d        Render2D 合批绘制
```

`run_hello_kit.bat auto` 会画 120 帧，并在离屏 Target 上做一次 GPU 像素自检
（画白色方块 → 读回中心/角落像素）——实测 `center=(255,255,255,255) corner=(0,0,0,255)`。

## 构建

- `run_tests.bat`：tlib 全部模块测试
- `run_gutwall_demo.bat auto`：GutWall Demo，D3D12/Vulkan 像素检查与退出取消验证
- `run_fluid2d.bat`：fluid2d 示例（复制运行时 DLL 与 Demo 自己的 shader）
- `run_clay_demo.bat`：clay UI demo
- `run_imgui_demo.bat`：ImGui demo（含输入管线自动验证）
- `run_dragonlib_demos.bat auto`：构建并运行默认资源、相机、实体、字体、Engine core/GPU 与属性编辑器回归
- `Tools\compile_shaders.bat`：改了 `Tests/fluid2d/shaders/hlsl/*.hlsl`
  后重编 shader blob 与 SHA-256 清单（需 DragonLib 检出；仓库已带编译产物）

需要：
- `jai.exe`（beta 0.2.009），路径在 bat 顶部 `JAI` 变量可改
- jfoster 检出（`%JFOSTER_PARENT%\jfoster`，默认 `D:\MySpace\Github\jfoster`）
- 仅使用 editor/ImGui 时需要根目录 `ImGui.dll`/`imgui.lib`（运行时 DLL + 导入库：`bindings/imgui_foster.jai`
  的 `#system_library "imgui"` 按名链接，Jai 的 ImGui 模块路径不在默认 libpath）
- jfoster 默认 shader / Roboto 图集编译时内嵌，不需要运行时 `content/`

## 运行

示例可从任意工作目录运行，也可双击 bin 下的 exe，gfx 不再修改工作目录。
fluid2d 自定义 shader 的源文件仍位于 `Tests/fluid2d/shaders/`，构建时仅将
编译产物复制到 `bin/fluid2d/shaders/`，启动时按 exe 所在目录读取。

```
bin\fluid2d.exe       # WASD/方向键平移，Q/E 旋转；"auto" = 240 帧退出
bin\clay_demo.exe     # "auto" = 180 帧退出
bin\imgui_demo.exe    # "auto" = 键盘/文本/删除端到端断言（PASS/FAIL）
bin\audio_demo.exe    # 播放 3 秒正弦后退出
bin\dual_camera2d_demo.exe  # WASD 移动、滚轮跟随缩放、Q/E 总览缩放、Space 旋转、R 重置
bin\dual_camera2d_demo.exe auto    # 120 帧；GPU 像素、resize、mesh/material 池上界断言
bin\dual_camera2d_demo.exe auto vulkan  # 强制 Vulkan（默认按驱动自动选择）
bin\entities_demo.exe  # 控制台运行 8 类测试，输出 mean/P95/ns per op；失败返回 1
bin\default_resources_tests.exe auto # 内嵌资源检查；加 vulkan 可验证 Vulkan
bin\font_demo.exe         # 内嵌 MSDF 与中文 TTF；auto 自动验证，vulkan 指定后端
bin\editor_demo.exe       # 反射属性编辑器与资源选择器
bin\engine_core_tests.exe # 无窗口基础模块验证
bin\engine_graphics_tests.exe vulkan # 纹理、图集和 clay 像素回归
```

`camera_tests.exe` 和 `entities_demo.exe` 是控制台程序：双击运行后保留
结果窗口，按 Enter 关闭；从已有终端运行时直接返回，传 `auto` 时也不会
等待。真正的相机图形窗口是 `dual_camera2d_demo.exe`。

## 渲染架构（gfx / jfoster / SDL_GPU）

- **全局唯一 Batcher**（`gfx/gfx.jai`）：2D 内容、imgui、clay、全屏
  shader pass 全部经同一 Batcher 提交；`gfx_pass_begin/end` 阶段式渲染，
  `gfx_blit_pass` 是带自定义片元 shader 的全屏/拉伸 pass。
- **shader**：HLSL 按 SDL_GPU 约定（`fragment_main` 入口、cbuffer
  `register(b0, space3)`、采样器 `register(t/s*, space2)`、成员全 float4
  对齐 + Jai 侧 `#assert size_of` 校验），shadercross 编 DXIL + SPIR-V，
  运行时按驱动选择。
- **坐标**：全链路左上原点 y 向下；窗口开 HIGH_PIXEL_DENSITY，合成时按
  backbuffer 物理像素尺寸（别硬编码窗口逻辑尺寸）。
- **对 jfoster 的本地补丁**（`D:\MySpace\Github\jfoster`）：
  1. `images/image.jai`：`read_entire_file` 补 `File.` 前缀（潜在 bug）；
  2. `input/states.jai`：`MOUSE_MAX_BUTTONS` 5 → 6（X2 越界）；
  3. `graphics/batcher.jai`：Batcher 改为 **mesh 环形缓冲**——原实现同帧多次
     `batcher_render` 共享一个 GPU mesh，而顶点上传走 cmd_upload、绘制走
     cmd_render、帧末才一起提交，后一次上传会覆盖前序 draw 要读的数据
     （单 render/帧的官方 sample 不受影响，多 render/帧必坏）；环形后每次
     render 用独立 mesh，槽位 k 固定承接每帧第 k 次 render，容量稳定。
     fluid2d 就是这条路径的回归测试。
  4. `graphics/graphics_device.jai`：`graphics_device_set_vsync` 里
     `for *state: d.windows` 双重指针（Table 的值本身已是指针）——该函数
     从未被调用过所以从未编译过，Jai 只编译被引用的函数，一调用就现形。
  5. `images/packer.jai`：打包页 blit 用整个共享 buffer 当源（每个字形都从
     buffer[0] 抄）——必须按 `s.BufferIndex` 切片。这是 **SpriteFont 图集
     自始就是周期性噪声（所有 HUD 文字显示为彩色碎片）的根因**。
  6. `graphics/batcher.jai` + `graphics/graphics_device.jai`：补齐 mesh 环形
     补丁的帧边界（`present_serial`）。原补丁没有任何 cursor 重置，mesh
     数量随 render 次数无限增长；新帧回到第 0 槽，同帧每次 render 分配
     独立槽位。同一份 CPU 几何重复 render 也必须上传到所选槽位，否则
     第二次 render 的 VertexBuffer 为空。双相机 auto 实测 120 帧稳定 6 槽。
  7. `graphics/batcher.jai`：material 池的 Clear 改为重置 head，不再把
     已属于池的指针重复追加；销毁 Batcher 时释放它拥有的 mesh、buffer
     包装对象与 material 副本。`gfx_shutdown` 配套销毁 Batcher 和源 Font。
  8. `utility/matrix3x2.jai`：旋转分支的枢轴平移必须包含 scale，原式
     忽略非单位缩放，导致绕 origin 旋转位置漂移；按本地 Foster
     `Spatial/Transform.cs` 的 T(-origin) * S * R * T(position) 修正。

上述 6–8 的修改位于相邻 **jfoster 仓库**，不是 JaiLib 内部副本；同步
JaiLib 时需要同步这些 jfoster 改动。既有 vsync / packer 本地修改保留。

## 与 DragonLib 的范围对照

已接入：Core 结构域（slotmap≈handle、容器、tween）、Encoding（CSV/JSON/XML）、
Entities、Audio、Assets（2D 域）、ImGui/clay 后端、
示例+测试的仓库形状。按 DragonLib 最新拆分，ECS 属于可选的
`Engine.ECS` 扩展，不纳入 JaiLib 的对标范围或功能缺口；游戏工程由
应用自行组织。

`Libs/Engine/entities` 是轻量实体容器，对应 DragonLib 仍保留在
`Engine/Core/Entities` 的通用容器；它不承担 ECS System 或 Pipeline
调度，现有 Entities Demo 继续作为容器正确性和性能测试。

2026-10-03 已补齐本轮 2D 基础范围：PropertyDrawer 与资源选择器、JobScheduler、
XML、SceneRouter、CommandQueue/BroadcastChannel、GPU 纹理引用管理、
命名图集 JSON 加载/多页打包、clay 图片缩放/CUSTOM/fontId，以及动态字体
补字、字体回退和 HarfBuzz run 排版。每部分用法和所有权约定见 Engine README。

仍按约定排除 ECS、3D、骨骼动画和物理集成。本库不是 DragonLib 的逐 API
兼容层；资源格式、场景生命周期和应用状态组织有各自的明确接口。

### 本地源码对照（2026-10-03 更新）

结论：JaiLib 遵循 DragonLib 的仓库组织和 Foster/SDL_GPU 的平台方向，
目前属于独立的 2D 库集合，尚未达到 DragonLib Engine 的功能等价。
本次对照采用拆分后的 Engine；`Engine.ECS` 中的接入代码不计入差距。
源码注释显示 Entities 源于 Odin 容器，Asset 管线源于 olib；相同领域名称
不代表照搬了 DragonLib 的 C# 实现。

| 领域 | DragonLib | JaiLib / jfoster | 对齐程度 |
| --- | --- | --- | --- |
| 仓库组织 | Libs / Tests / Tools | Libs / Tests / Tools | 已对齐 |
| 平台、2D 绘制 | Foster App / Batcher / SDL_GPU | jfoster + gfx 全局 Batcher、多 pass | 方向一致；Batcher 生命周期缺陷已补回归 |
| 相机 | Camera2D：PPU、视口、正向旋转、可逆查询 | CameraState：offset、zoom、负向旋转、鼠标逆变换 | 行为适配，API 和旋转符号不同；矩阵顺序已修正 |
| 实体容器 | 分类型池；int 索引、uint generation；自动组件注册 | Base 首字段；u32 索引、u64 创建序号；显式类型列表 | 大容量与旧句柄失效已验证；每类型固定容量 |
| 资源 | AssetDatabase / Registry / Scanner + Dasset | GUID/meta → blob；GPU 引用缓存、命名图集与打包 | 独立格式与接口，生命周期已接通 |
| 音频 | Foster.Audio 生态 | Jai Sound_Player 封装 | 提供相近基础 API，后端不同 |
| 编辑 UI | DearImGui 属性抽屉/资源抽屉 | editor 反射控件和 GUID 选择器；ImGui/clay | 通用属性编辑已接入，不含 ECS 检查器 |
| 场景切换 | Engine.World.SceneRouter，由应用调用 Update | world.Scene_Router | 场景状态与过渡计时已接入 |
| 消息 | Engine.Messaging.CommandQueue / BroadcastChannel | messaging | 命令批次与帧间广播已验证 |
| 线程调度 | Engine.Threading.JobScheduler | threading | 持久线程、有界队列、range 调度与 join |
| 3D、动画、物理 | Renderer3D / Dasset / skinning；Demo 接入 Box2D/Spine | 当前无对应集成 | 未对齐 |

这次移植两个能由现有库支撑的 DragonLib Demo：

- `DualCamera2DDemo.cs` → `Tests/dual_camera2d_demo.jai`：同一 arena、四个
  landmark、五个移动对象、玩家跟随与总览、独立缩放/旋转。原 ImGui
  控件改为键盘和 HUD，使用同一个 Batcher 的三个 viewport/overlay 提交。
  auto 额外用 64×32 Target 验证同帧不同几何、相同几何重复 render 的
  像素结果；每帧断言 mesh/material 池上界，并触发奇数窗口宽度的 resize。
- `EntitiesDemo.cs` → `Tests/entities_demo.jai`：保留 dense、50% sparse、
  component iteration、entity/component GetRef、raw dense、create reuse、
  destroy 共 8 类测试；固定 100,000 实体、4 次 warmup、25 次采样，输出
  mean/P95/ns per op。控制台形式，不包含原 ImGui 表格和 GC 分配统计。
  先创建全部 sparse 槽再删除一半，确保真的测量有洞的迭代。

JaiLib 实体容器的 `get_sub` 原先绕过 handle 有效性验证：destroy/reuse
后仍返回指针，非法 variant 会越界。现已复用 `get` 验证并检查组件注册。
`clear` 保留容器单调创建序号，防止清空后重用恢复旧句柄；
初始化检查容量/variant 上限；`get_buffer` 文档明确它包含已删除的洞。
generation 已升级为 u64，耗尽时拒绝新建；index/variant 为 u32。
Handle 为 16 字节，与旧版二进制布局不兼容。每类型容量最多为 s32 上限
减去保留槽，受实际内存限制；Demo 的大数组放在堆上避免 Windows 栈溢出。

验证入口：`run_dragonlib_demos.bat auto` 和 `run_tests.bat`。Demo 与测试
失败均返回非零退出码；旧单元测试入口的失败退出码也已补齐。fluid2d /
clay 的 auto 属于运行冒烟，不能替代像素正确性检查。

### 默认资源归属

JaiLib 根目录原 `content/` 的 27 个文件均是 jfoster 内置资源的重复副本，
现已移除。原始 HLSL、各后端 shader blob、Roboto JSON/PNG/许可证由
相邻 jfoster 的 `content/` 管理；`graphics/default_resource_data.jai` 在
编译期按模块源码位置读取并嵌入，不依赖编译或运行时的当前工作目录。
修改框架内置 shader 后需要重新编译应用，无需复制根目录 content。

默认资源回归验证三个 shader 的全部 18 个后端 blob、GPU shader 创建、
Roboto 图集/字形解析、资源缓存、许可证和离屏像素，并检查启动/退出不
改变 CWD。MSDF JSON 的多返回值、分配器调用、字形字段名等旧移植问题
也在实际加载内嵌字体时修正。

2026-10-03 已将内嵌 Roboto MSDF 接入 gfx 和 clay，默认初始化即可画字。
两者共用 `text` 的 UTF-8 测量与绘制，支持空格、换行、字距及缺字回退；
中文可通过 TTF/TTC 加载并按需补字。中文仍采用位图图集；内嵌字体
只有 ASCII。完整用法见 [Engine 字体说明](Libs/Engine/README.md)。

这部分依赖相邻 jfoster 的 `sprite_font_create_from_msdf`，并修正了
stb 字体结构 ABI、字体/图集释放，以及 PNG 编解码的 RGBA 格式、IO 参数
和返回缓冲区所有权。同步 JaiLib 时也需同步这些 jfoster 修改。
`font_demo` 验证实际字形像素、gfx/clay 一致性、多字号、半透明和相机矩阵；
现有默认资源测试仍负责资源加载及基础 shader 检查。

字体集成验证：D3D12 / Vulkan 各 38/38，覆盖动态补字、回退、fontId、
kerning、阿拉伯连字/RTL run 和组合附标；Windows 部署额外包含 harfbuzz.dll。
中文 Demo 使用本机字体，发行时需自行提供包含所需字形的字体文件。

本机验证结果（Jai beta 0.2.009 / Windows）：单元测试 348/348，相机与 TRS
45/45，Entities Demo 18/18；双相机在 D3D12、Vulkan 分别通过 120 帧、
720 项检查，mesh 维持 6 槽且 material 池不增长。fluid2d auto 240 帧正常
退出；ImGui auto 的中文文本注入及 Backspace 检查 PASS。这些结果覆盖
所测路径，不代表全部 jfoster API 或其他平台已经验证。

新增 Engine core 34/34，GPU 资源/图集/clay 在 D3D12 与 Vulkan 各 21/21，
属性编辑器 6/6（含文本编辑与资源选择）。`run_tests.bat` 包含 core；`run_dragonlib_demos.bat auto`
包含全部新 Demo。字体是 run 级 shaping，不包含完整段落双向算法与编辑器；
XML 为非验证的 UTF-8 配置树，图集 JSON 使用 Engine 自身格式。Linux/macOS
未在本机验证。具体边界及可运行调用示例已写入 Engine README。

GameStorage 新增 28/28，GutWall 生成器 7/7；`run_tests.bat` 现共验证 417 项
CPU 断言与 4 项 shader 清单检查。GutWall 在 D3D12/Vulkan 各通过 17 项 GPU
检查，退出取消任务 1/1。普通 gfx 在不部署 ImGui.dll 的独立目录中通过默认资源
32/32。WASM64 消息、场景和内嵌存储已在 Node 24.19.0 执行通过，Web 图形后端尚待接入。

移除 content 后，已将 exe、DLL 和 fluid2d 自己的 shader 复制到独立目录，
从空 CWD 再次验证：默认资源在 D3D12 / Vulkan 各 32/32，双相机两个
后端均 PASS，fluid2d/clay 正常退出，ImGui 输入检查 PASS。直接从空目录
调用 PATH 中的 `jai` 编译默认资源测试也通过；jfoster Triangle 的 GPU
像素验证 PASS。内置资源源文件仅在编译时需要，运行时无需检出仓库。

## Jai 移植说明（与 Odin 的关键差异，tlib 时代沉淀）

- **命名空间**：`X :: #import "路径"` 隔离同名类型；每包目录有 module.jai
  聚合入口（`#load` 文本合并，符号随 #load 传递；`handle` 因 4 个子实现
  顶层符号同名，改用 `HA`/`HMF`/`HMG`/`HMV` 命名空间别名聚合）。
- **语法**：无 `using`（字段显式访问）、无 `switch`（用 `if x == { case; }`）、
  过程参数不可变（需拷贝）、`remove`/`delete` 等为保留字（改名）、结构体
  字段用分号、解引用 `<<x`、取地址 `*x`、浮点字面量默认 float32、range
  `0..n` 含终点、字符字面量不支持转义（用 `"x"[0]`）、多返回值 return
  需解构。
- **运算符**：跨模块运算符不可见（按词法作用域解析），需具名过程重声明
  （见 `gfx/camera.jai` 的 `matrix_mul`、tlib handle 测试的 `operator ==`）。
- **#c_call**：回调内不要用无参 `push_context` 调本地过程（jai 0.2.009
  会随机崩溃）——clay 测量显式恢复字体创建时保存的 context，imgui 剪贴板经 SDL
  `#foreign`。
- **反射**：`cast(*Type_Info)` 运行时反射替代 Odin 的 `reflect`。

## 测试

```
run_tests.bat        # 或: jai -no_cwd -import_dir Libs/Engine -import_dir Tests Tests/run_tests.jai
```
