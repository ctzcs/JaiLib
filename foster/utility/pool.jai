#scope_module
using Basic; // module-private
#scope_export

// Port of Foster Framework/Utility/Pool.cs.
//
// C# `Pool<T>` is a *static* queue per closed generic type, reached through
// `Pool.Get<T>()` / `Pool.Return<T>()`. Jai has no per-type statics, so the
// equivalent here is an explicit `Pool($T)` value made with pool_create()
// (typically stored in a global or in the system that owns the objects):
//
//     pool := pool_create(*Enemy, zero_out = enemy_reset, capacity = 64);
//     e := pool_get(*pool);
//     ...
//     pool_return(*pool, e);
//     pool_destroy(*pool);
//
// IPoolable: Jai has no interfaces, so "notified when recycled" is expressed as
// a plain procedure-pointer callback instead of an interface implementation.
// C# `Pool<T>.ZeroOut` == our `zero_out`, and C#'s default ZeroOut (which calls
// IPoolable.Recycle for such types) is what you get by passing your recycle
// procedure as `zero_out`:
//
//     enemy_reset :: (data: *void, e: *Enemy) { e.* = .{}; }
//
// C#'s other default ZeroOut behaviours (auto-Clear of IList, IDictionary,
// HashSet<>, Queue<>, Stack<>) rely on reflection and are not reproduced: with
// zero_out == null the instance is cached untouched, which is exactly C#'s own
// fallback (`static _ => { }`). Pass the matching "clear" procedure instead.
//
// The freed/created bookkeeping is small enough that Pool is a plain struct;
// the cached instances themselves live in a heap array (`context.allocator`).

Pool :: struct($T: Type) {
    // Instances available for reuse. FIFO from `head`, like C#'s ConcurrentQueue.
    available: [..] T;
    head: s32;

    // Maximum number of instances kept for reuse after pool_return.
    // <= 0 means "unbounded", matching C# (its queue grows forever).
    capacity: s32;

    // Called by pool_get when nothing is cached. null = default-construct a
    // zeroed T, which is C#'s `where T : class, new()`.
    // 注意：这里不能写 `= null` —— 官方 Jai 在「泛型结构体的过程字段返回 T」+
    // 默认值时会在同模块的 `-> *Pool(T)` 处报 Unable to parse type instantiation。
    factory: (data: *void) -> T;
    factory_data: *void = null;

    // Called by pool_return on every instance before it is cached
    // (C#: Pool<T>.ZeroOut / IPoolable.Recycle).
    zero_out: (data: *void, item: *T);
    zero_out_data: *void = null;

    // Diagnostics.
    created: s32; // instances the pool had to build itself
    gets: s32;
    returns: s32;
    discarded: s32; // returned while at `capacity` (dropped, not cached)
}

// Creates a pool. `capacity <= 0` keeps every returned instance (C# behaviour).
//
// 注意返回类型写 `*Pool(T)` 而不是 `*Pool($T)`：后者会让官方 Jai 在
// 「泛型结构体的过程字段里出现 T」这种结构下报 Unable to parse type instantiation。
// 官方 Jai 的解析器要求这里写成单行签名：多行签名 + 泛型返回类型 + 过程类型字段
// 的组合会报 Unable to parse type instantiation（已用最小用例定位）。
pool_create :: ($T: Type, factory: (data: *void) -> T = null, zero_out: (data: *void, item: *T) = null, capacity: s32 = 0) -> *Pool(T) {
    pool := cast(*Pool(T)) alloc(size_of(Pool(T)));
    pool.* = .{};
    pool.factory = factory;
    pool.zero_out = zero_out;
    pool.capacity = capacity;
    if capacity > 0 array_reserve(*pool.available, capacity);
    return pool;
}

// Frees the pool and its cache. Instances themselves are not freed: for
// `Pool(*Thing)` free the Thing in your own teardown loop (C# had the GC).
pool_destroy :: (pool: *Pool($T)) {
    array_free(pool.available);
    free(pool);
}

// Requests an instance: a recycled one if available, otherwise factory() or a
// zeroed T.
pool_get :: (pool: *Pool($T)) -> T {
    item: T;
    if pool.head < pool.available.count {
        item = pool.available[pool.head];
        pool.head += 1;
        if pool.head >= pool.available.count {
            // cache drained: rewind so the storage is reused from the start
            pool.available.count = 0;
            pool.head = 0;
        }
    } else {
        if pool.factory != null item = pool.factory(pool.factory_data);
        pool.created += 1;
    }
    pool.gets += 1;
    return item;
}

// Non-allocating get: true only when an already-recycled instance was cached.
// This is the Jai spelling of C#'s TryGet-family (no out parameters, so the
// pair is returned by value).
pool_try_get :: (pool: *Pool($T)) -> (T, bool) {
    if pool.head < pool.available.count {
        item := pool.available[pool.head];
        pool.head += 1;
        if pool.head >= pool.available.count {
            pool.available.count = 0;
            pool.head = 0;
        }
        pool.gets += 1;
        return item, true;
    }
    return .{}, false;
}

// Returns an instance so it can be recycled. Runs zero_out first (C#: ZeroOut
// then enqueue). When the pool is at `capacity` the instance is dropped and
// counted in `discarded`.
pool_return :: (pool: *Pool($T), item: T) {
    pool.returns += 1;
    if pool.zero_out != null pool.zero_out(pool.zero_out_data, *item);

    if pool.capacity > 0 && pool_available_count(pool) >= pool.capacity {
        pool.discarded += 1;
        return;
    }

    if pool.head > 0 {
        // drop the consumed prefix so the cache doesn't grow forever
        live := pool.available.count - pool.head;
        if live > 0 {
            for i: 0..live - 1 pool.available[i] = pool.available[pool.head + i];
        }
        pool.available.count = cast(s64) live;
        pool.head = 0;
    }
    array_add(*pool.available, item);
}

// C# Pool<T>.Clear(): drops the cache so the instances can be collected.
pool_clear :: (pool: *Pool($T)) {
    pool.available.count = 0;
    pool.head = 0;
}

pool_set_capacity :: (pool: *Pool($T), capacity: s32) {
    pool.capacity = capacity;
    if capacity > 0 && pool_available_count(pool) > capacity {
        extra := pool_available_count(pool) - capacity;
        pool.discarded += extra;
        pool.available.count = cast(s64) (pool.head + capacity);
    }
}

// How many instances are currently cached and ready to be handed out.
pool_available_count :: (pool: *Pool($T)) -> s32 {
    return cast(s32) (pool.available.count - pool.head);
}

// How many instances the pool had to create itself (cache misses).
pool_created_count :: (pool: *Pool($T)) -> s32 {
    return pool.created;
}

//
// FramePool (Foster FramePool<T> / FramePool)
//
// Objects handed out by a frame pool are recycled at the start of the next
// frame instead of by an explicit Return. C# does that from a static
// constructor that registers FramePool<T>.NextFrame with the global
// FramePool.OnNextFrame event; Jai has no static constructors, so call
// frame_pool_next_frame(*pool) once per frame where Foster's app calls
// FramePool.NextFrame() (in jfoster: the top of app_step, see app.jai).
//

Frame_Pool :: struct($T: Type) {
    // instances recycled on previous frames
    available: [..] T;
    head: s32;

    // instances handed out during the current frame
    used_this_frame: [..] T;

    // C#: FramePool<T>.ZeroOut reuses Pool<T>.ZeroOut
    zero_out: (data: *void, item: *T);
    zero_out_data: *void = null;

    created: s32;
    gets: s32;
}

frame_pool_create :: ($T: Type, zero_out: (data: *void, item: *T) = null) -> *Frame_Pool(T) {
    pool := cast(*Frame_Pool(T)) alloc(size_of(Frame_Pool(T)));
    pool.* = .{};
    pool.zero_out = zero_out;
    return pool;
}

frame_pool_destroy :: (pool: *Frame_Pool($T)) {
    array_free(pool.available);
    array_free(pool.used_this_frame);
    free(pool);
}

// C# FramePool<T>.Get(): recycles a cached instance or creates one, and marks
// it for recycling next frame.
frame_pool_get :: (pool: *Frame_Pool($T)) -> T {
    item: T;
    if pool.head < pool.available.count {
        item = pool.available[pool.head];
        pool.head += 1;
        if pool.head >= pool.available.count {
            pool.available.count = 0;
            pool.head = 0;
        }
    } else {
        pool.created += 1;
    }
    pool.gets += 1;
    array_add(*pool.used_this_frame, item);
    return item;
}

// C# FramePool<T>.Clear(): drops both the recycled and the in-flight instances.
frame_pool_clear :: (pool: *Frame_Pool($T)) {
    pool.available.count = 0;
    pool.head = 0;
    pool.used_this_frame.count = 0;
}

// C# FramePool<T>.NextFrame(): every instance handed out during the frame is
// zeroed and moved back into the cache.
frame_pool_next_frame :: (pool: *Frame_Pool($T)) {
    for i: 0..pool.used_this_frame.count - 1 {
        item := pool.used_this_frame[i];
        if pool.zero_out != null pool.zero_out(pool.zero_out_data, *item);
        array_add(*pool.available, item);
    }
    pool.used_this_frame.count = 0;
}

// How many instances the frame pool created itself (cache misses).
frame_pool_created_count :: (pool: *Frame_Pool($T)) -> s32 {
    return pool.created;
}
