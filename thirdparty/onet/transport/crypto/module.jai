// SHA-256 and HMAC-SHA-256 for the UDP return-routability cookie.
// The cookie is not payload encryption or account authentication.
#import "Basic" ;
random_bytes :: ( bytes : [ ] u8 ) -> bool {
offset := 0 ;
while offset < bytes . count {
count := min ( 256 , bytes . count - offset ) ;
#if OS == . WINDOWS { if BCryptGenRandom ( null , bytes . data + offset , cast ( u32 ) count , 2 ) != 0 return false ; }
else { if getentropy ( bytes . data + offset , cast ( u64 ) count ) != 0 return false ; }
offset += count ;
}
return true ;
}
SHA256 :: struct {
state : [ 8 ] u32 = .[ 0x6a09e667 , 0xbb67ae85 , 0x3c6ef372 , 0xa54ff53a , 0x510e527f , 0x9b05688c , 0x1f83d9ab , 0x5be0cd19 ] ;
block : [ 64 ] u8 ;
used : int ;
length : u64 ;
}
sha256_update :: ( hash : * SHA256 , bytes : [ ] u8 ) {
for byte : bytes {
hash . block [ hash . used ] = byte ; hash . used += 1 ; hash . length += 1 ;
if hash . used == 64 { compress ( hash ) ; hash . used = 0 ; }
}
}
sha256_finish :: ( hash : SHA256 ) -> [ 32 ] u8 {
h := hash ; bits := h . length * 8 ;
h . block [ h . used ] = 0x80 ; h . used += 1 ;
if h . used > 56 { while h . used < 64 { h . block [ h . used ] = 0 ; h . used += 1 ; } compress ( * h ) ; h . used = 0 ; }
while h . used < 56 { h . block [ h . used ] = 0 ; h . used += 1 ; }
for 0 .. 7 h . block [ 56 + it ] = cast , trunc ( u8 ) ( bits >> ( ( 7 - it ) * 8 ) ) ;
compress ( * h ) ; result : [ 32 ] u8 ;
for 0 .. 31 result [ it ] = cast , trunc ( u8 ) ( h . state [ it / 4 ] >> ( ( 3 - it % 4 ) * 8 ) ) ;
return result ;
}
sha256 :: ( text : string ) -> [ 32 ] u8 { h : SHA256 ; sha256_update ( * h , ( [ ] u8 ) .{ text . count , text . data } ) ; return sha256_finish ( h ) ; }
hmac_sha256 :: ( key : string , message : string ) -> [ 32 ] u8 {
block : [ 64 ] u8 ;
if key . count > 64 { digest := sha256 ( key ) ; for 0 .. 31 block [ it ] = digest [ it ] ; }
else { i := 0 ; while i < key . count { block [ i ] = key [ i ] ; i += 1 ; } }
inner , outer : SHA256 ; pad : [ 64 ] u8 ;
for 0 .. 63 pad [ it ] = block [ it ] ^ 0x36 ;
sha256_update ( * inner , pad ) ; sha256_update ( * inner , ( [ ] u8 ) .{ message . count , message . data } ) ;
digest := sha256_finish ( inner ) ;
for 0 .. 63 pad [ it ] = block [ it ] ^ 0x5c ;
sha256_update ( * outer , pad ) ; sha256_update ( * outer , digest ) ;
return sha256_finish ( outer ) ;
}
#scope_file
#if OS == . WINDOWS {
bcrypt :: #system_library "bcrypt" ;
BCryptGenRandom :: ( algorithm : * void , bytes : * u8 , count : u32 , flags : u32 ) -> s32 #foreign bcrypt ;
} else {
libc :: #system_library "c" ;
getentropy :: ( bytes : * void , count : u64 ) -> s32 #foreign libc ;
}
rotate :: inline ( x : u32 , n : u32 ) -> u32 { return ( x >> n ) | ( x << ( 32 - n ) ) ; }
compress :: ( h : * SHA256 ) #no_aoc {
w : [ 64 ] u32 ;
for i : 0 .. 15 { for j : 0 .. 3 w [ i ] = ( w [ i ] << 8 ) | ( cast ( u32 ) h . block [ i * 4 + j ] ) ; }
for i : 16 .. 63 {
x := w [ i - 15 ] ; y := w [ i - 2 ] ;
w [ i ] = w [ i - 16 ] + ( rotate ( x , 7 ) ^ rotate ( x , 18 ) ^ ( x >> 3 ) ) + w [ i - 7 ] + ( rotate ( y , 17 ) ^ rotate ( y , 19 ) ^ ( y >> 10 ) ) ;
}
work := h . state ;
for i : 0 .. 63 {
a := work [ 0 ] ; b := work [ 1 ] ; c := work [ 2 ] ; e := work [ 4 ] ; f := work [ 5 ] ; g := work [ 6 ] ;
t1 := work [ 7 ] + ( rotate ( e , 6 ) ^ rotate ( e , 11 ) ^ rotate ( e , 25 ) ) + ( ( e & f ) ^ ( ( ~ e ) & g ) ) + K [ i ] + w [ i ] ;
t2 := ( rotate ( a , 2 ) ^ rotate ( a , 13 ) ^ rotate ( a , 22 ) ) + ( ( a & b ) ^ ( a & c ) ^ ( b & c ) ) ;
work = .[ t1 + t2 , a , b , c , work [ 3 ] + t1 , e , f , g ] ;
}
for 0 .. 7 h . state [ it ] += work [ it ] ;
}

 // Fractional cube roots of the first 64 primes (SHA-256 round constants).
K : [ 64 ] u32 : .[
0x428a2f98 , 0x71374491 , 0xb5c0fbcf , 0xe9b5dba5 , 0x3956c25b , 0x59f111f1 , 0x923f82a4 , 0xab1c5ed5 ,
0xd807aa98 , 0x12835b01 , 0x243185be , 0x550c7dc3 , 0x72be5d74 , 0x80deb1fe , 0x9bdc06a7 , 0xc19bf174 ,
0xe49b69c1 , 0xefbe4786 , 0x0fc19dc6 , 0x240ca1cc , 0x2de92c6f , 0x4a7484aa , 0x5cb0a9dc , 0x76f988da ,
0x983e5152 , 0xa831c66d , 0xb00327c8 , 0xbf597fc7 , 0xc6e00bf3 , 0xd5a79147 , 0x06ca6351 , 0x14292967 ,
0x27b70a85 , 0x2e1b2138 , 0x4d2c6dfc , 0x53380d13 , 0x650a7354 , 0x766a0abb , 0x81c2c92e , 0x92722c85 ,
0xa2bfe8a1 , 0xa81a664b , 0xc24b8b70 , 0xc76c51a3 , 0xd192e819 , 0xd6990624 , 0xf40e3585 , 0x106aa070 ,
0x19a4c116 , 0x1e376c08 , 0x2748774c , 0x34b0bcb5 , 0x391c0cb3 , 0x4ed8aa4a , 0x5b9cca4f , 0x682e6ff3 ,
0x748f82ee , 0x78a5636f , 0x84c87814 , 0x8cc70208 , 0x90befffa , 0xa4506ceb , 0xbef9a3f7 , 0xc67178f2
] ; 
