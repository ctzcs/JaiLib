// 一比一移植自 olib tests/core/handle/{soa,array,fixed,growing,virtual}/*_test.odin。
// 断言顺序、断言条数和测试拆分与 olib 一一对应；testing.expect / expectf 换成
// test_support.expect（同一个 proc，带 % 参数）。
//
// Jai 侧差异（仅测试写法，被验证的行为不变）：
//   - `Test_Handle :: distinct Handle` → `Soa_Handle :: SOA.Handle` 之类的别名。
//     Jai 的运算符按词法解析，模块内给 Handle 声明的 operator == 在本模块不可见，
//     所以每个句柄类型都在本文件里具名重声明一次 operator ==（同
//     Libs/Engine/handle/handle_array_test.jai 的做法）。
//   - `#soa[dynamic]` 列语法 rows.hp[i] → rows[i].hp（见 core/handle/soa/soa.jai 文件头）。
//   - add/make 的 (#optional_allocator_error / #optional_ok) → (值, bool)：
//     `h, err := add(...)` 写成 `h, ok := add(...)`，`err != nil` 写成 `!ok`。
//   - remove 是 Jai 关键字 → remove_handle。
//   - olib 的快照往返用 json.marshal/unmarshal；JaiLib 没有 json，改成逐切片深拷贝，
//     序列化格式不可观察，往返后的断言完全一致。
//   - mem.Tracking_Allocator / mem.Allocator 的计数与失败注入用本文件的
//     Track_Allocator / Failure_State / Alloc_Counter 手写实现。
//   - olib 里 `for i in 0 ..< N` 写作 `for 0..N - 1`，`for it := begin(&p); a, b in next(&it)`
//     写作 `it := begin(*p); while true { a, b, ok := next(*it); if !ok break; ... }`。
#import "Basic";
#import "test_support";

SOA :: #import "core/handle/soa";
ARR :: #import "core/handle/array";
FIX :: #import "core/handle/fixed";
GRO :: #import "core/handle/growing";
VIR :: #import "core/handle/virtual";

//@region 句柄类型（对应 olib 各测试里的 Test_Handle :: distinct Handle）

Soa_Handle     :: SOA.Handle;
Array_Handle   :: ARR.Handle;
Fixed_Handle   :: FIX.Handle;
Growing_Handle :: GRO.Handle;
Virtual_Handle :: VIR.Handle;

operator == :: (a: Soa_Handle, b: Soa_Handle) -> bool { return a.idx == b.idx && a.gen == b.gen; }
operator == :: (a: Array_Handle, b: Array_Handle) -> bool { return a.idx == b.idx && a.gen == b.gen; }
operator == :: (a: Fixed_Handle, b: Fixed_Handle) -> bool { return a.idx == b.idx && a.gen == b.gen; }
operator == :: (a: Growing_Handle, b: Growing_Handle) -> bool { return a.idx == b.idx && a.gen == b.gen; }
operator == :: (a: Virtual_Handle, b: Virtual_Handle) -> bool { return a.idx == b.idx && a.gen == b.gen; }

handle_is_zero :: (h: $HT) -> bool {
    return h.idx == 0 && h.gen == 0;
}
//@endregion

//@region 测试用分配器（对应 mem.Allocator / mem.Tracking_Allocator / 计数分配器）

// 对应 olib 里的 Alloc_Counter + counting_allocator：统计分配次数。
Alloc_Counter :: struct {
    count:  int;
    parent: Allocator;
}

counting_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    counter := cast(*Alloc_Counter) allocator_data;
    // 对应 .Alloc / .Alloc_Non_Zeroed / .Resize / .Resize_Non_Zeroed。
    if mode == .ALLOCATE || mode == .RESIZE {
        counter.count += 1;
    }
    return counter.parent.proc(mode, size, old_size, old_memory, counter.parent.data);
}

counting_allocator :: (counter: *Alloc_Counter) -> Allocator {
    result: Allocator;
    result.proc = counting_allocator_proc;
    result.data = cast(*void) counter;
    return result;
}

// 对应 olib 的 Failure_State + failing_allocator：budget 次分配之后开始失败。
Failure_State :: struct {
    backing:   Allocator;
    remaining: int;
}

failing_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    state := cast(*Failure_State) allocator_data;
    if mode == .ALLOCATE || mode == .RESIZE {
        if state.remaining == 0 return null;
        state.remaining -= 1;
    }
    return state.backing.proc(mode, size, old_size, old_memory, state.backing.data);
}

failing_allocator :: (state: *Failure_State) -> Allocator {
    result: Allocator;
    result.proc = failing_allocator_proc;
    result.data = cast(*void) state;
    return result;
}

// 对应 mem.Tracking_Allocator：记录未释放的块，并统计非法释放。
Track_Allocator :: struct {
    backing:  Allocator;
    live:     [..] *void;   // null 表示该块已释放
    bad_free: int;
}

track_mark_released :: (state: *Track_Allocator, memory: *void) -> bool {
    if !memory return true;
    if state.live.count > 0 {
        for 0..(state.live.count - 1) {
            if state.live[it] == memory {
                state.live[it] = null;
                return true;
            }
        }
    }
    return false;
}

track_alloc_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    state := cast(*Track_Allocator) allocator_data;
    memory := state.backing.proc(mode, size, old_size, old_memory, state.backing.data);
    if mode == .ALLOCATE {
        if memory != null array_add(*state.live, memory);
    } else if mode == .RESIZE {
        if memory != null && memory != old_memory {
            if !track_mark_released(state, old_memory) state.bad_free += 1;
            array_add(*state.live, memory);
        }
    } else if mode == .FREE {
        if !track_mark_released(state, old_memory) state.bad_free += 1;
    }
    return memory;
}

track_allocator :: (state: *Track_Allocator) -> Allocator {
    result: Allocator;
    result.proc = track_alloc_proc;
    result.data = cast(*void) state;
    return result;
}

track_begin :: (state: *Track_Allocator) {
    state.* = .{};
    state.backing = context.allocator;
    // live 表固定用装表之前的分配器，避免计数过程里递归调用自己。
    state.live.allocator = context.allocator;
    array_reserve(*state.live, 256);
    state.live.count = 0;
}

track_live_count :: (state: *Track_Allocator) -> int {
    count := 0;
    if state.live.count > 0 {
        for 0..(state.live.count - 1) {
            if state.live[it] != null count += 1;
        }
    }
    return count;
}

// 对应 Odin 的 make([]T, n, allocator)：给快照深拷贝用（释放时按 count * size_of(T) 归还，
// 与 snapshot_delete 的大小一致）。
handle_test_alloc_array :: ($T: Type, count: s64) -> [] T {
    result: [] T;
    if count <= 0 return result;
    result.data = cast(*T) alloc(count * size_of(T));
    result.count = count;
    return result;
}
//@endregion

//@region soa —— tests/core/handle/soa/soa_test.odin

Test_Handle :: Soa_Handle;

Unit :: struct {
    pos:    [2] float;
    hp:     float;
    target: Test_Handle;
}

// 对应 Odin 的 rows[i] == Unit{}：Jai 里逐字段比较。
unit_is_zero :: (u: Unit) -> bool {
    return u.pos[0] == 0 && u.pos[1] == 0 && u.hp == 0 && u.target.idx == 0 && u.target.gen == 0;
}

soa_zero_handle_is_invalid_and_add_assigns_row :: (state: *Test_State) {
    units: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*units);

    zero: Test_Handle;
    expect(state, !SOA.valid(units, zero), "零句柄无效");
    _, ok := SOA.row(units, zero);
    expect(state, !ok, "零句柄取不到行号");

    a, _ := SOA.add(*units, Unit.{ pos = .[1.0, 2.0], hp = 10 });
    b, _ := SOA.add(*units, Unit.{ pos = .[3.0, 4.0], hp = 20 });
    i, a_ok := SOA.row(units, a);
    expect(state, a_ok && i == cast(int) a.idx, "add 返回的句柄可解析成行号");
    expect(state, units.rows[i].hp == 10 && units.rows[i].pos[0] == 1 && units.rows[i].pos[1] == 2, "行内容为写入的值");
    j, _ := SOA.row(units, b);
    expect(state, units.rows[j].hp == 20, "第二行内容为写入的值");
    expect(state, SOA.len(units) == 2, "len == 2");
}

soa_remove_clears_row_and_stale_handle_stays_invalid :: (state: *Test_State) {
    units: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*units);

    a, _ := SOA.add(*units, Unit.{ hp = 10 });
    SOA.remove_handle(*units, a);
    expect(state, !SOA.valid(units, a), "remove 后句柄失效");
    expect(state, unit_is_zero(units.rows[cast(s64) a.idx]), "remove 清零整行");
    expect(state, SOA.len(units) == 0, "len == 0");

    b, _ := SOA.add(*units, Unit.{ hp = 5 });
    expect(state, b.idx == a.idx && b.gen == a.gen + 1, "复用同一行且代数 +1");
    expect(state, SOA.valid(units, b), "新句柄有效");
    expect(state, !SOA.valid(units, a), "旧句柄仍失效");

    // 过期句柄删除是无操作，不影响新的占用者。
    SOA.remove_handle(*units, a);
    expect(state, SOA.valid(units, b), "过期句柄删除不影响新占用者");
    expect(state, units.rows[cast(s64) b.idx].hp == 5, "新占用者的行内容未变");
}

soa_iteration_skips_free_slots_and_columns_round_trip :: (state: *Test_State) {
    units: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*units);

    hs: [5] Test_Handle;
    for 0..4 {
        h, _ := SOA.add(*units, Unit.{ hp = cast(float) it });
        hs[it] = h;
    }
    SOA.remove_handle(*units, hs[1]);
    SOA.remove_handle(*units, hs[3]);

    seen := 0;
    it := SOA.begin(*units);
    while true {
        i, h, ok := SOA.next(*it);
        if !ok break;
        expect(state, SOA.valid(units, h) && i == cast(int) h.idx, "迭代返回的句柄有效且行号一致");
        units.rows[i].hp += 100;
        seen += 1;
    }
    expect(state, seen == 3, "迭代跳过两个空洞");
    checked: [3] int = .[0, 2, 4];
    for k: checked {
        i, _ := SOA.row(units, hs[k]);
        expect(state, units.rows[i].hp == cast(float) k + 100, "第 % 行的列值写回", k);
    }
}

soa_remove_current_element_during_iteration :: (state: *Test_State) {
    units: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*units);
    for 0..5 {
        h, _ := SOA.add(*units, Unit.{ hp = cast(float) it });
    }

    visited := 0;
    it := SOA.begin(*units);
    while true {
        i, h, ok := SOA.next(*it);
        if !ok break;
        visited += 1;
        if cast(int) units.rows[i].hp % 2 == 0 {
            SOA.remove_handle(*units, h);
        }
    }
    expect(state, visited == 6, "遍历期间可删除当前元素");
    expect(state, SOA.len(units) == 3, "删除一半后 len == 3");
    it = SOA.begin(*units);
    while true {
        i, _, ok := SOA.next(*it);
        if !ok break;
        expect(state, cast(int) units.rows[i].hp % 2 == 1, "剩下的都是奇数行");
    }
}

soa_clear_does_not_allocate_and_invalidates_handles :: (state: *Test_State) {
    // 池在第一次分配时取用 context.allocator，所以先装好计数器再建池，
    // clear 期间若发生分配就会记到 counter 上（对应 olib 的 counting_allocator）。
    counter: Alloc_Counter;
    counter.parent = context.allocator;
    previous := context.allocator;
    context.allocator = counting_allocator(*counter);
    defer context.allocator = previous;

    units: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*units);

    old: [4] Test_Handle;
    for 0..3 {
        h, _ := SOA.add(*units, Unit.{ hp = 1 });
        old[it] = h;
    }
    SOA.remove_handle(*units, old[0]);

    counter.count = 0;
    SOA.clear(*units);
    SOA.clear(*units);
    expect(state, counter.count == 0, "clear 不分配");
    expect(state, SOA.len(units) == 0, "clear 后 len == 0");
    for h: old {
        expect(state, !SOA.valid(units, h), "clear 后旧句柄失效");
    }
    it := SOA.begin(*units);
    _, _, ok := SOA.next(*it);
    expect(state, !ok, "clear 后迭代立即结束");
}

soa_reset_and_delete_with_destroy_visit_live_rows_once :: (state: *Test_State) {
    Row :: struct {
        counter: *int;
    }
    destroy :: (r: Row) { r.counter.* += 1; }

    destroyed := 0;
    rows: SOA.Pool(Row, Test_Handle);
    a, _ := SOA.add(*rows, Row.{ *destroyed });
    b, _ := SOA.add(*rows, Row.{ *destroyed });
    SOA.remove_handle(*rows, a, destroy);
    expect(state, destroyed == 1, "remove 的 destroy 只跑一次");
    // Jai 侧补充（olib 没有）：destroy 收到行副本且可能清空它，确认 remove 清的是被删行、
    // 不会因为实参别名而清错行（Jai 的实参可能按引用传递）。
    expect(state, rows.rows[cast(s64) a.idx].counter == null, "被删的行已清零");
    expect(state, rows.rows[cast(s64) b.idx].counter == *destroyed, "另一行不受 destroy 影响");

    SOA.reset(*rows, destroy);
    expect(state, destroyed == 2, "reset 的 destroy 只覆盖存活行");
    expect(state, SOA.len(rows) == 0 && rows.slots.count == 0, "reset 清空槽位");

    c, _ := SOA.add(*rows, Row.{ *destroyed });
    SOA.delete(*rows, destroy);
    expect(state, destroyed == 3, "delete 的 destroy 只跑一次");
    expect(state, rows.slots.data == null && rows.num == 0, "delete 后池清零");
}

// olib 用 json.marshal → json.unmarshal 走一遍序列化；JaiLib 没有 json，
// 这里逐切片深拷贝，模拟同样的往返（快照只含普通切片与 POD 数据）。
soa_snapshot_deep_copy :: (s: SOA.Snapshot(Unit, Test_Handle)) -> SOA.Snapshot(Unit, Test_Handle) {
    result: SOA.Snapshot(Unit, Test_Handle);
    result.slots = handle_test_alloc_array(Test_Handle, s.slots.count);
    result.freelist = handle_test_alloc_array(u32, s.freelist.count);
    result.rows = handle_test_alloc_array(Unit, s.rows.count);
    if s.slots.count > 0 {
        for 0..(s.slots.count - 1) result.slots.data[it] = s.slots.data[it];
    }
    if s.freelist.count > 0 {
        for 0..(s.freelist.count - 1) result.freelist.data[it] = s.freelist.data[it];
    }
    if s.rows.count > 0 {
        for 0..(s.rows.count - 1) result.rows.data[it] = s.rows.data[it];
    }
    return result;
}

soa_snapshot_json_round_trip_preserves_generations_and_reuse_order :: (state: *Test_State) {
    units: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*units);

    hs: [4] Test_Handle;
    for 0..3 {
        h, _ := SOA.add(*units, Unit.{ hp = cast(float) it });
        hs[it] = h;
    }
    units.rows[cast(s64) hs[0].idx].target = hs[2];
    SOA.remove_handle(*units, hs[1]);
    SOA.remove_handle(*units, hs[3]);
    stale := hs[1];

    saved, captured := SOA.capture(units);
    expect(state, captured, "capture 成功");
    loaded := soa_snapshot_deep_copy(saved);
    SOA.snapshot_delete(saved);
    defer SOA.snapshot_delete(loaded);

    restored: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*restored);
    expect(state, SOA.restore(*restored, loaded), "restore 成功");

    expect(state, SOA.len(restored) == 2, "restore 后 len == 2");
    expect(state, SOA.valid(restored, hs[0]) && SOA.valid(restored, hs[2]), "存活句柄恢复后仍有效");
    expect(state, !SOA.valid(restored, stale) && !SOA.valid(restored, hs[3]), "快照前失效的句柄恢复后仍失效");
    i, _ := SOA.row(restored, hs[0]);
    expect(state, restored.rows[i].target == hs[2], "行数据（含句柄字段）随快照恢复");
    expect(state, restored.rows[cast(s64) hs[2].idx].hp == 2, "第二行的行数据恢复");

    // 后续 add 的复用顺序与原池一致。
    for 0..2 {
        x, _ := SOA.add(*units, Unit.{});
        y, _ := SOA.add(*restored, Unit.{});
        expect(state, x == y, "复用顺序与原池一致");
    }
}

soa_restore_rejects_inconsistent_snapshot_and_keeps_pool :: (state: *Test_State) {
    units: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*units);
    h, _ := SOA.add(*units, Unit.{ hp = 7 });

    good, captured := SOA.capture(units);
    expect(state, captured, "capture 成功");
    defer SOA.snapshot_delete(good);

    // slots[1] 的 idx 不等于下标 → 不一致。
    bad_slots: [2] Test_Handle;
    bad_slots[1].idx = 2;
    bad_slots[1].gen = 1;
    bad: SOA.Snapshot(Unit, Test_Handle);
    bad.slots.count = 2;
    bad.slots.data = *bad_slots[0];
    bad.rows = good.rows;
    expect(state, !SOA.restore(*units, bad), "拒绝 idx 与下标不符的快照");

    // 有一个空槽但空闲列表为空 → 不一致。
    missing_slots: [2] Test_Handle;
    missing_slots[1].gen = 1;
    missing_free: SOA.Snapshot(Unit, Test_Handle);
    missing_free.slots.count = 2;
    missing_free.slots.data = *missing_slots[0];
    missing_free.rows = good.rows;
    expect(state, !SOA.restore(*units, missing_free), "拒绝空闲列表不完整的快照");

    // rows 长度与 slots 不一致。
    short_rows: SOA.Snapshot(Unit, Test_Handle);
    short_rows.slots = good.slots;
    short_rows.rows.count = 1;
    short_rows.rows.data = good.rows.data;
    expect(state, !SOA.restore(*units, short_rows), "拒绝 rows 长度不符的快照");

    expect(state, SOA.valid(units, h) && units.rows[cast(s64) h.idx].hp == 7, "失败时池保持原样");
}

soa_restore_into_non_empty_pool_does_not_leak :: (state: *Test_State) {
    track: Track_Allocator;
    track_begin(*track);
    previous := context.allocator;
    context.allocator = track_allocator(*track);

    a: SOA.Pool(Unit, Test_Handle);
    b: SOA.Pool(Unit, Test_Handle);
    for 0..9 {
        h, _ := SOA.add(*a, Unit.{ hp = cast(float) it });
    }
    h, _ := SOA.add(*b, Unit.{ hp = 1 });
    s, captured := SOA.capture(a);
    expect(state, captured, "capture 成功");
    expect(state, SOA.restore(*b, s), "第一次 restore 成功");
    expect(state, SOA.restore(*b, s), "第二次 restore 成功（覆盖非空池）");
    SOA.snapshot_delete(s);
    expect(state, SOA.len(b) == 10, "restore 后 len == 10");
    SOA.delete(*a);
    SOA.delete(*b);

    context.allocator = previous;
    expect(state, track_live_count(*track) == 0, "restore 到非空池不泄漏");
    expect(state, track.bad_free == 0, "没有非法释放");
    array_free(track.live);
}

soa_remove_after_restore_does_not_allocate :: (state: *Test_State) {
    src: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*src);
    hs: [6] Test_Handle;
    for 0..5 {
        h, _ := SOA.add(*src, Unit.{});
        hs[it] = h;
    }
    s, captured := SOA.capture(src);
    expect(state, captured, "capture 成功");
    defer SOA.snapshot_delete(s);

    // 计数器在 restore 之前装好：目标池的数组会用这个分配器，remove 若分配就会被记到。
    counter: Alloc_Counter;
    counter.parent = context.allocator;
    previous := context.allocator;
    context.allocator = counting_allocator(*counter);
    defer context.allocator = previous;

    dst: SOA.Pool(Unit, Test_Handle);
    defer SOA.delete(*dst);
    expect(state, SOA.restore(*dst, s), "restore 成功");

    counter.count = 0;
    for h: hs {
        SOA.remove_handle(*dst, h);
    }
    expect(state, counter.count == 0, "restore 后 remove 不分配");
    expect(state, SOA.len(dst) == 0, "remove 全部后 len == 0");
}
//@endregion

//@region array —— tests/core/handle/array/array_test.odin

array_clear_preserves_generations_and_reuses_all_slots :: (state: *Test_State) {
    Test_Handle :: Array_Handle;
    values: ARR.Pool(s32, Test_Handle);
    defer ARR.delete(*values);

    ARR.clear(*values);
    expect(state, ARR.cap(values) == 0, "空池 cap == 0");

    old: [3] Test_Handle;
    for 0..2 {
        h, _ := ARR.add(*values, cast(s32) it + 1);
        old[it] = h;
    }
    ARR.remove_handle(*values, old[1]);
    // 再包含一个代数已经前进过的槽位。
    old[1], _ = ARR.add(*values, 4);
    ARR.remove_handle(*values, old[1]);
    capacity := ARR.cap(values);
    slot_count := values.slots.count;

    for 0..2 {
        ARR.clear(*values);
        ARR.clear(*values);
        expect(state, ARR.len(values) == 0, "clear 后 len == 0");
        expect(state, values.freelist.count == 3, "clear 后空闲列表恰好 3 项");
        it := ARR.begin(*values);
        _, _, ok := ARR.next(*it);
        expect(state, !ok, "clear 后迭代立即结束");

        fresh: [3] Test_Handle;
        for 0..2 {
            h, _ := ARR.add(*values, cast(s32) it);
            fresh[it] = h;
            expect(state, ARR.valid(values, fresh[it]), "复用的新句柄有效");
            for h2: old {
                expect(state, !ARR.valid(values, h2), "旧句柄仍失效");
            }
            outer := it;
            for 0..(outer - 1) {
                expect(state, fresh[outer].idx != fresh[it].idx, "新句柄之间槽位不重复");
            }
        }
        expect(state, ARR.len(values) == 3, "重新填满后 len == 3");
        expect(state, ARR.cap(values) == capacity, "clear 保留容量");
        expect(state, values.slots.count == slot_count, "clear 保留槽位数");
        old = fresh;
    }
}

array_clear_destroys_only_live_values_once :: (state: *Test_State) {
    Test_Handle :: Array_Handle;
    Value :: struct {
        destroyed: *int;
    }
    destroy :: (v: *Value) {
        v.destroyed.* += 1;
        empty: Value;
        v.* = empty;
    }
    values: ARR.Pool(Value, Test_Handle);
    defer ARR.delete(*values);
    counts: [3] int;
    first, _ := ARR.add(*values, Value.{ *counts[0] });
    removed, _ := ARR.add(*values, Value.{ *counts[1] });
    third, _ := ARR.add(*values, Value.{ *counts[2] });
    ARR.remove_handle(*values, removed, destroy);
    ARR.clear(*values, destroy);
    ARR.clear(*values, destroy);
    expect(state, counts[0] == 1 && counts[1] == 1 && counts[2] == 1, "clear 只销毁存活值各一次");
    expect(state, !ARR.valid(values, first), "clear 后 first 失效");
    expect(state, !ARR.valid(values, third), "clear 后 third 失效");
    expect(state, ARR.len(values) == 0, "clear 后 len == 0");
    // reset 同样丢弃槽位历史，并支持同样的回调形式。
    _, _ = ARR.add(*values, Value.{ *counts[0] });
    ARR.reset(*values, destroy);
    expect(state, counts[0] == 2 && counts[1] == 1 && counts[2] == 1, "reset 只销毁存活值");
    expect(state, values.slots.count == 0, "reset 清空槽位");
}

array_iterator_skips_free_slots_and_returns_live_values :: (state: *Test_State) {
    Test_Handle :: Array_Handle;

    values: ARR.Pool(s32, Test_Handle);
    defer ARR.delete(*values);

    first, _ := ARR.add(*values, 1);
    removed, _ := ARR.add(*values, 2);
    third, _ := ARR.add(*values, 3);
    ARR.remove_handle(*values, removed);

    expect(state, ARR.len(values) == 2, "len == 2");
    expect(state, ARR.cap(values) >= ARR.len(values), "cap >= len");
    expect(state, ARR.valid(values, first), "first 有效");
    expect(state, !ARR.valid(values, removed), "removed 失效");

    count := 0;
    sum := 0;
    saw_first := false;
    saw_third := false;

    it := ARR.begin(*values);
    while true {
        value, handle, ok := ARR.next(*it);
        if !ok break;
        count += 1;
        sum += <<value;
        saw_first = saw_first || (handle == first);
        saw_third = saw_third || (handle == third);
        <<value = <<value + 10;
    }

    expect(state, count == 2, "迭代 2 次");
    expect(state, sum == 4, "迭代求和 == 4");
    expect(state, saw_first, "迭代遇到 first");
    expect(state, saw_third, "迭代遇到 third");
    expect(state, ARR.get(values, removed) == null, "get 失效句柄返回 null");
    expect(state, <<ARR.get(values, first) == 11, "first 已被迭代改写为 11");
    expect(state, <<ARR.get(values, third) == 13, "third 已被迭代改写为 13");

    reused, _ := ARR.add(*values, 4);
    expect(state, reused.idx == removed.idx, "复用 removed 的槽位");
    expect(state, reused.gen != removed.gen, "复用后代数变化");

    copied, ok := ARR.get_value(values, reused);
    expect(state, ok, "get_value 成功");
    expect(state, copied == 4, "get_value 返回 4");

    ARR.reset(*values);
    expect(state, ARR.len(values) == 0, "reset 后 len == 0");
    expect(state, !ARR.valid(values, first), "reset 后 first 失效");
}

array_allocation_failure_leaves_pool_usable :: (state: *Test_State) {
    H :: Array_Handle;
    Item :: struct {
        handle: H;
        value: int;
    }
    // 前两次底层数组分配各失败一次，然后恢复。
    for 0..1 {
        failure: Failure_State;
        failure.backing = context.allocator;
        failure.remaining = it;
        allocator := failing_allocator(*failure);
        pool: ARR.Pool(Item, H);
        // 对应 olib 的 runtime.make([dynamic]Slot, allocator)：Jai 的数组自带分配器字段。
        pool.slots.allocator = allocator;
        pool.freelist.allocator = allocator;
        defer ARR.delete(*pool);
        h, ok := ARR.add(*pool, Item.{ value = 42 });
        expect(state, !ok && handle_is_zero(h), "分配失败返回零句柄");
        expect(state, ARR.len(pool) == 0, "分配失败后 len == 0");

        failure.remaining = 100;
        first, first_ok := ARR.add(*pool, Item.{ value = 42 });
        expect(state, first_ok, "恢复后可以 add");
        failure.remaining = 0;
        // 已有的备用容量可能还能装几个，直到扩容失败为止。
        for 0..99 {
            _, err := ARR.add(*pool, Item.{ value = it });
            if !err break;
        }
        expect(state, ARR.valid(pool, first), "失败循环后 first 仍有效");
        expect(state, ARR.get(pool, first).value == 42, "first 的值未被破坏");
        live := ARR.len(pool);
        expect(state, live < 101, "live < 101");

        ARR.clear(*pool);
        expect(state, ARR.len(pool) == 0, "clear 后 len == 0");
        for 0..(live - 1) {
            fresh, add_ok := ARR.add(*pool, Item.{ value = it });
            expect(state, add_ok && ARR.valid(pool, fresh), "复用空闲槽位不需要分配");
            expect(state, !ARR.valid(pool, first), "first 在 clear 后失效");
        }
        ARR.clear(*pool);
        failure.remaining = 10000;
        first, _ = ARR.add(*pool, Item.{ value = 42 });
        for 0..999 {
            _, _ = ARR.add(*pool, Item.{ value = it });
        }
        expect(state, ARR.get(pool, first).value == 42, "扩容后 first 的值仍然正确");
    }
}
//@endregion

//@region fixed —— tests/core/handle/fixed/fixed_test.odin

fixed_pool_lifecycle_and_iteration :: (state: *Test_State) {
    Test_Handle :: Fixed_Handle;
    Test_Item :: struct {
        handle: Test_Handle;
        value:  s32;
    }

    pool: FIX.Pool(Test_Item, Test_Handle, 4);
    defer FIX.delete(*pool);

    expect(state, FIX.len(pool) == 0, "len == 0");
    expect(state, FIX.cap(pool) == 3, "cap == N - 1 == 3");

    first, a := FIX.add(*pool, Test_Item.{ value = 1 });
    removed, b := FIX.add(*pool, Test_Item.{ value = 2 });
    third, c := FIX.add(*pool, Test_Item.{ value = 3 });
    _, added := FIX.add(*pool, Test_Item.{ value = 99 });
    expect(state, !added, "容量满时 add 失败");

    FIX.remove_handle(*pool, removed);
    expect(state, FIX.len(pool) == 2, "remove 后 len == 2");
    expect(state, FIX.valid(pool, first), "first 有效");
    expect(state, !FIX.valid(pool, removed), "removed 失效");
    expect(state, FIX.get(*pool, removed) == null, "get 失效句柄返回 null");

    reused, _ := FIX.add(*pool, Test_Item.{ value = 4 });
    expect(state, reused.idx == removed.idx, "复用 removed 的槽位");
    expect(state, reused.gen != removed.gen, "复用后代数变化");

    count := 0;
    sum: s32;
    it := FIX.begin(*pool);
    while true {
        item, handle, ok := FIX.next(*it);
        if !ok break;
        count += 1;
        sum += item.value;
        expect(state, handle == item.handle, "迭代返回条目自带的句柄");
    }
    expect(state, count == 3, "迭代 3 次");
    expect(state, sum == 8, "迭代求和 == 8");
    expect(state, FIX.valid(pool, third), "third 仍有效");

    FIX.reset(*pool);
    expect(state, FIX.len(pool) == 0, "reset 后 len == 0");
    expect(state, !FIX.valid(pool, first), "reset 后 first 失效");
}

fixed_callbacks_clear_and_delete_preserve_lifecycle :: (state: *Test_State) {
    H :: Fixed_Handle;
    Item :: struct {
        handle: H;
        count: *int;
        value: int;
    }
    destroy :: (item: *Item) { item.count.* += 1; empty: Item; item.* = empty; }
    pool: FIX.Pool(Item, H, 4);
    defer FIX.delete(*pool);
    counts: [3] int;
    FIX.clear(*pool);
    FIX.reset(*pool);
    FIX.delete(*pool);
    old: [3] H;
    for 0..2 {
        h, _ := FIX.add(*pool, Item.{ count = *counts[it], value = 7 });
        old[it] = h;
    }
    copied, ok := FIX.get_value(*pool, old[0]);
    expect(state, ok && copied.value == 7, "get_value 取到存活值");
    FIX.remove_handle(*pool, old[1], destroy);
    FIX.remove_handle(*pool, old[1], destroy);
    old[1], _ = FIX.add(*pool, Item.{ count = *counts[1] });
    FIX.remove_handle(*pool, old[1], destroy);
    FIX.clear(*pool, destroy);
    FIX.clear(*pool, destroy);
    expect(state, counts[0] == 1 && counts[1] == 2 && counts[2] == 1, "remove/clear 的销毁计数");
    expect(state, FIX.len(pool) == 0, "clear 后 len == 0");
    it := FIX.begin(*pool);
    _, _, more := FIX.next(*it);
    expect(state, !more, "clear 后迭代立即结束");
    _, missing := FIX.get_value(*pool, old[0]);
    expect(state, !missing, "clear 后 get_value 失败");

    fresh: [3] H;
    for 0..2 {
        h, _ := FIX.add(*pool, Item.{ count = *counts[it] });
        fresh[it] = h;
        for h2: old { expect(state, !FIX.valid(pool, h2), "旧句柄在 clear 后失效"); }
        outer := it;
        for 0..(outer - 1) { expect(state, fresh[outer].idx != fresh[it].idx, "新句柄之间槽位不重复"); }
    }
    expect(state, FIX.len(pool) == 3, "重新填满后 len == 3");
    FIX.reset(*pool, destroy);
    expect(state, counts[0] == 2 && counts[1] == 3 && counts[2] == 2, "reset 的销毁计数");
    _, _ = FIX.add(*pool, Item.{ count = *counts[0] });
    FIX.delete(*pool, destroy);
    FIX.delete(*pool, destroy);
    expect(state, counts[0] == 3 && counts[1] == 3 && counts[2] == 2, "delete 的销毁计数");
    expect(state, FIX.len(pool) == 0, "delete 后 len == 0");
    it = FIX.begin(*pool);
    _, _, more = FIX.next(*it);
    expect(state, !more, "delete 后迭代立即结束");
    h, _ := FIX.add(*pool, Item.{ count = *counts[0] });
    expect(state, FIX.valid(pool, h), "delete 后可重新使用");
    FIX.clear(*pool, destroy);
    expect(state, counts[0] == 4, "再次 clear 的销毁计数");
}
//@endregion

//@region growing —— tests/core/handle/growing/growing_test.odin

Growing_Item :: struct {
    handle: Growing_Handle;
    value:  s32;
}

growing_pool_lifecycle_and_iteration :: (state: *Test_State) {
    pool: GRO.Pool(Growing_Item, Growing_Handle);
    defer GRO.delete(*pool);

    first, _ := GRO.add(*pool, Growing_Item.{ value = 1 });
    removed, _ := GRO.add(*pool, Growing_Item.{ value = 2 });
    third, _ := GRO.add(*pool, Growing_Item.{ value = 3 });
    expect(state, GRO.len(pool) == 3, "len == 3");
    expect(state, GRO.cap(pool) >= GRO.len(pool), "cap >= len");

    GRO.remove_handle(*pool, removed);
    expect(state, GRO.len(pool) == 2, "remove 后 len == 2");
    expect(state, GRO.valid(pool, first), "first 有效");
    expect(state, !GRO.valid(pool, removed), "removed 失效");
    expect(state, GRO.get(pool, removed) == null, "get 失效句柄返回 null");

    reused, _ := GRO.add(*pool, Growing_Item.{ value = 4 });
    expect(state, reused.idx == removed.idx, "复用 removed 的槽位");
    expect(state, reused.gen != removed.gen, "复用后代数变化");

    count := 0;
    sum: s32;
    it := GRO.begin(*pool);
    while true {
        item, handle, ok := GRO.next(*it);
        if !ok break;
        count += 1;
        sum += item.value;
        expect(state, handle == item.handle, "迭代返回条目自带的句柄");
    }
    expect(state, count == 3, "迭代 3 次");
    expect(state, sum == 8, "迭代求和 == 8");
    expect(state, GRO.valid(pool, third), "third 仍有效");

    GRO.reset(*pool);
    expect(state, GRO.len(pool) == 0, "reset 后 len == 0");
    expect(state, !GRO.valid(pool, first), "reset 后 first 失效");
}

growing_callbacks_clear_and_delete_preserve_lifecycle :: (state: *Test_State) {
    H :: Growing_Handle;
    Item :: struct {
        handle: H;
        count: *int;
        value: int;
    }
    destroy :: (item: *Item) { item.count.* += 1; empty: Item; item.* = empty; }
    pool: GRO.Pool(Item, H);
    defer GRO.delete(*pool);
    counts: [3] int;
    GRO.clear(*pool);
    GRO.reset(*pool);
    GRO.delete(*pool);
    old: [3] H;
    for 0..2 {
        h, _ := GRO.add(*pool, Item.{ count = *counts[it], value = 7 });
        old[it] = h;
    }
    copied, ok := GRO.get_value(pool, old[0]);
    expect(state, ok && copied.value == 7, "get_value 取到存活值");
    GRO.remove_handle(*pool, old[1], destroy);
    GRO.remove_handle(*pool, old[1], destroy);
    old[1], _ = GRO.add(*pool, Item.{ count = *counts[1] });
    GRO.remove_handle(*pool, old[1], destroy);
    GRO.clear(*pool, destroy);
    GRO.clear(*pool, destroy);
    expect(state, counts[0] == 1 && counts[1] == 2 && counts[2] == 1, "remove/clear 的销毁计数");
    expect(state, GRO.len(pool) == 0, "clear 后 len == 0");
    it := GRO.begin(*pool);
    _, _, more := GRO.next(*it);
    expect(state, !more, "clear 后迭代立即结束");
    _, missing := GRO.get_value(pool, old[0]);
    expect(state, !missing, "clear 后 get_value 失败");

    fresh: [3] H;
    for 0..2 {
        h, _ := GRO.add(*pool, Item.{ count = *counts[it] });
        fresh[it] = h;
        for h2: old { expect(state, !GRO.valid(pool, h2), "旧句柄在 clear 后失效"); }
        outer := it;
        for 0..(outer - 1) { expect(state, fresh[outer].idx != fresh[it].idx, "新句柄之间槽位不重复"); }
    }
    expect(state, GRO.len(pool) == 3, "重新填满后 len == 3");
    GRO.reset(*pool, destroy);
    expect(state, counts[0] == 2 && counts[1] == 3 && counts[2] == 2, "reset 的销毁计数");
    _, _ = GRO.add(*pool, Item.{ count = *counts[0] });
    GRO.delete(*pool, destroy);
    GRO.delete(*pool, destroy);
    expect(state, counts[0] == 3 && counts[1] == 3 && counts[2] == 2, "delete 的销毁计数");
    expect(state, GRO.len(pool) == 0, "delete 后 len == 0");
    it = GRO.begin(*pool);
    _, _, more = GRO.next(*it);
    expect(state, !more, "delete 后迭代立即结束");
    h, _ := GRO.add(*pool, Item.{ count = *counts[0] });
    expect(state, GRO.valid(pool, h), "delete 后可重新使用");
    GRO.clear(*pool, destroy);
    expect(state, counts[0] == 4, "再次 clear 的销毁计数");
}

growing_allocation_failure_leaves_pool_usable :: (state: *Test_State) {
    H :: Growing_Handle;
    Item :: struct {
        handle: H;
        value: int;
    }
    // 前两次底层数组分配各失败一次，然后恢复。
    for 0..1 {
        failure: Failure_State;
        failure.backing = context.allocator;
        failure.remaining = it;
        allocator := failing_allocator(*failure);
        pool, made := GRO.make(Item, H, 0, allocator);
        defer GRO.delete(*pool);
        h, ok := GRO.add(*pool, Item.{ value = 42 });
        expect(state, !ok && handle_is_zero(h), "分配失败返回零句柄");
        expect(state, GRO.len(pool) == 0, "分配失败后 len == 0");

        failure.remaining = 100;
        first, first_ok := GRO.add(*pool, Item.{ value = 42 });
        expect(state, first_ok, "恢复后可以 add");
        first_ptr := GRO.get(pool, first);
        failure.remaining = 0;
        // 已有的备用容量可能还能装几个，直到扩容失败为止。
        for 0..99 {
            _, err := GRO.add(*pool, Item.{ value = it });
            if !err break;
        }
        expect(state, GRO.valid(pool, first), "失败循环后 first 仍有效");
        expect(state, GRO.get(pool, first).value == 42, "first 的值未被破坏");
        live := GRO.len(pool);
        expect(state, live < 101, "live < 101");

        GRO.clear(*pool);
        expect(state, GRO.len(pool) == 0, "clear 后 len == 0");
        for 0..(live - 1) {
            fresh, add_ok := GRO.add(*pool, Item.{ value = it });
            expect(state, add_ok && GRO.valid(pool, fresh), "复用空闲槽位不需要分配");
            expect(state, !GRO.valid(pool, first), "first 在 clear 后失效");
        }
        GRO.clear(*pool);
        failure.remaining = 10000;
        first, _ = GRO.add(*pool, Item.{ value = 42 });
        first_ptr = GRO.get(pool, first);
        for 0..999 {
            _, _ = GRO.add(*pool, Item.{ value = it });
        }
        expect(state, GRO.get(pool, first) == first_ptr, "arena 里条目地址稳定");
        expect(state, GRO.get(pool, first).value == 42, "扩容后 first 的值仍然正确");
    }
}
//@endregion

//@region virtual —— tests/core/handle/virtual/virtual_test.odin

Virtual_Item :: struct {
    handle: Virtual_Handle;
    value:  s32;
}

virtual_pool_lifecycle_and_iteration :: (state: *Test_State) {
    pool: VIR.Pool(Virtual_Item, Virtual_Handle, 32);
    defer VIR.delete(*pool);

    first, _ := VIR.add(*pool, Virtual_Item.{ value = 1 });
    removed, _ := VIR.add(*pool, Virtual_Item.{ value = 2 });
    third, _ := VIR.add(*pool, Virtual_Item.{ value = 3 });
    expect(state, VIR.len(pool) == 3, "len == 3");
    expect(state, VIR.cap(pool) >= 32, "cap >= 预留的 32");

    VIR.remove_handle(*pool, removed);
    expect(state, VIR.len(pool) == 2, "remove 后 len == 2");
    expect(state, VIR.valid(pool, first), "first 有效");
    expect(state, !VIR.valid(pool, removed), "removed 失效");
    expect(state, VIR.get(pool, removed) == null, "get 失效句柄返回 null");

    reused, _ := VIR.add(*pool, Virtual_Item.{ value = 4 });
    expect(state, reused.idx == removed.idx, "复用 removed 的槽位");
    expect(state, reused.gen != removed.gen, "复用后代数变化");

    count := 0;
    sum: s32;
    it := VIR.begin(*pool);
    while true {
        item, handle, ok := VIR.next(*it);
        if !ok break;
        count += 1;
        sum += item.value;
        expect(state, handle == item.handle, "迭代返回条目自带的句柄");
    }
    expect(state, count == 3, "迭代 3 次");
    expect(state, sum == 8, "迭代求和 == 8");
    expect(state, VIR.valid(pool, third), "third 仍有效");

    VIR.reset(*pool);
    expect(state, VIR.len(pool) == 0, "reset 后 len == 0");
    expect(state, !VIR.valid(pool, first), "reset 后 first 失效");
}

virtual_callbacks_clear_and_delete_preserve_lifecycle :: (state: *Test_State) {
    H :: Virtual_Handle;
    Item :: struct {
        handle: H;
        count: *int;
        value: int;
    }
    destroy :: (item: *Item) { item.count.* += 1; empty: Item; item.* = empty; }
    pool: VIR.Pool(Item, H, 32);
    defer VIR.delete(*pool);
    counts: [3] int;
    VIR.clear(*pool);
    VIR.reset(*pool);
    VIR.delete(*pool);
    old: [3] H;
    for 0..2 {
        h, _ := VIR.add(*pool, Item.{ count = *counts[it], value = 7 });
        old[it] = h;
    }
    copied, ok := VIR.get_value(pool, old[0]);
    expect(state, ok && copied.value == 7, "get_value 取到存活值");
    VIR.remove_handle(*pool, old[1], destroy);
    VIR.remove_handle(*pool, old[1], destroy);
    old[1], _ = VIR.add(*pool, Item.{ count = *counts[1] });
    VIR.remove_handle(*pool, old[1], destroy);
    VIR.clear(*pool, destroy);
    VIR.clear(*pool, destroy);
    expect(state, counts[0] == 1 && counts[1] == 2 && counts[2] == 1, "remove/clear 的销毁计数");
    expect(state, VIR.len(pool) == 0, "clear 后 len == 0");
    it := VIR.begin(*pool);
    _, _, more := VIR.next(*it);
    expect(state, !more, "clear 后迭代立即结束");
    _, missing := VIR.get_value(pool, old[0]);
    expect(state, !missing, "clear 后 get_value 失败");

    fresh: [3] H;
    for 0..2 {
        h, _ := VIR.add(*pool, Item.{ count = *counts[it] });
        fresh[it] = h;
        for h2: old { expect(state, !VIR.valid(pool, h2), "旧句柄在 clear 后失效"); }
        outer := it;
        for 0..(outer - 1) { expect(state, fresh[outer].idx != fresh[it].idx, "新句柄之间槽位不重复"); }
    }
    expect(state, VIR.len(pool) == 3, "重新填满后 len == 3");
    VIR.reset(*pool, destroy);
    expect(state, counts[0] == 2 && counts[1] == 3 && counts[2] == 2, "reset 的销毁计数");
    _, _ = VIR.add(*pool, Item.{ count = *counts[0] });
    VIR.delete(*pool, destroy);
    VIR.delete(*pool, destroy);
    expect(state, counts[0] == 3 && counts[1] == 3 && counts[2] == 2, "delete 的销毁计数");
    expect(state, VIR.len(pool) == 0, "delete 后 len == 0");
    it = VIR.begin(*pool);
    _, _, more = VIR.next(*it);
    expect(state, !more, "delete 后迭代立即结束");
    h, _ := VIR.add(*pool, Item.{ count = *counts[0] });
    expect(state, VIR.valid(pool, h), "delete 后可重新使用");
    VIR.clear(*pool, destroy);
    expect(state, counts[0] == 4, "再次 clear 的销毁计数");
}

virtual_allocation_failure_leaves_pool_usable :: (state: *Test_State) {
    H :: Virtual_Handle;
    Item :: struct {
        handle: H;
        value: int;
    }
    // 前两次底层数组分配各失败一次，然后恢复。
    for 0..1 {
        failure: Failure_State;
        failure.backing = context.allocator;
        failure.remaining = it;
        allocator := failing_allocator(*failure);
        pool, made := VIR.make(Item, H, 2048, allocator);
        defer VIR.delete(*pool);
        h, ok := VIR.add(*pool, Item.{ value = 42 });
        // virtual 的条目数组走自己的 arena，只有空闲列表走传进来的分配器。
        if it == 1 {
            expect(state, ok, "只失败空闲列表分配时 add 成功");
            VIR.clear(*pool);
        } else {
            expect(state, !ok && handle_is_zero(h), "空闲列表分配失败时 add 失败");
        }
        expect(state, VIR.len(pool) == 0, "失败后 len == 0");

        failure.remaining = 100;
        first, first_ok := VIR.add(*pool, Item.{ value = 42 });
        expect(state, first_ok, "恢复后可以 add");
        first_ptr := VIR.get(pool, first);
        failure.remaining = 0;
        // 已有的备用容量可能还能装几个，直到扩容失败为止。
        for 0..99 {
            _, err := VIR.add(*pool, Item.{ value = it });
            if !err break;
        }
        expect(state, VIR.valid(pool, first), "失败循环后 first 仍有效");
        expect(state, VIR.get(pool, first).value == 42, "first 的值未被破坏");
        live := VIR.len(pool);
        expect(state, live < 101, "live < 101");

        VIR.clear(*pool);
        expect(state, VIR.len(pool) == 0, "clear 后 len == 0");
        for 0..(live - 1) {
            fresh, add_ok := VIR.add(*pool, Item.{ value = it });
            expect(state, add_ok && VIR.valid(pool, fresh), "复用空闲槽位不需要分配");
            expect(state, !VIR.valid(pool, first), "first 在 clear 后失效");
        }
        VIR.clear(*pool);
        failure.remaining = 10000;
        first, _ = VIR.add(*pool, Item.{ value = 42 });
        first_ptr = VIR.get(pool, first);
        for 0..999 {
            _, _ = VIR.add(*pool, Item.{ value = it });
        }
        expect(state, VIR.get(pool, first) == first_ptr, "预留区里条目地址稳定");
        expect(state, VIR.get(pool, first).value == 42, "扩容后 first 的值仍然正确");
    }
}
//@endregion
