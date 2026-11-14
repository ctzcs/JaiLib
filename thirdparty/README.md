# 第三方代码

目录命名沿用参照库的 `thirdparty/`。

| 库 | 当前落点与状态 |
| --- | --- |
| Clay | clay/：已有纯 Jai 移植，保留上游命名与 LICENSE.md |
| Dear ImGui | imgui/：Windows 配套二进制、Jai 声明和 Foster 后端；不依赖全局 ImGui 模块 |
| onet | [onet/](onet/README.md)：Jai 实现、原生 UDP/ENet、复制与预测回放，配套行为测试 |
| voice | [voice/](voice/README.md)：Jai PCM/收发管线、Opus/RNNoise 原生绑定与测试 |
| Box2D | [box2d/](box2d/README.md)：3.1.1 C ABI 绑定、Windows/Linux/macOS 静态库、内联桥接及物理行为测试 |
| Box3D | [box3d/](box3d/README.md)：Odin vendor 0.1.0 源码快照、单精度 C ABI 绑定、Windows/Linux/macOS 静态库及物理行为测试 |

Foster 私有 C 依赖仍由 `foster/internal/third_party` 管理，不作为业务层导入入口。
未迁入 Odin ImGui 的所有平台后端；不可将原有 wasm 对象直接用于 Jai 的不同 ABI。
