// kit/gizmo/module.jai — 聚合入口：`#import "kit/gizmo"`。
// 与 olib kit/gizmo 一一对位：
//
//   translation.odin → translation.jai （移动专用手柄：投影、命中、拖拽生命周期；内部工具也在这里）
//   transform.odin   → transform.jai   （三维手柄：移动 / 旋转 / 缩放的世界空间几何与状态机）
//   transform2d.odin → transform2d.jai （二维手柄：Render2D 覆盖层 + Camera2D 数学）
//   render3d.odin    → render3d.jai    （世界空间顶点生成 + 两通道深度绘制 + Renderer3D 资源）
//   wireframe.odin   → wireframe.jai   （网格线框：CPU 参考实现、实例上传、240 字节常量）
//
// shaders_compiled.jai 是移植新增：jacket 0.35.1 不能在编译期 #load 二进制，
// olib 的 12 份预编译字节码（Gizmo3D / Wireframe3D × spv/dxil/msl）以 u8 常量内嵌，
// 与 kit/rendering/3d/shaders_compiled.jai 同一处理，字节与 olib 仓库逐字节相同。
//
// 公开过程/结构体/字段名、参数顺序、默认参数与返回语义与 olib 完全一致；
// 逐文件的 Jai 差异列在该文件头。全局影响所有文件的差异只有下面五条：
//
//   1. foster.X 的名字 → jfoster / kit/world 的名字：
//      Vec3/Vec2 → W.Vec3 / W.Vec2（Math.Vector3 / Vector2 的别名）、
//      Rect{X,Y,Width,Height} → F.Rect{x,y,w,h}、Color{R,G,B,A} → F.Color{r,g,b,a}、
//      Matrix3x2 → F.Matrix3x2、Color.A == 0 → color.a == 0。
//   2. 向量算术：olib 用 `a + b` / `a * s`，Jai 的运算符只在声明它的模块内可见（跨模块会触发
//      jacket 的 operator-out-of-scope 警告），所以统一走 gizmo_v2_* / gizmo_v3_* 与 kit/world
//      已有的 W.v3_sub / v3_dot / v3_cross；Odin 的 `v[axis]` 写法对应 `.component[axis]`。
//   3. Odin 的值类型 GPU 对象（foster.Mesh / Shader / Material）→ jfoster 的堆对象：
//      *F.Mesh / *F.Shader / *F.Material；就绪判据从 `.Resource != nil` 变成 `.handle != 0`，
//      释放走 gizmo_mesh_release / gizmo_shader_release（先还 GPU 资源再 free 结构体）。
//   4. `[dynamic]T` + append / clear / delete → `[..] T` + array_add / gizmo_array_clear / array_free。
//   5. `@(private)` 没有等价物：内部过程加 gizmo_ 前缀（gizmo_finite、gizmo_v2_dot、gizmo_rotate_world、
//      gizmo_tube、gizmo_draw_depth_tested …），行为与 olib 的同名私有过程一致。
//
// 导入说明（与 kit/rendering/3d、kit/rendering/2d 同一写法：#load 进来的文件共享这一层
// 的名字，各文件里不再重复 #import，避免「already declared in this scope」）：
//   Basic  —— 不具名：array_add / array_reserve / array_free / array_view / clamp / max / min /
//             memcpy / free / array 全家的辅助
//   JM     —— Math：sqrt / tan / cos / sin / atan2 / floor / abs / isnan / isinf / PI /
//             FLOAT32_INFINITY / Vector2 / Vector3
//   F      —— jfoster：Mesh / Shader / Material / Graphics_Device / Graphics_Buffer /
//             Draw_Command / Drawable_Target / Vertex_Format / Rect / Rect_Int / Color
//   W      —— kit/world：Camera3D / Camera2D / Matrix4 / Ray3D / Matrix3x2 辅助 / v3_* 向量辅助
//   mat    —— kit/rendering/material：shader_driver_supported / shader_pick / Shader_Binaries /
//             std140_write_matrix / std140_write_vec4
//   r2d    —— kit/rendering/2d：Render2D（二维覆盖层的记录入口）
//   MSH    —— core/meshutil：Edge / Edge_Kind（线框的边来源）
#import "Basic";
JM :: #import "Math";
F :: #import "foster";
W :: #import "kit/world";
mat :: #import "kit/rendering/material";
r2d :: #import "kit/rendering/2d";
MSH :: #import "core/meshutil";

#load "translation.jai";
#load "transform.jai";
#load "transform2d.jai";
#load "shaders_compiled.jai";
#load "render3d.jai";
#load "wireframe.jai";
