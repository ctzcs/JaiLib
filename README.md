# JaiLib

以 olib 为参照的 Jai 游戏库集合。运行时已内置在 `foster/`，库、测试和工具都从本仓库导入，
不需要同级 jfoster。验收编译器：jacket `jaic` 0.35.1。

## 目录

| 路径 | 内容 |
| --- | --- |
| core/ | 句柄、数据容器、编码、几何、协程、补间、资源格式和开发辅助 |
| foster/ | Foster 的 Jai 运行时：SDL3/SDL_GPU 桌面后端和 wasm64/WebGL2 后端，含原生依赖与默认资源 |
| kit/ | 世界/相机、2D/3D 渲染、shader/material、UI、音频、资产、工具面板 |
| thirdparty/clay/ | 纯 Jai Clay 移植与许可 |
| thirdparty/imgui/ | Jai 绑定、Foster 后端、配套 ImGui.dll 与 imgui.lib |
| thirdparty/onet/ | 网络复制、UDP/ENet、场景与预测回放 |
| thirdparty/voice/ | Opus/RNNoise 绑定、PCM 缓冲与语音收发 |
| assets/ | 正式字体、图标及来源/许可记录 |
| tests/ | 第一方与集成测试；Foster 回归在 foster/tests |
| tools/ | 统一检查、Jai 工具启动、shader、字体、图标、新项目和 wasm 构建 |
| prompts/ | 面向 Jai 的新项目、数据/依赖、编辑工具约定 |
| docs/ | 编码规范、移植差异和当前对位状态 |

`onet`、`voice` 已迁入 Jai 实现和行为测试，见 [onet](thirdparty/onet/README.md) 与
[voice](thirdparty/voice/README.md)。voice 测试需通过 `VOICE_LIB_DIR` 提供 Opus/RNNoise 原生库。
详见 [当前对位表](docs/OLIB_PARITY.md)。

## 检查和构建

```powershell
python tools/check/main.py
python tools/check/main.py --only core
python tools/check/main.py --only kit
python tools/check/main.py --web
```

脚本从自身位置确定库路径，可从任意目录调用。`JAIC` 可指定编译器，默认查 PATH，
本机安装还可识别 `D:/Lib/jacket-windows-x64/jaic.exe`。所有检查使用仓库内 Foster/ImGui。
类型检查带 `-no_dce`，同时检查错误文本与退出码；测试和日志在 `build/check`。
`--web` 需 wasm linker 与 Chrome/Edge，参数见 [wasm 构建入口](tools/wasm/build.py)。

检查也构建 `build/check/hello_kit.exe`；运行时加 `auto` 会做 GPU 像素检查并在 120 帧后退出。
Windows 运行所需 DLL 自动复制到构建目录。根目录不再保留旧的四个 run_*.bat。

应用导入：

```jai
F :: #import "foster";
World :: #import "kit/world";
```

编译添加 `-import_dir <JaiLib绝对路径>`；不再使用 JFOSTER_PARENT。
`thirdparty/imgui` 的绑定与本目录二进制保持 ABI 配套，不从编译器全局 ImGui 模块取另一份声明。

## 工具

- [tools/check](tools/check/README.md)：模块检查、core/kit 行为回归与可选 Web 验证。
- [tools/new-game](tools/new-game/README.md)：创建独立 Jai 游戏，含 core/core_editor/editor/game、状态测试和构建入口。
- [tools/shaders](tools/shaders/README.md)：共享 Jai 解析器的 .oshader/HLSL 编译、清单读回和过期检查。
- [tools/auto_gen](tools/auto_gen/README.md)：已有 Jai 声明扫描器的枚举生成 CLI。
- [tools/fonts](tools/fonts/README.md)、[tools/icons](tools/icons/README.md)：带校验的离线资产工具。
- [tools/zed-shader](tools/zed-shader/README.md)：.oshader 编辑器语法扩展，语法名沿用文件格式约定。

```powershell
python tools/new-game/main.py ../MyGame MyGame
python tools/wasm/build.py
python foster/tests/wasm/verify_webgl.py --gpu
```

新项目默认是可运行的静态桌面开发/游戏入口。jacket CLI 尚无共享库输出选项，
因此不生成假的 DLL 热替换命令；Web 游戏模板发布也不等同于已通过的 Foster Web 回归。

## 开发约定

[AGENTS](AGENTS.md) · [编码规范](docs/CODE_STYLE.md) · [Jai 移植说明](docs/PORTING.md) ·
[新项目约定](prompts/new-project.md) · [数据约定](prompts/dod-guidelines.md) · [编辑工具约定](prompts/editor-guidelines.md)

正式资产放 assets，构建产物放 build，诊断/截图放 library 下对应子目录；不复制依赖仓库和临时构建树。
Foster 来源及本地调整记录在 [LOCAL_CHANGES](foster/docs/LOCAL_CHANGES.md)。
