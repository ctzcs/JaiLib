// profiler —— 轻量作用域计时统计。
// 一比一移植自 olib core/profiler/profiler.odin（数据形状、累计语义、输出格式一致）。
//
// 用法（olib 用 @(deferred_out) 让 `defer profile_scope("frame")` 自动收尾；
// Jai 没有 deferred_out，必须显式配对）：
//
//     g := profile_scope("frame");
//     defer profile_scope_end(g);
//
// Jai 侧差异（对外语义不变）：
//   - 计时单位：olib 的 time.Duration 是 i64 纳秒，这里用 Duration :: s64 表示同一单位
//     （纳秒）。时钟换成本仓库既有的 Basic 单调时钟 current_time_monotonic（Apollo_Time，
//     128 位飞秒，单调不回退），用 to_nanoseconds 折成纳秒；减法与累计的语义同
//     time.now / time.since。
//   - profile_now 是 olib `time.now()` 的桥：Profile_Guard.start 是公开字段，调用方要
//     自己造 guard（测试、离线补录）时需要一个同源的“现在”。olib 里它就是 time.now()。
//   - 统计表：olib 是全局 map[string]Profile_Stat，这里用 Basic 的 Hash_Table 的
//     Table(string, Profile_Stat)（零值可用；分配器首次增长时取 context.allocator）。
//     profile_init 仍保留：清空并释放旧表后重新开始，等价于 olib 的 make 新 map。
//   - 累加走 table_find_pointer 原地更新（jacket 的 Hash_Table 没有 find_or_add，而
//     table_add 允许重复键，会让同名作用域散成多条），未命中才 table_set 插入一条：
//     与 olib 的 `s := profile_stats[name]` + 写回同一语义，命中时不分配。
//   - profile_dump 的 `%-20s` 在 Jai 的 print 里没有宽度说明符，改为手工补空格到 20 列
//     （名字超长时不截断，同 printf 的 %-20s）；浮点仍是 3 位小数（formatFloat
//     trailing_width=3）。
#import "Basic";        // print / formatFloat / current_time_monotonic / to_nanoseconds
#import "Hash_Table";   // Table(string, Profile_Stat)

//@region 数据 —— 统计表与 Guard 类型

// 纳秒，对位 olib 的 time.Duration（i64 纳秒）。
Duration :: s64;

Profile_Stat :: struct {
    count: s64;
    total: Duration;
    max:   Duration;
}

Profile_Guard :: struct {
    name:  string;
    start: Duration;
}

// 全局统计表（名字 -> Profile_Stat）。零值即可用；profile_init 清空重来。
profile_stats: Table(string, Profile_Stat);

// olib `time.now()` 的桥：单调时钟的纳秒读数（只保证差值有意义）。
profile_now :: () -> Duration {
    nanoseconds, _ := to_nanoseconds(current_time_monotonic());
    return nanoseconds;
}

profile_init :: () {
    deinit(*profile_stats);       // 释放旧表（等价于 olib 丢弃旧 map）
    profile_stats = .{};          // 分配器留空：首次增长时取 context.allocator
}
//@endregion

//@region Scope Guard —— 作用域计时

// 用法：`g := profile_scope("frame"); defer profile_scope_end(g);`
// —— 作用域结束时自动累计耗时。
profile_scope :: (name: string) -> Profile_Guard {
    return Profile_Guard.{
        name  = name,
        start = profile_now(),
    };
}

profile_scope_end :: (g: Profile_Guard) {
    d := profile_now() - g.start;

    // 对位 olib 的 `s := profile_stats[g.name]` + 写回：命中时原地累加（不再分配），
    // 未命中时插入一条。不能用 table_add —— jacket 的 table_add 允许重复键，
    // 会让同名作用域散成多条记录。
    stat := table_find_pointer(*profile_stats, g.name);
    if !stat {
        table_set(*profile_stats, g.name, Profile_Stat.{ count = 1, total = d, max = d });
        return;
    }
    stat.count += 1;
    stat.total += d;
    if d > stat.max stat.max = d;
}
//@endregion

//@region 输出

profile_dump :: () {
    for stat, name: profile_stats {
        // olib: f64(duration_milliseconds(total)) / max(1.0, f64(count))
        // Jai 的 max 泛型会把字面量 1.0 推断成 float32，这里直接展开等价写法。
        divisor := cast(float64) stat.count;
        if divisor < 1.0 divisor = 1.0;
        avg_ms := cast(float64) stat.total / 1000000.0 / divisor;
        max_ms := cast(float64) stat.max / 1000000.0;
        tot_ms := cast(float64) stat.total / 1000000.0;

        print("[PROFILE] %", name);
        if name.count < 20 {
            for name.count..20 - 1 print(" ");   // %-20s
        }
        print(" count=% avg=%ms max=%ms total=%ms\n",
              stat.count,
              formatFloat(avg_ms, trailing_width = 3),
              formatFloat(max_ms, trailing_width = 3),
              formatFloat(tot_ms, trailing_width = 3));
    }
}
//@endregion
