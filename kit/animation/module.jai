// animation/module.jai — 聚合入口：`#import "kit/animation"`。
// 与 olib kit/animation 对位（animation.odin 单文件，这里一个 #load）。
//
// 与 kit/world 相同：`#load` 进来的文件共享这一层的名字，animation.jai 里不再
// 重复 `#import`，避免「already declared in this scope」。
//
// 三个具名导入，别名照 olib 源码里的限定符（dasset. / world. / math.），
// 移植时正文可以逐行照抄：
//   math   —— sqrt / floor / acos / sin / abs（olib 的 core:math）；
//   dasset —— 骨骼 / 剪辑数据结构（olib 的 core/dasset）；
//   world  —— 行向量约定的 Matrix4（olib 的 kit/world）。
// 必须具名而不能裸导入：Math 与 kit/world 都导出 Matrix4 之类的同名声明，
// 裸导入会遮蔽本包的名字（jacket: declaration-hides-import）。
#import "Basic";
math :: #import "Math";
dasset :: #import "core/dasset";
world :: #import "kit/world";

#load "animation.jai";
