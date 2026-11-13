// kit/asset 回归测试 —— 一比一移植自 olib `tests/kit/asset/asset_test.odin`（444 行，8 个用例）。
//
// 组织方式与 olib 对位：每个 @(test) 对应一个过程，断言顺序尽量保持原样；签名统一
// `(state: *Test_State)`（由 Tests/kit/run_kit_tests.jai 或 .test_tmp 里的 runner 调度），
// 用 Tests/test_support.jai 的 expect / test_summary。本文件不写 main。
//
// 覆盖：guid 往返/唯一、blob 往返、.meta 身份（ensure/移动不坏/重复 GUID 报错）、
// import_all（导入/新鲜度跳过/删 Library 重建/孤儿警告/importer 版本失效）、
// 运行时加载（directory 与 map 后端、三种 kind、缓存、卸载）、
// manifest（打包形态：只带 Library、assets_root 为空时 load_path 仍可用）。
//
// Jai 侧差异（断言语义不变）：
//   | olib (Odin)                                     | 这里 (Jai)                                          |
//   | ----------------------------------------------- | --------------------------------------------------- |
//   | testing.expect / expectf                        | expect(state, cond, "说明 %", args)                  |
//   | os.make_directory_temp("", prefix, alloc)       | 固定目录 .test_tmp/asset_test/（已 gitignore），每个 |
//   |                                                 | 用例开头清空（fresh_dir）                            |
//   | os.remove_all / 自写 remove_tree                 | AT_FU.delete_directory_tree（File_Utilities 自带）   |
//   | os.write_entire_file(path, []u8)                | AT_FILE.write_entire_file(path, cast(string) bytes)  |
//   | os.rename                                       | AT_FILE.file_move(old, new)                         |
//   | foster.ImageMake + Pixels + ImageWriteQoi       | AT_F.image_create + Image.Data + image_encode_qoi   |
//   | foster.Color{...}                               | AT_F.Color{...}（字段 r/g/b/a，位置初始化同序）      |
//   | foster.DirectoryStorageContainer(&ds)           | ds 本身（jfoster 的容器就是 Storage_Container）      |
//   | foster.FileExists(assets, rel)                  | AT_F.storage_file_exists(assets, rel)                |
//   | keep := image.Pixels[x + y * w]                 | image.Data[x + y * w]                               |
//   | value.(json.Object) / obj["hp"].(json.Integer)  | value.kind == .Object + table_find(*object_val, k)   |
//   | strings.to_upper(s, temp)                       | asset_test_upper(s)（本文件内的夹具 helper）         |
//   | map[Guid]bool（去重视图）                        | 可增长数组 + 两两 guid_equal（1000 个 = 50 万次比较）|
//   | g1 == g2（Guid）/ handle == handle              | AT.guid_equal / AT.asset_handle_equal               |
//   | Color 的 ==（jfoster 里 operator == 是模块内的）  | asset_test_color_is（跨模块不可见运算符）            |
#import "Basic" ;
#import "Hash_Table" ; // table_find(*json.object_val, "hp")
// 具名导入一律带 AT_ 前缀：kit 的测试最终会被 run_kit_tests 具名/不具名导入到同一个模块，
// 裸的 F / M / W 之类会和 audio_test（F、M）、world_test（W）重名。
AT :: #import "kit/asset" ;
AT_F :: #import "foster" ;
AT_FILE :: #import "File" ;
AT_FU :: #import "File_Utilities" ;
#import "test_support" ;

 //@region 夹具 helper（聚合进 run_kit_tests 后不会重名）

 // olib 用 os.make_directory_temp 拿独占临时目录；这里用已 gitignore 的固定目录，
// 用例开头清空，保证不碰真实工程目录。
asset_test_temp_root :: ( ) -> string {
AT_FILE . make_directory_if_it_does_not_exist ( ".test_tmp/asset_test" , true ) ;
return ".test_tmp/asset_test" ;
}

 // 路径拼接（temp 分配，用法同 olib 的 strings.join + context.temp_allocator）。
asset_test_join :: ( a : string , b : string ) -> string {
return tprint ( "%/%" , a , b ) ;
}

 // olib 的 fresh_dir：清空并重建 <root>/<name>。
asset_test_fresh_dir :: ( name : string ) -> string {
dir := asset_test_join ( asset_test_temp_root ( ) , name ) ;
_ = AT_FU . delete_directory_tree ( dir ) ; // 不存在时返回 false，无所谓
AT_FILE . make_directory_if_it_does_not_exist ( dir , true ) ;
return dir ;
}

 // 递归删除（olib 的 remove_tree）。不存在视为成功。
asset_test_remove_tree :: ( path : string ) -> bool {
directory , found := AT_FU . is_directory ( path ) ;
if ! found || ! directory return true ;
return AT_FU . delete_directory_tree ( path ) ;
}

 asset_test_write_file :: ( state : * Test_State , path : string , data : [ ] u8 ) -> bool {
ok := AT_FILE . write_entire_file ( path , cast ( string ) data ) ;
expect ( state , ok , "write_entire_file(%)" , path ) ;
return ok ;
}

 // 四象限颜色：c00 左上、c10 右上、c01 左下、c11 右下（与 olib 的 make_test_qoi 一致）。
asset_test_quadrant_colors :: ( ) -> [ 4 ] AT_F . Color {
return .[
AT_F . Color .{ 255 , 0 , 0 , 255 } , // c00 红
AT_F . Color .{ 0 , 255 , 0 , 255 } , // c10 绿
AT_F . Color .{ 0 , 0 , 255 , 255 } , // c01 蓝
AT_F . Color .{ 255 , 255 , 0 , 255 } , // c11 黄
] ;
}

 // jfoster 的 Color 的 operator == 声明在 jfoster 模块里，跨模块不可见，这里显式比字段。
asset_test_color_is :: ( a : AT_F . Color , b : AT_F . Color ) -> bool {
return a . r == b . r && a . g == b . g && a . b == b . b && a . a == b . a ;
}

 // 生成并写出 >=2x2 的四象限纯色 QOI（olib 的 make_test_qoi）。
// 像素分配在 context 上，image_create/image_encode_qoi 都归本函数释放。
asset_test_write_qoi :: ( state : * Test_State , path : string , w : s32 , h : s32 ) -> bool {
expect ( state , w >= 2 && h >= 2 , "make_test_qoi 需要 >= 2x2，实际 % x %" , w , h ) ;
colors := asset_test_quadrant_colors ( ) ;

 image := AT_F . image_create ( w , h , AT_F . Color .{ 0 , 0 , 0 , 255 } ) ;
for y : 0 .. h - 1 {
for x : 0 .. w - 1 {
upper := y < h / 2 + 1 ;
left := x < w / 2 + 1 ;
c := colors [ 3 ] ;
if left {
if upper {
c = colors [ 0 ] ;
} else {
c = colors [ 2 ] ;
}
} else {
if upper {
c = colors [ 1 ] ;
} else {
c = colors [ 3 ] ;
}
}
image . Data [ x + y * w ] = c ;
}
}

 bytes := AT_F . image_encode_qoi ( image ) ;
ok := AT_FILE . write_entire_file ( path , cast ( string ) bytes ) ;
expect ( state , ok , "ImageWriteQoi(%) 失败" , path ) ;
if bytes . count > 0 free ( bytes . data ) ;
AT_F . image_destroy ( * image ) ;
return ok ;
}

 // olib 的 strings.to_upper(s, temp)：本文件内自备（context 分配，调用方 free）。
asset_test_upper :: ( s : string ) -> string {
out := copy_string ( s ) ;
for i : 0 .. out . count - 1 {
c := out [ i ] ;
if c >= #char "a" && c <= #char "z" out [ i ] = c - 32 ;
}
return out ;
}
//@endregion

 //@region Guid

 asset_guid_roundtrip_and_uniqueness :: ( state : * Test_State ) {
g := AT . guid_generate ( ) ;
s := AT . guid_to_string ( g , context . allocator ) ;
expect ( state , s . count == 32 , "guid_to_string 长度应为 32，实际 %" , s . count ) ;

 back , ok := AT . guid_from_string ( s ) ;
expect ( state , ok && AT . guid_equal ( back , g ) , "hex 往返失败: %" , s ) ;

 upper := asset_test_upper ( s ) ;
back2 , ok2 := AT . guid_from_string ( upper ) ;
expect ( state , ok2 && AT . guid_equal ( back2 , g ) , "大写 hex 解析不一致: %" , upper ) ;
free ( upper ) ;

 _ , ok3 := AT . guid_from_string ( "zzzz" ) ;
expect ( state , ! ok3 , "非 hex 串应解析失败" ) ;

 // 1000 次生成内不出现重复（olib 用 map[Guid]bool；这里数组两两比，量级相同）
guids : [ .. ] AT . Guid ;
dup := false ;
for 0 .. 999 {
gg := AT . guid_generate ( ) ;
for guids {
if AT . guid_equal ( it , gg ) {
dup = true ;
break ;
}
}
array_add ( * guids , gg ) ;
}
array_free ( guids ) ;
expect ( state , ! dup , "1000 次内出现重复 guid" ) ;

 free ( s ) ;
}
//@endregion

 //@region blob

 asset_blob_roundtrip :: ( state : * Test_State ) {
g := AT . guid_generate ( ) ;
payload : [ ] u8 = .[ 1 , 2 , 3 , 4 , 5 ] ;

 blob , ok := AT . blob_build ( g , . Raw , 7 , 12345 , 99 , payload , context . allocator ) ;
expect ( state , ok , "blob_build 失败" ) ;

 header , parsed , parsed_ok := AT . blob_parse ( blob ) ;
expect ( state , parsed_ok , "blob_parse 失败" ) ;
if parsed_ok {
expect ( state , AT . guid_equal ( header . guid , g ) , "header.guid 往返失败" ) ;
expect ( state , header . importer_version == 7 , "importer_version 应为 7，实际 %" , header . importer_version ) ;
expect ( state , header . src_mtime == 12345 && header . src_size == 99 , "src_mtime/src_size 不符: % %" ,
header . src_mtime , header . src_size ) ;
expect ( state , header . kind == cast ( u8 ) ( AT . Asset_Kind . Raw ) && header . payload_len == 5 ,
"kind/payload_len 不符: % %" , header . kind , header . payload_len ) ;
expect ( state , AT . asset_bytes_equal ( parsed , payload ) , "payload 往返失败" ) ;
}

 _ , _ , truncated := AT . blob_parse ( AT . asset_view ( blob , 10 ) ) ;
expect ( state , ! truncated , "截断到 10 字节的 blob 应判失败" ) ;

 blob [ 0 ] = #char "X" ;
_ , _ , bad_magic := AT . blob_parse ( blob ) ;
expect ( state , ! bad_magic , "magic 损坏的 blob 应判失败" ) ;

 AT . asset_free_bytes ( blob , context . allocator ) ;
}
//@endregion

 //@region .meta 身份

 asset_meta_identity :: ( state : * Test_State ) {
root := asset_test_fresh_dir ( "meta" ) ;

 assets : AT_F . Storage_Container ;
assets . Root = root ;
assets . Writable = true ;

 asset_test_write_qoi ( state , asset_test_join ( root , "a.qoi" ) , 4 , 4 ) ;

 // 缺 .meta 时 ensure 生成；已存在时读回同一个
g1 , e1 := AT . meta_ensure ( * assets , "a.qoi" ) ;
expect ( state , e1 == . None , "meta_ensure: %" , cast ( s64 ) e1 ) ;

 g1b , e2 := AT . meta_read ( * assets , "a.qoi" ) ;
expect ( state , e2 == . None && AT . guid_equal ( g1b , g1 ) , "meta_read 与 ensure 不一致" ) ;

 g1c , e3 := AT . meta_ensure ( * assets , "a.qoi" ) ;
expect ( state , e3 == . None && AT . guid_equal ( g1c , g1 ) , "二次 ensure 不应改 GUID" ) ;

 // 移动文件 + .meta 到子目录：GUID 不变（身份随 .meta 走）
expect ( state , AT_FILE . make_directory_if_it_does_not_exist ( asset_test_join ( root , "sub" ) , true ) ,
"mkdir sub 失败" ) ;
expect ( state , AT_FILE . file_move ( asset_test_join ( root , "a.qoi" ) , asset_test_join ( root , "sub/a.qoi" ) ) ,
"rename a.qoi 失败" ) ;
expect ( state , AT_FILE . file_move ( asset_test_join ( root , "a.qoi.meta" ) , asset_test_join ( root , "sub/a.qoi.meta" ) ) ,
"rename a.qoi.meta 失败" ) ;

 g2 , e7 := AT . meta_read ( * assets , "sub/a.qoi" ) ;
expect ( state , e7 == . None && AT . guid_equal ( g2 , g1 ) , "移动文件+.meta 后 GUID 应不变" ) ;

 // 人为制造重复 GUID：import_all 必须报 Duplicate_Guid（绝不静默换）
one_byte : [ ] u8 = .[ 1 ] ;
asset_test_write_file ( state , asset_test_join ( root , "b.qoi" ) , one_byte ) ;
e8 := AT . meta_write ( * assets , "b.qoi" , g1 ) ;
expect ( state , e8 == . None , "meta_write b: %" , cast ( s64 ) e8 ) ;

 _ , derr := AT . import_all ( root , asset_test_join ( root , "Library" ) ) ;
expect ( state , derr == . Duplicate_Guid , "重复 GUID 应报 Duplicate_Guid，实际 %" , cast ( s64 ) derr ) ;
}
//@endregion

 //@region import_all + 运行时加载（directory 后端）

 asset_import_and_load :: ( state : * Test_State ) {
root := asset_test_fresh_dir ( "pipeline" ) ;
assets_root := asset_test_join ( root , "Assets" ) ;
library_root := asset_test_join ( root , "Library" ) ;
expect ( state , AT_FILE . make_directory_if_it_does_not_exist ( assets_root , true ) , "mkdir Assets 失败" ) ;

 colors := asset_test_quadrant_colors ( ) ;
asset_test_write_qoi ( state , asset_test_join ( assets_root , "tex.qoi" ) , 4 , 4 ) ;

 json_text := "{\"hp\": 10, \"name\": \"slime\"}" ;
asset_test_write_file ( state , asset_test_join ( assets_root , "conf.json" ) , cast ( [ ] u8 ) json_text ) ;
bin_bytes : [ ] u8 = .[ 9 , 8 , 7 , 6 ] ;
asset_test_write_file ( state , asset_test_join ( assets_root , "data.bin" ) , bin_bytes ) ;

 s1 , e1 := AT . import_all ( assets_root , library_root ) ;
expect ( state , e1 == . None , "import_all #1: %" , cast ( s64 ) e1 ) ;
expect ( state , s1 . scanned == 3 && s1 . imported == 3 && s1 . skipped == 0 && s1 . guid_generated == 3 ,
"第一次导入统计不符: scanned % imported % skipped % generated %" ,
s1 . scanned , s1 . imported , s1 . skipped , s1 . guid_generated ) ;

 s2 , e2 := AT . import_all ( assets_root , library_root ) ;
expect ( state , e2 == . None , "import_all #2: %" , cast ( s64 ) e2 ) ;
expect ( state , s2 . skipped == 3 && s2 . imported == 0 && s2 . guid_generated == 0 ,
"第二次导入应全部跳过: imported % skipped % generated %" ,
s2 . imported , s2 . skipped , s2 . guid_generated ) ;

 // 不变量：删除整个 Library 可完全重建，GUID 不变
assets : AT_F . Storage_Container ;
assets . Root = assets_root ;
assets . Writable = false ;
g_tex , gerr := AT . meta_read ( * assets , "tex.qoi" ) ;
expect ( state , gerr == . None , "读 tex.qoi.meta 失败: %" , cast ( s64 ) gerr ) ;

 expect ( state , asset_test_remove_tree ( library_root ) , "删除 Library 失败" ) ;
s3 , e3 := AT . import_all ( assets_root , library_root ) ;
expect ( state , e3 == . None && s3 . imported == 3 , "删 Library 重建失败: imported %" , s3 . imported ) ;

 g_tex2 , gerr2 := AT . meta_read ( * assets , "tex.qoi" ) ;
expect ( state , gerr2 == . None && AT . guid_equal ( g_tex2 , g_tex ) , "重建后 GUID 不应改变" ) ;

 // 运行时加载（无 GPU：Texture 保留 CPU Image）
m : AT . Asset_Manager ;
cfg : AT . Asset_Manager_Config ;
cfg . assets_root = assets_root ;
cfg . library_root = library_root ;
expect ( state , AT . assets_init ( * m , cfg ) == . None , "assets_init 失败" ) ;
defer AT . assets_dispose ( * m ) ;

 htex , e5 := AT . assets_load_path ( * m , "tex.qoi" ) ;
expect ( state , e5 == . None , "load_path tex.qoi: %" , cast ( s64 ) e5 ) ;
image := AT . assets_get_image ( * m , htex ) ;
expect ( state , image != null , "无 device 时应拿到 CPU Image" ) ;
if image != null {
expect ( state , image . Width == 4 && image . Height == 4 , "图像尺寸不符: % x %" , image . Width , image . Height ) ;
expect ( state , asset_test_color_is ( image . Data [ 0 ] , colors [ 0 ] ) , "象限 c00 像素不符" ) ;
expect ( state , asset_test_color_is ( image . Data [ 3 ] , colors [ 1 ] ) , "象限 c10 像素不符" ) ;
expect ( state , asset_test_color_is ( image . Data [ 12 ] , colors [ 2 ] ) , "象限 c01 像素不符" ) ;
expect ( state , asset_test_color_is ( image . Data [ 15 ] , colors [ 3 ] ) , "象限 c11 像素不符" ) ;
}

 hjson , e6 := AT . assets_load_path ( * m , "conf.json" ) ;
expect ( state , e6 == . None , "load_path conf.json: %" , cast ( s64 ) e6 ) ;
value := AT . assets_get_json ( * m , hjson ) ;
expect ( state , value != null , "json getter 应返回非 nil" ) ;
if value != null {
expect ( state , value . kind == . Object , "json 根应为 object" ) ;
found_hp , hp_node := table_find ( * value . object_val , "hp" ) ;
expect ( state , found_hp && hp_node . kind == . Integer && hp_node . int_val == 10 , "hp 应为 10" ) ;
found_name , name_node := table_find ( * value . object_val , "name" ) ;
expect ( state , found_name && name_node . kind == . String && name_node . string_val == "slime" ,
"name 应为 slime" ) ;
}

 hraw , e7 := AT . assets_load_path ( * m , "data.bin" ) ;
expect ( state , e7 == . None , "load_path data.bin: %" , cast ( s64 ) e7 ) ;
raw := AT . assets_get_bytes ( * m , hraw ) ;
expect ( state , raw . count == 4 && raw [ 0 ] == 9 && raw [ 3 ] == 6 , "raw 字节不符" ) ;

 // kind 不匹配防御
expect ( state , AT . assets_get_texture ( * m , hjson ) == null , "json 句柄不应拿到 texture" ) ;
expect ( state , AT . assets_get_bytes ( * m , htex ) . count == 0 , "texture 句柄不应拿到 raw 字节" ) ;

 // guid 直查 + 缓存：同 guid 重复加载返回同句柄
hagain , e8 := AT . assets_load ( * m , g_tex ) ;
expect ( state , e8 == . None && AT . asset_handle_equal ( hagain , htex ) , "重复加载应命中缓存" ) ;
expect ( state , AT . assets_len ( * m ) == 3 , "缓存内应有 3 条，实际 %" , AT . assets_len ( * m ) ) ;

 // 卸载：句柄失效，缓存清空，重载可用
g_raw := AT . assets_guid ( * m , hraw ) ;
AT . assets_unload ( * m , hraw ) ;
expect ( state , ! AT . assets_valid ( * m , hraw ) , "卸载后句柄应失效" ) ;

 hraw2 , e9 := AT . assets_load ( * m , g_raw ) ;
expect ( state , e9 == . None && ! AT . asset_handle_equal ( hraw2 , AT . ASSET_HANDLE_NONE ) , "卸载后应可重载" ) ;
expect ( state , AT . assets_get_bytes ( * m , hraw2 ) . count == 4 , "重载后字节数应为 4" ) ;
}
//@endregion

 //@region importer 版本失效

 // olib 的 test_import_upper：把源字节转大写后原样当作 payload。
asset_test_import_upper :: ( source : [ ] u8 , ext : string , out : * AT . Payload_Builder , allocator : Allocator ) -> AT . Asset_Error {
data , allocated := AT . asset_alloc_bytes ( source . count , allocator ) ;
if ! allocated return . Import_Failed ;
for i : 0 .. source . count - 1 {
c := source [ i ] ;
if c >= #char "a" && c <= #char "z" c = c - 32 ;
data [ i ] = c ;
}
out . data = data ;
return . None ;
}

 asset_importer_version_invalidates :: ( state : * Test_State ) {
root := asset_test_fresh_dir ( "version" ) ;
assets_root := asset_test_join ( root , "Assets" ) ;
library_root := asset_test_join ( root , "Library" ) ;
expect ( state , AT_FILE . make_directory_if_it_does_not_exist ( assets_root , true ) , "mkdir Assets 失败" ) ;

 hello := "hello" ;
asset_test_write_file ( state , asset_test_join ( assets_root , "a.tst" ) , cast ( [ ] u8 ) hello ) ;

 AT . importer_register ( ".tst" , AT . Importer .{ kind = . Raw , version = 1 , run = asset_test_import_upper } ) ;

 s1 , e1 := AT . import_all ( assets_root , library_root ) ;
expect ( state , e1 == . None && s1 . imported == 1 , "v1 首次导入: imported %" , s1 . imported ) ;

 s2 , e2 := AT . import_all ( assets_root , library_root ) ;
expect ( state , e2 == . None && s2 . skipped == 1 , "v1 二次应跳过: skipped %" , s2 . skipped ) ;

 // 版本号 +1：源没变也要重导（导入逻辑升级即缓存失效）
AT . importer_register ( ".tst" , AT . Importer .{ kind = . Raw , version = 2 , run = asset_test_import_upper } ) ;

 s3 , e3 := AT . import_all ( assets_root , library_root ) ;
expect ( state , e3 == . None && s3 . imported == 1 && s3 . skipped == 0 ,
"版本升级应触发重导: imported % skipped %" , s3 . imported , s3 . skipped ) ;
}
//@endregion

 //@region map 后端

 asset_map_storage_load :: ( state : * Test_State ) {
g := AT . guid_generate ( ) ;
payload : [ ] u8 = .[ 1 , 2 , 3 ] ;
blob , ok := AT . blob_build ( g , . Raw , 1 , 0 , 0 , payload , context . allocator ) ;
expect ( state , ok , "blob_build 失败" ) ;

 ms : AT . Map_State ;
AT . storage_map_init ( * ms , context . allocator ) ;
defer AT . storage_map_dispose ( * ms ) ;
table_add ( * ms . blobs , g , blob ) ; // 值归本测试所有，dispose 不动它

 m : AT . Asset_Manager ;
defer AT . assets_dispose ( * m ) ;
cfg : AT . Asset_Manager_Config ;
cfg . storage = AT . storage_map ( * ms ) ;
expect ( state , AT . assets_init ( * m , cfg ) == . None , "assets_init 失败" ) ;

 handle , lerr := AT . assets_load ( * m , g ) ;
expect ( state , lerr == . None , "assets_load: %" , cast ( s64 ) lerr ) ;
raw := AT . assets_get_bytes ( * m , handle ) ;
expect ( state , raw . count == 3 && raw [ 0 ] == 1 && raw [ 2 ] == 3 , "map 后端字节不符" ) ;

 // 不存在的 guid
_ , nferr := AT . assets_load ( * m , AT . guid_generate ( ) ) ;
expect ( state , nferr == . File_Not_Found , "未知 guid 应报 File_Not_Found，实际 %" , cast ( s64 ) nferr ) ;

 AT . asset_free_bytes ( blob , context . allocator ) ;
}
//@endregion

 //@region 孤儿 .meta

 asset_orphan_meta_warns :: ( state : * Test_State ) {
root := asset_test_fresh_dir ( "orphan" ) ;
assets_root := asset_test_join ( root , "Assets" ) ;
library_root := asset_test_join ( root , "Library" ) ;
expect ( state , AT_FILE . make_directory_if_it_does_not_exist ( assets_root , true ) , "mkdir Assets 失败" ) ;

 assets : AT_F . Storage_Container ;
assets . Root = assets_root ;
assets . Writable = true ;
e1 := AT . meta_write ( * assets , "ghost.png" , AT . guid_generate ( ) ) ;
expect ( state , e1 == . None , "meta_write: %" , cast ( s64 ) e1 ) ;

 stats , e2 := AT . import_all ( assets_root , library_root ) ;
expect ( state , e2 == . None , "孤儿 .meta 不应报错: %" , cast ( s64 ) e2 ) ;
expect ( state , stats . scanned == 0 && stats . orphaned_meta == 1 ,
"孤儿统计不符: scanned % orphaned %" , stats . scanned , stats . orphaned_meta ) ;
expect ( state , AT_F . storage_file_exists ( * assets , "ghost.png.meta" ) , "孤儿 .meta 不应被删除" ) ;
}
//@endregion

 //@region manifest —— 打包形态（只带 Library，没有 Assets）

 asset_manifest_packaged_load :: ( state : * Test_State ) {
root := asset_test_fresh_dir ( "manifest" ) ;
assets_root := asset_test_join ( root , "Assets" ) ;
library_root := asset_test_join ( root , "Library" ) ;
expect ( state , AT_FILE . make_directory_if_it_does_not_exist ( assets_root , true ) , "mkdir Assets 失败" ) ;

 colors := asset_test_quadrant_colors ( ) ;
asset_test_write_qoi ( state , asset_test_join ( assets_root , "demo.qoi" ) , 4 , 4 ) ;

 s1 , e1 := AT . import_all ( assets_root , library_root ) ;
expect ( state , e1 == . None && s1 . imported == 1 , "导入: imported %" , s1 . imported ) ;

 // manifest blob 应作为保留 GUID 的 Raw blob 落在 Library 里
name_buf : [ 37 ] u8 ;
mname , mname_ok := AT . guid_filename ( AT . GUID_MANIFEST , name_buf ) ;
expect ( state , mname_ok , "guid_filename(GUID_MANIFEST) 失败" ) ;
expect ( state , AT_FU . file_exists ( asset_test_join ( library_root , mname ) ) , "manifest blob 应存在于 Library" ) ;

 // ---- 模拟打包：删掉源 Assets 目录，运行时只有 Library ----
expect ( state , asset_test_remove_tree ( assets_root ) , "删 Assets 失败" ) ;

 // 打包形态加载：assets_root 为空，.meta 回退不可用，只能靠 manifest
m : AT . Asset_Manager ;
defer AT . assets_dispose ( * m ) ;
cfg : AT . Asset_Manager_Config ;
cfg . assets_root = "" ;
cfg . library_root = library_root ;
expect ( state , AT . assets_init ( * m , cfg ) == . None , "assets_init 失败" ) ;

 h , e6 := AT . assets_load_path ( * m , "demo.qoi" ) ;
expect ( state , e6 == . None , "打包形态 load_path 应走 manifest: %" , cast ( s64 ) e6 ) ;
image := AT . assets_get_image ( * m , h ) ;
expect ( state , image != null , "打包形态应拿到 CPU Image" ) ;
if image != null {
expect ( state , image . Width == 4 && image . Height == 4 , "打包形态尺寸不符: % x %" , image . Width , image . Height ) ;
expect ( state , asset_test_color_is ( image . Data [ 0 ] , colors [ 0 ] ) , "打包形态 c00 像素不符" ) ;
expect ( state , asset_test_color_is ( image . Data [ 3 ] , colors [ 1 ] ) , "打包形态 c10 像素不符" ) ;
expect ( state , asset_test_color_is ( image . Data [ 12 ] , colors [ 2 ] ) , "打包形态 c01 像素不符" ) ;
expect ( state , asset_test_color_is ( image . Data [ 15 ] , colors [ 3 ] ) , "打包形态 c11 像素不符" ) ;
}

 // manifest 里不存在的路径：没有 .meta 回退时应报错而非崩溃
_ , e7 := AT . assets_load_path ( * m , "nope.qoi" ) ;
expect ( state , e7 != . None , "未知路径应报错" ) ;
}
//@endregion 

// Loop scopes adapted.
