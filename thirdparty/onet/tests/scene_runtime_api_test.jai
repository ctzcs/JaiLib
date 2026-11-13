#scope_file
objects :: #import "thirdparty/onet/objects" ;
nr :: #import "thirdparty/onet/runtime" ;
scenes :: #import "thirdparty/onet/scenes" ;
session :: #import "thirdparty/onet/session" ;
#scope_export


//@region 真实Session中的blocked-spawn请求与对象感知carry gate


scene_runtime_blocked_spawn_requests_and_dynamic_carry_gate :: ( t : * Test ) {

 s , a : RT_Node ;
rt_init ( * s , true ) ;
rt_init ( * a , false ) ;
defer rt_shutdown ( ( * RT_Node ) .[ * s , * a ] ) ;
binding : nr . Scene_Policy_Binding ;
assert ( nr . scene_policies_bind ( * binding , * s . r . server , .{
selection = . Registered
} ) ) ;
defer assert ( nr . scene_policies_unbind ( * binding ) ) ;
s . r . server . scenes . config . automatic_request_on_blocked_spawn = true ;
h , ok := scenes . open ( * s . r . server . scenes , 77 , .{
kind = . Connections
} , false ) ;
assert ( ok ) ;
carried := rt_spawn ( * s , 3 ) ;
carried . scene = ( cast , trunc ( u32 ) ( h ) ) ;
asset_bound := rt_spawn ( * s , 5 ) ;
asset_bound . scene = ( cast , trunc ( u32 ) ( h ) ) ;
assert ( scenes . carry_register ( * binding . carry . policy , carried . id , .{
eligible = true
} ) ) ;
assert ( session . start_server ( * s . s , 0 ) && session . start_client ( * a . s , "127.0.0.1" , session . bound_port ( * s . s ) ) ) ;
nodes := ( * RT_Node ) .[ * s , * a ] ;
rt_pump ( nodes , 20 ) ;
assert ( a . s . client_authenticated && objects . set_controller ( * s . reg , carried . id , a . s . client_server_id ) ) ;
rt_pump ( nodes , 30 ) ;
expect ( t , a . requests == 1 && a . ticket . operation == . Load && ! scenes . is_loaded ( * s . r . server . scenes , h , a . s . client_server_id ) ) ;
_ , has_dynamic := objects . get ( * a . reg , carried . id ) ;
_ , has_static := objects . get ( * a . reg , asset_bound . id ) ;
expect ( t , has_dynamic && ! has_static , "only explicitly dynamic carried controller bypasses pending load gate" ) ;
assert ( scenes . complete_load ( * a . r . client . scenes , a . ticket , true ) ) ;
rt_pump ( nodes , 60 ) ;
_ , has_static = objects . get ( * a . reg , asset_bound . id ) ;
expect ( t , has_static && scenes . is_loaded ( * s . r . server . scenes , h , a . s . client_server_id ) ) ;
assert ( scenes . close ( * s . r . server . scenes , h ) ) ;
rt_pump ( nodes , 60 ) ;
expect ( t , ( s . r . server . scenes . scenes ) . count == 0 && ( a . r . client . scenes . scenes ) . count == 0 ) ;

 } ;

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
