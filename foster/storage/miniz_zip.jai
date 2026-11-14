using Basic;
using Math;

// Zip archive reading through the vendored miniz amalgamation
// (internal/third_party/miniz), compiled to miniz_impl.dll via build.bat.

// foreign decls are exported for the Zip storage container

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

mz_zip_reader_init_file :: (pZip: *Zip_Archive, pFilename: *u8, flags: mz_uint) -> bool #foreign miniz_impl;
mz_zip_reader_end :: (pZip: *Zip_Archive) -> bool #foreign miniz_impl;
mz_zip_reader_get_num_files :: (pZip: *Zip_Archive) -> mz_uint #foreign miniz_impl;
mz_zip_reader_is_file_a_directory :: (pZip: *Zip_Archive, file_index: mz_uint) -> bool #foreign miniz_impl;
mz_zip_reader_file_stat :: (pZip: *Zip_Archive, file_index: mz_uint, pStat: *MZ_ZIP_ARCHIVE_FILE_STAT) -> bool #foreign miniz_impl;
mz_zip_reader_locate_file :: (pZip: *Zip_Archive, pName: *u8, pComment: *u8, flags: mz_uint) -> s32 #foreign miniz_impl;
mz_zip_reader_extract_to_heap :: (pZip: *Zip_Archive, file_index: mz_uint, pSize: *s64, flags: mz_uint) -> *void #foreign miniz_impl;
mz_free :: (p: *void) #foreign miniz_impl;
jf_mz_zip_archive_size :: () -> s64 #foreign miniz_impl;
jf_mz_stat_size :: () -> s64 #foreign miniz_impl;

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

zip_open_archive :: (path: string) -> *Zip_Archive {
    size := jf_mz_zip_archive_size();
    archive := cast(*Zip_Archive) alloc(size);
    // miniz 会读 m_zip_mode / 内部指针做状态判断，未零化的堆块会让 mz_zip_reader_init_file 随机失败。
    memset(archive, 0, size);
    cpath := to_cstr(path);
    ok := mz_zip_reader_init_file(archive, cpath, 0);
    free(cpath);
    if !ok {
        free(archive);
        return null;
    }
    return archive;
}

zip_close_archive :: (archive: *Zip_Archive) {
    mz_zip_reader_end(archive);
    free(archive);
}

zip_num_files :: (archive: *Zip_Archive) -> u32 {
    return mz_zip_reader_get_num_files(archive);
}

zip_has_file :: (archive: *Zip_Archive, path: string) -> bool {
    cpath := to_cstr(path);
    idx := mz_zip_reader_locate_file(archive, cpath, null, 0);
    free(cpath);
    return idx >= 0;
}

zip_read_file :: (archive: *Zip_Archive, path: string) -> [] u8 {
    cpath := to_cstr(path);
    idx := mz_zip_reader_locate_file(archive, cpath, null, 0);
    free(cpath);
    if idx < 0 return .[];

    size: s64 = 0;
    data := mz_zip_reader_extract_to_heap(archive, cast(u32) idx, *size, 0);
    if data == null return .[];

    out: [] u8 = .{ data = cast(*u8) alloc(size), count = size };
    if size > 0 memcpy(out.data, data, size);
    mz_free(data);
    return out;
}

zip_list_files :: (archive: *Zip_Archive, dir_prefix: string) -> [] string {
    results: [..] string;
    count := zip_num_files(archive);
    prefix := dir_prefix;

    // allocate the stat buffer on the heap with the C-side size; the Jai
    // struct decl mirrors the field order but the exact C layout is the
    // authority (a size mismatch on the stack corrupted the loop state)
    stat_size := jf_mz_stat_size();
    stat := cast(*MZ_ZIP_ARCHIVE_FILE_STAT) alloc(stat_size);
    defer free(stat);

    for i: 0..(cast(s64) count) - 1 {
        if !mz_zip_reader_file_stat(archive, cast(u32) i, stat) continue;
        if stat.m_is_directory continue;

        // cstr_to_string views the shared stat buffer — copy before storing
        name := copy_string(cstr_to_string(cast(*u8) stat.m_filename.data));

        if prefix != "" {
            if name.count < prefix.count continue;
            if sub_string(name, 0, cast(s32) prefix.count) != prefix continue;
            name = sub_string(name, cast(s32) prefix.count + 1, cast(s32) name.count);
        }

        array_add(*results, name);
    }
    return results;
}
