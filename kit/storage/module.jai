// storage/module.jai — 聚合入口：`#import "kit/storage"`。
// 与 olib kit/storage 对位：
//   storage.odin        → storage.jai          （公共：根的选择与便捷读写）
//   storage_native.odin → storage_native.jai   （`#+build !js` → `#if OS != .WASM`）
//   storage_web.odin    → storage_web.jai      （`#+build js`  → `#if OS == .WASM`，空实现）
//
// 与 kit/world、kit/audio 相同的写法：`#load` 进来的文件共享这一层的名字，
// 各文件里不再重复声明，避免「already declared in this scope」。
//
// 导入说明：
//   不具名 `#import "Basic"` = 把 Basic 的名字直接放进本模块（alloc / alloc_string /
//   free / memcpy / copy_string / temp / temp_c_string / Allocator / join 等），
//   所以下面不再写 `using Basic`，各 #load 文件里也不用重复导入。
//   F    —— jfoster：Storage_Container（olib `foster.StorageContainer` 的对应物）、
//            storage_write_all_* / storage_read_all_* / storage_create_directory 等。
//   FILE —— Basic 的 File 模块：make_directory_if_it_does_not_exist(recursive=true)
//            （olib `os.make_directory_all`）。
//   SYS  —— System 模块：get_path_of_running_executable（olib `os.get_executable_path`）。
// 三个具名导入避免遮蔽与重名（同 kit/world 对 Math 的处理）。
// 这三者只在桌面目标下存在（jfoster 依赖 SDL，System 只写桌面平台），
// 所以和 olib 的 `#+build !js` 一样放进条件里：`-os wasm` 走 storage_web.jai 的空实现。
#import "Basic";
#if OS != .WASM {
F :: #import "jfoster";
FILE :: #import "File";
SYS :: #import "System";
}

#load "storage.jai";
#load "storage_native.jai";
#load "storage_web.jai";
