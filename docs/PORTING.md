# olib → JaiLib 移植手册

以 `D:\MySpace\Github\olib` 为唯一参照，逐模块一比一移植到本仓库。
已完成的样板：`core/curve` + `Tests/core/curve`。

## 目录与命名

```
core/<module>/<file>.jai      // 对应 olib core/<module>/<file>.odin
core/<module>/module.jai      // 聚合入口，只做 #load
Tests/core/<module>/<module>_test.jai
```

- 包名 = 目录名；`#import "core/curve"` 取到 `module.jai`。
- 公开过程、结构体、字段名照 olib 的 snake_case / PascalCase，不改名。
  例如 `sample`、`sample_hermite_tangents`、`Kind.Linear`。
- 内部辅助函数加模块名前缀（`curve_add`）以避免聚合后重名。
- 注释照 olib 的中文注释保留；确实因语言差异改动的地方写一行说明。

## Jai 语言约束（都是踩过的坑）

| Odin 写法 | Jai 写法 |
| --- | --- |
| `switch x { case .A: }` | `if x == { case .A; ... }`（Jai 的 if-switch） |
| `for k in Enum` | `kinds : [N] Kind = .[...]; for k: kinds { }`（不能直接遍历 enum 类型） |
| `[4]f32{...}` / `matrix[4,4]f32{...}` | 数组字面量 `.[...]`，嵌套 `.[.[..], ..]`；结构体 `.{...}` |
| 数组加减、数组乘标量 | **Jai 没有数组算术**。标量/向量通用的泛型用 `#if T == float32 { } else { 逐元素循环 }`，或写 `curve_scale`/`curve_add` 这类桥接 |
| `ifx cond then a else b` | 只适合表达式；**语句块用 `#if cond { } else { }`**，`ifx` 不会跳过另一分支的类型检查 |
| `1 - t`（int/float 混算） | `cast(float32) 1 - t`；`2 * s` → `s * 2` 或先 cast |
| `matrix[4,4]` 索引 `m[列][行]` | `[4][4]` 是 `m[行][列]`；olib 字面量按行写，移植时把索引换成 `m[幂][控制点]` |
| 泛型 `[4]$T` | 同形支持；`[2]/[3]/[4] float32` 都能实例化（前提是内部不出现数组算术） |
| `#force_inline` | 去掉；Jai 自己决定内联 |
| `abs` | `#import "Math";` 后用 `abs` |

| `for i in 0..<n` | Jai 的 `a..b` **含终点**，写 `0..n - 1` |
| `for i := 0; cond; step` | Jai 没有 C 风格 for，条件循环写 `while` |
| `~x`（按位取反） | 同形；但 XOR 是 `^`，不是 `~` |
| 有默认参数 `allocator = context.allocator` | **默认参数在函数体首次使用时求值**：若函数体先 `push_allocator(temp)`，默认值会取到 temp。必须先 `allocator := allocator_in;` 再 push |
| `@(private)` / `@(test)` | 无等价物；内部过程加模块前缀，测试用独立的 `*_test.jai` |

| `STRING.slice(s, start, end)` | jacket 的第三参是**长度**不是结束下标：`STRING.slice(s, start, count)`。传错不报错，静默截错 |
| `read_entire_file(path) -> ([]u8, bool)` | jacket 返回 `(string, bool)`，要字节得 `cast([] u8)` |
| `FU.file_list(dir)` | jacket 是**单返回** `[] string` 且元素各自拥有（要逐个 free） |
| `log_info(fmt, args)` | jfoster 的 `log_info/log_error` 收**已格式化好的 string**，不是变参：先 `tprint` |
| `\`defer` | Jai 的 `\`defer` 在**调用方作用域**结束才触发；宏里用它关资源会漏（kit/ui 的 segfault 就是这么来的） |

## 测试

- 每个模块一个 `*_test.jai`，过程签名 `(state: *Test_State)`，用
  `expect(state, cond, "说明 %", args)`；断言顺序与 olib 测试一一对应。
- 模块测试文件不写 `main`；由 `Tests/core/run_core_tests.jai` 统一调度。
- 本地单模块验证可以在 `.test_tmp/`（已 gitignore）放临时 runner。

## 验收

```powershell
# 单模块编译检查
jaic -check -import_dir . core/curve/module.jai

# core 全量
jaic -import_dir . -import_dir Tests -exe core_tests -output_path bin Tests/core/run_core_tests.jai
bin\core_tests.exe
```

主验收编译器是 jacket（`D:\Lib\jacket-windows-x64\jaic.exe`，0.35.1）；
官方 jai 0.2.009 只保持既有构建不变，不作为新模块的验收门槛。

Windows 一键回归：`run_core_tests.bat`（当前 14 个模块 / 11,492 条断言）。
