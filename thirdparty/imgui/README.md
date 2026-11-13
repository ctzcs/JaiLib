# Dear ImGui（Jai）

`module.jai` / `declarations.jai` 是 jacket 0.35.1 的 Jai 绑定；Windows 绑定使用 C++ 符号，
必须与本目录的 `ImGui.dll`、`imgui.lib` 配套。后者是导入库，不是第二个 DLL。
绑定来源：jacket stdlib/ImGui/declarations.jai；Dear ImGui 许可见 LICENSE。

```jai
ImGui :: #import "thirdparty/imgui";
Backend :: #import "thirdparty/imgui/imgui_foster";
```

Foster 后端与输入测试从 JaiLib 原有实现迁入，运行时只依赖仓库内 `foster`。
链接使用相对本目录的导入库；发布时将 DLL 复制到可执行文件旁。
`python tools/check/main.py --only kit` 会构建并运行 ImGui 输入/生命周期回归。
当前随仓库交付的是 Windows ABI；不能拿它给 Web 或另一版本的 ImGui 链接。
