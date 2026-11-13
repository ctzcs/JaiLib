#scope_file
sim :: #import "thirdparty/onet/simulation" ;
#scope_export


//@region Single-system uses exactly the same world prediction implementation


world_single_system_authority_and_unconfirmed_tail_replay :: ( t : * Test ) {

 s , c : WX_Fixture ;
sw_init ( * s , true ) ;
sw_init ( * c , false ) ;
defer sim . world_destroy ( * s . world ) ;
defer sim . world_destroy ( * c . world ) ;
wx_seed ( t , * s , * c ) ;
s . a . gain = 2 ;
c . a . sample = .[
2 , 3 ,
] ;

 for tick : ( cast , trunc ( u64 ) ( 1 ) ) .. ( cast , trunc ( u64 ) ( 3 ) ) {
assert ( sim . world_step ( * c . world ) == . Ok ) ;
wx_input ( t , * s , * c , tick ) ;
}

 assert ( sim . world_step ( * s . world ) == . Ok ) ;
data , status := sim . world_encode_snapshot ( * s . world , 1 ) ;
assert ( status == . Ok ) ;
defer release ( data ) ;
assert ( sim . world_receive_snapshot ( * c . world , data ) == . Ok ) ;
replayed , corrected , result := sim . world_reconcile ( * c . world ) ;
expect ( t , result == . Ok && corrected && replayed == 2 && c . a . value == 8 && c . a . jumps == 9 ) ;
expect_value ( t , sim . world_receive_snapshot ( * c . world , data ) , . Duplicate ) ;
{ loop_index := 0 ; while loop_index < 2 { defer loop_index += 1 ;
assert ( sim . world_step ( * s . world ) == . Ok ) ;
} }

 wx_seed ( t , * s , * c ) ;
expect ( t , c . a . value == s . a . value && c . a . jumps == s . a . jumps ) ;

 }


world_single_matching_history_ring_reuse_does_not_replay_or_recapture_cached_tick :: ( t : * Test ) {

 s , c : WX_Fixture ;
sw_init ( * s , true , 1 , false , 4 ) ;
sw_init ( * c , false , 1 , false , 4 ) ;
defer sim . world_destroy ( * s . world ) ;
defer sim . world_destroy ( * c . world ) ;
wx_seed ( t , * s , * c ) ;
c . a . sample = .[
2 , 1 ,
] ;

 for tick : ( cast , trunc ( u64 ) ( 1 ) ) .. ( cast , trunc ( u64 ) ( 12 ) ) {

 assert ( sim . world_step ( * c . world ) == . Ok ) ;
wx_input ( t , * s , * c , tick ) ;
assert ( sim . world_step ( * s . world ) == . Ok ) ;
data , status := sim . world_encode_snapshot ( * s . world , tick ) ;
assert ( status == . Ok ) ;
assert ( sim . world_receive_snapshot ( * c . world , data ) == . Ok ) ;
release ( data ) ;
replayed , corrected , status2 := sim . world_reconcile ( * c . world ) ;
expect ( t , status2 == . Ok && ! corrected && replayed == 0 ) ;

 }

 expect ( t , c . a . value == 24 && c . a . jumps == 12 && c . replays == 0 ) ;
s . a . value = 999 ;
data , status := sim . world_encode_snapshot ( * s . world , 12 ) ;
assert ( status == . Ok ) ;
defer release ( data ) ;
assert ( sim . world_receive_snapshot ( * c . world , data ) == . Ok ) ;
_ , corrected , result := sim . world_reconcile ( * c . world ) ;
expect ( t , result == . Ok && ! corrected && c . a . value == 24 , "resend uses captured post-tick state, not later live writes" ) ;

 }


world_single_input_packet_every_truncation_rejects_without_queue_mutation :: ( t : * Test ) {

 s , c : WX_Fixture ;
sw_init ( * s , true ) ;
sw_init ( * c , false ) ;
defer sim . world_destroy ( * s . world ) ;
defer sim . world_destroy ( * c . world ) ;
wx_seed ( t , * s , * c ) ;
c . a . sample = .[
3 , 1 ,
] ;
assert ( sim . world_step ( * c . world ) == . Ok ) ;
data , status := sim . world_encode_input ( * c . world , 1 , 1 ) ;
assert ( status == . Ok ) ;
defer release ( data ) ;
{ cut := 0 ; while cut < ( data ) . count { defer cut += 1 ;

 expect ( t , sim . world_receive_input ( * s . world , 1 , view ( data , 0 , cut ) ) != . Ok && ( s . world . queued ) . count == 0 && s . a . value == 0 ) ;

 } } ;

 expect_value ( t , sim . world_receive_input ( * s . world , 2 , data ) , . Invalid_Data ) ;
expect_value ( t , sim . world_receive_input ( * s . world , 1 , data ) , . Ok ) ;
expect_value ( t , sim . world_receive_input ( * s . world , 1 , data ) , . Ok ) ;
expect_value ( t , ( s . world . queued ) . count , 1 ) ;
assert ( sim . world_step ( * s . world ) == . Ok ) ;
expect ( t , s . a . value == 3 && s . a . jumps == 1 ) ;
expect_value ( t , sim . world_receive_input ( * s . world , 1 , data ) , . Stale ) ;

 }


world_single_owner_transfer_clears_pending_inputs_and_rejects_old_incarnation :: ( t : * Test ) {

 f : WX_Fixture ;
sw_init ( * f , true ) ;
defer sim . world_destroy ( * f . world ) ;
assert ( sim . world_queue_input ( * f . world , 1 , 1 , 1 , 1 , u8 .[ 9 , 1 ] ) == . Ok ) ;
assert ( sim . world_set_owner ( * f . world , 1 , 2 , 2 ) ) ;
expect_value ( t , ( f . world . queued ) . count , 0 ) ;
expect_value ( t , sim . world_queue_input ( * f . world , 1 , 1 , 1 , 1 , u8 .[ 9 , 1 ] ) , . Invalid_Data ) ;
assert ( sim . world_step ( * f . world ) == . Ok ) ;
expect ( t , f . a . value == 0 && f . a . jumps == 0 ) ;
expect_value ( t , sim . world_queue_input ( * f . world , 2 , 1 , 2 , 2 , u8 .[ 2 , 0 ] ) , . Ok ) ;
assert ( sim . world_step ( * f . world ) == . Ok ) ;
expect_value ( t , f . a . value , ( cast , trunc ( u64 ) ( 2 ) ) ) ;

 }


world_single_input_future_size_validation_and_application_refusal_are_transactional :: ( t : * Test ) {

 f : WX_Fixture ;
sw_init ( * f , true , 1 , false , 4 ) ;
defer sim . world_destroy ( * f . world ) ;
expect_value ( t , sim . world_queue_input ( * f . world , 1 , 1 , 4 , 1 , u8 .[ 1 , 0 ] ) , . Out_Of_Order ) ;
expect_value ( t , sim . world_queue_input ( * f . world , 1 , 1 , 1 , 1 , u8 .[ 11 , 0 ] ) , . Invalid_Data ) ;
expect_value ( t , sim . world_queue_input ( * f . world , 1 , 1 , 1 , 1 , u8 .[ 1 ] ) , . Invalid_Data ) ;
expect_value ( t , ( f . world . queued ) . count , 0 ) ;
for tick : ( cast , trunc ( u64 ) ( 1 ) ) .. ( cast , trunc ( u64 ) ( 3 ) ) {
assert ( sim . world_queue_input ( * f . world , 1 , 1 , tick , 1 , u8 .[ 1 , 0 ] ) == . Ok ) ;
}

 expect_value ( t , ( f . world . queued ) . count , 3 ) ;
assert ( sim . world_step ( * f . world ) == . Ok ) ;
expect ( t , f . a . value == 1 && ( f . world . queued ) . count == 2 ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
