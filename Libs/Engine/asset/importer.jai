// importer.jai
// Port of olib engine/asset/importer.odin.
//
// Importer —— 源文件到 Library blob 的导入层（编辑器/工具侧）。
//
//   import_all("Assets", "Library")
//     1. 递归扫描 Assets/（.meta 不算源文件）
//     2. 每个源文件 meta_ensure：缺 .meta 就生成 GUID 写盘（新资产全自动入伙）
//     3. GUID 查重：两个 .meta 持同一 GUID -> Duplicate_Guid 报错（绝不静默换）
//     4. 新鲜度：blob 存在 且 源 mtime/size 相同 且 importer 版本相同 -> 跳过
//     5. 过期/缺失 -> 按扩展名分派 Importer 产出 payload -> 写 Library/<guid>.blob
//     6. 孤儿 .meta（源文件没了）打警告，不删除
//
// Library 是纯派生缓存：删除整个 Library 再 import_all 即完整恢复。
//
// Jai 移植差异：
//   - olib 的贴图解码走 ofoster.ImageFromEncoded；这里 .qoi 走本包 qoi.jai，
//     .png/.jpg/.bmp/.tga 走 Jai 工具链的 stb_image 模块（静态库随包携带）。
//   - 扫描/mtime 走 Jai File / File_Utilities 模块（native only，与 olib 相同）。

stb :: #import "stb_image";
stb_image_lib :: #library,no_dll "windows/stb_image.lib";

// ===========================================================================
// 导入器
// ===========================================================================

// Importer 的产出。data 所有权归导入器（分配于 context allocator），
// import_all 打包进 blob 后立即释放；调用方无需长期持有。
Payload_Builder :: struct {
    width:  u32;  // 仅 .Texture
    height: u32;  // 仅 .Texture
    format: u32;  // 仅 .Texture（TEXTURE_FORMAT_*）
    data:   []u8; // .Texture: 纯像素；.Json/.Raw: payload 全量字节
}

// 自定义导入器签名。source 是源文件字节，ext 是小写含点扩展名（".aseprite"），
// 仅在导入调用期间有效。
Import_Proc :: #type (source: []u8, ext: string, out: *Payload_Builder) -> Asset_Error;

Importer :: struct {
    kind:    Asset_Kind;  // 产出 blob 的 kind
    version: u32;         // 导入逻辑版本：改了导入算法就 +1，旧缓存自动过期
    run:     Import_Proc;
}

// 内建导入器的当前版本。
BUILTIN_VERSION_TEXTURE :: 1;
BUILTIN_VERSION_JSON    :: 1;
BUILTIN_VERSION_RAW     :: 1;

// 模块级注册表（key 小写含点，如 ".aseprite"）。
custom_importers: Table(string, Importer);

// 注册/覆盖某扩展名的导入器（key 小写含点，如 ".aseprite"；也可传 "aseprite"）。
// 优先级高于内建分派；版本号升级会令旧 blob 过期重导。
importer_register :: (ext: string, imp: Importer) {
    key := ext;
    if str_last_index_of(key, "."[0]) < 0 {
        key = str_concat(".", key);
    }
    table_set(*custom_importers, str_lower(key), imp); // set: 重复注册覆盖旧导入器
}

// 按扩展名选导入器：自定义注册优先，其次内建（贴图格式 -> Texture，
// .json -> Json，其余 -> Raw 直通）。
importer_for_ext :: (ext: string) -> Importer {
    imp, found := table_find(*custom_importers, ext);
    if found {
        return imp;
    }
    if ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".qoi" || ext == ".bmp" || ext == ".tga" {
        return .{ kind = .Texture, version = BUILTIN_VERSION_TEXTURE, run = import_texture };
    } else if ext == ".json" {
        return .{ kind = .Json, version = BUILTIN_VERSION_JSON, run = import_passthrough };
    }
    return .{ kind = .Raw, version = BUILTIN_VERSION_RAW, run = import_passthrough };
}

// 内建贴图导入：.qoi 走纯 Jai 解码器；png/jpg/bmp/tga 走 stb_image（RGBA8）。
// 产出像素分配于 context allocator，所有权移交给 builder。
import_texture :: (source: []u8, ext: string, out: *Payload_Builder) -> Asset_Error {
    if ext == ".qoi" {
        image, ok := qoi_decode(cast(string) source);
        if !ok return .Import_Failed;
        out.width  = cast(u32) image.width;
        out.height = cast(u32) image.height;
        out.format = TEXTURE_FORMAT_RGBA8;
        out.data   = image.pixels;
        return .None;
    }

    x, y, n: s32;
    pixels := stb.stbi_load_from_memory(source.data, cast(s32) source.count, *x, *y, *n, 4);
    if pixels == null return .Import_Failed;

    data := alloc_bytes(cast(int) x * cast(int) y * 4);
    memcpy(data.data, pixels, data.count);
    stb.stbi_image_free(pixels);

    out.width  = cast(u32) x;
    out.height = cast(u32) y;
    out.format = TEXTURE_FORMAT_RGBA8;
    out.data   = data;
    return .None;
}

// 内建直通导入：Json / Raw 的 payload 就是源字节本身。
import_passthrough :: (source: []u8, ext: string, out: *Payload_Builder) -> Asset_Error {
    data := alloc_bytes(source.count);
    memcpy(data.data, source.data, source.count);
    out.data = data;
    return .None;
}

// ===========================================================================
// import_all
// ===========================================================================

Import_Stats :: struct {
    scanned:        int; // 源文件数（不含 .meta）
    imported:       int;
    skipped:        int;
    guid_generated: int; // 本次新发 GUID 的资产数
    orphaned_meta:  int; // 孤儿 .meta 数（只警告）
}

import_all :: (assets_root: string, library_root: string) -> (Import_Stats, Asset_Error) {
    stats: Import_Stats;

    _ := dir_make_all(library_root);

    // 收集源文件与 .meta 的相对路径（一次递归扫描；字符串归 paths 所有，
    // 末尾统一释放，sources/metas 只借用）。
    paths := collect_relative_paths(assets_root, true);
    defer free_relative_paths(paths);

    sources: [..] string;
    metas:   [..] string;
    defer {
        array_free(sources);
        array_free(metas);
    }
    for paths {
        if str_ends_with(it, META_EXT) {
            array_add(*metas, it);
        } else {
            array_add(*sources, it);
        }
    }
    stats.scanned = sources.count;

    // ---- 第一遍：身份。发 GUID + 查重 ----
    guid_by_path: Table(string, Guid);
    path_by_guid: Table(Guid, string, guid_hash32, guid_equals);
    defer {
        deinit(*guid_by_path);
        deinit(*path_by_guid);
    }

    for sources {
        rel := it;

        meta_rel := str_concat(rel, META_EXT);
        meta_path := str_join2(assets_root, meta_rel);
        had_meta := file_exists(meta_path);
        free(meta_rel);
        free(meta_path);

        guid, err := meta_ensure(assets_root, rel);
        if err != .None return stats, err;
        if !had_meta stats.guid_generated += 1;

        other, dup := table_find(*path_by_guid, guid);
        if dup {
            guid_hex := guid_to_string(guid);
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
        guid, _ := table_find(*guid_by_path, rel);
        ext  := path_ext_lower(rel);
        imp  := importer_for_ext(ext);

        full_src := str_join2(assets_root, rel);
        mtime, size, sok := file_mtime_size(full_src);
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

        source, rok := file_read_bytes(full_src);
        free(full_src);
        if !rok {
            print("asset: 读不到源文件 %\n", rel);
            free(ext);
            return stats, .File_Not_Found;
        }

        builder: Payload_Builder;
        ierr := imp.run(source, ext, *builder);
        free_bytes(source);
        if ierr != .None {
            print("asset: 导入失败 % (%)\n", rel, ext);
            free(ext);
            if builder.data.count > 0 free_bytes(builder.data);
            return stats, .Import_Failed;
        }
        free(ext);

        payload := builder.data;
        if imp.kind == .Texture {
            // Texture 的 payload = 迷你头 + 像素（新分配），打包后统一 free。
            p, pok := blob_payload_texture(*builder);
            free_bytes(builder.data);
            if !pok return stats, .Write_Error;
            payload = cast([]u8) p;
        }

        blob, bok := blob_build(guid, imp.kind, imp.version, mtime, size, payload);
        free_bytes(payload);
        if !bok return stats, .Write_Error;

        buf: [37]u8;
        name, _ := guid_filename(guid, u8_view(cast(*u8) *buf, 37));
        blob_path := str_join2(library_root, name);
        written := file_write_bytes(blob_path, cast([]u8) blob);
        free(blob_path);
        free(blob);
        if !written {
            print("asset: 写 blob 失败 %\n", rel);
            return stats, .Write_Error;
        }
        stats.imported += 1;
    }

    // ---- 孤儿 .meta：只警告不删（防止误删身份） ----
    for metas {
        src_rel := meta_refers_to(it);
        _, known := table_find(*guid_by_path, src_rel);
        if !known {
            stats.orphaned_meta += 1;
            print("asset: 孤儿 .meta（源文件不存在，保留不删）: %\n", it);
        }
    }

    // ---- manifest：path→guid 全量重写（打包后 assets_load_path 零改动） ----
    werr := manifest_write(library_root, guid_by_path);
    if werr != .None {
        return stats, werr;
    }

    return stats, .None;
}

// ===========================================================================
// 内部
// ===========================================================================

// "x.png.meta" -> "x.png"（视图切片，借用入参）。
meta_refers_to :: (meta_rel: string) -> string {
    if meta_rel.count > META_EXT.count {
        return slice(meta_rel, 0, meta_rel.count - META_EXT.count);
    }
    return meta_rel;
}

// 只读 blob 头（新鲜度检查用，避免为比对而整读大 blob）。
read_blob_header :: (library_root: string, guid: Guid) -> (Blob_Header, bool) {
    fail: Blob_Header;
    buf: [37]u8;
    name, ok := guid_filename(guid, u8_view(cast(*u8) *buf, 37));
    if !ok return fail, false;
    path := str_join2(library_root, name);

    f, fok := FI.file_open(path, false, false, false);
    free(path);
    if !fok return fail, false;

    raw: [size_of(Blob_Header)] u8;
    rrok, n := FI.file_read(f, cast(*void) *raw, size_of(Blob_Header));
    FI.file_close(*f);
    if !rrok || n != size_of(Blob_Header) return fail, false;

    h := cast(*Blob_Header) *raw[0];
    for 0..7 {
        if h.magic[it] != BLOB_MAGIC[it] return fail, false;
    }
    return <<h, true;
}
