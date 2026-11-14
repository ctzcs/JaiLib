#scope_module
using Basic;
#scope_export

// 目录操作兼容层 — web (wasm64) 版本。W2：接上真实存储后端。
//
// `utility/folder.jai` 用 SDL3 的文件系统接口（SDL_GetPathInfo /
// SDL_CreateDirectory / SDL_RemovePath / SDL_GlobDirectory）补齐官方 Jai 与
// jacket stdlib 都没有的 folder_exists / folder_create / folder_delete /
// folder_enum。wasm 模块里没有这些东西：浏览器不暴露文件系统，WASI 的 preopen
// 目录在浏览器里也不存在。
//
// 所以这里给同名、同签名的一版，底层是 internal/web/storage_web.jai 的虚拟键
// 空间（内存 + localStorage + OPFS 镜像，见那个文件的头部）。语义映射：
//
//   文件           → 一个键
//   目录           → 键前缀（"a/b" 存在 == 有键以 "a/b/" 开头）
//   folder_create  → 空操作，返回 true（键空间按需隐式创建）
//   folder_delete  → 删掉这个前缀下的所有键
//   jf_file_exists → 键存在
//
// 读文件内容的两个原语（web_storage_read_file / write_file）在同一层，但由
// storage/storage.jai 的 #if OS == .WASM 分支调用，因为它读的是 File 模块。

FILE :: #import "File";

jf_file_exists :: (path: string) -> bool {
    return web_storage_file_exists(path);
}

jf_file_delete :: (path: string) -> bool {
    return web_storage_file_delete(path);
}

folder_exists :: (path: string) -> bool {
    return web_storage_dir_exists(path);
}

// 键空间里没有「空目录」这个概念：创建只为了满足调用方的 mkdir -p 语义。
folder_create :: (path: string) -> bool {
    return true;
}

// 删掉前缀下的所有键（模拟 rm -r）。目录本身不存在也返回 false，和桌面的
// SDL_RemovePath 对不存在路径的行为一致。
folder_delete :: (path: string) -> bool {
    entries, ok := web_storage_list(path);
    if !ok return false;

    removed := false;
    for name: entries {
        full := tprint("%/%", path, name);
        // 名字可能是一层（文件）也可能更深（"a/b/c"）——深的那种交给递归。
        if !web_storage_file_delete(full) {
            folder_delete(full);
        }
        removed = true;
    }
    return removed;
}

// 返回目录下的条目名。recursive=false 只回直接子项（和 SDL_GlobDirectory 一致）。
folder_enum :: (path: string, pattern: string, recursive: bool) -> ([] string, bool) {
    results: [..] string;
    entries, ok := web_storage_list(path);
    if !ok return results, false;

    pat := pattern;
    if pat == "" pat = "*.*";

    for name: entries {
        // 桥给的是「前缀之下的相对键」：可能 "settings.json"，也可能
        // "slot1/state.bin"。非递归时后者的「名字」是 "slot1"。
        trimmed := name;
        if !recursive {
            slash := 0;
            found := false;
            for c, i: trimmed {
                if c == #char "/" {
                    slash = i;
                    found = true;
                    break;
                }
            }
            if found trimmed = web_str_of(trimmed.data, cast(s32) slash);
        }

        if pattern != "" && !match_wildcard(pat, trimmed) continue;

        // 去重：非递归时多个子文件会把同一个目录名报多次。
        duplicate := false;
        for existing: results {
            if existing == trimmed {
                duplicate = true;
                break;
            }
        }
        if duplicate continue;

        array_add(*results, copy_string(trimmed));
    }
    return results, true;
}
