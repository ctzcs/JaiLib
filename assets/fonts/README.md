# ImGui 内置字体

`NotoSansCJKsc-Regular-subset.otf` 是 Noto Sans CJK SC Regular 的子集，
供 `thirdparty/imgui/imgui_foster` 的 `imgui_foster_setup(font_path)` 加载为 ImGui 字体。按同目录 `OFL.txt` 分发。

- 源字体：NotoSansCJKsc-Regular.otf（notofonts/noto-cjk，Sans/OTF/SimplifiedChinese），
  SHA-256 `2C76254F6FC379FDDFCE0A7E84FB5385BB135D3E399294F6EEB6680D0365B74B`。
- 码点：ASCII、Latin-1、U+2026 与 GB2312 全部双字节字符（6763 个汉字及全角符号），共 7619 个。
- 去掉 hinting 与 GSUB/GPOS（ImGui 只按码点取字形，不做塑形），保留 name 表的版权与许可信息。

Jai 后端按简体中文常用字范围烘焙字体图集；字体子集或烘焙范围之外的字会显示为缺字。
不要把 Odin ImGui 1.92 的按需光栅化约定套到本仓库 ABI。重建需要 Python 3 和 fontTools（本次使用 4.64.0），在 JaiLib 根目录运行：

```powershell
python -m pip install fonttools==4.64.0
python tools/fonts/imgui_font.py path/to/NotoSansCJKsc-Regular.otf
```

脚本先校验源字体哈希，保留源 `head.modified`，同一版本重复生成字节一致。正式资产保留在 assets，
不按临时文件清理。
