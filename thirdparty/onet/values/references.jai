#scope_file
core :: #import "thirdparty/onet/core" ;
#scope_export


//@region Live reference resolution without object/session dependency

 Reference_Resolver :: struct ( T : Type ) {

 userdata : * void ;

 lookup : #type ( * void , Reference ) -> * T ;

 identify : #type ( * void , * T ) -> ( Reference , bool ) ;

 pending : #type ( * void , u64 ) -> ( Reference , * T , bool ) ;

 ticket : #type ( * void , * T ) -> u64 ;


}

 Resolved_Reference :: struct ( T : Type ) {

 identity : Reference ;

 resolver : Reference_Resolver ( T ) ;

 pending_ticket : u64 ;


}

 // Resolve on EVERY access, never cache a possibly pooled/destroyed pointer.

 // Missing target is ordinary: preserve identity to resolve after spawn/roster

 // admission. Disconnect/interest exit removes resolution but not its identity.

 reference_target :: ( x : * Resolved_Reference ( $T ) ) -> * T {

 if x . pending_ticket != 0 && x . resolver . pending != null {

 id , target , ok := x . resolver . pending ( x . resolver . userdata , x . pending_ticket ) ;
if ! ok {
return null ;
}

 if id . id == 0 {
return target ;
}

 x . identity = id ;
x . pending_ticket = 0 ;

 }

 if x . identity . id == 0 || x . resolver . lookup == null {
return null ;
}

 return x . resolver . lookup ( x . resolver . userdata , x . identity ) ;

 }

 reference_set_target :: ( x : * Resolved_Reference ( $T ) , target : * T ) -> bool {

 if target == null {
x . identity = .{

 } ;
x . pending_ticket = 0 ;
return true ;
} ;

 if x . resolver . identify == null {
return false ;
}

 id , ok := x . resolver . identify ( x . resolver . userdata , target ) ;
if ! ok || id . id == 0 {

 if x . resolver . ticket == null {
return false ;
}

 ticket := x . resolver . ticket ( x . resolver . userdata , target ) ;
if ticket == 0 {
return false ;
}

 x . identity = .{

 } ;
x . pending_ticket = ticket ;
return true ;

 } ;

 x . identity = id ;
x . pending_ticket = 0 ;
return true ;

 }

 // Pure serialization view: no target callbacks run during decode/probe and no

 // lookup ever changes external registry state. An unnumbered target sends null

 // for now, retaining its pending ticket so a later serialize carries its ID.

 reference_identity :: ( x : * Resolved_Reference ( $T ) ) -> Reference {

 if x . pending_ticket != 0 && x . resolver . pending != null {

 id , _ , ok := x . resolver . pending ( x . resolver . userdata , x . pending_ticket ) ;
if ok {
return id ;
}


}

 return x . identity ;

 }

 reference_is_pending :: ( x : * Resolved_Reference ( $T ) ) -> bool {

 if x . pending_ticket == 0 || x . resolver . pending == null {
return false ;
}

 id , _ , ok := x . resolver . pending ( x . resolver . userdata , x . pending_ticket ) ;
return ok && id . id == 0 ;

 }

 Pending_Target :: struct ( T : Type ) {
target : * T ;
identity : Reference ;
}

 // Registry callbacks implement generation-aware local identity. Keep its address

 // stable. The registry BORROWS targets and never frees/dereferences them itself.

 // Remove BEFORE freeing/repooling a target. Reusing an ID must increment its

 // generation; old handles remain unresolved, even if allocator address repeats.

 Reference_Registry :: struct ( T : Type ) {

 entries : H . Table ( Reference , * T , hash_Reference , equal_Reference ) ;

 generations : H . Table ( u64 , u32 ) ;

 initialized : bool ;

 pending : H . Table ( u64 , Pending_Target ( T ) ) ;

 next_ticket : u64 ;


}

 reference_registry_init :: ( reg : * Reference_Registry ( $T ) ) {

 reg .* = .{
entries = new_table ( Reference , * T , hash_function = hash_Reference , compare_function = equal_Reference ) , generations = new_table ( u64 , u32 ) , initialized = true ,
} ;

 reg . pending = new_table ( u64 , Pending_Target ( T ) ) ;
reg . next_ticket = 1 ;

 }

 reference_registry_destroy :: ( reg : * Reference_Registry ( $T ) ) {

 release ( reg . pending ) ;
release ( reg . entries ) ;
release ( reg . generations ) ;
reg .* = .{

 } ;


}

 reference_publish :: ( reg : * Reference_Registry ( $T ) , id : Reference , target : * T ) -> bool {

 if ! reg . initialized || id . id == 0 || target == null {
return false ;
}

 generation , known := table_get ( * reg . generations , id . id ) ;
if known && generation > id . generation {
return false ;
}

 existing , exists := table_get ( * reg . entries , id ) ;
if exists && existing != target {
return false ;
}

 for pointer , other : reg . entries {
if pointer == target && other != id {
return false ;
}

 }

 H . table_set ( * reg . entries , id , target ) ;
if known && generation < id . generation {
H . table_remove ( * reg . entries , Reference .{
id . id , generation
} ) ;
} ;

 H . table_set ( * reg . generations , id . id , id . generation ) ;
for entry , ticket : reg . pending {

 if entry . identity . id == 0 && entry . target == target {
H . table_set ( * reg . pending , ticket , Pending_Target ( T ) .{
target , id ,
} ) ;

 }


}

 return true ;

 }

 reference_withdraw :: ( reg : * Reference_Registry ( $T ) , id : Reference ) -> bool {

 _ , exists := table_get ( * reg . entries , id ) ;
if exists {
H . table_remove ( * reg . entries , id ) ;
}

 return exists ;

 }

 // Track before assigning a reference to an unspawned/unnumbered target. Tickets

 // are monotonically allocated, never reused, and must be forgotten BEFORE the

 // pending target is freed or repooled. This avoids caching its raw address in a

 // member and accidentally following another object's later pool rental.

 reference_track_pending :: ( reg : * Reference_Registry ( $T ) , target : * T ) -> ( u64 , bool ) {

 if ! reg . initialized || target == null || reg . next_ticket == 0 {
return 0 , false ;
}

 for entry , ticket : reg . pending {
if entry . target == target && entry . identity . id == 0 {
return ticket , true ;
}

 }

 ticket := reg . next_ticket ;
reg . next_ticket += 1 ;
H . table_set ( * reg . pending , ticket , Pending_Target ( T ) .{
target = target ,
} ) ;

 return ticket , true ;

 }

 reference_forget_pending :: ( reg : * Reference_Registry ( $T ) , ticket : u64 ) {

 H . table_remove ( * reg . pending , ticket ) ;

 }

 reference_resolver :: ( reg : * Reference_Registry ( $T ) ) -> Reference_Resolver ( T ) {

 return .{

 userdata = reg ,
lookup = ( p : * void , id : Reference ) -> * T {

 reg := ( cast ( * Reference_Registry ( T ) ) p ) ;
if reg == null || ! reg . initialized {
return null ;
}

 return table_get ( * reg . entries , id ) ;

 } ,
identify = ( p : * void , target : * T ) -> ( Reference , bool ) {

 reg := ( cast ( * Reference_Registry ( T ) ) p ) ;
if reg == null || ! reg . initialized {
return .{

 } , false ;
} ;

 for pointer , id : reg . entries {
if pointer == target {
return id , true ;
}

 }

 return .{

 } , false ;

 } ,
pending = ( p : * void , ticket : u64 ) -> ( Reference , * T , bool ) {

 reg := ( cast ( * Reference_Registry ( T ) ) p ) ;
if reg == null || ! reg . initialized {
return .{

 } , null , false ;
} ;

 entry , exists := table_get ( * reg . pending , ticket ) ;
if ! exists {
return .{

 } , null , false ;
} ;

 if entry . identity . id != 0 {
return entry . identity , table_get ( * reg . entries , entry . identity ) , true ;
}

 return .{

 } , entry . target , true ;

 } ,
ticket = ( p : * void , target : * T ) -> u64 {

 reg := ( cast ( * Reference_Registry ( T ) ) p ) ;
if reg == null || ! reg . initialized {
return 0 ;
}

 for entry , ticket : reg . pending {
if entry . target == target && entry . identity . id == 0 {
return ticket ;
}

 }

 return 0 ;

 } ,

 }


} ;

 // A member binds ^Resolved_Reference(T), NOT ^T or values.Binding(T). Reads only

 // replace identity after complete validation. Factories install each receiver's

 // resolver before member registration; decoding never invokes callbacks, so

 // probe prevalidation cannot subscribe or notify an external registry.

 reference_bridge :: ( $T : Type , schema : u32 ) -> Bridge {

 if schema < CUSTOM_SCHEMA_MIN {
return .{

 } ;

 }

 return .{

 schema = schema ,
write = ( w : * core . Writer , p : * void ) {

 x := ( cast ( * Resolved_Reference ( T ) ) p ) ;
id := reference_identity ( x ) ;
write ( builtin ( Reference ) , w , * id ) ;

 } ,
read = ( r : * core . Reader , p : * void ) -> bool {

 id , ok := read_new ( builtin ( Reference ) , r ) ;
if ! ok || ! value_member_finished ( r ) {
return reject_read ( r ) ;
}

 x := ( cast ( * Resolved_Reference ( T ) ) p ) ;
x . identity = id ;
x . pending_ticket = 0 ;
return true ;

 } ,
destroy = ( p : * void ) {
( ( cast ( * Resolved_Reference ( T ) ) p ) ) .* = .{

 } ;

 } ,

 }


}

 // Reference deltas are always absolute identities, never differences depending

 // on a pooled target's previous state. Zero ID is null; generation is retained

 // on the wire to prevent recycled IDs resolving to an unrelated connection.

 reference_delta_codec :: ( ) -> Delta_Codec ( Reference ) {

 return .{

 full = builtin ( Reference ) ,
write = ( w : * core . Writer , a , b : * Reference , mode : core . Delta_Check_Mode ) -> ( bool , bool ) {

 if mode == . Checked && a .* == b .* {
return false , true ;
}

 return true , write ( builtin ( Reference ) , w , b ) ;

 } ,
read = ( r : * core . Reader , a , out : * Reference ) -> bool {
value , ok := read_new ( builtin ( Reference ) , r ) ;
out .* = value ;
return ok ;
} ,

 }


}

 //@endregion


// Cast semantics adapted. 
