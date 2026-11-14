#scope_file
transport :: #import "thirdparty/onet/transport";
#scope_export

//@region Driver adapter
// No ownership transfer: destroy the Transport after its Session is destroyed.

driver :: (t: *Transport) -> transport.Driver {
    return .{
        t, *driver_vtable,
    };
}

flush :: (t: *Transport) {
    if t.host != null {
        enet.host_flush(t.host);
    }

    if t.client_host != null {
        enet.host_flush(t.client_host);
    }
}

driver_vtable := transport.Driver_Vtable.{
    start_server = (p: *void, port: u16, limit: u64) -> bool {
        return start_server((cast(*Transport) p), port, limit);
    },
    start_client = (p: *void, host: string, port: u16) -> bool {
        return start_client((cast(*Transport) p), host, port);
    },
    bound_port = (p: *void) -> u16 {
        return bound_port((cast(*Transport) p));
    },
    local_connection = (p: *void) -> transport.Connection_Id {
        return local_client_connection((cast(*Transport) p));
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
    kick = (p: *void, id: transport.Connection_Id, later: bool) -> transport.Connection_State_Change_Result {
        if later {
            return kick_after_delivery((cast(*Transport) p), id);
        };
        return kick_now((cast(*Transport) p), id);
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
    flush = (p: *void) {
        flush((cast(*Transport) p));
    },
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
        return .{
            max_message = MAX_PACKET_BYTES, max_unreliable = MAX_PACKET_BYTES, unreliable = true, connection_quality = true,
        };
    },
    connection_quality = (p: *void, id: transport.Connection_Id) -> (transport.Connection_Quality, bool) {
        return connection_quality((cast(*Transport) p), id);
    },
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
