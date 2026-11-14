using Basic;
using Math;

// Zip 读取 — web (wasm64) 版本。
//
// `storage/miniz_zip.jai` 是 miniz 的 `#foreign miniz_impl` 绑定（预编译的
// miniz_impl.dll/.lib，由 internal/third_party/miniz/build.bat 产出）。native
// 库无法链进 wasm 模块，所以 wasm 目标下整个绑定换成这里。
//
// W1 语义：**没有 zip 后端**。`zip_open_archive` 返回 null，于是
// storage/storage.jai 的 Zip_Storage 与 storage_ext.jai 的 quick-scan 都走它们
// 已有的“打不开”分支（前者返回空数组，后者返回 .INVALID_ARGUMENT /
// .READ_FAILED）。类型别名、`MZ_ZIP_ARCHIVE_FILE_STAT` 和 `jf_mz_stat_size`
// 都保留，因为 storage_ext.jai 会 `alloc(jf_mz_stat_size())` 再 cast 成它。
//
// W2 的做法有两种，都留在 README 的清单里：
//   * 把 miniz 的 amalgamation 用 jaic -os wasm 编成 .o 再链进来；或
//   * 用浏览器原生的 DecompressionStream("deflate-raw")，中央目录解析用纯 Jai
//     写（约 200 行）。

mz_uint :: u32;
mz_uint64 :: u64;
mz_uint16 :: u16;
mz_uint32 :: u32;
mz_int64 :: s64;

MZ_ZIP_FLAG_CASE_SENSITIVE :: 0x0100;

MZ_ZIP_MODE_INVALID :: 0;
MZ_ZIP_MODE_READING :: 1;
MZ_ZIP_MODE_WRITING :: 2;
MZ_ZIP_MODE_WRITING_HAS_BEEN_FINALIZED :: 3;

Zip_Archive :: void;

// 与 storage/miniz_zip.jai 逐字段一致（字段名、类型、顺序都不能改）：
// storage_ext.jai 会按 jf_mz_stat_size() 分配再 cast 成它。
MZ_ZIP_ARCHIVE_FILE_STAT :: struct {
    m_file_index: mz_uint32;
    m_central_dir_ofs: mz_uint64;
    m_version_made_by: mz_uint16;
    m_version_needed: mz_uint16;
    m_bit_flag: mz_uint16;
    m_method: mz_uint16;
    m_crc32: mz_uint32;
    m_comp_size: mz_uint64;
    m_uncomp_size: mz_uint64;
    m_internal_attr: mz_uint16;
    m_external_attr: mz_uint32;
    m_local_header_ofs: mz_uint64;
    m_comment_size: mz_uint32;
    m_is_directory: u32; // mz_bool is a 4-byte int in miniz, NOT 1-byte bool
    m_is_encrypted: u32;
    m_is_supported: u32;
    m_filename: [512] u8;
    m_comment: [512] u8;
    m_time: s64;
}

// storage_ext.jai 按 C 侧 sizeof 分配再 cast；这里没有 C 侧，返回 Jai 侧的
// 字节数 —— alloc 出来的缓冲区一定够大。
jf_mz_stat_size :: () -> s64 {
    return size_of(MZ_ZIP_ARCHIVE_FILE_STAT);
}

// 只在 desktop 的 zip_open_archive 里用于分配归档上下文，web 侧没有意义。
jf_mz_zip_archive_size :: () -> s64 {
    return 0;
}

// 直接调用 miniz 的两处（storage_ext.jai 的 zip_storage_read_all_bytes_result）。
// 永远定位失败 / 统计失败，正好落进它已有的 READ_FAILED 分支。
mz_zip_reader_locate_file :: (pZip: *Zip_Archive, pName: *u8, pComment: *u8, flags: mz_uint) -> s32 {
    return -1;
}

mz_zip_reader_file_stat :: (pZip: *Zip_Archive, file_index: mz_uint, pStat: *MZ_ZIP_ARCHIVE_FILE_STAT) -> bool {
    // 不写 pStat：调用方 inspect 为 false 就直接返回，从不读它。
    return false;
}

mz_free :: (p: *void) {}

zip_open_archive :: (path: string) -> *Zip_Archive {
    log_warning("zip_open_archive: web 目标下没有 zip 后端（miniz 是 native 库），拿不到压缩包内容 —— W2 接上 DecompressionStream 或 wasm 版 miniz");
    return null;
}

zip_close_archive :: (archive: *Zip_Archive) {
    // zip_open_archive 永远返回 null，所以这里没有东西可关。
}

zip_num_files :: (archive: *Zip_Archive) -> u32 {
    return 0;
}

zip_has_file :: (archive: *Zip_Archive, path: string) -> bool {
    return false;
}

zip_read_file :: (archive: *Zip_Archive, path: string) -> [] u8 {
    return .[];
}

zip_list_files :: (archive: *Zip_Archive, dir_prefix: string) -> [] string {
    result: [..] string;
    return result;
}
