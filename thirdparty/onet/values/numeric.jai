#scope_file
core :: #import "thirdparty/onet/core" ;
#scope_export


//@region Named portable special types

 Char :: #type,distinct u16 ; // One UTF-16 code unit, including lone surrogates; not rune.

 Guid :: #type,distinct [ 16 ] u8 ; // Application/RFC byte order, never host struct layout.

 Matrix4 :: #type,distinct [ 16 ] float32 ; // Explicit row-major component order.

 Vec2i :: [ 2 ] s32 ;
Vec3i :: [ 3 ] s32 ;
Vec4i :: [ 4 ] s32 ;
Color :: #type,distinct [ 4 ] u8 ; // R,G,B,A bytes, not an engine's in-memory color.

 Channel :: enum u8 {
Unreliable ; Reliable ;
}

 Date_Time_Kind :: enum u8 {
Unspecified ; UTC ; Local ;
}

 Date_Time :: struct {
ticks : s64 ;
kind : Date_Time_Kind ;
}

 MAX_DATE_TICKS :: wire_cast ( s64 , ( 3155378975999999999 ) ) ;
TICKS_PER_MINUTE :: wire_cast ( s64 , ( 600000000 ) ) ;
date_time_write :: ( w : * core . Writer , x : Date_Time , level : core . Compression_Level , offset_minutes : s16 ) -> bool {

 if x . ticks < 0 || x . ticks > MAX_DATE_TICKS || wire_cast ( u8 , ( x . kind ) ) > 2 || offset_minutes < - 840 || offset_minutes > 840 {
return reject_write ( w ) ;
}

 utc := x . ticks ;
if x . kind == . Local {
utc -= wire_cast ( s64 , ( offset_minutes ) ) * TICKS_PER_MINUTE ;
}

 core . write_bits ( w , wire_cast ( u64 , ( x . kind ) ) , 2 ) ;
core . write_int64 ( w , utc , level ) ;
return w . err == . None ;

 }

 date_time_read :: ( r : * core . Reader , level : core . Compression_Level , offset_minutes : s16 ) -> ( Date_Time , bool ) {

 kind := core . read_bits ( r , 2 ) ;
ticks := core . read_int64 ( r , level ) ;
if ticks < - 840 * TICKS_PER_MINUTE || ticks > MAX_DATE_TICKS + 840 * TICKS_PER_MINUTE {
return .{

 } , reject_read ( r ) ;
} ;

 if kind == 2 {
ticks += wire_cast ( s64 , ( offset_minutes ) ) * TICKS_PER_MINUTE ;
}

 if kind > 2 || ticks < 0 || ticks > MAX_DATE_TICKS || offset_minutes < - 840 || offset_minutes > 840 {
return .{

 } , reject_read ( r ) ;
} ;

 return .{
ticks , ( cast ( Date_Time_Kind ) ( kind ) ) ,
} , r . err == . None ;

 } ;

 //@endregion


//@region Configured full codecs and tolerance

 // Options are compile-time constants: no closures, mutable process-global codec

 // tables, raw-memory casts or hidden allocations. schema must identify OPTIONS

 // too. Existing builtin schemas/bit-exact float semantics remain unchanged.

 network_codec :: ( $T : Type , schema : u32 , $level : core . Compression_Level , $accuracy : float32 ) -> Codec ( T ) {

 if schema < CUSTOM_SCHEMA_MIN || ! core . valid_accuracy ( accuracy ) {
return .{

 } ;

 }

 #if T == Quaternion {
if accuracy == 0 {
return .{

 } ;

 }

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * T ) -> bool {
return network_write ( w , x , level , accuracy ) ;
} ,
read = ( r : * core . Reader , x : * T ) -> bool {
return network_read ( r , x , level , accuracy ) ;
} ,
equal = ( a , b : * T ) -> bool {
return network_equal ( a , b , accuracy ) ;
} ,
clone = ( x : * T ) -> T {
return x .* ;
} ,
destroy = ( x : * T ) {
x .* = .{

 } ;

 } ,

 }


}

 network_write :: ( w : * core . Writer , x : * $T , level : core . Compression_Level = . Loose , accuracy : float32 = core . DEFAULT_ACCURACY ) -> bool {

 if ! core . valid_accuracy ( accuracy ) {
return reject_write ( w ) ;
}

 #if T == s8 || T == s16 || T == s32 || T == s64 || T == u8 || T == u16 || T == u32 || T == u64 {

 return core . typed_integer_write ( w , x .* , level ) ;

 } else #if T == bool {
core . write_boolean ( w , x .* ) ;
}

 else #if T == float32 {
core . write_single ( w , x .* , level , accuracy ) ;
}

 else #if T == float64 {
core . write_double ( w , x .* , level , accuracy ) ;
}

 else #if T == Char {
core . write_uint16 ( w , wire_cast ( u16 , ( x .* ) ) , level ) ;
}

 else #if T == Channel {

 if wire_cast ( u8 , ( x .* ) ) > 1 {
return reject_write ( w ) ;
}

 core . write_boolean ( w , x .* == . Reliable ) ;

 } else #if T == Date_Time {
return date_time_write ( w , x .* , level , 0 ) ;
}

 else #if T == Guid || T == Color {

 for component : x .* {
core . write_uint8 ( w , component , level ) ;
}


} else #if T == Vec2i || T == Vec3i || T == Vec4i {

 for component : x .* {
core . write_int32 ( w , component , level ) ;
}


} else #if T == Vec2 || T == Vec3 || T == Vec4 || T == Matrix4 {

 for component : x .* {
core . write_single ( w , component , level , accuracy ) ;
}


} else #if T == Quaternion {

 q , ok := core . quaternion_unit ( ( cast ( [ 4 ] float32 ) x .* ) ) ;
if ! ok || accuracy == 0 {
return reject_write ( w ) ;
}

 core . write_quaternion ( w , q [ 0 ] , q [ 1 ] , q [ 2 ] , q [ 3 ] , level , accuracy ) ;

 } else {
#assert ( false , "unsupported network_codec type; use explicit custom Codec" ) ;
}

 return w . err == . None ;

 }

 network_read :: ( r : * core . Reader , x : * $T , level : core . Compression_Level = . Loose , accuracy : float32 = core . DEFAULT_ACCURACY ) -> bool {

 if ! core . valid_accuracy ( accuracy ) {
return reject_read ( r ) ;
}

 #if T == s8 || T == s16 || T == s32 || T == s64 || T == u8 || T == u16 || T == u32 || T == u64 {

 x .* = core . typed_integer_read ( r , T , level ) ;

 } else #if T == bool {
x .* = core . read_boolean ( r ) ;
}

 else #if T == float32 {
x .* = core . read_single ( r , level , accuracy ) ;
}

 else #if T == float64 {
x .* = core . read_double ( r , level , accuracy ) ;
}

 else #if T == Char {
x .* = ( cast ( Char ) ( core . read_uint16 ( r , level ) ) ) ;
}

 else #if T == Channel {
x .* = ( ifx core . read_boolean ( r ) then . Reliable else . Unreliable ) ;
}

 else #if T == Date_Time {
value , ok := date_time_read ( r , level , 0 ) ;
x .* = value ;
return ok ;
}

 else #if T == Guid || T == Color {
for * component : x .* {
component .* = core . read_uint8 ( r , level ) ;
}

 }

 else #if T == Vec2i || T == Vec3i || T == Vec4i {
for * component : x .* {
component .* = core . read_int32 ( r , level ) ;
}

 }

 else #if T == Vec2 || T == Vec3 || T == Vec4 || T == Matrix4 {
for * component : x .* {
component .* = core . read_single ( r , level , accuracy ) ;
}

 }

 else #if T == Quaternion {

 if accuracy == 0 {
return reject_read ( r ) ;
}

 a , b , c , d := core . read_quaternion ( r , level , accuracy ) ;
x .* = .[
a , b , c , d ,
] ;


} else {
#assert ( false , "unsupported network_codec type" ) ;
}

 return r . err == . None ;

 }

 network_equal :: ( a , b : * $T , accuracy : float32 = core . DEFAULT_ACCURACY ) -> bool {

 #if T == s8 || T == s16 || T == s32 || T == s64 || T == u8 || T == u16 || T == u32 || T == u64 || T == float32 || T == float64 {

 return core . typed_tolerance ( a .* , b .* , accuracy ) ;

 } else #if T == Vec2 || T == Vec3 || T == Vec4 || T == Vec2i || T == Vec3i || T == Vec4i {

 for x , i : a .* {
if ! core . typed_tolerance ( x , b .* [ i ] , accuracy ) {
return false ;
}

 }

 return true ;

 } else #if T == Quaternion {
return core . quaternion_tolerance ( ( cast ( [ 4 ] float32 ) a .* ) , ( cast ( [ 4 ] float32 ) b .* ) , accuracy ) ;
}

 else #if T==Matrix4 || T==Guid || T==Color {
 for x,i:a.* if x!=b.*[i] return false;
 return true;
} else {
return a .* == b .* ;
}


}

 datetime_codec :: ( schema : u32 , $offset_minutes : s16 , $level : core . Compression_Level ) -> Codec ( Date_Time ) {

 if schema < CUSTOM_SCHEMA_MIN || offset_minutes < - 840 || offset_minutes > 840 {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * Date_Time ) -> bool {
return date_time_write ( w , x .* , level , offset_minutes ) ;
} ,
read = ( r : * core . Reader , x : * Date_Time ) -> bool {
value , ok := date_time_read ( r , level , offset_minutes ) ;
x .* = value ;
return ok ;
} ,
equal = ( a , b : * Date_Time ) -> bool {
return a .* == b .* ;
} ,
clone = ( x : * Date_Time ) -> Date_Time {
return x .* ;
} ,
destroy = ( x : * Date_Time ) {
x .* = .{

 } ;

 } ,

 }


}

 // Enum raw/compact encoding preserves unnamed values/flags.

 // Choose bits=underlying width for signed enums; narrowed nonnegative enums

 // reject values that do not fit instead of silently truncating them.

 enum_codec :: ( $E : Type , schema : u32 , $bits : u32 ) -> Codec ( E ) {

 #assert ( type_info(E).type == .ENUM ) ;
if schema < CUSTOM_SCHEMA_MIN || bits < 1 || bits > wire_cast ( u32 , ( size_of ( E ) * 8 ) ) || bits > 64 {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * E ) -> bool {

 value := wire_cast ( u64 , ( x .* ) ) ;
if bits < wire_cast ( u32 , ( size_of ( E ) * 8 ) ) && value >> bits != 0 {
return reject_write ( w ) ;
}

 core . write_bits ( w , value & ( 0xffffffffffffffff >> ( 64 - bits ) ) , bits ) ;
return w . err == . None ;

 } ,
read = ( r : * core . Reader , x : * E ) -> bool {
x .* = cast,trunc(E)( core . read_bits ( r , bits ) ) ;
return r . err == . None ;
} ,
equal = ( a , b : * E ) -> bool {
return a .* == b .* ;
} ,
clone = ( x : * E ) -> E {
return x .* ;
} ,
destroy = ( x : * E ) {
x .* = .{

 } ;

 } ,

 }


}

 //@endregion


//@region Numeric and generated component-mask deltas

 Delta_Codec :: struct ( T : Type ) {

 full : Codec ( T ) ;

 write : #type ( * core . Writer , * T , * T , core . Delta_Check_Mode ) -> ( written : bool , ok : bool ) ;

 read : #type ( * core . Reader , * T , * T ) -> bool ;


}

 // Unlike full Codec callbacks, delta readers borrow the baseline and write a

 // fresh zero result. The wrapper owns cleanup and commits transactionally.

 write_delta :: ( c : Delta_Codec ( $T ) , w : * core . Writer , previous , next : * T , mode : core . Delta_Check_Mode = . Checked ) -> ( bool , bool ) {

 if ! valid ( c . full ) || c . write == null || w . err != . None {
return false , reject_write ( w ) ;
}

 before := w . bit_count ;
written , ok := c . write ( w , previous , next , mode ) ;
if ! ok || w . err != . None || ( written && before >= w . bit_count ) || ( ! written && before != w . bit_count ) {
return false , reject_write ( w ) ;
}

 return written , true ;

 }

 read_delta :: ( c : Delta_Codec ( $T ) , r : * core . Reader , previous , dst : * T ) -> bool {

 if ! valid ( c . full ) || c . read == null || r . err != . None {
return reject_read ( r ) ;
}

 result : T ;
before := r . bit_position ;
if ! c . read ( r , previous , * result ) || r . err != . None || before >= r . bit_position {

 c . full . destroy ( * result ) ;
return reject_read ( r ) ;

 }

 c . full . destroy ( dst ) ;
dst .* = result ;
return true ;

 }

 network_delta_codec :: ( $T : Type , schema : u32 , $accuracy : float32 ) -> Delta_Codec ( T ) {

 #if T == Matrix4 || T == Channel {
#assert ( false , "original Matrix4/Channel delta methods throw NotImplementedException; use full codec" ) ;
}

 return .{

 full = network_codec ( T , schema , . Loose , accuracy ) ,
write = ( w : * core . Writer , a , b : * T , mode : core . Delta_Check_Mode ) -> ( bool , bool ) {

 #if T == s8 || T == s16 || T == s32 || T == s64 || T == u8 || T == u16 || T == u32 || T == u64 {
return core . typed_integer_delta_write ( w , a .* , b .* , mode ) ;
}

 else #if T == float32 || T == float64 {
return core . typed_float_delta_write ( w , a .* , b .* , accuracy , mode ) ;
}

 else #if T == Char {
return core . typed_integer_delta_write ( w , wire_cast ( u16 , ( a .* ) ) , wire_cast ( u16 , ( b .* ) ) , mode ) ;
}

 else #if T == Quaternion {
return core . typed_quaternion_delta_write ( w , ( cast ( [ 4 ] float32 ) a .* ) , ( cast ( [ 4 ] float32 ) b .* ) , accuracy , mode ) ;
}

 else #if T == Vec2 || T == Vec3 || T == Vec4 || T == Vec2i || T == Vec3i || T == Vec4i || T == Color {

 flags : u64 ;
for x , i : a .* {

 #if T == Vec2 || T == Vec3 || T == Vec4 {

 if mode == . Unchecked || core . typed_float_delta_changed ( x , b .* [ i ] , accuracy ) {
flags |= wire_cast ( u64 , ( 1 ) ) << cast,trunc(u64)( i ) ;
}


} else {
if mode == . Unchecked || x != b .* [ i ] {
flags |= wire_cast ( u64 , ( 1 ) ) << cast,trunc(u64)( i ) ;
}

 }


}

 if mode == . Checked && flags == 0 {
return false , true ;
}

 core . write_bits ( w , flags , wire_cast ( u32 , ( ( a .* ) . count ) ) ) ;
for x , i : a .* {

 if flags & ( wire_cast ( u64 , ( 1 ) ) << cast,trunc(u64)( i ) ) == 0 {
continue ;
}

 #if T == Vec2 || T == Vec3 || T == Vec4 {
core . typed_float_delta_write ( w , x , b .* [ i ] , accuracy , . Unchecked ) ;
}

 else {
core . typed_integer_delta_write ( w , x , b .* [ i ] , . Unchecked ) ;
}


}

 return true , w . err == . None ;

 } else {

 if mode == . Checked && network_equal ( a , b , accuracy ) {
return false , true ;
}

 return true , network_write ( w , b , . Tight , accuracy ) ;

 }


} ,
read = ( r : * core . Reader , a , result : * T ) -> bool {

 #if T == s8 || T == s16 || T == s32 || T == s64 || T == u8 || T == u16 || T == u32 || T == u64 {
result .* = core . typed_integer_delta_read ( r , a .* ) ;
}

 else #if T == float32 || T == float64 {
result .* = core . typed_float_delta_read ( r , a .* , accuracy ) ;
}

 else #if T == Char {
result .* = ( cast ( Char ) ( core . typed_integer_delta_read ( r , wire_cast ( u16 , ( a .* ) ) ) ) ) ;
}

 else #if T == Quaternion {
result .* = ( cast ( Quaternion ) ( core . typed_quaternion_delta_read ( r , ( cast ( [ 4 ] float32 ) a .* ) , accuracy ) ) ) ;
}

 else #if T == Vec2 || T == Vec3 || T == Vec4 || T == Vec2i || T == Vec3i || T == Vec4i || T == Color {

 result .* = a .* ;
flags := core . read_bits ( r , wire_cast ( u32 , ( ( a .* ) . count ) ) ) ;
for x , i : a .* {

 if flags & ( wire_cast ( u64 , ( 1 ) ) << cast,trunc(u64)( i ) ) == 0 {
continue ;
}

 #if T == Vec2 || T == Vec3 || T == Vec4 {
result .* [ i ] = core . typed_float_delta_read ( r , x , accuracy ) ;
}

 else {
result .* [ i ] = core . typed_integer_delta_read ( r , x ) ;
}


}


} else {
return network_read ( r , result , . Tight , accuracy ) ;
}

 return r . err == . None ;

 } ,

 }


}

 // Checked replacement deltas serve strings, Guid, DateTime, nullable and custom

 // registered types. Arrays/lists/dictionaries use always_write=true, matching

 // the original full-replacement generic collection delta methods.

 replacement_delta_codec :: ( $T : Type , $make : #type ( ) -> Codec ( T ) , $always_write : bool ) -> Delta_Codec ( T ) {

 return .{

 full = make ( ) ,
write = ( w : * core . Writer , a , b : * T , mode : core . Delta_Check_Mode ) -> ( bool , bool ) {

 c := make ( ) ;
if ! always_write && mode == . Checked && c . equal ( a , b ) {
return false , true ;
}

 return true , write ( c , w , b ) ;

 } ,
read = ( r : * core . Reader , a , out : * T ) -> bool {
c := make ( ) ;
value , ok := read_new ( c , r ) ;
out .* = value ;
return ok ;
} ,

 }


}

 //@endregion


//@region Enum delta and custom registration convenience

 compact_enum_delta_codec :: ( $E : Type , schema : u32 , $bits : u32 ) -> Delta_Codec ( E ) {

 return .{

 full = enum_codec ( E , schema , bits ) ,
write = ( w : * core . Writer , a , b : * E , mode : core . Delta_Check_Mode ) -> ( bool , bool ) {

 if mode == . Checked && a .* == b .* {
return false , true ;
}

 return true , write ( enum_codec ( E , CUSTOM_SCHEMA_MIN , bits ) , w , b ) ;

 } ,
read = ( r : * core . Reader , a , out : * E ) -> bool {
value , ok := read_new ( enum_codec ( E , CUSTOM_SCHEMA_MIN , bits ) , r ) ;
out .* = value ;
return ok ;
} ,

 }


}

 // Explicit underlying integer is required; this is a numeric conversion, not a

 // reinterpretation of an arbitrary third-party enum's memory layout.

 enum_integer_codec :: ( $E , $I : Type , schema : u32 , $level : core . Compression_Level ) -> Codec ( E ) {

 #assert ( type_info(E).type == .ENUM && type_info(I).type == .INTEGER && size_of ( E ) == size_of ( I ) ) ;
if schema < CUSTOM_SCHEMA_MIN {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * E ) -> bool {
return core . typed_integer_write ( w , cast,trunc(I)( x .* ) , level ) ;
} ,
read = ( r : * core . Reader , x : * E ) -> bool {
x .* = cast,trunc(E)( core . typed_integer_read ( r , I , level ) ) ;
return r . err == . None ;
} ,
equal = ( a , b : * E ) -> bool {
return a .* == b .* ;
} ,
clone = ( x : * E ) -> E {
return x .* ;
} ,
destroy = ( x : * E ) {
x .* = .{

 } ;

 } ,

 }


}

 enum_integer_delta_codec :: ( $E , $I : Type , schema : u32 ) -> Delta_Codec ( E ) {

 return .{

 full = enum_integer_codec ( E , I , schema , . Loose ) ,
write = ( w : * core . Writer , a , b : * E , mode : core . Delta_Check_Mode ) -> ( bool , bool ) {
return core . typed_integer_delta_write ( w , cast,trunc(I)( a .* ) , cast,trunc(I)( b .* ) , mode ) ;
} ,
read = ( r : * core . Reader , a , out : * E ) -> bool {
out .* = cast,trunc(E)( core . typed_integer_delta_read ( r , cast,trunc(I)( a .* ) ) ) ;
return r . err == . None ;
} ,

 }


}

 register_delta_in :: ( reg : * Registry , c : Delta_Codec ( $T ) ) -> ( Delta_Codec ( T ) , bool ) {

 if c . write == null || c . read == null {
return .{

 } , false ;
} ;

 _ , ok := register_in ( reg , c . full ) ;
return ( ifx ok then c else Delta_Codec ( T ) .{

 } ) , ok ;

 } ;

 //@endregion


//@region Local DateTime zone adapter

 // Pure timezone lookup. writing=true receives local wall ticks; false receives

 // UTC ticks. The application can use its host zone/DST rules without this

 // portable library guessing the receiving machine's timezone or host layout.

 Date_Time_Zone :: struct {
userdata : * void ;
offset : #type ( * void , s64 , bool ) -> s16 ;
}

 Date_Time_Binding :: struct {
value : Date_Time ;
zone : Date_Time_Zone ;
}

 datetime_zone_bridge :: ( schema : u32 ) -> Bridge {

 if schema < CUSTOM_SCHEMA_MIN {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , p : * void ) {

 binding := ( cast ( * Date_Time_Binding ) p ) ;
offset : s16 ;
if binding . value . kind == . Local && binding . zone . offset != null {
offset = binding . zone . offset ( binding . zone . userdata , binding . value . ticks , true ) ;
}

 date_time_write ( w , binding . value , . Loose , offset ) ;

 } ,
read = ( r : * core . Reader , p : * void ) -> bool {

 binding := ( cast ( * Date_Time_Binding ) p ) ;
probe := r .* ;
kind := core . read_bits ( * probe , 2 ) ;
utc_ticks := core . read_int64 ( * probe , . Loose ) ;
if probe . err != . None || kind > 2 || utc_ticks < - 840 * TICKS_PER_MINUTE || utc_ticks > MAX_DATE_TICKS + 840 * TICKS_PER_MINUTE {
return reject_read ( r ) ;
}

 offset : s16 ;
if kind == 2 && binding . zone . offset != null {
offset = binding . zone . offset ( binding . zone . userdata , utc_ticks , false ) ;
}

 value , ok := date_time_read ( r , . Loose , offset ) ;
if ! ok || ! value_member_finished ( r ) {
return reject_read ( r ) ;
}

 binding . value = value ;
return true ;

 } ,
destroy = ( p : * void ) {
( ( cast ( * Date_Time_Binding ) p ) ) .* = .{

 } ;

 } ,

 }


}

 //@endregion


// Cast semantics adapted. 

operator == :: (a:Date_Time,b:Date_Time) -> bool { return a.ticks==b.ticks && a.kind==b.kind; }
