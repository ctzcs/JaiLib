#scope_file
phy :: #import "thirdparty/onet/physics" ;
sim :: #import "thirdparty/onet/simulation" ;
#scope_export
// Test-only free-flight/sphere-plane reference. The integration oracle uses its

 // own math, never physics.project_* or convergence to compute solver results.



 //@region Reference body and borrowed whole-world solver

 Native_Body :: struct {

 state : phy . Snapshot ;

 gravity : sim . Vec3 ;

 drag , mass : float64 ;

 force : sim . Vec3 ;

 last_mode : phy . Apply_Mode ;

 steps : u64 ;


}

 native_body_init :: ( b : * Native_Body , mass : float64 = 1 ) {

 b .* = .{
state = .{
tick = 1 , rotation = .[
0 , 0 , 0 , 1 ,
] , flags = (phy.Body_Flags.Captured | phy.Body_Flags.Velocity) ,

 } , gravity = .[
0 , - 9.81 , 0 ,
] , mass = max ( mass , 1e-12 ) ,
} ;


} ;

 native_adapter :: ( b : * Native_Body ) -> phy . Adapter {

 return .{
body = .{
user = b , capture = native_capture , apply = native_apply ,
} , properties = native_properties , add_force = native_add_force ,
} ;


} ;

 native_capture :: ( user : * void ) -> phy . Snapshot {
return ( ( cast ( * Native_Body ) user ) ) . state ;
}

 native_properties :: ( user : * void ) -> phy . Body_Properties {

 b := ( cast ( * Native_Body ) user ) ;
return .{
b . gravity , b . drag , b . mass , phy.has_flag( b . state . flags , . Kinematic ) ,
} ;


}

 native_apply :: ( user : * void , s : phy . Snapshot , mode : phy . Apply_Mode ) {

 b := ( cast ( * Native_Body ) user ) ;
local_kinematic := phy.has_flag( b . state . flags , . Kinematic ) ;
b . state , b . last_mode = s , mode ;
if mode != . Kinematic {

 b . state . flags &= ~ ( phy.Body_Flags. Kinematic ) ;
if local_kinematic {
b . state . flags |= ( phy.Body_Flags. Kinematic ) ;
}


}


}

 native_add_force :: ( user : * void , force : sim . Vec3 ) {

 b := ( cast ( * Native_Body ) user ) ;
if phy.has_flag( b . state . flags , . Kinematic ) {
return ;
}

 for v : force {
if ! sim . finite ( v ) {
return ;
}

 }

 b . force += force ;
if force != ( float64.[0,0,0] ) {
b . state . flags &= ~ ( phy.Body_Flags. Sleeping ) ;
}


} ;

 native_simulate :: ( user : * void , dt : float64 ) {

 b := ( cast ( * Native_Body ) user ) ;
if ! sim . finite ( dt ) || dt <= 0 {
return ;
}

 if ! phy.has_flag( b . state . flags , . Kinematic ) && ! phy.has_flag( b . state . flags , . Sleeping ) {

 b . state . linear_velocity = ( b . state . linear_velocity + ( b . gravity + b . force / b . mass ) * dt ) * max ( cast(float64)0 , 1 - max ( b . drag , 0 ) * dt ) ;
b . state . position += b . state . linear_velocity * dt ;
// Independent world-space quaternion increment, not the library projector.

 w := b . state . angular_velocity ;
speed := Math . sqrt ( w [ 0 ] * w [ 0 ] + w [ 1 ] * w [ 1 ] + w [ 2 ] * w [ 2 ] ) ;
if speed > 0 {

 half := speed * dt * 0.5 ;
v := w * ( Math . sin ( half ) / speed ) ;
c := Math . cos ( half ) ;
q := b . state . rotation ;
r := float64.[c * q [ 0 ] + v [ 0 ] * q [ 3 ] + v [ 1 ] * q [ 2 ] - v [ 2 ] * q [ 1 ] ,
c * q [ 1 ] - v [ 0 ] * q [ 2 ] + v [ 1 ] * q [ 3 ] + v [ 2 ] * q [ 0 ] ,
c * q [ 2 ] + v [ 0 ] * q [ 1 ] - v [ 1 ] * q [ 0 ] + v [ 2 ] * q [ 3 ] ,
c * q [ 3 ] - v [ 0 ] * q [ 0 ] - v [ 1 ] * q [ 1 ] - v [ 2 ] * q [ 2 ] ] ;

 length := Math . sqrt ( r [ 0 ] * r [ 0 ] + r [ 1 ] * r [ 1 ] + r [ 2 ] * r [ 2 ] + r [ 3 ] * r [ 3 ] ) ;
b . state . rotation = r / length ;

 }


}

 b . force = .{

 } ;
b . steps += 1 ;
b . state . time += dt ;

 } ;

 World :: struct {
active : [ .. ] * Native_Body ;
steps : u64 ;
}

 world_adapter :: ( w : * World ) -> phy . World_Adapter {

 return .{
user = w , step = world_step , set_enabled = world_set_enabled ,
} ;


}

 world_set_enabled :: ( user : * void , body : phy . Body , enabled : bool ) {

 w := ( cast ( * World ) user ) ;
b := ( cast ( * Native_Body ) body . user ) ;
// Disable uses only the opaque address, including after runtime despawn.

 for existing , i : w . active {

 if existing != b {
continue ;
}

 if ! enabled {

 { j := i ; while j < ( w . active ) . count - 1 { defer j += 1 ;
w . active [ j ] = w . active [ j + 1 ] ;
} }

 array_resize ( * w . active , ( w . active ) . count - 1 ) ;

 }

 return ;

 }

 if enabled {
array_add ( * w . active , b ) ;
}


}

 world_step :: ( user : * void , dt : float64 ) {

 w := ( cast ( * World ) user ) ;
w . steps += 1 ;
for b : w . active {
native_simulate ( b , dt ) ;
}


}

 world_destroy :: ( w : * World ) {
release ( w . active ) ;
w .* = .{

 } ;

 }

 //@endregion


//@region Sphere-plane reference sweep

 Plane :: struct {
normal : sim . Vec3 ;
offset : float64 ;
}

 Plane_Sweep :: struct {
planes : [ ] Plane ;
radius : float64 ;
}

 plane_sweep :: ( user : * void , body : phy . Body , from , to : sim . Vec3 ) -> ( phy . Sweep_Hit , bool ) {

 world := ( cast ( * Plane_Sweep ) user ) ;
earliest := ( cast ( float64 ) ( 2 ) ) ;
normal : sim . Vec3 ;
for plane : world . planes {

 length := sim . vec3_length ( plane . normal ) ;
if length <= 1e-12 {
continue ;
}

 n := plane . normal / length ;
boundary := plane . offset / length + max ( world . radius , 0 ) ;
a , b := dot3 ( from , n ) - boundary , dot3 ( to , n ) - boundary ;
fraction := ( cast ( float64 ) ( 2 ) ) ;
if a < 0 {
fraction = 0 ;
} else if b < 0 && a - b > 1e-12 {
fraction = a / ( a - b ) ;
}

 if fraction < earliest {
earliest , normal = fraction , n ;
}


}

 if earliest > 1 {
return .{

 } , false ;
} ;

 return .{
from + ( to - from ) * earliest , normal ,
} , true ;

 } ;


dot3 :: ( a , b : sim . Vec3 ) -> float64 {
return a [ 0 ] * b [ 0 ] + a [ 1 ] * b [ 1 ] + a [ 2 ] * b [ 2 ] ;
}

 //@endregion


//@region Presentation-only body fixture

 Test_Body :: struct {
state : phy . Snapshot ;
last_mode : phy . Apply_Mode ;
applies : int ;
}

 test_capture :: ( user : * void ) -> phy . Snapshot {
return ( ( cast ( * Test_Body ) user ) ) . state ;
}

 test_apply :: ( user : * void , state : phy . Snapshot , mode : phy . Apply_Mode ) {

 b := ( cast ( * Test_Body ) user ) ;
b . state , b . last_mode = state , mode ;
b . applies += 1 ;

 }

 test_adapter :: ( b : * Test_Body ) -> phy . Body {
return .{
user = b , capture = test_capture , apply = test_apply ,
} ;

 }

 test_state :: ( tick : u64 , time , x : float64 ) -> phy . Snapshot {

 return .{
tick = tick , time = time , position = .[
x , 0 , 0 ,
] , rotation = .[
0 , 0 , 0 , 1 ,
] , flags = (phy.Body_Flags.Captured) ,

 } ;


} ;

 wall_sweep :: ( user : * void , from , to : sim . Vec3 ) -> ( sim . Vec3 , bool ) {

 result := to ;
result [ 0 ] = min ( result [ 0 ] , 1.0 ) ;
return result , true ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.     
