#scope_file

 #scope_export
// onet core: serialization core types.

 //

 // Wire format implemented here:

 //   * values are a pure bit stream, MSB-first, sequential;

 //   * compressed numbers: [length indicator (3/4/5/6 bits for 8/16/32/64-bit

 //     types) = bitCount-1][value bits];

 //   * signed numbers are zigzag encoded first, at their native width;

 //   * Uncompressed: full-width raw bits, no length indicator.



 // ---------------------------------------------------------------------------

 // CompressionLevel

 // ---------------------------------------------------------------------------




// Controls how aggressively values are compressed during serialization.

 // Aggressive/Tight/Loose select the compressed

 // exact-length encoding; Uncompressed writes full-width values.

 Compression_Level :: enum u8 {

 Aggressive ;
Tight ;
Loose ;
Uncompressed ;

 }


// ---------------------------------------------------------------------------

 // NumericValueType — indexes the serializer lookup tables.

 // Layout must stay "signed/unsigned pairs in ascending width order" so that

 // bit_size() = 8 << (t >> 1) and indicator_bits() = (t >> 1) + 3 hold.

 // ---------------------------------------------------------------------------


Numeric_Value_Type :: enum u8 {

 UInt8 = 0 ;
Int8 = 1 ;
UInt16 = 2 ;
Int16 = 3 ;
UInt32 = 4 ;
Int32 = 5 ;
UInt64 = 6 ;
Int64 = 7 ;

 }


// Width, in bits, of the numeric value type (8/16/32/64).

 bit_size :: ( t : Numeric_Value_Type ) -> u32 {

 return 8 << ( wire_cast ( u32 , ( t ) ) >> 1 ) ;

 }


// Width, in bits, of the exact-length indicator written before a compressed

 // value's bits. Indicator widths by type: {3,3,4,4,5,5,6,6}.

 indicator_bits :: ( t : Numeric_Value_Type ) -> u32 {

 return ( wire_cast ( u32 , ( t ) ) >> 1 ) + 3 ;

 }


// Number of bits needed to represent an unsigned value; 0 needs 1 bit.

 bits_needed_for :: ( value : u64 ) -> u32 {

 if value == 0 {

 return 1 ;

 }

 v := value ;
length : u32 = 1 ;
if v > 0xFFFFFFFF {
v >>= 32 ;
length += 32 ;
}

 if v > 0xFFFF {
v >>= 16 ;
length += 16 ;
}

 if v > 0xFF {
v >>= 8 ;
length += 8 ;
}

 if v > 0xF {
v >>= 4 ;
length += 4 ;
}

 if v > 0x3 {
v >>= 2 ;
length += 2 ;
}

 if v > 0x1 {
length += 1 ;
}

 return length ;

 }


// ---------------------------------------------------------------------------

 // Zigzag helpers, done at the value's native width so the compressed length

 // stays tight for negative values.

 // ---------------------------------------------------------------------------


zigzag_i8 :: ( v : s8 ) -> u64 {

 u := wire_cast ( u8 , v ) ;
m := wire_cast ( u8 , ( v >> 7 ) ) ; // 0x00 or 0xFF

 z := ( u << 1 ) ^ m ;
return wire_cast ( u64 , z ) ;

 }

 zigzag_i16 :: ( v : s16 ) -> u64 {

 u := wire_cast ( u16 , v ) ;
m := wire_cast ( u16 , ( v >> 15 ) ) ;
z := ( u << 1 ) ^ m ;
return wire_cast ( u64 , z ) ;

 }

 zigzag_i32 :: ( v : s32 ) -> u64 {

 u := wire_cast ( u32 , v ) ;
m := wire_cast ( u32 , ( v >> 31 ) ) ;
z := ( u << 1 ) ^ m ;
return wire_cast ( u64 , z ) ;

 }

 zigzag_i64 :: ( v : s64 ) -> u64 {

 u := wire_cast ( u64 , v ) ;
m := wire_cast ( u64 , ( v >> 63 ) ) ;
return ( u << 1 ) ^ m ;

 }

 unzigzag_i8 :: ( z : u64 ) -> s8 {

 u := wire_cast ( u8 , z ) ;
m : u8 = 0 ;
if ( u & 1 ) == 1 {

 m = 0xFF ;

 }

 r := ( u >> 1 ) ^ m ;
return wire_cast ( s8 , r ) ;

 }

 unzigzag_i16 :: ( z : u64 ) -> s16 {

 u := wire_cast ( u16 , z ) ;
m : u16 = 0 ;
if ( u & 1 ) == 1 {

 m = 0xFFFF ;

 }

 r := ( u >> 1 ) ^ m ;
return wire_cast ( s16 , r ) ;

 }

 unzigzag_i32 :: ( z : u64 ) -> s32 {

 u := wire_cast ( u32 , z ) ;
m : u32 = 0 ;
if ( u & 1 ) == 1 {

 m = 0xFFFFFFFF ;

 }

 r := ( u >> 1 ) ^ m ;
return wire_cast ( s32 , r ) ;

 }

 unzigzag_i64 :: ( z : u64 ) -> s64 {

 m : u64 = 0 ;
if ( z & 1 ) == 1 {

 m = 0xFFFFFFFFFFFFFFFF ;

 }

 r := ( z >> 1 ) ^ m ;
return wire_cast ( s64 , r ) ;

 }


// ---------------------------------------------------------------------------

 // Quantization helpers.

 // Scales by 1/accuracy and rounds half away from zero.

 // Returns false when the rounded result would not fit the signed carrier

 // (2^31 / 2^63 quanta), for an infinity or for NaN; callers then use the

 // raw-bits fallback. The extreme sentinel values are reserved as markers, so

 // quantization additionally fails when rounding would land exactly on them.

 // ---------------------------------------------------------------------------


SINGLE_BITS_2_POW_31 :: wire_cast ( u32 , ( 0x4F000000 ) ) ; // float bit pattern of 2^31

 DOUBLE_BITS_2_POW_63 :: wire_cast ( u64 , ( 0x43E0000000000000 ) ) ; // double bit pattern of 2^63


try_quantize_single :: ( value : float32 , accuracy : float32 , quantized : * s32 ) -> bool {

 scaled := value * ( 1.0 / accuracy ) ;
bits := bit_cast ( u32 , scaled ) ;
if ( bits & 0x7FFFFFFF ) >= SINGLE_BITS_2_POW_31 {

 // |scaled| >= 2^31, infinity or NaN: cannot ride in an i32.

 return false ;

 }

 // Round half away from zero: add +0.5 for positives, -0.5 for negatives.

 rounded := ( cast ( float64 ) scaled ) + ( 0.5 - ( cast ( float64 ) ( ( bits >> 31 ) & 1 ) ) ) ;
if rounded < - 2147483647.0 || rounded > 2147483647.0 {

 // Would land on or past the i32 marker/range: use the raw fallback.

 return false ;

 }

 quantized .* = wire_cast ( s32 , ( rounded ) ) ;
return true ;

 }

 try_quantize_double :: ( value : float64 , accuracy : float32 , quantized : * s64 ) -> bool {

 scaled := value * ( 1.0 / ( cast ( float64 ) accuracy ) ) ;
bits := bit_cast ( u64 , scaled ) ;
if ( bits & 0x7FFFFFFFFFFFFFFF ) >= DOUBLE_BITS_2_POW_63 {

 return false ;

 }

 rounded := ( ifx scaled >= 0 then Math . floor ( scaled + 0.5 ) else Math . ceil ( scaled - 0.5 ) ) ; // rounds half away from zero

 if rounded < - 9223372036854775807.0 || rounded > 9223372036854775807.0 {

 return false ;

 }

 quantized .* = wire_cast ( s64 , ( rounded ) ) ;
return true ;

 }


// ---------------------------------------------------------------------------

 // Errors

 // ---------------------------------------------------------------------------


// Codec_Error is sticky: once set, writes are skipped / reads return zero

 // values; malformed data is refused, not partially applied.

 Codec_Error :: enum u8 {

 None ;
// Writer: a value needs more bits than its bit count allows.

 Value_Too_Large ;
// Writer: a collection count was negative or exceeded the collection.

 Invalid_Count ;
// Reader: a read went past the end of the buffer.

 Out_Of_Bounds ;
// Reader: the encoding itself is invalid (reserved counts, bad markers).

 Malformed ;

 }


// Finite checks; core:math in this build exposes is_nan/is_inf only.

 is_finite_single :: ( v : float32 ) -> bool {
return ! Math . isnan ( v ) && ! Math . isinf ( v ) ;
}

 is_finite_double :: ( v : float64 ) -> bool {
return ! Math . isnan ( v ) && ! Math . isinf ( v ) ;
}


// Jai represents a GUID as two explicit 64-bit halves.
u128 :: U128 ;


// Cast semantics adapted. 

 // Loop scopes adapted. 
