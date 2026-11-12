// compile/module.jai — 聚合入口：`#import "kit/rendering/shader/compile"`。
// 与 olib kit/rendering/shader/compile 对位（package compile 的唯一文件）：
//
//   compile.jai —— compile.odin（策略 / 工具身份 / 命令行生成 / 阶段编译 / 反射 / run）
//
// 具名导入：
//   STRING  —— String（路径拆分与拼接；Jai 的 Basic 没有 path_extension 之类）
//   FILE    —— File（read_entire_file / write_entire_file / file_delete / get_absolute_path）
//   FU      —— File_Utilities（file_exists / file_list；替代 odin 的 os.is_file / read_all_directory）
//   ENV     —— Extensions/Environment（PATH）
//   DEFAULT —— Default_Allocator（olib 的 runtime.heap_allocator）
//   SORT    —— Sort（slice.sort 的对位）
#import "Basic";
STRING :: #import "String";
FILE :: #import "File";
FU :: #import "File_Utilities";
ENV :: #import "Extensions/Environment";
DEFAULT :: #import "Default_Allocator";
SORT :: #import "Sort";

#load "compile.jai";
