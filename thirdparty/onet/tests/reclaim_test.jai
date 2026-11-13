#scope_file
objects :: #import "thirdparty/onet/objects" ;
nr :: #import "thirdparty/onet/runtime" ;
session :: #import "thirdparty/onet/session" ;
#scope_export
// despawn 条目回收：服务器在全部 peer 确认后删除，客户端应用快照时删除。




reclaim_despawned_entries_after_all_peers_acknowledge :: ( t : * Test ) {

 s , a , b : RT_Node ;
rt_init ( * s , true ) ;
rt_init ( * a , false ) ;
rt_init ( * b , false ) ;
s . reg . reclaim_despawned = true ;
nodes := ( * RT_Node ) .[ * s , * a , * b ] ;
defer rt_shutdown ( nodes ) ;
keep := rt_spawn ( * s , 1 ) ;
expect ( t , session . start_server ( * s . s , 0 ) ) ;
port := session . bound_port ( * s . s ) ;
expect ( t , session . start_client ( * a . s , "127.0.0.1" , port ) ) ;
rt_pump ( nodes ) ;
if ! expect ( t , rt_value ( * a , keep . id ) == 1 , "client sees live object" ) {
return ;
}


// 客户端尚未确认不含该对象的快照前，服务器保留条目。

 early := rt_spawn ( * s , 5 ); early_id := early.id;
rt_pump ( nodes ) ;
expect ( t , objects . despawn ( * s . reg , early_id ) ) ;
nr . update ( * s . r , 10 ) ;
_ , held := table_get(*s . reg . objects , early_id ) ;
expect ( t , held && ( s . r . server . reclaims ) . count == 1 , "held until acknowledged" ) ;
rt_pump ( nodes ) ;
_ , held = table_get(*s . reg . objects , early_id ) ;
expect ( t , ! held , "reclaimed after acknowledgement" ) ;

 // 一万次 spawn/despawn：每批 100 个，下一批生成时销毁上一批。

 batch : [ .. ] objects . Network_Id ;
defer release ( batch ) ;
last_id : objects . Network_Id ;
{ loop_index := 0 ; while loop_index < 100 { defer loop_index += 1 ;

 for id : batch {
objects . despawn ( * s . reg , id ) ;
}

 array_reset_keeping_memory ( * batch ) ;
{ loop_index := 0 ; while loop_index < 100 { defer loop_index += 1 ;

 o := rt_spawn ( * s , 2 ) ;
array_add ( * batch , o . id ) ;
last_id = o . id ;

 } }

 rt_pump ( nodes , 3 ) ;

 } }

 for id : batch {
objects . despawn ( * s . reg , id ) ;
}

 rt_pump ( nodes , 100 ) ;
expect_value ( t , ( s . reg . objects ) . count , 1 ) ;
expect_value ( t , ( a . reg . objects ) . count , 1 ) ;
expect_value ( t , ( s . r . server . reclaims ) . count , 0 ) ;
_ , still := table_get(*s . reg . objects , last_id ) ;
expect ( t , ! still , "last despawned entry removed" ) ;

 // 迟加入与重连都只看到存活对象，被删的不会复活；ID 不复用。

 expect ( t , session . start_client ( * b . s , "127.0.0.1" , port ) ) ;
session . disconnect_local ( * a . s ) ;
rt_pump ( nodes ) ;
expect ( t , session . stop_client ( * a . s ) ) ;
expect ( t , session . start_client ( * a . s , "127.0.0.1" , port ) ) ;
rt_pump ( nodes , 100 ) ;
expect_value ( t , ( b . reg . objects ) . count , 1 ) ;
expect_value ( t , ( a . reg . objects ) . count , 1 ) ;
expect_value ( t , rt_value ( * b , keep . id ) , ( cast , trunc ( s32 ) ( 1 ) ) ) ;
expect_value ( t , rt_value ( * a , keep . id ) , ( cast , trunc ( s32 ) ( 1 ) ) ) ;
fresh := rt_spawn ( * s , 3 ) ;
expect ( t , fresh . id > last_id , "ids stay monotonic" ) ;

 }



 reclaim_is_opt_in :: ( t : * Test ) {

 reg : objects . Registry ;
objects . registry_init ( * reg ) ;
defer objects . registry_destroy ( * reg ) ;
o := objects . spawn ( * reg , 0 ) ;
expect ( t , objects . despawn ( * reg , o . id ) ) ;
expect_value ( t , ( reg . despawned ) . count , 0 ) ;
expect_value ( t , ( reg . objects ) . count , 1 ) ;
live := objects . spawn ( * reg , 0 ) ;
expect ( t , ! objects . reclaim ( * reg , live . id ) , "active objects are never reclaimed" ) ;
expect ( t , objects . reclaim ( * reg , o . id ) ) ;
expect_value ( t , ( reg . objects ) . count , 1 ) ;

 }


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
