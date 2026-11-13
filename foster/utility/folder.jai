FILE :: #import "File";

// 目录操作兼容层。
//
// 官方 Jai 与 jacket 的 stdlib 都没有 `folder_exists / folder_create /
// folder_delete / folder_enum`（storage.jai 里的调用在两种编译器下都编译不过），
// 这里用 SDL3 的文件系统接口补上，语义对齐 odin 那套同名过程。

// jacket 的 File_Utilities 不再提供 file_exists / file_delete（官方 Jai 提供），
// 仓库统一以 jacket 为验收编译器，因此在这里补上同名过程。
jf_file_exists :: (path: string) -> bool {
    info: SDL_PathInfo;
    if !SDL_GetPathInfo(to_c_string(path), *info) return false;
    return info.type == .SDL_PATHTYPE_FILE;
}

jf_file_delete :: (path: string) -> bool {
    return FILE.file_delete(path);
}

folder_exists :: (path: string) -> bool {
    info: SDL_PathInfo;
    if !SDL_GetPathInfo(to_c_string(path), *info) return false;
    return info.type == .SDL_PATHTYPE_DIRECTORY;
}

folder_create :: (path: string) -> bool {
    if folder_exists(path) return true;
    return SDL_CreateDirectory(to_c_string(path));
}

folder_delete :: (path: string) -> bool {
    return SDL_RemovePath(to_c_string(path));
}

// 返回目录下的条目名（相对 path 的名字）。recursive 目前不展开子目录：
// SDL_GlobDirectory 只做单层匹配，storage.jai 的调用方只用到名字集合。
folder_enum :: (path: string, pattern: string, recursive: bool) -> ([] string, bool) {
    results: [..] string;
    pat := pattern;
    if pat == "" pat = "*";

    count: s32 = 0;
    list := SDL_GlobDirectory(to_c_string(path), to_c_string(pat), 0, *count);
    if list == null return results, false;

    for i: 0..count - 1 {
        name := cstr_to_string(list[i]);
        array_add(*results, copy_string(name));
        SDL_free(list[i]);
    }
    SDL_free(list);
    return results, true;
}
