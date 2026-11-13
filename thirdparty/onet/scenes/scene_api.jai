#scope_file
objects :: #import "thirdparty/onet/objects" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export


//@region Explicit queued observer and authority validator registrations

 // Scope preserves the pre-existing Odin allowlist behavior. Select

 // Every_Open_Scene explicitly when adopting that placement policy.

 Join_Placement :: enum {
Scope ; Every_Open_Scene ; Global_Scenes ; None ;
}

 Registration_Id :: #type,distinct u64 ;
Observer_Kind :: enum {
Requested ; State_Changed ; Load_Failed ;
}

 Observer_Event :: struct {
kind : Observer_Kind ;
connection : transport . Connection_Id ;
handle : Handle ;
asset : Asset_Id ;
loaded : bool ;
revision : u64 ;
}

 // false is an explicit callback failure: stop this list walk, but never abort

 // the already recorded request/state edge. Odin has no managed exceptions.

 Observer_Proc :: ( * void , Observer_Event ) -> bool ;
Load_Validator_Proc :: ( * void , transport . Connection_Id , Handle , Asset_Id ) -> bool ;
Progress_Proc :: ( * void , Ticket , float32 ) ;
Callback_Kind :: enum {
Observer ; Validator ; Progress ;
}

 Callback :: struct {
id : Registration_Id ;
kind : Callback_Kind ;
userdata : * void ;
observer : Observer_Proc ;
validator : Load_Validator_Proc ;
progress : Progress_Proc ;
}

 Callback_Change :: struct {
callback : Callback ;
remove_flag : bool ;
}

 Progress_Update :: struct {
ticket : Ticket ;
value : float32 ;
}

 Scene_API :: struct {

 callbacks : [ .. ] Callback ;

 changes : [ .. ] Callback_Change ;

 walk_depth : int ;

 local_peers : H . Table ( transport . Connection_Id , bool ) ;

 progress , draining_progress : [ .. ] Progress_Update ;
// progress protected by Manager.mutex


}

 MAX_CALLBACKS :: 256 ;
MAX_PROGRESS_UPDATES :: 1024 ;
callback_exists :: ( m : * Manager , id : Registration_Id , kind : Callback_Kind ) -> bool {

 found := false ;
for c : m . api . callbacks {
if c . id == id && c . kind == kind {
found = true ;
break ;
}

 }

 for op : m . api . changes {
if op . callback . id == id && op . callback . kind == kind {
found = ! op . remove_flag ;
}

 }

 return found ;

 }

 change_callback :: ( m : * Manager , c : Callback , remove_flag : bool ) -> bool {

 if ! m . initialized || c . id == 0 || callback_exists ( m , c . id , c . kind ) != remove_flag {
return false ;
}

 if m . api . walk_depth > 0 {

 if ( m . api . changes ) . count >= MAX_CALLBACKS * 2 {
return false ;
}

 if ! remove_flag && ( m . api . callbacks ) . count + ( m . api . changes ) . count >= MAX_CALLBACKS {
return false ;
}

 array_add ( * m . api . changes , Callback_Change .{
c , remove_flag
} ) ;
return true ;

 } ;

 if remove_flag {

 for x , i : m . api . callbacks {
if x . id == c . id && x . kind == c . kind {
array_ordered_remove_by_index ( * m . api . callbacks , i ) ;
return true ;
}

 }

 return false ;

 }

 if ( m . api . callbacks ) . count >= MAX_CALLBACKS {
return false ;
}

 array_add ( * m . api . callbacks , c ) ;
return true ;

 }

 end_callback_walk :: ( m : * Manager ) {

 m . api . walk_depth -= 1 ;
if m . api . walk_depth != 0 {
return ;
}

 for op : m . api . changes {

 if op . remove_flag {

 for c , i : m . api . callbacks {
if c . id == op . callback . id && c . kind == op . callback . kind {
array_ordered_remove_by_index ( * m . api . callbacks , i ) ;
break ;
}

 }


} else {
array_add ( * m . api . callbacks , op . callback ) ;
}


}

 array_reset_keeping_memory ( * m . api . changes ) ;

 }

 register_observer :: ( m : * Manager , id : Registration_Id , callback : Observer_Proc , userdata : * void = null ) -> bool {

 if callback == null {
return false ;
} ;
return change_callback ( m , .{
id = id , kind = . Observer , userdata = userdata , observer = callback
} , false ) ;

 } ;

 unregister_observer :: ( m : * Manager , id : Registration_Id ) -> bool {
return change_callback ( m , .{
id = id , kind = . Observer
} , true ) ;
} ;

 register_load_validator :: ( m : * Manager , id : Registration_Id , callback : Load_Validator_Proc , userdata : * void = null ) -> bool {

 if callback == null {
return false ;
} ;
return change_callback ( m , .{
id = id , kind = . Validator , userdata = userdata , validator = callback
} , false ) ;

 } ;

 unregister_load_validator :: ( m : * Manager , id : Registration_Id ) -> bool {
return change_callback ( m , .{
id = id , kind = . Validator
} , true ) ;
} ;

 register_progress :: ( m : * Manager , id : Registration_Id , callback : Progress_Proc , userdata : * void = null ) -> bool {

 if callback == null {
return false ;
} ;
return change_callback ( m , .{
id = id , kind = . Progress , userdata = userdata , progress = callback
} , false ) ;

 } ;

 unregister_progress :: ( m : * Manager , id : Registration_Id ) -> bool {
return change_callback ( m , .{
id = id , kind = . Progress
} , true ) ;
} ;

 observe :: ( m : * Manager , event : Observer_Event ) {

 m . api . walk_depth += 1 ;
defer end_callback_walk ( m ) ;
for c : m . api . callbacks {
if c . kind == . Observer && ! c . observer ( c . userdata , event ) {
break ;
}

 }


}

 load_allowed :: ( m : * Manager , c : transport . Connection_Id , h : Handle , asset : Asset_Id ) -> bool {

 m . api . walk_depth += 1 ;
defer end_callback_walk ( m ) ;
for cb : m . api . callbacks {
if cb . kind == . Validator && ! cb . validator ( cb . userdata , c , h , asset ) {
return false ;
}

 }

 return true ;

 }

 api_destroy :: ( m : * Manager ) {

 { p := m . config . carry_policy ; if
p != null && p . manager == m {
p . manager = null ;
} }

 release ( m . api . callbacks ) ;
release ( m . api . changes ) ;
release ( m . api . local_peers ) ;
release ( m . api . progress ) ;
release ( m . api . draining_progress ) ;
m . api = .{

 } ;


}

 //@endregion


//@region Local progress, ticket-safe any-thread ingestion

 // Raw values (including finite out-of-range values) are forwarded, not clamped,

 // like NotifySceneLoadProgress. Ticketed producer updates are incarnation-safe.

 notify_load_progress :: ( m : * Manager , ticket : Ticket , progress : float32 ) -> bool {

 if ticket . serial == 0 || ticket . operation != . Load || Math . isnan ( progress ) || Math . isinf ( progress ) {
return false ;
}

 Thread . lock ( * m . mutex ) ;
defer Thread . unlock ( * m . mutex ) ;
if ! m . accept_completions || ( m . api . progress ) . count >= MAX_PROGRESS_UPDATES {
return false ;
}

 array_add ( * m . api . progress , .{
ticket , progress
} ) ;
return true ;

 } ;

 // Loop-only convenience on handle/asset; producers should use

 // the ticket overload above to reject a late update from an earlier incarnation.

 notify_scene_load_progress :: ( m : * Manager , h : Handle , asset : Asset_Id , progress : float32 ) -> bool {

 if ! m . initialized || Math . isnan ( progress ) || Math . isinf ( progress ) {
return false ;
}

 ticket := Ticket .{
handle = h , asset = asset , operation = . Load ,
} ;

 { s := table_get ( * m . scenes , h ) ; if
s != null && s . asset == asset && s . local . busy && s . local . ticket . operation == . Load {
ticket = s . local . ticket ;
} }

 emit_progress ( m , ticket , progress ) ;
return true ;

 }

 emit_progress :: ( m : * Manager , ticket : Ticket , value : float32 ) {

 m . api . walk_depth += 1 ;
defer end_callback_walk ( m ) ;
for cb : m . api . callbacks {
if cb . kind == . Progress {
cb . progress ( cb . userdata , ticket , value ) ;
}

 }


}

 consume_progress :: ( m : * Manager ) {

 Thread . lock ( * m . mutex ) ;
m . api . progress , m . api . draining_progress = m . api . draining_progress , m . api . progress ;
Thread . unlock ( * m . mutex ) ;
for update : m . api . draining_progress {

 s := table_get ( * m . scenes , update . ticket . handle ) ;
if s == null || ! s . local . busy || s . local . ticket != update . ticket || ! s . local . desired {
continue ;
}

 emit_progress ( m , update . ticket , update . value ) ;

 }

 array_reset_keeping_memory ( * m . api . draining_progress ) ;

 }

 //@endregion


//@region Placement, queries and interest-driven automatic requests

 peer_scope :: ( s : * Scene , c : transport . Connection_Id ) -> bool {
return in_scope ( s , c ) || table_get ( * s . remotes , c ) . scope_override ;
}

 // Explicit placement is allowed outside the scope.

 // Scope remains an automatic placement rule, not an entitlement validator.

 request_placement :: ( m : * Manager , h : Handle , c : transport . Connection_Id , retry : bool = false ) -> bool {

 s := table_get ( * m . scenes , h ) ;
if ! m . initialized || m . stopping || m . config . role != . Server || s == null || s . phase != . Open || table_get ( * m . peers , c ) == 0 || table_get ( * m . api . local_peers , c ) {
return false ;
}

 r := table_get ( * s . remotes , c ) ;
if r . failure_latched && ! retry {
return false ;
}

 if r . state != . Absent && ! ( retry && r . state == . Load_Failed ) {
return false ;
}

 if ! start_remote ( m , s , h , c , . Load ) {
return false ;
}

 r = table_get ( * s . remotes , c ) ;
r . scope_override = ! in_scope ( s , c ) ;
H . table_set ( * s . remotes , c , r ) ;
return true ;

 }

 request_placements :: ( m : * Manager , h : Handle , connections : [ ] transport . Connection_Id ) -> ( count : int ) {

 for c : connections {
if request_placement ( m , h , c ) {
count += 1 ;
}

 } ;
return ;

 }

 clear_load_failure :: ( m : * Manager , h : Handle , c : transport . Connection_Id ) -> bool {

 s := table_get ( * m . scenes , h ) ;
if ! m . initialized || m . config . role != . Server || s == null || table_get ( * m . peers , c ) == 0 {
return false ;
}

 r , exists := table_get ( * s . remotes , c ) ;
if ! exists || ( ! r . failure_latched && r . state != . Load_Failed ) {
return false ;
}

 r . failure_latched = false ;
if r . state == . Load_Failed {
r . state = . Absent ;
}

 H . table_set ( * s . remotes , c , r ) ;
return true ;

 }

 load_outstanding :: ( m : * Manager , h : Handle , c : transport . Connection_Id ) -> bool {

 s := table_get ( * m . scenes , h ) ;
if s == null || s . phase != . Open || table_get ( * m . peers , c ) == 0 {
return false ;
}

 r := table_get ( * s . remotes , c ) ;
return r . state == . Loading && ! r . failure_latched && ( m . now - r . began < m . config . timeout_ms ) ;

 }

 connection_holds_scene :: ( m : * Manager , h : Handle , c : transport . Connection_Id ) -> bool {

 if ! m . initialized || m . config . role != . Server || table_get ( * m . peers , c ) == 0 {
return false ;
}

 if h == 0 {
return true ;
}

 s := table_get ( * m . scenes , h ) ;
return s != null && table_get ( * s . remotes , c ) . held ;

 }

 collect_connections_in_scene :: ( m : * Manager , h : Handle , dst : * [ .. ] transport . Connection_Id ) {

 if dst == null {
return ;
}

 for _ , c : m . peers {
if connection_holds_scene ( m , h , c ) {
array_add ( dst , c ) ;
}

 }


}

 is_closed_handle :: ( m : * Manager , h : Handle ) -> bool {
return m . config . role == . Server && h != 0 && ( cast , trunc ( u32 ) ( h ) ) < m . next_handle && table_get ( * m . scenes , h ) == null ;
}

 // Existing is_loaded is the normal interest path, including opt-in blocked-spawn

 // requests. For the narrowly scoped dynamic controlled-object carry exception,

 // use this object-aware gate in the runtime's object visibility predicate.

 spawn_allowed :: ( m : * Manager , obj : * objects . Network_Object , c : transport . Connection_Id ) -> bool {

 if obj == null || ! obj . active {
return false ;
}

 if obj . scene == 0 || table_get ( * m . api . local_peers , c ) {
return table_get ( * m . peers , c ) != 0 ;
}

 h := ( cast ( Handle ) ( obj . scene ) ) ;
if carried_for ( m , obj , c ) {
return true ;
}

 return is_loaded ( m , h , c ) ;

 }

 carried_for :: ( m : * Manager , obj : * objects . Network_Object , c : transport . Connection_Id ) -> bool {

 p := m . config . carry_policy ;
if p == null || obj == null || ! obj . active || ! load_outstanding ( m , ( cast ( Handle ) ( obj . scene ) ) , c ) {
return false ;
}

 meta , registered := table_get ( * p . metadata , obj . id ) ;
// Explicit metadata opt-in distinguishes dynamic carry eligibility from scene

 // asset-bound objects; absent metadata never guesses that an object is dynamic.

 if ! registered || ! meta . eligible {
return false ;
}

 if obj . owner == c {
return true ;
}

 if meta . group != 0 {

 for member , id : p . registry . objects {
if member != null && member . active && table_get ( * p . metadata , id ) . group == meta . group && member . owner == c {
return true ;
}

 }


}

 return false ;

 }

 request_carried_scene :: ( m : * Manager , id : objects . Network_Id ) -> ( requested : int ) {

 p := m . config . carry_policy ;
if p == null || m . config . role != . Server {
return 0 ;
}

 obj , ok := objects . get ( p . registry , id ) ;
if ! ok {
return 0 ;
}

 meta , registered := table_get ( * p . metadata , id ) ;
if ! registered || ! meta . eligible {
return 0 ;
}

 seen := new_table ( transport . Connection_Id , bool ) ;
defer release ( seen ) ;
for member , mid : p . registry . objects {

 if member == null || ! member . active || ( mid != id && ( meta . group == 0 || table_get ( * p . metadata , mid ) . group != meta . group ) ) {
continue ;
}

 c := member . owner ;
if c == 0 || table_get ( * seen , c ) {
continue ;
} ;
H . table_set ( * seen , c , true ) ;
if request_placement ( m , ( cast ( Handle ) ( obj . scene ) ) , c ) {
requested += 1 ;
}


}

 return ;

 }

 //@endregion


//@region Unexpected authority physical unload recovery

 // The caller reports content ALREADY gone, not a request to release it. No second

 // engine unload and no invented remote ACK. Objects despawn before peer records

 // are forgotten; the next replication snapshot carries their real removal.

 notify_unloaded_unexpectedly :: ( m : * Manager , h : Handle , registry : * objects . Registry = null ) -> bool {

 s := table_get ( * m . scenes , h ) ;
if ! m . initialized || m . config . role != . Server || s == null || s . phase == . Waiting {
return false ;
}

 if registry != null && ! registry . authoritative {
return false ;
}

 if s . local . busy {
return false ;
}
// drain/cancel the producer before forgetting its storage

 if m . config . loader != null && ! loader_external_unload ( m . config . loader , m , h ) {
return false ;
}

 for a , source : m . scenes {
if a . replacement == h || source == h {
if a . replacement != 0 {
abort_replace ( m , source ) ;
}

 }

 }

 notify ( m , . Before_Unload , h ) ; // existing typed binding tears down actual registry objects here

 reg := registry ;
if reg == null && m . config . carry_policy != null {
reg = m . config . carry_policy . registry ;
}

 if reg != null {
for obj , id : reg . objects {
if obj != null && obj . active && obj . scene == ( cast , trunc ( u32 ) ( h ) ) {
objects . despawn ( reg , id ) ;
}

 }

 }

 left := new_dynamic ( transport . Connection_Id , 0 ) ;
defer release ( left ) ;
for r , c : s . remotes {
if r . held {
array_add ( * left , c ) ;
}

 }

 array_reset_keeping_memory ( * s . remotes ) ;
s . local . held , s . local . desired = false , false ;
s . phase = . Closing ;
for c : left {
observe ( m , .{ . State_Changed , c , h , s . asset , false , 0
} ) ;
}

 notify ( m , . Unexpected_Unload , h ) ;
notify ( m , . Closed , h ) ;
free_scene ( m , h , s ) ;
return true ;

 }

 //@endregion


//@region Optional late typed policy binding

 bind_carry_policy :: ( m : * Manager , p : * Carry_Policy ) -> bool {

 if ! m . initialized || m . config . role != . Server || p == null || p . registry == null || ( p . manager != null && p . manager != m ) {
return false ;
}

 { old := m . config . carry_policy ; if
old != null && old != p {
return false ;
} }

 m . config . carry_policy = p ;
p . manager = m ;
return true ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted.  

 // Cast semantics adapted. 
