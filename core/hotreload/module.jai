// hotreload/module.jai — 聚合入口：`#import "core/hotreload"`。
// 与 olib core/hotreload 对位；这里只做 #load 聚合。
//
// 文件顺序对位 olib 的 package 内声明：协议(api) → 扫描(scan + 平台层) → 会话(session)
// → 监听(watch) → 一站式入口(hot) → 游戏侧最简入口(simple)。
// Jai 的 #load 把各文件合进同一作用域，所以各文件里的 #import 别名必须互不相同。

#load "api.jai";
#load "scan.jai";
#load "scan_windows.jai";
#load "scan_other.jai";
#load "session.jai";
#load "watch.jai";
