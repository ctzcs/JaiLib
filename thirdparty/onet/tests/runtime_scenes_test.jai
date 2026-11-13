#scope_file
nr :: #import "thirdparty/onet/runtime" ;
scenes :: #import "thirdparty/onet/scenes" ;
session :: #import "thirdparty/onet/session" ;
transport :: #import "thirdparty/onet/transport" ;
wire :: #import "thirdparty/onet/wire" ;
#scope_export


//@region 场景迁移的真实状态ACK屏障

 RT_Held_Acks :: struct {
node : * RT_Node ;
hold : bool ;
frames : [ .. ] [ ] u8 ;
}

 rt_hold_ack :: ( userdata : * void , side : transport . Invoker , to : transport . Connection_Id , channel : transport . Channel , frame : [ ] u8 ) -> bool {

 h := ( cast ( * RT_Held_Acks ) userdata ) ;
if h . hold && side == . Client && ( frame ) . count > 0 && frame [ 0 ] == ( cast , trunc ( u8 ) ( nr . Kind . Ack ) ) {

 array_add ( * h . frames , wire . clone ( frame ) ) ;
return true ; // 拥有副本，直到测试释放；不是丢弃可靠帧。


}

 return session . send_extension ( * h . node . s , to , nr . EXTENSION_ID , frame , channel ) ;

 }


rt_scene_carry_waits_for_replication_ack_before_unload :: ( t : * Test ) {

 s , a : RT_Node ;
rt_init ( * s , true ) ;
rt_init ( * a , false ) ;
nodes := ( * RT_Node ) .[ * s , * a ] ;
defer rt_shutdown ( nodes ) ;
hold := RT_Held_Acks .{
node = * a ,
} ;

 defer {

 hold . hold = false ;
for frame : hold . frames {
release ( frame ) ;
}

 release ( hold . frames ) ;

 }

 a . r . config . send , a . r . config . userdata = rt_hold_ack , * hold ;
expect ( t , session . start_server ( * s . s , 0 ) ) ;
old_scene , ok := scenes . open ( * s . r . server . scenes , 41 , .{
kind = . Global
} ) ;
expect ( t , ok ) ;
o := rt_spawn ( * s , 31 ) ;
o . scene = ( cast , trunc ( u32 ) ( old_scene ) ) ;
expect ( t , session . start_client ( * a . s , "127.0.0.1" , session . bound_port ( * s . s ) ) ) ;
rt_pump ( nodes , 20 ) ;
expect ( t , scenes . complete_load ( * a . r . client . scenes , a . ticket , true ) ) ;
rt_pump ( nodes , 20 ) ;
expect_value ( t , rt_value ( * a , o . id ) , ( cast , trunc ( s32 ) ( 31 ) ) ) ;
new_scene , opened := scenes . open ( * s . r . server . scenes , 42 , .{
kind = . Global
} ) ;
expect ( t , opened ) ;
rt_pump ( nodes , 20 ) ;
expect ( t , a . ticket . handle == new_scene ) ;
expect ( t , scenes . complete_load ( * a . r . client . scenes , a . ticket , true ) ) ;
rt_pump ( nodes , 20 ) ;
hold . hold = true ;
expect ( t , scenes . begin_replace ( * s . r . server . scenes , old_scene , new_scene , true ) ) ;
rt_pump ( nodes , 20 ) ;
info , exists := scenes . get_info ( * s . r . server . scenes , old_scene ) ;
expect ( t , exists && info . phase == . Open , "carry cannot unload before migrated state ACK" ) ;
expect ( t , o . scene == ( cast , trunc ( u32 ) ( new_scene ) ) && ( hold . frames ) . count > 0 ) ;
// 只放行迁移完成时的ACK；目标场景随后持续churn，其ACK仍暂存。

 if ( hold . frames ) . count == 0 {
return ;
}

 frame := hold . frames [ ( hold . frames ) . count - 1 ] ;
expect ( t , session . send_extension ( * a . s , session . local_connection ( * a . s ) , nr . EXTENSION_ID , frame ) ) ;
{ i := 0 ; while i < 15 { defer i += 1 ;

 extra := rt_spawn ( * s , ( cast , trunc ( s32 ) ( i ) ) ) ;
extra . scene = ( cast , trunc ( u32 ) ( new_scene ) ) ;
rt_pump ( nodes , 2 ) ;

 } } ;

 hold . hold = false ;
_ , exists = scenes . get_info ( * s . r . server . scenes , old_scene ) ;
expect ( t , ! exists , "old scene released after migration ACK and unload report" ) ;
expect ( t , scenes . is_loaded ( * s . r . server . scenes , new_scene , a . s . client_server_id ) ) ;

 } ;

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
