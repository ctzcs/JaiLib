#load "driver.jai" ;
#load "enet_transport.jai" ;
#scope_module
#import "Basic" ;
Math :: #import "Math" ;
Thread :: #import "Thread" ;
#load "../../support.jai" ;

 #import "Atomics" ;
lock_initialization :: ( ) { while ! compare_and_swap ( * init_mutex , ( cast , trunc ( s32 ) 0 ) , ( cast , trunc ( s32 ) 1 ) ) { sleep_milliseconds ( 1 ) ; } }
unlock_initialization :: ( ) { atomic_write ( * init_mutex , ( cast , trunc ( s32 ) 0 ) ) ; }

 // Loop scopes adapted.

 enet :: #import "thirdparty/onet/transport/enet/native" ;

 // Cast semantics adapted. 
