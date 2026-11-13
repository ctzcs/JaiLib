#scope_file
objects :: #import "thirdparty/onet/objects" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export


//@region Typed carry selection and compensating transactions

 Carry_Selection :: enum {
Controlled ; Registered ; All ;
}

 Carry_Failure_Action :: enum {
Release_Controller ; Retain ; Despawn ;
}

 Carry_Object :: struct {
eligible : bool ;
group : u64 ;
has_failure_override : bool ;
failure : Carry_Failure_Action ;
}

 Carry_Config :: struct {

 selection : Carry_Selection ;

 failure : Carry_Failure_Action ;

 max_objects , max_transactions : int ;

 userdata : * void ;

 select_object : #type ( * void , * objects . Network_Object , Handle , Handle ) -> bool ;

 resolve_failure : #type ( * void , transport . Connection_Id , * objects . Network_Object , Handle , Carry_Failure_Action ) -> Carry_Failure_Action ;


}

 Carry_Transaction :: struct {
target : Handle ;
ids : [ .. ] objects . Network_Id ;
}

 Carry_Policy :: struct {

 registry : * objects . Registry ;

 config : Carry_Config ;

 metadata : H . Table ( objects . Network_Id , Carry_Object ) ;

 transactions : H . Table ( Handle , * Carry_Transaction ) ;

 manager : * Manager ;
// optional stable manager for ordinary carried-object placement

 resolvers : [ .. ] Carry_Resolver ;

 resolver_changes : [ .. ] Carry_Resolver_Change ;

 resolving : bool ;


}

 carry_init :: ( p : * Carry_Policy , reg : * objects . Registry , config : Carry_Config ) -> bool {

 if reg == null || ! reg . authoritative || p . registry != null {
return false ;
}

 p . registry , p . config = reg , config ;
if p . config . max_objects <= 0 {
p . config . max_objects = 4096 ;
}

 if p . config . max_transactions <= 0 {
p . config . max_transactions = 64 ;
}

 p . metadata = new_table ( objects . Network_Id , Carry_Object ) ;
p . transactions = new_table ( Handle , * Carry_Transaction ) ;
return true ;

 }

 carry_register :: ( p : * Carry_Policy , id : objects . Network_Id , metadata : Carry_Object ) -> bool {

 if p . registry == null {
return false ;
}

 { _ , ok := objects . get ( p . registry , id ) ; if
! ok {
return false ;
} }

 { _ , ok := table_get ( * p . metadata , id ) ; if
! ok && ( p . metadata ) . count >= p . config . max_objects {
return false ;
} }

 H . table_set ( * p . metadata , id , metadata ) ;
return true ;

 }

 carry_unregister :: ( p : * Carry_Policy , id : objects . Network_Id ) {
H . table_remove ( * p . metadata , id ) ;
}

 carry_selected :: ( p : * Carry_Policy , obj : * objects . Network_Object , old , target : Handle ) -> bool {

 meta , registered := table_get ( * p . metadata , obj . id ) ;
if registered && ! meta . eligible {
return false ;
}

 selected := false ;
if p . config . selection == {

 case . Controlled ; selected = obj . owner != objects . SERVER_OWNED ;
case . Registered ; selected = registered && meta . eligible ;
case . All ; selected = true ;

 }

 if selected && p . config . select_object != null {
selected = p . config . select_object ( p . config . userdata , obj , old , target ) ;
}

 return selected ;

 }

 carry_begin :: ( p : * Carry_Policy , old , target : Handle ) -> bool {

 if p . registry == null || old == 0 || target == 0 || old == target || ( p . transactions ) . count >= p . config . max_transactions {
return false ;
}

 { tx := table_get ( * p . transactions , old ) ; if
tx != null {
return tx . target == target ;
} }

 ids := new_dynamic ( objects . Network_Id , 0 ) ;
defer release ( ids ) ;
groups := new_table ( u64 , bool ) ;
defer release ( groups ) ;
for obj , id : p . registry . objects {

 if obj == null || ! obj . active || obj . scene != ( cast , trunc ( u32 ) ( old ) ) || ! carry_selected ( p , obj , old , target ) {
continue ;
}

 array_add ( * ids , id ) ;
{ group := table_get ( * p . metadata , id ) . group ; if
group != 0 {
H . table_set ( * groups , group , true ) ;
} }


}

 // A group is one engine object: selection expands to every live member.

 for obj , id : p . registry . objects {

 if obj == null || ! obj . active || ! table_get ( * groups , table_get ( * p . metadata , id ) . group ) {
continue ;
}

 if obj . scene != ( cast , trunc ( u32 ) ( old ) ) {
return false ;
}
// reject cross-scene groups atomically

 found := false ;
for selected : ids {
if id == selected {
found = true ;
break ;
}

 }

 if ! found {
array_add ( * ids , id ) ;
}


}

 if ( ids ) . count > p . config . max_objects {
return false ;
}

 // No mutation until selection, group and budget validation all succeed.

 tx := new_one ( Carry_Transaction ) ;
tx . target = target ;
for id : ids {
obj , _ := objects . get ( p . registry , id ) ;
obj . scene = ( cast , trunc ( u32 ) ( target ) ) ;
array_add ( * tx . ids , id ) ;
}

 if p . manager != null {
for id : ids {
request_carried_scene ( p . manager , id ) ;
}

 }

 H . table_set ( * p . transactions , old , tx ) ;
return true ;

 }

 carry_finish :: ( p : * Carry_Policy , old : Handle , commit : bool ) {

 tx := table_get ( * p . transactions , old ) ;
if tx == null {
return ;
}

 if ! commit {

 for id : tx . ids {

 { obj , ok := objects . get ( p . registry , id ) ; if
ok && obj . scene == ( cast , trunc ( u32 ) ( tx . target ) ) {
obj . scene = ( cast , trunc ( u32 ) ( old ) ) ;
} }


}


}

 release ( tx . ids ) ;
free ( tx ) ;
H . table_remove ( * p . transactions , old ) ;

 }

 carry_apply_failure :: ( p : * Carry_Policy , connection : transport . Connection_Id , scene : Handle ) -> int {

 if p . registry == null || connection == 0 {
return 0 ;
}

 ids := new_dynamic ( objects . Network_Id , 0 ) ;
defer release ( ids ) ;
for obj , id : p . registry . objects {

 if obj != null && obj . active && obj . scene == ( cast , trunc ( u32 ) ( scene ) ) && obj . owner == connection {
array_add ( * ids , id ) ;
}


}

 affected := 0 ;
for id : ids {

 obj , ok := objects . get ( p . registry , id ) ;
if ! ok {
continue ;
}

 action := p . config . failure ;
meta := table_get ( * p . metadata , id ) ;
if meta . has_failure_override {
action = meta . failure ;
}

 { cb := p . config . resolve_failure ; if
cb != null {
action = cb ( p . config . userdata , connection , obj , scene , action ) ;
} }

 action = resolve_carry_failure ( p , connection , obj , scene , action ) ;
if action == . Retain {
continue ;
}

 group := meta . group ;
members := new_dynamic ( objects . Network_Id , 0 ) ;
for member , mid : p . registry . objects {

 if member != null && member . active && ( mid == id || ( group != 0 && table_get ( * p . metadata , mid ) . group == group ) ) {
array_add ( * members , mid ) ;
}


}

 for mid : members {

 member , exists := objects . get ( p . registry , mid ) ;
if ! exists {
continue ;
}

 if action == . Despawn {
if objects . despawn ( p . registry , mid ) {
affected += 1 ;
}


} else if member . owner == connection {
if objects . set_controller ( p . registry , mid , objects . SERVER_OWNED ) {
affected += 1 ;
}

 }


}

 release ( members ) ;

 }

 return affected ;

 }

 carry_destroy :: ( p : * Carry_Policy ) {

 for _ , old : p . transactions {
carry_finish ( p , old , false ) ;
}

 if p . manager != null && p . manager . config . carry_policy == p {
p . manager . config . carry_policy = null ;
}

 release ( p . transactions ) ;
release ( p . metadata ) ;
release ( p . resolvers ) ;
release ( p . resolver_changes ) ;
p .* = .{

 } ;


}

 //@endregion


//@region Stable explicit binding, also usable without Runtime

 Carry_Binding :: struct {

 policy : Carry_Policy ;
callbacks : Config ;
initialized : bool ;

 rollback_userdata : * void ;

 on_rollback : #type ( * void , Handle , Handle , [ ] objects . Network_Id ) ;
// after restoration, borrowed frozen IDs


}

 carry_binding_init :: ( b : * Carry_Binding , reg : * objects . Registry , callbacks : Config , config : Carry_Config ) -> bool {

 if b . initialized || ! carry_init ( * b . policy , reg , config ) {
return false ;
}

 b . callbacks = callbacks ;
b . initialized = true ;
return true ;

 }

 carry_binding_config :: ( b : * Carry_Binding ) -> Config {

 assert ( b . initialized ) ;
c := b . callbacks ;
c . userdata = b ;
if c . send != null {
c . send = carry_binding_send ;
}

 if c . request != null {
c . request = carry_binding_request ;
}

 if c . validate_load != null {
c . validate_load = carry_binding_validate ;
}

 if c . ready_to_unload != null {
c . ready_to_unload = carry_binding_ready ;
}

 c . carry = carry_binding_begin ;
c . event = carry_binding_event ;
c . carry_policy = * b . policy ;
return c ;

 }

 carry_binding_send :: ( user : * void , to : transport . Connection_Id , payload : [ ] u8 ) -> bool {
b := ( cast ( * Carry_Binding ) user ) ;
return b . callbacks . send ( b . callbacks . userdata , to , payload ) ;
}

 carry_binding_request :: ( user : * void , t : Ticket ) {
b := ( cast ( * Carry_Binding ) user ) ;
b . callbacks . request ( b . callbacks . userdata , t ) ;
}

 carry_binding_validate :: ( user : * void , h : Handle , a : Asset_Id , c : transport . Connection_Id ) -> bool {
b := ( cast ( * Carry_Binding ) user ) ;
return b . callbacks . validate_load ( b . callbacks . userdata , h , a , c ) ;
}

 carry_binding_ready :: ( user : * void , old , target : Handle , c : transport . Connection_Id ) -> bool {
b := ( cast ( * Carry_Binding ) user ) ;
return b . callbacks . ready_to_unload ( b . callbacks . userdata , old , target , c ) ;
}

 carry_binding_begin :: ( user : * void , old , target : Handle ) -> bool {

 b := ( cast ( * Carry_Binding ) user ) ;
// Typed selection replaces a legacy arbitrary mover; never run two migrations.

 return carry_begin ( * b . policy , old , target ) ;

 }

 carry_binding_event :: ( user : * void , e : Event ) {

 b := ( cast ( * Carry_Binding ) user ) ;
if e . kind == {

 case . Replace_Committed ; carry_finish ( * b . policy , e . handle , true ) ;
case . Replace_Failed ;
{ tx := table_get ( * b . policy . transactions , e . handle ) ; if
tx != null && b . on_rollback != null {

 ids := new_slice ( objects . Network_Id , ( tx . ids ) . count ) ;
copy_samples ( ids , view ( tx . ids , 0 ) ) ;
target := tx . target ;
carry_finish ( * b . policy , e . handle , false ) ;
b . on_rollback ( b . rollback_userdata , e . handle , target , ids ) ;
release ( ids ) ;

 } else {
carry_finish ( * b . policy , e . handle , false ) ;
} }

 case . Load_Failed , . Timeout ;
if e . connection != 0 {
carry_apply_failure ( * b . policy , e . connection , e . handle ) ;
}

 case . Before_Unload ;
// Anything not selected for migration belongs to the scene being released.

 for obj , id : b . policy . registry . objects {
if obj != null && obj . active && obj . scene == ( cast , trunc ( u32 ) ( e . handle ) ) {
objects . despawn ( b . policy . registry , id ) ;
}

 }


}

 { cb := b . callbacks . event ; if
cb != null {
cb ( b . callbacks . userdata , e ) ;
} }


}

 carry_binding_destroy :: ( b : * Carry_Binding ) {
carry_destroy ( * b . policy ) ;
b .* = .{

 } ;

 }

 //@endregion


//@region Ordered carry failure resolver registrations

 Carry_Resolver_Proc :: ( * void , transport . Connection_Id , * objects . Network_Object , Handle , Carry_Failure_Action ) -> ( Carry_Failure_Action , bool ) ;
Carry_Resolver :: struct {
id : Registration_Id ;
callback : Carry_Resolver_Proc ;
userdata : * void ;
}

 Carry_Resolver_Change :: struct {
resolver : Carry_Resolver ;
remove_flag : bool ;
}

 carry_resolver_change :: ( p : * Carry_Policy , r : Carry_Resolver , remove_flag : bool ) -> bool {

 if p . registry == null || r . id == 0 {
return false ;
}

 found := false ;
for existing : p . resolvers {
if existing . id == r . id {
found = true ;
}

 }

 for op : p . resolver_changes {
if op . resolver . id == r . id {
found = ! op . remove_flag ;
}

 }

 if found != remove_flag {
return false ;
}

 if p . resolving {

 if ( p . resolver_changes ) . count >= MAX_CALLBACKS || ( ! remove_flag && ( p . resolvers ) . count + ( p . resolver_changes ) . count >= MAX_CALLBACKS ) {
return false ;
}

 array_add ( * p . resolver_changes , .{
r , remove_flag
} ) ;
return true ;

 } ;

 if remove_flag {
for existing , i : p . resolvers {
if existing . id == r . id {
array_ordered_remove_by_index ( * p . resolvers , i ) ;
return true ;
}

 } ;
return false ;
}

 if ( p . resolvers ) . count >= MAX_CALLBACKS {
return false ;
}

 array_add ( * p . resolvers , r ) ;
return true ;

 }

 register_carry_resolver :: ( p : * Carry_Policy , id : Registration_Id , callback : Carry_Resolver_Proc , userdata : * void = null ) -> bool {

 if callback == null {
return false ;
} ;
return carry_resolver_change ( p , .{
id , callback , userdata
} , false ) ;

 } ;

 unregister_carry_resolver :: ( p : * Carry_Policy , id : Registration_Id ) -> bool {
return carry_resolver_change ( p , .{
id = id
} , true ) ;
} ;

 resolve_carry_failure :: ( p : * Carry_Policy , c : transport . Connection_Id , obj : * objects . Network_Object , h : Handle , initial : Carry_Failure_Action ) -> Carry_Failure_Action {

 assert ( ! p . resolving ) ;
p . resolving = true ;
action := initial ;
for r : p . resolvers {

 next , ok := r . callback ( r . userdata , c , obj , h , action ) ;
if ! ok {
break ;
} ;
action = next ;

 }

 p . resolving = false ;
for op : p . resolver_changes {

 if op . remove_flag {
for r , i : p . resolvers {
if r . id == op . resolver . id {
array_ordered_remove_by_index ( * p . resolvers , i ) ;
break ;
}

 }


} else {
array_add ( * p . resolvers , op . resolver ) ;
}


}

 array_reset_keeping_memory ( * p . resolver_changes ) ;
return action ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted.  

 // Cast semantics adapted. 
