#scope_file
core :: #import "thirdparty/onet/core" ;
objects :: #import "thirdparty/onet/objects" ;
rpc :: #import "thirdparty/onet/rpc" ;
session :: #import "thirdparty/onet/session" ;
transport :: #import "thirdparty/onet/transport" ;
memory :: #import "thirdparty/onet/transport/memory" ;
#scope_export
// 超过后端单条上限的可靠帧：Session 分片与重组、恶意分片拒绝、runtime 大快照与大 RPC。



 //@region Session 分片

 FR_BIG :: ( cast ( session . Message_Id ) ( 401 ) ) ;
FR_Peer :: struct {
got : [ .. ] [ ] u8 ;
violations : int ;
}

 fr_on_big :: ( s : * session . Session , from : transport . Connection_Id , payload : [ ] u8 ) {

 p := ( cast ( * FR_Peer ) s . userdata ) ;
out := new_slice ( u8 , ( payload ) . count ) ;
copy_samples ( out , payload ) ;
array_add ( * p . got , out ) ;

 }

 fr_on_violation :: ( s : * session . Session , id : transport . Connection_Id , v : session . Violation ) -> session . Violation_Action {

 ( ( cast ( * FR_Peer ) s . userdata ) ) . violations += 1 ;
return . Drop ;

 }

 fr_pattern :: ( n : int , seed : u8 ) -> [ ] u8 {

 b := new_slice ( u8 , n ) ;
for * x , i : b {
x.* = ( cast , trunc ( u8 ) ( i * 7 ) ) + seed ;
}

 return b ;

 }

 fr_destroy :: ( p : * FR_Peer ) {

 for b : p . got {
release ( b ) ;
}

 release ( p . got ) ;

 }

 // 内存后端：仅可靠、单条 1024 字节。

 fr_session :: ( s : * session . Session , x : * memory . Transport , hub : * memory . Hub , peer : * FR_Peer ) {

 memory . init ( x , hub , .{
max_message = 1024 , reliable_only = true
} ) ;
session . init ( s , 10 ) ;
assert ( session . set_driver ( s , memory . driver ( x ) ) ) ;
s . userdata , s . on_violation = peer , fr_on_violation ;
session . register_handler ( s , FR_BIG , fr_on_big ) ;

 } ;

 fr_pump :: ( ss : ..* session . Session ) {
{ loop_index := 0 ; while loop_index < 10 { defer loop_index += 1 ;
for s : ss {
session . update ( s , 5 ) ;
}

 } }

 }



 session_fragments_large_reliable_frames :: ( t : * Test ) {

 hub : memory . Hub ;
memory . hub_init ( * hub ) ;
defer memory . hub_destroy ( * hub ) ;
sx , cx : memory . Transport ;
defer {
memory . destroy ( * sx ) ;
memory . destroy ( * cx ) ;
}

 s , c : session . Session ;
sp , cp : FR_Peer ;
defer {
fr_destroy ( * sp ) ;
fr_destroy ( * cp ) ;
}

 fr_session ( * s , * sx , * hub , * sp ) ;
fr_session ( * c , * cx , * hub , * cp ) ;
defer {
session . destroy ( * s ) ;
session . destroy ( * c ) ;
}

 expect ( t , session . start_server ( * s , 0 ) && session . start_client ( * c , memory . ADDRESS , session . bound_port ( * s ) ) ) ;
fr_pump ( * s , * c ) ;
if ! expect ( t , c . client_authenticated ) {
return ;
}


up , down := fr_pattern ( 100_000 , 1 ) , fr_pattern ( 5_000 , 9 ) ;
defer {
release ( up ) ;
release ( down ) ;
}

 small: []u8 = u8.[ 42 ] ;
expect ( t , session . send_to_server ( * c , FR_BIG , up ) ) ;
expect ( t , session . send_to_server ( * c , FR_BIG , small ) ) ;
expect ( t , session . broadcast_message ( * s , FR_BIG , down ) ) ;
expect ( t , ! session . send_to_server ( * c , FR_BIG , small , . Unreliable ) , "reliable-only backend refuses unreliable" ) ;
fr_pump ( * s , * c ) ;
if expect_value ( t , ( sp . got ) . count , 2 ) {

 expect ( t , ( cast ( string ) ( sp . got [ 0 ] ) ) == ( cast ( string ) ( up ) ) && ( cast ( string ) ( sp . got [ 1 ] ) ) == ( cast ( string ) ( small ) ) , "large then small, in order" ) ;

 }

 if expect_value ( t , ( cp . got ) . count , 1 ) {
expect ( t , ( cast ( string ) ( cp . got [ 0 ] ) ) == ( cast ( string ) ( down ) ) ) ;
}

 expect_value ( t , ( s . assemblies ) . count + ( c . assemblies ) . count , 0 ) ;
expect_value ( t , sp . violations , 0 ) ;
limit := new_slice ( u8 , s . limits . max_packet_bytes ) ;
defer release ( limit ) ;
expect ( t , ! session . send_to_server ( * c , FR_BIG , limit ) , "max_packet_bytes still bounds the whole frame" ) ;

 }


fr_fragment :: ( total , offset : u32 , part : [ ] u8 ) -> [ ] u8 {

 w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
core . write_uint8 ( * w , ( cast , trunc ( u8 ) ( session . Packet_Kind . Fragment ) ) , . Uncompressed ) ;
core . write_uint32 ( * w , total , . Uncompressed ) ;
core . write_uint32 ( * w , offset , . Uncompressed ) ;
core . write_u8_array_as_bytes_unsafe ( * w , part , . Loose ) ;
return core . writer_to_array ( * w ) ;

 }



 session_rejects_malformed_fragments :: ( t : * Test ) {

 hub : memory . Hub ;
memory . hub_init ( * hub ) ;
defer memory . hub_destroy ( * hub ) ;
sx , cx : memory . Transport ;
defer {
memory . destroy ( * sx ) ;
memory . destroy ( * cx ) ;
}

 s , c : session . Session ;
sp , cp : FR_Peer ;
defer {
fr_destroy ( * sp ) ;
fr_destroy ( * cp ) ;
}

 fr_session ( * s , * sx , * hub , * sp ) ;
fr_session ( * c , * cx , * hub , * cp ) ;
defer {
session . destroy ( * s ) ;
session . destroy ( * c ) ;
}

 expect ( t , session . start_server ( * s , 0 ) && session . start_client ( * c , memory . ADDRESS , session . bound_port ( * s ) ) ) ;
fr_pump ( * s , * c ) ;
if ! expect ( t , c . client_authenticated ) {
return ;
}

 id := c . client_server_id ;
inject :: ( x : * memory . Transport , id : transport . Connection_Id , channel : transport . Channel , frame : [ ] u8 ) {

 array_add ( * x . incoming , transport . Incoming_Packet .{
id , . Server , channel , frame
} ) ;

 } ;

 part: []u8 = u8.[ 1 , 2 , 3 ] ;
inject ( * sx , id , . Reliable , fr_fragment ( 10 , 3 , part ) ) ; // 没有开头

 inject ( * sx , id , . Reliable , fr_fragment ( ( cast , trunc ( u32 ) ( s . limits . max_packet_bytes ) ) + 1 , 0 , part ) ) ; // 总长超限

 inject ( * sx , id , . Unreliable , fr_fragment ( 10 , 0 , part ) ) ; // 不可靠通道

 inject ( * sx , id , . Reliable , fr_fragment ( 4 , 0 , part ) ) ; // 合法开头

 inject ( * sx , id , . Reliable , fr_fragment ( 4 , 2 , part ) ) ; // 偏移不连续且越过总长

 session . update ( * s , 0 ) ;
expect_value ( t , sp . violations , 4 ) ;
expect_value ( t , ( s . assemblies ) . count , 0 ) ;

 // 重组出的帧里再嵌套分片。

 inner := fr_fragment ( 3 , 0 , u8 .[ 1 ] ) ;
defer release ( inner ) ;
inject ( * sx , id , . Reliable , fr_fragment ( ( cast , trunc ( u32 ) ( ( inner ) . count ) ) , 0 , inner ) ) ;
session . update ( * s , 0 ) ;
expect_value ( t , sp . violations , 5 ) ;

 // 半成品在连接断开（代次变化）时丢弃。

 inject ( * sx , id , . Reliable , fr_fragment ( 100 , 0 , part ) ) ;
session . update ( * s , 0 ) ;
expect_value ( t , ( s . assemblies ) . count , 1 ) ;
session . kick ( * s , id ) ;
fr_pump ( * s , * c ) ;
expect_value ( t , ( s . assemblies ) . count , 0 ) ;
expect_value ( t , ( sp . got ) . count , 0 ) ;

 }

 //@endregion


//@region runtime 大快照与大 RPC


runtime_large_snapshot_and_rpc_over_small_reliable_only_backend :: ( t : * Test ) {

 hub : memory . Hub ;
memory . hub_init ( * hub ) ;
defer memory . hub_destroy ( * hub ) ;
sx , cx : memory . Transport ;
memory . init ( * sx , * hub , .{
max_message = 1024 , reliable_only = true
} ) ;
memory . init ( * cx , * hub , .{
max_message = 1024 , reliable_only = true
} ) ;
defer {
memory . destroy ( * sx ) ;
memory . destroy ( * cx ) ;
}

 s , a : RT_Node ;
rt_init ( * s , true ) ;
rt_init ( * a , false ) ;
nodes := ( * RT_Node ) .[ * s , * a ] ;
defer rt_shutdown ( nodes ) ;
expect ( t , session . set_driver ( * s . s , memory . driver ( * sx ) ) && session . set_driver ( * a . s , memory . driver ( * cx ) ) ) ;
ids : [ .. ] objects . Network_Id ;
defer release ( ids ) ;
{ i := 0 ; while i < 400 { defer i += 1 ;
array_add ( * ids , rt_spawn ( * s , ( cast , trunc ( s32 ) ( i ) ) ) . id ) ;
} } ;

 expect ( t , session . start_server ( * s . s , 0 ) && session . start_client ( * a . s , memory . ADDRESS , session . bound_port ( * s . s ) ) ) ;
rt_pump ( nodes , 60 ) ;
if ! expect ( t , a . s . client_authenticated ) {
return ;
}

 expect_value ( t , ( a . reg . objects ) . count , 400 ) ;
expect_value ( t , rt_value ( * a , ids [ 399 ] ) , ( cast , trunc ( s32 ) ( 399 ) ) ) ;
big := new_slice ( u8 , 20_000 ) ;
defer release ( big ) ;
expect ( t , rpc . send ( * a . r . client . rpc , 71 , ids [ 0 ] , . Server , big ) , "large RPC accepted" ) ;
rt_pump ( nodes , 20 ) ;
expect_value ( t , s . hits , 1 ) ;

 } ;

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
