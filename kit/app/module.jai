// app/module.jai — 聚合入口：`#import "kit/app"`。
// 与 olib kit/app 对位（cli_console.odin 单文件，这里拆成一个 #load）。
//
// 与 kit/world、kit/audio 相同：`#load` 进来的文件共享这一层的名字，各文件里
// 不再重复声明，避免「already declared in this scope」。
//
// 四个具名导入（不能写成裸导入）：
//   F       —— jfoster 的 App_State（olib 的 foster.App / foster.Exit 对应物）
//   HASH    —— Hash_Table.Table（olib 的 map[string]Cli_Command）
//   THREAD  —— Thread（olib 的 core:thread：Mutex / Thread）
//   DEFAULT —— Default_Allocator.allocator_proc（olib 的 runtime.heap_allocator）
#import "Basic";
F :: #import "jfoster";
HASH :: #import "Hash_Table";
THREAD :: #import "Thread";
DEFAULT :: #import "Default_Allocator";

#load "cli_console.jai";
