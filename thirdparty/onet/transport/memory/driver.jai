#scope_file
transport :: #import "thirdparty/onet/transport";
#scope_export

//@region Driver adapter
// Transport 与 Hub 必须比借用它的 Session 活得久并保持地址稳定。

driver :: (t: *Transport) -> transport.Driver {
    return .{
        t, *driver_vtable,
    };
}

driver_vtable := transport.Driver_Vtable.{
    start_server = (p: *void, port: u16, limit: u64) -> bool {
        return start_server((cast(*Transport) p), port, limit);
    },
    start_client = (p: *void, address: string, port: u16) -> bool {
        return start_client((cast(*Transport) p), address, port);
    },
    loopback_address = (p: *void) -> string {
        return ADDRESS;
    },
    bound_port = (p: *void) -> u16 {
        return bound_port((cast(*Transport) p));
    },
    local_connection = (p: *void) -> transport.Connection_Id {
        return local_connection((cast(*Transport) p));
    },
    client_is_connected = (p: *void) -> bool {
        return client_is_connected((cast(*Transport) p));
    },
    poll = (p: *void) {
        poll((cast(*Transport) p));
    },
    send = (p: *void, id: transport.Connection_Id, c: transport.Channel, b: [] u8) -> bool {
        return send((cast(*Transport) p), id, c, b);
    },
    // 帧按序投递，Close 排在已发数据之后，因此“送达后断开”与立即断开相同。

    kick = (p: *void, id: transport.Connection_Id, later: bool) -> transport.Connection_State_Change_Result {
        return kick((cast(*Transport) p), id);
    },
    incoming = (p: *void) -> [] transport.Incoming_Packet {
        return incoming_packets((cast(*Transport) p));
    },
    clear_incoming = (p: *void) {
        clear_incoming((cast(*Transport) p));
    },
    changes = (p: *void) -> [] transport.State_Change {
        return state_changes_view((cast(*Transport) p));
    },
    clear_changes = (p: *void) {
        clear_state_changes((cast(*Transport) p));
    },
    flush = (p: *void) {},
    disconnect_local = (p: *void) -> transport.Connection_State_Change_Result {
        return disconnect_local((cast(*Transport) p));
    },
    stop_client = (p: *void) -> bool {
        return stop_client((cast(*Transport) p));
    },
    shutdown = (p: *void) {
        shutdown((cast(*Transport) p));
    },
    capabilities = (p: *void) -> transport.Capabilities {
        return capabilities((cast(*Transport) p));
    },
    remote_identity = (p: *void, id: transport.Connection_Id) -> string {
        return remote_identity((cast(*Transport) p), id);
    },
    open_local_pair = (p: *void) -> bool {
        return open_local_pair((cast(*Transport) p));
    },
    connection_quality = (p: *void, id: transport.Connection_Id) -> transport.Connection_Quality, bool {
        return connection_quality((cast(*Transport) p), id);
    },
}

//@endregion
// Cast semantics adapted.
// Loop scopes adapted.
