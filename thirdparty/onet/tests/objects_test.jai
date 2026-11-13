#scope_file
core :: #import "thirdparty/onet/core" ;
objects :: #import "thirdparty/onet/objects" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export
// Network objects tests: sync members, replication packets.





 // Test component state: a small player-like struct.

 Player_State :: struct {

 position : [ 3 ] float32 ;

 health : s32 ;

 alive : bool ;

 aim : [ 4 ] float32 ;
// quaternion

 speed : float32 ;


}


TEST_PLAYER_TYPE :: ( cast ( objects . Component_Type_Id ) ( 1 ) ) ;
// Builds a server-side component around the given state (member order is

 // the contract between both sides).

 make_player_component :: ( st : * Player_State ) -> * objects . Component {

 comp := objects . component_make ( TEST_PLAYER_TYPE ) ;
objects . member_vec3 ( comp , * st . position ) ;
objects . member_i32 ( comp , * st . health ) ;
objects . member_bool ( comp , * st . alive ) ;
objects . member_quat ( comp , * st . aim ) ;
objects . member_f32 ( comp , * st . speed ) ;
return comp ;

 }


// Client-side factory: allocates its own state and registers the same

 // members in the same order.

 player_factory :: ( ) -> * objects . Component {

 st := new_one ( Player_State ) ;
comp := make_player_component ( st ) ;
comp . userdata = st ;
comp . destroy_userdata = ( p : * void ) {

 free ( ( cast ( * Player_State ) p ) ) ;

 }

 return comp ;

 }



 objects_full_replication_roundtrip :: ( t : * Test ) {

 server : objects . Registry ;
objects . registry_init ( * server ) ;
defer objects . registry_destroy ( * server ) ;
objects . register_factory ( * server , TEST_PLAYER_TYPE , player_factory ) ;

 client : objects . Registry ;
objects . registry_init ( * client ) ;
defer objects . registry_destroy ( * client ) ;
objects . register_factory ( * client , TEST_PLAYER_TYPE , player_factory ) ;

 st : Player_State ;
st . position = .[
10 , 20 , 30 ,
] ;

 st . health = 87 ;
st . alive = true ;
st . aim = .[
0 , (cast(float32)0.7071067690849304) , 0 , (cast(float32)0.7071067690849304) ,
] ;

 st . speed = 5.5 ;

 obj := objects . spawn ( * server , transport . UNSET_CONNECTION_ID ) ;
comp := make_player_component ( * st ) ;
array_add ( * obj . components , comp ) ;
obj . position = st . position ;

 objects . poll_dirty ( obj ) ;
expect ( t , objects . is_dirty ( obj ) , "fresh object is dirty" ) ;

 // Build -> apply.

 w : core . Writer ;
core . writer_init ( * w , 128 ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , objects . build_state_packet ( * server , * w ) , "packet has content" ) ;

 data := core . writer_to_array ( * w ) ;
defer release ( data ) ;

 r : core . Reader ;
core . reader_init ( * r , data ) ;
touched , ok := objects . apply_state_packet ( * client , * r ) ;
expect ( t , ok , "apply clean" ) ;
expect_value ( t , touched , 1 ) ;

 mirror , found := objects . get ( * client , obj . id ) ;
expect ( t , found , "client mirrored the object" ) ;
mirror_state := client_state_of ( t , mirror ) ;

 expect_value ( t , mirror_state . health , 87 ) ;
expect_value ( t , mirror_state . alive , true ) ;
expect_f32 ( t , mirror_state . position [ 0 ] , 10 , "pos x" ) ;
expect_f32 ( t , mirror_state . position [ 1 ] , 20 , "pos y" ) ;
expect_f32 ( t , mirror_state . position [ 2 ] , 30 , "pos z" ) ;
expect_f32 ( t , mirror_state . speed , 5.5 , "speed" ) ;
expect_f32 ( t , mirror_state . aim [ 1 ] , (cast(float32)0.7071067690849304) , "aim y" ) ;

 // Second build with no changes: nothing on the wire.

 w2 : core . Writer ;
core . writer_init ( * w2 , 128 ) ;
defer core . writer_destroy ( * w2 ) ;
expect ( t , ! objects . build_state_packet ( * server , * w2 ) , "no changes, no packet" ) ;

 }



 objects_delta_replication :: ( t : * Test ) {

 server : objects . Registry ;
objects . registry_init ( * server ) ;
defer objects . registry_destroy ( * server ) ;
objects . register_factory ( * server , TEST_PLAYER_TYPE , player_factory ) ;

 client : objects . Registry ;
objects . registry_init ( * client ) ;
defer objects . registry_destroy ( * client ) ;
objects . register_factory ( * client , TEST_PLAYER_TYPE , player_factory ) ;

 st : Player_State ;
st . position = .[
0 , 0 , 0 ,
] ;

 st . health = 100 ;
st . speed = 1 ;

 obj := objects . spawn ( * server , transport . UNSET_CONNECTION_ID ) ;
array_add ( * obj . components , make_player_component ( * st ) ) ;

 // First packet establishes the mirror.

 apply_to_client ( t , * server , * client ) ;

 // Move on one axis only.

 st . position [ 0 ] = 4.25 ;
objects . poll_dirty ( obj ) ;

 w : core . Writer ;
core . writer_init ( * w , 64 ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , objects . build_state_packet ( * server , * w ) , "delta packet has content" ) ;
data := core . writer_to_array ( * w ) ;
defer release ( data ) ;

 // The delta packet must be tiny: object header + two unchanged vec3 axes

 // (1 bit each) + one changed axis.

 expect ( t , ( data ) . count <= 12 , "delta packet is small" ) ;

 // Apply the exact packet built above (a fresh build would be empty:

 // the manual build already advanced the delta bases).

 r2 : core . Reader ;
core . reader_init ( * r2 , data ) ;
_ , ok := objects . apply_state_packet ( * client , * r2 ) ;
expect ( t , ok , "delta apply clean" ) ;
mirror , _ := objects . get ( * client , obj . id ) ;
mirror_state := client_state_of ( t , mirror ) ;
expect_f32 ( t , mirror_state . position [ 0 ] , 4.25 , "delta applied x" ) ;
expect_f32 ( t , mirror_state . position [ 1 ] , 0 , "y unchanged" ) ;
expect_value ( t , mirror_state . health , 100 ) ;

 }



 objects_despawn_replicates :: ( t : * Test ) {

 server : objects . Registry ;
objects . registry_init ( * server ) ;
defer objects . registry_destroy ( * server ) ;
objects . register_factory ( * server , TEST_PLAYER_TYPE , player_factory ) ;

 client : objects . Registry ;
objects . registry_init ( * client ) ;
defer objects . registry_destroy ( * client ) ;
objects . register_factory ( * client , TEST_PLAYER_TYPE , player_factory ) ;

 st : Player_State ;
obj := objects . spawn ( * server , transport . UNSET_CONNECTION_ID ) ;
array_add ( * obj . components , make_player_component ( * st ) ) ;

 apply_to_client ( t , * server , * client ) ;
expect_value ( t , objects . active_object_count ( * client ) , 1 ) ;

 expect ( t , objects . despawn ( * server , obj . id ) , "despawn queued" ) ;

 // A despawn alone must flush in a packet.

 w : core . Writer ;
core . writer_init ( * w , 64 ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , objects . build_state_packet ( * server , * w ) , "despawn packet written" ) ;

 // Apply the exact packet built above (it holds the despawn queue).

 despawn_data := core . writer_to_array ( * w ) ;
defer release ( despawn_data ) ;
dr : core . Reader ;
core . reader_init ( * dr , despawn_data ) ;
_ , d_ok := objects . apply_state_packet ( * client , * dr ) ;
expect ( t , d_ok , "despawn apply clean" ) ;
expect_value ( t , objects . active_object_count ( * client ) , 0 ) ;
_ , found := objects . get ( * client , obj . id ) ;
expect ( t , ! found , "mirror gone" ) ;

 }


apply_to_client :: ( t : * Test , server : * objects . Registry , client : * objects . Registry ) {

 w : core . Writer ;
core . writer_init ( * w , 256 ) ;
objects . build_state_packet ( server , * w ) ;
data := core . writer_to_array ( * w ) ;
core . writer_destroy ( * w ) ;

 r : core . Reader ;
core . reader_init ( * r , data ) ;
_ , ok := objects . apply_state_packet ( client , * r ) ;
expect ( t , ok , "apply clean" ) ;
release ( data ) ;

 }


client_state_of :: ( t : * Test , obj : * objects . Network_Object ) -> * Player_State {

 expect ( t , ( obj . components ) . count == 1 , "one component" ) ;
comp := obj . components [ 0 ] ;
expect_value ( t , comp . type_id , TEST_PLAYER_TYPE ) ;
// The first member points at Player_State.position; the state base is

 // derived from it (layout order is part of the factory contract).

 pos_member := * comp . members [ 0 ] ;
return state_base_of ( pos_member . ptr ) ;

 }


state_base_of :: ( position_ptr : * void ) -> * Player_State {

 // offsetof(Player_State, position) == 0 by declaration order.

 return ( cast ( * Player_State ) position_ptr ) ;

 }


expect_f32 :: ( t : * Test , got , want : float32 , label : string ) {

 epsilon := ( cast ( float32 ) ( 0.01 ) ) ;
if got - want > epsilon || want - got > epsilon {

 expect ( t , false , label ) ;
return ;

 }

 expect ( t , true , label ) ;

 }


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
