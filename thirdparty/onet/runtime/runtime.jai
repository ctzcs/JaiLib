#scope_file
core :: #import "thirdparty/onet/core" ;
objects :: #import "thirdparty/onet/objects" ;
rpc :: #import "thirdparty/onet/rpc" ;
scenes :: #import "thirdparty/onet/scenes" ;
session :: #import "thirdparty/onet/session" ;
transport :: #import "thirdparty/onet/transport" ;
wire :: #import "thirdparty/onet/wire" ;
sim :: #import "thirdparty/onet/simulation" ;
#scope_export
// 统一网络循环。Runtime/World/Session/Registry必须保持地址稳定，由单一loop独占。




//@region 运行时与所有权

 EXTENSION_ID :: ( cast ( session . Extension_Id ) ( 0x4e55 ) ) ;
// 7..11 belonged to the removed independent prediction protocol; never reuse.

 Kind :: enum u8 {
State = 1 ; Ack ; Full ; Member_Write ; Rpc ; Scene ; World_Input = 12 ; World_State ; World_Result ; World_Correction ; World_Reset_Request ; Clock_Ping ; Clock_Pong ;
}

 Peer_State :: struct {

 generation : u64 ;

 state : objects . Peer ;

 served_sequence , member_sequence : u64 ;

 world_correction_serial : u64 ;

 world_correction : [ ] u8 ;

 world_results : [ .. ] [ ] u8 ;

 world_last_request_ms : s64 ;

 world_client_binding : u64 ;


}

 // 可选发送器用于诊断/确定性网络模拟；true必须表示已复制并接管payload。

 // side是发送端；可靠帧不得在返回true后悄悄丢弃。

 Send_Proc :: ( userdata : * void , side : transport . Invoker , to : transport . Connection_Id , channel : transport . Channel , frame : [ ] u8 ) -> bool ;
Scene_Manager :: scenes . Manager ;
Scene_Config :: scenes . Config ;
Scene_Handle :: scenes . Handle ;
Config :: struct {

 server_registry , client_registry : * objects . Registry ;
// 借用，不由runtime销毁。

 server_scenes , client_scenes : scenes . Config ;

 send : Send_Proc ;

 userdata : * void ;


}

 World :: struct {

 runtime : * Runtime ;

 registry : * objects . Registry ;

 authority : bool ;

 peers : H . Table ( transport . Connection_Id , * Peer_State ) ;

 client_peer : objects . Peer ;

 generation : u64 ;

 member_sequence : u64 ;

 rpc : rpc . Manager ;

 scenes : Scene_Manager ;

 scene_callbacks : Scene_Config ;

 visibility : objects . Visibility ;

 visibility_userdata : * void ;

 validate_member : objects . Member_Write_Validator ;

 migrations : H . Table ( Scene_Handle , * Migration ) ;

 simulation : * Simulation_World ;

 simulation_callbacks : Simulation_Callbacks ;

 simulation_objects : bool ;

 simulation_epoch , simulation_binding , next_simulation_binding : u64 ;

 simulation_seeded : bool ;

 world_factories : H . Table ( objects . Component_Type_Id , World_Factory ) ;

 automatic_systems : H . Table ( sim . System_Id , objects . Network_Id ) ;

 physics_system : * Body_System ;

 body_factories : H . Table ( objects . Component_Type_Id , Body_Factory_Binding ) ;

 automatic_bodies : H . Table ( objects . Network_Id , bool ) ;

 world_clock , state_clock : sim . Remote_Clock ;

 clock_pending : H . Table ( u64 , s64 ) ;

 clock_nonce : u64 ;

 world_last_request_ms , clock_last_request_ms , state_full_last_ms : s64 ;

 state_clock_network_sampled : bool ;

 world_waiting_packet : [ ] u8 ;

 world_waiting_epoch : u64 ;

 state_pending : [ .. ] Queued_State ;

 // Registry.reclaim_despawned：despawn后首个快照的tick；全部peer确认到该tick后回收。

 reclaims : [ .. ] Reclaim ;

 counters : Net_Stats ;
// 库内累计计数；时钟字段由stats()在查询时填入。

 initialized : bool ;


}

 Reclaim :: struct {
id : objects . Network_Id ;
tick : u64 ;
}

 Runtime :: struct {

 session : * session . Session ;

 server , client : World ;
// host使用不同Registry，不共享可变世界。

 config : Config ;

 initialized , stopping : bool ;


}


init :: ( r : * Runtime , s : * session . Session , config : Config ) -> bool {

 if r . initialized || s == null || s . runtime_userdata != null || s . runtime_tick != null || s . runtime_before_tick != null || table_get ( * s . extensions , EXTENSION_ID ) != null ||
( config . server_registry == null && config . client_registry == null ) ||
( config . server_registry != null && ( ! config . server_registry . authoritative || config . server_registry == config . client_registry ) ) ||
( config . client_registry != null && config . client_registry . authoritative ) {
return false ;
}

 r .* = Runtime .{
session = s , config = config , initialized = true ,
} ;

 if config . server_registry != null {
world_init ( * r . server , r , config . server_registry , true , config . server_scenes ) ;
}

 if config . client_registry != null {
world_init ( * r . client , r , config . client_registry , false , config . client_scenes ) ;
}

 s . runtime_userdata = r ;
s . runtime_tick = tick ;
s . runtime_before_tick = before_tick ;
session . register_extension ( s , EXTENSION_ID , extension ) ;
return true ;

 }

 world_init :: ( w : * World , r : * Runtime , reg : * objects . Registry , authority : bool , original_scene_config : scenes . Config ) {

 scene_config := original_scene_config ;
w . runtime , w . registry , w . authority , w . initialized = r , reg , authority , true ;
w . peers = new_table ( transport . Connection_Id , * Peer_State ) ;
w . migrations = new_table ( Scene_Handle , * Migration ) ;
w . world_factories = new_table ( objects . Component_Type_Id , World_Factory ) ;
w . automatic_systems = new_table ( sim . System_Id , objects . Network_Id ) ;
w . body_factories = new_table ( objects . Component_Type_Id , Body_Factory_Binding ) ;
w . automatic_bodies = new_table ( objects . Network_Id , bool ) ;
w . clock_pending = new_table ( u64 , s64 ) ;
w . world_last_request_ms , w . clock_last_request_ms , w . state_full_last_ms = - 1000 , - 1000 , - 1000 ;
sim . clock_init ( * w . world_clock , .{
fixed_ms = ( cast ( float64 ) ( r . session . tick_interval_ms ) ) , interpolation_ticks = 2 , input_lead_ticks = 2 , max_lead_ticks = 32
} ) ;
sim . clock_init ( * w . state_clock , .{
fixed_ms = ( cast ( float64 ) ( r . session . tick_interval_ms ) ) , interpolation_ticks = 2 , input_lead_ticks = 2 , max_lead_ticks = 32
} ) ;
w . visibility , w . visibility_userdata = reg . is_observer , reg . visibility_userdata ;
if authority {
reg . is_observer , reg . visibility_userdata = observer_visibility , w ;
}

 rpc . init ( * w . rpc , reg , authority ) ;
w . rpc . transport_userdata , w . rpc . send , w . rpc . is_observer , w . rpc . connections = w , rpc_send , rpc_observed , rpc_connections ;
w . scene_callbacks = scene_config ;
scene_config . role = ( ifx authority then . Server else . Client ) ;
scene_config . userdata , scene_config . send = w , scene_send ;
if scene_config . request != null {
scene_config . request = scene_request ;
}

 scene_config . event = scene_event ;
if scene_config . carry != null {
scene_config . carry = scene_carry ;
}

 if scene_config . validate_load != null {
scene_config . validate_load = scene_validate ;
}

 if authority || scene_config . ready_to_unload != null {
scene_config . ready_to_unload = scene_ready ;
}

 scenes . init ( * w . scenes , scene_config ) ;

 } ;

 shutdown :: ( r : * Runtime ) {

 if ! r . initialized || r . stopping {
return ;
}

 r . stopping = true ;
if r . server . initialized {
scenes . shutdown ( * r . server . scenes ) ;
}

 if r . client . initialized {
scenes . shutdown ( * r . client . scenes ) ;
}


}

 // 必须先shutdown并继续update直到loader/远端卸载完成；失败时Runtime完全保留。

 // Session/Registry/channel的生命周期归调用者，销毁顺序：runtime -> channels/registry -> session。

 destroy :: ( r : * Runtime ) -> bool {

 if ! r . initialized {
return true ;
}

 if ! r . stopping {
return false ;
}

 for w : ( ( * World ) .[ * r . server , * r . client ] ) {

 if w . initialized && ( w . scenes . scenes ) . count != 0 {
return false ;
}


}

 for w : ( ( * World ) .[ * r . server , * r . client ] ) {

 if ! w . initialized {
continue ;
}

 if ! scenes . destroy ( * w . scenes ) {
return false ;
}

 for p , _ : w . peers {
forget_world_peer ( w , p ) ;
objects . peer_destroy ( * p . state ) ;
free ( p ) ;
}

 release ( w . peers ) ;
objects . peer_destroy ( * w . client_peer ) ;
for _ , old : w . migrations {
forget_migration ( w , old ) ;
}

 release ( w . migrations ) ;
unbind_simulation ( w ) ;
unbind_physics ( w ) ;
release ( w . body_factories ) ;
release ( w . automatic_bodies ) ;
release ( w . world_factories ) ;
release ( w . automatic_systems ) ;
release ( w . clock_pending ) ;
clear_state_queue ( w ) ;
release ( w . reclaims ) ;
rpc . destroy ( * w . rpc ) ;
if w . authority {
w . registry . is_observer , w . registry . visibility_userdata = w . visibility , w . visibility_userdata ;
}


}

 H . table_remove ( * r . session . extensions , EXTENSION_ID ) ;
r . session . runtime_tick , r . session . runtime_before_tick , r . session . runtime_userdata = null , null , null ;
r .* = .{

 } ;

 return true ;

 }

 // 一次完成关闭：session.shutdown → shutdown → 继续update直到destroy成功。

 // 超时返回false，Runtime保留，可继续update后再destroy。借用的Simulation_World、

 // Registry、Session和backend仍由调用方在之后按顺序销毁。

 close :: ( r : * Runtime , max_wait_ms := 1000 ) -> bool {

 if ! r . initialized {
return true ;
}

 session . shutdown ( r . session ) ;
shutdown ( r ) ;
start := monotonic_seconds ( ) ;
last := start ;
while true {

 now := monotonic_seconds ( ) ;
update ( r , max ( 1 , ( cast ( int ) ( ( now - last ) * 1000.0 ) ) ) ) ;
last = now ;
if destroy ( r ) {
return true ;
}

 if ( now - start ) * 1000.0 >= cast ( float64 ) max_wait_ms {
return false ;
}

 sleep_milliseconds ( 1 ) ;

 }


return false ;
}

 //@endregion


//@region 连接代次、可见性与场景

 clear_client_world :: ( w : * World ) {

 for obj , id : w . registry . objects {

 if obj != null {
objects . free_object ( obj ) ;
}

 H . table_remove ( * w . registry . objects , id ) ;

 }

 w . registry . active_count = 0 ;
array_reset_keeping_memory ( * w . registry . pending_despawns ) ;

 }

 synchronize :: ( r : * Runtime ) {

 s := r . session ;
w := * r . server ;
if w . initialized {

 for p , id : w . peers {

 info := session . client_info ( s , id ) ;
if info == null || info . state != . Approved || info . generation != p . generation {

 scenes . peer_leave ( * w . scenes , id ) ;
rpc . forget_connection ( * w . rpc , id ) ;
forget_world_peer ( w , p ) ;
objects . peer_destroy ( * p . state ) ;
free ( p ) ;
H . table_remove ( * w . peers , id ) ;

 }


}

 for id : s . connections {

 if id == 0 || ! session . is_authenticated ( s , id ) || table_get ( * w . peers , id ) != null {
continue ;
}

 p := new_one ( Peer_State ) ;
p . generation = session . client_info ( s , id ) . generation ;
objects . peer_init ( * p . state , id , max ( 32 , 2000 / s . tick_interval_ms + 2 ) ) ;
p . world_last_request_ms = - 1000 ;
H . table_set ( * w . peers , id , p ) ;
scenes . peer_join ( * w . scenes , id , p . generation ) ;

 }


}

 w = * r . client ;
if w . initialized {

 generation := ( ifx s . client_authenticated then s . client_generation else 0 ) ;
if generation != w . generation {

 scenes . disconnect ( * w . scenes ) ;
rpc . reset ( * w . rpc ) ;
objects . peer_destroy ( * w . client_peer ) ;
reset_bound_simulation ( w ) ;
clear_state_queue ( w ) ;
sim . clock_reset ( * w . state_clock ) ;
w . state_clock_network_sampled = false ;
clear_client_world ( w ) ;
w . generation = generation ;
w . member_sequence = 0 ;
objects . peer_init ( * w . client_peer , s . client_server_id ) ;

 }

 if generation != 0 {

 w . rpc . server_connection = session . local_connection ( s ) ;
if w . scenes . authority == 0 {
scenes . bind_authority ( * w . scenes , session . local_connection ( s ) , generation ) ;
}


}


}


}

 visible :: ( obj : * objects . Network_Object , id : transport . Connection_Id , userdata : * void ) -> bool {

 w := ( cast ( * World ) userdata ) ;
return session . is_authenticated ( w . runtime . session , id ) &&
( w . visibility == null || w . visibility ( obj , id , w . visibility_userdata ) ) && scenes . spawn_allowed ( * w . scenes , obj , id ) ;

 }

 is_observer :: ( w : * World , obj : * objects . Network_Object , id : transport . Connection_Id ) -> bool {

 p := table_get ( * w . peers , id ) ;
if p == null || ! visible ( obj , id , w ) {
return false ;
}

 snapshot := objects . snapshot_find ( view ( p . state . sent , 0 ) , p . served_sequence ) ;
return objects . image_find ( snapshot , obj . id ) . data != null ;

 }

 observer_visibility :: ( obj : * objects . Network_Object , id : transport . Connection_Id , userdata : * void ) -> bool {

 return is_observer ( ( cast ( * World ) userdata ) , obj , id ) ;

 }

 scene_send :: ( userdata : * void , to : transport . Connection_Id , payload : [ ] u8 ) -> bool {
return send ( ( cast ( * World ) userdata ) , to , . Scene , payload , . Reliable ) ;
}

 scene_request :: ( userdata : * void , ticket : scenes . Ticket ) {

 w := ( cast ( * World ) userdata ) ;
w . scene_callbacks . request ( w . scene_callbacks . userdata , ticket ) ;

 }

 scene_event :: ( userdata : * void , event : scenes . Event ) {

 w := ( cast ( * World ) userdata ) ;
if event . kind == {

 case . Replace_Committed , . Replace_Failed , . Closed ; forget_migration ( w , event . handle ) ;

 }

 { cb := w . scene_callbacks . event ; if
cb != null {
cb ( w . scene_callbacks . userdata , event ) ;
} }


}

 scene_carry :: ( userdata : * void , old_scene , new_scene : scenes . Handle ) -> bool {

 w := ( cast ( * World ) userdata ) ;
ids := migration_candidates ( w , old_scene ) ;
if ! w . scene_callbacks . carry ( w . scene_callbacks . userdata , old_scene , new_scene ) {
release ( ids ) ;
return false ;
}

 remember_migration ( w , old_scene , new_scene , ids ) ;
return true ;

 }

 scene_validate :: ( userdata : * void , h : scenes . Handle , asset : scenes . Asset_Id , authority : transport . Connection_Id ) -> bool {

 w := ( cast ( * World ) userdata ) ;
return w . scene_callbacks . validate_load ( w . scene_callbacks . userdata , h , asset , authority ) ;

 }

 // 应用负责决定哪些对象carry；库负责将新scene字段的已确认快照作为卸载屏障。

 scene_ready :: ( userdata : * void , old_scene , new_scene : scenes . Handle , id : transport . Connection_Id ) -> bool {

 w := ( cast ( * World ) userdata ) ;
{ cb := w . scene_callbacks . ready_to_unload ; if
cb != null && ! cb ( w . scene_callbacks . userdata , old_scene , new_scene , id ) {
return false ;
} }

 if ! w . authority || id == 0 {
return true ;
}

 return migration_ready ( w , old_scene , new_scene , id ) ;

 }

 carry_scene_objects :: ( w : * World , old_scene , new_scene : scenes . Handle ) -> bool {

 if ! w . authority || old_scene == 0 || new_scene == 0 || old_scene == new_scene {
return false ;
}

 _ , old_ok := scenes . get_info ( * w . scenes , old_scene ) ;
_ , new_ok := scenes . get_info ( * w . scenes , new_scene ) ;
if ! old_ok || ! new_ok {
return false ;
}

 for obj , _ : w . registry . objects {

 if obj != null && obj . active && obj . scene == ( cast , trunc ( u32 ) ( old_scene ) ) {
obj . scene = ( cast , trunc ( u32 ) ( new_scene ) ) ;
}


}

 return true ;

 }

 rpc_send :: ( userdata : * void , to : transport . Connection_Id , channel : transport . Channel , payload : [ ] u8 ) -> bool {
return send ( ( cast ( * World ) userdata ) , to , . Rpc , payload , channel ) ;
}

 rpc_observed :: ( userdata : * void , obj : * objects . Network_Object , id : transport . Connection_Id ) -> bool {
return is_observer ( ( cast ( * World ) userdata ) , obj , id ) ;
}

 rpc_connections :: ( userdata : * void ) -> [ ] transport . Connection_Id {
return view ( ( cast ( * World ) userdata ) . runtime . session . connections , 0 ) ;
}

 //@endregion


//@region 封包与可信分发

 send :: ( w : * World , to : transport . Connection_Id , kind : Kind , payload : [ ] u8 , channel : transport . Channel = . Reliable ) -> bool {

 if ! w . initialized {
return false ;
}

 r := w . runtime ;
s := r . session ;
epoch := w . generation ;
if w . authority {

 p := table_get ( * w . peers , to ) ;
if p == null || ! session . is_authenticated ( s , to ) {
return false ;
}

 epoch = p . generation ;

 } else if ! s . client_authenticated || to != session . local_connection ( s ) {
return false ;
}

 if epoch == 0 || ( payload ) . count + 12 > s . limits . max_packet_bytes {
return false ;
}

 writer : core . Writer ;
core . writer_init ( * writer ) ;
defer core . writer_destroy ( * writer ) ;
core . write_uint8 ( * writer , ( cast , trunc ( u8 ) ( kind ) ) , . Uncompressed ) ;
core . write_uint64 ( * writer , epoch , . Uncompressed ) ;
core . write_u8_array_as_bytes_unsafe ( * writer , payload , . Loose ) ;
frame := core . writer_to_array ( * writer ) ;
defer release ( frame ) ;
if r . config . send != null {
return r . config . send ( r . config . userdata , ( ifx w . authority then . Server else . Client ) , to , channel , frame ) ;
}

 ok := session . send_extension ( s , to , EXTENSION_ID , frame , channel ) ;
if ! ok && kind == . State && channel == . Unreliable {
return session . send_extension ( s , to , EXTENSION_ID , frame , . Reliable ) ;
}

 return ok ;

 }

 extension :: ( s : * session . Session , from : transport . Connection_Id , side : transport . Invoker , channel : transport . Channel , payload : [ ] u8 ) {

 r := ( cast ( * Runtime ) s . runtime_userdata ) ;
if ! receive ( r , from , side , channel , payload ) {
session . report_violation ( s , from , . Unauthorized ) ;
}


}

 // 只接受Session已认证的sender，side是接收端；公开用于拥有缓冲的诊断队列回放。

 receive :: ( r : * Runtime , from : transport . Connection_Id , side : transport . Invoker , channel : transport . Channel , frame : [ ] u8 ) -> bool {

 if r == null || ! r . initialized || ( frame ) . count < 9 || ( frame ) . count > wire . MAX_PAYLOAD {
return false ;
}

 synchronize ( r ) ;
reader : core . Reader ;
core . reader_init ( * reader , frame ) ;
kind := ( cast ( Kind ) ( core . read_uint8 ( * reader , . Uncompressed ) ) ) ;
epoch := core . read_uint64 ( * reader , . Uncompressed ) ;
payload := view ( frame , 9 ) ;
w := ( ifx side == . Server then * r . server else * r . client ) ;
if ! w . initialized || epoch == 0 {
return false ;
}

 if side == . Server {

 p := table_get ( * w . peers , from ) ;
if p == null || ! session . is_authenticated ( r . session , from ) || p . generation != epoch {
return false ;
}


} else if ! r . session . client_authenticated || from != session . local_connection ( r . session ) || epoch != w . generation {
return false ;
}

 if kind != . State && kind != . Rpc && channel != . Reliable {
return false ;
}

 if kind == {

 case . State ;
if w . authority {
return false ;
}

 return enqueue_state ( w , from , payload ) ;
case . Ack ;
if ! w . authority {
return false ;
}

 core . reader_init ( * reader , payload ) ;
seq := core . read_uint64 ( * reader , . Uncompressed ) ;
p := table_get ( * w . peers , from ) ;
return wire . finished ( * reader ) && seq <= p . served_sequence && objects . peer_ack ( * p . state , seq ) ;
case . Full ;
if ! w . authority || ( payload ) . count != 0 {
return false ;
}

 objects . peer_request_full ( * table_get ( * w . peers , from ) . state ) ;
return true ;
case . Member_Write ;
return w . authority && receive_member ( w , from , payload ) ;
case . Rpc ;
return rpc . receive ( * w . rpc , from , channel , payload ) ;
case . Scene ;
return scenes . handle ( * w . scenes , from , payload ) ;
case . World_Input , . World_State , . World_Result , . World_Correction , . World_Reset_Request ;
return receive_world ( w , from , kind , payload ) ;
case . Clock_Ping , . Clock_Pong ;
return receive_clock ( w , from , kind , payload ) ;

 }

 return false ;

 }

 send_number :: ( w : * World , to : transport . Connection_Id , kind : Kind , value : u64 ) -> bool {

 writer : core . Writer ;
core . writer_init ( * writer ) ;
defer core . writer_destroy ( * writer ) ;
core . write_uint64 ( * writer , value , . Uncompressed ) ;
data := core . writer_to_array ( * writer ) ;
defer release ( data ) ;
return send ( w , to , kind , data ) ;

 }

 //@endregion


//@region 成员写入与逐tick复制

 write_member :: ( w : * World , id : objects . Network_Id , component , member : int ) -> bool {

 if w . authority || w . generation == 0 || w . runtime . stopping {
return false ;
}

 obj , ok := objects . get ( w . registry , id ) ;
if ! ok || obj . owner != w . runtime . session . client_server_id || component < 0 || component >= ( obj . components ) . count || member < 0 || member >= ( obj . components [ component ] . members ) . count {
return false ;
}

 value , valid := objects . member_bytes ( * obj . components [ component ] . members [ member ] ) ;
defer release ( value ) ;
if ! valid || w . member_sequence == ~ ( cast , trunc ( u64 ) ( 0 ) ) {
return false ;
}

 writer : core . Writer ;
core . writer_init ( * writer ) ;
defer core . writer_destroy ( * writer ) ;
core . write_uint64 ( * writer , w . member_sequence + 1 , . Uncompressed ) ;
core . write_uint32 ( * writer , ( cast , trunc ( u32 ) ( id ) ) , . Uncompressed ) ;
core . write_uint16 ( * writer , ( cast , trunc ( u16 ) ( component ) ) , . Uncompressed ) ;
core . write_uint16 ( * writer , ( cast , trunc ( u16 ) ( member ) ) , . Uncompressed ) ;
wire . write_bytes ( * writer , value ) ;
data := core . writer_to_array ( * writer ) ;
defer release ( data ) ;
ok = send ( w , session . local_connection ( w . runtime . session ) , . Member_Write , data ) ;
if ok {
w . member_sequence += 1 ;
}

 return ok ;

 }

 receive_member :: ( w : * World , from : transport . Connection_Id , payload : [ ] u8 ) -> bool {

 reader : core . Reader ;
core . reader_init ( * reader , payload ) ;
seq := core . read_uint64 ( * reader , . Uncompressed ) ;
id := ( cast ( objects . Network_Id ) ( core . read_uint32 ( * reader , . Uncompressed ) ) ) ;
component := ( cast ( int ) ( core . read_uint16 ( * reader , . Uncompressed ) ) ) ;
member := ( cast ( int ) ( core . read_uint16 ( * reader , . Uncompressed ) ) ) ;
value , ok := wire . read_bytes ( * reader ) ;
defer release ( value ) ;
p := table_get ( * w . peers , from ) ;
if ! ok || ! wire . finished ( * reader ) || seq == 0 {
return false ;
}

 if seq <= p . member_sequence {
return true ;
}

 if ! objects . apply_member_write ( w . registry , id , from , component , member , value , w . validate_member ) {
return false ;
}

 p . member_sequence = seq ;
return true ;

 }

 replicate :: ( w : * World ) {

 if ! w . initialized || ! w . authority || w . runtime . stopping {
return ;
}

 objects . begin_tick ( w . registry , w . runtime . session . tick ) ;
for p , id : w . peers {

 writer : core . Writer ;
core . writer_init ( * writer ) ;
if objects . peer_build ( w . registry , * p . state , * writer , w . runtime . session . tick , visible , w ) {

 data := core . writer_to_array ( * writer ) ;
if send ( w , id , . State , data , . Unreliable ) {
p . served_sequence = p . state . next_sequence - 1 ;
}

 else {
objects . peer_request_full ( * p . state ) ;
}

 release ( data ) ;

 }

 core . writer_destroy ( * writer ) ;

 }

 array_reset_keeping_memory ( * w . registry . pending_despawns ) ;
reclaim_despawned ( w ) ;

 }

 // 本tick之后的快照都不含已despawn对象；peer确认到该tick即已在客户端删除。

 reclaim_despawned :: ( w : * World ) {

 tick := w . runtime . session . tick ;
for id : w . registry . despawned {
array_add ( * w . reclaims , Reclaim .{
id , tick
} ) ;
} ;

 array_reset_keeping_memory ( * w . registry . despawned ) ;
kept := 0 ;
for pending : w . reclaims {

 confirmed := true ;
for p , _ : w . peers {

 if p . state . acknowledged_tick < pending . tick {
confirmed = false ;
break ;
}


}

 if confirmed {
objects . reclaim ( w . registry , pending . id ) ;
}

 else {
w . reclaims [ kept ] = pending ;
kept += 1 ;
}


}

 array_resize ( * w . reclaims , kept ) ;

 }

 tick :: ( s : * session . Session ) {

 r := ( cast ( * Runtime ) s . runtime_userdata ) ;
synchronize ( r ) ;
for w : ( ( * World ) .[ * r . server , * r . client ] ) {

 if ! w . initialized {
continue ;
}

 w . rpc . tick = s . tick ;
scenes . update ( * w . scenes , ( cast , trunc ( u64 ) ( s . clock_ms ) ) ) ;
objects . begin_tick ( w . registry , s . tick ) ;
if ! r . stopping {
step_world ( w ) ;
}

 if ! r . stopping {
step_physics_bodies ( w ) ;
}


}

 replicate ( * r . server ) ;
publish_world ( * r . server ) ;

 }

 update :: ( r : * Runtime , delta_ms : int ) -> bool {

 if ! r . initialized {
return false ;
}

 ok := session . update ( r . session , delta_ms ) ;
synchronize ( r ) ;
if r . client . initialized {
drain_state ( * r . client ) ;
}

 for w : ( ( * World ) .[ * r . server , * r . client ] ) {

 if ! w . initialized {
continue ;
}

 scenes . update ( * w . scenes , ( cast , trunc ( u64 ) ( r . session . clock_ms ) ) ) ;
rpc . update ( * w . rpc , clamp ( delta_ms , 0 , 1000 ) ) ;
if ! r . stopping {
send_clock_probe ( w ) ;
}


}

 return ok ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
