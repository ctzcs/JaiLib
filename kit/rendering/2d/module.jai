// 2d/module.jai — 聚合入口：`#import "kit/rendering/2d"`。
// 与 olib kit/rendering/2d 一一对位：
//
//   atlas.odin          → atlas.jai          （核心图集：纹理 + 「名字 -> 像素矩形」，Grid / Kenney XML 来源）
//   atlas_aseprite.odin → atlas_aseprite.jai （.aseprite 目录 -> 单张图集的构建器）
//   render2d.odin       → render2d.jai       （Render2D：2D 唯一的绘制入口 + 常驻精灵实例缓冲）
//   animation_set.odin  → animation_set.jai  （帧动画集合：图集子图 + 时长 + 命名动画）
//
// 公开过程/结构体/字段名、参数顺序、返回语义与 olib 完全一致；逐文件的 Jai 差异列在该文件头。
// 全局影响所有文件的差异只有下面四条（都与 jfoster / Jai 的形态有关，不是接口发明）：
//
//   1. foster.X（值类型 + .Resource 句柄）→ jfoster 的 *F.X（堆对象 + .handle）。
//      判据从 `.Resource != nil` 变成 `.handle != 0`；释放统一走 atlas_texture_release /
//      render2d_mesh_release / render2d_buffer_release（先还 GPU 资源再 free 结构体），与 material 包同一写法。
//   2. foster 的名字 → jfoster 的名字：Vec2→Vector2、RectInt→Rect_Int{x,y,w,h}、
//      BatcherVertex→Batcher_Vertex{pos,tex,col,mode}、TextureSamplerMake→texture_sampler_make(.NEAREST, …)、
//      BlendModePremultiply→Blend_Mode_Premultiply、Subtexture.Texture→Subtexture.Tex、
//      AsepriteLoopDir→Aseprite_Loop_Direction（.FORWARD/.REVERSE/…）、AsepriteFrame.Duration→DurationMS。
//   3. Odin 的 map / [dynamic]T / pop → Table（Hash_Table，作为形参要传指针）/ [..]T + array_add / render2d_pop。
//   4. 内置图标通过 #run + File.read_entire_file 嵌入 assets/icons，不依赖进程工作目录。
//
// 导入说明（与 kit/rendering/material、kit/rendering/shader 同一写法：#load 进来的文件共享这一层的
// 名字，各文件里不再重复 #import，避免「already declared in this scope」）：
//   Basic  —— 不具名：alloc / copy_string / memcpy / memset / array_add / array_free / array_resize /
//             array_view / clamp / max / min / New / tprint / talloc ...
//   STRING —— String：trim / ends_with / to_lower_copy / compare / join / find_index_from_right
//   JM     —— Math：sqrt / cos / sin / TAU / Vector2
//   F      —— jfoster：Batcher_Vertex / Mesh / Graphics_Buffer / Material / Texture / Subtexture /
//             Packer / Aseprite / Drawable_Target / Draw_Command / Rect / Rect_Int / Color ...
//   mat    —— kit/rendering/material：Material / Material_Library / Draw_Error / Pass_Id / Pass_Selection /
//             material_select / material_pass_values / Instance_Values / Instance_Table / instance_*
//   sh     —— kit/rendering/shader：Shader_Desc / Pass_Desc / MAX_PASSES / MAX_INSTANCE_FIELDS /
//             INSTANCE_FIXED_ATTRIBUTES / field_sprite_sampler / instance_count / shader_is_sprite
//   HASH   —— Hash_Table：Table / table_add / table_set / table_find_pointer / deinit（olib 的 map）
//   XML    —— core/encoding：Xml_Node 树（Kenney XML 来源；olib 用 core:encoding/xml）
//   FILE   —— File：read_entire_file（.aseprite 读取）
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
F :: #import "foster";
mat :: #import "kit/rendering/material";
sh :: #import "kit/rendering/shader";
HASH :: #import "Hash_Table";

using HASH; // `for v, k: table` 的 for_expansion 必须在同一作用域可见（olib 的 map 迭代）

XML :: #import "core/encoding";
FILE :: #import "File";

#load "atlas.jai";
#load "atlas_aseprite.jai";
#load "render2d.jai";
#load "animation_set.jai";
