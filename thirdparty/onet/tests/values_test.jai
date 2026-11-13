#scope_file
core :: #import "thirdparty/onet/core" ;
v :: #import "thirdparty/onet/values" ;
collections :: #import "thirdparty/onet/collections" ;
#scope_export


//@region Value codec tests



 values_scalars :: ( t : * Test ) {

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
c := v . builtin ( s32 ) ;
a := ( cast , trunc ( s32 ) ( - 1234 ) ) ;
expect ( t , v . write ( c , * w , * a ) ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
b , ok := v . read_new ( c , * r ) ;
expect ( t , ok && a == b ) ;
expect ( t , ! v . valid ( v . builtin ( * void ) ) ) ;
binding := v . Binding ( s32 ) .{
c , a ,
} ;

 bridge := v . bridge ( c ) ;
core . writer_reset ( * w ) ;
bridge . write ( * w , * binding ) ;
binding . value = 0 ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , bridge . read ( * r , * binding ) && binding . value == a ) ;
bridge . destroy ( * binding ) ;

 }



 values_owned_and_bounds :: ( t : * Test ) {

 c := v . builtin ( string ) ;
a := "hello 世界" ;
owned := c . clone ( * a ) ;
defer c . destroy ( * owned ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , v . write ( c , * w , * a ) ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
b , ok := v . read_new ( c , * r ) ;
expect ( t , ok && b == a ) ;
c . destroy ( * b ) ;
core . reader_init ( * r , view ( w . buffer , 0 , ( w . buffer ) . count - 1 ) ) ;
expect ( t , ! v . read ( c , * r , * owned ) && owned == a ) ;
core . writer_reset ( * w ) ;
core . write_bits ( * w , v . MAX_BYTES + 1 , 32 ) ;
core . reader_from_writer ( * r , * w ) ;
_ , ok = v . read_new ( c , * r ) ;
expect ( t , ! ok && r . err != . None ) ;

 }


values_expect_roundtrip :: ( t : * Test , input : $T ) {

 a := input ;
codec := v . builtin ( T ) ;
expect ( t , v . valid ( codec ) ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , v . write ( codec , * w , * a ) ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
b , ok := v . read_new ( codec , * r ) ;
expect ( t , ok && codec . equal ( * a , * b ) ) ;
codec . destroy ( * b ) ;

 }



 values_builtin_schema_coverage :: ( t : * Test ) {

 values_expect_roundtrip ( t , true ) ;
values_expect_roundtrip ( t , ( cast , trunc ( u8 ) ( 255 ) ) ) ;
values_expect_roundtrip ( t , ( cast , trunc ( u16 ) ( 65535 ) ) ) ;
values_expect_roundtrip ( t , ( cast , trunc ( u32 ) ( 0xffffffff ) ) ) ;
values_expect_roundtrip ( t , 18446744073709551615 ) ;
values_expect_roundtrip ( t , cast ( s8 ) ( - 128 ) ) ;
values_expect_roundtrip ( t , cast ( s16 ) ( - 32768 ) ) ;
values_expect_roundtrip ( t , cast ( s32 ) ( - 2147483648 ) ) ;
values_expect_roundtrip ( t , cast ( s64 ) ( - 9223372036854775808 ) ) ;
values_expect_roundtrip ( t , ( cast ( float32 ) ( - 1.25 ) ) ) ;
values_expect_roundtrip ( t , ( cast ( float64 ) ( - 1.25 ) ) ) ;
// IEEE payloads, including NaN and signed zero, are preserved exactly.

 values_expect_roundtrip ( t , bit_cast ( float32 , ( cast , trunc ( u32 ) ( 0x7fc12345 ) ) ) ) ;
values_expect_roundtrip ( t , bit_cast ( float64 , ( cast , trunc ( u64 ) ( 0x8000000000000000 ) ) ) ) ;
values_expect_roundtrip ( t , ( cast ( string ) ( "" ) ) ) ;
values_expect_roundtrip ( t , view ( u8 .[ ] , 0 ) ) ;
values_expect_roundtrip ( t , view ( u8 .[ 0 , 1 , 255 ] , 0 ) ) ;
values_expect_roundtrip ( t , cast ( v . Vec2 ) float32 .[
1 , 2
] ) ;
values_expect_roundtrip ( t , cast ( v . Vec3 ) float32 .[
1 , 2 , 3
] ) ;
values_expect_roundtrip ( t , cast ( v . Vec4 ) float32 .[
1 , 2 , 3 , 4
] ) ;
values_expect_roundtrip ( t , cast ( v . Quaternion ) float32 .[
0 , 0 , 0 , 1
] ) ;
values_expect_roundtrip ( t , v . Reference .{
123 , 7
} ) ;
values_expect_roundtrip ( t , v . Reference .{

 } ) ;
// Jai int is an alias of s64, so it uses the explicit 64-bit codec.
expect ( t , v . valid ( v . builtin ( int ) ) && v . builtin ( int ) . schema == v . builtin ( s64 ) . schema ) ;

 } ;


Values_Record :: struct {
name : string ;
payload : [ ] u8 ;
position : v . Vec3 ;
}

 values_record_codec :: ( ) -> v . Codec ( Values_Record ) {

 return .{
65537 ,
( w : * core . Writer , x : * Values_Record ) -> bool {

 return v . write ( v . builtin ( string ) , w , * x . name ) && v . write ( v . builtin ( [ ] u8 ) , w , * x . payload ) && v . write ( v . builtin ( v . Vec3 ) , w , * x . position ) ;

 } ,
( r : * core . Reader , x : * Values_Record ) -> bool {

 return v . read ( v . builtin ( string ) , r , * x . name ) && v . read ( v . builtin ( [ ] u8 ) , r , * x . payload ) && v . read ( v . builtin ( v . Vec3 ) , r , * x . position ) ;

 } ,
( a , b : * Values_Record ) -> bool {

 return a . name == b . name && v . builtin ( [ ] u8 ) . equal ( * a . payload , * b . payload ) && a . position == b . position ;

 } ,
( x : * Values_Record ) -> Values_Record {

 return .{
v . builtin ( string ) . clone ( * x . name ) , v . builtin ( [ ] u8 ) . clone ( * x . payload ) , x . position ,
} ;


} ,
( x : * Values_Record ) {

 v . builtin ( string ) . destroy ( * x . name ) ;
v . builtin ( [ ] u8 ) . destroy ( * x . payload ) ;
x .* = .{

 } ;


} ,

 }


}



 values_custom_owned_struct :: ( t : * Test ) {

 expect ( t , ! v . valid ( v . builtin ( Values_Record ) ) ) ;
codec , registered := v . register ( values_record_codec ( ) ) ;
expect ( t , registered ) ;
wrong := codec ;
wrong . schema = 1 ;
_ , registered = v . register ( wrong ) ;
expect ( t , ! registered ) ;
wrong = codec ;
wrong . clone = null ;
_ , registered = v . register ( wrong ) ;
expect ( t , ! registered ) ;
borrowed := Values_Record .{
"custom" , u8 .[ 1 , 2 , 3 ] , .[ 1 , 2 , 3 ] ,

 } ;

 source := codec . clone ( * borrowed ) ;
defer codec . destroy ( * source ) ;
owned := codec . clone ( * source ) ;
defer codec . destroy ( * owned ) ;
source . payload [ 0 ] = 9 ;
expect ( t , owned . payload [ 0 ] == 1 ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , v . write ( codec , * w , * source ) ) ;
r : core . Reader ;
{ cut := 0 ; while cut < ( w . buffer ) . count { defer cut += 1 ;

 core . reader_init ( * r , view ( w . buffer , 0 , cut ) ) ;
expect ( t , ! v . read ( codec , * r , * owned ) && owned . name == "custom" && owned . payload [ 0 ] == 1 ) ;

 } }

 core . reader_from_writer ( * r , * w ) ;
expect ( t , v . read ( codec , * r , * owned ) && owned . payload [ 0 ] == 9 ) ;
binding := v . Binding ( Values_Record ) .{
codec , codec . clone ( * source ) ,
} ;

 bridge := v . bridge ( codec ) ;
defer bridge . destroy ( * binding ) ;
core . writer_reset ( * w ) ;
bridge . write ( * w , * binding ) ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , bridge . read ( * r , * binding ) && codec . equal ( * binding . value , * source ) ) ;
a , b : collections . Sequence ( Values_Record ) ;
expect ( t , collections . list_init ( * a , codec ) && collections . list_init ( * b , codec ) ) ;
defer collections . destroy ( * a ) ;
defer collections . destroy ( * b ) ;
expect ( t , collections . add ( * a , source ) ) ;
core . writer_reset ( * w ) ;
expect ( t , collections . write_full ( * a , * w ) ) ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , collections . apply_full ( * b , * r ) ) ;
collections . begin_tick ( * a ) ;
source . payload [ 0 ] = 7 ;
expect ( t , collections . set ( * a , 0 , source ) && a . previous [ 0 ] . payload [ 0 ] == 9 ) ;
core . writer_reset ( * w ) ;
expect ( t , collections . write_delta ( * a , * w ) ) ;
{ cut := 0 ; while cut < ( w . buffer ) . count { defer cut += 1 ;

 core . reader_init ( * r , view ( w . buffer , 0 , cut ) ) ;
expect ( t , ! collections . apply_delta ( * b , * r ) && b . items [ 0 ] . payload [ 0 ] == 9 ) ;

 } }

 core . reader_from_writer ( * r , * w ) ;
expect ( t , collections . apply_delta ( * b , * r ) && b . items [ 0 ] . payload [ 0 ] == 7 && b . previous [ 0 ] . payload [ 0 ] == 9 ) ;

 }



 values_registration_and_errors :: ( t : * Test ) {

 registry : v . Registry ;
v . registry_init ( * registry ) ;
defer v . registry_destroy ( * registry ) ;
c , ok := v . register_in ( * registry , values_record_codec ( ) ) ;
expect ( t , ok ) ;
_ , ok = v . register_in ( * registry , c ) ;
expect ( t , ! ok ) ;
other := v . builtin ( s32 ) ;
other . schema = c . schema ;
_ , ok = v . register_in ( * registry , other ) ;
expect ( t , ! ok ) ;
typ , present := v . registered_type ( * registry , c . schema ) ;
expect ( t , present && typ == Values_Record ) ;
_ , present = v . registered_type ( * registry , 99 ) ;
expect ( t , ! present ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
ptr : * void ;
expect ( t , ! v . write ( v . builtin ( * void ) , * w , * ptr ) && w . err == . Malformed && w . bit_count == 0 ) ;
core . writer_reset ( * w ) ;
w . err = . Invalid_Count ;
x := ( cast , trunc ( s32 ) ( 1 ) ) ;
expect ( t , ! v . write ( v . builtin ( s32 ) , * w , * x ) && w . err == . Invalid_Count && w . bit_count == 0 ) ;
no_progress := v . builtin ( s32 ) ;
no_progress . schema = 65538 ;
no_progress . write = ( w : * core . Writer , x : * s32 ) -> bool {
return true ;
}

 no_progress . read = ( r : * core . Reader , x : * s32 ) -> bool {
return true ;
}

 core . writer_reset ( * w ) ;
expect ( t , ! v . write ( no_progress , * w , * x ) && w . err == . Malformed ) ;
r : core . Reader ;
core . reader_init ( * r , .[ ] ) ;
_ , ok = v . read_new ( no_progress , * r ) ;
expect ( t , ! ok && r . err == . Malformed ) ;

 }



 values_oversized_write_and_partial_bytes :: ( t : * Test ) {

 data := new_slice ( u8 , v . MAX_BYTES + 1 ) ;
defer release ( data ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , ! v . write ( v . builtin ( [ ] u8 ) , * w , * data ) && w . err == . Malformed && w . bit_count == 0 ) ;
core . writer_reset ( * w ) ;
text := ( cast ( string ) ( data ) ) ;
expect ( t , ! v . write ( v . builtin ( string ) , * w , * text ) && w . err == . Malformed && w . bit_count == 0 ) ;
core . writer_reset ( * w ) ;
core . write_bits ( * w , 2 , 32 ) ;
core . write_bits ( * w , 1 , 8 ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
bytes , ok := v . read_new ( v . builtin ( [ ] u8 ) , * r ) ;
expect ( t , ! ok && ( bytes ) . count == 0 && r . err != . None ) ;

 }

 //@endregion


// Cast semantics adapted. 

 // Loop scopes adapted. 

 // Iterator semantics adapted.      
