#scope_file
nr :: #import "thirdparty/onet/runtime" ;
session :: #import "thirdparty/onet/session" ;
objects :: #import "thirdparty/onet/objects" ;
scenes :: #import "thirdparty/onet/scenes" ;
transport :: #import "thirdparty/onet/transport" ;
enet :: #import "thirdparty/onet/transport/enet" ;
#scope_export


//@region Concrete asynchronous resource loader fixture

 Policy_Loader :: struct {

 loader : scenes . Loader ;

 pending : [ .. ] scenes . Loader_Ticket ;

 started : [ .. ] scenes . Loader_Ticket ;

 resources : H.Table(scenes.Resource_Key,[]u8,test_resource_hash,test_resource_equal) ;

 active , peak , cancels : int ;


}

 policy_loader_request :: ( user : * void , ticket : scenes . Loader_Ticket ) {

 l := ( cast ( * Policy_Loader ) user ) ;
array_add ( * l . pending , ticket ) ;
array_add ( * l . started , ticket ) ;
l . active += 1 ;
l . peak = max ( l . peak , l . active ) ;

 }

 policy_loader_cancel :: ( user : * void , ticket : scenes . Loader_Ticket ) {
( ( cast ( * Policy_Loader ) user ) ) . cancels += 1 ;
}

 policy_loader_init :: ( l : * Policy_Loader , max_operations : int = 1 , max_resident : int = 0 ) {

 l . resources = new_table(scenes.Resource_Key,[]u8,hash_function=test_resource_hash,compare_function=test_resource_equal) ;
assert ( scenes . loader_init ( * l . loader , .{
userdata = l , request = policy_loader_request , cancel = policy_loader_cancel , max_operations = max_operations , max_resident = max_resident
} ) ) ;

 } ;

 policy_loader_finish :: ( l : * Policy_Loader , success : bool = true ) -> scenes . Loader_Ticket {

 assert ( ( l . pending ) . count > 0 ) ;
ticket := l . pending [ 0 ] ;
array_ordered_remove_by_index ( * l . pending , 0 ) ;
l . active -= 1 ;
if success {

 if ticket . operation == . Load {
assert ( table_get ( * l . resources , ticket . key ).data == null ) ;
data := new_slice ( u8 , 16 ) ;
data [ 0 ] = ( cast , trunc ( u8 ) ( ticket . asset ) ) ;
H . table_set ( * l . resources , ticket . key , data ) ;

 } else {
release ( table_get ( * l . resources , ticket . key ) ) ;
H . table_remove ( * l . resources , ticket . key ) ;
}


}

 assert ( scenes . loader_complete ( * l . loader , ticket , success ) ) ;
return ticket ;

 }

 policy_loader_destroy :: ( t : * Test , l : * Policy_Loader ) {

 scenes . loader_shutdown ( * l . loader ) ;
scenes . loader_update ( * l . loader ) ;
expect ( t , scenes . loader_destroy ( * l . loader ) ) ;
expect_value ( t , ( l . resources ) . count , 0 ) ;
expect_value ( t , l . active , 0 ) ;
for data , _ : l . resources {
release ( data ) ;
} ;
release ( l . resources ) ;
release ( l . pending ) ;
release ( l . started ) ;

 }

 policy_pump :: ( m : * scenes . Manager , now : * u64 , steps : int = 4 ) {

 { loop_index := 0 ; while loop_index < steps { defer loop_index += 1 ;
now .* += 1 ;
scenes . update ( m , now .* ) ;
} }


}

 policy_drain :: ( t : * Test , m : * scenes . Manager , l : * Policy_Loader , now : * u64 ) {

 scenes . shutdown ( m ) ;
{ loop_index := 0 ; while loop_index < 100 { defer loop_index += 1 ;

 policy_pump ( m , now , 1 ) ;
if ( l . pending ) . count > 0 {
policy_loader_finish ( l ) ;
}

 if ( m . scenes ) . count == 0 {
break ;
}


} }

 expect ( t , scenes . destroy ( m ) ) ;

 }

 policy_send :: ( user : * void , to : transport . Connection_Id , payload : [ ] u8 ) -> bool {
return true ;
}


scene_global_loader_concurrency_and_capacity_release_order :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l , 1 , 1 ) ;
m : scenes . Manager ;
scenes . init ( * m , .{
role = . Server , loader = * l . loader
} ) ;
now := ( cast , trunc ( u64 ) ( 0 ) ) ;
a , _ := scenes . open ( * m , 1 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , ( l . pending ) . count , 1 ) ;
policy_loader_finish ( * l ) ;
policy_pump ( * m , * now ) ;
b , _ := scenes . open ( * m , 2 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
expect ( t , ( l . started ) . count == 1 , "resident budget queues the second physical load" ) ;
expect ( t , table_get ( * m . scenes , b ) . local . busy ) ;
expect ( t , scenes . close ( * m , a ) ) ;
policy_pump ( * m , * now ) ;
if expect ( t , ( l . pending ) . count == 1 ) {
expect ( t , l . pending [ 0 ] . operation == . Unload ) ;
policy_loader_finish ( * l ) ;
}

 policy_pump ( * m , * now ) ;
if expect ( t , ( l . pending ) . count == 1 ) {
expect ( t , l . pending [ 0 ] . operation == . Load && l . pending [ 0 ] . asset == 2 ) ;
policy_loader_finish ( * l ) ;
}

 policy_pump ( * m , * now ) ;
expect ( t , scenes . is_local_loaded ( * m , b ) ) ;
expect_value ( t , l . peak , 1 ) ;
policy_drain ( t , * m , * l , * now ) ;
policy_loader_destroy ( t , * l ) ;

 } ;


scene_global_loader_limit_is_shared_across_managers :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l , 2 ) ;
a , b : scenes . Manager ;
scenes . init ( * a , .{
role = . Server , loader = * l . loader
} ) ;
scenes . init ( * b , .{
role = . Server , loader = * l . loader
} ) ;
now := ( cast , trunc ( u64 ) ( 0 ) ) ;
{ loop_index := 0 ; while loop_index < 2 { defer loop_index += 1 ;
scenes . open ( * a , 1 , .{
kind = . Global
} , true ) ;
scenes . open ( * b , 2 , .{
kind = . Global
} , true ) ;
} } ;

 policy_pump ( * a , * now ) ;
policy_pump ( * b , * now ) ;
expect_value ( t , ( l . pending ) . count , 2 ) ;
expect_value ( t , l . peak , 2 ) ;
{ loop_index := 0 ; while loop_index < 8 { defer loop_index += 1 ;
if ( l . pending ) . count > 0 {
policy_loader_finish ( * l ) ;
} ;
policy_pump ( * a , * now ) ;
policy_pump ( * b , * now ) ;
} }

 expect_value ( t , ( l . resources ) . count , 4 ) ;
expect_value ( t , l . peak , 2 ) ;
policy_drain ( t , * a , * l , * now ) ;
policy_drain ( t , * b , * l , * now ) ;
policy_loader_destroy ( t , * l ) ;

 } ;


scene_cancel_queued_and_running_load_cleans_late_success :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l , 1 ) ;
m : scenes . Manager ;
scenes . init ( * m , .{
role = . Server , loader = * l . loader
} ) ;
now := ( cast , trunc ( u64 ) ( 0 ) ) ;
a , _ := scenes . open ( * m , 1 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
b , _ := scenes . open ( * m , 2 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , ( l . started ) . count , 1 ) ;
scenes . close ( * m , b ) ;
policy_pump ( * m , * now ) ;
_ , exists := scenes . get_info ( * m , b ) ;
expect ( t , ! exists , "cancelled queued load never dispatches" ) ;
scenes . close ( * m , a ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , l . cancels , 1 ) ;
policy_loader_finish ( * l , true ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , ( l . pending ) . count , 1 ) ;
if expect ( t , ( l . pending ) . count > 0 ) {
expect ( t , l . pending [ 0 ] . operation == . Unload ) ;
}

 expect ( t , ! scenes . destroy ( * m ) , "late-success cleanup is still owned" ) ;
policy_loader_finish ( * l , true ) ;
policy_pump ( * m , * now ) ;
policy_drain ( t , * m , * l , * now ) ;
policy_loader_destroy ( t , * l ) ;

 } ;


scene_shutdown_cleanup_failure_is_retryable_not_forgotten :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l , 1 ) ;
m : scenes . Manager ;
scenes . init ( * m , .{
role = . Server , loader = * l . loader
} ) ;
now := ( cast , trunc ( u64 ) ( 0 ) ) ;
h , _ := scenes . open ( * m , 5 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
scenes . shutdown ( * m ) ;
scenes . loader_shutdown ( * l . loader ) ;
policy_pump ( * m , * now ) ;
policy_loader_finish ( * l , true ) ;
policy_pump ( * m , * now ) ;
cleanup := policy_loader_finish ( * l , false ) ;
policy_pump ( * m , * now ) ;
expect ( t , ! scenes . loader_destroy ( * l . loader ) && ! scenes . destroy ( * m ) ) ;
expect_value ( t , ( l . resources ) . count , 1 ) ;
expect_value ( t , l . loader . active , 0 ) ;
// Duplicate failed completion is ignored, not a second decrement.

 scenes . loader_complete ( * l . loader , cleanup , false ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , l . loader . active , 0 ) ;
expect ( t , scenes . loader_retry_cleanup ( * l . loader , scenes . loader_key ( * m , h ) ) ) ;
policy_loader_finish ( * l , true ) ;
policy_pump ( * m , * now ) ;
expect ( t , scenes . destroy ( * m ) ) ;
policy_loader_destroy ( t , * l ) ;

 } ;


scene_host_shared_physical_reference_count_waits_for_remote_ack :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l ) ;
s , c : scenes . Manager ;
scenes . init ( * s , .{
role = . Server , loader = * l . loader , loader_namespace = 77 , send = policy_send
} ) ;
scenes . init ( * c , .{
role = . Client , loader = * l . loader , loader_namespace = 77 , send = policy_send
} ) ;
expect ( t , scenes . peer_join ( * s , 1 , 99 ) ) ;
expect ( t , scenes . bind_authority ( * c , 900 , 99 ) ) ;
now := ( cast , trunc ( u64 ) ( 0 ) ) ;
h , _ := scenes . open ( * s , 3 , .{
kind = . Global
} , true ) ;
policy_pump ( * s , * now ) ;
policy_loader_finish ( * l ) ;
policy_pump ( * s , * now ) ;
r := table_get ( * table_get ( * s . scenes , h ) . remotes , 1 ) ;
packet , _ := scenes . encode_packet ( .{ . Load , h , 3 , 99 , r . revision
} ) ;
expect ( t , scenes . handle ( * c , 900 , view ( packet , 0 ) ) ) ;
policy_pump ( * c , * now ) ;
policy_pump ( * s , * now ) ;
expect ( t , ( l . started ) . count == 1 , "host client acquires existing physical scene" ) ;
expect_value ( t , scenes . loader_reference_count ( * l . loader , .{
77 , h
} ) , 2 ) ;
loaded , _ := scenes . encode_packet ( .{ . Loaded , h , 3 , 99 , r . revision
} ) ;
expect ( t , scenes . handle ( * s , 1 , view ( loaded , 0 ) ) ) ;
scenes . close ( * s , h ) ;
policy_pump ( * s , * now ) ;
expect ( t , ( l . started ) . count == 1 , "no physical unload before client report" ) ;
r = table_get ( * table_get ( * s . scenes , h ) . remotes , 1 ) ;
unload , _ := scenes . encode_packet ( .{ . Unload , h , 3 , 99 , r . revision
} ) ;
expect ( t , scenes . handle ( * c , 900 , view ( unload , 0 ) ) ) ;
policy_pump ( * c , * now ) ;
expect_value ( t , scenes . loader_reference_count ( * l . loader , .{
77 , h
} ) , 1 ) ;
policy_pump ( * s , * now ) ;
expect ( t , ( l . started ) . count == 1 , "authority retains its reference until unload ACK" ) ;
unloaded , _ := scenes . encode_packet ( .{ . Unloaded , h , 3 , 99 , r . revision
} ) ;
expect ( t , scenes . handle ( * s , 1 , view ( unloaded , 0 ) ) ) ;
policy_pump ( * s , * now ) ;
if expect ( t , ( l . pending ) . count == 1 ) {
expect ( t , l . pending [ 0 ] . operation == . Unload ) ;
policy_loader_finish ( * l ) ;
}

 policy_pump ( * s , * now ) ;
scenes . peer_leave ( * s , 1 ) ;
policy_drain ( t , * s , * l , * now ) ;
policy_drain ( t , * c , * l , * now ) ;
policy_loader_destroy ( t , * l ) ;

 } ;

 //@endregion


//@region Actual registry carry/group policy execution and rollback


scene_typed_carry_selection_group_expansion_and_compensation :: ( t : * Test ) {

 reg : objects . Registry ;
objects . registry_init ( * reg ) ;
defer objects . registry_destroy ( * reg ) ;
a := objects . spawn ( * reg , 1 ) ;
a . scene = 10 ;
b := objects . spawn ( * reg , 2 ) ;
b . scene = 10 ;
stationary := objects . spawn ( * reg , 0 ) ;
stationary . scene = 10 ;
policy : scenes . Carry_Policy ;
expect ( t , scenes . carry_init ( * policy , * reg , .{
selection = . Registered
} ) ) ;
defer scenes . carry_destroy ( * policy ) ;
expect ( t , scenes . carry_register ( * policy , a . id , .{
eligible = true , group = 44
} ) ) ;
expect ( t , scenes . carry_register ( * policy , b . id , .{
eligible = false , group = 44
} ) ) ;
expect ( t , scenes . carry_begin ( * policy , 10 , 20 ) ) ;
expect_value ( t , a . scene , ( cast , trunc ( u32 ) ( 20 ) ) ) ;
expect_value ( t , b . scene , ( cast , trunc ( u32 ) ( 20 ) ) ) ;
expect_value ( t , stationary . scene , ( cast , trunc ( u32 ) ( 10 ) ) ) ;
scenes . carry_finish ( * policy , 10 , false ) ;
expect_value ( t , a . scene , ( cast , trunc ( u32 ) ( 10 ) ) ) ;
expect_value ( t , b . scene , ( cast , trunc ( u32 ) ( 10 ) ) ) ;
expect ( t , scenes . carry_begin ( * policy , 10 , 20 ) ) ;
scenes . carry_finish ( * policy , 10 , true ) ;
expect_value ( t , a . scene , ( cast , trunc ( u32 ) ( 20 ) ) ) ;
expect_value ( t , ( policy . transactions ) . count , 0 ) ;

 } ;


scene_carry_failure_retain_despawn_release_controller_and_group_scope :: ( t : * Test ) {

 actions: []scenes.Carry_Failure_Action = scenes.Carry_Failure_Action.[ . Retain , . Despawn , . Release_Controller ] ;
for action : actions {

 reg : objects . Registry ;
objects . registry_init ( * reg ) ;
a := objects . spawn ( * reg , 1 ) ;
b := objects . spawn ( * reg , 2 ) ;
a . scene , b . scene = 20 , 20 ;
policy : scenes . Carry_Policy ;
expect ( t , scenes . carry_init ( * policy , * reg , .{
failure = action
} ) ) ;
scenes . carry_register ( * policy , a . id , .{
eligible = true , group = 5
} ) ;
scenes . carry_register ( * policy , b . id , .{
eligible = true , group = 5
} ) ;
scenes . carry_apply_failure ( * policy , 1 , 20 ) ;
if action == {

 case . Retain ; expect ( t , a . active && b . active && a . owner == 1 && b . owner == 2 ) ;
case . Despawn ; expect ( t , ! a . active && ! b . active ) ;
case . Release_Controller ; expect ( t , a . active && b . active && a . owner == 0 && b . owner == 2 ) ;

 }

 scenes . carry_destroy ( * policy ) ;
objects . registry_destroy ( * reg ) ;

 } ;


} ;

 Policy_Gate :: struct {
ready : bool ;
failed , committed : int ;
}

 policy_gate :: ( user : * void , old , target : scenes . Handle , c : transport . Connection_Id ) -> bool {
return ( ( cast ( * Policy_Gate ) user ) ) . ready ;
}

 policy_event :: ( user : * void , event : scenes . Event ) {

 g := ( cast ( * Policy_Gate ) user ) ;
if event . kind == . Replace_Failed {
g . failed += 1 ;
} ;
if event . kind == . Replace_Committed {
g . committed += 1 ;
}


}


scene_carried_objects_rollback_after_ack_gate_timeout_and_destination_abort :: ( t : * Test ) {

 { mode := 0 ; while mode < 2 { defer mode += 1 ;

 l : Policy_Loader ;
policy_loader_init ( * l , 2 ) ;
reg : objects . Registry ;
objects . registry_init ( * reg ) ;
gate : Policy_Gate ;
binding : scenes . Carry_Binding ;
expect ( t , scenes . carry_binding_init ( * binding , * reg , .{
role = . Server , loader = * l . loader , userdata = * gate , event = policy_event , ready_to_unload = policy_gate , replace_timeout_ms = 30
} , .{
selection = . All
} ) ) ;
m : scenes . Manager ;
scenes . init ( * m , scenes . carry_binding_config ( * binding ) ) ;
now := ( cast , trunc ( u64 ) ( 0 ) ) ;
old , _ := scenes . open ( * m , 1 , .{
kind = . Global
} , true ) ;
target , _ := scenes . open ( * m , 2 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
while ( l . pending ) . count > 0 {
policy_loader_finish ( * l ) ;
} ;
policy_pump ( * m , * now ) ;
obj := objects . spawn ( * reg , 1 ) ;
obj . scene = ( cast , trunc ( u32 ) ( old ) ) ;
expect ( t , scenes . begin_replace ( * m , old , target , true ) ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , obj . scene , ( cast , trunc ( u32 ) ( target ) ) ) ;
expect_value ( t , ( binding . policy . transactions ) . count , 1 ) ;
expect ( t , ( l . resources ) . count == 2 , "ACK gate keeps both physical resources alive" ) ;
if mode == 0 {
policy_pump ( * m , * now , 40 ) ;
} else {
scenes . close ( * m , target ) ;
}

 expect_value ( t , obj . scene , ( cast , trunc ( u32 ) ( old ) ) ) ;
expect_value ( t , gate . failed , 1 ) ;
expect ( t , scenes . is_local_loaded ( * m , old ) , "source retained after failed replace" ) ;
policy_drain ( t , * m , * l , * now ) ;
scenes . carry_binding_destroy ( * binding ) ;
objects . registry_destroy ( * reg ) ;
policy_loader_destroy ( t , * l ) ;

 } }


}


scene_carry_commit_waits_for_gate_and_despawns_unselected_source_objects :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l , 2 ) ;
reg : objects . Registry ;
objects . registry_init ( * reg ) ;
gate : Policy_Gate ;
binding : scenes . Carry_Binding ;
expect ( t , scenes . carry_binding_init ( * binding , * reg , .{
role = . Server , loader = * l . loader , userdata = * gate , event = policy_event , ready_to_unload = policy_gate
} , .{
selection = . Controlled
} ) ) ;
m : scenes . Manager ;
scenes . init ( * m , scenes . carry_binding_config ( * binding ) ) ;
now := ( cast , trunc ( u64 ) ( 0 ) ) ;
old , _ := scenes . open ( * m , 1 , .{
kind = . Global
} , true ) ;
target , _ := scenes . open ( * m , 2 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
while ( l . pending ) . count > 0 {
policy_loader_finish ( * l ) ;
} ;
policy_pump ( * m , * now ) ;
carried := objects . spawn ( * reg , 1 ) ;
carried . scene = ( cast , trunc ( u32 ) ( old ) ) ;
left := objects . spawn ( * reg , 0 ) ;
left . scene = ( cast , trunc ( u32 ) ( old ) ) ;
expect ( t , scenes . begin_replace ( * m , old , target , true ) ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , ( l . resources ) . count , 2 ) ;
expect ( t , left . active && carried . active ) ;
gate . ready = true ;
policy_pump ( * m , * now ) ;
expect_value ( t , gate . committed , 1 ) ;
expect ( t , ! left . active && carried . active && carried . scene == ( cast , trunc ( u32 ) ( target ) ) ) ;
if expect ( t , ( l . pending ) . count == 1 ) {
policy_loader_finish ( * l ) ;
} ;
policy_pump ( * m , * now ) ;
policy_drain ( t , * m , * l , * now ) ;
scenes . carry_binding_destroy ( * binding ) ;
objects . registry_destroy ( * reg ) ;
policy_loader_destroy ( t , * l ) ;

 }


scene_carry_overrides_resolver_and_cross_scene_group_atomicity :: ( t : * Test ) {

 reg : objects . Registry ;
objects . registry_init ( * reg ) ;
defer objects . registry_destroy ( * reg ) ;
a := objects . spawn ( * reg , 1 ) ;
b := objects . spawn ( * reg , 2 ) ;
a . scene , b . scene = 10 , 11 ;
calls := 0 ;
policy : scenes . Carry_Policy ;
expect ( t , scenes . carry_init ( * policy , * reg , .{
selection = . Registered , failure = . Despawn , userdata = * calls ,
resolve_failure = ( user : * void , c : transport . Connection_Id , obj : * objects . Network_Object , h : scenes . Handle , action : scenes . Carry_Failure_Action ) -> scenes . Carry_Failure_Action {

 ( ( cast ( * int ) user ) ) .* += 1 ;
assert ( action == . Retain ) ;
return . Release_Controller

 ; }

 } ) ) ;
defer scenes . carry_destroy ( * policy ) ;
scenes . carry_register ( * policy , a . id , .{
eligible = true , group = 8 , has_failure_override = true , failure = . Retain
} ) ;
scenes . carry_register ( * policy , b . id , .{
eligible = false , group = 8
} ) ;
expect ( t , ! scenes . carry_begin ( * policy , 10 , 20 ) , "cross-scene group rejected before mutation" ) ;
expect_value ( t , a . scene , ( cast , trunc ( u32 ) ( 10 ) ) ) ;
expect_value ( t , b . scene , ( cast , trunc ( u32 ) ( 11 ) ) ) ;
scenes . carry_apply_failure ( * policy , 1 , 10 ) ;
expect_value ( t , calls , 1 ) ;
expect ( t , a . active && b . active && a . owner == 0 && b . owner == 2 ) ;

 } ;


scene_loader_failed_load_releases_capacity_and_never_creates_reference :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l , 1 , 1 ) ;
m : scenes . Manager ;
scenes . init ( * m , .{
role = . Server , loader = * l . loader
} ) ;
now := ( cast , trunc ( u64 ) ( 0 ) ) ;
a , _ := scenes . open ( * m , 1 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
b , _ := scenes . open ( * m , 2 , .{
kind = . Global
} , true ) ;
policy_pump ( * m , * now ) ;
failed := policy_loader_finish ( * l , false ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , scenes . loader_reference_count ( * l . loader , scenes . loader_key ( * m , a ) ) , 0 ) ;
expect ( t , ( l . pending ) . count == 1 && l . pending [ 0 ] . asset == 2 ) ;
scenes . loader_complete ( * l . loader , failed , true ) ;
policy_pump ( * m , * now ) ;
expect_value ( t , l . loader . active , 1 ) ;
policy_loader_finish ( * l , true ) ;
policy_pump ( * m , * now ) ;
expect ( t , scenes . is_local_loaded ( * m , b ) ) ;
policy_drain ( t , * m , * l , * now ) ;
policy_loader_destroy ( t , * l ) ;

 } ;

 //@endregion


//@region Actual runtime snapshot ACK barrier with typed carry and physical resources

 Policy_Node :: struct {
backend : enet . Transport ;
s : session . Session ;
reg : objects . Registry ;
r : nr . Runtime ;
}

 Policy_Acks :: struct {
node : * Policy_Node ;
hold : bool ;
frames : [ .. ] [ ] u8 ;
}

 policy_runtime_send :: ( user : * void , side : transport . Invoker , to : transport . Connection_Id , channel : transport . Channel , frame : [ ] u8 ) -> bool {

 h := ( cast ( * Policy_Acks ) user ) ;
if h . hold && side == . Client && ( frame ) . count > 0 && frame [ 0 ] == ( cast , trunc ( u8 ) ( nr . Kind . Ack ) ) {

 owned := new_slice ( u8 , ( frame ) . count ) ;
copy_samples ( owned , frame ) ;
array_add ( * h . frames , owned ) ;
return true ;

 }

 return session . send_extension ( * h . node . s , to , nr . EXTENSION_ID , frame , channel ) ;

 }

 policy_node_init :: ( n : * Policy_Node , authority : bool , l : * Policy_Loader ) {

 test_session ( * n . s , * n . backend , 10 ) ;
objects . registry_init ( * n . reg , authority ) ;
cfg := nr . Config .{
server_scenes = .{
loader = * l . loader , timeout_ms = 2000 , resend_ms = 20 ,
} , client_scenes = .{
loader = * l . loader , timeout_ms = 2000 , resend_ms = 20 ,
} ,

 } ;

 if authority {
cfg . server_registry = * n . reg ;
} else {
cfg . client_registry = * n . reg ;
}

 assert ( nr . init ( * n . r , * n . s , cfg ) ) ;

 }

 policy_runtime_pump :: ( a , b : * Policy_Node , l : * Policy_Loader , steps : int = 20 ) {

 { loop_index := 0 ; while loop_index < steps { defer loop_index += 1 ;

 nr . update ( * a . r , 5 ) ;
nr . update ( * b . r , 5 ) ;
while ( l . pending ) . count > 0 {
policy_loader_finish ( l ) ;
}

 sleep_milliseconds ( 1 ) ;

 } }


} ;


scene_runtime_typed_binding_keeps_frozen_migration_ack_and_real_loader_resources :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l , 0 ) ;
a , b : Policy_Node ;
policy_node_init ( * a , true , * l ) ;
policy_node_init ( * b , false , * l ) ;
binding : nr . Scene_Policy_Binding ;
expect ( t , nr . scene_policies_bind ( * binding , * a . r . server , .{
selection = . Registered
} ) ) ;
acks := Policy_Acks .{
node = * b ,
} ;
b . r . config . send , b . r . config . userdata = policy_runtime_send , * acks ;
expect ( t , session . start_server ( * a . s , 0 ) ) ;
expect ( t , session . start_client ( * b . s , "127.0.0.1" , session . bound_port ( * a . s ) ) ) ;
policy_runtime_pump ( * a , * b , * l , 30 ) ;
old , _ := scenes . open ( * a . r . server . scenes , 11 , .{
kind = . Global
} , true ) ;
target , _ := scenes . open ( * a . r . server . scenes , 12 , .{
kind = . Global
} , true ) ;
policy_runtime_pump ( * a , * b , * l , 30 ) ;
if ! expect ( t , b . s . client_authenticated && scenes . is_loaded ( * a . r . server . scenes , target , b . s . client_server_id ) ) {
return ;
}

 obj := objects . spawn ( * a . reg , b . s . client_server_id ) ;
obj . scene = ( cast , trunc ( u32 ) ( old ) ) ;
expect ( t , scenes . carry_register ( * binding . carry . policy , obj . id , .{
eligible = true
} ) ) ;
policy_runtime_pump ( * a , * b , * l ) ;
acks . hold = true ;
expect ( t , scenes . begin_replace ( * a . r . server . scenes , old , target , true ) ) ;
policy_runtime_pump ( * a , * b , * l ) ;
info , exists := scenes . get_info ( * a . r . server . scenes , old ) ;
expect ( t , exists && info . phase == . Open && obj . scene == ( cast , trunc ( u32 ) ( target ) ) ) ;
expect_value ( t , ( l . resources ) . count , 4 ) ;
migration := table_get ( * a . r . server . migrations , old ) ;
if expect ( t , migration != null ) {
expect_value ( t , ( migration . objects ) . count , 1 ) ;
expect_value ( t , migration . objects [ 0 ] , obj . id ) ;
}

 if expect ( t , ( acks . frames ) . count > 0 ) {

 late := objects . spawn ( * a . reg , 0 ) ;
late . scene = ( cast , trunc ( u32 ) ( target ) ) ;
expect ( t , session . send_extension ( * b . s , session . local_connection ( * b . s ) , nr . EXTENSION_ID , acks . frames [ ( acks . frames ) . count - 1 ] ) ) ;
policy_runtime_pump ( * a , * b , * l , 30 ) ;
_ , exists = scenes . get_info ( * a . r . server . scenes , old ) ;
expect ( t , ! exists , "frozen migration ACK releases source despite later target churn" ) ;
expect_value ( t , ( l . resources ) . count , 2 ) ;

 }

 acks . hold = false ;
for frame : acks . frames {
release ( frame ) ;
} ;
release ( acks . frames ) ;
expect ( t , nr . scene_policies_unbind ( * binding ) ) ;
session . shutdown ( * a . s ) ;
session . shutdown ( * b . s ) ;
nr . shutdown ( * a . r ) ;
nr . shutdown ( * b . r ) ;
policy_runtime_pump ( * a , * b , * l , 30 ) ;
expect ( t , nr . destroy ( * a . r ) ) ;
expect ( t , nr . destroy ( * b . r ) ) ;
objects . registry_destroy ( * a . reg ) ;
objects . registry_destroy ( * b . reg ) ;
session . destroy ( * a . s ) ;
session . destroy ( * b . s ) ;
enet . destroy ( * a . backend ) ;
enet . destroy ( * b . backend ) ;
policy_loader_destroy ( t , * l ) ;

 }


scene_runtime_rollback_waits_for_inverse_ack_before_releasing_destination :: ( t : * Test ) {

 l : Policy_Loader ;
policy_loader_init ( * l , 0 ) ;
a , b : Policy_Node ;
policy_node_init ( * a , true , * l ) ;
policy_node_init ( * b , false , * l ) ;
binding : nr . Scene_Policy_Binding ;
expect ( t , nr . scene_policies_bind ( * binding , * a . r . server , .{
selection = . All
} ) ) ;
acks := Policy_Acks .{
node = * b ,
} ;
b . r . config . send , b . r . config . userdata = policy_runtime_send , * acks ;
expect ( t , session . start_server ( * a . s , 0 ) ) ;
expect ( t , session . start_client ( * b . s , "127.0.0.1" , session . bound_port ( * a . s ) ) ) ;
policy_runtime_pump ( * a , * b , * l , 30 ) ;
old , _ := scenes . open ( * a . r . server . scenes , 11 , .{
kind = . Global
} , true ) ;
target , _ := scenes . open ( * a . r . server . scenes , 12 , .{
kind = . Global
} , true ) ;
policy_runtime_pump ( * a , * b , * l , 30 ) ;
obj := objects . spawn ( * a . reg , b . s . client_server_id ) ;
obj . scene = ( cast , trunc ( u32 ) ( old ) ) ;
policy_runtime_pump ( * a , * b , * l ) ;
acks . hold = true ;
expect ( t , scenes . begin_replace ( * a . r . server . scenes , old , target , true ) ) ;
policy_runtime_pump ( * a , * b , * l ) ;
expect_value ( t , obj . scene , ( cast , trunc ( u32 ) ( target ) ) ) ;
expect ( t , scenes . close ( * a . r . server . scenes , target ) ) ;
expect_value ( t , obj . scene , ( cast , trunc ( u32 ) ( old ) ) ) ;
policy_runtime_pump ( * a , * b , * l ) ;
expect_value ( t , ( l . resources ) . count , 4 ) ;
expect ( t , ! nr . scene_policies_unbind ( * binding ) , "inverse migration is still awaiting ACK" ) ;
expect_value ( t , ( binding . rollbacks ) . count , 1 ) ;
if expect ( t , ( acks . frames ) . count > 0 ) {

 expect ( t , session . send_extension ( * b . s , session . local_connection ( * b . s ) , nr . EXTENSION_ID , acks . frames [ ( acks . frames ) . count - 1 ] ) ) ;
policy_runtime_pump ( * a , * b , * l , 30 ) ;
_ , exists := scenes . get_info ( * a . r . server . scenes , target ) ;
expect ( t , ! exists ) ;
expect ( t , scenes . is_local_loaded ( * a . r . server . scenes , old ) && obj . scene == ( cast , trunc ( u32 ) ( old ) ) ) ;
expect_value ( t , ( l . resources ) . count , 2 ) ;

 }

 acks . hold = false ;
for frame : acks . frames {
release ( frame ) ;
} ;
release ( acks . frames ) ;
expect ( t , nr . scene_policies_unbind ( * binding ) ) ;
session . shutdown ( * a . s ) ;
session . shutdown ( * b . s ) ;
nr . shutdown ( * a . r ) ;
nr . shutdown ( * b . r ) ;
policy_runtime_pump ( * a , * b , * l , 30 ) ;
expect ( t , nr . destroy ( * a . r ) ) ;
expect ( t , nr . destroy ( * b . r ) ) ;
objects . registry_destroy ( * a . reg ) ;
objects . registry_destroy ( * b . reg ) ;
session . destroy ( * a . s ) ;
session . destroy ( * b . s ) ;
enet . destroy ( * a . backend ) ;
enet . destroy ( * b . backend ) ;
policy_loader_destroy ( t , * l ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
