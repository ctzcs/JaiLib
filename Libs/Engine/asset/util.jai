// util.jai
// Jai-specific helpers for the asset module: small string/path utilities and
// thin file-system wrappers. olib leaned on core:strings / core:os / ofoster
// storage for these; the Jai port keeps the same operations in one place.

#import "Basic";
#import "String";   // slice(s, index, count)
#import "Hash_Table"; // Table / table_add / table_find / deinit

FI :: #import "File";
FU :: #import "File_Utilities";

// ---- string helpers (all allocate on the context allocator) ----

// Byte-slice allocation helpers (Jai's alloc() has no allocator/typed-slice
// overloads, so everything goes through push_allocator, which restores the
// previous allocator when the enclosing scope exits).
alloc_bytes :: (count: s64, allocator: Allocator = context.allocator) -> []u8 {
    v: []u8;
    push_allocator(allocator);
    v.data  = cast(*u8) alloc(count);
    v.count = count;
    return v;
}

free_bytes :: (mem: []u8, allocator: Allocator = context.allocator) {
    if mem.data == null return;
    push_allocator(allocator);
    free(mem.data);
}

// 非 owning 视图：把定长栈缓冲（如 [37]u8 的 guid 文件名缓冲）交给要 []u8 的 API。
u8_view :: (data: *u8, count: int) -> []u8 {
    v: []u8;
    v.data  = data;
    v.count = count;
    return v;
}

str_clone :: (s: string) -> string {
    return copy_string(s);
}

// Concatenate / join path segments (context allocator).
str_concat :: (a: string, b: string) -> string {
    buf: String_Builder;
    append(*buf, a);
    append(*buf, b);
    return builder_to_string(*buf);
}

// Join two path segments with '/' (empty segments handled).
str_join2 :: (a: string, b: string) -> string {
    if a.count == 0 return str_clone(b);
    if b.count == 0 return str_clone(a);
    return str_concat(str_concat(a, "/"), b);
}

str_lower :: (s: string) -> string {
    out: String_Builder;
    for s {
        append(*out, to_lower_ascii(it));
    }
    return builder_to_string(*out);
}

to_lower_ascii :: (c: u8) -> u8 {
    if c >= "A"[0] && c <= "Z"[0] return c + 32;
    return c;
}

str_ends_with :: (s: string, suffix: string) -> bool {
    if s.count < suffix.count return false;
    return slice(s, s.count - suffix.count, suffix.count) == suffix;
}

// Lexicographic byte compare (Jai has no built-in string ordering).
str_less :: (a: string, b: string) -> bool {
    n := min(a.count, b.count);
    for 0..n-1 {
        if a[it] != b[it] return a[it] < b[it];
    }
    return a.count < b.count;
}

// Last index of a byte, or -1.
str_last_index_of :: (s: string, c: u8) -> int {
    i := s.count - 1;
    while i >= 0 {
        if s[i] == c return i;
        i -= 1;
    }
    return -1;
}

// Normalize Windows separators to '/' so manifest keys stay stable.
path_normalize :: (s: string) -> string {
    out := str_clone(s);
    for 0..out.count-1 {
        if out[it] == "\\"[0] out[it] = "/"[0];
    }
    return out;
}

// Lower-case extension including the dot (".png"); "" when there is none.
path_ext_lower :: (path: string) -> string {
    dot := str_last_index_of(path, "."[0]);
    if dot < 0 return "";
    slash := str_last_index_of(path, "/"[0]);
    if slash > dot return ""; // dot inside a directory name, not an extension
    return str_lower(slice(path, dot, path.count - dot));
}

// ---- file-system wrappers ----

// Reads a file as raw bytes (context allocator); empty + false when missing.
file_read_bytes :: (path: string) -> ([]u8, bool) {
    data, ok := FI.read_entire_file(path, false, false);
    if !ok {
        empty: []u8;
        return empty, false;
    }
    return cast([]u8) data, true;
}

file_write_bytes :: (path: string, data: []u8) -> bool {
    return FI.write_entire_file(path, data.data, data.count);
}

file_exists :: (path: string) -> bool {
    return FU.file_exists(path);
}

// (mtime unix nanos, size, ok).
file_mtime_size :: (path: string) -> (s64, s64, bool) {
    at, size, ok := FU.file_modtime_and_size(path);
    if !ok return 0, 0, false;
    nanos, sok := to_nanoseconds(at);
    if !sok return cast(s64) at.low, size, true; // low-word fallback; consistency is all freshness needs
    return nanos, size, true;
}

file_delete :: (path: string) -> bool {
    return FI.file_delete(path);
}

// Recursive delete (File.delete_directory wraps SHFileOperationW).
dir_delete_tree :: (path: string) -> bool {
    return FI.delete_directory(path);
}

file_rename :: (old_path: string, new_path: string) -> bool {
    return FU.atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(old_path, new_path);
}

dir_make_all :: (path: string) -> bool {
    return FI.make_directory_if_it_does_not_exist(path, true);
}

// ---- directory enumeration ----
//
// olib recursed through ofoster's storage container; the Jai port walks the
// real directory tree via File_Utilities.visit_files and turns full names
// into '/'-separated paths relative to root (root itself must be slash-
// normalized or backslash-native, both handled by stripping its length).

Dir_Walk :: struct {
    root:        string; // as passed to visit_files (no trailing separator)
    paths:       [..] string; // relative, '/'-separated
}

collect_relative_paths :: (root: string, recursive: bool) -> []string {
    walk: Dir_Walk;
    walk.root = root;

    visitor :: (info: *FU.File_Visit_Info, w: *Dir_Walk) {
        full := info.full_name;
        if full.count <= w.root.count + 1 {
            array_add(*w.paths, str_clone(path_normalize(full)));
        } else {
            rel := slice(full, w.root.count + 1, full.count - w.root.count - 1);
            array_add(*w.paths, path_normalize(rel));
        }
    }

    FU.visit_files(root, recursive, *walk, visitor);
    return walk.paths;
}

free_relative_paths :: (paths: []string) {
    for paths free(it);
    array_free(paths);
}
