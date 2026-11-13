#scope_file
simulation :: #import "thirdparty/onet/simulation" ;
#scope_export
// Engine-neutral remote-body synchronization, NOT a physics engine. The adapter

 // owns the real body; the follower owns only snapshot history. No Divine/spawn

 // compensation or engine-specific solver, force, or collision integration.



 //@region Body snapshots and explicit wire representation


Body_Flag :: enum u8 {
Sleeping = 0 ; Kinematic = 1 ; Velocity = 2 ; Captured = 4 ;
}

 Body_Flags :: enum_flags u8 {
Sleeping = 1 ; Kinematic = 2 ; Velocity = 4 ; Captured = 16 ;
}

 Snapshot :: struct {

 tick : simulation . Tick ;

 time : float64 ;

 position : simulation . Vec3 ;

 rotation : simulation . Quat ;

 linear_velocity , angular_velocity : simulation . Vec3 ;

 flags : Body_Flags ;


}

 Apply_Mode :: enum {
Adopt ; Smooth ; Teleport ; Sleep ; Kinematic ;
}

 Body :: struct {

 user : * void ;

 capture : #type ( user : * void ) -> Snapshot ;

 apply : #type ( user : * void , state : Snapshot , mode : Apply_Mode ) ;


}

 SNAPSHOT_SIZE :: 128 ;

 finite :: ( v : float64 ) -> bool {
return simulation . finite ( v ) ;
}


snapshot_valid :: ( s : Snapshot ) -> bool {

 if s . tick == 0 || ! finite ( s . time ) || ! has_flag ( s . flags , . Captured ) || ( bit_cast ( u8 , s . flags ) & ~ ( cast , trunc ( u8 ) ( 0x17 ) ) ) != 0 {
return false ;
}

 for v : s . position {
if ! finite ( v ) {
return false ;
}

 }

 for v : s . rotation {
if ! finite ( v ) {
return false ;
}

 }

 for v : s . linear_velocity {
if ! finite ( v ) {
return false ;
}

 }

 for v : s . angular_velocity {
if ! finite ( v ) {
return false ;
}

 }

 return s . rotation != float64 .[ 0 , 0 , 0 , 0 ] ;


}


body_capture :: ( body : Body , tick : simulation . Tick , time : float64 ) -> ( Snapshot , bool ) {

 if body . capture == null {
return .{

 } , false ;
} ;

 s := body . capture ( body . user ) ;
s . tick , s . time = tick , time ;
s . flags |= ( Body_Flags . Captured ) ;
if ! snapshot_valid ( s ) {
return .{

 } , false ;
} ;

 s . rotation = simulation . quat_normalize ( s . rotation ) ;
return s , true ;

 }


body_apply :: ( body : Body , state : Snapshot , mode : Apply_Mode ) -> bool {

 if body . apply == null || ! snapshot_valid ( state ) {
return false ;
}

 s := state ;
s . rotation = simulation . quat_normalize ( s . rotation ) ;
if has_flag ( s . flags , . Sleeping ) {
s . linear_velocity , s . angular_velocity = .{

 } , .{

 } ;

 } ;

 body . apply ( body . user , s , mode ) ;
return true ;

 }


// v1: version:u8, flags:u8, reserved[6], tick:u64, time:f64,

 // position[3], rotation[x,y,z,w], linear_velocity[3], angular_velocity[3]: all f64 LE.

 // Layout is explicit; NEVER transmit native Snapshot memory/padding.

 snapshot_encode :: ( dst : [ ] u8 , state : Snapshot ) -> simulation . Status {

 if ( dst ) . count != SNAPSHOT_SIZE {
return . Truncated ;
}

 if ! snapshot_valid ( state ) {
return . Invalid_Data ;
}

 s := state ;
s . rotation = simulation . quat_normalize ( s . rotation ) ;
for * v : dst {
v .* = 0 ;
}

 dst [ 0 ] , dst [ 1 ] = 1 , bit_cast ( u8 , s . flags ) ;
put_uint ( view ( dst , 8 , 16 ) , s . tick ) ;
put_float ( view ( dst , 16 , 24 ) , s . time ) ;
offset := 24 ;
for v : s . position {
put_float ( view ( dst , offset , offset + 8 ) , v ) ;
offset += 8 ;
}

 for v : s . rotation {
put_float ( view ( dst , offset , offset + 8 ) , v ) ;
offset += 8 ;
}

 for v : s . linear_velocity {
put_float ( view ( dst , offset , offset + 8 ) , v ) ;
offset += 8 ;
}

 for v : s . angular_velocity {
put_float ( view ( dst , offset , offset + 8 ) , v ) ;
offset += 8 ;
}

 return . Ok ;

 }


snapshot_decode :: ( src : [ ] u8 ) -> ( Snapshot , simulation . Status ) {

 if ( src ) . count != SNAPSHOT_SIZE {
return .{

 } , . Truncated ;
} ;

 if src [ 0 ] != 1 {
return .{

 } , . Invalid_Data ;
} ;

 { i := 2 ; while i < 8 { defer i += 1 ;
if src [ i ] != 0 {
return .{

 } , . Invalid_Data ;
} ;

 } }

 s := Snapshot .{
tick = get_uint ( view ( src , 8 , 16 ) ) , time = get_float ( view ( src , 16 , 24 ) ) , flags = bit_cast ( Body_Flags , src [ 1 ] ) ,
} ;

 offset := 24 ;
for * v : s . position {
v .* = get_float ( view ( src , offset , offset + 8 ) ) ;
offset += 8 ;
}

 for * v : s . rotation {
v .* = get_float ( view ( src , offset , offset + 8 ) ) ;
offset += 8 ;
}

 for * v : s . linear_velocity {
v .* = get_float ( view ( src , offset , offset + 8 ) ) ;
offset += 8 ;
}

 for * v : s . angular_velocity {
v .* = get_float ( view ( src , offset , offset + 8 ) ) ;
offset += 8 ;
}

 if ! snapshot_valid ( s ) {
return .{

 } , . Invalid_Data ;
} ;

 s . rotation = simulation . quat_normalize ( s . rotation ) ;
return s , . Ok ;

 }



 put_uint :: ( dst : [ ] u8 , v : u64 ) {
{ i := 0 ; while i < 8 { defer i += 1 ;
dst [ i ] = ( cast , trunc ( u8 ) ( v >> ( cast , trunc ( u64 ) ( 8 * i ) ) ) ) ;
} }

 }


get_uint :: ( src : [ ] u8 ) -> ( v : u64 ) {
for x , i : src {
v |= ( ( cast , trunc ( u64 ) x ) ) << ( cast , trunc ( u64 ) ( 8 * i ) ) ;
} ;
return ;
}


put_float :: ( dst : [ ] u8 , v : float64 ) {
put_uint ( dst , bit_cast ( u64 , v ) ) ;
}


get_float :: ( src : [ ] u8 ) -> float64 {
return bit_cast ( float64 , get_uint ( src ) ) ;
}

 //@endregion


//@region Remote-body follower


// A sweep provider must sweep the body's full shape, not just raycast its center.

 // false or a non-finite safe_position means blocked: keep from. It is called for

 // extrapolation AND final smoothed motion. Authoritative adopt/teleport are snaps.

 Sweep_Proc :: #type ( user : * void , from , to : simulation . Vec3 ) -> ( safe_position : simulation . Vec3 , valid : bool ) ;
Settings :: struct {

 capacity : int ;

 max_age , max_extrapolation : float64 ;

 position_rate , rotation_rate , teleport_distance : float64 ;

 estimate_velocity , use_gravity : bool ;

 gravity : simulation . Vec3 ;


}

 Follower :: struct {

 body : Body ;

 settings : Settings ;

 buffer : simulation . Buffer ;

 latest : Snapshot ;

 has_received_state , teleported : bool ;

 sweep : Sweep_Proc ;

 sweep_user : * void ;


}


settings_default :: ( ) -> Settings {

 return .{
capacity = 32 , max_age = 2 , max_extrapolation = 0.15 ,
position_rate = 15 , rotation_rate = 15 , teleport_distance = 5 ,
estimate_velocity = true , gravity = .[
0 , - 9.81 , 0 ,
] ,

 } ;


}


follower_init :: ( f : * Follower , body : Body , settings : Settings , sweep : Sweep_Proc = null , sweep_user : * void = null ) -> simulation . Status {

 if ( f . buffer . samples ) . count != 0 || body . capture == null || body . apply == null ||
! finite ( settings . position_rate ) || settings . position_rate < 0 ||
! finite ( settings . rotation_rate ) || settings . rotation_rate < 0 ||
! finite ( settings . teleport_distance ) || settings . teleport_distance < 0 {
return . Invalid_Config ;
}

 for v : settings . gravity {
if ! finite ( v ) {
return . Invalid_Config ;
}

 }

 config := simulation . Buffer_Config .{
capacity = settings . capacity , value_size = SNAPSHOT_SIZE ,
max_age = settings . max_age , max_extrapolation = settings . max_extrapolation ,
} ;

 status := simulation . buffer_init ( * f . buffer , config , blend_snapshots ) ;
if status != . Ok {
return status ;
}

 f . body , f . settings , f . sweep , f . sweep_user = body , settings , sweep , sweep_user ;
return . Ok ;

 }


follower_destroy :: ( f : * Follower ) {
simulation . buffer_destroy ( * f . buffer ) ;
f .* = .{

 } ;

 }


// Reconnect/respawn must explicitly reset the timeline; no stale packet can do so.

 follower_reset :: ( f : * Follower ) {

 simulation . buffer_clear ( * f . buffer ) ;
f . latest , f . has_received_state , f . teleported = .{

 } , false , false ;

 } ;


follower_receive :: ( f : * Follower , state : Snapshot ) -> simulation . Status {

 if ( f . buffer . samples ) . count == 0 {
return . Not_Ready ;
}

 if ! snapshot_valid ( state ) {
return . Invalid_Data ;
}

 s := state ;
s . rotation = simulation . quat_normalize ( s . rotation ) ;
if ! has_flag ( s . flags , . Velocity ) {
s . linear_velocity , s . angular_velocity = .{

 } , .{

 } ;

 } ;

 if f . has_received_state {

 if s . tick == f . latest . tick {
return . Duplicate ;
}

 if s . tick < f . latest . tick || s . time <= f . latest . time {
return . Stale ;
}

 span := s . time - f . latest . time ;
if ! finite ( span ) {
return . Invalid_Data ;
}

 if f . settings . estimate_velocity && ! has_flag ( s . flags , . Velocity ) && span <= f . settings . max_age {

 s . linear_velocity = ( s . position - f . latest . position ) / span ;
// Shortest-arc world angular velocity from successive orientations.

 q := simulation . quat_multiply ( s . rotation , .[
- f . latest . rotation [ 0 ] , - f . latest . rotation [ 1 ] , - f . latest . rotation [ 2 ] , f . latest . rotation [ 3 ]
] ) ;
if q [ 3 ] < 0 {
for * component : q component .* = - component .* ;
}

 axis := float64 .[
q [ 0 ] , q [ 1 ] , q [ 2 ] ,
] ;

 length := simulation . vec3_length ( axis ) ;
if length > 1.0e-10 {
s . angular_velocity = axis * ( 2 * Math . atan2 ( length , q [ 3 ] ) / ( length * span ) ) ;
}

 s . flags |= ( Body_Flags . Velocity ) ;

 } ;


}

 if has_flag ( s . flags , . Sleeping ) {
s . linear_velocity , s . angular_velocity = .{

 } , .{

 } ;

 } ;

 if ! snapshot_valid ( s ) {
return . Invalid_Data ;
}

 bytes : [ SNAPSHOT_SIZE ] u8 ;
snapshot_encode ( view ( bytes , 0 ) , s ) ;
status := simulation . buffer_push ( * f . buffer , s . tick , s . time , view ( bytes , 0 ) ) ;
if status != . Ok {
return status ;
}

 if ! f . has_received_state {

 // Never smooth the first real state from an invented origin/default pose.

 body_apply ( f . body , s , . Adopt ) ;

 }

 f . latest , f . has_received_state = s , true ;
return . Ok ;

 }


// time is the desired authority-timeline render/physics time (caller may subtract

 // interpolation delay). dt is local elapsed time for exponential pose convergence.

 // Kinematic and sleeping targets are applied exactly, with no gravity/extrapolation.

 follower_step :: ( f : * Follower , time , dt : float64 ) -> simulation . Status {

 f . teleported = false ;
if ! f . has_received_state {
return . Not_Ready ;
}

 if ! finite ( time ) || ! finite ( dt ) || dt < 0 {
return . Invalid_Data ;
}

 if time - f . latest . time > f . settings . max_age {
return . Expired ;
}

 target := f . latest ;
if time <= f . latest . time {

 bytes : [ SNAPSHOT_SIZE ] u8 ;
_ , status := simulation . buffer_sample ( * f . buffer , time , view ( bytes , 0 ) ) ;
if status != . Ok {
return status ;
}

 target , status = snapshot_decode ( view ( bytes , 0 ) ) ;
if status != . Ok {
return status ;
}


} else if ! has_flag ( target . flags , . Sleeping ) && ! has_flag ( target . flags , . Kinematic ) {

 ahead := clamp ( time - target . time , 0 , f . settings . max_extrapolation ) ;
target . position += target . linear_velocity * ahead ;
if f . settings . use_gravity {

 target . position += f . settings . gravity * ( 0.5 * ahead * ahead ) ;
target . linear_velocity += f . settings . gravity * ahead ;

 }

 speed := simulation . vec3_length ( target . angular_velocity ) ;
if speed > 1.0e-10 && finite ( speed ) {

 half := speed * ahead * 0.5 ;
axis := target . angular_velocity * ( Math . sin ( half ) / speed ) ;
target . rotation = simulation . quat_normalize ( simulation . quat_multiply ( .[
axis [ 0 ] , axis [ 1 ] , axis [ 2 ] , Math . cos ( half )
] , target . rotation ) ) ;

 } ;

 target . position = swept_position ( f , f . latest . position , target . position ) ;

 }

 if ! snapshot_valid ( target ) {
return . Invalid_Data ;
}

 current := f . body . capture ( f . body . user ) ;
// The body's local metadata may be unset; only its pose is needed here.

 current . tick , current . time = target . tick , target . time ;
current . flags |= ( Body_Flags . Captured ) ;
if ! snapshot_valid ( current ) {
return . Invalid_Data ;
}

 distance := simulation . vec3_length ( target . position - current . position ) ;
mode : Apply_Mode = . Smooth ;
if f . settings . teleport_distance > 0 && distance > f . settings . teleport_distance {

 mode , f . teleported = . Teleport , true ;

 } else if has_flag ( target . flags , . Sleeping ) {

 mode = . Sleep ;

 } else if has_flag ( target . flags , . Kinematic ) {

 mode = . Kinematic ;

 } else {

 target . position = simulation . lerp_vec3 ( current . position , target . position , 1 - Math . exp ( - f . settings . position_rate * dt ) ) ;
target . rotation = simulation . quat_slerp ( current . rotation , target . rotation , 1 - Math . exp ( - f . settings . rotation_rate * dt ) ) ;
target . position = swept_position ( f , current . position , target . position ) ;

 }

 if ! body_apply ( f . body , target , mode ) {
return . Invalid_Data ;
}

 return . Ok ;

 }



 swept_position :: ( f : * Follower , from , to : simulation . Vec3 ) -> simulation . Vec3 {

 if f . sweep == null {
return to ;
}

 safe , ok := f . sweep ( f . sweep_user , from , to ) ;
if ! ok {
return from ;
}

 for v : safe {
if ! finite ( v ) {
return from ;
}

 }

 return safe ;

 }



 blend_snapshots :: ( user : * void , a , b : [ ] u8 , t : float64 , dst : [ ] u8 ) {

 x , xs := snapshot_decode ( a ) ;
y , ys := snapshot_decode ( b ) ;
assert ( xs == . Ok && ys == . Ok ) ;
z := y ;
z . position = simulation . lerp_vec3 ( x . position , y . position , t ) ;
z . rotation = simulation . quat_slerp ( x . rotation , y . rotation , t ) ;
z . linear_velocity = simulation . lerp_vec3 ( x . linear_velocity , y . linear_velocity , t ) ;
z . angular_velocity = simulation . lerp_vec3 ( x . angular_velocity , y . angular_velocity , t ) ;
z . time = simulation . lerp_scalar ( x . time , y . time , t ) ;
if t < 1 {
z . flags = x . flags ;
}

 snapshot_encode ( dst , z ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted.
has_flag :: ( flags : Body_Flags , flag : Body_Flags ) -> bool { return ( flags & flag ) != 0 ; }


// Cast semantics adapted. 
