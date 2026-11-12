// codegen/module.jai — 聚合入口：`#import "core/codegen"`。
// 与 olib core/codegen 对位。odin 的 package 由同目录 .odin 自动组成，Jai 没有这种
// 自动合并，所以这里用 #load 显式合成同一个模块（生成出来的 *_generated.jai 同理，
// 需要由所属包的 module.jai 显式 #load）。

#load "codegen.jai";
