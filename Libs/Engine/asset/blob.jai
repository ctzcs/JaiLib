// blob.jai
// Port of olib engine/asset/blob.odin.
//
// blob 是 Importer 与 Runtime 的边界格式：
//   Assets/ 源文件 --(Importer)--> Library/<guid>.blob --(Runtime Loader)--> 游戏对象
// Importer 认识 png/qoi/json 等源格式并产出 blob；Runtime 只认识 blob，
// 完全不知道源文件的存在。将来的 pak 只是把 "按 guid 读一个 blob" 换成
// "按 pak 索引读一段偏移"，本格式不需要变化。
//
// 数值一律小端（v1 与宿主一致，x86/ARM 原生目标均为 LE）。

BLOB_MAGIC :: "OLASBLOB"; // 8 bytes

// blob 格式版本（header 布局变化时 +1；v1 读取端精确匹配）。
BLOB_VERSION :: 1;

// Texture payload 的像素格式编号（v1 只有 RGBA8 一种）。
TEXTURE_FORMAT_RGBA8 :: 0;

// blob 头：importer_version 用于缓存失效——即使源文件 mtime/size 都没变，
// 只要导入逻辑升级（版本号变化），旧 blob 也会被判定过期而重新导入。
Blob_Header :: struct {
    magic:            [8] u8;
    version:          u32;
    importer_version: u32;
    kind:             u8;  // Asset_Kind 的底层值
    _pad:             [3] u8;
    guid:             [16] u8;
    payload_len:      u32;
    src_mtime:        s64; // 源文件 mtime（unix 纳秒），仅作新鲜度比对
    src_size:         s64; // 源文件字节数，仅作新鲜度比对
} #no_padding;

// Texture payload 的迷你头，其后紧跟 width*height*4 字节 RGBA8 像素。
// Json / Raw 的 payload 没有迷你头（utf8 / 原样字节）。
Blob_Texture_Header :: struct {
    width:  u32;
    height: u32;
    format: u32;
} #no_padding;

// 组装一个完整 blob（header + payload 一次性分配，context allocator）。
// 返回的 string 只是字节缓冲；调用方用 free 释放。
blob_build :: (guid: Guid, kind: Asset_Kind, importer_version: u32, src_mtime: s64, src_size: s64, payload: []u8) -> (string, bool) {
    total := size_of(Blob_Header) + payload.count;
    data: string;
    data.data  = cast(*u8) alloc(total);
    data.count = total;

    h := cast(*Blob_Header) data.data;
    <<h = Blob_Header.{};
    memcpy(*h.magic, BLOB_MAGIC.data, 8);
    h.version          = BLOB_VERSION;
    h.importer_version = importer_version;
    h.kind             = cast(u8) kind;
    h.guid             = guid.bytes;
    h.payload_len      = cast(u32) payload.count;
    h.src_mtime        = src_mtime;
    h.src_size         = src_size;
    memcpy(data.data + size_of(Blob_Header), payload.data, payload.count);
    return data, true;
}

// 解析校验 blob：返回指向 data 内部的 header 与 payload 切片（零拷贝）。
// magic / version / payload_len 任一不符都判失败。
blob_parse :: (data: string) -> (*Blob_Header, string, bool) {
    if data.count < size_of(Blob_Header) return null, "", false;
    h := cast(*Blob_Header) data.data;
    for 0..7 {
        if h.magic[it] != BLOB_MAGIC[it] return null, "", false;
    }
    if h.version != BLOB_VERSION return null, "", false;
    if size_of(Blob_Header) + cast(int) h.payload_len > data.count return null, "", false;
    return h, slice(data, size_of(Blob_Header), cast(int) h.payload_len), true;
}

// Texture 专用：把 Importer 产出的像素（builder.data）打包成带迷你头的 payload。
blob_payload_texture :: (builder: *Payload_Builder) -> (string, bool) {
    body := size_of(Blob_Texture_Header) + builder.data.count;
    data: string;
    data.data  = cast(*u8) alloc(body);
    data.count = body;
    th := cast(*Blob_Texture_Header) data.data;
    <<th = Blob_Texture_Header.{
        width  = builder.width,
        height = builder.height,
        format = builder.format,
    };
    memcpy(data.data + size_of(Blob_Texture_Header), builder.data.data, builder.data.count);
    return data, true;
}

// Texture 专用：从 payload 拆出像素切片（视图，指向 payload 内部，不拷贝）。
blob_texture_parse :: (payload: string) -> (w: u32, h: u32, format: u32, pixels: []u8, ok: bool) {
    if payload.count < size_of(Blob_Texture_Header) return 0, 0, 0, .[], false;
    th := cast(*Blob_Texture_Header) payload.data;
    if th.width == 0 || th.height == 0 return 0, 0, 0, .[], false;
    pixels: []u8;
    pixels.data  = payload.data + size_of(Blob_Texture_Header);
    pixels.count = payload.count - size_of(Blob_Texture_Header);
    if pixels.count != cast(int) th.width * cast(int) th.height * 4 return 0, 0, 0, .[], false;
    return th.width, th.height, th.format, pixels, true;
}
