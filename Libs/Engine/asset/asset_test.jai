// asset_test.jai
// Port of olib engine/asset/asset_test.odin — asset 包单元测试（native）。
//
// 覆盖：guid 往返/唯一、blob 往返、.meta 身份（ensure/移动不坏/重复 GUID 报错）、
// import_all（导入/新鲜度跳过/删 Library 重建/孤儿警告/importer 版本失效）、
// 运行时加载（directory 与 map 后端、三种 kind、缓存、卸载）、
// manifest（打包形态：只带 Library、assets_root 为空时 load_path 仍可用）、
// 以及一个无头管线示例（生成渐变 QOI -> 导入 -> 按 guid 加载）。
//
// 测试工作区在 CWD 下的 .test_tmp/asset/（不入库，已加 .gitignore）。

#import "Basic";
#import "test_support";
#import "Hash_Table";

AT :: #import "asset";
FI :: #import "File";
FU :: #import "File_Utilities";

// Named comparisons (operator == for the same type pair must stay unique
// program-wide; the asset module already declares one for Guid).
guid_eq :: (a: AT.Guid, b: AT.Guid) -> bool {
    return AT.guid_equals(a, b);
}

handle_eq :: (a: AT.Asset_Handle, b: AT.Asset_Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

// ---------------------------------------------------------------------------
// 测试工作区助手
// ---------------------------------------------------------------------------

test_root :: () -> string {
    return ".test_tmp/asset";
}

// 清空并重建 <test_root>/<name>，返回其路径（context 分配）。
fresh_dir :: (state: *Test_State, name: string) -> string {
    dir := AT.str_join2(test_root(), name);
    if FU.file_exists(dir) {
        AT.dir_delete_tree(dir);
    }
    ok := FI.make_directory_if_it_does_not_exist(dir, true);
    expect(state, ok, "make_directory %", dir);
    if !ok return "";
    return dir;
}

write_file :: (state: *Test_State, path: string, data: []u8) -> bool {
    ok := AT.file_write_bytes(path, data);
    expect(state, ok, "write_file %", path);
    return ok;
}

// 生成一张 >=2x2 的四象限纯色 QOI（返回四个象限颜色 RGBA，
// 顺序：左上、右上、左下、右下）。
make_test_qoi :: (state: *Test_State, path: string, w: int, h: int) -> [4][4]u8 {
    c00 := u8.[255, 0, 0, 255];
    c10 := u8.[0, 255, 0, 255];
    c01 := u8.[0, 0, 255, 255];
    c11 := u8.[255, 255, 0, 255];
    expect(state, w >= 2 && h >= 2, "qoi test image must be >= 2x2");

    pixels := AT.alloc_bytes(w * h * 4);
    for y: 0..h-1 {
        for x: 0..w-1 {
            upper := y < h / 2 + 1;
            left  := x < w / 2 + 1;
            c: [4]u8;
            if left {
                if upper { c = c00; } else { c = c01; }
            } else {
                if upper { c = c10; } else { c = c11; }
            }
            for b: 0..3 {
                pixels[(x + y * w) * 4 + b] = c[b];
            }
        }
    }
    qoi := AT.qoi_encode(w, h, pixels);
    AT.free_bytes(pixels);
    ok := AT.file_write_bytes(path, cast([]u8) qoi);
    expect(state, ok, "write qoi %", path);
    free(qoi);
    return .[c00, c10, c01, c11];
}

// ---------------------------------------------------------------------------
// Guid
// ---------------------------------------------------------------------------

// Port of asset_test.odin: guid_roundtrip_and_uniqueness
test_asset_guid :: (state: *Test_State) {
    g := AT.guid_generate();
    s := AT.guid_to_string(g);
    expect(state, s.count == 32, "guid_to_string 长度应为 32，实际 %", s.count);

    back, ok := AT.guid_from_string(s);
    expect(state, ok && guid_eq(back, g), "hex 往返失败: %", s);

    // 大写 hex 解析
    upper_buf: String_Builder;
    for s {
        if it >= "a"[0] && it <= "f"[0] {
            append(*upper_buf, it - 32);
        } else {
            append(*upper_buf, it);
        }
    }
    upper_str := builder_to_string(*upper_buf);
    back2, ok2 := AT.guid_from_string(upper_str);
    expect(state, ok2 && guid_eq(back2, g), "大写 hex 解析不一致");
    free(upper_str);
    free(s);

    _, ok3 := AT.guid_from_string("zzzz");
    expect(state, !ok3, "非 hex 应解析失败");

    seen: Table(AT.Guid, bool, AT.guid_hash32, AT.guid_equals);
    dup := false;
    for 0..999 {
        gg := AT.guid_generate();
        _, hit := table_find(*seen, gg);
        if hit {
            dup = true;
            break;
        }
        table_add(*seen, gg, true);
    }
    deinit(*seen);
    expect(state, !dup, "1000 次内出现重复 guid");
}

// ---------------------------------------------------------------------------
// blob
// ---------------------------------------------------------------------------

// Port of asset_test.odin: blob_roundtrip
test_asset_blob :: (state: *Test_State) {
    g := AT.guid_generate();
    payload := cast([]u8) "\x01\x02\x03\x04\x05";

    blob, ok := AT.blob_build(g, .Raw, 7, 12345, 99, payload);
    expect(state, ok, "blob_build");

    header, parsed, pok := AT.blob_parse(blob);
    expect(state, pok, "blob_parse");
    expect(state, AT.guid_bytes_equal(header.guid, g.bytes), "header guid roundtrip");
    expect(state, header.importer_version == 7, "header importer_version");
    expect(state, header.src_mtime == 12345 && header.src_size == 99, "header freshness fields");
    expect(state, header.kind == cast(u8) AT.Asset_Kind.Raw && header.payload_len == 5, "header kind/payload_len");
    expect(state, parsed.count == payload.count, "payload length");
    match := true;
    for 0..payload.count-1 {
        if parsed[it] != payload[it] match = false;
    }
    expect(state, match, "payload bytes");
    free(blob);

    short, ok2 := AT.blob_build(g, .Raw, 1, 0, 0, cast([]u8) "0123456789ABCDEFGHIJ");
    trunc: string;
    trunc.data  = short.data;
    trunc.count = 10;
    _, _, ok_trunc := AT.blob_parse(trunc);
    expect(state, !ok_trunc, "truncated blob should fail");
    short[0] = "X"[0];
    _, _, ok_magic := AT.blob_parse(short);
    expect(state, !ok_magic, "bad magic should fail");
    free(short);
}

// ---------------------------------------------------------------------------
// .meta 身份
// ---------------------------------------------------------------------------

// Port of asset_test.odin: meta_identity
test_asset_meta :: (state: *Test_State) {
    root := fresh_dir(state, "meta");
    if root.count == 0 return;

    _ := make_test_qoi(state, AT.str_join2(root, "a.qoi"), 4, 4);

    // 缺 .meta 时 ensure 生成；已存在时读回同一个
    g1, e1 := AT.meta_ensure(root, "a.qoi");
    expect(state, e1 == .None, "meta_ensure: %", e1);
    g1b, e2 := AT.meta_read(root, "a.qoi");
    expect(state, e2 == .None && guid_eq(g1b, g1), "meta_read 与 ensure 不一致: %", e2);
    g1c, e3 := AT.meta_ensure(root, "a.qoi");
    expect(state, e3 == .None && guid_eq(g1c, g1), "二次 ensure 不应改 GUID");

    // 移动文件 + .meta 到子目录：GUID 不变（身份随 .meta 走）
    sub := AT.str_join2(root, "sub");
    ok := FI.make_directory_if_it_does_not_exist(sub, true);
    expect(state, ok, "mkdir sub");
    expect(state, AT.file_rename(AT.str_join2(root, "a.qoi"), AT.str_join2(sub, "a.qoi")), "rename a.qoi");
    expect(state, AT.file_rename(AT.str_join2(root, "a.qoi.meta"), AT.str_join2(sub, "a.qoi.meta")), "rename a.qoi.meta");
    g2, e7 := AT.meta_read(root, "sub/a.qoi");
    expect(state, e7 == .None && guid_eq(g2, g1), "移动文件+.meta 后 GUID 应不变: %", e7);

    // 人为制造重复 GUID：import_all 必须报 Duplicate_Guid（绝不静默换）
    _ := write_file(state, AT.str_join2(root, "b.qoi"), u8.[1]);
    e8 := AT.meta_write(root, "b.qoi", g1);
    expect(state, e8 == .None, "meta_write b: %", e8);
    _, derr := AT.import_all(root, AT.str_join2(root, "Library"));
    expect(state, derr == .Duplicate_Guid, "重复 GUID 应报 Duplicate_Guid，实际 %", derr);
}

// ---------------------------------------------------------------------------
// import_all + 运行时加载（directory 后端）
// ---------------------------------------------------------------------------

// Port of asset_test.odin: import_and_load
test_asset_import_load :: (state: *Test_State) {
    root := fresh_dir(state, "pipeline");
    if root.count == 0 return;
    assets_root := AT.str_join2(root, "Assets");
    library_root := AT.str_join2(root, "Library");
    expect(state, FI.make_directory_if_it_does_not_exist(assets_root, true), "mkdir Assets");

    quads := make_test_qoi(state, AT.str_join2(assets_root, "tex.qoi"), 4, 4);
    json_text := "{\"hp\": 10, \"name\": \"slime\"}";
    _ := write_file(state, AT.str_join2(assets_root, "conf.json"), cast([]u8) json_text);
    _ := write_file(state, AT.str_join2(assets_root, "data.bin"), u8.[9, 8, 7, 6]);

    s1, e1 := AT.import_all(assets_root, library_root);
    expect(state, e1 == .None, "import_all #1: %", e1);
    expect(state, s1.scanned == 3 && s1.imported == 3 && s1.skipped == 0 && s1.guid_generated == 3, "stats #1 scanned/imported/skipped/generated");

    s2, e2 := AT.import_all(assets_root, library_root);
    expect(state, e2 == .None, "import_all #2: %", e2);
    expect(state, s2.skipped == 3 && s2.imported == 0 && s2.guid_generated == 0, "stats #2 freshness skip");

    // 不变量：删除整个 Library 可完全重建，GUID 不变
    g_tex, _ := AT.meta_read(assets_root, "tex.qoi");
    AT.dir_delete_tree(library_root);
    s3, e3 := AT.import_all(assets_root, library_root);
    expect(state, e3 == .None && s3.imported == 3, "删 Library 重建: %", e3);
    g_after, _ := AT.meta_read(assets_root, "tex.qoi");
    expect(state, guid_eq(g_after, g_tex), "重建后 GUID 不变");

    // 运行时加载（本移植永远保留 CPU Image）
    m: AT.Asset_Manager;
    e4 := AT.assets_init(*m, .{ assets_root = assets_root, library_root = library_root });
    expect(state, e4 == .None, "assets_init: %", e4);
    defer AT.assets_dispose(*m);

    htex, e5 := AT.assets_load_path(*m, "tex.qoi");
    expect(state, e5 == .None, "load_path tex.qoi: %", e5);
    image := AT.assets_get_image(*m, htex);
    expect(state, image != null, "应拿到 CPU Image");
    if image != null {
        expect(state, image.width == 4 && image.height == 4, "image 尺寸 4x4");
        // 四角像素 = 四象限颜色
        xs := int.[0, 3, 0, 3];
        ys := int.[0, 0, 3, 3];
        for i: 0..3 {
            want := quads[i];
            match := true;
            for b: 0..3 {
                if image.pixels[(xs[i] + ys[i] * 4) * 4 + b] != want[b] match = false;
            }
            expect(state, match, "象限 % 像素不符", i);
        }
    }

    hjson, e6 := AT.assets_load_path(*m, "conf.json");
    expect(state, e6 == .None, "load_path conf.json: %", e6);
    value := AT.assets_get_json(*m, hjson);
    expect(state, value != null, "json getter 应返回非 null");
    if value != null {
        hp_v, hp_ok := table_find(*value.object_val, "hp");
        expect(state, hp_ok, "json 有 hp 字段");
        expect(state, hp_v.kind == .Number && hp_v.number_val == 10, "hp == 10");
    }

    hraw, e7 := AT.assets_load_path(*m, "data.bin");
    expect(state, e7 == .None, "load_path data.bin: %", e7);
    raw := AT.assets_get_bytes(*m, hraw);
    expect(state, raw.count == 4 && raw[0] == 9 && raw[3] == 6, "raw bytes 内容");

    // kind 不匹配防御
    expect(state, AT.assets_get_image(*m, hjson) == null, "get_image(json) == null");
    expect(state, AT.assets_get_bytes(*m, htex).count == 0, "get_bytes(texture) 为空");

    // guid 直查 + 缓存：同 guid 重复加载返回同句柄
    hagain, e8 := AT.assets_load(*m, g_tex);
    expect(state, e8 == .None && handle_eq(hagain, htex), "重复加载应命中缓存: %", e8);
    expect(state, AT.assets_len(*m) == 3, "assets_len == 3");

    // 卸载：句柄失效，缓存清空，重载可用
    g_raw := AT.assets_guid(*m, hraw);
    AT.assets_unload(*m, hraw);
    expect(state, !AT.assets_valid(*m, hraw), "卸载后句柄失效");
    hraw2, e9 := AT.assets_load(*m, g_raw);
    expect(state, e9 == .None && handle_eq(hraw2, AT.ASSET_HANDLE_NONE) == false, "卸载后应可重载: %", e9);
    expect(state, AT.assets_get_bytes(*m, hraw2).count == 4, "重载后内容完整");
}

// ---------------------------------------------------------------------------
// importer 版本失效
// ---------------------------------------------------------------------------

test_import_upper :: (source: []u8, ext: string, out: *AT.Payload_Builder) -> AT.Asset_Error {
    data := AT.alloc_bytes(source.count);
    for 0..source.count-1 {
        c := source[it];
        if c >= "a"[0] && c <= "z"[0] {
            data[it] = c - 32;
        } else {
            data[it] = c;
        }
    }
    out.data = data;
    return .None;
}

// Port of asset_test.odin: importer_version_invalidates
test_asset_importer_version :: (state: *Test_State) {
    root := fresh_dir(state, "version");
    if root.count == 0 return;
    assets_root := AT.str_join2(root, "Assets");
    library_root := AT.str_join2(root, "Library");
    expect(state, FI.make_directory_if_it_does_not_exist(assets_root, true), "mkdir");
    _ := write_file(state, AT.str_join2(assets_root, "a.tst"), cast([]u8) "hello");

    AT.importer_register(".tst", .{ kind = .Raw, version = 1, run = test_import_upper });

    s1, e1 := AT.import_all(assets_root, library_root);
    expect(state, e1 == .None && s1.imported == 1, "v1 首次导入: %", e1);
    s2, e2 := AT.import_all(assets_root, library_root);
    expect(state, e2 == .None && s2.skipped == 1, "v1 二次应跳过: %", e2);

    // 版本号 +1：源没变也要重导（导入逻辑升级即缓存失效）
    AT.importer_register(".tst", .{ kind = .Raw, version = 2, run = test_import_upper });
    s3, e3 := AT.import_all(assets_root, library_root);
    expect(state, e3 == .None && s3.imported == 1 && s3.skipped == 0, "版本升级应触发重导: % imported=% skipped=%", e3, s3.imported, s3.skipped);

    // 校验 v1/v2 产物内容确实是大写化的 "HELLO"
    m: AT.Asset_Manager;
    _ := AT.assets_init(*m, .{ assets_root = assets_root, library_root = library_root });
    defer AT.assets_dispose(*m);
    h, le := AT.assets_load_path(*m, "a.tst");
    expect(state, le == .None, "load a.tst: %", le);
    bytes := AT.assets_get_bytes(*m, h);
    expect(state, bytes.count == 5, "tst bytes 长度 5");
    match := true;
    want := cast([]u8) "HELLO";
    for 0..4 {
        if bytes[it] != want[it] match = false;
    }
    expect(state, match, "tst 内容应为大写 HELLO");
}

// ---------------------------------------------------------------------------
// map 后端
// ---------------------------------------------------------------------------

// Port of asset_test.odin: map_storage_load
test_asset_map_storage :: (state: *Test_State) {
    g := AT.guid_generate();
    blob, ok := AT.blob_build(g, .Raw, 1, 0, 0, u8.[1, 2, 3]);
    expect(state, ok, "blob_build");

    map_state: AT.Map_State;
    AT.storage_map_init(*map_state);
    defer AT.storage_map_dispose(*map_state);
    table_add(*map_state.blobs, g, cast([]u8) blob);

    m: AT.Asset_Manager;
    defer AT.assets_dispose(*m);
    e := AT.assets_init(*m, .{ storage = AT.storage_map(*map_state) });
    expect(state, e == .None, "assets_init: %", e);

    handle, lerr := AT.assets_load(*m, g);
    expect(state, lerr == .None, "assets_load: %", lerr);
    raw := AT.assets_get_bytes(*m, handle);
    expect(state, raw.count == 3 && raw[0] == 1 && raw[2] == 3, "map 后端 raw 内容");
    free(blob);

    // 不存在的 guid
    _, nferr := AT.assets_load(*m, AT.guid_generate());
    expect(state, nferr == .File_Not_Found, "未知 guid 应报 File_Not_Found: %", nferr);
}

// ---------------------------------------------------------------------------
// 孤儿 .meta
// ---------------------------------------------------------------------------

// Port of asset_test.odin: orphan_meta_warns
test_asset_orphan_meta :: (state: *Test_State) {
    root := fresh_dir(state, "orphan");
    if root.count == 0 return;
    assets_root := AT.str_join2(root, "Assets");
    library_root := AT.str_join2(root, "Library");
    expect(state, FI.make_directory_if_it_does_not_exist(assets_root, true), "mkdir");

    e1 := AT.meta_write(assets_root, "ghost.png", AT.guid_generate());
    expect(state, e1 == .None, "meta_write: %", e1);

    stats, e2 := AT.import_all(assets_root, library_root);
    expect(state, e2 == .None, "孤儿 .meta 不应报错: %", e2);
    expect(state, stats.scanned == 0 && stats.orphaned_meta == 1, "scanned 0 / orphan 1");
    expect(state, AT.file_exists(AT.str_join2(assets_root, "ghost.png.meta")), "孤儿 .meta 保留未删");
}

// ---------------------------------------------------------------------------
// manifest —— 打包形态（只带 Library，没有 Assets）
// ---------------------------------------------------------------------------

// Port of asset_test.odin: manifest_packaged_load
test_asset_manifest :: (state: *Test_State) {
    root := fresh_dir(state, "manifest");
    if root.count == 0 return;
    assets_root := AT.str_join2(root, "Assets");
    library_root := AT.str_join2(root, "Library");
    expect(state, FI.make_directory_if_it_does_not_exist(assets_root, true), "mkdir");

    quads := make_test_qoi(state, AT.str_join2(assets_root, "demo.qoi"), 4, 4);

    s1, e1 := AT.import_all(assets_root, library_root);
    expect(state, e1 == .None && s1.imported == 1, "导入: %", e1);

    // manifest blob 应作为保留 GUID 的 Raw blob 落在 Library 里
    buf: [37]u8;
    buf_view: []u8;
    buf_view.data  = cast(*u8) *buf;
    buf_view.count = 37;
    mname, _ := AT.guid_filename(AT.GUID_MANIFEST, buf_view);
    expect(state, AT.file_exists(AT.str_join2(library_root, mname)), "manifest blob 应存在于 Library");

    // ---- 模拟打包：删掉源 Assets 目录，运行时只有 Library ----
    AT.dir_delete_tree(assets_root);

    // 打包形态加载：assets_root 为空，.meta 回退不可用，只能靠 manifest
    m: AT.Asset_Manager;
    e5 := AT.assets_init(*m, .{ assets_root = "", library_root = library_root });
    expect(state, e5 == .None, "assets_init: %", e5);
    defer AT.assets_dispose(*m);

    h, e6 := AT.assets_load_path(*m, "demo.qoi");
    expect(state, e6 == .None, "打包形态 load_path 应走 manifest: %", e6);
    image := AT.assets_get_image(*m, h);
    expect(state, image != null, "打包形态应拿到 CPU Image");
    if image != null {
        expect(state, image.width == 4 && image.height == 4, "image 尺寸 4x4");
        xs := int.[0, 3, 0, 3];
        ys := int.[0, 0, 3, 3];
        for i: 0..3 {
            match := true;
            for b: 0..3 {
                if image.pixels[(xs[i] + ys[i] * 4) * 4 + b] != quads[i][b] match = false;
            }
            expect(state, match, "打包形态象限 % 像素不符", i);
        }
    }

    // manifest 里不存在的路径：没有 .meta 回退时应报错而非崩溃
    _, e7 := AT.assets_load_path(*m, "nope.qoi");
    expect(state, e7 != .None, "未知路径应报错: %", e7);
}

// ---------------------------------------------------------------------------
// 无头管线示例（对标 olib example/main.odin，不渲染）：生成渐变 QOI ->
// import_all -> 按 GUID / 路径双路加载 -> 校验尺寸与首尾像素。
// ---------------------------------------------------------------------------

test_asset_pipeline_example :: (state: *Test_State) {
    root := fresh_dir(state, "example");
    if root.count == 0 return;
    assets_root := AT.str_join2(root, "Assets");
    library_root := AT.str_join2(root, "Library");
    expect(state, FI.make_directory_if_it_does_not_exist(assets_root, true), "mkdir Assets");

    // 8x8 红->蓝水平渐变 QOI
    w := 8; h := 8;
    pixels := AT.alloc_bytes(w * h * 4);
    for y: 0..h-1 {
        for x: 0..w-1 {
            t := cast(u8) (x * 255 / (w - 1));
            pixels[(x + y * w) * 4 + 0] = t;
            pixels[(x + y * w) * 4 + 1] = 0;
            pixels[(x + y * w) * 4 + 2] = cast(u8) (255 - t);
            pixels[(x + y * w) * 4 + 3] = 255;
        }
    }
    qoi := AT.qoi_encode(w, h, pixels);
    AT.free_bytes(pixels);
    ok := AT.file_write_bytes(AT.str_join2(assets_root, "gradient.qoi"), cast([]u8) qoi);
    free(qoi);
    expect(state, ok, "写 gradient.qoi");

    stats, ierr := AT.import_all(assets_root, library_root);
    expect(state, ierr == .None && stats.imported == 1, "example import_all: %", ierr);

    m: AT.Asset_Manager;
    _ := AT.assets_init(*m, .{ assets_root = assets_root, library_root = library_root });
    defer AT.assets_dispose(*m);

    // 路径加载 + guid 加载收敛到同一资产
    h_path, e1 := AT.assets_load_path(*m, "gradient.qoi");
    expect(state, e1 == .None, "example load_path: %", e1);
    h_guid := h_path;
    g, _ := AT.meta_read(assets_root, "gradient.qoi");
    h2, e2 := AT.assets_load(*m, g);
    expect(state, e2 == .None && handle_eq(h2, h_guid), "guid 与 path 加载同一资产: %", e2);

    image := AT.assets_get_image(*m, h_path);
    expect(state, image != null, "example image");
    if image != null {
        expect(state, image.width == w && image.height == h, "example 尺寸 8x8");
        first_r := image.pixels[0];
        last_r  := image.pixels[(w * h - 1) * 4];
        expect(state, first_r == 0 && last_r == 255, "example 渐变首尾像素 R=0/255");
    }
}
