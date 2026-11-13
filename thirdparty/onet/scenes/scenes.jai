#scope_file
codec :: #import "thirdparty/onet/core" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export


//@region 公共类型与所有权

 Handle :: #type,distinct u32 ;
Asset_Id :: #type,distinct u16 ;
Role :: enum {
Server ; Client ;
}

 Scope_Kind :: enum {
Connections ; Global ;
}

 Scope :: struct {

 kind : Scope_Kind ;

 // 输入借用；open/set_scope 会复制。连接号不是账户号，跨重连映射由 Session 负责。

 connections : [ ] transport . Connection_Id ;


}

 Phase :: enum {
Opening ; Open ; Closing ; Waiting ;
}

 State :: enum {
Absent ; Loading ; Loaded ; Load_Failed ; Unloading ; Unload_Failed ;
}

 Operation :: enum {
Load ; Unload ;
}

 Ticket :: struct {

 handle : Handle ;

 asset : Asset_Id ;

 serial : u64 ;

 revision : u64 ;

 operation : Operation ;


}

 Event_Kind :: enum {

 Opened ; Closing ; Closed ; Load_Requested ; Unload_Requested ;
Loaded ; Unloaded ; Load_Failed ; Unload_Failed ; Timeout ;
Before_Unload ; Replace_Committed ; Replace_Failed ; Disconnected ;
Unexpected_Unload ;

 }

 Event :: struct {

 kind : Event_Kind ;

 handle , other : Handle ;

 connection : transport . Connection_Id ;
// 0 表示本机。

 revision : u64 ;


}

 // payload 只在调用期间有效，Send 必须复制并走可靠有序通道；true 表示已可靠接管。

 // 除 complete_* 外，所有回调均在单一网络 loop 调用，不可重入管理器。

 // Observer/validator/progress registration changes may be queued from callbacks.

 Send_Proc :: #type ( userdata : * void , to : transport . Connection_Id , payload : [ ] u8 ) -> bool ;
// Ticket 是值。加载成功前注册全部 scene objects；失败必须释放部分资源。

 // 每个 Ticket 恰好完成一次；同 handle 的 engine 操作不会并行。

 Request_Proc :: #type ( userdata : * void , ticket : Ticket ) ;
Event_Proc :: #type ( userdata : * void , event : Event ) ;
// 仅用于显式 carry replace；true 表示调用方已迁移对象/携带关系，false 保留旧 scene。

 Carry_Proc :: #type ( userdata : * void , old_scene , new_scene : Handle ) -> bool ;
// 受信任的本机策略；只验证新 revision 的远端 Load，不验证本机 open。

 Validate_Load_Proc :: #type ( userdata : * void , scene : Handle , asset : Asset_Id , authority : transport . Connection_Id ) -> bool ;
// carry 成功后轮询，0 表示本机，其他值表示仍持有旧 scene 的已认证 peer。

 // 必须无副作用、非阻塞；false 延迟整个提交，直到超时失败。不能在此同步调用管理器。

 Ready_To_Unload_Proc :: #type ( userdata : * void , old_scene , new_scene : Handle , connection : transport . Connection_Id ) -> bool ;
Config :: struct {

 role : Role ;

 userdata : * void ;
// 借用，必须活到 destroy 成功且所有生产者退出。

 send : Send_Proc ;

 request : Request_Proc ;

 event : Event_Proc ;

 carry : Carry_Proc ;

 timeout_ms : u64 ;

 resend_ms : u64 ;

 max_scenes : int ;
// 同时存在的记录上限，不含已经回收的 handle。

 validate_load : Validate_Load_Proc ;

 ready_to_unload : Ready_To_Unload_Proc ;

 replace_timeout_ms : u64 ;
// 0 使用 timeout_ms；包含加载、carry 与 ACK gate 等待。

 loader : * Loader ;
// borrowed global scheduler, shared by host server/client

 loader_namespace : u64 ;
// same explicit nonzero namespace shares matching handles

 release_guard : #type ( * void , Handle ) -> bool ;
// authority: gate the entire close, including remote unload requests

 release_guard_userdata : * void ;

 join_placement : Join_Placement ;
// zero Scope keeps existing Odin allowlists

 automatic_request_on_blocked_spawn : bool ;
// default false

 carry_policy : * Carry_Policy ;
// borrowed, installed by typed Carry_Binding


}

 Info :: struct {

 asset : Asset_Id ;

 phase : Phase ;

 local_state : State ;

 load_here : bool ;

 replacement : Handle ;


}

 Remote :: struct {

 state : State ;

 revision : u64 ;

 began , last_sent : u64 ;

 send_pending , dispatched : bool ;

 load_after_unload : bool ;
// scope 重新加入时，先可靠卸载，再加载。

 held , scope_override , failure_latched : bool ;


}

 Local :: struct {

 held , desired , busy , failed : bool ;

 failure_operation : Operation ;

 began : u64 ;

 ticket : Ticket ;

 cancel_requested : bool ;


}

 Scene :: struct {

 asset : Asset_Id ;

 phase : Phase ;

 scope : Scope ;
// connections 由管理器拥有。

 remotes : H . Table ( transport . Connection_Id , Remote ) ;
// 管理器拥有。

 load_here : bool ;

 local : Local ;

 revision : u64 ;
// 客户端最新的 authority 请求。

 report_ready , report_sent : bool ;

 report_kind : Packet_Kind ;

 replacement : Handle ;

 carry : bool ;

 load_rejected : bool ;

 replace_began : u64 ;

 carry_done : bool ;

 release_from : Handle ;
// release-first 操作归目标记录所有，源记录必须先物理释放。

 release_started : bool ;

 release_allowed : bool ;


}

 Completion :: struct {
ticket : Ticket ;
success : bool ;
}

 Manager :: struct {

 // 整个 Manager 不可复制或移动。除 complete_* 外，字段只归单一网络 loop 所有。

 config : Config ;

 allocator : Allocator ;

 scenes : H . Table ( Handle , * Scene ) ;

 peers : H . Table ( transport . Connection_Id , u64 ) ;
// 已认证连接 -> 本次连接唯一 epoch。

 authority : transport . Connection_Id ;

 epoch , last_revision : u64 ;

 next_handle : u32 ;

 next_revision , next_ticket : u64 ;

 now : u64 ;

 stopping , initialized , clock_started : bool ;

 garbage : [ .. ] Handle ;

 // 仅下面三个字段归 mutex 保护；complete_* 可由任意线程调用。

 mutex : Thread . Mutex ;

 completions : [ .. ] Completion ;

 accept_completions : bool ;

 draining : [ .. ] Completion ;
// loop 独占的第二个缓冲。

 api : Scene_API ;


}

 //@endregion


//@region 固定长度协议与原子解析

 Packet_Kind :: enum u8 {

 Load = 1 ; Unload ; Loaded ; Load_Failed ; Unloaded ; Unload_Failed ;

 }

 Packet :: struct {

 kind : Packet_Kind ;

 handle : Handle ;

 asset : Asset_Id ;

 epoch , revision : u64 ;


}

 PACKET_SIZE :: 28 ;
packet_valid :: ( p : Packet ) -> bool {

 return p . kind >= . Load && p . kind <= . Unload_Failed && p . handle != 0 && p . epoch != 0 && p . revision != 0 ;

 }

 // 返回栈值，无调用方需释放的内存。

 encode_packet :: ( p : Packet ) -> ( data : [ PACKET_SIZE ] u8 , ok : bool ) {

 if ! packet_valid ( p ) {
return data , false ;
}

 w : codec . Writer ;
codec . writer_init ( * w , PACKET_SIZE ) ;
defer codec . writer_destroy ( * w ) ;
codec . write_bits ( * w , 0x5343 , 16 ) ;
codec . write_bits ( * w , 1 , 8 ) ;
codec . write_bits ( * w , ( cast , trunc ( u64 ) ( p . kind ) ) , 8 ) ;
codec . write_bits ( * w , ( cast , trunc ( u64 ) ( p . handle ) ) , 32 ) ;
codec . write_bits ( * w , ( cast , trunc ( u64 ) ( p . asset ) ) , 16 ) ;
codec . write_bits ( * w , 0 , 16 ) ;
codec . write_bits ( * w , p . epoch , 64 ) ;
codec . write_bits ( * w , p . revision , 64 ) ;
if codec . writer_failed ( * w ) {
return data , false ;
}

 copy_samples ( view ( data , 0 ) , view ( w . buffer , 0 ) ) ;
return data , true ;

 }

 // 先完整校验，失败不修改任何网络状态；拒绝截断、尾随字节及非零保留位。

 decode_packet :: ( data : [ ] u8 ) -> ( p : Packet , ok : bool ) {

 if ( data ) . count != PACKET_SIZE {
return .{

 } , false ;
} ;

 r : codec . Reader ;
codec . reader_init ( * r , data ) ;
magic := codec . read_bits ( * r , 16 ) ;
version := codec . read_bits ( * r , 8 ) ;
p . kind = ( cast ( Packet_Kind ) ( codec . read_bits ( * r , 8 ) ) ) ;
p . handle = ( cast ( Handle ) ( codec . read_bits ( * r , 32 ) ) ) ;
p . asset = ( cast ( Asset_Id ) ( codec . read_bits ( * r , 16 ) ) ) ;
reserved := codec . read_bits ( * r , 16 ) ;
p . epoch = codec . read_bits ( * r , 64 ) ;
p . revision = codec . read_bits ( * r , 64 ) ;
if codec . reader_failed ( * r ) || magic != 0x5343 || version != 1 || reserved != 0 || ! packet_valid ( p ) {

 return .{

 } , false ;

 } ;

 return p , true ;

 }

 //@endregion


//@region 生命周期与连接身份

 init :: ( m : * Manager , config : Config , allocator := context . allocator ) {

 assert ( ! m . initialized ) ;
m . config = config ;
if m . config . timeout_ms == 0 {
m . config . timeout_ms = 180000 ;
}

 if m . config . resend_ms == 0 {
m . config . resend_ms = 1000 ;
}

 if m . config . max_scenes <= 0 {
m . config . max_scenes = 1024 ;
}

 if m . config . replace_timeout_ms == 0 {
m . config . replace_timeout_ms = m . config . timeout_ms ;
}

 m . allocator = allocator ;
m . scenes = new_table ( Handle , * Scene , allocator ) ;
m . peers = new_table ( transport . Connection_Id , u64 , allocator ) ;
m . garbage = new_dynamic ( Handle , allocator ) ;
m . completions = new_dynamic ( Completion , allocator ) ;
m . draining = new_dynamic ( Completion , allocator ) ;
m . api . local_peers = new_table ( transport . Connection_Id , bool , allocator ) ;
m . next_handle = 1 ;
m . next_revision = 1 ;
m . next_ticket = 1 ;
Thread . init ( * m . mutex ) ;
m . initialized = true ;
m . accept_completions = true ;
{ p := m . config . carry_policy ; if
p != null {
assert ( bind_carry_policy ( m , p ) ) ;
} }


}

 notify :: ( m : * Manager , kind : Event_Kind , h : Handle , c : transport . Connection_Id = 0 , revision : u64 = 0 , other : Handle = 0 ) {

 if m . config . event != null {
m . config . event ( m . config . userdata , .{
kind , h , other , c , revision
} ) ;
} ;

 if c != 0 && m . config . role == . Server {

 asset : Asset_Id ;
{ s := table_get ( * m . scenes , h ) ; if
s != null {
asset = s . asset ;
} }

 if kind == {

 case . Load_Requested , . Unload_Requested ; observe ( m , .{ . Requested , c , h , asset , kind == . Load_Requested , revision
} ) ;
case . Load_Failed ; observe ( m , .{ . Load_Failed , c , h , asset , false , revision
} ) ;

 }


}


}

 scope_contains :: ( scope : Scope , c : transport . Connection_Id ) -> bool {

 if scope . kind == . Global {
return true ;
}

 for id : scope . connections {
if id == c {
return true ;
}

 }

 return false ;

 }

 in_scope :: ( s : * Scene , c : transport . Connection_Id ) -> bool {
return scope_contains ( s . scope , c ) ;
}

 scope_valid :: ( scope : Scope ) -> bool {

 if scope . kind != . Global && scope . kind != . Connections {
return false ;
}

 for c : scope . connections {
if c == 0 {
return false ;
}

 }

 return true ;

 }

 scope_covers :: ( wide , narrow : Scope ) -> bool {

 if narrow . kind == . Global {
return wide . kind == . Global ;
}

 for c : narrow . connections {
if ! scope_contains ( wide , c ) {
return false ;
}

 }

 return true ;

 }

 // Session 仅在认证完成后调用；epoch 必须由受信任握手给双方，且每次重新加入都不重复。

 peer_join :: ( m : * Manager , c : transport . Connection_Id , epoch : u64 , local_peer : bool = false ) -> bool {

 if ! m . initialized || m . stopping || m . config . role != . Server || c == 0 || epoch == 0 {
return false ;
}

 { _ , exists := table_get ( * m . peers , c ) ; if
exists {
return false ;
} }

 H . table_set ( * m . peers , c , epoch ) ;
H . table_set ( * m . api . local_peers , c , local_peer ) ;
for s , h : m . scenes {

 if s . phase != . Open || local_peer {
continue ;
}

 if m . config . join_placement == {

 case . Scope ; if in_scope ( s , c ) {
request_load ( m , h , c ) ;
}

 case . Every_Open_Scene ; request_placement ( m , h , c ) ;
case . Global_Scenes ; if s . scope . kind == . Global {
request_placement ( m , h , c ) ;
}

 case . None ;

 }


}

 return true ;

 }

 peer_leave :: ( m : * Manager , c : transport . Connection_Id ) {

 if m . config . role != . Server {
return ;
}

 H . table_remove ( * m . peers , c ) ;
H . table_remove ( * m . api . local_peers , c ) ;
for s , h : m . scenes {

 { r , exists := table_get ( * s . remotes , c ) ; if
exists {

 H . table_remove ( * s . remotes , c ) ;
if r . held {
observe ( m , .{ . State_Changed , c , h , s . asset , false , r . revision
} ) ;
}

 if r . state != . Absent {
notify ( m , . Disconnected , h , c , r . revision ) ;
}


} }


}


}

 // 必须先 disconnect，再 update 到旧资源全部释放。

 bind_authority :: ( m : * Manager , authority : transport . Connection_Id , epoch : u64 ) -> bool {

 if ! m . initialized || m . stopping || m . config . role != . Client || authority == 0 || epoch == 0 || m . authority != 0 {
return false ;
}

 for s , _ : m . scenes {
if s . local . busy || s . local . held {
return false ;
}

 }

 for s , h : m . scenes {
free_scene ( m , h , s ) ;
}

 m . authority = authority ;
m . epoch = epoch ;
m . last_revision = 0 ;
return true ;

 }

 disconnect :: ( m : * Manager ) {

 if m . config . role != . Client {
return ;
}

 m . authority = 0 ;
m . epoch = 0 ;
for s , _ : m . scenes {

 s . phase = . Closing ;
s . local . desired = false ;
s . local . failed = false ;
s . report_ready = false ;

 }


}

 shutdown :: ( m : * Manager ) {

 if ! m . initialized || m . stopping {
return ;
}

 m . stopping = true ;
if m . config . role == . Client {

 disconnect ( m ) ;

 } else {

 for _ , h : m . scenes {
close ( m , h ) ;
}


}


}

 // false 表示仍有 engine 资源/请求或远端卸载未结束：继续 update，重试或 peer_leave。

 // 成功销毁前调用方必须停止并 join completion 生产者；此函数本身不可与生产者并行。

 destroy :: ( m : * Manager ) -> bool {

 if ! m . initialized {
return true ;
}

 if ! m . stopping || ( m . scenes ) . count != 0 {
return false ;
}

 Thread . lock ( * m . mutex ) ;
m . accept_completions = false ;
release ( m . completions ) ;
Thread . unlock ( * m . mutex ) ;
release ( m . draining ) ;
release ( m . garbage ) ;
release ( m . scenes ) ;
release ( m . peers ) ;
api_destroy ( m ) ;
Thread . destroy ( * m . mutex ) ;
m .* = .{

 } ;

 return true ;

 }

 free_scene :: ( m : * Manager , h : Handle , s : * Scene ) {

 release ( s . scope . connections , m . allocator ) ;
release ( s . remotes ) ;
free ( s , m . allocator ) ;
H . table_remove ( * m . scenes , h ) ;

 }

 //@endregion


//@region Authority 开放、请求、关闭与替换

 open :: ( m : * Manager , asset : Asset_Id , scope : Scope , load_here := false ) -> ( Handle , bool ) {

 return create_scene ( m , asset , scope , load_here , false ) ;

 }

 create_scene :: ( m : * Manager , asset : Asset_Id , scope : Scope , load_here , waiting : bool ) -> ( h : Handle , ok : bool ) {

 if ! m . initialized || m . stopping || m . config . role != . Server || m . next_handle == 0 || ( m . scenes ) . count >= m . config . max_scenes {
return 0 , false ;
}

 if ! scope_valid ( scope ) || ( load_here && m . config . request == null && m . config . loader == null ) {
return 0 , false ;
}

 h = ( cast ( Handle ) ( m . next_handle ) ) ;
m . next_handle += 1 ; // 溢出至 0 后永久耗尽，不重用。

 s := new_one ( Scene , m . allocator ) ;
s . asset = asset ;
s . scope . kind = scope . kind ;
s . scope . connections = new_slice ( transport . Connection_Id , ( scope . connections ) . count , m . allocator ) ;
copy_samples ( s . scope . connections , scope . connections ) ;
s . remotes = new_table ( transport . Connection_Id , Remote , m . allocator ) ;
s . load_here = load_here ;
s . local . desired = load_here && ! waiting ;
s . phase = ( ifx waiting then . Waiting else ( ifx load_here then . Opening else . Open ) ) ;
H . table_set ( * m . scenes , h , s ) ;
notify ( m , . Opened , h ) ;
if s . phase == . Open {
place_scene ( m , s , h ) ;
}

 return h , true ;

 }

 // 更新允许范围；不重新加载留在 scope 内的手工卸载/失败项。替换期间 scope 必须稳定。

 set_scope :: ( m : * Manager , h : Handle , scope : Scope ) -> bool {

 s , exists := table_get ( * m . scenes , h ) ;
if ! exists || m . config . role != . Server || m . stopping || s . phase == . Closing || ! scope_valid ( scope ) || replacement_busy ( m , h ) {
return false ;
}

 { guard := m . config . release_guard ; if
guard != null && ! guard ( m . config . release_guard_userdata , h ) {
return false ;
} }

 // 预留最坏情况的 revision，避免耗尽时部分提交 scope。

 if ( m . peers ) . count > 0 && ( m . next_revision == 0 || ( cast , trunc ( u64 ) ( ( m . peers ) . count - 1 ) ) > ( cast , trunc ( u64 ) ( 18446744073709551615 ) ) - m . next_revision ) {
return false ;
}

 next := Scope .{
kind = scope . kind , connections = new_slice ( transport . Connection_Id , ( scope . connections ) . count , m . allocator ) ,
} ;

 copy_samples ( next . connections , scope . connections ) ;
previous := s . scope ;
s . scope = next ; // 先关移出者的复制 gate；ACK 不再依赖当前 scope。

 for _ , c : m . peers {

 was , now := scope_contains ( previous , c ) , in_scope ( s , c ) ;
r := table_get ( * s . remotes , c ) ;
if ! now {

 r . scope_override = false ;
r . load_after_unload = false ;
H . table_set ( * s . remotes , c , r ) ;
if r . state != . Absent && r . state != . Unloading {
start_remote ( m , s , h , c , . Unload ) ;
}


} else if ! was && s . phase == . Open {

 if r . state == . Unloading || r . state == . Unload_Failed {

 if r . state == . Unload_Failed {
start_remote ( m , s , h , c , . Unload ) ;
}

 r = table_get ( * s . remotes , c ) ;
r . load_after_unload = true ;
H . table_set ( * s . remotes , c , r ) ;

 } else if r . state == . Absent || r . state == . Load_Failed {

 start_remote ( m , s , h , c , . Load ) ;

 }


}


}

 release ( previous . connections , m . allocator ) ;
return true ;

 }

 place_scene :: ( m : * Manager , s : * Scene , h : Handle ) {

 for _ , c : m . peers {
if in_scope ( s , c ) {
start_remote ( m , s , h , c , . Load ) ;
}

 }


}

 start_remote :: ( m : * Manager , s : * Scene , h : Handle , c : transport . Connection_Id , op : Operation , load_after_unload := false ) -> bool {

 if m . next_revision == 0 || table_get ( * m . peers , c ) == 0 || table_get ( * m . api . local_peers , c ) {
return false ;
}

 if op == . Load && ! load_allowed ( m , c , h , s . asset ) {
return false ;
}

 r := Remote .{
state = ( ifx op == . Load then . Loading else . Unloading ) , revision = m . next_revision , began = m . now , send_pending = true ,
} ;

 previous := table_get ( * s . remotes , c ) ;
r . held , r . scope_override = previous . held , previous . scope_override ;
r . failure_latched = op == . Unload && previous . failure_latched ;
r . load_after_unload = load_after_unload ;
m . next_revision += 1 ;
H . table_set ( * s . remotes , c , r ) ;
notify ( m , ( ifx op == . Load then . Load_Requested else . Unload_Requested ) , h , c , r . revision ) ;
return true ;

 }

 // 失败锁存：只有 retry=true 才重新尝试，成功/正在加载时不会重复请求。

 request_load :: ( m : * Manager , h : Handle , c : transport . Connection_Id , retry := false ) -> bool {

 s , exists := table_get ( * m . scenes , h ) ;
if ! exists || m . config . role != . Server || m . stopping || s . phase != . Open || ! peer_scope ( s , c ) {
return false ;
}

 { _ , joined := table_get ( * m . peers , c ) ; if
! joined {
return false ;
} }

 r := table_get ( * s . remotes , c ) ;
if r . failure_latched && ! retry {
return false ;
}

 if r . state != . Absent && ! ( retry && r . state == . Load_Failed ) {
return false ;
}

 return start_remote ( m , s , h , c , . Load ) ;

 }

 request_unload :: ( m : * Manager , h : Handle , c : transport . Connection_Id ) -> bool {

 s , exists := table_get ( * m . scenes , h ) ;
if ! exists || m . config . role != . Server {
return false ;
}

 { guard := m . config . release_guard ; if
guard != null && ! guard ( m . config . release_guard_userdata , h ) {
return false ;
} }

 r , requested := table_get ( * s . remotes , c ) ;
if ! requested || r . state == . Absent || r . state == . Unloading {
return false ;
}

 return start_remote ( m , s , h , c , . Unload , r . load_after_unload && s . phase == . Open && peer_scope ( s , c ) ) ;

 }

 close :: ( m : * Manager , h : Handle ) -> bool {

 s , exists := table_get ( * m . scenes , h ) ;
if ! exists || m . config . role != . Server {
return false ;
}

 // Resolve a destination abort before it can begin physical teardown.

 for a , source : m . scenes {
if source != h && a . replacement == h {
abort_replace ( m , source ) ;
}

 }

 if s . phase != . Closing {

 s . phase = . Closing ; // 先关 gate，再发卸载，再等待 ACK，最后释放本机。

 if s . replacement != 0 {
notify ( m , . Replace_Failed , h , other = s . replacement ) ;
}

 s . replacement = 0 ;
notify ( m , . Closing , h ) ;

 }

 if ! s . release_allowed {

 { guard := m . config . release_guard ; if
guard != null && ! guard ( m . config . release_guard_userdata , h ) {
return true ;
} }

 s . release_allowed = true ;

 }

 for r , c : s . remotes {

 if r . state != . Absent && r . state != . Unloading {
start_remote ( m , s , h , c , . Unload ) ;
}


}

 // 明确 close 重试本机卸载失败；运行中的 load 不取消，完成后串行释放。

 s . local . failed = false ;
return true ;

 }

 // 防止链、环，以及 scope 在替换期间改变；不限制 peer_join/peer_leave。

 replacement_busy :: ( m : * Manager , h : Handle ) -> bool {

 for s , source : m . scenes {

 if s . replacement != 0 && ( source == h || s . replacement == h ) {
return true ;
}

 if s . release_from != 0 && ( source == h || s . release_from == h ) {
return true ;
}


}

 return false ;

 }

 begin_replace :: ( m : * Manager , old_scene , new_scene : Handle , carry := false ) -> bool {

 a , a_ok := table_get ( * m . scenes , old_scene ) ;
b , b_ok := table_get ( * m . scenes , new_scene ) ;
if m . config . role != . Server || m . stopping || ! a_ok || ! b_ok || old_scene == new_scene || a . phase != . Open || b . phase == . Closing || b . phase == . Waiting || replacement_busy ( m , old_scene ) || replacement_busy ( m , new_scene ) {
return false ;
}

 if carry && m . config . carry == null {
return false ;
}

 if ( a . load_here && ! b . load_here ) || ! scope_covers ( b . scope , a . scope ) {
return false ;
}

 { guard := m . config . release_guard ; if
guard != null && ( ! guard ( m . config . release_guard_userdata , old_scene ) || ! guard ( m . config . release_guard_userdata , new_scene ) ) {
return false ;
} }

 a . replacement = new_scene ;
a . carry = carry ;
a . carry_done = false ;
a . replace_began = m . now ;
return true ;

 }

 abort_replace :: ( m : * Manager , old_scene : Handle ) -> bool {

 s , exists := table_get ( * m . scenes , old_scene ) ;
if ! exists || m . config . role != . Server || s . replacement == 0 {
return false ;
}

 notify ( m , . Replace_Failed , old_scene , other = s . replacement ) ;
s . replacement = 0 ;
s . carry_done = false ;
return true ;

 }

 // 不携带对象、不回滚旧 scene；先等待全部旧资源卸载，再开始目标加载。

 replace_release_first :: ( m : * Manager , old_scene : Handle , asset : Asset_Id , scope : Scope , load_here := false ) -> ( Handle , bool ) {

 a , exists := table_get ( * m . scenes , old_scene ) ;
if ! exists || a . phase != . Open || replacement_busy ( m , old_scene ) || ( a . load_here && ! load_here ) || ! scope_valid ( scope ) || ! scope_covers ( scope , a . scope ) {
return 0 , false ;
}

 h , ok := create_scene ( m , asset , scope , load_here , true ) ;
if ! ok {
return 0 , false ;
}

 b := table_get ( * m . scenes , h ) ;
b . release_from = old_scene ;
b . replace_began = m . now ;
close ( m , old_scene ) ;
return h , true ;

 }

 // ready=false 只是尚未全部加载；failed=true 才锁存失败。

 replacement_ready :: ( m : * Manager , b : * Scene ) -> ( ready : bool , failed : bool ) {

 if b . phase == . Closing {
return false , true ;
}

 if b . phase != . Open {
return false , false ;
}

 ready = true ;
for _ , c : m . peers {

 if ! in_scope ( b , c ) {
continue ;
}

 r := table_get ( * b . remotes , c ) ;
if r . state == . Load_Failed || r . state == . Unload_Failed || r . state == . Unloading {
return false , true ;
}

 if r . state != . Loaded {
ready = false ;
}


}

 return ready , false ;

 }

 advance_replace :: ( m : * Manager , h : Handle , a : * Scene ) {

 if a . replacement == 0 || a . phase != . Open {
return ;
}

 dest := a . replacement ;
b , exists := table_get ( * m . scenes , dest ) ;
ready , failed := false , ! exists ;
if exists {
ready , failed = replacement_ready ( m , b ) ;
}

 timed_out := m . now - a . replace_began >= m . config . replace_timeout_ms ;
if failed || timed_out {

 a . replacement = 0 ;
if timed_out {
notify ( m , . Timeout , h , other = dest ) ;
}

 notify ( m , . Replace_Failed , h , other = dest ) ;
return ;

 }

 if ! ready {
return ;
}

 if ! a . carry_done {

 if a . carry && ! m . config . carry ( m . config . userdata , h , dest ) {

 a . replacement = 0 ;
notify ( m , . Replace_Failed , h , other = dest ) ;
return ;

 }

 a . carry_done = true ; // ACK 等待期间绝不重复迁移。


}

 if m . config . ready_to_unload != null {

 allowed := true ;
if a . load_here && ! m . config . ready_to_unload ( m . config . userdata , h , dest , 0 ) {
allowed = false ;
}

 for r , c : a . remotes {

 if r . state != . Absent && ! m . config . ready_to_unload ( m . config . userdata , h , dest , c ) {
allowed = false ;
}


}

 if ! allowed {
return ;
}


}

 a . replacement = 0 ;
notify ( m , . Replace_Committed , h , other = dest ) ;
close ( m , h ) ;

 }

 advance_release_first :: ( m : * Manager , dest : Handle , b : * Scene ) {

 old := b . release_from ;
if old == 0 {
return ;
}

 a , exists := table_get ( * m . scenes , old ) ;
failed := b . phase == . Closing ;
if exists {

 failed = failed || local_state ( a ) == . Unload_Failed ;
for r , _ : a . remotes {
if r . state == . Unload_Failed {
failed = true ;
}

 }


}

 timed_out := m . now - b . replace_began >= m . config . replace_timeout_ms ;
if failed || timed_out {

 b . release_from = 0 ;
if timed_out {
notify ( m , . Timeout , old , other = dest ) ;
}

 notify ( m , . Replace_Failed , old , other = dest ) ;
close ( m , dest ) ;
return ;

 }

 if exists {
return ;
}
// 记录删除证明远端 ACK 与本机物理卸载都完成。

 if ! b . release_started {

 b . release_started = true ;
b . local . desired = b . load_here ;
b . phase = ( ifx b . load_here then . Opening else . Open ) ;
if b . phase == . Open {
place_scene ( m , b , dest ) ;
}


}

 ready , load_failed := replacement_ready ( m , b ) ;
if load_failed {

 b . release_from = 0 ;
notify ( m , . Replace_Failed , old , other = dest ) ;
close ( m , dest ) ;

 } else if ready {

 b . release_from = 0 ;
notify ( m , . Replace_Committed , old , other = dest ) ;

 }


}

 //@endregion


//@region 异步请求与线程安全完成队列

 queue_completion :: ( m : * Manager , ticket : Ticket , success : bool , op : Operation ) -> bool {

 if ticket . serial == 0 || ticket . handle == 0 || ticket . operation != op {
return false ;
}

 Thread . lock ( * m . mutex ) ;
defer Thread . unlock ( * m . mutex ) ;
if ! m . accept_completions {
return false ;
}

 array_add ( * m . completions , Completion .{
ticket , success
} ) ;
return true ;

 } ;

 complete_load :: ( m : * Manager , ticket : Ticket , success : bool ) -> bool {

 return queue_completion ( m , ticket , success , . Load ) ;

 }

 complete_unload :: ( m : * Manager , ticket : Ticket , success : bool ) -> bool {

 return queue_completion ( m , ticket , success , . Unload ) ;

 }

 consume_completions :: ( m : * Manager ) {

 Thread . lock ( * m . mutex ) ;
m . completions , m . draining = m . draining , m . completions ;
Thread . unlock ( * m . mutex ) ;
for done : m . draining {

 t := done . ticket ;
s , exists := table_get ( * m . scenes , t . handle ) ;
if ! exists || ! s . local . busy || s . local . ticket != t {
continue ;
}

 s . local . busy = false ;
if done . success {

 s . local . held = t . operation == . Load ;
notify ( m , ( ifx t . operation == . Load then . Loaded else . Unloaded ) , t . handle , revision = t . revision ) ;

 } else {

 s . local . failed = true ;
s . local . failure_operation = t . operation ;
notify ( m , ( ifx t . operation == . Load then . Load_Failed else . Unload_Failed ) , t . handle , revision = t . revision ) ;

 }

 // 新 revision 的反向请求仍要等待物理操作完成；旧成功不产生旧网络报告。

 if ( t . operation == . Load ) != s . local . desired {
s . local . failed = false ;
}


}

 array_reset_keeping_memory ( * m . draining ) ;

 }

 local_state :: ( s : * Scene ) -> State {

 if s . local . busy {
return ( ifx s . local . ticket . operation == . Load then . Loading else . Unloading ) ;
}

 if s . local . failed {
return ( ifx s . local . failure_operation == . Load then . Load_Failed else . Unload_Failed ) ;
}

 if s . load_rejected {
return . Load_Failed ;
}

 return ( ifx s . local . held then . Loaded else . Absent ) ;

 }

 drive_local :: ( m : * Manager , h : Handle , s : * Scene ) {

 if s . local . busy {
return ;
}

 if s . local . failed {

 if m . config . role == . Client && m . authority != 0 && ! s . report_ready {

 s . report_ready = true ;
s . report_kind = ( ifx s . local . desired || s . load_rejected then . Load_Failed else . Unload_Failed ) ;

 }

 return ;

 }

 if s . local . desired == s . local . held {

 if m . config . role == . Client && m . authority != 0 && ! s . report_ready {

 s . report_ready = true ;
s . report_kind = ( ifx s . load_rejected then . Load_Failed else ( ifx s . local . held then . Loaded else . Unloaded ) ) ;

 }

 return ;

 }

 if m . next_ticket == 0 {
return ;
}
// Ticket 耗尽：保持 gate 关闭，调用方须重建管理器。

 op : Operation = ( ifx s . local . desired then . Load else . Unload ) ;
t := Ticket .{
h , s . asset , m . next_ticket , s . revision , op ,
} ;

 m . next_ticket += 1 ;
s . local . ticket = t ;
s . local . busy = true ;
s . local . began = m . now ;
if op == . Unload {
notify ( m , . Before_Unload , h , revision = t . revision ) ;
}

 s . local . cancel_requested = false ;
if m . config . loader != null {

 if ! loader_submit ( m . config . loader , m , t ) {
queue_completion ( m , t , false , op ) ;
}


} else if m . config . request != null {

 m . config . request ( m . config . userdata , t ) ;

 } else {

 queue_completion ( m , t , false , op ) ; // 无 loader 不是成功 stub。


}


}

 // 断线/关闭后的 engine unload 失败不能自动遗忘资源；宿主修复原因后显式重试。

 retry_local_unload :: ( m : * Manager , h : Handle ) -> bool {

 s , exists := table_get ( * m . scenes , h ) ;
if ! exists || s . phase != . Closing || s . local . busy || ! s . local . failed || s . local . failure_operation != . Unload {
return false ;
}

 s . local . failed = false ;
return true ;

 }

 //@endregion


//@region 接收验证、网络推进与复制 gate

 send_packet :: ( m : * Manager , to : transport . Connection_Id , p : Packet ) -> bool {

 if m . config . send == null {
return false ;
}

 data , ok := encode_packet ( p ) ;
return ok && m . config . send ( m . config . userdata , to , view ( data , 0 ) ) ;

 }

 // from 必须来自 Session 的认证元数据，不能从 payload 推导或信任客户端声明的角色。

 handle :: ( m : * Manager , from : transport . Connection_Id , payload : [ ] u8 ) -> bool {

 if ! m . initialized {
return false ;
}

 p , valid := decode_packet ( payload ) ;
if ! valid {
return false ;
}

 if m . config . role == . Server {

 epoch , joined := table_get ( * m . peers , from ) ;
if ! joined || epoch != p . epoch || p . kind == . Load || p . kind == . Unload {
return false ;
}

 s , exists := table_get ( * m . scenes , p . handle ) ;
if ! exists || s . asset != p . asset {
return false ;
}

 r , requested := table_get ( * s . remotes , from ) ;
if ! requested || ! r . dispatched || r . revision != p . revision {
return false ;
}

 // 移出 scope 的卸载报告仍必须接受；只接受实际派发的最新请求。

 if ( p . kind == . Loaded || p . kind == . Load_Failed ) && ! peer_scope ( s , from ) {
return false ;
}

 next : State ;
if p . kind == {

 case . Loaded ; next = . Loaded ;
case . Load_Failed ; next = . Load_Failed ;
case . Unloaded ; next = . Absent ;
case . Unload_Failed ; next = . Unload_Failed ;
case . Load , . Unload ; return false ;

 }

 if r . state == next {
return true ;
}
// 同一终态报告幂等，不重发事件。

 if ( r . state != . Loading || ( p . kind != . Loaded && p . kind != . Load_Failed ) ) &&
( r . state != . Unloading || ( p . kind != . Unloaded && p . kind != . Unload_Failed ) ) {
return false ;
}

 was_held := r . held ;
if p . kind == . Loaded {
r . held = true ;
}

 if p . kind == . Unloaded {
r . held = false ;
}

 if p . kind == . Load_Failed {
r . failure_latched = true ;
}

 r . state = next ;
r . send_pending = false ;
H . table_set ( * s . remotes , from , r ) ;
kind : Event_Kind ;
if p . kind == {

 case . Loaded ; kind = . Loaded ;
case . Load_Failed ; kind = . Load_Failed ;
case . Unloaded ; kind = . Unloaded ;
case . Unload_Failed ; kind = . Unload_Failed ;
case . Load , . Unload ; return false ;

 }

 notify ( m , kind , p . handle , from , p . revision ) ;
if was_held != r . held {
observe ( m , .{ . State_Changed , from , p . handle , s . asset , r . held , p . revision
} ) ;
}

 return true ;

 }

 if m . authority == 0 || from != m . authority || p . epoch != m . epoch || m . stopping || ( p . kind != . Load && p . kind != . Unload ) {
return false ;
}

 s , exists := table_get ( * m . scenes , p . handle ) ;
if exists && s . asset != p . asset {
return false ;
}

 if p . revision <= m . last_revision {

 if exists && s . revision == p . revision && ( s . local . desired || s . load_rejected ) == ( p . kind == . Load ) {

 if s . report_ready {
s . report_sent = false ;
}

 return true ;

 }

 return false ;

 }

 if ! exists {

 if ( m . scenes ) . count >= m . config . max_scenes {

 // 容量拒绝不启动 loader，不分配记录；可靠接管报告后才提交 watermark。

 kind : Packet_Kind = ( ifx p . kind == . Load then . Load_Failed else . Unloaded ) ;
if ! send_packet ( m , m . authority , .{
kind , p . handle , p . asset , m . epoch , p . revision
} ) {
return false ;
}

 m . last_revision = p . revision ;
if p . kind == . Load {
notify ( m , . Load_Failed , p . handle , revision = p . revision ) ;
}

 return true ;

 } ;

 s = new_one ( Scene , m . allocator ) ;
s . asset = p . asset ;
s . load_here = true ;
H . table_set ( * m . scenes , p . handle , s ) ;

 }

 m . last_revision = p . revision ;
s . revision = p . revision ;
s . phase = ( ifx p . kind == . Load then . Open else . Closing ) ;
s . load_rejected = p . kind == . Load && m . config . validate_load != null && ! m . config . validate_load ( m . config . userdata , p . handle , p . asset , from ) ;
s . local . desired = p . kind == . Load && ! s . load_rejected ;
if s . load_rejected {
notify ( m , . Load_Failed , p . handle , revision = p . revision ) ;
}

 s . local . failed = false ;
s . report_ready = false ;
s . report_sent = false ;
notify ( m , ( ifx p . kind == . Load then . Load_Requested else . Unload_Requested ) , p . handle , revision = p . revision ) ;
return true ;

 }

 update_remote :: ( m : * Manager , h : Handle , s : * Scene , c : transport . Connection_Id , previous : Remote ) {

 r := previous ;
if r . state == . Absent && r . load_after_unload && ! r . failure_latched && s . phase == . Open && peer_scope ( s , c ) {

 start_remote ( m , s , h , c , . Load ) ;
return ;

 }

 if r . state != . Loading && r . state != . Unloading {
return ;
}

 if m . now - r . began >= m . config . timeout_ms {

 notify ( m , . Timeout , h , c , r . revision ) ;
if r . state == . Loading {

 // load 超时不是取消 engine 操作；新 revision 卸载会在客户端串行回收迟到成功。

 r . failure_latched = true ;
H . table_set ( * s . remotes , c , r ) ;
observe ( m , .{ . Load_Failed , c , h , s . asset , false , r . revision
} ) ;
start_remote ( m , s , h , c , . Unload ) ;

 } else {

 r . state = . Unload_Failed ;
r . send_pending = false ;
H . table_set ( * s . remotes , c , r ) ; // 不假装已释放；close/request_unload 可重试，断线可遗忘。


}


}


}

 // 所有首次发送按 revision 排序；失败时停止该连接，不能让新命令越过未送出的旧命令。

 // 可靠有序发送使客户端只需全局 watermark，无需永久保留每个已关闭 scene 的墓碑。

 dispatch_requests :: ( m : * Manager ) {

 for epoch , c : m . peers {

 after : u64 = 0 ;
while true {

 chosen : * Scene ;
handle : Handle ;
best : Remote ;
for s , h : m . scenes {

 r , exists := table_get ( * s . remotes , c ) ;
if ! exists || r . revision <= after || ( r . state != . Loading && r . state != . Unloading ) {
continue ;
}

 if ! r . send_pending && m . now - r . last_sent < m . config . resend_ms {
continue ;
}

 if chosen == null || r . revision < best . revision {
chosen , handle , best = s , h , r ;
}


}

 if chosen == null {
break ;
}

 p := Packet .{
( ifx best . state == . Loading then . Load else . Unload ) , handle , chosen . asset , epoch , best . revision ,
} ;

 best . send_pending = ! send_packet ( m , c , p ) ;
best . dispatched = best . dispatched || ! best . send_pending ;
best . last_sent = m . now ;
H . table_set ( * chosen . remotes , c , best ) ;
if best . send_pending {
break ;
}

 after = best . revision ;

 }


}


}

 // 单调毫秒时钟，由宿主提供。此函数是唯一消费 loader 结果及推进状态机的位置。

 update :: ( m : * Manager , now_ms : u64 ) {

 if ! m . initialized || now_ms < m . now {
return ;
}

 if ! m . clock_started {

 // 允许直接使用系统 uptime；init/open 到第一次 update 不算网络请求超时。

 m . clock_started = true ;
for s , _ : m . scenes {

 if s . replacement != 0 || s . release_from != 0 {
s . replace_began = now_ms ;
}

 for previous , c : s . remotes {

 r := previous ;
r . began = now_ms ;
r . last_sent = now_ms ;
H . table_set ( * s . remotes , c , r ) ;

 }


}


}

 m . now = now_ms ;
if m . config . loader != null {
loader_update ( m . config . loader ) ;
}

 consume_progress ( m ) ;
consume_completions ( m ) ;
for s , h : m . scenes {

 if m . config . role == . Server {

 if s . phase == . Opening {

 if s . local . failed {

 close ( m , h ) ;

 } else if s . local . held && ! s . local . busy {

 s . phase = . Open ;
place_scene ( m , s , h ) ;

 } else if s . local . busy && m . now - s . local . began >= m . config . timeout_ms {

 notify ( m , . Timeout , h ) ;
close ( m , h ) ; // 不丢弃 in-flight Ticket；迟到成功仍会先卸载再回收。


}


}

 if s . phase == . Closing && ! s . release_allowed {
close ( m , h ) ;
}

 if s . phase != . Closing || s . release_allowed {
for r , c : s . remotes {
update_remote ( m , h , s , c , r ) ;
}

 }

 if s . phase == . Closing && s . release_allowed {

 all_gone := true ;
for r , _ : s . remotes {
if r . state != . Absent {
all_gone = false ;
}

 }

 if all_gone {
s . local . desired = false ;
}


}


}

 if s . phase == . Closing && s . local . busy && s . local . ticket . operation == . Load && ! s . local . cancel_requested && m . config . loader != null {

 s . local . cancel_requested = loader_cancel ( m . config . loader , m , s . local . ticket ) ;

 }

 drive_local ( m , h , s ) ;
if m . config . role == . Client && m . authority != 0 && s . report_ready && ! s . report_sent {

 s . report_sent = send_packet ( m , m . authority , .{
s . report_kind , h , s . asset , m . epoch , s . revision
} ) ;

 } ;

 if s . phase == . Closing && ! s . local . busy && ! s . local . held && ! s . local . desired {

 can_remove := m . config . role == . Client && ( m . authority == 0 || s . report_sent ) ;
if m . config . role == . Server {

 can_remove = s . release_allowed ;
for r , _ : s . remotes {
if r . state != . Absent {
can_remove = false ;
}

 }


}

 if can_remove {
array_add ( * m . garbage , h ) ;
}


}


}

 if m . config . role == . Server {

 for s , h : m . scenes {
advance_replace ( m , h , s ) ;
}

 for s , h : m . scenes {
advance_release_first ( m , h , s ) ;
}

 dispatch_requests ( m ) ;

 }

 for h : m . garbage {

 { s , exists := table_get ( * m . scenes , h ) ; if
exists {

 notify ( m , . Closed , h ) ;
free_scene ( m , h , s ) ;

 } }


}

 array_reset_keeping_memory ( * m . garbage ) ;
if m . config . loader != null {
loader_update ( m . config . loader ) ;
}


}

 get_info :: ( m : * Manager , h : Handle ) -> ( info : Info , ok : bool ) {

 s , exists := table_get ( * m . scenes , h ) ;
if ! exists {
return .{

 } , false ;
} ;

 return .{
s . asset , s . phase , local_state ( s ) , s . load_here , s . replacement ,
} , true ;

 } ;

 connection_state :: ( m : * Manager , h : Handle , c : transport . Connection_Id ) -> State {

 s , exists := table_get ( * m . scenes , h ) ;
if ! exists || m . config . role != . Server {
return . Absent ;
}

 return table_get ( * s . remotes , c ) . state ;

 }

 // 对象复制必须使用此 gate，不可仅看 scope 或物理 held；0 handle 的无 scene 对象由宿主另判。

 is_loaded :: ( m : * Manager , h : Handle , c : transport . Connection_Id ) -> bool {

 s , exists := table_get ( * m . scenes , h ) ;
if ! exists || s . phase != . Open || m . config . role != . Server || table_get ( * m . peers , c ) == 0 {
return false ;
}

 if peer_scope ( s , c ) && ( ! s . load_here || ( s . local . held && ! s . local . busy && ! s . local . failed ) ) && table_get ( * s . remotes , c ) . state == . Loaded {
return true ;
}

 if m . config . automatic_request_on_blocked_spawn {
request_placement ( m , h , c ) ;
}

 return false ;

 }

 is_local_loaded :: ( m : * Manager , h : Handle ) -> bool {

 s , exists := table_get ( * m . scenes , h ) ;
return exists && s . phase == . Open && s . local . desired && s . local . held && ! s . local . busy && ! s . local . failed ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted.  

 // Cast semantics adapted. 
