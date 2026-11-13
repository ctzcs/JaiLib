#scope_file
transport :: #import "thirdparty/onet/transport" ;
udp :: #import "thirdparty/onet/transport/udp" ;
#scope_export


//@region Raw UDP handshake adversaries

 native_raw_socket :: ( t : * Test ) -> net . UDP_Socket {

 s , err := net . make_bound_udp_socket ( net . IP4_Loopback , 0 ) ;
expect ( t , err == . None ) ;
if err == . None {
expect ( t , net . set_blocking ( s , false ) == .None ) ;
} ;
return s ;

 }

 native_raw_packet :: ( kind : udp . Packet_Type , nonce , bucket : u64 , payload : [ ] u8 = .[] ) -> [ ] u8 {

 b := new_slice ( u8 , udp . HEADER_SIZE + ( payload ) . count ) ;
udp . encode_header ( b , kind , . Reliable , 0 , 0 , 0 , 0 , nonce , bucket ) ;
copy_samples ( view ( b , udp . HEADER_SIZE ) , payload ) ;
return b ;

 }

 native_raw_send :: ( t : * Test , s : net . UDP_Socket , server : * udp . Transport , b : [ ] u8 ) {

 n , err := net . send_udp ( s , b , .{
net . IP4_Loopback , ( cast ( int ) ( udp . bound_port ( server ) ) )
} ) ;
expect ( t , err == . None && n == ( b ) . count ) ;

 } ;

 native_raw_until :: ( server : * udp . Transport , s : net . UDP_Socket , kind : udp . Packet_Type ) -> [ ] u8 {

 buf : [ 65536 ] u8 ;
{ loop_index := 0 ; while loop_index < 300 { defer loop_index += 1 ;

 udp . poll ( server ) ;
{ loop_index := 0 ; while loop_index < 100 { defer loop_index += 1 ;

 n , _ , err := net . recv_udp ( s , view ( buf , 0 ) ) ;
if err != . None {
break ;
}

 if n >= udp . HEADER_SIZE && buf [ 5 ] == ( cast , trunc ( u8 ) ( kind ) ) {
owned := new_slice ( u8 , n ) ;
copy_samples ( owned , view ( buf , 0 , n ) ) ;
return owned ;
}


} }

 sleep_milliseconds ( 1 ) ;

 } }

 return .[ ] ;

 }


native_udp_stateless_cookie_endpoint_binding_nonce_replay_and_cap :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
cfg . violations_before_ban = 1000 ;
server : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . start_server ( * server , 0 , 1 ) ) ;
a := native_raw_socket ( t ) ;
defer net . close ( a ) ;
b := native_raw_socket ( t ) ;
defer net . close ( b ) ;
hello := native_raw_packet ( . Hello , 9001 , 0 ) ;
defer release ( hello ) ;
native_raw_send ( t , a , * server , hello ) ;
challenge := native_raw_until ( * server , a , . Challenge ) ;
defer release ( challenge ) ;
if ! expect ( t , ( challenge ) . count == 72 ) {
return ;
}

 expect ( t , ( server . peers ) . count == 0 , "no connection allocated for first hello" ) ;
expect ( t , ( server . replays ) . count == 0 , "stateless challenge" ) ;
bucket := udp . get64 ( view ( challenge , 32 , 40 ) ) ;
echo := native_raw_packet ( . Echo , 9001 , bucket , view ( challenge , 40 ) ) ;
defer release ( echo ) ;
echo [ 40 ] ^= 1 ;
native_raw_send ( t , a , * server , echo ) ;
udp . poll ( * server ) ;
expect ( t , ( server . peers ) . count == 0 , "forged HMAC rejected" ) ;
echo [ 40 ] ^= 1 ;
native_raw_send ( t , b , * server , echo ) ;
udp . poll ( * server ) ;
expect ( t , ( server . peers ) . count == 0 , "cookie bound to source port and IP" ) ;
native_raw_send ( t , a , * server , echo ) ;
accept := native_raw_until ( * server , a , . Accept ) ;
defer release ( accept ) ;
if ! expect ( t , ( accept ) . count == 40 && ( server . peers ) . count == 1 ) {
return ;
}

 token := udp . get64 ( view ( accept , 8 , 16 ) ) ;
expect ( t , token != 0 ) ;
native_raw_send ( t , a , * server , echo ) ;
duplicate := native_raw_until ( * server , a , . Accept ) ;
defer release ( duplicate ) ;
expect ( t , ( server . peers ) . count == 1 , "active duplicate is idempotent" ) ;
expect ( t , ( server . changes ) . count == 1 , "only one Connected event" ) ;
if ( duplicate ) . count > 0 {
expect_value ( t , udp . get64 ( view ( duplicate , 8 , 16 ) ) , token ) ;
}

 // A valid second cookie still cannot exceed the connection cap.

 hello2 := native_raw_packet ( . Hello , 9002 , 0 ) ;
defer release ( hello2 ) ;
native_raw_send ( t , b , * server , hello2 ) ;
ch2 := native_raw_until ( * server , b , . Challenge ) ;
defer release ( ch2 ) ;
if ! expect ( t , ( ch2 ) . count == 72 ) {
return ;
}

 echo2 := native_raw_packet ( . Echo , 9002 , udp . get64 ( view ( ch2 , 32 , 40 ) ) , view ( ch2 , 40 ) ) ;
defer release ( echo2 ) ;
native_raw_send ( t , b , * server , echo2 ) ;
udp . poll ( * server ) ;
expect_value ( t , ( server . peers ) . count , 1 ) ;
id : transport . Connection_Id ;
for _ , k : server . peers {
id = k ;
}

 expect ( t , udp . kick_now ( * server , id ) == . Success ) ;
native_raw_send ( t , a , * server , echo ) ;
udp . poll ( * server ) ;
expect ( t , ( server . peers ) . count == 0 , "consumed nonce cannot re-admit after disconnect" ) ;
expect_value ( t , server . stats . replay_rejections , ( cast , trunc ( u64 ) ( 1 ) ) ) ;
// A newly issued endpoint-bound cookie cannot reuse a consumed nonce either.

 native_raw_send ( t , b , * server , hello ) ;
other_challenge := native_raw_until ( * server , b , . Challenge ) ;
defer release ( other_challenge ) ;
if ! expect ( t , ( other_challenge ) . count == 72 ) {
return ;
}

 other_echo := native_raw_packet ( . Echo , 9001 , udp . get64 ( view ( other_challenge , 32 , 40 ) ) , view ( other_challenge , 40 ) ) ;
defer release ( other_echo ) ;
native_raw_send ( t , b , * server , other_echo ) ;
udp . poll ( * server ) ;
expect_value ( t , ( server . peers ) . count , 0 ) ;
expect_value ( t , server . stats . replay_rejections , ( cast , trunc ( u64 ) ( 2 ) ) ) ;
native_raw_send ( t , b , * server , echo2 ) ;
accept2 := native_raw_until ( * server , b , . Accept ) ;
defer release ( accept2 ) ;
expect ( t , ( accept2 ) . count == 40 && ( server . peers ) . count == 1 , "available capacity accepts fresh nonce" ) ;

 }


native_udp_expired_and_wrong_nonce_challenges_are_rejected :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
cfg . cookie_bucket_ms = 10 ;
server : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
s := native_raw_socket ( t ) ;
defer net . close ( s ) ;
hello := native_raw_packet ( . Hello , 1234 , 0 ) ;
defer release ( hello ) ;
native_raw_send ( t , s , * server , hello ) ;
ch := native_raw_until ( * server , s , . Challenge ) ;
defer release ( ch ) ;
if ! expect ( t , ( ch ) . count == 72 ) {
return ;
}

 wrong := native_raw_packet ( . Echo , 1235 , udp . get64 ( view ( ch , 32 , 40 ) ) , view ( ch , 40 ) ) ;
defer release ( wrong ) ;
native_raw_send ( t , s , * server , wrong ) ;
udp . poll ( * server ) ;
expect_value ( t , ( server . peers ) . count , 0 ) ;
sleep_milliseconds(35) ;
stale := native_raw_packet ( . Echo , 1234 , udp . get64 ( view ( ch , 32 , 40 ) ) , view ( ch , 40 ) ) ;
defer release ( stale ) ;
native_raw_send ( t , s , * server , stale ) ;
udp . poll ( * server ) ;
expect ( t , ( server . peers ) . count == 0 , "cookie time bucket expired" ) ;

 }

 //@endregion


//@region Real ingress rate/size policy, violation windows and ban expiration


native_udp_packet_rate_ip_ban_and_expiration :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
cfg . packets_per_second = 2 ;
cfg . violations_before_ban = 2 ;
cfg . ban_duration_ms = 30 ;
server : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
s := native_raw_socket ( t ) ;
defer net . close ( s ) ;
b := native_raw_packet ( . Hello , 8 , 0 ) ;
defer release ( b ) ;
{ loop_index := 0 ; while loop_index < 4 { defer loop_index += 1 ;
native_raw_send ( t , s , * server , b ) ;
} } ;
udp . poll ( * server ) ;
expect ( t , udp . blacklisted ( * server , net . IP4_Loopback ) ) ;
expect_value ( t , server . stats . cookie_challenges , ( cast , trunc ( u64 ) ( 2 ) ) ) ;
expect_value ( t , server . stats . violations , ( cast , trunc ( u64 ) ( 2 ) ) ) ;
other := native_raw_socket ( t ) ;
defer net . close ( other ) ;
native_raw_send ( t , other , * server , b ) ;
udp . poll ( * server ) ;
expect ( t , server . stats . cookie_challenges == 2 , "ban is IP-wide, not endpoint-only" ) ;
sleep_milliseconds(40) ;
expect ( t , ! udp . blacklisted ( * server , net . IP4_Loopback ) ) ;
native_raw_send ( t , s , * server , b ) ;
udp . poll ( * server ) ;
expect ( t , server . stats . cookie_challenges == 3 , "expired ban also resets rate window" ) ;

 }


native_udp_byte_rate_and_packet_size_are_enforced :: ( t : * Test ) {

 { mode := 0 ; while mode < 2 { defer mode += 1 ;

 cfg := udp . default_config ( ) ;
cfg . packets_per_second = 0 ;
cfg . bytes_per_second = 80 ;
cfg . violations_before_ban = 1 ;
server : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
s := native_raw_socket ( t ) ;
defer net . close ( s ) ;
if mode == 0 {

 b := native_raw_packet ( . Hello , 8 , 0 ) ;
defer release ( b ) ;
{ loop_index := 0 ; while loop_index < 3 { defer loop_index += 1 ;
native_raw_send ( t , s , * server , b ) ;
} }


} else {

 b := new_slice ( u8 , cfg . max_datagram + 1 ) ;
defer release ( b ) ;
native_raw_send ( t , s , * server , b ) ;

 }

 udp . poll ( * server ) ;
expect ( t , udp . blacklisted ( * server , net . IP4_Loopback ) ) ;
expect_value ( t , server . stats . violations , ( cast , trunc ( u64 ) ( 1 ) ) ) ;

 } }


}


native_udp_violation_window_and_bounded_policy_tables :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
cfg . violation_window_ms = 15 ;
cfg . violations_before_ban = 2 ;
cfg . max_policy_entries = 2 ;
server : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
s := native_raw_socket ( t ) ;
defer net . close ( s ) ;
bad : [ 40 ] u8 ;
native_raw_send ( t , s , * server , view ( bad , 0 ) ) ;
udp . poll ( * server ) ;
sleep_milliseconds(25) ;
native_raw_send ( t , s , * server , view ( bad , 0 ) ) ;
udp . poll ( * server ) ;
expect ( t , ! udp . blacklisted ( * server , net . IP4_Loopback ) , "prior violation outside window" ) ;
native_raw_send ( t , s , * server , view ( bad , 0 ) ) ;
udp . poll ( * server ) ;
expect ( t , udp . blacklisted ( * server , net . IP4_Loopback ) ) ;
expect ( t , udp . ban_ip ( * server , net.ipv4(.[
127 , 0 , 0 , 2
]) , 1 ) ) ;
expect ( t , ! udp . ban_ip ( * server , net.ipv4(.[
127 , 0 , 0 , 3
]) , 1 ) , "policy memory bound" ) ;
udp . unban_ip ( * server , net . IP4_Loopback ) ;
expect ( t , ! udp . blacklisted ( * server , net . IP4_Loopback ) ) ;

 } ;

 Native_Admission :: struct {
endpoint , admission : bool ;
calls : int ;
}


native_udp_endpoint_and_admission_validators_run_on_ingress :: ( t : * Test ) {

 state := Native_Admission .{

 } ;

 cfg := udp . default_config ( ) ;
cfg . userdata = * state ;
cfg . endpoint_validator = ( user : * void , ep : net . Endpoint ) -> bool {
return ( ( cast ( * Native_Admission ) user ) ) . endpoint ;
}

 cfg . admission_validator = ( user : * void , ep : net . Endpoint , nonce : u64 ) -> bool {
s := ( cast ( * Native_Admission ) user ) ;
s . calls += 1 ;
return s . admission && nonce != 0 ;
}

 server : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
s := native_raw_socket ( t ) ;
defer net . close ( s ) ;
hello := native_raw_packet ( . Hello , 234 , 0 ) ;
defer release ( hello ) ;
native_raw_send ( t , s , * server , hello ) ;
udp . poll ( * server ) ;
expect_value ( t , server . stats . cookie_challenges , ( cast , trunc ( u64 ) ( 0 ) ) ) ;
expect_value ( t , state . calls , 0 ) ;
state . endpoint = true ;
native_raw_send ( t , s , * server , hello ) ;
ch := native_raw_until ( * server , s , . Challenge ) ;
defer release ( ch ) ;
if ! expect ( t , ( ch ) . count == 72 ) {
return ;
}

 echo := native_raw_packet ( . Echo , 234 , udp . get64 ( view ( ch , 32 , 40 ) ) , view ( ch , 40 ) ) ;
defer release ( echo ) ;
native_raw_send ( t , s , * server , echo ) ;
udp . poll ( * server ) ;
expect_value ( t , state . calls , 1 ) ;
expect_value ( t , ( server . peers ) . count , 0 ) ;
state . admission = true ;
native_raw_send ( t , s , * server , echo ) ;
accept := native_raw_until ( * server , s , . Accept ) ;
defer release ( accept ) ;
expect_value ( t , state . calls , 2 ) ;
expect_value ( t , ( server . peers ) . count , 1 ) ;

 }

 //@endregion


//@region Probe retries, ConnectedSocket conflict, hooks, protocol exhaustion


native_udp_known_endpoint_probe_success_timeout_and_socket_reuse :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
cfg . full_cone = true ;
cfg . probe_retry_ms = 5 ;
cfg . probe_max_attempts = 3 ;
server , a : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . init ( * a , cfg ) ) ;
defer udp . destroy ( * a ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
expect ( t , udp . bind_client ( * a ) ) ;
port := udp . bound_client_port ( * a ) ;
nonce , ok := udp . begin_probe ( * a , .{
net . IP4_Loopback , ( cast ( int ) ( udp . bound_port ( * server ) ) )
} ) ;
expect ( t , ok ) ;
native_pump ( * server , * a , null , 15 ) ;
state , found := udp . probe_state ( * a , nonce ) ;
expect ( t , found && state == . Succeeded ) ;
expect ( t , ( server . peers ) . count == 0 , "probe does not allocate a connection" ) ;
expect ( t , udp . start_client ( * a , "127.0.0.1" , udp . bound_port ( * server ) ) ) ;
expect ( t , native_ready ( * server , * a ) ) ;
expect ( t , udp . bound_client_port ( * a ) == port , "same punched socket" ) ;
// A bound UDP sink deliberately never responds; no assumptions about unused ports.

 sink := native_raw_socket ( t ) ;
defer net . close ( sink ) ;
sink_ep , _ := net . bound_endpoint ( sink ) ;
failed , _ := udp . begin_probe ( * a , sink_ep ) ;
native_pump ( * server , * a , null , 40 ) ;
result , exists := udp . probe_state ( * a , failed ) ;
expect ( t , exists && result == . Failed ) ;
expect_value ( t , table_get(*a . probes , failed ) . attempts , 3 ) ;
udp . forget_probe ( * a , failed ) ;
_ , exists = udp . probe_state ( * a , failed ) ;
expect ( t , ! exists ) ;
bad := cfg ;
bad . connected_socket = true ;
x : udp . Transport ;
expect ( t , ! udp . init ( * x , bad ) , "FullCone plus ConnectedSocket is an explicit error" ) ;
udp . destroy ( * x ) ;

 } ;


native_udp_connected_socket_is_a_real_os_connected_udp_socket :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
server , a : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
cfg . connected_socket = true ;
expect ( t , udp . init ( * a , cfg ) ) ;
defer udp . destroy ( * a ) ;
expect ( t , ! udp . start_server ( * a , 0 ) , "connected socket cannot listen for several peers" ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
expect ( t , udp . start_client ( * a , "127.0.0.1" , udp . bound_port ( * server ) ) ) ;
if ! expect ( t , native_ready ( * server , * a ) ) {
return ;
}

 ep , err := net . peer_endpoint ( a . client_sockets [ 0 ] ) ;
expect ( t , err == . None && ep . port == ( cast ( int ) ( udp . bound_port ( * server ) ) ) ) ;
_ , ok := udp . begin_probe ( * a , ep ) ;
expect ( t , ! ok , "probe is off by default/connected mode" ) ;
expect ( t , udp . send ( * a , a . client . id , . Reliable , u8 .[ 1 , 2 ] ) ) ;
native_pump ( * server , * a , null , 10 ) ;
expect_value ( t , ( server . incoming ) . count , 1 ) ;

 }

 Native_Transform_Stats :: struct {
outbound , inbound : int ;
}


native_udp_explicit_payload_transform_hook_not_enabled_by_default :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
expect ( t , cfg . transform == null ) ;
state : Native_Transform_Stats ;
cfg . userdata = * state ;
cfg . transform_reserved_bytes = 1 ;
// Test framing marker, NOT encryption. Header is never rewritten by this hook.

 cfg . transform = ( user : * void , d : udp . Direction , k : udp . Packet_Type , ep : net . Endpoint , src , dst : [ ] u8 ) -> ( int , bool ) {

 s := ( cast ( * Native_Transform_Stats ) user ) ;
if d == . Outbound {
s . outbound += 1 ;
if ( dst ) . count < ( src ) . count + 1 {
return 0 , false ;
} ;
dst [ 0 ] = 0xa5 ;
copy_samples ( view ( dst , 1 ) , src ) ;
return ( src ) . count + 1 , true ;
}

 s . inbound += 1 ;
if ( src ) . count < 1 || src [ 0 ] != 0xa5 || ( dst ) . count < ( src ) . count - 1 {
return 0 , false ;
} ;
copy_samples ( dst , view ( src , 1 ) ) ;
return ( src ) . count - 1 , true ;

 }

 server , a : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . init ( * a , cfg ) ) ;
defer udp . destroy ( * a ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
expect ( t , udp . start_client ( * a , "127.0.0.1" , udp . bound_port ( * server ) ) ) ;
if ! expect ( t , native_ready ( * server , * a ) ) {
return ;
}

 payload := new_slice ( u8 , 5000 ) ;
defer release ( payload ) ;
for * b : payload {
b.* = 9 ;
}

 expect ( t , udp . send ( * a , a . client . id , . Reliable , payload ) ) ;
native_pump ( * server , * a , null , 20 ) ;
expect_value ( t , ( server . incoming ) . count , 1 ) ;
if ( server . incoming ) . count > 0 {
expect_value ( t , ( server . incoming [ 0 ] . payload ) . count , 5000 ) ;
}

 expect ( t , state . outbound > 0 && state . inbound > 0 ) ;
udp . clear_incoming ( * server ) ;
// Transform rejection is exercised by real malformed wire traffic.

 s := native_raw_socket ( t ) ;
defer net . close ( s ) ;
hello := native_raw_packet ( . Hello , 88 , 0 ) ;
defer release ( hello ) ;
native_raw_send ( t , s , * server , hello ) ;
udp . poll ( * server ) ;
expect ( t , server . stats . violations > 0 ) ;

 }


native_udp_reliable_retry_exhaustion_and_reassembly_bounds :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
cfg . retry_ms = 5 ;
cfg . max_retries = 3 ;
cfg . max_message = 4096 ;
cfg . max_buffered_bytes = 8192 ;
cfg . window = 2 ;
cfg . max_fragments = 4 ;
server , a : udp . Transport ;
expect ( t , udp . init ( * server , cfg ) ) ;
defer udp . destroy ( * server ) ;
expect ( t , udp . init ( * a , cfg ) ) ;
defer udp . destroy ( * a ) ;
expect ( t , udp . start_server ( * server , 0 ) ) ;
expect ( t , udp . start_client ( * a , "127.0.0.1" , udp . bound_port ( * server ) ) ) ;
if ! expect ( t , native_ready ( * server , * a ) ) {
return ;
}

 oversize := new_slice ( u8 , 4097 ) ;
defer release ( oversize ) ;
expect ( t , ! udp . send ( * a , a . client . id , . Reliable , oversize ) ) ;
// Valid token with absurd fragment count is rejected before assembly allocation.

 udp . emit ( * a , . Client , a . client . endpoint , . Data , a . client . token , 1 , 0 , 65535 , a . client . nonce , 0 , u8 .[ 1 ] ) ;
udp . poll ( * server ) ;
for p , _ : server . peers {
expect_value ( t , ( p . assemblies ) . count , 0 ) ;
expect_value ( t , p . assembly_bytes , 0 ) ;
}

 udp . set_conditions ( * a , .{
seed = 1 , loss_permille = 1000
} ) ;
expect ( t , udp . send ( * a , a . client . id , . Reliable , u8 .[ 1 ] ) ) ;
{ loop_index := 0 ; while loop_index < 100 { defer loop_index += 1 ;
udp . poll ( * server ) ;
udp . poll ( * a ) ;
if a . client == null {
break ;
} ;
sleep_milliseconds ( 1 ) ;
} }

 expect ( t , a . client == null , "finite reliable retry cap closes, never skips an ordered sequence" ) ;
expect_value ( t , a . stats . retransmitted , ( cast , trunc ( u64 ) ( 2 ) ) ) ;

 } ;

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
