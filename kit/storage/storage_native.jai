// 平台根目录（桌面）—— 对位 olib kit/storage/storage_native.odin（`#+build !js`）。
// Jai 侧用 `#if OS != .WASM` 对位 Odin 的 `#+build !js`；Web 分支见 storage_web.jai。
//
// olib 在这里用的 core:os，Jai 侧对应关系（行为不变）：
//
//   | olib (Odin)                              | 这里 (Jai)                                                     |
//   | ---------------------------------------- | -------------------------------------------------------------- |
//   | os.get_working_directory(allocator)      | get_working_directory()（Basic，返回 temp 字符串）+ 拷进 allocator |
//   | os.get_executable_path(allocator)        | SYS.get_path_of_running_executable()（System 模块，temp 字符串）  |
//   | os.get_env_alloc(name, allocator)        | storage_get_env（Windows: GetEnvironmentVariableA / POSIX: getenv）|
//   | os.make_directory_all(path)              | FILE.make_directory_if_it_does_not_exist(path, recursive = true) |
//   | strings.last_index(exe, "/") / ("\\")     | 一趟遍历记下最后一个 '/' 或 '\\' 的下标                          |
//   | strings.clone(exe[:sep], allocator)      | storage_copy_string(exe[:sep], allocator)                       |
//   | or_else ""                               | 失败时返回 ""（分配失败即空串）                                   |
//
// 平台分支照搬 olib：
//   Windows  %APPDATA%\<app_name>
//   macOS    $HOME/Library/Application Support/<app_name>
//   Linux 等 $XDG_CONFIG_HOME/<app_name>，缺省 $HOME/.config/<app_name>
// 注意：jfoster 也绑了 SDL_GetPrefPath（SDL_filesystem.jai），但 SDL 会在应用名前面
// 再插一层组织名（%APPDATA%\<org>\<app>），与 olib 的路径策略不同，故这里不用它，
// 而是按 olib 的分支直接读环境变量；未初始化 SDL 时也能取到用户根。
#import "Basic";

#if OS != .WASM {

    //@region 环境变量与字符串（Jai 侧新增的桥接，olib 由 core:os 提供）

    #if OS == .WINDOWS {
        storage_kernel32 :: #library,system "kernel32";
        // 用 W 版：olib 的 core:os 在 Windows 上走 UTF-16，A 版会把非 ASCII 用户名（如中文）
        // 变成 ANSI 代码页字节，和 Jai/File 期望的 UTF-8 不一致。
        storage_get_environment_variable_w :: (name: *u16, buffer: *u16, size: u32) -> u32 #foreign storage_kernel32 "GetEnvironmentVariableW";
    } else {
        storage_libc :: #library,system "c";
        storage_getenv :: (name: *u8) -> *u8 #foreign storage_libc "getenv";
    }

    #if OS == .WINDOWS { // Jai 只接受带花括号的编译期分支
        // UTF-16 → UTF-8。olib 由 core:os 的 UTF-16 API 顺带完成；Jai 侧没有跨编译器的 UTF-8 模块
        // （jacket 叫 Windows_Utf8、官方叫 Utf8），所以这里自带最小编解码：BMP + 代理对，
        // 孤立代理写成 U+FFFD。units 不要求 0 结尾，长度由 count 给。
        storage_wide_to_utf8 :: (units: *u16, count: s64, allocator: Allocator) -> string {
            if count <= 0 return "";

            push_allocator(allocator);
            // UTF-8 每单元最多 3 字节（代理对 2 单元 → 4 字节），按 3 * count 预留。
            out := alloc_string(cast(int) (count * 3));
            if !out return "";

            n: s64 = 0;
            i: s64 = 0;
            while i < count {
                unit := units[i];
                i += 1;

                code: u32;
                if unit >= 0xD800 && unit <= 0xDBFF {
                    // 高位代理：后面必须跟低位代理，否则算非法。
                    if i < count && units[i] >= 0xDC00 && units[i] <= 0xDFFF {
                        low := units[i];
                        i += 1;
                        code = 0x10000 + ((cast(u32) (unit - 0xD800)) << 10) + cast(u32) (low - 0xDC00);
                    } else {
                        code = 0xFFFD;
                    }
                } else if unit >= 0xDC00 && unit <= 0xDFFF {
                    code = 0xFFFD; // 孤立低位代理
                } else {
                    code = unit;
                }

                if code < 0x80 {
                    out[n] = cast(u8) code;
                    n += 1;
                } else if code < 0x800 {
                    out[n] = cast(u8) (0xC0 | (code >> 6));
                    out[n + 1] = cast(u8) (0x80 | (code & 0x3F));
                    n += 2;
                } else if code < 0x10000 {
                    out[n] = cast(u8) (0xE0 | (code >> 12));
                    out[n + 1] = cast(u8) (0x80 | ((code >> 6) & 0x3F));
                    out[n + 2] = cast(u8) (0x80 | (code & 0x3F));
                    n += 3;
                } else {
                    out[n] = cast(u8) (0xF0 | (code >> 18));
                    out[n + 1] = cast(u8) (0x80 | ((code >> 12) & 0x3F));
                    out[n + 2] = cast(u8) (0x80 | ((code >> 6) & 0x3F));
                    out[n + 3] = cast(u8) (0x80 | (code & 0x3F));
                    n += 4;
                }
            }

            out.count = n;
            return out;
        }
    } // #if

    // 环境变量名转 UTF-16（我们只用 APPDATA / HOME / XDG_CONFIG_HOME，都是 ASCII）。
    #if OS == .WINDOWS {
        storage_wide_name :: (name: string, buffer: *[64] u16) -> bool {
            if name.count + 1 > 64 return false;
            for c, i: name {
                if c >= 0x80 return false;
                buffer.*[i] = cast(u16) c;
            }
            buffer.*[name.count] = 0;
            return true;
        }
    } // #if

    // olib 的 os.get_env_alloc(name, allocator)：值不存在返回 ""。
    // 结果归 allocator 所有（不是 temp），调用方按 olib 的约定 delete。
    storage_get_env :: (name: string, allocator: Allocator) -> string {
        #if OS == .WINDOWS {
            wide: [64] u16;
            if !storage_wide_name(name, *wide) return "";

            // 值的缓冲区放栈上（路径长度远小于 2048 个 UTF-16 单元）。
            buffer: [2048] u16;
            written := storage_get_environment_variable_w(wide.data, buffer.data, xx buffer.count);
            if written == 0 || written >= buffer.count return "";

            return storage_wide_to_utf8(buffer.data, cast(s64) written, allocator);
        } else {
            value := storage_getenv(temp_c_string(name));
            if value == null return "";

            length: s64 = 0;
            while value[length] != 0 length += 1;
            if length == 0 return "";

            push_allocator(allocator);
            out := alloc_string(cast(int) length);
            if !out return "";
            memcpy(out.data, value, length);
            return out;
        }
    }

    // strings.clone(s, allocator) 的对位：总是新分配，失败返回空字符串。
    storage_copy_string :: (s: string, allocator: Allocator) -> string {
        if !s.count return "";
        push_allocator(allocator);
        out := alloc_string(s.count);
        if !out return "";
        memcpy(out.data, s.data, s.count);
        return out;
    }

    // os.make_directory_all 的对位（File 模块的 recursive 版本会逐级建目录）。
    // 已经存在时返回 true，与 olib 的「不为 nil 即成功」等价。
    storage_make_directory_all :: (path: string) -> bool {
        return FILE.make_directory_if_it_does_not_exist(path, true);
    }
    //@endregion

    //@region 资源根 —— 开发期 cwd / 发布版 exe 目录

    // 开发期资源根：当前目录（把工作目录设到项目根，编辑器改的文件立即可见）。
    // olib 把结果分配于 allocator；Basic 的 get_working_directory 返回 temp 字符串，
    // 这里按 olib 的契约复制进 allocator。
    resources_root_dev :: (allocator := context.allocator) -> string {
        dir := get_working_directory();
        if dir == "" return "";
        return storage_copy_string(dir, allocator);
    }

    // 发布版资源根：exe 所在目录（游戏连同 Resources/ 一起分发时用）；
    // 取不到 exe 路径时退回 cwd。
    resources_root_release :: (allocator := context.allocator) -> string {
        exe := SYS.get_path_of_running_executable();
        if exe == "" return resources_root_dev(allocator);

        // olib: sep := max(strings.last_index(exe, "/"), strings.last_index(exe, "\\"))
        // System 模块在 Windows 上已把 '\' 换成 '/'，这里仍按 olib 两个分隔符都认。
        sep: s64 = -1;
        for c, i: exe {
            if c == #char "/" || c == #char "\\" sep = i;
        }
        if sep < 0 return "";

        return storage_copy_string(.{ data = exe.data, count = sep }, allocator);
    }
    //@endregion

    //@region 用户根 —— 平台 pref 路径（自动建目录）

    // 计算用户数据根目录并确保存在；失败（无 HOME/APPDATA 等）返回 ""。
    // 路径分配于传入 allocator（默认 context），调用方持有。
    user_root :: (app_name: string, allocator := context.allocator) -> string {
        if !valid_app_name(app_name) return "";
        #if OS == .WINDOWS {
            base := storage_get_env("APPDATA", allocator);
            if base == "" return "";
            defer storage_free(base, allocator);

            root := storage_path_join(base, app_name, allocator);
            if root == "" return "";
            if !storage_make_directory_all(root) {
                storage_free(root, allocator);
                return "";
            }
            return root;
        } else #if OS == .MACOS {
            home := storage_get_env("HOME", allocator);
            if home == "" return "";
            defer storage_free(home, allocator);

            support := storage_path_join(home, "Library/Application Support", allocator);
            if support == "" return "";
            root := storage_path_join(support, app_name, allocator);
            storage_free(support, allocator);
            if root == "" return "";
            if !storage_make_directory_all(root) {
                storage_free(root, allocator);
                return "";
            }
            return root;
        } else {
            base := storage_get_env("XDG_CONFIG_HOME", allocator);
            if base == "" {
                home := storage_get_env("HOME", allocator);
                if home == "" return "";
                defer storage_free(home, allocator);
                base = storage_path_join(home, ".config", allocator);
                if base == "" return "";
            }
            defer storage_free(base, allocator);

            root := storage_path_join(base, app_name, allocator);
            if root == "" return "";
            if !storage_make_directory_all(root) {
                storage_free(root, allocator);
                return "";
            }
            return root;
        }
    }
    //@endregion

}
