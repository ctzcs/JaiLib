#scope_file
transport :: #import "thirdparty/onet/transport";
#scope_export
// 进程内回环后端：不开 socket，同一 Hub 上的 Transport 按虚拟端口互连。
// 可靠与不可靠帧都按序送达、不丢失；弱网用 transport.Conditioner 叠加。
// Hub 与其上的全部 Transport 属于同一个网络 loop，Hub 必须比所有 Transport 活得久。
//@region 配置与所有权

ADDRESS :: "mem";

Config :: struct {
    // 报告给对端的已验证身份；空串表示不提供。

    identity: string;
    max_message, max_unreliable: int;
    reliable_only: bool;
}

default_config :: () -> Config {
    return .{
        max_message = transport.DEFAULT_MAX_MESSAGE, max_unreliable = transport.DEFAULT_MAX_MESSAGE,
    };
}

// 连接两端共享的链路，归 Hub 所有，Hub 销毁时释放；事件里的指针因此始终有效。

Link :: struct {
    client, server: *Transport;
    client_id, server_id: transport.Connection_Id;
    open: bool;
}

Hub :: struct {
    servers: H.Table(u16, *Transport);
    links: [..] *Link;
    next_port: u16;
}

Event_Kind :: enum u8 {
    Connect;
    Accept;
    Reject;
    Data;
    Close;
}

Event :: struct {
    kind: Event_Kind;
    link: *Link;
    to_server: bool;
    channel: transport.Channel;
    payload: [] u8;
}

Transport :: struct {
    hub: *Hub;
    config: Config;
    next_id: u32;
    port: u16;
    listening: bool;
    max_clients: u64;
    server_links: H.Table(transport.Connection_Id, *Link);
    client: *Link;
    client_connected: bool;
    inbox: [..] Event;
    incoming: [..] transport.Incoming_Packet;
    changes: [..] transport.State_Change;
}

hub_init :: (h: *Hub) {
    h.* = .{
        next_port = 40000,
    };

    h.servers = new_table(u16, *Transport);
}

hub_destroy :: (h: *Hub) {
    for link: h.links {
        free(link);
    }

    release(h.links);
    release(h.servers);
    h.* = .{
    };
}

init :: (t: *Transport, hub: *Hub, config: Config = .{
}) {
    t.* = .{
        hub = hub, config = config, next_id = 1,
    };

    if t.config.max_message <= 0 {
        t.config.max_message = transport.DEFAULT_MAX_MESSAGE;
    }

    if t.config.max_unreliable <= 0 {
        t.config.max_unreliable = t.config.max_message;
    }

    t.config.identity = copy_string(config.identity);
    t.server_links = new_table(transport.Connection_Id, *Link);
}

destroy :: (t: *Transport) {
    shutdown(t);
    release(t.config.identity);
    release(t.server_links);
    release(t.inbox);
    release(t.incoming);
    release(t.changes);
    t.* = .{
    };
}

//@endregion
//@region 连接生命周期

start_server :: (t: *Transport, port: u16, max_clients: u64 = 32) -> bool {
    if t.listening || max_clients == 0 {
        return false;
    }

    selected := port;
    if selected == 0 {
        {
            loop_index := 0;
            while loop_index < 65535 {
                defer loop_index += 1;

                t.hub.next_port = (ifx t.hub.next_port == 65535 then 1 else t.hub.next_port + 1);
                if table_get(*t.hub.servers, t.hub.next_port) == null {
                    selected = t.hub.next_port;
                    break;
                }
            }
        }
    }

    if selected == 0 || table_get(*t.hub.servers, selected) != null {
        return false;
    }

    H.table_set(*t.hub.servers, selected, t);
    t.port, t.listening, t.max_clients = selected, true, max_clients;
    return true;
};

start_client :: (t: *Transport, address: string, port: u16) -> bool {
    if t.client != null || (address != ADDRESS && !Str.begins_with(address, "mem:")) {
        return false;
    }

    link := new_link(t);
    {
        server := table_get(*t.hub.servers, port);
        if
        server != null {
            link.server = server;
            post(server, .{
                kind = .Connect, link = link, to_server = true
            });
        } else {
            post(t, .{
                kind = .Reject, link = link
            });
        }
    };

    return true;
}

open_local_pair :: (t: *Transport) -> bool {
    if !t.listening || t.client != null {
        return false;
    }

    link := new_link(t);
    link.server = t;
    post(t, .{
        kind = .Connect, link = link, to_server = true
    });
    return true;
};

new_link :: (t: *Transport) -> *Link {
    link := new_one(Link);
    link.client, link.client_id = t, next_connection(t);
    array_add(*t.hub.links, link);
    t.client, t.client_connected = link, false;
    return link;
}

next_connection :: (t: *Transport) -> transport.Connection_Id {
    id := (cast(transport.Connection_Id) (t.next_id));
    t.next_id += 1;
    return id;
}

post :: (t: *Transport, event: Event) {
    array_add(*t.inbox, event);
}

// 关闭链路：通知对端，本端立即产生 Disconnected（与 kick_now/disconnect_local 的其他后端一致）。

close_link :: (t: *Transport, link: *Link, from_server, notify_self: bool) {
    if !link.open && from_server {
        return;
    }

    was_open := link.open;
    link.open = false;
    if from_server {
        H.table_remove(*t.server_links, link.server_id);
        if notify_self {
            array_add(*t.changes, transport.State_Change.{
                link.server_id, .Server, .Disconnected
            });
        };

        if was_open && link.client != null {
            post(link.client, .{
                kind = .Close, link = link
            });
        };
    } else {
        if notify_self {
            array_add(*t.changes, transport.State_Change.{
                link.client_id, .Client, .Disconnected
            });
        };

        t.client, t.client_connected = null, false;
        if was_open && link.server != null {
            post(link.server, .{
                kind = .Close, link = link, to_server = true
            });
        };
    }
}

kick :: (t: *Transport, id: transport.Connection_Id) -> transport.Connection_State_Change_Result {
    link := table_get(*t.server_links, id);
    if link == null {
        return .Invalid_Connection;
    }

    close_link(t, link, true, true);
    return .Success;
}

disconnect_local :: (t: *Transport) -> transport.Connection_State_Change_Result {
    if t.client == null {
        return .Invalid_Connection;
    }

    close_link(t, t.client, false, true);
    return .Success;
}

stop_client :: (t: *Transport) -> bool {
    if t.client_connected {
        return false;
    }

    // 服务器可能已接受但本端尚未处理 Accept：照常通知对端，不产生本端事件。

    if t.client != null {
        close_link(t, t.client, false, false);
    }

    return true;
}

// 关闭全部链路并通知对端；不产生本端状态变化。可重复调用。

shutdown :: (t: *Transport) {
    if t.hub == null {
        return;
    }

    for link, _: t.server_links {
        close_link(t, link, true, false);
    }

    array_reset_keeping_memory(*t.server_links);
    if t.client != null {
        close_link(t, t.client, false, false);
    }

    if t.listening && table_get(*t.hub.servers, t.port) == t {
        H.table_remove(*t.hub.servers, t.port);
    }

    t.listening, t.port = false, 0;
    for event: t.inbox {
        release(event.payload);
    }

    array_reset_keeping_memory(*t.inbox);
    clear_incoming(t);
    array_reset_keeping_memory(*t.changes);
}

//@endregion
//@region 收发

send :: (t: *Transport, id: transport.Connection_Id, channel: transport.Channel, payload: [] u8) -> bool {
    if channel == .Unreliable && (t.config.reliable_only || (payload).count > t.config.max_unreliable) {
        return false;
    }

    if channel == .Reliable && (payload).count > t.config.max_message {
        return false;
    }

    link: *Link;
    to_server := false;
    if t.client != null && id == t.client.client_id {
        if !t.client_connected || !t.client.open {
            return false;
        }

        link, to_server = t.client, true;
    } else {
        link = table_get(*t.server_links, id);
        if link == null || !link.open {
            return false;
        }
    }

    target := (ifx to_server then link.server else link.client);
    post(target, .{
        kind = .Data, link = link, to_server = to_server, channel = channel, payload = clone(payload)
    });
    return true;
};

clone :: (data: [] u8) -> [] u8 {
    out := new_slice(u8, (data).count);
    copy_samples(out, data);
    return out;
}

// 按到达顺序处理收件箱；处理中新投递给自己的事件（本地连接对）在同一次 poll 内继续处理。

poll :: (t: *Transport) {
    {
        i := 0;
        while i < (t.inbox).count {
            defer i += 1;

            event := t.inbox[i];
            link := event.link;
            if event.kind == {
                case .Connect;
                    if !t.listening || (cast, trunc(u64)((t.server_links).count)) >= t.max_clients || !link_alive(link) {
                        post(link.client, .{
                            kind = .Reject, link = link
                        });
                        continue;
                    };

                    link.server_id, link.open = next_connection(t), true;
                    H.table_set(*t.server_links, link.server_id, link);
                    array_add(*t.changes, transport.State_Change.{
                        link.server_id, .Server, .Connected
                    });
                    post(link.client, .{
                        kind = .Accept, link = link
                    });
                case .Accept;
                    // 服务器可能已在接受后立刻关闭；其 Close 排在后面，这里仍先报告连上。

                    if t.client != link {
                        continue;
                    }

                    t.client_connected = true;
                    array_add(*t.changes, transport.State_Change.{
                        link.client_id, .Client, .Connected
                    });
                case .Reject;
                    if t.client != link {
                        continue;
                    }

                    t.client, t.client_connected = null, false;
                    array_add(*t.changes, transport.State_Change.{
                        link.client_id, .Client, .Disconnected
                    });
                case .Data;
                    id := (ifx event.to_server then link.server_id else link.client_id);
                    valid := (ifx event.to_server then table_get(*t.server_links, id) == link else (t.client == link && t.client_connected));
                    if !valid {
                        release(event.payload);
                        continue;
                    }

                    array_add(*t.incoming, transport.Incoming_Packet.{
                        id, (ifx event.to_server then .Server else .Client), event.channel, event.payload
                    });
                case .Close;
                    if event.to_server {
                        if table_get(*t.server_links, link.server_id) == link {
                            H.table_remove(*t.server_links, link.server_id);
                            array_add(*t.changes, transport.State_Change.{
                                link.server_id, .Server, .Disconnected
                            });
                        };
                    } else if t.client == link {
                        t.client, t.client_connected = null, false;
                        array_add(*t.changes, transport.State_Change.{
                            link.client_id, .Client, .Disconnected
                        });
                    };
            }
        }
    }

    array_reset_keeping_memory(*t.inbox);
}

// 客户端在连接请求送达前就放弃（stop_client/shutdown）时不再接受。

link_alive :: (link: *Link) -> bool {
    return link.client != null && link.client.client == link;
}

remote_identity :: (t: *Transport, id: transport.Connection_Id) -> string {
    if t.client != null && id == t.client.client_id {
        return (ifx t.client.server != null then t.client.server.config.identity else "");
    }

    {
        link := table_get(*t.server_links, id);
        if
        link != null {
            return link.client.config.identity;
        }
    }

    return "";
}

capabilities :: (t: *Transport) -> transport.Capabilities {
    return .{
        max_message = t.config.max_message, max_unreliable = t.config.max_unreliable, unreliable = !t.config.reliable_only, local_pair = true, remote_identity = true, connection_quality = true,
    };
}

// 进程内投递没有延迟、丢包与重传。

connection_quality :: (t: *Transport, id: transport.Connection_Id) -> transport.Connection_Quality, bool {
    connected := (t.client != null && id == t.client.client_id && t.client_connected) || table_get(*t.server_links, id) != null;
    return .{
    }, connected;
};

bound_port :: (t: *Transport) -> u16 {
    return t.port;
}

local_connection :: (t: *Transport) -> transport.Connection_Id {
    return (ifx t.client != null then t.client.client_id else 0);
}

client_is_connected :: (t: *Transport) -> bool {
    return t.client != null && t.client_connected;
}

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
    return view(t.changes, 0);
}

clear_state_changes :: (t: *Transport) {
    array_reset_keeping_memory(*t.changes);
}

//@endregion
// Cast semantics adapted.
// Loop scopes adapted.
