#scope_file

 #scope_export

 //@region 可插拔单loop驱动

 // Borrowed, address-stable backend. Session never frees this object. All calls,

 // views and callbacks belong to the same loop; views expire at clear/shutdown.

 Driver :: struct {

 data : * void ;
vtable : * Driver_Vtable ;

 }

 Driver_Vtable :: struct {

 start_server : #type ( * void , u16 , u64 ) -> bool ;
start_client : #type ( * void , string , u16 ) -> bool ;
bound_port : #type ( * void ) -> u16 ;
local_connection : #type ( * void ) -> Connection_Id ;
client_is_connected : #type ( * void ) -> bool ;
poll : #type ( * void ) ;
send : #type ( * void , Connection_Id , Channel , [ ] u8 ) -> bool ;
kick : #type ( * void , Connection_Id , bool ) -> Connection_State_Change_Result ;
loopback_address : #type ( * void ) -> string ; // optional; default IPv4 loopback

 incoming : #type ( * void ) -> [ ] Incoming_Packet ;
clear_incoming : #type ( * void ) ;
changes : #type ( * void ) -> [ ] State_Change ;
clear_changes : #type ( * void ) ;
flush : #type ( * void ) ;
disconnect_local : #type ( * void ) -> Connection_State_Change_Result ;
stop_client : #type ( * void ) -> bool ;
shutdown : #type ( * void ) ;
// 以下为可选槽；留空时按保守默认处理，见 capabilities/remote_identity/open_local_pair。

 capabilities : #type ( * void ) -> Capabilities ;
remote_identity : #type ( * void , Connection_Id ) -> string ;
open_local_pair : #type ( * void ) -> bool ;
connection_quality : #type ( * void , Connection_Id ) -> Connection_Quality , bool ;

 }

 // 后端自身看到的连接质量。字段为 -1 表示该后端不提供这一项。

 // 只反映后端协议（含它自己的确认/重传），不含 Conditioner 等外层施加的延迟；

 // 应用层往返时间见 runtime.stats 的 rtt_ms。

 Connection_Quality :: struct {

 rtt_ms : float64 ; // 平滑往返时间

 loss : float64 ; // 丢包率估计 0..1

 retransmits : s64 ; // 累计重传次数

 pending_bytes : s64 ; // 已发出但未确认的可靠字节


}

 // 后端能力。max_* 是单条消息字节上限（不含后端自身协议头）。

 Capabilities :: struct {

 max_message : int ; // 可靠通道

 max_unreliable : int ; // 不可靠通道；unreliable=false 时为0

 unreliable : bool ; // 是否支持不可靠通道

 local_pair : bool ; // 是否提供 open_local_pair

 remote_identity : bool ; // 是否提供后端已验证的对端身份

 connection_quality : bool ; // 是否提供 connection_quality


}

 // 未提供 capabilities 槽时的默认值，与引入能力槽之前的行为一致。

 DEFAULT_MAX_MESSAGE :: 4 * 1024 * 1024 ;
valid_driver :: ( d : Driver ) -> bool {

 v := d . vtable ;
return v != null && v . start_server != null && v . start_client != null && v . bound_port != null && v . local_connection != null && v . client_is_connected != null && v . poll != null && v . send != null && v . kick != null && v . incoming != null && v . clear_incoming != null && v . changes != null && v . clear_changes != null && v . flush != null && v . disconnect_local != null && v . stop_client != null && v . shutdown != null ;

 }


start_server :: ( d : Driver , port : u16 , max_clients : u64 = 32 ) -> bool {
return d . vtable . start_server ( d . data , port , max_clients ) ;
}

 start_client :: ( d : Driver , address : string , port : u16 ) -> bool {
return d . vtable . start_client ( d . data , address , port ) ;
}

 bound_port :: ( d : Driver ) -> u16 {
return d . vtable . bound_port ( d . data ) ;
}

 local_connection :: ( d : Driver ) -> Connection_Id {
return d . vtable . local_connection ( d . data ) ;
}

 client_is_connected :: ( d : Driver ) -> bool {
return d . vtable . client_is_connected ( d . data ) ;
}

 poll :: ( d : Driver ) {
d . vtable . poll ( d . data ) ;
}

 send :: ( d : Driver , id : Connection_Id , channel : Channel , payload : [ ] u8 ) -> bool {
return d . vtable . send ( d . data , id , channel , payload ) ;
}

 kick :: ( d : Driver , id : Connection_Id , after_delivery : bool = false ) -> Connection_State_Change_Result {
return d . vtable . kick ( d . data , id , after_delivery ) ;
}

 incoming_packets :: ( d : Driver ) -> [ ] Incoming_Packet {
return d . vtable . incoming ( d . data ) ;
}

 clear_incoming :: ( d : Driver ) {
d . vtable . clear_incoming ( d . data ) ;
}

 state_changes_view :: ( d : Driver ) -> [ ] State_Change {
return d . vtable . changes ( d . data ) ;
}

 clear_state_changes :: ( d : Driver ) {
d . vtable . clear_changes ( d . data ) ;
}

 flush :: ( d : Driver ) {
d . vtable . flush ( d . data ) ;
}

 disconnect_local :: ( d : Driver ) -> Connection_State_Change_Result {
return d . vtable . disconnect_local ( d . data ) ;
}

 stop_client :: ( d : Driver ) -> bool {
return d . vtable . stop_client ( d . data ) ;
}

 shutdown :: ( d : Driver ) {
d . vtable . shutdown ( d . data ) ;
}

 // 未选择后端时使用：所有操作都是空操作，启动和发送返回失败。

 null_driver :: ( ) -> Driver {
return .{
null , * null_vtable ,
} ;

 }

 null_vtable := Driver_Vtable .{

 start_server = ( p : * void , port : u16 , limit : u64 ) -> bool {
return false ;
} ,
start_client = ( p : * void , address : string , port : u16 ) -> bool {
return false ;
} ,
bound_port = ( p : * void ) -> u16 {
return 0 ;
} ,
local_connection = ( p : * void ) -> Connection_Id {
return 0 ;
} ,
client_is_connected = ( p : * void ) -> bool {
return false ;
} ,
poll = ( p : * void ) {

 } ,
send = ( p : * void , id : Connection_Id , channel : Channel , payload : [ ] u8 ) -> bool {
return false ;
} ,
kick = ( p : * void , id : Connection_Id , later : bool ) -> Connection_State_Change_Result {
return . Invalid_Connection ;
} ,
incoming = ( p : * void ) -> [ ] Incoming_Packet {
return .[ ] ;
} ,
clear_incoming = ( p : * void ) {

 } ,
changes = ( p : * void ) -> [ ] State_Change {
return .[ ] ;
} ,
clear_changes = ( p : * void ) {

 } ,
flush = ( p : * void ) {

 } ,
disconnect_local = ( p : * void ) -> Connection_State_Change_Result {
return . Invalid_Connection ;
} ,
stop_client = ( p : * void ) -> bool {
return true ;
} ,
shutdown = ( p : * void ) {

 } ,

 }

 loopback_address :: ( d : Driver ) -> string {

 if d . vtable . loopback_address != null {
return d . vtable . loopback_address ( d . data ) ;
}

 return "127.0.0.1" ;

 }

 capabilities :: ( d : Driver ) -> Capabilities {

 if d . vtable . capabilities == null {

 return .{
max_message = DEFAULT_MAX_MESSAGE , max_unreliable = DEFAULT_MAX_MESSAGE , unreliable = true ,
} ;


}

 c := d . vtable . capabilities ( d . data ) ;
if ! c . unreliable {
c . max_unreliable = 0 ;
}

 c . local_pair = c . local_pair && d . vtable . open_local_pair != null ;
c . remote_identity = c . remote_identity && d . vtable . remote_identity != null ;
c . connection_quality = c . connection_quality && d . vtable . connection_quality != null ;
return c ;

 }

 // 后端已验证的对端身份（例如平台账号），借用到下一次 poll/clear 为止；不提供时返回空串。

 // 各后端信任强度不同，是否据此批准连接由应用决定。

 remote_identity :: ( d : Driver , id : Connection_Id ) -> string {

 if d . vtable . remote_identity == null {
return "" ;
}

 return d . vtable . remote_identity ( d . data , id ) ;

 }

 // 连接不存在或后端不提供时返回 false。

 connection_quality :: ( d : Driver , id : Connection_Id ) -> Connection_Quality , bool {

 if d . vtable . connection_quality == null {
return .{

 } , false ;
} ;

 return d . vtable . connection_quality ( d . data , id ) ;

 }

 // 服务器半部已运行、客户端半部空闲时，在本进程内把客户端半部连到自己的服务器半部。

 // 两侧照常产生 Connected 状态变化。不提供时返回 false，调用方退回 loopback_address。

 open_local_pair :: ( d : Driver ) -> bool {

 if d . vtable . open_local_pair == null {
return false ;
}

 return d . vtable . open_local_pair ( d . data ) ;

 }

 //@endregion


// Cast semantics adapted. 

 // Loop scopes adapted. 
