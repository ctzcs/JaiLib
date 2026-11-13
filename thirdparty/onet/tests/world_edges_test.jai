#scope_file
core :: #import "thirdparty/onet/core" ;
objects :: #import "thirdparty/onet/objects" ;
nr :: #import "thirdparty/onet/runtime" ;
session :: #import "thirdparty/onet/session" ;
sim :: #import "thirdparty/onet/simulation" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export


//@region 输入包事务与观察子集

 wx_admit :: ( user : * void , id : sim . System_Id , owner : transport . Connection_Id ) -> bool {
return id != 2 ;
}

 wx_select_one :: ( id : sim . System_Id , user : * void ) -> bool {
return id == 1 ;
}


world_input_packet_authorizer_rejects_all_records_atomically :: ( t : * Test ) {

 s , c : WX_Fixture ;
wx_init ( * s , true ) ;
wx_init ( * c , false ) ;
defer sim . world_destroy ( * s . world ) ;
defer sim . world_destroy ( * c . world ) ;
wx_seed ( t , * s , * c ) ;
c . a . sample , c . b . sample = .[
3 , 1 ,
] , .[
4 , 0 ,
] ;

 expect_value ( t , sim . world_step ( * c . world ) , . Ok ) ;
data , status := sim . world_encode_input ( * c . world , 1 , 1 ) ;
defer release ( data ) ;
expect_value ( t , status , . Ok ) ;
expect_value ( t , sim . world_receive_input ( * s . world , 1 , data , wx_admit ) , . Invalid_Data ) ;
expect_value ( t , ( s . world . queued ) . count , 0 ) ;
expect_value ( t , sim . world_receive_input ( * s . world , 1 , data ) , . Ok ) ;
expect_value ( t , ( s . world . queued ) . count , 2 ) ;

 } ;


world_filtered_snapshot_contains_only_observed_systems_and_adopts_owner :: ( t : * Test ) {

 s , c : WX_Fixture ;
wx_init ( * s , true ) ;
defer sim . world_destroy ( * s . world ) ;
assert ( sim . world_init ( * c . world , .{
local_owner = 1 , fixed_dt = 0.02 , capacity = 16
} ) == . Ok ) ;
defer sim . world_destroy ( * c . world ) ;
c . a . gain = 1 ;
assert ( wx_register ( * c , * c . a , 1 , 1 ) == . Ok ) ;
s . a . value , s . b . value , s . remote . value = 17 , 999 , 888 ;
assert ( sim . world_set_owner ( * s . world , 1 , 2 , 2 ) ) ;
assert ( sim . world_step ( * s . world ) == . Ok ) ;
data , status := sim . world_encode_snapshot ( * s . world , 1 , 0 , wx_select_one ) ;
defer release ( data ) ;
expect_value ( t , status , . Ok ) ;
expect_value ( t , sim . world_receive_snapshot ( * c . world , data ) , . Ok ) ;
_ , _ , result := sim . world_reconcile ( * c . world ) ;
expect_value ( t , result , . Ok ) ;
expect ( t , c . a . value == 17 && ( c . world . systems ) . count == 1 ) ;
cs , _ := sim . world_find ( * c . world , 1 ) ;
expect ( t , cs . config . owner == 2 && cs . config . incarnation == 2 ) ;

 } ;

 //@endregion


//@region 运行中的Session晚绑定与最后静止状态


world_runtime_late_bind_discards_session_tick_clock_and_pending_probes :: ( t : * Test ) {

 s , a : RT_Node ;
rt_init ( * s , true ) ;
rt_init ( * a , false ) ;
server , client : sim . Simulation_World ;
defer sim . world_destroy ( * server ) ;
defer sim . world_destroy ( * client ) ;
defer rt_shutdown ( ( * RT_Node ) .[ * s , * a ] ) ;
assert ( session . start_server ( * s . s , 0 ) ) ;
assert ( session . start_client ( * a . s , "127.0.0.1" , session . bound_port ( * s . s ) ) ) ;
rt_pump ( ( * RT_Node ) .[ * s , * a ] , 300 ) ;
expect ( t , a . r . client . world_clock . sampled && a . r . client . world_clock . remote_tick > 100 ) ;
assert ( sim . world_init ( * server , .{
authority = true , fixed_dt = 0.01 , capacity = 16
} ) == . Ok ) ;
assert ( sim . world_init ( * client , .{
fixed_dt = 0.01 , capacity = 16
} ) == . Ok ) ;
H . table_set ( * a . r . client . clock_pending , 999 , 123 ) ;
expect ( t , nr . bind_simulation ( * s . r . server , * server , false ) && nr . bind_simulation ( * a . r . client , * client , false ) ) ;
expect ( t , ! a . r . client . world_clock . sampled && ( a . r . client . clock_pending ) . count == 0 ) ;
rt_pump ( ( * RT_Node ) .[ * s , * a ] , 80 ) ;
expect ( t , a . r . client . world_clock . sampled && a . r . client . world_clock . remote_tick < 60 && client . tick > 0 && client . tick < 70 ) ;

 } ;


world_runtime_idle_playout_releases_final_frame_without_more_server_packets :: ( t : * Test ) {

 s , a : RT_Node ;
rt_init ( * s , true ) ;
rt_init ( * a , false ) ;
defer rt_shutdown ( ( * RT_Node ) .[ * s , * a ] ) ;
o := rt_spawn ( * s , 1 ) ;
assert ( session . start_server ( * s . s , 0 ) ) ;
assert ( session . start_client ( * a . s , "127.0.0.1" , session . bound_port ( * s . s ) ) ) ;
rt_pump ( ( * RT_Node ) .[ * s , * a ] , 80 ) ;
// 不再更新server；构建一个最终状态，证明释放不依赖下一包到来。

 { loop_index := 0 ; while loop_index < 20 { defer loop_index += 1 ;
nr . update ( * a . r , 5 ) ;
} }

 ( ( cast ( * RT_Value ) o . components [ 0 ] . userdata ) ) . value = 73 ;
p := table_get ( * s . r . server . peers , a . s . client_server_id ) ;
writer : core . Writer ;
core . writer_init ( * writer ) ;
defer core . writer_destroy ( * writer ) ;
final_tick := s . s . tick + 20 ;
assert ( objects . peer_build ( * s . reg , * p . state , * writer , final_tick ) ) ;
data := core . writer_to_array ( * writer ) ;
defer release ( data ) ;
sim . clock_reset ( * a . r . client . state_clock ) ;
assert ( nr . enqueue_state ( * a . r . client , session . local_connection ( * a . s ) , data ) ) ;
old := a . r . client . client_peer . applied ;
expect_value ( t , rt_value ( * a , o . id ) , ( cast , trunc ( s32 ) ( 1 ) ) ) ;
nr . update ( * a . r , 1 ) ;
expect_value ( t , a . r . client . client_peer . applied , old ) ;
{ loop_index := 0 ; while loop_index < 40 { defer loop_index += 1 ;
nr . update ( * a . r , 5 ) ;
} } ;

 expect ( t , rt_value ( * a , o . id ) == 73 && a . r . client . client_peer . applied > old && ( a . r . client . state_pending ) . count == 0 ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
