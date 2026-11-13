#scope_file

 #scope_export
// Bounded remote history plus interpolation primitives. Times are seconds on one

 // caller-synchronized timeline; this package does not estimate clock offsets.



 //@region Scalar, vector and quaternion helpers


Vec2 :: [ 2 ] float64 ;
Vec3 :: [ 3 ] float64 ;
Vec4 :: [ 4 ] float64 ;
// Quaternion component order is x,y,z,w (identity = {0,0,0,1}).

 Quat :: [ 4 ] float64 ;

 lerp_scalar :: ( a , b , t : float64 ) -> float64 {
return a + ( b - a ) * t ;
}

 lerp_vec2 :: ( a , b : Vec2 , t : float64 ) -> Vec2 {
return a + ( b - a ) * t ;
}

 lerp_vec3 :: ( a , b : Vec3 , t : float64 ) -> Vec3 {
return a + ( b - a ) * t ;
}

 lerp_vec4 :: ( a , b : Vec4 , t : float64 ) -> Vec4 {
return a + ( b - a ) * t ;
}

 vec3_length :: ( v : Vec3 ) -> float64 {
return Math . sqrt ( v [ 0 ] * v [ 0 ] + v [ 1 ] * v [ 1 ] + v [ 2 ] * v [ 2 ] ) ;
}

 quat_dot :: ( a , b : Quat ) -> float64 {
return a [ 0 ] * b [ 0 ] + a [ 1 ] * b [ 1 ] + a [ 2 ] * b [ 2 ] + a [ 3 ] * b [ 3 ] ;
}


quat_normalize :: ( q : Quat ) -> Quat {

 // Scale first to avoid overflow for finite, very large components.

 scale : float64 ;
for x : q {
if ! finite ( x ) {
return .[
0 , 0 , 0 , 1 ,
] ;

 } ;
scale = max ( scale , Math . abs ( x ) ) ;
}

 if scale == 0 {
return .[
0 , 0 , 0 , 1 ,
] ;

 }

 n := q / scale ;
return n / Math . sqrt ( quat_dot ( n , n ) ) ;

 }


// Slerp follows the shortest arc, normalizes inputs AND output, and supports

 // bounded extrapolation when the caller supplies t outside [0,1].

 quat_slerp :: ( a , b : Quat , t : float64 ) -> Quat {

 x , y := quat_normalize ( a ) , quat_normalize ( b ) ;
if ! finite ( t ) {
return x ;
}

 dot := quat_dot ( x , y ) ;
if dot < 0 {
for * component : y component .* = - component .* ;
dot = - dot ;
}

 dot = clamp ( dot , 0 , 1 ) ;
if dot > 0.9995 {
return quat_normalize ( x + ( y - x ) * t ) ;
}

 angle := Math . acos ( dot ) ;
return quat_normalize ( ( x * Math . sin ( ( 1 - t ) * angle ) + y * Math . sin ( t * angle ) ) / Math . sin ( angle ) ) ;

 }


quat_multiply :: ( a , b : Quat ) -> Quat {

 return .[
a [ 3 ] * b [ 0 ] + a [ 0 ] * b [ 3 ] + a [ 1 ] * b [ 2 ] - a [ 2 ] * b [ 1 ] ,
a [ 3 ] * b [ 1 ] - a [ 0 ] * b [ 2 ] + a [ 1 ] * b [ 3 ] + a [ 2 ] * b [ 0 ] ,
a [ 3 ] * b [ 2 ] + a [ 0 ] * b [ 1 ] - a [ 1 ] * b [ 0 ] + a [ 2 ] * b [ 3 ] ,
a [ 3 ] * b [ 3 ] - a [ 0 ] * b [ 0 ] - a [ 1 ] * b [ 1 ] - a [ 2 ] * b [ 2 ] ,
] ;


}

 //@endregion


//@region Remote snapshot buffer


Sample_Mode :: enum {
Held ; Interpolated ; Extrapolated ; Clamped ;
}

 Blend_Proc :: #type ( user : * void , a , b : [ ] u8 , t : float64 , dst : [ ] u8 ) ;
Buffer_Config :: struct {
capacity , value_size : int ;
max_age , max_extrapolation : float64 ;
}

 Remote_Sample :: struct {
tick : Tick ;
time : float64 ;
value : [ ] u8 ;
}

 Buffer :: struct {

 config : Buffer_Config ;

 allocator : Allocator ;

 blend : Blend_Proc ;

 user : * void ;

 samples : [ ] Remote_Sample ;

 storage : [ ] u8 ;

 head , count : int ;


}


buffer_init :: ( b : * Buffer , config : Buffer_Config , blend : Blend_Proc , user : * void = null , allocator := context . allocator ) -> Status {

 if ( b . samples ) . count != 0 || config . capacity < 2 || config . capacity > MAX_HISTORY ||
config . value_size < 1 || config . value_size > MAX_PAYLOAD || config . capacity * config . value_size > MAX_STORAGE ||
! finite ( config . max_age ) || config . max_age <= 0 || ! finite ( config . max_extrapolation ) ||
config . max_extrapolation < 0 || config . max_extrapolation > config . max_age || blend == null {
return . Invalid_Config ;
}

 b .* = Buffer .{
config = config , allocator = allocator , blend = blend , user = user ,
} ;

 b . samples = new_slice ( Remote_Sample , config . capacity , allocator ) ;
b . storage = new_slice ( u8 , config . capacity * config . value_size , allocator ) ;
for * s , i : b . samples {
s .* . value = view ( b . storage , i * config . value_size , ( i + 1 ) * config . value_size ) ;
}

 return . Ok ;

 }


buffer_destroy :: ( b : * Buffer ) {

 if ( b . samples ) . count > 0 {
release ( b . samples , b . allocator ) ;
release ( b . storage , b . allocator ) ;
}

 b .* = .{

 } ;


}


buffer_clear :: ( b : * Buffer ) {
b . head , b . count = 0 , 0 ;
}


// Strictly increasing ticks AND times. Old/reordered packets never rewrite history.

 // Overflow/age eviction is safe for REMOTE interpolation, not prediction replay.

 buffer_push :: ( b : * Buffer , tick : Tick , time : float64 , value : [ ] u8 ) -> Status {

 if ( b . samples ) . count == 0 {
return . Not_Ready ;
}

 if tick == 0 || ! finite ( time ) || ( value ) . count != b . config . value_size {
return . Invalid_Data ;
}

 if b . count > 0 {

 last := * b . samples [ ( b . head + b . count - 1 ) % ( b . samples ) . count ] ;
if tick == last . tick {
return . Duplicate ;
}

 if tick < last . tick || time <= last . time {
return . Stale ;
}

 if ! finite ( time - last . time ) {
return . Invalid_Data ;
}


}

 while b . count > 0 && ( b . count == ( b . samples ) . count || time - b . samples [ b . head ] . time > b . config . max_age ) {

 b . head = ( b . head + 1 ) % ( b . samples ) . count ;
b . count -= 1 ;

 }

 s := * b . samples [ ( b . head + b . count ) % ( b . samples ) . count ] ;
s . tick , s . time = tick , time ;
copy_samples ( s . value , value ) ;
b . count += 1 ;
return . Ok ;

 }


// Before the oldest time: hold oldest, never extrapolate backwards. After newest:

 // extrapolate using the last pair only up to max_extrapolation, then hold that

 // capped result; after max_age seconds without fresh data return Expired instead.

 // dst is caller-owned, must not alias buffer storage. No callback retains slices.

 buffer_sample :: ( b : * Buffer , time : float64 , dst : [ ] u8 ) -> ( Sample_Mode , Status ) {

 if ( b . samples ) . count == 0 {
return . Held , . Not_Ready ;
}

 if b . count == 0 {
return . Held , . Empty ;
}

 if ! finite ( time ) || ( dst ) . count != b . config . value_size {
return . Held , . Invalid_Data ;
}

 first := * b . samples [ b . head ] ;
last := * b . samples [ ( b . head + b . count - 1 ) % ( b . samples ) . count ] ;
if time - last . time > b . config . max_age {
return . Held , . Expired ;
}

 if time <= first . time || b . count == 1 {
copy_samples ( dst , first . value ) ;
return . Held , . Ok ;
}

 { i := 1 ; while i < b . count { defer i += 1 ;

 x := * b . samples [ ( b . head + i - 1 ) % ( b . samples ) . count ] ;
y := * b . samples [ ( b . head + i ) % ( b . samples ) . count ] ;
if time <= y . time {

 b . blend ( b . user , x . value , y . value , clamp ( ( time - x . time ) / ( y . time - x . time ) , 0 , 1 ) , dst ) ;
return . Interpolated , . Ok ;

 }


} }

 prev := * b . samples [ ( b . head + b . count - 2 ) % ( b . samples ) . count ] ;
ahead := min ( max ( ( cast ( float64 ) 0 ) , time - last . time ) , b . config . max_extrapolation ) ;
mode : Sample_Mode = . Extrapolated ;
if time - last . time > b . config . max_extrapolation {
mode = . Clamped ;
}

 if ahead == 0 {
copy_samples ( dst , last . value ) ;
return mode , . Ok ;
}

 t := 1 + ahead / ( last . time - prev . time ) ;
if ! finite ( t ) {
return . Held , . Invalid_Data ;
}

 b . blend ( b . user , prev . value , last . value , t , dst ) ;
return mode , . Ok ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted.   

 // Cast semantics adapted. 
