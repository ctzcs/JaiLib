# olib 对位状态

当前状态：2026-11-14。参照 olib `d3943f1b4608fdc22983ac57f73332f0ada1e3ae`。
目录存在不等于功能等价；下面区分已迁入、已验证和仍未移植的内容。

## 仓库整合

| 项 | JaiLib 落点 | 状态 |
| --- | --- | --- |
| Foster 运行时 | foster/ | 从 jfoster 工作树迁入，模块名统一为 foster，原生依赖/默认资源随库 |
| ImGui | thirdparty/imgui/ | DLL、导入库、Jai 声明与 Foster 后端同目录；输入/生命周期回归通过 |
| Clay | thirdparty/clay/ | 保留已有纯 Jai 实现，补齐来源许可 |
| 字体、图标 | assets/ | 按参照仓库逐字节复制正式资产与许可/来源记录 |
| prompts、AGENTS | prompts/、AGENTS.md | 按 Jai 模块、内存、编译器能力重写；非 Odin 命令替换壳 |
| 检查入口 | tools/check/main.py | 取代根目录四个批处理，自动发现模块并检查完整过程体 |
| 字体/图标/Zed 工具 | tools/fonts、icons、zed-shader | 复用与语言无关的工具及测试，保留 .oshader 格式命名 |
| 新项目 | tools/new-game | Jai 四目录模板、状态测试、游戏入口与 ImGui 开发入口 |
| Shader | tools/shaders | 使用现有 Jai parser/manifest reader；HLSL/.oshader 与产物哈希检查 |
| Codegen CLI | tools/auto_gen | 接入已有 Jai scanner 的 kind_enum；不声称完整 AST 能力 |

## 运行时与库

- core：既有句柄、entities、encoding、curve、coroutine、localization、geometry、meshutil、
  dasset、tween、messaging、profiler、debug、devbuild、hotreload 实现保留；统一入口运行现有回归。
- kit：既有 world、rendering、ui、gizmo、animation、asset、audio、storage、app、tools 实现保留，
  导入改为仓库内 Foster；不额外创建一层引擎转发模块。
- Foster：SDL3/SDL_GPU 桌面后端以及 wasm64/WebGL2 后端均已存在。Web 不是未迁移项。
  已验证 render-to-target 方向、局部读写/blit、1x/4x MSAA、热替换及 3,000 帧资源稳定性。
  原生和 Web 的平台/原生工具限制见 foster/internal/web/README.md。

## 明确缺口与适配差异

| 项 | 当前状态 |
| --- | --- |
| thirdparty/onet | 库和 242 组原测试已迁移，另加密码学已知答案测试；243 组、27,237 断言通过；原示例和独立 CLI 未翻译，见 thirdparty/onet/README.md |
| thirdparty/voice | Jai 实现与 20 组测试已迁移；真实 Opus/RNNoise 4,616 断言通过，原生库需自行提供 |
| ImGui 的其他平台/后端 | 本仓库交付 Windows ABI 与 Foster 后端；未迁入 Odin 的全部后端和 wasm 对象 |
| core/codegen 全面对位 | 维持原独立验收范围；新增工具仅覆盖现有 scanner 的枚举生成入口 |
| DLL 热重载编译链 | core/hotreload 的监听/加载已可用。jaic 命令行没有共享库开关，但 Compiler 元编程 API 的 `Build_Options.output_type = .DYNAMIC_LIBRARY` 能产出 DLL：示例 `src/hotreload/build.jai` 在编译期生成模块，宿主用 `session_library_*` 加载并在源码变动后换新（已在 Windows 上跑通 build → load → swap）。`hot_command` 仍拼 Odin 参数，Jai 侧由调用方传自己的构建命令 |
| 新项目模板 DLL/Web 发布 | 当前模板为静态桌面开发和游戏入口；需另接支持共享库的 Jai 构建器及 Web 游戏宿主 |
| kit/material Web 清单 | Foster 已支持 WebGL2，但 material 预编译目录登记仍拒绝 wasm，尚未接 GLSL 清单 |
| 跨平台 native 验证 | 本次在 Windows 验收；不把预置二进制或条件编译当作 Linux/macOS 实测 |

上述缺口不会被统一检查伪装成已通过。完整命令和报告位置见根 README。
