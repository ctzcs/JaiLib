#scope_file
simulation :: #import "thirdparty/onet/simulation" ;
#scope_export


//@region PhysicsConvergence: position/velocity modes and prediction

 Body_Properties :: struct {
gravity : simulation . Vec3 ;
drag , mass : float64 ;
kinematic : bool ;
}

 Adapter :: struct {

 body : Body ;

 properties : #type ( * void ) -> Body_Properties ;

 add_force : #type ( * void , simulation . Vec3 ) ;


}

 Blend_Mode :: enum {
Position ; Velocity ;
}

 Convergence_Settings :: struct {

 position_threshold , rotation_threshold_degrees , blend_per_tick : float64 ;

 residual_close_rate , residual_close_maximum_speed , teleport_distance , maximum_projection_seconds : float64 ;

 gravity_projection : Gravity_Projection ;

 blend_mode : Blend_Mode ;


}

 Convergence :: struct {

 settings : Convergence_Settings ;

 locally_predicted : bool ;

 prediction_maximum_projection_seconds , prediction_correction_rate : float64 ;

 target_error : simulation . Vec3 ;

 teleported : bool ;

 provider : * Swept_Target ;

 target_user : * void ;

 target_provider : #type ( * void , Adapter , Snapshot , float64 , float64 , Gravity_Projection ) -> ( Snapshot , bool ) ;


}

 convergence_default :: ( ) -> Convergence {

 return .{
settings = .{
position_threshold = 0.1 , rotation_threshold_degrees = 5 , blend_per_tick = 0.1 , residual_close_rate = 0.5 ,
residual_close_maximum_speed = 0.5 , teleport_distance = 4 , maximum_projection_seconds = 0.2 , gravity_projection = . Auto ,
} ,
prediction_maximum_projection_seconds = 1 , prediction_correction_rate = 0.1 ,
} ;


} ;

 convergence_valid :: ( c : * Convergence ) -> bool {

 s := c . settings ;
values := float64 .[ s . position_threshold , s . rotation_threshold_degrees , s . blend_per_tick , s . residual_close_rate , s . residual_close_maximum_speed , s . teleport_distance , s . maximum_projection_seconds , c . prediction_maximum_projection_seconds , c . prediction_correction_rate ] ;
for v : values {

 if ! finite ( v ) || v < 0 {
return false ;
}


}

 return s . blend_per_tick <= 1 && c . prediction_correction_rate <= 1 ;

 }

 convergence_reset :: ( c : * Convergence ) {
c . target_error = .{

 } ;
c . teleported = false ;
c . locally_predicted = false ;
} ;

 convergence_step :: ( c : * Convergence , a : Adapter , remote : Snapshot , dt , ticks : float64 ) -> simulation . Status {

 c . teleported = false ;
if ! convergence_valid ( c ) || a . body . capture == null || a . body . apply == null || a . properties == null {
return . Invalid_Config ;
}

 if ! snapshot_valid ( remote ) || ! finite ( dt ) || dt <= 0 || ! finite ( ticks ) {
return . Invalid_Data ;
}

 properties := a . properties ( a . body . user ) ;
if properties . kinematic {
return . Ok ;
}
// local kinematic body is never steered

 if ! finite ( properties . drag ) {
return . Invalid_Data ;
}

 for v : properties . gravity {
if ! finite ( v ) {
return . Invalid_Data ;
}

 }

 current := a . body . capture ( a . body . user ) ;
body_speed := simulation . vec3_length ( current . linear_velocity ) ;
maximum := ( ifx c . locally_predicted then c . prediction_maximum_projection_seconds else c . settings . maximum_projection_seconds ) ;
ahead := clamp ( ticks , 0 , maximum / dt ) ;
target : Snapshot ;
valid := true ;
if c . target_provider != null {
target , valid = c . target_provider ( c . target_user , a , remote , dt , ahead , c . settings . gravity_projection ) ;

 } else if c . provider != null {
target , valid = swept_project ( c . provider .* , a . body , remote , dt , ahead , properties . gravity , properties . drag , c . settings . gravity_projection ) ;

 } else {
target = project_snapshot ( remote , dt , ahead , properties . gravity , properties . drag , c . settings . gravity_projection ) ;
}

 if ! valid || ! snapshot_valid ( target ) {
return . Invalid_Data ;
}

 result := target ;
result . position , result . rotation = current . position , current . rotation ;
error := target . position - current . position ;
c . target_error = error ;
distance := simulation . vec3_length ( error ) ;
rotation_finite := true ;
for v : current . rotation {
if ! finite ( v ) {
rotation_finite = false ;
}

 }

 if ! c . locally_predicted && c . settings . teleport_distance > 0 && ! ( distance <= c . settings . teleport_distance && rotation_finite ) {

 if body_apply ( a . body , target , . Teleport ) {
c . teleported = true ;
return . Ok ;
} ;
return . Invalid_Data ;

 }

 if ! rotation_finite {
return . Invalid_Data ;
}

 angle := simulation . vec3_length ( extract_rotation_vector ( current . rotation , target . rotation ) ) * 180 / Math . PI ;
if c . locally_predicted {

 if distance > c . settings . position_threshold {
result . linear_velocity += error * ( c . prediction_correction_rate / dt ) ;
}

 if angle > c . settings . rotation_threshold_degrees {
result . angular_velocity += extract_rotation_vector ( current . rotation , target . rotation ) * ( c . prediction_correction_rate / dt ) ;
}


} else {

 if distance > c . settings . position_threshold {

 if c . settings . blend_mode == . Velocity {
result . linear_velocity += error * ( c . settings . blend_per_tick / dt ) ;

 } else {
result . position = simulation . lerp_vec3 ( current . position , target . position , c . settings . blend_per_tick ) ;
}


} else if body_speed < c . settings . residual_close_maximum_speed {
result . linear_velocity += error * c . settings . residual_close_rate ;
}

 if angle > c . settings . rotation_threshold_degrees {

 if c . settings . blend_mode == . Velocity {
result . angular_velocity += extract_rotation_vector ( current . rotation , target . rotation ) * ( c . settings . blend_per_tick / dt ) ;

 } else {
result . rotation = simulation . quat_slerp ( current . rotation , target . rotation , c . settings . blend_per_tick ) ;
}


}


}

 // Convergence does not copy remote kinematic/sleep state onto a dynamic local

 // body. Sleeping targets can still close positional errors via velocity bias.

 result . flags &= ~ ( Body_Flags . Sleeping | Body_Flags . Kinematic ) ;
result . flags |= ( Body_Flags . Captured | Body_Flags . Velocity ) ;
if ! body_apply ( a . body , result , . Smooth ) {
return . Invalid_Data ;
} ;
return . Ok ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
