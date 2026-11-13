#scope_file
transport :: #import "thirdparty/onet/transport" ;
udp :: #import "thirdparty/onet/transport/udp" ;
#scope_export


//@region 丢失Close后同端点的验证重连


native_udp_lost_close_reconnect_replaces_only_validated_endpoint_without_ip_ban :: ( t : * Test ) {

 cfg := udp . default_config ( ) ;
cfg . violations_before_ban = 1 ;
s , a , b : udp . Transport ;
assert ( udp . init ( * s , cfg ) && udp . init ( * a , cfg ) && udp . init ( * b , cfg ) ) ;
defer udp . destroy ( * s ) ;
defer udp . destroy ( * a ) ;
defer udp . destroy ( * b ) ;
assert ( udp . start_server ( * s , 0 , 2 ) ) ;
assert ( udp . start_client ( * a , "127.0.0.1" , udp . bound_port ( * s ) ) && native_ready ( * s , * a ) ) ;
assert ( udp . start_client ( * b , "127.0.0.1" , udp . bound_port ( * s ) ) && native_ready ( * s , * b ) ) ;
old_id := native_server_id ( * s , * a ) ;
other_id := native_server_id ( * s , * b ) ;
old := table_get ( * s . peers , old_id ) ;
ep , nonce , token := old . endpoint , old . nonce , old . token ;
port := udp . bound_client_port ( * a ) ;
udp . clear_state_changes ( * s ) ;
udp . set_conditions ( * a , .{
seed = 1 , loss_permille = 1000
} ) ;
assert ( udp . disconnect_local ( * a ) == . Success ) ;
expect ( t , a . stats . dropped > 0 && ( s . peers ) . count == 2 , "old server incarnation survives lost Close" ) ;
udp . set_conditions ( * a , .{
seed = 1
} ) ;
// Preserve the local endpoint, exactly as a relay/NAT mapping does.

 assert ( udp . start_client ( * a , "127.0.0.1" , udp . bound_port ( * s ) ) ) ;
if ! expect ( t , native_ready ( * s , * a ) ) {
return ;
}

 fresh := native_server_id ( * s , * a ) ;
expect ( t , fresh != old_id && ( s . peers ) . count == 2 && udp . bound_client_port ( * a ) == port ) ;
expect ( t , table_get ( * s . peers , old_id ) == null && table_get ( * s . peers , other_id ) != null && s . stats . violations == 0 && ! udp . blacklisted ( * s , ep . address ) ) ;
expect ( t , ( s . changes ) . count == 2 && s . changes [ 0 ] . kind == transport . State_Change_Kind . Disconnected && s . changes [ 0 ] . connection == old_id && s . changes [ 1 ] . kind == . Connected ) ;
stale : [ udp . HEADER_SIZE ] u8 ;
udp . encode_header ( view ( stale , 0 ) , . Close , . Reliable , token , 0 , 0 , 0 , nonce , 0 ) ;
udp . receive ( * s , . Server , ep , view ( stale , 0 ) ) ;
expect ( t , table_get ( * s . peers , fresh ) != null && s . stats . violations == 0 , "late old Close cannot revoke new token" ) ;
assert ( udp . send ( * b , udp . local_client_connection ( * b ) , . Reliable , u8 .[ 9 ] ) ) ;
native_pump ( * s , * a , * b , 20 ) ;
expect ( t , ( s . incoming ) . count == 1 && s . incoming [ 0 ] . connection == other_id && s . incoming [ 0 ] . payload [ 0 ] == 9 ) ;

 } ;

 reconnect_admission :: ( user : * void , ep : net . Endpoint , nonce : u64 ) -> bool {
return ( ( cast ( * bool ) user ) ) .* ;
}


native_udp_same_endpoint_replacement_admission_veto_keeps_old_connection :: ( t : * Test ) {

 allow := true ;
cfg := udp . default_config ( ) ;
cfg . userdata = * allow ;
cfg . admission_validator = reconnect_admission ;
s , a : udp . Transport ;
assert ( udp . init ( * s , cfg ) ) ;
defer udp . destroy ( * s ) ;
assert ( udp . init ( * a , udp . default_config ( ) ) ) ;
defer udp . destroy ( * a ) ;
assert ( udp . start_server ( * s , 0 , 1 ) && udp . start_client ( * a , "127.0.0.1" , udp . bound_port ( * s ) ) && native_ready ( * s , * a ) ) ;
id := native_server_id ( * s , * a ) ;
old := table_get ( * s . peers , id ) ;
allow = false ;
bucket := ( cast , trunc ( u64 ) ( s . clock_ms / ( cast , trunc ( s64 ) ( s . config . cookie_bucket_ms ) ) ) ) ;
nonce := old . nonce ^ 0x12345678 ;
if nonce == 0 {
nonce = 1 ;
}

 cookie := udp . make_cookie ( * s , old . endpoint , nonce , bucket , . Hello ) ;
udp . handshake ( * s , . Server , old . endpoint , . Echo , 0 , nonce , bucket , view ( cookie , 0 ) ) ;
expect ( t , ( s . peers ) . count == 1 && table_get ( * s . peers , id ) == old && old . connected && s . stats . violations == 1 ) ;
expect ( t , udp . send ( * s , id , . Reliable , u8 .[ 1 ] ) ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
