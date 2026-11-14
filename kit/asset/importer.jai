// Importer —— 源文件到资源派生 blob 的导入层（编辑器/工具侧）。
// 对位 olib kit/asset/importer.odin。
//
//   import_all("Assets", "Library")
//     1. 递归扫描 Assets/（.meta 不算源文件）
//     2. 每个源文件 meta_ensure：缺 .meta 就生成 GUID 写盘（新资产全自动入伙）
//     3. GUID 查重：两个 .meta 持同一 GUID -> Duplicate_Guid 报错（绝不静默换）
//     4. 新鲜度：blob 存在 且 源 mtime/size 相同 且 importer 版本相同 -> 跳过
//     5. 过期/缺失 -> 按扩展名分派 Importer 产出 payload -> 写 Library/<guid>.blob
//     6. 孤儿 .meta（源文件没了）打警告，不删除
//
// 仅资源管线拥有的 Library 是可重建派生缓存；保留源资源与 .meta 后可重新导入。
// 不得整体清理 Library，其中还可能有截图、生成素材候选与提示词。
// 本文件只在 native 目标可用（枚举/mtime 依赖文件系统）。
//
// Jai 侧差异（公开名、参数顺序、返回语义、blob 布局不变）：
//   | olib (Odin)                                     | 这里 (Jai)                                          |
//   | ----------------------------------------------- | --------------------------------------------------- |
//   | foster.EnumerateDirectory / DirectoryExists      | FU.visit_files（一次递归走完）+ FU.is_directory      |
//   | os.stat(full, temp) -> fi.modification_time/size | asset_file_mtime_size（FU.file_modtime_and_size，   |
//   |                                                  | 返回 (Apollo_Time, s64, bool)，折成 unix 纳秒）     |
//   | foster.ReadAllBytes(assets, rel)                 | FILE.read_entire_file(full)（bool 明确区分"读不到"  |
//   |                                                  | 与"0 字节"，jfoster 的 storage_read_all_bytes 不行）|
//   | foster.WriteAllBytes(library, name, blob)        | F.storage_write_all_bytes（要求 Writable = true）   |
//   | foster.CreateDirectory(library, "")              | FILE.make_directory_if_it_does_not_exist(root, true)|
//   | foster.ImageFromEncoded(source)                  | F.image_decode(source)（qoi/png；见下面的风险注）   |
//   | image.Pixels（[dynamic]Color）+ 逐字节 copy       | image.Data（[] Color）+ memcpy 整块                |
//   | strings.to_lower / last_index                    | asset_path_ext_lower（asset.jai 里的本地小工具）    |
//   | map[Guid]string 查重                             | Table(Guid, string, guid_hash, guid_equal)          |
//   | for path, guid in t                              | `for guid, path: *t`（jacket 是 value, key）        |
//   | custom_importers: map[string]Importer            | Table(string, Importer)（零值即可用，首次分配取    |
//   |                                                  | context.allocator）                                 |
//   注（风险）：jfoster 的 image_decode 只认 QOI 与 PNG（PNG 走 SDL_LoadPNG_IO，
//   需要 SDL 已初始化）。扩展名表故意与 olib 一致（png/jpg/jpeg/qoi/bmp/tga），
//   其余格式会解出空 Image 并返回 Import_Failed——不静默产出坏 blob。

//@region 导入器

// Importer 的产出。data 所有权归导入器（分配于传入 allocator），
// import_all 打包进 blob 后立即释放；调用方无需长期持有。
Payload_Builder :: struct {
    width: u32; // 仅 .Texture
    height: u32; // 仅 .Texture
    format: u32; // 仅 .Texture（TEXTURE_FORMAT_*）
    data: [] u8; // .Texture: 纯像素；.Json/.Raw: payload 全量字节
}

// 自定义导入器签名。source 是源文件字节，ext 是小写含点扩展名（".aseprite"），
// 仅在导入调用期间有效。非 contextless：内建贴图导入要走 jfoster 的解码路径。
Import_Proc :: #type (source: [] u8, ext: string, out: *Payload_Builder, allocator: Allocator) -> Asset_Error;

Importer :: struct {
    kind: Asset_Kind; // 产出 blob 的 kind
    version: u32; // 导入逻辑版本：改了导入算法就 +1，旧缓存自动过期
    run: Import_Proc;
}

// 内建导入器的当前版本。
BUILTIN_VERSION_TEXTURE: u32 : 1;
BUILTIN_VERSION_JSON: u32 : 1;
BUILTIN_VERSION_RAW: u32 : 1;

// 模块级注册表（key 小写含点，如 ".aseprite"）。
custom_importers: Table(string, Importer);

// 注册/覆盖某扩展名的导入器（key 小写含点，如 ".aseprite"；也可传 "aseprite"）。
// 优先级高于内建分派；版本号升级会令旧 blob 过期重导。
importer_register :: (ext: string, imp: Importer) {
    // olib: strings.contains(key, ".") ? key : strings.join({".", key}, "")
    key := ext;
    owned_key := "";
    if asset_last_index_of(key, #char ".") < 0 {
        owned_key = asset_concat(".", key, context.allocator);
        key = owned_key;
    }
    lower := asset_lower_copy(key, context.allocator);
    // set: 重复注册覆盖旧导入器（table_set 而不是 table_add，避免同名多条）。
    table_set(*custom_importers, lower, imp); // key 随注册表存活，不释放
    if owned_key.count > 0 free(owned_key);
}

// 按扩展名选导入器：自定义注册优先，其次内建（贴图格式 -> Texture，
// .json -> Json，其余 -> Raw 直通）。
importer_for_ext :: (ext: string) -> Importer {
    found, registered := table_find(*custom_importers, ext);
    if found return registered;

    if ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".qoi" || ext == ".bmp" || ext == ".tga" {
        return Importer.{ kind = .Texture, version = BUILTIN_VERSION_TEXTURE, run = import_texture };
    }
    if ext == ".json" {
        return Importer.{ kind = .Json, version = BUILTIN_VERSION_JSON, run = import_passthrough };
    }
    return Importer.{ kind = .Raw, version = BUILTIN_VERSION_RAW, run = import_passthrough };
}

// 内建贴图导入：qoi/png -> 解码为 RGBA8 像素。
// 解码中间量归 jfoster（context），产出像素克隆到传入 allocator。
import_texture :: (source: [] u8, ext: string, out: *Payload_Builder, allocator: Allocator) -> Asset_Error {
    image := F.image_decode(source);
    if image.Width <= 0 || image.Height <= 0 return .Import_Failed;
    defer F.image_destroy(*image);

    byte_count := cast(int) image.Width * cast(int) image.Height * size_of(F.Color);
    data, allocated := asset_alloc_bytes(byte_count, allocator);
    if !allocated return .Import_Failed;
    // 注意：transmute 切片保留的是元素个数而非字节数，这里一律按 rawptr+字节数拷。
    memcpy(data.data, image.Data.data, byte_count);

    out.width = cast(u32) image.Width;
    out.height = cast(u32) image.Height;
    out.format = TEXTURE_FORMAT_RGBA8;
    out.data = data;
    return .None;
}

// 内建直通导入：Json / Raw 的 payload 就是源字节本身。
import_passthrough :: (source: [] u8, ext: string, out: *Payload_Builder, allocator: Allocator) -> Asset_Error {
    data, allocated := asset_alloc_bytes(source.count, allocator);
    if !allocated return .Import_Failed;
    if source.count > 0 memcpy(data.data, source.data, source.count);
    out.data = data;
    return .None;
}
//@endregion

//@region import_all

Import_Stats :: struct {
    scanned: int; // 源文件数（不含 .meta）
    imported: int;
    skipped: int;
    guid_generated: int; // 本次新发 GUID 的资产数
    orphaned_meta: int; // 孤儿 .meta 数（只警告）
}

import_all :: (assets_root: string, library_root: string) -> (Import_Stats, Asset_Error) {
    stats: Import_Stats;

    // olib: foster.CreateDirectory(library, "")（容器自己建根目录）
    _ = FILE.make_directory_if_it_does_not_exist(library_root, true);

    assets: F.Storage_Container;
    assets.Root = assets_root;
    assets.Writable = false;

    library: F.Storage_Container;
    library.Root = library_root;
    library.Writable = true;

    // 收集源文件与 .meta 的相对路径（一次递归扫描；字符串归 sources/metas 所有，
    // 末尾统一释放）。
    sources: [..] string;
    metas: [..] string;
    defer {
        for sources free(it);
        array_free(sources);
        for metas free(it);
        array_free(metas);
    }
    collect_sources(assets_root, *sources, *metas);
    stats.scanned = sources.count;

    // ---- 第一遍：身份。发 GUID + 查重 ----
    guid_by_path: Table(string, Guid);
    path_by_guid: Table(Guid, string, guid_hash, guid_equal);
    defer {
        deinit(*guid_by_path);
        deinit(*path_by_guid);
    }

    for sources {
        rel := it;

        meta_rel := asset_concat(rel, META_EXT);
        had_meta := F.storage_file_exists(*assets, meta_rel);
        free(meta_rel);

        guid, err := meta_ensure(*assets, rel);
        if err != .None return stats, err;
        if !had_meta stats.guid_generated += 1;

        found, other := table_find(*path_by_guid, guid);
        if found {
            guid_hex := guid_to_string(guid, context.allocator);
            print(
                "asset: duplicate guid %\n  %\n  %\n  (复制了 .meta？删掉其中一个 .meta 重新生成)\n",
                guid_hex, other, rel,
            );
            free(guid_hex);
            return stats, .Duplicate_Guid;
        }
        table_add(*path_by_guid, guid, rel); // 借用 sources 持有的字符串
        table_add(*guid_by_path, rel, guid);
    }

    // ---- 第二遍：新鲜度 + 导入 ----
    for sources {
        rel := it;
        known, guid := table_find(*guid_by_path, rel);
        if !known continue;
        ext := asset_path_ext_lower(rel);
        imp := importer_for_ext(ext);

        full_src := join_owned(assets_root, rel);
        mtime, size, sok := asset_file_mtime_size(full_src);
        if !sok {
            free(full_src);
            free(ext);
            return stats, .File_Not_Found;
        }

        hdr, hok := read_blob_header(library_root, guid);
        if hok {
            if hdr.kind == cast(u8) imp.kind
            && hdr.importer_version == imp.version
            && hdr.src_mtime == mtime
            && hdr.src_size == size {
                free(full_src);
                free(ext);
                stats.skipped += 1;
                continue;
            }
        }

        // olib: foster.ReadAllBytes(assets, rel)。这里走 File：bool 同时表达
        // "打不开" 与 "打开但 0 字节"，空源文件是合法的 Raw payload。
        data, rok := FILE.read_entire_file(full_src);
        free(full_src);
        if !rok {
            print("asset: 读不到源文件 %\n", rel);
            free(ext);
            return stats, .File_Not_Found;
        }
        source := cast([] u8) data;

        builder: Payload_Builder;
        ierr := imp.run(source, ext, *builder, context.allocator);
        free(source.data);
        if ierr != .None {
            print("asset: 导入失败 % (%)\n", rel, ext);
            free(ext);
            if builder.data.count > 0 asset_free_bytes(builder.data, context.allocator);
            return stats, .Import_Failed;
        }
        free(ext);

        payload := builder.data;
        if imp.kind == .Texture {
            // Texture 的 payload = 迷你头 + 像素（新分配），打包后统一释放。
            p, pok := blob_payload_texture(*builder, context.allocator);
            asset_free_bytes(builder.data, context.allocator);
            if !pok return stats, .Write_Error;
            payload = p;
        }

        blob, bok := blob_build(guid, imp.kind, imp.version, mtime, size, payload, context.allocator);
        asset_free_bytes(payload, context.allocator);
        if !bok return stats, .Write_Error;

        name_buf: [37] u8;
        name, _ := guid_filename(guid, name_buf);
        written := F.storage_write_all_bytes(*library, name, blob);
        asset_free_bytes(blob, context.allocator);
        if !written {
            print("asset: 写 blob 失败 %\n", rel);
            return stats, .Write_Error;
        }
        stats.imported += 1;
    }

    // ---- 孤儿 .meta：只警告不删（防止误删身份） ----
    for metas {
        src_rel := asset_meta_refers_to(it);
        known, _ := table_find(*guid_by_path, src_rel);
        if !known {
            stats.orphaned_meta += 1;
            print("asset: 孤儿 .meta（源文件不存在，保留不删）: %\n", it);
        }
    }

    // ---- manifest：path→guid 全量重写（打包后 assets_load_path 零改动） ----
    werr := manifest_write(*library, *guid_by_path);
    if werr != .None {
        return stats, werr;
    }

    return stats, .None;
}
//@endregion

//@region 内部

// 一次递归扫描的结果：sources / metas 里的字符串由本过程分配，调用方负责释放。
Asset_Walk :: struct {
    root: string;
    sources: *[..] string;
    metas: *[..] string;
}

// FU.visit_files 的回调（visit_directories 默认 false，所以只会拿到文件）。
asset_walk_visit :: (info: *FU.File_Visit_Info, walk: *Asset_Walk) {
    if info.is_directory return;
    rel := asset_relative_path(info.full_name, walk.root);
    if rel.count == 0 {
        free(rel);
        return;
    }
    if asset_has_meta_ext(rel) {
        array_add(walk.metas, rel);
    } else {
        array_add(walk.sources, rel);
    }
}

collect_sources :: (root: string, sources: *[..] string, metas: *[..] string) {
    walk: Asset_Walk;
    walk.root = root;
    walk.sources = sources;
    walk.metas = metas;
    // olib 是逐层 foster.EnumerateDirectory + 递归；visit_files(recursive = true)
    // 一次走完，顺序（目录内枚举序）不参与任何语义。
    _ = FU.visit_files(root, true, *walk, asset_walk_visit);
}

// 把 visit_files 的 full_name 变成相对 root、'/' 分隔的新字符串（调用方 free）。
// 前缀不匹配时原样（分隔符归一）返回整条路径——不会静默丢文件。
asset_relative_path :: (full: string, root: string) -> string {
    start := 0;
    if root.count > 0 {
        if full.count > root.count && asset_starts_with(full, root) start = root.count;
    }
    while start < full.count && (full[start] == #char "/" || full[start] == #char "\\") start += 1;

    n := full.count - start;
    if n <= 0 return "";
    out := alloc_string(n);
    if !out return "";
    for i: 0..n - 1 {
        c := full[start + i];
        if c == #char "\\" c = #char "/";
        out[i] = c;
    }
    return out;
}

// "x.png.meta" -> "x.png"（视图，借用入参）。
asset_meta_refers_to :: (meta_rel: string) -> string {
    if meta_rel.count > META_EXT.count {
        return asset_str_view(meta_rel, 0, meta_rel.count - META_EXT.count);
    }
    return meta_rel;
}

asset_has_meta_ext :: (path: string) -> bool {
    if path.count <= META_EXT.count return false;
    tail := asset_str_view(path, path.count - META_EXT.count, path.count);
    return asset_string_equal(tail, META_EXT);
}

// 只读 blob 头（新鲜度检查用，避免为比对而整读大 blob）。
read_blob_header :: (library_root: string, guid: Guid) -> (Blob_Header, bool) {
    empty: Blob_Header;
    buf: [37] u8;
    name, name_ok := guid_filename(guid, buf);
    if !name_ok return empty, false;

    path := join_owned(library_root, name);
    defer free(path);

    f, opened := FILE.file_open(path);
    if !opened return empty, false;
    defer FILE.file_close(*f);

    raw: [size_of(Blob_Header)] u8;
    read_ok, got := FILE.file_read(*f, cast(*void) *raw, size_of(Blob_Header));
    if !read_ok || got != size_of(Blob_Header) return empty, false;

    h := cast(*Blob_Header) *raw[0];
    if !asset_bytes_equal(h.magic, BLOB_MAGIC) return empty, false;
    return h.*, true;
}
//@endregion
