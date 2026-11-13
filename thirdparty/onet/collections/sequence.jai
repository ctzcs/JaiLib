#scope_file
core :: #import "thirdparty/onet/core" ;
v :: #import "thirdparty/onet/values" ;
#scope_export


//@region Storage and lifetime

 MAX_ELEMENTS :: 65536 ;
MAX_OPERATIONS :: 65536 ;
DEFAULT_LIMIT :: 4096 ;
WIRE_MAGIC :: ( cast , trunc ( u64 ) ( 0x4e434f31 ) ) ;
Kind :: enum u8 {
List = 1 ; Array = 2 ; Queue = 3 ; Dictionary = 4 ; HashSet = 5 ;
}

 Operation :: enum u8 {
Set = 1 ; Insert = 2 ; Remove = 3 ; Clear = 4 ; Resize = 5 ; Fill = 6 ;
}

 Change :: struct ( T : Type ) {
operation : Operation ;
index : int ;
value : T ;
}


// List/Array/Queue share typed storage, but kind is checked on every mutation

 // and on the wire. Never modify these owning fields directly or copy owners.

 Sequence :: struct ( T : Type ) {

 codec : v . Codec ( T ) ;

 kind : Kind ;

 limit : int ;

 items : [ .. ] T ;

 previous : [ .. ] T ;

 changes : [ .. ] Change ( T ) ;

 revision : u64 ;

 base_revision : u64 ;

 timeline : Timeline ;

 history : [ .. ] Sequence_Snapshot ( T ) ;

 journal : [ .. ] Sequence_Event ( T ) ;

 events : [ .. ] Change ( T ) ;

 applied : [ .. ] Sequence_Event ( T ) ;

 applied_cursor : int ;


}

 List :: struct ( T : Type ) {
using state : Sequence ( T ) ;
}

 Array :: struct ( T : Type ) {
using state : Sequence ( T ) ;
}

 Queue :: struct ( T : Type ) {
using state : Sequence ( T ) ;
}

 // Generic procedures take ^Sequence(T); pass &list.state (etc.) explicitly.


list_init :: ( s : * Sequence ( $T ) , c : v . Codec ( T ) , limit := DEFAULT_LIMIT ) -> bool {

 if ! v . valid ( c ) || limit < 0 || limit > MAX_ELEMENTS {
return false ;
}

 s .* = .{
codec = c , kind = . List , limit = limit ,
} ;

 return true ;

 }

 queue_init :: ( s : * Sequence ( $T ) , c : v . Codec ( T ) , limit := DEFAULT_LIMIT ) -> bool {

 if ! list_init ( s , c , limit ) {
return false ;
}

 s . kind = . Queue ;
return true ;

 }

 // Array length is logical, not fixed: Resize is the only structural mutation.

 // Zero T must be a valid default for array element codecs (grow/Clear).

 array_init :: ( s : * Sequence ( $T ) , c : v . Codec ( T ) , initial : [ ] T , limit := MAX_ELEMENTS ) -> bool {

 if ( initial ) . count > limit || ! list_init ( s , c , limit ) {
return false ;
}

 s . kind = . Array ;
for * x : initial {

 array_add ( * s . items , c . clone ( x ) ) ;
array_add ( * s . previous , c . clone ( x ) ) ;

 }

 return true ;

 }

 destroy_items :: ( c : v . Codec ( $T ) , a : * [ .. ] T ) {

 for * x : a .* {
c . destroy ( x ) ;
}

 release ( a .* ) ;
a .* = .{ } ;

 }

 destroy_changes :: ( s : * Sequence ( $T ) ) {

 for * ch : s . changes {

 sequence_destroy_change ( s , ch ) ;

 }

 release ( s . changes ) ;
s . changes = .{ } ;

 }

 destroy :: ( s : * Sequence ( $T ) ) {

 if v . valid ( s . codec ) {

 destroy_items ( s . codec , * s . items ) ;
destroy_items ( s . codec , * s . previous ) ;
destroy_changes ( s ) ;
sequence_destroy_timeline ( s ) ;

 }

 s .* = .{

 } ;


}

 // Call once at the start of a simulation tick. previous remains an independent

 // deep snapshot until the next call; deltas cover precisely this baseline.

 begin_tick :: ( s : * Sequence ( $T ) ) {

 s . timeline . tick += 1 ;
s . timeline . started = true ;
s . timeline . rotated = false ;
sequence_before_change ( s ) ;
destroy_changes ( s ) ;
s . base_revision = s . revision ;
sequence_clear_events ( s ) ;
sequence_compact_applied ( s ) ;

 }

 changed :: ( s : * Sequence ( $T ) ) -> bool {
return s . revision != s . base_revision ;
}

 count :: ( s : * Sequence ( $T ) ) -> int {
return ( s . items ) . count ;
}

 // Borrowed result: do not mutate/free; invalidated by mutation/destroy.

 get :: ( s : * Sequence ( $T ) , index : int , previous := false ) -> ( T , bool ) {

 a := view ( s . items , 0 ) ;
if previous {
a = view ( s . previous , 0 ) ;
}

 if index < 0 || index >= ( a ) . count {
return .{

 } , false ;
} ;

 return a [ index ] , true ;

 }

 can_change :: ( s : * Sequence ( $T ) ) -> bool {

 return ! s . timeline . replaying && v . valid ( s . codec ) && s . revision < ( cast , trunc ( u64 ) ( 18446744073709551615 ) ) && ( s . changes ) . count < MAX_OPERATIONS ;

 }

 //@endregion


//@region Mutations

 set :: ( s : * Sequence ( $T ) , index : int , input : T ) -> bool {

 value := input ;
if s . timeline . replaying {
return false ;
}

 if s . kind != . List && s . kind != . Array {
return false ;
}

 if index < 0 || index >= ( s . items ) . count {
return false ;
}

 if s . codec . equal ( * s . items [ index ] , * value ) {
return true ;
}

 if ! can_change ( s ) {
return false ;
}

 // Clone before destroy, so assigning a borrowed existing value is safe.

 x := s . codec . clone ( * value ) ;
log := s . codec . clone ( * value ) ;
sequence_before_change ( s ) ;
s . codec . destroy ( * s . items [ index ] ) ;
s . items [ index ] = x ;
array_add ( * s . changes , Change ( T ) .{ . Set , index , log
} ) ;
s . revision += 1 ;
sequence_record ( s , s . changes [ ( s . changes ) . count - 1 ] ) ;
return true ;

 }

 insert :: ( s : * Sequence ( $T ) , index : int , input : T ) -> bool {

 value := input ;
if s . kind != . List && s . kind != . Queue {
return false ;
}

 if s . kind == . Queue && index != ( s . items ) . count {
return false ;
}

 if ! can_change ( s ) || index < 0 || index > ( s . items ) . count || ( s . items ) . count >= s . limit {
return false ;
}

 x := s . codec . clone ( * value ) ;
log := s . codec . clone ( * value ) ;
sequence_before_change ( s ) ;
array_add ( * s . items , x ) ;
{ i := ( s . items ) . count - 1 ; while i > index { defer i -= 1 ;
s . items [ i ] = s . items [ i - 1 ] ;
} }

 s . items [ index ] = x ;
array_add ( * s . changes , Change ( T ) .{ . Insert , index , log
} ) ;
s . revision += 1 ;
sequence_record ( s , s . changes [ ( s . changes ) . count - 1 ] ) ;
return true ;

 }

 add :: ( s : * Sequence ( $T ) , value : T ) -> bool {
return insert ( s , ( s . items ) . count , value ) ;
}

 enqueue :: ( s : * Sequence ( $T ) , value : T ) -> bool {

 if s . kind != . Queue {
return false ;
}

 return add ( s , value ) ;

 }

 remove_at :: ( s : * Sequence ( $T ) , index : int ) -> bool {

 if s . kind != . List && s . kind != . Queue {
return false ;
}

 if s . kind == . Queue && index != 0 {
return false ;
}

 if ! can_change ( s ) || index < 0 || index >= ( s . items ) . count {
return false ;
}

 sequence_before_change ( s ) ;
removed : T ;
if s . kind == . Queue {
removed = s . codec . clone ( * s . items [ index ] ) ;
}

 s . codec . destroy ( * s . items [ index ] ) ;
{ i := index ; while i < ( s . items ) . count - 1 { defer i += 1 ;
s . items [ i ] = s . items [ i + 1 ] ;
} }

 pop ( * s . items ) ;
array_add ( * s . changes , Change ( T ) .{
operation = . Remove , index = index , value = removed
} ) ;
s . revision += 1 ;
sequence_record ( s , s . changes [ ( s . changes ) . count - 1 ] ) ;
return true ;

 } ;

 // Returned item is an owned clone; caller must codec.destroy it.

 dequeue :: ( s : * Sequence ( $T ) ) -> ( T , bool ) {

 if s . kind != . Queue || ( s . items ) . count == 0 || ! can_change ( s ) {
return .{

 } , false ;
} ;

 out := s . codec . clone ( * s . items [ 0 ] ) ;
remove_at ( s , 0 ) ;
return out , true ;

 }

 // Fill records one operation, including identical values and empty arrays.

 // Clone the argument before any destruction.

 fill :: ( s : * Sequence ( $T ) , input : T ) -> bool {

 if s . kind != . Array || ! can_change ( s ) {
return false ;
}

 value := input ;
owned := s . codec . clone ( * value ) ;
defer s . codec . destroy ( * owned ) ;
log := s . codec . clone ( * owned ) ;
sequence_before_change ( s ) ;
for * x : s . items {

 s . codec . destroy ( x ) ;
x .* = s . codec . clone ( * owned ) ;

 }

 array_add ( * s . changes , Change ( T ) .{
operation = . Fill , value = log
} ) ;
s . revision += 1 ;
sequence_record ( s , s . changes [ ( s . changes ) . count - 1 ] ) ;
return true ;

 } ;

 resize :: ( s : * Sequence ( $T ) , length : int ) -> bool {

 if s . timeline . replaying {
return false ;
}

 if s . kind != . Array || length < 0 || length > s . limit || length > MAX_ELEMENTS {
return false ;
}

 if length == ( s . items ) . count {
return true ;
}

 if ! can_change ( s ) {
return false ;
}

 sequence_before_change ( s ) ;
while ( s . items ) . count > length {

 s . codec . destroy ( * s . items [ ( s . items ) . count - 1 ] ) ;
pop ( * s . items ) ;

 }

 zero : T ;
while ( s . items ) . count < length {
array_add ( * s . items , s . codec . clone ( * zero ) ) ;
}

 array_add ( * s . changes , Change ( T ) .{
operation = . Resize , index = length
} ) ;
s . revision += 1 ;
sequence_record ( s , s . changes [ ( s . changes ) . count - 1 ] ) ;
return true ;

 } ;

 clear :: ( s : * Sequence ( $T ) ) -> bool {

 if s . timeline . replaying {
return false ;
}

 if s . kind != . List && s . kind != . Queue && s . kind != . Array {
return false ;
}

 if ( s . items ) . count == 0 && ( s . changes ) . count == 0 {
return true ;
}

 if ! can_change ( s ) {
return false ;
}

 sequence_before_change ( s ) ;
if s . kind == . Array {

 zero : T ;
for * x : s . items {

 s . codec . destroy ( x ) ;
x .* = s . codec . clone ( * zero ) ;

 }


} else {
destroy_items ( s . codec , * s . items ) ;
}

 array_add ( * s . changes , Change ( T ) .{
operation = . Clear
} ) ;
s . revision += 1 ;
sequence_record ( s , s . changes [ ( s . changes ) . count - 1 ] ) ;
return true ;

 } ;

 //@endregion


//@region Transactional local wire protocol

 write_header :: ( w : * core . Writer , kind : Kind , schema : u32 , delta : bool , base , revision : u64 , n : int ) {

 core . write_bits ( w , WIRE_MAGIC , 32 ) ;
core . write_bits ( w , ( cast , trunc ( u64 ) ( kind ) ) , 8 ) ;
core . write_bits ( w , ( cast , trunc ( u64 ) ( schema ) ) , 32 ) ;
core . write_bits ( w , ( cast , trunc ( u64 ) ( ( cast , trunc ( u8 ) ( delta ) ) ) ) , 8 ) ;
core . write_bits ( w , base , 64 ) ;
core . write_bits ( w , revision , 64 ) ;
core . write_bits ( w , ( cast , trunc ( u64 ) ( n ) ) , 32 ) ;

 }

 read_header :: ( r : * core . Reader , kind : Kind , schema : u32 , delta : bool ) -> ( base : u64 , revision : u64 , n : int , ok : bool ) {

 magic := core . read_bits ( r , 32 ) ;
k := core . read_bits ( r , 8 ) ;
sc := core . read_bits ( r , 32 ) ;
mode := core . read_bits ( r , 8 ) ;
base = core . read_bits ( r , 64 ) ;
revision = core . read_bits ( r , 64 ) ;
n = ( cast ( int ) ( core . read_bits ( r , 32 ) ) ) ;
if r . err != . None || magic != WIRE_MAGIC || k != ( cast , trunc ( u64 ) ( kind ) ) || sc != ( cast , trunc ( u64 ) ( schema ) ) || mode != ( cast , trunc ( u64 ) ( ( cast , trunc ( u8 ) ( delta ) ) ) ) {

 v . reject_read ( r ) ;
return ;

 }

 ok = true ;
return ;

 }

 write_full :: ( s : * Sequence ( $T ) , w : * core . Writer ) -> bool {

 if ! v . valid ( s . codec ) || ( s . items ) . count > s . limit || w . err != . None {
return v . reject_write ( w ) ;
}

 write_header ( w , s . kind , s . codec . schema , false , 0 , s . revision , ( s . items ) . count ) ;
for * x : s . items {
if ! v . write ( s . codec , w , x ) {
return false ;
}

 }

 return w . err == . None ;

 }

 write_delta :: ( s : * Sequence ( $T ) , w : * core . Writer ) -> bool {

 if ! v . valid ( s . codec ) || w . err != . None || s . revision - s . base_revision != ( cast , trunc ( u64 ) ( ( s . changes ) . count ) ) {
return v . reject_write ( w ) ;
}

 write_header ( w , s . kind , s . codec . schema , true , s . base_revision , s . revision , ( s . changes ) . count ) ;
for * ch : s . changes {

 core . write_bits ( w , ( cast , trunc ( u64 ) ( ch .* . operation ) ) , 8 ) ;
core . write_bits ( w , ( cast , trunc ( u64 ) ( ch .* . index ) ) , 32 ) ;
if ch .* . operation == . Set || ch .* . operation == . Insert || ch .* . operation == . Fill {

 if ! v . write ( s . codec , w , * ch . value ) {
return false ;
}


}


}

 return w . err == . None ;

 }

 apply_full :: ( s : * Sequence ( $T ) , r : * core . Reader ) -> bool {

 if ! v . valid ( s . codec ) {
return v . reject_read ( r ) ;
}

 base , revision , n , ok := read_header ( r , s . kind , s . codec . schema , false ) ;
if ! ok || base != 0 || n > s . limit || n > MAX_ELEMENTS || n > core . reader_remaining_bits ( r ) {
return v . reject_read ( r ) ;
}

 tmp := Sequence ( T ) .{
codec = s . codec , kind = s . kind , limit = s . limit , revision = revision , base_revision = revision ,
} ;

 tmp . timeline = s . timeline ;
tmp . timeline . head_tick = s . timeline . tick ;
tmp . timeline . rotated = false ;
tmp . timeline . has_remote = false ;
tmp . timeline . remote_revision = 0 ;
defer destroy ( * tmp ) ;
{ loop_index := 0 ; while loop_index < n { defer loop_index += 1 ;

 x , good := v . read_new ( s . codec , r ) ;
if ! good {
return false ;
}

 array_add ( * tmp . items , x ) ;

 } }

 for * x : tmp . items {
array_add ( * tmp . previous , s . codec . clone ( x ) ) ;
}

 destroy ( s ) ;
s .* = tmp ;
tmp = .{

 } ;

 return true ;

 }

 apply_delta :: ( s : * Sequence ( $T ) , r : * core . Reader ) -> bool {

 if ! v . valid ( s . codec ) {
return v . reject_read ( r ) ;
}

 base , revision , n , ok := read_header ( r , s . kind , s . codec . schema , true ) ;
if ! ok || base != s . revision || n > MAX_OPERATIONS - ( s . changes ) . count || n > core . reader_remaining_bits ( r ) / 40 || ( cast , trunc ( u64 ) ( n ) ) > ( cast , trunc ( u64 ) ( 18446744073709551615 ) ) - base || revision != base + ( cast , trunc ( u64 ) ( n ) ) {
return v . reject_read ( r ) ;
}

 tmp := Sequence ( T ) .{
codec = s . codec , kind = s . kind , limit = s . limit , revision = base , base_revision = s . base_revision ,
} ;

 defer destroy ( * tmp ) ;
for * x : s . items {
array_add ( * tmp . items , s . codec . clone ( x ) ) ;
}

 for * x : s . previous {
array_add ( * tmp . previous , s . codec . clone ( x ) ) ;
}

 for * ch : s . changes {

 copied := ch .* ;
copied = sequence_clone_change ( s , ch .* ) ;
array_add ( * tmp . changes , copied ) ;

 }

 sequence_clone_timeline ( * tmp , s ) ;
replaying := tmp . timeline . replaying ;
tmp . timeline . replaying = false ; // Wire application is not a local write.

 { loop_index := 0 ; while loop_index < n { defer loop_index += 1 ;

 op := core . read_bits ( r , 8 ) ;
index := ( cast ( int ) ( core . read_bits ( r , 32 ) ) ) ;
if r . err != . None {
return false ;
}

 if op == {

 case ( cast , trunc ( u64 ) ( Operation . Set ) ) , ( cast , trunc ( u64 ) ( Operation . Insert ) ) ;
// Check indices and family semantics before invoking a value decoder.

 if op == ( cast , trunc ( u64 ) ( Operation . Set ) ) {

 if ( tmp . kind != . List && tmp . kind != . Array ) || index >= ( tmp . items ) . count {
return v . reject_read ( r ) ;
}


} else {

 if ( tmp . kind != . List && tmp . kind != . Queue ) || index > ( tmp . items ) . count || ( tmp . items ) . count >= tmp . limit || ( tmp . kind == . Queue && index != ( tmp . items ) . count ) {
return v . reject_read ( r ) ;
}


}

 x , good := v . read_new ( s . codec , r ) ;
if ! good {
return false ;
}

 before := tmp . revision ;
applied := false ;
if op == ( cast , trunc ( u64 ) ( Operation . Set ) ) {
applied = set ( * tmp , index , x ) ;
}

 else {
applied = insert ( * tmp , index , x ) ;
}

 s . codec . destroy ( * x ) ;
// No-op setters are not legal log operations.

 if ! applied || tmp . revision != before + 1 {
return v . reject_read ( r ) ;
}

 case ( cast , trunc ( u64 ) ( Operation . Remove ) ) ;
if ! remove_at ( * tmp , index ) {
return v . reject_read ( r ) ;
}

 case ( cast , trunc ( u64 ) ( Operation . Clear ) ) ;
if index != 0 || ( ( tmp . items ) . count == 0 && ( tmp . changes ) . count == 0 ) || ! clear ( * tmp ) {
return v . reject_read ( r ) ;
}

 case ( cast , trunc ( u64 ) ( Operation . Resize ) ) ;
if tmp . kind != . Array || index == ( tmp . items ) . count || ! resize ( * tmp , index ) {
return v . reject_read ( r ) ;
}

 case ( cast , trunc ( u64 ) ( Operation . Fill ) ) ;
if tmp . kind != . Array || index != 0 {
return v . reject_read ( r ) ;
}

 x , good := v . read_new ( s . codec , r ) ;
if ! good {
return false ;
}

 applied := fill ( * tmp , x ) ;
s . codec . destroy ( * x ) ;
if ! applied {
return v . reject_read ( r ) ;
}

 case ;
return v . reject_read ( r ) ;

 }


} }

 if r . err != . None || tmp . revision != revision {
return v . reject_read ( r ) ;
}

 tmp . timeline . replaying = replaying ;
destroy ( s ) ;
s .* = tmp ;
tmp = .{

 } ;

 return true ;

 }

 //@endregion


// Cast semantics adapted. 

 // Loop scopes adapted. 

 // Iterator semantics adapted. 
