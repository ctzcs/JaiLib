# JaiLib 开发约定

本仓库以 olib 的功能和边界为参照，使用 Jai 实现。当前入口和能力见
[README](README.md)，移植差异见 [PORTING](docs/PORTING.md)。不要从历史对位表推断当前能力。

- `core/` 为纯数据与算法；`foster/` 为本仓库拥有的 SDL3/WebGL 运行时；`kit/` 依赖两者。
  使用 `#import "foster"` 和 `-import_dir <JaiLib>`，不得依赖同级 jfoster 检出。
- kit 不以转发过程或别名复制 Foster API，外部代码不导入 `foster/internal`。
- 按功能、所有权、平台边界组织源码。Jai 目录不会自动形成模块：公共入口用
  `module.jai` 显式 `#load`；区分 `#scope_file`、`#scope_module`、`#scope_export`。
  导入优先具名，避免 Math/Foster 的同名类型及运算符污染。
- Foster 的本地改动登记在 [LOCAL_CHANGES](foster/docs/LOCAL_CHANGES.md)；第三方库保留来源和许可。
- 第三方 ImGui 绑定与 ABI 对应的二进制统一在 `thirdparty/imgui/`，不要链接机器上另一版 ImGui。
- 新游戏遵循 [新项目约定](prompts/new-project.md)；数据与模块边界遵循
  [数据约定](prompts/dod-guidelines.md)；编辑器改动先读 [编辑工具约定](prompts/editor-guidelines.md)。
- 第三方翻译必须交付可调用的 Jai 实现和行为验证；不能以 Odin 源码副本、空模块或 TODO 算完成。
  未支持的能力须明确报错，不把跳过当通过。

## 文件与验证

- 第一方测试放 `tests/<模块路径>/`；Foster 回归放 `foster/tests/`，第三方配套测试可放各库 `tests/`。
- 正式字体、图标及许可放 `assets/`；构建产物和日志放 `build/`；诊断副本放 `library/tmp/`，
  截图放 `library/screenshots/`，图像参考放 `library/imagegen/`。按需创建，不批量清理正式资产。
- 可复用构建/转换/检查入口放 `tools/`，不在根目录新增 `run_*.bat` 或机器绝对路径脚本。
- `python tools/check/main.py` 为统一检查入口，`--only <名字片段>` 可缩小范围；
  Web 变更另加 `--web`。验收编译器为 jacket `jaic`，可用 `JAIC` 环境变量指定。
- 类型检查带 `-no_dce`，同时检查退出码与编译器错误文本。运行行为测试；无 GPU 的 mock
  不能替代像素测试。DLL 热重载必须真编译、加载、失败回退后才能称为已验证。
- 保留工作树中的已有修改；不提交、推送或覆盖相邻仓库，除非用户要求。汇报实际执行的检查及限制。
