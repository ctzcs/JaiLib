#scope_file
transport :: #import "thirdparty/onet/transport" ;
#scope_export


//@region Poll and handshake

 poll :: ( t : * Transport ) {

 if ! t . initialized {
return ;
}

 update_clock ( t ) ;
ps32_security ( t ) ;
flush_queue ( t , false ) ;
for s : t . server_sockets {
if s != 0 {
drain ( t , s , . Server ) ;
}

 }

 for s : t . client_sockets {
if s != 0 {
drain ( t , s , . Client ) ;
}

 }

 if t . connecting && t . client != null {

 p := t . client ;
if t . clock_ms - t . connect_started >= ( cast , trunc ( s64 ) ( t . config . connect_timeout_ms ) ) {

 violation ( t , p . endpoint , . Timeout ) ;
close_peer ( t , p , false ) ;

 } else if t . clock_ms >= t . connect_next {

 if t . has_cookie {
emit ( t , . Client , p . endpoint , . Echo , 0 , 0 , 0 , 0 , p . nonce , t . cookie_bucket , view ( t . cookie , 0 ) ) ;

 } else {
emit ( t , . Client , p . endpoint , . Hello , 0 , 0 , 0 , 0 , p . nonce , 0 , .[ ] ) ;
}

 t . connect_next = t . clock_ms + ( cast , trunc ( s64 ) ( t . config . retry_ms ) ) ;

 }


}

 for p , _ : t . peers {
maintain_peer ( t , p ) ;
}

 if t . client != null && t . client . connected {
maintain_peer ( t , t . client ) ;
}

 poll_probes ( t ) ;
flush_queue ( t , false ) ;

 }

 drain :: ( t : * Transport , s : net . UDP_Socket , side : transport . Invoker ) {

 buffer : [ 65536 ] u8 ;
{ loop_index := 0 ; while loop_index < t . config . max_receives_per_poll { defer loop_index += 1 ;

 n , ep , err := net . recv_udp ( s , view ( buffer , 0 ) ) ;
if err != . None {
break ;
}

 t . stats . received += 1 ;
if ! inspect ( t , ep , n ) {
continue ;
}

 receive ( t , side , ep , view ( buffer , 0 , n ) ) ;

 } }


}

 receive :: ( t : * Transport , side : transport . Invoker , ep : net . Endpoint , wire : [ ] u8 ) {

 if ( wire ) . count < HEADER_SIZE {
violation ( t , ep , . Malformed ) ;
return ;
}

 if get32 ( view ( wire , 0 , 4 ) ) != MAGIC || wire [ 4 ] != 1 || wire [ 7 ] != 0 || wire [ 6 ] > 1 || wire [ 5 ] < ( cast , trunc ( u8 ) ( Packet_Type . Hello ) ) || wire [ 5 ] > ( cast , trunc ( u8 ) ( Packet_Type . Probe_Ok ) ) {

 violation ( t , ep , . Malformed ) ;
return ;

 }

 kind := ( cast ( Packet_Type ) ( wire [ 5 ] ) ) ;
channel := ( cast ( transport . Channel ) ( wire [ 6 ] ) ) ;
token := get64 ( view ( wire , 8 , 16 ) ) ;
seq := get32 ( view ( wire , 16 , 20 ) ) ;
fragment := get16 ( view ( wire , 20 , 22 ) ) ;
count := get16 ( view ( wire , 22 , 24 ) ) ;
nonce := get64 ( view ( wire , 24 , 32 ) ) ;
bucket := get64 ( view ( wire , 32 , 40 ) ) ;
payload := view ( wire , HEADER_SIZE ) ;
decoded : [ 65536 ] u8 ;
if t . config . transform != null {

 n , ok := t . config . transform ( t . config . userdata , . Inbound , kind , ep , payload , view ( decoded , 0 ) ) ;
if ! ok || n < 0 || n > ( decoded ) . count {
violation ( t , ep , . Transform ) ;
return ;
} ;
payload = view ( decoded , 0 , n ) ;

 }

 if kind != . Data && kind != . Ack && ( seq != 0 || fragment != 0 || count != 0 || channel != . Reliable ) {
violation ( t , ep , . Malformed ) ;
return ;
}

 if kind == {

 case . Hello , . Challenge , . Echo , . Accept ;
handshake ( t , side , ep , kind , token , nonce , bucket , payload ) ;
return ;
case . Probe , . Probe_Challenge , . Probe_Echo , . Probe_Ok ;
if token != 0 {
violation ( t , ep , . Malformed ) ;
return ;
}

 receive_probe ( t , side , ep , kind , nonce , bucket , payload ) ;
return ;
case ; // Established packets below.


}

 p : * Peer ;
if side == . Client {
p = t . client ;
} else {
p = find_peer ( t , ep ) ;
}

 if p == null || ! p . connected || p . token != token || p . nonce != nonce || endpoint_key ( p . endpoint ) != endpoint_key ( ep ) {
return ;
}

 if bucket != 0 {
violation ( t , ep , . Malformed ) ;
return ;
}

 p . last_receive = t . clock_ms ;
if kind == {

 case . Data ;
receive_data ( t , p , channel , seq , fragment , count , payload ) ;
case . Ack ;
m := table_get ( * p . pending , seq ) ;
if channel != . Reliable || ( payload ) . count != 0 || m == null {
return ;
}

 if ( cast ( int ) ( count ) ) != ( m . acked ) . count || ( cast ( int ) ( fragment ) ) >= ( m . acked ) . count {
violation ( t , ep , . Malformed ) ;
return ;
}

 if ! m . acked [ fragment ] {

 if m . attempts [ fragment ] == 1 {
sample_rtt ( p , t . clock_ms - m . sent [ fragment ] ) ;
p . loss -= p . loss / 16 ;
}

 m . acked [ fragment ] = true ;
t . stats . acked_fragments += 1 ;

 }

 complete := true ;
for ack : m . acked {
if ! ack {
complete = false ;
break ;
}

 }

 if complete {
p . pending_bytes -= ( m . data ) . count ;
H . table_remove ( * p . pending , seq ) ;
free_pending ( m ) ;
}

 case . Close ;
if ( payload ) . count != 0 {
violation ( t , ep , . Malformed ) ;
return ;
} ;
close_peer ( t , p , false ) ;
case . Ping ;
if ( payload ) . count == 0 {
emit ( t , p . side , p . endpoint , . Pong , p . token , 0 , 0 , 0 , p . nonce , 0 , .[ ] ) ;
}

 case . Pong ;
if ( payload ) . count != 0 {
violation ( t , ep , . Malformed ) ;
return ;
}

 if t . clock_ms - p . last_ping < ( cast , trunc ( s64 ) ( t . config . heartbeat_ms ) ) {
sample_rtt ( p , t . clock_ms - p . last_ping ) ;
}

 case ;
violation ( t , ep , . Malformed ) ;

 }


}

 find_peer :: ( t : * Transport , ep : net . Endpoint ) -> * Peer {

 key := endpoint_key ( ep ) ;
for p , _ : t . peers {
if endpoint_key ( p . endpoint ) == key {
return p ;
}

 } ;
return null ;

 }

 handshake :: ( t : * Transport , side : transport . Invoker , ep : net . Endpoint , kind : Packet_Type , token , nonce , bucket : u64 , payload : [ ] u8 ) {

 if nonce == 0 {
violation ( t , ep , . Malformed ) ;
return ;
}

 if kind != . Accept && token != 0 {
violation ( t , ep , . Malformed ) ;
return ;
}

 if side == . Server {

 if kind == . Hello {

 if ( payload ) . count != 0 || bucket != 0 {
violation ( t , ep , . Malformed ) ;
return ;
}

 b := ( cast , trunc ( u64 ) ( t . clock_ms / ( cast , trunc ( s64 ) ( t . config . cookie_bucket_ms ) ) ) ) ;
cookie := make_cookie ( t , ep , nonce , b , . Hello ) ;
emit ( t , side , ep , . Challenge , 0 , 0 , 0 , 0 , nonce , b , view ( cookie , 0 ) ) ;
t . stats . cookie_challenges += 1 ;

 } else if kind == . Echo {

 if ! verify_cookie ( t , ep , nonce , bucket , . Hello , payload ) {
violation ( t , ep , . Cookie ) ;
return ;
}

 { p := find_peer ( t , ep ) ; if
p != null && p . nonce == nonce {

 // Idempotent retransmission of an active handshake, never a new admission.

 emit ( t , side , ep , . Accept , p . token , 0 , 0 , 0 , nonce , 0 , .[ ] ) ;
return ;

 } }

 key := ( cast ( Replay_Key ) ( nonce ) ) ;
{ _ , replayed := table_get ( * t . replays , key ) ; if
replayed {
t . stats . replay_rejections += 1 ;
violation ( t , ep , . Replay ) ;
return ;
} }

 previous := find_peer ( t , ep ) ;
if ( previous == null && ( cast ( u64 ) t . peers . count ) >= t . max_clients ) || ( t . replays ) . count >= t . config . max_replays {
violation ( t , ep , . Capacity ) ;
return ;
}

 if t . config . admission_validator != null && ! t . config . admission_validator ( t . config . userdata , ep , nonce ) {
violation ( t , ep , . Admission ) ;
return ;
}

 p := new_peer ( t , ep , side , nonce , random64 ( ) ) ;
if p == null {
return ;
} ;
p . connected = true ;
// Close is best-effort UDP: a valid fresh cookie/nonce at the same

 // endpoint may replace a stranded incarnation. Never evict before

 // cookie, replay, admission and new-ID allocation all succeeded.

 if previous != null {
close_peer ( t , previous , false ) ;
}

 H . table_set ( * t . peers , p . id , p ) ;
H . table_set ( * t . replays , key , ( cast , trunc ( s64 ) ( bucket + 2 ) ) * ( cast , trunc ( s64 ) ( t . config . cookie_bucket_ms ) ) ) ;
array_add ( * t . changes , .{
p . id , side , . Connected
} ) ;
emit ( t , side , ep , . Accept , p . token , 0 , 0 , 0 , nonce , 0 , .[ ] ) ;

 } ;

 return ;

 }

 p := t . client ;
if p == null || p . nonce != nonce || endpoint_key ( p . endpoint ) != endpoint_key ( ep ) {
return ;
}

 if kind == . Challenge && t . connecting {

 if ( payload ) . count != 32 {
violation ( t , ep , . Malformed ) ;
return ;
}

 copy_samples ( view ( t . cookie , 0 ) , payload ) ;
t . cookie_bucket = bucket ;
t . has_cookie = true ;
t . connect_next = t . clock_ms ;

 } else if kind == . Accept && t . connecting && t . has_cookie && token != 0 && bucket == 0 && ( payload ) . count == 0 {

 p . token , p . connected , p . last_receive = token , true , t . clock_ms ;
t . connecting = false ;
array_add ( * t . changes , .{
p . id , . Client , . Connected
} ) ;

 } ;


}

 //@endregion


//@region Reliable ordered selective fragment ACK

 fragment_size :: ( t : * Transport ) -> int {
return t . config . mtu - HEADER_SIZE - t . config . transform_reserved_bytes ;
}

 send :: ( t : * Transport , id : transport . Connection_Id , channel : transport . Channel , payload : [ ] u8 ) -> bool {

 p := table_get ( * t . peers , id ) ;
if t . client != null && t . client . id == id {
p = t . client ;
}

 if p == null || ! p . connected || p . closing {
t . err = . Unknown_Connection ;
return false ;
}

 if ( payload ) . count > t . config . max_message {
t . err = . Send_Failed ;
return false ;
}

 update_clock ( t ) ;
chunk := fragment_size ( t ) ;
if channel == . Unreliable {

 if ( payload ) . count > chunk {
t . err = . Send_Failed ;
return false ;
}

 seq := p . next_unreliable ;
p . next_unreliable += 1 ;
return emit ( t , p . side , p . endpoint , . Data , p . token , seq , 0 , 1 , p . nonce , 0 , payload , channel ) ;

 }

 count := max ( 1 , ( ( payload ) . count + chunk - 1 ) / chunk ) ;
if count > t . config . max_fragments || ( p . pending ) . count >= t . config . window || p . pending_bytes + ( payload ) . count > t . config . max_buffered_bytes {
t . err = . Send_Failed ;
return false ;
}

 // A sliding sequence window, not only a count: ACKed future messages must not

 // let the sender advance past an unACKed oldest message across sequence wrap.

 for _ , seq : p . pending {
if p . next_send - seq >= ( cast , trunc ( u32 ) ( t . config . window ) ) {
return false ;
}

 }

 m := new_one ( Pending ) ;
m . data = new_slice ( u8 , ( payload ) . count ) ;
copy_samples ( m . data , payload ) ;
m . acked = new_slice ( bool , count ) ;
m . sent = new_slice ( s64 , count ) ;
m . attempts = new_slice ( int , count ) ;
seq := p . next_send ;
p . next_send += 1 ;
H . table_set ( * p . pending , seq , m ) ;
p . pending_bytes += ( payload ) . count ;
transmit_message ( t , p , seq , m ) ;
return true ;

 }

 transmit_message :: ( t : * Transport , p : * Peer , seq : u32 , m : * Pending ) -> bool {

 chunk := fragment_size ( t ) ;
{ i := 0 ; while i < ( m . acked ) . count { defer i += 1 ;

 if m . acked [ i ] || ( m . attempts [ i ] > 0 && t . clock_ms - m . sent [ i ] < ( cast , trunc ( s64 ) ( t . config . retry_ms ) ) ) {
continue ;
}

 if m . attempts [ i ] >= t . config . max_retries {
return false ;
}

 if m . attempts [ i ] > 0 {
t . stats . retransmitted += 1 ;
p . retransmits += 1 ;
p . loss += ( 1 - p . loss ) / 16 ;
}

 m . attempts [ i ] += 1 ;
m . sent [ i ] = t . clock_ms ;
emit ( t , p . side , p . endpoint , . Data , p . token , seq , ( cast , trunc ( u16 ) ( i ) ) , ( cast , trunc ( u16 ) ( ( m . acked ) . count ) ) , p . nonce , 0 , view ( m . data , min ( i * chunk , ( m . data ) . count ) , min ( ( i + 1 ) * chunk , ( m . data ) . count ) ) ) ;

 } }

 return true ;

 }

 sample_rtt :: ( p : * Peer , ms : s64 ) {

 sample := ( cast ( float64 ) ( max ( ms , 0 ) ) ) ;
if ! p . rtt_sampled {
p . rtt_ms , p . rtt_sampled = sample , true ;
} else {
p . rtt_ms += ( sample - p . rtt_ms ) / 8 ;
}


}

 ack_fragment :: ( t : * Transport , p : * Peer , seq : u32 , fragment , count : u16 ) {

 emit ( t , p . side , p . endpoint , . Ack , p . token , seq , fragment , count , p . nonce , 0 , .[ ] ) ;

 }

 receive_data :: ( t : * Transport , p : * Peer , channel : transport . Channel , seq : u32 , fragment , count : u16 , payload : [ ] u8 ) {

 chunk := fragment_size ( t ) ;
size := ( payload ) . count ;
if count == 0 || ( cast ( int ) ( count ) ) > t . config . max_fragments || fragment >= count || size > chunk ||
( ( cast ( int ) ( fragment ) ) < ( cast ( int ) ( count ) ) - 1 && size != chunk ) || ( ( cast ( int ) ( count ) ) - 1 ) * chunk > t . config . max_message ||
( fragment == count - 1 && ( ( cast ( int ) ( count ) ) - 1 ) * chunk + size > t . config . max_message ) {

 violation ( t , p . endpoint , . Malformed ) ;
return ;

 }

 if channel == . Unreliable {

 if count != 1 || fragment != 0 {
violation ( t , p . endpoint , . Malformed ) ;
return ;
}

 if ! accept_unreliable ( p , seq ) {
return ;
}

 deliver ( t , p , . Unreliable , payload ) ;
return ;

 }

 distance := seq - p . next_receive ;
if distance >= 0x80000000 {
ack_fragment ( t , p , seq , fragment , count ) ;
return ;
}
// Already delivered, ACK loss.

 if distance >= ( cast , trunc ( u32 ) ( t . config . window ) ) {
return ;
}
// Do not ACK data we cannot buffer.

 a := table_get ( * p . assemblies , seq ) ;
if a == null {

 allocated := min ( ( cast ( int ) ( count ) ) * chunk , t . config . max_message ) ;
if ( p . assemblies ) . count >= t . config . window || p . assembly_bytes + allocated > t . config . max_buffered_bytes {
return ;
}

 a = new_one ( Assembly ) ;
a . data = new_slice ( u8 , allocated ) ;
a . received = new_slice ( bool , ( cast ( int ) ( count ) ) ) ;
a . final_length = - 1 ;
a . touched = t . clock_ms ;
H . table_set ( * p . assemblies , seq , a ) ;
p . assembly_bytes += allocated ;

 } else if ( a . received ) . count != ( cast ( int ) ( count ) ) {
violation ( t , p . endpoint , . Malformed ) ;
return ;
}

 if ! a . received [ fragment ] {

 copy_samples ( view ( a . data , ( cast ( int ) ( fragment ) ) * chunk ) , payload ) ;
a . received [ fragment ] = true ;
a . count += 1 ;
if fragment == count - 1 {
a . final_length = ( ( cast ( int ) ( count ) ) - 1 ) * chunk + size ;
}


}

 ack_fragment ( t , p , seq , fragment , count ) ;
deliver_ordered ( t , p ) ;

 }

 accept_unreliable :: ( p : * Peer , seq : u32 ) -> bool {

 if p . unreliable_seen == 0 {
p . unreliable_high , p . unreliable_seen = seq , 1 ;
return true ;
}

 distance := seq - p . unreliable_high ;
if distance != 0 && distance < 0x80000000 {

 p . unreliable_seen = ( ifx distance >= 64 then 0 else p . unreliable_seen << distance ) ;
p . unreliable_seen |= 1 ;
p . unreliable_high = seq ;
return true ;

 }

 behind := p . unreliable_high - seq ;
if behind >= 64 || ( p . unreliable_seen & ( ( cast , trunc ( u64 ) ( 1 ) ) << behind ) ) != 0 {
return false ;
}

 p . unreliable_seen |= ( cast , trunc ( u64 ) ( 1 ) ) << behind ;
return true ;

 }

 deliver :: ( t : * Transport , p : * Peer , channel : transport . Channel , payload : [ ] u8 ) -> bool {

 if ( t . incoming ) . count >= t . config . max_incoming_packets || t . incoming_bytes + ( payload ) . count > t . config . max_buffered_bytes {
return false ;
}

 owned := new_slice ( u8 , ( payload ) . count ) ;
copy_samples ( owned , payload ) ;
array_add ( * t . incoming , .{
p . id , p . side , channel , owned
} ) ;
t . incoming_bytes += ( payload ) . count ;
return true ;

 } ;

 deliver_ordered :: ( t : * Transport , p : * Peer ) {

 while true {

 a := table_get ( * p . assemblies , p . next_receive ) ;
if a == null || a . count != ( a . received ) . count || a . final_length < 0 {
return ;
}

 if ! deliver ( t , p , . Reliable , view ( a . data , 0 , a . final_length ) ) {
return ;
}

 p . assembly_bytes -= ( a . data ) . count ;
H . table_remove ( * p . assemblies , p . next_receive ) ;
p . next_receive += 1 ;
free_assembly ( a ) ;

 }


}

 maintain_peer :: ( t : * Transport , p : * Peer ) {

 if t . clock_ms - p . last_receive >= ( cast , trunc ( s64 ) ( t . config . idle_timeout_ms ) ) {
violation ( t , p . endpoint , . Timeout ) ;
close_peer ( t , p , false ) ;
return ;
}

 if blacklisted ( t , p . endpoint . address ) {
close_peer ( t , p , true ) ;
return ;
}

 for a , _ : p . assemblies {

 // Never discard ACKed fragments silently: close on exhausted assembly lifetime.

 if t . clock_ms - a . touched >= ( cast , trunc ( s64 ) ( t . config . assembly_timeout_ms ) ) {
violation ( t , p . endpoint , . Timeout ) ;
close_peer ( t , p , true ) ;
return ;
}


}

 deliver_ordered ( t , p ) ;
for m , seq : p . pending {

 if ! transmit_message ( t , p , seq , m ) {
violation ( t , p . endpoint , . Reliable_Exhausted ) ;
close_peer ( t , p , true ) ;
return ;
}


}

 if p . closing && ( p . pending ) . count == 0 {
close_peer ( t , p , true ) ;
return ;
}

 if t . clock_ms - p . last_ping >= ( cast , trunc ( s64 ) ( t . config . heartbeat_ms ) ) {

 p . last_ping = t . clock_ms ;
emit ( t , p . side , p . endpoint , . Ping , p . token , 0 , 0 , 0 , p . nonce , 0 , .[ ] ) ;

 }


}

 //@endregion


//@region Opt-in known-endpoint FullCone probe (no STUN/TURN/symmetric NAT)

 // Caller supplies endpoints out-of-band and arranges both NAT peers to probe.

 // bind_client -> begin_probe -> start_client preserves the punched local port.

 begin_probe :: ( t : * Transport , endpoint : net . Endpoint , side : transport . Invoker = . Client ) -> ( u64 , bool ) {

 if ! t . initialized || ! t . config . full_cone || t . config . connected_socket || ( t . probes ) . count >= t . config . max_probes || endpoint . address . family == . Invalid || endpoint . port < 1 || endpoint . port > 65535 {
return 0 , false ;
}

 if side == . Client && ! t . client_bound && ! bind_client ( t ) {
return 0 , false ;
}

 if socket_for ( t , side , endpoint ) == 0 {
return 0 , false ;
}

 if t . config . endpoint_validator != null && ! t . config . endpoint_validator ( t . config . userdata , endpoint ) {
return 0 , false ;
}

 update_clock ( t ) ;
nonce := random64 ( ) ;
H . table_set ( * t . probes , nonce , .{
endpoint , side , nonce , . Pending , 0 , t . clock_ms ,
} ) ;
return nonce , true ;

 } ;

 probe_state :: ( t : * Transport , nonce : u64 ) -> ( Probe_State , bool ) {
p , ok := table_get ( * t . probes , nonce ) ;
return p . state , ok ;
}

 forget_probe :: ( t : * Transport , nonce : u64 ) {
H . table_remove ( * t . probes , nonce ) ;
}

 poll_probes :: ( t : * Transport ) {

 for initial , nonce : t . probes {

 p := initial ;
if p . state != . Pending || t . clock_ms < p . next_ms {
continue ;
}

 if p . attempts >= t . config . probe_max_attempts {
p . state = . Failed ;
} else {

 emit ( t , p . side , p . endpoint , . Probe , 0 , 0 , 0 , 0 , nonce , 0 , .[ ] ) ;
p . attempts += 1 ;
p . next_ms = t . clock_ms + ( cast , trunc ( s64 ) ( t . config . probe_retry_ms ) ) ;

 }

 H . table_set ( * t . probes , nonce , p ) ;

 }


}

 receive_probe :: ( t : * Transport , side : transport . Invoker , ep : net . Endpoint , kind : Packet_Type , nonce , bucket : u64 , payload : [ ] u8 ) {

 if ! t . config . full_cone || t . config . connected_socket || nonce == 0 {
return ;
}

 if kind == {

 case . Probe ;
if ( payload ) . count != 0 || bucket != 0 {
violation ( t , ep , . Malformed ) ;
return ;
}

 b := ( cast , trunc ( u64 ) ( t . clock_ms / ( cast , trunc ( s64 ) ( t . config . cookie_bucket_ms ) ) ) ) ;
cookie := make_cookie ( t , ep , nonce , b , . Probe ) ;
emit ( t , side , ep , . Probe_Challenge , 0 , 0 , 0 , 0 , nonce , b , view ( cookie , 0 ) ) ;
case . Probe_Challenge ;
p , ok := table_get ( * t . probes , nonce ) ;
if ! ok || p . side != side || p . state != . Pending || endpoint_key ( p . endpoint ) != endpoint_key ( ep ) || ( payload ) . count != 32 {
return ;
}

 emit ( t , side , ep , . Probe_Echo , 0 , 0 , 0 , 0 , nonce , bucket , payload ) ;
case . Probe_Echo ;
if ! verify_cookie ( t , ep , nonce , bucket , . Probe , payload ) {
violation ( t , ep , . Cookie ) ;
return ;
}

 emit ( t , side , ep , . Probe_Ok , 0 , 0 , 0 , 0 , nonce , 0 , .[ ] ) ;
case . Probe_Ok ;
p , ok := table_get ( * t . probes , nonce ) ;
if ok && p . side == side && p . state == . Pending && endpoint_key ( p . endpoint ) == endpoint_key ( ep ) && ( payload ) . count == 0 && bucket == 0 {
p . state = . Succeeded ;
H . table_set ( * t . probes , nonce , p ) ;
}

 case ;

 }


}

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
