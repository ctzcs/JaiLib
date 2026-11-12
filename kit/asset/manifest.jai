// manifest —— path → GUID 寻址层（开发期与打包共用同一套加载代码的关键）。
// 对位 olib kit/asset/manifest.odin。
//
// import_all 收尾时，把扫描到的全部（源相对路径, GUID）全量重写进一个
// 保留 GUID 的 Raw blob。assets_load_path 先查它，查不到再回退读源目录
// 旁侧 .meta：
//
//   开发期：两条路都在，新丢进的文件没导入过时自动落到 .meta 回退；
//   打包后：将所需 blob 与 manifest 放入发布资源目录（将来 pak），
//           配置 library_root 后复用 assets_load_path；不得整体打包项目 library。
//
// 为什么是保留 GUID 的 blob 而不是派生缓存目录下一个散文件：manifest 和
// 其他派生物走同一条 Asset_Storage(Guid) 通道，pak 后端不需要任何特殊
// 处理。manifest 是纯派生物（从 .meta 推导），不进版本控制、不承担身份。
//
// Jai 侧差异（manifest 的 JSON 字段名 "version" / "entries" / "path" / "guid" 不变）：
//   | olib (Odin)                                    | 这里 (Jai)                                             |
//   | ---------------------------------------------- | ------------------------------------------------------ |
//   | json.marshal(m, enc.DEFAULT_MARSHAL_OPT)       | ENC.json_marshal(ENC.json_struct_to_value(...),         |
//   |                                                | ENC.DEFAULT_MARSHAL_OPT)（本仓库的 marshal 只吃 Value， |
//   |                                                | 所以 struct → Value → 文本分两步）                      |
//   | json.unmarshal(payload, &mf)                   | ENC.json_parse + ENC.json_value_to_struct                |
//   | delete(data) / delete(blob)                    | free(data) / array_free(blob)（都是 context 分配）       |
//   | guid_by_path: map[string]Guid                  | *Table(string, Guid)（Jai 的表按指针传）                |
//   | for path, guid in guid_by_path                 | `for guid, path: *guid_by_path`（jacket 的 for 是      |
//   |                                                | `for value, key`，顺序与 Odin 相反）                    |
//   | entries[j-1].path > e.path（Odin 的字符串比较） | asset_string_compare(entries[j-1].path, e.path) > 0    |
//   | foster.WriteAllBytes(library, name, blob)      | F.storage_write_all_bytes(library, name, blob)         |
//   注：manifest 的对象键顺序（本仓库的 Table 遍历序）与 olib 的字段声明序不同，
//   字段名与条目排序（按 path）一致，import_all 两次输出的 manifest 仍然稳定。

MANIFEST_VERSION : u32 : 1;

// 保留 GUID（前缀 "manifest"）。128-bit 随机生成撞上它的概率可忽略；
// 它没有 .meta，不会参与 import_all 的 Duplicate_Guid 检查。
GUID_MANIFEST :: u8.[ #char "m", #char "a", #char "n", #char "i", #char "f", #char "e", #char "s", #char "t",
                      0, 0, 0, 0, 0, 0, 0, 1 ];

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
manifest_write :: (library: *F.Storage_Container, guid_by_path: *Table(string, Guid)) -> Asset_Error {
    m: Asset_Manifest;
    m.version = MANIFEST_VERSION;
    defer {
        for m.entries {
            free(it.path);
            free(it.guid);
        }
        array_free(m.entries);
    }

    // jacket 的 for 是 `for value, key: table`（与 Odin 的 `for k, v in` 相反）。
    for guid, path: guid_by_path {
        e := Manifest_Entry.{
            path = copy_string(path),
            guid = guid_to_string(guid, context.allocator),
        };
        array_add(*m.entries, e);
    }
    manifest_sort(m.entries);

    // olib 的 json.marshal(m, opt)：这里 struct → Value → 文本（Value 树要自己回收）。
    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(Asset_Manifest);
    value := ENC.json_struct_to_value(cast(*void) *m, info);
    defer ENC.json_destroy_value(value);
    data := ENC.json_marshal(value, ENC.DEFAULT_MARSHAL_OPT);
    defer free(data);

    blob, ok := blob_build(GUID_MANIFEST, .Raw, MANIFEST_VERSION, 0, 0, cast([] u8) data, context.allocator);
    if !ok return .Write_Error;
    defer asset_free_bytes(blob, context.allocator);

    name_buf: [37] u8;
    name, _ := guid_filename(GUID_MANIFEST, name_buf);
    if !F.storage_write_all_bytes(library, name, blob) {
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
    defer asset_free_bytes(data, m.allocator);

    header, payload, ok := blob_parse(data);
    if !ok || header.kind != cast(u8) Asset_Kind.Raw return false;

    mf: Asset_Manifest;
    defer {
        // entries 里的字符串借用 JSON 树（json_value_to_struct 不作拷贝），
        // 由下面的 json_destroy_value 统一释放；这里只归还条目数组本身。
        array_free(mf.entries);
    }

    value, parsed := ENC.json_parse(cast(string) payload, context.allocator);
    if !parsed return false;
    defer ENC.json_destroy_value(value);

    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(Asset_Manifest);
    if !ENC.json_value_to_struct(value, cast(*void) *mf, info) return false;

    for mf.entries {
        guid, gok := guid_from_string(it.guid);
        if !gok continue;
        path := asset_clone_string(it.path, m.allocator);
        table_add(*m.manifest, path, guid);
    }
    return true;
}

// 插入排序：manifest 条目量级在几十~几千，不值得引通用排序。
// 形参按值传可增长数组（Jai 的可增长数组头持有 data 指针，元素写入对调用方可见，
// 与 Odin 的切片语义一致；`*[..] T` 的下标写法在 jacket 里不成立）。
manifest_sort :: (entries: [..] Manifest_Entry) {
    for i: 1..entries.count - 1 {
        e := entries[i];
        j := i;
        while j > 0 && asset_string_compare(entries[j - 1].path, e.path) > 0 {
            entries[j] = entries[j - 1];
            j -= 1;
        }
        entries[j] = e;
    }
}
