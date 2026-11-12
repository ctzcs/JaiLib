// shader_lab/module.jai — 聚合入口：`#import "kit/tools/shader_lab"`。
// 与 olib kit/tools/shader_lab 一一对位（package shader_lab 的 12 个 .odin 文件）：
//
//   session.odin        → session.jai        （Session / Config / Preview_Hooks / 工作区书签 / 生命周期）
//   bank.odin           → bank.jai           （Parameter_Bank：整包切换、选中映射、提交）
//   parameters.odin     → parameters.jai      （Parameter_State / 自动面板 / 贴图选择 / 贴图热重载）
//   presets.odin        → presets.jai         （数值应用、默认值恢复、预设存取）
//   files.odin          → files.jai           （宿主文件对话框请求 / 回复、贴图戳、新建 Shader 模板）
//   material_files.odin → material_files.jai  （材质与预设的文件编解码读写）
//   color_picker.odin   → color_picker.jai    （模态调色板：打开记原色、取消完整恢复）
//   shader_panel.odin   → shader_panel.jai    （Shader 选择、Pass 列表、检查器、Pass 覆盖查询）
//   shader_runtime.ioruntime.odin → shader_runtime.jai （Pass_Target / 目标分配 / Pass 命令 / shader_render）
//   material_preview.odin → material_preview.jai（材质 Shader 的 Render2D/Render3D 预览与材质存取）
//   shapes.odin         → shapes.jai          （程序化立方体/球体，走 dasset → r3d.mesh_upload）
//   windows.odin        → windows.jai         （控制窗口 / 预览窗口 / 每帧入口 / 控件封装）
//
// 公开过程/结构体/字段名、参数顺序、默认参数与返回语义与 olib 完全一致；逐文件的 Jai 差异列在
// 该文件头。全局影响所有文件的差异只有下面六条（都与 jfoster 形态、ImGui 绑定与资产缺失有关，
// 不是接口发明）：
//
//   1. foster.X（值类型 + .Resource）→ jfoster 的 *F.X（堆对象 + .handle）。判据从
//      `.Resource != nil` 变成 `.handle != 0`：Texture / Mesh / Target / Shader / Material 全部一样，
//      释放走 F.texture_dispose / F.mesh_dispose / F.target_dispose / F.material_destroy。
//   2. foster.Target 的 Attachments 是 []TargetAttachment（值），jfoster 是 [..] *Texture；
//      foster.TargetInit(t, dev, w, h, specs, name) → F.target_create_attachments(dev, w, h, infos, name)
//      （返回堆对象），foster.TargetAttachment(t) → F.target_texture(t)，
//      foster.DrawableTargetFromTarget(t) → F.drawable_target_target(t)。
//   3. foster.MaterialStageSetUniformBuffer(&stage, buf, slot) → F.material_stage_set_uniform(&stage, slot, buf)。
//      foster.GraphicsDeviceDraw(dev, &cmd) → F.graphics_device_draw(dev, cmd)（按值传命令）；
//      foster.DrawCommandDispose(&cmd) 不存在：jfoster 的 Draw_Command 不含动态数组，无需释放。
//   4. **热重载路径**：jfoster 没有 ShaderPairTryReplace，`dev.apply` 在 JaiLib 是未实现的 seam
//      （dev.Session.vertex / .fragment 恒为 null，诊断文本见 dev.SHADER_PAIR_REPLACE_UNAVAILABLE）。
//      因此 bank 不再“原位替换 GPU 程序”，而是用 dev 候选包编译出的字节码
//      （dev.Build.code[2]）直接 F.shader_create 出新的 Shader 对再 F.material_create。语义等价：
//      bank 存活期间的 Material 地址仍然固定（一次分配、不再增长），旧包整体释放。
//   5. **图标图集未移植**：r2d.builtin_icons_decode / imgui_foster.Icons 依赖 olib 的
//      assets/icons/game-icons.{xml,png}，不属于本仓库（见 kit/rendering/2d/module.jai 第 4 条）。
//      这里保留 Icon_Set 类型与 ICON_NAMES 表，但表为空，lab_button 退化为纯文字按钮；
//      id / label / track 语义不变，因此宿主注入点击的稳定 ID 不受影响。
//   6. ImGui：olib 的 `imgui.X` → Jai stdlib 的 ImGui 模块（`ImGui.X`）。olib 用 imgui_impl_ofoster
//      的 Texture()/IconButton()，本包用 imgui_texture_id()（把 *F.Texture 转成 ImTextureID）与
//      lab_button（文字按钮）替代；DrawList_AddXxx 走 thirdparty/imgui_foster 的 foreign 声明。
//
// 导入说明（与 kit/ui、kit/gizmo 同一写法：#load 进来的文件共享这一层的名字，各文件里不再
// 重复 #import，避免「already declared in this scope」）：
//   Basic  —— 不具名：array_add / array_free / array_resize / array_view / clamp / max / min /
//             memcpy / memset / free / New / cast / copy_string / tprint / temp / Allocator ...
//   STRING —— String：has_prefix / replace / to_lower / path 辅助
//   JM     —— Math：sin / cos / sqrt / floor / clamp / abs / PI / isnan / isinf / Vector2
//   FILE   —— File：read_entire_file / write_entire_file / get_absolute_path
//   FU     —— File_Utilities：file_list / file_visit（目录枚举）
//   HASH   —— Hash_Table：Table / table_add / table_find（widgets 的稳定 ID → 矩形）
//   F      —— jfoster：Graphics_Device / Mesh / Shader / Material / Texture / Target /
//             Draw_Command / Drawable_Target / Vertex_Format / Image / Color / Rect / Rect_Int ...
//   sh     —— kit/rendering/shader：Schema / Field / Value / Instance / Shader_Desc / Pass_Desc ...
//   dev    —— kit/rendering/shader/dev：Session / Status / Parameter_Watch / Parameter_Build
//   mat    —— kit/rendering/material：Material / Material_Library / Material_Binding / pass_state_apply
//   r2d    —— kit/rendering/2d：Render2D
//   r3d    —— kit/rendering/3d：Render3D / Model_Buffer / mesh_upload / pack_material_blocks
//   W      —— kit/world：Camera3D / Matrix4 / Vec3
//   DA     —— core/dasset：Dasset_Primitive / Dasset_Vertex / Dasset_Material / Dasset_Bounds
//   ImGui  —— stdlib ImGui 声明（宿主负责 context 与帧）
//   IMGF   —— thirdparty/imgui_foster：DrawList 的 foreign 包装
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
FILE :: #import "File";
FU :: #import "File_Utilities";
HASH :: #import "Hash_Table";
using HASH;

F :: #import "jfoster";
sh :: #import "kit/rendering/shader";
dev :: #import "kit/rendering/shader/dev";
mat :: #import "kit/rendering/material";
r2d :: #import "kit/rendering/2d";
r3d :: #import "kit/rendering/3d";
W :: #import "kit/world";
DA :: #import "core/dasset";

ImGui :: #import "ImGui";
IMGF :: #import "thirdparty/imgui_foster";

// kit/tools 共用的 ImGui 薄包装（标签吃 string）：本包内所有 ImGui 控件调用都走它。
#load "../lab_imgui.jai";

#load "shapes.jai";
#load "session.jai";
#load "shader_runtime.jai";
#load "bank.jai";
#load "parameters.jai";
#load "presets.jai";
#load "files.jai";
#load "material_files.jai";
#load "color_picker.jai";
#load "shader_panel.jai";
#load "material_preview.jai";
#load "windows.jai";
