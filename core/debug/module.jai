// debug/module.jai — 聚合入口：`#import "core/debug"`。
// 与 olib core/debug 对位：Tracking_Allocator 的 defer 包装（track_create / track_destroy），
// 报告泄漏与非法释放。
//
// Jai 差异见 debug.jai 文件头（无 @(deferred_out)，改为显式配对；分配器协议不带
// #caller_location，故逐条分配的源码位置不可得）。

#load "debug.jai";
