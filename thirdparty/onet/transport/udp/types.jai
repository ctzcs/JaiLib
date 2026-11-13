#scope_file
transport :: #import "thirdparty/onet/transport" ;
#scope_export
// Native Odin UDP, Synapse-style semantics.

 // No encryption or account authentication. HMAC cookies prove return routing,

 // random connection tokens only resist off-path injection. Use a reviewed

 // authenticated transport/transform on untrusted networks needing confidentiality.



 //@region Configuration and ownership

 Family :: enum {
IPv4 ; IPv6 ; Dual ;
}

 Violation :: enum {
Malformed ; Packet_Size ; Packet_Rate ; Byte_Rate ; Cookie ; Replay ; Admission ; Capacity ; Transform ; Timeout ; Reliable_Exhausted ;
}

 Direction :: enum {
Outbound ; Inbound ;
}

 Packet_Type :: enum u8 {
Hello = 1 ; Challenge ; Echo ; Accept ; Data ; Ack ; Close ; Ping ; Pong ; Probe ; Probe_Challenge ; Probe_Echo ; Probe_Ok ;
}

 // Payload only, header is preserved. Returns (written, accepted). Nil by default;

 // independent Synapse hook, disabled by default.

 Transform :: ( user : * void , direction : Direction , kind : Packet_Type , endpoint : net . Endpoint , source , destination : [ ] u8 ) -> ( int , bool ) ;
Network_Conditions :: struct {

 seed : u64 ;

 loss_permille , duplicate_permille , reorder_permille : u32 ;

 latency_ms , jitter_ms , reorder_ms : int ;


}

 Config :: struct {

 family : Family ;

 connected_socket : bool ;

 full_cone : bool ;

 mtu , max_datagram , max_message , max_fragments : int ;

 window , max_buffered_bytes , max_incoming_packets : int ;

 max_receives_per_poll , max_queue_packets , max_queue_bytes : int ;

 packets_per_second , bytes_per_second : int ;
// per source IP, includes control/handshake

 violations_before_ban , violation_window_ms , ban_duration_ms : int ;
// 0 duration = permanent

 max_policy_entries , max_replays , max_probes : int ;

 cookie_bucket_ms , retry_ms , max_retries , assembly_timeout_ms : int ;

 connect_timeout_ms , idle_timeout_ms , heartbeat_ms : int ;

 probe_retry_ms , probe_max_attempts : int ;

 conditions : Network_Conditions ;

 endpoint_validator : #type ( user : * void , ep : net . Endpoint ) -> bool ;

 admission_validator : #type ( user : * void , ep : net . Endpoint , nonce : u64 ) -> bool ;

 on_violation : #type ( user : * void , ep : net . Endpoint , reason : Violation ) ;

 transform : Transform ;

 transform_reserved_bytes : int ;

 userdata : * void ;


}

 default_config :: ( ) -> Config {

 return .{
family = . IPv4 , mtu = 1200 , max_datagram = 1400 , max_message = 256 * 1024 , max_fragments = 256 ,
window = 32 , max_buffered_bytes = 2 * 1024 * 1024 , max_incoming_packets = 1024 ,
max_receives_per_poll = 4096 , max_queue_packets = 8192 , max_queue_bytes = 8 * 1024 * 1024 ,
packets_per_second = 4000 , bytes_per_second = 4 * 1024 * 1024 ,
violations_before_ban = 8 , violation_window_ms = 10000 , ban_duration_ms = 30000 ,
max_policy_entries = 8192 , max_replays = 8192 , max_probes = 32 ,
cookie_bucket_ms = 5000 , retry_ms = 80 , max_retries = 100 , assembly_timeout_ms = 15000 ,
connect_timeout_ms = 8000 , idle_timeout_ms = 20000 , heartbeat_ms = 1000 ,
probe_retry_ms = 100 , probe_max_attempts = 10 , conditions = .{
seed = 1 ,
} ,

 } ;


}

 IP_Key :: [ 17 ] u8 ;
Endpoint_Key :: [ 19 ] u8 ;
Replay_Key :: #type,distinct u64 ; // consumed client nonce, global to this server lifetime/bucket

 Policy_Record :: struct {
rate_ms , violation_ms , ban_until : s64 ;
packets , bytes , violations : int ;
}

 Pending :: struct {
data : [ ] u8 ;
acked : [ ] bool ;
sent : [ ] s64 ;
attempts : [ ] int ;
}

 Assembly :: struct {
data : [ ] u8 ;
received : [ ] bool ;
count , final_length : int ;
touched : s64 ;
}

 Peer :: struct {

 id : transport . Connection_Id ;

 endpoint : net . Endpoint ;

 side : transport . Invoker ;

 token , nonce : u64 ;

 connected , closing : bool ;

 next_send , next_receive , next_unreliable , unreliable_high : u32 ;

 unreliable_seen : u64 ;

 last_receive , last_ping : s64 ;

 pending : H . Table ( u32 , * Pending ) ;

 assemblies : H . Table ( u32 , * Assembly ) ;

 pending_bytes , assembly_bytes : int ;

 // 连接质量：首发片段的 ACK 与 Ping/Pong 采样 RTT（Karn），重发推高丢包估计。

 rtt_ms , loss : float64 ;

 rtt_sampled : bool ;

 retransmits : u64 ;


}

 Queued :: struct {
socket : net . UDP_Socket ;
endpoint : net . Endpoint ;
payload : [ ] u8 ;
due : s64 ;
}

 Probe_State :: enum {
Pending ; Succeeded ; Failed ;
}

 Probe :: struct {
endpoint : net . Endpoint ;
side : transport . Invoker ;
nonce : u64 ;
state : Probe_State ;
attempts : int ;
next_ms : s64 ;
}

 Statistics :: struct {
sent , received , dropped , duplicated , retransmitted , acked_fragments , violations , cookie_challenges , replay_rejections , socket_errors : u64 ;
}

 Transport :: struct {

 config : Config ;

 initialized , server_running , client_bound , connecting : bool ;

 server_sockets , client_sockets : [ 2 ] net . UDP_Socket ;

 server_port , client_port : u16 ;

 max_clients : u64 ;

 next_id : u32 ;

 client : * Peer ;

 peers : H . Table ( transport . Connection_Id , * Peer ) ;

 policy : H . Table ( IP_Key , Policy_Record , hash_ip , equal_ip ) ;

 replays : H . Table ( Replay_Key , s64 ) ;

 probes : H . Table ( u64 , Probe ) ;

 incoming : [ .. ] transport . Incoming_Packet ;

 changes : [ .. ] transport . State_Change ;

 queue : [ .. ] Queued ;

 queue_bytes , incoming_bytes : int ;

 secret : [ 32 ] u8 ;

 prng : u64 ;

 origin : float64 ;

 clock_ms , connect_started , connect_next : s64 ;

 cookie_bucket : u64 ;

 cookie : [ 32 ] u8 ;

 has_cookie : bool ;

 err : transport . Transport_Error ;

 stats : Statistics ;


}

 HEADER_SIZE :: 40 ;
MAGIC :: ( cast , trunc ( u32 ) ( 0x31554e4e ) ) ;
//@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
