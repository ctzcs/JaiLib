// meta.jai
// Port of olib engine/asset/meta.odin.
//
// .meta —— 资产身份文件。
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
// Jai 移植差异：olib 以 ofoster StorageContainer 传目录，这里直接传
// assets_root 字符串（路径以 '/' 拼接）。

enc :: #import "encoding";

META_EXT :: ".meta";

// .meta 的 JSON 形态。保持单字段：管线内部信息（新鲜度等）都记在 blob
// header 里，不污染身份文件。
Asset_Meta :: struct {
    guid: string;
}

// 读取源文件旁的 .meta。缺失返回 Meta_Missing；内容不合法返回 Parse_Error。
meta_read :: (assets_root: string, rel_path: string) -> (Guid, Asset_Error) {
    meta_rel := str_concat(rel_path, META_EXT);
    meta_path := str_join2(assets_root, meta_rel);
    free(meta_rel);

    if !file_exists(meta_path) {
        free(meta_path);
        return GUID_NONE, .Meta_Missing;
    }

    meta: Asset_Meta;
    jerr := enc.json_load_struct(meta_path, *meta);
    free(meta_path);
    if jerr != .None {
        return GUID_NONE, .Parse_Error;
    }

    guid, ok := guid_from_string(meta.guid);
    if !ok {
        return GUID_NONE, .Parse_Error;
    }
    return guid, .None;
}

// 写出 .meta（pretty JSON，diff 友好）。
meta_write :: (assets_root: string, rel_path: string, guid: Guid) -> Asset_Error {
    meta_rel := str_concat(rel_path, META_EXT);
    meta_path := str_join2(assets_root, meta_rel);
    free(meta_rel);

    meta := Asset_Meta.{ guid = guid_to_string(guid) };
    jerr := enc.json_save_struct(meta_path, *meta);
    free(meta.guid);
    free(meta_path);
    if jerr != .None return .Write_Error;
    return .None;
}

// ensure 语义：有 .meta 则读，没有则生成新 GUID 并写盘。
// import_all 对每个源文件调它，所以新资产入伙是全自动的。
meta_ensure :: (assets_root: string, rel_path: string) -> (Guid, Asset_Error) {
    guid, err := meta_read(assets_root, rel_path);
    if err == .None {
        return guid, .None;
    }
    if err != .Meta_Missing {
        return GUID_NONE, err;
    }

    guid = guid_generate();
    werr := meta_write(assets_root, rel_path, guid);
    if werr != .None {
        return GUID_NONE, werr;
    }
    return guid, .None;
}
