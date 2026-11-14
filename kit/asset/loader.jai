// Asset_Storage —— Runtime 的存储后端抽象（以 Guid 为键）。对位 olib kit/asset/loader.odin。
//
// Runtime 从始至终只以 Guid 请求 blob，不知道也不需要知道
// "31d0a7c9.blob" 这样的文件名；文件名/布局是后端实现细节：
//
//   开发期: guid -> Library/<guid>.blob        (storage_directory)
//   测试/内嵌: guid -> 内存表                  (storage_map)
//   将来发布: guid -> pak 索引 -> offset/size   (再加一个后端即可)
//
// 注：read/exists 故意不是 contextless——directory 后端内部要走 jfoster 的
// storage 读路径（带隐式 context）；allocator 显式传入这一点保持不变。
//
// Jai 侧差异（语义、参数顺序不变）：
//   | olib (Odin)                                     | 这里 (Jai)                                          |
//   | ----------------------------------------------- | --------------------------------------------------- |
//   | read: proc(storage, guid, allocator) -> ([]u8,bool) | 具名过程类型 Asset_Read_Proc / Asset_Exists_Proc |
//   | userdata: rawptr                                 | userdata: *void                                     |
//   | storage.read(&m.storage, guid, alloc)            | m.storage.read(*m.storage, guid, alloc)             |
//   | (^Directory_State)(storage.userdata)             | cast(*Directory_State) storage.userdata             |
//   | foster.StorageContainer{Root, Writable}          | F.Storage_Container{Bool Writable, string Root}     |
//   | foster.ReadAllBytes(container, name, allocator)  | push_allocator(allocator) + storage_read_all_bytes  |
//   |                                                  | （jfoster 那个没有 allocator 形参，吃 context）       |
//   | foster.FileExists(container, name)               | F.storage_file_exists(container, name)              |
//   | map[Guid][]u8                                    | Table(Guid, []u8, guid_hash, guid_equal)（Jai 的  |
//   |                                                  | 数组键要显式 hash/compare，见 asset.jai）            |
//   | delete(state.blobs)                              | deinit(*state.blobs)（值的内存归塞进来的调用方）     |
//   | make([]u8, len(src), allocator) + copy           | asset_alloc_bytes + memcpy                          |

//@region 类型

// olib 的回调类型：`proc(storage: ^Asset_Storage, guid: Guid, allocator: mem.Allocator)`。
// 返回的字节必须分配在 allocator 上，调用方（assets_load）统一释放。
Asset_Read_Proc :: (storage: *Asset_Storage, guid: Guid, allocator: Allocator) -> ([] u8, bool);
Asset_Exists_Proc :: (storage: *Asset_Storage, guid: Guid) -> bool;

Asset_Storage :: struct {
    read: Asset_Read_Proc;
    exists: Asset_Exists_Proc;
    userdata: *void;
}
//@endregion

//@region Directory 后端（开发期默认）

Directory_State :: struct {
    container: F.Storage_Container;
}

storage_directory_init :: (state: *Directory_State, library_root: string) {
    // olib: foster.StorageContainer{ Root = library_root, Writable = false }
    state.container.Root = library_root;
    state.container.Writable = false;
}

storage_directory :: (state: *Directory_State) -> Asset_Storage {
    return Asset_Storage.{
        read = directory_read,
        exists = directory_exists,
        userdata = state,
    };
}

directory_read :: (storage: *Asset_Storage, guid: Guid, allocator: Allocator) -> ([] u8, bool) {
    state := cast(*Directory_State) storage.userdata;
    buf: [37] u8;
    name, ok := guid_filename(guid, buf);
    if !ok return .[], false;

    // olib 判的是「ReadAllBytes 返回 nil」，即"文件读不到"。
    // jfoster 的 storage_read_all_bytes 读失败与读到 0 字节都返回空切片，
    // 无法区分；所以先判存在（0 字节 payload 是合法的，交给 blob_parse 判 Parse_Error）。
    if !F.storage_file_exists(*state.container, name) return .[], false;

    // push_allocator 是作用域级的：读回来的字节落在 allocator 上，
    // 与 olib 的 foster.ReadAllBytes(container, name, allocator) 语义一致。
    push_allocator(allocator);
    data := F.storage_read_all_bytes(*state.container, name);
    return data, true;
}

directory_exists :: (storage: *Asset_Storage, guid: Guid) -> bool {
    state := cast(*Directory_State) storage.userdata;
    buf: [37] u8;
    name, ok := guid_filename(guid, buf);
    if !ok return false;
    return F.storage_file_exists(*state.container, name);
}
//@endregion

//@region Map 后端（测试 / 将来 web 目标把 #load 预烘焙的 blob 塞进来）

Map_State :: struct {
    blobs: Table(Guid, [] u8, guid_hash, guid_equal);
}

storage_map_init :: (state: *Map_State, allocator := context.allocator) {
    // jacket 的 Table 零值即就绪；这里按 olib 的签名先把分配器钉住
    // （Table 首次增长时才真正分配，用这个分配器）。
    state.blobs.allocator = allocator;
}

storage_map_dispose :: (state: *Map_State) {
    // olib 的 delete(state.blobs) 只回收表本身，值（blob 字节）归塞进来的调用方。
    deinit(*state.blobs);
    // Jai 的带参类型不能直接跟 `.{ }` 空字面量：先造零值再整块赋值。
    empty: Table(Guid, [] u8, guid_hash, guid_equal);
    state.blobs = empty;
}

storage_map :: (state: *Map_State) -> Asset_Storage {
    return Asset_Storage.{
        read = map_read,
        exists = map_exists,
        userdata = state,
    };
}

// read 会把字节克隆到传入 allocator——与 directory 后端语义一致，
// 调用方（assets_load）可以统一释放。
map_read :: (storage: *Asset_Storage, guid: Guid, allocator: Allocator) -> ([] u8, bool) {
    state := cast(*Map_State) storage.userdata;
    found, src := table_find(*state.blobs, guid);
    if !found return .[], false;
    out, ok := asset_alloc_bytes(src.count, allocator);
    if !ok return .[], false;
    if src.count > 0 memcpy(out.data, src.data, src.count);
    return out, true;
}

map_exists :: (storage: *Asset_Storage, guid: Guid) -> bool {
    state := cast(*Map_State) storage.userdata;
    found, _ := table_find(*state.blobs, guid);
    return found;
}
//@endregion
