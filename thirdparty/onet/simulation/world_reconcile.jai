#scope_file

 #scope_export

 //@region 整世界原子恢复、冻结与回放

 world_restore_record :: ( s : * World_System , frame : * World_Frame ) {

 s . config . callbacks . restore ( s . config . callbacks . user , view ( frame . state , s . state_offset , s . state_offset + s . config . state_size ) ) ;

 }

 world_seed :: ( w : * Simulation_World , source : * World_Frame ) {

 world_clear_inputs ( w ) ;
for * frame : w . history {
frame .* . valid = false ;
}

 for s , i : w . systems {

 world_restore_record ( s , source ) ;
start , end := s . input_offset , s . input_offset + s . config . input_size ;
if source . meta [ i ] . missing {
copy_samples ( view ( w . last_input , start , end ) , view ( source . last , start , end ) ) ;
s . last_tick = source . meta [ i ] . last_tick ;
}

 else {
copy_samples ( view ( w . last_input , start , end ) , view ( source . input , start , end ) ) ;
s . last_tick = source . meta [ i ] . controller_tick ;
}


}

 copy_samples ( w . current_input , source . input ) ;
w . tick , w . needs_full = source . tick , false ;
f := world_capture_frame ( w , w . tick ) ;
copy_samples ( f . state , source . state ) ;
copy_samples ( f . input , source . input ) ;
copy_samples ( f . last , source . last ) ;
copy_samples ( f . meta , source . meta ) ;
world_notify ( w , . Full_Reset , 0 , w . tick ) ;

 }

 // 收包只排队；在Reconcile阶段、固定模拟前调用一次，使用本批最新权威基态。

 world_reconcile :: ( w : * Simulation_World ) -> ( replayed : int , corrected : bool , status : Status ) {

 if ! w . initialized || w . config . authority || w . busy {
return 0 , false , . Not_Ready ;
}

 if ! w . pending . valid {
return 0 , false , . Empty ;
}

 w . busy = true ;
defer w . busy = false ;
defer world_frame_destroy ( w , * w . pending ) ;
p := * w . pending ;
base := world_frame ( w , p . tick ) ;
needs_seed := w . needs_full || p . tick > w . tick || base == null ;
if ! needs_seed && w . tick - p . tick > ( cast , trunc ( u64 ) ( w . config . max_replay_ticks ) ) {
needs_seed = true ;
}

 if ! needs_seed {

 { tick := p . tick + 1 ; while tick <= w . tick { defer tick += 1 ;

 if world_frame ( w , tick ) == null {
needs_seed = true ;
break ;
}


} }


}

 if needs_seed {

 world_seed ( w , p ) ;
w . applied_tick , w . correction_serial = p . tick , max ( w . correction_serial , w . pending_correction ) ;
return 0 , true , . Ok ;

 }

 changed := new_slice ( bool , ( w . systems ) . count , w . allocator ) ;
defer release ( changed , w . allocator ) ;
for s , i : w . systems {

 if ! world_predicted ( w , s ) {
continue ;
}

 a := view ( base . state , s . state_offset , s . state_offset + s . config . state_size ) ;
b := view ( p . state , s . state_offset , s . state_offset + s . config . state_size ) ;
equal := true ;
{ cb := s . config . callbacks . equal ; if
cb != null {
equal = cb ( s . config . callbacks . user , a , b ) ;
}

 else {
for byte , j : a {
if byte != b [ j ] {
equal = false ;
break ;
}

 }

 } }

 changed [ i ] = ! equal ;
corrected = corrected || ! equal ;

 }

 // 保存权威基态供后续整世界恢复，不改变预测显示的最新状态。

 copy_samples ( base . state , p . state ) ;
copy_samples ( base . input , p . input ) ;
copy_samples ( base . last , p . last ) ;
copy_samples ( base . meta , p . meta ) ;
if corrected {

 { cb := w . callbacks . replay_mode ; if
cb != null {
cb ( w . callbacks . user , true ) ;
} }

 defer {
{ cb := w . callbacks . replay_mode ; if
cb != null {
cb ( w . callbacks . user , false ) ;
} }

 }

 latest := new_slice ( u8 , w . state_size , w . allocator ) ;
defer release ( latest , w . allocator ) ;
for s , i : w . systems {

 if ! world_predicted ( w , s ) {

 s . config . callbacks . capture ( s . config . callbacks . user , view ( latest , s . state_offset , s . state_offset + s . config . state_size ) ) ;
{ cb := s . config . callbacks . hold ; if
cb != null {
cb ( s . config . callbacks . user , true ) ;
} }


}

 world_restore_record ( s , p ) ; // 先恢复全部系统，然后任何系统才可模拟。

 if changed [ i ] {
world_notify ( w , . Reconcile , s . config . id , p . tick ) ;
}


}

 world_notify ( w , . Replay_Starting , 0 , p . tick ) ;
{ tick := p . tick + 1 ; while tick <= w . tick { defer tick += 1 ;

 f := world_frame ( w , tick ) ;
for s , i : w . systems {

 cfg := * s . config ;
m := f . meta [ i ] ;
start , end := s . input_offset , s . input_offset + cfg . input_size ;
w . steps [ i ] = .{
world = w , system = cfg . id , tick = tick , controller_tick = m . controller_tick , last_tick = m . last_tick , dt = w . config . fixed_dt , missing = m . missing , estimated = m . estimated , replay = true , input = view ( f . input , start , end ) , last = view ( f . last , start , end ) , defaults = cfg . defaults , carry_mask = cfg . carry_mask ,
} ;


}

 world_run_phases ( w , f , true ) ;
for s , i : w . systems {

 if f . meta [ i ] . predicted {
s . config . callbacks . capture ( s . config . callbacks . user , view ( f . state , s . state_offset , s . state_offset + s . config . state_size ) ) ;
}


}

 replayed += 1 ;

 } }

 for s : w . systems {

 if ! world_predicted ( w , s ) {

 s . config . callbacks . restore ( s . config . callbacks . user , view ( latest , s . state_offset , s . state_offset + s . config . state_size ) ) ;
{ cb := s . config . callbacks . hold ; if
cb != null {
cb ( s . config . callbacks . user , false ) ;
} }


} else {
world_notify ( w , . Corrected , s . config . id , w . tick ) ;
}


}

 world_notify ( w , . Replay_Completed , 0 , w . tick ) ;

 }

 for s , i : w . systems {

 if s . config . owner == w . config . local_owner {
continue ;
}

 start , end := s . input_offset , s . input_offset + s . config . input_size ;
if ! p . meta [ i ] . missing {
copy_samples ( view ( w . last_input , start , end ) , view ( p . input , start , end ) ) ;
s . last_tick = p . meta [ i ] . controller_tick ;
}


}

 w . applied_tick , w . correction_serial = p . tick , max ( w . correction_serial , w . pending_correction ) ;
return replayed , corrected , . Ok ;

 }

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted.   

 // Cast semantics adapted. 
