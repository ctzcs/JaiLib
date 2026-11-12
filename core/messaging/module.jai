// messaging/module.jai — 聚合入口：`#import "core/messaging"`。
// 与 olib core/messaging 对位：单消费者命令队列 + 延迟一帧的广播通道（均为单线程、
// 无锁；零值可用，dispose 释放内部缓冲）。
//
// Jai 差异见 messaging.jai 文件头（分配器契约、handler 过程指针、int → s64）。

#load "messaging.jai";
