// Internal allocation and wire helpers. No dependency on JaiLib core/kit/Foster.
#scope_module
H :: #import "Hash_Table" ;
Str :: #import "String" ;
operator + :: ( a : [ $N ] $T , b : [ N ] T ) -> [ N ] T { r : [ N ] T ; for x , i : a r [ i ] = x + b [ i ] ; return r ; }
operator == :: ( a : [ $N ] $T , b : [ N ] T ) -> bool { for x , i : a if x != b [ i ] return false ; return true ; }
operator - :: ( a : [ $N ] $T , b : [ N ] T ) -> [ N ] T { r : [ N ] T ; for x , i : a r [ i ] = x - b [ i ] ; return r ; }
operator - :: ( a : [ $N ] $T ) -> [ N ] T { r : [ N ] T ; for x , i : a r [ i ] = - x ; return r ; }
operator * :: ( a : [ $N ] $T , b : T ) -> [ N ] T { r : [ N ] T ; for x , i : a r [ i ] = x * b ; return r ; }
operator / :: ( a : [ $N ] $T , b : T ) -> [ N ] T { r : [ N ] T ; for x , i : a r [ i ] = x / b ; return r ; }
#if OS == . WINDOWS {
Clock :: #import "Windows" ;
monotonic_seconds :: ( ) -> float64 {
count , frequency : s64 ;
assert ( Clock . QueryPerformanceCounter ( * count ) != 0 ) ;
assert ( Clock . QueryPerformanceFrequency ( * frequency ) != 0 && frequency > 0 ) ;
return cast ( float64 ) count / cast ( float64 ) frequency ;
}
} else {
Clock :: #import "POSIX" ;
monotonic_seconds :: ( ) -> float64 {
t : Clock . timespec ;
assert ( Clock . clock_gettime ( Clock . clockid_t . MONOTONIC , * t ) == 0 ) ;
return cast ( float64 ) t . tv_sec + cast ( float64 ) t . tv_nsec / 1.0e9 ;
}
}
new_table :: ( $K : Type , $V : Type , allocator : Allocator = context . allocator ,
$hash_function : ( K ) -> u32 = null , $compare_function : ( K , K ) -> bool = null ) -> H . Table ( K , V , hash_function , compare_function ) {
t : H . Table ( K , V , hash_function , compare_function ) ; t . allocator = allocator ; return t ;
}
table_get :: ( table : * H . Table ( $K , $V , $HF , $EF ) , key : table . Key_Type ) -> table . Value_Type , bool {
p := H . table_find_pointer ( table , key ) ;
if p == null return .{ } , false ;
return p .* , true ;
}
release :: ( t : H . Table ( $K , $V , $HF , $EF ) ) { H . deinit ( * t ) ; }
array_reset_keeping_memory :: ( t : * H . Table ( $K , $V , $HF , $EF ) ) { H . table_reset_keeping_memory ( t ) ; }
new_one :: ( $T : Type , allocator : Allocator = context . allocator ) -> * T {
push_allocator ( allocator ) ; return New ( T ) ;
}
free :: ( memory : * void , allocator : Allocator ) {
if memory == null return ;
push_allocator ( allocator ) ; free ( memory ) ;
}
new_slice :: ( $T : Type , count : int , allocator : Allocator = context . allocator ) -> [ ] T {
push_allocator ( allocator ) ; return NewArray ( count , T ) ;
}
new_dynamic :: ( $T : Type , count : int = 0 , capacity : int = 0 , allocator : Allocator = context . allocator ) -> [ .. ] T {
push_allocator ( allocator ) ;
result : [ .. ] T ; array_reserve ( * result , max ( count , capacity ) ) ; array_resize ( * result , count ) ; return result ;
}
new_dynamic :: ( $T : Type , allocator : Allocator ) -> [ .. ] T { return new_dynamic ( T , 0 , 0 , allocator ) ; }
release :: ( a : [ ] $T , allocator : Allocator = context . allocator ) {
if a . data == null return ;
push_allocator ( allocator ) ; free ( a . data ) ;
}
release :: ( a : [ .. ] $T ) { array_free ( a ) ; }
release :: ( s : string , allocator : Allocator = context . allocator ) {
if s . data == null return ;
push_allocator ( allocator ) ; free ( s . data ) ;
}
view :: ( a : [ ] $T , start : int , end : int = - 1 ) -> [ ] T {
if end < 0 end = a . count ;
assert ( start >= 0 && end >= start && end <= a . count ) ;
return array_view ( a , start , end - start ) ;
}
copy_samples :: ( dest : [ ] $T , src : [ ] T ) {
n := min ( dest . count , src . count ) ;
if cast ( u64 ) dest . data > cast ( u64 ) src . data {
i := n ; while i > 0 { i -= 1 ; dest [ i ] = src [ i ] ; }
} else {
i := 0 ; while i < n { dest [ i ] = src [ i ] ; i += 1 ; }
}
}
bit_cast :: ( $T : Type , value : $U ) -> T {
#assert size_of ( T ) == size_of ( U ) ;
return ( cast ( * T ) * value ) .* ;
}
// Explicit modulo conversion for integer wire carriers; float conversions stay checked.
wire_cast :: ( $T : Type , value : $U ) -> T {
#if U == float32 || U == float64 || T == float32 || T == float64 {
return cast ( T ) value ;
} else {
result : T ;
source := cast ( * u8 ) * value ;
dest := cast ( * u8 ) * result ;
fill : u8 ;
#if U == s8 || U == s16 || U == s32 || U == s64 {
if value < 0 fill = 0xff ;
}
i := 0 ; while i < size_of ( T ) { dest [ i ] = fill ; i += 1 ; }
probe : u16 = 1 ;
little := ( cast ( * u8 ) * probe ) .* == 1 ;
i = 0 ; while i < min ( size_of ( T ) , size_of ( U ) ) {
if little dest [ i ] = source [ i ] ;
else dest [ size_of ( T ) - 1 - i ] = source [ size_of ( U ) - 1 - i ] ;
i += 1 ;
}
return result ;
}
}

