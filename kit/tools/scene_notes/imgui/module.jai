// scene_notes/imgui/module.jai — 聚合入口：`#import "kit/tools/scene_notes/imgui"`。
// 与 olib kit/tools/scene_notes/imgui/scene_notes_imgui.odin 一一对位（那个包只有一个文件）：
//
//   scene_notes_imgui.odin → scene_notes_imgui.jai（Panel/Draft、批注列表、总览、就地便签、世界图钉）
//
// 导入说明（与 kit/ui、shader_lab、perf_overlay/imgui 同一写法：#load 进来的文件共享这一层的
// 名字，各文件里不再重复 #import，避免「already declared in this scope」）：
//   Basic  —— 不具名：tprint / memcpy / min / max / cast
//   STRING —— String：trim / contains_nocase / slice
//   JM     —— Math：Vector2（Panel.editor_size、marker 坐标、布局换算）
//   ImGui  —— stdlib ImGui 声明（宿主负责 context 与帧）
//   F      —— jfoster：Rect（视口与便签框的布局参数）
//   W      —— kit/world：Vec3（Draft.position 与 notes.Note.position 同源）
//   notes  —— kit/tools/scene_notes：Note / Session / Marker / Error / MAX_*_BYTES 与事务 API
//   lab    —— ../lab_imgui.jai 的 ImGui 薄包装（标签吃 string；DrawList 走值语义）
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
ImGui :: #import "thirdparty/imgui";
F :: #import "foster";
W :: #import "kit/world";
notes :: #import "kit/tools/scene_notes";

#load "../../lab_imgui.jai";

#load "scene_notes_imgui.jai";
