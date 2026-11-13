#scope_module
using Basic;   // module-private
using Math;
#scope_export

// Small platform shims used by the framework (sleep, thread id, mutex).

#if OS == .WINDOWS {
    Windows :: #import "Windows";

    Mutex :: struct {
        crit: Windows.CRITICAL_SECTION;
    }

    mutex_init :: (m: *Mutex)    { Windows.InitializeCriticalSection(*m.crit); }
    mutex_destroy :: (m: *Mutex) { Windows.DeleteCriticalSection(*m.crit); }
    mutex_lock :: (m: *Mutex)    { Windows.EnterCriticalSection(*m.crit); }
    mutex_unlock :: (m: *Mutex)  { Windows.LeaveCriticalSection(*m.crit); }

    sleep_ms :: (ms: s32) { Windows.Sleep(ms); }

    current_thread_id :: () -> u32 { return Windows.GetCurrentThreadId(); }
} else #if OS == .WASM {
    // Web target: single-threaded, and there is no pthread to import (POSIX is
    // also unusable — its module #assert's on any non-native platform). A mutex
    // therefore only has to be a bool: reentrancy and contention cannot happen
    // because there is exactly one thread.
    Mutex :: struct {
        locked: bool;
    }

    mutex_init :: (m: *Mutex)    { m.locked = false; }
    mutex_destroy :: (m: *Mutex) { m.locked = false; }
    mutex_lock :: (m: *Mutex)    { m.locked = true; }
    mutex_unlock :: (m: *Mutex)  { m.locked = false; }

    // Blocking inside the rAF callback would freeze the tab, so this is a
    // deliberate no-op. app_tick's fixed-step "do not run too fast" loop still
    // terminates, because platform_time_seconds() advances off the WASI clock;
    // it just spins instead of sleeping until W2 puts requestAnimationFrame /
    // Atomics.wait behind it.
    sleep_ms :: (ms: s32) { }

    current_thread_id :: () -> u32 { return 1; }
} else {
    POSIX :: #import "POSIX";

    Mutex :: struct {
        m: POSIX.pthread_mutex_t = POSIX.PTHREAD_MUTEX_INITIALIZER;
    }

    mutex_init :: (m: *Mutex)    { POSIX.pthread_mutex_init(*m.m, null); }
    mutex_destroy :: (m: *Mutex) { POSIX.pthread_mutex_destroy(*m.m); }
    mutex_lock :: (m: *Mutex)    { POSIX.pthread_mutex_lock(*m.m); }
    mutex_unlock :: (m: *Mutex)  { POSIX.pthread_mutex_unlock(*m.m); }

    sleep_ms :: (ms: s32) {
        t: POSIX.timespec;
        t.tv_sec  = cast(time_t) (ms / 1000);
        t.tv_nsec = cast(s64)    (ms % 1000) * 1_000_000;
        POSIX.nanosleep(*t, null);
    }

    current_thread_id :: () -> u32 {
        #if OS == .MACOS {
            return cast(u32) POSIX.pthread_mach_thread_np(POSIX.pthread_self());
        } else {
            return cast(u32) POSIX.gettid();
        }
    }
}

// Monotonic seconds (used for the app timer / fixed-step accumulator).
//
// Web 目标用**宿主喂进来的 dt 累加的虚拟时钟**，不用 WASI 的 monotonic：
//   * headless（--virtual-time-budget）里虚拟时间和墙钟差得很远，用 WASI 时钟会让
//     app_tick 的固定步长累加器永远攒不满 delta，一帧 app_step 都跑不出来；
//   * 浏览器切标签页回来时会甩一个巨大的 dt，虚拟时钟天然被宿主钳死。
// app_web_frame(dt) 每帧调 web_advance_clock(dt) 推进它。
#if OS == .WASM {
    web_clock_seconds: float64;

    web_advance_clock :: (dt: float64) {
        if dt > 0.0 web_clock_seconds += dt;
    }

    platform_time_seconds :: () -> float64 {
        return web_clock_seconds;
    }
} else {
    platform_time_seconds :: () -> float64 {
        t := current_time_monotonic();
        s, success := to_float64_seconds(t);
        assert(success);
        return s;
    }
}
