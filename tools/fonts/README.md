# 离线 MSDF 字体资产

统一使用 [msdf-atlas-gen](https://github.com/Chlumsky/msdf-atlas-gen) 生成真正的多通道图集。
生成器只用于开发/资产构建，不随游戏发布；运行时直接使用 Foster 的 `msdf_font_load_paths`
或 `msdf_font_load_bytes`，不新增 kit 包装层。

本仓库测试资产使用 **msdf-atlas-gen 1.4**。从上游 release 下载对应平台工具，
或按上游说明从 v1.4 源码构建；把可执行文件加入 PATH。Windows release 为
[msdf-atlas-gen-1.4-win64.zip](https://github.com/Chlumsky/msdf-atlas-gen/releases/download/v1.4/msdf-atlas-gen-1.4-win64.zip)。

## 参数化批次 CLI（推荐）

`font_pipeline.py` 不选项目字体，不默认 glob/扫描源码，不下载字体或工具，也不覆盖已有输出。
构建依赖本地 Python 3、fontTools（已验证 4.64.0）及支持 `-and` variants 的
msdf-atlas-gen（资产基线 1.4）；`validate` 和单元测试仅用 Python 标准库，不需要 Pillow。
工具版本由调用者核实后用 `--tool-version` 标注，同时记录实际可执行文件 SHA-256，
不会把调用者标签冒充自动探测版本。

在库根或项目根显式提供输入；所有相对路径相对于调用时的工作目录。例如 PowerShell：

```powershell
python -B tools/fonts/font_pipeline.py build `
  --font assets/source/ui.ttf --license assets/source/OFL.txt `
  --font assets/source/fallback.otf --license assets/source/fallback-OFL.txt `
  --chars '0123456789+- ' --text-file assets/source/ui-text.txt `
  --json-file assets/source/locale.json --codepoints-file assets/source/codepoints.txt `
  --generator 'C:\local-tools\msdf-atlas-gen.exe' --tool-version '1.4' `
  --output-root assets/fonts/ui-candidate --temp-root "$env:TEMP\my-font-work" `
  --size 48 --pxrange 8 --seed 0
python -B tools/fonts/font_pipeline.py validate assets/fonts/ui-candidate
```

- `--font` 的顺序就是 fallback 顺序；`--license` 按出现次序与字体一一对应，不能省略。
  每个码点只归第一个有字形的字体，不把 `.notdef` 当覆盖；空子集跳过，但保留其来源/许可记录。
  只接受静态 TTF/OTF；可变字体先在项目侧实例化所需轴值，不猜字重，不接受 TTC/WOFF。
- 四类字符输入可重复并取并集；没有默认 ASCII、数字或项目源码扫描。
  `--chars` 是字面文本，`--text-file` 是 UTF-8 文本（可带 BOM）；两者忽略 CR/LF/Tab，
  保留空格和其他字符，不做 Unicode NFC。`--json-file` 递归读取标准 JSON 的**字符串值**，
  不读取 key、数字和布尔值；重复 key 报错。这不是 Odin/Python 等语言字符串解析器。
  本地化 JSON 的值若包含非展示字符串，项目应先导出专用字符清单。
- `--codepoints-file` 是显式 scalar 清单，空白分隔 `U+0041 0x4E2D`，`#` 后为注释；
  不接受范围、生成器 charset 语法或代理项。需要控制字符时必须在此显式列出。
  最终排序去重；空字符集、缺字、缺字体/许可/工具、工具失败/超时、产物不符全部非零退出。
  运行成功退出 0，输入/构建/校验失败退出 1，CLI 用法错误退出 2；`--timeout` 默认 300 秒。
- 输出根必须是**尚不存在的新目录**，与临时根互不包含；不会默认重烘焙正式资产。
  每次构建在临时根下独占目录，单次启动生成器同时输出 JSON+PNG，失败自清，不复用旧产物。
  校验完成后使用输出父目录下的独占同卷暂存目录整体发布并自清；已有输出拒绝覆盖。
  维护者验收通过后自行把整个候选批次纳入所属资产版本管理，不单独替换 PNG 或 JSON。

### 产物、归一与复现契约

每个输出批次包含：

| 文件 | 用途 |
|---|---|
| `font.png` + `font.json` | 供 Foster 直接加载的 RGB MSDF / flat JSON |
| `generator.json` | 同次生成的原始 flat/variants JSON，用于复核归一 |
| `subset-NNN.ttf/otf`、`charset-NNN.txt` | 非空字体的确定性子集及生成器字符清单 |
| `license-NNN.txt` | 每个源字体许可的逐字节副本（不替代人工授权审查） |
| `provenance.json` | 字符来源/hash、字体顺序/hash、许可/hash、完整 argv、工具 hash/版本标签、Python/fontTools/脚本版本、批次文件 hash |

子集复用 ImGui 的无 hinting/无 GSUB/GPOS 塑形策略，保留所有 name ID（fontTools 默认语言集）
及源 `head.modified`；外部许可全文另存。运行时仅按码点，不支持塑形/双向排版。
保留原有 bidi/glyph closure：子集 cmap 可能包含额外镜像码点，MSDF 始终用显式 charset
限制本字体实际烘焙的字符，因此不会把这些闭包字符重复分配给 fallback。
生成固定 `-type msdf -format png -yorigin top -threads 1`，显式 size/pxrange/seed（默认 48/8/0）。
相同输入、参数、Python/fontTools/生成器二进制和平台应得到相同子集、JSON、PNG 与 provenance；
不保证跨工具版本/平台逐字节一致。argv 使用批次内相对文件名、固定 `<BATCH>` 工作目录标识，
不把随机临时路径/运行耗时写入记录。原始来源文件需由项目另行保留；记录不是数字签名。

flat 与 variants 都归一为 Foster 的单 metrics/glyphs/kerning 格式：
每个 variant 的度量、advance、planeBounds、kerning 除以其 emSize；atlasBounds 保持像素单位。
基线不平移，ascender 取最小值、descender 取最大值、行高取各字体行高与包络高度的最大值，
下划线度量取第一个非空字体。glyph 按码点、kerning 按码点对排序；保留生成器导出的字距，
不合成跨字体字距，不从未导出的 GPOS 恢复 kerning。重复字形/字距、跨 variant 字距、缺字、
越界/倒置边界、非有限数值、bottom-origin 或非对称距离范围直接拒绝。

PNG 检查签名、chunk CRC、完整 zlib 流、尺寸、所有五种解滤波及真实 RGB 两两通道差异；
只接受 8-bit 非交错 RGB，拒绝 alpha/透明度、sRGB/ICC/gamma 元数据。**不做预乘或色彩变换**。
通道差异是排除伪 RGB/SDF 的必要检查，不是距离场数学正确性或视觉质量证明；纯空白字符批次
无法通过该检查，应加入实际会显示的轮廓字符。`validate` 先查同批 hash，再复算 raw → flat，
不能用任意同尺寸旧 PNG 拼凑新 JSON。运行时仍需线性采样、禁止 sRGB 解码/预乘。

离线检查与[最终小字号像素验收](../../kit/ui/README.md#最终像素采样与清晰度验收)分开：
UI 在最终 drawable 像素目标绘制，不随低分辨率场景放大；14–16px 中文、125% DPI、resize 等
须在实际消费者最终输出另验，不能以加粗或增大图集代替采样排查。本工具不恢复运行时烘焙。

### Python API 与无外部依赖测试

`tools/fonts/font_pipeline.py` 可直接导入；`FontError` 表示契约错误，文件错误保持 `OSError`：

- `collect_codepoints(chars=(), text_files=(), codepoint_files=(), json_files=()) -> (list[int], sources)`
- `assign_fallback(codepoints, coverages) -> list[list[int]]`（包含空子集）
- `font_coverage(path) -> set[int]`、`save_subset(source, output, codepoints)`（仅这两者需要 fontTools）
- `normalize_msdf(data, assignments=None) -> dict`、`validate_png(path, width, height)`
- `validate_pair(data, png, assignments=None) -> dict`（归一 JSON；不单独证明批次来源）
- `build(codepoints, fonts, output_root, temp_root, generator, tool_version, sources=(), size=48, pxrange=8, seed=0, timeout=300) -> provenance`
  其中 `fonts` 为有序 `(font_path, license_path)` 对；输入文件/码点集合不被修改。
- `validate_batch(directory) -> provenance`（标准库即可校验完整批次）

从库根运行：

```powershell
python -B -S -m unittest discover -s tests/tools/fonts -p 'test_*.py' -v
```

测试用标准库合成 PNG/JSON、受控字体后端和子进程替身，使用独占自清临时目录；
`-S` 禁用 site-packages，证明无需字体、fontTools、Pillow 或生成器即可重跑。
覆盖字符来源、fallback 去重、确定性/子集选项、metrics/kerning、伪 RGB/坏 PNG、同批 hash、
缺字体/字/工具、非零进程/超时/缺产物和不覆盖已有输出。统一 `odin run tools/check` 也执行这组测试，
可用 `-- -only:tools/fonts` 筛选；不要求安装 fontTools、Pillow 或 MSDF 生成器。
真实字体/生成器小样应另在 session scratch 或测试独占临时目录执行，不能默认写回库内资产。

## 生成

字符集文件是生成器的 charset 语法，例如 ASCII 加中文：

```text
[32, 126]
"中文菜单设置返回确认取消"
```

包含本地化和动态文本可能用到的全部字符；引号内按 UTF-8 保存，也可一行一个 `0x4E2D`
这样的 Unicode 码点。不要直接把未经转义的本地化 JSON 当作 charset 输入。

在游戏仓库中运行（输出目录须先存在）：

```sh
msdf-atlas-gen -font assets/source/ui.otf -charset assets/source/ui-charset.txt -type msdf -format png -size 48 -pxrange 8 -yorigin top -seed 0 -imageout assets/ui.png -json assets/ui.json
```

必须确认生成器退出成功，且 `Loaded geometry of N out of N glyphs` 没有缺字。
输出 JSON 应为 `atlas.type = "msdf"`、`atlas.yOrigin = "top"`，宽高应匹配 PNG。
PNG 的 RGB 应包含不同的距离信息；不能换成 SDF 或把同一个距离复制三次。

`-yorigin top` 对当前 Foster 加载器是必需的，省略时生成器默认 bottom 原点，
会导致字形边界/基线解释错误。保留默认对称距离范围，不使用自定义非对称范围；
现有 shader 以 0.5 为边界。PNG 与 JSON 必须一起更新，不能混用不同批次。

图集是线性数据，禁止 sRGB 解码或预乘 alpha。运行时保持线性过滤；不要通过硬阈值
或增加字体字重掩盖采样问题。48px/em、范围 8 是起点，最终质量验收见
[UI 像素与采样约定](../../kit/ui/README.md#最终像素采样与清晰度验收)。

源字体、许可证、字符集、生成器版本、完整参数和生成结果一起纳入资产版本管理。
字体子集和图集是正式资源，不迁入 library；临时对比图与验收截图按
[生成文件规则](../../prompts/new-project.md#生成文件与目录纪律) 分别放 library/tmp 与 library/screenshots。
动态新增字符后重新生成并打包；离线资产不提供运行时 TTF 补字。

## 复现库内测试资产

在 olib 根目录运行：

```sh
msdf-atlas-gen -font foster/tests/port_regression/fonts/Abel-Regular.ttf -charset tests/kit/ui/testdata/abel-charset.txt -type msdf -format png -size 48 -pxrange 8 -yorigin top -seed 0 -imageout tests/kit/ui/testdata/abel-msdf.png -json tests/kit/ui/testdata/abel-msdf.json
odin run tools/check -- -only:kit/ui
```

预期 95/95 字形、336×336 图集。CPU 测试读取真实 PNG/JSON，检查通道独立信息、字形
边界、基线、空格、字距和 UI 四边形/测量一致性。该测试不能替代最终 GPU 输出验收。
Abel 源字体及 OFL 许可证位于 `foster/tests/port_regression/fonts/`，图集旁附许可证副本。

示例共用的中英文图集及复现说明位于同级 `olib_sample/shared/msdf_font/`；
`game_ui`、`ui_gallery` 内嵌该资产，无系统字体依赖；Shader Lab 改用 ImGui 后使用下文的 ImGui 字体。

## ImGui 字体

ImGui 不使用 MSDF 图集，而是在运行时按需光栅化 OTF。olib 的 ImGui 后端默认加载
[`assets/fonts`](../../assets/fonts/README.md) 里同一字体（Noto Sans CJK SC）的 GB2312 子集，
由本目录的 `imgui_font.py` 生成；既有 `source [--output ...]`、源 hash、字符集和默认输出
保持不变，现与通用流水线共用 `save_subset`；缺字或失败现在非零退出。用法与复现命令见该 README。
