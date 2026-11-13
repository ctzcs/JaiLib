#scope_file
core :: #import "thirdparty/onet/core" ;
objects :: #import "thirdparty/onet/objects" ;
transport :: #import "thirdparty/onet/transport" ;
wire :: #import "thirdparty/onet/wire" ;
#scope_export
// 对象级RPC；网络循环独占，身份由可信Session提供，payload在handler内借用。



 //@region 管理器与上下文

 Id :: #type,distinct u32 ;
Target :: enum u8 {
Server ; Observers ; Controller ; Connection ;
}

 Permission :: enum {
Controller_Only ; Any_Observer ;
}

 Disposition :: enum {
Origin ; Routing ; Recipient ;
}

 Send_Proc :: ( userdata : * void , to : transport . Connection_Id , channel : transport . Channel , payload : [ ] u8 ) -> bool ;
Observer_Proc :: ( userdata : * void , obj : * objects . Network_Object , connection : transport . Connection_Id ) -> bool ;
Connections_Proc :: ( userdata : * void ) -> [ ] transport . Connection_Id ;
Handler :: ( ctx : * Context , payload : [ ] u8 ) ;
// declared=true 表示只声明可发送的id（客户端常用），不处理收到的调用。

 Registration :: struct {
handler : Handler ;
permission : Permission ;
declared : bool ;
}

 // 服务器拒绝客户端调用的原因。仅用于诊断，不是安全机制。

 Reject_Reason :: enum {
Unknown_Object ; Not_Observed ; Not_Controller ; No_Handler ;
}

 Reject_Proc :: ( m : * Manager , from : transport . Connection_Id , call : Id , object : objects . Network_Id , reason : Reject_Reason ) ;
Context :: struct {

 manager : * Manager ;

 object : * objects . Network_Object ;

 sender : transport . Connection_Id ;

 target : Target ;

 disposition : Disposition ;

 channel : transport . Channel ;

 cancel_relay : bool ;

 amended : [ ] u8 ;

 has_amendment : bool ;


}

 Call :: struct {

 sequence : u64 ;

 tick : u64 ;

 id : Id ;

 object : objects . Network_Id ;

 target : Target ;

 to : transport . Connection_Id ;

 origin : transport . Connection_Id ;

 include_sender : bool ;

 payload : [ ] u8 ;


}

 Pending :: struct {
call : Call ;
channel : transport . Channel ;
from : transport . Connection_Id ;
received_ms : s64 ;
}

 Receive_Key :: struct {
connection : transport . Connection_Id ;
channel : transport . Channel ;
}

 Manager :: struct {

 registry : * objects . Registry ;

 authority : bool ;

 server_connection : transport . Connection_Id ;

 userdata : * void ;

 // nil 保持旧API；网络适配器可独立保留游戏handler的userdata。

 transport_userdata : * void ;

 send : Send_Proc ;

 is_observer : Observer_Proc ;

 connections : Connections_Proc ;

 handlers : H . Table ( Id , Registration ) ;

 seen : H . Table ( Receive_Key , u64 , hash_Receive_Key , equal_Receive_Key ) ;

 pending : [ .. ] Pending ;

 sequence : u64 ;

 tick : u64 ;

 clock_ms : s64 ;

 state_tick : u64 ;

 has_state : bool ;

 replaying : bool ;

 max_pending : int ;

 max_pending_bytes : int ;

 unreliable_hold_ms : int ;

 // 服务器侧诊断：拒绝客户端调用时回调并计数。

 on_rejected : Reject_Proc ;

 rejected : [ 4 ] int ;


}


init :: ( m : * Manager , reg : * objects . Registry , authority : bool ) {

 m .* = .{

 } ;

 m . registry = reg ;
m . authority = authority ;
m . handlers = new_table ( Id , Registration ) ;
m . seen = new_table ( Receive_Key , u64 , hash_function = hash_Receive_Key , compare_function = equal_Receive_Key ) ;
m . max_pending = 256 ;
m . max_pending_bytes = wire . MAX_PAYLOAD ;
m . unreliable_hold_ms = 100 ;

 }

 destroy :: ( m : * Manager ) {

 for pending : m . pending {

 release ( pending . call . payload ) ;

 }

 release ( m . pending ) ;
release ( m . handlers ) ;
release ( m . seen ) ;
m .* = .{

 } ;


}

 register :: ( m : * Manager , id : Id , handler : Handler , permission : Permission = . Controller_Only ) {

 H . table_set ( * m . handlers , id , .{
handler , permission , false ,
} ) ;


}

 // 只声明可以发送的id，不需要handler；已注册的handler保持不变。

 declare :: ( m : * Manager , id : Id , permission : Permission = . Controller_Only ) {

 if table_get ( * m . handlers , id ) . handler != null {
return ;
}

 H . table_set ( * m . handlers , id , .{
null , permission , true ,
} ) ;


}

 reject :: ( m : * Manager , from : transport . Connection_Id , call : * Call , reason : Reject_Reason ) {

 m . rejected [ ( cast ( int ) reason ) ] += 1 ;
if m . on_rejected != null {
m . on_rejected ( m , from , call . id , call . object , reason ) ;
}


}

 amend :: ( ctx : * Context , payload : [ ] u8 ) {

 release ( ctx . amended ) ;
ctx . amended = wire . clone ( payload ) ;
ctx . has_amendment = true ;

 }

 forget_connection :: ( m : * Manager , id : transport . Connection_Id ) {

 H . table_remove ( * m . seen , Receive_Key .{
id , . Reliable
} ) ;
H . table_remove ( * m . seen , Receive_Key .{
id , . Unreliable
} ) ;
kept := 0 ;
for pending : m . pending {

 if pending . from == id {
release ( pending . call . payload ) ;
}

 else {
m . pending [ kept ] = pending ;
kept += 1 ;
}


}

 array_resize ( * m . pending , kept ) ;

 } ;

 reset :: ( m : * Manager ) {

 for pending : m . pending {
release ( pending . call . payload ) ;
}

 array_reset_keeping_memory ( * m . pending ) ;
array_reset_keeping_memory ( * m . seen ) ;
m . has_state , m . state_tick , m . sequence = false , 0 , 0 ;

 }

 io_userdata :: ( m : * Manager ) -> * void {

 return ( ifx m . transport_userdata != null then m . transport_userdata else m . userdata ) ;

 }

 //@endregion


//@region 编码与接纳

 encode :: ( call : * Call ) -> ( [ ] u8 , bool ) {

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
core . write_uint32 ( * w , 0x4E525043 , . Uncompressed ) ;
core . write_uint8 ( * w , 1 , . Uncompressed ) ;
core . write_uint64 ( * w , call . sequence , . Uncompressed ) ;
core . write_uint64 ( * w , call . tick , . Uncompressed ) ;
core . write_uint32 ( * w , ( cast , trunc ( u32 ) ( call . id ) ) , . Uncompressed ) ;
core . write_uint32 ( * w , ( cast , trunc ( u32 ) ( call . object ) ) , . Uncompressed ) ;
core . write_uint8 ( * w , ( cast , trunc ( u8 ) ( call . target ) ) , . Uncompressed ) ;
core . write_uint32 ( * w , ( cast , trunc ( u32 ) ( call . to ) ) , . Uncompressed ) ;
core . write_uint32 ( * w , ( cast , trunc ( u32 ) ( call . origin ) ) , . Uncompressed ) ;
core . write_uint8 ( * w , ( ifx call . include_sender then 1 else 0 ) , . Uncompressed ) ;
wire . write_bytes ( * w , call . payload ) ;
if w . err != . None || core . writer_bytes_written ( * w ) > wire . MAX_PAYLOAD {

 return .[ ] , false ;

 }

 return core . writer_to_array ( * w ) , true ;

 }

 decode :: ( data : [ ] u8 ) -> ( Call , bool ) {

 call : Call ;
if ( data ) . count > wire . MAX_PAYLOAD {

 return call , false ;

 }

 r : core . Reader ;
core . reader_init ( * r , data ) ;
magic := core . read_uint32 ( * r , . Uncompressed ) ;
version := core . read_uint8 ( * r , . Uncompressed ) ;
call . sequence = core . read_uint64 ( * r , . Uncompressed ) ;
call . tick = core . read_uint64 ( * r , . Uncompressed ) ;
call . id = ( cast ( Id ) ( core . read_uint32 ( * r , . Uncompressed ) ) ) ;
call . object = ( cast ( objects . Network_Id ) ( core . read_uint32 ( * r , . Uncompressed ) ) ) ;
target := core . read_uint8 ( * r , . Uncompressed ) ;
call . target = ( cast ( Target ) ( target ) ) ;
call . to = ( cast ( transport . Connection_Id ) ( core . read_uint32 ( * r , . Uncompressed ) ) ) ;
call . origin = ( cast ( transport . Connection_Id ) ( core . read_uint32 ( * r , . Uncompressed ) ) ) ;
include := core . read_uint8 ( * r , . Uncompressed ) ;
call . include_sender = include == 1 ;
payload , ok := wire . read_bytes ( * r ) ;
call . payload = payload ;
if ! ok || ! wire . finished ( * r ) || magic != 0x4E525043 || version != 1 || call . sequence == 0 || call . id == 0 || call . object == 0 || target > ( cast , trunc ( u8 ) ( Target . Connection ) ) || include > 1 {

 release ( call . payload ) ;
call . payload = .[ ] ;
return call , false ;

 }

 return call , true ;

 }


observed :: ( m : * Manager , obj : * objects . Network_Object , id : transport . Connection_Id ) -> bool {

 return id != 0 && m . is_observer != null && m . is_observer ( io_userdata ( m ) , obj , id ) ;

 }


emit :: ( m : * Manager , to : transport . Connection_Id , call : * Call , channel : transport . Channel ) -> bool {

 if m . send == null || m . replaying || to == 0 {

 return false ;

 }

 data , ok := encode ( call ) ;
defer release ( data ) ;
return ok && m . send ( io_userdata ( m ) , to , channel , data ) ;

 }


invoke :: ( m : * Manager , obj : * objects . Network_Object , call : * Call , channel : transport . Channel , disposition : Disposition ) -> ( bool , [ ] u8 , bool ) {

 registration := table_get ( * m . handlers , call . id ) ;
if registration . handler == null {

 return false , .[ ] , false ;

 }

 ctx := Context .{
manager = m , object = obj , sender = call . origin , target = call . target , disposition = disposition , channel = channel ,
} ;

 registration . handler ( * ctx , call . payload ) ;
return ! ctx . cancel_relay , ctx . amended , ctx . has_amendment ;

 }


route :: ( m : * Manager , from : transport . Connection_Id , call : * Call , channel : transport . Channel ) -> bool {

 obj , exists := objects . get ( m . registry , call . object ) ;
if ! exists {

 if m . authority && from != 0 {
reject ( m , from , call , . Unknown_Object ) ;
}

 return m . authority ; // 与服务器despawn竞争的调用按已结束处理。


}

 registration := table_get ( * m . handlers , call . id ) ;
if registration . handler == null {

 if m . authority && from != 0 {
reject ( m , from , call , . No_Handler ) ;
}

 return false ;

 }

 if ! m . authority {

 _ , amended , loop_index := invoke ( m , obj , call , channel , . Recipient ) ;
release ( amended ) ;
return true ;

 }

 if from != 0 {

 if ! observed ( m , obj , from ) {

 reject ( m , from , call , . Not_Observed ) ;
return false ;

 }

 if registration . permission == . Controller_Only && obj . owner != from {

 reject ( m , from , call , . Not_Controller ) ;
return false ;

 }

 call . origin = from ; // 永远不相信客户端自报origin。


}

 local := call . target == . Server || ( call . target == . Controller && obj . owner == 0 ) ;
disposition := Disposition . Routing ;
if local || from == 0 {

 disposition = . Origin ;

 }

 allowed , amended , has_amendment := invoke ( m , obj , call , channel , disposition ) ;
defer release ( amended ) ;
if local || ! allowed {

 return true ;

 }

 out := call .* ;
if has_amendment {

 out . payload = amended ;

 }

 m . sequence += 1 ;
out . sequence = m . sequence ;
out . tick = m . tick ;
if call . target == {

 case . Server ;
return true ;
case . Observers ;
if m . connections == null {

 return false ;

 }

 ok := true ;
for id : m . connections ( io_userdata ( m ) ) {

 if observed ( m , obj , id ) && ( call . include_sender || id != from ) {

 ok = emit ( m , id , * out , channel ) && ok ;

 }


}

 return ok ;
case . Controller , . Connection ;
to := call . to ;
if call . target == . Controller {

 to = obj . owner ;

 }

 if ! observed ( m , obj , to ) || ( ! call . include_sender && to == from ) {

 return false ;

 }

 return emit ( m , to , * out , channel ) ;

 }

 return false ;

 }

 //@endregion


//@region 调用与等待队列

 // 客户端返回true只表示已发出；服务器是否接受见其on_rejected。id须已register或declare。

 send :: ( m : * Manager , id : Id , object : objects . Network_Id , target : Target , payload : [ ] u8 , to : transport . Connection_Id = 0 , channel : transport . Channel = . Reliable , include_sender : bool = false ) -> bool {

 registration , known := table_get ( * m . handlers , id ) ;
if m . replaying || ( payload ) . count > wire . MAX_PAYLOAD || ! known || ( registration . handler == null && ! registration . declared ) {

 return false ;

 }

 m . sequence += 1 ;
call := Call .{
sequence = m . sequence , tick = m . tick , id = id , object = object , target = target , to = to , include_sender = include_sender , payload = payload ,
} ;

 if m . authority {

 return route ( m , 0 , * call , channel ) ;

 }

 return emit ( m , m . server_connection , * call , channel ) ;

 }


// 用core.Writer编码参数后发送；不改变线协议，接收端用reader(payload)读取。

 Write_Proc :: ( w : * core . Writer , user : * void ) ;
send_with :: ( m : * Manager , id : Id , object : objects . Network_Id , target : Target , write : Write_Proc , user : * void = null , to : transport . Connection_Id = 0 , channel : transport . Channel = . Reliable , include_sender : bool = false ) -> bool {

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
if write != null {
write ( * w , user ) ;
}

 if w . err != . None {
return false ;
}

 payload := core . writer_to_array ( * w ) ;
defer release ( payload ) ;
return send ( m , id , object , target , payload , to , channel , include_sender ) ;

 }

 // handler内借用payload读取send_with写入的参数；读完可用wire.finished校验。

 reader :: ( payload : [ ] u8 ) -> core . Reader {

 r : core . Reader ;
core . reader_init ( * r , payload ) ;
return r ;

 }


receive :: ( m : * Manager , from : transport . Connection_Id , channel : transport . Channel , data : [ ] u8 ) -> bool {

 if m . replaying || ( ! m . authority && from != m . server_connection ) {

 return false ;

 }

 call , ok := decode ( data ) ;
if ! ok {

 return false ;

 }

 owned := true ;
defer {

 if owned {

 release ( call . payload ) ;

 }


}

 key := Receive_Key .{
from , channel ,
} ;

 if call . sequence <= table_get ( * m . seen , key ) {

 return true ;

 }

 if m . authority && call . origin != 0 {

 return false ;

 }

 if m . authority {

 accepted := route ( m , from , * call , channel ) ;
if accepted {

 H . table_set ( * m . seen , key , call . sequence ) ;

 }

 return accepted ;

 }

 _ , exists := objects . get ( m . registry , call . object ) ;
queued_reliable := false ;
pending_bytes := 0 ;
for pending : m . pending {

 pending_bytes += ( pending . call . payload ) . count ;
queued_reliable = queued_reliable || pending . channel == . Reliable ;

 }

 if ! exists || ( channel == . Reliable && queued_reliable ) {

 if ( m . pending ) . count >= m . max_pending || pending_bytes + ( call . payload ) . count > m . max_pending_bytes {

 return false ;

 }

 array_add ( * m . pending , Pending .{
call , channel , from , m . clock_ms
} ) ;
owned = false ;
H . table_set ( * m . seen , key , call . sequence ) ;
return true ;

 } ;

 accepted := route ( m , from , * call , channel ) ;
if accepted {

 H . table_set ( * m . seen , key , call . sequence ) ;

 }

 return accepted ;

 }


update :: ( m : * Manager , delta_ms : int ) {

 m . clock_ms += ( cast , trunc ( s64 ) ( max ( delta_ms , 0 ) ) ) ;
blocked := false ;
kept := 0 ;
{ i := 0 ; while i < ( m . pending ) . count { defer i += 1 ;

 pending := * m . pending [ i ] ;
_ , exists := objects . get ( m . registry , pending . call . object ) ;
confirmed_absent := m . has_state && m . state_tick >= pending . call . tick && ! exists ;
expired := pending . channel == . Unreliable && m . clock_ms - pending . received_ms >= ( cast , trunc ( s64 ) ( m . unreliable_hold_ms ) ) ;
ready := exists && ! ( blocked && pending . channel == . Reliable ) ;
if ready {

 route ( m , pending . from , * pending . call , pending . channel ) ;

 }

 if ready || confirmed_absent || expired {

 release ( pending . call . payload ) ;

 } else {

 if pending . channel == . Reliable {

 blocked = true ;

 }

 m . pending [ kept ] = pending .* ;
kept += 1 ;

 }


} }

 array_resize ( * m . pending , kept ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted.    

 // Cast semantics adapted. 
