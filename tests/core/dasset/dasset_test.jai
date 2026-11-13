// 一比一移植自 olib tests/core/dasset/dasset_test.odin（写读往返 + 坏文件防御）。
// core:testing.expect 换成 test_support.expect；断言数值、拆分与顺序保持原样。
// Odin 的 `if !testing.expectf(...) { return }` 在 Jai 里拆成 `expect(...)` + `if !x return`：
// 断言计数与提前返回的控制流都与 olib 相同。
// 内部辅助过程（make_test_model / make_minimal_v4 / matrix_identity16）加了 dasset_ 前缀，
// 因为测试文件会被聚合到同一个运行入口里。
//
// olib 的两个测试之外，这里多三个过程（都用 expect 断言，不写 main）：
//   - dasset_binary_layout_and_byte_roundtrip：结构体尺寸 / 文件头 / 953 字节的黄金哈希 /
//     写→读→写 逐字节相等（守住「与 DragonLib v4 比特兼容」）；
//   - dasset_reads_legacy_versions：手写 v1/v2/v3 字节流，验证 Reader 的版本分支；
//   - dasset_rejects_corrupt_counts：计数越界（不产生巨额分配）与枚举越界。
//
// Jai 侧差异：`==` 不支持定点数组（会去匹配 S128 的 operator==），比较用下面的
// dasset_test_f32_array_eq；定长数组字面量写 `.[...]`；`for i in 0..<n` 写 `for 0..n - 1`。
#import "Basic" ;
#import "test_support" ;
DASSET :: #import "core/dasset" ;

 // Jai 的 == 不支持定点数组（会去找 S128 的 operator==），逐分量比较等价于 Odin 的数组 ==。
dasset_test_f32_array_eq :: ( a : $T , b : T ) -> bool {
for x , i : a {
if x != b [ i ] return false ;
}
return true ;
}

 // olib（Odin）dasset_write 对同一测试模型写出的 953 字节的 FNV-1a 64。
// 已用 olib 实现实际生成并逐字节比对确认（与 DragonLib DassetWriter v4 比特兼容）。
DASSET_TEST_GOLDEN_FNV : u64 : 0xb59c2ba327e67039 ;
DASSET_TEST_GOLDEN_LEN :: 953 ;

 dasset_test_fnv1a64 :: ( data : [ ] u8 ) -> u64 {
h : u64 = 0xcbf29ce484222325 ;
for b : data {
h = ( h ^ cast ( u64 ) b ) * 0x100000001b3 ;
}
return h ;
}

 //@region 写读往返

 dasset_roundtrip_full_model :: ( state : * Test_State ) {
model := dasset_make_test_model ( ) ;
defer DASSET . dasset_model_dispose ( * model ) ;

 bytes , ok := DASSET . dasset_write ( * model ) ;
defer array_free ( bytes ) ;
expect ( state , ok , "写出失败" ) ;
if ! ok return ;

 back , err := DASSET . dasset_read ( bytes ) ;
defer DASSET . dasset_model_dispose ( * back ) ;
expect ( state , err == . None , "读回失败: %" , err ) ;
if err != . None return ;

 // 贴图
expect ( state , back . textures . count == 1 , "贴图数" ) ;
tex := back . textures [ 0 ] ;
expect ( state , tex . name == "albedo" && tex . codec == . Png && tex . bytes . count == 4 && tex . bytes [ 3 ] == 9 , "贴图字段往返" ) ;

 // 骨架
expect ( state , back . skeletons . count == 1 , "骨架数" ) ;
skel := back . skeletons [ 0 ] ;
expect ( state , skel . joints . count == 2 , "关节数" ) ;
expect ( state , skel . joints [ 0 ] . name == "root" && skel . joints [ 0 ] . parent_index == - 1 , "根关节" ) ;
expect ( state , skel . joints [ 1 ] . parent_index == 0 , "子关节父下标" ) ;
expect ( state , skel . joints [ 0 ] . inverse_bind_matrix [ 15 ] == 1 , "inverse bind matrix" ) ;

 // primitives：静态 + 蒙皮
expect ( state , back . primitives . count == 2 , "primitive 数" ) ;
p0 := back . primitives [ 0 ] ;
expect ( state , ! DASSET . dasset_primitive_is_skinned ( * p0 ) && p0 . vertices . count == 3 && p0 . skin_index == - 1 , "静态 primitive" ) ;
expect ( state , dasset_test_f32_array_eq ( p0 . vertices [ 2 ] . uv , .[ 0.5 , 0.25 ] ) , "uv 往返" ) ;
expect ( state , p0 . indices . count == 3 && p0 . indices [ 2 ] == 5 , "索引往返" ) ;
p1 := back . primitives [ 1 ] ;
expect ( state , DASSET . dasset_primitive_is_skinned ( * p1 ) && p1 . skin_vertices . count == 1 && p1 . skin_index == 0 , "蒙皮 primitive" ) ;
expect ( state , p1 . skin_vertices [ 0 ] . joints == 0x01020003 , "joints 打包" ) ; // byte0|byte1<<8|...
expect ( state , p1 . skin_vertices [ 0 ] . weights [ 3 ] == 0.25 , "weights 往返" ) ;

 // 材质（v3 字段）
m := p1 . material ;
expect ( state , dasset_test_f32_array_eq ( m . base_color_factor , .[ 1 , 0.5 , 0.25 , 1 ] ) , "base_color_factor" ) ;
expect ( state , m . metallic == 0.1 && m . roughness == 0.9 , "metallic/roughness" ) ;
expect ( state , m . alpha_mode == . Blend && m . double_sided && m . alpha_cutoff == 0.5 , "alpha 设置" ) ;
expect ( state , m . albedo_texture_index == 0 && m . normal_texture_index == - 1 , "贴图索引" ) ;
expect ( state , m . emissive_texture_index == 0 && dasset_test_f32_array_eq ( m . emissive_factor , .[ 0.1 , 0.2 , 0.3 ] ) , "自发光" ) ;

 // 剪辑（cubic + v4 插值）
expect ( state , back . clips . count == 1 , "剪辑数" ) ;
clip := back . clips [ 0 ] ;
expect ( state , clip . name == "idle" && clip . skin_index == 0 && clip . duration == 2 , "剪辑头" ) ;
expect ( state , clip . channels . count == 2 , "channel 数" ) ;
ch := clip . channels [ 0 ] ;
expect ( state , ch . interpolation == . Cubic_Spline && ch . path == . Rotation , "cubic rotation" ) ;
expect ( state , ch . times . count == 2 && ch . times [ 1 ] == 1.5 , "关键帧时间" ) ;
expect ( state , dasset_test_f32_array_eq ( ch . values [ 1 ] , .[ 0 , 0.7 , 0 , 0.7 ] ) , "关键帧值" ) ;
expect ( state , dasset_test_f32_array_eq ( ch . in_tangents [ 0 ] , .[ 0.1 , 0 , 0 , 0 ] ) , "入切线" ) ;
expect ( state , dasset_test_f32_array_eq ( ch . out_tangents [ 1 ] , .[ 0 , 0.2 , 0 , 0 ] ) , "出切线" ) ;
ch1 := clip . channels [ 1 ] ;
expect ( state , ch1 . interpolation == . Linear && ch1 . in_tangents . count == 0 , "linear 无切线" ) ;

 // 模型级 AABB
expect ( state , dasset_test_f32_array_eq ( back . bounds . min , .[ - 1 , - 2 , - 3 ] ) && dasset_test_f32_array_eq ( back . bounds . max , .[ 4 , 5 , 6 ] ) , "模型 AABB" ) ;
}
//@endregion

 //@region 坏文件防御

 dasset_rejects_bad_input :: ( state : * Test_State ) {
// 魔数不符
bad : [ 8 ] u8 = .[ 0 , 0 , 0 , 0 , 4 , 0 , 0 , 0 ] ;
bad_view : [ ] u8 = bad ;
m0 , err := DASSET . dasset_read ( bad_view ) ;
DASSET . dasset_model_dispose ( * m0 ) ;
expect ( state , err == . Not_Dasset , "魔数不符应为 Not_Dasset" ) ;

 // 版本超界
high : [ 8 ] u8 = .[ 0x44 , 0x41 , 0x53 , 0x54 , 99 , 0 , 0 , 0 ] ;
high_view : [ ] u8 = high ;
m1 , err2 := DASSET . dasset_read ( high_view ) ;
DASSET . dasset_model_dispose ( * m1 ) ;
expect ( state , err2 == . Bad_Version , "版本超界应为 Bad_Version" ) ;

 // 截断
bytes , ok := dasset_make_minimal_v4 ( ) ;
defer array_free ( bytes ) ;
if ok {
cuts : [ 3 ] s64 = .[ 4 , 12 , bytes . count - 1 ] ;
for cut : cuts {
if cut >= bytes . count continue ;
view := array_view ( bytes , 0 , cut ) ;
model , err3 := DASSET . dasset_read ( view ) ;
DASSET . dasset_model_dispose ( * model ) ;
expect ( state , err3 != . None , "截断到 % 应报错" , cut ) ;
}
}

 // 空数据
empty : [ ] u8 ;
m4 , err4 := DASSET . dasset_read ( empty ) ;
DASSET . dasset_model_dispose ( * m4 ) ;
expect ( state , err4 == . Truncated , "空数据应为 Truncated" ) ;
}

 dasset_make_minimal_v4 :: ( ) -> ( [ .. ] u8 , bool ) {
model := dasset_make_test_model ( ) ;
defer DASSET . dasset_model_dispose ( * model ) ;
return DASSET . dasset_write ( * model ) ;
}
//@endregion

 //@region 坏文件防御补充 —— 计数与枚举范围

 // olib 的测试覆盖魔数/版本/截断/空数据；这里补「计数越界不产生巨额分配」与「枚举越界」
// 两类守卫（r_count / 枚举范围检查），它们与 olib 的 dasset_read 逐条对应。
dasset_rejects_corrupt_counts :: ( state : * Test_State ) {
// 贴图数 = 0x7FFFFFFF：r_count 按剩余字节换算后越界 -> Truncated（绝不尝试分配）。
big : [ .. ] u8 ;
DASSET . dasset_w_u32 ( * big , DASSET . DASSET_MAGIC ) ;
DASSET . dasset_w_i32 ( * big , DASSET . DASSET_VERSION ) ;
DASSET . dasset_w_i32 ( * big , 0x7FFFFFFF ) ;
mb , errb := DASSET . dasset_read ( big ) ;
DASSET . dasset_model_dispose ( * mb ) ;
expect ( state , errb == . Truncated , "巨大贴图计数应为 Truncated" ) ;
array_free ( big ) ;

 // 贴图数 = -1：负计数直接拒绝。
neg : [ .. ] u8 ;
DASSET . dasset_w_u32 ( * neg , DASSET . DASSET_MAGIC ) ;
DASSET . dasset_w_i32 ( * neg , DASSET . DASSET_VERSION ) ;
DASSET . dasset_w_i32 ( * neg , - 1 ) ;
mn , errn := DASSET . dasset_read ( neg ) ;
DASSET . dasset_model_dispose ( * mn ) ;
expect ( state , errn == . Truncated , "负贴图计数应为 Truncated" ) ;
array_free ( neg ) ;

 // 贴图 codec = 5：枚举越界 -> Bad_Value。
codec : [ .. ] u8 ;
DASSET . dasset_w_u32 ( * codec , DASSET . DASSET_MAGIC ) ;
DASSET . dasset_w_i32 ( * codec , DASSET . DASSET_VERSION ) ;
DASSET . dasset_w_i32 ( * codec , 1 ) ; // 贴图数
DASSET . dasset_w_string ( * codec , "t" ) ;
DASSET . dasset_w_i32 ( * codec , 5 ) ; // 非法 codec
// r_count(8) 要求每个贴图条目至少剩 8 字节，codec 之后补上 byte_count 占位。
DASSET . dasset_w_i32 ( * codec , 0 ) ;
mc , errc := DASSET . dasset_read ( codec ) ;
DASSET . dasset_model_dispose ( * mc ) ;
expect ( state , errc == . Bad_Value , "非法贴图 codec 应为 Bad_Value" ) ;
array_free ( codec ) ;

 // 版本 0 / 5 都在 1..4 之外。
low : [ 8 ] u8 = .[ 0x44 , 0x41 , 0x53 , 0x54 , 0 , 0 , 0 , 0 ] ;
low_view : [ ] u8 = low ;
ml , errl := DASSET . dasset_read ( low_view ) ;
DASSET . dasset_model_dispose ( * ml ) ;
expect ( state , errl == . Bad_Version , "版本 0 应为 Bad_Version" ) ;

 newer : [ 8 ] u8 = .[ 0x44 , 0x41 , 0x53 , 0x54 , 5 , 0 , 0 , 0 ] ;
newer_view : [ ] u8 = newer ;
mn2 , errn2 := DASSET . dasset_read ( newer_view ) ;
DASSET . dasset_model_dispose ( * mn2 ) ;
expect ( state , errn2 == . Bad_Version , "版本 5 应为 Bad_Version" ) ;

 // 不足 8 字节的头部。
tiny : [ 3 ] u8 = .[ 0x44 , 0x41 , 0x53 ] ;
tiny_view : [ ] u8 = tiny ;
mt , errt := DASSET . dasset_read ( tiny_view ) ;
DASSET . dasset_model_dispose ( * mt ) ;
expect ( state , errt == . Truncated , "不足 8 字节应为 Truncated" ) ;
}
//@endregion

 //@region 二进制布局 / 字节级 round-trip

 // olib 的测试只比对字段值；这里补两组断言，守住「与 DragonLib v4 比特兼容」的要求：
//   1) 顶点结构体尺寸必须等于格式里声明的 stride（48 / 68）；
//   2) 同一模型 写 -> 读 -> 再写 的字节流逐字节相等，且总长度与布局手算值一致。
dasset_binary_layout_and_byte_roundtrip :: ( state : * Test_State ) {
expect ( state , size_of ( DASSET . Dasset_Vertex ) == DASSET . DASSET_VERTEX_STRIDE_STATIC , "静态顶点 48B" ) ;
expect ( state , size_of ( DASSET . Dasset_Skin_Vertex ) == DASSET . DASSET_VERTEX_STRIDE_SKIN , "蒙皮顶点 68B" ) ;
expect ( state , size_of ( DASSET . Dasset_Bounds ) == 24 , "AABB 24B" ) ;
expect ( state , DASSET . DASSET_MAGIC == 0x54534144 , "魔数" ) ;
expect ( state , DASSET . DASSET_VERSION == 4 , "当前版本" ) ;

 model := dasset_make_test_model ( ) ;
defer DASSET . dasset_model_dispose ( * model ) ;

 b1 , ok1 := DASSET . dasset_write ( * model ) ;
defer array_free ( b1 ) ;
expect ( state , ok1 , "第一次写出失败" ) ;
if ! ok1 return ;

 // 文件头：ASCII "DAST" + little-endian 的版本 4。
expect ( state , b1 . count >= 8 && b1 [ 0 ] == 0x44 && b1 [ 1 ] == 0x41 && b1 [ 2 ] == 0x53 && b1 [ 3 ] == 0x54 , "文件头魔数应为 DAST" ) ;
expect ( state , b1 . count >= 8 && b1 [ 4 ] == 4 && b1 [ 5 ] == 0 && b1 [ 6 ] == 0 && b1 [ 7 ] == 0 , "文件头版本应为 LE 4" ) ;

 // 逐段累加得到的 v4 字节数：
//   8 头 + 23 贴图表 + 235 骨架表 + 466 primitives + 24 模型 AABB + 197 剪辑表 = 953
expect ( state , b1 . count == DASSET_TEST_GOLDEN_LEN , "v4 文件字节数应为 953（实际 %）" , b1 . count ) ;
// 黄金值：olib 的 Odin dasset_write 对同一模型的输出逐字节相同（哈希已实测比对）。
h := dasset_test_fnv1a64 ( b1 ) ;
expect ( state , h == DASSET_TEST_GOLDEN_FNV , "字节流应与 olib/DragonLib v4 完全一致（fnv1a=%）" , h ) ;

 back , err := DASSET . dasset_read ( b1 ) ;
defer DASSET . dasset_model_dispose ( * back ) ;
expect ( state , err == . None , "读回失败: %" , err ) ;
if err != . None return ;

 b2 , ok2 := DASSET . dasset_write ( * back ) ;
defer array_free ( b2 ) ;
expect ( state , ok2 , "第二次写出失败" ) ;
expect ( state , b2 . count == b1 . count , "两次写出的字节数应相同（% vs %）" , b1 . count , b2 . count ) ;
same := b2 . count == b1 . count && memcmp ( b1 . data , b2 . data , b1 . count ) == 0 ;
expect ( state , same , "写→读→写 的字节流应逐字节相等" ) ;
}
//@endregion

 //@region v1..v3 读兼容

 // olib 的测试没有覆盖版本分支；「Reader 兼容 1..4」是硬性要求，这里手写旧版字节流。
// 字节由模块的写辅助拼出（写辅助本身已由上面的黄金哈希与 olib 比对过）：
//   v1：无骨架段、primitive 无布局前缀、材质无 v3 字段、无剪辑段；
//   v2：有骨架段 + primitive 布局前缀 + 剪辑段，但材质仍无 v3 字段、channel 无插值；
//   v3：材质有 v3 字段，channel 仍无插值（v4 才写）。
dasset_reads_legacy_versions :: ( state : * Test_State ) {
versions : [ 3 ] s32 = .[ 1 , 2 , 3 ] ;
for version : versions {
buf := dasset_test_make_legacy ( version ) ;
m , err := DASSET . dasset_read ( buf ) ;
expect ( state , err == . None , "v% 应能读入（err=%）" , version , err ) ;
if err == . None {
expect ( state , m . textures . count == 1 && m . textures [ 0 ] . name == "t" &&
m . textures [ 0 ] . bytes . count == 1 && m . textures [ 0 ] . bytes [ 0 ] == 7 , "v% 贴图表" , version ) ;
expect ( state , m . skeletons . count == 0 , "v% 无骨架" , version ) ;
expect ( state , m . primitives . count == 1 , "v% primitive 数" , version ) ;
p := m . primitives [ 0 ] ;
expect ( state , p . vertices . count == 1 && p . skin_index == - 1 && p . indices . count == 0 , "v% 静态 primitive" , version ) ;
expect ( state , dasset_test_f32_array_eq ( p . vertices [ 0 ] . position , .[ 1 , 2 , 3 ] ) , "v% 顶点位置" , version ) ;
expect ( state , dasset_test_f32_array_eq ( p . vertices [ 0 ] . normal , .[ 0 , 0 , 1 ] ) , "v% 顶点法线" , version ) ;
expect ( state , dasset_test_f32_array_eq ( p . vertices [ 0 ] . tangent , .[ 0 , 0 , 0 , 1 ] ) , "v% 顶点切线" , version ) ;
expect ( state , dasset_test_f32_array_eq ( p . bounds . min , .[ - 1 , - 2 , - 3 ] ) &&
dasset_test_f32_array_eq ( p . bounds . max , .[ 4 , 5 , 6 ] ) , "v% primitive AABB" , version ) ;
expect ( state , p . material . alpha_mode == . Opaque && ! p . material . double_sided &&
p . material . alpha_cutoff == 0.5 && p . material . albedo_texture_index == - 1 , "v% 材质基础字段" , version ) ;
// v1/v2 没有 v3 字段，值应保持 DASSET_MATERIAL_DEFAULT。
expect ( state , p . material . metallic_roughness_texture_index == - 1 &&
p . material . occlusion_texture_index == - 1 && p . material . occlusion_strength == 1 &&
p . material . emissive_texture_index == - 1 && p . material . normal_scale == 1 , "v% 材质 v3 字段缺省" , version ) ;
expect ( state , dasset_test_f32_array_eq ( m . bounds . min , .[ - 1 , - 2 , - 3 ] ) &&
dasset_test_f32_array_eq ( m . bounds . max , .[ 4 , 5 , 6 ] ) , "v% 模型 AABB" , version ) ;
if version >= 2 {
expect ( state , m . clips . count == 1 , "v% 剪辑表" , version ) ;
clip := m . clips [ 0 ] ;
expect ( state , clip . name == "c" && clip . skin_index == 0 && clip . duration == 1 , "v% 剪辑头" , version ) ;
expect ( state , clip . channels . count == 1 , "v% channel 数" , version ) ;
ch := clip . channels [ 0 ] ;
// v3 及更早没有插值字段，缺省为 Linear（零值 = 第一个成员）。
expect ( state , ch . path == . Rotation && ch . interpolation == . Linear , "v% 缺省插值为 Linear" , version ) ;
expect ( state , ch . times . count == 1 && ch . values . count == 1 , "v% 关键帧数" , version ) ;
expect ( state , dasset_test_f32_array_eq ( ch . values [ 0 ] , .[ 1 , 0 , 0 , 0 ] ) , "v% 关键帧值" , version ) ;
expect ( state , ch . in_tangents . count == 0 && ch . out_tangents . count == 0 , "v% 非 cubic 无切线" , version ) ;
} else {
expect ( state , m . clips . count == 0 , "v% 无剪辑段" , version ) ;
}
}
DASSET . dasset_model_dispose ( * m ) ;
array_free ( buf ) ;
}
}

 // 手写旧版字节流：1 贴图 + 1 静态 primitive（1 顶点/0 索引）+ (v2+)1 剪辑 1 channel。
dasset_test_make_legacy :: ( version : s32 ) -> ( [ .. ] u8 ) {
out : [ .. ] u8 ;
DASSET . dasset_w_u32 ( * out , DASSET . DASSET_MAGIC ) ;
DASSET . dasset_w_i32 ( * out , version ) ;

 // 贴图表：1 张 "t"，1 字节 {7}
DASSET . dasset_w_i32 ( * out , 1 ) ;
DASSET . dasset_w_string ( * out , "t" ) ;
DASSET . dasset_w_i32 ( * out , 0 ) ; // codec Png
DASSET . dasset_w_i32 ( * out , 1 ) ;
DASSET . dasset_w_u8 ( * out , 7 ) ;

 // 骨架表（v2+ 才有这段）
if version >= 2 {
DASSET . dasset_w_i32 ( * out , 0 ) ;
}

 // primitives
DASSET . dasset_w_i32 ( * out , 1 ) ;
if version >= 2 {
DASSET . dasset_w_i32 ( * out , 0 ) ; // layout: Position_Normal_Uv
DASSET . dasset_w_i32 ( * out , - 1 ) ; // skin_index
}
DASSET . dasset_w_i32 ( * out , 1 ) ; // 顶点数
// 48B 静态顶点：pos3 + normal3 + uv2 + tangent4 = 12 个 float32
DASSET . dasset_w_vec3 ( * out , .[ 1 , 2 , 3 ] ) ; // position
DASSET . dasset_w_vec3 ( * out , .[ 0 , 0 , 1 ] ) ; // normal
DASSET . dasset_w_f32 ( * out , 0 ) ; // uv[0]
DASSET . dasset_w_f32 ( * out , 0 ) ; // uv[1]
DASSET . dasset_w_vec4 ( * out , .[ 0 , 0 , 0 , 1 ] ) ; // tangent

 DASSET . dasset_w_i32 ( * out , 0 ) ; // 索引数
DASSET . dasset_w_vec3 ( * out , .[ - 1 , - 2 , - 3 ] ) ; // bounds.min
DASSET . dasset_w_vec3 ( * out , .[ 4 , 5 , 6 ] ) ; // bounds.max

 // 材质：v1/v2 到 normal_texture_index 为止
DASSET . dasset_w_vec4 ( * out , .[ 1 , 1 , 1 , 1 ] ) ;
DASSET . dasset_w_f32 ( * out , 0 ) ; // metallic
DASSET . dasset_w_f32 ( * out , 1 ) ; // roughness
DASSET . dasset_w_u8 ( * out , 0 ) ; // double_sided
DASSET . dasset_w_i32 ( * out , 0 ) ; // alpha_mode Opaque
DASSET . dasset_w_f32 ( * out , 0.5 ) ; // alpha_cutoff
DASSET . dasset_w_i32 ( * out , - 1 ) ; // albedo_texture_index
DASSET . dasset_w_i32 ( * out , - 1 ) ; // normal_texture_index
if version >= 3 {
DASSET . dasset_w_i32 ( * out , - 1 ) ; // metallic_roughness_texture_index
DASSET . dasset_w_i32 ( * out , - 1 ) ; // occlusion_texture_index
DASSET . dasset_w_f32 ( * out , 1 ) ; // occlusion_strength
DASSET . dasset_w_i32 ( * out , - 1 ) ; // emissive_texture_index
DASSET . dasset_w_vec3 ( * out , .[ 0 , 0 , 0 ] ) ; // emissive_factor
DASSET . dasset_w_f32 ( * out , 1 ) ; // normal_scale
}

 // 模型级 AABB
DASSET . dasset_w_vec3 ( * out , .[ - 1 , - 2 , - 3 ] ) ;
DASSET . dasset_w_vec3 ( * out , .[ 4 , 5 , 6 ] ) ;

 // 剪辑表（v2+）：1 剪辑 "c"，1 个 Rotation channel，1 个关键帧，无切线
if version >= 2 {
DASSET . dasset_w_i32 ( * out , 1 ) ;
DASSET . dasset_w_string ( * out , "c" ) ;
DASSET . dasset_w_i32 ( * out , 0 ) ; // skin_index
DASSET . dasset_w_f32 ( * out , 1 ) ; // duration
DASSET . dasset_w_i32 ( * out , 1 ) ; // channel 数
DASSET . dasset_w_i32 ( * out , 0 ) ; // joint_index
DASSET . dasset_w_i32 ( * out , 1 ) ; // path Rotation
// v4 才写 interpolation，这里刻意不写
DASSET . dasset_w_i32 ( * out , 1 ) ; // 关键帧数
DASSET . dasset_w_f32 ( * out , 0 ) ; // times[0]
DASSET . dasset_w_vec4 ( * out , .[ 1 , 0 , 0 , 0 ] ) ; // values[0]
}

 return out ;
}
//@endregion

 //@region 测试模型（对应 olib 测试里的 make_test_model）

 dasset_make_test_model :: ( ) -> DASSET . Dasset_Model {
model : DASSET . Dasset_Model ;
model . bounds . min = .[ - 1 , - 2 , - 3 ] ;
model . bounds . max = .[ 4 , 5 , 6 ] ;

 tex_bytes : [ 4 ] u8 = .[ 1 , 2 , 3 , 9 ] ;
tex_view : [ ] u8 = tex_bytes ;
array_add ( * model . textures , DASSET . Dasset_Texture_Entry .{
name = DASSET . dasset_clone_owned ( "albedo" ) ,
codec = . Png ,
bytes = DASSET . dasset_clone_bytes ( tex_view ) ,
} ) ;

 skel : DASSET . Dasset_Skeleton ;
root : DASSET . Dasset_Joint ;
root . name = DASSET . dasset_clone_owned ( "root" ) ;
root . parent_index = - 1 ;
root . bind_scale = .[ 1 , 1 , 1 ] ;
root . bind_rotation = .[ 0 , 0 , 0 , 1 ] ;
root . inverse_bind_matrix = dasset_test_matrix_identity16 ( ) ;
array_add ( * skel . joints , root ) ;
child : DASSET . Dasset_Joint ;
child . name = DASSET . dasset_clone_owned ( "child" ) ;
child . parent_index = 0 ;
child . inverse_bind_matrix = dasset_test_matrix_identity16 ( ) ;
array_add ( * skel . joints , child ) ;
array_add ( * model . skeletons , skel ) ;

 p_static : DASSET . Dasset_Primitive ;
p_static . vertices = DASSET . dasset_alloc_array ( DASSET . Dasset_Vertex , 3 ) ;
p_static . vertices [ 2 ] . uv = .[ 0.5 , 0.25 ] ;
p_static . vertices [ 2 ] . normal = .[ 0 , 1 , 0 ] ;
p_static . indices = DASSET . dasset_alloc_array ( u32 , 3 ) ;
p_static . indices [ 2 ] = 5 ;
p_static . skin_index = - 1 ;
p_static . material = DASSET . DASSET_MATERIAL_DEFAULT ;
p_static . bounds . min = .[ 0 , 0 , 0 ] ;
p_static . bounds . max = .[ 1 , 1 , 1 ] ;
array_add ( * model . primitives , p_static ) ;

 p_skin : DASSET . Dasset_Primitive ;
p_skin . skin_vertices = DASSET . dasset_alloc_array ( DASSET . Dasset_Skin_Vertex , 1 ) ;
p_skin . skin_vertices [ 0 ] . joints = 0x01020003 ;
p_skin . skin_vertices [ 0 ] . weights = .[ 0.25 , 0.25 , 0.25 , 0.25 ] ;
p_skin . skin_index = 0 ;
p_skin . indices = DASSET . dasset_alloc_array ( u32 , 3 ) ;
p_skin . material = DASSET . DASSET_MATERIAL_DEFAULT ;
p_skin . material . base_color_factor = .[ 1 , 0.5 , 0.25 , 1 ] ;
p_skin . material . metallic = 0.1 ;
p_skin . material . roughness = 0.9 ;
p_skin . material . double_sided = true ;
p_skin . material . alpha_mode = . Blend ;
p_skin . material . albedo_texture_index = 0 ;
p_skin . material . emissive_texture_index = 0 ;
p_skin . material . emissive_factor = .[ 0.1 , 0.2 , 0.3 ] ;
p_skin . bounds . min = .[ 0 , 0 , 0 ] ;
p_skin . bounds . max = .[ 1 , 1 , 1 ] ;
array_add ( * model . primitives , p_skin ) ;

 clip : DASSET . Dasset_Animation_Clip ;
clip . name = DASSET . dasset_clone_owned ( "idle" ) ;
clip . skin_index = 0 ;
clip . duration = 2 ;

 rot : DASSET . Dasset_Animation_Channel ;
rot . joint_index = 0 ;
rot . path = . Rotation ;
rot . interpolation = . Cubic_Spline ;
rot . times = DASSET . dasset_alloc_array ( float32 , 2 ) ;
rot . times [ 1 ] = 1.5 ;
rot . values = DASSET . dasset_alloc_array ( [ 4 ] float32 , 2 ) ;
rot . values [ 1 ] = .[ 0 , 0.7 , 0 , 0.7 ] ;
rot . in_tangents = DASSET . dasset_alloc_array ( [ 4 ] float32 , 2 ) ;
rot . in_tangents [ 0 ] = .[ 0.1 , 0 , 0 , 0 ] ;
rot . out_tangents = DASSET . dasset_alloc_array ( [ 4 ] float32 , 2 ) ;
rot . out_tangents [ 1 ] = .[ 0 , 0.2 , 0 , 0 ] ;
array_add ( * clip . channels , rot ) ;

 tr : DASSET . Dasset_Animation_Channel ;
tr . joint_index = 1 ;
tr . path = . Translation ;
tr . interpolation = . Linear ;
tr . times = DASSET . dasset_alloc_array ( float32 , 2 ) ;
tr . times [ 1 ] = 1 ;
tr . values = DASSET . dasset_alloc_array ( [ 4 ] float32 , 2 ) ;
tr . values [ 1 ] = .[ 1 , 2 , 3 , 0 ] ;
array_add ( * clip . channels , tr ) ;

 array_add ( * model . clips , clip ) ;
return model ;
}

 dasset_test_matrix_identity16 :: ( ) -> [ 16 ] float32 {
m : [ 16 ] float32 ;
m [ 0 ] = 1 ;
m [ 5 ] = 1 ;
m [ 10 ] = 1 ;
m [ 15 ] = 1 ;
return m ;
}
//@endregion 

// Loop scopes adapted.
