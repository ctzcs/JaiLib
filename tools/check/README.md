# 仓库检查

`python tools/check/main.py` 从任意工作目录运行；路径相对脚本定位。
`JAIC` 可指定编译器，默认查 PATH，再查本机已知的 jacket 安装。

- `--only core` / `--only kit`：检查、构建并运行相关层。
- `--only box2d` / `--only box3d`：校验五种目标的源码/二进制哈希和 Jai 声明，并在当前平台构建、运行 C ABI/符号及真实物理行为测试。支持 Windows x64、Linux/macOS x64 与 ARM64；跨目标声明检查不算运行验收。
- `--only "test kit"`：只运行已构建的 kit 测试。
- `--list`：列出实际检查项。
- `--web`：另构建 wasm 并运行 WebGL 真像素回归，需 Chrome/Edge。

产物和完整日志放 `build/check/`。类型检查带 `-no_dce`，同时检查错误文本与退出码。
仅有退出码 0 或已有旧 exe 不代表构建成功。core/codegen 维持既有未验收范围，未列为通过项。
桌面完整测试需要可写的用户存档目录；受限沙箱应授权实际测试，不修改生产存储语义来绕过失败。
