// .meta —— 资产身份文件。对位 olib kit/asset/meta.odin。
//
// 每个源资产旁边一个（Assets/textures/belt.png + belt.png.meta），
// 内容是一行 JSON：{"guid": "31d0a7c9e2f4..."}。
//
// 纪律：
//   - .meta 提交进版本控制（它是身份，不是缓存）；
//   - 移动/重命名源文件时把 .meta 一起带走（身份随文件走，引用不断）；
//   - 绝不手动编辑 guid；复制 .meta 会造成 Duplicate_Guid，import_all 会报错；
//   - 删除资产 = 源文件 + .meta 一起删；孤立的 .meta（源没了）import_all
//     只警告不删除，防止误删身份。
//
// Jai 侧差异（JSON 字段名 "guid"、pretty 输出与 olib 一致）：
//   | olib (Odin)                                    | 这里 (Jai)                                        |
//   | ---------------------------------------------- | ------------------------------------------------- |
//   | foster.StorageContainer                        | F.Storage_Container                               |
//   | foster.FileExists(assets, meta_rel)            | F.storage_file_exists(assets, meta_rel)           |
//   | strings.join({rel_path, META_EXT}, "")         | asset_concat(rel_path, META_EXT)（不能借用       |
//   |                                                | KS.storage_path_join，它会在中间插 '/'）          |
//   | enc.json_load_struct(full, &meta)              | ENC.json_parse + ENC.json_value_to_struct，树自己 |
//   |                                                | destroy（json_load_struct 的字符串字段指向解析树  |
//   |                                                | 内部，free 它会变成非法 free）                    |
//   | enc.json_save_struct(full, &meta)              | ENC.json_save_struct(full, *meta)                 |
//   | delete(meta.guid) / delete(s)                  | free(s)（都是 context 分配）                      |
//   | join_owned(assets.Root, rel)（本包私有）        | join_owned（放在 asset.jai，meta/importer 共用）   |

META_EXT :: ".meta";

// .meta 的 JSON 形态。保持单字段：管线内部信息（新鲜度等）都记在 blob
// header 里，不污染身份文件。
Asset_Meta :: struct {
    guid: string;
}

// 读取源文件旁的 .meta。缺失返回 Meta_Missing；内容不合法返回 Parse_Error。
meta_read :: (assets: *F.Storage_Container, rel_path: string) -> (Guid, Asset_Error) {
    meta_rel := asset_concat(rel_path, META_EXT);
    defer free(meta_rel);

    if !F.storage_file_exists(assets, meta_rel) {
        return GUID_NONE, .Meta_Missing;
    }

    full := join_owned(assets.Root, meta_rel);
    defer free(full);

    text, read_ok := FILE.read_entire_file(full);
    if !read_ok return GUID_NONE, .Parse_Error;
    defer free(text);

    value, parsed := ENC.json_parse(text, context.allocator);
    if !parsed return GUID_NONE, .Parse_Error;
    defer ENC.json_destroy_value(value);

    meta: Asset_Meta;
    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(Asset_Meta);
    // 解析失败（不是 object / 字段类型不符）一律按 Parse_Error 处理；
    // guid 缺失时 meta.guid 是空字符串，guid_from_string 会再失败一次。
    if !ENC.json_value_to_struct(value, cast(*void) *meta, info) return GUID_NONE, .Parse_Error;

    guid, ok := guid_from_string(meta.guid);
    if !ok {
        return GUID_NONE, .Parse_Error;
    }
    return guid, .None;
}

// 写出 .meta（pretty JSON，diff 友好）。
meta_write :: (assets: *F.Storage_Container, rel_path: string, guid: Guid) -> Asset_Error {
    meta: Asset_Meta;
    meta.guid = guid_to_string(guid, context.allocator);
    defer free(meta.guid);

    meta_rel := asset_concat(rel_path, META_EXT);
    defer free(meta_rel);

    full := join_owned(assets.Root, meta_rel);
    defer free(full);

    if ENC.json_save_struct(full, *meta) != .None {
        return .Write_Error;
    }
    return .None;
}

// ensure 语义：有 .meta 则读，没有则生成新 GUID 并写盘。
// import_all 对每个源文件调它，所以新资产入伙是全自动的。
meta_ensure :: (assets: *F.Storage_Container, rel_path: string) -> (Guid, Asset_Error) {
    guid, err := meta_read(assets, rel_path);
    if err == .None {
        return guid, .None;
    }
    if err != .Meta_Missing {
        return GUID_NONE, err;
    }

    guid = guid_generate();
    werr := meta_write(assets, rel_path, guid);
    if werr != .None {
        return GUID_NONE, werr;
    }
    return guid, .None;
}
