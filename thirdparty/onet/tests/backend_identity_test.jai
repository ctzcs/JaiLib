#scope_file
session :: #import "thirdparty/onet/session" ;
transport :: #import "thirdparty/onet/transport" ;
memory :: #import "thirdparty/onet/transport/memory" ;
#scope_export
// 后端已验证身份交给应用决定批准；host 优先使用后端的本地连接对。



 //@region 身份

 BI_State :: struct {
seen : string ;
approved : bool ;
}

 bi_connecting :: ( s : * session . Session , id : transport . Connection_Id , generation : u64 ) {

 st := ( cast ( * BI_State ) s . userdata ) ;
identity := session . remote_identity ( s , id ) ;
st . seen = identity ;
// 示例策略：只批准后端报告了身份的连接，并把它作为已验证身份。

 if identity != "" {
st . approved = session . approve_client ( s , id , generation , identity ) ;
}

 else {
session . deny_client ( s , id , generation ) ;
}


}



 session_backend_identity_reaches_application :: ( t : * Test ) {

 hub : memory . Hub ;
memory . hub_init ( * hub ) ;
defer memory . hub_destroy ( * hub ) ;
sx , cx : memory . Transport ;
memory . init ( * sx , * hub , .{
identity = "server-account"
} ) ;
memory . init ( * cx , * hub , .{
identity = "alice"
} ) ;
defer {
memory . destroy ( * sx ) ;
memory . destroy ( * cx ) ;
}

 s , c : session . Session ;
session . init ( * s , 10 ) ;
session . init ( * c , 10 ) ;
defer {
session . destroy ( * s ) ;
session . destroy ( * c ) ;
}

 expect ( t , session . set_driver ( * s , memory . driver ( * sx ) ) && session . set_driver ( * c , memory . driver ( * cx ) ) ) ;
st : BI_State ;
s . userdata , s . require_authentication , s . on_client_connecting = * st , true , bi_connecting ;
expect ( t , session . start_server ( * s , 0 ) && session . start_client ( * c , memory . ADDRESS , session . bound_port ( * s ) ) ) ;
{ loop_index := 0 ; while loop_index < 10 { defer loop_index += 1 ;
session . update ( * s , 5 ) ;
session . update ( * c , 5 ) ;
} } ;

 expect ( t , st . approved && st . seen == "alice" && c . client_authenticated ) ;
info := session . client_info ( * s , c . client_server_id ) ;
expect ( t , info != null && info . identity == "alice" && info . backend_identity == "alice" ) ;
expect_value ( t , session . server_identity ( * c ) , "server-account" ) ;

 } ;

 //@endregion


//@region host 本地连接对

 bi_pairs : int ; // 只有本文件的测试修改

 bi_vtable_counting : transport . Driver_Vtable ;
bi_vtable_no_pair : transport . Driver_Vtable ;

 bi_host :: ( t : * Test , vtable : * transport . Driver_Vtable ) -> bool {

 hub : memory . Hub ;
memory . hub_init ( * hub ) ;
defer memory . hub_destroy ( * hub ) ;
x : memory . Transport ;
memory . init ( * x , * hub ) ;
defer memory . destroy ( * x ) ;
s : session . Session ;
session . init ( * s , 10 ) ;
defer session . destroy ( * s ) ;
expect ( t , session . set_driver ( * s , .{
* x , vtable
} ) ) ;
if ! expect ( t , session . start_host ( * s , 4 ) ) {
return false ;
}

 { loop_index := 0 ; while loop_index < 5 { defer loop_index += 1 ;
session . update ( * s , 5 ) ;
} } ;

 return s . client_authenticated && session . connection_count ( * s ) == 1 ;

 }



 session_host_prefers_local_pair :: ( t : * Test ) {

 bi_vtable_counting = memory . driver_vtable ;
bi_vtable_counting . open_local_pair = ( p : * void ) -> bool {
bi_pairs += 1 ;
return memory . open_local_pair ( ( cast ( * memory . Transport ) p ) ) ;
}

 bi_vtable_no_pair = memory . driver_vtable ;
bi_vtable_no_pair . open_local_pair = null ;
expect ( t , bi_host ( t , * bi_vtable_counting ) , "host via local pair" ) ;
expect_value ( t , bi_pairs , 1 ) ;
expect ( t , bi_host ( t , * bi_vtable_no_pair ) , "host via loopback address" ) ;
expect_value ( t , bi_pairs , 1 ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
