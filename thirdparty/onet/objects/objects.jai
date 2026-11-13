#scope_file
core :: #import "thirdparty/onet/core" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export
// onet objects: network objects and synchronized members.

 //

 // Design: a sync member is a pointer registered against a component; the

 // per-type knowledge on the receiving side comes from a component FACTORY

 // registry (map Component_Type_Id -> make proc); dirty tracking compares

 // current vs last-sent, and delta packets use the core codec's delta

 // primitives.

 //

 // 简单 build_state_packet 保留共享可靠流；多人游戏使用 peer_build/peer_apply。

 // 每连接快照、ACK 和恢复独立于 Member 中的旧式 last-sent 字段。




Network_Id :: #type,distinct u32 ;
UNSET_NETWORK_ID :: ( cast ( Network_Id ) ( 0 ) ) ;

 Component_Type_Id :: #type,distinct u32 ;

 // Server authority marker in packets.

 SERVER_OWNED :: ( cast ( transport . Connection_Id ) ( 0 ) ) ;

 Member_Kind :: enum u8 {

 F32 = 1 ;
I32 = 2 ;
Bool = 3 ;
Vec3 = 4 ; // three f32s

 Quat = 5 ; // four f32s, smallest-three packed

 F64 ;
U64 ;
String ;
Bytes ;
Vec2 ;
Vec4 ;
Network_Reference ;
Connection_Reference ;
Custom ;

 }


// One synchronized value: a pointer into the owning game struct plus the

 // last value written to the wire (dirty base + delta base).

 Member :: struct {

 kind : Member_Kind ;

 ptr : * void ;

 accuracy : float32 ;


last_f32 : float32 ;

 last_i32 : s32 ;

 last_bool : bool ;

 last_vec3 : [ 3 ] float32 ;

 last_quat : [ 4 ] float32 ;

 dirty : bool ;

 ever_sent : bool ;

 codec : Value_Codec ;

 last_encoded : [ ] u8 ;

 owned_bytes : [ ] u8 ;


}


// A replicated component: a bag of sync members identified by a type id.

 // Game code derives nothing from this; it registers members by pointer.

 Component :: struct {

 type_id : Component_Type_Id ;

 members : [ .. ] Member ;

 // destroy_userdata 只释放游戏状态外壳；成员拥有的接收缓冲由库释放。

 userdata : * void ;

 destroy_userdata : #type ( * void ) ;


}


// A replicated object.

 Network_Object :: struct {

 id : Network_Id ;

 owner : transport . Connection_Id ;
// SERVER_OWNED or the owning client

 active : bool ;
// false = tombstone

 // Position used by interest management and lag compensation.

 position : [ 3 ] float32 ;

 components : [ .. ] * Component ;

 scene : u32 ;


}


// Factory: builds the client-side mirror of a component type. Registered

 // once per type; must register members in the SAME ORDER as the server.

 Component_Factory :: ( ) -> * Component ;

 Registry :: struct {

 objects : H . Table ( Network_Id , * Network_Object ) ;

 next_id : u32 ;

 active_count : int ;


factories : H . Table ( Component_Type_Id , Component_Factory ) ;


// Despawns waiting to be written into the next state packet.

 pending_despawns : [ .. ] Network_Id ;

 // 服务器选择开启：despawn 的条目在所有 peer 确认后由 runtime 回收（释放对象与组件）。

 // 开启后不要在 despawn 之后继续持有对象或组件指针。未开启时保留墓碑。

 reclaim_despawned : bool ;

 // 开启 reclaim_despawned 时等待回收的 despawn；runtime 取走后清空。

 despawned : [ .. ] Network_Id ;

 authoritative : bool ;

 is_observer : Visibility ;

 visibility_userdata : * void ;

 retained : H . Table ( Network_Id , Control_Retention ) ;

 next_retention : u64 ;

 collection_tick : u64 ;

 collection_tick_started : bool ;

 replaying : bool ;


}


registry_init :: ( reg : * Registry , authoritative : bool = true ) {

 reg .* = .{

 } ;

 reg . objects = new_table ( Network_Id , * Network_Object ) ;
reg . factories = new_table ( Component_Type_Id , Component_Factory ) ;
reg . pending_despawns = new_dynamic ( Network_Id , 0 , 8 ) ;
reg . next_id = 1 ;
reg . authoritative = authoritative ;
reg . retained = new_table ( Network_Id , Control_Retention ) ;
reg . next_retention = 1 ;

 }


registry_destroy :: ( reg : * Registry ) {

 for obj , _ : reg . objects {

 if obj != null {

 free_object ( obj ) ;

 }


}

 release ( reg . objects ) ;
release ( reg . factories ) ;
release ( reg . pending_despawns ) ;
release ( reg . despawned ) ;
for retention , _ : reg . retained {

 release ( retention . identity ) ;

 }

 release ( reg . retained ) ;
reg .* = .{

 } ;


}


free_object :: ( obj : * Network_Object ) {

 for comp : obj . components {

 component_destroy ( comp ) ;

 }

 release ( obj . components ) ;
free ( obj ) ;

 }


register_factory :: ( reg : * Registry , type_id : Component_Type_Id , factory : Component_Factory ) {

 H . table_set ( * reg . factories , type_id , factory ) ;

 }


// Spawns an object; owner UNSET_CONNECTION_ID (0) means server owned.

 spawn :: ( reg : * Registry , owner : transport . Connection_Id ) -> * Network_Object {

 // Never wrap to null or overwrite an earlier lifetime's identity.

 if reg . next_id == 0 {
return null ;
}

 { _ , exists := table_get ( * reg . objects , ( cast ( Network_Id ) ( reg . next_id ) ) ) ; if
exists {
return null ;
} }

 obj := new_one ( Network_Object ) ;
obj . id = ( cast ( Network_Id ) ( reg . next_id ) ) ;
reg . next_id += 1 ;
obj . owner = owner ;
obj . active = true ;
obj . components = new_dynamic ( * Component , 0 , 2 ) ;
H . table_set ( * reg . objects , obj . id , obj ) ;
reg . active_count += 1 ;
return obj ;

 }


// Marks an object despawned; queued for the next state packet. The entry stays

 // as a tombstone unless reclaim_despawned asks runtime to reclaim it later.

 despawn :: ( reg : * Registry , id : Network_Id ) -> bool {

 obj , ok := table_get ( * reg . objects , id ) ;
if ! ok || obj == null || ! obj . active {

 return false ;

 }

 obj . active = false ;
reg . active_count -= 1 ;
array_add ( * reg . pending_despawns , id ) ;
if reg . reclaim_despawned {

 array_add ( * reg . despawned , id ) ;

 }

 return true ;

 }


// 释放已 despawn 对象并删除其条目；活动对象不受影响。ID 仍不复用（next_id 单调）。

 reclaim :: ( reg : * Registry , id : Network_Id ) -> bool {

 obj , ok := table_get ( * reg . objects , id ) ;
if ! ok || ( obj != null && obj . active ) {

 return false ;

 }

 if obj != null {

 free_object ( obj ) ;

 }

 H . table_remove ( * reg . objects , id ) ;
return true ;

 }


get :: ( reg : * Registry , id : Network_Id ) -> ( * Network_Object , bool ) {

 obj , ok := table_get ( * reg . objects , id ) ;
if ok && obj != null && obj . active {

 return obj , true ;

 }

 return null , false ;

 }


active_object_count :: ( reg : * Registry ) -> int {

 return reg . active_count ;

 }


// 对象上第一个 type_id 组件的游戏状态。对象为 nil、已 despawn 或没有该组件时返回 nil。

 // T 必须是该类型工厂放进 Component.userdata 的结构。

 component_data :: ( obj : * Network_Object , $T : Type , type_id : Component_Type_Id ) -> * T {

 if obj == null || ! obj . active {

 return null ;

 }

 for comp : obj . components {

 if comp . type_id == type_id {

 return ( cast ( * T ) comp . userdata ) ;

 }


}

 return null ;

 }


// owner 会随快照复制到客户端：客户端用 find_owned(reg, sess.client_server_id) 找本地角色。

 // 有多个时返回 ID 最小者；owner 为 0（服务器所有或客户端尚未认证）时总是失败。

 find_owned :: ( reg : * Registry , owner : transport . Connection_Id ) -> ( * Network_Object , bool ) {

 if owner == SERVER_OWNED {

 return null , false ;

 }

 found : * Network_Object ;
for obj , _ : reg . objects {

 if obj != null && obj . active && obj . owner == owner && ( found == null || obj . id < found . id ) {

 found = obj ;

 }


}

 return found , found != null ;

 }


// 按 ID 升序追加 owner 拥有的全部活动对象。

 owned_by :: ( reg : * Registry , owner : transport . Connection_Id , out : * [ .. ] Network_Id ) {

 start := ( out ) . count ;
for obj , id : reg . objects {

 if obj != null && obj . active && obj . owner == owner {

 array_add ( out , id ) ;

 }


}

 { i := start + 1 ; while i < ( out ) . count { defer i += 1 ;

 { j := i ; while j > start && out .* [ j ] < out .* [ j - 1 ] { defer j -= 1 ;

 out .* [ j ] , out .* [ j - 1 ] = out .* [ j - 1 ] , out .* [ j ] ;

 } }


} }


}


// ---------------------------------------------------------------------------

 // Components and sync members

 // ---------------------------------------------------------------------------


// Builds a standalone component (not yet attached to an object): the shape

 // client-side factories produce; apply_state_packet attaches it.

 component_make :: ( type_id : Component_Type_Id ) -> * Component {

 comp := new_one ( Component ) ;
comp . type_id = type_id ;
comp . members = new_dynamic ( Member , 0 , 8 ) ;
return comp ;

 }



 component_add :: ( obj : * Network_Object , type_id : Component_Type_Id ) -> * Component {

 comp := new_one ( Component ) ;
comp . type_id = type_id ;
comp . members = new_dynamic ( Member , 0 , 8 ) ;
array_add ( * obj . components , comp ) ;
return comp ;

 }


member_f32 :: ( comp : * Component , value : * float32 , accuracy : float32 = core . DEFAULT_ACCURACY ) {

 array_add ( * comp . members , Member .{
kind = . F32 , ptr = value , accuracy = accuracy
} ) ;

 } ;


member_i32 :: ( comp : * Component , value : * s32 ) {

 array_add ( * comp . members , Member .{
kind = . I32 , ptr = value
} ) ;

 } ;


member_bool :: ( comp : * Component , value : * bool ) {

 array_add ( * comp . members , Member .{
kind = . Bool , ptr = value
} ) ;

 } ;


member_vec3 :: ( comp : * Component , value : * [ 3 ] float32 , accuracy : float32 = core . DEFAULT_ACCURACY ) {

 array_add ( * comp . members , Member .{
kind = . Vec3 , ptr = value , accuracy = accuracy
} ) ;

 } ;


member_quat :: ( comp : * Component , value : * [ 4 ] float32 , accuracy : float32 = core . DEFAULT_ACCURACY ) {

 array_add ( * comp . members , Member .{
kind = . Quat , ptr = value , accuracy = accuracy
} ) ;

 } ;


// Compares every member against its last-sent value and raises the dirty

 // flag (the last-sent value is NOT updated here; that happens on write).

 poll_dirty :: ( obj : * Network_Object ) -> bool {

 any := false ;
for comp : obj . components {

 { i := 0 ; while i < ( comp . members ) . count { defer i += 1 ;

 m := * comp . members [ i ] ;
if m . kind == {

 case . F32 ;
cur := ( ( cast ( * float32 ) m . ptr ) ) .* ;
if ! m . ever_sent || cur != m . last_f32 {

 m . dirty = true ;

 }

 case . I32 ;
cur := ( ( cast ( * s32 ) m . ptr ) ) .* ;
if ! m . ever_sent || cur != m . last_i32 {

 m . dirty = true ;

 }

 case . Bool ;
cur := ( ( cast ( * bool ) m . ptr ) ) .* ;
if ! m . ever_sent || cur != m . last_bool {

 m . dirty = true ;

 }

 case . Vec3 ;
cur := ( ( cast ( * [ 3 ] float32 ) m . ptr ) ) .* ;
if ! m . ever_sent || cur [ 0 ] != m . last_vec3 [ 0 ] || cur [ 1 ] != m . last_vec3 [ 1 ] || cur [ 2 ] != m . last_vec3 [ 2 ] {

 m . dirty = true ;

 }

 case . Quat ;
cur := ( ( cast ( * [ 4 ] float32 ) m . ptr ) ) .* ;
if ! m . ever_sent || cur [ 0 ] != m . last_quat [ 0 ] || cur [ 1 ] != m . last_quat [ 1 ] || cur [ 2 ] != m . last_quat [ 2 ] || cur [ 3 ] != m . last_quat [ 3 ] {

 m . dirty = true ;

 }

 case ;
encoded , ok := member_bytes ( m ) ;
m . dirty = ! ok || ! m . ever_sent || ! bytes_equal ( encoded , m . last_encoded ) ;
release ( encoded ) ;

 }

 if m . dirty {

 any = true ;

 }


} }


}

 return any ;

 }


// True when the object has at least one dirty member (poll_dirty first).

 is_dirty :: ( obj : * Network_Object ) -> bool {

 for comp : obj . components {

 for m : comp . members {

 if m . dirty {

 return true ;

 }


}


}

 return false ;

 }


member_value_f32 :: ( m : * Member ) -> float32 {
return ( ( cast ( * float32 ) m . ptr ) ) .* ;
}


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
