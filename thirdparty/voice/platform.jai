#scope_module
Env :: #import "Extensions/Environment";

Stopwatch :: struct {
    running: bool;
    origin: float64;
}

stopwatch_start :: (s: *Stopwatch) {
    s.running = true;
    s.origin = monotonic_seconds();
}

stopwatch_seconds :: (s: Stopwatch) -> float64 {
    return monotonic_seconds() - s.origin;
}

#if OS == .WINDOWS {
    W :: #import "Windows";
    Utf8 :: #import "Windows_Utf8";

    kernel :: #library,system "kernel32";
    open_native :: (name: *u16) -> *void #foreign kernel "LoadLibraryW";
    symbol_native :: (lib: *void, name: *u8) -> *void #foreign kernel "GetProcAddress";
    close_native :: (lib: *void) -> s32 #foreign kernel "FreeLibrary";

    monotonic_seconds :: () -> float64 {
        ticks, frequency: s64;
        assert(W.QueryPerformanceCounter(*ticks) != 0);
        assert(W.QueryPerformanceFrequency(*frequency) != 0 && frequency > 0);
        return cast(float64) ticks / cast(float64) frequency;
    }

    open_library :: (name: string) -> *void {
        wide := Utf8.utf8_to_wide_new(name);
        if wide == null return null;
        defer free(wide);
        return open_native(wide);
    }
} else {
    P :: #import "POSIX";

    #if OS == .LINUX || OS == .ANDROID dl :: #library,system "dl";
    else dl :: #library,system "System";
    open_native :: (name: *u8, flags: s32) -> *void #foreign dl "dlopen";
    symbol_native :: (lib: *void, name: *u8) -> *void #foreign dl "dlsym";
    close_native :: (lib: *void) -> s32 #foreign dl "dlclose";

    monotonic_seconds :: () -> float64 {
        t: P.timespec;
        assert(P.clock_gettime(P.clockid_t.MONOTONIC, *t) == 0);
        return cast(float64) t.tv_sec + cast(float64) t.tv_nsec / 1e9;
    }

    open_library :: (name: string) -> *void {
        c := to_c_string(name);
        defer free(c);
        return open_native(c, 2);
    }
}

load_shared_library :: (file: string) -> *void, bool {
    lib := open_library(file);
    if lib != null return lib, true;
    dir := Env.environment_variable("VOICE_LIB_DIR");
    if dir != "" {
        path := sprint("%/%", dir, file);
        defer free(path);
        lib = open_library(path);
        if lib != null return lib, true;
    }
    path := sprint("build/%", file);
    defer free(path);
    lib = open_library(path);
    return lib, lib != null;
}

unload_shared_library :: (lib: *void) {
    if lib != null close_native(lib);
}

shared_symbol_ptr :: (lib: *void, name: string) -> *void {
    if lib == null return null;
    c := to_c_string(name);
    defer free(c);
    return symbol_native(lib, c);
}

shared_library_file :: (stem: string) -> string {
    push_allocator(temp);
    #if OS == .WINDOWS return sprint("%.dll", stem);
    else #if OS == .MACOS return sprint("lib%.dylib", stem);
    else return sprint("lib%.so", stem);
}
