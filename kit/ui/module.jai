// ui/module.jai — 聚合入口：`#import "kit/ui"`。
// 与 olib kit/ui 一一对位：
//
//   ui.odin           → ui.jai           （UI_Context：clay 初始化/帧流程、字体表、声明适配层）
//   ui_text.odin      → ui_text.jai      （msdf 字体测量、字形四边形、Font 位图烘焙）
//   ui_backend.odin   → ui_backend.jai   （RenderCommand -> UI_Op 翻译 + Render2D 发射）
//   ui_visual.odin    → ui_visual.jai    （子树视觉变换 / Tween / 变换命中 / 状态驱动动效）
//   ui_input.odin     → ui_input.jai     （指针捕获 / 导航焦点 / 禁用态 / 模态 / 输入消费）
//   ui_widgets.odin   → ui_widgets.jai   （主题、基础控件、图像、进度、滑条、容器）
//   ui_controls.odin  → ui_controls.jai  （下拉框 / 虚拟列表 / 拖放）
//   ui_text_input.odin→ ui_text_input.jai（单行文本输入 / 输入法候选框位置）
//
// 公开过程/结构体/字段名、参数顺序、返回语义与 olib 一致；逐文件的差异列在各文件头，
// 全局差异（都与 clay 0.12 绑定、jfoster 形态有关，不是接口发明）见 ui.jai 头部 A..H：
//   A. clay 0.12：`if clay.UI()(decl)` → `ui_element(decl, children = #code { ... })`，
//      *decl 助手返回 UI_Decl（名字/参数不变）。
//   B. 没有 Clay_GetLayoutElementInfo：视觉树由 ui_element 在声明期记录。
//   C. 没有 Clay_SetPointerHitTestFunction：命中测试为布局轴对齐矩形（不含 ui_set_visual 变换）。
//   D. 没有 ClipElementConfig：裁剪一律用 Scroll 容器。
//   E. foster → jfoster 的名字（Texture/Msdf_Font 为指针、Vec2→Vector2、Color 小写通道）。
//   F. Odin map/[dynamic]T → Table/[..]T。
//   G. ui_init 不再收 allocator 参数。
//   H. ui_font_bake 返回 *F.Msdf_Font（Atlas 为 jfoster Image）。
//
// 导入说明：`#load` 进来的文件共享这一层的名字，各文件里不再 #import/重复声明。
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
UNI :: #import "Unicode";     // utf8_next_character
F :: #import "foster";       // Texture / Msdf_Font / Font / Image / Color / Vector2 / Matrix3x2
r2d :: #import "kit/rendering/2d";     // Render2D
mat :: #import "kit/rendering/material"; // Material / Material_Library / BUILTIN_TEXT
tw :: #import "core/tween";   // spring
clay :: #import "thirdparty/clay/module"; // clay 0.12 绑定
HASH :: #import "Hash_Table";
using HASH;   // `for value, key: table` 的 for_expansion 必须在同一作用域可见
using JM;     // Vector2 / Color 的 + - * == 运算符（clay.Color 与 F.Vector2 都靠它）

#load "ui.jai";
#load "ui_text.jai";
#load "ui_visual.jai";
#load "ui_backend.jai";
#load "ui_input.jai";
#load "ui_widgets.jai";
#load "ui_controls.jai";
#load "ui_text_input.jai";
