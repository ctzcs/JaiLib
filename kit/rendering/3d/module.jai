// 3d/module.jai — 聚合入口：`#import "kit/rendering/3d"`。
// 与 olib kit/rendering/3d 对位：
//
//   render3d.jai   —— render3d.odin   （View / Render3D 的记录、分段、提交）
//   mesh.jai       —— mesh.odin       （静态/蒙皮顶点格式与上传）
//   queue.jai      —— queue.odin      （不透明前到后 / 透明后到前的稳定排序）
//   lod.jai        —— lod.odin        （屏幕高度阈值选择 + 迟滞）
//   debug_draw.jai —— debug_draw.odin （线段几何生成与提交）
//   uniforms.jai   —— uniforms.odin   （视图/材质/关节块的 std140 打包）
//
// shaders_compiled.jai 是移植新增：jacket 0.35.1 不能在编译期 #load 二进制，
// DebugDraw3D 的 6 份后端字节码以 u8 常量内嵌（字节与 olib 资源一致）。
//
// 具名导入（避免与 olib 的同名包/过程冲突）：
//   F    —— jfoster（Mesh / Buffer / Draw_Command / Material）
//   mat  —— kit/rendering/material
//   sh   —— kit/rendering/shader
//   W    —— kit/world（Matrix4 / Camera3D / Frustum3D）
//   DA   —— core/dasset（骨骼与蒙皮数据）
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
HASH :: #import "Hash_Table";
F :: #import "jfoster";
mat :: #import "kit/rendering/material";
sh :: #import "kit/rendering/shader";
W :: #import "kit/world";
DA :: #import "core/dasset";

#load "queue.jai";
#load "lod.jai";
#load "uniforms.jai";
#load "mesh.jai";
#load "shaders_compiled.jai";
#load "debug_draw.jai";
#load "render3d.jai";
