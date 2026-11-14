// asset —— Foster 资源管线 v1（对位 olib kit/asset/asset.odin）。
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
// 典型用法（开发期，编辑器/工具侧每次启动时）：
//
//   stats, err := import_all("Assets", "Library");
//
// 游戏侧（startup 一次，update/render 里用句柄取对象；开发/打包同一段代码）：
//
//   m: Asset_Manager;
//   assets_init(*m, Asset_Manager_Config.{
//       assets_root  = "Assets",            // assets_load_path 的 .meta 回退用；
//       library_root = "Library",           //   打包发行时可为 ""（纯 manifest）
//       device       = *app.Graphics_Device, // 传了则贴图自动上 GPU
//   });
//   defer assets_dispose(*m);
//   tex, err := assets_load_path(*m, "textures/belt.png");
//   // render: r2d.texture(&renderer, assets_get_texture(*m, tex), transform)
//
// 构建（native；本包 v1 仅支持 native 目标，扫描/mtime 依赖文件系统）：
//   jaic -import_dir <jfoster 父目录> -import_dir <本仓库> <app>.jai
//
// Jai 侧差异（公开名、参数顺序、返回语义、字节布局与 JSON 字段名不变，逐条对位）：
//
//   | olib (Odin)                                   | 这里 (Jai)                                              |
//   | --------------------------------------------- | ------------------------------------------------------- |
//   | Guid :: distinct [16]u8                       | Guid :: [16] u8（同一块 16 字节；Jai 没有 distinct，     |
//   |                                               | 用类型别名 + 具名比较保语义）                           |
//   | GUID_NONE :: Guid{}（常量）                    | GUID_NONE :: u8.[0 × 16]（Jai 的定长数组没有零值字面量， |
//   |                                               | 用元素前缀 u8 的数组字面量写满 16 个 0）                |
//   | g1 == g2 / g1 != g2（Guid）                    | guid_equal(a, b)（Jai 的数组不支持 ==；Table 的键比较    |
//   |                                               | 也因此要显式传 compare，见 guid_hash / guid_equal）     |
//   | (cast([16]u8)g)[i]                            | g[i]（本身就是字节数组，不需要 cast）                    |
//   | s[i:j]（切片）                                 | asset_view / blob_view（Jai 没有切片语法）              |
//   | mem.Allocator                                 | Allocator（Basic）                                      |
//   | delete(ptr, allocator) / delete(s, allocator)  | asset_free_bytes / KS.storage_free（jacket 的 free      |
//   |                                               | 只认当前 context.allocator，故显式走传入的那个）        |
//   | make([]u8, n, allocator)                      | asset_alloc_bytes(n, allocator)（push_allocator + alloc）|
//   | strings.clone(s, allocator)                   | asset_clone_string(s, allocator)                        |
//   | strings.join({a, b}, "", alloc)               | asset_concat(a, b, alloc)（Jai 没有零长分隔的 join）    |
//   | map[Guid]Asset_Handle                         | Table(Guid, Asset_Handle, guid_hash, guid_equal)        |
//   | map[string]Guid                               | Table(string, Guid)（字符串键用默认 hash / compare）    |
//   | if existing, ok := m.by_guid[guid]; ok        | found, existing := table_find(*m.by_guid, guid)（jacket |
//   |                                               | 的 table_find 返回 (found, value)，注意顺序）           |
//   | delete_key(&m.by_guid, guid)                  | table_remove(*m.by_guid, guid)                          |
//   | ha.Pool / ha.Handle（core/handle/array）      | HA.HANDLE_ARRAY.Pool / 同形 Handle 结构体（字段 idx/gen，|
//   |                                               | 与 handle/array.Handle 一致，池可直接用）               |
//   | ha.add 返回 (Handle, err)                      | 返回 (Handle, bool)，false 对应 olib 的 err != nil      |
//   | ha.remove(ha, h, destroy)                     | HA.HANDLE_ARRAY.remove_handle（remove 是 Jai 关键字）   |
//   | ha.begin / ha.next 的 `for it := …; v, _ in …` | `it := begin(…); while true { v, _, ok := next(*it); … }`|
//   | ha.delete(ha, destroy)                        | HA.HANDLE_ARRAY.delete(*pool, destroy_record)           |
//   | foster.Image{Width, Height, Pixels}           | F.Image{Width, Height, Data}（jfoster 的字段名）        |
//   | foster.Texture（值类型 + .Resource）           | *F.Texture（jfoster 的贴图是 texture_create 里 New 出来 |
//   |                                               | 的堆对象，dispose 只还 GPU 资源，指针要自己还）          |
//   | foster.TextureFromImage(dev, &img, "")        | F.texture_create_from_colors(dev, w, h, img.Data)       |
//   | foster.TextureDispose(&tex)                   | F.texture_dispose(tex) + 按 rec.allocator 还结构体      |
//   | &rec.image（取地址返回）                        | `return *rec.image;`（Jai 的取地址就是 `*`，没有 `&`）  |
//   | json.Value / json.parse(parse_integers=true)  | ENC.Json_Value / ENC.json_parse（本仓库的解析器默认就   |
//   |                                               | 区分 .Integer 与 .Float，故没有 parse_integers 形参）   |
//   | json.destroy_value(v, allocator)              | ENC.json_destroy_value(v)（无 allocator 形参：内部一律 |
//   |                                               | 用当前 context.allocator，故解析时也用 context）        |
//   | fmt.eprintf(...)                              | print(...)（Basic 没有独立的 stderr 通道）              |
//   | os.get_pid()                                  | asset_process_id()（Win32 GetCurrentProcessId；非      |
//   |                                               | Windows 返回 0——只影响熵，见文件尾）                    |
//   | time.time_to_unix_nano(time.now())            | asset_now_unix_nano()（Apollo_Time - 1970 偏移）        |
//   | @(private)                                    | 无文件级私有：内部过程一律加 asset_ / guid_ 前缀        |

//@region Guid —— 资产身份

// 128-bit 资产身份。属于源资产（存放在 .meta 里），与路径解耦：
// 移动/重命名文件只要 .meta 跟着走，所有 GUID 引用不断。
Guid :: [16] u8;

GUID_NONE :: u8.[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

// olib 的 `g1 == g2`：Jai 的数组不支持 ==（hash-table 的键比较也一样），
// 所以本包所有 Guid 比较都走这个具名过程；它是相对 olib 的必要补充。
guid_equal :: (a: Guid, b: Guid) -> bool {
    return asset_bytes_equal(a, b);
}

// Guid 的键哈希（Table 的第三个实参）。FNV-1a over 16 字节：不依赖
// Hash.get_hash 对定长数组的支持，且跨平台结果稳定（manifest 排序不靠它，
// 但 Table 的遍历序稳定与否会体现在 manifest 的 JSON 键序上）。
guid_hash :: (g: Guid) -> u32 {
    h: u32 = 2166136261;
    for 0..15 {
        h = h ^ cast(u32) g[it];
        h = h * 16777619;
    }
    return h;
}

// 进程内计数器 + 墙钟 + pid 混合熵；128-bit 随机空间下碰撞概率可忽略。
// 不做"撞表重生"：库层没有全局表，冲突由 import_all 扫描 .meta 时以
// Duplicate_Guid 显式报错（静默换 GUID 会破坏既有引用）。
guid_counter: u64 = 0x51ED270B4C9D3F1A;

splitmix64 :: (s: *u64) -> u64 {
    s.* += 0x9E3779B97F4A7C15;
    z := s.*;
    // olib 的 `~` 是按位异或；Jai 的 ^ 才是异或（~ 是按位取反），这里换写。
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

guid_generate :: () -> Guid {
    guid_counter += 0x9E3779B97F4A7C15;
    now := cast(u64) asset_now_unix_nano();
    pid_part := asset_process_id() << 32;
    s := now ^ guid_counter ^ pid_part;

    bytes: Guid;
    for i: 0..1 {
        v := splitmix64(*s);
        for j: 0..7 {
            bytes[i * 8 + j] = cast(u8) ((v >> (8 * j)) & 0xFF); // 先掩码再窄化，jacket 的 cast 会做溢出检查
        }
    }
    return bytes;
}

// 32 位小写 hex（分配于 allocator，调用方负责释放）。
guid_to_string :: (g: Guid, allocator := context.allocator) -> string {
    buf: [32] u8;
    guid_hex_into(g, buf);
    return asset_clone_string(cast(string) asset_view(buf, 32), allocator);
}

// 解析 32 位 hex（大小写均可，容忍 '-' 分隔）。失败返回 (GUID_NONE, false)。
guid_from_string :: (s: string) -> (Guid, bool) {
    out: Guid;
    n := 0;
    for c: s {
        if c == #char "-" continue;
        v: u8;
        if c >= #char "0" && c <= #char "9" {
            v = c - #char "0";
        } else if c >= #char "a" && c <= #char "f" {
            v = c - #char "a" + 10;
        } else if c >= #char "A" && c <= #char "F" {
            v = c - #char "A" + 10;
        } else {
            return GUID_NONE, false;
        }
        if n >= 32 return GUID_NONE, false;
        if n % 2 == 0 {
            out[n / 2] = v << 4;
        } else {
            out[n / 2] |= v;
        }
        n += 1;
    }
    if n != 32 return GUID_NONE, false;
    return out, true;
}

// 把 guid 写成 32 字符小写 hex 到 dst（不分配；dst 需 >= 32 字节）。
// olib 的 `hi < 10 ? a : b` 三元：Jai 运行期分支一律 if/else（ifx 只用于编译期）。
guid_hex_into :: (g: Guid, dst: [] u8) {
    for i: 0..15 {
        hi := g[i] >> 4;
        lo := g[i] & 0xF;
        if hi < 10 {
            dst[i * 2 + 0] = #char "0" + hi;
        } else {
            dst[i * 2 + 0] = #char "a" + hi - 10;
        }
        if lo < 10 {
            dst[i * 2 + 1] = #char "0" + lo;
        } else {
            dst[i * 2 + 1] = #char "a" + lo - 10;
        }
    }
}

// Library 内的 blob 文件名（"<32hex>.blob"）。写入调用方的栈缓冲并返回视图，
// 视图只在缓冲存活期间有效——用于免分配地构造后端读取路径。
guid_filename :: (g: Guid, dst: [] u8) -> (name: string, ok: bool) {
    if dst.count < 37 return "", false;
    guid_hex_into(g, dst);
    dst[32] = #char ".";
    dst[33] = #char "b";
    dst[34] = #char "l";
    dst[35] = #char "o";
    dst[36] = #char "b";
    return cast(string) asset_view(dst, 37), true;
}
//@endregion

//@region 句柄 / 错误 / 种类

// blob payload 的运行时形态（决定 loader 建什么对象）。
Asset_Kind :: enum u8 {
    Raw; // 原样字节：shader blob / .cache / .field 等自定义二进制
    Texture; // 解码后的 RGBA8 像素
    Json; // utf8 JSON 文本
}

Asset_Error :: enum u32 {
    None;
    File_Not_Found; // Library 里没有该 guid 的 blob
    Meta_Missing; // 源文件旁没有 .meta（先跑 import_all）
    Parse_Error; // blob/JSON/.meta 内容不合法，或 blob 内 guid 与请求不符
    Write_Error; // blob/.meta 写盘失败
    Import_Failed; // 导入器无法处理该源文件
    Kind_Mismatch; // 用 Texture 的 getter 取 Json 资产之类
    Duplicate_Guid; // 两个 .meta 持有同一 GUID（人为复制 .meta 所致，需手动处理）
    Not_Supported; // 未配置 assets_root 却调用 assets_load_path 等
}

// 运行时资产句柄。带代数，卸载后旧句柄自动失效。
// 不依赖 ECS：任何 struct 里放一个 Asset_Handle 即可引用资产。
// olib 是 `distinct ha.Handle`；Jai 没有 distinct，用字段同形（idx / gen）的独立结构体，
// handle/array 的池按字段访问句柄，所以 HA.HANDLE_ARRAY.Pool(Asset_Record, Asset_Handle) 直接可用。
Asset_Handle :: struct {
    idx: u32;
    gen: u32;
}

// Jai 的运算符按词法作用域解析：本包声明的 operator == 在别的模块（含测试）
// 里不可见，所以对外统一用这个具名比较（同 Kit 其它模块的约定）。
asset_handle_equal :: (a: Asset_Handle, b: Asset_Handle) -> bool {
    return a.idx == b.idx && a.gen == b.gen;
}

ASSET_HANDLE_NONE :: Asset_Handle.{};
//@endregion

//@region Asset_Manager —— 运行时加载与缓存

// 一条已加载资产。payload 按 kind 有效，其余字段为零值。
Asset_Record :: struct {
    guid: Guid;
    kind: Asset_Kind;
    allocator: Allocator; // 载荷分配器（卸载时释放用）

    has_texture: bool; // .Texture：texture 有效（已上 GPU）
    texture: *F.Texture; // .Texture 且 device != null（jfoster 是堆对象）
    image: F.Image; // .Texture 且 device == null（保留 CPU 副本）
    json: ENC.Json_Value; // .Json
    bytes: [] u8; // .Raw
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

    // 传入后 .Texture 资产自动建 GPU Texture；null 则保留 CPU Image。
    device: *F.Graphics_Device;

    // 载荷分配器；留零值 = context.allocator。
    allocator: Allocator;
}

Asset_Manager :: struct {
    records: HA.HANDLE_ARRAY.Pool(Asset_Record, Asset_Handle);
    by_guid: Table(Guid, Asset_Handle, guid_hash, guid_equal);

    storage: Asset_Storage;
    directory_state: Directory_State; // 默认后端的状态
    map_state: Map_State;

    manifest: Table(string, Guid); // path -> guid（manifest blob 惰性加载）
    manifest_loaded: bool;

    assets_root: string;
    device: *F.Graphics_Device;
    allocator: Allocator;
}

assets_init :: (m: *Asset_Manager, config: Asset_Manager_Config) -> Asset_Error {
    m.* = Asset_Manager.{};
    // olib: config.allocator.procedure != nil ? config.allocator : context.allocator
    if config.allocator.proc {
        m.allocator = config.allocator;
    } else {
        m.allocator = context.allocator;
    }
    m.assets_root = config.assets_root; // 借用调用方字符串（通常是字面量）
    m.device = config.device;

    if config.storage.read != null {
        m.storage = config.storage;
    } else {
        library_root := config.library_root;
        if library_root == "" library_root = DEFAULT_LIBRARY_ROOT;
        storage_directory_init(*m.directory_state, library_root);
        m.storage = storage_directory(*m.directory_state);
    }
    return .None;
}

// 卸载全部资产并释放管理器。终止态调用，之后 manager 不可再用。
assets_dispose :: (m: *Asset_Manager) {
    // olib 手写 begin/next 循环；jacket 的 delete 带 destroy 形参，一一等价。
    HA.HANDLE_ARRAY.delete(*m.records, destroy_record);
    deinit(*m.by_guid);
    // 键是克隆的 path 字符串，表 deinit 本身不释放它们（olib 同理）
    for guid, path: m.manifest {
        asset_free_string(path, m.allocator);
    }
    deinit(*m.manifest);
    m.* = Asset_Manager.{};
}

// 主 API：按 guid 加载（重复加载直接返回缓存句柄）。
assets_load :: (m: *Asset_Manager, guid: Guid) -> (Asset_Handle, Asset_Error) {
    found_hit, existing := table_find(*m.by_guid, guid);
    if found_hit return existing, .None;

    data, found := m.storage.read(*m.storage, guid, m.allocator);
    if !found return ASSET_HANDLE_NONE, .File_Not_Found;
    defer asset_free_bytes(data, m.allocator);

    header, payload, ok := blob_parse(data);
    if !ok return ASSET_HANDLE_NONE, .Parse_Error;
    if !guid_equal(header.guid, guid) {
        print("asset: blob guid mismatch (requested %)\n", guid_to_string(guid, temp));
        return ASSET_HANDLE_NONE, .Parse_Error;
    }

    rec: Asset_Record;
    rec.guid = guid;
    rec.kind = cast(Asset_Kind) header.kind;
    rec.allocator = m.allocator;

    if rec.kind == {
        case .Texture;
            w, h, format, pixels, tex_ok := blob_texture_parse(payload);
            if !tex_ok return ASSET_HANDLE_NONE, .Parse_Error;

            pixel_buf, px_ok := asset_alloc_colors(pixels.count / size_of(F.Color), m.allocator);
            if !px_ok return ASSET_HANDLE_NONE, .Import_Failed;
            rec.image.Width = cast(s32) w;
            rec.image.Height = cast(s32) h;
            rec.image.Data = pixel_buf;
            if pixels.count > 0 memcpy(rec.image.Data.data, pixels.data, pixels.count);

            if m.device != null {
                // jfoster 的 Texture 是 texture_create 里 New 出来的堆对象；
                // 这里把"创建期分配器"钉成 rec.allocator，destroy_record 才能配对归还。
                push_allocator(m.allocator);
                tex := F.texture_create_from_colors(m.device, rec.image.Width, rec.image.Height, rec.image.Data);
                if tex == null return ASSET_HANDLE_NONE, .Import_Failed;
                asset_free_bytes(asset_colors_as_bytes(rec.image.Data), m.allocator);
                rec.image = F.Image.{};
                rec.texture = tex;
                rec.has_texture = true;
            }
        case .Json;
            // 解析树用当前 context.allocator：ENC.json_destroy_value 内部一律
            // free/array_free/deinit（只认 context），两边必须是同一个分配器。
            value, jok := ENC.json_parse(cast(string) payload, context.allocator);
            if !jok return ASSET_HANDLE_NONE, .Parse_Error;
            rec.json = value;
        case .Raw;
            bytes, bok := asset_alloc_bytes(payload.count, m.allocator);
            if !bok return ASSET_HANDLE_NONE, .Import_Failed;
            if payload.count > 0 memcpy(bytes.data, payload.data, payload.count);
            rec.bytes = bytes;
    }

    handle, added := HA.HANDLE_ARRAY.add(*m.records, rec);
    if !added return ASSET_HANDLE_NONE, .Import_Failed;
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
    manifest_hit, guid := table_find(*m.manifest, rel_path);
    if manifest_hit {
        return assets_load(m, guid);
    }

    if m.assets_root == "" return ASSET_HANDLE_NONE, .Not_Supported;

    // jfoster 没有 Directory_Storage 类型：容器本身就是 Storage_Container。
    ds: F.Storage_Container;
    ds.Root = m.assets_root;
    ds.Writable = false;
    meta_guid, err := meta_read(*ds, rel_path);
    if err != .None return ASSET_HANDLE_NONE, err;
    return assets_load(m, meta_guid);
}

// 卸载单个资产（GPU 贴图/JSON 树/字节随记录一起释放）。
assets_unload :: (m: *Asset_Manager, handle: Asset_Handle) {
    rec := HA.HANDLE_ARRAY.get(*m.records, handle);
    if rec == null return;
    table_remove(*m.by_guid, rec.guid);
    HA.HANDLE_ARRAY.remove_handle(*m.records, handle, destroy_record);
}

// ---- 类型化获取（kind 不匹配返回零值，便于调用方写防御代码） ----

assets_get_texture :: (m: *Asset_Manager, handle: Asset_Handle) -> *F.Texture {
    rec := HA.HANDLE_ARRAY.get(*m.records, handle);
    if rec == null || rec.kind != .Texture || !rec.has_texture return null;
    return rec.texture;
}

// device == null 时 Texture 资产保留的 CPU 副本（测试/无 GPU 场景）。
assets_get_image :: (m: *Asset_Manager, handle: Asset_Handle) -> *F.Image {
    rec := HA.HANDLE_ARRAY.get(*m.records, handle);
    if rec == null || rec.kind != .Texture || rec.has_texture return null;
    return *rec.image; // Jai 的取地址就是 `*`（没有 & 运算符）
}

assets_get_json :: (m: *Asset_Manager, handle: Asset_Handle) -> *ENC.Json_Value {
    rec := HA.HANDLE_ARRAY.get(*m.records, handle);
    if rec == null || rec.kind != .Json return null;
    return *rec.json;
}

assets_get_bytes :: (m: *Asset_Manager, handle: Asset_Handle) -> [] u8 {
    rec := HA.HANDLE_ARRAY.get(*m.records, handle);
    if rec == null || rec.kind != .Raw return .[];
    return rec.bytes;
}

assets_kind :: (m: *Asset_Manager, handle: Asset_Handle) -> (Asset_Kind, bool) {
    rec := HA.HANDLE_ARRAY.get(*m.records, handle);
    if rec == null return Asset_Kind.{}, false;
    return rec.kind, true;
}

assets_guid :: (m: *Asset_Manager, handle: Asset_Handle) -> Guid {
    rec := HA.HANDLE_ARRAY.get(*m.records, handle);
    if rec == null return GUID_NONE;
    return rec.guid;
}

assets_valid :: (m: *Asset_Manager, handle: Asset_Handle) -> bool {
    return HA.HANDLE_ARRAY.valid(*m.records, handle);
}

assets_len :: (m: *Asset_Manager) -> int {
    return HA.HANDLE_ARRAY.len(*m.records);
}

// ---- 内部 ----

destroy_record :: (rec: *Asset_Record) {
    if rec.kind == {
        case .Texture;
            if rec.has_texture && rec.texture != null {
                F.texture_dispose(rec.texture);
                // 结构体是 texture_create 里 New 出来的：创建期已 push_allocator
                // （见 assets_load），所以按 rec.allocator 配对归还。
                if rec.allocator.proc {
                    rec.allocator.proc(.FREE, 0, 0, rec.texture, rec.allocator.data);
                }
            }
            if rec.image.Data.count > 0 {
                asset_free_bytes(asset_colors_as_bytes(rec.image.Data), rec.allocator);
                rec.image = F.Image.{};
            }
        case .Json;
            if rec.json.kind != .Null ENC.json_destroy_value(rec.json);
        case .Raw;
            if rec.bytes.data != null {
                asset_free_bytes(rec.bytes, rec.allocator);
                rec.bytes = .[];
            }
    }
    rec.* = Asset_Record.{};
}
//@endregion

//@region 内部 —— 字节 / 字符串 / 分配器 / 时间 / 进程（olib 用标准库直接做的事）

// olib 的 `a == b`（定长字节数组）与切片比较：Jai 的数组不支持 ==，逐字节比。
asset_bytes_equal :: (a: [] u8, b: [] u8) -> bool {
    if a.count != b.count return false;
    for 0..a.count - 1 {
        if a[it] != b[it] return false;
    }
    return true;
}

// olib 的 s[0:count]：Jai 没有切片语法，一律显式建视图（不拷贝）。
asset_view :: (data: [] u8, count: int) -> [] u8 {
    if count > data.count count = data.count;
    if count < 0 count = 0;
    return .{ data = data.data, count = count };
}

// olib 的 s[start:end]（不拷贝）。
asset_view_from :: (data: [] u8, start: int, end: int) -> [] u8 {
    if end <= start || start >= data.count return .[];
    if end > data.count end = data.count;
    return .{ data = data.data + start, count = end - start };
}

// olib 的 make([]u8, n, allocator)：push_allocator 是作用域级的，
// 所以这里分配完 context.allocator 自动还原，返回值归 allocator 所有。
asset_alloc_bytes :: (count: int, allocator: Allocator) -> (out: [] u8, ok: bool) {
    if count <= 0 return .[], false;
    if !allocator.proc return .[], false;
    push_allocator(allocator);
    memory := alloc(count);
    if memory == null return .[], false;
    out.data = cast(*u8) memory;
    out.count = count;
    return out, true;
}

// olib 的 make([dynamic]foster.Color, n, allocator)（像素缓冲，按字节分配）。
asset_alloc_colors :: (count: int, allocator: Allocator) -> (out: [] F.Color, ok: bool) {
    bytes, allocated := asset_alloc_bytes(count * size_of(F.Color), allocator);
    if !allocated return .[], false;
    out.data = cast(*F.Color) bytes.data;
    out.count = count;
    return out, true;
}

asset_colors_as_bytes :: (colors: [] F.Color) -> [] u8 {
    return .{ data = cast(*u8) colors.data, count = colors.count * size_of(F.Color) };
}

// olib 的 delete(data, allocator)：jacket 的 free 只认当前 context.allocator，
// 所以显式用传入的那个（与 kit/storage 的 storage_free 同一写法）。
asset_free_bytes :: (data: [] u8, allocator: Allocator) {
    if data.data == null return;
    if !allocator.proc return;
    allocator.proc(.FREE, 0, 0, data.data, allocator.data);
}

asset_free_string :: (s: string, allocator: Allocator) {
    if s.data == null return;
    if !allocator.proc return;
    allocator.proc(.FREE, 0, 0, s.data, allocator.data);
}

// olib 的 strings.clone(s, allocator)：总是新分配，失败返回空字符串。
asset_clone_string :: (s: string, allocator: Allocator) -> string {
    if !s.count return "";
    if !allocator.proc return "";
    push_allocator(allocator);
    return copy_string(s);
}

// olib 的 strings.join({a, b}, "")：零长分隔的拼接（总是新分配）。
// 不能借用 KS.storage_path_join——那个会插 '/'，用在 ".meta" 后缀上会变成 "a.qoi/.meta"。
asset_concat :: (a: string, b: string, allocator := context.allocator) -> string {
    if !allocator.proc return "";
    push_allocator(allocator);
    out := alloc_string(a.count + b.count);
    if !out return "";
    if a.count > 0 memcpy(out.data, a.data, a.count);
    if b.count > 0 memcpy(out.data + a.count, b.data, b.count);
    return out;
}

// 小写含点扩展名（新分配，调用方 free）；无扩展名返回 ""。
asset_path_ext_lower :: (path: string) -> string {
    dot := asset_last_index_of(path, #char ".");
    if dot < 0 return "";
    slash := asset_last_index_of(path, #char "/");
    if slash > dot return ""; // 点在目录名里，不是扩展名
    n := path.count - dot;
    out := alloc_string(n);
    if !out return "";
    for i: 0..n - 1 {
        c := path[dot + i];
        if c >= #char "A" && c <= #char "Z" c = c + 32;
        out[i] = c;
    }
    return out;
}

// 最后一个 c 的下标，没有返回 -1（olib 的 strings.last_index）。
asset_last_index_of :: (s: string, c: u8) -> int {
    i := cast(int) s.count - 1;
    while i >= 0 {
        if s[i] == c return i;
        i -= 1;
    }
    return -1;
}

// olib 的 `a > b`（字符串字典序比较）：Jai 没有字符串序运算符，逐字节比。
asset_string_compare :: (a: string, b: string) -> int {
    n := min(a.count, b.count);
    for 0..n - 1 {
        if a[it] != b[it] {
            if a[it] < b[it] return -1;
            return 1;
        }
    }
    if a.count == b.count return 0;
    if a.count < b.count return -1;
    return 1;
}

// olib 的 `a == b`（字符串）：Jai 没有字符串 ==，逐字节比。
asset_string_equal :: (a: string, b: string) -> bool {
    if a.count != b.count return false;
    for 0..a.count - 1 {
        if a[it] != b[it] return false;
    }
    return true;
}

// olib 的 s[start:end]（字符串视图，不拷贝）。
asset_str_view :: (s: string, start: int, end: int) -> string {
    if end <= start || start >= s.count return "";
    if end > s.count end = s.count;
    return .{ data = s.data + start, count = end - start };
}

asset_starts_with :: (s: string, prefix: string) -> bool {
    if s.count < prefix.count return false;
    return asset_string_equal(asset_str_view(s, 0, prefix.count), prefix);
}

// 小写副本（新分配，调用方 free）；olib 的 strings.to_lower。
asset_lower_copy :: (s: string, allocator := context.allocator) -> string {
    if !s.count return "";
    if !allocator.proc return "";
    push_allocator(allocator);
    out := alloc_string(s.count);
    if !out return "";
    for i: 0..s.count - 1 {
        c := s[i];
        if c >= #char "A" && c <= #char "Z" c = c + 32;
        out[i] = c;
    }
    return out;
}

// olib 的 join_owned：拼接 root/rel，结果总是新分配（context），可安全 free。
// root 为空时退回 rel 的克隆（打包形态 assets_root == ""）。
join_owned :: (root: string, rel: string) -> string {
    if root == "" return copy_string(rel);
    return asset_concat(asset_concat(root, "/"), rel);
}

// olib 的 time.time_to_unix_nano(time.now())（jacket 的时间原点不是 Unix 纪元）。
asset_now_unix_nano :: () -> s64 {
    return asset_apollo_to_unix_nano(current_time_consensus());
}

// Apollo_Time → Unix 纳秒（mtime 与墙钟同一把尺子）。
asset_apollo_to_unix_nano :: (t: Apollo_Time) -> s64 {
    nanoseconds, ok := to_nanoseconds(t);
    if !ok return 0;
    epoch, epoch_ok := to_nanoseconds(APOLLO_TIME_FOR_JAN_1_1970);
    if !epoch_ok return 0;
    return nanoseconds - epoch;
}

// FU.file_modtime_and_size 的对位：olib 的 os.stat 拿 (modification_time, size)。
// 返回 unix 纳秒，与 blob header 里记的同一把尺子（新鲜度只做相等比较）。
asset_file_mtime_size :: (path: string) -> (mtime: s64, size: s64, ok: bool) {
    at, bytes, success := FU.file_modtime_and_size(path);
    if !success return 0, 0, false;
    return asset_apollo_to_unix_nano(at), bytes, true;
}

// olib 的 os.get_pid()：只作熵的第三个来源。
// Win32 GetCurrentProcessId；其它平台返回 0（guid 的唯一性仍由
// guid_counter 的进程内单调 + 墙钟纳秒保证，见 guid_generate）。
asset_process_id :: () -> u64 {
    #if OS == .WINDOWS {
        return cast(u64) asset_get_current_process_id();
    } else {
        return 0;
    }
}

#if OS == .WINDOWS {
    // odin 的 core:sys/windows 现成声明；Jai 侧自备（同 core/hotreload/scan_windows.jai）。
    kernel32_asset :: #library,system "kernel32";
    asset_get_current_process_id :: () -> u32 #foreign kernel32_asset "GetCurrentProcessId";
}
//@endregion
