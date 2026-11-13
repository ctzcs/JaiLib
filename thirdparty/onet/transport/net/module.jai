// Native endpoint and nonblocking UDP support shared by the onet backend and tests.
#import "Basic" ;
S :: #import "Socket" ;
Address_Family :: enum { Invalid ; IP4 ; IP6 ; }
Address :: struct { family : Address_Family ; bytes : [ 16 ] u8 ; }
Endpoint :: struct { address : Address ; port : int ; }
UDP_Socket :: #type,distinct u64 ; // native descriptor + 1; zero is always closed
Error :: enum { None ; Socket ; Invalid_Address ; }
Option :: enum { Receive_Buffer_Size ; }
IP4_Any :: Address .{ family = . IP4 } ;
IP6_Any :: Address .{ family = . IP6 } ;
family_from_address :: ( a : Address ) -> Address_Family { return a . family ; }
family_from_endpoint :: ( ep : Endpoint ) -> Address_Family { return ep . address . family ; }
native :: ( s : UDP_Socket ) -> S . Socket { return cast ( S . Socket ) ( ( cast ( u64 ) s ) - 1 ) ; }
parse_address :: ( text : string ) -> Address {
a : Address ; z := to_c_string ( text ) ; defer free ( z ) ;
if S . inet_pton ( S . AF_INET , z , a . bytes . data ) == 1 { a . family = . IP4 ; return a ; }
if S . inet_pton ( S . AF_INET6 , z , a . bytes . data ) == 1 a . family = . IP6 ;
return a ;
}
make_unbound_udp_socket :: ( family : Address_Family ) -> UDP_Socket , Error {
if ! socket_ready() return 0 , . Socket ;
s := S . socket ( cast ( s32 ) ifx family == . IP6 then S . AF_INET6 else S . AF_INET , . SOCK_DGRAM , . UDP ) ;
if s == S . INVALID_SOCKET return 0 , . Socket ;
return cast ( UDP_Socket ) ( ( cast ( u64 ) s ) + 1 ) , . None ;
}
close :: ( s : UDP_Socket ) { if s != 0 { fd := native ( s ) ; S . close_and_reset ( * fd ) ; } }
to_native :: ( ep : Endpoint , storage : * S . sockaddr_storage ) -> S . socklen_t {
if ep . address . family == . IP4 {
a := cast ( * S . sockaddr_in ) storage ; a . sin_family = cast ( type_of ( a . sin_family ) ) S . AF_INET ; a . sin_port = S . htons ( cast ( u16 ) ep . port ) ;
memcpy ( * a . sin_addr , ep . address . bytes . data , 4 ) ;
#if OS == . MACOS a . sin_len = cast ( u8 ) size_of ( S . sockaddr_in ) ;
return cast ( S . socklen_t ) size_of ( S . sockaddr_in ) ;
}
a := cast ( * S . sockaddr_in6 ) storage ; a . sin6_family = cast ( type_of ( a . sin6_family ) ) S . AF_INET6 ; a . sin6_port = S . htons ( cast ( u16 ) ep . port ) ;
memcpy ( * a . sin6_addr , ep . address . bytes . data , 16 ) ;
#if OS == . MACOS a . sin6_len = cast ( u8 ) size_of ( S . sockaddr_in6 ) ;
return cast ( S . socklen_t ) size_of ( S . sockaddr_in6 ) ;
}
from_native :: ( storage : * S . sockaddr ) -> Endpoint {
ep : Endpoint ;
if storage . sa_family == S . AF_INET {
a := cast ( * S . sockaddr_in ) storage ; ep . address . family = . IP4 ; ep . port = cast ( int ) S . ntohs ( a . sin_port ) ;
memcpy ( ep . address . bytes . data , * a . sin_addr , 4 ) ;
} else if storage . sa_family == S . AF_INET6 {
a := cast ( * S . sockaddr_in6 ) storage ; ep . address . family = . IP6 ; ep . port = cast ( int ) S . ntohs ( a . sin6_port ) ;
memcpy ( ep . address . bytes . data , * a . sin6_addr , 16 ) ;
}
return ep ;
}
bind :: ( s : UDP_Socket , ep : Endpoint ) -> Error {
storage : S . sockaddr_storage ; n := to_native ( ep , * storage ) ;
return ifx S . bind ( native ( s ) , cast ( * S . sockaddr ) * storage , n ) == 0 then . None else . Socket ;
}
set_blocking :: ( s : UDP_Socket , blocking : bool ) -> Error { return ifx S . set_blocking ( native ( s ) , blocking ) then . None else . Socket ; }
set_option :: ( s : UDP_Socket , option : Option , value : int ) -> Error {
v := cast ( s32 ) value ;
result := S . setsockopt ( native ( s ) , S . SOL_SOCKET , S . SO_RCVBUF , cast ( * u8 ) * v , 4 ) ;
return ifx result == 0 then . None else . Socket ;
}
set_v6_only :: ( s : UDP_Socket ) -> bool {
v : s32 = 1 ; return S . setsockopt ( native ( s ) , cast ( s32 ) S . IPPROTO . IPV6 , S . IPV6_V6ONLY , cast ( * u8 ) * v , 4 ) == 0 ;
}
kernel_connect :: ( s : UDP_Socket , ep : Endpoint ) -> bool {
storage : S . sockaddr_storage ; n := to_native ( ep , * storage ) ;
return S . connect ( native ( s ) , cast ( * S . sockaddr ) * storage , n ) == 0 ;
}
bound_endpoint :: ( s : UDP_Socket ) -> Endpoint , Error {
storage : S . sockaddr_storage ; n := cast ( S . socklen_t ) size_of ( S . sockaddr_storage ) ;
if S . getsockname ( native ( s ) , cast ( * S . sockaddr ) * storage , * n ) != 0 return .{ } , . Socket ;
return from_native ( cast ( * S . sockaddr ) * storage ) , . None ;
}
send_udp :: ( s : UDP_Socket , data : [ ] u8 , ep : Endpoint ) -> int , Error {
storage : S . sockaddr_storage ; n := to_native ( ep , * storage ) ;
#if OS == . WINDOWS { size := cast ( s32 ) data . count ; } else { size := cast ( u64 ) data . count ; }
sent := S . sendto ( native ( s ) , data . data , size , cast ( S . MSG ) 0 , cast ( * S . sockaddr ) * storage , n ) ;
return cast ( int ) sent , ifx sent < 0 then . Socket else . None ;
}
recv_udp :: ( s : UDP_Socket , data : [ ] u8 ) -> int , Endpoint , Error {
storage : S . sockaddr_storage ; n := cast ( S . socklen_t ) size_of ( S . sockaddr_storage ) ;
#if OS == . WINDOWS { size := cast ( s32 ) data . count ; } else { size := cast ( u64 ) data . count ; }
got := S . recvfrom ( native ( s ) , data . data , size , cast ( S . MSG ) 0 , cast ( * S . sockaddr ) * storage , * n ) ;
if got < 0 return 0 , .{ } , . Socket ;
return cast ( int ) got , from_native ( cast ( * S . sockaddr ) * storage ) , . None ;
}
resolve :: ( host : string ) -> Endpoint , Endpoint , Error {
a4 , a6 : Endpoint ;
if ! socket_ready() return a4 , a6 , . Socket ;
z := to_c_string ( host ) ; defer free ( z ) ;
hint : S . addrinfo ; hint . ai_socktype = . SOCK_DGRAM ; hint . ai_protocol = . UDP ;
list : * S . addrinfo ;
if S . getaddrinfo ( z , null , * hint , * list ) != 0 return a4 , a6 , . Invalid_Address ;
defer S . freeaddrinfo ( list ) ;
p := list ;
while p != null {
ep := from_native ( p . ai_addr ) ;
if ep . address . family == . IP4 && a4 . address . family == . Invalid a4 = ep ;
if ep . address . family == . IP6 && a6 . address . family == . Invalid a6 = ep ;
p = p . ai_next ;
}
return a4 , a6 , . None ;
} 
IP4_Loopback :: Address.{family=.IP4,bytes=.[127,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0]};
ipv4 :: (bytes: [4]u8) -> Address { a:Address; a.family=.IP4; for 0..3 a.bytes[it]=bytes[it]; return a; }
make_bound_udp_socket :: (address: Address, port: int) -> UDP_Socket, Error {
 s,err:=make_unbound_udp_socket(address.family);
 if err!=.None return 0,err;
 err=bind(s,.{address,port});
 if err!=.None { close(s); return 0,err; }
 return s,.None;
}
peer_endpoint :: (s:UDP_Socket) -> Endpoint, Error {
 storage:S.sockaddr_storage; n:=cast(S.socklen_t)size_of(S.sockaddr_storage);
 if S.getpeername(native(s),cast(*S.sockaddr)*storage,*n)!=0 return .{},.Socket;
 return from_native(cast(*S.sockaddr)*storage),.None;
}

#scope_module
#import "Atomics";
startup_state:s32;
socket_ready :: () -> bool {
 state:=atomic_read(*startup_state); if state==2 return true; if state==-1 return false;
 won,_:=compare_and_swap(*startup_state,cast(s32)0,cast(s32)1);
 if won { ok:=S.socket_init(); atomic_write(*startup_state,ifx ok then cast(s32)2 else -1); return ok; }
 while atomic_read(*startup_state)==1 sleep_milliseconds(1);
 return atomic_read(*startup_state)==2;
}
