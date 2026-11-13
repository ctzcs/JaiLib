// material/module.jai — 聚合入口：`#import "kit/rendering/material"`。
// 与 olib kit/rendering/material 一一对位：
//
//   material.odin         → material.jai          （材质实例：加载/替换/数值/贴图）
//   material_library.odin → material_library.jai  （材质库：登记 Shader、惰性建 GPU 程序、贴图缓存、内置 2D Shader）
//   draw.odin             → draw.jai              （Render2D/Render3D 共用：绑定、Pass 选择、Pass 状态、参数打包）
//   shader_code.odin      → shader_code.jai       （按驱动选字节码、清单/目录登记）
//   instance_values.odin  → instance_values.jai   （每实例值：槽位、覆盖、求值表）
//   std140.odin           → std140.jai            （手写 cbuffer 的 CPU 侧打包）
//
// 公开过程/结构体/字段名、参数顺序、返回语义与 olib 完全一致；逐文件的 Jai 差异列在该文件头。
// 全局影响所有文件的差异只有下面五条（都与 jfoster 的形态有关，不是接口发明）：
//
//   1. foster.X（值类型 + .Resource 句柄）→ jfoster 的 *F.X（堆对象 + .handle）。
//      因此 olib 的 `library.white: foster.Texture`、`shader.gpu: []foster.Material`、
//      `shader.vertex: []foster.Shader` 在本包里是 `*F.Texture` / `[]*F.Material` / `[]*F.Shader`。
//      「句柄非空」的判据从 `.Resource != nil` 变成 `.handle != 0`。
//   2. `foster.MaterialInitWithShaders(&m, &vs, &fs)` → `F.material_create(vs, fs)`（返回堆对象）；
//      `foster.MaterialDispose` → `F.material_destroy`。语义相同：只建/只销毁 Material 本身，
//      它引用的 Shader 归调用方（内置 Shader 归设备）。
//   3. `foster.ShaderInit(&s, dev, {Stage, Code, UniformBufferCount, SamplerCount, StorageBufferCount,
//      EntryPoint}, name)` → `F.shader_create(dev, stage, code, sampler_count=…, uniform_buffer_count=…,
//      storage_buffer_count=…, entry_point=…, name=…)`。jfoster 没有“失败 panic”的包装，
//      失败表现为 handle == 0，本包照 olib 的 material_shader_prepare 判空返回 false。
//   4. `#load_directory`（`runtime.Load_Directory_File`）在 jacket 0.35.1 里不可用，
//      所以 material_register_directory 吃本包自带的 Load_Directory_File，并额外提供
//      material_load_directory / material_load_directory_free 在运行时读目录（见 shader_code.jai）。
//   5. Foster 已有 WebGL2 后端，但本模块的预编译 material 目录登记仍只接受 native
//      字节码；shader_driver_supported 在 wasm 返回 false。不能把 Foster 的 Web 回归
//      推广成整个 kit/material 的 Web 能力已经验收。
//
// 导入说明（与 kit/world、kit/asset、kit/rendering/shader 同一写法：#load 进来的文件共享这一层
// 的名字，各文件里不再重复 #import，避免「already declared in this scope」）：
//   Basic   —— 不具名：alloc / alloc_string / copy_string / memcpy / memset / print / tprint /
//              temp / talloc / talloc_string / free / array_add / array_free / clamp / max / min /
//              New / xx / enum_names / enum_values_as_s64 ...
//   STRING  —— String：begins_with / ends_with / contains（olib strings.has_prefix/has_suffix/contains）
//   JM      —— Math：isnan / isinf（olib math.is_nan / math.is_inf）
//   F       —— jfoster：olib foster 的对应物（Graphics_Device / Shader / Material / Texture /
//              Bound_Sampler / Draw_Command / Storage_Container / Image / Color ...）
//   sh      —— kit/rendering/shader：Schema / Field / Value / Instance / Shader_Desc / Pass_Desc /
//              pack / instance_make / instance_decode ...（olib `sh "../shader"`）
//   JSON    —— core/encoding：JSON 解析（olib core:encoding/json，本仓库的 Json_Value 树）
//   FILE    —— File：read_entire_file（目录登记用）
//   FU      —— File_Utilities：file_list（替代 #load_directory）
//   HASH    —— Hash_Table：Json_Value 的对象成员查找（见 sh.shader_json_member）
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
F :: #import "foster";
sh :: #import "kit/rendering/shader";
JSON :: #import "core/encoding";
FILE :: #import "File";
FU :: #import "File_Utilities";
HASH :: #import "Hash_Table";

#load "std140.jai";
#load "instance_values.jai";
#load "draw.jai";
#load "shader_code.jai";
#load "material_library.jai";
#load "material.jai";
