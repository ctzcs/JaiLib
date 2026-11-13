#scope_file
objects :: #import "thirdparty/onet/objects" ;
scenes :: #import "thirdparty/onet/scenes" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export


//@region Live placement paths, queued registrations and edge observations

 API_Callbacks :: struct {

 manager : * scenes . Manager ;

 log : [ .. ] int ;

 events : [ .. ] scenes . Observer_Event ;

 deny : bool ;

 mutate : bool ;


}

 api_first_validator :: ( user : * void , c : transport . Connection_Id , h : scenes . Handle , a : scenes . Asset_Id ) -> bool {

 x := ( cast ( * API_Callbacks ) user ) ;
array_add ( * x . log , 1 ) ;
if x . mutate {
x . mutate = false ;
assert ( scenes . unregister_load_validator ( x . manager , 2 ) ) ;
assert ( scenes . register_load_validator ( x . manager , 3 , api_third_validator , x ) ) ;
}

 return true ;

 }

 api_second_validator :: ( user : * void , c : transport . Connection_Id , h : scenes . Handle , a : scenes . Asset_Id ) -> bool {
x := ( cast ( * API_Callbacks ) user ) ;
array_add ( * x . log , 2 ) ;
return ! x . deny ;
}

 api_third_validator :: ( user : * void , c : transport . Connection_Id , h : scenes . Handle , a : scenes . Asset_Id ) -> bool {
array_add ( * ( ( cast ( * API_Callbacks ) user ) ) . log , 3 ) ;
return true ;
}

 api_first_observer :: ( user : * void , event : scenes . Observer_Event ) -> bool {

 x := ( cast ( * API_Callbacks ) user ) ;
array_add ( * x . log , 10 ) ;
if x . mutate {
x . mutate = false ;
assert ( scenes . unregister_observer ( x . manager , 2 ) ) ;
assert ( scenes . register_observer ( x . manager , 3 , api_third_observer , x ) ) ;
}

 return true ;

 }

 api_second_observer :: ( user : * void , event : scenes . Observer_Event ) -> bool {
array_add ( * ( ( cast ( * API_Callbacks ) user ) ) . log , 20 ) ;
return true ;
}

 api_third_observer :: ( user : * void , event : scenes . Observer_Event ) -> bool {
array_add ( * ( ( cast ( * API_Callbacks ) user ) ) . log , 30 ) ;
return true ;
}

 api_record_observer :: ( user : * void , event : scenes . Observer_Event ) -> bool {

 x := ( cast ( * API_Callbacks ) user ) ;
if event . kind == . State_Changed {
assert ( scenes . connection_holds_scene ( x . manager , event . handle , event . connection ) == event . loaded ) ;
}

 array_add ( * x . events , event ) ;
return true ;

 }


scene_api_authority_validator_list_gates_every_placement_before_disclosure :: ( t : * Test ) {

 h : Scene_Hub ;
scene_hub_init ( * h ) ;

m := * h . endpoints [ 0 ] . manager ;
x := API_Callbacks .{
manager = m , deny = true ,
} ;
defer release ( x . log ) ;
defer scene_hub_destroy ( * h , t ) ;
expect ( t , scenes . register_load_validator ( m , 1 , api_first_validator , * x ) ) ;
expect ( t , scenes . register_load_validator ( m , 2 , api_second_validator , * x ) ) ;
expect ( t , scenes . register_load_validator ( m , 3 , api_third_validator , * x ) ) ;
expect ( t , ! scenes . register_load_validator ( m , 3 , api_third_validator , * x ) ) ;
expect ( t , ! scenes . register_load_validator ( m , 4 , null ) ) ;
scene_join ( * h , 1 , 101 ) ;
id := scene_open ( * h , 9 , .{
kind = . Global
} ) ;
scene_pump ( * h ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , 0 ) ;
expect_value ( t , ( table_get ( * m . scenes , id ) . remotes ) . count , 0 ) ;
expect_value ( t , m . next_revision , ( cast , trunc ( u64 ) ( 1 ) ) ) ;
expect_value ( t , ( x . log ) . count , 2 ) ;
expect_value ( t , x . log [ 0 ] , 1 ) ;
expect_value ( t , x . log [ 1 ] , 2 ) ;
// Join, explicit placement and blocked-spawn queries all use the same predicate.

 scene_join ( * h , 2 , 102 ) ;
expect ( t , ! scenes . request_placement ( m , id , 1 ) ) ;
m . config . automatic_request_on_blocked_spawn = true ;
expect ( t , ! scenes . is_loaded ( m , id , 1 ) ) ;
scene_pump ( * h ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , 0 ) ;
x . deny = false ;
expect ( t , scenes . request_load ( m , id , 1 ) ) ;
scene_pump ( * h ) ;
expect ( t , scenes . is_loaded ( m , id , 1 ) ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , 1 ) ;
// A validator refusing a peer does not affect independent peers in batch requests.

 expect_value ( t , scenes . request_placements ( m , id , transport . Connection_Id .[ 1 , 2 , 99 ] ) , 1 ) ;
scene_pump ( * h ) ;
expect ( t , scenes . is_loaded ( m , id , 2 ) ) ;

 } ;


scene_api_registration_mutation_is_deferred_until_walk_finishes :: ( t : * Test ) {

 h : Scene_Hub ;
scene_hub_init ( * h ) ;

m := * h . endpoints [ 0 ] . manager ;
x := API_Callbacks .{
manager = m , mutate = true ,
} ;
defer release ( x . log ) ;
defer scene_hub_destroy ( * h , t ) ;
scenes . register_load_validator ( m , 1 , api_first_validator , * x ) ;
scenes . register_load_validator ( m , 2 , api_second_validator , * x ) ;
scene_join ( * h , 1 , 101 ) ;
scene_open ( * h , 1 , .{
kind = . Global
} ) ;
expect_value ( t , ( x . log ) . count , 2 ) ;
expect_value ( t , x . log [ 1 ] , 2 ) ;
array_reset_keeping_memory ( * x . log ) ;
scene_open ( * h , 2 , .{
kind = . Global
} ) ;
expect_value ( t , ( x . log ) . count , 2 ) ;
expect_value ( t , x . log [ 1 ] , 3 ) ;
scenes . unregister_load_validator ( m , 1 ) ;
scenes . unregister_load_validator ( m , 3 ) ;
array_reset_keeping_memory ( * x . log ) ;
x . mutate = true ;
scenes . register_observer ( m , 1 , api_first_observer , * x ) ;
scenes . register_observer ( m , 2 , api_second_observer , * x ) ;
scene_open ( * h , 3 , .{
kind = . Global
} ) ;
expect_value ( t , ( x . log ) . count , 2 ) ;
expect_value ( t , x . log [ 1 ] , 20 ) ;
array_reset_keeping_memory ( * x . log ) ;
scene_open ( * h , 4 , .{
kind = . Global
} ) ;
expect_value ( t , ( x . log ) . count , 2 ) ;
expect_value ( t , x . log [ 1 ] , 30 ) ;
expect ( t , ! scenes . unregister_observer ( m , 2 ) ) ;
scenes . unregister_observer ( m , 1 ) ;
scenes . unregister_observer ( m , 3 ) ;
// Explicit observer failure stops remaining observers, never cancels admission.

 scenes . register_observer ( m , 4 , ( user : * void , e : scenes . Observer_Event ) -> bool {
array_add ( * ( ( cast ( * API_Callbacks ) user ) ) . log , 40 ) ;
return false
; } , * x ) ;
scenes . register_observer ( m , 5 , api_third_observer , * x ) ;
array_reset_keeping_memory ( * x . log ) ;
id := scene_open ( * h , 5 , .{
kind = . Global
} ) ;
scene_pump ( * h ) ;
expect ( t , scenes . is_loaded ( m , id , 1 ) ) ;
for value : x . log {
expect_value ( t , value , 40 ) ;
}


} ;


scene_api_observer_edges_hold_through_unload_and_emit_once :: ( t : * Test ) {

 h : Scene_Hub ;
scene_hub_init ( * h ) ;

m := * h . endpoints [ 0 ] . manager ;
x := API_Callbacks .{
manager = m ,
} ;
defer release ( x . events ) ;
defer scene_hub_destroy ( * h , t ) ;
scenes . register_observer ( m , 1 , api_record_observer , * x ) ;
scene_join ( * h , 1 , 101 ) ;
scene_join ( * h , 2 , 102 ) ;
id := scene_open ( * h , 3 , .{
kind = . Global
} ) ;
scene_pump ( * h ) ;
states := 0 ;
for e : x . events {
if e . kind == . State_Changed {
states += 1 ;
}

 } ;
expect_value ( t , states , 2 ) ;
r := table_get ( * table_get ( * m . scenes , id ) . remotes , 1 ) ;
expect ( t , scene_inject ( m , 1 , .{ . Loaded , id , 3 , 101 , r . revision
} ) ) ;
expect_value ( t , ( x . events ) . count , 4 ) ;
h . endpoints [ 1 ] . auto_complete = false ;
expect ( t , scenes . request_unload ( m , id , 1 ) ) ;
scene_pump ( * h , 3 ) ;
expect ( t , scenes . connection_holds_scene ( m , id , 1 ) ) ;
expect ( t , ! scenes . is_loaded ( m , id , 1 ) , "pending unload closes spawn gate immediately" ) ;
occupants := new_dynamic ( transport . Connection_Id , 0 ) ;
defer release ( occupants ) ;
scenes . collect_connections_in_scene ( m , id , * occupants ) ;
expect_value ( t , ( occupants ) . count , 2 ) ;
scene_finish ( * h . endpoints [ 1 ] , id ) ;
scene_pump ( * h ) ;
expect ( t , ! scenes . connection_holds_scene ( m , id , 1 ) ) ;
scenes . peer_leave ( m , 2 ) ;
expect ( t , ! scenes . connection_holds_scene ( m , id , 2 ) ) ;
states = 0 ;
for e : x . events {
if e . kind == . State_Changed {
states += 1 ;
}

 } ;
expect_value ( t , states , 4 ) ;

 }


scene_api_join_placement_modes_override_scope_only_when_selected :: ( t : * Test ) {

 modes : [ ] scenes . Join_Placement = scenes . Join_Placement .[ . Scope , . Every_Open_Scene , . Global_Scenes , . None ] ;
for mode : modes {

 h : Scene_Hub ;
scene_hub_init ( * h ) ;
m := * h . endpoints [ 0 ] . manager ;
m . config . join_placement = mode ;
private := scene_open ( * h , 1 , .{
kind = . Connections
} ) ;
shared := scene_open ( * h , 2 , .{
kind = . Global
} ) ;
scene_join ( * h , 1 , 101 ) ;
scene_pump ( * h ) ;
expect_value ( t , scenes . is_loaded ( m , private , 1 ) , mode == . Every_Open_Scene ) ;
expect_value ( t , scenes . is_loaded ( m , shared , 1 ) , mode != . None ) ;
later := scene_open ( * h , 3 , .{
kind = . Global
} ) ;
scene_pump ( * h ) ;
expect ( t , scenes . is_loaded ( m , later , 1 ) , "opening Global places current peers even under None" ) ;
before := ( h . endpoints [ 2 ] . requests ) . count ;
scenes . bind_authority ( * h . endpoints [ 2 ] . manager , 900 , 102 ) ;
expect ( t , scenes . peer_join ( m , 2 , 102 , true ) ) ;
scene_pump ( * h ) ;
expect_value ( t , ( h . endpoints [ 2 ] . requests ) . count , before ) ;
expect ( t , ! scenes . request_placement ( m , private , 2 ) , "true local-peer sentinel skipped, not remote host client" ) ;
scene_hub_destroy ( * h , t ) ;

 } ;


} ;


scene_api_blocked_spawn_actual_gate_requests_deduplicates_latches_and_rearms :: ( t : * Test ) {
defer scene_hub_destroy ( * h , t ) ;

 h : Scene_Hub ;
scene_hub_init ( * h ) ;

m := * h . endpoints [ 0 ] . manager ;
m . config . join_placement = . None ;
id := scene_open ( * h , 4 , .{
kind = . Connections
} ) ;
scene_join ( * h , 1 , 101 ) ;
reg : objects . Registry ;
objects . registry_init ( * reg ) ;
defer objects . registry_destroy ( * reg ) ;
obj := objects . spawn ( * reg , 0 ) ;
obj . scene = ( cast , trunc ( u32 ) ( id ) ) ;
expect ( t , ! scenes . spawn_allowed ( m , obj , 1 ) ) ;
expect_value ( t , ( table_get ( * m . scenes , id ) . remotes ) . count , 0 ) ;
m . config . automatic_request_on_blocked_spawn = true ;
h . endpoints [ 1 ] . fail_load = true ;
{ loop_index := 0 ; while loop_index < 20 { defer loop_index += 1 ;
expect ( t , ! scenes . spawn_allowed ( m , obj , 1 ) ) ;
} } ;

 scene_pump ( * h ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , 1 ) ;
expect_value ( t , scenes . connection_state ( m , id , 1 ) , scenes . State . Load_Failed ) ;
{ loop_index := 0 ; while loop_index < 20 { defer loop_index += 1 ;
expect ( t , ! scenes . is_loaded ( m , id , 1 ) ) ;
} } ;
scene_pump ( * h ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , 1 ) ;
expect ( t , scenes . clear_load_failure ( m , id , 1 ) ) ;
expect ( t , ! scenes . clear_load_failure ( m , id , 1 ) ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , 1 ) ;
h . endpoints [ 1 ] . fail_load = false ;
expect ( t , ! scenes . spawn_allowed ( m , obj , 1 ) ) ;
scene_pump ( * h ) ;
expect ( t , scenes . spawn_allowed ( m , obj , 1 ) ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , 2 ) ;
occupants := new_dynamic ( transport . Connection_Id , 0 ) ;
array_add ( * occupants , 99 ) ;
defer release ( occupants ) ;
scenes . collect_connections_in_scene ( m , 0 , * occupants ) ;
expect_value ( t , ( occupants ) . count , 2 ) ;
expect ( t , ! scenes . is_closed_handle ( m , id ) ) ;
expect ( t , scenes . close ( m , id ) ) ;
scene_pump ( * h ) ;
expect ( t , scenes . is_closed_handle ( m , id ) ) ;
expect ( t , ! scenes . is_closed_handle ( m , ( cast ( scenes . Handle ) ( m . next_handle ) ) ) ) ;

 }

 //@endregion


//@region Ticket progress ingestion is local and caller-thread safe

 API_Progress :: struct {
values : [ .. ] float32 ;
ticket : scenes . Ticket ;
}

 api_progress :: ( user : * void , ticket : scenes . Ticket , value : float32 ) {
x := ( cast ( * API_Progress ) user ) ;
x . ticket = ticket ;
array_add ( * x . values , value ) ;
}

 API_Progress_Worker :: struct {
manager : * scenes . Manager ;
ticket : scenes . Ticket ;
}

 api_progress_worker :: ( user : * void ) {
x := ( cast ( * API_Progress_Worker ) user ) ;
assert ( scenes . notify_load_progress ( x . manager , x . ticket , 0.375 ) ) ;
}


scene_api_progress_thread_ingestion_stale_ticket_and_no_wire_traffic :: ( t : * Test ) {

 h : Scene_Hub ;
scene_hub_init ( * h ) ;

scene_join ( * h , 1 , 101 ) ;
e := * h . endpoints [ 1 ] ;
e . auto_complete = false ;
x : API_Progress ;
defer release ( x . values ) ;
defer scene_hub_destroy ( * h , t ) ;
scenes . register_progress ( * e . manager , 1 , api_progress , * x ) ;
id := scene_open ( * h , 7 , .{
kind = . Global
} ) ;
scene_pump ( * h , 3 ) ;
ticket := e . pending [ 0 ] ;
worker_data := API_Progress_Worker .{
* e . manager , ticket ,
} ;

 worker := create_worker ( * worker_data , api_progress_worker ) ;
join_worker ( worker ) ;
destroy_worker ( worker ) ;
expect_value ( t , ( x . values ) . count , 0 ) ;
expect ( t , scenes . notify_scene_load_progress ( * e . manager , id , 7 , 1.5 ) ) ;
expect_value ( t , ( x . values ) . count , 1 ) ;
expect ( t , scenes . notify_scene_load_progress ( * e . manager , 999 , 8 , 0.5 ) , "self-driven local progress needs no authority request" ) ;
expect_value ( t , x . ticket . serial , ( cast , trunc ( u64 ) ( 0 ) ) ) ;
scenes . update ( * e . manager , h . now + 1 ) ;
expect_value ( t , ( x . values ) . count , 3 ) ;
expect_value ( t , x . values [ 0 ] , ( cast ( float32 ) ( 1.5 ) ) ) ;
expect_value ( t , x . values [ 1 ] , ( cast ( float32 ) ( 0.5 ) ) ) ;
expect_value ( t , x . values [ 2 ] , ( cast ( float32 ) ( 0.375 ) ) ) ;
expect_value ( t , ( h . messages ) . count , 0 ) ;
expect_value ( t , x . ticket , ticket ) ;
scene_finish ( e , id ) ;
scene_pump ( * h ) ;
scenes . notify_load_progress ( * e . manager , ticket , 0.9 ) ;
scene_pump ( * h ) ;
expect_value ( t , ( x . values ) . count , 3 ) ;
expect ( t , scenes . unregister_progress ( * e . manager , 1 ) ) ;

 } ;

 //@endregion


//@region Actual shared physical loader recovery and progress

 API_Physical :: struct {
loader : scenes . Loader ;
pending : [ .. ] scenes . Loader_Ticket ;
held : H.Table(scenes.Resource_Key,[]u8,test_resource_hash,test_resource_equal) ;
requests : int ;
}

 api_physical_request :: ( user : * void , ticket : scenes . Loader_Ticket ) {
x := ( cast ( * API_Physical ) user ) ;
array_add ( * x . pending , ticket ) ;
x . requests += 1 ;
}

 api_physical_finish :: ( x : * API_Physical ) {

 ticket := x . pending [ 0 ] ;
array_ordered_remove_by_index ( * x . pending , 0 ) ;
if ticket . operation == . Load {
H . table_set ( * x . held , ticket . key , new_slice ( u8 , 8 ) ) ;
} else {
release ( table_get ( * x . held , ticket . key ) ) ;
H . table_remove ( * x . held , ticket . key ) ;
}

 assert ( scenes . loader_complete ( * x . loader , ticket , true ) ) ;

 }


scene_api_physical_progress_and_unexpected_unload_own_no_ghost_references :: ( t : * Test ) {

 x := API_Physical .{
held = new_table(scenes.Resource_Key,[]u8,hash_function=test_resource_hash,compare_function=test_resource_equal) ,
} ;

 assert ( scenes . loader_init ( * x . loader , .{
userdata = * x , request = api_physical_request
} ) ) ;
s , c : scenes . Manager ;
scenes . init ( * s , .{
role = . Server , loader = * x . loader , loader_namespace = 57
} ) ;
scenes . init ( * c , .{
role = . Client , loader = * x . loader , loader_namespace = 57
} ) ;
progress : API_Progress ;
defer release ( progress . values ) ;
scenes . register_progress ( * s , 1 , api_progress , * progress ) ;
id , loop_index := scenes . open ( * s , 4 , .{
kind = . Global
} , true ) ;
scenes . update ( * s , 1 ) ;
expect_value ( t , ( x . pending ) . count , 1 ) ;
expect ( t , ! scenes . notify_unloaded_unexpectedly ( * s , id ) , "cannot forget active producer" ) ;
expect ( t , scenes . loader_notify_progress ( * x . loader , x . pending [ 0 ] , 0.25 ) ) ;
scenes . update ( * s , 2 ) ;
expect_value ( t , ( progress . values ) . count , 1 ) ;
api_physical_finish ( * x ) ;
scenes . update ( * s , 3 ) ;
assert ( scenes . bind_authority ( * c , 900 , 101 ) ) ;
expect ( t , scene_inject ( * c , 900 , .{ . Load , id , 4 , 101 , 1
} ) ) ;
scenes . update ( * c , 4 ) ;
scenes . update ( * c , 5 ) ;
expect_value ( t , scenes . loader_reference_count ( * x . loader , .{
57 , id
} ) , 2 ) ;
// Engine already unloaded the physical resource; recovery must not unload again.

 release ( table_get ( * x . held , .{
57 , id
, } ) ) ;
H . table_remove ( * x . held , scenes . Resource_Key .{
57 , id
} ) ;
expect ( t , scenes . notify_unloaded_unexpectedly ( * s , id ) ) ;
expect_value ( t , scenes . loader_reference_count ( * x . loader , .{
57 , id
} ) , 0 ) ;
expect_value ( t , x . requests , 1 ) ;
expect ( t , ! scenes . notify_unloaded_unexpectedly ( * s , id ) ) ;
scenes . update ( * c , 6 ) ;
expect_value ( t , ( c . scenes ) . count , 0 ) ;
scenes . shutdown ( * s ) ;
scenes . shutdown ( * c ) ;
expect ( t , scenes . destroy ( * s ) && scenes . destroy ( * c ) ) ;
scenes . loader_shutdown ( * x . loader ) ;
scenes . loader_update ( * x . loader ) ;
expect ( t , scenes . loader_destroy ( * x . loader ) ) ;
expect_value ( t , ( x . held ) . count , 0 ) ;
release ( x . held ) ;
release ( x . pending ) ;

 } ;

 API_Recovery :: struct {
manager : * scenes . Manager ;
object : * objects . Network_Object ;
order : [ .. ] int ;
}

 api_recovery_event :: ( user : * void , e : scenes . Event ) {

 x := ( cast ( * API_Recovery ) user ) ;
if e . kind == . Before_Unload {
assert ( scenes . connection_holds_scene ( x . manager , e . handle , 1 ) ) ;
array_add ( * x . order , 1 ) ;
}

 if e . kind == . Unexpected_Unload {
assert ( ! x . object . active ) ;
array_add ( * x . order , 3 ) ;
}


}

 api_recovery_observer :: ( user : * void , e : scenes . Observer_Event ) -> bool {

 x := ( cast ( * API_Recovery ) user ) ;
if e . kind == . State_Changed && ! e . loaded {
assert ( ! x . object . active ) ;
assert ( ! scenes . connection_holds_scene ( x . manager , e . handle , e . connection ) ) ;
array_add ( * x . order , 2 ) ;
}

 return true ;

 }


scene_api_unexpected_unload_despawns_before_forgetting_occupants :: ( t : * Test ) {

 h : Scene_Hub ;
scene_hub_init ( * h ) ;

m := * h . endpoints [ 0 ] . manager ;
scene_join ( * h , 1 , 101 ) ;
id := scene_open ( * h , 5 , .{
kind = . Global
} ) ;
scene_pump ( * h ) ;
reg : objects . Registry ;
objects . registry_init ( * reg ) ;
defer objects . registry_destroy ( * reg ) ;
obj := objects . spawn ( * reg , 1 ) ;
obj . scene = ( cast , trunc ( u32 ) ( id ) ) ;
x := API_Recovery .{
m , obj , ( [ .. ] int ) .{ } ,

 } ;
defer release ( x . order ) ;
defer scene_hub_destroy ( * h , t ) ;
m . config . event , m . config . userdata = api_recovery_event , * x ;
scenes . register_observer ( m , 1 , api_recovery_observer , * x ) ;
expect ( t , scenes . notify_unloaded_unexpectedly ( m , id , * reg ) ) ;
expect ( t , ! obj . active && scenes . is_closed_handle ( m , id ) ) ;
expect_value ( t , ( x . order ) . count , 3 ) ;
for value , i : x . order {
expect_value ( t , value , i + 1 ) ;
}

 expect_value ( t , ( h . messages ) . count , 0 ) ;
m . config . event , m . config . userdata = scene_event , * h . endpoints [ 0 ] ;

 } ;

 //@endregion


//@region Carried dynamic object exception and registered failure resolvers


scene_api_carried_object_moves_auto_request_and_group_gate_is_bounded :: ( t : * Test ) {
defer scene_hub_destroy ( * h , t ) ;

 h : Scene_Hub ;
scene_hub_init ( * h ) ;

m := * h . endpoints [ 0 ] . manager ;
m . config . join_placement = . None ;
old := scene_open ( * h , 1 , .{
kind = . Connections
} ) ;
target := scene_open ( * h , 2 , .{
kind = . Connections
} ) ;
scene_join ( * h , 1 , 101 ) ;
scene_join ( * h , 2 , 102 ) ;
reg : objects . Registry ;
objects . registry_init ( * reg ) ;
defer objects . registry_destroy ( * reg ) ;
p : scenes . Carry_Policy ;
scenes . carry_init ( * p , * reg , .{
selection = . Registered
} ) ;
defer scenes . carry_destroy ( * p ) ;
a := objects . spawn ( * reg , 1 ) ;
b := objects . spawn ( * reg , 0 ) ;
unrelated := objects . spawn ( * reg , 0 ) ;
a . scene , b . scene , unrelated . scene = ( cast , trunc ( u32 ) ( old ) ) , ( cast , trunc ( u32 ) ( old ) ) , ( cast , trunc ( u32 ) ( target ) ) ;
scenes . carry_register ( * p , a . id , .{
eligible = true , group = 8
} ) ;
scenes . carry_register ( * p , b . id , .{
eligible = true , group = 8
} ) ;
expect ( t , scenes . bind_carry_policy ( m , * p ) ) ;
expect ( t , scenes . carry_begin ( * p , old , target ) ) ;
expect ( t , scenes . load_outstanding ( m , target , 1 ) ) ;
expect ( t , ! scenes . load_outstanding ( m , target , 2 ) ) ;
expect ( t , scenes . spawn_allowed ( m , a , 1 ) && scenes . spawn_allowed ( m , b , 1 ) ) ;
expect ( t , ! scenes . spawn_allowed ( m , unrelated , 1 ) && ! scenes . spawn_allowed ( m , a , 2 ) ) ;
expect_value ( t , scenes . request_carried_scene ( m , a . id ) , 0 ) ;
scene_pump ( * h ) ;
expect ( t , scenes . is_loaded ( m , target , 1 ) ) ;
expect ( t , scenes . request_unload ( m , target , 1 ) ) ;
expect ( t , ! scenes . carried_for ( m , a , 1 ) ) ;
scenes . carry_finish ( * p , old , true ) ;

 } ;

 API_Resolvers :: struct {
policy : * scenes . Carry_Policy ;
log : [ .. ] int ;
mutate : bool ;
}

 api_resolver_one :: ( user : * void , c : transport . Connection_Id , obj : * objects . Network_Object , h : scenes . Handle , action : scenes . Carry_Failure_Action ) -> ( scenes . Carry_Failure_Action , bool ) {

 x := ( cast ( * API_Resolvers ) user ) ;
array_add ( * x . log , 1 ) ;
if x . mutate {
x . mutate = false ;
assert ( scenes . unregister_carry_resolver ( x . policy , 2 ) ) ;
}

 return . Retain , true ;

 }

 api_resolver_two :: ( user : * void , c : transport . Connection_Id , obj : * objects . Network_Object , h : scenes . Handle , action : scenes . Carry_Failure_Action ) -> ( scenes . Carry_Failure_Action , bool ) {

 x := ( cast ( * API_Resolvers ) user ) ;
array_add ( * x . log , 2 ) ;
assert ( action == . Retain ) ;
return . Release_Controller , true ;

 }


scene_api_ordered_failure_resolver_list_drives_real_controller_policy :: ( t : * Test ) {

 reg : objects . Registry ;
objects . registry_init ( * reg ) ;
defer objects . registry_destroy ( * reg ) ;
p : scenes . Carry_Policy ;
scenes . carry_init ( * p , * reg , .{
failure = . Despawn
} ) ;
defer scenes . carry_destroy ( * p ) ;
x := API_Resolvers .{
policy = * p , mutate = true ,
} ;
defer release ( x . log ) ;
scenes . register_carry_resolver ( * p , 1 , api_resolver_one , * x ) ;
scenes . register_carry_resolver ( * p , 2 , api_resolver_two , * x ) ;
a := objects . spawn ( * reg , 1 ) ;
a . scene = 4 ;
expect_value ( t , scenes . carry_apply_failure ( * p , 1 , 4 ) , 1 ) ;
expect ( t , a . active && a . owner == 0 ) ;
expect_value ( t , ( x . log ) . count , 2 ) ;
objects . set_controller ( * reg , a . id , 1 ) ;
expect_value ( t , scenes . carry_apply_failure ( * p , 1 , 4 ) , 0 ) ;
expect ( t , a . active && a . owner == 1 ) ;
expect_value ( t , ( x . log ) . count , 3 ) ;

 } ;

 //@endregion


//@region Failure latch and policy registration exercised through Manager update


scene_api_scope_transition_runs_authority_validators_and_timeout_is_failure_edge :: ( t : * Test ) {

 h : Scene_Hub ;
scene_hub_init ( * h ) ;

m := * h . endpoints [ 0 ] . manager ;
x := API_Callbacks .{
manager = m , deny = true ,
} ;

 defer release ( x . log ) ;
defer release ( x . events ) ;
defer scene_hub_destroy ( * h , t ) ;
scenes . register_load_validator ( m , 1 , api_second_validator , * x ) ;
scenes . register_observer ( m , 1 , api_record_observer , * x ) ;
scene_join ( * h , 1 , 101 ) ;
id := scene_open ( * h , 6 , .{
kind = . Connections
} ) ;
expect ( t , scenes . set_scope ( m , id , .{ . Connections , transport . Connection_Id .[ 1 ]
} ) ) ;
scene_pump ( * h ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , 0 ) ;
expect_value ( t , ( x . log ) . count , 1 ) ;
x . deny = false ;
h . endpoints [ 1 ] . auto_complete = false ;
expect ( t , scenes . request_load ( m , id , 1 ) ) ;
scene_pump ( * h , 3 ) ;
expect ( t , scenes . load_outstanding ( m , id , 1 ) ) ;
h . now += 101 ;
scenes . update ( m , h . now ) ;
scene_pump ( * h , 3 ) ;
failures := 0 ;
for e : x . events {
if e . kind == . Load_Failed {
failures += 1 ;
}

 }

 expect_value ( t , failures , 1 ) ;
expect ( t , ! scenes . load_outstanding ( m , id , 1 ) ) ;
// Finish a timed-out physical load: new-revision unload releases it, and

 // blocked-spawn evaluation must not turn that cleanup into an endless retry.

 scene_finish ( * h . endpoints [ 1 ] , id ) ;
scene_pump ( * h , 3 ) ;
scene_finish ( * h . endpoints [ 1 ] , id ) ;
scene_pump ( * h ) ;
m . config . automatic_request_on_blocked_spawn = true ;
before := ( h . endpoints [ 1 ] . requests ) . count ;
{ loop_index := 0 ; while loop_index < 10 { defer loop_index += 1 ;
expect ( t , ! scenes . is_loaded ( m , id , 1 ) ) ;
} } ;
scene_pump ( * h ) ;
expect_value ( t , ( h . endpoints [ 1 ] . requests ) . count , before ) ;
expect ( t , scenes . clear_load_failure ( m , id , 1 ) ) ;
h . endpoints [ 1 ] . auto_complete = true ;
expect ( t , ! scenes . is_loaded ( m , id , 1 ) ) ;
scene_pump ( * h ) ;
expect ( t , scenes . is_loaded ( m , id , 1 ) ) ;

 } ;


scene_api_carry_resolver_failure_keeps_prior_decision_on_real_load_failure :: ( t : * Test ) {

 reg : objects . Registry ;
objects . registry_init ( * reg ) ;
defer objects . registry_destroy ( * reg ) ;
binding : scenes . Carry_Binding ;
expect ( t , scenes . carry_binding_init ( * binding , * reg , .{
role = . Server , send = ( user : * void , c : transport . Connection_Id , b : [ ] u8 ) -> bool {
return true
; }

 } , .{
failure = . Despawn
} ) ) ;
defer scenes . carry_binding_destroy ( * binding ) ;
m : scenes . Manager ;
scenes . init ( * m , scenes . carry_binding_config ( * binding ) ) ;
scenes . peer_join ( * m , 1 , 101 ) ;
id , loop_index := scenes . open ( * m , 7 , .{
kind = . Global
} ) ;
obj := objects . spawn ( * reg , 1 ) ;
obj . scene = ( cast , trunc ( u32 ) ( id ) ) ;
x := API_Resolvers .{
policy = * binding . policy ,
} ;
defer release ( x . log ) ;
scenes . register_carry_resolver ( * binding . policy , 1 , api_resolver_one , * x ) ;
scenes . register_carry_resolver ( * binding . policy , 2 , ( user : * void , c : transport . Connection_Id , o : * objects . Network_Object , h : scenes . Handle , a : scenes . Carry_Failure_Action ) -> ( scenes . Carry_Failure_Action , bool ) {

 array_add ( * ( ( cast ( * API_Resolvers ) user ) ) . log , 2 ) ;
return . Despawn , false

 ; } , * x ) ;
scenes . register_carry_resolver ( * binding . policy , 3 , api_resolver_two , * x ) ;
scenes . update ( * m , 1 ) ;
r := table_get ( * table_get ( * m . scenes , id ) . remotes , 1 ) ;
expect ( t , scene_inject ( * m , 1 , .{ . Load_Failed , id , 7 , 101 , r . revision
} ) ) ;
expect ( t , obj . active && obj . owner == 1 , "failed resolver applies the preceding Retain decision" ) ;
expect_value ( t , ( x . log ) . count , 2 ) ;
scenes . peer_leave ( * m , 1 ) ;
scenes . shutdown ( * m ) ;
scenes . update ( * m , 2 ) ;
expect ( t , scenes . destroy ( * m ) ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.        
