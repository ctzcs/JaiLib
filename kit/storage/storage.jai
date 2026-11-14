// storage —— 游戏资源与用户数据的跨平台路径策略。
//
// 桌面使用系统用户目录；Web 使用 Foster 虚拟文件系统，由浏览器 localStorage 持久化。
// 本包只选择根与应用命名空间，读写直接使用 Foster 的存储类型和操作，不封装运行时。
// 路径返回值归指定 allocator 所有；存储容器借用根字符串，容器结束使用后才可释放。
// 平台根目录在 storage_native.jai / storage_web.jai。
//
// 与 olib kit/storage/storage.odin 一比一对应。Jai 侧差异（行为不变，逐条对应）：
//
//   | olib (Odin)                                        | 这里 (Jai)                                          |
//   | -------------------------------------------------- | --------------------------------------------------- |
//   | foster.StorageContainer                            | F.Storage_Container（jfoster storage/storage.jai）   |
//   | foster.DirectoryStorage + DirectoryStorageInit()   | F.Storage_Container.{ Root = root, Writable = true } |
//   |                                                    | （jfoster 没有 Directory_Storage 类型；            |
//   |                                                    |  directory_storage_create 返回堆上的同一结构）      |
//   | foster.WriteAllBytes / WriteAllText                | F.storage_write_all_bytes / storage_write_all_text   |
//   | foster.WriteAllBytesAtomic / WriteAllTextAtomic    | 无对应物（jfoster 未移植原子写，见风险点）           |
//   | proc(storage: ^foster.DirectoryStorage, userdata: rawptr) | Storage_Use（Jai 的过程类型必须先有名字）    |
//   | rawptr                                             | *void                                               |
//   | context.allocator                                  | context.allocator（同名；默认参数在调用点求值）      |
//   | delete(s, allocator)                               | storage_free(s, allocator)（显式 allocator 释放）    |
//   | strings.join({a, b}, "/", allocator)               | storage_path_join（push_allocator + 手工拼 '/'）     |
//   | for c in app_name（遍历 rune）                      | for c: app_name（遍历字节；续字节 >= 0x80，等价）    |
//   | @(private)                                         | 无文件级私有：内部过程加 storage_ 前缀；             |
//   |                                                    | valid_app_name 按 olib 名字保留（测试同包调用）      |
#import "Basic";

//@region 便捷读写

// with_user_storage 要拿到 F.Storage_Container，桌面目标才有（jfoster 依赖 SDL）；
// Web 目标没有存储后端，直接不提供——与 olib 里 Web 侧 CreateDirectory 必然失败的等价。
#if OS != .WASM {

    // olib 的回调类型 `proc(storage: ^foster.DirectoryStorage, userdata: rawptr)`。
    // Jai 的过程类型必须先在作用域里有名字，才可作为参数类型，故这里立 Storage_Use。
    // 参数顺序（storage, userdata）与 olib 相同；*void 对应 rawptr。
    Storage_Use :: (storage: *F.Storage_Container, userdata: *void);

    // 打开用户存储执行 use 后立即释放（桌面和 Web 均同步调用；true 表示打开成功，读写结果由 use 检查）。
    // use 内部完成全部读写；不要把 storage 带出回调。
    // Jai 侧：Web 目标没有存储后端，本过程只在桌面目标下存在（见上面的 #if）。
    with_user_storage :: (app_name: string, use: Storage_Use, userdata: *void = null) -> bool {
        root := user_root(app_name);
        if root == "" return false;
        defer storage_free(root, context.allocator);

        // olib: foster.DirectoryStorageInit(&ds, root, true)
        // jfoster 没有 DirectoryStorageInit，容器就地构造（Root 借用 root，不复制）。
        ds: F.Storage_Container;
        ds.Root = root;
        ds.Writable = true;
        use(*ds, userdata);
        return true;
    }

} // #if OS != .WASM

// 用户数据内某文件的路径（temp 分配）；Web 为虚拟路径，不能传给系统文件 API。
// 根不可用时返回空字符串，不回退到当前工作目录。
user_file_path :: (app_name: string, rel_path: string) -> string {
    root := user_root(app_name, temp);
    if root == "" return "";
    return storage_path_join(root, rel_path, temp);
}
//@endregion

//@region 内部 —— 路径拼接（'/' 分隔，总是新分配）

// olib 的 @(private) path_join（strings.join({a, b}, "/", allocator) 的对位）。
// 具名导入 String 会与 Basic 的 join 重名，故手工拼两段，分配语义与 olib 相同：
// 总是新分配（a、b 都为空时得到 "/"），失败返回空字符串（olib 的 or_else） 。
storage_path_join :: (a: string, b: string, allocator := context.allocator) -> string {
    push_allocator(allocator);
    out := alloc_string(a.count + 1 + b.count);
    if !out return "";
    memcpy(out.data, a.data, a.count);
    out[a.count] = #char "/";
    memcpy(out.data + a.count + 1, b.data, b.count);
    return out;
}

// olib 的 delete(s, allocator)：Jai 的 free 只认当前 allocator，这里显式用传入的那个，
// 保证「路径返回值归指定 allocator 所有」的契约在自定义 allocator 下同样成立。
storage_free :: (s: string, allocator: Allocator) {
    if s.data == null return;
    allocator.proc(.FREE, 0, 0, s.data, allocator.data);
}

// app_name 是稳定的命名空间，不是路径，也不取自可变窗口标题。
valid_app_name :: (app_name: string) -> bool {
    if app_name == "" || app_name == "." || app_name == ".." return false;
    for c: app_name {
        if c < 32 || c == #char "/" || c == #char "\\" || c == #char ":" return false;
    }
    return true;
}
//@endregion
