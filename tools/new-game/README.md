# 新建 Jai 游戏

`python tools/new-game/main.py ../MyGame MyGame`

目标目录必须不存在；项目名为字母开头的字母/数字/下划线，拒绝 Windows 保留名。
不会覆盖已有项目、初始化 Git、安装工具链或修改相邻项目。
生成 core、core_editor、editor、game 四目录，状态测试、构建入口、AGENTS 和带许可的默认资产。
核心状态可无窗口测试，开发入口带 ImGui 暂停/重置面板，发布入口不链接它。

默认资产包括 ImGui 的 Noto OTF、游戏用的 `assets/fonts/msdf/ui.png`/`ui.json`
（509 字形，有限中文字符）、字符集与 OFL 许可，以及 PNG/XML 图标图集。
从 JaiLib/assets 逐字节复制，无需相邻 olib 检出或生成时下载。加载方式见
[内置资源清单](../../assets/README.md)，图标许可状态见图标目录的 README。

生成后运行 `python tools/build.py check`、`python tools/build.py editor --run`、
`python tools/build.py game --run`。`JAIC` / `JAILIB` 可覆盖编译器和库路径。

适配差异：jacket 0.35.1 CLI 不提供共享库输出，所以模板交付可运行的静态开发程序；
DLL 热重载、Web 游戏发布不冒充已经实现。库的 Web 回归另由 `tools/wasm` 维护。
