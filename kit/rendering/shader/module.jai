// shader/module.jai — 聚合入口：`#import "kit/rendering/shader"`。
// 与 olib kit/rendering/shader 对位（package shader 的四个 .odin 文件）：
//
//   shader.jai     —— shader.odin     （Shader_Desc / Pass_Desc / 校验 / 拓扑排序 / 克隆）
//   parameters.jai —— parameters.odin （Schema / Field / Value / 槽布局 / pack / 每 Pass 的 HLSL）
//   resource.jai   —— resource.odin   （单材质文件的字节编解码）
//   instance.jai   —— instance.odin   （对象材质实例：多参数组 + 编解码）
//
// 子包与 olib 一样各自成包（Jai 一个目录一个包）：
//   kit/rendering/shader/lang    —— olib lang   （.oshader 解析 + 两条 D3D12 规则）
//   kit/rendering/shader/compile —— olib compile（工具身份 / 命令行 / 阶段编译）
//   kit/rendering/shader/dev     —— olib dev    （.oshader 候选包、后台监听、热重载）
//
// 两个具名导入（本包的 jfoster 依赖只有一个字段：Texture_Sampler）：
//   F  —— jfoster 的 graphics 面（Texture_Sampler / texture_sampler_make / 枚举）
//   JM —— Math（isnan / isinf；Jai 的 Math 导出一个同名 Matrix4，本包不用它，具名导入避免遮蔽）
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";
F :: #import "foster";
HASH :: #import "Hash_Table";
JSON :: #import "core/encoding";

#load "shader.jai";
#load "parameters.jai";
#load "resource.jai";
#load "instance.jai";
