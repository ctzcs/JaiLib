// loader.jai
// Port of olib engine/asset/loader.odin.
//
// Asset_Storage —— Runtime 的存储后端抽象（以 Guid 为键）。
// Runtime 从始至终只以 Guid 请求 blob，不知道也不需要知道
// "31d0a7c9.blob" 这样的文件名；文件名/布局是后端实现细节：
//
//   开发期:   guid -> Library/<guid>.blob        (storage_directory)
//   测试/内嵌: guid -> 内存 map                  (storage_map)
//   将来发布: guid -> pak 索引 -> offset/size    (再加一个后端即可)

// Storage proc signatures. read 的返回字节分配于传入 allocator，
// 由调用方（assets_load）统一释放。
Storage_Read_Proc :: #type (storage: *Asset_Storage, guid: Guid, allocator: Allocator) -> ([]u8, bool);
Storage_Exists_Proc :: #type (storage: *Asset_Storage, guid: Guid) -> bool;

Asset_Storage :: struct {
    read:     Storage_Read_Proc = null;
    exists:   Storage_Exists_Proc = null;
    userdata: *void;
}

// ===========================================================================
// Directory 后端（开发期默认）
// ===========================================================================

Directory_State :: struct {
    root: string; // 借用调用方字符串（通常是字面量）
}

storage_directory_init :: (state: *Directory_State, library_root: string) {
    state.root = library_root;
}

storage_directory :: (state: *Directory_State) -> Asset_Storage {
    return .{
        read     = directory_read,
        exists   = directory_exists,
        userdata = state,
    };
}

directory_read :: (storage: *Asset_Storage, guid: Guid, allocator: Allocator) -> ([]u8, bool) {
    state := cast(*Directory_State) storage.userdata;
    buf: [37]u8;
    name, ok := guid_filename(guid, u8_view(cast(*u8) *buf, 37));
    if !ok return .[], false;

    path := str_join2(state.root, name);
    data, rok := file_read_bytes(path);
    free(path);
    if !rok return .[], false;

    // 与 map 后端语义一致：read 拷贝进传入 allocator，由调用方统一释放。
    out := alloc_bytes(data.count, allocator);
    memcpy(out.data, data.data, data.count);
    free_bytes(data);
    return out, true;
}

directory_exists :: (storage: *Asset_Storage, guid: Guid) -> bool {
    state := cast(*Directory_State) storage.userdata;
    buf: [37]u8;
    name, ok := guid_filename(guid, u8_view(cast(*u8) *buf, 37));
    if !ok return false;
    path := str_join2(state.root, name);
    found := file_exists(path);
    free(path);
    return found;
}

// ===========================================================================
// Map 后端（测试 / 将来 web 目标把 #load 预烘焙的 blob 塞进来）
// ===========================================================================

Map_State :: struct {
    blobs: Table(Guid, []u8, guid_hash32, guid_equals);
}

storage_map_init :: (state: *Map_State) {
    // 默认构造即可（Jai Table 是惰性分配），这里显式初始化以示所有权。
}

storage_map_dispose :: (state: *Map_State) {
    // 表内存释放；存放的字节归写入方所有（与 olib 语义一致）。
    deinit(*state.blobs);
}

storage_map :: (state: *Map_State) -> Asset_Storage {
    return .{
        read     = map_read,
        exists   = map_exists,
        userdata = state,
    };
}

// read 会把字节克隆到传入 allocator——与 directory 后端语义一致，
// 调用方（assets_load）可以统一释放。
map_read :: (storage: *Asset_Storage, guid: Guid, allocator: Allocator) -> ([]u8, bool) {
    state := cast(*Map_State) storage.userdata;
    src, found := table_find(*state.blobs, guid);
    if !found return .[], false;
    out := alloc_bytes(src.count, allocator);
    memcpy(out.data, src.data, src.count);
    return out, true;
}

map_exists :: (storage: *Asset_Storage, guid: Guid) -> bool {
    state := cast(*Map_State) storage.userdata;
    _, found := table_find(*state.blobs, guid);
    return found;
}
