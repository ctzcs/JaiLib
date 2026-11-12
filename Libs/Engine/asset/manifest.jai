// manifest.jai
// Port of olib engine/asset/manifest.odin.
//
// manifest —— path → GUID 寻址层（开发期与打包共用同一套加载代码的关键）。
//
// import_all 收尾时，把扫描到的全部（源相对路径, GUID）全量重写进一个
// 保留 GUID 的 Raw blob。assets_load_path 先查它，查不到再回退读源目录
// 旁侧 .meta：
//
//   开发期：两条路都在，新丢进的文件没导入过时自动落到 .meta 回退；
//   打包后：只发行 Library/（将来 pak），manifest 随其他 blob 一起进包，
//           assets_load_path 一行代码都不用改。
//
// 为什么是保留 GUID 的 blob 而不是 Library 根下一个散文件：manifest 和
// 其他派生物走同一条 Asset_Storage(Guid) 通道，pak 后端不需要任何特殊
// 处理。manifest 是纯派生物（从 .meta 推导），不进版本控制、不承担身份。

MANIFEST_VERSION :: 1;

// 保留 GUID（前缀 "manifest"）。128-bit 随机生成撞上它的概率可忽略；
// 它没有 .meta，不会参与 import_all 的 Duplicate_Guid 检查。
GUID_MANIFEST :: Guid.{
    bytes = .[
        "m"[0], "a"[0], "n"[0], "i"[0], "f"[0], "e"[0], "s"[0], "t"[0],
        0, 0, 0, 0, 0, 0, 0, 1,
    ],
};

Manifest_Entry :: struct {
    path: string; // 相对 assets_root，'/' 分隔
    guid: string; // 32-hex
}

Asset_Manifest :: struct {
    version: u32;
    entries: [..] Manifest_Entry;
}

// import_all 收尾调用：把 path→guid 表全量写成 manifest blob。
// 按路径排序保证输出稳定，便于人工比对两次导入的 manifest。
manifest_write :: (library_root: string, guid_by_path: Table(string, Guid)) -> Asset_Error {
    m: Asset_Manifest;
    m.version = MANIFEST_VERSION;

    for guid_by_path {
        array_add(*m.entries, .{
            path = str_clone(it_index),
            guid = guid_to_string(it),
        });
    }
    manifest_sort(m.entries);

    value := enc.json_struct_to_value(*m, cast(*Type_Info_Struct) cast(*Type_Info) type_info(Asset_Manifest));
    data := enc.json_marshal(value, 0, true);
    enc.json_destroy_value(value);

    for m.entries {
        free(it.path);
        free(it.guid);
    }
    array_free(m.entries);

    payload := cast([]u8) data;
    blob, ok := blob_build(GUID_MANIFEST, .Raw, MANIFEST_VERSION, 0, 0, payload);
    free(data);
    if !ok return .Write_Error;

    buf: [37]u8;
    name, _ := guid_filename(GUID_MANIFEST, u8_view(cast(*u8) *buf, 37));
    path := str_join2(library_root, name);
    written := file_write_bytes(path, cast([]u8) blob);
    free(path);
    free(blob);
    if !written {
        print("asset: 写 manifest 失败\n");
        return .Write_Error;
    }
    return .None;
}

// 把 manifest blob 解析进管理器的 path→guid 缓存（惰性加载一次）。
// 返回 false = 存储 backend 里没有 manifest 或内容不合法；
// 调用方按"无 manifest"处理，走 .meta 回退。
manifest_load :: (m: *Asset_Manager) -> bool {
    data, found := m.storage.read(*m.storage, GUID_MANIFEST, m.allocator);
    if !found return false;
    defer free_bytes(data, m.allocator);

    header, payload, ok := blob_parse(cast(string) data);
    if !ok return false;
    if header.kind != cast(u8) Asset_Kind.Raw return false;

    parser: enc.Json_Parser;
    parser.text = payload;
    value, pok := enc.json_parser_parse_value(*parser);
    if !pok return false;
    defer enc.json_destroy_value(value);

    if value.kind != .Object return false;
    entries_v, efound := table_find(*value.object_val, "entries");
    if !efound return false;
    if entries_v.kind != .Array return false;

    for entries_v.array_val {
        item := <<it;
        if item.kind != .Object continue;
        path_v, pfound := table_find(*item.object_val, "path");
        guid_v, gfound := table_find(*item.object_val, "guid");
        if !pfound || !gfound continue;
        if path_v.kind != .String || guid_v.kind != .String continue;

        guid, gok := guid_from_string(guid_v.string_val);
        if !gok continue;
        table_add(*m.manifest, str_clone(path_v.string_val), guid);
    }
    return true;
}

// 插入排序：manifest 条目量级在几十~几千，不值得引排序框架。
manifest_sort :: (entries: [] Manifest_Entry) {
    for 1..entries.count-1 {
        e := entries[it];
        j := it;
        while j > 0 && str_less(e.path, entries[j - 1].path) {
            entries[j] = entries[j - 1];
            j -= 1;
        }
        entries[j] = e;
    }
}
