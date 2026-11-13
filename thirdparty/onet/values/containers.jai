#scope_file
core :: #import "thirdparty/onet/core" ;
#scope_export


//@region Nullable and fixed/dynamic owned arrays

 MAX_ARRAY_ELEMENTS :: 65536 ;
Nullable :: struct ( T : Type ) {
has_value : bool ;
value : T ;
}

 // Factory arguments are compile-time proc symbols, not closure captures. Each

 // returns a stable schema/configuration, so arbitrary custom element ownership

 // composes without altering Codec's existing six-field source ABI.

 nullable_codec :: ( $T : Type , $make : #type ( ) -> Codec ( T ) , schema : u32 ) -> Codec ( Nullable ( T ) ) {

 if schema < CUSTOM_SCHEMA_MIN || ! valid ( make ( ) ) {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * Nullable ( T ) ) -> bool {

 core . write_boolean ( w , x . has_value ) ;
return ( ifx ! x . has_value then w . err == . None else write ( make ( ) , w , * x . value ) ) ;

 } ,
read = ( r : * core . Reader , x : * Nullable ( T ) ) -> bool {

 x . has_value = core . read_boolean ( r ) ;
if r . err != . None {
return false ;
}

 if ! x . has_value {
return true ;
}

 value , ok := read_new ( make ( ) , r ) ;
x . value = value ;
return ok ;

 } ,
equal = ( a , b : * Nullable ( T ) ) -> bool {
return a . has_value == b . has_value && ( ! a . has_value || make ( ) . equal ( * a . value , * b . value ) ) ;
} ,
clone = ( x : * Nullable ( T ) ) -> Nullable ( T ) {

 if ! x . has_value {
return .{

 } ;

 }

 return .{
true , make ( ) . clone ( * x . value ) ,
} ;


} ,
destroy = ( x : * Nullable ( T ) ) {
if x . has_value {
make ( ) . destroy ( * x . value ) ;
} ;
x .* = .{

 } ;

 } ,

 }


}

 fixed_array_codec :: ( $N : int , $T : Type , $make : #type ( ) -> Codec ( T ) , schema : u32 ) -> Codec ( [ N ] T ) {

 #assert ( N >= 0 && N <= MAX_ARRAY_ELEMENTS ) ;
if schema < CUSTOM_SCHEMA_MIN || ! valid ( make ( ) ) {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * [ N ] T ) -> bool {

 c := make ( ) ;
#if N == 0 {
core . write_boolean ( w , false ) ;
}

 for * e : x .* {
if ! write ( c , w , e ) {
return false ;
}

 }

 return w . err == . None ;

 } ,
read = ( r : * core . Reader , x : * [ N ] T ) -> bool {

 c := make ( ) ;
#if N == 0 {
if core . read_boolean ( r ) {
return reject_read ( r ) ;
}

 }

 if N > core . reader_remaining_bits ( r ) {
return reject_read ( r ) ;
}

 for * e : x .* {
value , ok := read_new ( c , r ) ;
if ! ok {
return false ;
} ;
e .* = value ;
}

 return r . err == . None ;

 } ,
equal = ( a , b : * [ N ] T ) -> bool {

 c := make ( ) ;
for * e , i : a .* {
if ! c . equal ( e , * b .* [ i ] ) {
return false ;
}

 }

 return true ;

 } ,
clone = ( x : * [ N ] T ) -> [ N ] T {
out : [ N ] T ;
c := make ( ) ;
for * e , i : x .* {
out [ i ] = c . clone ( e ) ;
} ;
return out ;
} ,
destroy = ( x : * [ N ] T ) {
c := make ( ) ;
for * e : x .* {
c . destroy ( e ) ;
} ;
x .* = .{

 } ;

 } ,

 }


}

 slice_codec :: ( $T : Type , $element : #type ( ) -> Codec ( T ) , schema : u32 , $limit : int ) -> Codec ( [ ] T ) {

 if schema < CUSTOM_SCHEMA_MIN || ! valid ( element ( ) ) || limit < 0 || limit > MAX_ARRAY_ELEMENTS {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * [ ] T ) -> bool {

 if ( x .* ) . count > limit {
return reject_write ( w ) ;
}

 core . write_bits ( w , wire_cast ( u64 , ( ( x .* ) . count ) ) , 32 ) ;
for * e : x .* {
if ! write ( element ( ) , w , e ) {
return false ;
}

 }

 return w . err == . None ;

 } ,
read = ( r : * core . Reader , x : * [ ] T ) -> bool {

 n := core . read_bits ( r , 32 ) ;
if r . err != . None || n > wire_cast ( u64 , ( limit ) ) || n > wire_cast ( u64 , ( core . reader_remaining_bits ( r ) ) ) {
return reject_read ( r ) ;
}

 if n == 0 {
return true ;
}

 x .* = new_slice ( T , ( cast ( int ) ( n ) ) ) ;
for * e : x .* {
value , ok := read_new ( element ( ) , r ) ;
if ! ok {
return false ;
} ;
e .* = value ;
}

 return true ;

 } ,
equal = ( a , b : * [ ] T ) -> bool {

 if ( a .* ) . count != ( b .* ) . count {
return false ;
}

 for * e , i : a .* {
if ! element ( ) . equal ( e , * b .* [ i ] ) {
return false ;
}

 }

 return true ;

 } ,
clone = ( x : * [ ] T ) -> [ ] T {

 if ( x .* ) . count == 0 {
return .[ ] ;
}

 out := new_slice ( T , ( x .* ) . count ) ;
for * e , i : x .* {
out [ i ] = element ( ) . clone ( e ) ;
} ;
return out ;

 } ,
destroy = ( x : * [ ] T ) {
for * e : x .* {
element ( ) . destroy ( e ) ;
} ;
release ( x .* ) ;
x .* = .[ ] ;
} ,

 }


}

 dynamic_array_codec :: ( $T : Type , $element : #type ( ) -> Codec ( T ) , schema : u32 , $limit : int ) -> Codec ( [ .. ] T ) {

 if schema < CUSTOM_SCHEMA_MIN || ! valid ( element ( ) ) || limit < 0 || limit > MAX_ARRAY_ELEMENTS {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * [ .. ] T ) -> bool {

 view := view ( x .* , 0 ) ;
c := slice_codec ( T , element , CUSTOM_SCHEMA_MIN , limit ) ;
return write ( c , w , * view ) ;

 } ,
read = ( r : * core . Reader , x : * [ .. ] T ) -> bool {

 c := slice_codec ( T , element , CUSTOM_SCHEMA_MIN , limit ) ;
items , ok := read_new ( c , r ) ;
if ! ok {
return false ;
}

 defer release ( items ) ; // Move element owners, not their backing slice.

 array_add ( x , .. items ) ;
return true ;

 } ,
equal = ( a , b : * [ .. ] T ) -> bool {

 av , bv := view ( a .* , 0 ) , view ( b .* , 0 ) ;
return slice_codec ( T , element , CUSTOM_SCHEMA_MIN , limit ) . equal ( * av , * bv ) ;

 } ,
clone = ( x : * [ .. ] T ) -> [ .. ] T {

 out : [ .. ] T ;
for * e : x .* {
array_add ( * out , element ( ) . clone ( e ) ) ;
} ;
return out ;

 } ,
destroy = ( x : * [ .. ] T ) {
for * e : x .* {
element ( ) . destroy ( e ) ;
} ;
release ( x .* ) ;
x .* = .{} ;
} ,

 }


}

 // Nullable([]T) preserves null versus empty arrays; Nullable(string) preserves

 // null versus empty strings. Legacy builtin([]u8/string) stays unchanged.

 // Safe offset/count counterparts to the original unsafe array/list methods.

 write_array_range :: ( c : Codec ( $T ) , w : * core . Writer , items : [ ] T , offset , count : int ) -> bool {

 if ! valid ( c ) || w . err != . None || offset < 0 || count < 0 || offset > ( items ) . count || count > ( items ) . count - offset || count > MAX_ARRAY_ELEMENTS {
return reject_write ( w ) ;
}

 core . write_bits ( w , wire_cast ( u64 , ( count ) ) , 32 ) ;
for * e : view ( items , offset , offset + count ) {
if ! write ( c , w , e ) {
return false ;
}

 }

 return w . err == . None ;

 }

 // Reads into existing owning elements atomically; capacity/count are local.

 read_array_range :: ( c : Codec ( $T ) , r : * core . Reader , items : [ ] T , offset , count : int ) -> bool {

 if ! valid ( c ) || r . err != . None || offset < 0 || count < 0 || offset > ( items ) . count || count > ( items ) . count - offset || count > MAX_ARRAY_ELEMENTS || count > core . reader_remaining_bits ( r ) {
return reject_read ( r ) ;
}

 pending := new_slice ( T , count ) ;
defer {
for * e : pending {
c . destroy ( e ) ;
} ;
release ( pending ) ;
}

 for * e : pending {
value , ok := read_new ( c , r ) ;
if ! ok {
return false ;
} ;
e .* = value ;
}

 for * e , i : pending {
c . destroy ( * items [ offset + i ] ) ;
items [ offset + i ] = e .* ;
e .* = .{

 } ;

 }

 return true ;

 }

 skip :: ( c : Codec ( $T ) , r : * core . Reader ) -> bool {

 value , ok := read_new ( c , r ) ;
if ok {
c . destroy ( * value ) ;
}

 return ok ;

 }

 //@endregion


//@region Owning dictionary payloads (not synchronized collection members)

 Value_Entry :: struct ( K , V : Type ) {
key : K ;
value : V ;
}

 Value_Map :: struct ( K , V : Type ) {
entries : [ .. ] Value_Entry ( K , V ) ;
}

 // Explicit ordered entry storage avoids a constraint on native Odin hash keys

 // and keeps every encoded key/value owned independently. Duplicate keys reject.

 map_codec :: ( $K , $V : Type , $key : #type ( ) -> Codec ( K ) , $value : #type ( ) -> Codec ( V ) , schema : u32 , $limit : int ) -> Codec ( Value_Map ( K , V ) ) {

 if schema < CUSTOM_SCHEMA_MIN || ! valid ( key ( ) ) || ! valid ( value ( ) ) || limit < 0 || limit > MAX_ARRAY_ELEMENTS {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , x : * Value_Map ( K , V ) ) -> bool {

 if ( x . entries ) . count > limit {
return reject_write ( w ) ;
}

 for * entry , i : x . entries {

 for * earlier : view ( x . entries , 0 , i ) {
if key ( ) . equal ( * entry . key , * earlier . key ) {
return reject_write ( w ) ;
}

 }


}

 core . write_bits ( w , wire_cast ( u64 , ( ( x . entries ) . count ) ) , 32 ) ;
for * entry : x . entries {
if ! write ( key ( ) , w , * entry . key ) || ! write ( value ( ) , w , * entry . value ) {
return false ;
}

 }

 return w . err == . None ;

 } ,
read = ( r : * core . Reader , x : * Value_Map ( K , V ) ) -> bool {

 n := core . read_bits ( r , 32 ) ;
if r . err != . None || n > wire_cast ( u64 , ( limit ) ) || n > wire_cast ( u64 , ( core . reader_remaining_bits ( r ) / 2 ) ) {
return reject_read ( r ) ;
}

 loop_index := 0 ; while loop_index < ( cast ( int ) ( n ) ) { defer loop_index += 1 ;

 k , ok := read_new ( key ( ) , r ) ;
if ! ok {
return false ;
}

 duplicate := false ;
for * entry : x . entries {
if key ( ) . equal ( * entry . key , * k ) {
duplicate = true ;
break ;
}

 }

 if duplicate {
key ( ) . destroy ( * k ) ;
return reject_read ( r ) ;
}

 val , good := read_new ( value ( ) , r ) ;
if ! good {
key ( ) . destroy ( * k ) ;
return false ;
}

 array_add ( * x . entries , Value_Entry ( K , V ) .{
k , val
} ) ;

 } ;

 return true ;

 } ,
equal = ( a , b : * Value_Map ( K , V ) ) -> bool {

 if ( a . entries ) . count != ( b . entries ) . count {
return false ;
}

 for * entry : a . entries {

 found := false ;
for * other : b . entries {
if key ( ) . equal ( * entry . key , * other . key ) {
if ! value ( ) . equal ( * entry . value , * other . value ) {
return false ;
} ;
found = true ;
break ;
}

 }

 if ! found {
return false ;
}


}

 return true ;

 } ,
clone = ( x : * Value_Map ( K , V ) ) -> Value_Map ( K , V ) {

 out : Value_Map ( K , V ) ;
for * entry : x . entries {
array_add ( * out . entries , Value_Entry ( K , V ) .{
key ( ) . clone ( * entry . key ) , value ( ) . clone ( * entry . value )
} ) ;
} ;

 return out ;

 } ,
destroy = ( x : * Value_Map ( K , V ) ) {
for * entry : x . entries {
key ( ) . destroy ( * entry . key ) ;
value ( ) . destroy ( * entry . value ) ;
} ;
release ( x . entries ) ;
x .* = .{

 } ;

 } ,

 }


}

 //@endregion


//@region Byte segments and genuinely allocation-free reads

 // A segment is a []u8 sub-slice; its count is len, offset is already reflected

 // in data. The codec owns read/clone results and never frees a borrowed input.

 byte_segment_codec :: ( ) -> Codec ( [ ] u8 ) {
return builtin ( [ ] u8 ) ;
}

 write_bytes_raw :: ( w : * core . Writer , bytes : [ ] u8 ) -> bool {

 if ( bytes ) . count > MAX_BYTES {
return reject_write ( w ) ;
}

 for b : bytes {
core . write_bits ( w , wire_cast ( u64 , ( b ) ) , 8 ) ;
}

 return w . err == . None ;

 }

 // No heap allocation, even on an unaligned reader. Validate the entire raw byte

 // budget first, so truncation cannot leave a partially modified output buffer.

 read_bytes_into :: ( r : * core . Reader , out : [ ] u8 ) -> bool {

 if r . err != . None || ( out ) . count > MAX_BYTES || ( out ) . count > core . reader_remaining_bits ( r ) / 8 {
return reject_read ( r ) ;
}

 for * b : out {
b .* = wire_cast ( u8 , ( core . read_bits ( r , 8 ) ) ) ;
}

 return true ;

 }

 // Borrow the packet itself only when aligned. No owning Codec ever returns

 // this view; it dies with the caller's reader input. Unaligned use read_bytes_into.

 read_bytes_view :: ( r : * core . Reader , count : int ) -> ( [ ] u8 , bool ) {

 if r . err != . None || count < 0 || count > MAX_BYTES || count > core . reader_remaining_bits ( r ) / 8 || r . bit_position % 8 != 0 {
return .[ ] , reject_read ( r ) ;
}

 offset := r . bit_position / 8 ;
r . bit_position += count * 8 ;
return view ( r . data , offset , offset + count ) , true ;

 }

 //@endregion



 // Cast semantics adapted. 
