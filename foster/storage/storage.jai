#scope_module
using Basic;
using Math;
using Hash_Table;

File_Utilities :: #import "File_Utilities";

using File_Utilities; // file_exists / folder_* helpers
// `File` (namespace) is already exported at module scope by utility/json.jai.
#scope_export

// Port of Foster Framework/Storage/*.cs — the StorageContainer abstraction
// (Directory/Relative over the OS filesystem + Zip via miniz). SDL_Storage
// (ContentStorage) is deferred: desktop games use the filesystem directly.

//
// StorageContainer
//

Storage_Container :: struct {
    Writable: bool = false;
    Root: string; // base path for Read/Write implementations
}

storage_exists :: (s: *Storage_Container, path: string) -> bool {
    full := storage_full_path(s, path);
    return jf_file_exists(full) || directory_exists(full);
}

storage_file_exists :: (s: *Storage_Container, path: string) -> bool {
    return jf_file_exists(storage_full_path(s, path));
}

storage_directory_exists :: (s: *Storage_Container, path: string) -> bool {
    return directory_exists(storage_full_path(s, path));
}

storage_read_all_bytes :: (s: *Storage_Container, path: string) -> [] u8 {
    full := storage_full_path(s, path);
    data, ok := storage_platform_read_text(full);
    if !ok return .[];
    return cast([] u8) data;
}

storage_read_all_text :: (s: *Storage_Container, path: string) -> string {
    full := storage_full_path(s, path);
    data, ok := storage_platform_read_text(full);
    if !ok return "";
    return data;
}

storage_write_all_bytes :: (s: *Storage_Container, path: string, data: [] u8) -> bool {
    if !s.Writable return false;
    full := storage_full_path(s, path);
    // `file_write(path, bytes)` never existed in the Jai stdlib; write via File.
    return storage_platform_write_text(full, cast(string) data);
}

storage_write_all_text :: (s: *Storage_Container, path: string, text: string) -> bool {
    if !s.Writable return false;
    full := storage_full_path(s, path);
    return storage_platform_write_text(full, text);
}

// ===========================================================================
// [W2] 平台文件原语：整个文件读 / 整个文件写
// ===========================================================================
// 这是 desktop 与 web 唯一需要分叉的两处 I/O（其余 storage_* 都建立在
// jf_file_exists / directory_* / 这两个原语之上）。桌面仍然是原来的
// File.read_entire_file / File.write_entire_file，行为一字未变；web 走
// internal/web/storage_web.jai 的虚拟键空间（内存 + localStorage + OPFS）。
//
// 返回值语义与 File.read_entire_file 一致：(内容, 成功)。web 分支会 copy_string
// 一次，因为底层缓冲区是复用的静态内存。
#if OS == .WASM {
    storage_platform_read_text :: (full: string) -> (string, bool) {
        view, ok := web_storage_read_file(full);
        if !ok return "", false;
        return copy_string(view), true;
    }

    storage_platform_write_text :: (full: string, text: string) -> bool {
        return web_storage_write_file(full, text);
    }
} else {
    storage_platform_read_text :: (full: string) -> (string, bool) {
        return File.read_entire_file(full);
    }

    storage_platform_write_text :: (full: string, text: string) -> bool {
        return File.write_entire_file(full, text);
    }
}

storage_create_directory :: (s: *Storage_Container, path: string) -> bool {
    if !s.Writable return false;
    return create_directory(storage_full_path(s, path));
}

storage_remove :: (s: *Storage_Container, path: string) -> bool {
    if !s.Writable return false;
    full := storage_full_path(s, path);
    if jf_file_exists(full) return jf_file_delete(full);
    if directory_exists(full) return directory_delete(full, true);
    return false;
}

storage_enumerate :: (s: *Storage_Container, path: string, search_pattern := "*.*", recursive := false) -> [] string {
    full := storage_full_path(s, path);
    return directory_enum(full, search_pattern, recursive);
}

// resolve path against the container root, normalizing separators
storage_full_path :: (s: *Storage_Container, path: string) -> string {
    normalized := normalize_storage_path(path);
    if s.Root == "" return normalized;
    return tprint("%/%", s.Root, normalized);
}

normalize_storage_path :: (path: string) -> string {
    out: String_Builder;
    for c: path {
        if c == #char "\\" append(*out, #char "/");
        else append(*out, c);
    }
    return builder_to_string(*out);
}

//
// DirectoryStorage — plain OS folder
//

directory_storage_create :: (root: string) -> *Storage_Container {
    s := New(Storage_Container);
    s.Root = root;
    s.Writable = true;
    return s;
}

//
// RelativeStorage — prefixes every path with a relative dir (decorator)
//

relative_storage_create :: (relative: string) -> *Storage_Container {
    s := New(Storage_Container);
    s.Root = relative;
    s.Writable = true;
    return s;
}

//
// ZipStorage — read-only zip via miniz
//

Zip_Storage :: struct {
    using container: Storage_Container;
    archive: *Zip_Archive;
}

zip_storage_open :: (path: string) -> *Zip_Storage {
    archive := zip_open_archive(path);
    if archive == null return null;

    z := New(Zip_Storage);
    z.archive = archive;
    z.Writable = false;
    return z;
}

zip_storage_close :: (z: *Zip_Storage) {
    zip_close_archive(z.archive);
    free(z);
}

zip_storage_read :: (z: *Zip_Storage, path: string) -> [] u8 {
    return zip_read_file(z.archive, path);
}

zip_storage_exists :: (z: *Zip_Storage, path: string) -> bool {
    return zip_has_file(z.archive, path);
}

zip_storage_enumerate :: (z: *Zip_Storage, path: string) -> [] string {
    return zip_list_files(z.archive, path);
}

//
// FileSystem (App-level helpers)
//

file_system_open_directory :: (path: string) -> *Storage_Container {
    return directory_storage_create(path);
}

file_system_open_zip :: (path: string) -> *Zip_Storage {
    return zip_storage_open(path);
}

// directory helpers over the OS filesystem (File_Utilities wrappers)
directory_exists :: (path: string) -> bool {
    return jf_file_exists(path) == false && folder_exists(path);
}

create_directory :: (path: string) -> bool {
    return folder_create(path);
}

directory_delete :: (path: string, recursive := false) -> bool {
    return folder_delete(path);
}

directory_enum :: (path: string, search_pattern := "*.*", recursive := false) -> [] string {
    results: [..] string;
    entries, ok := folder_enum(path, "", true);
    if !ok return results;
    for e: entries {
        if match_wildcard(search_pattern, e) {
            array_add(*results, e);
        }
    }
    return results;
}

match_wildcard :: (pattern: string, name: string) -> bool {
    // simple * and ? glob
    p := 0;
    n := 0;
    star := -1;
    match := 0;
    while n < name.count {
        if p < pattern.count && (pattern[p] == #char "?" || pattern[p] == name[n]) {
            p += 1;
            n += 1;
        } else if p < pattern.count && pattern[p] == #char "*" {
            star = p;
            match = n;
            p += 1;
        } else if star != -1 {
            p = star + 1;
            match += 1;
            n = match;
        } else {
            return false;
        }
    }
    while p < pattern.count && pattern[p] == #char "*" p += 1;
    return p == pattern.count;
}
