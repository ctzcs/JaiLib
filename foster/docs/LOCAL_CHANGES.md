# JaiLib 内置 Foster 的本地改动

来源：相邻 jfoster 工作树，基线 commit `4e676a2eedd41a6bc8c3286696610fab3aadda5c`，
并保留该工作树在 2026-11-14 已验证的 Web target 方向、深度附件、scissor、program 缓存修复。
这是源码及原生依赖的内置副本，不是 Git 子模块，不依赖相邻检出。

## L-001：收进 JaiLib（2026-11-14）

模块名改为 `foster`，回归样例归入 `foster/tests`，更新导入和工具路径；运行时实现不因迁移改写。
原生库、GLSL/预编译 shader、字体和配套工具随源树保留。仓库外 jfoster 保持原样。
Web 回归从统一 `tools/check --web` 接入；单独构建由 `tools/wasm/build.py` 提供。

## L-002：同帧上传顺序与批次合并（2026-11-14）

SDL_GPU 在已有 render pass 后收到新的缓冲上传时先提交先前绘制，避免独立上传命令
提前执行、覆盖先前 draw 所引用的实例/顶点数据。该正确性修复可能增加命令提交次数。
Batcher 合并回前一个批次时同时恢复 Elements，避免丢失之前的索引范围。
回归 `foster/tests/upload_order/main.jai` 连续三帧读回红/蓝区域，覆盖同帧两次上传与
无几何的 scissor 切换后合并；Windows/D3D12 实测通过，其他后端尚未运行。

## L-004：颜色打包和 QOI 大尺寸解码（2026-11-14）

先将通道或字节扩展到 u32，再左移；修复 Jai cast 优先级导致的高位截断。
颜色 RGBA/ABGR 和宽高超过 255 的 QOI 逐像素往返由 foster/tests/image_bytes 回归。

同一回归还覆盖 QOI RGBA 操作码、差分模 256 运算及编码尺寸字节掩码，避免透明度丢失和检查模式溢出。

颜色回归同时覆盖向暗色插值（先扩展为 float，避免 u8 回绕）、十六进制颜色转换与预乘 alpha。

## L-005：浮点颜色目标（2026-11-14）

追加 RGBA16F / RGBA32F 公共纹理格式（保留已有枚举值），补齐字节大小、颜色类型判断和 SDL/WebGL 映射。Shader Lab 不再将 Float16/Float32 降级为 COLOR。foster/tests/hdr_targets 实际绘制并读回 2.0 和 4.0，验证 HDR 不被截断。
