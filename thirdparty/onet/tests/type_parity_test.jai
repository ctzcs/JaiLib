#scope_file
core :: #import "thirdparty/onet/core" ;
v :: #import "thirdparty/onet/values" ;
using v ;
#scope_export


//@region Type convenience parity

 parity_string :: ( ) -> v . Codec ( string ) {
return v . builtin ( string ) ;
}

 parity_i32 :: ( ) -> v . Codec ( s32 ) {
return v . network_codec ( s32 , 70001 , . Loose , 0.001 ) ;
}

 parity_slice :: ( ) -> v . Codec ( [ ] string ) {
return v . slice_codec ( string , parity_string , 70002 , 32 ) ;
}

 parity_roundtrip :: ( t : * Test , c : v . Codec ( $T ) , input : T ) {

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
src := input ;
expect ( t , v . write ( c , * w , * src ) ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
dst , ok := v . read_new ( c , * r ) ;
defer c . destroy ( * dst ) ;
expect ( t , ok && c . equal ( * src , * dst ) ) ;
copied := c . clone ( * dst ) ;
defer c . destroy ( * copied ) ;
expect ( t , c . equal ( * dst , * copied ) ) ;

 }


parity_initial_instantiations :: ( t : * Test ) {

 parity_roundtrip ( t , v . network_codec ( s32 , 70000 , . Loose , 0.001 ) , ( cast , trunc ( s32 ) ( - 77 ) ) ) ;
parity_roundtrip ( t , v . network_codec ( float64 , 70001 , . Loose , 0.001 ) , ( cast ( float64 ) ( 17.25 ) ) ) ;
parity_roundtrip ( t , v . network_codec ( v . Vec3 , 70002 , . Loose , 0.001 ) , ( cast ( v . Vec3 ) float32 .[ 1 , 2 , 3 ] ) ) ;
parity_roundtrip ( t , v . network_codec ( v . Vec3i , 70003 , . Loose , 0.001 ) , ( cast ( v . Vec3i ) s32 .[ - 1 , 0 , 500 ] ) ) ;
parity_roundtrip ( t , v . network_codec ( v . Quaternion , 70004 , . Loose , 0.001 ) , ( cast ( v . Quaternion ) float32 .[ 0 , 0 , 0 , 1 ] ) ) ;
parity_roundtrip ( t , v . network_codec ( v . Color , 70005 , . Loose , 0.001 ) , ( cast ( v . Color ) u8 .[ 1 , 2 , 3 , 255 ] ) ) ;
parity_roundtrip ( t , v . network_codec ( v . Guid , 70006 , . Loose , 0.001 ) , ( cast ( v . Guid ) u8 .[ 1 , 2 , 3 , 4 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 ] ) ) ;
parity_roundtrip ( t , v . network_codec ( v . Matrix4 , 70007 , . Loose , 0 ) , ( cast ( v . Matrix4 ) float32 .[ 1 , 2 , 3 , 4 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 ] ) ) ;
parity_roundtrip ( t , v . network_codec ( v . Channel , 70008 , . Loose , 0.001 ) , v . Channel . Reliable ) ;
parity_roundtrip ( t , v . network_codec ( v . Char , 70009 , . Loose , 0.001 ) , ( cast ( v . Char ) ( 0xd800 ) ) ) ;
parity_roundtrip ( t , v . datetime_codec ( 70010 , 0 , . Loose ) , v . Date_Time .{
123456 , . UTC
} ) ;
parity_roundtrip ( t , v . enum_codec ( v . Channel , 70011 , 1 ) , v . Channel . Unreliable ) ;
parity_roundtrip ( t , v . fixed_array_codec ( 2 , string , parity_string , 70012 ) , string .[ "a" , "b" ] ) ;
parity_roundtrip ( t , parity_slice ( ) , string .[ "a" , "b" ] ) ;
parity_roundtrip ( t , v . nullable_codec ( string , parity_string , 70013 ) , v . Nullable ( string ) .{
true , "owned"
} ) ;
parity_roundtrip ( t , v . nullable_codec ( [ ] string , parity_slice , 70014 ) , v . Nullable ( [ ] string ) .{
true , string .[ "owned" ]
} ) ;
a : [ .. ] string ;
array_add ( * a , "one" , "two" ) ;
defer release ( a ) ;
parity_roundtrip ( t , v . dynamic_array_codec ( string , parity_string , 70015 , 32 ) , a ) ;
dict : v . Value_Map ( string , string ) ;
array_add ( * dict . entries , .{
"a" , "A"
} , .{
"b" , "B"
} ) ;
defer release ( dict . entries ) ;
parity_roundtrip ( t , v . map_codec ( string , string , parity_string , parity_string , 70016 , 32 ) , dict ) ;
parity_roundtrip ( t , v . decimal_codec ( 70017 , 3 , . Loose ) , v . Decimal .{
v . wide ( 12345 , 0 ) , 2 , true
} ) ;
reg : v . Reference_Registry ( s32 ) ;
v . reference_registry_init ( * reg ) ;
defer v . reference_registry_destroy ( * reg ) ;
target := ( cast , trunc ( s32 ) ( 5 ) ) ;
expect ( t , v . reference_publish ( * reg , .{
42 , 1
} , * target ) ) ;
ref := v . Resolved_Reference ( s32 ) .{
identity = .{
42 , 1 ,
} , resolver = v . reference_resolver ( * reg ) ,
} ;

 expect ( t , v . reference_target ( * ref ) == * target ) ;

 } ;

 //@endregion


//@region Numeric, enum and specialized delta bodies

 parity_delta :: ( t : * Test , c : v . Delta_Codec ( $T ) , previous , next , expected : T ) {

 a , b , want := previous , next , expected ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
wrote , ok := v . write_delta ( c , * w , * a , * b ) ;
expect ( t , wrote && ok ) ;
if ! wrote || ! ok {
return ;
}

 r : core . Reader ;
dst := c . full . clone ( * a ) ;
defer c . full . destroy ( * dst ) ;
{ cut := 0 ; while cut < core . writer_bytes_written ( * w ) { defer cut += 1 ;

 core . reader_init ( * r , view ( w . buffer , 0 , cut ) ) ;
expect ( t , ! v . read_delta ( c , * r , * a , * dst ) && c . full . equal ( * a , * dst ) ) ;

 } }

 core . reader_from_writer ( * r , * w ) ;
expect ( t , v . read_delta ( c , * r , * a , * dst ) && c . full . equal ( * want , * dst ) ) ;
// Aliased baseline/destination remains safe for owning replacement codecs.

 core . reader_from_writer ( * r , * w ) ;
c . full . destroy ( * dst ) ;
dst = c . full . clone ( * a ) ;
expect ( t , v . read_delta ( c , * r , * dst , * dst ) && c . full . equal ( * want , * dst ) ) ;
c . full . destroy ( * dst ) ;
dst = c . full . clone ( * a ) ;
core . writer_reset ( * w ) ;
suppressed , good := v . write_delta ( c , * w , * a , * a ) ;
expect ( t , ! suppressed && good && w . bit_count == 0 ) ;
forced , forced_ok := v . write_delta ( c , * w , * a , * a , . Unchecked ) ;
expect ( t , forced && forced_ok && w . bit_count > 0 ) ;

 } ;

 parity_integer :: ( t : * Test , $T : Type ) {

 levels: []core.Compression_Level = core.Compression_Level.[ . Uncompressed , . Tight , . Loose ] ;
for level : levels {

 // Full constructor options must be compile-time constants, while direct

 // convenience procedures support runtime compression selection.

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , core . typed_integer_write ( * w , min ( T ) , level ) && core . typed_integer_write ( * w , max ( T ) , level ) ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
expect_value ( t , core . typed_integer_read ( * r , T , level ) , min ( T ) ) ;
expect_value ( t , core . typed_integer_read ( * r , T , level ) , max ( T ) ) ;

 }

 parity_delta ( t , v . network_delta_codec ( T , 71000 , 0.001 ) , min ( T ) , max ( T ) , max ( T ) ) ;
parity_delta ( t , v . network_delta_codec ( T , 71000 , 0.001 ) , max ( T ) , min ( T ) , min ( T ) ) ;

 }

 Parity_Signed :: enum s64 {
Negative = - 9223372036854775807 ; Zero = 0 ; Positive = 9223372036854775807 ;
}

 Parity_Flags :: enum u16 {
A = 1 ; B = 2 ; Both = 3 ;
}


parity_all_integer_widths_unsigned_wrap_and_enums :: ( t : * Test ) {

 parity_integer ( t , s8 ) ;
parity_integer ( t , s16 ) ;
parity_integer ( t , s32 ) ;
parity_integer ( t , s64 ) ;
parity_integer ( t , u8 ) ;
parity_integer ( t , u16 ) ;
parity_integer ( t , u32 ) ;
parity_integer ( t , u64 ) ;
parity_roundtrip ( t , v . enum_codec ( Parity_Signed , 71001 , 64 ) , Parity_Signed . Negative ) ;
parity_roundtrip ( t , v . enum_codec ( Parity_Flags , 71002 , 2 ) , Parity_Flags . Both ) ;
parity_delta ( t , v . enum_integer_delta_codec ( Parity_Signed , s64 , 71003 ) , Parity_Signed . Negative , Parity_Signed . Positive , Parity_Signed . Positive ) ;
parity_delta ( t , v . compact_enum_delta_codec ( Parity_Flags , 71004 , 2 ) , Parity_Flags . A , Parity_Flags . Both , Parity_Flags . Both ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
bad := ( cast ( Parity_Flags ) ( 4 ) ) ;
expect ( t , ! v . write ( v . enum_codec ( Parity_Flags , 71002 , 2 ) , * w , * bad ) && w . bit_count == 0 ) ;
expect ( t , ! v . valid ( v . enum_codec ( Parity_Flags , 71002 , 17 ) ) ) ;
parity_delta ( t , v . network_delta_codec ( bool , 71005 , 0.001 ) , false , true , true ) ;
parity_delta ( t , v . network_delta_codec ( v . Char , 71006 , 0.001 ) , ( cast ( v . Char ) ( 65535 ) ) , ( cast ( v . Char ) ( 0 ) ) , ( cast ( v . Char ) ( 0 ) ) ) ;

 }


parity_float_precision_raw_escape_tolerance_and_nonfinite_rejection :: ( t : * Test ) {

 parity_delta ( t , v . network_delta_codec ( float32 , 71100 , 0.001 ) , ( cast ( float32 ) ( 1 ) ) , ( cast ( float32 ) ( 1.0006 ) ) , ( cast ( float32 ) ( 1.001 ) ) ) ;
parity_delta ( t , v . network_delta_codec ( float64 , 71101 , 0.0001 ) , ( cast ( float64 ) ( 123 ) ) , ( cast ( float64 ) ( 124.125 ) ) , ( cast ( float64 ) ( 124.125 ) ) ) ;
parity_delta ( t , v . network_delta_codec ( float32 , 71100 , 0.001 ) , ( cast ( float32 ) ( 1 ) ) , ( cast ( float32 ) ( 1.0e30 ) ) , ( cast ( float32 ) ( 1.0e30 ) ) ) ;
parity_delta ( t , v . network_delta_codec ( float64 , 71101 , 0.001 ) , ( cast ( float64 ) ( - 1.0e200 ) ) , ( cast ( float64 ) ( 1.0e200 ) ) , ( cast ( float64 ) ( 1.0e200 ) ) ) ;
parity_roundtrip ( t , v . network_codec ( float32 , 71102 , . Tight , 0 ) , ( cast ( float32 ) ( 1.234567 ) ) ) ;
parity_roundtrip ( t , v . network_codec ( float64 , 71103 , . Uncompressed , 0.001 ) , ( cast ( float64 ) ( 1.0e200 ) ) ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
previous , next := ( cast ( float32 ) ( 1 ) ) , ( cast ( float32 ) ( 1.0004 ) ) ;
wrote , ok := v . write_delta ( v . network_delta_codec ( float32 , 71100 , 0.001 ) , * w , * previous , * next ) ;
expect ( t , ! wrote && ok && w . bit_count == 0 ) ;
nan_a := bit_cast ( float32 , ( cast , trunc ( u32 ) ( 0x7fc00001 ) ) ) ;
nan_b := bit_cast ( float32 , ( cast , trunc ( u32 ) ( 0x7fc00002 ) ) ) ;
infinity := bit_cast ( float64 , ( cast , trunc ( u64 ) ( 0x7ff0000000000000 ) ) ) ;
expect ( t , core . typed_tolerance ( nan_a , nan_b ) && core . typed_tolerance ( infinity , infinity ) ) ;
expect ( t , ! core . typed_tolerance ( ( cast , trunc ( s64 ) ( - 9223372036854775808 ) ) , ( cast , trunc ( s64 ) ( 9223372036854775807 ) ) , 1 ) && ! core . typed_tolerance ( ( cast , trunc ( u64 ) ( 18446744073709551615 ) ) , ( cast , trunc ( u64 ) ( 18446744073709551615 ) ) - 1 , 0.1 ) ) ;
expect ( t , core . typed_tolerance ( ( cast , trunc ( s32 ) ( 1 ) ) , ( cast , trunc ( s32 ) ( 2 ) ) , 1 ) && core . typed_tolerance ( ( cast ( float32 ) ( 0 ) ) , bit_cast ( float32 , ( cast , trunc ( u32 ) ( 0x80000000 ) ) ) , 0 ) ) ;
// The original network readers sanitize a raw nonfinite full value to zero

 // (delta retains previous); exact builtin codecs still preserve NaN bits.

 parity_roundtrip ( t , v . builtin ( float32 ) , nan_a ) ;
expect ( t , v . write ( v . network_codec ( float32 , 71102 , . Tight , 0.001 ) , * w , * nan_a ) ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
dst := ( cast ( float32 ) ( 77 ) ) ;
expect ( t , v . read ( v . network_codec ( float32 , 71102 , . Tight , 0.001 ) , * r , * dst ) && dst == 0 ) ;
expect ( t , ! v . valid ( v . network_codec ( float32 , 71102 , . Tight , - 1 ) ) ) ;

 }


parity_vectors_color_quaternion_matrix_guid_datetime :: ( t : * Test ) {

 parity_delta ( t , v . network_delta_codec ( v . Vec2 , 71200 , 0.001 ) , ( cast ( v . Vec2 ) float32 .[ 1 , 2 ] ) , ( cast ( v . Vec2 ) float32 .[ 1 , 4 ] ) , ( cast ( v . Vec2 ) float32 .[ 1 , 4 ] ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Vec3 , 71201 , 0.001 ) , ( cast ( v . Vec3 ) float32 .[ 1 , 2 , 3 ] ) , ( cast ( v . Vec3 ) float32 .[ 2 , 2 , 5 ] ) , ( cast ( v . Vec3 ) float32 .[ 2 , 2 , 5 ] ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Vec4 , 71202 , 0.001 ) , ( cast ( v . Vec4 ) float32 .[ 0 , 0 , 0 , 0 ] ) , ( cast ( v . Vec4 ) float32 .[ 1 , 2 , 3 , 4 ] ) , ( cast ( v . Vec4 ) float32 .[ 1 , 2 , 3 , 4 ] ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Vec2i , 71203 , 0.001 ) , ( cast ( v . Vec2i ) s32 .[ ( cast , trunc ( s32 ) ( - 2147483648 ) ) , 9 ] ) , ( cast ( v . Vec2i ) s32 .[ ( cast , trunc ( s32 ) ( 2147483647 ) ) , 9 ] ) , ( cast ( v . Vec2i ) s32 .[ ( cast , trunc ( s32 ) ( 2147483647 ) ) , 9 ] ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Vec3i , 71204 , 0.001 ) , ( cast ( v . Vec3i ) s32 .[ 0 , 0 , 0 ] ) , ( cast ( v . Vec3i ) s32 .[ - 1 , 2 , - 3 ] ) , ( cast ( v . Vec3i ) s32 .[ - 1 , 2 , - 3 ] ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Vec4i , 71205 , 0.001 ) , ( cast ( v . Vec4i ) s32 .[ 0 , 0 , 0 , 0 ] ) , ( cast ( v . Vec4i ) s32 .[ 1 , 2 , 3 , 4 ] ) , ( cast ( v . Vec4i ) s32 .[ 1 , 2 , 3 , 4 ] ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Color , 71206 , 0.001 ) , ( cast ( v . Color ) u8 .[ 255 , 0 , 30 , 255 ] ) , ( cast ( v . Color ) u8 .[ 0 , 0 , 30 , 1 ] ) , ( cast ( v . Color ) u8 .[ 0 , 0 , 30 , 1 ] ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Quaternion , 71207 , 0.001 ) , ( cast ( v . Quaternion ) float32 .[ 0 , 0 , 0 , 1 ] ) , ( cast ( v . Quaternion ) float32 .[ 0 , 0.6 , 0 , 0.8 ] ) , ( cast ( v . Quaternion ) float32 .[ 0 , 0.6 , 0 , 0.8 ] ) ) ;
expect ( t , core . quaternion_tolerance ( .[
0 , 0.6 , 0 , 0.8
] , .[
0 , - 0.6 , 0 , - 0.8
] , 0 ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Guid , 71208 , 0.001 ) , ( cast ( v . Guid ) u8 .[ 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 ] ) , ( cast ( v . Guid ) u8 .[ 255 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 42 ] ) , ( cast ( v . Guid ) u8 .[ 255 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 , 42 ] ) ) ;
parity_delta ( t , v . network_delta_codec ( v . Date_Time , 71209 , 0.001 ) , v . Date_Time .{
123 , . UTC
} , v . Date_Time .{
123 , . Unspecified
} , v . Date_Time .{
123 , . Unspecified
} ) ;
// Matrix full is component-quantized; no fake implementation of its original

 // throwing delta method is offered. Verify explicit row order and error.

 mat := ( cast ( v . Matrix4 ) float32 .[ 1.2345 , 0 , 0 , 0 , 0 , 2.4567 , 0 , 0 , 0 , 0 , 3.1234 , 0 , 0 , 0 , 0 , 1 ] ) ;

 c := v . network_codec ( v . Matrix4 , 71210 , . Loose , 0.001 ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , v . write ( c , * w , * mat ) ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
m , ok := v . read_new ( c , * r ) ;
expect ( t , ok ) ;
for x , i : mat {
expect ( t , Math . abs ( x - m [ i ] ) <= 0.001 ) ;
}

 sender , receiver := v . datetime_codec ( 71211 , 120 , . Loose ) , v . datetime_codec ( 71211 , - 300 , . Loose ) ;
local := v . Date_Time .{
ticks = 1000 * v . TICKS_PER_MINUTE , kind = . Local ,
} ;

 core . writer_reset ( * w ) ;
expect ( t , v . write ( sender , * w , * local ) ) ;
core . reader_from_writer ( * r , * w ) ;
arrived , good := v . read_new ( receiver , * r ) ;
expect ( t , good && arrived . kind == . Local && arrived . ticks == 580 * v . TICKS_PER_MINUTE ) ;

 } ;

 //@endregion


//@region Recursive owners, failed decoding and original full-replacement deltas

 Parity_Record :: struct {
name : string ;
payload : [ ] u8 ;
}

 parity_record_codec :: ( ) -> v . Codec ( Parity_Record ) {

 return .{

 schema = 72000 ,
write = ( w : * core . Writer , x : * Parity_Record ) -> bool {
return v . write ( v . builtin ( string ) , w , * x . name ) && v . write ( v . builtin ( [ ] u8 ) , w , * x . payload ) ;
} ,
read = ( r : * core . Reader , x : * Parity_Record ) -> bool {

 if ! v . read ( v . builtin ( string ) , r , * x . name ) {
return false ;
}

 return v . read ( v . builtin ( [ ] u8 ) , r , * x . payload ) ;

 } ,
equal = ( a , b : * Parity_Record ) -> bool {
return a . name == b . name && v . builtin ( [ ] u8 ) . equal ( * a . payload , * b . payload ) ;
} ,
clone = ( x : * Parity_Record ) -> Parity_Record {
return .{
v . builtin ( string ) . clone ( * x . name ) , v . builtin ( [ ] u8 ) . clone ( * x . payload ) ,
} ;

 } ,
destroy = ( x : * Parity_Record ) {
v . builtin ( string ) . destroy ( * x . name ) ;
v . builtin ( [ ] u8 ) . destroy ( * x . payload ) ;
} ,

 }


}

 parity_record_slice :: ( ) -> v . Codec ( [ ] Parity_Record ) {
return v . slice_codec ( Parity_Record , parity_record_codec , 72001 , 16 ) ;
}

 parity_nullable_string :: ( ) -> v . Codec ( v . Nullable ( string ) ) {
return v . nullable_codec ( string , parity_string , 72002 ) ;
}

 parity_nullable_float :: ( ) -> v . Codec ( v . Nullable ( float32 ) ) {
return v . nullable_codec ( float32 , parity_float_codec , 72003 ) ;
}

 parity_float_codec :: ( ) -> v . Codec ( float32 ) {
return v . network_codec ( float32 , 72004 , . Loose , 0.001 ) ;
}

 parity_owned_failures :: ( t : * Test , c : v . Codec ( $T ) , src : T ) {

 source := src ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
expect ( t , v . write ( c , * w , * source ) ) ;
dst := c . clone ( * source ) ;
defer c . destroy ( * dst ) ;
copy := c . clone ( * source ) ;
defer c . destroy ( * copy ) ;
r : core . Reader ;
{ cut := 0 ; while cut < core . writer_bytes_written ( * w ) { defer cut += 1 ;

 core . reader_init ( * r , view ( w . buffer , 0 , cut ) ) ;
expect ( t , ! v . read ( c , * r , * dst ) && c . equal ( * dst , * copy ) ) ;

 } }

 core . reader_from_writer ( * r , * w ) ;
expect ( t , v . read ( c , * r , * dst ) && c . equal ( * dst , * copy ) ) ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , v . skip ( c , * r ) ) ;

 }


parity_owned_fixed_dynamic_nullable_custom_and_map_failures :: ( t : * Test ) {

 record := Parity_Record .{
"deep" , u8 .[ 1 , 2 , 3 ] ,
} ;

 parity_owned_failures ( t , parity_record_codec ( ) , record ) ;
parity_owned_failures ( t , v . fixed_array_codec ( 2 , Parity_Record , parity_record_codec , 72010 ) , Parity_Record .[ record , record ] ) ;
parity_owned_failures ( t , parity_record_slice ( ) , Parity_Record .[ record , record ] ) ;
parity_owned_failures ( t , v . nullable_codec ( [ ] Parity_Record , parity_record_slice , 72011 ) , v . Nullable ( [ ] Parity_Record ) .{
true , Parity_Record .[ record , record ]
} ) ;
dyn : [ .. ] Parity_Record ;
array_add ( * dyn , record , record ) ;
defer release ( dyn ) ;
parity_owned_failures ( t , v . dynamic_array_codec ( Parity_Record , parity_record_codec , 72012 , 16 ) , dyn ) ;
dictionary : v . Value_Map ( string , Parity_Record ) ;
array_add ( * dictionary . entries , .{
"one" , record
} , .{
"two" , record
} ) ;
defer release ( dictionary . entries ) ;
parity_owned_failures ( t , v . map_codec ( string , Parity_Record , parity_string , parity_record_codec , 72013 , 16 ) , dictionary ) ;
// An empty fixed array still consumes one canonical bit; generic progress

 // validation and nesting cannot confuse it with a non-progress decoder.

 parity_roundtrip ( t , v . fixed_array_codec ( 0 , string , parity_string , 72014 ) , string .[ ] ) ;
parity_roundtrip ( t , parity_nullable_string ( ) , v . Nullable ( string ) .{

 } ) ;
parity_roundtrip ( t , parity_nullable_string ( ) , v . Nullable ( string ) .{
true , ""
} ) ;
parity_delta ( t , v . replacement_delta_codec ( v . Nullable ( string ) , parity_nullable_string , false ) , v . Nullable ( string ) .{
true , ""
} , v . Nullable ( string ) .{

 } , v . Nullable ( string ) .{

 } ) ;
parity_delta ( t , v . replacement_delta_codec ( v . Nullable ( float32 ) , parity_nullable_float , false ) , v . Nullable ( float32 ) .{
true , 1
} , v . Nullable ( float32 ) .{
true , 1.1
} , v . Nullable ( float32 ) .{
true , 1.1
} ) ;
// Null and empty remain #type,distinct through explicit Nullable, while the old

 // builtin string/[]u8 encoding intentionally remains unchanged.

 c := parity_nullable_string ( ) ;
absent , present := v . Nullable ( string ) .{

 } , v . Nullable ( string ) .{
true , "" ,
} ;

 expect ( t , ! c . equal ( * absent , * present ) ) ;
always := v . replacement_delta_codec ( [ ] string , parity_slice , true ) ;
parity_delta ( t , v . replacement_delta_codec ( string , parity_string , false ) , "before" , "after" , "after" ) ;
changed_record := Parity_Record .{
"changed" , u8 .[ 4 , 5 , 6 , 7 ] ,
} ;

 parity_delta ( t , v . replacement_delta_codec ( Parity_Record , parity_record_codec , false ) , record , changed_record , changed_record ) ;
a: []string = string.[ "unchanged" ] ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
wrote , ok := v . write_delta ( always , * w , * a , * a ) ;
expect ( t , wrote && ok ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
out : [ ] string ;
expect ( t , v . read_delta ( always , * r , * a , * out ) ) ;
expect ( t , ( out ) . count == 1 && out [ 0 ] == "unchanged" && raw_data ( out [ 0 ] ) != raw_data ( a [ 0 ] ) ) ;
always . full . destroy ( * out ) ;
core . writer_reset ( * w ) ;
core . write_bits ( * w , 17 , 32 ) ;
core . reader_from_writer ( * r , * w ) ;
dst : [ ] Parity_Record ;
expect ( t , ! v . read ( parity_record_slice ( ) , * r , * dst ) && ( dst ) . count == 0 ) ;

 } ;


parity_duplicate_map_ranges_and_binding_transaction :: ( t : * Test ) {

 c := v . map_codec ( string , string , parity_string , parity_string , 72100 , 8 ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
core . write_bits ( * w , 2 , 32 ) ;
key , value := "same" , "payload" ;
{ loop_index := 0 ; while loop_index < 2 { defer loop_index += 1 ;
expect ( t , v . write ( parity_string ( ) , * w , * key ) && v . write ( parity_string ( ) , * w , * value ) ) ;
} }

 r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
dst : v . Value_Map ( string , string ) ;
expect ( t , ! v . read ( c , * r , * dst ) && ( dst . entries ) . count == 0 ) ;
core . writer_reset ( * w ) ;
input: []string = string.[ "skip" , "first" , "second" ] ;
expect ( t , v . write_array_range ( parity_string ( ) , * w , input , 1 , 2 ) ) ;
core . reader_from_writer ( * r , * w ) ;
expect_value ( t , core . read_bits ( * r , 32 ) , ( cast , trunc ( u64 ) ( 2 ) ) ) ;
target : [3]string ;
defer {
for * s : target {
parity_string ( ) . destroy ( s ) ;
}

 }

 expect ( t , v . read_array_range ( parity_string ( ) , * r , view ( target , 0 ) , 1 , 2 ) && target [ 1 ] == "first" && target [ 2 ] == "second" ) ;
core . reader_from_writer ( * r , * w ) ;
core . read_bits ( * r , 32 ) ;
r . data = view ( r . data , 0 , ( r . data ) . count - 1 ) ;
expect ( t , ! v . read_array_range ( parity_string ( ) , * r , view ( target , 0 ) , 1 , 2 ) && target [ 1 ] == "first" && target [ 2 ] == "second" ) ;
core . writer_reset ( * w ) ;
expect ( t , ! v . write_array_range ( parity_string ( ) , * w , input , 2 , 2 ) && w . bit_count == 0 ) ;
binding := v . Binding ( [ ] string ) .{
codec = parity_slice ( ) ,
} ;

 bridge := v . bridge ( parity_slice ( ) ) ;
core . writer_reset ( * w ) ;
source: []string = string.[ "new" ] ;
expect ( t , v . write ( parity_slice ( ) , * w , * source ) ) ;
core . write_bits ( * w , 1 , 8 ) ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , ! bridge . read ( * r , * binding ) && binding . value.data == null ) ;
bridge . destroy ( * binding ) ;

 } ;

 //@endregion


//@region Decimal arithmetic and quantization


parity_decimal_full_range_fraction_delta_and_overflow :: ( t : * Test ) {

 decimals: []v.Decimal = v.Decimal.[ .{
v . DECIMAL_MAX , 0 , false
, } , .{
v . DECIMAL_MAX , 28 , true
} , .{
v . wide ( 123456789 , 0 ) , 6 , true
} , .{
v . wide ( 0 , 0 ) , 28 , true
} , .{
v . wide ( 999999 , 0 ) , 3 , false
} ] ;
for x : decimals {

 parity_roundtrip ( t , v . decimal_codec ( 73000 , 3 , . Loose ) , x ) ;

 }

 tiny := v . Decimal .{
v . wide ( 1 , 0 ) , 28 , false ,
} ;

 quantized , good := v . decimal_quantize ( tiny , 3 ) ;
expect ( t , good && quantized . coefficient == 0 ) ;
a , b := v . Decimal .{
v . wide ( 12345 , 0 ) , 2 , false ,
} , v . Decimal .{
v . wide ( 1234567 , 0 ) , 4 , false ,
} ;

 parity_delta ( t , v . decimal_delta_codec ( 73001 , 3 ) , a , b , v . Decimal .{
v . wide ( 123456 , 0 ) , 3 , false
} ) ;
parity_delta ( t , v . decimal_delta_codec ( 73001 , 3 ) , v . Decimal .{
v . wide ( 1000 , 0 ) , 0 , true
} , v . Decimal .{
v . wide ( 1 , 0 ) , 3 , false
} , v . Decimal .{
v . wide ( 1 , 0 ) , 3 , false
} ) ;
difference , ok := v . decimal_add ( v . Decimal .{
v . DECIMAL_MAX , 0 , false
} , v . Decimal .{
v . DECIMAL_MAX , 28 , false
} , true ) ;
// Scale alignment uses 192-bit intermediates, then rounds to the 96-bit

 // precision with nearest-even instead of overflowing a limb.

 expect ( t , ok && v . decimal_equal ( difference , .{
v . DECIMAL_MAX - 8 , 0 , false
} ) ) ;
exact , exact_ok := v . decimal_add ( v . Decimal .{
v . wide ( 1 , 0 ) , 0 , false
} , v . Decimal .{
v . wide ( 1 , 0 ) , 28 , false
} , true ) ;
expect ( t , exact_ok && exact . scale == 28 && exact . coefficient == v . decimal_pow10 ( 28 ) - 1 ) ;
_ , overflow := v . decimal_add ( v . Decimal .{
v . DECIMAL_MAX , 0 , false
} , v . Decimal .{
v . wide ( 1 , 0 ) , 0 , false
} ) ;
expect ( t , ! overflow ) ;
expect ( t , v . decimal_equal ( .{
v . wide ( 1200 , 0 ) , 3 , true
} , .{
v . wide ( 12 , 0 ) , 1 , true
} ) && v . decimal_tolerance ( .{
v . wide ( 1000 , 0 ) , 3 , false
} , .{
v . wide ( 1001 , 0 ) , 3 , false
} , 3 ) ) ;
parity_owned_failures ( t , v . decimal_codec ( 73002 , 18 , . Tight ) , v . Decimal .{
v . wide ( 1234567890123456789 , 0 ) , 18 , true
} ) ;
expect ( t , ! v . valid ( v . decimal_codec ( 73003 , 29 , . Loose ) ) ) ;
rounded , rounded_ok := v . decimal_add ( v . Decimal .{
v . wide ( 10 , 0 ) , 0 , false
} , v . Decimal .{
v . wide ( 1 , 0 ) , 28 , false
} , true ) ;
expect ( t , rounded_ok && v . decimal_equal ( rounded , .{
v . wide ( 10 , 0 ) , 0 , false
} ) ) ;
parity_roundtrip ( t , v . decimal_exact_codec ( 73004 ) , v . Decimal .{
v . DECIMAL_MAX , 28 , true
} ) ;
parity_roundtrip ( t , v . decimal_exact_codec ( 73004 ) , v . Decimal .{
v . wide ( 1 , 0 ) , 28 , false
} ) ;

 } ;

 //@endregion


//@region Automatic local-instance reference resolution and registration safety

 Parity_Entity :: struct {
data : s32 ;
}


parity_reference_unspawn_disconnect_generation_and_probe_safety :: ( t : * Test ) {

 registry : v . Reference_Registry ( Parity_Entity ) ;
v . reference_registry_init ( * registry ) ;
defer v . reference_registry_destroy ( * registry ) ;
first , other := Parity_Entity .{
1 ,
} , Parity_Entity .{
2 ,
} ;

 handle := v . Resolved_Reference ( Parity_Entity ) .{
identity = .{
42 , 7 ,
} , resolver = v . reference_resolver ( * registry ) ,
} ;

 expect ( t , v . reference_target ( * handle ) == null && handle . identity . id == 42 ) ;
expect ( t , v . reference_publish ( * registry , .{
42 , 7
} , * first ) && v . reference_target ( * handle ) == * first ) ;
expect ( t , ! v . reference_publish ( * registry , .{
42 , 7
} , * other ) && v . reference_target ( * handle ) == * first ) ;
expect ( t , v . reference_withdraw ( * registry , .{
42 , 7
} ) && v . reference_target ( * handle ) == null && handle . identity . id == 42 ) ;
expect ( t , v . reference_publish ( * registry , .{
42 , 7
} , * first ) && v . reference_target ( * handle ) == * first ) ; // interest return

 expect ( t , v . reference_withdraw ( * registry , .{
42 , 7
} ) && v . reference_publish ( * registry , .{
42 , 8
} , * first ) ) ; // same pooled address

 expect ( t , v . reference_target ( * handle ) == null && ! v . reference_publish ( * registry , .{
42 , 7
} , * other ) ) ;
expect ( t , v . reference_set_target ( * handle , * first ) && handle . identity . generation == 8 && v . reference_target ( * handle ) == * first ) ;
expect ( t , ! v . reference_set_target ( * handle , * other ) && handle . identity . generation == 8 ) ;
bridge := v . reference_bridge ( Parity_Entity , 74000 ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
bridge . write ( * w , * handle ) ;
mirror := v . Resolved_Reference ( Parity_Entity ) .{
resolver = v . reference_resolver ( * registry ) ,
} ;

 r : core . Reader ;
{ cut := 0 ; while cut < core . writer_bytes_written ( * w ) { defer cut += 1 ;

 core . reader_init ( * r , view ( w . buffer , 0 , cut ) ) ;
expect ( t , ! bridge . read ( * r , * mirror ) && mirror . identity . id == 0 ) ;

 } } ;

 core . reader_from_writer ( * r , * w ) ;
expect ( t , bridge . read ( * r , * mirror ) && v . reference_target ( * mirror ) == * first ) ;
core . write_bits ( * w , 1 , 8 ) ;
core . reader_from_writer ( * r , * w ) ;
mirror . identity = .{

 } ;

 expect ( t , ! bridge . read ( * r , * mirror ) && mirror . identity . id == 0 ) ;
expect ( t , v . reference_set_target ( * handle , null ) && v . reference_target ( * handle ) == null ) ;
// Deltas decode absolute identity even against an unrelated/stale baseline.

 parity_delta ( t , v . reference_delta_codec ( ) , v . Reference .{
999 , 1
} , v . Reference .{
42 , 8
} , v . Reference .{
42 , 8
} ) ;
bridge . destroy ( * mirror ) ;
expect ( t , v . reference_publish ( * registry , .{
123 , 1
} , * other ) ) ;
v . reference_registry_destroy ( * registry ) ;
expect ( t , v . reference_target ( * handle ) == null ) ;

 } ;


parity_schema_collisions_do_not_mutate_registration :: ( t : * Test ) {

 reg : v . Registry ;
v . registry_init ( * reg ) ;
defer v . registry_destroy ( * reg ) ;
_ , ok := v . register_in ( * reg , v . network_codec ( s32 , 75000 , . Loose , 0.001 ) ) ;
expect ( t , ok ) ;
_ , duplicate := v . register_in ( * reg , v . network_codec ( s32 , 75000 , . Tight , 0.1 ) ) ;
expect ( t , ! duplicate ) ;
_ , collision := v . register_in ( * reg , v . network_codec ( float32 , 75000 , . Loose , 0.001 ) ) ;
expect ( t , ! collision ) ;
registered , exists := v . registered_type ( * reg , 75000 ) ;
expect ( t , exists && registered == s32 ) ;
_ , custom := v . register_in ( * reg , parity_record_codec ( ) ) ;
expect ( t , custom ) ;
_ , delta := v . register_delta_in ( * reg , v . network_delta_codec ( u64 , 75001 , 0.001 ) ) ;
expect ( t , delta ) ;
_ , repeat := v . register_delta_in ( * reg , v . network_delta_codec ( u64 , 75001 , 0.001 ) ) ;
expect ( t , ! repeat ) ;
_ , reserved := v . register ( v . network_codec ( s32 , 18 , . Loose , 0.001 ) ) ;
expect ( t , ! reserved ) ;

 }

 //@endregion


//@region Numberless targets retain safe pending tickets until spawn


parity_reference_pending_target_is_renumbered_without_another_assignment :: ( t : * Test ) {

 registry : v . Reference_Registry ( Parity_Entity ) ;
v . reference_registry_init ( * registry ) ;
defer v . reference_registry_destroy ( * registry ) ;
entity := Parity_Entity .{
42 ,
} ;

 ticket , ok := v . reference_track_pending ( * registry , * entity ) ;
expect ( t , ok && ticket != 0 ) ;
handle := v . Resolved_Reference ( Parity_Entity ) .{
resolver = v . reference_resolver ( * registry ) ,
} ;

 expect ( t , v . reference_set_target ( * handle , * entity ) && v . reference_is_pending ( * handle ) && v . reference_target ( * handle ) == * entity ) ;
bridge := v . reference_bridge ( Parity_Entity , 76000 ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
bridge . write ( * w , * handle ) ;
remote := v . Resolved_Reference ( Parity_Entity ) .{
resolver = v . reference_resolver ( * registry ) ,
} ;

 r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , bridge . read ( * r , * remote ) && remote . identity . id == 0 ) ;
expect ( t , v . reference_publish ( * registry , .{
88 , 4
} , * entity ) && ! v . reference_is_pending ( * handle ) ) ;
core . writer_reset ( * w ) ;
bridge . write ( * w , * handle ) ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , bridge . read ( * r , * remote ) && remote . identity == v . Reference .{
88 , 4
, }
&& v . reference_target ( * remote ) == * entity ) ;
expect ( t , v . reference_target ( * handle ) == * entity && handle . identity == v . Reference .{
88 , 4
, }
&& handle . pending_ticket == 0 ) ;
v . reference_forget_pending ( * registry , ticket ) ;
expect ( t , v . reference_withdraw ( * registry , .{
88 , 4
} ) && v . reference_target ( * handle ) == null ) ;
// Abort an unspawned target, then reuse the same outer address under a new

 // ticket. The old member must never follow that new rental's identity.

 old_ticket , old_ok := v . reference_track_pending ( * registry , * entity ) ;
expect ( t , old_ok && v . reference_set_target ( * handle , * entity ) ) ;
v . reference_forget_pending ( * registry , old_ticket ) ;
new_ticket , new_ok := v . reference_track_pending ( * registry , * entity ) ;
expect ( t , new_ok && new_ticket != old_ticket && v . reference_publish ( * registry , .{
99 , 1
} , * entity ) ) ;
expect ( t , v . reference_target ( * handle ) == null && v . reference_identity ( * handle ) . id == 0 && ! v . reference_is_pending ( * handle ) ) ;

 } ;

 //@endregion


//@region Byte segment budgets and explicit host timezone callbacks


parity_bytes_segments_unaligned_noallocation_and_atomic_truncation :: ( t : * Test ) {

 src: []u8 = u8.[ 9 , 1 , 2 , 3 , 8 ] ;
parity_roundtrip ( t , v . byte_segment_codec ( ) , view ( src , 1 , 4 ) ) ;
parity_owned_failures ( t , v . byte_segment_codec ( ) , view ( src , 1 , 4 ) ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
core . write_boolean ( * w , true ) ;
expect ( t , v . write_bytes_raw ( * w , view ( src , 1 , 4 ) ) ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , core . read_boolean ( * r ) ) ;
out := u8 .[ 7 , 7 , 7 ] ;
r . data = view ( r . data , 0 , ( r . data ) . count - 1 ) ;
expect ( t , ! v . read_bytes_into ( * r , view ( out , 0 ) ) && out == u8 .[
7 , 7 , 7
] ) ;
core . reader_from_writer ( * r , * w ) ;
core . read_boolean ( * r ) ;
expect ( t , v . read_bytes_into ( * r , view ( out , 0 ) ) && out == u8 .[
1 , 2 , 3
] ) ;
core . writer_reset ( * w ) ;
expect ( t , v . write_bytes_raw ( * w , src ) ) ;
core . reader_from_writer ( * r , * w ) ;
view , ok := v . read_bytes_view ( * r , 3 ) ;
expect ( t , ok && ( view ) . count == 3 && raw_data ( view ) == raw_data ( r . data ) ) ;
core . reader_from_writer ( * r , * w ) ;
core . read_boolean ( * r ) ;
_ , unaligned := v . read_bytes_view ( * r , 1 ) ;
expect ( t , ! unaligned ) ;

 }


parity_datetime_zone_bridge_preserves_kind_and_local_instant :: ( t : * Test ) {

 sender_offset , receiver_offset := ( cast , trunc ( s16 ) ( 120 ) ) , ( cast , trunc ( s16 ) ( - 300 ) ) ;
zone := ( p : * void , ticks : s64 , writing : bool ) -> s16 {
return ( ( cast ( * s16 ) p ) ) .* ;
}

 a := v . Date_Time_Binding .{
value = .{
1000 * v . TICKS_PER_MINUTE , . Local ,
} , zone = .{
* sender_offset , zone ,
} ,

 } ;

 b := v . Date_Time_Binding .{
value = .{
77 , . UTC ,
} , zone = .{
* receiver_offset , zone ,
} ,

 } ;

 bridge := v . datetime_zone_bridge ( 77000 ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
bridge . write ( * w , * a ) ;
r : core . Reader ;
{ cut := 0 ; while cut < core . writer_bytes_written ( * w ) { defer cut += 1 ;

 core . reader_init ( * r , view ( w . buffer , 0 , cut ) ) ;
expect ( t , ! bridge . read ( * r , * b ) && b . value == v . Date_Time .{
77 , . UTC
, } ) ;

 } }

 core . reader_from_writer ( * r , * w ) ;
expect ( t , bridge . read ( * r , * b ) && b . value == v . Date_Time .{
580 * v . TICKS_PER_MINUTE , . Local
, } ) ;
// Provider changes stand in for DST changes: its runtime answer, not a

 // compile-time capture or the host memory layout, drives the conversion.

 receiver_offset = - 240 ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , bridge . read ( * r , * b ) && b . value . ticks == 640 * v . TICKS_PER_MINUTE ) ;
a . value . kind = . UTC ;
core . writer_reset ( * w ) ;
bridge . write ( * w , * a ) ;
core . reader_from_writer ( * r , * w ) ;
expect ( t , bridge . read ( * r , * b ) && b . value . ticks == a . value . ticks && b . value . kind == . UTC ) ;
bridge . destroy ( * a ) ;
bridge . destroy ( * b ) ;

 }

 //@endregion


//@region Original nonfinite quaternion delta policy


parity_nonfinite_quaternion_checked_refusal_unchecked_identity :: ( t : * Test ) {

 codec := v . network_delta_codec ( v . Quaternion , 78000 , 0.001 ) ;
previous := ( cast ( v . Quaternion ) float32 .[ 0 , 0.6 , 0 , 0.8 ] ) ;

 invalid := ( cast ( v . Quaternion ) float32 .[ 0 , 0 , 0 , bit_cast ( float32 , ( cast , trunc ( u32 ) ( 0x7fc00000 ) ) ) ] ) ;

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
wrote , ok := v . write_delta ( codec , * w , * previous , * invalid ) ;
expect ( t , ! wrote && ok && w . bit_count == 0 ) ;
forced , good := v . write_delta ( codec , * w , * previous , * invalid , . Unchecked ) ;
expect ( t , forced && good ) ;
r : core . Reader ;
core . reader_from_writer ( * r , * w ) ;
out := ( cast ( v . Quaternion ) float32 .[ 0 , 0 , 0 , 0 ] ) ;

 expect ( t , v . read_delta ( codec , * r , * previous , * out ) && codec . full . equal ( * previous , * out ) ) ;
expect ( t , ! v . valid ( v . network_codec ( v . Quaternion , 78001 , . Loose , 0 ) ) ) ;

 }

 //@endregion


//@region Decimal precision across all scales and arbitrary accuracy steps


parity_decimal_28_places_and_non_power_of_ten_accuracy :: ( t : * Test ) {

 c := v . decimal_codec ( 79000 , 28 , . Loose ) ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
r : core . Reader ;
inputs: []v.Decimal = v.Decimal.[ .{
v . wide ( 1 , 0 ) , 28 , false
, } , .{
v . DECIMAL_MAX , 28 , true
} , .{
v . wide ( 5097733592125636885 , 669260594 ) , 28 , false
} ] ;
for input : inputs {

 x := input ;
core . writer_reset ( * w ) ;
expect ( t , v . write ( c , * w , * x ) ) ;
core . reader_from_writer ( * r , * w ) ;
out , ok := v . read_new ( c , * r ) ;
expect ( t , ok && v . decimal_equal ( x , out ) ) ;

 }

 step := v . decimal_step_codec ( 79001 , v.u128.{5,0}, 3 , . Loose ) ; // accuracy 0.005

 x := v . Decimal .{
v . wide ( 4212349 , 0 ) , 5 , false ,
} ;

 core . writer_reset ( * w ) ;
expect ( t , v . write ( step , * w , * x ) ) ;
core . reader_from_writer ( * r , * w ) ;
quantized , ok := v . read_new ( step , * r ) ;
expect ( t , ok && v . decimal_equal ( quantized , .{
v . wide ( 4212 , 0 ) , 2 , false
} ) ) ;
parity_delta ( t , v . decimal_step_delta_codec ( 79002 , v.u128.{5,0}, 3 ) , v . Decimal .{
v . wide ( 11 , 0 ) , 1 , false
} , v . Decimal .{
v . wide ( 112349 , 0 ) , 5 , false
} , v . Decimal .{
v . wide ( 112 , 0 ) , 2 , false
} ) ;
parity_roundtrip ( t , v . decimal_step_codec ( 79003 , v.u128.{25,0}, 1 , . Tight ) , v . Decimal .{
v . wide ( 1275 , 0 ) , 2 , false
} ) ;
parity_owned_failures ( t , v . decimal_step_codec ( 79004 , v.u128.{1,0}, 28 , . Tight ) , v . Decimal .{
v . DECIMAL_MAX , 28 , true
} ) ;
expect ( t , ! v . valid ( v . decimal_step_codec ( 79005 , v.u128.{0,0}, 3 , . Loose ) ) ) ;

 } ;

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
