#scope_module
using Basic;   // module-private
using Math;
#scope_export

// olib extensions to the Storage layer — NOT part of upstream Foster.
//
// Ported from olib's Odin port (<olib>/foster/olib_storage.odin and the
// Storage / Atomic Write section of <olib>/foster/olib_ext.odin), each block
// carrying its docs/LOCAL_CHANGES.md registration number:
//
//   L-024  Storage_Read_Error + the *_read_all_*_result readers
//   L-015  storage_write_all_bytes_atomic / storage_write_all_text_atomic
//
// Neither block changes the Foster 1:1 port: storage.jai, miniz_zip.jai and
// content_storage.jai keep their existing (silent) readers and writers. These
// are additive entry points, which is what olib did too ("保留旧读取 API").
//
// Container kinds, since jfoster splits them into three types where olib folds
// everything into one StorageContainer:
//   *Storage_Container  plain OS directory (storage.jai)          -> file backend
//   *Zip_Storage        read-only zip via miniz (storage.jai)     -> zip backend
//   *Content_Storage    SDL_Storage (content_storage.jai)         -> SDL backend
// Each backend gets its own pair of result-returning readers; there is no
// common pointer type to overload on (a `using`-embedded struct is not
// implicitly upcast), and routing them through one function would mean runtime
// guessing. Atomic writes exist for the file backend only: SDL_Storage has no
// rename, and ZIP containers are read-only (olib rejects both, same outcome).

//
// [olib L-024] Storage read results
//

// [olib L-024] The minimum result every backend can promise. A pre-flight
// existence check is NOT a read result: success comes only from err == .NONE.
Storage_Read_Error :: enum {
    NONE;              // success, including a legitimately empty file
    INVALID_ARGUMENT;  // null container, empty path, or a path/Root holding NUL
    READ_FAILED;       // missing, refused, a directory, or IO/decoding/allocation
                       // failure; nothing more specific can be claimed for
                       // every backend, so this does not guess a cause
}

// Human-readable name for logs and diagnostics (olib spells the members
// InvalidArgument/ReadFailed, which is where the strings come from).
storage_read_error_name :: (err: Storage_Read_Error) -> string {
    if err == {
        case .NONE;             return "None";
        case .INVALID_ARGUMENT; return "InvalidArgument";
        case .READ_FAILED;      return "ReadFailed";
    }
    return "";
}

// UTF-8 paths go straight to the OS / SDL / miniz as C strings, so an embedded
// NUL would silently truncate the name and read a different file: reject it
// instead (olib: strings.contains(path, "\x00")).
storage_ext_has_nul :: (s: string) -> bool {
    for c: s {
        if c == 0 return true;
    }
    return false;
}

//
// File backend (plain OS directory container)
//

// [olib L-024] ReadAllBytesResult for a directory container.
//
// A fresh, independently owned buffer on success — never a view into the
// container or a shared scratch buffer; free it with `free(data.data)`.
// A legitimately empty file gives an empty slice and .NONE (nothing to free).
// On failure the slice is empty and the message is non-.NONE: callers must not
// report "the file is empty" or "the file does not exist" from a failure.
//
// A missing file, a directory, a permission error and a short read are all
// .READ_FAILED with no further splitting: the OS calls do not distinguish them
// portably. No UTF-8 validation, no line-ending translation, and no promise of
// a consistent snapshot if another thread rewrites the file mid-read.
storage_read_all_bytes_result :: (s: *Storage_Container, path: string) -> ([] u8, Storage_Read_Error) {
    if s == null || path == "" || storage_ext_has_nul(path) || storage_ext_has_nul(s.Root) {
        return .[], .INVALID_ARGUMENT;
    }

    full := storage_full_path(s, path);
    text, ok := File.read_entire_file(full);
    if !ok return .[], .READ_FAILED;
    if text.count == 0 {
        free(text);   // empty string from read_entire_file still owns a buffer
        return .[], .NONE;
    }
    return cast([] u8) text, .NONE;
}

// [olib L-024] Same result and ownership as the bytes reader, as counted text
// (Jai strings need no terminator). Free with `free(text)`; an empty file is
// "", .NONE.
storage_read_all_text_result :: (s: *Storage_Container, path: string) -> (string, Storage_Read_Error) {
    data, err := storage_read_all_bytes_result(s, path);
    if err != .NONE return "", err;
    if data.count == 0 return "", .NONE;
    return .{ data = data.data, count = data.count }, .NONE;
}

//
// Zip backend (Zip_Storage from storage.jai / miniz_zip.jai)
//

// [olib L-024] ReadAllBytesResult for a zip container.
//
// The entry is copied out of the archive (mz_zip_reader_extract_to_heap ->
// alloc), so the buffer is independent of the Zip_Storage and stays valid after
// the archive is closed; free with `free(data.data)`.
//
// The archive is consulted for the entry's name, size and directory bit
// instead of trusting "extraction returned null": that way a zero-length entry
// is a success (.NONE, empty) rather than being confused with a missing entry,
// which olib gets from its ZipEntries map and miniz does not give for free.
// A missing entry, a directory entry and a failed extract are .READ_FAILED.
zip_storage_read_all_bytes_result :: (z: *Zip_Storage, path: string) -> ([] u8, Storage_Read_Error) {
    if z == null || z.archive == null || path == "" || storage_ext_has_nul(path) {
        return .[], .INVALID_ARGUMENT;
    }

    cpath := to_cstr(path);
    idx := mz_zip_reader_locate_file(z.archive, cpath, null, 0);
    free(cpath);
    if idx < 0 return .[], .READ_FAILED;

    // The stat buffer is allocated with the C-side sizeof (see zip_list_files:
    // the Jai struct mirror is not the authority on the layout).
    stat := cast(*MZ_ZIP_ARCHIVE_FILE_STAT) alloc(jf_mz_stat_size());
    inspected := mz_zip_reader_file_stat(z.archive, cast(u32) idx, stat);
    is_directory := stat.m_is_directory != 0;
    uncompressed := stat.m_uncomp_size;
    free(stat);

    if !inspected return .[], .READ_FAILED;
    if is_directory return .[], .READ_FAILED;
    if uncompressed == 0 return .[], .NONE;

    data := zip_read_file(z.archive, path);
    if data.data == null || data.count <= 0 return .[], .READ_FAILED;
    return data, .NONE;
}

// [olib L-024] Text view sharing the bytes allocation; free with `free(text)`.
zip_storage_read_all_text_result :: (z: *Zip_Storage, path: string) -> (string, Storage_Read_Error) {
    data, err := zip_storage_read_all_bytes_result(z, path);
    if err != .NONE return "", err;
    if data.count == 0 return "", .NONE;
    return .{ data = data.data, count = data.count }, .NONE;
}

//
// SDL_Storage backend (Content_Storage from content_storage.jai)
//

// [olib L-024] ReadAllBytesResult for an SDL_Storage container.
//
// Wraps content_storage_open_read (path info -> size -> SDL_ReadStorageFile) and
// narrows its (data, ok) pair onto Storage_Read_Error. The SDL backend's own
// status stays available through content_storage_last_error(), which is where
// the detailed reason lives (CLOSED / IO_FAILED / ...); this reader only
// promises the portable split olib promises.
//
// A closed or null storage is .INVALID_ARGUMENT for a null container and
// .READ_FAILED for a closed one — the same rule as a null vs. failed OS read;
// not-ready, missing, directory and IO failures are .READ_FAILED. Returned
// bytes are a fresh allocation from content_storage_open_read; free(data.data).
content_storage_read_all_bytes_result :: (c: *Content_Storage, path: string) -> ([] u8, Storage_Read_Error) {
    if c == null || path == "" || storage_ext_has_nul(path) return .[], .INVALID_ARGUMENT;
    if !content_storage_is_open(c) return .[], .READ_FAILED;

    data, ok := content_storage_open_read(c, path);
    if !ok return .[], .READ_FAILED;
    return data, .NONE;
}

// [olib L-024] Text view sharing the bytes allocation; free with `free(text)`.
content_storage_read_all_text_result :: (c: *Content_Storage, path: string) -> (string, Storage_Read_Error) {
    data, err := content_storage_read_all_bytes_result(c, path);
    if err != .NONE return "", err;
    if data.count == 0 return "", .NONE;
    return .{ data = data.data, count = data.count }, .NONE;
}

//
// [olib L-015] Storage / Atomic Write — replace one file in one step
//
// olib's WriteAllBytesAtomic: write a temporary file in the *same* directory,
// flush it, then rename it over the target, so a reader (or a crash) sees
// either the old file or the whole new one and never a half-written mix.
// Upstream Foster writes straight through the container (File.WriteAllBytes),
// which truncates first — that is the behavior this extension exists to avoid.
//
// What it does NOT promise, exactly as in olib: durability across a power cut
// (the directory entry is not fsync'd), transactions across several files, or
// an ordering guarantee against concurrent writers of the same path. Storing to
// a read-only container, a ZIP container, a directory path or an empty path is
// refused with false and the existing file left alone.
//

// Directory part of a storage path (either separator; storage paths use '/',
// but '\' is accepted on input by normalize_storage_path). "" when there is
// none, i.e. the path is relative to the working directory.
storage_ext_parent :: (path: string) -> string {
    i := path.count - 1;
    while i >= 0 {
        c := path[i];
        if c == #char "/" || c == #char "\\" return .{ data = path.data, count = i };
        i -= 1;
    }
    return "";
}

// `mkdir -p` for one component at a time: SDL_CreateDirectory (folder_create)
// only makes the last component, and the temp file has to land in a directory
// that exists. A path that already exists is success; failing to create an
// ancestor is reported as false rather than silently writing elsewhere.
storage_ext_make_directory_all :: (path: string) -> bool {
    if path == "" return true;
    if folder_exists(path) return true;

    parent := storage_ext_parent(path);
    if parent != "" && parent != path {
        if !storage_ext_make_directory_all(parent) return false;
    }
    return folder_create(path);
}

// Serial for the temp-file names of this process (a counter catches two writes
// in the same millisecond; the timestamp keeps two processes apart).
storage_ext_write_serial: u64;

// A temp name next to the target, so the rename never crosses a file system
// (that is the only case where rename is not atomic) and never litters another
// directory. The leading dot keeps it out of casual listings; the ".tmp"
// suffix keeps it out of save-file globs that look for the real extension.
storage_ext_temp_path :: (parent: string) -> string {
    serial := storage_ext_write_serial;
    storage_ext_write_serial = serial + 1;
    stamp := cast(u64) (platform_time_seconds() * 1000.0);
    if parent == "" return tprint(".jfoster-%-%.tmp", stamp, serial);
    return tprint("%/.jfoster-%-%.tmp", parent, stamp, serial);
}

// [olib L-015] WriteAllBytesAtomic.
//
// The temp file is created with file_open(for_writing) -> file_write ->
// file_flush, i.e. the bytes reach the device before the rename, which is what
// olib does with os.sync before os.rename. File_Utilities' atomic replace is a
// replacing move (MoveFileEx on Windows, rename on Unix), which is the
// platform-guaranteed way to swap the name in one step.
//
// Returns true only when the new content is in place. Any failure — cannot
// create/write/flush the temp file, cannot rename — deletes the temp file it
// created itself and returns false; the previous file survives untouched.
storage_write_all_bytes_atomic :: (s: *Storage_Container, path: string, data: [] u8) -> bool {
    if s == null || !s.Writable || path == "" return false;
    if storage_ext_has_nul(path) || storage_ext_has_nul(s.Root) return false;

    full := storage_full_path(s, path);
    parent := storage_ext_parent(full);
    if parent != "" && !storage_ext_make_directory_all(parent) return false;
    if directory_exists(full) return false;   // replace a file, never a directory

    temp := storage_ext_temp_path(parent);
    file, opened := File.file_open(temp, for_writing = true);
    if !opened {
        log_error(tprint("storage_write_all_bytes_atomic: cannot create the temporary file '%'", temp));
        return false;
    }
    wrote := File.file_write(*file, data.data, data.count);
    flushed := ifx wrote then File.file_flush(file) else false;
    File.file_close(*file);
    if !wrote || !flushed {
        log_error(tprint("storage_write_all_bytes_atomic: writing '%' failed, keeping the old file", full));
        jf_file_delete(temp);
        return false;
    }

    if !File_Utilities.atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(temp, full) {
        log_error(tprint("storage_write_all_bytes_atomic: replacing '%' failed, keeping the old file", full));
        jf_file_delete(temp);
        return false;
    }
    return true;
}

// [olib L-015] WriteAllTextAtomic — the same single-file replacement for UTF-8
// text (Jai strings are bytes, so this only saves the caller the cast).
storage_write_all_text_atomic :: (s: *Storage_Container, path: string, text: string) -> bool {
    return storage_write_all_bytes_atomic(s, path, cast([] u8) text);
}
