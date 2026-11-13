# JaiLib 测试

第一方用例镜像到 `tests/core`、`tests/kit`；集成检查在 `tests/tools` 和 `tests/thirdparty`。
Foster 的原有运行/像素回归在 `foster/tests`。

统一运行 `python tools/check/main.py`，类型检查使用 `-no_dce`。
`--only core` / `--only kit` 包含构建与运行，`--only "test kit"` 仅运行已有构建。
`--web` 额外执行真实 WebGL 像素回归。日志与可执行文件在 `build/check`。
root 的 `hello_kit` 是最小集成回归，不是业务示例仓库；自动退出/GPU 检查参数为 `auto`。

工具测试验证新项目拒绝覆盖、含空格路径构建、游戏/编辑器分离、代码生成过期检测、
shader 清单由运行时读回以及源码/产物哈希拒绝失配。字体工具测试不要求外部生成器。
平台能力或权限缺失需明确报告，不能把 skip 或旧 exe 当通过。
