#scope_file
core :: #import "thirdparty/onet/core" ;
o :: #import "thirdparty/onet/objects" ;
transport :: #import "thirdparty/onet/transport" ;
#scope_export


//@region Member write authorization and schema transactions

 CONTROL_TYPE :: ( cast ( o . Component_Type_Id ) ( 8101 ) ) ;
Control_State :: struct {
health : s32 ;
enabled : bool ;
}

 control_factory :: ( ) -> * o . Component {

 st := new_one ( Control_State ) ;
st . health = 7 ;
comp := o . component_make ( CONTROL_TYPE ) ;
comp . userdata = st ;
comp . destroy_userdata = ( p : * void ) {
free ( p ) ;
}

 o . member_i32 ( comp , * st . health ) ;
o . member_bool ( comp , * st . enabled ) ;
return comp ;

 }

 control_observer :: ( obj : * o . Network_Object , from : transport . Connection_Id , p : * void ) -> bool {
return from == 2 ;
}

 control_reject :: ( obj : * o . Network_Object , from : transport . Connection_Id , component , member : int , data : [ ] u8 ) -> bool {
return false ;
}

 control_never_validate :: ( obj : * o . Network_Object , from : transport . Connection_Id , component , member : int , data : [ ] u8 ) -> bool {
panic ( "validator ran before authorization/schema/decode checks" ) ;
return false;
}

 control_validate :: ( obj : * o . Network_Object , from : transport . Connection_Id , component , member : int , data : [ ] u8 ) -> bool {

 st := ( cast ( * Control_State ) obj . components [ component ] . userdata ) ;
r : core . Reader ;
core . reader_init ( * r , data ) ;
value := core . read_int32 ( * r , . Loose ) ;
return st . health == 7 && value == 10 && from == 2 && member == 0 ;

 }



 control_member_write_rejections_are_transactional :: ( t : * Test ) {

 reg : o . Registry ;
o . registry_init ( * reg ) ;
defer o . registry_destroy ( * reg ) ;
o . register_factory ( * reg , CONTROL_TYPE , control_factory ) ;
obj := o . spawn ( * reg , 2 ) ;
comp := control_factory ( ) ;
array_add ( * obj . components , comp ) ;
st := ( cast ( * Control_State ) comp . userdata ) ;
comp . members [ 0 ] . dirty = true ;
comp . members [ 0 ] . ever_sent = true ;
comp . members [ 0 ] . last_i32 = 6 ;
w : core . Writer ;
core . writer_init ( * w ) ;
defer core . writer_destroy ( * w ) ;
core . write_int32 ( * w , 10 , . Loose ) ;
encoded := core . writer_to_array ( * w ) ;
defer release ( encoded ) ;
// No observer policy means clients are denied, including the owner.

 expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
reg . is_observer = ( obj : * o . Network_Object , from : transport . Connection_Id , p : * void ) -> bool {
return false ;
}

 expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
reg . is_observer = control_observer ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 1 , 0 , 0 , encoded , control_never_validate ) ) ;
for index : ( int .[ - 1 , 2 , 99 ] ) {

 expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , index , 0 , encoded , control_never_validate ) ) ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , index , encoded , control_never_validate ) ) ;

 }

 expect ( t , ! o . apply_member_write ( * reg , 999 , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
reg . authoritative = false ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
reg . authoritative = true ;
o . register_factory ( * reg , CONTROL_TYPE , null ) ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
o . register_factory ( * reg , CONTROL_TYPE , ( ) -> * o . Component {
return null
; } ) ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
o . register_factory ( * reg , CONTROL_TYPE , ( ) -> * o . Component {

 wrong := control_factory ( ) ;
wrong . type_id += 1 ;
return wrong

 ; } ) ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
o . register_factory ( * reg , CONTROL_TYPE , control_factory ) ;
{ n := 0 ; while n < ( encoded ) . count { defer n += 1 ;

 expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , view ( encoded , 0 , n ) , control_never_validate ) && st . health == 7 ) ;

 } }

 extra := new_slice ( u8 , ( encoded ) . count + 1 ) ;
defer release ( extra ) ;
copy_samples ( extra , encoded ) ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , extra , control_never_validate ) && st . health == 7 ) ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_reject ) && st . health == 7 ) ;
// Same member count is insufficient: kind, bit-exact accuracy, custom schema

 // and even an unrelated member in the live component must match the factory.

 saved := comp . members [ 0 ] ;
comp . members [ 0 ] . kind = . F32 ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
comp . members [ 0 ] = saved ;
comp . members [ 0 ] . accuracy = 0.25 ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
comp . members [ 0 ] = saved ;
comp . members [ 0 ] . accuracy = bit_cast ( float32 , ( cast , trunc ( u32 ) ( 0x80000000 ) ) ) ; // -0 is a different wire schema bit pattern.

 expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
comp . members [ 0 ] = saved ;
comp . members [ 1 ] . codec . schema = 8109 ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
comp . members [ 1 ] . codec . schema = 0 ;
expect ( t , st . health == 7 && ! st . enabled && comp . members [ 0 ] . dirty && comp . members [ 0 ] . ever_sent && comp . members [ 0 ] . last_i32 == 6 ) ;
expect ( t , o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_validate ) && st . health == 10 ) ;
// Server writes need no observer; server-owned objects are never writable by clients.

 expect ( t , o . set_controller ( * reg , obj . id , o . SERVER_OWNED ) ) ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , 2 , 0 , 0 , encoded , control_never_validate ) ) ;
reg . is_observer = null ;
expect ( t , o . apply_member_write ( * reg , obj . id , o . SERVER_OWNED , 0 , 0 , encoded ) ) ;
expect ( t , o . despawn ( * reg , obj . id ) ) ;
expect ( t , ! o . apply_member_write ( * reg , obj . id , o . SERVER_OWNED , 0 , 0 , encoded , control_never_validate ) ) ;

 }

 //@endregion


//@region Reconnect leases use verified account identities, never connection ids


control_retention_identity_generation_expiry_and_consumption :: ( t : * Test ) {

 reg : o . Registry ;
o . registry_init ( * reg ) ;
defer o . registry_destroy ( * reg ) ;
obj := o . spawn ( * reg , 11 ) ;
token , ok := o . retain_controller ( * reg , obj . id , "account:alice" , 100 , 50 ) ;
expect ( t , ok && obj . owner == o . SERVER_OWNED ) ;
expect ( t , ! o . claim_controller ( * reg , token , 12 , "account:bob" , 110 ) ) ;
expect ( t , ! o . claim_controller ( * reg , token , 0 , "account:alice" , 110 ) ) ;
expect ( t , ! o . claim_controller ( * reg , .{
token . object , token . generation + 1
} , 12 , "account:alice" , 110 ) ) ;
expect ( t , ! o . claim_controller ( * reg , .{
token . object , 0
} , 12 , "account:alice" , 110 ) ) ;
expect ( t , ! o . claim_controller ( * reg , .{
999 , token . generation
} , 12 , "account:alice" , 110 ) ) ;
expect ( t , obj . owner == o . SERVER_OWNED && table_get ( * reg . retained , obj . id ) . generation == token . generation ) ;
// A different connection with the same verified account can reconnect.

 expect ( t , o . claim_controller ( * reg , token , 99 , "account:alice" , 149 ) && obj . owner == 99 ) ;
expect ( t , table_get ( * reg . retained , obj . id ) . generation == 0 && table_get ( * reg . retained , obj . id ) . identity == "" ) ;
expect ( t , ! o . claim_controller ( * reg , token , 100 , "account:alice" , 149 ) ) ;
expect ( t , o . set_controller ( * reg , obj . id , o . SERVER_OWNED ) ) ;
expect ( t , ! o . claim_controller ( * reg , token , 100 , "account:alice" , 149 ) ) ;
expired , retained := o . retain_controller ( * reg , obj . id , "account:alice" , 200 , 10 ) ;
expect ( t , retained && ! o . claim_controller ( * reg , expired , 12 , "account:alice" , 210 ) ) ;
o . expire_retained ( * reg , 209 ) ;
expect ( t , table_get ( * reg . retained , obj . id ) . generation == expired . generation ) ;
o . expire_retained ( * reg , 210 ) ;
expect ( t , table_get ( * reg . retained , obj . id ) . generation == 0 && table_get ( * reg . retained , obj . id ) . identity == "" ) ;
o . expire_retained ( * reg , 999 ) ; // idempotent

 expect ( t , ! o . claim_controller ( * reg , expired , 12 , "account:alice" , 205 ) ) ;

 } ;



 control_retention_replacement_handoff_and_destroy :: ( t : * Test ) {

 reg : o . Registry ;
o . registry_init ( * reg ) ;
defer o . registry_destroy ( * reg ) ;
obj := o . spawn ( * reg , 11 ) ;
old , ok := o . retain_controller ( * reg , obj . id , "account:alice" , 0 , 100 ) ;
expect ( t , ok ) ;
// The caller may borrow the old record's identity during renewal.

 current , renewed := o . retain_controller ( * reg , obj . id , table_get ( * reg . retained , obj . id ) . identity , 1 , 100 ) ;
expect ( t , renewed && current . generation != old . generation && table_get ( * reg . retained , obj . id ) . identity == "account:alice" ) ;
expect ( t , ! o . claim_controller ( * reg , old , 12 , "account:alice" , 2 ) ) ;
expect ( t , ! o . set_controller ( * reg , obj . id , 12 , 11 ) ) ;
expect ( t , table_get ( * reg . retained , obj . id ) . generation == current . generation ) ;
expect ( t , o . set_controller ( * reg , obj . id , 12 ) ) ;
expect ( t , table_get ( * reg . retained , obj . id ) . generation == 0 ) ;
expect ( t , o . set_controller ( * reg , obj . id , o . SERVER_OWNED ) ) ;
expect ( t , ! o . claim_controller ( * reg , current , 13 , "account:alice" , 2 ) , "handoff then server return must not revive an old lease" ) ;
dead , retained := o . retain_controller ( * reg , obj . id , "account:alice" , 3 , 100 ) ;
expect ( t , retained && o . despawn ( * reg , obj . id ) ) ;
expect ( t , ! o . claim_controller ( * reg , dead , 13 , "account:alice" , 4 ) ) ;
_ , after_destroy := o . retain_controller ( * reg , obj . id , "account:alice" , 4 , 100 ) ;
expect ( t , ! after_destroy ) ;
o . expire_retained ( * reg , 4 ) ;
expect ( t , table_get ( * reg . retained , obj . id ) . generation == 0 ) ;
// expire also purges a record whose object was handed away outside the API.

 other := o . spawn ( * reg , 1 ) ;
_ , other_ok := o . retain_controller ( * reg , other . id , "account:bob" , 4 , 100 ) ;
expect ( t , other_ok ) ;
other . owner = 2 ;
o . expire_retained ( * reg , 5 ) ;
expect ( t , table_get ( * reg . retained , other . id ) . generation == 0 ) ;

 }



 control_retention_rejects_invalid_limits_and_authority :: ( t : * Test ) {

 reg : o . Registry ;
o . registry_init ( * reg ) ;
defer o . registry_destroy ( * reg ) ;
obj := o . spawn ( * reg , 1 ) ;
for duration : ( int .[ - 1 , 0 , 24 * 60 * 60 * 1000 + 1 ] ) {

 _ , ok := o . retain_controller ( * reg , obj . id , "account" , 0 , duration ) ;
expect ( t , ! ok && obj . owner == 1 && reg . next_retention == 1 ) ;

 }

 _ , empty := o . retain_controller ( * reg , obj . id , "" , 0 , 1 ) ;
_ , overflow := o . retain_controller ( * reg , obj . id , "account" , ( cast , trunc ( s64 ) ( 9223372036854775807 ) ) , 1 ) ;
long_identity := new_slice ( u8 , 257 ) ;
defer release ( long_identity ) ;
_ , oversized := o . retain_controller ( * reg , obj . id , ( cast ( string ) ( long_identity ) ) , 0 , 1 ) ;
expect ( t , ! empty && ! overflow && ! oversized && obj . owner == 1 ) ;
token , ok := o . retain_controller ( * reg , obj . id , "account" , 0 , 1 ) ;
expect ( t , ok ) ;
reg . authoritative = false ;
_ , denied := o . retain_controller ( * reg , obj . id , "account" , 0 , 1 ) ;
expect ( t , ! denied && ! o . claim_controller ( * reg , token , 2 , "account" , 0 ) ) ;
reg . authoritative = true ;
reg . next_retention = 0 ;
_ , exhausted := o . retain_controller ( * reg , obj . id , "account" , 0 , 1 ) ;
expect ( t , ! exhausted && table_get ( * reg . retained , obj . id ) . generation == token . generation ) ;

 }



 control_retention_accepts_maximum_valid_boundaries :: ( t : * Test ) {

 reg : o . Registry ;
o . registry_init ( * reg ) ;
defer o . registry_destroy ( * reg ) ;
obj := o . spawn ( * reg , 1 ) ;
identity := new_slice ( u8 , 256 ) ;
defer release ( identity ) ;
for * x : identity {
x.* = #char "a" ;
}

 duration := 24 * 60 * 60 * 1000 ;
reg . next_retention = ( cast , trunc ( u64 ) ( 18446744073709551615 ) ) ;
token , ok := o . retain_controller ( * reg , obj . id , ( cast ( string ) ( identity ) ) , ( cast , trunc ( s64 ) ( 9223372036854775807 ) ) - ( cast , trunc ( s64 ) ( duration ) ) , duration ) ;
expect ( t , ok && token . generation == ( cast , trunc ( u64 ) ( 18446744073709551615 ) ) && reg . next_retention == 0 && table_get ( * reg . retained , obj . id ) . expires_ms == ( cast , trunc ( s64 ) ( 9223372036854775807 ) ) ) ;
_ , exhausted := o . retain_controller ( * reg , obj . id , "new" , 0 , 1 ) ;
expect ( t , ! exhausted && table_get ( * reg . retained , obj . id ) . generation == token . generation ) ;
expect ( t , o . claim_controller ( * reg , token , 2 , ( cast ( string ) ( identity ) ) , ( cast , trunc ( s64 ) ( 9223372036854775807 ) ) - 1 ) && obj . owner == 2 ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
