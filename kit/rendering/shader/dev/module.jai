// dev/module.jai — 聚合入口：`#import "kit/rendering/shader/dev"`。
// 与 olib kit/rendering/shader/dev 对位（package dev 的四个 .odin 文件）：
//
//   compiler.jai     —— compiler.odin     （临时工作区 / 源码与 include 快照 / 候选编译 / 指纹）
//   shader_files.jai —— shader_files.odin （.oshader 候选包：schemas + shaders + programs）
//   parameters.jai   —— parameters.odin   （候选包所有权 + 后台监听线程）
//   dev.jai          —— dev.odin          （Session / Status / update / apply / revalidate）
//
// 具名导入：
//   sh     —— kit/rendering/shader（Schema / Shader_Desc / clone / dispose）
//   lang   —— kit/rendering/shader/lang（parse / dispose / INCLUDE_DIRECTORY）
//   comp   —— kit/rendering/shader/compile（Options / Identity / identify / stage_compile / reflect / bytes_hash / POLICY）
//   F      —— jfoster（Shader / Graphics_Device / Graphics_Driver / Draw_Command）
//   STRING / FILE / FU / ENV / DEFAULT / SORT / JSON / HASH / ATOMICS / THREAD
#import "Basic";
STRING :: #import "String";
FILE :: #import "File";
FU :: #import "File_Utilities";
ENV :: #import "Extensions/Environment";
DEFAULT :: #import "Default_Allocator";
SORT :: #import "Sort";
JSON :: #import "core/encoding";
HASH :: #import "Hash_Table";
ATOMICS :: #import "Atomics";
THREAD :: #import "Thread";

F :: #import "jfoster";
sh :: #import "kit/rendering/shader";
lang :: #import "kit/rendering/shader/lang";
comp :: #import "kit/rendering/shader/compile";

#load "compiler.jai";
#load "shader_files.jai";
#load "parameters.jai";
#load "dev.jai";
