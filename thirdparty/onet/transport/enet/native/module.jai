// ENet 1.3.17 C ABI. Native hosts/peers are owned exclusively by ENet.
#import "Basic" ;
Socket :: #import "Socket" ;
#if OS == . WINDOWS { lib :: #library "enet64" ; winmm :: #library,system,link_always "winmm" ; ws2 :: #library,system,link_always "ws2_32" ; }
else { lib :: #system_library "enet" ; }
Address :: struct { host : u32 ; port : u16 ; }
List :: struct { next , previous : * void ; }
// Only the public prefix is viewed; never allocate, copy or index a Host value.
Host :: struct { socket : Socket . Socket ; address : Address ; }
PeerState :: enum s32 { DISCONNECTED ; CONNECTING ; ACKNOWLEDGING_CONNECT ; CONNECTION_PENDING ; CONNECTION_SUCCEEDED ; CONNECTED ; DISCONNECT_LATER ; DISCONNECTING ; ACKNOWLEDGING_DISCONNECT ; ZOMBIE ; }
PacketFlags :: enum_flags u32 { RELIABLE = 1 ; UNSEQUENCED = 2 ; NO_ALLOCATE = 4 ; UNRELIABLE_FRAGMENT = 8 ; SENT = 256 ; }
Packet :: struct { referenceCount : u64 ; flags : u32 ; data : * u8 ; dataLength : u64 ; freeCallback : #type ( * Packet ) #c_call ; userData : * void ; }
EventType :: enum s32 { NONE ; CONNECT ; DISCONNECT ; RECEIVE ; }
Event :: struct { type : EventType ; peer : * Peer ; channelID : u8 ; data : u32 ; packet : * Packet ; }
HOST_ANY :: 0 ;
PEER_PACKET_LOSS_SCALE :: 65536 ;
HOST_TO_NET_32 :: ( value : u32 ) -> u32 { return Socket . htonl ( value ) ; }
initialize :: ( ) -> s32 #foreign lib "enet_initialize" ;
deinitialize :: ( ) #foreign lib "enet_deinitialize" ;
address_set_host :: ( address : * Address , hostName : * u8 ) -> s32 #foreign lib "enet_address_set_host" ;
host_create :: ( address : * Address , peerCount : u64 , channelLimit : u64 , incomingBandwidth : u32 , outgoingBandwidth : u32 ) -> * Host #foreign lib "enet_host_create" ;
host_destroy :: ( host : * Host ) #foreign lib "enet_host_destroy" ;
host_connect :: ( host : * Host , address : * Address , channelCount : u64 , data : u32 ) -> * Peer #foreign lib "enet_host_connect" ;
host_service :: ( host : * Host , event : * Event , timeout : u32 ) -> s32 #foreign lib "enet_host_service" ;
packet_destroy :: ( packet : * Packet ) #foreign lib "enet_packet_destroy" ;
packet_create :: ( data : * void , dataLength : u64 , flags : PacketFlags ) -> * Packet #foreign lib "enet_packet_create" ;
peer_send :: ( peer : * Peer , channelID : u8 , packet : * Packet ) -> s32 #foreign lib "enet_peer_send" ;
host_flush :: ( host : * Host ) #foreign lib "enet_host_flush" ;
host_broadcast :: ( host : * Host , channelID : u8 , packet : * Packet ) #foreign lib "enet_host_broadcast" ;
peer_disconnect_now :: ( peer : * Peer , data : u32 ) #foreign lib "enet_peer_disconnect_now" ;
peer_disconnect_later :: ( peer : * Peer , data : u32 ) #foreign lib "enet_peer_disconnect_later" ;
peer_disconnect :: ( peer : * Peer , data : u32 ) #foreign lib "enet_peer_disconnect" ;

 #scope_file

 #scope_export
Peer :: struct {

 dispatchList : List ;

 host : * Host ;

 outgoingPeerID : u16 ;

 incomingPeerID : u16 ;

 connectID : u32 ;

 outgoingSessionID : u8 ;

 incomingSessionID : u8 ;

 address : Address ;

 data : * void ;

 state : PeerState ;

 channels : * void ;

 channelCount : u64 ;

 incomingBandwidth : u32 ;

 outgoingBandwidth : u32 ;

 incomingBandwidthThrottleEpoch : u32 ;

 outgoingBandwidthThrottleEpoch : u32 ;

 incomingDataTotal : u32 ;

 outgoingDataTotal : u32 ;

 lastSendTime : u32 ;

 lastReceiveTime : u32 ;

 nextTimeout : u32 ;

 earliestTimeout : u32 ;

 packetLossEpoch : u32 ;

 packetsSent : u32 ;

 packetsLost : u32 ;

 packetLoss : u32 ;

 packetLossVariance : u32 ;

 packetThrottle : u32 ;

 packetThrottleLimit : u32 ;

 packetThrottleCounter : u32 ;

 packetThrottleEpoch : u32 ;

 packetThrottleAcceleration : u32 ;

 packetThrottleDeceleration : u32 ;

 packetThrottleInterval : u32 ;

 pingInterval : u32 ;

 timeoutLimit : u32 ;

 timeoutMinimum : u32 ;

 timeoutMaximum : u32 ;

 lastRoundTripTime : u32 ;

 lowestRoundTripTime : u32 ;

 lastRoundTripTimeVariance : u32 ;

 highestRoundTripTimeVariance : u32 ;

 roundTripTime : u32 ;

 roundTripTimeVariance : u32 ;

 mtu : u32 ;

 windowSize : u32 ;

 reliableDataInTransit : u32 ;

 outgoingReliableSequenceNumber : u16 ;

 acknowledgements : List ;

 sentReliableCommands : List ;

 sentUnreliableCommands : List ;

 outgoingCommands : List ;

 dispatchedCommands : List ;

 flags : u16 ;

 reserved : u16 ;

 incomingUnsequencedGroup : u16 ;

 outgoingUnsequencedGroup : u16 ;

 unsequencedWindow : [ 32 ] u32 ;

 eventData : u32 ;

 totalWaitingData : u64 ;


}

 // Loop scopes adapted. 

 // Cast semantics adapted. 
