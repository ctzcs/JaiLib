#scope_file
core :: #import "thirdparty/onet/core" ;
objects :: #import "thirdparty/onet/objects" ;
sim :: #import "thirdparty/onet/simulation" ;
phy :: #import "thirdparty/onet/physics" ;
wire :: #import "thirdparty/onet/wire" ;
#scope_export


//@region 借用物理body与认证对象状态桥

 Body_System :: phy . Body_System ;
Body_Factory :: ( user : * void , obj : * objects . Network_Object ) -> * phy . Body_Binding ;
Body_Factory_Binding :: struct {
user : * void ;
build : Body_Factory ;
}

 // One Session fixed-tick transaction, before serialization; Body_System calls

 // its borrowed World_Adapter.step exactly once, never a per-body solver.

 // Predicted interacting solvers belong ONLY in Simulation_World.callbacks.physics

 // (with capture/restore in predicted Systems). Never give both drivers the same

 // solver world. A capture-only World_Adapter{step=nil} is an explicit alternative.

 bind_physics :: ( w : * World , system : * Body_System ) -> bool {

 if ! w . initialized || w . physics_system != null || system == null || ! system . initialized || system . world . bound_system != system || system . host != null {
return false ;
}

 w . physics_system = system ;
system . host = w ;
return true ;

 }

 register_body_component :: ( w : * World , type_id : objects . Component_Type_Id , build : Body_Factory , user : * void = null ) -> bool {

 if ! w . initialized || type_id == 0 || build == null || table_get ( * w . body_factories , type_id ) . build != null {
return false ;
}

 H . table_set ( * w . body_factories , type_id , .{
user , build ,
} ) ;
return true ;

 } ;

 reset_physics_bodies :: ( w : * World ) {

 if w . physics_system == null {
return ;
}

 for _ , id : w . automatic_bodies {
phy . body_system_unregister ( w . physics_system , ( cast , trunc ( u64 ) ( id ) ) ) ;
}

 array_reset_keeping_memory ( * w . automatic_bodies ) ;

 }

 unbind_physics :: ( w : * World ) {

 reset_physics_bodies ( w ) ;
if w . physics_system != null {
w . physics_system . host = null ;
}

 w . physics_system = null ;

 }

 sync_physics_bodies :: ( w : * World ) {

 s := w . physics_system ;
if s == null {
return ;
}

 for _ , id : w . automatic_bodies {

 { _ , exists := objects . get ( w . registry , id ) ; if
! exists {
phy . body_system_unregister ( s , ( cast , trunc ( u64 ) ( id ) ) ) ;
H . table_remove ( * w . automatic_bodies , id ) ;
} }


}

 for obj , id : w . registry . objects {

 if obj == null || ! obj . active || table_get ( * w . automatic_bodies , id ) {
continue ;
}

 for comp : obj . components {

 f := table_get ( * w . body_factories , comp . type_id ) ;
if f . build == null {
continue ;
}

 b := f . build ( f . user , obj ) ;
if b != null {
b . authority = w . authority ;
if phy . body_system_register ( s , ( cast , trunc ( u64 ) ( id ) ) , b ) {
H . table_set ( * w . automatic_bodies , id , true ) ;
}

 }

 break ;

 }


}


}

 step_physics_bodies :: ( w : * World ) {

 if w . physics_system == null {
return ;
}

 // The runtime hook may be reached again for an already handled Session tick;

 // do not create/remove_flag bodies or step the borrowed solver twice.

 if w . runtime . session . tick <= w . physics_system . last_tick {
return ;
}

 sync_physics_bodies ( w ) ;
s := w . runtime . session ;
dt := ( cast ( float64 ) ( s . tick_interval_ms ) ) / 1000 ;
now := ( cast ( float64 ) ( s . tick ) ) * dt ;
if ! w . authority {

 { tick , status := sim . clock_estimate_tick ( * w . state_clock , ( cast ( float64 ) ( s . clock_ms ) ) ) ; if
status == . Ok {
now = ( cast ( float64 ) ( tick ) ) * dt ;
} }


}

 now = max ( now , w . physics_system . last_time ) ;
phy . body_system_step ( w . physics_system , s . tick , now , dt ) ;

 }

 // Bind ^Body_Binding using member_custom in the component factory. Reads change

 // only the motion buffer: engine callbacks run later in the fixed body loop,

 // never in snapshot prevalidation or a temporary factory instance.

 body_codec :: ( schema : u32 ) -> objects . Value_Codec {

 assert ( schema != 0 ) ;
return .{
schema = schema , write = body_write , read = body_read ,
} ;


}

 body_write :: ( w : * core . Writer , p : * void ) {

 b := ( cast ( * phy . Body_Binding ) p ) ;
core . write_boolean ( w , b . component . has_state ) ;
if ! b . component . has_state {
return ;
}

 data : [ phy . MOTION_SIZE ] u8 ;
if phy . motion_encode ( view ( data , 0 ) , b . component . state ) != . Ok {
w . err = . Malformed ;
return ;
}

 wire . write_bytes ( w , view ( data , 0 ) , phy . MOTION_SIZE ) ;

 }

 body_read :: ( r : * core . Reader , p : * void ) -> bool {

 b := ( cast ( * phy . Body_Binding ) p ) ;
has := core . read_boolean ( r ) ;
if r . err != . None {
return false ;
}

 if ! has {
return true ;
}

 data , ok := wire . read_bytes ( r , phy . MOTION_SIZE ) ;
defer release ( data ) ;
if ! ok {
return false ;
}

 state , status := phy . motion_decode ( data ) ;
if status != . Ok {
return false ;
}

 dt := ( cast ( float64 ) ( 1 ) ) / 50 ;
if b . component . has_state && state . tick > b . component . state . tick {
dt = ( state . time - b . component . state . time ) / ( cast ( float64 ) ( state . tick - b . component . state . tick ) ) ;
}

 status = phy . motion_receive ( * b . component , state , dt ) ;
return status == . Ok || status == . Duplicate || status == . Stale ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
