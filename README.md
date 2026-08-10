# JaiLib — Ascension 的 Jai 移植版

用 Jai（beta 0.2.009）重写 [Ascension](https://github.com/)（Odin + raylib 的 2D 游戏），
目录与文件命名与原项目一致（`.odin` → `.jai`）。

## 结构

```
tlib/                    # tlib 游戏库的 Jai 翻译（核心 8 模块）
  container/             #   定长数组
  debug/                 #   分配器调试（Jai 全局 Memory_Debugger 的 API 对齐）
  encoding/              #   CSV / JSON（自实现解析器 + 反射映射）
  entities/              #   实体容器（运行时 Type_Info 反射）
  handle/                #   4 种句柄池（含自写线性 / 虚拟内存 arena）
  profiler/              #   作用域计时
  tween/                 #   补间系统（interpolated / manager / sequence）
  trash/                 #   废弃代码占位（Odin 原版即注释掉的代码）
  run_tests.jai          #   统一测试入口
src/                     # 游戏本体
  core/                  #   DEV 标志、屏幕尺寸、输入/相机、imgui 帧封装
  content/               #   const/defs/utils/assets/atlas/particle/entity/
                         #   managers/gen_csv/game/ink_post/ink_fluid
  editor/                #   编辑器壳 + 3 个工具（imgui 接入 Jai ImGui 模块）
  main.jai               #   App 壳（Game/Editor 模式，F1 切换）
bindings/                # raylib / rlgl / imgui_raylib / clay 的 Jai FFI 绑定
  clay/                  #   clay UI 库绑定（module.jai + clay.c + windows/clay.lib + generate.jai）
  clay_raylib.jai        #   clay 的 raylib 渲染后端（含文本测量回调）
```

## 构建

- `build_dev.bat`：编译 tlib 测试 + DEV 版游戏（编辑器启用），自动拷贝 `raylib.dll`/`ImGui.dll`
- `build_release.bat`：`DEV=false` + `-release` 版游戏
- `build_clay_demo.bat`：编译独立的 clay UI demo（`tools/clay_demo.jai`）

需要：
- `jai.exe`（beta 0.2.009），路径在 bat 顶部 `JAI` 变量可改
- `raylib.dll`（来自 `D:\Lib\odin\vendor\raylib\windows\`，或用 raylibdll.lib 导入库）
- `ImGui.dll`/`ImGui.lib`（Jai 自带 `modules/ImGui/windows/`）
- 项目根的 `resources/` 与 `config/`（从 Ascension 拷贝）

## 运行

```
bin\Ascension_dev.exe     # F1 切换 Game / Editor 模式
```

Game 模式：空格重放叶群爆发，按住左键挥砍切叶。Editor 模式：imgui 工具窗
（Dialogue / Burst Tuning / CSV Tables）。

## Jai 移植说明（与 Odin 的关键差异）

- **命名空间**：Jai 的 `#import` 不传递且命名空间绑定名全局唯一；tlib 各包用
  `X :: #import "路径"` 隔离同名类型，`#import` 依赖需逐文件声明。
- **语法**：无 `using`（字段显式访问）、无 `switch`（用 `if x == { case; }`）、
  过程参数不可变（需拷贝）、`remove`/`delete` 等为保留字（改名 `remove_handle`）、
  结构体字段用分号、解引用 `<<x`、取地址 `*x`、浮点字面量默认 float32、
  range `0..n` 含终点（用 `0..n-1`）、字符字面量不支持转义（用 `"x"[0]`）、
  枚举显式值 `::`、`#type` 无返回类型、多返回值 return 需解构。
- **Math**：`Math` 模块的 `Vector2` 会污染全局，经 `tween/math_util.jai` 包装。
- **反射**：`cast(*Type_Info)` 运行时反射替代 Odin 的 `reflect`/`intrinsics`。
- **内存**：`[..]` 数组是引用语义（拷贝需深拷贝）；分配器用 `context.allocator`
  + `push_allocator`；虚拟内存用 `VirtualAlloc`（需按页对齐）。
- **imgui**：编辑器用 Jai `ImGui` 模块（非 docking 版 dll）+ 自写 raylib 后端
  `bindings/imgui_raylib.jai`，完整移植 Odin 版 `imgui_impl_raylib`：
  rlgl 立即模式渲染（`rlBegin`/`rlVertex2f`/`rlScissor`，与官方 rlImGui 同思路），
  输入全部对齐（键盘 keymap、修饰键、焦点、字符输入、鼠标按钮/滚轮/位置、
  鼠标光标、剪贴板回调）。编辑器默认字体为 `resources/fonts/MapleMono-CN-Medium.ttf`
  （ASCII + 简体中文，`ChineseSimplifiedCommon` 字符集），dialogue 工具可正常
  显示中文。DrawList 绘制函数因编译器不支持 cpp_method 成员调用，
  在 `bindings/imgui_raylib.jai` 重绑定为独立函数。
- **clay**：`bindings/clay/` 为 clay UI 库的 Jai 绑定（由 clay-jai 的
  `generate.jai` 生成，含宏层 `Element`/`ID`/`Layout`/`Text` 等），静态库用
  预编译的 `windows/clay.lib`（`module.jai` 自带 `#library,no_dll` 路径）。
  `bindings/clay_raylib.jai` 提供 raylib 渲染后端与文本测量回调
  （`SetMeasureTextFunction`，基于 raylib 默认字体）。demo：
  `build_clay_demo.bat` → `bin\clay_demo.exe`。
  注意：`#c_call` 文本测量回调内不要用无参 `push_context` 调用本地过程
  （jai 0.2.009 会随机崩溃），直接内联拷贝 + `#foreign` 调用。
- **未完成**：`tools/` 开发期生成器未移植
  （见 `tools/README.md`，资源已直接拷贝自原项目）。`tool_dialogue` 已完整实现
  （节点编辑/连线/拖拽/右键菜单 + JSON 保存/加载）。

## 测试

`tlib/run_tests.jai` 覆盖全部模块（171 断言）：`jai -no_cwd -import_dir tlib tlib/run_tests.jai`
