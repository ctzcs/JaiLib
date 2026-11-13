#scope_file
core :: #import "thirdparty/onet/core" ;
transport :: #import "thirdparty/onet/transport" ;
wire :: #import "thirdparty/onet/wire" ;
#scope_export
// 单线程网络会话。回调payload仅在回调期间借用；异步鉴权用id+generation回报。




//@region 协议与会话

 Role :: enum u8 {
Server ; Client ; Host ;
}

 Message_Id :: #type,distinct u16 ;
Extension_Id :: #type,distinct u16 ;
// Fragment 承载超过后端单条上限的可靠帧，只在可靠通道出现。

 Packet_Kind :: enum u8 {
Message = 1 ; Object_Sync = 2 ; Extension = 3 ; Authentication = 4 ; Fragment = 5 ;
}

 FRAGMENT_HEADER :: 9 ; // kind + 总长 u32 + 偏移 u32

 DEFAULT_TICK_INTERVAL_MS :: 50 ;
Message_Handler :: ( sess : * Session , from : transport . Connection_Id , payload : [ ] u8 ) ;
Extension_Handler :: ( sess : * Session , from : transport . Connection_Id , side : transport . Invoker , channel : transport . Channel , payload : [ ] u8 ) ;
Message_Registration :: struct {

 handler : Message_Handler ;

 authentication_required : bool ;


}

 Authentication_State :: enum {
Pending ; Approved ; Denied ;
}

 Client_Info :: struct {

 id : transport . Connection_Id ;

 generation : u64 ;

 state : Authentication_State ;

 identity : string ;

 // 后端报告的已验证身份（例如平台账号），连接建立时记录；不会自动用于批准。

 backend_identity : string ;

 connected_ms : s64 ;

 window_ms : s64 ;

 packets : int ;

 bytes : int ;


}

 Violation :: enum {
Malformed ; Unauthenticated ; Rate_Limit ; Unauthorized ; Invalid_Ack ; Unknown_Protocol ;
}

 Violation_Action :: enum {
Drop ; Ignore ; Kick ;
}

 // 客户端半部结束的原因。Connect_Failed 包括超时；Denied 是服务器拒绝认证。

 Server_Disconnect_Reason :: enum u8 {
Connect_Failed ; Lost ; Local ; Denied ;
}

 Limits :: struct {

 max_packet_bytes : int ;

 packets_per_second : int ;

 bytes_per_second : int ;

 authentication_timeout_ms : int ;

 // 客户端从 start_client 到通过认证的时限；0 沿用传输层自身的连接超时。

 connect_timeout_ms : int ;


}

 Session :: struct {

 driver : transport . Driver ;
// 借用的后端；启动前用 set_driver 选择，未选择时启动失败。

 driver_started : bool ;

 // set_network_conditions 启用后，所有发送经过这个后端无关的弱网包装。

 conditioner : transport . Conditioner ;

 conditioned : bool ;

 role : Role ;

 tick : u64 ;

 tick_interval_ms : int ;

 accumulator_ms : int ;

 max_ticks_per_update : int ;

 clock_ms : s64 ;

 connections : [ .. ] transport . Connection_Id ;

 clients : H . Table ( transport . Connection_Id , * Client_Info ) ;

 next_generation : u64 ;

 handlers : H . Table ( Message_Id , Message_Registration ) ;

 extensions : H . Table ( Extension_Id , Extension_Handler ) ;

 limits : Limits ;

 require_authentication : bool ;

 client_authenticated : bool ;

 client_server_id : transport . Connection_Id ;

 client_generation : u64 ;

 // 客户端半部的生命周期跟踪，用于 on_server_connected/on_server_disconnected。

 client_tracking , client_was_authenticated , client_denied , client_closing : bool ;

 client_started_ms : s64 ;

 runtime_userdata : * void ;

 runtime_before_tick : #type ( sess : * Session ) ;
// fixed tick: before application on_tick.

 runtime_tick : #type ( sess : * Session ) ;
// 游戏on_tick之后；由runtime独占，不替换应用回调。

 current_invoker : transport . Invoker ;

 userdata : * void ;

 on_tick : #type ( sess : * Session ) ;

 on_client_connecting : #type ( sess : * Session , connection : transport . Connection_Id , generation : u64 ) ;

 on_client_connected : #type ( sess : * Session , connection : transport . Connection_Id ) ;

 on_client_disconnected : #type ( sess : * Session , connection : transport . Connection_Id ) ;

 // 客户端侧：服务器批准本连接后触发一次，此时 client_server_id 已有效。

 on_server_connected : #type ( sess : * Session ) ;

 // 客户端侧：每次 start_client/start_host 至多触发一次。

 on_server_disconnected : #type ( sess : * Session , reason : Server_Disconnect_Reason ) ;

 on_object_packet : #type ( sess : * Session , from : transport . Connection_Id , payload : [ ] u8 ) ;

 on_violation : #type ( sess : * Session , connection : transport . Connection_Id , violation : Violation ) -> Violation_Action ;

 // 每个 (连接, 接收端) 至多一个正在重组的分片帧，总长受 limits.max_packet_bytes 限制。

 assemblies : H . Table ( Assembly_Key , * Assembly , hash_Assembly_Key , equal_Assembly_Key ) ;

 running : bool ;


}

 Assembly_Key :: struct {
connection : transport . Connection_Id ;
invoker : transport . Invoker ;
}

 Assembly :: struct {
data : [ ] u8 ;
received : int ;
}


init :: ( sess : * Session , tick_interval_ms : int = DEFAULT_TICK_INTERVAL_MS ) {

 sess .* = .{

 } ;

 sess . tick_interval_ms = max ( tick_interval_ms , 1 ) ;
sess . max_ticks_per_update = 2 ;
sess . clients = new_table ( transport . Connection_Id , * Client_Info ) ;
sess . handlers = new_table ( Message_Id , Message_Registration ) ;
sess . extensions = new_table ( Extension_Id , Extension_Handler ) ;
sess . assemblies = new_table ( Assembly_Key , * Assembly , hash_function = hash_Assembly_Key , compare_function = equal_Assembly_Key ) ;
sess . next_generation = 1 ;
sess . limits = .{
max_packet_bytes = wire . MAX_PAYLOAD , packets_per_second = 2000 , bytes_per_second = 2 * 1024 * 1024 , authentication_timeout_ms = 10000 ,
} ;

 sess . running = true ;

 }


destroy :: ( sess : * Session ) {

 if sess . driver . vtable != null {
transport . shutdown ( sess . driver ) ;
}

 if sess . conditioned {
transport . conditioner_destroy ( * sess . conditioner ) ;
}

 for client , _ : sess . clients {

 if client != null {

 release ( client . identity ) ;
release ( client . backend_identity ) ;
free ( client ) ;

 }


}

 release ( sess . clients ) ;
release ( sess . connections ) ;
release ( sess . handlers ) ;
release ( sess . extensions ) ;
forget_assemblies ( sess , 0 , true ) ;
release ( sess . assemblies ) ;
sess .* = .{

 } ;


}


start_server :: ( sess : * Session , port : u16 , max_clients : u64 = 32 ) -> bool {

 sess . role = . Server ;
ok := transport . start_server ( driver_view ( sess ) , port , max_clients ) ;
sess . driver_started = sess . driver_started || ok ;
return ok ;

 }

 start_client :: ( sess : * Session , address : string , port : u16 ) -> bool {

 sess . role = . Client ;
ok := transport . start_client ( driver_view ( sess ) , address , port ) ;
sess . driver_started = sess . driver_started || ok ;
if ok {
track_client ( sess ) ;
}

 return ok ;

 }

 // port 0 绑定临时端口（bound_port 查询）；指定端口时其他机器可以加入。

 start_host :: ( sess : * Session , max_clients : u64 = 32 , port : u16 = 0 ) -> bool {

 sess . role = . Host ;
if ! transport . start_server ( driver_view ( sess ) , port , max_clients ) {

 return false ;

 }

 sess . driver_started = true ;
// 后端能在进程内直连时不经过地址回环（非 IP 后端通常只能这样连自己）。

 ok : bool ;
if transport . capabilities ( driver_view ( sess ) ) . local_pair {

 ok = transport . open_local_pair ( driver_view ( sess ) ) ;

 } else {

 ok = transport . start_client ( driver_view ( sess ) , transport . loopback_address ( driver_view ( sess ) ) , bound_port ( sess ) ) ;

 }

 if ok {
track_client ( sess ) ;
}

 return ok ;

 }

 bound_port :: ( sess : * Session ) -> u16 {
return transport . bound_port ( driver_view ( sess ) ) ;
}

 local_connection :: ( sess : * Session ) -> transport . Connection_Id {
return transport . local_connection ( driver_view ( sess ) ) ;
}

 client_is_connected :: ( sess : * Session ) -> bool {
return transport . client_is_connected ( driver_view ( sess ) ) ;
}

 // 后端看到的连接质量；客户端查服务器连接用 local_connection(sess)。后端不提供时返回 false。

 connection_quality :: ( sess : * Session , id : transport . Connection_Id ) -> ( transport . Connection_Quality , bool ) {

 return transport . connection_quality ( driver_view ( sess ) , id ) ;

 }


// 借用的后端，启动前选择；Session 不负责释放。未选择时所有启动都失败。

 set_driver :: ( sess : * Session , driver : transport . Driver ) -> bool {

 if sess . driver_started || ( driver . vtable != null && ! transport . valid_driver ( driver ) ) {
return false ;
}

 sess . driver = driver ;
return true ;

 }

 driver_view :: ( sess : * Session ) -> transport . Driver {

 if sess . conditioned {

 sess . conditioner . inner = backend_driver ( sess ) ;
return transport . conditioner_driver ( * sess . conditioner ) ;

 }

 return backend_driver ( sess ) ;

 }

 backend_driver :: ( sess : * Session ) -> transport . Driver {

 if sess . driver . vtable != null {
return sess . driver ;
}

 return transport . null_driver ( ) ;

 }

 // 对本端发出的应用数据施加延迟/抖动/丢包/复制/重排，ENet 与原生 UDP 行为一致。

 // 可靠帧只延迟、保持顺序，从不丢弃。随时可调；再次调用只重置决策流，不影响已排队数据。

 set_network_conditions :: ( sess : * Session , conditions : transport . Network_Conditions ) {

 if ! sess . conditioned {

 transport . conditioner_init ( * sess . conditioner , backend_driver ( sess ) , conditions ) ;
sess . conditioned = true ;

 } else {

 transport . conditioner_set ( * sess . conditioner , conditions ) ;

 }


}

 flush :: ( sess : * Session ) {
transport . flush ( driver_view ( sess ) ) ;
}

 disconnect_local :: ( sess : * Session ) -> transport . Connection_State_Change_Result {

 connected := client_is_connected ( sess ) ;
sess . client_closing = sess . client_tracking ;
result := transport . disconnect_local ( driver_view ( sess ) ) ;
// 尚未连上时部分后端直接复位、不再报告断开，这里立即结束跟踪。

 if ! connected {
finish_client ( sess , . Local ) ;
}

 return result ;

 }

 stop_client :: ( sess : * Session ) -> bool {

 ok := transport . stop_client ( driver_view ( sess ) ) ;
if ok {
finish_client ( sess , . Local ) ;
}

 return ok ;

 }

 connection_count :: ( sess : * Session ) -> int {

 count := 0 ;
for id : sess . connections {

 if id != 0 {

 count += 1 ;

 }


}

 return count ;

 }

 //@endregion


//@region 鉴权与违规

 client_info :: ( sess : * Session , id : transport . Connection_Id ) -> * Client_Info {
return table_get ( * sess . clients , id ) ;
}

 // 服务器侧：该连接由后端验证的身份，空串表示后端不提供。可在 on_client_connecting 中读取，

 // 据此决定是否 approve_client(…, identity)；各后端信任强度不同。

 remote_identity :: ( sess : * Session , id : transport . Connection_Id ) -> string {

 info := table_get ( * sess . clients , id ) ;
return ( ifx info != null then info . backend_identity else "" ) ;

 }

 // 客户端侧：服务器由后端验证的身份，借用到下一次 update。

 server_identity :: ( sess : * Session ) -> string {

 return transport . remote_identity ( driver_view ( sess ) , local_connection ( sess ) ) ;

 }

 is_authenticated :: ( sess : * Session , id : transport . Connection_Id ) -> bool {

 info := table_get ( * sess . clients , id ) ;
return info != null && info . state == . Approved ;

 }


report_violation :: ( sess : * Session , id : transport . Connection_Id , kind : Violation ) -> Violation_Action {

 action := Violation_Action . Drop ;
if sess . on_violation != null {

 action = sess . on_violation ( sess , id , kind ) ;

 }

 if action == . Kick {

 kick ( sess , id ) ;

 }

 return action ;

 }


send_authentication :: ( sess : * Session , id : transport . Connection_Id , approved : bool ) -> bool {

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
core . write_uint8 ( * w , ( cast , trunc ( u8 ) ( Packet_Kind . Authentication ) ) , . Uncompressed ) ;
core . write_uint8 ( * w , ( ifx approved then 1 else 0 ) , . Uncompressed ) ;
core . write_uint32 ( * w , ( cast , trunc ( u32 ) ( id ) ) , . Uncompressed ) ;
core . write_uint64 ( * w , table_get ( * sess . clients , id ) . generation , . Uncompressed ) ;
data := core . writer_to_array ( * w ) ;
defer release ( data ) ;
return transport . send ( driver_view ( sess ) , id , . Reliable , data ) ;

 }


approve_client :: ( sess : * Session , id : transport . Connection_Id , generation : u64 , identity : string = "" ) -> bool {

 info := table_get ( * sess . clients , id ) ;
if info == null || info . generation != generation || info . state != . Pending || ( identity ) . count > 256 {

 return false ;

 }

 info . state = . Approved ;
info . identity = copy_string ( identity ) ;
array_add ( * sess . connections , id ) ;
_ = send_authentication ( sess , id , true ) ;
if sess . on_client_connected != null {

 sess . on_client_connected ( sess , id ) ;

 }

 return true ;

 }


deny_client :: ( sess : * Session , id : transport . Connection_Id , generation : u64 ) -> bool {

 info := table_get ( * sess . clients , id ) ;
if info == null || info . generation != generation || info . state != . Pending {

 return false ;

 }

 info . state = . Denied ;
_ = send_authentication ( sess , id , false ) ;
transport . kick ( driver_view ( sess ) , id , true ) ;
return true ;

 }


accept_rate :: ( sess : * Session , info : * Client_Info , size : int ) -> bool {

 if sess . clock_ms - info . window_ms >= 1000 {

 info . window_ms = sess . clock_ms ;
info . packets = 0 ;
info . bytes = 0 ;

 }

 info . packets += 1 ;
info . bytes += size ;
return ( sess . limits . packets_per_second <= 0 || info . packets <= sess . limits . packets_per_second ) && ( sess . limits . bytes_per_second <= 0 || info . bytes <= sess . limits . bytes_per_second ) ;

 }

 //@endregion


//@region 消息和扩展通道

 register_handler :: ( sess : * Session , id : Message_Id , handler : Message_Handler , authentication_required : bool = true ) {

 H . table_set ( * sess . handlers , id , .{
handler , authentication_required ,
} ) ;


}

 register_extension :: ( sess : * Session , id : Extension_Id , handler : Extension_Handler ) {

 H . table_set ( * sess . extensions , id , handler ) ;

 }


// 按后端能力发送：不可靠帧超过 max_unreliable（或后端不支持不可靠）时返回 false，

 // 不会悄悄改走可靠；可靠帧超过 max_message 时切成 Fragment 依次发送。

 send_frame :: ( sess : * Session , to : transport . Connection_Id , kind : Packet_Kind , payload : [ ] u8 , channel : transport . Channel ) -> bool {

 if ! sess . running || ( payload ) . count + 1 > sess . limits . max_packet_bytes {

 return false ;

 }

 caps := transport . capabilities ( driver_view ( sess ) ) ;
if channel == . Unreliable && ( ! caps . unreliable || 1 + ( payload ) . count > caps . max_unreliable ) {

 return false ;

 }

 if channel == . Reliable && 1 + ( payload ) . count > caps . max_message {

 return send_fragments ( sess , to , kind , payload , caps . max_message ) ;

 }

 w : core . Writer ;
core . writer_init ( * w , 1 + ( payload ) . count ) ;
defer core . writer_destroy ( * w ) ;
core . write_uint8 ( * w , ( cast , trunc ( u8 ) ( kind ) ) , . Uncompressed ) ;
core . write_u8_array_as_bytes_unsafe ( * w , payload , . Loose ) ;
data := core . writer_to_array ( * w ) ;
defer release ( data ) ;
return transport . send ( driver_view ( sess ) , to , channel , data ) ;

 }


// 任一分片发送失败即返回 false；接收端遇到偏移不连续会丢弃半成品。

 send_fragments :: ( sess : * Session , to : transport . Connection_Id , kind : Packet_Kind , payload : [ ] u8 , max_message : int ) -> bool {

 chunk := max_message - FRAGMENT_HEADER ;
if chunk < 1 {

 return false ;

 }

 frame := new_slice ( u8 , 1 + ( payload ) . count ) ;
defer release ( frame ) ;
frame [ 0 ] = ( cast , trunc ( u8 ) ( kind ) ) ;
copy_samples ( view ( frame , 1 ) , payload ) ;
{ offset := 0 ; while offset < ( frame ) . count { defer offset += chunk ;

 part := view ( frame , offset , min ( offset + chunk , ( frame ) . count ) ) ;
w : core . Writer ;
core . writer_init ( * w , FRAGMENT_HEADER + ( part ) . count ) ;
core . write_uint8 ( * w , ( cast , trunc ( u8 ) ( Packet_Kind . Fragment ) ) , . Uncompressed ) ;
core . write_uint32 ( * w , ( cast , trunc ( u32 ) ( ( frame ) . count ) ) , . Uncompressed ) ;
core . write_uint32 ( * w , ( cast , trunc ( u32 ) ( offset ) ) , . Uncompressed ) ;
core . write_u8_array_as_bytes_unsafe ( * w , part , . Loose ) ;
data := core . writer_to_array ( * w ) ;
ok := transport . send ( driver_view ( sess ) , to , . Reliable , data ) ;
release ( data ) ;
core . writer_destroy ( * w ) ;
if ! ok {

 return false ;

 }


} }

 return true ;

 }

 forget_assemblies :: ( sess : * Session , connection : transport . Connection_Id , all := false , invoker := transport . Invoker . Server ) {

 for a , key : sess . assemblies {

 if all || ( key . connection == connection && key . invoker == invoker ) || ( connection == 0 && key . invoker == invoker ) {

 release ( a . data ) ;
free ( a ) ;
H . table_remove ( * sess . assemblies , key ) ;

 }


}


}


send_message_to :: ( sess : * Session , to : transport . Connection_Id , id : Message_Id , payload : [ ] u8 , channel : transport . Channel = . Reliable ) -> bool {

 registration , known := table_get ( * sess . handlers , id ) ;
is_server_target := to != local_connection ( sess ) && sess . role != . Client ;
if is_server_target && ! is_authenticated ( sess , to ) && ( ! known || registration . authentication_required ) {

 return false ;

 }

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
core . write_uint16 ( * w , ( cast , trunc ( u16 ) ( id ) ) , . Uncompressed ) ;
core . write_u8_array_as_bytes_unsafe ( * w , payload , . Loose ) ;
data := core . writer_to_array ( * w ) ;
defer release ( data ) ;
return send_frame ( sess , to , . Message , data , channel ) ;

 }

 send_to_server :: ( sess : * Session , id : Message_Id , payload : [ ] u8 , channel : transport . Channel = . Reliable ) -> bool {

 return send_message_to ( sess , local_connection ( sess ) , id , payload , channel ) ;

 }

 broadcast_message :: ( sess : * Session , id : Message_Id , payload : [ ] u8 , channel : transport . Channel = . Reliable ) -> bool {

 ok := true ;
for connection : sess . connections {

 if connection != 0 && is_authenticated ( sess , connection ) {

 ok = send_message_to ( sess , connection , id , payload , channel ) && ok ;

 }


}

 return ok ;

 }

 send_object_payload :: ( sess : * Session , to : transport . Connection_Id , payload : [ ] u8 , channel : transport . Channel = . Reliable ) -> bool {

 if to != local_connection ( sess ) && ! is_authenticated ( sess , to ) {

 return false ;

 }

 return send_frame ( sess , to , . Object_Sync , payload , channel ) ;

 }

 send_extension :: ( sess : * Session , to : transport . Connection_Id , id : Extension_Id , payload : [ ] u8 , channel : transport . Channel = . Reliable ) -> bool {

 if to != local_connection ( sess ) && ! is_authenticated ( sess , to ) {

 return false ;

 }

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
core . write_uint16 ( * w , ( cast , trunc ( u16 ) ( id ) ) , . Uncompressed ) ;
core . write_u8_array_as_bytes_unsafe ( * w , payload , . Loose ) ;
data := core . writer_to_array ( * w ) ;
defer release ( data ) ;
return send_frame ( sess , to , . Extension , data , channel ) ;

 }

 kick :: ( sess : * Session , id : transport . Connection_Id ) -> transport . Connection_State_Change_Result {

 // 立即撤销认证；同次poll已经缓存的余下包也必须隔离。

 { info := table_get ( * sess . clients , id ) ; if
info != null {
info . state = . Denied ;
} }

 for * connection : sess . connections {
if connection .* == id {
connection .* = 0 ;
}

 }

 return transport . kick ( driver_view ( sess ) , id ) ;

 }

 //@endregion


//@region 客户端连接事件

 track_client :: ( sess : * Session ) {

 sess . client_tracking = true ;
sess . client_was_authenticated , sess . client_denied , sess . client_closing = false , false , false ;
sess . client_started_ms = sess . clock_ms ;

 }

 // 结束一次客户端连接跟踪；未跟踪时为空操作，保证每次连接至多回调一次。

 finish_client :: ( sess : * Session , reason : Server_Disconnect_Reason ) {

 if ! sess . client_tracking {

 return ;

 }

 sess . client_tracking = false ;
if sess . on_server_disconnected != null {

 sess . on_server_disconnected ( sess , reason ) ;

 }


}

 client_disconnect_reason :: ( sess : * Session ) -> Server_Disconnect_Reason {

 if sess . client_closing {
return . Local ;
}

 if sess . client_was_authenticated {
return . Lost ;
}

 if sess . client_denied {
return . Denied ;
}

 return . Connect_Failed ;

 }

 //@endregion


//@region 生命周期与分发

 forget_client :: ( sess : * Session , id : transport . Connection_Id ) {

 info := table_get ( * sess . clients , id ) ;
if info == null {

 return ;

 }

 for * connection : sess . connections {

 if connection .* == id {

 connection .* = 0 ;

 }


}

 if sess . on_client_disconnected != null {

 sess . on_client_disconnected ( sess , id ) ;

 }

 forget_assemblies ( sess , id ) ;
release ( info . identity ) ;
release ( info . backend_identity ) ;
free ( info ) ;
H . table_set ( * sess . clients , id , null ) ;

 }


// 分发一帧。reassembled=true 表示由分片重组而来，其中不允许再嵌套分片。

 handle_frame :: ( sess : * Session , connection : transport . Connection_Id , invoker : transport . Invoker , channel : transport . Channel , payload : [ ] u8 , reassembled : bool ) {

 info := table_get ( * sess . clients , connection ) ;
r : core . Reader ;
core . reader_init ( * r , payload ) ;
kind := ( cast ( Packet_Kind ) ( core . read_uint8 ( * r , . Uncompressed ) ) ) ;
if kind == {

 case . Message ;
id := ( cast ( Message_Id ) ( core . read_uint16 ( * r , . Uncompressed ) ) ) ;
registration , ok := table_get ( * sess . handlers , id ) ;
if r . err != . None || ! ok || registration . handler == null {

 report_violation ( sess , connection , . Malformed ) ;
return ;

 }

 if invoker == . Server && registration . authentication_required && info . state != . Approved {

 report_violation ( sess , connection , . Unauthenticated ) ;
return ;

 }

 registration . handler ( sess , connection , view ( payload , r . bit_position / 8 ) ) ;
case . Object_Sync ;
if invoker == . Server && info . state != . Approved {

 report_violation ( sess , connection , . Unauthenticated ) ;
return ;

 }

 if sess . on_object_packet != null {

 sess . on_object_packet ( sess , connection , view ( payload , 1 ) ) ;

 }

 case . Extension ;
id := ( cast ( Extension_Id ) ( core . read_uint16 ( * r , . Uncompressed ) ) ) ;
handler := table_get ( * sess . extensions , id ) ;
if r . err != . None || handler == null {

 report_violation ( sess , connection , . Unknown_Protocol ) ;
return ;

 }

 if invoker == . Server && info . state != . Approved {

 report_violation ( sess , connection , . Unauthenticated ) ;
return ;

 }

 handler ( sess , connection , invoker , channel , view ( payload , r . bit_position / 8 ) ) ;
case . Authentication ;
approved := core . read_uint8 ( * r , . Uncompressed ) ;
remote_id := core . read_uint32 ( * r , . Uncompressed ) ;
generation := core . read_uint64 ( * r , . Uncompressed ) ;
if invoker != . Client || approved > 1 || remote_id == 0 || generation == 0 || ! wire . finished ( * r ) {

 report_violation ( sess , connection , . Unauthorized ) ;
return ;

 }

 was_authenticated := sess . client_authenticated ;
sess . client_authenticated = approved == 1 ;
sess . client_server_id = ( cast ( transport . Connection_Id ) ( remote_id ) ) ;
sess . client_generation = generation ;
if approved == 0 {

 sess . client_denied = true ;

 } else if ! was_authenticated {

 sess . client_tracking = true ;
sess . client_was_authenticated = true ;
if sess . on_server_connected != null {

 sess . on_server_connected ( sess ) ;

 }


}

 case . Fragment ;
receive_fragment ( sess , connection , invoker , channel , payload , reassembled ) ;
case ;
report_violation ( sess , connection , . Unknown_Protocol ) ;

 }


}


receive_fragment :: ( sess : * Session , connection : transport . Connection_Id , invoker : transport . Invoker , channel : transport . Channel , payload : [ ] u8 , reassembled : bool ) {

 key := Assembly_Key .{
connection , invoker ,
} ;

 r : core . Reader ;
core . reader_init ( * r , payload ) ;
_ = core . read_uint8 ( * r , . Uncompressed ) ;
total := ( cast ( int ) ( core . read_uint32 ( * r , . Uncompressed ) ) ) ;
offset := ( cast ( int ) ( core . read_uint32 ( * r , . Uncompressed ) ) ) ;
part := view ( payload , min ( FRAGMENT_HEADER , ( payload ) . count ) ) ;
a := table_get ( * sess . assemblies , key ) ;
if offset == 0 && a != null {

 forget_assemblies ( sess , connection , false , invoker ) ; // 上一条在发送端失败，丢弃半成品

 a = null ;

 }

 if reassembled || channel != . Reliable || r . err != . None || ( part ) . count == 0 || total < 2 || total > sess . limits . max_packet_bytes ||
offset + ( part ) . count > total || ( offset == 0 ) != ( a == null ) || ( a != null && ( ( a . data ) . count != total || a . received != offset ) ) {

 forget_assemblies ( sess , connection , false , invoker ) ;
report_violation ( sess , connection , . Malformed ) ;
return ;

 }

 if a == null {

 a = new_one ( Assembly ) ;
a . data = new_slice ( u8 , total ) ;
H . table_set ( * sess . assemblies , key , a ) ;

 }

 copy_samples ( view ( a . data , offset ) , part ) ;
a . received += ( part ) . count ;
if a . received < total {

 return ;

 }

 frame := a . data ;
free ( a ) ;
H . table_remove ( * sess . assemblies , key ) ;
defer release ( frame ) ;
handle_frame ( sess , connection , invoker , channel , frame , true ) ;

 }


update :: ( sess : * Session , delta_ms : int ) -> bool {

 if ! sess . running {

 return false ;

 }

 delta := clamp ( delta_ms , 0 , 1000 ) ;
sess . clock_ms += ( cast , trunc ( s64 ) ( delta ) ) ;
transport . poll ( driver_view ( sess ) ) ;
// 同一次poll里的认证包与断开事件分列两表；断开原因在处理完包后再结算。

 client_ended := false ;
for change : transport . state_changes_view ( driver_view ( sess ) ) {

 if change . invoker == . Client {

 if change . kind == . Disconnected {

 sess . client_authenticated = false ;
sess . client_server_id = 0 ;
sess . client_generation = 0 ;
client_ended = true ;

 }

 continue ;

 }

 if change . kind == . Connected {

 forget_client ( sess , change . connection ) ;
info := new_one ( Client_Info ) ;
info . id = change . connection ;
info . generation = sess . next_generation ;
sess . next_generation += 1 ;
info . connected_ms = sess . clock_ms ;
info . window_ms = sess . clock_ms ;
info . backend_identity = copy_string ( transport . remote_identity ( driver_view ( sess ) , change . connection ) ) ;
H . table_set ( * sess . clients , change . connection , info ) ;
if sess . on_client_connecting != null {

 sess . on_client_connecting ( sess , change . connection , info . generation ) ;

 } else if ! sess . require_authentication {

 approve_client ( sess , change . connection , info . generation ) ;

 }


} else {

 forget_client ( sess , change . connection ) ;

 }


}

 transport . clear_state_changes ( driver_view ( sess ) ) ;
for info , _ : sess . clients {

 if info != null && info . state == . Pending && sess . limits . authentication_timeout_ms > 0 && sess . clock_ms - info . connected_ms >= ( cast , trunc ( s64 ) ( sess . limits . authentication_timeout_ms ) ) {

 deny_client ( sess , info . id , info . generation ) ;

 }


}

 for packet : transport . incoming_packets ( driver_view ( sess ) ) {

 sess . current_invoker = packet . invoker ;
if ( packet . payload ) . count == 0 || ( packet . payload ) . count > sess . limits . max_packet_bytes {

 report_violation ( sess , packet . connection , . Malformed ) ;
continue ;

 }

 info := table_get ( * sess . clients , packet . connection ) ;
if packet . invoker == . Server {

 if info == null || info . state == . Denied {

 continue ;

 }

 if ! accept_rate ( sess , info , ( packet . payload ) . count ) {

 report_violation ( sess , packet . connection , . Rate_Limit ) ;
continue ;

 }


}

 handle_frame ( sess , packet . connection , packet . invoker , packet . channel , packet . payload , false ) ;

 }

 transport . clear_incoming ( driver_view ( sess ) ) ;
if client_ended {

 forget_assemblies ( sess , 0 , false , . Client ) ;
sess . client_authenticated , sess . client_server_id , sess . client_generation = false , 0 , 0 ;
finish_client ( sess , client_disconnect_reason ( sess ) ) ;

 }

 if sess . client_tracking && ! sess . client_authenticated && sess . limits . connect_timeout_ms > 0 && sess . clock_ms - sess . client_started_ms >= ( cast , trunc ( s64 ) ( sess . limits . connect_timeout_ms ) ) {

 sess . client_closing = false ;
_ = transport . disconnect_local ( driver_view ( sess ) ) ;
finish_client ( sess , . Connect_Failed ) ;

 }

 sess . accumulator_ms += delta ;
steps := 0 ;
while sess . accumulator_ms >= sess . tick_interval_ms && steps < max ( 1 , sess . max_ticks_per_update ) {

 sess . accumulator_ms -= sess . tick_interval_ms ;
sess . tick += 1 ;
steps += 1 ;
if sess . runtime_before_tick != null {
sess . runtime_before_tick ( sess ) ;
}

 if sess . on_tick != null {

 sess . on_tick ( sess ) ;

 }

 if sess . runtime_tick != null {
sess . runtime_tick ( sess ) ;
}


}

 if sess . accumulator_ms >= sess . tick_interval_ms {

 sess . accumulator_ms %= sess . tick_interval_ms ;

 }

 return true ;

 }


shutdown :: ( sess : * Session ) {

 if ! sess . running {

 return ;

 }

 finish_client ( sess , . Local ) ;
transport . shutdown ( driver_view ( sess ) ) ;
sess . driver_started = false ;
for info , id : sess . clients {

 if info != null {

 forget_client ( sess , id ) ;

 }


}

 array_reset_keeping_memory ( * sess . connections ) ;
forget_assemblies ( sess , 0 , true ) ;
sess . running = false ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted.    

 // Cast semantics adapted. 
