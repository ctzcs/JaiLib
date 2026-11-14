// world/module.jai — 聚合入口：`#import "kit/world"`。
// 与 olib kit/world 对位；矩阵/相机/射线/视锥全部无分配，参数由调用方持有。
//
// 除 #load 外只有三行 import 绑定：`#load` 进来的文件共享这一层的名字
// （Jai 与 jfoster 的既有写法一致），各文件里不再重复声明，避免
// 「already declared in this scope」。
//
// 两个具名导入（不能写成 `Math :: #import "Math"` 或直接 `#import "Math";`）：
// Math 也导出一个 Matrix4，本包按 olib 语义另立同名 4x4（行向量约定），
// 不具名导入会让本包的 Matrix4 遮蔽 Math 的名字（jacket: declaration-hides-import，
// 官方 Jai 直接拒绝）。用具名导入 + `JM.` 前缀后没有这个遮蔽，olib 的公开名保持不变。
#import "Basic";
JM :: #import "Math"; // sqrt / tan / isnan / PI64 / Vector2 / Vector3
F :: #import "foster"; // Point2 / Matrix3x2 的来源（olib 的 foster 对应物）

#load "matrix4.jai";
#load "ray3d.jai";
#load "frustum3d.jai";
#load "camera3d.jai";
#load "camera2d.jai";
#load "scene_router.jai";
