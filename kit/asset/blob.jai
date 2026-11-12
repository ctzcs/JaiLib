// blob 是 Importer 与 Runtime 的边界格式（对位 olib kit/asset/blob.odin）：
//
//   assets/ 的源文件 --(Importer)--> library/assets/<guid>.blob --(Runtime Loader)--> 游戏对象
//
// Importer 认识 png/qoi/json 等源格式并产出 blob；Runtime 只认识 blob，
// 完全不知道源文件的存在。将来的 pak 只是把 "按 guid 读一个 blob" 换成
// "按 pak 索引读一段偏移"，本格式不需要变化。
//
// 数值一律小端（v1 与宿主一致，x86/ARM 原生目标均为 LE）。
//
// Jai 侧差异（字节布局逐字段不变，56 字节 / 12 字节，见文件尾的 #assert）：
//   | olib (Odin)                              | 这里 (Jai)                                        |
//   | ---------------------------------------- | ------------------------------------------------- |
//   | struct #packed { ... }                   | Jai 的结构体默认就是紧密布局，去掉 #packed，     |
//   |                                          | 用 #assert(size_of(...) == 56) 钉住布局           |
//   | BLOB_MAGIC :: [8]u8{'O', ...}            | BLOB_MAGIC :: u8.[#char "O", ...]（Jai 的元素前缀 |
//   |                                          | 只能写内建元素类型，不能写别名 Guid.[...]）      |
//   | BLOB_VERSION :: u32(1)                   | BLOB_VERSION : u32 : 1;（带类型的常量）          |
//   | h^ = Blob_Header{...}                    | h.* = Blob_Header.{...}                           |
//   | (^Blob_Header)(&data[0])                 | cast(*Blob_Header) data.data                      |
//   | data[size_of(Blob_Header):end]           | blob_view(data, start, end)（Jai 没有切片语法）  |
//   | h.magic != BLOB_MAGIC（数组比较）        | !asset_bytes_equal(h.magic, BLOB_MAGIC)（Jai 的  |
//   |                                          | 数组不能用 ==，见 asset.jai 的差异表）           |
//   | make([]u8, n, allocator)                 | asset_alloc_bytes(n, allocator)（asset.jai）     |

//@region 常量与布局

BLOB_MAGIC :: u8.[ #char "O", #char "L", #char "A", #char "S", #char "B", #char "L", #char "O", #char "B" ];

// blob 格式版本（header 布局变化时 +1；v1 读取端精确匹配）。
BLOB_VERSION : u32 : 1;

// Texture payload 的像素格式编号（v1 只有 RGBA8 一种）。
TEXTURE_FORMAT_RGBA8 : u32 : 0;

// blob 头：importer_version 用于缓存失效——即使源文件 mtime/size 都没变，
// 只要导入逻辑升级（版本号变化），旧 blob 也会被判定过期而重新导入。
Blob_Header :: struct {
    magic:            [8] u8;
    version:          u32;
    importer_version: u32;
    kind:             u8;      // Asset_Kind 的底层值
    _pad:             [3] u8;
    guid:             [16] u8;
    payload_len:      u32;
    src_mtime:        s64;     // 源文件 mtime（unix 纳秒），仅作新鲜度比对
    src_size:         s64;     // 源文件字节数，仅作新鲜度比对
}

// Texture payload 的迷你头，其后紧跟 width*height*4 字节 RGBA8 像素。
// Json / Raw 的 payload 没有迷你头（utf8 / 原样字节）。
Blob_Texture_Header :: struct {
    width:  u32;
    height: u32;
    format: u32;
}

// 与 olib 的 #packed 布局一致：8+4+4+1+3+16+4+8+8 = 56，迷你头 4+4+4 = 12。
#assert(size_of(Blob_Header) == 56);
#assert(size_of(Blob_Texture_Header) == 12);
//@endregion

//@region 组装 / 解析

// 组装一个完整 blob（header + payload 一次性分配）。
// payload 生命周期归调用方；返回的 buf 用 allocator 释放。
blob_build :: (
    guid:             Guid,
    kind:             Asset_Kind,
    importer_version: u32,
    src_mtime:        s64,
    src_size:         s64,
    payload:          [] u8,
    allocator := context.allocator,
) -> (buf: [] u8, ok: bool) {
    total := size_of(Blob_Header) + payload.count;
    data, allocated := asset_alloc_bytes(total, allocator);
    if !allocated return .[], false;

    // olib: h := (^Blob_Header)(&data[0]); h^ = Blob_Header{...}
    // 结构体字面量会把 _pad 一并清零（olib 的 Odin 字面量同样如此）。
    h := cast(*Blob_Header) data.data;
    h.* = Blob_Header.{
        magic            = BLOB_MAGIC,
        version          = BLOB_VERSION,
        importer_version = importer_version,
        kind             = cast(u8) kind,
        guid             = guid,
        payload_len      = cast(u32) payload.count,
        src_mtime        = src_mtime,
        src_size         = src_size,
    };
    if payload.count > 0 {
        memcpy(data.data + size_of(Blob_Header), payload.data, payload.count);
    }
    return data, true;
}

// 解析校验 blob：返回指向 data 内部的 header 与 payload 切片（零拷贝）。
// magic / version / payload_len 任一不符都判失败。
blob_parse :: (data: [] u8) -> (header: *Blob_Header, payload: [] u8, ok: bool) {
    if data.count < size_of(Blob_Header) return null, .[], false;
    h := cast(*Blob_Header) data.data;
    if !asset_bytes_equal(h.magic, BLOB_MAGIC) return null, .[], false;
    if h.version != BLOB_VERSION return null, .[], false;
    end := size_of(Blob_Header) + cast(int) h.payload_len;
    if end > data.count return null, .[], false;
    return h, blob_view(data, size_of(Blob_Header), end), true;
}

// Texture 专用：把 Importer 产出的像素（builder.data）打包成带迷你头的 payload。
blob_payload_texture :: (builder: *Payload_Builder, allocator := context.allocator) -> (payload: [] u8, ok: bool) {
    body := size_of(Blob_Texture_Header) + builder.data.count;
    data, allocated := asset_alloc_bytes(body, allocator);
    if !allocated return .[], false;

    th := cast(*Blob_Texture_Header) data.data;
    th.* = Blob_Texture_Header.{
        width  = builder.width,
        height = builder.height,
        format = builder.format,
    };
    if builder.data.count > 0 {
        memcpy(data.data + size_of(Blob_Texture_Header), builder.data.data, builder.data.count);
    }
    return data, true;
}

// Texture 专用：从 payload 拆出像素切片（视图，指向 payload 内部，不拷贝）。
blob_texture_parse :: (payload: [] u8) -> (w: u32, h: u32, format: u32, pixels: [] u8, ok: bool) {
    if payload.count < size_of(Blob_Texture_Header) return 0, 0, 0, .[], false;
    th := cast(*Blob_Texture_Header) payload.data;
    if th.width == 0 || th.height == 0 return 0, 0, 0, .[], false;
    pixels = blob_view(payload, size_of(Blob_Texture_Header), payload.count);
    if pixels.count != cast(int) th.width * cast(int) th.height * 4 return 0, 0, 0, .[], false;
    return th.width, th.height, th.format, pixels, true;
}
//@endregion

//@region 内部

// olib 的 data[start:end]（Jai 没有切片语法，一律显式建视图，不拷贝）。
blob_view :: (data: [] u8, start: int, end: int) -> [] u8 {
    if end <= start return .[];
    return .{ data = data.data + start, count = end - start };
}
//@endregion
