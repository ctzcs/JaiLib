// profiler.jai
// Port of Ascension/tlib/profiler/profiler.odin
// Uses Basic's Apollo_Time monotonic clock instead of Odin's core:time.
// Note: the Odin version attached profile_scope_end via @(deferred_out);
// Jai has no deferred_out, so callers write:
//   g := profile_scope("name"); defer profile_scope_end(g);

#import "Basic";
#import "Hash_Table";

Profile_Stat :: struct {
    count: s64;
    total: Apollo_Time;
    max:   Apollo_Time;
}

profile_stats: Table(string, Profile_Stat);

Profile_Guard :: struct {
    name:  string;
    start: Apollo_Time;
}

profile_init :: () {
    init(*profile_stats);
}

profile_scope :: (name: string) -> Profile_Guard {
    return .{ name = name, start = current_time_monotonic() };
}

profile_scope_end :: (g: Profile_Guard) {
    d := current_time_monotonic() - g.start;
    stat, _ := find_or_add(*profile_stats, g.name);
    stat.count += 1;
    stat.total += d;
    if d > stat.max { stat.max = d; }
}

profile_dump :: () {
    for profile_stats {
        seconds_total, _ := to_float64_seconds(it.total);
        seconds_max,   _ := to_float64_seconds(it.max);
        avg_ms := seconds_total * 1000.0 / max(cast(float64) 1, cast(float64) it.count);
        max_ms := seconds_max * 1000.0;
        tot_ms := seconds_total * 1000.0;
        print("[PROFILE] % count=% avg=%ms max=%ms total=%ms\n",
              it_index, it.count,
              formatFloat(avg_ms, trailing_width=3),
              formatFloat(max_ms, trailing_width=3),
              formatFloat(tot_ms, trailing_width=3));
    }
}
