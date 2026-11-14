#scope_file

#scope_export
// onet transport: transport-common types.
//
// Transports deal in Connection_Ids they assign themselves; 0 is never a
// valid connection id (UNSET_CONNECTION_ID == 0).
// Which lane a packet travels on.

Channel :: enum u8 {
    Reliable; // ordered and reliable

    Unreliable; // unreliable
}

// Which network role is acting.

Invoker :: enum u8 {
    Client;
    Server;
}

// Distinct id for a connection within one transport; 0 is never assigned.

Connection_Id :: #type,distinct u32;

UNSET_CONNECTION_ID :: (cast(Connection_Id) (0));

// Result of a connection-state request.

Connection_State_Change_Result :: enum u8 {
    Success;
    Already_In_State;
    Invalid_Connection;
    Not_Supported;
    Error;
}

// A received packet, payload owned by the receiver until cleared.

Incoming_Packet :: struct {
    connection: Connection_Id;
    invoker: Invoker;
    channel: Channel;
    payload: [] u8;
}

// Connection lifecycle events surfaced by a transport's poll.

State_Change_Kind :: enum u8 {
    Connected;
    Disconnected;
}

State_Change :: struct {
    connection: Connection_Id;
    invoker: Invoker;
    kind: State_Change_Kind;
}

// Shared transport error model (mirrors the sticky-error convention of the
// core codec).

Transport_Error :: enum u8 {
    None;
    Not_Initialized;
    Already_Running;
    Not_Running;
    Host_Create_Failed;
    Connect_Failed;
    Unknown_Connection;
    Send_Failed;
}

// Cast semantics adapted.
// Loop scopes adapted.
