// olib 的 core/profiler 没有测试文件（tests/core/profiler 不存在）；这里的用例按
// profiler.odin 的语义逐条对位，过程名沿用 “作用域计时 / 输出” 的分区。
//
// Jai 侧差异（只影响测试写法，被测语义不变）：
//   - olib 用 @(deferred_out) 让 `defer profile_scope("x")` 自动收尾；Jai 没有 deferred_out，
//     一律写成 `g := profile_scope("x"); defer profile_scope_end(g);`。
//   - 累计时长不靠“跑多慢”来断言：用 profile_now() 造一个 5ms 之前的起点，让
//     profile_scope_end 记下的时长有一个确定下界。
//   - 统计表是 Hash_Table 的 Table(string, Profile_Stat)，用 table_find 按名字取。
#import "Basic" ;
#import "Hash_Table" ;
#import "test_support" ;
PROF :: #import "core/profiler" ;

 //@region 作用域计时与累计

 profile_scope_accumulates :: ( state : * Test_State ) {
PROF . profile_init ( ) ;
expect ( state , PROF . profile_stats . count == 0 , "profile_init 后统计表为空" ) ;

 // 第一次：真实计时的作用域
{
g := PROF . profile_scope ( "test_scope" ) ;
defer PROF . profile_scope_end ( g ) ;
sum := 0 ;
for 1 .. 1000 sum += it ;
expect ( state , sum == 500500 , "scope 体执行" ) ;
}

 expect ( state , PROF . profile_stats . count == 1 , "一条统计记录" ) ;
found , first := table_find ( * PROF . profile_stats , "test_scope" ) ;
expect ( state , found , "按名字找到统计" ) ;
expect ( state , first . count == 1 , "首次 count 为 1" ) ;
expect ( state , first . total >= 0 && first . max >= 0 , "时长非负" ) ;
expect ( state , first . max == first . total , "首次 max 等于 total" ) ;

 // 第二次：同名作用域累加到同一条记录
{
g := PROF . profile_scope ( "test_scope" ) ;
defer PROF . profile_scope_end ( g ) ;
sum := 0 ;
for 1 .. 1000 sum += it ;
expect ( state , sum > 0 , "第二个 scope 体执行" ) ;
}

 found2 , second := table_find ( * PROF . profile_stats , "test_scope" ) ;
expect ( state , found2 && second . count == 2 , "第二次 count 累加到 2" ) ;
expect ( state , second . total >= first . total , "total 单调累加" ) ;
expect ( state , second . max <= second . total , "max 不超过 total" ) ;
expect ( state , PROF . profile_stats . count == 1 , "同名作用域仍只有一条记录" ) ;

 // 不同名字各自一条
{
g := PROF . profile_scope ( "other_scope" ) ;
defer PROF . profile_scope_end ( g ) ;
}
expect ( state , PROF . profile_stats . count == 2 , "不同名字各占一条记录" ) ;
found3 , other := table_find ( * PROF . profile_stats , "other_scope" ) ;
expect ( state , found3 && other . count == 1 , "other_scope count 为 1" ) ;
}

 // 用 profile_now() 造一个 5ms 之前的起点：duration = profile_now() - start >= 5ms。
profile_scope_end_records_elapsed :: ( state : * Test_State ) {
PROF . profile_init ( ) ;

 synthetic := PROF . Profile_Guard .{ name = "synthetic" , start = PROF . profile_now ( ) - 5000000 } ;
PROF . profile_scope_end ( synthetic ) ;

 found , stat := table_find ( * PROF . profile_stats , "synthetic" ) ;
expect ( state , found && stat . count == 1 , "合成 guard 也计入统计" ) ;
expect ( state , stat . total >= 5000000 , "记录到至少 5ms, 实际 % ns" , stat . total ) ;
expect ( state , stat . max == stat . total , "首次 max 等于 total" ) ;

 // 再补一次更短的：total 变大、max 保留较长的那次
shorter := PROF . Profile_Guard .{ name = "synthetic" , start = PROF . profile_now ( ) - 2000000 } ;
PROF . profile_scope_end ( shorter ) ;

 found2 , stat2 := table_find ( * PROF . profile_stats , "synthetic" ) ;
expect ( state , found2 && stat2 . count == 2 , "两次累计 count 为 2" ) ;
expect ( state , stat2 . total >= 7000000 , "total 累加两次, 实际 % ns" , stat2 . total ) ;
expect ( state , stat2 . max >= 5000000 , "max 保留较长的一次" ) ;
expect ( state , stat2 . total >= stat2 . max , "total 不小于 max" ) ;
}

 profile_guard_carries_name_and_start :: ( state : * Test_State ) {
g := PROF . profile_scope ( "guard_name" ) ;
expect ( state , g . name == "guard_name" , "guard 保留名字" ) ;
expect ( state , g . start > 0 , "guard 记录起点" ) ;
expect ( state , PROF . profile_now ( ) >= g . start , "起点不晚于当前读数" ) ;
PROF . profile_scope_end ( g ) ;
}
//@endregion

 //@region 输出与重置

 profile_dump_prints_stats :: ( state : * Test_State ) {
PROF . profile_init ( ) ;

 // 两个作用域都要在 dump 之前收尾（defer 会拖到函数结束，这里显式配对）。
g := PROF . profile_scope ( "dump_scope" ) ;
PROF . profile_scope_end ( g ) ;
dump := PROF . profile_scope ( "dump_scope_2" ) ;
PROF . profile_scope_end ( dump ) ;

 expect ( state , PROF . profile_stats . count == 2 , "输出前有两条记录" ) ;
PROF . profile_dump ( ) ; // 只要求不崩（格式见 profiler.jai 的 profile_dump）
expect ( state , PROF . profile_stats . count == 2 , "dump 不改变统计表" ) ;

 // 重置后归零，可继续使用
PROF . profile_init ( ) ;
expect ( state , PROF . profile_stats . count == 0 , "重置后统计表为空" ) ;
found , _ := table_find ( * PROF . profile_stats , "dump_scope" ) ;
expect ( state , ! found , "重置后旧名字查不到" ) ;

 g3 := PROF . profile_scope ( "dump_scope" ) ;
PROF . profile_scope_end ( g3 ) ;
expect ( state , PROF . profile_stats . count == 1 , "重置后仍可继续计数" ) ;
found_again , again := table_find ( * PROF . profile_stats , "dump_scope" ) ;
expect ( state , found_again && again . count == 1 , "重置后同名记录重新计数" ) ;
}
//@endregion 

// Loop scopes adapted.
