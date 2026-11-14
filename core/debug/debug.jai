// debug —— 内存调试工具：泄漏 / 非法释放追踪。
// 一比一移植自 olib core/debug/debug.odin（含它依赖的 core:mem Tracking_Allocator 形状）。
//
// 用法（olib 用 @(deferred_out=track_destroy) 让 `defer track_create(backing)` 自动收尾；
// Jai 没有 deferred_out，必须显式配对）：
//
//     track := track_create(backing_allocator);   // 返回包装后的 Allocator
//     defer track_destroy(track);
//
// track_destroy 先按 olib 的格式打印泄漏与非法释放，再销毁追踪器本身。被泄漏的内存不会被
// 释放（那正是要报告的东西）。
//
// Jai 侧差异（对外语义不变）：
//   - 没有 deferred_out，调用点写成 `track := track_create(...); defer track_destroy(track);`。
//   - 没有 ODIN_DEBUG 的 `when`：Jai 侧没有等价的“按构建配置编译掉”的常量，这里恒为开启，
//     只在调试路径调用 track_create 即可（olib 在 release 下直接返回 backing）。
//   - 追踪器自身的内存：Odin 用 `new(track)`（context.allocator）分配、却在 track_destroy 里
//     用 `track.backing` 归还；这里分配与归还都走同一个 backing allocator，成对且无歧义。
//   - 逐条分配的源码位置不可得：Odin 的 Allocator_Proc 末尾带 `loc := #caller_location`
//     （由编译器在每个分配点填），所以 mem.Tracking_Allocator 能记录每个分配的 file/line。
//     Jai 的 Allocator_Proc 只有 (mode, size, old_size, old_memory, allocator_data)，拿不到
//     调用点；因此 Tracking_Allocator_Entry.location 字段保留（形状对齐）但为空，
//     报告里打印 “<location unavailable>”，仍给出泄漏字节数与指针、以及非法释放的指针。
//     需要源码位置时用 source_location() 把 #caller_location 转成 Source_Location
//     （procedure 字段为空：Jai 的位置信息里没有过程名）。
//   - Odin 在遇到非法释放时默认 panic；库代码里直接终止调用方不合适，这里一律记入
//     bad_free_array 并交给 track_destroy 汇报：设置了 bad_free_callback 就再多给它一次
//     机会（返回 false 时打印一行）。
//   - Jai 的 Allocator_Mode 比 Odin 多 STARTUP / SHUTDOWN / THREAD_* / CREATE_HEAP /
//     DESTROY_HEAP / IS_THIS_YOURS / CAPS，这些模式原样转发给 backing，不参与记账。
//   - Odin 的 rawptr / int 在这里是 *void / s64。
#import "Basic"; // Allocator / array_add / array_free / print
#import "Hash_Table"; // Table(*void, Tracking_Allocator_Entry) 对位 olib 的 map[rawptr]Entry

//@region 位置 —— runtime.Source_Location 的对位

Source_Location :: struct {
    file: string;
    line: s64;
    column: s64;
    procedure: string; // Jai 的 #caller_location 不带过程名，恒为空
}

// Jai 的 #caller_location 只能作为参数默认值，类型是 Source_Code_Location。
source_location :: (loc: Source_Code_Location = #caller_location) -> Source_Location {
    return Source_Location.{
        file = loc.fully_pathed_filename,
        line = loc.line_number,
        column = loc.character_number,
    };
}
//@endregion

//@region Tracking Allocator —— 泄漏/非法释放追踪

Tracking_Allocator_Entry :: struct {
    size: s64;
    location: Source_Location;
}

Tracking_Allocator_Bad_Free :: struct {
    memory: *void;
    location: Source_Location;
}

// 返回 true 表示这次非法释放已被处理（不再打印）。
Tracking_Allocator_Bad_Free_Callback :: #type (ta: *Tracking_Allocator, entry: Tracking_Allocator_Bad_Free) -> bool;

Tracking_Allocator :: struct {
    backing: Allocator;
    allocation_map: Table(*void, Tracking_Allocator_Entry);
    bad_free_array: [..] Tracking_Allocator_Bad_Free;
    bad_free_callback: Tracking_Allocator_Bad_Free_Callback;
}

// Jai 的分配器调用：Allocator 只有 proc/data 两个字段，失败返回 null（没有 Error 码）。
debug_alloc_call :: (allocator: Allocator, mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void) -> *void {
    if !allocator.proc return null;
    return allocator.proc(mode, size, old_size, old_memory, allocator.data);
}

debug_note_bad_free :: (ta: *Tracking_Allocator, memory: *void) {
    entry := Tracking_Allocator_Bad_Free.{ memory = memory };
    if !ta.bad_free_array.allocator.proc ta.bad_free_array.allocator = ta.backing;
    array_add(*ta.bad_free_array, entry);

    if ta.bad_free_callback {
        if !ta.bad_free_callback(ta, entry) {
            print("[debug] bad free @ %\n", entry.memory);
        }
    }
}

debug_tracking_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    ta := cast(*Tracking_Allocator) allocator_data;
    if !ta return null;

    if mode == {
        case .ALLOCATE;
            result := debug_alloc_call(ta.backing, .ALLOCATE, size, 0, null);
            if result {
                if !ta.allocation_map.allocator.proc ta.allocation_map.allocator = ta.backing;
                table_add(*ta.allocation_map, result, Tracking_Allocator_Entry.{ size = size });
            }
            return result;

        case .RESIZE;
            old := old_size;
            if old == 0 && old_memory {
                found, entry := table_find(*ta.allocation_map, old_memory);
                if found old = entry.size;
            }
            result := debug_alloc_call(ta.backing, .RESIZE, size, old, old_memory);
            if result {
                if old_memory && old_memory != result {
                    if !table_remove(*ta.allocation_map, old_memory) debug_note_bad_free(ta, old_memory);
                }
                if !ta.allocation_map.allocator.proc ta.allocation_map.allocator = ta.backing;
                table_add(*ta.allocation_map, result, Tracking_Allocator_Entry.{ size = size });
            }
            return result;

        case .FREE;
            debug_alloc_call(ta.backing, .FREE, 0, old_size, old_memory);
            if old_memory && !table_remove(*ta.allocation_map, old_memory) {
                debug_note_bad_free(ta, old_memory);
            }
            return null;
    }

    return debug_alloc_call(ta.backing, mode, size, old_size, old_memory);
}

// odin: mem.tracking_allocator_init(track, backing)
// 记账结构（allocation_map / bad_free_array）的分配一律走 backing，不穿过自己的 proc，
// 否则会自引用。
tracking_allocator_init :: (ta: *Tracking_Allocator, backing_allocator: Allocator = context.allocator) {
    if !ta return;
    ta.* = .{};
    ta.backing = backing_allocator;
    if !ta.backing.proc ta.backing = context.allocator;
    ta.allocation_map.allocator = ta.backing;
    ta.bad_free_array.allocator = ta.backing;
}

// odin: mem.tracking_allocator(track)
tracking_allocator :: (ta: *Tracking_Allocator) -> Allocator {
    return Allocator.{ proc = debug_tracking_allocator_proc, data = ta };
}

// odin: mem.tracking_allocator_bad_free_callback_add_to_array
// 这里记账已经在 debug_note_bad_free 里做了，回调只需回答“已处理”，不重复追加。
tracking_allocator_bad_free_callback_add_to_array :: (ta: *Tracking_Allocator, entry: Tracking_Allocator_Bad_Free) -> bool {
    return true;
}

// odin: mem.tracking_allocator_destroy(track) —— 只释放记账结构，不碰泄漏的内存。
tracking_allocator_destroy :: (ta: *Tracking_Allocator) {
    if !ta return;
    backing := ta.backing;

    deinit(*ta.allocation_map);
    if ta.bad_free_array.data {
        if !ta.bad_free_array.allocator.proc ta.bad_free_array.allocator = backing;
        array_free(ta.bad_free_array);
    }

    ta.* = .{};
}

debug_report_leaks :: (ta: *Tracking_Allocator) {
    if ta.allocation_map.count > 0 {
        for entry, memory: ta.allocation_map {
            if entry.location.file.count > 0 {
                print("%:% leaked % bytes (ptr %)\n", entry.location.file, entry.location.line, entry.size, memory);
            } else {
                print("<location unavailable> leaked % bytes (ptr %)\n", entry.size, memory);
            }
        }
    }
    if ta.bad_free_array.count > 0 {
        for bad: ta.bad_free_array {
            if bad.location.file.count > 0 {
                print("%:% bad free @ %\n", bad.location.file, bad.location.line, bad.memory);
            } else {
                print("<location unavailable> bad free @ %\n", bad.memory);
            }
        }
    }
}
//@endregion

//@region 对外包装 —— track_create / track_destroy

// 用法：`track := track_create(backing); defer track_destroy(track);`
// 分配失败时退回 backing（Odin 侧 new 失败会 panic）。
track_create :: (backing_allocator: Allocator = context.allocator) -> Allocator {
    backing := backing_allocator;
    if !backing.proc backing = context.allocator;

    tracker := cast(*Tracking_Allocator) debug_alloc_call(backing, .ALLOCATE, size_of(Tracking_Allocator), 0, null);
    if !tracker return backing;

    tracking_allocator_init(tracker, backing);
    return tracking_allocator(tracker);
}

// 显式接受 allocator 参数，让调用点清楚自己传的是哪一个。
// 打印泄漏与非法释放，然后销毁追踪器（连同它的记账结构）。
track_destroy :: (tracking_allocator: Allocator) {
    tracker := cast(*Tracking_Allocator) tracking_allocator.data;
    if !tracker return;

    debug_report_leaks(tracker);

    backing := tracker.backing;
    tracking_allocator_destroy(tracker);
    debug_alloc_call(backing, .FREE, 0, size_of(Tracking_Allocator), tracker);
}
//@endregion
