#scope_file
transport :: #import "thirdparty/onet/transport";
#scope_export
// onet transport: ENet transport.
//
// Implements the transport surface over the ENet bindings bundled with the
// Odin toolchain (vendor/ENet, statically linked, ENet 1.3.17). This
// replaces the whole SynapseSocket protocol stack for the fast lane:
// connection management, reliability, ordering, fragmentation and throttling
// are ENet's.
//
// Host mode: one transport may run server and client halves together
// (start_server + start_client); poll() services both hosts alternately,
// which the ENet handshake requires.

MAX_CHANNELS_DEFAULT :: (cast, trunc(u64)(4));
// 收发两端共用的单包上限；更大的包在 send 时拒绝、在接收时丢弃。

MAX_PACKET_BYTES :: 4 * 1024 * 1024;

// 仅初始化/销毁计数跨线程；单个Transport仍由一个网络loop独占。

init_refcount: int;
init_mutex: s32;

Transport :: struct {
    // Server half (nil until start_server).

    initialized: bool;

    host: *enet.Host;

    // Client half (nil until start_client).

    client_host: *enet.Host;

    client_peer: *enet.Peer;

    next_id: u32;

    active_connections: int;

    loopback_token: u32;

    own_client_connection: transport.Connection_Id;

    // Server-side connections: id -> peer and peer -> id.

    peers_by_id: H.Table(transport.Connection_Id, *enet.Peer);

    ids_by_peer: H.Table(u64, transport.Connection_Id);

    local_client_id: transport.Connection_Id;

    incoming: [..] transport.Incoming_Packet;

    state_changes: [..] transport.State_Change;

    err: transport.Transport_Error;
}

// 解析字面量；start_client 对非字面量使用 ENet 的系统 DNS 解析。

parse_ipv4 :: (address: string) -> (host: u32, ok: bool) {
    if (address).count == 0 || (address).count > 15 {
        return 0, false;
    }

    octets: [4] u32;
    octet := 0;
    value: u32 = 0;
    digits := 0;
    for c: address {
        if c == #char "." {
            if octet >= 3 || digits == 0 || value > 255 {
                return 0, false;
            }

            octets[octet] = value;
            octet += 1;
            value = 0;
            digits = 0;
            continue;
        }

        if c < #char "0" || c > #char "9" {
            return 0, false;
        }

        value = value * 10 + ((cast, trunc(u32) c) - #char "0");
        digits += 1;
        if digits > 3 {
            return 0, false;
        }
    }

    if octet != 3 || digits == 0 || value > 255 {
        return 0, false;
    }

    octets[3] = value;
    return enet.HOST_TO_NET_32((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]), true;
}

init :: (t: *Transport) {
    t.* = .{
    };

    lock_initialization();
    defer unlock_initialization();
    if init_refcount == 0 {
        if enet.initialize() != 0 {
            t.err = .Not_Initialized;
            return;
        }
    }

    init_refcount += 1;
    t.initialized = true;
    t.next_id = 1;
    t.peers_by_id = new_table(transport.Connection_Id, *enet.Peer);
    t.ids_by_peer = new_table(u64, transport.Connection_Id);
    t.incoming = new_dynamic(transport.Incoming_Packet, 0, 16);
    t.state_changes = new_dynamic(transport.State_Change, 0, 8);
}

destroy :: (t: *Transport) {
    shutdown(t);
    if t.initialized {
        lock_initialization();
        init_refcount -= 1;
        if init_refcount == 0 {
            enet.deinitialize();
        }

        unlock_initialization();
    }

    release(t.peers_by_id);
    release(t.ids_by_peer);
    release(t.incoming);
    release(t.state_changes);
    t.* = .{
    };
}

error_of :: (t: *Transport) -> transport.Transport_Error {
    return t.err;
}

failed :: (t: *Transport) -> bool {
    return t.err != .None;
}

// Starts the server half, bound to any address on the given port.
// Port 0 binds an ephemeral port; bound_port() reports it afterwards.

start_server :: (t: *Transport, port: u16, max_clients: u64 = 32, max_channels: u64 = MAX_CHANNELS_DEFAULT) -> bool {
    if t.err == .Not_Initialized {
        return false;
    }

    if t.host != null {
        t.err = .Already_Running;
        return false;
    }

    addr: enet.Address;
    addr.host = enet.HOST_ANY;
    addr.port = port;
    t.host = enet.host_create(*addr, max_clients, max_channels, 0, 0);
    if t.host == null {
        t.err = .Host_Create_Failed;
        return false;
    }

    return true;
}

// Starts the client half and begins connecting to address:port.
// In host mode, call after start_server.

start_client :: (t: *Transport, address: string, port: u16, max_channels: u64 = MAX_CHANNELS_DEFAULT) -> bool {
    if t.err == .Not_Initialized {
        return false;
    }

    if t.client_host != null {
        t.err = .Already_Running;
        return false;
    }

    t.client_host = enet.host_create(null, 1, max_channels, 0, 0);
    if t.client_host == null {
        t.err = .Host_Create_Failed;
        return false;
    }

    addr: enet.Address;
    host, ok := parse_ipv4(address);
    if !ok {
        name := new_slice(u8, (address).count + 1);
        copy_samples(name, bit_cast([] u8, address));
        resolved := enet.address_set_host(*addr, name.data) == 0;
        release(name);
        if !resolved {
            enet.host_destroy(t.client_host);
            t.client_host = null;
            t.err = .Connect_Failed;
            return false;
        }

        host = addr.host;
    }

    addr.port = port;
    addr.host = host;
    // 仅用于关联同进程host的两半；可预测，不是认证凭据。

    t.loopback_token = (((cast, trunc(u32) port)) << 16) ^ t.next_id;
    t.client_peer = enet.host_connect(t.client_host, *addr, max_channels, t.loopback_token);
    if t.client_peer == null {
        enet.host_destroy(t.client_host);
        t.client_host = null;
        t.err = .Connect_Failed;
        return false;
    }

    t.local_client_id = (cast(transport.Connection_Id) (t.next_id));
    t.next_id += 1;
    return true;
}

bound_port :: (t: *Transport) -> u16 {
    if t.host == null {
        return 0;
    }

    return t.host.address.port;
}

is_host_mode :: (t: *Transport) -> bool {
    return t.host != null && t.client_host != null;
}

// The connection id the local client half uses for its own traffic.

local_client_connection :: (t: *Transport) -> transport.Connection_Id {
    return t.local_client_id;
}

// Services both halves with a zero timeout, draining every pending event.
// Must be called by the network loop; the ENet handshake needs both ends
// polled, so host mode polls server then client each call.

poll :: (t: *Transport) {
    if t.host != null {
        poll_host(t, .Server);
    }

    if t.client_host != null {
        poll_host(t, .Client);
    }
}

poll_host :: (t: *Transport, side: transport.Invoker) {
    host := t.host;
    if side == .Client {
        host = t.client_host;
    }

    if host == null {
        return;
    }

    ev: enet.Event;
    while true {
        r := enet.host_service(host, *ev, 0);
        if r <= 0 {
            break;
        }

        if ev.type == {
            case .CONNECT;
                if side == .Server {
                    id := (cast(transport.Connection_Id) (t.next_id));
                    t.next_id += 1;
                    H.table_set(*t.peers_by_id, id, ev.peer);
                    H.table_set(*t.ids_by_peer, (cast, trunc(u64)(ev.peer)), id);
                    t.active_connections += 1;
                    if t.client_host != null && ev.data == t.loopback_token {
                        t.own_client_connection = id;
                    }

                    array_add(*t.state_changes, .{
                        id, .Server, .Connected
                    });
                } else {
                    array_add(*t.state_changes, .{
                        t.local_client_id, .Client, .Connected
                    });
                };

            case .RECEIVE;
                id, ok := connection_for_event(t, side, ev.peer);
                if ev.packet.dataLength > MAX_PACKET_BYTES {
                    enet.packet_destroy(ev.packet);
                    continue;
                }

                if ok {
                    payload := new_slice(u8, (cast(int) ev.packet.dataLength));
                    copy_samples(payload, ([] u8).{ (cast(int) ev.packet.dataLength), ev.packet.data });
                    channel := transport.Channel.Reliable;
                    if (ev.packet.flags & (cast, trunc(u32)(enet.PacketFlags.RELIABLE))) == 0 {
                        channel = .Unreliable;
                    }

                    array_add(*t.incoming, transport.Incoming_Packet.{
                        connection = id,
                        invoker = side,
                        channel = channel,
                        payload = payload,
                    });
                };

                enet.packet_destroy(ev.packet);
            case .DISCONNECT;
                if side == .Server {
                    {
                        id, ok := table_get(*t.ids_by_peer, (cast, trunc(u64)(ev.peer)));
                        if
                        ok && id != transport.UNSET_CONNECTION_ID {
                            H.table_set(*t.ids_by_peer, (cast, trunc(u64)(ev.peer)), transport.UNSET_CONNECTION_ID);
                            H.table_set(*t.peers_by_id, id, null);
                            t.active_connections -= 1;
                            array_add(*t.state_changes, .{
                                id, .Server, .Disconnected
                            });
                        }
                    };
                } else {
                    array_add(*t.state_changes, .{
                        t.local_client_id, .Client, .Disconnected
                    });
                    t.local_client_id = transport.UNSET_CONNECTION_ID;
                };

            case;
                // None/event-type with no payload: ignore.
        }
    }
}

connection_for_event :: (t: *Transport, side: transport.Invoker, peer: *enet.Peer) -> (transport.Connection_Id, bool) {
    if side == .Client {
        if t.client_peer != null {
            return t.local_client_id, true;
        }

        return transport.UNSET_CONNECTION_ID, false;
    }

    {
        id, ok := table_get(*t.ids_by_peer, (cast, trunc(u64)(peer)));
        if
        ok && id != transport.UNSET_CONNECTION_ID {
            return id, true;
        }
    }

    return transport.UNSET_CONNECTION_ID, false;
}

// Sends payload to a connection. The buffer is copied into the ENet packet,
// so the caller's slice is free to reuse once this returns.

send :: (t: *Transport, connection: transport.Connection_Id, channel: transport.Channel, payload: [] u8) -> bool {
    if t.err == .Not_Initialized {
        return false;
    }

    // Local client connection routes through the client half.

    if connection == t.local_client_id && t.client_peer != null {
        return send_to_peer(t, t.client_peer, channel, payload);
    }

    peer, ok := table_get(*t.peers_by_id, connection);
    if !ok || peer == null {
        t.err = .Unknown_Connection;
        return false;
    }

    return send_to_peer(t, peer, channel, payload);
}

send_to_peer :: (t: *Transport, peer: *enet.Peer, channel: transport.Channel, payload: [] u8) -> bool {
    if (payload).count == 0 {
        return true;
    }

    if (payload).count > MAX_PACKET_BYTES {
        t.err = .Send_Failed;
        return false;
    }

    flags: enet.PacketFlags = (cast(enet.PacketFlags) 0);

    if channel == .Reliable {
        flags = .RELIABLE;
    }

    packet := enet.packet_create(payload.data, (cast, trunc(u64)((payload).count)), flags);
    if packet == null {
        t.err = .Send_Failed;
        return false;
    }

    if enet.peer_send(peer, 0, packet) != 0 {
        enet.packet_destroy(packet);
        t.err = .Send_Failed;
        return false;
    }

    // Flush eagerly: the caller's network loop batches sends itself and calls
    // poll right after; ENet holding an unflushed queue across that boundary
    // would add latency for no benefit.

    if t.client_peer != null && peer == t.client_peer {
        enet.host_flush(t.client_host);
    } else {
        enet.host_flush(t.host);
    }

    return true;
}

// Server-side broadcast to every connection.

broadcast :: (t: *Transport, channel: transport.Channel, payload: [] u8) -> bool {
    if t.host == null || (payload).count == 0 {
        return false;
    }

    flags: enet.PacketFlags = (cast(enet.PacketFlags) 0);

    if channel == .Reliable {
        flags = .RELIABLE;
    }

    packet := enet.packet_create(payload.data, (cast, trunc(u64)((payload).count)), flags);
    if packet == null {
        t.err = .Send_Failed;
        return false;
    }

    enet.host_broadcast(t.host, 0, packet);
    enet.host_flush(t.host);
    return true;
}

// Disconnects a remote client immediately.

kick_now :: (t: *Transport, connection: transport.Connection_Id) -> transport.Connection_State_Change_Result {
    peer, ok := table_get(*t.peers_by_id, connection);
    if !ok || peer == null {
        return .Invalid_Connection;
    }

    enet.peer_disconnect_now(peer, 0);
    // peer_disconnect_now resets the peer without a farewell event; the
    // server-side bookkeeping is dropped here, the state change is queued.

    H.table_set(*t.ids_by_peer, (cast, trunc(u64)(peer)), transport.UNSET_CONNECTION_ID);
    H.table_set(*t.peers_by_id, connection, null);
    t.active_connections -= 1;
    array_add(*t.state_changes, .{
        connection, .Server, .Disconnected
    });
    return .Success;
};

// Disconnects a remote client once its queued reliable data has been
// delivered. ENet's
// peer_disconnect_later is this exact semantic.

kick_after_delivery :: (t: *Transport, connection: transport.Connection_Id) -> transport.Connection_State_Change_Result {
    peer, ok := table_get(*t.peers_by_id, connection);
    if !ok || peer == null {
        return .Invalid_Connection;
    }

    enet.peer_disconnect_later(peer, 0);
    return .Success;
}

// Disconnects the local client half.

disconnect_local :: (t: *Transport) -> transport.Connection_State_Change_Result {
    if t.client_peer == null {
        return .Invalid_Connection;
    }

    enet.peer_disconnect(t.client_peer, 0);
    enet.host_flush(t.client_host);
    return .Success;
}

// 同进程host提示；token可预测，不能用作身份验证或权限判定。

is_own_client_connection :: (t: *Transport, server_side_connection: transport.Connection_Id) -> bool {
    if t.client_peer == null {
        return false;
    }

    return server_side_connection != transport.UNSET_CONNECTION_ID && server_side_connection == t.own_client_connection;
}

// View of packets received since the last clear_incoming; payloads are owned
// by the transport until cleared.

incoming_packets :: (t: *Transport) -> [] transport.Incoming_Packet {
    return view(t.incoming, 0);
}

clear_incoming :: (t: *Transport) {
    for packet: t.incoming {
        release(packet.payload);
    }

    array_reset_keeping_memory(*t.incoming);
}

state_changes_view :: (t: *Transport) -> [] transport.State_Change {
    return view(t.state_changes, 0);
}

clear_state_changes :: (t: *Transport) {
    array_reset_keeping_memory(*t.state_changes);
}

// True once the client half has seen its connect event.

client_is_connected :: (t: *Transport) -> bool {
    if t.client_peer == null {
        return false;
    }

    return t.client_peer.state == .CONNECTED;
}

// ENet 的 roundTripTime 在首次测得前为默认值（500 ms）；packetsLost 计的是超时重发的可靠包。

connection_quality :: (t: *Transport, connection: transport.Connection_Id) -> (transport.Connection_Quality, bool) {
    peer: *enet.Peer;
    if connection == t.local_client_id && t.client_peer != null {
        peer = t.client_peer;
    } else {
        peer = table_get(*t.peers_by_id, connection);
    }

    if peer == null {
        return .{
        }, false;
    };

    return .{
        rtt_ms = (cast(float64) (peer.roundTripTime)),
        loss = (cast(float64) (peer.packetLoss)) / (cast(float64) (enet.PEER_PACKET_LOSS_SCALE)),
        retransmits = (cast, trunc(s64)(peer.packetsLost)),
        pending_bytes = (cast, trunc(s64)(peer.reliableDataInTransit)),
    }, true;
};

server_connection_count :: (t: *Transport) -> int {
    return t.active_connections;
}

// Stops both halves and releases every resource. Remote peers get a
// best-effort disconnect notice instead of waiting for ENet's timeout.

shutdown :: (t: *Transport) {
    clear_incoming(t);
    clear_state_changes(t);
    if t.client_host != null {
        if t.client_peer != null {
            enet.peer_disconnect_now(t.client_peer, 0);
        }

        enet.host_destroy(t.client_host);
        t.client_host = null;
        t.client_peer = null;
    }

    if t.host != null {
        for peer, _: t.peers_by_id {
            if peer != null {
                enet.peer_disconnect_now(peer, 0);
            }
        }

        enet.host_destroy(t.host);
        t.host = null;
    }

    array_reset_keeping_memory(*t.peers_by_id);
    t.local_client_id = transport.UNSET_CONNECTION_ID;
    t.own_client_connection = transport.UNSET_CONNECTION_ID;
    t.active_connections = 0;
    array_reset_keeping_memory(*t.ids_by_peer);
    // shutdown可重复，ENet全局引用直到destroy才释放。

    t.err = .None;
}

// 仅在旧连接结束后释放客户端host，允许同Session重新连接，服务器半部不受影响。

stop_client :: (t: *Transport) -> bool {
    if client_is_connected(t) {
        return false;
    }

    if t.client_host != null {
        enet.host_destroy(t.client_host);
    }

    t.client_host, t.client_peer = null, null;
    t.local_client_id, t.own_client_connection = 0, 0;
    return true;
}

// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
