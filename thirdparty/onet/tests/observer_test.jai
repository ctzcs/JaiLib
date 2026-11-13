#scope_file
sim :: #import "thirdparty/onet/simulation" ;
#scope_export


//@region Observer strategy uses the same world scheduler and history

 sw_init :: ( f : * WX_Fixture , authority : bool , owner : u32 = 1 , observer := false , capacity := 8 ) {

 assert ( sim . world_init ( * f . world , .{
authority = authority , local_owner = 1 , fixed_dt = 0.02 , capacity = capacity
} , .{
user = f , physics = wx_physics , event = wx_event , replay_mode = wx_mode
} ) == . Ok ) ;
f . a . gain = 1 ;
assert ( wx_register ( f , * f . a , 1 , owner , observer ) == . Ok ) ;

 } ;


world_observer_default_and_explicit_selective_carry_remain_distinct :: ( t : * Test ) {

 s , c : WX_Fixture ;
sw_init ( * s , true , 2 ) ;
sw_init ( * c , false , 2 , true ) ;
defer sim . world_destroy ( * s . world ) ;
defer sim . world_destroy ( * c . world ) ;
assert ( sim . world_queue_input ( * s . world , 2 , 1 , 1 , 1 , u8 .[ 3 , 1 ] ) == . Ok ) ;
assert ( sim . world_step ( * s . world ) == . Ok ) ;
wx_seed ( t , * s , * c ) ;
assert ( sim . world_step ( * c . world ) == . Ok ) ;
expect ( t , c . a . value == 3 && c . a . jumps == 1 , "missing default does not repeat the last movement or jump" ) ;
c . a . carry = true ;
assert ( sim . world_step ( * c . world ) == . Ok ) ;
expect ( t , c . a . value == 6 && c . a . jumps == 1 , "selective carry excludes one-shot jump" ) ;
c . a . hold_all = true ;
assert ( sim . world_step ( * c . world ) == . Ok ) ;
expect ( t , c . a . value == 9 && c . a . jumps == 2 ) ;

 }


world_observer_authority_replay_and_silence_bound_use_one_history :: ( t : * Test ) {

 s , c : WX_Fixture ;
sw_init ( * s , true , 2 ) ;
sw_init ( * c , false , 2 , true , 4 ) ;
defer sim . world_destroy ( * s . world ) ;
defer sim . world_destroy ( * c . world ) ;
assert ( sim . world_queue_input ( * s . world , 2 , 1 , 1 , 1 , u8 .[ 2 , 1 ] ) == . Ok ) ;
assert ( sim . world_step ( * s . world ) == . Ok ) ;
wx_seed ( t , * s , * c ) ;
c . a . carry = true ;
{ loop_index := 0 ; while loop_index < 3 { defer loop_index += 1 ;
assert ( sim . world_step ( * c . world ) == . Ok ) ;
} }

 expect_value ( t , sim . world_step ( * c . world ) , . Need_Resync ) ;
before := c . a . value ;
old , status := sim . world_encode_snapshot ( * s . world , 1 ) ;
assert ( status == . Ok ) ;
defer release ( old ) ;
expect_value ( t , sim . world_receive_snapshot ( * c . world , old ) , . Ok ) ;
_ , _ , status = sim . world_reconcile ( * c . world ) ;
expect ( t , status == . Ok && ! c . world . needs_full && c . world . tick == 1 && c . a . value <= before ) ;
// Repeated receipt cannot restart a second time without a newer snapshot.

 expect_value ( t , sim . world_receive_snapshot ( * c . world , old ) , . Duplicate ) ;
{ loop_index := 0 ; while loop_index < 3 { defer loop_index += 1 ;
assert ( sim . world_step ( * c . world ) == . Ok ) ;
} } ;

 expect_value ( t , sim . world_step ( * c . world ) , . Need_Resync ) ;
expect_value ( t , sim . world_receive_snapshot ( * c . world , old ) , . Duplicate ) ;
expect_value ( t , sim . world_step ( * c . world ) , . Need_Resync ) ;

 }


world_observer_can_disable_prediction_and_never_gain_foreign_input_authority :: ( t : * Test ) {

 s , readonly , predicted : WX_Fixture ;
sw_init ( * s , true , 2 ) ;
sw_init ( * readonly , false , 2 ) ;
sw_init ( * predicted , false , 2 , true ) ;
defer sim . world_destroy ( * s . world ) ;
defer sim . world_destroy ( * readonly . world ) ;
defer sim . world_destroy ( * predicted . world ) ;
assert ( sim . world_queue_input ( * s . world , 2 , 1 , 1 , 1 , u8 .[ 4 , 0 ] ) == . Ok ) ;
assert ( sim . world_step ( * s . world ) == . Ok ) ;
wx_seed ( t , * s , * readonly ) ;
wx_seed ( t , * s , * predicted ) ;
readonly . a . carry , predicted . a . carry = true , true ;
assert ( sim . world_step ( * readonly . world ) == . Ok && sim . world_step ( * predicted . world ) == . Ok ) ;
expect ( t , readonly . a . value == 4 && predicted . a . value == 8 ) ;
expect_value ( t , sim . world_queue_input ( * s . world , 1 , 1 , 2 , 1 , u8 .[ 9 , 0 ] ) , . Invalid_Data ) ;
expect ( t , ( s . world . queued ) . count == 0 , "observer_prediction is not upload authority" ) ;
assert ( sim . world_set_observer_prediction ( * readonly . world , 1 , true ) ) ;
wx_seed ( t , * s , * readonly ) ;
assert ( sim . world_step ( * readonly . world ) == . Ok ) ;
expect_value ( t , readonly . a . value , ( cast , trunc ( u64 ) ( 8 ) ) ) ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted.      
