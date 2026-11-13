#scope_file

 #scope_export
// onet core: bit-oriented Reader.

 //

 // Reads the bit stream produced by Writer. Errors are sticky: after an

 // out-of-bounds or malformed read, every subsequent read returns a zero value

 // and reader_failed(r) stays true.

 //

 // Note: Odin has no implicit method-call syntax; all procedures are called

 // explicitly as read_xxx(r, ...).




// Reads data from a packed bit buffer produced by Writer.

 Reader :: struct {

 data : [ ] u8 ;
bit_position : int ;
err : Codec_Error ;

 }


reader_init :: ( r : * Reader , data : [ ] u8 ) {

 r . data = data ;
r . bit_position = 0 ;
r . err = . None ;

 }


// Borrows the writer's buffer without copying; valid while the writer's

 // buffer lives and is not appended to.

 reader_from_writer :: ( r : * Reader , w : * Writer ) {

 n := writer_bytes_written ( w ) ;
r . data = view ( w . buffer , 0 , n ) ;
r . bit_position = 0 ;
r . err = . None ;

 }


reader_reset :: ( r : * Reader , data : [ ] u8 ) {

 reader_init ( r , data ) ;

 }


reader_error :: ( r : * Reader ) -> Codec_Error {
return r . err ;
}

 reader_failed :: ( r : * Reader ) -> bool {
return r . err != . None ;
}

 reader_valid :: ( r : * Reader ) -> bool {
return r . err == . None ;
}

 reader_remaining_bits :: ( r : * Reader ) -> int {

 return ( r . data ) . count * 8 - r . bit_position ;

 }


fail_reader :: ( r : * Reader , err : Codec_Error ) {

 if r . err == . None {

 r . err = err ;

 }


}


// ---------------------------------------------------------------------------

 // Primitive bit reads

 // ---------------------------------------------------------------------------


read_bit :: ( r : * Reader ) -> bool {

 if r . bit_position >= ( r . data ) . count * 8 {

 fail_reader ( r , . Out_Of_Bounds ) ;
return false ;

 }

 bit := ( r . data [ r . bit_position / 8 ] >> ( wire_cast ( u8 , ( 7 ) ) - wire_cast ( u8 , ( r . bit_position % 8 ) ) ) ) & 1 ;
r . bit_position += 1 ;
return bit == 1 ;

 }


// Reads bit_count bits, MSB-first.

 read_bits :: ( r : * Reader , bit_count : u32 ) -> u64 {

 if bit_count > 64 {

 fail_reader ( r , . Out_Of_Bounds ) ;
return 0 ;

 }

 if r . bit_position + ( cast ( int ) ( bit_count ) ) > ( r . data ) . count * 8 {

 fail_reader ( r , . Out_Of_Bounds ) ;
return 0 ;

 }

 result : u64 = 0 ;
{ loop_index := 0 ; while loop_index < ( cast ( int ) ( bit_count ) ) { defer loop_index += 1 ;

 result <<= 1 ;
if ( r . data [ r . bit_position / 8 ] >> ( wire_cast ( u8 , ( 7 ) ) - wire_cast ( u8 , ( r . bit_position % 8 ) ) ) ) & 1 == 1 {

 result |= 1 ;

 }

 r . bit_position += 1 ;

 } }

 return result ;

 }


read_boolean :: ( r : * Reader ) -> bool {

 return read_bit ( r ) ;

 }


read_char :: ( r : * Reader , level : Compression_Level ) -> s32 {

 return wire_cast ( s32 , read_uint16 ( r , level ) ) ;

 }


// ---------------------------------------------------------------------------

 // Numbers — exact-length compressed encoding

 // ---------------------------------------------------------------------------


read_unsigned_with_length :: ( r : * Reader , t : Numeric_Value_Type ) -> u64 {

 indicator := read_bits ( r , indicator_bits ( t ) ) ;
if r . err != . None {

 return 0 ;

 }

 return read_bits ( r , wire_cast ( u32 , indicator ) + 1 ) ;

 }


read_signed_with_length :: ( r : * Reader , t : Numeric_Value_Type ) -> u64 {

 indicator := read_bits ( r , indicator_bits ( t ) ) ;
if r . err != . None {

 return 0 ;

 }

 return read_bits ( r , wire_cast ( u32 , indicator ) + 1 ) ;

 }


read_uint8 :: ( r : * Reader , level : Compression_Level ) -> u8 {

 if level == . Uncompressed {

 return wire_cast ( u8 , read_bits ( r , 8 ) ) ;

 }

 return wire_cast ( u8 , read_unsigned_with_length ( r , . UInt8 ) ) ;

 }


read_uint16 :: ( r : * Reader , level : Compression_Level ) -> u16 {

 if level == . Uncompressed {

 return wire_cast ( u16 , read_bits ( r , 16 ) ) ;

 }

 return wire_cast ( u16 , read_unsigned_with_length ( r , . UInt16 ) ) ;

 }


read_uint32 :: ( r : * Reader , level : Compression_Level ) -> u32 {

 if level == . Uncompressed {

 return wire_cast ( u32 , read_bits ( r , 32 ) ) ;

 }

 return wire_cast ( u32 , read_unsigned_with_length ( r , . UInt32 ) ) ;

 }


read_uint64 :: ( r : * Reader , level : Compression_Level ) -> u64 {

 if level == . Uncompressed {

 return read_bits ( r , 64 ) ;

 }

 return read_unsigned_with_length ( r , . UInt64 ) ;

 }


read_int8 :: ( r : * Reader , level : Compression_Level ) -> s8 {

 if level == . Uncompressed {

 return unzigzag_i8 ( read_bits ( r , 8 ) ) ;

 }

 return unzigzag_i8 ( read_signed_with_length ( r , . Int8 ) ) ;

 }


read_int16 :: ( r : * Reader , level : Compression_Level ) -> s16 {

 if level == . Uncompressed {

 return unzigzag_i16 ( read_bits ( r , 16 ) ) ;

 }

 return unzigzag_i16 ( read_signed_with_length ( r , . Int16 ) ) ;

 }


read_int32 :: ( r : * Reader , level : Compression_Level ) -> s32 {

 if level == . Uncompressed {

 return unzigzag_i32 ( read_bits ( r , 32 ) ) ;

 }

 return unzigzag_i32 ( read_signed_with_length ( r , . Int32 ) ) ;

 }


read_int64 :: ( r : * Reader , level : Compression_Level ) -> s64 {

 if level == . Uncompressed {

 return unzigzag_i64 ( read_bits ( r , 64 ) ) ;

 }

 return unzigzag_i64 ( read_signed_with_length ( r , . Int64 ) ) ;

 }


// ---------------------------------------------------------------------------

 // Floating point

 // ---------------------------------------------------------------------------


read_single :: ( r : * Reader , level : Compression_Level , accuracy : float32 ) -> float32 {

 quantized := read_int32 ( r , level ) ;
if r . err != . None {

 return 0 ;

 }

 if quantized == RAW_SINGLE_MARKER {

 return read_raw_single ( r , 0 ) ;

 }

 return ( cast ( float32 ) quantized ) * accuracy ;

 }


read_double :: ( r : * Reader , level : Compression_Level , accuracy : float32 ) -> float64 {

 quantized := read_int64 ( r , level ) ;
if r . err != . None {

 return 0 ;

 }

 if quantized == RAW_DOUBLE_MARKER {

 return read_raw_double ( r , 0 ) ;

 }

 return ( cast ( float64 ) quantized ) * ( cast ( float64 ) accuracy ) ;

 }


// Reads raw float bits; non-finite values are refused and `previous` is

 // returned instead (mirrors Reader.ReadRawSingle).

 read_raw_single :: ( r : * Reader , previous : float32 ) -> float32 {

 bits := wire_cast ( u32 , read_bits ( r , 32 ) ) ;
if r . err != . None {

 return previous ;

 }

 value := bit_cast ( float32 , bits ) ;
if ! is_finite_single ( value ) {

 return previous ;

 }

 return value ;

 }


read_raw_double :: ( r : * Reader , previous : float64 ) -> float64 {

 bits := read_bits ( r , 64 ) ;
if r . err != . None {

 return previous ;

 }

 value := bit_cast ( float64 , bits ) ;
if ! is_finite_double ( value ) {

 return previous ;

 }

 return value ;

 }


// ---------------------------------------------------------------------------

 // Collections

 // ---------------------------------------------------------------------------


// Reads the shared count header. Returns (count, true) for a valid count,

 // (0, true) for the null marker, and (0, false) once the stream is invalid.

 read_collection_validity_with_count :: ( r : * Reader ) -> int , bool {
count : int ;
ok : bool ;


written := read_uint32 ( r , . Tight ) ;
if r . err != . None {

 return 0 , false ;

 }

 if written == {

 case NULL_COLLECTION_COUNT ;
return 0 , true ;
case INVALID_COLLECTION_COUNT ;
fail_reader ( r , . Malformed ) ;
return 0 , false ;
case ;
return ( cast ( int ) written ) - COUNT_OFFSET_AFTER_VALIDITY , true ;

 }


}


read_u8_array_with_count :: ( r : * Reader , level : Compression_Level , allocator := context . allocator ) -> [ ] u8 {

 count , ok := read_collection_validity_with_count ( r ) ;
if ! ok || count == 0 {

 return .[ ] ;

 }

 out := new_slice ( u8 , count , allocator ) ;
read_u8_array_as_bytes_unsafe ( r , out , level ) ;
if r . err != . None {

 release ( out , allocator ) ;
return .[ ] ;

 }

 return out ;

 }


read_u8_array_as_bytes_unsafe :: ( r : * Reader , out : [ ] u8 , level : Compression_Level ) {

 if ( out ) . count == 0 {

 return ;

 }

 if level == . Aggressive || level == . Tight {

 out [ 0 ] = wire_cast ( u8 , read_bits ( r , 8 ) ) ;
{ i := 1 ; while i < ( out ) . count { defer i += 1 ;

 is_lower_half := read_boolean ( r ) ;
zigzag_delta : u8 ;
if is_lower_half {

 zigzag_delta = wire_cast ( u8 , read_bits ( r , 4 ) ) ;

 } else {

 zigzag_delta = wire_cast ( u8 , read_bits ( r , 8 ) ) ;

 }

 if r . err != . None {

 return ;

 }

 delta_mask : u8 = 0 ;
if ( zigzag_delta & 1 ) == 1 {

 delta_mask = 0xFF ;

 }

 delta := wire_cast ( s8 , ( ( zigzag_delta >> 1 ) ^ delta_mask ) ) ;
out [ i ] = wire_cast ( u8 , ( wire_cast ( s16 , wire_cast ( s8 , out [ i - 1 ] ) ) + wire_cast ( s16 , delta ) ) ) ;

 } }

 return ;

 }

 { i := 0 ; while i < ( out ) . count { defer i += 1 ;

 out [ i ] = wire_cast ( u8 , read_bits ( r , 8 ) ) ;

 } }


}


// Reads a length-prefixed UTF-8 string. The returned string borrows a fresh

 // allocation owned by the caller; free it with the same allocator.

 read_string :: ( r : * Reader , level : Compression_Level , allocator := context . allocator ) -> string {

 count , ok := read_collection_validity_with_count ( r ) ;
if ! ok || count == 0 {

 return "" ;

 }

 buf := new_slice ( u8 , count , allocator ) ;
read_u8_array_as_bytes_unsafe ( r , buf , level ) ;
if r . err != . None {

 release ( buf , allocator ) ;
return "" ;

 }

 return ( cast ( string ) ( buf ) ) ;

 }


// ---------------------------------------------------------------------------

 // Guid, quaternion

 // ---------------------------------------------------------------------------


read_guid :: ( r : * Reader ) -> u128 {
value : u128 ;
for i : 0 .. 15 {
b := read_bits ( r , 8 ) ;
if r . err != . None return .{ } ;
if i < 8 value . low |= b << ( i * 8 ) ;
else value . high |= b << ( ( i - 8 ) * 8 ) ;
}
return value ;
}

 // Reads a smallest-three encoded quaternion.

 read_quaternion :: ( r : * Reader , level : Compression_Level , accuracy : float32 ) -> float32 , float32 , float32 , float32 {
x : float32 ;
y : float32 ;
z : float32 ;
w : float32 ;


largest_index := ( cast ( int ) read_bits ( r , 2 ) ) ;
is_largest_positive := read_bit ( r ) ;
if r . err != . None {

 return 0 , 0 , 0 , 1 ;

 }


c0 := read_quaternion_single ( r , accuracy ) ;
c1 := read_quaternion_single ( r , accuracy ) ;
c2 := read_quaternion_single ( r , accuracy ) ;
if r . err != . None {

 return 0 , 0 , 0 , 1 ;

 }


// The largest axis is implied: sign * sqrt(1 - sum of squares).

 sum_squares := ( cast ( float64 ) c0 ) * ( cast ( float64 ) c0 ) + ( cast ( float64 ) c1 ) * ( cast ( float64 ) c1 ) + ( cast ( float64 ) c2 ) * ( cast ( float64 ) c2 ) ;
largest := Math . sqrt ( max ( ( cast ( float64 ) 0.0 ) , 1.0 - sum_squares ) ) ;
if ! is_largest_positive {

 largest = - largest ;

 }


// Undo the writer's swap trick: the three carried values sit in slots

 // 0..2 (with W occupying the largest's slot); put the implied largest at

 // slot 3, then exchange slots L and 3 back into place.

 axes := float32 .[ c0 , c1 , c2 , ( cast ( float32 ) largest ) ] ;
axes [ largest_index ] , axes [ 3 ] = axes [ 3 ] , axes [ largest_index ] ;
return axes [ 0 ] , axes [ 1 ] , axes [ 2 ] , axes [ 3 ] ;

 }


read_quaternion_single :: ( r : * Reader , accuracy : float32 ) -> float32 {

 indicator := read_bits ( r , indicator_bits ( . Int32 ) ) ;
if r . err != . None {

 return 0 ;

 }

 unsigned := wire_cast ( u32 , read_bits ( r , wire_cast ( u32 , indicator ) + 1 ) ) ;
if r . err != . None {

 return 0 ;

 }

 return ( cast ( float32 ) wire_cast ( s32 , unsigned ) ) * accuracy ;

 }


// ---------------------------------------------------------------------------

 // Deltas

 // ---------------------------------------------------------------------------


read_delta_single :: ( r : * Reader , previous : float32 , accuracy : float32 ) -> float32 {

 quantized := read_int32 ( r , . Tight ) ;
if r . err != . None {

 return previous ;

 }

 if quantized == RAW_SINGLE_MARKER {

 return read_raw_single ( r , previous ) ;

 }

 return previous + ( cast ( float32 ) quantized ) * accuracy ;

 }


read_delta_double :: ( r : * Reader , previous : float64 , accuracy : float32 ) -> float64 {

 quantized := read_int64 ( r , . Tight ) ;
if r . err != . None {

 return previous ;

 }

 if quantized == RAW_DOUBLE_MARKER {

 return read_raw_double ( r , previous ) ;

 }

 return previous + ( cast ( float64 ) quantized ) * ( cast ( float64 ) accuracy ) ;

 }


// Generic integer delta counterpart to write_delta_int.

 read_delta_int :: ( r : * Reader , previous : $T , level : Compression_Level ) -> T {

 #if T == s8 {

 return wire_cast ( T , ( wire_cast ( s64 , previous ) + wire_cast ( s64 , read_int8 ( r , level ) ) ) ) ;

 } else #if T == s16 {

 return wire_cast ( T , ( wire_cast ( s64 , previous ) + wire_cast ( s64 , read_int16 ( r , level ) ) ) ) ;

 } else #if T == s32 {

 return wire_cast ( T , ( wire_cast ( s64 , previous ) + wire_cast ( s64 , read_int32 ( r , level ) ) ) ) ;

 } else #if T == s64 {

 return previous + read_int64 ( r , level ) ;

 } else {

 #assert ( false , "read_delta_int expects a signed integer type" ) ;

 }


}



 // Cast semantics adapted. 

 // Loop scopes adapted. 
