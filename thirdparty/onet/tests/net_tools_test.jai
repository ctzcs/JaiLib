#scope_file
objects :: #import "thirdparty/onet/objects" ;
nr :: #import "thirdparty/onet/runtime" ;
session :: #import "thirdparty/onet/session" ;
sim :: #import "thirdparty/onet/simulation" ;
#scope_export
// 网络统计、定长状态布局与单独输入 user。弱网包装的跨后端一致性见 transport_conformance_test。




//@region 网络统计


runtime_stats_count_corrections_without_event_subscription :: ( t : * Test ) {

 s , a : RW_Endpoint ;
rw_init ( * s , true , false ) ;
rw_init ( * a , false , false ) ;
defer rw_shutdown ( ( * RW_Endpoint ) .[ * s , * a ] ) ;
s . gain = 2 ; // 服务器规则不同，客户端预测必然被校正。

 a . moving = true ;
{ loop_index := 0 ; while loop_index < 4 { defer loop_index += 1 ;
o := objects . spawn ( * s . node . reg , 0 ) ;
array_add ( * o . components , rw_factory ( ) ) ;
} }

 expect ( t , session . start_server ( * s . node . s , 0 ) ) ;
expect ( t , session . start_client ( * a . node . s , "127.0.0.1" , session . bound_port ( * s . node . s ) ) ) ;
nodes := ( * RT_Node ) .[ * s . node , * a . node ] ;
rt_pump ( nodes , 80 ) ;
if ! expect ( t , a . node . s . client_authenticated ) {
return ;
}

 expect ( t , objects . set_controller ( * s . node . reg , 1 , a . node . s . client_server_id ) ) ;
rt_pump ( nodes , 150 ) ;
client := nr . stats ( * a . node . r . client ) ;
server := nr . stats ( * s . node . r . server ) ;
expect ( t , client . corrections > 0 && client . corrected_systems >= client . corrections , "client corrections counted" ) ;
expect ( t , client . full_resyncs >= 1 , "initial seed counted" ) ;
expect ( t , client . tick > 0 && client . applied_tick > 0 && client . prediction_lead == ( cast , trunc ( s64 ) ( client . tick ) ) - ( cast , trunc ( s64 ) ( client . applied_tick ) ) ) ;
expect ( t , client . rtt_ms >= 0 && a . node . r . client . state_clock . sampled , "clock stats" ) ;
expect_value ( t , client . missing_inputs , 0 ) ; // 客户端不统计远端系统的输入缺失。

 expect ( t , client . backend_ok && client . backend . rtt_ms >= 0 , "client backend quality" ) ;
expect ( t , ! server . backend_ok , "server world reports no single backend link" ) ;
expect ( t , server . tick > 0 && server . prediction_lead == 0 ) ;
expect_value ( t , server . rtt_ms , 0 ) ;

 }

 //@endregion


//@region 定长状态布局


simulation_state_layout_round_trip_and_bounds :: ( t : * Test ) {

 buf : [ 13 ] u8 ;
at := 0 ;
expect ( t , sim . state_put_vec2 ( view ( buf , 0 ) , * at , .[
1.5 , - 2
] ) ) ;
expect ( t , sim . state_put_u8 ( view ( buf , 0 ) , * at , 7 ) ) ;
expect ( t , sim . state_put_u16 ( view ( buf , 0 ) , * at , 0xBEEF ) ) ;
expect ( t , sim . state_put_u16 ( view ( buf , 0 ) , * at , 3 ) ) ;
expect_value ( t , at , 13 ) ;
expect ( t , ! sim . state_put_u8 ( view ( buf , 0 ) , * at , 1 ) , "write past end rejected" ) ;
expect_value ( t , at , 13 ) ;
at = 10 ;
expect ( t , ! sim . state_put_f32 ( view ( buf , 0 ) , * at , 1 ) , "partial write rejected" ) ;
expect ( t , ! sim . state_put_vec2 ( view ( buf , 0 ) , * at , .{

 } ) , "partial vec2 rejected" ) ;
expect_value ( t , buf [ 10 ] , ( cast , trunc ( u8 ) ( 0xBE ) ) ) ;
at = - 1 ;
expect ( t , ! sim . state_put_u8 ( view ( buf , 0 ) , * at , 1 ) , "negative offset rejected" ) ;

 at = 0 ;
v , ok := sim . state_get_vec2 ( view ( buf , 0 ) , * at ) ;
expect ( t , ok && v == float32 .[
1.5 , - 2
] ) ;
b , _ := sim . state_get_u8 ( view ( buf , 0 ) , * at ) ;
h , _ := sim . state_get_u16 ( view ( buf , 0 ) , * at ) ;
expect ( t , b == 7 && h == 0xBEEF ) ;
expect_value ( t , buf [ 0 ] , ( cast , trunc ( u8 ) ( 0 ) ) ) ; // 小端：1.5 = 0x3FC00000

 expect_value ( t , buf [ 3 ] , ( cast , trunc ( u8 ) ( 0x3F ) ) ) ;
at = 11 ;
f , f_ok := sim . state_get_f32 ( view ( buf , 0 ) , * at ) ;
expect ( t , ! f_ok && f == 0 && at == 11 , "read past end" ) ;
u , u_ok := sim . state_get_u32 ( view ( buf , 0 ) , * at ) ;
expect ( t , ! u_ok && u == 0 ) ;

 }

 //@endregion


//@region 单独的输入 user

 NT_Input :: struct {
bits : u8 ;
}

 NT_Body :: struct {
value : u64 ;
seen_user : * void ;
}

 nt_capture :: ( p : * void , dst : [ ] u8 ) {
at := 0 ;
sim . state_put_u32 ( dst , * at , ( cast , trunc ( u32 ) ( ( ( cast ( * NT_Body ) p ) ) . value ) ) ) ;
}

 nt_restore :: ( p : * void , state : [ ] u8 ) {
at := 0 ;
v , _ := sim . state_get_u32 ( state , * at ) ;
( ( cast ( * NT_Body ) p ) ) . value = ( cast , trunc ( u64 ) ( v ) ) ;
}

 nt_valid :: ( p : * void , state : [ ] u8 , tick : sim . Tick ) -> bool {
return ( state ) . count == 4 ;
}

 nt_valid_input :: ( p : * void , input : [ ] u8 , tick : sim . Tick ) -> bool {
return ( input ) . count == 1 ;
}

 nt_sample :: ( p : * void , dst : [ ] u8 , tick : sim . Tick ) {
dst [ 0 ] = ( ( cast ( * NT_Input ) p ) ) . bits ;
}

 nt_early :: ( p : * void , step : * sim . World_Step ) {
( ( cast ( * NT_Body ) p ) ) . value += ( cast , trunc ( u64 ) ( step . input [ 0 ] ) ) ;
}



 simulation_sample_input_uses_input_user :: ( t : * Test ) {

 w : sim . Simulation_World ;
expect_value ( t , sim . world_init ( * w , .{
authority = true , fixed_dt = 0.02
} ) , sim . Status . Ok ) ;
defer sim . world_destroy ( * w ) ;
body : NT_Body ;
keys := NT_Input .{
3 ,
} ;

 cb := sim . System_Callbacks .{
user = * body , input_user = * keys , capture = nt_capture , restore = nt_restore , validate_state = nt_valid , validate_input = nt_valid_input , sample_input = nt_sample , early = nt_early ,
} ;

 expect_value ( t , sim . world_register ( * w , .{
id = 1 , schema = 7 , state_size = 4 , input_size = 1 , callbacks = cb
} ) , sim . Status . Ok ) ;
expect_value ( t , sim . world_step ( * w ) , sim . Status . Ok ) ;
keys . bits = 4 ;
expect_value ( t , sim . world_step ( * w ) , sim . Status . Ok ) ;
expect_value ( t , body . value , ( cast , trunc ( u64 ) ( 7 ) ) ) ;

 } ;

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
