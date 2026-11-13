#scope_file

 #scope_export


//@region Typed numeric convenience (existing Reader/Writer are unchanged)

 Delta_Check_Mode :: enum {
Checked ; Unchecked ;
}

 typed_integer_write :: ( w : * Writer , value : $T , level : Compression_Level = . Loose ) -> bool {

 #if T == s8 {
write_int8 ( w , value , level ) ;
}

 else #if T == s16 {
write_int16 ( w , value , level ) ;
}

 else #if T == s32 {
write_int32 ( w , value , level ) ;
}

 else #if T == s64 {
write_int64 ( w , value , level ) ;
}

 else #if T == u8 {
write_uint8 ( w , value , level ) ;
}

 else #if T == u16 {
write_uint16 ( w , value , level ) ;
}

 else #if T == u32 {
write_uint32 ( w , value , level ) ;
}

 else #if T == u64 {
write_uint64 ( w , value , level ) ;
}

 else {
#assert ( false , "expected explicit 8/16/32/64-bit integer" ) ;
}

 return w . err == . None ;

 }

 typed_integer_read :: ( r : * Reader , $T : Type , level : Compression_Level = . Loose ) -> T {

 #if T == s8 {
return read_int8 ( r , level ) ;
}

 else #if T == s16 {
return read_int16 ( r , level ) ;
}

 else #if T == s32 {
return read_int32 ( r , level ) ;
}

 else #if T == s64 {
return read_int64 ( r , level ) ;
}

 else #if T == u8 {
return read_uint8 ( r , level ) ;
}

 else #if T == u16 {
return read_uint16 ( r , level ) ;
}

 else #if T == u32 {
return read_uint32 ( r , level ) ;
}

 else #if T == u64 {
return read_uint64 ( r , level ) ;
}

 else {
#assert ( false , "expected explicit 8/16/32/64-bit integer" ) ;
}


}

 // Returns (written, success); false/true means checked suppression, no bits.

 // Arithmetic is explicitly modulo the type width, including signed endpoints.

 typed_integer_delta_write :: ( w : * Writer , previous , next : $T , mode : Delta_Check_Mode = . Checked ) -> bool , bool {

 if w . err != . None {
return false , false ;
}

 if mode == . Checked && previous == next {
return false , true ;
}

 difference := wire_cast ( T , ( wire_cast ( u64 , ( next ) ) - wire_cast ( u64 , ( previous ) ) ) ) ;
return true , typed_integer_write ( w , difference , . Tight ) ;

 }

 typed_integer_delta_read :: ( r : * Reader , previous : $T ) -> T {

 difference := typed_integer_read ( r , T , . Tight ) ;
return wire_cast ( T , ( wire_cast ( u64 , ( previous ) ) + wire_cast ( u64 , ( difference ) ) ) ) ;

 }

 valid_accuracy :: ( accuracy : float32 ) -> bool {
return is_finite_single ( accuracy ) && accuracy >= 0 ;
}

 typed_float_delta_changed :: ( previous , next : $T , accuracy : float32 = DEFAULT_ACCURACY ) -> bool {

 #if T == float32 {

 q : s32 ;
if try_quantize_single ( next - previous , accuracy , * q ) {
return q != 0 ;
}

 return bit_cast ( u32 , previous ) != bit_cast ( u32 , next ) ;

 } else #if T == float64 {

 q : s64 ;
if try_quantize_double ( next - previous , accuracy , * q ) {
return q != 0 ;
}

 return bit_cast ( u64 , previous ) != bit_cast ( u64 , next ) ;

 } else {
#assert ( false , "expected float32 or float64" ) ;
}


}

 typed_float_delta_write :: ( w : * Writer , previous , next : $T , accuracy : float32 = DEFAULT_ACCURACY , mode : Delta_Check_Mode = . Checked ) -> bool , bool {

 if ! valid_accuracy ( accuracy ) {
fail_writer ( w , . Malformed ) ;
return false , false ;
}

 if w . err != . None {
return false , false ;
}

 #if T == float32 {

 q : s32 = RAW_SINGLE_MARKER ;
quantized := try_quantize_single ( next - previous , accuracy , * q ) ;
changed := ( ifx quantized then q != 0 else bit_cast ( u32 , previous ) != bit_cast ( u32 , next ) ) ;
if mode == . Checked && ! changed {
return false , true ;
}

 write_int32 ( w , q , . Tight ) ;
if ! quantized {
write_raw_single ( w , next ) ;
}


} else #if T == float64 {

 q : s64 = RAW_DOUBLE_MARKER ;
quantized := try_quantize_double ( next - previous , accuracy , * q ) ;
changed := ( ifx quantized then q != 0 else bit_cast ( u64 , previous ) != bit_cast ( u64 , next ) ) ;
if mode == . Checked && ! changed {
return false , true ;
}

 write_int64 ( w , q , . Tight ) ;
if ! quantized {
write_raw_double ( w , next ) ;
}


} else {
#assert ( false , "expected float32 or float64" ) ;
}

 return true , w . err == . None ;

 }

 typed_float_delta_read :: ( r : * Reader , previous : $T , accuracy : float32 = DEFAULT_ACCURACY ) -> T {

 if ! valid_accuracy ( accuracy ) {
fail_reader ( r , . Malformed ) ;
return previous ;
}

 result : T ;
#if T == float32 {
result = read_delta_single ( r , previous , accuracy ) ;
}

 else #if T == float64 {
result = read_delta_double ( r , previous , accuracy ) ;
}

 else {
#assert ( false , "expected float32 or float64" ) ;
}

 if ! is_finite_double ( ( cast ( float64 ) ( result ) ) ) {
fail_reader ( r , . Malformed ) ;
return previous ;
}

 return result ;

 }

 // Tolerance helpers: all NaNs compare equal; same-sign infinities and signed

 // zeros compare equal. Integer differences retain exact magnitude at endpoints.

 typed_tolerance :: ( a , b : $T , accuracy : float32 = DEFAULT_ACCURACY ) -> bool {

 #if T == float32 || T == float64 {

 return Math . abs ( a - b ) <= wire_cast ( T , ( accuracy ) ) || a == b || ( Math . isnan ( a ) && Math . isnan ( b ) ) ;

 } else #if (T==s8 || T==s16 || T==s32 || T==s64 || T==u8 || T==u16 || T==u32 || T==u64) {

 difference : u64 ;
#if (T==s8 || T==s16 || T==s32 || T==s64) {

 difference = ( ifx a >= b then wire_cast ( u64 , ( a ) ) - wire_cast ( u64 , ( b ) ) else wire_cast ( u64 , ( b ) ) - wire_cast ( u64 , ( a ) ) ) ;

 } else {
difference = ( ifx a >= b then wire_cast ( u64 , ( a - b ) ) else wire_cast ( u64 , ( b - a ) ) ) ;
}

 return ( cast ( float32 ) ( difference ) ) <= accuracy ;

 } else {
#assert ( false , "expected scalar integer or floating type" ) ;
}


}

 //@endregion


//@region Quaternion rotation delta

 quaternion_multiply :: ( a , b : [ 4 ] float32 ) -> [ 4 ] float32 {

 return .[

 a [ 3 ] * b [ 0 ] + a [ 0 ] * b [ 3 ] + a [ 1 ] * b [ 2 ] - a [ 2 ] * b [ 1 ] ,
a [ 3 ] * b [ 1 ] - a [ 0 ] * b [ 2 ] + a [ 1 ] * b [ 3 ] + a [ 2 ] * b [ 0 ] ,
a [ 3 ] * b [ 2 ] + a [ 0 ] * b [ 1 ] - a [ 1 ] * b [ 0 ] + a [ 2 ] * b [ 3 ] ,
a [ 3 ] * b [ 3 ] - a [ 0 ] * b [ 0 ] - a [ 1 ] * b [ 1 ] - a [ 2 ] * b [ 2 ] ,

 ] ;


}

 quaternion_unit :: ( q : [ 4 ] float32 ) -> [ 4 ] float32 , bool {

 magnitude : float64 ;
for x : q {
if ! is_finite_single ( x ) {
return .{

 } , false ;
} ;
magnitude += ( cast ( float64 ) ( x ) ) * ( cast ( float64 ) ( x ) ) ;
} ;

 if magnitude <= 0 {
return .{

 } , false ;
} ;

 scale := 1 / Math . sqrt ( magnitude ) ;
out : [ 4 ] float32 ;
for x , i : q {
out [ i ] = ( cast ( float32 ) ( ( cast ( float64 ) ( x ) ) * scale ) ) ;
}

 return out , true ;

 }

 quaternion_tolerance :: ( a , b : [ 4 ] float32 , accuracy : float32 = DEFAULT_ACCURACY ) -> bool {

 dot : float32 ;
for x , i : a {
dot += x * b [ i ] ;
}

 sign : float32 = 1 ;
if dot < 0 {
sign = - 1 ;
}

 for x , i : a {
if ! typed_tolerance ( x , b [ i ] * sign , accuracy ) {
return false ;
}

 }

 return true ;

 }

 typed_quaternion_delta_write :: ( w : * Writer , previous , next : [ 4 ] float32 , accuracy : float32 = DEFAULT_ACCURACY , mode : Delta_Check_Mode = . Checked ) -> bool , bool {

 if w . err != . None {
return false , false ;
}

 if ! valid_accuracy ( accuracy ) || accuracy == 0 {
fail_writer ( w , . Malformed ) ;
return false , false ;
}

 finite := true ;
for component : next {
if ! is_finite_single ( component ) {
finite = false ;
}

 }

 if ! finite {

 if mode == . Checked {
return false , true ;
}

 // Unchecked nonfinite delta writes identity rotation.

 write_quaternion ( w , 0 , 0 , 0 , 1 , . Tight , accuracy ) ;
return true , w . err == . None ;

 }

 a , good_a := quaternion_unit ( previous ) ;
b , good_b := quaternion_unit ( next ) ;
if ! good_a || ! good_b || ! valid_accuracy ( accuracy ) || accuracy == 0 {
fail_writer ( w , . Malformed ) ;
return false , false ;
}

 // The original delta compares components (its tolerance comparer separately

 // sign-aligns q/-q), then encodes inverse(previous)*next as smallest-three.

 changed := false ;
for x , i : a {
if Math . abs ( x - b [ i ] ) > accuracy {
changed = true ;
}

 }

 if mode == . Checked && ! changed {
return false , w . err == . None ;
}

 inverse := float32 .[ - a [ 0 ] , - a [ 1 ] , - a [ 2 ] , a [ 3 ] ] ;
delta := quaternion_multiply ( inverse , b ) ;
write_quaternion ( w , delta [ 0 ] , delta [ 1 ] , delta [ 2 ] , delta [ 3 ] , . Tight , accuracy ) ;
return true , w . err == . None ;

 }

 typed_quaternion_delta_read :: ( r : * Reader , previous : [ 4 ] float32 , accuracy : float32 = DEFAULT_ACCURACY ) -> [ 4 ] float32 {

 if ! valid_accuracy ( accuracy ) || accuracy == 0 {
fail_reader ( r , . Malformed ) ;
return previous ;
}

 x , y , z , w := read_quaternion ( r , . Tight , accuracy ) ;
out , ok := quaternion_unit ( quaternion_multiply ( previous , .[ x , y , z , w ] ) ) ;
if ! ok {
fail_reader ( r , . Malformed ) ;
return previous ;
}

 return out ;

 } ;

 //@endregion


// Cast semantics adapted. 

 // Loop scopes adapted. 
