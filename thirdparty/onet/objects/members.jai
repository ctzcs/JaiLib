#scope_file
core :: #import "thirdparty/onet/core" ;
transport :: #import "thirdparty/onet/transport" ;
wire :: #import "thirdparty/onet/wire" ;
#scope_export
// 显式成员编解码替代托管生成器。自定义 read 必须确定性、无外部副作用。



 //@region 成员与所有权

 Value_Codec :: struct {

 schema : u32 ;

 write : #type ( w : * core . Writer , value : * void ) ;

 read : #type ( r : * core . Reader , value : * void ) -> bool ;

 destroy : #type ( value : * void ) ;

 // Optional scheduling hooks, appended for source compatibility. Collection

 // reads only populate owned pull logs; they never notify during predecode.

 begin_tick : #type ( value : * void , tick : u64 ) ;

 set_replaying : #type ( value : * void , replaying : bool ) ;


}


component_destroy :: ( comp : * Component ) {

 if comp == null {

 return ;

 }

 for * m : comp . members {

 release ( m .* . last_encoded ) ;
release ( m .* . owned_bytes ) ;
if m .* . kind == . Custom && m .* . codec . destroy != null {

 m .* . codec . destroy ( m .* . ptr ) ;

 }


}

 release ( comp . members ) ;
if comp . destroy_userdata != null {

 comp . destroy_userdata ( comp . userdata ) ;

 }

 free ( comp ) ;

 }


member_f64 :: ( comp : * Component , value : * float64 , accuracy : float32 = core . DEFAULT_ACCURACY ) {

 array_add ( * comp . members , Member .{
kind = . F64 , ptr = value , accuracy = accuracy
} ) ;

 } ;

 member_u64 :: ( comp : * Component , value : * u64 ) {

 array_add ( * comp . members , Member .{
kind = . U64 , ptr = value
} ) ;

 } ;

 member_string :: ( comp : * Component , value : * string ) {

 array_add ( * comp . members , Member .{
kind = . String , ptr = value
} ) ;

 } ;

 member_bytes_value :: ( comp : * Component , value : * [ ] u8 ) {

 array_add ( * comp . members , Member .{
kind = . Bytes , ptr = value
} ) ;

 } ;

 member_vec2 :: ( comp : * Component , value : * [ 2 ] float32 , accuracy : float32 = core . DEFAULT_ACCURACY ) {

 array_add ( * comp . members , Member .{
kind = . Vec2 , ptr = value , accuracy = accuracy
} ) ;

 } ;

 member_vec4 :: ( comp : * Component , value : * [ 4 ] float32 , accuracy : float32 = core . DEFAULT_ACCURACY ) {

 array_add ( * comp . members , Member .{
kind = . Vec4 , ptr = value , accuracy = accuracy
} ) ;

 } ;

 member_reference :: ( comp : * Component , value : * Network_Id ) {

 array_add ( * comp . members , Member .{
kind = . Network_Reference , ptr = value
} ) ;

 } ;

 member_connection :: ( comp : * Component , value : * transport . Connection_Id ) {

 array_add ( * comp . members , Member .{
kind = . Connection_Reference , ptr = value
} ) ;

 } ;

 member_custom :: ( comp : * Component , value : * void , codec : Value_Codec ) {

 assert ( value != null && codec . schema != 0 && codec . write != null && codec . read != null ) ;
array_add ( * comp . members , Member .{
kind = . Custom , ptr = value , codec = codec
} ) ;

 } ;


bytes_equal :: ( a , b : [ ] u8 ) -> bool {

 return wire . equal ( a , b ) ;

 }


member_bytes :: ( m : * Member ) -> ( [ ] u8 , bool ) {

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
member_write_full ( * w , m ) ;
if w . err != . None || core . writer_bytes_written ( * w ) > wire . MAX_PAYLOAD {

 return .[ ] , false ;

 }

 return core . writer_to_array ( * w ) , true ;

 }

 //@endregion


//@region 完整值编码

 member_write_full :: ( w : * core . Writer , m : * Member ) {

 if m . ptr == null {

 w . err = . Malformed ;
return ;

 }

 if m . kind == {

 case . F32 ;
core . write_single ( w , ( ( cast ( * float32 ) m . ptr ) ) .* , . Loose , m . accuracy ) ;
case . I32 ;
core . write_int32 ( w , ( ( cast ( * s32 ) m . ptr ) ) .* , . Loose ) ;
case . Bool ;
core . write_boolean ( w , ( ( cast ( * bool ) m . ptr ) ) .* ) ;
case . Vec3 ;
for v : ( ( cast ( * [ 3 ] float32 ) m . ptr ) ) .* {

 core . write_single ( w , v , . Loose , m . accuracy ) ;

 }

 case . Quat ;
q := ( ( cast ( * [ 4 ] float32 ) m . ptr ) ) .* ;
core . write_quaternion ( w , q [ 0 ] , q [ 1 ] , q [ 2 ] , q [ 3 ] , . Loose , m . accuracy ) ;
case . F64 ;
core . write_double ( w , ( ( cast ( * float64 ) m . ptr ) ) .* , . Loose , m . accuracy ) ;
case . U64 ;
core . write_uint64 ( w , ( ( cast ( * u64 ) m . ptr ) ) .* , . Loose ) ;
case . String ;
value := ( ( cast ( * string ) m . ptr ) ) .* ;
wire . write_bytes ( w , bit_cast ( [ ] u8 , value ) ) ;
case . Bytes ;
wire . write_bytes ( w , ( ( cast ( * [ ] u8 ) m . ptr ) ) .* ) ;
case . Vec2 ;
for v : ( ( cast ( * [ 2 ] float32 ) m . ptr ) ) .* {

 core . write_single ( w , v , . Loose , m . accuracy ) ;

 }

 case . Vec4 ;
for v : ( ( cast ( * [ 4 ] float32 ) m . ptr ) ) .* {

 core . write_single ( w , v , . Loose , m . accuracy ) ;

 }

 case . Network_Reference ;
core . write_uint32 ( w , ( cast , trunc ( u32 ) ( ( ( cast ( * Network_Id ) m . ptr ) ) .* ) ) , . Uncompressed ) ;
case . Connection_Reference ;
core . write_uint32 ( w , ( cast , trunc ( u32 ) ( ( ( cast ( * transport . Connection_Id ) m . ptr ) ) .* ) ) , . Uncompressed ) ;
case . Custom ;
if m . codec . write == null {

 w . err = . Malformed ;
return ;

 }

 m . codec . write ( w , m . ptr ) ;

 }


}


member_read_full :: ( r : * core . Reader , m : * Member ) -> bool {

 if m . ptr == null {

 wire . fail ( r ) ;
return false ;

 }

 if m . kind == {

 case . F32 ;
( ( cast ( * float32 ) m . ptr ) ) .* = core . read_single ( r , . Loose , m . accuracy ) ;
case . I32 ;
( ( cast ( * s32 ) m . ptr ) ) .* = core . read_int32 ( r , . Loose ) ;
case . Bool ;
( ( cast ( * bool ) m . ptr ) ) .* = core . read_boolean ( r ) ;
case . Vec3 ;
{ i := 0 ; while i < 3 { defer i += 1 ;

 ( ( cast ( * [ 3 ] float32 ) m . ptr ) ) .* [ i ] = core . read_single ( r , . Loose , m . accuracy ) ;

 } }

 case . Quat ;
x , y , z , qw := core . read_quaternion ( r , . Loose , m . accuracy ) ;
( ( cast ( * [ 4 ] float32 ) m . ptr ) ) .* = .[ x , y , z , qw ] ;

 case . F64 ;
( ( cast ( * float64 ) m . ptr ) ) .* = core . read_double ( r , . Loose , m . accuracy ) ;
case . U64 ;
( ( cast ( * u64 ) m . ptr ) ) .* = core . read_uint64 ( r , . Loose ) ;
case . String , . Bytes ;
data , ok := wire . read_bytes ( r ) ;
if ! ok {

 return false ;

 }

 release ( m . owned_bytes ) ;
m . owned_bytes = data ;
if m . kind == . String {

 ( ( cast ( * string ) m . ptr ) ) .* = bit_cast ( string , data ) ;

 } else {

 ( ( cast ( * [ ] u8 ) m . ptr ) ) .* = data ;

 }

 case . Vec2 ;
{ i := 0 ; while i < 2 { defer i += 1 ;

 ( ( cast ( * [ 2 ] float32 ) m . ptr ) ) .* [ i ] = core . read_single ( r , . Loose , m . accuracy ) ;

 } }

 case . Vec4 ;
{ i := 0 ; while i < 4 { defer i += 1 ;

 ( ( cast ( * [ 4 ] float32 ) m . ptr ) ) .* [ i ] = core . read_single ( r , . Loose , m . accuracy ) ;

 } }

 case . Network_Reference ;
( ( cast ( * Network_Id ) m . ptr ) ) .* = ( cast ( Network_Id ) ( core . read_uint32 ( r , . Uncompressed ) ) ) ;
case . Connection_Reference ;
( ( cast ( * transport . Connection_Id ) m . ptr ) ) .* = ( cast ( transport . Connection_Id ) ( core . read_uint32 ( r , . Uncompressed ) ) ) ;
case . Custom ;
if m . codec . read == null || ! m . codec . read ( r , m . ptr ) {

 wire . fail ( r ) ;

 }


}

 return r . err == . None ;

 }


// schema 与 kind/accuracy 都参与布局校验，防止同长度的错误工厂被接受。

 member_write_schema :: ( w : * core . Writer , m : * Member ) {

 core . write_uint8 ( w , ( cast , trunc ( u8 ) ( m . kind ) ) , . Uncompressed ) ;
core . write_bits ( w , ( cast , trunc ( u64 ) ( bit_cast ( u32 , m . accuracy ) ) ) , 32 ) ;
core . write_uint32 ( w , m . codec . schema , . Uncompressed ) ;

 }

 member_check_schema :: ( r : * core . Reader , m : * Member ) -> bool {

 kind := core . read_uint8 ( r , . Uncompressed ) ;
accuracy := ( cast , trunc ( u32 ) ( core . read_bits ( r , 32 ) ) ) ;
schema := core . read_uint32 ( r , . Uncompressed ) ;
if r . err != . None || kind != ( cast , trunc ( u8 ) ( m . kind ) ) || accuracy != bit_cast ( u32 , m . accuracy ) || schema != m . codec . schema {

 wire . fail ( r ) ;
return false ;

 }

 return true ;

 }

 //@endregion


//@region 控制权与成员写入

 // Trusted policy callback: inspect only; do not mutate the object, registry or

 // encoded bytes. Like custom decoders it must be deterministic/side-effect-free.

 Member_Write_Validator :: ( obj : * Network_Object , from : transport . Connection_Id , component , member : int , encoded_value : [ ] u8 ) -> bool ;

 set_controller :: ( reg : * Registry , id : Network_Id , controller : transport . Connection_Id , requester : transport . Connection_Id = SERVER_OWNED ) -> bool {

 obj , ok := get ( reg , id ) ;
if ! ok || ! reg . authoritative || requester != SERVER_OWNED {

 return false ;

 }

 // Explicit assignment revokes any outstanding reconnect lease, even if a

 // later assignment returns control to the server (no stale-token revival).

 forget_retained ( reg , id ) ;
obj . owner = controller ;
return true ;

 }


can_write :: ( reg : * Registry , id : Network_Id , from : transport . Connection_Id ) -> bool {

 obj , ok := get ( reg , id ) ;
return ok && reg . authoritative && ( from == SERVER_OWNED || ( obj . owner != SERVER_OWNED && obj . owner == from && reg . is_observer != null && reg . is_observer ( obj , from , reg . visibility_userdata ) ) ) ;

 }


apply_member_write :: ( reg : * Registry , id : Network_Id , from : transport . Connection_Id , component , member : int , encoded : [ ] u8 , validate : Member_Write_Validator = null ) -> bool {

 obj , ok := get ( reg , id ) ;
if ! ok || ! can_write ( reg , id , from ) || component < 0 || component >= ( obj . components ) . count || member < 0 || member >= ( obj . components [ component ] . members ) . count || ( encoded ) . count > wire . MAX_PAYLOAD {

 return false ;

 }

 comp := obj . components [ component ] ;
factory := table_get ( * reg . factories , comp . type_id ) ;
if factory == null {

 return false ;

 }

 probe := factory ( ) ;
if probe == null {

 return false ;

 }

 defer component_destroy ( probe ) ;
if probe . type_id != comp . type_id || ( probe . members ) . count != ( comp . members ) . count {

 return false ;

 }

 // Count alone does not establish a compatible factory. Validate the entire

 // live layout before calling any decoder or application validator.

 for live , i : comp . members {

 candidate := probe . members [ i ] ;
if live . kind != candidate . kind || bit_cast ( u32 , live . accuracy ) != bit_cast ( u32 , candidate . accuracy ) || live . codec . schema != candidate . codec . schema || live . ptr == null || candidate . ptr == null {

 return false ;

 }


}


r : core . Reader ;
core . reader_init ( * r , encoded ) ;
if ! member_read_full ( * r , * probe . members [ member ] ) || ! wire . finished ( * r ) {

 return false ;

 }

 if validate != null && ! validate ( obj , from , component , member , encoded ) {

 return false ;

 }

 core . reader_reset ( * r , encoded ) ;
return member_read_full ( * r , * comp . members [ member ] ) && wire . finished ( * r ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
