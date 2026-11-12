// devbuild/module.jai — 聚合入口：`#import "core/devbuild"`。
// 与 olib core/devbuild 对位；两个 .odin 文件同属 package devbuild，
// 这里用 #load 合成同一个包（进程串行化 + 集中测试工作区）。

#load "process.jai";
#load "test_workspace.jai";
