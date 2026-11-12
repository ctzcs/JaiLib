// lang/module.jai — 聚合入口：`#import "kit/rendering/shader/lang"`。
// 与 olib kit/rendering/shader/lang 对位：
//
//   lang.jai        —— lang.odin        （.oshader 词法/语法分析、每个 Pass 的 HLSL 生成）
//   hlsl_rules.jai  —— hlsl_rules.odin  （两条 D3D12 语义重编号规则）
//   include/olib/*.hlsli —— 同名的标准 include（引擎 b0 块、实例与精灵接口）
//
// include/ 是**数据资产**，不参与 Jai 编译：shadercross 只接受一个 -I，
// compile/dev 在编译前把 include/olib 复制到各自的临时目录（见 dev/compiler.jai）。
//
// 具名导入：
//   sh —— kit/rendering/shader（Schema / Field / Shader_Desc / shader_order / hlsl ...）
//   STRING / JM —— String / Math（Jai 的 Basic 不提供 begins_with、isnan 等）
#import "Basic";
STRING :: #import "String";
JM :: #import "Math";

sh :: #import "kit/rendering/shader";

#load "lang.jai";
#load "hlsl_rules.jai";
