#scope_file

 #scope_export


//@region Encoding and stateless return-routability

 put16 :: ( b : [ ] u8 , n : u16 ) {
b [ 0 ] , b [ 1 ] = ( cast , trunc ( u8 ) ( n >> 8 ) ) , ( cast , trunc ( u8 ) ( n ) ) ;
}

 put32 :: ( b : [ ] u8 , n : u32 ) {
{ i := 0 ; while i < 4 { defer i += 1 ;
b [ i ] = ( cast , trunc ( u8 ) ( n >> ( cast , trunc ( u32 ) ( 24 - 8 * i ) ) ) ) ;
} }

 }

 put64 :: ( b : [ ] u8 , n : u64 ) {
{ i := 0 ; while i < 8 { defer i += 1 ;
b [ i ] = ( cast , trunc ( u8 ) ( n >> ( cast , trunc ( u32 ) ( 56 - 8 * i ) ) ) ) ;
} }

 }

 get16 :: ( b : [ ] u8 ) -> u16 {
return ( cast , trunc ( u16 ) ( b [ 0 ] ) ) << 8 | ( cast , trunc ( u16 ) ( b [ 1 ] ) ) ;
}

 get32 :: ( b : [ ] u8 ) -> ( n : u32 ) {
{ i := 0 ; while i < 4 { defer i += 1 ;
n = n << 8 | ( cast , trunc ( u32 ) ( b [ i ] ) ) ;
} } ;
return ;
}

 get64 :: ( b : [ ] u8 ) -> ( n : u64 ) {
{ i := 0 ; while i < 8 { defer i += 1 ;
n = n << 8 | ( cast , trunc ( u64 ) ( b [ i ] ) ) ;
} } ;
return ;
}

 random64 :: ( ) -> u64 {
b : [ 8 ] u8 ; n : u64 ;
while n == 0 { assert ( Crypto . random_bytes ( b ) , "operating system secure random generator failed" ) ; n = get64 ( b ) ; }
return n ;
}
// Canonical IPv4-mapped IPv6 and IPv4 have the same IP policy key.

 ip_key :: ( address : net . Address ) -> ( key : IP_Key ) {
if address . family == . IP4 { key [ 0 ] = 4 ; for 0 .. 3 key [ 1 + it ] = address . bytes [ it ] ; }
else if address . family == . IP6 {
mapped := true ; for 0 .. 9 if address . bytes [ it ] != 0 mapped = false ;
mapped = mapped && address . bytes [ 10 ] == 255 && address . bytes [ 11 ] == 255 ;
if mapped { key [ 0 ] = 4 ; for 0 .. 3 key [ 1 + it ] = address . bytes [ 12 + it ] ; }
else { key [ 0 ] = 6 ; for 0 .. 15 key [ 1 + it ] = address . bytes [ it ] ; }
}
return ;
}
endpoint_key :: ( ep : net . Endpoint ) -> ( key : Endpoint_Key ) {

 ip := ip_key ( ep . address ) ;
copy_samples ( view ( key , 0 , 17 ) , view ( ip , 0 ) ) ;
put16 ( view ( key , 17 ) , ( cast , trunc ( u16 ) ( ep . port ) ) ) ;
return ;

 }

 update_clock :: ( t : * Transport ) {
t . clock_ms = ( cast , trunc ( s64 ) ( ( ( monotonic_seconds ( ) - t . origin ) * 1000 ) ) ) ;
}

 cookie_message :: ( ep : net . Endpoint , nonce , bucket : u64 , domain : Packet_Type ) -> ( b : [ 36 ] u8 ) {

 key := endpoint_key ( ep ) ;
copy_samples ( view ( b , 0 , 19 ) , view ( key , 0 ) ) ;
put64 ( view ( b , 19 , 27 ) , nonce ) ;
put64 ( view ( b , 27 , 35 ) , bucket ) ;
b [ 35 ] = ( cast , trunc ( u8 ) ( domain ) ) ;
return ;

 }

 make_cookie :: ( t : * Transport , ep : net . Endpoint , nonce , bucket : u64 , domain : Packet_Type ) -> ( mac : [ 32 ] u8 ) {

 msg := cookie_message ( ep , nonce , bucket , domain ) ;
mac = Hmac . hmac_sha256 ( string .{ 32 , t . secret . data } , string .{ 36 , msg . data } ) ;
return ;

 }

 verify_cookie :: ( t : * Transport , ep : net . Endpoint , nonce , bucket : u64 , domain : Packet_Type , tag : [ ] u8 ) -> bool {

 current := ( cast , trunc ( u64 ) ( t . clock_ms / ( cast , trunc ( s64 ) ( t . config . cookie_bucket_ms ) ) ) ) ;
if nonce == 0 || ( tag ) . count != 32 || bucket > current || current - bucket > 1 {
return false ;
}

 msg := cookie_message ( ep , nonce , bucket , domain ) ;
expected := Hmac . hmac_sha256 ( string .{ 32 , t . secret . data } , string .{ 36 , msg . data } ) ; difference : u8 ; for 0 .. 31 difference |= tag [ it ] ^ expected [ it ] ; return difference == 0 ;

 }

 //@endregion


//@region Bounded IP policy (not identity or authentication)

 blacklisted :: ( t : * Transport , address : net . Address ) -> bool {

 update_clock ( t ) ;
key := ip_key ( address ) ;
record , ok := table_get ( * t . policy , key ) ;
if ! ok || record . ban_until == 0 {
return false ;
}

 if record . ban_until == 0x7fffffffffffffff || t . clock_ms < record . ban_until {
return true ;
}

 record . ban_until , record . violations , record . packets , record . bytes = 0 , 0 , 0 , 0 ;
record . rate_ms , record . violation_ms = t . clock_ms , t . clock_ms ;
H . table_set ( * t . policy , key , record ) ;
return false ;

 }

 ban_ip :: ( t : * Transport , address : net . Address , duration_ms : int = 0 ) -> bool {

 update_clock ( t ) ;
key := ip_key ( address ) ;
record , ok := table_get ( * t . policy , key ) ;
if ! ok && ( t . policy ) . count >= t . config . max_policy_entries {
return false ;
}

 record . ban_until = ( ifx duration_ms <= 0 then 0x7fffffffffffffff else t . clock_ms + ( cast , trunc ( s64 ) ( duration_ms ) ) ) ;
H . table_set ( * t . policy , key , record ) ;
return true ;

 }

 unban_ip :: ( t : * Transport , address : net . Address ) {
H . table_remove ( * t . policy , ip_key ( address ) ) ;
}

 violation :: ( t : * Transport , ep : net . Endpoint , reason : Violation ) {

 t . stats . violations += 1 ;
key := ip_key ( ep . address ) ;
record , ok := table_get ( * t . policy , key ) ;
if ok || ( t . policy ) . count < t . config . max_policy_entries {

 if t . clock_ms - record . violation_ms >= ( cast , trunc ( s64 ) ( t . config . violation_window_ms ) ) {
record . violation_ms , record . violations = t . clock_ms , 0 ;
}

 record . violations += 1 ;
if record . violations >= t . config . violations_before_ban {

 record . ban_until = ( ifx t . config . ban_duration_ms == 0 then 0x7fffffffffffffff else t . clock_ms + ( cast , trunc ( s64 ) ( t . config . ban_duration_ms ) ) ) ;

 }

 H . table_set ( * t . policy , key , record ) ;

 }

 if t . config . on_violation != null {
t . config . on_violation ( t . config . userdata , ep , reason ) ;
}


}

 inspect :: ( t : * Transport , ep : net . Endpoint , size : int ) -> bool {

 if blacklisted ( t , ep . address ) {
return false ;
}

 if t . config . endpoint_validator != null && ! t . config . endpoint_validator ( t . config . userdata , ep ) {
return false ;
}

 key := ip_key ( ep . address ) ;
r , ok := table_get ( * t . policy , key ) ;
if ! ok && ( t . policy ) . count >= t . config . max_policy_entries {
return false ;
}

 if t . clock_ms - r . rate_ms >= 1000 {
r . rate_ms , r . packets , r . bytes = t . clock_ms , 0 , 0 ;
}

 r . packets += 1 ;
r . bytes += size ;
H . table_set ( * t . policy , key , r ) ;
if size < HEADER_SIZE || size > t . config . max_datagram {
violation ( t , ep , . Packet_Size ) ;
return false ;
}

 if t . config . packets_per_second > 0 && r . packets > t . config . packets_per_second {
violation ( t , ep , . Packet_Rate ) ;
return false ;
}

 if t . config . bytes_per_second > 0 && r . bytes > t . config . bytes_per_second {
violation ( t , ep , . Byte_Rate ) ;
return false ;
}

 return true ;

 }

 ps32_security :: ( t : * Transport ) {

 for expiry , key : t . replays {
if t . clock_ms >= expiry {
H . table_remove ( * t . replays , key ) ;
}

 }

 for r , key : t . policy {

 if r . ban_until != 0x7fffffffffffffff && t . clock_ms >= r . ban_until && t . clock_ms - r . rate_ms > max ( ( cast , trunc ( s64 ) ( t . config . violation_window_ms ) ) , 1000 ) {

 H . table_remove ( * t . policy , key ) ;

 }


}


}

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
