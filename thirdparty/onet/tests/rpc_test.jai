#scope_file
objects :: #import "thirdparty/onet/objects" ;
rpc :: #import "thirdparty/onet/rpc" ;
transport :: #import "thirdparty/onet/transport" ;
wire :: #import "thirdparty/onet/wire" ;
#scope_export


Rpc_Output :: struct {
to : transport . Connection_Id ;
channel : transport . Channel ;
data : [ ] u8 ;
}

 Rpc_Harness :: struct {

 outputs : [ .. ] Rpc_Output ;

 observers : [ .. ] transport . Connection_Id ;

 calls : [ .. ] u8 ;

 senders : [ .. ] transport . Connection_Id ;


}

 rpc_harness_destroy :: ( h : * Rpc_Harness ) {

 for output : h . outputs {
release ( output . data ) ;
}

 release ( h . outputs ) ;
release ( h . observers ) ;
release ( h . calls ) ;
release ( h . senders ) ;

 }

 rpc_harness_send :: ( data : * void , to : transport . Connection_Id , channel : transport . Channel , payload : [ ] u8 ) -> bool {

 h := ( cast ( * Rpc_Harness ) data ) ;
array_add ( * h . outputs , Rpc_Output .{
to , channel , wire . clone ( payload )
} ) ;
return true ;

 } ;

 rpc_harness_observed :: ( data : * void , obj : * objects . Network_Object , id : transport . Connection_Id ) -> bool {

 h := ( cast ( * Rpc_Harness ) data ) ;
for observer : h . observers {

 if observer == id {
return true ;
}


}

 return false ;

 }

 rpc_harness_connections :: ( data : * void ) -> [ ] transport . Connection_Id {

 return view((cast(*Rpc_Harness)data).observers,0) ;

 }

 rpc_harness_handler :: ( ctx : * rpc . Context , payload : [ ] u8 ) {

 h := ( cast ( * Rpc_Harness ) ctx . manager . userdata ) ;
if ( payload ) . count > 0 {

 array_add ( * h . calls , payload [ 0 ] ) ;
if payload [ 0 ] == 0xCC {
ctx . cancel_relay = true ;
}

 if payload [ 0 ] == 0xAA {

 value := u8 .[ 0xBB ] ;
rpc . amend ( ctx , view ( value , 0 ) ) ;

 }


}

 array_add ( * h . senders , ctx . sender ) ;

 }

 rpc_harness_init :: ( m : * rpc . Manager , reg : * objects . Registry , h : * Rpc_Harness , authority : bool ) {

 objects . registry_init ( reg , authority ) ;
rpc . init ( m , reg , authority ) ;
m . userdata = h ;
m . send = rpc_harness_send ;
m . is_observer = rpc_harness_observed ;
m . connections = rpc_harness_connections ;
m . server_connection = 7 ;
rpc . register ( m , 1 , rpc_harness_handler ) ;

 }

 rpc_deliver_call :: ( m : * rpc . Manager , from : transport . Connection_Id , call : rpc . Call , channel : transport . Channel = . Reliable ) -> bool {

 copy_call := call ;
data , ok := rpc . encode ( * copy_call ) ;
defer release ( data ) ;
return ok && rpc . receive ( m , from , channel , data ) ;

 }



 rpc_permissions_origin_rewrite_and_replay_suppression :: ( t : * Test ) {

 reg : objects . Registry ;
m : rpc . Manager ;
h : Rpc_Harness ;
rpc_harness_init ( * m , * reg , * h , true ) ;
defer objects . registry_destroy ( * reg ) ;
defer rpc . destroy ( * m ) ;
defer rpc_harness_destroy ( * h ) ;
array_add ( * h . observers , 1 , 2 ) ;
obj := objects . spawn ( * reg , 1 ) ;
payload := u8 .[ 42 ] ;
call := rpc . Call .{
sequence = 1 , id = 1 , object = obj . id , target = . Observers , payload = view ( payload , 0 ) ,
} ;

 expect ( t , rpc_deliver_call ( * m , 1 , call ) ) ;
expect_value ( t , ( h . outputs ) . count , 1 ) ;
expect_value ( t , h . outputs [ 0 ] . to , 2 ) ;
forwarded , valid := rpc . decode ( h . outputs [ 0 ] . data ) ;
defer release ( forwarded . payload ) ;
expect ( t , valid ) ;
expect_value ( t , forwarded . origin , 1 ) ;
expect_value ( t , h . senders [ 0 ] , 1 ) ;
call . sequence = 2 ;
call . origin = 99 ;
expect ( t , ! rpc_deliver_call ( * m , 1 , call ) , "forged origin" ) ;
call . origin = 0 ;
call . target = . Server ;
expect ( t , ! rpc_deliver_call ( * m , 2 , call ) , "noncontroller denied" ) ;
rpc . register ( * m , 1 , rpc_harness_handler , . Any_Observer ) ;
expect ( t , rpc_deliver_call ( * m , 2 , call ) ) ;
call . sequence = 3 ;
expect ( t , ! rpc_deliver_call ( * m , 3 , call ) , "nonobserver denied even with AnyObserver" ) ;
m . replaying = true ;
expect ( t , ! rpc . send ( * m , 1 , obj . id , . Observers , view ( payload , 0 ) ) ) ;

 }



 rpc_relay_cancel_and_amend :: ( t : * Test ) {

 reg : objects . Registry ;
m : rpc . Manager ;
h : Rpc_Harness ;
rpc_harness_init ( * m , * reg , * h , true ) ;
defer objects . registry_destroy ( * reg ) ;
defer rpc . destroy ( * m ) ;
defer rpc_harness_destroy ( * h ) ;
array_add ( * h . observers , 1 , 2 ) ;
obj := objects . spawn ( * reg , 1 ) ;
cancel := u8 .[ 0xCC ] ;
call := rpc . Call .{
sequence = 1 , id = 1 , object = obj . id , target = . Observers , payload = view ( cancel , 0 ) ,
} ;

 expect ( t , rpc_deliver_call ( * m , 1 , call ) ) ;
expect_value ( t , ( h . outputs ) . count , 0 ) ;
changed := u8 .[ 0xAA ] ;
call . sequence = 2 ;
call . payload = view ( changed , 0 ) ;
expect ( t , rpc_deliver_call ( * m , 1 , call ) ) ;
forwarded , valid := rpc . decode ( h . outputs [ 0 ] . data ) ;
defer release ( forwarded . payload ) ;
expect ( t , valid ) ;
expect_value ( t , forwarded . payload [ 0 ] , 0xBB ) ;

 }



 rpc_reliable_wait_preserves_order_and_deduplicates :: ( t : * Test ) {

 reg : objects . Registry ;
m : rpc . Manager ;
h : Rpc_Harness ;
rpc_harness_init ( * m , * reg , * h , false ) ;
defer objects . registry_destroy ( * reg ) ;
defer rpc . destroy ( * m ) ;
defer rpc_harness_destroy ( * h ) ;
first := u8 .[ 1 ] ;
second := u8 .[ 2 ] ;
call := rpc . Call .{
sequence = 1 , tick = 10 , id = 1 , object = 1 , target = . Observers , payload = view ( first , 0 ) ,
} ;

 expect ( t , rpc_deliver_call ( * m , 7 , call ) ) ;
objects . spawn ( * reg , 0 ) ;
objects . spawn ( * reg , 0 ) ;
call . sequence = 2 ;
call . object = 2 ;
call . payload = view ( second , 0 ) ;
expect ( t , rpc_deliver_call ( * m , 7 , call ) ) ;
expect_value ( t , ( h . calls ) . count , 0 ) ;
rpc . update ( * m , 1 ) ;
expect_value ( t , ( h . calls ) . count , 2 ) ;
expect_value ( t , h . calls [ 0 ] , 1 ) ;
expect_value ( t , h . calls [ 1 ] , 2 ) ;
expect ( t , rpc_deliver_call ( * m , 7 , call ) ) ;
expect_value ( t , ( h . calls ) . count , 2 ) ;

 }



 rpc_unknown_expiry_state_evidence_and_limits :: ( t : * Test ) {

 reg : objects . Registry ;
m : rpc . Manager ;
h : Rpc_Harness ;
rpc_harness_init ( * m , * reg , * h , false ) ;
defer objects . registry_destroy ( * reg ) ;
defer rpc . destroy ( * m ) ;
defer rpc_harness_destroy ( * h ) ;
payload := u8 .[ 1 ] ;
call := rpc . Call .{
sequence = 1 , tick = 10 , id = 1 , object = 50 , target = . Observers , payload = view ( payload , 0 ) ,
} ;

 expect ( t , ! rpc_deliver_call ( * m , 8 , call ) , "only bound authority accepted" ) ;
expect ( t , rpc_deliver_call ( * m , 7 , call , . Unreliable ) ) ;
rpc . update ( * m , 101 ) ;
expect_value ( t , ( m . pending ) . count , 0 ) ;
call . sequence = 2 ;
expect ( t , rpc_deliver_call ( * m , 7 , call ) ) ;
m . max_pending = 1 ;
call . sequence = 3 ;
expect ( t , ! rpc_deliver_call ( * m , 7 , call ) ) ;
m . has_state = true ;
m . state_tick = 10 ;
rpc . update ( * m , 1 ) ;
expect_value ( t , ( m . pending ) . count , 0 ) ;

 }


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
