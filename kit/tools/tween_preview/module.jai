// tween_preview/module.jai — 聚合入口：`#import "kit/tools/tween_preview"`。
// 与 olib kit/tools/tween_preview 一一对位（那个包只有一个文件 session.odin）：
//
//   session.odin → session.jai（案例协议 / 固定步长重演 / 轨迹采样 / 可嵌入面板 / 画布与曲线）
//
// 导入说明（与 shader_lab、perf_overlay/imgui 同一写法：#load 进来的文件共享这一层的名字，
// 各文件里不再重复 #import，避免「already declared in this scope」）：
//   Basic  —— 不具名：tprint / memcpy / array_add / array_view / array_free / clamp / min / max /
//             cast / Allocator / context
//   STRING —— String：trim（面板里没有用到切片类操作，保留给宿主侧同名移植）
//   JM     —— Math：Vector2 / cos / sin / floor / ceil / abs / isnan / isinf
//   ImGui  —— stdlib ImGui 声明（宿主负责 context 与帧）
//   F      —— jfoster：Color（Pose.color）
//   lab    —— ../lab_imgui.jai 的 ImGui 薄包装（标签吃 string，DrawList 走值语义）
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
ImGui :: #import "thirdparty/imgui";
F :: #import "foster";

#load "../lab_imgui.jai";

#load "session.jai";
