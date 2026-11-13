#scope_file
core :: #import "thirdparty/onet/core" ;
objects :: #import "thirdparty/onet/objects" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export


peer_packet :: ( t : * Test , reg : * objects . Registry , peer : * objects . Peer , tick : u64 , visible : objects . Visibility = null ) -> [ ] u8 {

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , objects . peer_build ( reg , peer , * w , tick , visible ) ) ;
return core . writer_to_array ( * w ) ;

 }

 peer_receive :: ( reg : * objects . Registry , peer : * objects . Peer , data : [ ] u8 ) -> ( u64 , bool , bool ) {

 r : core . Reader ;
core . reader_init ( * r , data ) ;
return objects . peer_apply ( reg , peer , * r ) ;

 }

 peer_setup :: ( server , client : * objects . Registry , outgoing , incoming : * objects . Peer , st : * Player_State ) -> * objects . Network_Object {

 objects . registry_init ( server ) ;
objects . registry_init ( client , false ) ;
objects . register_factory ( server , TEST_PLAYER_TYPE , player_factory ) ;
objects . register_factory ( client , TEST_PLAYER_TYPE , player_factory ) ;
objects . peer_init ( outgoing , 1 ) ;
objects . peer_init ( incoming , 1 ) ;
obj := objects . spawn ( server , 1 ) ;
array_add ( * obj . components , make_player_component ( st ) ) ;
return obj ;

 }



 peer_independent_late_join_and_stable_pointers :: ( t : * Test ) {

 server , client : objects . Registry ;
outgoing , incoming : objects . Peer ;
st := Player_State .{
health = 100 , speed = 7 , position = .[
13 , 27 , - 4 ,
] ,

 } ;

 obj := peer_setup ( * server , * client , * outgoing , * incoming , * st ) ;
defer objects . registry_destroy ( * server ) ;
defer objects . registry_destroy ( * client ) ;
defer objects . peer_destroy ( * outgoing ) ;
defer objects . peer_destroy ( * incoming ) ;
first := peer_packet ( t , * server , * outgoing , 1 ) ;
defer release ( first ) ;
seq , ok , _ := peer_receive ( * client , * incoming , first ) ;
expect ( t , ok && objects . peer_ack ( * outgoing , seq ) ) ;
mirror , _ := objects . get ( * client , obj . id ) ;
before := client_state_of ( t , mirror ) ;
st . position [ 1 ] = 29 ;
st . speed = 8 ;
second := peer_packet ( t , * server , * outgoing , 2 ) ;
defer release ( second ) ;
_ , second_ok , _ := peer_receive ( * client , * incoming , second ) ;
expect ( t , second_ok ) ;
mirror2 , _ := objects . get ( * client , obj . id ) ;
expect ( t , before == client_state_of ( t , mirror2 ) , "game state pointer remains stable" ) ;
expect_f32 ( t , before . position [ 1 ] , 29 , "nonzero delta base" ) ;
late : objects . Registry ;
late_peer , sender : objects . Peer ;
objects . registry_init ( * late , false ) ;
objects . register_factory ( * late , TEST_PLAYER_TYPE , player_factory ) ;
objects . peer_init ( * late_peer , 2 ) ;
objects . peer_init ( * sender , 2 ) ;
defer objects . registry_destroy ( * late ) ;
defer objects . peer_destroy ( * late_peer ) ;
defer objects . peer_destroy ( * sender ) ;
late_packet := peer_packet ( t , * server , * sender , 3 ) ;
defer release ( late_packet ) ;
_ , late_ok , _ := peer_receive ( * late , * late_peer , late_packet ) ;
expect ( t , late_ok ) ;
late_object , _ := objects . get ( * late , obj . id ) ;
expect_value ( t , client_state_of ( t , late_object ) . health , 100 ) ;
expect_f32 ( t , client_state_of ( t , late_object ) . speed , 8 , "late join current state" ) ;

 }



 peer_loss_reorder_duplicate_and_full_recovery :: ( t : * Test ) {

 server , client : objects . Registry ;
outgoing , incoming : objects . Peer ;
st := Player_State .{
health = 100 ,
} ;

 obj := peer_setup ( * server , * client , * outgoing , * incoming , * st ) ;
defer objects . registry_destroy ( * server ) ;
defer objects . registry_destroy ( * client ) ;
defer objects . peer_destroy ( * outgoing ) ;
defer objects . peer_destroy ( * incoming ) ;
one := peer_packet ( t , * server , * outgoing , 1 ) ;
defer release ( one ) ;
seq , ok , _ := peer_receive ( * client , * incoming , one ) ;
expect ( t , ok && objects . peer_ack ( * outgoing , seq ) ) ;
st . health = 80 ;
lost := peer_packet ( t , * server , * outgoing , 2 ) ;
defer release ( lost ) ;
st . health = 60 ;
three := peer_packet ( t , * server , * outgoing , 3 ) ;
defer release ( three ) ;
third_seq , third_ok , _ := peer_receive ( * client , * incoming , three ) ;
expect ( t , third_ok && objects . peer_ack ( * outgoing , third_seq ) ) ;
_ , old_ok , _ := peer_receive ( * client , * incoming , lost ) ;
expect ( t , old_ok , "old snapshot acknowledged but never reapplied" ) ;
mirror , _ := objects . get ( * client , obj . id ) ;
expect_value ( t , client_state_of ( t , mirror ) . health , 60 ) ;
expect ( t , ! objects . peer_ack ( * outgoing , 9999 ) , "future ack rejected" ) ;
objects . peer_destroy ( * incoming ) ;
objects . peer_init ( * incoming , 1 ) ;
st . health = 40 ;
four := peer_packet ( t , * server , * outgoing , 4 ) ;
defer release ( four ) ;
_ , four_ok , needs_full := peer_receive ( * client , * incoming , four ) ;
expect ( t , ! four_ok && needs_full ) ;
expect_value ( t , client_state_of ( t , mirror ) . health , 60 ) ;
objects . peer_request_full ( * outgoing ) ;
full := peer_packet ( t , * server , * outgoing , 5 ) ;
defer release ( full ) ;
_ , full_ok , _ := peer_receive ( * client , * incoming , full ) ;
expect ( t , full_ok ) ;
expect_value ( t , client_state_of ( t , mirror ) . health , 40 ) ;

 }



 peer_truncated_packets_do_not_mutate_world :: ( t : * Test ) {

 server , client : objects . Registry ;
outgoing , incoming : objects . Peer ;
st := Player_State .{
health = 100 ,
} ;

 peer_setup ( * server , * client , * outgoing , * incoming , * st ) ;
defer objects . registry_destroy ( * server ) ;
defer objects . registry_destroy ( * client ) ;
defer objects . peer_destroy ( * outgoing ) ;
defer objects . peer_destroy ( * incoming ) ;
packet := peer_packet ( t , * server , * outgoing , 1 ) ;
defer release ( packet ) ;
{ n := 0 ; while n < ( packet ) . count { defer n += 1 ;

 _ , ok , _ := peer_receive ( * client , * incoming , view ( packet , 0 , n ) ) ;
expect ( t , ! ok ) ;
expect_value ( t , objects . active_object_count ( * client ) , 0 ) ;
expect_value ( t , incoming . applied , 0 ) ;

 } }


}



 peer_visibility_exit_reentry_and_controller_change :: ( t : * Test ) {

 server , client : objects . Registry ;
outgoing , incoming : objects . Peer ;
st := Player_State .{
health = 100 ,
} ;

 obj := peer_setup ( * server , * client , * outgoing , * incoming , * st ) ;
defer objects . registry_destroy ( * server ) ;
defer objects . registry_destroy ( * client ) ;
defer objects . peer_destroy ( * outgoing ) ;
defer objects . peer_destroy ( * incoming ) ;
visible := ( obj : * objects . Network_Object , id : transport . Connection_Id , userdata : * void ) -> bool {

 return obj . owner == id ;

 }

 one := peer_packet ( t , * server , * outgoing , 1 , visible ) ;
defer release ( one ) ;
seq , ok , _ := peer_receive ( * client , * incoming , one ) ;
expect ( t , ok && objects . peer_ack ( * outgoing , seq ) ) ;
expect ( t , ! objects . set_controller ( * server , obj . id , 2 , 1 ) , "client cannot assign control" ) ;
expect ( t , objects . set_controller ( * server , obj . id , 2 ) ) ;
two := peer_packet ( t , * server , * outgoing , 2 , visible ) ;
defer release ( two ) ;
seq2 , ok2 , _ := peer_receive ( * client , * incoming , two ) ;
expect ( t , ok2 && objects . peer_ack ( * outgoing , seq2 ) ) ;
expect_value ( t , objects . active_object_count ( * client ) , 0 ) ;
objects . set_controller ( * server , obj . id , 1 ) ;
three := peer_packet ( t , * server , * outgoing , 3 , visible ) ;
defer release ( three ) ;
_ , ok3 , _ := peer_receive ( * client , * incoming , three ) ;
expect ( t , ok3 ) ;
expect_value ( t , objects . active_object_count ( * client ) , 1 ) ;

 }


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
