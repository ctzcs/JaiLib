// 平台根目录（Web）—— 对位 olib kit/storage/storage_web.odin（`#+build js`）。
//
// 【Jai 侧没有对应目标，这里是可编译的空实现】
//   olib 的 Web 分支把根指向 Foster 的虚拟文件系统（`/foster/<app>/`），由浏览器
//   localStorage 持久化。jfoster 只移植了桌面侧（Storage_Container / Directory /
//   Relative / Zip / Content），没有 localStorage 后端，Jai 侧也没有验收的 wasm 目标，
//   因此这里按 olib 的**失败语义**给空实现：
//     - resources_root_dev / resources_root_release 返回虚拟 FS 根 "/"（不是 URL，
//       也不会自动下载站点文件；#load 资源直接内嵌，与 olib 相同）；
//     - user_root 返回 ""（olib：localStorage 不可用 / CreateDirectory 失败时返回空串）。
//   调用方按 olib 的约定处理：根为 "" 时不要回退到当前工作目录。
//
// 本文件只在 `#if OS == .WASM`（对位 `#+build js`）下生效；桌面构建里是空文件。
// 要真正支持浏览器存储，需要先给 jfoster 补 localStorage 存储后端，再把下面的
// user_root 换成「建 /foster/<app>/ 并返回」，其余路径策略不用改。
#import "Basic";

#if OS == .WASM {

//@region Web 专用桥接（桌面分支的同名过程在 storage_native.jai 里，两者互斥）

// strings.clone(s, allocator) 的对位：总是新分配，失败返回空字符串。
storage_web_copy_string :: (s: string, allocator: Allocator) -> string {
    if !s.count return "";
    push_allocator(allocator);
    out := alloc_string(s.count);
    if !out return "";
    memcpy(out.data, s.data, s.count);
    return out;
}
//@endregion

// 浏览器资源根指向 Foster 虚拟 FS；不是网页 URL，不会自动下载服务器文件。
// #load 资源无需读取此根；外部资源须先由应用加载/挂载到虚拟 FS。
resources_root_dev :: (allocator := context.allocator) -> string {
    return storage_web_copy_string("/", allocator);
}

resources_root_release :: (allocator := context.allocator) -> string {
    return resources_root_dev(allocator);
}

// 与 Foster OpenUserStorage 使用同一 /foster/<app>/ 命名空间。
// localStorage 按浏览器源隔离；创建失败（例如禁用存储）返回空字符串。
// olib 在这里调 foster.CreateDirectory(&container, "")；Jai 侧没有 localStorage
// 后端，等价于「创建失败」，故直接返回 ""（不编造一个写不进去的虚拟路径）。
user_root :: (app_name: string, allocator := context.allocator) -> string {
    if !valid_app_name(app_name) return "";
    return "";
}

}
