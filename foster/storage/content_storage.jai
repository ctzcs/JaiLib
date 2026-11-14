#scope_module
using Basic; // module-private
using Math;
#scope_export

// Port of Foster Framework/Storage/ContentStorage.cs — Title (application/game
// data) and User (save data) storage on top of SDL_Storage.
//
// Foster reaches these through App.FileSystem.OpenTitleStorage /
// OpenUserStorage; here they are explicit constructors (content_storage_open_*)
// plus the same members the C# class implements over StorageContainer.
//
// Shape: exactly like the other containers in storage.jai — a struct that
// `using`s a Storage_Container (Writable lives there, as in Zip_Storage) and a
// family of `content_storage_*` procedures. The generic `storage_*` helpers from
// storage.jai resolve paths against a real filesystem root and therefore must
// NOT be used on this container; use the content_storage_* procedures (the same
// rule that applies to Zip_Storage / zip_storage_*).
//
// Failure policy: Jai has no exceptions, so instead of Foster's
// `throw new Exception(...)` every entry point returns false / an empty result
// and leaves a human-readable reason in content_storage_last_error(). Nothing
// fails silently: the reason distinguishes "not available", "not open", "not
// writable", "not ready" and "the SDL call itself failed" (the latter carries
// SDL_GetError()).
//
// Readiness: as the SDL docs note, an opened storage may take a moment to become
// usable. Check content_storage_ready() (C# ContentStorage.Ready) or call
// content_storage_wait_ready() — the latter busy-waits, so call it off the main
// thread, the same constraint Foster's FileSystem has.
//
// Differences from the C# implementation are called out inline; the two that
// matter are the absence of Streams (a whole file is read/written in one call,
// because SDL_Storage has no stream API either) and directory enumeration going
// through SDL_GlobStorageDirectory instead of a callback (a `#c_call` callback
// has no Jai context to allocate with — see cs_enumerate_dir).

//
// Capability switch
//

// The SDL_Storage backend is bound in internal/sdl3/SDL_storage.jai. Setting
// this to false builds and links Content_Storage *without* SDL: every entry
// point then fails with status .NOT_AVAILABLE and a diagnostic naming this flag,
// instead of pretending to work. This is the "no SDL_Storage bindings" path.
// wasm 目标下没有 SDL_Storage：走文件里已有的 .NOT_AVAILABLE 降级路径。
#if OS != .WASM {
    CONTENT_STORAGE_SDL_AVAILABLE :: true;
} else {
    CONTENT_STORAGE_SDL_AVAILABLE :: false;
}

// Recursive enumeration stops at this depth (guards against a pathological
// storage backend / symlink loop).
CONTENT_STORAGE_MAX_ENUM_DEPTH :: 32;

//
// Types
//

Content_Storage_Status :: enum {
    OK; // success
    NOT_AVAILABLE; // built without the SDL_Storage backend (see the switch above)
    OPEN_FAILED; // SDL_Open*Storage returned NULL (see the diagnostic)
    CLOSED; // the handle is NULL — never opened, or already closed
    NOT_WRITABLE; // a write was attempted on a read-only (Title) storage
    NOT_READY; // the storage is not ready yet (poll content_storage_ready)
    IO_FAILED; // the SDL call itself failed
}

// Decoupled copy of SDL_PathType so this file does not have to be compiled with
// the SDL bindings (see CONTENT_STORAGE_SDL_AVAILABLE).
Content_Storage_Path_Type :: enum {
    NONE;
    FILE;
    DIRECTORY;
    OTHER;
}

Content_Storage :: struct {
    using container: Storage_Container;
    Handle: *void; // SDL_Storage*; null == closed. Typed as *void on purpose:
    // the struct then compiles whether or not the SDL bindings
    // are loaded, and only the backend touches the real type.
}

//
// Diagnostics
//

content_storage_diagnostic: string; // last failure; "" after a success

// Why the last operation failed. "" when it succeeded. The string lives in
// temporary storage — copy_string it if you need to keep it.
content_storage_last_error :: () -> string {
    return content_storage_diagnostic;
}

cs_clear_error :: () {
    content_storage_diagnostic = "";
}

cs_error :: (status: Content_Storage_Status, message: string) -> Content_Storage_Status {
    content_storage_diagnostic = message;
    return status;
}

// Builds a diagnostic from the backend's last error (SDL_GetError), with the
// same "X failed: ..." shape app_sdl_error_message uses elsewhere in the module.
cs_error_sdl :: (status: Content_Storage_Status, sdl_method: string) -> Content_Storage_Status {
    return cs_error(status, tprint("content storage: % failed: %", sdl_method, cs_backend_last_error()));
}

cs_require_backend :: () -> bool {
    if cs_backend_available() return true;
    cs_error(.NOT_AVAILABLE, "content storage is unavailable: this build has no SDL_Storage backend (CONTENT_STORAGE_SDL_AVAILABLE is false in storage/content_storage.jai)");
    return false;
}

// Frees a string list produced by the backend (or handed back to the caller).
cs_free_string_list :: (list: [..] string) {
    for entry: list free(entry.data);
    array_free(list);
}

// `dir` + "/" + `entry`, allocated with the context allocator (the caller owns
// it). SDL_GlobStorageDirectory hands back names relative to `dir`, so this is
// what turns them into the storage-relative paths C# returns.
cs_join_path :: (dir: string, entry: string) -> string {
    n := entry.count;
    if dir != "" n += dir.count + 1;
    if n == 0 return "";

    block := alloc(n);
    at := cast(*u8) block;
    if dir != "" {
        memcpy(at, dir.data, dir.count);
        at[dir.count] = #char "/";
        at += dir.count + 1;
    }
    memcpy(at, entry.data, entry.count);
    return .{ data = cast(*u8) block, count = n };
}

//
// C# Calc.NormalizePath: '\' -> '/', collapse repeated '/'. Unlike a filesystem
// canonicalization it does not resolve "." / ".." (neither does Foster's).
//

content_storage_normalize_path :: (path: string) -> string {
    out: String_Builder;
    previous_was_slash := false;
    for c: path {
        ch := c;
        if ch == #char "\\" ch = #char "/";
        if ch == #char "/" {
            if previous_was_slash continue;
            previous_was_slash = true;
        } else {
            previous_was_slash = false;
        }
        append(*out, ch);
    }
    return builder_to_string(*out);
}

// `path` with the `root` prefix and its separator removed (C# matches the search
// pattern against this). Returns `path` unchanged when it is not under `root`.
content_storage_relative_path :: (root: string, path: string) -> string {
    if root == "" return path;
    if path.count <= root.count return path;
    for i: 0..root.count - 1 {
        if path[i] != root[i] return path;
    }
    if path[root.count] != #char "/" return path;
    return .{ data = path.data + root.count + 1, count = path.count - root.count - 1 };
}

//
// Backend — everything that touches SDL_Storage lives behind this seam, so the
// "no bindings" build only differs in the branch below.
//

#if CONTENT_STORAGE_SDL_AVAILABLE {

    cs_backend_available :: () -> bool {
        return true;
    }

    // SDL_GetError() for whatever the last backend call did.
    cs_backend_last_error :: () -> string {
        return cstr_to_string(SDL_GetError());
    }

    cs_backend_open_user :: (org: string, app_name: string) -> *void {
        org_c := to_cstr(org);
        app_c := to_cstr(app_name);
        defer free(org_c);
        defer free(app_c);
        return cast(*void) SDL_OpenUserStorage(org_c, app_c, 0);
    }

    // `override_path == ""` maps to a NULL override, i.e. "use the platform default
    // title directory" (C# passes null for the same case).
    cs_backend_open_title :: (override_path: string) -> *void {
        if override_path == "" return cast(*void) SDL_OpenTitleStorage(null, 0);
        path_c := to_cstr(override_path);
        defer free(path_c);
        return cast(*void) SDL_OpenTitleStorage(path_c, 0);
    }

    cs_backend_open_file :: (path: string) -> *void {
        path_c := to_cstr(path);
        defer free(path_c);
        return cast(*void) SDL_OpenFileStorage(path_c);
    }

    cs_backend_close :: (handle: *void) {
        SDL_CloseStorage(cast(*SDL_Storage) handle);
    }

    cs_backend_ready :: (handle: *void) -> bool {
        return SDL_StorageReady(cast(*SDL_Storage) handle);
    }

    cs_backend_path_info :: (handle: *void, path: string) -> (Content_Storage_Path_Type, u64, bool) {
        info: SDL_PathInfo;
        path_c := to_cstr(path);
        defer free(path_c);
        if !SDL_GetStoragePathInfo(cast(*SDL_Storage) handle, path_c, *info) {
            return .NONE, 0, false;
        }
        type := Content_Storage_Path_Type.OTHER;
        if info.type == SDL_PATHTYPE_NONE type = .NONE;
        else if info.type == SDL_PATHTYPE_FILE type = .FILE;
        else if info.type == SDL_PATHTYPE_DIRECTORY type = .DIRECTORY;
        return type, info.size, true;
    }

    cs_backend_read :: (handle: *void, path: string, destination: *void, length: u64) -> bool {
        path_c := to_cstr(path);
        defer free(path_c);
        return SDL_ReadStorageFile(cast(*SDL_Storage) handle, path_c, destination, length);
    }

    cs_backend_write :: (handle: *void, path: string, source: *void, length: u64) -> bool {
        path_c := to_cstr(path);
        defer free(path_c);
        return SDL_WriteStorageFile(cast(*SDL_Storage) handle, path_c, source, length);
    }

    cs_backend_create_directory :: (handle: *void, path: string) -> bool {
        path_c := to_cstr(path);
        defer free(path_c);
        return SDL_CreateStorageDirectory(cast(*SDL_Storage) handle, path_c);
    }

    cs_backend_remove :: (handle: *void, path: string) -> bool {
        path_c := to_cstr(path);
        defer free(path_c);
        return SDL_RemoveStoragePath(cast(*SDL_Storage) handle, path_c);
    }

    cs_backend_space_remaining :: (handle: *void) -> u64 {
        return SDL_GetStorageSpaceRemaining(cast(*SDL_Storage) handle);
    }

    // Every entry (files *and* directories) directly inside `dir`, as paths relative
    // to the storage root, using SDL's own glob engine (pattern "*", which never
    // matches a '/'). Result strings are allocated with the context allocator.
    cs_backend_list :: (handle: *void, dir: string) -> ([..] string, bool) {
        out: [..] string;
        dir_c := to_cstr(dir); // "" (and NULL) mean "the storage root"
        pattern_c := to_cstr("*");
        defer free(dir_c);
        defer free(pattern_c);

        count: s32;
        results := SDL_GlobStorageDirectory(cast(*SDL_Storage) handle, dir_c, pattern_c, 0, *count);
        if results == null return out, false;
        defer SDL_free(cast(*void) results);

        for i: 0..count - 1 {
            array_add(*out, copy_string(cstr_to_string(results[i])));
        }
        return out, true;
    }

} else {

    // Degraded build: SDL_Storage is not compiled in. These stubs exist only so the
    // public API below stays identical; every public entry point calls
    // cs_require_backend() first and returns .NOT_AVAILABLE with a diagnostic before
    // reaching them, so they can never be the silent path.

    cs_backend_available :: () -> bool {
        return false;
    }

    cs_backend_last_error :: () -> string {
        return "no SDL_Storage backend in this build";
    }

    cs_backend_open_user :: (org: string, app_name: string) -> *void {
        return null;
    }

    cs_backend_open_title :: (override_path: string) -> *void {
        return null;
    }

    cs_backend_open_file :: (path: string) -> *void {
        return null;
    }

    cs_backend_close :: (handle: *void) {}

    cs_backend_ready :: (handle: *void) -> bool {
        return false;
    }

    cs_backend_path_info :: (handle: *void, path: string) -> (Content_Storage_Path_Type, u64, bool) {
        return .NONE, 0, false;
    }

    cs_backend_read :: (handle: *void, path: string, destination: *void, length: u64) -> bool {
        return false;
    }

    cs_backend_write :: (handle: *void, path: string, source: *void, length: u64) -> bool {
        return false;
    }

    cs_backend_create_directory :: (handle: *void, path: string) -> bool {
        return false;
    }

    cs_backend_remove :: (handle: *void, path: string) -> bool {
        return false;
    }

    cs_backend_space_remaining :: (handle: *void) -> u64 {
        return 0;
    }

    cs_backend_list :: (handle: *void, dir: string) -> ([..] string, bool) {
        out: [..] string;
        return out, false;
    }

}

//
// Open / close
//

cs_open_result :: (handle: *void, writable: bool, sdl_method: string) -> (*Content_Storage, Content_Storage_Status) {
    if handle == null {
        return null, cs_error_sdl(.OPEN_FAILED, sdl_method);
    }
    storage := New(Content_Storage);
    storage.Handle = handle;
    storage.Root = ""; // paths are resolved by SDL, not by storage_full_path
    storage.Writable = writable;
    cs_clear_error();
    return storage, .OK;
}

// C# ContentStorage.OpenUserStorage(name): user (save data) storage, writable.
// `org` is Foster's string.Empty; some platforms want a real organization name.
content_storage_open_user :: (app_name: string, org := "") -> (*Content_Storage, Content_Storage_Status) {
    if !cs_require_backend() return null, .NOT_AVAILABLE;
    if app_name == "" {
        return null, cs_error(.OPEN_FAILED, "content storage open failed: the application name is empty");
    }
    return cs_open_result(cs_backend_open_user(org, app_name), true, "SDL_OpenUserStorage");
}

// C# ContentStorage.OpenTitleStorage(path): title (game data) storage, read-only.
// `override_path == ""` means "the platform default title directory".
content_storage_open_title :: (override_path := "") -> (*Content_Storage, Content_Storage_Status) {
    if !cs_require_backend() return null, .NOT_AVAILABLE;
    return cs_open_result(cs_backend_open_title(override_path), false, "SDL_OpenTitleStorage");
}

// port addition: a storage rooted at an arbitrary directory (SDL_OpenFileStorage).
// Foster has no ContentStorage equivalent — it uses StorageContainer for that —
// but it is the practical way to exercise the same code path on desktop.
content_storage_open_file :: (path: string) -> (*Content_Storage, Content_Storage_Status) {
    if !cs_require_backend() return null, .NOT_AVAILABLE;
    if path == "" {
        return null, cs_error(.OPEN_FAILED, "content storage open failed: the path is empty");
    }
    return cs_open_result(cs_backend_open_file(path), true, "SDL_OpenFileStorage");
}

content_storage_is_open :: (c: *Content_Storage) -> bool {
    return c != null && c.Handle != null;
}

// Close the SDL storage and free the Content_Storage returned by an open call
// (C# Dispose + the managed wrapper going away).
content_storage_close :: (c: *Content_Storage) {
    if c == null return;
    if c.Handle != null {
        if cs_backend_available() cs_backend_close(c.Handle);
        c.Handle = null;
    }
    free(c);
}

//
// Readiness
//

// C# ContentStorage.Ready.
content_storage_ready :: (c: *Content_Storage) -> bool {
    if !content_storage_is_open(c) {
        cs_error(.CLOSED, "content storage readiness check failed: the storage is not open");
        return false;
    }
    if !cs_require_backend() return false;
    return cs_backend_ready(c.Handle);
}

// Polls until the storage is ready or `timeout_ms` elapses (0 = check once).
// SDL asks that this not be spin-waited on the main thread, so call it from a
// worker thread — the same rule Foster's FileSystem.Open*Async follows.
content_storage_wait_ready :: (c: *Content_Storage, timeout_ms := 5000) -> bool {
    if !content_storage_is_open(c) {
        cs_error(.CLOSED, "content storage wait failed: the storage is not open");
        return false;
    }
    if !cs_require_backend() return false;

    start := to_float64_seconds(current_time_monotonic());
    timeout := cast(float64) timeout_ms / 1000.0;
    while true {
        if cs_backend_ready(c.Handle) {
            cs_clear_error();
            return true;
        }
        if to_float64_seconds(current_time_monotonic()) - start >= timeout break;
    }
    cs_error(.NOT_READY, tprint("content storage was not ready after % ms", timeout_ms));
    return false;
}

//
// Queries
//

// Shared guard for the path queries: normalizes and resolves SDL_PathInfo.
cs_path_info :: (c: *Content_Storage, path: string, sdl_method: string) -> (Content_Storage_Path_Type, u64, bool) {
    if !content_storage_is_open(c) {
        cs_error(.CLOSED, tprint("content storage: % failed: the storage is not open", sdl_method));
        return .NONE, 0, false;
    }
    if !cs_require_backend() return .NONE, 0, false;

    p := content_storage_normalize_path(path);
    type, size, ok := cs_backend_path_info(c.Handle, p);
    if !ok {
        // A missing path is reported as .NONE with SDL's own reason attached.
        cs_error_sdl(.IO_FAILED, sdl_method);
        return type, size, false;
    }
    cs_clear_error();
    return type, size, true;
}

content_storage_exists :: (c: *Content_Storage, path: string) -> bool {
    type, _, ok := cs_path_info(c, path, "SDL_GetStoragePathInfo");
    return ok && (type == .FILE || type == .DIRECTORY);
}

content_storage_file_exists :: (c: *Content_Storage, path: string) -> bool {
    type, _, ok := cs_path_info(c, path, "SDL_GetStoragePathInfo");
    return ok && type == .FILE;
}

content_storage_directory_exists :: (c: *Content_Storage, path: string) -> bool {
    type, _, ok := cs_path_info(c, path, "SDL_GetStoragePathInfo");
    return ok && type == .DIRECTORY;
}

// Bytes left on the storage's volume (SDL_GetStorageSpaceRemaining); 0 when the
// platform does not report it.
content_storage_space_remaining :: (c: *Content_Storage) -> u64 {
    if !content_storage_is_open(c) {
        cs_error(.CLOSED, "content storage space query failed: the storage is not open");
        return 0;
    }
    if !cs_require_backend() return 0;
    return cs_backend_space_remaining(c.Handle);
}

//
// Reading
//

// C# OpenRead(path) (a Stream over the whole file) — here the file comes back as
// one block of bytes, allocated with the context allocator; free(data) when done.
// An existing but empty file returns an empty slice with ok == true.
content_storage_open_read :: (c: *Content_Storage, path: string) -> ([] u8, bool) {
    if !content_storage_is_open(c) {
        cs_error(.CLOSED, "content storage read failed: the storage is not open");
        return .[], false;
    }
    if !cs_require_backend() return .[], false;

    p := content_storage_normalize_path(path);
    type, size, ok := cs_backend_path_info(c.Handle, p);
    if !ok {
        cs_error_sdl(.IO_FAILED, "SDL_GetStorageFileSize");
        return .[], false;
    }
    if type != .FILE {
        cs_error(.IO_FAILED, tprint("content storage read failed: '%' is not a file", p));
        return .[], false;
    }
    if size == 0 {
        cs_clear_error();
        return .[], true;
    }

    data: [] u8 = .{ data = cast(*u8) alloc(cast(s64) size), count = cast(s64) size };
    if !cs_backend_read(c.Handle, p, data.data, size) {
        cs_error_sdl(.IO_FAILED, "SDL_ReadStorageFile");
        free(data.data);
        return .[], false;
    }
    cs_clear_error();
    return data, true;
}

content_storage_read_all_bytes :: (c: *Content_Storage, path: string) -> ([] u8, bool) {
    return content_storage_open_read(c, path);
}

content_storage_read_all_text :: (c: *Content_Storage, path: string) -> (string, bool) {
    data, ok := content_storage_open_read(c, path);
    if !ok return "", false;
    // Jai strings are counted, so no terminator is needed (or added).
    return .{ data = data.data, count = data.count }, true;
}

//
// Writing (User storage only — Title storage is read-only, as in Foster)
//

// C# Create(path) → write → Flush(), collapsed into one call: SDL_Storage has no
// stream, so the bytes go out in a single SDL_WriteStorageFile.
content_storage_write_all_bytes :: (c: *Content_Storage, path: string, data: [] u8) -> bool {
    if !content_storage_is_open(c) {
        cs_error(.CLOSED, "content storage write failed: the storage is not open");
        return false;
    }
    if !c.Writable {
        cs_error(.NOT_WRITABLE, "content storage write failed: the storage can not be written to");
        return false;
    }
    if !cs_require_backend() return false;

    p := content_storage_normalize_path(path);
    if !cs_backend_write(c.Handle, p, data.data, cast(u64) data.count) {
        cs_error_sdl(.IO_FAILED, "SDL_WriteStorageFile");
        return false;
    }
    cs_clear_error();
    return true;
}

content_storage_write_all_text :: (c: *Content_Storage, path: string, text: string) -> bool {
    return content_storage_write_all_bytes(c, path, cast([] u8) text);
}

//
// Directories / removal
//

content_storage_create_directory :: (c: *Content_Storage, path: string) -> bool {
    if !content_storage_is_open(c) {
        cs_error(.CLOSED, "content storage CreateDirectory failed: the storage is not open");
        return false;
    }
    if !c.Writable {
        cs_error(.NOT_WRITABLE, "content storage CreateDirectory failed: the storage can not be written to");
        return false;
    }
    if !cs_require_backend() return false;

    p := content_storage_normalize_path(path);
    if !cs_backend_create_directory(c.Handle, p) {
        cs_error_sdl(.IO_FAILED, "SDL_CreateStorageDirectory");
        return false;
    }
    cs_clear_error();
    return true;
}

content_storage_remove :: (c: *Content_Storage, path: string) -> bool {
    if !content_storage_is_open(c) {
        cs_error(.CLOSED, "content storage Remove failed: the storage is not open");
        return false;
    }
    if !c.Writable {
        cs_error(.NOT_WRITABLE, "content storage Remove failed: the storage can not be written to");
        return false;
    }
    if !cs_require_backend() return false;

    p := content_storage_normalize_path(path);
    if !cs_backend_remove(c.Handle, p) {
        cs_error_sdl(.IO_FAILED, "SDL_RemoveStoragePath");
        return false;
    }
    cs_clear_error();
    return true;
}

//
// Enumeration
//

// Walks `dir` depth-first: the entries of `dir` are filtered by `pattern` and
// appended to `out`, then every subdirectory is visited the same way (C# order:
// its callback appends entries while walking, then recurses into the subfolders
// it collected).
//
// C# drives SDL_EnumerateStorageDirectory with a managed callback. That is not
// usable from Jai: a `#c_call` procedure has no context, so it can neither
// allocate the result strings nor build paths. SDL_GlobStorageDirectory gives the
// same listing in one call, and the recursion that used to happen inside the
// callback happens here instead.
cs_enumerate_dir :: (c: *Content_Storage, dir: string, pattern: string,
                     recursive: bool, out: *[..] string, depth: s32) -> bool {
    if depth > CONTENT_STORAGE_MAX_ENUM_DEPTH {
        cs_error(.IO_FAILED, tprint("content storage enumeration stopped: deeper than % levels at '%'",
                                    CONTENT_STORAGE_MAX_ENUM_DEPTH, dir));
        return false;
    }

    list, ok := cs_backend_list(c.Handle, dir);
    if !ok {
        cs_error_sdl(.IO_FAILED, "SDL_GlobStorageDirectory");
        return false;
    }
    defer cs_free_string_list(list);

    // entries of this directory first (C# filters inside its callback) ...
    for entry: list {
        full := cs_join_path(dir, entry);
        if pattern != "" && !match_wildcard(pattern, content_storage_relative_path(dir, full)) {
            free(full.data);
            continue;
        }
        array_add(out, full);
    }

    // ... then the subfolders, whether or not they matched the pattern
    if recursive {
        for entry: list {
            full := cs_join_path(dir, entry);
            type, _, info_ok := cs_backend_path_info(c.Handle, full);
            ok_dir := info_ok && type == .DIRECTORY;
            if ok_dir {
                if !cs_enumerate_dir(c, full, pattern, recursive, out, depth + 1) {
                    free(full.data);
                    return false;
                }
            }
            free(full.data);
        }
    }
    return true;
}

// C# EnumerateDirectory: full paths of the entries under `path`, filtered by a
// '*' / '?' wildcard matched against the path relative to `path` ("" matches
// everything), optionally recursing into subfolders. Returned strings are
// allocated with the context allocator.
content_storage_enumerate :: (c: *Content_Storage, path := "",
                              search_pattern := "*.*", recursive := false) -> ([] string, bool) {
    entries: [..] string;

    if !content_storage_is_open(c) {
        cs_error(.CLOSED, "content storage enumeration failed: the storage is not open");
        return entries, false;
    }
    if !cs_require_backend() return entries, false;

    root := content_storage_normalize_path(path);
    if !cs_enumerate_dir(c, root, search_pattern, recursive, *entries, 0) {
        // drop the partial result rather than returning half a listing
        cs_free_string_list(entries);
        entries: [..] string;
        return entries, false;
    }

    cs_clear_error();
    return entries, true;
}
