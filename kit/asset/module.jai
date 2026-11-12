// asset/module.jai — 聚合入口：`#import "kit/asset"`。
// 与 olib kit/asset 一一对位：
//   asset.odin    → asset.jai     （Guid / 句柄 / Asset_Manager 运行时）
//   blob.odin     → blob.jai      （blob 边界格式，字节布局逐字段一致）
//   importer.odin → importer.jai  （源文件 → blob 的导入层 + import_all）
//   loader.odin   → loader.jai    （Asset_Storage 后端：directory / map）
//   manifest.odin → manifest.jai  （path → guid 寻址层，打包形态的关键）
//   meta.odin     → meta.jai      （.meta 身份文件）
//
// 与 kit/world、kit/storage、kit/audio 相同的写法：`#load` 进来的文件共享这一层的名字，
// 各文件里不再重复声明 #import，避免「already declared in this scope」。
//
// 导入说明：
//   Basic          —— 不具名：把 alloc / alloc_string / copy_string / memcpy / print / sprint /
//                     tprint / temp / free / Allocator / push_allocator / deinit / array_add /
//                     array_free / current_time_consensus / to_nanoseconds /
//                     APOLLO_TIME_FOR_JAN_1_1970 放进本模块（所以各文件不用再 #import "Basic"）。
//   Hash_Table     —— 不具名：Table / table_find / table_add / table_remove / deinit。
//                     与 core/profiler 同样的组合（Basic + Hash_Table 同名共存，实测无冲突）。
//                     jacket 的 table_find 返回 **(found, value)**，顺序与 Odin 的 `v, ok :=` 相反。
//   HA             —— core/handle 聚合入口。注意它是**命名空间别名**而不是直接给过程：
//                     句柄池实现在 HA.HANDLE_ARRAY（olib 的 core/handle/array），
//                     所以调用点是 HA.HANDLE_ARRAY.add / get / remove_handle / begin / next / len /
//                     delete / valid。
//   ENC            —— core/encoding（olib 的 core:encoding/json + core/encoding 合并）；
//                     本包只用到 json_parse / json_marshal / json_load_struct / json_save_struct /
//                     json_struct_to_value / json_value_to_struct / json_destroy_value / Json_Value。
//   KS             —— kit/storage：只借 storage_path_join（olib 的 join_owned 用 strings.join）。
//                     注意它**总是插 '/'**，".meta" 后缀拼接用的是 asset_concat。
//   F              —— jfoster：Storage_Container / Image / Color / Texture / Graphics_Device。
//                     jfoster 没有 Directory_Storage 类型（容器本身就是 Storage_Container），
//                     storage_read_all_bytes 也没有 allocator 形参（吃 context.allocator）。
//   FILE           —— File：read_entire_file / write_entire_file / file_open / file_read /
//                     file_close（替代 olib 的 os.*）/ make_directory_if_it_does_not_exist。
//   FU             —— File_Utilities：visit_files（目录枚举）/ file_modtime_and_size（os.stat）。
//                     file_modtime_and_size 返回 (Apollo_Time, s64, bool)。
#import "Basic";
#import "Hash_Table";
HA :: #import "core/handle";
ENC :: #import "core/encoding";
KS :: #import "kit/storage";
F :: #import "jfoster";
FILE :: #import "File";
FU :: #import "File_Utilities";

#load "asset.jai";
#load "blob.jai";
#load "loader.jai";
#load "meta.jai";
#load "manifest.jai";
#load "importer.jai";
