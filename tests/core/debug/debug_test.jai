// olib 的 core/debug 没有测试文件（tests/core/debug 不存在）；这里的用例按 debug.odin
// 的语义逐条对位：track_create 返回可用的 Allocator、分配/释放/重分配都记账、
// 未记账指针的释放进 bad_free_array、track_destroy 汇报后把追踪器自己的内存全部归还。
//
// Jai 侧差异（只影响测试写法，被测语义不变）：
//   - 没有 @(deferred_out)，一律 `track := track_create(...); defer track_destroy(track);`
//     或者显式配对。
//   - Jai 没有 odin 的 `alloc(allocator, size)` 帮手，测试直接用 Allocator 的公开字段
//     （proc / data）调用，这也是仓库里其它模块的写法（见 localization）。
//   - 逐条分配的源码位置不可得（Allocator_Proc 不带 #caller_location），所以这里不断言
//     entry.location，只断言字节数、指针与计数。
#import "Basic" ;
#import "Hash_Table" ;
#import "test_support" ;
DBG :: #import "core/debug" ;

 //@region 计数 backing allocator

 // 只用来验证「追踪器自己分配的内存也全部归还」：记录净存活字节数。
Counting :: struct {
allocs : s64 ;
frees : s64 ;
live : s64 ;
}

 counting_proc :: ( mode : Allocator_Mode , size : s64 , old_size : s64 , old_memory : * void , allocator_data : * void ) -> * void {
c := cast ( * Counting ) allocator_data ;
if mode == {
case . ALLOCATE ;
result := context . allocator . proc ( . ALLOCATE , size , 0 , null , context . allocator . data ) ;
if result {
c . allocs += 1 ;
c . live += size ;
}
return result ;
case . RESIZE ;
result := context . allocator . proc ( . RESIZE , size , old_size , old_memory , context . allocator . data ) ;
if result c . live += size - old_size ;
return result ;
case . FREE ;
if old_memory {
context . allocator . proc ( . FREE , 0 , old_size , old_memory , context . allocator . data ) ;
c . frees += 1 ;
c . live -= old_size ;
}
return null ;
}
return null ;
}
//@endregion

 //@region 测试用的分配器调用

 tra_alloc :: ( track : Allocator , size : s64 ) -> * void {
return track . proc ( . ALLOCATE , size , 0 , null , track . data ) ;
}

 tra_free :: ( track : Allocator , memory : * void , size : s64 ) {
track . proc ( . FREE , 0 , size , memory , track . data ) ;
}

 tra_resize :: ( track : Allocator , memory : * void , old_size : s64 , new_size : s64 ) -> * void {
return track . proc ( . RESIZE , new_size , old_size , memory , track . data ) ;
}
//@endregion

 //@region 记账、非法释放、泄漏与归还

 callback_hits : s64 ;

 note_bad_free :: ( ta : * DBG . Tracking_Allocator , entry : DBG . Tracking_Allocator_Bad_Free ) -> bool {
callback_hits += 1 ;
return true ; // 已处理：不再额外打印
}

 tracking_allocator_records_and_reports :: ( state : * Test_State ) {
counting : Counting ;
backing := Allocator .{ counting_proc , * counting } ;

 track := DBG . track_create ( backing ) ;
expect ( state , track . proc != null , "track_create 返回可用的 allocator" ) ;
expect ( state , track . data != null , "track_create 带回追踪器指针" ) ;
expect ( state , counting . live == size_of ( DBG . Tracking_Allocator ) ,
"追踪器自身从 backing 分配一次, live=%" , counting . live ) ;

 ta := cast ( * DBG . Tracking_Allocator ) track . data ;
expect ( state , ta . allocation_map . count == 0 , "初始无记账" ) ;
expect ( state , ta . bad_free_array . count == 0 , "初始无非法释放" ) ;

 // 分配：两条记录，字节数按分配大小记
p64 := tra_alloc ( track , 64 ) ;
expect ( state , p64 != null , "分配 64 字节" ) ;
expect ( state , ta . allocation_map . count == 1 , "记账 1 条" ) ;
found64 , entry64 := table_find ( * ta . allocation_map , p64 ) ;
expect ( state , found64 && entry64 . size == 64 , "记录的字节数为 64" ) ;

 p128 := tra_alloc ( track , 128 ) ;
expect ( state , ta . allocation_map . count == 2 , "记账 2 条" ) ;

 // 释放：只去掉被释放的那条
tra_free ( track , p64 , 64 ) ;
expect ( state , ta . allocation_map . count == 1 , "释放后只剩 1 条" ) ;
found_p64 , _ := table_find ( * ta . allocation_map , p64 ) ;
expect ( state , ! found_p64 , "释放过的指针已不在记账表里" ) ;
found128 , _ := table_find ( * ta . allocation_map , p128 ) ;
expect ( state , found128 , "未释放的指针仍在记账表里" ) ;

 // 重分配：旧指针的记录换成新指针，字节数更新
p256 := tra_resize ( track , p128 , 128 , 256 ) ;
expect ( state , p256 != null , "重分配成功" ) ;
expect ( state , ta . allocation_map . count == 1 , "重分配后仍只有 1 条" ) ;
found_p256 , entry256 := table_find ( * ta . allocation_map , p256 ) ;
expect ( state , found_p256 && entry256 . size == 256 , "新指针记录的字节数为 256" ) ;
tra_free ( track , p256 , 256 ) ;
expect ( state , ta . allocation_map . count == 0 , "释放重分配后的指针, 记账清零" ) ;

 // 非法释放：指针从未经过追踪器
raw := backing . proc ( . ALLOCATE , 16 , 0 , null , backing . data ) ;
tra_free ( track , raw , 16 ) ;
expect ( state , ta . bad_free_array . count == 1 , "非法释放记入 bad_free_array" ) ;
expect ( state , ta . bad_free_array [ 0 ] . memory == raw , "记录的是被释放的指针" ) ;
expect ( state , ta . allocation_map . count == 0 , "非法释放不产生记账条目" ) ;

 // 设置回调后：回调被调用一次，且仍记入 bad_free_array
ta . bad_free_callback = note_bad_free ;
raw2 := backing . proc ( . ALLOCATE , 8 , 0 , null , backing . data ) ;
tra_free ( track , raw2 , 8 ) ;
expect ( state , callback_hits == 1 , "bad_free_callback 被调用一次, 实际 %" , callback_hits ) ;
expect ( state , ta . bad_free_array . count == 2 , "回调不会吞掉记录" ) ;

 // 泄漏：留一条不释放，destroy 时应当被汇报
leak := tra_alloc ( track , 100 ) ;
expect ( state , leak != null && ta . allocation_map . count == 1 , "留下一条泄漏" ) ;

 live_before := counting . live ;
expect ( state , live_before > 100 , "destroy 前 backing 上还挂着追踪器与记账结构" ) ;

 DBG . track_destroy ( track ) ; // 打印 1 条泄漏 + 2 条非法释放，然后销毁追踪器

 // 追踪器结构体、Table 槽位与 bad_free_array 全部归还，只剩那条故意的泄漏。
expect ( state , counting . live == 100 ,
"追踪器自身与记账结构全部归还（只剩泄漏的 100 字节）, 实际 %" , counting . live ) ;

 // 收尾：把泄漏的 100 字节按 backing 归还，净存活归零
backing . proc ( . FREE , 0 , 100 , leak , backing . data ) ;
expect ( state , counting . live == 0 , "全部归还后 live 为 0, 实际 %" , counting . live ) ;
}
//@endregion

 //@region 默认 backing 与 init/destroy 形状

 debug_default_backing_wrapper :: ( state : * Test_State ) {
track := DBG . track_create ( ) ; // 默认 context.allocator
expect ( state , track . proc != null , "默认 backing 也能创建追踪器" ) ;
expect ( state , track . data != null , "默认 backing 带回追踪器指针" ) ;

 ta := cast ( * DBG . Tracking_Allocator ) track . data ;
p := tra_alloc ( track , 32 ) ;
expect ( state , p != null , "默认 backing 分配成功" ) ;
expect ( state , ta . allocation_map . count == 1 , "默认 backing 也记账" ) ;

 tra_free ( track , p , 32 ) ;
expect ( state , ta . allocation_map . count == 0 , "释放后记账清零" ) ;

 DBG . track_destroy ( track ) ; // 无泄漏、无非法释放
expect ( state , true , "默认 backing 下 destroy 正常返回" ) ;
}

 tracking_allocator_init_and_helper :: ( state : * Test_State ) {
loc := DBG . source_location ( ) ;
expect ( state , loc . line > 0 , "source_location 有行号" ) ;
expect ( state , loc . file . count > 0 , "source_location 有文件名" ) ;
expect ( state , loc . procedure . count == 0 , "Jai 的位置信息不含过程名" ) ;

 ta : DBG . Tracking_Allocator ;
DBG . tracking_allocator_init ( * ta ) ;
expect ( state , ta . backing . proc != null , "init 取到默认 backing" ) ;
expect ( state , ta . allocation_map . count == 0 && ta . bad_free_array . count == 0 , "init 后记账为空" ) ;

 wrapper := DBG . tracking_allocator ( * ta ) ;
expect ( state , wrapper . proc != null , "tracking_allocator 返回可用的 proc" ) ;
expect ( state , wrapper . data == cast ( * void ) * ta , "tracking_allocator 绑定到同一个追踪器" ) ;

 entry := DBG . Tracking_Allocator_Bad_Free .{ memory = null } ;
expect ( state , DBG . tracking_allocator_bad_free_callback_add_to_array ( * ta , entry ) , "回调助手恒返回已处理" ) ;

 DBG . tracking_allocator_destroy ( * ta ) ;
expect ( state , ta . allocation_map . count == 0 && ta . bad_free_array . count == 0 , "destroy 后记账结构清空" ) ;
}
//@endregion 

// Loop scopes adapted.
