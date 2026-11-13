#scope_module
KeyHash :: #import "Hash" ;
hash_Input_Key :: ( k : Input_Key ) -> u32 { return KeyHash . get_hash ( k . system , KeyHash . get_hash ( k . tick , cast ( u32 ) 5381 ) ) ; }
equal_Input_Key :: ( a , b : Input_Key ) -> bool { return a . tick == b . tick && a . system == b . system ; } 
