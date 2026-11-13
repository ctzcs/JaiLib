// perf_overlay/module.jai — 聚合入口：`#import "kit/tools/perf_overlay"`。
// 与 olib kit/tools/perf_overlay 一一对位：
//
//   perf_overlay.odin  → perf_overlay.jai   （Overlay / 采样 / 统计 / kit/ui+clay 浮层）
//   imgui/perf_imgui.odin → imgui/module.jai + imgui/perf_imgui.jai（Dear ImGui 版的同一份内容）
//
// 导入说明（与 kit/ui、shader_lab 同一写法：#load 进来的文件共享这一层的名字，
// 各文件里不再重复 #import）：
//   Basic    —— tprint / max / min / memcpy / free / NewArray / temporary_allocator
//   HASH     —— Hash_Table：Table / table_find / table_set（作用域累计表）
//   JM       —— Math
//   F        —— jfoster：Graphics_Device / Msdf_Font / Texture / Drawable_Target / Color / Rect
//   profiler —— core/profiler：profile_stats / Profile_Stat
//   mat      —— kit/rendering/material：Material_Library
//   r2d      —— kit/rendering/2d：Render2D / View / init / submit
//   ui       —— kit/ui：UI_Context / UI_Theme / ui_element / ui_column_decl ...
//   clay     —— thirdparty/clay/module：clay 0.12 绑定
#import "Basic";
STRING :: #import "String";
HASH :: #import "Hash_Table";
using HASH;
JM :: #import "Math";
F :: #import "foster";
profiler :: #import "core/profiler";
mat :: #import "kit/rendering/material";
r2d :: #import "kit/rendering/2d";
ui :: #import "kit/ui";
clay :: #import "thirdparty/clay/module";

#load "perf_overlay.jai";
