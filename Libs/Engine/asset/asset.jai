// asset.jai
// Port of olib engine/asset/asset.odin —— ofoster 资源管线 v1（Jai 移植）。
//
// 架构（.meta 管身份，Library 管派生物，blob 是 Importer/Runtime 边界）：
//
//   Assets/                  Library/                    Runtime
//   demo.qoi        --Importer-->  31d0a7c9.blob  --Loader-->  Asset_Handle
//   demo.qoi.meta   (身份, git)    (派生缓存,       (按 guid 零表直查,
//                                  可删重建)         不知道文件名)
//
// 分层纪律：
//   - .meta 是资产身份（{"guid":"..."}），提交进版本控制，移动源文件时跟着走；
//     GUID 一旦发布就永不改变，关卡/存档里只存 GUID。
//   - Library/ 是纯派生缓存，不进版本控制；删除整个 Library 后跑一次
//     import_all 即可完整恢复——这是本管线"干净"的不变量。
//   - blob 是 Importer 与 Runtime 的唯一边界；将来的 pak 只是给
//     Asset_Storage 换一个后端（guid -> pak 索引 -> offset/size），
//     Runtime 代码零改动。
//   - manifest（保留 GUID 的 Raw blob，import_all 收尾全量重写）记录
//     path -> guid，让 assets_load_path 在打包形态（只带 Library/pak）下
//     原样可用——开发期与打包期加载代码完全相同。
//
// Jai 移植差异（对 olib）：
//   - olib 的 Texture 资产可上 GPU（foster.Texture）；本移植不依赖任何图形
//     框架（含 raylib）：.Texture 始终保留 CPU 端 Image（RGBA8 像素），
//     GPU 上传是调用方的职责——为 SDL2 迁移铺路。
//   - Guid 为 struct 而非 distinct；Table 键经 guid_hash32/guid_equals 传入。
//   - guid_generate 无 pid 参与（Jai 无可移植 pid API），以单调计数器 +
//     墙钟 + splitmix64 混合，进程内唯一性由 128-bit 空间保证。

#import "Basic";

Hash :: #import "Hash";

HA :: #import "handle/handle_array/handle_array";

// ===========================================================================
// Guid —— 资产身份
// ===========================================================================

// 128-bit 资产身份。属于源资产（存放在 .meta 里），与路径解耦：
// 移动/重命名文件只要 .meta 跟着走，所有 GUID 引用不断。
Guid :: struct {
    bytes: [16] u8;
}

operator == :: (a: Guid, b: Guid) -> bool {
    for 0..15 {
        if a.bytes[it] != b.bytes[it] return false;
    }
    return true;
}

operator != :: (a: Guid, b: Guid) -> bool {
    return !(a == b);
}

GUID_NONE :: Guid.{};

guid_hash32 :: (g: Guid) -> u32 {
    return cast,trunc(u32) Hash.fnv1a_hash(*g.bytes[0], 16);
}

guid_equals :: (a: Guid, b: Guid) -> bool {
    return a == b;
}

// Raw [16]u8 comparison (Jai arrays have no operator ==).
guid_bytes_equal :: (a: [16]u8, b: [16]u8) -> bool {
    return memcmp(*a, *b, 16) == 0;
}

// 进程内计数器 + 墙钟混合熵；128-bit 随机空间下碰撞概率可忽略。
// 不做"撞表重生"：库层没有全局表，冲突由 import_all 扫描 .meta 时以
// Duplicate_Guid 显式报错（静默换 GUID 会破坏既有引用）。
guid_counter: u64 = 0x51ED270B4C9D3F1A;

splitmix64 :: (s: *u64) -> u64 {
    <<s += 0x9E3779B97F4A7C15;
    z := <<s;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

guid_generate :: () -> Guid {
    guid_counter += 0x9E3779B97F4A7C15;

    wall := current_time_consensus();
    wall_nanos, _ := to_nanoseconds(wall);
    wall_u64 := cast(u64) wall_nanos;
    s := wall_u64 ^ guid_counter;

    out: Guid;
    for w: 0..1 {
        v := splitmix64(*s);
        for b: 0..7 {
            out.bytes[w * 8 + b] = cast,trunc(u8) (v >> (8 * b));
        }
    }
    return out;
}

// 32 位小写 hex（分配于 context allocator，调用方负责释放）。
guid_to_string :: (g: Guid) -> string {
    buf: [32]u8;
    guid_hex_into(g, u8_view(cast(*u8) *buf, 32));
    view: string;
    view.data  = cast(*u8) *buf;
    view.count = 32;
    return copy_string(view);
}

// 解析 32 位 hex（大小写均可，容忍 '-' 分隔）。失败返回 (GUID_NONE, false)。
guid_from_string :: (s: string) -> (Guid, bool) {
    out: Guid;
    n := 0;
    for s {
        c := it;
        if c == "-"[0] continue;
        v: u8;
        if c >= "0"[0] && c <= "9"[0] {
            v = c - "0"[0];
        } else if c >= "a"[0] && c <= "f"[0] {
            v = c - "a"[0] + 10;
        } else if c >= "A"[0] && c <= "F"[0] {
            v = c - "A"[0] + 10;
        } else {
            return GUID_NONE, false;
        }
        if n >= 32 return GUID_NONE, false;
        if n % 2 == 0 {
            out.bytes[n / 2] = v << 4;
        } else {
            out.bytes[n / 2] |= v;
        }
        n += 1;
    }
    if n != 32 return GUID_NONE, false;
    return out, true;
}

// 把 guid 写成 32 字符小写 hex 到 dst（不分配；dst 需 >= 32 字节）。
guid_hex_into :: (g: Guid, dst: []u8) {
    for 0..15 {
        hi := g.bytes[it] >> 4;
        lo := g.bytes[it] & 0xF;
        if hi < 10 { dst[it * 2 + 0] = "0"[0] + hi; } else { dst[it * 2 + 0] = "a"[0] + hi - 10; }
        if lo < 10 { dst[it * 2 + 1] = "0"[0] + lo; } else { dst[it * 2 + 1] = "a"[0] + lo - 10; }
    }
}

// Library 内的 blob 文件名（"<32hex>.blob"）。写入调用方的栈缓冲并返回视图，
// 视图只在缓冲存活期间有效——用于免分配地构造后端读取路径。
guid_filename :: (g: Guid, dst: []u8) -> (name: string, ok: bool) {
    if dst.count < 37 return "", false;
    guid_hex_into(g, dst); // 只写前 32 字节
    dst[32] = "."[0]; dst[33] = "b"[0]; dst[34] = "l"[0]; dst[35] = "o"[0]; dst[36] = "b"[0];
    name: string;
    name.data  = dst.data;
    name.count = 37;
    return name, true;
}

// ===========================================================================
// 句柄 / 错误 / 种类
// ===========================================================================

// blob payload 的运行时形态（决定 loader 建什么对象）。
Asset_Kind :: enum u8 {
    Raw;     // 原样字节：shader blob / .cache / .field 等自定义二进制
    Texture; // 解码后的 RGBA8 像素
    Json;    // utf8 JSON 文本
}

Asset_Error :: enum {
    None;
    File_Not_Found;  // Library 里没有该 guid 的 blob
    Meta_Missing;    // 源文件旁没有 .meta（先跑 import_all）
    Parse_Error;     // blob/JSON/.meta 内容不合法，或 blob 内 guid 与请求不符
    Write_Error;     // blob/.meta 写盘失败
    Import_Failed;   // 导入器无法处理该源文件
    Kind_Mismatch;   // 用 Texture 的 getter 取 Json 资产之类
    Duplicate_Guid;  // 两个 .meta 持有同一 GUID（人为复制 .meta 所致，需手动处理）
    Not_Supported;   // 未配置 assets_root 却调用 assets_load_path 等
}

// 运行时资产句柄。带代数（HA.Handle），卸载后旧句柄自动失效。
// 不依赖 ECS：任何 struct 里放一个 Asset_Handle 即可引用资产。
Asset_Handle :: HA.Handle;

ASSET_HANDLE_NONE :: Asset_Handle.{};

// ===========================================================================
// Image —— CPU 端 RGBA8 位图（替代 olib 的 foster.Image/foster.Texture）
// ===========================================================================

Image :: struct {
    width:  int;
    height: int;
    pixels: []u8; // width*height*4 字节 RGBA8
}

// ===========================================================================
// Asset_Manager —— 运行时加载与缓存
// ===========================================================================

// 一条已加载资产。payload 按 kind 有效，其余字段为零值。
Asset_Record :: struct {
    guid:      Guid;
    kind:      Asset_Kind;
    allocator: Allocator; // 载荷分配器（卸载时释放用）

    image:  Image;          // .Texture：CPU 端 RGBA8 像素
    json:   enc.Json_Value; // .Json
    bytes:  []u8;           // .Raw
}

// assets_init 的缺省 Library 根（config.library_root 留空时使用）。
DEFAULT_LIBRARY_ROOT :: "Library";

Asset_Manager_Config :: struct {
    // 源根目录。只影响 assets_load_path（去源文件旁读 .meta）；纯 guid 加载不需要。
    assets_root: string;

    // Library 根目录。留空 = DEFAULT_LIBRARY_ROOT；
    // storage 显式指定时本字段不参与后端构造。
    library_root: string;

    // 可选覆盖存储后端（.read != null 时生效），例如测试/内嵌用 storage_map。
    storage: Asset_Storage;

    // 载荷分配器；留零值 = context.allocator。
    allocator: Allocator;
}

Asset_Manager :: struct {
    records: HA.Pool(Asset_Record, Asset_Handle);
    by_guid: Table(Guid, Asset_Handle, guid_hash32, guid_equals);

    storage:         Asset_Storage;
    directory_state: Directory_State; // 默认后端的状态
    map_state:       Map_State;

    manifest:        Table(string, Guid); // path -> guid（manifest blob 惰性加载）
    manifest_loaded: bool;

    assets_root: string;
    allocator:   Allocator;
}

assets_init :: (m: *Asset_Manager, config: Asset_Manager_Config) -> Asset_Error {
    <<m = .{};

    if config.allocator.proc != null {
        m.allocator = config.allocator;
    } else {
        m.allocator = context.allocator;
    }
    m.assets_root = config.assets_root; // 借用调用方字符串（通常是字面量）

    if config.storage.read != null {
        m.storage = config.storage;
    } else {
        library_root := config.library_root;
        if library_root.count == 0 library_root = DEFAULT_LIBRARY_ROOT;
        storage_directory_init(*m.directory_state, library_root);
        m.storage = storage_directory(*m.directory_state);
    }
    return .None;
}

// 卸载全部资产并释放管理器。终止态调用，之后 manager 不可再用。
assets_dispose :: (m: *Asset_Manager) {
    it := HA.begin(*m.records);
    while true {
        rec, _, ok := HA.next(*it);
        if !ok break;
        destroy_record(rec);
    }
    HA.delete(*m.records);
    deinit(*m.by_guid);
    for m.manifest {
        free(it_index); // 键是克隆的 path 字符串
    }
    deinit(*m.manifest);
    <<m = .{};
}

// 主 API：按 guid 加载（重复加载直接返回缓存句柄）。
assets_load :: (m: *Asset_Manager, guid: Guid) -> (Asset_Handle, Asset_Error) {
    existing, found := table_find(*m.by_guid, guid);
    if found {
        return existing, .None;
    }

    data, loaded := m.storage.read(*m.storage, guid, m.allocator);
    if !loaded return ASSET_HANDLE_NONE, .File_Not_Found;
    defer free_bytes(data, m.allocator);

    header, payload, ok := blob_parse(cast(string) data);
    if !ok return ASSET_HANDLE_NONE, .Parse_Error;
    if !guid_bytes_equal(header.guid, guid.bytes) {
        guid_hex := guid_to_string(guid);
        print("asset: blob guid mismatch (requested %)\n", guid_hex);
        free(guid_hex);
        return ASSET_HANDLE_NONE, .Parse_Error;
    }

    rec: Asset_Record;
    rec.guid      = guid;
    rec.kind      = cast(Asset_Kind) header.kind;
    rec.allocator = m.allocator;

    if rec.kind == {
        case .Texture;
            w, h, _, pixels, pok := blob_texture_parse(payload);
            if !pok return ASSET_HANDLE_NONE, .Parse_Error;

            image: Image;
            image.width  = cast(int) w;
            image.height = cast(int) h;
            image.pixels = alloc_bytes(pixels.count, m.allocator);
            memcpy(image.pixels.data, pixels.data, pixels.count);
            rec.image = image; // 见下方 Asset_Record 说明

        case .Json;
            parser: enc.Json_Parser;
            parser.text = payload;
            value, jok := enc.json_parser_parse_value(*parser);
            if !jok return ASSET_HANDLE_NONE, .Parse_Error;
            rec.json = value;

        case .Raw;
            bytes := alloc_bytes(payload.count, m.allocator);
            memcpy(bytes.data, payload.data, payload.count);
            rec.bytes = bytes;
    }

    handle := HA.add(*m.records, rec);
    table_add(*m.by_guid, guid, handle);
    return handle, .None;
}

// 便捷 API：按源相对路径加载。先查 Library 的 manifest blob（打包形态：
// 只发行 Library/pak 也走这条路），查不到再回退读源文件旁的 .meta（开发期
// 新丢进来还没导入的文件）。两条路收敛到同一 guid——开发期与打包期
// 用的是完全相同的代码。
assets_load_path :: (m: *Asset_Manager, rel_path: string) -> (Asset_Handle, Asset_Error) {
    if !m.manifest_loaded {
        m.manifest_loaded = true;
        manifest_load(m);
    }
    guid, known := table_find(*m.manifest, rel_path);
    if known {
        h, err := assets_load(m, guid);
        return h, err;
    }

    if m.assets_root.count == 0 return ASSET_HANDLE_NONE, .Not_Supported;

    meta_guid, merr := meta_read(m.assets_root, rel_path);
    if merr != .None return ASSET_HANDLE_NONE, merr;
    h, lerr := assets_load(m, meta_guid);
    return h, lerr;
}

// 卸载单个资产（CPU 像素/JSON 树/字节随记录一起释放）。
assets_unload :: (m: *Asset_Manager, handle: Asset_Handle) {
    rec := HA.get(m.records, handle);
    if rec == null return;
    table_remove(*m.by_guid, rec.guid);
    HA.remove_handle(*m.records, handle, destroy_record);
}

// ---- 类型化获取（kind 不匹配返回零值，便于调用方写防御代码） ----

// .Texture 资产的 CPU 端 RGBA8 像素（olib 在 device==nil 时的形态；本移植
// 的唯一形态——GPU 上传由调用方负责）。
assets_get_image :: (m: *Asset_Manager, handle: Asset_Handle) -> *Image {
    rec := HA.get(m.records, handle);
    if rec == null return null;
    if rec.kind != .Texture return null;
    return *rec.image;
}

assets_get_json :: (m: *Asset_Manager, handle: Asset_Handle) -> *enc.Json_Value {
    rec := HA.get(m.records, handle);
    if rec == null return null;
    if rec.kind != .Json return null;
    return *rec.json;
}

assets_get_bytes :: (m: *Asset_Manager, handle: Asset_Handle) -> []u8 {
    rec := HA.get(m.records, handle);
    if rec == null return .[];
    if rec.kind != .Raw return .[];
    return rec.bytes;
}

assets_kind :: (m: *Asset_Manager, handle: Asset_Handle) -> (Asset_Kind, bool) {
    rec := HA.get(m.records, handle);
    if rec == null return .Raw, false;
    return rec.kind, true;
}

assets_guid :: (m: *Asset_Manager, handle: Asset_Handle) -> Guid {
    rec := HA.get(m.records, handle);
    if rec == null return GUID_NONE;
    return rec.guid;
}

assets_valid :: (m: *Asset_Manager, handle: Asset_Handle) -> bool {
    return HA.valid(m.records, handle);
}

assets_len :: (m: *Asset_Manager) -> int {
    return m.records.num;
}

// ---- 内部 ----

destroy_record :: (rec: *Asset_Record) {
    if rec.kind == {
        case .Texture;
            if rec.image.width > 0 {
                free_bytes(rec.image.pixels, rec.allocator);
            }
        case .Json;
            enc.json_destroy_value(rec.json);
        case .Raw;
            if rec.bytes.count > 0 free_bytes(rec.bytes, rec.allocator);
    }
    <<rec = .{};
}
