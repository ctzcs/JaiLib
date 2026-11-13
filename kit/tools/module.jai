// kit/tools/module.jai —— kit/tools 聚合入口：一次 `jaic -check -no_dce` 覆盖整个工具层。
//
// 覆盖范围（olib kit/tools 下的四个工具包 + 两个 imgui 子包，各自已有对位入口）：
//
//   tween_preview/           session.odin          → tween_preview/module.jai + session.jai
//   shader_lab/              12 个 .odin            → shader_lab/module.jai + 12 个 .jai
//   perf_overlay/            perf_overlay.odin     → perf_overlay/module.jai + perf_overlay.jai
//   perf_overlay/imgui/      perf_imgui.odin       → perf_overlay/imgui/module.jai + perf_imgui.jai
//   scene_notes/             scene_notes.odin      → scene_notes/module.jai + scene_notes.jai
//   scene_notes/imgui/       scene_notes_imgui.odin→ scene_notes/imgui/module.jai + scene_notes_imgui.jai
//   lab_imgui.jai            所有工具共用的 ImGui 薄包装（标签吃 string）
//
// 为什么这一层用 `#load "lab_imgui.jai"` + `#import "kit/tools/<pkg>"`，而不是把四个包也 `#load` 进来：
//
//   实测（jaic 会把 `#load` 当成同一声明的字面包含）：
//     - 同一个 `#import "Basic";` 出现在多个 `#load` 的文件里**不冲突**；
//     - 但子包 module.jai 里的具名导入 `STRING :: #import "String"` 会撞车，报
//       `error[already-declared-scope]: STRING is already declared in this scope`（scene_notes/module.jai:18）；
//     - 就算把具名导入全删掉，四个包的实现文件之间也有硬冲突：`Session` / `Status` / `Config` / `Case`
//       在 tween_preview、shader_lab、scene_notes 里各有一份同名类型（olib 也是靠 package 隔离）。
//   所以四个子包只能走具名 `#import`（互不冲突、也不与本文件的导出入名冲突）；`-no_dce` 对**被导入
//   模块的全部符号**都生效，覆盖效果与 `#load` 一致。实测方式（每个包各试一次，验完已还原）：
//   在 tween_preview/session.jai、shader_lab/windows.jai、scene_notes/scene_notes.jai、
//   lab_imgui.jai 里各塞一句 `x: int = "cover";`，本文件的 -check 都立刻报出
//   `error[type-mismatch]`（含 lab_imgui.jai:484，说明连被 #load 进去的包装层也覆盖到了）。
//
// 已知副作用（warning，不是 error）：本文件 `#load "lab_imgui.jai"` 把 imgui_* 包装声明在当前作用域，
// 与各子包导出的同名过程同签名，于是 jaic 对每条包装报一次 `warning[declaration-hides-import]`
// （90 条，全部指向 lab_imgui.jai），除此之外没有本文件的告警。要一份 0 warning 的输出，把下面那行
// `#load "lab_imgui.jai";` 注释掉即可（包装层随任一子包的 `#load ../../lab_imgui.jai` 仍会被检查，
// 已验证）。写成 #load 是为了让本文件单独 -check 时也有包装层的符号。
//
// 本文件的具名导入 = 六个子包的导入清单并集（各包 module.jai 里仍然保留自己那一份，互不依赖）：
//   Basic  —— 不具名：tprint / formatFloat / formatInt / temp_c_string / array_add / array_free /
//             memcpy / clamp / min / max / cast / New / Allocator / context ...
//   STRING —— String：trim / contains / replace / to_lower / slice / path 辅助
//   JM     —— Math：Vector2 / cos / sin / floor / ceil / isnan / isinf / PI
//   FILE   —— File：read_entire_file / write_entire_file / make_directory / file_move ...
//   FU     —— File_Utilities：file_list / file_visit
//   HASH   —— Hash_Table：Table / table_find / table_set（场景批注与 shader_lab 的稳定 ID 表）
//   EN     —— core/encoding：JSON 编解码（scene_notes 的文件格式）
//   PROF   —— core/profiler：profile_stats / Profile_Stat（perf_overlay 的采样）
//   W      —— kit/world：Vec3 / Camera3D / Matrix4
//   F      —— jfoster：Color / Texture / Mesh / Material / Graphics_Device / Rect / Storage_Container ...
//   ImGui  —— stdlib ImGui 声明（宿主负责 context 与帧）
//   sh / mat / r2d / r3d / DA —— kit/rendering/* 与 core/dasset（shader_lab 的预览管线）
//   ui / clay —— kit/ui 与 thirdparty/clay（perf_overlay 的 clay 浮层实现）
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
FILE :: #import "File";
FU :: #import "File_Utilities";
HASH :: #import "Hash_Table";
EN :: #import "core/encoding";
PROF :: #import "core/profiler";
W :: #import "kit/world";
F :: #import "foster";
ImGui :: #import "thirdparty/imgui";
sh :: #import "kit/rendering/shader";
dev :: #import "kit/rendering/shader/dev";
mat :: #import "kit/rendering/material";
r2d :: #import "kit/rendering/2d";
r3d :: #import "kit/rendering/3d";
DA :: #import "core/dasset";
ui :: #import "kit/ui";
clay :: #import "thirdparty/clay/module";

// kit/tools 共用的 ImGui 薄包装（标签一律吃 string，见该文件头）。
#load "lab_imgui.jai";

// 四个工具包 + 两个 imgui 子包：具名导入，名字不进入本文件的作用域。
#import "kit/tools/tween_preview";
#import "kit/tools/shader_lab";
#import "kit/tools/perf_overlay";
#import "kit/tools/perf_overlay/imgui";
#import "kit/tools/scene_notes";
#import "kit/tools/scene_notes/imgui";
