// session —— 宿主侧的加载/替换/卸载会话：游戏 DLL 的影子副本、协议校验、快照交接。
// 一比一移植自 olib core/hotreload/session.odin。
//
// Jai 侧差异（本文件）：
//   - odin 的 `import "core:dynlib"` 在 jacket 里没有对应模块（也没有 load_dynamic_library），
//     所以这里用 `#library,system "kernel32"` + `#foreign` 自备最小声明集
//     LoadLibraryW / GetProcAddress / FreeLibrary / GetLastError；`dynlib.Library` → `*void`，
//     `dynlib.LIBRARY_FILE_EXTENSION` → 本文件的 LIBRARY_FILE_EXTENSION，路径用
//     Windows_Utf8.utf8_to_wide_new 转宽字符，导出名用 to_c_string 转 C 字符串。
//     scan_windows.jai 已经占用了 `kernel32` 这个名字，同一作用域不能重名，所以这里叫
//     `session_kernel32`（链接的是同一个系统库）。
//   - odin 的 `os.create_temp_file(dir, ".olib-reload-*.dll")` 换成「自己拼唯一名字（计数器 +
//     单调纳秒）+ 平台层独占创建 hotreload_create_exclusive_file」，jacket 没有创建临时文件的过程。
//   - `filepath.abs` → FILE.get_absolute_path（同样返回规范化绝对路径，分隔符统一成 `/`）；
//     `filepath.dir` → STRING.path_strip_filename，注意 **它带结尾分隔符**（odin 的不带），
//     所以拼路径时写成 `"%.olib-reload-...", directory`，不再补 `/`。
//   - `os.copy_file` → FU.copy_file（目标已存在则覆盖，语义相同）；`os.remove` → FILE.file_delete。
//     odin 能在诊断里带 `%v` 的错误内容，Jai 的 copy_file 只回答成功与否，诊断只写「不能复制」。
//   - `strings.clone` → copy_string；`delete(str, alloc)` → free。jacket 的 free 用的是**当前**
//     allocator，所以 odin 的 `context.allocator = s.allocator` 在这里统一写成 push_allocator，
//     分配与释放落在同一把尺子上。
//   - `make([]u8, n, s.allocator)` → 先设 count 再 alloc(n)（Jai 的 make 不接分配器）。
//   - odin 的 `s^ = {...}` → `s.* = Session.{...}`；取址 `&x` → `*x`。
//   - odin 的错误值（`path_err != nil`）在 Jai 侧换成空串/布尔判定。
//   - 回调里的 `context = call.host_context^` 由模块自己写，宿主这一侧只负责把 host_context
//     指向本帧的 context 副本，与 odin 完全一致。
//
// 平台分支：Windows 用 LoadLibraryW 系列；非 Windows 用 dlopen 系列（按 POSIX 写，
// **本次验收没有跑过**，见 session_other 区域）。
#import "Basic";
S_FILE :: #import "File";
S_FU :: #import "File_Utilities";
S_STRING :: #import "String";

// odin: dynlib.LIBRARY_FILE_EXTENSION。watch.jai 拼产物文件名时也用它。
#if OS == .WINDOWS LIBRARY_FILE_EXTENSION :: "dll";
#if OS == .MACOS LIBRARY_FILE_EXTENSION :: "dylib";
#if OS != .WINDOWS && OS != .MACOS LIBRARY_FILE_EXTENSION :: "so";

//@region 平台层（动态库）

// odin 的 dynlib.Library 是不透明句柄；Jai 侧统一用 *void。
// 打开失败返回 null，诊断由 session_library_error_text 给出。
#if OS == .WINDOWS {
    SESSION_WU :: #import "Windows_Utf8";

    session_kernel32 :: #library,system "kernel32";
    session_load_library_w :: (path: *u16) -> *void #foreign session_kernel32 "LoadLibraryW";
    session_get_proc_address :: (library: *void, name: *u8) -> *void #foreign session_kernel32 "GetProcAddress";
    session_free_library :: (library: *void) -> s32 #foreign session_kernel32 "FreeLibrary";
    session_get_last_error :: () -> u32 #foreign session_kernel32 "GetLastError";

    session_library_open :: (path: string) -> *void {
        wide := SESSION_WU.utf8_to_wide_new(path);
        if wide == null return null;
        defer free(wide);
        return session_load_library_w(wide);
    }

    session_library_symbol :: (library: *void, name: string) -> *void {
        c_name := to_c_string(name);
        defer free(c_name);
        return session_get_proc_address(library, c_name);
    }

    session_library_close :: (library: *void) {
        if library != null session_free_library(library);
    }

    // odin: dynlib.last_error()。这里只说「打不开」和 GetLastError 的编号，字符串用调用方的 allocator。
    session_library_error_text :: () -> string {
        return sprint("Cannot load module (GetLastError=%)", session_get_last_error());
    }
}

// 非 Windows：odin 仍用 core:dynlib；Jai 侧按 POSIX dlopen 写一份对位实现。
// 注意：这条分支在 Windows 上整块不类型检查，也没有在 CI 里跑过（验收平台是 Windows）。
#if OS != .WINDOWS {
    #if OS == .LINUX || OS == .ANDROID session_dl :: #library,system "dl";
    #if OS != .LINUX && OS != .ANDROID session_dl :: #library,system "System";

    RTLD_NOW: s32 : 2;

    session_dlopen :: (path: *u8, mode: s32) -> *void #foreign session_dl "dlopen";
    session_dlsym :: (library: *void, name: *u8) -> *void #foreign session_dl "dlsym";
    session_dlclose :: (library: *void) -> s32 #foreign session_dl "dlclose";
    session_dlerror :: () -> *u8 #foreign session_dl "dlerror";

    session_library_open :: (path: string) -> *void {
        c_path := to_c_string(path);
        defer free(c_path);
        return session_dlopen(c_path, RTLD_NOW);
    }

    session_library_symbol :: (library: *void, name: string) -> *void {
        c_name := to_c_string(name);
        defer free(c_name);
        return session_dlsym(library, c_name);
    }

    session_library_close :: (library: *void) {
        if library != null session_dlclose(library);
    }

    session_library_error_text :: () -> string {
        message := session_dlerror();
        if message == null return copy_string("Cannot load module");
        return sprint("Cannot load module (%): %", "", to_string(message));
    }
}
//@endregion

//@region 影子副本

// odin 用 os.create_temp_file(dir, ".olib-reload-*.dll") 拿一个已独占创建的唯一名字；
// jacket 没有等价过程，这里自己拼名字（进程内计数器 + 单调纳秒）再交给平台层独占创建：
// 名字被占用就换下一个，和 odin 的临时文件语义一致。
session_shadow_counter: int;

session_create_shadow_copy :: (directory: string) -> (string, bool) {
    for 0..1023 {
        attempt := session_shadow_counter;
        session_shadow_counter += 1;
        // directory 由 STRING.path_strip_filename 给出，已经带结尾分隔符。
        candidate := tprint("%.olib-reload-%_%.%", directory, attempt, scan_monotonic_nano(),
                            LIBRARY_FILE_EXTENSION);
        if !hotreload_create_exclusive_file(candidate) continue;
        return copy_string(candidate), true;
    }
    return "", false;
}
//@endregion

//@region 会话

State_Policy :: enum u8 {
    Compatible; // state_version 不同则拒绝；默认不会静默丢失当前局面。
    Migrate; // 把旧快照交给新模块，由 load 明确接受或拒绝。
    Reset; // 不保存旧状态，明确启动新局。
}

Result :: enum u8 {
    Success;
    Not_Initialized;
    Busy;
    File_Error;
    Library_Error;
    Invalid_API;
    Host_Mismatch;
    State_Mismatch;
    Snapshot_Error;
    Load_Rejected;
}

// 单一宿主线程操作；地址稳定，不复制。没有自动安装宿主框架回调。
// 每帧在上一帧绘制/任务结束、下一帧 update 之前 reload；回调内不得重入。
Session :: struct {
    host_version: u64;
    services: *void;
    allocator: Allocator;
    max_snapshot_bytes: int;
    revision: u64;
    diagnostic: string;
    initialized: bool;
    busy: bool;
    live: Module;
}

// olib 里的 @(private) Module。Jai 没有包内私有，靠命名约定：宿主只碰 Session。
Module :: struct {
    library: *void;
    path: string;
    api: API;
    instance: *void;
    load_called: bool;
}

init :: (s: *Session, host_version: u64, services: *void = null,
         max_snapshot_bytes: int = 64 * 1024 * 1024, allocator: Allocator = context.allocator) -> bool {
    if s.initialized || host_version == 0 || max_snapshot_bytes < 0 return false;
    s.* = Session.{
        host_version = host_version,
        services = services,
        allocator = allocator,
        max_snapshot_bytes = max_snapshot_bytes,
        initialized = true,
    };
    return true;
}

// 返回 false 表示正在回调中，调用方应在帧外重试。
dispose :: (s: *Session) -> bool {
    if s.busy return false;
    if !s.initialized return true;
    s.busy = true;
    module_dispose(s, *s.live);
    session_copy_diagnostic(s, "");
    s.* = Session.{};
    return true;
}

is_live :: (s: *Session) -> bool {
    return s.live.library != null;
}

// source 必须是已完整编译、不会继续写入的产物。复制到同目录独立文件，
// 避免 Windows 锁住编译输出；原文件与同目录依赖均不归会话所有。
// 候选 API/快照/load 失败均保留旧模块；不隔离崩溃或模块擅自修改宿主的副作用。
reload :: (s: *Session, source: string, policy: State_Policy = .Compatible) -> Result {
    if !s.initialized return .Not_Initialized;
    if s.busy return .Busy;
    s.busy = true;
    defer s.busy = false;
    push_allocator(s.allocator);
    candidate: Module;
    // 候选无论成功与否都在这里收尾：成功后 candidate 已经清空，只关多余资源。
    defer module_dispose(s, *candidate);
    absolute, resolved := S_FILE.get_absolute_path(source);
    if !resolved || absolute.count == 0 return fail(s, .File_Error, "Cannot resolve module path");
    defer if absolute.data != null free(absolute);
    shadow, created := session_create_shadow_copy(S_STRING.path_strip_filename(absolute));
    if !created return fail(s, .File_Error, "Cannot create module shadow copy");
    candidate.path = shadow;
    if !S_FU.copy_file(absolute, candidate.path) {
        return fail(s, .File_Error, "Cannot copy module");
    }
    library := session_library_open(candidate.path);
    if library == null {
        session_take_diagnostic(s, session_library_error_text());
        return .Library_Error;
    }
    candidate.library = library;
    address := session_library_symbol(library, ENTRY_SYMBOL);
    if address == null return fail(s, .Invalid_API, "Missing olib_game_api export");
    get_api := cast(Get_API) address;
    if !get_api(API_VERSION, size_of(API), *candidate.api) || !api_valid(candidate.api) {
        return fail(s, .Invalid_API, "Module protocol or required callbacks are invalid");
    }
    if candidate.api.host_version != s.host_version {
        return fail(s, .Host_Mismatch, "Host ABI changed; rebuild and restart host");
    }
    if is_live(s) && policy == .Compatible &&
       candidate.api.state_version != s.live.api.state_version {
        return fail(s, .State_Mismatch, "State format changed; explicitly migrate or reset");
    }
    callback_context := context;
    old_call := Call.{
        host_context = *callback_context,
        services = s.services,
        instance = s.live.instance,
    };
    snapshot: Snapshot;
    // odin 的 defer delete(snapshot.data, s.allocator)：Jai 的 defer 只在同一块内生效，
    // 所以提到函数作用域，并自己判空。
    defer if snapshot.data.data != null free(snapshot.data.data);
    if is_live(s) && policy != .Reset {
        n := s.live.api.snapshot_size(*old_call);
        if n < 0 || n > s.max_snapshot_bytes {
            return fail(s, .Snapshot_Error, "Snapshot size is invalid or exceeds configured limit");
        }
        if n > 0 {
            snapshot.data.count = n;
            snapshot.data.data = cast(*u8) alloc(n);
        }
        snapshot.version = s.live.api.state_version;
        if !s.live.api.save(*old_call, snapshot.data) {
            return fail(s, .Snapshot_Error, "Old module could not serialize state");
        }
    }
    new_call := Call.{ host_context = *callback_context, services = s.services };
    candidate.load_called = true;
    accepted := candidate.api.load(*new_call, snapshot);
    candidate.instance = new_call.instance;
    if !accepted return fail(s, .Load_Rejected, "Candidate rejected state or initialization failed");
    // 旧状态一直保留到新状态完整建立；旧模块清理仍在旧代码有效时执行。
    module_dispose(s, *s.live);
    s.live = candidate;
    candidate = Module.{};
    s.revision += 1;
    if s.live.api.activate != null s.live.api.activate(*new_call);
    session_copy_diagnostic(s, "");
    return .Success;
}

update :: (s: *Session, dt: float64, frame: *void = null) {
    dispatch(s, false, dt, frame);
}

render :: (s: *Session, dt: float64, frame: *void = null) {
    dispatch(s, true, dt, frame);
}

dispatch :: (s: *Session, rendering: bool, dt: float64, frame: *void) {
    if !is_live(s) || s.busy return;
    s.busy = true;
    defer s.busy = false;
    callback_context := context;
    callback_context.allocator = s.allocator;
    call := Call.{
        host_context = *callback_context,
        services = s.services,
        instance = s.live.instance,
        frame = frame,
    };
    callback := ifx rendering then s.live.api.render else s.live.api.update;
    if callback != null callback(*call, dt);
}

api_valid :: (api: API) -> bool {
    return api.state_version != 0 && api.load != null && api.unload != null &&
           api.snapshot_size != null && api.save != null && api.update != null && api.render != null;
}

module_dispose :: (s: *Session, m: *Module) {
    push_allocator(s.allocator);
    callback_context := context;
    callback_context.allocator = s.allocator;
    if m.load_called {
        call := Call.{
            host_context = *callback_context,
            services = s.services,
            instance = m.instance,
        };
        m.api.unload(*call);
    }
    session_library_close(m.library);
    if m.path.count > 0 {
        // 卸载失败时 Windows 会保留锁定文件，不强删用户目录或依赖。
        S_FILE.file_delete(m.path);
        free(m.path);
    }
    m.* = Module.{};
}

// odin: fail(s, result, message) —— 借用 message，内部复制一份（用会话的 allocator）。
fail :: (s: *Session, result: Result, message: string) -> Result {
    session_copy_diagnostic(s, message);
    return result;
}

// 接管 message 的所有权；旧诊断先释放。message 必须是用 s.allocator 分配的。
session_take_diagnostic :: (s: *Session, message: string) {
    push_allocator(s.allocator);
    if s.diagnostic.data != null free(s.diagnostic);
    s.diagnostic = message;
}

// 借用 message，复制一份存进会话诊断。
session_copy_diagnostic :: (s: *Session, message: string) {
    push_allocator(s.allocator);
    session_take_diagnostic(s, ifx message.count > 0 then copy_string(message) else "");
}
//@endregion
