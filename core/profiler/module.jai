// profiler/module.jai — 聚合入口：`#import "core/profiler"`。
// 与 olib core/profiler 对位：作用域计时统计（count / total / max，全局名字表，
// profile_dump 打印 avg / max / total 毫秒）。
//
// Jai 差异见 profiler.jai 文件头（无 @(deferred_out)，改为显式配对
// profile_scope + deferred profile_scope_end；Duration 为纳秒 s64）。

#load "profiler.jai";
