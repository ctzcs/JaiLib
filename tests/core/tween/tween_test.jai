// 一比一移植自 olib tests/core/tween/{damp_test,manager_reset_test}.odin。
// 断言顺序、断言条数与测试拆分与 olib 一一对应；testing.expect / expectf
// 换成 test_support.expect（同一个 proc，带 % 参数）。
//
// Jai 侧差异（仅测试写法，被验证的行为不变）：
//   - olib 的 @(test) 标记 → 过程签名 (state: *Test_State)，由 runner 统一调度；
//   - `distinct Handle` 的比较：Jai 的运算符按词法解析，core/tween 里的
//     operator == 在本模块不可见，所以这里具名重声明一次（同
//     Tests/core/handle/handle_test.jai 的做法）；
//   - olib 的嵌套 proc `settle`（spring 测试用）提到文件作用域，改名
//     damp_test_settle；
//   - Jai 没有数组相等 / 数组算术：`v == [2]f32{4, -4}` 改为逐分量比较；
//   - 泛型 T 由第一个实参推断，整数字面量实参显式写成 float32。
//
// 末尾的 `*_extension` 三个 proc 是从旧实现 Libs/Engine/tween/tween_test.jai
// 迁移过来的补充覆盖（olib 两个测试文件没有覆盖 Tween 采样 / manager 生命周期 /
// Sequence 时间轴），不属于 olib 对位部分。
#import "Basic" ;
#import "Math" ;
#import "test_support" ;
TW :: #import "core/tween" ;

 operator == :: ( a : TW . Tween_Handle , b : TW . Tween_Handle ) -> bool {
return a . idx == b . idx && a . gen == b . gen ;
}

 //@region damp —— 目标追随（olib tests/core/tween/damp_test.odin）

 // 目标追随：帧率无关、不过冲、零步长与非法参数不产生 NaN。
approach_is_frame_rate_independent :: ( state : * Test_State ) {
a : float32 = 0 ;
b : float32 = 0 ;
for 0 .. 59 {
a = TW . approach ( a , 10 , 8 , 1.0 / 60 ) ;
}
for 0 .. 179 {
b = TW . approach ( b , 10 , 8 , 1.0 / 180 ) ;
}
expect ( state , abs ( a - b ) < 0.001 , "60 帧与 180 帧结果一致 a=% b=%" , a , b ) ;
expect ( state , a < 10 && a > 9.99 , "8/rate 秒后基本到位 a=%" , a ) ;
zero : [ 2 ] float32 = .[ 0 , 0 ] ;
target : [ 2 ] float32 = .[ 4 , - 4 ] ;
v := TW . approach ( zero , target , 1000 , 1 ) ;
expect ( state , v [ 0 ] == 4 && v [ 1 ] == - 4 , "超大 rate 不过冲、直接落到目标 v=(%, %)" , v [ 0 ] , v [ 1 ] ) ;
}

 smooth_damp_settles_without_overshoot :: ( state : * Test_State ) {
pos : [ 2 ] float32 = .[ 0 , 0 ] ;
vel : [ 2 ] float32 = .[ 0 , 0 ] ;
target : [ 2 ] float32 = .[ 100 , 50 ] ;
max_x : float32 = 0 ;
for 0 .. 119 {
pos , vel = TW . smooth_damp ( pos , vel , target , 0.1 , 1.0 / 60 ) ;
max_x = max ( max_x , pos [ 0 ] ) ;
}
expect ( state , abs ( pos [ 0 ] - 100 ) < 0.01 && abs ( pos [ 1 ] - 50 ) < 0.01 , "2 秒后到位 pos=(%, %)" , pos [ 0 ] , pos [ 1 ] ) ;
expect ( state , max_x <= 100.001 , "静止出发的临界阻尼不得过冲 max_x=%" , max_x ) ;
// 一次长帧也必须稳定。
x , xv := TW . smooth_damp ( cast ( float32 ) 0 , cast ( float32 ) 0 , cast ( float32 ) 1 , 0.05 , cast ( float32 ) 1 ) ;
expect ( state , x > 0.99 && x <= 1.001 && abs ( xv ) < 1 , "长帧稳定 x=% v=%" , x , xv ) ;
same , same_v := TW . smooth_damp ( cast ( float32 ) 3 , cast ( float32 ) 2 , cast ( float32 ) 9 , 0.1 , cast ( float32 ) 0 ) ;
expect ( state , same == 3 && same_v == 2 , "dt<=0 原样返回 same=% same_v=%" , same , same_v ) ;
snap , snap_v := TW . smooth_damp ( cast ( float32 ) 3 , cast ( float32 ) 2 , cast ( float32 ) 9 , cast ( float32 ) 0 , 1.0 / 60 ) ;
expect ( state , snap == 9 && snap_v == 0 , "smooth_time<=0 立即到位 snap=% snap_v=%" , snap , snap_v ) ;
}

 // olib 里是 spring 测试内的嵌套 proc；Jai 侧提到文件作用域。
// 迭代次数照抄 `for _ in 0..<int(1 / dt)`（截断取整，1/(1/60) 在 f32 下是 59）。
damp_test_settle :: ( bounce : float32 , dt : float32 ) -> ( final : float32 , peak : float32 ) {
count := cast ( int ) ( 1.0 / dt ) ;
x : float32 = 0 ;
v : float32 = 0 ;
for 0 .. ( count - 1 ) {
x , v = TW . spring ( x , v , 1.0 , 0.3 , bounce , dt ) ;
peak = max ( peak , x ) ;
}
return x , peak ;
}

 spring_settles_and_bounce_controls_overshoot :: ( state : * Test_State ) {
x , peak := damp_test_settle ( 0 , 1.0 / 60 ) ;
expect ( state , abs ( x - 1 ) < 0.001 , "临界阻尼到位 x=%" , x ) ;
expect ( state , peak <= 1.0001 , "bounce=0 静止出发不得过冲 peak=%" , peak ) ;
_ , bouncy := damp_test_settle ( 0.5 , 1.0 / 60 ) ;
expect ( state , bouncy > 1.05 , "bounce=0.5 必须过冲 peak=%" , bouncy ) ;
// 解析解与步长无关。
a , _ := damp_test_settle ( 0.5 , 1.0 / 60 ) ;
b , _ := damp_test_settle ( 0.5 , 1.0 / 240 ) ;
expect ( state , abs ( a - b ) < 0.001 , "步长无关 a=% b=%" , a , b ) ;
// 约 time 秒内基本到位。
y : float32 = 0 ;
yv : float32 = 0 ;
for 0 .. 17 {
y , yv = TW . spring ( y , yv , 1.0 , 0.3 , 0 , 1.0 / 60 ) ;
}
expect ( state , y > 0.97 , "0.3 秒内基本到位 y=%" , y ) ;
// 长帧稳定，冲击速度会回到目标，[N]f32 可用。
big , big_v := TW . spring ( cast ( float32 ) 0 , cast ( float32 ) 0 , cast ( float32 ) 1 , 0.1 , 0.3 , cast ( float32 ) 5 ) ;
expect ( state , abs ( big - 1 ) < 0.001 && abs ( big_v ) < 0.01 , "长帧稳定 big=% big_v=%" , big , big_v ) ;
p : [ 2 ] float32 = .[ 0 , 0 ] ;
pv : [ 2 ] float32 = .[ 40 , - 40 ] ;
p_target : [ 2 ] float32 = .[ 0 , 0 ] ;
for 0 .. 119 {
p , pv = TW . spring ( p , pv , p_target , 0.25 , 0.4 , 1.0 / 60 ) ;
}
expect ( state , abs ( p [ 0 ] ) < 0.01 && abs ( p [ 1 ] ) < 0.01 , "vec2 冲击速度回到目标 p=(%, %)" , p [ 0 ] , p [ 1 ] ) ;
same , same_v := TW . spring ( cast ( float32 ) 3 , cast ( float32 ) 2 , cast ( float32 ) 9 , 0.2 , 0 , cast ( float32 ) 0 ) ;
expect ( state , same == 3 && same_v == 2 , "dt<=0 原样返回 same=% same_v=%" , same , same_v ) ;
snap , snap_v := TW . spring ( cast ( float32 ) 3 , cast ( float32 ) 2 , cast ( float32 ) 9 , cast ( float32 ) 0 , 0.5 , 1.0 / 60 ) ;
expect ( state , snap == 9 && snap_v == 0 , "time<=0 立即到位 snap=% snap_v=%" , snap , snap_v ) ;
}
//@endregion

 //@region manager —— 重置语义（olib tests/core/tween/manager_reset_test.odin）

 // manager 重置语义：reset 复用槽位但换代数，旧句柄必须全部失效。
manager_reset_keeps_previous_handles_invalid :: ( state : * Test_State ) {
manager := TW . manager_make ( ) ;
defer TW . manager_delete ( * manager ) ;
old := TW . manager_add_sequence ( * manager ) ;
expect ( state , TW . manager_is_handle_valid ( manager , old ) , "重置前句柄有效 old=(%, %)" , old . idx , old . gen ) ;
TW . manager_reset ( * manager ) ;
fresh := TW . manager_add_sequence ( * manager ) ;
expect ( state , fresh . idx == old . idx , "重置后复用槽位 fresh.idx=% old.idx=%" , fresh . idx , old . idx ) ;
expect ( state , fresh . gen != old . gen , "重置后代数递增 fresh.gen=% old.gen=%" , fresh . gen , old . gen ) ;
expect ( state , ! TW . manager_is_handle_valid ( manager , old ) , "重置让旧句柄失效" ) ;
expect ( state , TW . manager_is_handle_valid ( manager , fresh ) , "重置后新句柄有效" ) ;
}
//@endregion

 //@region 扩展覆盖 —— Tween 采样（迁移自 Libs/Engine/tween/tween_test.jai）

 lerp_f32 :: ( a : float32 , b : float32 , ratio : float32 ) -> float32 {
return a + ( b - a ) * ratio ;
}

 tween_value_sampling_extension :: ( state : * Test_State ) {
// once + ease-out：t=1 到达 finish 并保持
tw := TW . make_ex ( 0.0 , 10.0 , 0 , TW . Tween_Config .{
duration = 1.0 ,
transition = TW . Transition . EaseOut ,
} , lerp_f32 ) ;
expect ( state , TW . tween_get_value ( * tw , 0.0 ) == 0.0 , "t0 取起点" ) ;
expect ( state , ! TW . tween_is_finished ( * tw , 0.5 ) , "0.5 未结束" ) ;
expect ( state , TW . tween_get_value ( * tw , 1.0 ) == 10.0 , "t1 取终点" ) ;
expect ( state , TW . tween_is_finished ( * tw , 1.25 ) , "1.25 已结束" ) ;
expect ( state , TW . tween_get_value ( * tw , 1.25 ) == 10.0 , "结束后保持终点" ) ;

 // pingpong 在 start / finish 之间往返
pp := TW . make_ex ( 0.0 , 100.0 , 0 , TW . Tween_Config .{
duration = 1.0 ,
repeat_mode = TW . Repeat_Mode . PingPong ,
transition = TW . Transition . Linear ,
} , lerp_f32 ) ;
expect ( state , TW . tween_get_value ( * pp , 0.5 ) == 50.0 , "pingpong 0.5 -> 50" ) ;
expect ( state , TW . tween_get_value ( * pp , 1.5 ) == 50.0 , "pingpong 1.5 -> 50（回程）" ) ;
expect ( state , TW . tween_get_value ( * pp , 2.0 ) == 0.0 , "pingpong 2.0 -> 0" ) ;
expect ( state , TW . tween_get_value ( * pp , 3.0 ) == 100.0 , "pingpong 3.0 -> 100" ) ;
expect ( state , ! TW . tween_is_finished ( * pp , 5.0 ) , "pingpong 永不结束" ) ;

 // delay + loop
lp := TW . make_ex ( 0.0 , 1.0 , 0 , TW . Tween_Config .{
duration = 0.5 ,
delay = 0.25 ,
repeat_mode = TW . Repeat_Mode . Loop ,
transition = TW . Transition . Linear ,
} , lerp_f32 ) ;
expect ( state , TW . tween_get_value ( * lp , 0.0 ) == 0.0 , "loop delay 内取起点" ) ;
expect ( state , TW . tween_get_value ( * lp , 0.25 ) == 0.0 , "loop delay 结束时仍取起点" ) ;
expect ( state , TW . tween_get_value ( * lp , 0.5 ) == 0.5 , "loop t0.5 -> 0.5" ) ;
expect ( state , TW . tween_get_value ( * lp , 0.75 ) == 0.0 , "loop t0.75 回绕到起点" ) ;
expect ( state , TW . tween_get_value ( * lp , 1.0 ) == 0.5 , "loop t1.0 -> 0.5" ) ;

 // transition_proc（.Custom）
ct := TW . make_ex ( 0.0 , 1.0 , 0 , TW . Tween_Config .{
duration = 1.0 ,
transition = TW . Transition . Linear ,
} , lerp_f32 ) ;
TW . tween_set_transition_proc ( * ct , ( t : float32 ) -> float32 { return t * t ; } ) ;
expect ( state , TW . tween_get_value ( * ct , 0.5 ) == 0.25 , "自定义缓动 t0.5 -> 0.25" ) ;
}
//@endregion

 //@region 扩展覆盖 —— manager 生命周期（迁移自 Libs/Engine/tween/tween_test.jai）

 managed_value : float32 ;
managed_start_count : s32 ;
managed_complete_count : s32 ;
managed_kill_count : s32 ;

 managed_set_value :: ( value : float32 ) {
managed_value = value ;
}

 managed_on_start :: ( handle : TW . Tween_Handle ) {
managed_start_count += 1 ;
}

 managed_on_complete :: ( handle : TW . Tween_Handle ) {
managed_complete_count += 1 ;
}

 managed_on_kill :: ( handle : TW . Tween_Handle ) {
managed_kill_count += 1 ;
}

 manager_lifecycle_extension :: ( state : * Test_State ) {
mgr := TW . manager_make ( ) ;
defer TW . manager_delete ( * mgr ) ;

 managed_value = - 1 ;
managed_start_count = 0 ;
managed_complete_count = 0 ;
managed_kill_count = 0 ;

 tw := TW . make_ex ( 0.0 , 10.0 , 0 , TW . Tween_Config .{
duration = 1.0 ,
delay = 0.25 ,
transition = TW . Transition . Linear ,
} , lerp_f32 ) ;
h := TW . manager_add_tween ( * mgr , tw , managed_set_value ) ;
expect ( state , managed_value == 0.0 , "注册时立刻推起点值" ) ;
expect ( state , TW . manager_is_handle_valid ( mgr , h ) , "add 之后句柄有效" ) ;
_ = TW . manager_on_start ( * mgr , h , managed_on_start ) ;
_ = TW . manager_on_complete ( * mgr , h , managed_on_complete ) ;
_ = TW . manager_on_kill ( * mgr , h , managed_on_kill ) ;

 TW . manager_update ( * mgr , 0.1 ) ; // now=0.1，仍在 delay 内
expect ( state , managed_value == 0.0 , "now=0.1 仍在 delay 内" ) ;

 TW . manager_update ( * mgr , 0.2 ) ; // now=0.3，越过 0.25 的 delay
expect ( state , managed_value > 0.0 , "delay 之后开始推进" ) ;
expect ( state , managed_start_count == 1 , "on_start 只触发一次" ) ;

 TW . manager_update ( * mgr , 0.5 ) ; // now=0.8，elapsed 0.55
TW . manager_update ( * mgr , 0.5 ) ; // now=1.3 > 1.25，完成
expect ( state , managed_value == 10.0 , "完成值是终点" ) ;
expect ( state , managed_complete_count == 1 , "on_complete 触发一次" ) ;

 TW . manager_update ( * mgr , 0.1 ) ;
expect ( state , ! TW . manager_is_handle_valid ( mgr , h ) , "完成后自动清理" ) ;
expect ( state , managed_kill_count == 0 , "自动清理不触发 on_kill" ) ;

 // pause / play / kill
h2 := TW . manager_add_tween ( * mgr , tw , managed_set_value ) ;
expect ( state , TW . manager_pause ( * mgr , h2 ) , "pause 成功" ) ;
TW . manager_update ( * mgr , 0.5 ) ;
expect ( state , managed_value == 0.0 , "暂停后不再推进" ) ;
expect ( state , TW . manager_play ( * mgr , h2 ) , "play 成功" ) ;
TW . manager_update ( * mgr , 0.5 ) ;
expect ( state , managed_value > 0.0 , "恢复后继续推进" ) ;

 expect ( state , TW . manager_kill ( * mgr , h2 ) , "kill 成功" ) ;
TW . manager_update ( * mgr , 0.1 ) ;
expect ( state , ! TW . manager_is_handle_valid ( mgr , h2 ) , "kill 后节点被清理" ) ;
}
//@endregion

 //@region 扩展覆盖 —— Sequence 时间轴（迁移自 Libs/Engine/tween/tween_test.jai）

 seq_callback_count : s32 ;

 seq_callback_proc :: ( ) {
seq_callback_count += 1 ;
}

 sequence_timeline_extension :: ( state : * Test_State ) {
mgr := TW . manager_make ( ) ;
defer TW . manager_delete ( * mgr ) ;

 managed_value = - 1 ;
seq := TW . manager_add_sequence ( * mgr ) ;

 tw1 := TW . make_ex ( 0.0 , 10.0 , 0 , TW . Tween_Config .{
duration = 1.0 ,
transition = TW . Transition . Linear ,
} , lerp_f32 ) ;
h1 , ok := TW . sequence_append_tween ( * mgr , seq , tw1 , managed_set_value ) ;
expect ( state , ok && ! ( h1 == TW . TWEEN_HANDLE_NONE ) , "append tween 成功" ) ;

 tw2 := TW . make_ex ( 10.0 , 20.0 , 0 , TW . Tween_Config .{
duration = 1.0 ,
transition = TW . Transition . Linear ,
} , lerp_f32 ) ;
_ , ok2 := TW . sequence_append_tween ( * mgr , seq , tw2 , managed_set_value ) ;
expect ( state , ok2 , "append 第二个 tween 成功" ) ;

 TW . manager_update ( * mgr , 0.5 ) ;
expect ( state , managed_value == 5.0 , "seq: 第一段中点" ) ;
TW . manager_update ( * mgr , 0.5 ) ; // now=1.0
expect ( state , managed_value == 10.0 , "seq: 第一段结束" ) ;
TW . manager_update ( * mgr , 0.5 ) ; // now=1.5
expect ( state , managed_value == 15.0 , "seq: 第二段中点" ) ;
TW . manager_update ( * mgr , 0.5 ) ; // now=2.0
expect ( state , managed_value == 20.0 , "seq: 第二段结束" ) ;
TW . manager_update ( * mgr , 0.5 ) ;
expect ( state , ! TW . manager_is_handle_valid ( mgr , seq ) , "sequence 完成后自动清理" ) ;
expect ( state , ! TW . manager_is_handle_valid ( mgr , h1 ) , "子节点随 sequence 一起清理" ) ;

 // callback + interval
seq2 := TW . manager_add_sequence ( * mgr ) ;
seq_callback_count = 0 ;
_ = TW . sequence_append_interval ( * mgr , seq2 , 0.5 ) ;
expect ( state , TW . sequence_append_callback ( * mgr , seq2 , seq_callback_proc ) , "append callback 成功" ) ;

 TW . manager_update ( * mgr , 0.25 ) ;
expect ( state , seq_callback_count == 0 , "callback 尚未触发" ) ;
TW . manager_update ( * mgr , 0.5 ) ; // 越过 0.5 的 interval
expect ( state , seq_callback_count == 1 , "interval 之后 callback 触发一次" ) ;
}
//@endregion 

// Loop scopes adapted.
