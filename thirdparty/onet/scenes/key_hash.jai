#scope_module
KeyHash :: #import "Hash" ;
hash_Resource_Key :: ( k : Resource_Key ) -> u32 { return KeyHash . get_hash ( k . handle , KeyHash . get_hash ( k . namespace , cast ( u32 ) 5381 ) ) ; }
equal_Resource_Key :: ( a , b : Resource_Key ) -> bool { return a . namespace == b . namespace && a . handle == b . handle ; } 
