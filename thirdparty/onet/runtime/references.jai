#scope_file
objects :: #import "thirdparty/onet/objects" ;
v :: #import "thirdparty/onet/values" ;
#scope_export


//@region 当前运行时对象的本地实例解析

 Object_Reference :: v . Resolved_Reference ( objects . Network_Object ) ;
// IDs belong to this Registry lifetime and are not recycled by runtime. This

 // resolver borrows World; references must not outlive or cross its reinit.

 // For application-pooled IDs use values.Reference_Registry's generation checks.

 object_reference_resolver :: ( w : * World ) -> v . Reference_Resolver ( objects . Network_Object ) {

 return .{
userdata = w ,
lookup = ( p : * void , id : v . Reference ) -> * objects . Network_Object {

 w := ( cast ( * World ) p ) ;
if w == null || ! w . initialized || id . id == 0 || id . id > ( cast , trunc ( u64 ) ( 0xffffffff ) ) || id . generation != 0 {
return null ;
}

 obj , exists := objects . get ( w . registry , ( cast ( objects . Network_Id ) ( id . id ) ) ) ;
return ( ifx exists then obj else null ) ;

 } ,
identify = ( p : * void , target : * objects . Network_Object ) -> ( v . Reference , bool ) {

 w := ( cast ( * World ) p ) ;
if w == null || ! w . initialized || target == null {
return .{

 } , false ;
} ;

 // Compare addresses only: never dereference a caller's stale target.

 for obj , id : w . registry . objects {
if obj == target && obj . active {
return .{
( cast , trunc ( u64 ) ( id ) ) , 0 ,
} , true ;
} ;

 }

 return .{

 } , false ;

 } ,

 } ;


}

 object_reference_target :: ( w : * World , ref : * Object_Reference ) -> * objects . Network_Object {

 ref . resolver = object_reference_resolver ( w ) ;
return v . reference_target ( ref ) ;

 }

 object_reference_set_target :: ( w : * World , ref : * Object_Reference , target : * objects . Network_Object ) -> bool {

 ref . resolver = object_reference_resolver ( w ) ;
return v . reference_set_target ( ref , target ) ;

 }

 object_reference_codec :: ( schema : u32 ) -> objects . Value_Codec {

 b := v . reference_bridge ( objects . Network_Object , schema ) ;
return .{
schema = b . schema , write = b . write , read = b . read , destroy = b . destroy ,
} ;


}

 //@endregion


// Iterator semantics adapted. 

 // Loop scopes adapted. 

 // Cast semantics adapted. 
