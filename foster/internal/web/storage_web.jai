#scope_module
using Basic;
#scope_export

// jfoster — 存档后端，web (wasm64) 版本。
//
// ===========================================================================
// 浏览器里没有文件系统，但有一个「键值存储」
// ===========================================================================
// 桌面端存档走 SDL_GetPrefPath() 给的真实目录，读写是 File 模块。浏览器里
// 两者都不存在，能用的只有两样东西：
//
//   * localStorage   —— 同步、字符串键值、容量小（各浏览器 5~10 MB）、
//                       只能在同源窗口里看见。**同步**这一点是关键。
//   * OPFS           —— 真正的文件系统（navigator.storage.getDirectory），
//                       容量大、能存二进制，但 API 是 Promise，**没有同步版本**
//                       （除非开 worker + FileSystemSyncAccessHandle）。
//
// 而我们的桥是同步的：wasm 导出 `fw_step` 不能 await。所以最终结构是三层：
//
//   1. **内存 Map**：真值。读永远同步、立刻，零失败。
//   2. **localStorage**：boot 时整份载入内存，每次写立刻同步回写。这是
//      「关掉标签页再回来还在」的那一层。
//   3. **OPFS 镜像**：后台异步，把同一份数据也写到 OPFS（容量大、不会被
//      「清除站点数据」的 localStorage 策略牵连）。读不用它，所以异步没关系。
//
// 于是：有 localStorage → 同步可用；没有（Node / file:// 的某些配置）→ 退化成
// 纯内存，本轮会话内可用；OPFS 只当耐久备份。三条都在 host.js 里，Jai 侧看到
// 的永远只是 `fw_storage_*` 四个同步导入。
//
// ===========================================================================
// 路径模型
// ===========================================================================
// web 目标是**扁平键空间**：没有目录，只有 "save/slot1.dat" 这样的键。为了
// 让桌面的 Storage_Container 语义照旧能用，约定：
//
//   * 键 = 归一化后的相对路径（'/' 分隔，无前导 '/'）
//   * app_user_path() 返回 "/save/"（虚拟根）
//   * "目录" 就是键前缀：目录存在 == 至少有一个键以 "<dir>/" 开头
//   * folder_create 是空操作（键空间隐式创建），但返回 true —— 浏览器里它
//     确实不需要预先创建
//
// ===========================================================================

// 一次读/列的静态缓冲区。存档文件（设置、存档槽）远小于这个；超了会截断并
// 记一条警告（不静默）。
WEB_STORAGE_BUF :: 262144; // 256 KiB
web_storage_buf: [WEB_STORAGE_BUF] u8;
web_storage_truncated_warned: bool;

// 归一化：'\\' → '/'，去掉前导 '/'，折叠重复的 '/'。
WEB_STORAGE_KEY_MAX :: 512;
web_storage_key_buf: [WEB_STORAGE_KEY_MAX] u8;

// 归一化：反斜杠转正斜杠，吃掉前导 "/"，折叠重复的 "/"。
//
// 注意：jacket 的 String_Builder 没有 .count（只有一个 Buffer 链），而这里要的
// 是字节数，所以直接写静态缓冲区 —— 顺便零分配，这个函数每帧都会被存档路径调到。
web_storage_key :: (path: string) -> string {
    n: s32 = 0;
    prev_slash := true; // true 让前导 "/" 被吃掉
    for c: path {
        ch := c;
        if ch == #char "\\" ch = #char "/";
        if ch == #char "/" {
            if prev_slash continue;
            prev_slash = true;
        } else {
            prev_slash = false;
        }
        if n >= WEB_STORAGE_KEY_MAX - 1 break;
        web_storage_key_buf[n] = ch;
        n += 1;
    }
    return web_str_of(*web_storage_key_buf[0], n);
}

// 文件长度；-1 = 不存在。cap=0 的读 == 查长度。
web_storage_size :: (path: string) -> s32 {
    key := web_storage_key(path);
    if key.count <= 0 return -1;
    return fw_storage_read(web_str_off(key), cast(s32) key.count, 0, 0);
}

web_storage_file_exists :: (path: string) -> bool {
    return web_storage_size(path) >= 0;
}

// 读整个文件。返回的 string 指向静态缓冲区，**下一次读会覆盖它** —— 调用方要
// 留住内容就自己 copy_string（storage.jai 的两个入口都会立刻转交给
// File.read_entire_file 的等价物，所以这里选择零分配）。
web_storage_read_file :: (path: string) -> (string, bool) {
    key := web_storage_key(path);
    if key.count <= 0 return "", false;

    declared := fw_storage_read(web_str_off(key), cast(s32) key.count, 0, 0);
    if declared < 0 return "", false; // 不存在
    if declared == 0 return "", true; // 存在但是空文件

    cap := declared;
    if cap > WEB_STORAGE_BUF {
        cap = WEB_STORAGE_BUF;
        if !web_storage_truncated_warned {
            web_storage_truncated_warned = true;
            log_warning(tprint("web_storage_read_file: '%' 有 % 字节，超过静态缓冲区 %，只读到前 % 字节",
                               key, declared, WEB_STORAGE_BUF, cap));
        }
    }

    got := fw_storage_read(web_str_off(key), cast(s32) key.count,
                           cast(s32) cast(u64) *web_storage_buf[0], cap);
    if got < 0 return "", false;
    if got > cap got = cap;

    return web_str_of(*web_storage_buf[0], got), true;
}

web_storage_write_file :: (path: string, data: string) -> bool {
    key := web_storage_key(path);
    if key.count <= 0 return false;

    off := ifx data.count > 0 then web_str_off(data) else 0;
    return fw_storage_write(web_str_off(key), cast(s32) key.count,
                            off, cast(s32) data.count) >= 0;
}

web_storage_file_delete :: (path: string) -> bool {
    key := web_storage_key(path);
    if key.count <= 0 return false;
    return fw_storage_remove(web_str_off(key), cast(s32) key.count) >= 0;
}

// 列出一层目录名（"a/b/c" 前缀下，返回直接子项的名字）。
// 返回 false = 这个前缀下什么都没有。
web_storage_list :: (prefix: string) -> ([] string, bool) {
    out: [..] string;
    key := web_storage_key(prefix);

    n := fw_storage_list(web_str_off(key), cast(s32) key.count,
                         cast(s32) cast(u64) *web_storage_buf[0], WEB_STORAGE_BUF);
    if n <= 0 return out, false;
    if n > WEB_STORAGE_BUF n = WEB_STORAGE_BUF;

    // 桥用 '\n' 分隔返回（键空间里的键不可能含换行：我们是唯一的写者）。
    start := 0;
    for i: 0..n {
        if i < n && web_storage_buf[i] != #char "\n" continue;
        if i > start {
            name := web_str_of(*web_storage_buf[start], cast(s32) (i - start));
            array_add(*out, copy_string(name));
        }
        start = i + 1;
    }
    return out, true;
}

web_storage_dir_exists :: (path: string) -> bool {
    entries, ok := web_storage_list(path);
    return ok && entries.count > 0;
}
