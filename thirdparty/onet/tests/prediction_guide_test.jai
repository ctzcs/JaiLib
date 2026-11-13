#scope_file
objects :: #import "thirdparty/onet/objects" ;
nr :: #import "thirdparty/onet/runtime" ;
session :: #import "thirdparty/onet/session" ;
sim :: #import "thirdparty/onet/simulation" ;
#scope_export
// 预测接入指南的依据：只用模拟状态、不注册对象成员时，远端显示、迟加入与重连都正确。



 //@region 只有模拟状态的组件

 SO_TYPE :: ( cast ( objects . Component_Type_Id ) ( 9933 ) ) ;
SO_Body :: struct {
pos : [ 2 ] float32 ;
}

 SO_Endpoint :: struct {
node : RT_Node ;
world : sim . Simulation_World ;
input , server_motion : u8 ;
}

 so_carry := u8 .[ 1 ] ;
so_free :: ( p : * void ) {
free ( ( cast ( * SO_Body ) p ) ) ;
}

 // 不注册任何成员：位置只随 Simulation_World 快照同步。

 so_factory :: ( ) -> * objects . Component {

 c := objects . component_make ( SO_TYPE ) ;
c . userdata , c . destroy_userdata = new_one ( SO_Body ) , so_free ;
return c ;

 }

 so_capture :: ( p : * void , dst : [ ] u8 ) {
at := 0 ;
sim . state_put_vec2 ( dst , * at , ( ( cast ( * SO_Body ) p ) ) . pos ) ;
}

 so_restore :: ( p : * void , state : [ ] u8 ) {
at := 0 ;
( ( cast ( * SO_Body ) p ) ) . pos , _ = sim . state_get_vec2 ( state , * at ) ;
}

 so_valid :: ( p : * void , state : [ ] u8 , tick : sim . Tick ) -> bool {
return ( state ) . count == 8 ;
}

 so_valid_input :: ( p : * void , input : [ ] u8 , tick : sim . Tick ) -> bool {
return ( input ) . count == 1 && input [ 0 ] <= 5 ;
}

 so_sample :: ( p : * void , dst : [ ] u8 , tick : sim . Tick ) {

 e := ( cast ( * SO_Endpoint ) p ) ;
dst [ 0 ] = ( ifx e . node . reg . authoritative then e . server_motion else e . input ) ;

 }

 so_early :: ( p : * void , step : * sim . World_Step ) {

 sim . world_try_last_state ( step ) ;
( ( cast ( * SO_Body ) p ) ) . pos [0] += ( cast ( float32 ) ( step . input [ 0 ] ) ) ;

 }

 so_build :: ( p : * void , obj : * objects . Network_Object ) -> ( sim . System_Config , bool ) {

 b := objects . component_data ( obj , SO_Body , SO_TYPE ) ;
if b == null {
return .{

 } , false ;
} ;

 return .{
schema = 0x5000_0001 , state_size = 8 , input_size = 1 , carry_mask = view ( so_carry , 0 ) ,
callbacks = .{
user = b , input_user = p , capture = so_capture , restore = so_restore , validate_state = so_valid ,
validate_input = so_valid_input , sample_input = so_sample , early = so_early ,
} ,

 } , true ;

 } ;

 so_init :: ( e : * SO_Endpoint , authority : bool ) {

 rt_init ( * e . node , authority ) ;
objects . register_factory ( * e . node . reg , SO_TYPE , so_factory ) ;
assert ( sim . world_init ( * e . world , .{
authority = authority , fixed_dt = 0.01 , capacity = 64
} ) == . Ok ) ;
w := ( ifx authority then * e . node . r . server else * e . node . r . client ) ;
assert ( nr . bind_simulation ( w , * e . world ) ) ;
assert ( nr . register_world_component ( w , SO_TYPE , so_build , e ) ) ;

 } ;

 so_pos :: ( e : * SO_Endpoint , id : objects . Network_Id ) -> [ 2 ] float32 {

 obj , _ := objects . get ( * e . node . reg , id ) ;
{ b := objects . component_data ( obj , SO_Body , SO_TYPE ) ; if
b != null {
return b . pos ;
} }

 return .[
- 1 , - 1 ,
] ;


}

 //@endregion



 prediction_state_only_component_converges_for_remote_late_join_and_reconnect :: ( t : * Test ) {

 s , a , b , c : SO_Endpoint ;
so_init ( * s , true ) ;
so_init ( * a , false ) ;
so_init ( * b , false ) ;
so_init ( * c , false ) ;
nodes := ( * RT_Node ) .[ * s . node , * a . node , * b . node , * c . node ] ;
defer {

 rt_shutdown ( nodes ) ;
for e : ( ( * SO_Endpoint ) .[ * s , * a , * b , * c ] ) {
sim . world_destroy ( * e . world ) ;
}


}

 expect ( t , session . start_server ( * s . node . s , 0 ) ) ;
port := session . bound_port ( * s . node . s ) ;
expect ( t , session . start_client ( * a . node . s , "127.0.0.1" , port ) ) ;
expect ( t , session . start_client ( * b . node . s , "127.0.0.1" , port ) ) ;
rt_pump ( nodes , 80 ) ;
if ! expect ( t , a . node . s . client_authenticated && b . node . s . client_authenticated , "connected" ) {
return ;
}

 owned := objects . spawn ( * s . node . reg , a . node . s . client_server_id ) ;
array_add ( * owned . components , so_factory ( ) ) ;
server_owned := objects . spawn ( * s . node . reg , 0 ) ;
array_add ( * server_owned . components , so_factory ( ) ) ;

 // 运动中：远端（B）只靠模拟快照也能看到两个对象持续移动。

 a . input , s . server_motion = 1 , 2 ;
rt_pump ( nodes , 60 ) ;
moving_owned , moving_server := so_pos ( * b , owned . id ) , so_pos ( * b , server_owned . id ) ;
rt_pump ( nodes , 40 ) ;
expect ( t , so_pos ( * b , owned . id ) [0] > moving_owned [0] && so_pos ( * b , server_owned . id ) [0] > moving_server [0] , "remote display follows simulation state" ) ;
expect ( t , so_pos ( * a , owned . id ) [0] > 0 , "owner predicts locally" ) ;

 // 停止后三端完全一致（同一权威状态，未注册任何对象成员）。

 a . input , s . server_motion = 0 , 0 ;
rt_pump ( nodes , 120 ) ;
for id : ( objects . Network_Id .[ owned . id , server_owned . id ] ) {

 want := so_pos ( * s , id ) ;
expect ( t , want [0] > 0 , "server moved" ) ;
expect_value ( t , so_pos ( * a , id ) , want ) ;
expect_value ( t , so_pos ( * b , id ) , want ) ;

 }


// 迟加入与重连从完整世界种子拿到当前状态。

 expect ( t , session . start_client ( * c . node . s , "127.0.0.1" , port ) ) ;
session . disconnect_local ( * b . node . s ) ;
rt_pump ( nodes , 40 ) ;
expect ( t , session . stop_client ( * b . node . s ) ) ;
expect ( t , session . start_client ( * b . node . s , "127.0.0.1" , port ) ) ;
rt_pump ( nodes , 150 ) ;
for id : ( objects . Network_Id .[ owned . id , server_owned . id ] ) {

 want := so_pos ( * s , id ) ;
expect_value ( t , so_pos ( * c , id ) , want ) ;
expect_value ( t , so_pos ( * b , id ) , want ) ;

 }


}


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
