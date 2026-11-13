//
// clay 模块 —— Clay v0.14 纯 Jai 移植的聚合入口（只做 #load）。
//
// 分层与 olib `thirdparty/clay` 的文件划分一一对应，加载顺序按依赖走：
//
//   clay_types.jai    基础类型 + 全部配置/内部结构体 + Context + C 枚举常量
//                     (olib: clay.odin 的类型部分 + clay_types.odin)
//   clay_memory.jai   arena / 类型化数组 / 文字测量缓存 / 哈希表 / 全局回调
//                     (olib: clay_memory.odin)
//   clay_layout.jai   开闭元素、尺寸计算、最终布局、渲染命令生成
//                     (olib: clay_layout.odin；MinMemorySize 也提前放在这里)
//   clay_debug.jai    debug 面板（_RenderDebugView 等）
//                     (olib: clay_debug.odin)
//   clay_backend.jai  olib 后端扩展：PointerHitTest / GetLayoutElementInfo
//                     (olib: clay_backend.odin)
//   clay_api.jai      公开 API：Initialize / BeginLayout / EndLayout / PointerOver …
//                     (olib: clay_api.odin)
//   clay.jai          声明辅助语法糖：Padding / Sizing / Text / UI / ID
//                     (olib: clay.odin 的 “Odin 声明辅助” 段)
//
// Jai 是单编译单元（#load 只是文本包含），过程互相引用与 #load 顺序无关；
// 这里按 olib 的层次顺序排，纯粹为了人工 diff 时好找。
//
// 旧的 C 绑定（clay.c / windows/clay.lib / generate.jai）已删除：本模块是纯 Jai 实现，
// 不再链接 clay 的 C 库。需要旧的 FFI 版本可以 `git checkout f672218 -- thirdparty/clay`。
//
// 命名与 olib 一比一：公开名 PascalCase，字段 camelCase，内部符号保留下划线前缀，
// 枚举成员是大写下划线（.FIXED / .LEFT_TO_RIGHT），详见 clay_types.jai 顶部的约定说明。
//

#load "clay_types.jai";
#load "clay_memory.jai";
#load "clay_layout.jai";
#load "clay_debug.jai";
#load "clay_backend.jai";
#load "clay_api.jai";
#load "clay.jai";
