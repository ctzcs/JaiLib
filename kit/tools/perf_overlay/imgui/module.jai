// perf_overlay/imgui/module.jai — 聚合入口：`#import "kit/tools/perf_overlay/imgui"`。
// 与 olib kit/tools/perf_overlay/imgui/perf_imgui.odin 一一对位（那个包只有一个文件）。
//
// 导入说明（与 perf_overlay、shader_lab 同一写法：#load 进来的文件共享这一层的名字）：
//   Basic  —— 不具名：tprint / max / min / cast
//   JM     —— Math：floor（perf_round 的取整；jacket 的 Math 没有 round）
//   ImGui  —— stdlib ImGui 声明（宿主负责 context 与帧）
//   F      —— jfoster：Color（沿用 perf 包的颜色类型，面板配色与 kit/ui 版同源）
//   perf   —— kit/tools/perf_overlay：Overlay / history_at / rating_color / GRAPH_BARS / TARGET_MS
//   lab    —— ../lab_imgui.jai 的 ImGui 薄包装（标签吃 string）
#import "Basic";
JM :: #import "Math";
ImGui :: #import "thirdparty/imgui";
F :: #import "foster";
perf :: #import "kit/tools/perf_overlay";

#load "../../lab_imgui.jai";

#load "perf_imgui.jai";
