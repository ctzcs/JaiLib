# JaiLib 内置 Foster 的本地改动

来源：相邻 jfoster 工作树，基线 commit `4e676a2eedd41a6bc8c3286696610fab3aadda5c`，
并保留该工作树在 2026-11-14 已验证的 Web target 方向、深度附件、scissor、program 缓存修复。
这是源码及原生依赖的内置副本，不是 Git 子模块，不依赖相邻检出。

## L-001：收进 JaiLib（2026-11-14）

模块名改为 `foster`，回归样例归入 `foster/tests`，更新导入和工具路径；运行时实现不因迁移改写。
原生库、GLSL/预编译 shader、字体和配套工具随源树保留。仓库外 jfoster 保持原样。
Web 回归从统一 `tools/check --web` 接入；单独构建由 `tools/wasm/build.py` 提供。
