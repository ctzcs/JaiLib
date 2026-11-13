#scope_file
ref :: #import "thirdparty/onet/tests/support/reference_physics" ;
#scope_file
phy :: #import "thirdparty/onet/physics" ;
sim :: #import "thirdparty/onet/simulation" ;
#scope_export


//@region Projector numeric parity against discrete simulation, not continuous gravity

 parity_vec :: ( t : * Test , a , b : sim . Vec3 , epsilon : float64 = 1.0e-9 ) {
expect ( t , sim . vec3_length ( a - b ) < epsilon ) ;
}

 parity_state :: ( ) -> phy . Snapshot {
return .{
tick = 1 , time = 1 , rotation = .[
0 , 0 , 0 , 1 ,
] , flags = (phy.Body_Flags.Captured | phy.Body_Flags.Velocity) ,

 } ;

 }


physics_discrete_projector_matches_stepped_gravity_drag_rotation :: ( t : * Test ) {

 drags: []float64 = float64.[ 0 , - 1 , 0.3 , 4 , 50 ] ;
for drag : drags {

 b : ref . Native_Body ;
ref . native_body_init ( * b ) ;
b . state . position = .[
1 , 2 , 3 ,
] ;
b . state . linear_velocity = .[
2 , 5 , - 1 ,
] ;
b . state . angular_velocity = .[
0 , 1.7 , 0 ,
] ;
b . drag = drag ;
initial := b . state ;
dt := ( cast ( float64 ) ( 0.02 ) ) ;
n := 20 ;
{ loop_index := 0 ; while loop_index < n { defer loop_index += 1 ;
ref . native_simulate ( * b , dt ) ;
} } ;

 projected := phy . project_snapshot ( initial , dt , ( cast ( float64 ) ( n ) ) , b . gravity , drag , . Apply ) ;
parity_vec ( t , b . state . position , projected . position ) ;
parity_vec ( t , b . state . linear_velocity , projected . linear_velocity ) ;
expect ( t , sim . vec3_length ( phy . extract_rotation_vector ( b . state . rotation , projected . rotation ) ) < 1.0e-9 ) ;

 } ;

 p := phy . project_position ( 0.1 , 1 , .{

 } , .{

 } , .[
0 , - 10 , 0
] , 0 ) ;
parity_vec ( t , p , .[
0 , - 0.1 , 0
] ) ; // Euler gravity-first, NOT continuous -0.05

 fractional := phy . project_position ( 0.1 , 0.5 , .{

 } , .{

 } , .[
0 , - 10 , 0
] , 0 ) ;
parity_vec ( t , fractional , .[
0 , - 0.0375 , 0
] ) ;
parity_vec ( t , phy . project_velocity ( 0.1 , 0 , .[
1 , 2 , 3
] , .[
0 , - 10 , 0
] , 10 ) , .[
1 , 2 , 3
] ) ;
parity_vec ( t , phy . project_velocity ( 0.1 , 0.5 , .[
1 , 2 , 3
] , .[
0 , - 10 , 0
] , 10 ) , .{

 } ) ;

 } ;


physics_gravity_auto_sleep_and_shortest_arc_rotation :: ( t : * Test ) {

 s := parity_state ( ) ;
s . linear_velocity = .[
1 , - 0.25 , 0 ,
] ;

 parity_vec ( t , phy . resolve_gravity ( s , .[
0 , - 10 , 0
] , . Auto ) , .{

 } ) ;
s . linear_velocity [ 1 ] = - 0.251 ;
parity_vec ( t , phy . resolve_gravity ( s , .[
0 , - 10 , 0
] , . Auto ) , .[
0 , - 10 , 0
] ) ;
parity_vec ( t , phy . resolve_gravity ( s , .[
0 , - 10 , 0
] , . None ) , .{

 } ) ;
s . flags |= ( phy.Body_Flags. Sleeping ) ;
s . angular_velocity = .[
0 , 2 , 0 ,
] ;

 projected := phy . project_snapshot ( s , 0.02 , 10 , .[
0 , - 10 , 0
] , 1 , . Apply ) ;
expect_value ( t , projected , s ) ;
q := phy . project_rotation ( 0.1 , 1 , .[
0 , 0 , 0 , 1
] , .[
0 , Math . PI , 0
] ) ;
parity_vec ( t , phy . extract_rotation_vector ( .[
0 , 0 , 0 , 1
] , q ) , .[
0 , Math . PI * 0.1 , 0
] ) ;
parity_vec ( t , phy . extract_rotation_vector ( .[
0 , 0 , 0 , 1
] , (q * -1.0) ) , .[
0 , Math . PI * 0.1 , 0
] ) ;

 } ;

 //@endregion


//@region Convergence modes, deadbands, kinematic and prediction


physics_free_position_and_velocity_convergence_modes :: ( t : * Test ) {

 modes: []phy.Blend_Mode = phy.Blend_Mode.[ . Position , . Velocity ] ;
for mode : modes {

 b : ref . Native_Body ;
ref . native_body_init ( * b ) ;
b . gravity = .{

 } ;

 c := phy . convergence_default ( ) ;
c . settings . blend_mode = mode ;
c . settings . teleport_distance = 0 ;
c . settings . blend_per_tick = 0.25 ;
s := parity_state ( ) ;
s . position = .[
2 , 0 , 0 ,
] ;
s . linear_velocity = .[
1 , 0 , 0 ,
] ;
s . rotation = phy . project_rotation ( 1 , 1 , s . rotation , .[
0 , 0 , Math . PI / 2
] ) ;
expect_value ( t , phy . convergence_step ( * c , ref . native_adapter ( * b ) , s , 0.1 , 0 ) , . Ok ) ;
if mode == . Position {
parity_vec ( t , b . state . position , .[
0.5 , 0 , 0
] ) ;
parity_vec ( t , b . state . linear_velocity , .[
1 , 0 , 0
] ) ;

 } else {
parity_vec ( t , b . state . position , .{

 } ) ;
parity_vec ( t , b . state . linear_velocity , .[
6 , 0 , 0
] ) ;
parity_vec ( t , b . state . angular_velocity , .[
0 , 0 , Math . PI * 1.25
] ) ;
} ;

 parity_vec ( t , c . target_error , .[
2 , 0 , 0
] ) ;
expect ( t , ! c . teleported ) ;

 } ;


} ;


physics_residual_close_uses_preexisting_body_speed_and_thresholds :: ( t : * Test ) {

 b : ref . Native_Body ;
ref . native_body_init ( * b ) ;
b . gravity = .{

 } ;

 c := phy . convergence_default ( ) ;
s := parity_state ( ) ;
s . position = .[
0.05 , 0 , 0 ,
] ;
s . linear_velocity = .[
2 , 0 , 0 ,
] ;

 expect_value ( t , phy . convergence_step ( * c , ref . native_adapter ( * b ) , s , 0.02 , 0 ) , . Ok ) ;
parity_vec ( t , b . state . position , .{

 } ) ;
parity_vec ( t , b . state . linear_velocity , .[
2.025 , 0 , 0
] ) ;
b . state . linear_velocity = .[
1 , 0 , 0 ,
] ;

 expect_value ( t , phy . convergence_step ( * c , ref . native_adapter ( * b ) , s , 0.02 , 0 ) , . Ok ) ;
parity_vec ( t , b . state . linear_velocity , .[
2 , 0 , 0
] ) ;

 } ;


physics_prediction_never_teleports_and_local_kinematic_is_untouched :: ( t : * Test ) {

 b : ref . Native_Body ;
ref . native_body_init ( * b ) ;
b . gravity = .{

 } ;

 c := phy . convergence_default ( ) ;
c . locally_predicted = true ;
s := parity_state ( ) ;
s . position = .[
100 , 0 , 0 ,
] ;
s . linear_velocity = .[
2 , 0 , 0 ,
] ;

 expect_value ( t , phy . convergence_step ( * c , ref . native_adapter ( * b ) , s , 0.1 , 50 ) , . Ok ) ;
parity_vec ( t , b . state . position , .{

 } ) ;
parity_vec ( t , c . target_error , .[
102 , 0 , 0
] ) ; // wider one-second prediction cap

 parity_vec ( t , b . state . linear_velocity , .[
104 , 0 , 0
] ) ;
expect ( t , ! c . teleported ) ;
c . locally_predicted = false ;
expect_value ( t , phy . convergence_step ( * c , ref . native_adapter ( * b ) , s , 0.1 , 50 ) , . Ok ) ;
parity_vec ( t , b . state . position , .[
100.4 , 0 , 0
] ) ;
expect ( t , c . teleported ) ;
b . state . flags |= ( phy.Body_Flags. Kinematic ) ;
saved := b . state ;
s . position = .[
999 , 0 , 0 ,
] ;

 expect_value ( t , phy . convergence_step ( * c , ref . native_adapter ( * b ) , s , 0.1 , 0 ) , . Ok ) ;
expect_value ( t , b . state , saved ) ;
expect ( t , ! c . teleported ) ;
phy . convergence_reset ( * c ) ;
expect ( t , ! c . locally_predicted && ! c . teleported && c . target_error == ( float64.[0,0,0] ) ) ;

 } ;


physics_sweep_clamps_and_optional_reflection_changes_velocity :: ( t : * Test ) {

 b : ref . Native_Body ;
ref . native_body_init ( * b ) ;
planes: []ref.Plane = ref.Plane.[ .{
normal = .[
0 , 1 , 0
] , offset = 0
, } ] ;
world := ref . Plane_Sweep .{
planes = planes , radius = 0.25 ,
} ;

 provider := phy . swept_target_default ( ) ;
provider . sweep = ref . plane_sweep ;
provider . user = * world ;
s := parity_state ( ) ;
s . position = .[
0 , 1 , 0 ,
] ;
s . linear_velocity = .[
2 , - 10 , 0 ,
] ;

 target , ok := phy . swept_project ( provider , ref . native_adapter ( * b ) . body , s , 0.1 , 2 , .{

 } , 0 , . None ) ;
expect ( t , ok ) ;
parity_vec ( t , target . position , .[
0.15 , 0.25 , 0
] ) ;
parity_vec ( t , target . linear_velocity , .[
2 , - 10 , 0
] ) ;
provider . reflect = true ;
provider . restitution = 0.6 ;
target , ok = phy . swept_project ( provider , ref . native_adapter ( * b ) . body , s , 0.1 , 2 , .{

 } , 0 , . None ) ;
expect ( t , ok ) ;
parity_vec ( t , target . linear_velocity , .[
1.2 , 6 , 0
] ) ;
c := phy . convergence_default ( ) ;
c . provider = * provider ;
b . state . position = .[
0 , 1 , 0 ,
] ;
b . gravity = .{

 } ;

 c . settings . blend_per_tick = 1 ;
expect_value ( t , phy . convergence_step ( * c , ref . native_adapter ( * b ) , s , 0.1 , 2 ) , . Ok ) ;
parity_vec ( t , b . state . position , target . position ) ;
parity_vec ( t , b . state . linear_velocity , target . linear_velocity ) ;

 } ;

 //@endregion


//@region Concrete automatic body registration, pose-only receive/adopt/sleep/wake


physics_pose_component_derives_velocity_and_preserves_quiet_capture_tick :: ( t : * Test ) {

 b : ref . Native_Body ;
ref . native_body_init ( * b ) ;
component : phy . Motion_Component ;
expect_value ( t , phy . motion_capture ( * component , ref . native_adapter ( * b ) . body , 1 , 1 ) , . Ok ) ;
expect_value ( t , component . capture_tick , (cast(sim . Tick )( 1 )) ) ;
expect_value ( t , phy . motion_capture ( * component , ref . native_adapter ( * b ) . body , 2 , 1.1 ) , . Ok ) ;
expect_value ( t , component . capture_tick , (cast(sim . Tick )( 1 )) ) ;
b . state . position = .[
2 , 0 , 0 ,
] ;
phy . motion_capture ( * component , ref . native_adapter ( * b ) . body , 3 , 1.2 ) ;
expect_value ( t , component . capture_tick , (cast(sim . Tick )( 3 )) ) ;
remote : phy . Motion_Component ;
a := parity_state ( ) ;
z := a ;
z . tick = 3 ;
z . time = 1.2 ;
z . position = .[
2 , 0 , 0 ,
] ;
z . rotation = phy . project_rotation ( 0.1 , 2 , a . rotation , .[
0 , 1 , 0
] ) ;
expect_value ( t , phy . motion_receive ( * remote , a , 0.1 ) , . Ok ) ;
expect_value ( t , phy . motion_receive ( * remote , z , 0.1 ) , . Ok ) ;
parity_vec ( t , remote . state . linear_velocity , .[
10 , 0 , 0
] ) ;
parity_vec ( t , remote . state . angular_velocity , .[
0 , 1 , 0
] ) ;
packet : [ phy . MOTION_SIZE ] u8 ;
expect_value ( t , phy . motion_encode ( view ( packet , 0 ) , z ) , . Ok ) ;
decoded , status := phy . motion_decode ( view ( packet , 0 ) ) ;
expect_value ( t , status , . Ok ) ;
expect ( t , ! phy.has_flag( decoded . flags , . Velocity ) && decoded . position == z . position ) ;
expect_value ( t , phy . motion_receive ( * remote , z , 0.1 ) , . Duplicate ) ;
phy . motion_reset ( * remote ) ;
expect ( t , ! remote . has_state && ! remote . adopted ) ;

 } ;


physics_body_system_automatically_simulates_captures_adopts_sleeps_wakes :: ( t : * Test ) {

 world : ref . World ;
defer ref . world_destroy ( * world ) ;
adapter := ref . world_adapter ( * world ) ;
system : phy . Body_System ;
expect ( t , phy . body_system_init ( * system , * adapter ) ) ;
defer phy . body_system_destroy ( * system ) ;
a , b : ref . Native_Body ;
ref . native_body_init ( * a , 2 ) ;
ref . native_body_init ( * b ) ;
a . gravity , b . gravity = .{

 } , .{

 } ;

 authority := phy . Body_Binding .{
adapter = ref . native_adapter ( * a ) , authority = true , convergence = phy . convergence_default ( ) ,
} ;

 proxy := phy . Body_Binding .{
adapter = ref . native_adapter ( * b ) , convergence = phy . convergence_default ( ) ,
} ;

 expect ( t , phy . body_system_register ( * system , 1 , * authority ) ) ;
expect ( t , phy . body_system_register ( * system , 2 , * proxy ) ) ;
expect ( t , ! phy . body_system_register ( * system , 3 , * proxy ) ) ;
ref . native_add_force ( * a , .[
4 , 0 , 0
] ) ;
expect_value ( t , phy . body_system_step ( * system , 1 , 1 , 0.1 ) , . Ok ) ;
parity_vec ( t , a . state . position , .[
0.02 , 0 , 0
] ) ;
expect_value ( t , a . steps , ( cast , trunc ( u64 ) ( 1 ) ) ) ;
expect_value ( t , b . steps , ( cast , trunc ( u64 ) ( 0 ) ) ) ;
packet : [ phy . MOTION_SIZE ] u8 ;
phy . motion_encode ( view ( packet , 0 ) , authority . component . state ) ;
expect_value ( t , phy . body_system_receive ( * system , 2 , view ( packet , 0 ) , 0.1 ) , . Ok ) ;
expect_value ( t , phy . body_system_step ( * system , 2 , 1.1 , 0.1 ) , . Ok ) ;
expect ( t , proxy . component . adopted && b . last_mode == . Adopt ) ;
parity_vec ( t , b . state . position , .[
0.02 , 0 , 0
] ) ;
s := parity_state ( ) ;
s . tick = 3 ;
s . time = 1.2 ;
s . position = .[
4 , 0 , 0 ,
] ;
s . flags |= ( phy.Body_Flags. Sleeping ) ;
phy . motion_encode ( view ( packet , 0 ) , s ) ;
expect_value ( t , phy . body_system_receive ( * system , 2 , view ( packet , 0 ) , 0.1 ) , . Ok ) ;
phy . body_system_step ( * system , 3 , 1.2 , 0.1 ) ;
expect ( t , phy.has_flag( b . state . flags , . Sleeping ) && b . last_mode == . Sleep ) ;
parity_vec ( t , b . state . position , .[
4 , 0 , 0
] ) ;
s . tick = 4 ;
s . time = 1.3 ;
s . flags &= ~ ( phy.Body_Flags. Sleeping ) ;
s . position = .[
4.2 , 0 , 0 ,
] ;

 phy . motion_encode ( view ( packet , 0 ) , s ) ;
phy . body_system_receive ( * system , 2 , view ( packet , 0 ) , 0.1 ) ;
phy . body_system_step ( * system , 4 , 1.3 , 0.1 ) ;
expect ( t , ! phy.has_flag( b . state . flags , . Sleeping ) && b . last_mode == . Smooth ) ;
expect ( t , b . state . position [ 0 ] > 4 ) ;
phy . body_system_unregister ( * system , 2 ) ;
expect_value ( t , ( system . bindings ) . count , 1 ) ;

 } ;

 //@endregion


//@region Driver edge cases and wire-quiet authority capture


physics_system_rejects_duplicate_ticks_and_suppresses_quiet_capture :: ( t : * Test ) {

 body : ref . Native_Body ;
ref . native_body_init ( * body ) ;
body . gravity = .{

 } ;

 count := 0 ;
binding := phy . Body_Binding .{
adapter = ref . native_adapter ( * body ) , authority = true , convergence = phy . convergence_default ( ) , userdata = * count ,
on_capture = ( user : * void , id : u64 , s : phy . Snapshot ) {
( ( cast ( * int ) user ) ) .* += 1 ;
}

 } ;

 world : ref . World ;
defer ref . world_destroy ( * world ) ;
adapter := ref . world_adapter ( * world ) ;
system : phy . Body_System ;
expect ( t , phy . body_system_init ( * system , * adapter ) ) ;
defer phy . body_system_destroy ( * system ) ;
expect ( t , phy . body_system_register ( * system , 1 , * binding ) ) ;
expect_value ( t , phy . body_system_step ( * system , 1 , 1 , 0.02 ) , . Ok ) ;
expect_value ( t , count , 1 ) ;
expect_value ( t , phy . body_system_step ( * system , 1 , 1 , 0.02 ) , . Duplicate ) ;
expect_value ( t , body . steps , ( cast , trunc ( u64 ) ( 1 ) ) ) ;
expect_value ( t , phy . body_system_step ( * system , 2 , 1.02 , 0.02 ) , . Ok ) ;
expect_value ( t , count , 1 ) ;
body . state . flags |= ( phy.Body_Flags. Sleeping ) ;
phy . body_system_step ( * system , 3 , 1.04 , 0.02 ) ;
expect_value ( t , count , 2 ) ;
ref . native_add_force ( * body , .[
1 , 0 , 0
] ) ;
phy . body_system_step ( * system , 4 , 1.06 , 0.02 ) ;
expect_value ( t , count , 3 ) ;
expect ( t , ! phy.has_flag( body . state . flags , . Sleeping ) && body . state . position [ 0 ] > 0 ) ;

 } ;


physics_invalid_rotation_teleports_and_initial_adopt_preserves_local_kinematic :: ( t : * Test ) {

 body : ref . Native_Body ;
ref . native_body_init ( * body ) ;
body . gravity = .{

 } ;

 body . state . rotation [ 0 ] = bit_cast ( float64 , ( cast , trunc ( u64 ) ( 0x7ff8000000000000 ) ) ) ;
c := phy . convergence_default ( ) ;
state := parity_state ( ) ;
state . position = .[
1 , 0 , 0 ,
] ;

 expect_value ( t , phy . convergence_step ( * c , ref . native_adapter ( * body ) , state , 0.02 , 0 ) , . Ok ) ;
expect ( t , c . teleported && body . state . rotation == state . rotation ) ;
body . state . flags |= ( phy.Body_Flags. Kinematic ) ;
component : phy . Motion_Component ;
phy . motion_receive ( * component , state , 0.02 ) ;
expect ( t , phy . motion_adopt ( * component , ref . native_adapter ( * body ) . body ) ) ;
expect ( t , phy.has_flag( body . state . flags , . Kinematic ) ) ;
bad := c ;
bad . settings . blend_per_tick = 2 ;
expect_value ( t , phy . convergence_step ( * bad , ref . native_adapter ( * body ) , state , 0.02 , 0 ) , . Invalid_Config ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
