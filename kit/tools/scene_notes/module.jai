// scene_notes/module.jai — 聚合入口：`#import "kit/tools/scene_notes"`。
// 与 olib kit/tools/scene_notes 一一对位：
//
//   scene_notes.odin        → scene_notes.jai        （文件协议 / 编辑事务 / 撤销 / 安全保存 / 命中查询）
//   imgui/scene_notes_imgui.odin → imgui/module.jai + imgui/scene_notes_imgui.jai（面板、图钉、总览）
//
// 导入说明（与 kit/ui、shader_lab、perf_overlay 同一写法：#load 进来的文件共享这一层的名字，
// 各文件里不再重复 #import）：
//   Basic  —— 不具名：copy_string / memcpy / tprint / NewArray / array_add / free / max / min
//   STRING —— String：trim / contains / contains_any_character / to_lower_in_place
//   FILE   —— File：read_entire_file / write_entire_file / file_move / file_delete / make_directory…
//   HASH   —— Hash_Table：Table / table_find / table_set（valid_file 的重复 ID 检查）
//   JM     —— Math：isnan / isinf（位置字段的有限性校验）
//   EN     —— core/encoding：JSON 编解码（olib 用 core:encoding/json）
//   W      —— kit/world：Vec3（olib 的 foster.Vec3）
//   F      —— jfoster：Rect（marker_hit 的视口参数与 marker 坐标类型）
#import "Basic";
STRING :: #import "String";
FILE :: #import "File";
HASH :: #import "Hash_Table";
using HASH;
JM :: #import "Math";
EN :: #import "core/encoding";
W :: #import "kit/world";
F :: #import "foster";

#load "scene_notes.jai";
