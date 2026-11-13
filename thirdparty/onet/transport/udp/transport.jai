#scope_file
transport :: #import "thirdparty/onet/transport" ;
#scope_export


//@region Lifetime and socket binding

 init :: ( t : * Transport , config : Config ) -> bool {

 t .* = .{
config = config , next_id = 1 , origin = monotonic_seconds ( ) ,
} ;

 c := * t . config ;
if c . mtu < HEADER_SIZE + 64 || c . max_datagram < c . mtu || c . max_datagram > 65507 ||
c . max_message < 1 || c . max_message > 4 * 1024 * 1024 || c . max_fragments < 1 || c . max_fragments > 4096 ||
c . window < 1 || c . window > 1024 || c . max_buffered_bytes < c . max_message || c . max_incoming_packets < 1 ||
c . max_receives_per_poll < 1 || c . max_queue_packets < 1 || c . max_queue_bytes < c . max_datagram ||
c . violations_before_ban < 1 || c . violation_window_ms < 1 || c . ban_duration_ms < 0 ||
c . max_policy_entries < 1 || c . max_replays < 1 || c . max_probes < 1 || c . cookie_bucket_ms < 1 ||
c . retry_ms < 1 || c . max_retries < 1 || c . assembly_timeout_ms < c . retry_ms ||
c . connect_timeout_ms < 1 || c . idle_timeout_ms < 1 || c . heartbeat_ms < 1 ||
c . probe_retry_ms < 1 || c . probe_max_attempts < 1 || c . transform_reserved_bytes < 0 ||
c . transform_reserved_bytes > c . mtu - HEADER_SIZE - 1 || ( c . connected_socket && c . full_cone ) {

 t . err = . Not_Initialized ;
return false ;

 }

 t . peers = new_table ( transport . Connection_Id , * Peer ) ;
t . policy = new_table ( IP_Key , Policy_Record , hash_function = hash_ip , compare_function = equal_ip ) ;
t . replays = new_table ( Replay_Key , s64 ) ;
t . probes = new_table ( u64 , Probe ) ;
assert ( Crypto . random_bytes ( view ( t . secret , 0 ) ) , "operating system secure random generator failed" ) ;
set_conditions ( t , c . conditions ) ;
t . initialized = true ;
return true ;

 }

 open_sockets :: ( t : * Transport , sockets : * [ 2 ] net . UDP_Socket , port : u16 ) -> ( u16 , bool ) {

 selected := ( cast ( int ) ( port ) ) ;
{ i := 0 ; while i < 2 { defer i += 1 ;

 if ( i == 0 && t . config . family == . IPv6 ) || ( i == 1 && t . config . family == . IPv4 ) {
continue ;
}

 family := ( ifx i == 0 then net . Address_Family . IP4 else net . Address_Family . IP6 ) ;
s , err := net . make_unbound_udp_socket ( family ) ;
if err != . None {
close_sockets ( sockets ) ;
return 0 , false ;
}

 sockets .* [ i ] = s ;
if i == 1 && ! set_v6_only ( s ) {
close_sockets ( sockets ) ;
return 0 , false ;
}

 address : net . Address = ( ifx i == 0 then net . IP4_Any else net . IP6_Any ) ;
if net . bind ( s , .{
address , selected
} ) != . None || net . set_blocking ( s , false ) != . None {
close_sockets ( sockets ) ;
return 0 , false ;
}

 _ = net . set_option ( s , . Receive_Buffer_Size , 1024 * 1024 ) ;
ep , info_err := net . bound_endpoint ( s ) ;
if info_err != . None {
close_sockets ( sockets ) ;
return 0 , false ;
}

 selected = ep . port ;

 } } ;

 return ( cast , trunc ( u16 ) ( selected ) ) , true ;

 }

 close_sockets :: ( sockets : * [ 2 ] net . UDP_Socket ) {

 for * s : sockets .* {
if s .* != 0 {
net . close ( s .* ) ;
s .* = 0 ;
}

 }


}

 start_server :: ( t : * Transport , port : u16 , max_clients : u64 = 32 ) -> bool {

 if ! t . initialized {
t . err = . Not_Initialized ;
return false ;
}

 if t . server_running {
t . err = . Already_Running ;
return false ;
}

 if t . config . connected_socket || max_clients == 0 {
t . err = . Host_Create_Failed ;
return false ;
}

 p , ok := open_sockets ( t , * t . server_sockets , port ) ;
if ! ok {
t . err = . Host_Create_Failed ;
return false ;
}

 t . server_port , t . server_running , t . max_clients , t . err = p , true , max_clients , . None ;
return true ;

 }

 // Bind once before probing; start_client reuses this exact socket/port.

 bind_client :: ( t : * Transport , port : u16 = 0 ) -> bool {

 if ! t . initialized || t . client_bound {
return false ;
}

 p , ok := open_sockets ( t , * t . client_sockets , port ) ;
if ok {
t . client_port , t . client_bound = p , true ;
}

 return ok ;

 }

 resolve_endpoint :: ( t : * Transport , address : string , port : u16 ) -> ( net . Endpoint , bool ) {

 if port == 0 {
return .{

 } , false ;
} ;

 a := net . parse_address ( address ) ;
if a . family != . Invalid {

 family := net . family_from_address ( a ) ;
if ( t . config . family == . IPv4 && family != . IP4 ) || ( t . config . family == . IPv6 && family != . IP6 ) {
return .{

 } , false ;
} ;

 return .{
a , ( cast ( int ) ( port ) ) ,
} , true ;

 } ;

 // OS DNS is synchronous at start, never a fake network API. Literal IPs do not resolve.

 ep4 , ep6 , err := net . resolve ( address ) ;
if err != . None {
return .{

 } , false ;
} ;

 ep := ep4 ;
if t . config . family == . IPv6 || ep . address . family == . Invalid {
ep = ep6 ;
}

 if ep . address . family == . Invalid || ( t . config . family == . IPv4 && net . family_from_endpoint ( ep ) != . IP4 ) {
return .{

 } , false ;
} ;

 ep . port = ( cast ( int ) ( port ) ) ;
return ep , true ;

 }

 start_client :: ( t : * Transport , address : string , port : u16 ) -> bool {

 if ! t . initialized {
t . err = . Not_Initialized ;
return false ;
}

 if t . client != null || t . connecting {
t . err = . Already_Running ;
return false ;
}

 ep , ok := resolve_endpoint ( t , address , port ) ;
if ! ok || ( t . config . endpoint_validator != null && ! t . config . endpoint_validator ( t . config . userdata , ep ) ) {
t . err = . Connect_Failed ;
return false ;
}

 if ! t . client_bound && ! bind_client ( t ) {
t . err = . Host_Create_Failed ;
return false ;
}

 s := socket_for ( t , . Client , ep ) ;
if t . config . connected_socket && ! kernel_connect ( s , ep ) {
t . err = . Connect_Failed ;
return false ;
}

 p := new_peer ( t , ep , . Client , random64 ( ) , 0 ) ;
if p == null {
t . err = . Connect_Failed ;
return false ;
}

 t . client , t . connecting , t . has_cookie = p , true , false ;
update_clock ( t ) ;
t . connect_started , t . connect_next = t . clock_ms , t . clock_ms ;
t . err = . None ;
return true ;

 }

 new_peer :: ( t : * Transport , ep : net . Endpoint , side : transport . Invoker , nonce , token : u64 ) -> * Peer {

 if t . next_id == 0 {
return null ;
}
// Never reuse IDs, even across shutdown/reconnect.

 p := new_one ( Peer ) ;
p .* = .{
id = ( cast ( transport . Connection_Id ) ( t . next_id ) ) , endpoint = ep , side = side , nonce = nonce , token = token ,
next_send = 1 , next_receive = 1 , next_unreliable = 1 , last_receive = t . clock_ms , last_ping = t . clock_ms ,
pending = new_table ( u32 , * Pending ) , assemblies = new_table ( u32 , * Assembly ) ,
} ;

 t . next_id += 1 ;
return p ;

 }

 free_pending :: ( p : * Pending ) {
release ( p . data ) ;
release ( p . acked ) ;
release ( p . sent ) ;
release ( p . attempts ) ;
free ( p ) ;
}

 free_assembly :: ( a : * Assembly ) {
release ( a . data ) ;
release ( a . received ) ;
free ( a ) ;
}

 free_peer :: ( p : * Peer ) {

 for m , _ : p . pending {
free_pending ( m ) ;
} ;
for a , _ : p . assemblies {
free_assembly ( a ) ;
}

 release ( p . pending ) ;
release ( p . assemblies ) ;
free ( p ) ;

 }

 close_peer :: ( t : * Transport , p : * Peer , notify : bool ) {

 if notify && p . connected {
emit ( t , p . side , p . endpoint , . Close , p . token , 0 , 0 , 0 , p . nonce , 0 , .[ ] ) ;
}

 array_add ( * t . changes , .{
p . id , p . side , . Disconnected
} ) ;
if p . side == . Server {
H . table_remove ( * t . peers , p . id ) ;
} else {
t . client = null ;
t . connecting = false ;
t . has_cookie = false ;
t . cookie = .{

 } ;

 }

 free_peer ( p ) ;

 }

 shutdown :: ( t : * Transport ) {

 if ! t . initialized {
return ;
}

 // Queued/latency traffic is dropped; a best-effort Close still spares peers the idle timeout.

 for q : t . queue {
release ( q . payload ) ;
} ;
array_reset_keeping_memory ( * t . queue ) ;
t . queue_bytes = 0 ;
update_clock ( t ) ;
for p , _ : t . peers {
if p . connected {
emit ( t , p . side , p . endpoint , . Close , p . token , 0 , 0 , 0 , p . nonce , 0 , .[ ] ) ;
}

 }

 if t . client != null && t . client . connected {
emit ( t , . Client , t . client . endpoint , . Close , t . client . token , 0 , 0 , 0 , t . client . nonce , 0 , .[ ] ) ;
}

 flush_queue ( t , true ) ;
for p , _ : t . peers {
free_peer ( p ) ;
} ;
array_reset_keeping_memory ( * t . peers ) ;
if t . client != null {
free_peer ( t . client ) ;
t . client = null ;
}

 clear_incoming ( t ) ;
clear_state_changes ( t ) ;
close_sockets ( * t . server_sockets ) ;
close_sockets ( * t . client_sockets ) ;
array_reset_keeping_memory ( * t . replays ) ;
array_reset_keeping_memory ( * t . probes ) ;
t . server_running , t . client_bound , t . connecting , t . has_cookie = false , false , false , false ;
t . server_port , t . client_port , t . cookie_bucket , t . cookie = 0 , 0 , 0 , .{

 } ;

 assert ( Crypto . random_bytes ( view ( t . secret , 0 ) ) , "operating system secure random generator failed" ) ;
t . err = . None ;

 }

 destroy :: ( t : * Transport ) {

 shutdown ( t ) ;
release ( t . peers ) ;
release ( t . policy ) ;
release ( t . replays ) ;
release ( t . probes ) ;
release ( t . incoming ) ;
release ( t . changes ) ;
release ( t . queue ) ;
zero_secret ( * t . secret ) ;
t .* = .{

 } ;


}

 bound_port :: ( t : * Transport ) -> u16 {
return t . server_port ;
}

 bound_client_port :: ( t : * Transport ) -> u16 {
return t . client_port ;
}

 local_client_connection :: ( t : * Transport ) -> transport . Connection_Id {
if t . client == null {
return 0 ;
} ;
return t . client . id ;
}

 client_is_connected :: ( t : * Transport ) -> bool {
return t . client != null && t . client . connected ;
}

 server_connection_count :: ( t : * Transport ) -> int {
return ( t . peers ) . count ;
}

 error_of :: ( t : * Transport ) -> transport . Transport_Error {
return t . err ;
}

 // 可靠消息受 max_message、分片数和发送缓冲共同限制；不可靠消息必须装进单个数据报。

 capabilities :: ( t : * Transport ) -> transport . Capabilities {

 c := * t . config ;
chunk := c . mtu - HEADER_SIZE - c . transform_reserved_bytes ;
return .{
max_message = min ( c . max_message , c . max_fragments * chunk , c . max_buffered_bytes ) , max_unreliable = chunk , unreliable = true , connection_quality = true ,
} ;


}

 // 尚未采到 RTT 时 rtt_ms 为 -1。

 connection_quality :: ( t : * Transport , id : transport . Connection_Id ) -> ( transport . Connection_Quality , bool ) {

 p := table_get ( * t . peers , id ) ;
if t . client != null && t . client . id == id {
p = t . client ;
}

 if p == null || ! p . connected {
return .{

 } , false ;
} ;

 return .{
rtt_ms = ( ifx p . rtt_sampled then p . rtt_ms else - 1 ) , loss = p . loss , retransmits = ( cast , trunc ( s64 ) ( p . retransmits ) ) , pending_bytes = ( cast , trunc ( s64 ) ( p . pending_bytes ) ) ,
} , true ;

 } ;

 incoming_packets :: ( t : * Transport ) -> [ ] transport . Incoming_Packet {
return view ( t . incoming , 0 ) ;
}

 state_changes_view :: ( t : * Transport ) -> [ ] transport . State_Change {
return view ( t . changes , 0 ) ;
}

 clear_state_changes :: ( t : * Transport ) {
array_reset_keeping_memory ( * t . changes ) ;
}

 clear_incoming :: ( t : * Transport ) {

 for p : t . incoming {
release ( p . payload ) ;
} ;
array_reset_keeping_memory ( * t . incoming ) ;
t . incoming_bytes = 0 ;

 }

 stop_client :: ( t : * Transport ) -> bool {

 if t . client != null {
return false ;
}

 // Remove queued traffic that references the sockets being closed.

 { i := ( t . queue ) . count - 1 ; while i >= 0 { defer i -= 1 ;

 q := t . queue [ i ] ;
if q . socket == t . client_sockets [ 0 ] || q . socket == t . client_sockets [ 1 ] {

 t . queue_bytes -= ( q . payload ) . count ;
release ( q . payload ) ;
array_ordered_remove_by_index ( * t . queue , i ) ;

 }


} }

 close_sockets ( * t . client_sockets ) ;
t . client_bound = false ;
t . client_port = 0 ;
return true ;

 }

 disconnect_local :: ( t : * Transport ) -> transport . Connection_State_Change_Result {

 if t . client == null {
return . Invalid_Connection ;
} ;
close_peer ( t , t . client , true ) ;
flush ( t ) ;
return . Success ;

 }

 kick_now :: ( t : * Transport , id : transport . Connection_Id ) -> transport . Connection_State_Change_Result {

 p := table_get ( * t . peers , id ) ;
if p == null {
return . Invalid_Connection ;
} ;
close_peer ( t , p , true ) ;
flush ( t ) ;
return . Success ;

 }

 kick_after_delivery :: ( t : * Transport , id : transport . Connection_Id ) -> transport . Connection_State_Change_Result {

 p := table_get ( * t . peers , id ) ;
if p == null {
return . Invalid_Connection ;
} ;
p . closing = true ;
return . Success ;

 }

 //@endregion


//@region Owned deterministic native send queue

 set_conditions :: ( t : * Transport , conditions : Network_Conditions ) {

 c := conditions ;
c . loss_permille = min ( c . loss_permille , 1000 ) ;
c . duplicate_permille = min ( c . duplicate_permille , 1000 ) ;
c . reorder_permille = min ( c . reorder_permille , 1000 ) ;
c . latency_ms = clamp ( c . latency_ms , 0 , 60000 ) ;
c . jitter_ms = clamp ( c . jitter_ms , 0 , 60000 ) ;
c . reorder_ms = clamp ( c . reorder_ms , 0 , 60000 ) ;
t . config . conditions = c ;
t . prng = max ( c . seed , ( cast , trunc ( u64 ) ( 1 ) ) ) ;

 }

 next_random :: ( t : * Transport ) -> u64 {

 x := t . prng ;
x = x ^ ( x << 13 ) ;
x = x ^ ( x >> 7 ) ;
x = x ^ ( x << 17 ) ;
t . prng = x ;
return x ;

 }

 socket_for :: ( t : * Transport , side : transport . Invoker , ep : net . Endpoint ) -> net . UDP_Socket {

 i := 0 ;
if net . family_from_endpoint ( ep ) == . IP6 {
i = 1 ;
}

 if side == . Server {
return t . server_sockets [ i ] ;
} ;
return t . client_sockets [ i ] ;

 }

 // Encodes the fixed header; useful for protocol instrumentation, not authentication.

 encode_header :: ( b : [ ] u8 , kind : Packet_Type , channel : transport . Channel , token : u64 , seq : u32 , fragment , count : u16 , nonce , bucket : u64 ) {

 assert ( ( b ) . count >= HEADER_SIZE ) ;
put32 ( view ( b , 0 , 4 ) , MAGIC ) ;
b [ 4 ] , b [ 5 ] , b [ 6 ] , b [ 7 ] = 1 , ( cast , trunc ( u8 ) ( kind ) ) , ( cast , trunc ( u8 ) ( channel ) ) , 0 ;
put64 ( view ( b , 8 , 16 ) , token ) ;
put32 ( view ( b , 16 , 20 ) , seq ) ;
put16 ( view ( b , 20 , 22 ) , fragment ) ;
put16 ( view ( b , 22 , 24 ) , count ) ;
put64 ( view ( b , 24 , 32 ) , nonce ) ;
put64 ( view ( b , 32 , 40 ) , bucket ) ;

 }

 emit :: ( t : * Transport , side : transport . Invoker , ep : net . Endpoint , kind : Packet_Type , token : u64 , seq : u32 , fragment , count : u16 , nonce , bucket : u64 , payload : [ ] u8 , channel : transport . Channel = . Reliable ) -> bool {

 s := socket_for ( t , side , ep ) ;
if s == 0 {
return false ;
}

 c := t . config . conditions ;
if next_random ( t ) % 1000 < ( cast , trunc ( u64 ) ( min ( c . loss_permille , 1000 ) ) ) {
t . stats . dropped += 1 ;
return true ;
}

 buf : [ 65536 ] u8 ;
encode_header ( view ( buf , 0 , HEADER_SIZE ) , kind , channel , token , seq , fragment , count , nonce , bucket ) ;
n := ( payload ) . count ;
if t . config . transform != null {

 ok : bool ;
n , ok = t . config . transform ( t . config . userdata , . Outbound , kind , ep , payload , view ( buf , HEADER_SIZE , t . config . mtu ) ) ;
if ! ok || n < 0 || n > t . config . mtu - HEADER_SIZE {
violation ( t , ep , . Transform ) ;
return false ;
}


} else {
if n > t . config . mtu - HEADER_SIZE {
return false ;
} ;
copy_samples ( view ( buf , HEADER_SIZE ) , payload ) ;
}

 size := HEADER_SIZE + n ;
copies := 1 ;
if next_random ( t ) % 1000 < ( cast , trunc ( u64 ) ( min ( c . duplicate_permille , 1000 ) ) ) {
copies = 2 ;
t . stats . duplicated += 1 ;
}

 if ( t . queue ) . count + copies > t . config . max_queue_packets || t . queue_bytes + copies * size > t . config . max_queue_bytes {
return false ;
}

 { loop_index := 0 ; while loop_index < copies { defer loop_index += 1 ;

 delay := max ( c . latency_ms , 0 ) ;
if c . jitter_ms > 0 {
delay += ( cast ( int ) ( next_random ( t ) % ( cast , trunc ( u64 ) ( c . jitter_ms + 1 ) ) ) ) ;
}

 if next_random ( t ) % 1000 < ( cast , trunc ( u64 ) ( min ( c . reorder_permille , 1000 ) ) ) {
delay += max ( c . reorder_ms , 0 ) ;
}

 owned := new_slice ( u8 , size ) ;
copy_samples ( owned , view ( buf , 0 , size ) ) ;
array_add ( * t . queue , .{
s , ep , owned , t . clock_ms + ( cast , trunc ( s64 ) ( delay ) )
} ) ;
t . queue_bytes += size ;

 } } ;

 flush_queue ( t , false ) ;
return true ;

 }

 flush_queue :: ( t : * Transport , force : bool ) {

 i := 0 ;
while i < ( t . queue ) . count {

 q := t . queue [ i ] ;
if ! force && q . due > t . clock_ms {
i += 1 ;
continue ;
}

 n , err := net . send_udp ( q . socket , q . payload , q . endpoint ) ;
if err != . None || n != ( q . payload ) . count {
t . stats . socket_errors += 1 ;
} else {
t . stats . sent += 1 ;
}

 t . queue_bytes -= ( q . payload ) . count ;
release ( q . payload ) ;
array_ordered_remove_by_index ( * t . queue , i ) ;

 }


}

 // Explicit flush releases ALL simulated latency (loss already selected is not undone).

 flush :: ( t : * Transport ) {
update_clock ( t ) ;
flush_queue ( t , true ) ;
}

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
