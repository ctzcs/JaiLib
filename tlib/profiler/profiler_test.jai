#import "Basic";
#import "Hash_Table";
#import "test_support";
#import "profiler/profiler";

// Port of the semantics of Ascension/tlib (profiler had no Odin test file).

test_profiler :: (state: *Test_State) {
    profile_init();
    {
        g := profile_scope("test_scope");
        defer profile_scope_end(g);
        sum := 0;
        for 1..1000 sum += it;
        expect(state, sum > 0, "scope body ran");
    }

    expect(state, profile_stats.count == 1, "one profile stat recorded");
    stat, ok := table_find(*profile_stats, "test_scope");
    expect(state, ok, "stat found by name");
    expect(state, stat.count == 1, "stat count is 1");

    // second pass accumulates into the same stat
    {
        g := profile_scope("test_scope");
        defer profile_scope_end(g);
    }
    stat2, _ := table_find(*profile_stats, "test_scope");
    expect(state, stat2.count == 2, "stat count is 2 after second scope");

    profile_dump();
}
