# tools/ — 说明

原项目（Ascension）的 `tools/` 是 **Odin 开发期代码生成器**，不属于游戏运行时：

- `atlas_builder_vendor/` — 第三方 vendor（aseprite 文件解析 + 图集打包库，Odin 实现）
- `assets_builder/` — 资源清单生成器（Odin）
- `csv_codegen/` — 从 CSV 生成代码（Odin）

本 Jai 移植版**未移植**这些工具（它们是 Odin 工具链的一部分，且 atlas_builder 是外部 vendor 库）。
对应的生成产物（`resources/` 图集、`config/*.csv`）已直接拷贝自原项目，游戏运行不需要这些工具。
需要重新生成资源时，请在 Odin 原项目运行 `gen.bat` 后拷贝产物。
