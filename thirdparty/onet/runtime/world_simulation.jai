#scope_file
core :: #import "thirdparty/onet/core" ;
objects :: #import "thirdparty/onet/objects" ;
session :: #import "thirdparty/onet/session" ;
sim :: #import "thirdparty/onet/simulation" ;
transport :: #import "thirdparty/onet/transport" ;
wire :: #import "thirdparty/onet/wire" ;
#scope_export


//@region 组件工厂与整世界绑定

 Simulation_World :: sim . Simulation_World ;
Simulation_Callbacks :: sim . World_Callbacks ;
World_System_Factory :: ( user : * void , obj : * objects . Network_Object ) -> ( sim . System_Config , bool ) ;
World_Factory :: struct {
user : * void ;
build : World_System_Factory ;
}

 World_Selection_Context :: struct {
world : * World ;
connection : transport . Connection_Id ;
}

 World_Prediction_Guard :: struct {
id : sim . System_Id ;
user : * void ;
state : [ ] u8 ;
}


bind_simulation :: ( w : * World , c : * sim . Simulation_World , bind_objects := true ) -> bool {

 if ! w . initialized || w . simulation != null || c == null || ! c . initialized || c . binding != null || c . config . authority != w . authority || w . next_simulation_binding == ~ ( cast , trunc ( u64 ) ( 0 ) ) || Math . abs ( c . config . fixed_dt * 1000 - ( cast ( float64 ) ( w . runtime . session . tick_interval_ms ) ) ) > 0.00001 {
return false ;
}

 w . simulation , w . simulation_callbacks , w . simulation_objects = c , c . callbacks , bind_objects ;
w . next_simulation_binding += 1 ;
w . simulation_binding = w . next_simulation_binding ;
if w . authority {
w . simulation_epoch = w . simulation_binding ;
}

 c . binding = w ;
reset_simulation_timeline ( w ) ;
for p , _ : w . peers {
reset_world_peer ( w , p ) ;
}

 c . callbacks = .{
user = w , physics = world_physics , event = world_event , replay_mode = world_replay_mode ,
} ;

 if ! w . authority {
c . config . local_owner = w . runtime . session . client_server_id ;
c . needs_full = true ;
}

 // Session时钟可能已运行，不能把旧Session.tick锚点沿用到新世界tick。

 sim . clock_reset ( * w . world_clock ) ;
array_reset_keeping_memory ( * w . clock_pending ) ;
w . world_last_request_ms , w . clock_last_request_ms = - 1000 , - 1000 ;
return true ;

 }

 unbind_simulation :: ( w : * World ) {

 if w . simulation == null {
return ;
}

 ids : [ .. ] sim . System_Id ;
for _ , id : w . automatic_systems {
array_add ( * ids , id ) ;
}

 sim . world_unregister_batch ( w . simulation , view ( ids , 0 ) ) ;
release ( ids ) ;
array_reset_keeping_memory ( * w . automatic_systems ) ;
sim . world_clear_inputs ( w . simulation ) ;
sim . world_frame_destroy ( w . simulation , * w . simulation . pending ) ;
w . simulation . binding = null ;
w . simulation . callbacks = w . simulation_callbacks ;
w . simulation = null ;
release ( w . world_waiting_packet ) ;
w . world_waiting_packet = .[ ] ;

 }

 register_world_component :: ( w : * World , type_id : objects . Component_Type_Id , build : World_System_Factory , user : * void = null ) -> bool {

 if ! w . initialized || type_id == 0 || build == null || table_get ( * w . world_factories , type_id ) . build != null {
return false ;
}

 H . table_set ( * w . world_factories , type_id , .{
user , build ,
} ) ;

 return true ;

 }

 world_physics :: ( user : * void , c : * sim . Simulation_World , tick : sim . Tick , dt : float64 , replay : bool ) {

 w := ( cast ( * World ) user ) ;
{ cb := w . simulation_callbacks . physics ; if
cb != null {
cb ( w . simulation_callbacks . user , c , tick , dt , replay ) ;
} }


}

 world_event :: ( user : * void , c : * sim . Simulation_World , event : sim . World_Event , id : sim . System_Id , tick : sim . Tick ) {

 w := ( cast ( * World ) user ) ;
if event == {

 case . Replay_Starting ; w . counters . corrections += 1 ;
case . Corrected ; w . counters . corrected_systems += 1 ;
case . Full_Reset ; w . counters . full_resyncs += 1 ;
case . Result_Mismatch ; w . counters . result_mismatches += 1 ;
case . Missing_Input ; if c . config . authority {
w . counters . missing_inputs += 1 ;
}


}

 { cb := w . simulation_callbacks . event ; if
cb != null {
cb ( w . simulation_callbacks . user , c , event , id , tick ) ;
} }


}

 world_replay_mode :: ( user : * void , enabled : bool ) {

 w := ( cast ( * World ) user ) ;
w . rpc . replaying = enabled ;
objects . set_replaying ( w . registry , enabled ) ;
{ cb := w . simulation_callbacks . replay_mode ; if
cb != null {
cb ( w . simulation_callbacks . user , enabled ) ;
} }


}

 sync_simulation_objects :: ( w : * World ) {

 c := w . simulation ;
if c == null {
return ;
}

 remove_flag : [ .. ] sim . System_Id ;
for object , id : w . automatic_systems {
{ _ , exists := objects . get ( w . registry , object ) ; if
! exists {
array_add ( * remove_flag , id ) ;
} }

 }

 if ( remove_flag ) . count > 0 {

 sim . world_unregister_batch ( c , view ( remove_flag , 0 ) ) ;
for id : remove_flag {
H . table_remove ( * w . automatic_systems , id ) ;
}


}

 release ( remove_flag ) ;
for obj , _ : w . registry . objects {

 if obj == null || ! obj . active {
continue ;
}

 id := ( cast ( sim . System_Id ) ( obj . id ) ) ;
{ existing , loop_index := sim . world_find ( c , id ) ; if
existing != null {

 if w . authority && w . simulation_objects && existing . config . owner != obj . owner {

 if existing . config . incarnation != ~ ( cast , trunc ( u64 ) ( 0 ) ) {
sim . world_set_owner ( c , id , obj . owner , existing . config . incarnation + 1 ) ;
}


}

 continue ;

 } }

 for comp : obj . components {

 factory := table_get ( * w . world_factories , comp . type_id ) ;
if factory . build == null {
continue ;
}

 cfg , ok := factory . build ( factory . user , obj ) ;
if ! ok {
break ;
}

 cfg . id , cfg . owner = id , obj . owner ;
if sim . world_register ( c , cfg ) == . Ok {
H . table_set ( * w . automatic_systems , id , obj . id ) ;
}

 break ;

 }


}


}

 reset_bound_simulation :: ( w : * World ) {

 reset_physics_bodies ( w ) ;
c := w . simulation ;
if c == null {
return ;
}

 ids : [ .. ] sim . System_Id ;
for _ , id : w . automatic_systems {
array_add ( * ids , id ) ;
}

 sim . world_unregister_batch ( c , view ( ids , 0 ) ) ;
release ( ids ) ;
array_reset_keeping_memory ( * w . automatic_systems ) ;
reset_simulation_timeline ( w ) ;
if ! w . authority {
w . simulation_epoch = 0 ;
}

 if ! c . config . authority {
c . config . local_owner = w . runtime . session . client_server_id ;
}

 release ( w . world_waiting_packet ) ;
w . world_waiting_packet = .[ ] ;
sim . clock_reset ( * w . world_clock ) ;
array_reset_keeping_memory ( * w . clock_pending ) ;
w . world_last_request_ms , w . clock_last_request_ms = - 1000 , - 1000 ;

 }

 // Binding/connection changes discard only simulation networking state, not game

 // state or borrowed callbacks. New authority must establish a full world seed.

 reset_simulation_timeline :: ( w : * World ) {

 c := w . simulation ;
if c == null {
return ;
}

 w . simulation_seeded = false ;
sim . world_clear_inputs ( c ) ;
sim . world_frame_destroy ( c , * c . pending ) ;
c . received_sequence , c . applied_tick , c . correction_serial = 0 , 0 , 0 ;
c . needs_full = ! c . config . authority ;
release ( w . world_waiting_packet ) ;
w . world_waiting_packet = .[ ] ;

 }

 reset_world_peer :: ( w : * World , p : * Peer_State ) {

 release ( p . world_correction ) ;
p . world_correction = .[ ] ;
for data : p . world_results {
release ( data ) ;
}

 release ( p . world_results ) ;
p . world_results = .{ } ;
p . world_correction_serial , p . world_last_request_ms = 0 , - 1000 ;
if w . simulation != null {
sim . world_clear_inputs ( w . simulation , p . state . connection , false ) ;
}


}

 world_selected :: ( id : sim . System_Id , user : * void ) -> bool {

 ctx := ( cast ( * World_Selection_Context ) user ) ;
if ! ctx . world . simulation_objects {
return true ;
}

 obj , exists := objects . get ( ctx . world . registry , ( cast ( objects . Network_Id ) ( id ) ) ) ;
return exists && is_observer ( ctx . world , obj , ctx . connection ) ;

 }

 world_input_allowed :: ( user : * void , id : sim . System_Id , owner : transport . Connection_Id ) -> bool {

 w := ( cast ( * World ) user ) ;
return ! w . simulation_objects || objects . can_write ( w . registry , ( cast ( objects . Network_Id ) ( id ) ) , owner ) ;

 }

 world_save_prediction :: ( w : * World ) -> ( saved : [ .. ] World_Prediction_Guard ) {

 c := w . simulation ;
if c == null {
return ;
}

 for s : c . systems {

 if ! sim . world_predicted ( c , s ) {
continue ;
}

 state := new_slice ( u8 , s . config . state_size ) ;
s . config . callbacks . capture ( s . config . callbacks . user , state ) ;
array_add ( * saved , World_Prediction_Guard .{
s . config . id , s . config . callbacks . user , state
} ) ;

 } ;

 return ;

 }

 world_restore_prediction :: ( w : * World , saved : [ .. ] World_Prediction_Guard ) {

 defer release ( saved ) ;
for old : saved {

 defer release ( old . state ) ;
if w . simulation == null {
continue ;
}

 s , loop_index := sim . world_find ( w . simulation , old . id ) ;
if s != null && s . config . callbacks . user == old . user && sim . world_predicted ( w . simulation , s ) {
s . config . callbacks . restore ( s . config . callbacks . user , old . state ) ;
}


}


}

 //@endregion


//@region 网络统计

 Net_Stats :: struct {

 // 远端时钟（客户端；服务器为0）。

 rtt_ms , jitter_ms , offset_ms : float64 ;

 // 模拟世界本地tick与最近应用的权威tick；客户端lead=tick-applied_tick即预测领先量。

 tick , applied_tick : u64 ;

 prediction_lead : s64 ;

 corrections : u64 ;
// 客户端发生回滚重放的次数

 corrected_systems : u64 ;
// 其中被校正的预测系统累计数

 missing_inputs : u64 ;
// 服务器：客户端输入未按时到达而按默认/沿用推进的次数

 full_resyncs : u64 ;
// 历史不足或needs_full导致的完整重新同步

 result_mismatches : u64 ;
// 服务器：客户端结果hash不一致

 // 客户端到服务器连接的后端质量（丢包、重传、未确认字节、后端RTT）；后端不提供时backend_ok=false。

 // 服务器侧逐连接查询用 session.connection_quality。

 backend : transport . Connection_Quality ;

 backend_ok : bool ;


}

 // 计数在World生命周期内累计，应用无需订阅World_Callbacks.event。

 stats :: ( w : * World ) -> Net_Stats {

 out := w . counters ;
clock := * w . state_clock ;
if ! clock . sampled {
clock = * w . world_clock ;
}

 if clock . sampled {
out . rtt_ms , out . jitter_ms , out . offset_ms = clock . rtt_ms , clock . jitter_ms , clock . offset_ms ;
}

 if ! w . authority && w . generation != 0 {

 out . backend , out . backend_ok = session . connection_quality ( w . runtime . session , session . local_connection ( w . runtime . session ) ) ;

 }

 { c := w . simulation ; if
c != null {

 out . tick , out . applied_tick = c . tick , c . applied_tick ;
if ! c . config . authority {
out . prediction_lead = ( cast , trunc ( s64 ) ( c . tick ) ) - ( cast , trunc ( s64 ) ( c . applied_tick ) ) ;
}


} }

 return out ;

 }

 //@endregion


//@region 世界快照、输入与Validate路由

 // All simulation traffic has a server epoch and client binding nonce. This is a

 // new world protocol, not an adapter for the removed independent channels.

 send_world :: ( w : * World , to : transport . Connection_Id , kind : Kind , body : [ ] u8 ) -> bool {

 if w . simulation == null {
return false ;
}

 binding := w . simulation_binding ;
if w . authority {
p := table_get ( * w . peers , to ) ;
if p == null {
return false ;
} ;
binding = p . world_client_binding ;
}

 if binding == 0 {
return false ;
}

 writer : core . Writer ;
core . writer_init ( * writer ) ;
defer core . writer_destroy ( * writer ) ;
core . write_uint64 ( * writer , w . simulation_epoch , . Uncompressed ) ;
core . write_uint64 ( * writer , binding , . Uncompressed ) ;
core . write_u8_array_as_bytes_unsafe ( * writer , body , . Loose ) ;
data := core . writer_to_array ( * writer ) ;
defer release ( data ) ;
return send ( w , to , kind , data ) ;

 }


world_snapshot_to :: ( w : * World , to : transport . Connection_Id , correction := false ) -> bool {

 p := table_get ( * w . peers , to ) ;
if p == null || w . simulation == null || p . world_client_binding == 0 {
return false ;
}

 if correction {

 if p . world_correction_serial == ~ ( cast , trunc ( u64 ) ( 0 ) ) {
return false ;
}

 p . world_correction_serial += 1 ;

 }

 ctx := World_Selection_Context .{
w , to ,
} ;

 data , status := sim . world_encode_snapshot ( w . simulation , w . simulation . tick , p . world_correction_serial , world_selected , * ctx ) ;
if status != . Ok {
return false ;
}

 if correction {
release ( p . world_correction ) ;
p . world_correction = wire . clone ( data ) ;
}

 defer release ( data ) ;
return send_world ( w , to , ( ifx correction then . World_Correction else . World_State ) , data ) ;

 }

 world_request_snapshot :: ( w : * World ) -> bool {

 if w . simulation == null || w . authority || w . generation == 0 {
return false ;
}

 if w . runtime . session . clock_ms - w . world_last_request_ms < 100 {
return true ;
}

 if w . simulation . needs_full && w . simulation_seeded {

 if w . next_simulation_binding == ~ ( cast , trunc ( u64 ) ( 0 ) ) {
return false ;
}

 w . next_simulation_binding += 1 ;
w . simulation_binding = w . next_simulation_binding ;
reset_simulation_timeline ( w ) ;

 }

 w . world_last_request_ms = w . runtime . session . clock_ms ;
return send_world ( w , session . local_connection ( w . runtime . session ) , . World_Reset_Request , .[ ] ) ;

 }

 receive_world :: ( w : * World , from : transport . Connection_Id , kind : Kind , data : [ ] u8 ) -> bool {

 c := w . simulation ;
if c == null {
return false ;
}

 sync_simulation_objects ( w ) ;
reader : core . Reader ;
core . reader_init ( * reader , data ) ;
epoch := core . read_uint64 ( * reader , . Uncompressed ) ;
binding := core . read_uint64 ( * reader , . Uncompressed ) ;
if reader . err != . None || binding == 0 {
return false ;
}

 body := view ( data , 16 ) ;
if w . authority {

 p := table_get ( * w . peers , from ) ;
if p == null {
return false ;
}

 if kind == . World_Reset_Request {

 if ( body ) . count != 0 {
return false ;
}

 if binding < p . world_client_binding {
return true ;
}

 if binding > p . world_client_binding {
reset_world_peer ( w , p ) ;
p . world_client_binding = binding ;
}


} else if epoch != w . simulation_epoch || binding != p . world_client_binding {
return true ;
}


} else {

 if binding != w . simulation_binding || epoch < w . simulation_epoch {
return true ;
}

 if epoch == 0 || ( kind != . World_State && kind != . World_Correction ) {
return false ;
}


}

 if w . authority {

 if kind == {

 case . World_Reset_Request ;
if ( body ) . count != 0 {
return false ;
}

 p := table_get ( * w . peers , from ) ;
if w . runtime . session . clock_ms - p . world_last_request_ms < 100 {
return true ;
}

 p . world_last_request_ms = w . runtime . session . clock_ms ;
return world_snapshot_to ( w , from ) ;
case . World_Input ;
status := sim . world_receive_input ( c , from , body , world_input_allowed , w ) ;
return status == . Ok || status == . Stale || status == . Duplicate ;
case . World_Result ;
return receive_world_result ( w , from , body , true ) ;
case ; return false ;

 }


} else {

 if kind != . World_State && kind != . World_Correction {
return false ;
}

 status := sim . world_receive_snapshot ( c , body , epoch > w . simulation_epoch ) ;
if status == . Schema_Mismatch {

 if ( body ) . count < 18 || ( body ) . count > wire . MAX_PAYLOAD {
return false ;
}

 release ( w . world_waiting_packet ) ;
w . world_waiting_packet = wire . clone ( body ) ;
w . world_waiting_epoch = epoch ;
return world_request_snapshot ( w ) ;

 }

 if status == . Ok {
commit_world_epoch ( w , epoch ) ;
w . simulation_seeded = true ;
release ( w . world_waiting_packet ) ;
w . world_waiting_packet = .[ ] ;
}

 return status == . Ok || status == . Duplicate || status == . Stale ;

 }


}

 receive_world_result :: ( w : * World , from : transport . Connection_Id , data : [ ] u8 , may_queue : bool ) -> bool {

 p := table_get ( * w . peers , from ) ;
if p == null {
return false ;
}

 tick , ack , mismatch , status := sim . world_check_result ( w . simulation , from , data , false ) ;
if ack > p . world_correction_serial {
return false ;
}

 if status == . Not_Ready && may_queue {

 bytes := 0 ;
for queued : p . world_results {
bytes += ( queued ) . count ;
}

 if ( p . world_results ) . count >= w . simulation . config . capacity || bytes + ( data ) . count > wire . MAX_PAYLOAD {
return false ;
}

 for queued : p . world_results {
if wire . equal ( queued , data ) {
return true ;
}

 }

 array_add ( * p . world_results , wire . clone ( data ) ) ;
return true ;

 }

 if status == . Expired {
return world_snapshot_to ( w , from , true ) ;
}

 if status != . Ok {
return status == . Stale ;
}

 if ack == p . world_correction_serial {
release ( p . world_correction ) ;
p . world_correction = .[ ] ;
}

 if p . world_correction . data != null {
return send_world ( w , from , . World_Correction , p . world_correction ) ;
}

 if mismatch {
sim . world_notify ( w . simulation , . Result_Mismatch , 0 , tick ) ;
return world_snapshot_to ( w , from , true ) ;
}

 _ = tick ;
return true ;

 }

 process_world_results :: ( w : * World ) {

 for p , id : w . peers {

 kept := 0 ;
for queued : p . world_results {

 _ , _ , _ , status := sim . world_check_result ( w . simulation , id , queued , false ) ;
if status == . Not_Ready {
p . world_results [ kept ] = queued ;
kept += 1 ;
}

 else {
receive_world_result ( w , id , queued , false ) ;
release ( queued ) ;
}


}

 array_resize ( * p . world_results , kept ) ;

 }


}

 forget_world_peer :: ( w : * World , p : * Peer_State ) {

 reset_world_peer ( w , p ) ;

 }

 //@endregion


//@region 远端时钟握手与网络tick接线

 send_clock_probe :: ( w : * World ) {

 if w . authority || w . generation == 0 || w . runtime . session . clock_ms - w . clock_last_request_ms < 250 || w . clock_nonce == ~ ( cast , trunc ( u64 ) ( 0 ) ) {
return ;
}

 w . clock_nonce += 1 ;
w . clock_last_request_ms = w . runtime . session . clock_ms ;
writer : core . Writer ;
core . writer_init ( * writer ) ;
defer core . writer_destroy ( * writer ) ;
core . write_uint64 ( * writer , w . clock_nonce , . Uncompressed ) ;
core . write_uint64 ( * writer , ( cast , trunc ( u64 ) ( w . runtime . session . clock_ms ) ) , . Uncompressed ) ;
data := core . writer_to_array ( * writer ) ;
defer release ( data ) ;
if send ( w , session . local_connection ( w . runtime . session ) , . Clock_Ping , data ) {
H . table_set ( * w . clock_pending , w . clock_nonce , w . runtime . session . clock_ms ) ;
}

 for sent , nonce : w . clock_pending {
if w . runtime . session . clock_ms - sent > 10000 {
H . table_remove ( * w . clock_pending , nonce ) ;
}

 }


}

 receive_clock :: ( w : * World , from : transport . Connection_Id , kind : Kind , data : [ ] u8 ) -> bool {

 r : core . Reader ;
core . reader_init ( * r , data ) ;
nonce := core . read_uint64 ( * r , . Uncompressed ) ;
sent := core . read_uint64 ( * r , . Uncompressed ) ;
if nonce == 0 || sent > ( cast , trunc ( u64 ) ( 0x7fffffffffffffff ) ) {
return false ;
}

 if w . authority {

 if kind != . Clock_Ping || ! wire . finished ( * r ) {
return false ;
}

 writer : core . Writer ;
core . writer_init ( * writer ) ;
defer core . writer_destroy ( * writer ) ;
core . write_uint64 ( * writer , nonce , . Uncompressed ) ;
core . write_uint64 ( * writer , sent , . Uncompressed ) ;
core . write_uint64 ( * writer , ( cast , trunc ( u64 ) ( w . runtime . session . clock_ms ) ) , . Uncompressed ) ;
core . write_uint64 ( * writer , ( ifx w . simulation != null then w . simulation . tick else w . runtime . session . tick ) , . Uncompressed ) ;
core . write_uint64 ( * writer , w . runtime . session . tick , . Uncompressed ) ;
bytes := core . writer_to_array ( * writer ) ;
defer release ( bytes ) ;
return send ( w , from , . Clock_Pong , bytes ) ;

 }

 if kind != . Clock_Pong {
return false ;
}

 remote_ms := core . read_uint64 ( * r , . Uncompressed ) ;
remote_tick := core . read_uint64 ( * r , . Uncompressed ) ;
state_tick := core . read_uint64 ( * r , . Uncompressed ) ;
expected , exists := table_get ( * w . clock_pending , nonce ) ;
if ! wire . finished ( * r ) || remote_ms > ( cast , trunc ( u64 ) ( 0x7fffffffffffffff ) ) {
return false ;
}

 if ! exists {
return true ;
}

 if sent != ( cast , trunc ( u64 ) ( expected ) ) {
return false ;
}

 H . table_remove ( * w . clock_pending , nonce ) ;
status := sim . clock_observe ( * w . world_clock , ( cast ( float64 ) ( sent ) ) , ( cast ( float64 ) ( w . runtime . session . clock_ms ) ) , ( cast ( float64 ) ( remote_ms ) ) , remote_tick ) ;
if ! w . state_clock_network_sampled {
sim . clock_reset ( * w . state_clock ) ;
w . state_clock_network_sampled = true ;
}

 state_status := sim . clock_observe ( * w . state_clock , ( cast ( float64 ) ( sent ) ) , ( cast ( float64 ) ( w . runtime . session . clock_ms ) ) , ( cast ( float64 ) ( remote_ms ) ) , state_tick ) ;
return ( status == . Ok || status == . Stale ) && ( state_status == . Ok || state_status == . Stale ) ;

 }

 commit_world_epoch :: ( w : * World , epoch : u64 ) {

 if epoch == w . simulation_epoch {
return ;
}

 w . simulation_epoch = epoch ;
sim . clock_reset ( * w . world_clock ) ;
array_reset_keeping_memory ( * w . clock_pending ) ;
w . clock_last_request_ms = - 1000 ;

 }


world_before_tick :: ( w : * World ) {

 if w . simulation == null {
return ;
}

 sync_simulation_objects ( w ) ;
if ! w . authority {

 if ( w . world_waiting_packet ) . count > 0 {

 status := ( ifx w . world_waiting_epoch < w . simulation_epoch then sim . Status . Stale else sim . world_receive_snapshot ( w . simulation , w . world_waiting_packet , w . world_waiting_epoch > w . simulation_epoch ) ) ;
if status == . Ok {
commit_world_epoch ( w , w . world_waiting_epoch ) ;
w . simulation_seeded = true ;
}

 if status == . Ok || status == . Duplicate || status == . Stale {
release ( w . world_waiting_packet ) ;
w . world_waiting_packet = .[ ] ;
}


}

 sim . world_reconcile ( w . simulation ) ;

 }


}

 step_world :: ( w : * World ) {

 c := w . simulation ;
if c == null {
return ;
}

 sync_simulation_objects ( w ) ;
if w . authority {
sim . world_step ( c ) ;
process_world_results ( w ) ;
return ;
}

 if c . needs_full {
world_request_snapshot ( w ) ;
return ;
}

 target , status := sim . clock_prediction_tick ( * w . world_clock , ( cast ( float64 ) ( w . runtime . session . clock_ms ) ) ) ;
if status != . Ok {
return ;
}

 { steps := 0 ; while c . tick < target && steps < 2 { defer steps += 1 ;

 if sim . world_step ( c ) != . Ok {
break ;
}

 if sim . world_has_owner ( c , ( cast , trunc ( u32 ) ( w . runtime . session . client_server_id ) ) ) {

 input , input_status := sim . world_encode_input ( c , w . runtime . session . client_server_id , c . tick ) ;
if input_status == . Ok {
send_world ( w , session . local_connection ( w . runtime . session ) , . World_Input , input ) ;
}

 release ( input ) ;
result , result_status := sim . world_encode_result ( c , w . runtime . session . client_server_id , c . tick ) ;
if result_status == . Ok {
send_world ( w , session . local_connection ( w . runtime . session ) , . World_Result , result ) ;
}

 release ( result ) ;

 }


} }


}

 publish_world :: ( w : * World ) {

 if w . simulation == null || ! w . authority || w . runtime . stopping {
return ;
}

 for _ , id : w . peers {
world_snapshot_to ( w , id ) ;
}


}

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
