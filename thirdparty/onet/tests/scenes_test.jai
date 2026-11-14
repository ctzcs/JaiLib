#scope_file
scenes :: #import "thirdparty/onet/scenes";
transport :: #import "thirdparty/onet/transport";
#scope_export

//@region 协议回环与异步 engine 测试适配器

Scene_Message :: struct {
    from, to: transport.Connection_Id;

    data: [scenes.PACKET_SIZE] u8;
}

Scene_Endpoint :: struct {
    manager: scenes.Manager;

    hub: *Scene_Hub;

    id: transport.Connection_Id;

    auto_complete, fail_load, fail_unload, fail_send, carry_ok: bool;

    requests: [..] scenes.Ticket;

    pending: [..] scenes.Ticket;

    events: [..] scenes.Event;

    held: H.Table(scenes.Handle, bool);

    carry_count: int;

    reject_load, single_scene: bool;

    validate_count: int;

    ready: [4] bool;
    // index 0 是 authority 本机，1..3 是 peer。

    gate_calls: [4] int;
}

Scene_Hub :: struct {
    endpoints: [4] Scene_Endpoint;

    messages: [..] Scene_Message;

    now: u64;

    rejected: int;
}

scene_send :: (userdata: *void, to: transport.Connection_Id, payload: [] u8) -> bool {
    e := (cast(*Scene_Endpoint) userdata);
    if e.fail_send {
        return false;
    }

    assert((payload).count == scenes.PACKET_SIZE);
    message := Scene_Message.{
        from = e.id, to = to,
    };

    copy_samples(view(message.data, 0), payload);
    array_add(*e.hub.messages, message);
    return true;
}

scene_complete :: (e: *Scene_Endpoint, ticket: scenes.Ticket, success: bool) {
    if ticket.operation == .Load {
        if success {
            H.table_set(*e.held, ticket.handle, true);
        }

        assert(scenes.complete_load(*e.manager, ticket, success));
    } else {
        if success {
            H.table_remove(*e.held, ticket.handle);
        }

        assert(scenes.complete_unload(*e.manager, ticket, success));
    }
}

scene_request :: (userdata: *void, ticket: scenes.Ticket) {
    e := (cast(*Scene_Endpoint) userdata);
    array_add(*e.requests, ticket);
    if e.single_scene && ticket.operation == .Load {
        assert((e.held).count == 0);
    }

    if e.auto_complete {
        scene_complete(e, ticket, !(ifx ticket.operation == .Load then e.fail_load else e.fail_unload));
    } else {
        array_add(*e.pending, ticket);
    }
}

scene_event :: (userdata: *void, event: scenes.Event) {
    e := (cast(*Scene_Endpoint) userdata);
    array_add(*e.events, event);
}

scene_carry :: (userdata: *void, old_scene, new_scene: scenes.Handle) -> bool {
    e := (cast(*Scene_Endpoint) userdata);
    e.carry_count += 1;
    assert(old_scene != new_scene);
    // 真实 engine 的对象关系由调用方迁移；测试仅验证授权时机，不伪造对象实现。

    return e.carry_ok;
}

scene_validate_load :: (userdata: *void, scene: scenes.Handle, asset: scenes.Asset_Id, authority: transport.Connection_Id) -> bool {
    e := (cast(*Scene_Endpoint) userdata);
    assert(e.manager.config.userdata == userdata && scene != 0 && authority == 900 && asset != 0);
    e.validate_count += 1;
    return !e.reject_load;
}

scene_ready_to_unload :: (userdata: *void, old_scene, new_scene: scenes.Handle, connection: transport.Connection_Id) -> bool {
    e := (cast(*Scene_Endpoint) userdata);
    assert(e.manager.config.userdata == userdata && e.id == 900 && old_scene != 0 && old_scene != new_scene);
    assert(connection < 4);
    e.gate_calls[(cast(int) (connection))] += 1;
    return e.ready[(cast(int) (connection))];
}

scene_hub_init :: (h: *Scene_Hub) {
    h.messages = new_dynamic(Scene_Message);
    for *e, i: h.endpoints {
        e.*.hub = h;
        e.*.id = (cast(transport.Connection_Id) (ifx i == 0 then 900 else i));
        e.*.auto_complete = true;
        e.*.carry_ok = true;
        e.*.ready = .[
        true, true, true, true,
        ];

        e.*.held = new_table(scenes.Handle, bool);
        e.*.requests = new_dynamic(scenes.Ticket);
        e.*.pending = new_dynamic(scenes.Ticket);
        e.*.events = new_dynamic(scenes.Event);
        scenes.init(*e.*.manager, .{
            role = (ifx i == 0 then .Server else .Client), userdata = e, send = scene_send, request = scene_request, event = scene_event, carry = scene_carry, timeout_ms = 100, resend_ms = 20
        });
    };
}

scene_join :: (h: *Scene_Hub, i: int, epoch: u64) {
    assert(scenes.bind_authority(*h.endpoints[i].manager, 900, epoch));
    assert(scenes.peer_join(*h.endpoints[0].manager, (cast(transport.Connection_Id) (i)), epoch));
}

scene_deliver :: (h: *Scene_Hub) {
    while (h.messages).count != 0 {
        msg := h.messages[0];
        array_ordered_remove_by_index(*h.messages, 0);
        for *e: h.endpoints {
            if e.*.id == msg.to && !scenes.handle(*e.*.manager, msg.from, view(msg.data, 0)) {
                h.rejected += 1;
            }
        }
    }
}

scene_pump :: (h: *Scene_Hub, count: int = 8) {
    {
        loop_index := 0;
        while loop_index < count {
            defer loop_index += 1;

            h.now += 1;
            for *e: h.endpoints {
                scenes.update(*e.*.manager, h.now);
            }

            scene_deliver(h);
        }
    }
}

scene_finish :: (e: *Scene_Endpoint, h: scenes.Handle, success := true) -> scenes.Ticket {
    for ticket, i: e.pending {
        if ticket.handle != h {
            continue;
        }

        array_ordered_remove_by_index(*e.pending, i);
        scene_complete(e, ticket, success);
        return ticket;
    }

    panic("missing pending engine operation");
    return .{};
}

scene_open :: (h: *Scene_Hub, asset: scenes.Asset_Id, scope: scenes.Scope, local := false) -> scenes.Handle {
    handle, ok := scenes.open(*h.endpoints[0].manager, asset, scope, local);
    assert(ok);
    return handle;
}

scene_event_count :: (e: *Scene_Endpoint, kind: scenes.Event_Kind, h: scenes.Handle) -> int {
    n := 0;
    for event: e.events {
        if event.kind == kind && event.handle == h {
            n += 1;
        }
    }

    return n;
}

scene_inject :: (m: *scenes.Manager, from: transport.Connection_Id, p: scenes.Packet) -> bool {
    data, ok := scenes.encode_packet(p);
    assert(ok);
    return scenes.handle(m, from, view(data, 0));
}

scene_hub_destroy :: (h: *Scene_Hub, t: *Test) {
    {
        i := 1;
        while i < 4 {
            defer i += 1;
            scenes.peer_leave(*h.endpoints[0].manager, (cast(transport.Connection_Id) (i)));
        }
    }

    for *e: h.endpoints {
        e.*.auto_complete = true;
        e.*.fail_unload = false;
        e.*.fail_load = false;
        e.*.fail_send = false;
        scenes.shutdown(*e.*.manager);
        for ticket: e.*.pending {
            scene_complete(e, ticket, true);
        }

        array_reset_keeping_memory(*e.*.pending);
    }

    scene_pump(h, 12);
    for *e: h.endpoints {
        expect(t, (e.*.held).count == 0, "engine resources released");
        expect(t, scenes.destroy(*e.*.manager), "manager destroy is quiescent");
        release(e.*.requests);
        release(e.*.pending);
        release(e.*.events);
        release(e.*.held);
    }

    release(h.messages);
}

//@endregion
//@region Scope、晚加入、身份与失败重试

scenes_two_client_scope_and_late_join :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    scene_join(*h, 2, 102);
    members := transport.Connection_Id.[1];
    private := scene_open(*h, 7, .{ .Connections, view(members, 0)
    });
    members[0] = 2; // scope 是深拷贝，不能由调用方修改。

    global := scene_open(*h, 7, .{
        kind = .Global
    });
    expect(t, private != global, "same asset, #type,#type,distinct live handles");
    scene_pump(*h);
    s := *h.endpoints[0].manager;
    expect(t, scenes.is_loaded(s, private, 1));
    expect(t, !scenes.is_loaded(s, private, 2));
    expect(t, scenes.is_loaded(s, global, 1) && scenes.is_loaded(s, global, 2));
    expect(t, (h.endpoints[2].requests).count == 1, "no scope leak");
    scene_join(*h, 3, 103);
    scene_pump(*h);
    expect(t, scenes.is_loaded(s, global, 3));
    expect(t, !scenes.is_loaded(s, private, 3));
    expect_value(t, h.rejected, 0);
};

scenes_authority_and_unsolicited_reports :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    scene_join(*h, 2, 102);
    s := *h.endpoints[0].manager;
    c := *h.endpoints[1].manager;
    private := scene_open(*h, 9, .{ .Connections, transport.Connection_Id.[1]
    });
    // 正确格式的真实协议包仍必须验证发送身份、scope、请求及 epoch。

    expect(t, !scene_inject(c, 2, .{ .Load, 88, 9, 101, 10
   }));
    expect(t, !scene_inject(s, 1, .{ .Load, private, 9, 101, 1
    }));
    expect(t, !scene_inject(s, 2, .{ .Loaded, private, 9, 102, 1
    }));
    expect(t, !scene_inject(s, 1, .{ .Loaded, 99, 9, 101, 1
    }));
    expect(t, !scene_inject(s, 1, .{ .Loaded, private, 9, 101, 1
    }), "not yet dispatched is not requested on wire");
    expect(t, !scene_inject(s, 1, .{ .Loaded, private, 9, 999, 1
    }));
    expect(t, !scene_inject(c, 900, .{ .Load, 88, 9, 999, 1
    }));
    scene_pump(*h);
    expect(t, scenes.is_loaded(s, private, 1));
    expect_value(t, (h.endpoints[1].requests).count, 1);
}

scenes_failure_latch_retry_and_duplicate_reports :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    e := *h.endpoints[1];
    e.fail_load = true;
    id := scene_open(*h, 8, .{
        kind = .Global
    });
    scene_pump(*h);
    s := *h.endpoints[0].manager;
    expect_value(t, scenes.connection_state(s, id, 1), .Load_Failed);
    expect(t, !scenes.is_loaded(s, id, 1));
    expect(t, !scenes.request_load(s, id, 1));
    old := e.requests[0];
    e.fail_load = false;
    expect(t, scenes.request_load(s, id, 1, retry = true));
    scene_pump(*h);
    expect(t, scenes.is_loaded(s, id, 1));
    current := e.requests[(e.requests).count - 1];
    expect(t, current.revision > old.revision);
    expect(t, !scene_inject(s, 1, .{ .Loaded, id, 8, 101, old.revision
    }));
    before := scene_event_count(*h.endpoints[0], .Loaded, id);
    expect(t, scene_inject(s, 1, .{ .Loaded, id, 8, 101, current.revision
    }));
    expect_value(t, scene_event_count(*h.endpoints[0], .Loaded, id), before);
    expect(t, scene_inject(*e.manager, 900, .{ .Load, id, 8, 101, current.revision
    }));
    scene_pump(*h);
    expect(t, (e.requests).count == 2, "duplicate command does not reload");
};

//@endregion
//@region 卸载、过期完成、超时和关闭顺序

scenes_unload_while_loading_and_stale_completion :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    e := *h.endpoints[1];
    e.auto_complete = false;
    id := scene_open(*h, 2, .{
        kind = .Global
    });
    scene_pump(*h, 3);
    s := *h.endpoints[0].manager;
    expect_value(t, (e.pending).count, 1);
    expect(t, scenes.request_unload(s, id, 1));
    scene_pump(*h, 3);
    expect(t, (e.pending).count == 1, "unload must wait for physical load");
    old := scene_finish(e, id);
    expect(t, !scenes.is_loaded(s, id, 1));
    scene_pump(*h, 2);
    expect_value(t, (e.pending).count, 1);
    expect_value(t, e.pending[0].operation, .Unload);
    expect(t, !scene_inject(s, 1, .{ .Loaded, id, 2, 101, old.revision
    }));
    // 重复旧 completion 不得满足正在运行的新卸载 Ticket。

    expect(t, scenes.complete_load(*e.manager, old, true));
    scene_pump(*h, 2);
    expect_value(t, scenes.connection_state(s, id, 1), .Unloading);
    expect_value(t, (e.held).count, 1);
    scene_finish(e, id);
    scene_pump(*h);
    expect_value(t, scenes.connection_state(s, id, 1), .Absent);
    expect_value(t, (e.held).count, 0);
    expect(t, !scene_inject(*e.manager, 900, .{ .Load, id, 2, 101, old.revision
    }));
};

scenes_close_waits_remote_then_local_and_retries_release :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv := *h.endpoints[0];
    cli := *h.endpoints[1];
    id := scene_open(*h, 3, .{
        kind = .Global
    }, true);
    scene_pump(*h);
    expect(t, scenes.is_loaded(*srv.manager, id, 1));
    srv.auto_complete = false;
    cli.auto_complete = false;
    expect(t, scenes.close(*srv.manager, id));
    expect(t, !scenes.is_loaded(*srv.manager, id, 1));
    scene_pump(*h, 3);
    expect(t, (srv.pending).count == 0, "authority cannot release before remote acknowledgement");
    expect_value(t, (cli.pending).count, 1);
    scene_finish(cli, id, false);
    scene_pump(*h, 3);
    expect_value(t, scenes.connection_state(*srv.manager, id, 1), .Unload_Failed);
    expect_value(t, (srv.pending).count, 0);
    expect(t, scenes.close(*srv.manager, id), "close retries failed remote release");
    scene_pump(*h, 3);
    scene_finish(cli, id);
    scene_pump(*h, 3);
    expect_value(t, (srv.pending).count, 1);
    scene_finish(srv, id, false);
    scene_pump(*h, 2);
    info, exists := scenes.get_info(*srv.manager, id);
    expect(t, exists && info.local_state == .Unload_Failed);
    expect(t, scenes.close(*srv.manager, id));
    scene_pump(*h, 2);
    scene_finish(srv, id);
    scene_pump(*h);
    _, exists = scenes.get_info(*srv.manager, id);
    expect(t, !exists);
};

scenes_timeout_reclaims_late_success_and_rejects_old_report :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    e := *h.endpoints[1];
    e.auto_complete = false;
    id := scene_open(*h, 5, .{
        kind = .Global
    });
    scene_pump(*h, 3);
    old := e.pending[0];
    h.now = 101;
    scenes.update(*h.endpoints[0].manager, h.now);
    scene_deliver(*h);
    scene_pump(*h, 2);
    expect_value(t, scenes.connection_state(*h.endpoints[0].manager, id, 1), .Unloading);
    scene_finish(e, id);
    scene_pump(*h, 2);
    expect_value(t, e.pending[0].operation, .Unload);
    expect(t, !scene_inject(*h.endpoints[0].manager, 1, .{ .Loaded, id, 5, 101, old.revision
    }));
    scene_finish(e, id);
    scene_pump(*h);
    expect_value(t, (e.held).count, 0);
    expect_value(t, scenes.connection_state(*h.endpoints[0].manager, id, 1), .Absent);
};

//@endregion
//@region Replace、断线重入和解析回滚

scenes_replace_carry_and_failure_preserve_old :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    scene_join(*h, 2, 102);
    srv := *h.endpoints[0];
    old := scene_open(*h, 10, .{
        kind = .Global
    });
    scene_pump(*h);
    h.endpoints[2].auto_complete = false;
    dest := scene_open(*h, 11, .{
        kind = .Global
    });
    expect(t, scenes.begin_replace(*srv.manager, old, dest, carry = true));
    scene_pump(*h, 5);
    expect(t, scenes.is_loaded(*srv.manager, old, 1) && scenes.is_loaded(*srv.manager, old, 2));
    expect_value(t, srv.carry_count, 0);
    scene_finish(*h.endpoints[2], dest, false);
    scene_pump(*h, 3);
    expect(t, scenes.is_loaded(*srv.manager, old, 1));
    expect_value(t, scene_event_count(srv, .Replace_Failed, old), 1);
    expect(t, scenes.request_load(*srv.manager, dest, 2, retry = true));
    expect(t, scenes.begin_replace(*srv.manager, old, dest, carry = true));
    scene_pump(*h, 3);
    scene_finish(*h.endpoints[2], dest);
    scene_pump(*h, 3);
    expect_value(t, srv.carry_count, 1);
    expect(t, scenes.is_loaded(*srv.manager, dest, 1) && scenes.is_loaded(*srv.manager, dest, 2));
    expect(t, !scenes.is_loaded(*srv.manager, old, 1));
    expect_value(t, h.endpoints[2].pending[0].operation, .Unload);
    scene_finish(*h.endpoints[2], old);
    scene_pump(*h);
    _, exists := scenes.get_info(*srv.manager, old);
    expect(t, !exists);
};

scenes_disconnect_pending_load_and_rejoin_epoch :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    e := *h.endpoints[1];
    e.auto_complete = false;
    id := scene_open(*h, 12, .{
        kind = .Global
    });
    scene_pump(*h, 3);
    old := e.pending[0];
    scenes.peer_leave(*h.endpoints[0].manager, 1);
    scenes.disconnect(*e.manager);
    expect(t, !scenes.bind_authority(*e.manager, 900, 201), "old loader must drain first");
    scene_finish(e, id);
    scene_pump(*h, 2);
    expect_value(t, e.pending[0].operation, .Unload);
    scene_finish(e, id, false);
    scene_pump(*h, 2);
    expect(t, scenes.retry_local_unload(*e.manager, id));
    scene_pump(*h, 2);
    scene_finish(e, id);
    scene_pump(*h, 2);
    e.auto_complete = true;
    scene_join(*h, 1, 201);
    expect(t, !scene_inject(*e.manager, 900, .{ .Load, id, 12, 101, old.revision
    }));
    expect(t, !scene_inject(*h.endpoints[0].manager, 1, .{ .Loaded, id, 12, 101, old.revision
    }));
    scene_pump(*h);
    expect(t, scenes.is_loaded(*h.endpoints[0].manager, id, 1));
    expect_value(t, (e.held).count, 1);
};

scenes_malformed_packets_rollback_and_send_order :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    c := *h.endpoints[1].manager;
    data, ok := scenes.encode_packet(.{ .Load, 90, 1, 101, 1
    });
    expect(t, ok);
    {
        n := 0;
        while n < scenes.PACKET_SIZE {
            defer n += 1;
            expect(t, !scenes.handle(c, 900, view(data, 0, n)));
        }
    }

    oversized: [scenes.PACKET_SIZE + 1] u8;
    copy_samples(view(oversized, 0), view(data, 0));
    expect(t, !scenes.handle(c, 900, view(oversized, 0)));
    for index: (int.[0, 2, 3, 10]) {
        bad := data;
        bad[index] = 255;
        expect(t, !scenes.handle(c, 900, view(bad, 0)));
    }

    expect_value(t, (c.scenes).count, 0);
    expect_value(t, c.last_revision, 0);
    // 同一轮 map 遍历不保证顺序；协议发送必须按 revision 升序且失败不越过。

    h.endpoints[0].fail_send = true;
    ids: [16] scenes.Handle;
    for *id, i: ids {
        id.* = scene_open(*h, (cast(scenes.Asset_Id) (i)), .{
            kind = .Global
        });
    };

    scene_pump(*h, 3);
    expect_value(t, (h.endpoints[1].requests).count, 0);
    h.endpoints[0].fail_send = false;
    h.now += 1;
    scenes.update(*h.endpoints[0].manager, h.now);
    previous: u64 = 0;
    for *message: h.messages {
        packet, valid := scenes.decode_packet(view(message.*.data, 0));
        expect(t, valid && packet.revision > previous, "wire commands are ordered");
        previous = packet.revision;
    }

    scene_deliver(*h);
    scene_pump(*h);
    for id: ids {
        expect(t, scenes.is_loaded(*h.endpoints[0].manager, id, 1));
    }

    expect_value(t, h.rejected, 0);
}

//@endregion
//@region 后台完成只在网络 loop 消费

Scene_Thread_Data :: struct {
    manager: *scenes.Manager;
    ticket: scenes.Ticket;
}

scene_worker :: (data: *void) {
    d := (cast(*Scene_Thread_Data) data);
    // 重复完成也只消费一次；线程不接触 engine 或 network 状态。

    {
        loop_index := 0;
        while loop_index < 100 {
            defer loop_index += 1;
            assert(scenes.complete_load(d.manager, d.ticket, true));
        }
    }
}

scenes_worker_completion_is_queued :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    e := *h.endpoints[1];
    e.auto_complete = false;
    id := scene_open(*h, 15, .{
        kind = .Global
    });
    scene_pump(*h, 3);
    ticket := e.pending[0];
    array_reset_keeping_memory(*e.pending);
    H.table_set(*e.held, id, true);
    data := Scene_Thread_Data.{
        *e.manager, ticket,
    };

    workers: [4] *Worker;
    for *worker: workers {
        worker.* = create_worker(*data, scene_worker);
    }

    for worker: workers {
        join_worker(worker);
        destroy_worker(worker);
    }

    expect(t, !scenes.is_local_loaded(*e.manager, id), "worker must not mutate loop state");
    expect(t, !scenes.is_loaded(*h.endpoints[0].manager, id, 1));
    scene_pump(*h);
    expect(t, scenes.is_loaded(*h.endpoints[0].manager, id, 1));
    expect_value(t, scene_event_count(e, .Loaded, id), 1);
};

//@endregion
//@region 本机开放失败、容量拒绝和恢复策略

scenes_authority_load_failure_timeout_and_shutdown :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv := *h.endpoints[0];
    srv.fail_load = true;
    failed := scene_open(*h, 21, .{
        kind = .Global
    }, true);
    scene_pump(*h);
    _, exists := scenes.get_info(*srv.manager, failed);
    expect(t, !exists);
    expect_value(t, (h.endpoints[1].requests).count, 0);
    srv.fail_load = false;
    srv.auto_complete = false;
    timed := scene_open(*h, 21, .{
        kind = .Global
    }, true);
    expect(t, timed != failed);
    scene_pump(*h, 2);
    h.now += 101;
    scenes.update(*srv.manager, h.now);
    info, present := scenes.get_info(*srv.manager, timed);
    expect(t, present && info.phase == .Closing);
    expect(t, !scenes.destroy(*srv.manager), "cannot destroy outstanding loader");
    scene_finish(srv, timed);
    scene_pump(*h, 2);
    expect_value(t, srv.pending[0].operation, .Unload);
    scene_finish(srv, timed);
    scene_pump(*h);
    expect_value(t, (srv.held).count, 0);
    expect_value(t, (h.endpoints[1].requests).count, 0);
};

scenes_capacity_refusal_and_report_send_retry :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    e := *h.endpoints[1];
    e.manager.config.max_scenes = 1;
    e.fail_send = true;
    a := scene_open(*h, 22, .{
        kind = .Global
    });
    scene_pump(*h, 4);
    expect(t, scenes.is_local_loaded(*e.manager, a));
    expect(t, !scenes.is_loaded(*h.endpoints[0].manager, a, 1));
    e.fail_send = false;
    scene_pump(*h, 2);
    expect(t, scenes.is_loaded(*h.endpoints[0].manager, a, 1));
    b := scene_open(*h, 23, .{
        kind = .Global
    });
    scene_pump(*h);
    expect_value(t, scenes.connection_state(*h.endpoints[0].manager, b, 1), .Load_Failed);
    expect_value(t, (e.requests).count, 1);
    expect(t, scenes.request_unload(*h.endpoints[0].manager, a, 1));
    scene_pump(*h);
    expect(t, scenes.request_load(*h.endpoints[0].manager, b, 1, retry = true));
    scene_pump(*h);
    expect(t, scenes.is_loaded(*h.endpoints[0].manager, b, 1));
};

scenes_carry_veto_keeps_old_and_abort_is_explicit :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv := *h.endpoints[0];
    a := scene_open(*h, 24, .{
        kind = .Global
    });
    b := scene_open(*h, 25, .{
        kind = .Global
    });
    scene_pump(*h);
    srv.carry_ok = false;
    expect(t, scenes.begin_replace(*srv.manager, a, b, carry = true));
    scene_pump(*h, 2);
    expect(t, scenes.is_loaded(*srv.manager, a, 1));
    expect_value(t, srv.carry_count, 1);
    expect(t, scenes.begin_replace(*srv.manager, a, b));
    expect(t, scenes.abort_replace(*srv.manager, a));
    scene_pump(*h, 2);
    expect(t, scenes.is_loaded(*srv.manager, a, 1));
};

scenes_unload_timeout_waits_for_retry_or_disconnect :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv := *h.endpoints[0];
    cli := *h.endpoints[1];
    id := scene_open(*h, 26, .{
        kind = .Global
    }, true);
    scene_pump(*h);
    cli.auto_complete = false;
    expect(t, scenes.close(*srv.manager, id));
    scene_pump(*h, 3);
    h.now += 101;
    scenes.update(*srv.manager, h.now);
    expect_value(t, scenes.connection_state(*srv.manager, id, 1), .Unload_Failed);
    expect_value(t, (srv.held).count, 1);
    scenes.peer_leave(*srv.manager, 1);
    scenes.disconnect(*cli.manager);
    scene_pump(*h, 3);
    expect_value(t, (srv.held).count, 0);
    scene_finish(cli, id);
    scene_pump(*h);
    expect_value(t, (cli.held).count, 0);
};

//@endregion
//@region 无 loader 不能伪装成功

scenes_missing_loader_reports_failure :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    h.endpoints[1].manager.config.request = null;
    id := scene_open(*h, 27, .{
        kind = .Global
    });
    scene_pump(*h);
    expect_value(t, scenes.connection_state(*h.endpoints[0].manager, id, 1), .Load_Failed);
    expect(t, !scenes.is_loaded(*h.endpoints[0].manager, id, 1));
    expect_value(t, (h.endpoints[1].held).count, 0);
    srv := *h.endpoints[0].manager;
    srv.config.request = null;
    before := (srv.scenes).count;
    local, accepted := scenes.open(srv, 28, .{
        kind = .Global
    }, load_here = true);
    expect(t, !accepted && local == 0 && (srv.scenes).count == before, "no loader: local open is rejected synchronously");
};

//@endregion
//@region 单调时钟初始值不要求为零

scenes_first_update_accepts_uptime_clock :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    id := scene_open(*h, 28, .{
        kind = .Global
    });
    h.now = 9000000;
    scene_pump(*h);
    expect(t, scenes.is_loaded(*h.endpoints[0].manager, id, 1));
    expect_value(t, scene_event_count(*h.endpoints[0], .Timeout, id), 0);
};

//@endregion
//@region 动态 scope 与本机可信加载策略

scenes_scope_switch_reliable_cleanup_and_late_join :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    scene_join(*h, 2, 102);
    srv := *h.endpoints[0];
    id := scene_open(*h, 31, .{ .Connections, transport.Connection_Id.[1]
    });
    scene_pump(*h);
    srv.fail_send = true;
    h.endpoints[1].fail_unload = true;
    members := transport.Connection_Id.[2, 3];
    expect(t, scenes.set_scope(*srv.manager, id, .{ .Connections, view(members, 0)
    }));
    members[0] = 1; // set_scope 也必须深拷贝。

    expect(t, !scenes.is_loaded(*srv.manager, id, 1), "removed gate closes before reliable send succeeds");
    scene_pump(*h, 3);
    expect(t, table_get(*h.endpoints[1].held, id));
    expect_value(t, (h.endpoints[2].requests).count, 0);
    srv.fail_send = false;
    scene_pump(*h);
    expect_value(t, scenes.connection_state(*srv.manager, id, 1), .Unload_Failed);
    expect(t, scenes.is_loaded(*srv.manager, id, 2));
    h.endpoints[1].fail_unload = false;
    expect(t, scenes.request_unload(*srv.manager, id, 1), "out-of-scope cleanup can be retried");
    scene_join(*h, 3, 103);
    scene_pump(*h);
    expect_value(t, scenes.connection_state(*srv.manager, id, 1), .Absent);
    expect(t, !table_get(*h.endpoints[1].held, id) && scenes.is_loaded(*srv.manager, id, 3));
    expect(t, !scenes.set_scope(*srv.manager, id, .{ .Connections, transport.Connection_Id.[0]
    }));
    expect(t, scenes.set_scope(*srv.manager, id, .{
        kind = .Global
    }));
    scene_pump(*h);
    expect(t, scenes.is_loaded(*srv.manager, id, 1));
    expect(t, scenes.set_scope(*srv.manager, id, .{
        kind = .Connections
    }));
    scene_pump(*h);
    {
        i := 1;
        while i < 4 {
            defer i += 1;
            expect_value(t, scenes.connection_state(*srv.manager, id, (cast(transport.Connection_Id) (i))), .Absent);
        }
    };

    expect(t, h.rejected == 0, "removed peers' exact unload ACKs remain valid");
};

scenes_scope_reentry_serializes_inflight_resources :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    e := *h.endpoints[1];
    e.auto_complete = false;
    srv := *h.endpoints[0].manager;
    scope := scenes.Scope.{ .Connections, transport.Connection_Id.[1],
    }

    id := scene_open(*h, 32, scope);
    scene_pump(*h, 3);
    expect(t, scenes.set_scope(srv, id, .{
        kind = .Connections
    }));
    expect(t, scenes.set_scope(srv, id, scope));
    scene_pump(*h, 2);
    expect(t, (e.requests).count == 1, "reentry cannot overlap a stale physical load");
    scene_finish(e, id);
    scene_pump(*h, 2);
    expect_value(t, e.pending[0].operation, .Unload);
    scene_finish(e, id);
    e.auto_complete = true;
    scene_pump(*h);
    expect(t, scenes.is_loaded(srv, id, 1));
    expect_value(t, (e.requests).count, 3);
    expect(t, scenes.request_unload(srv, id, 1));
    scene_pump(*h);
    expect(t, scenes.set_scope(srv, id, scope));
    scene_pump(*h);
    expect(t, scenes.connection_state(srv, id, 1) == .Absent, "unchanged scope does not override explicit unload");
};

scenes_trusted_validator_rejects_and_retries_without_loader :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    e := *h.endpoints[1];
    e.manager.config.validate_load = scene_validate_load;
    e.reject_load = true;
    id := scene_open(*h, 33, .{
        kind = .Global
    });
    scene_pump(*h);
    srv := *h.endpoints[0].manager;
    expect_value(t, scenes.connection_state(srv, id, 1), .Load_Failed);
    expect_value(t, (e.requests).count, 0);
    expect_value(t, (e.held).count, 0);
    expect_value(t, e.validate_count, 1);
    revision := table_get(*e.manager.scenes, id).revision;
    expect(t, scene_inject(*e.manager, 900, .{ .Load, id, 33, 101, revision
    }));
    expect(t, !scene_inject(*e.manager, 2, .{ .Load, id, 33, 101, revision + 1
    }));
    scene_pump(*h);
    expect(t, e.validate_count == 1, "duplicates and unauthenticated packets cannot rerun policy");
    expect_value(t, scene_event_count(e, .Load_Failed, id), 1);
    e.reject_load = false;
    expect(t, scenes.request_load(srv, id, 1, retry = true));
    scene_pump(*h);
    expect(t, scenes.is_loaded(srv, id, 1));
    expect_value(t, e.validate_count, 2);
    expect_value(t, (e.requests).count, 1);
};

//@endregion
//@region 替换 ACK 屏障与有界等待

scenes_replace_ack_barrier_carries_once_and_tracks_late_peers :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv := *h.endpoints[0];
    srv.manager.config.ready_to_unload = scene_ready_to_unload;
    srv.ready[1] = false;
    old := scene_open(*h, 34, .{
        kind = .Global
    }, true);
    dest := scene_open(*h, 35, .{
        kind = .Global
    }, true);
    scene_pump(*h);
    expect(t, scenes.begin_replace(*srv.manager, old, dest, carry = true));
    scene_pump(*h, 3);
    expect_value(t, srv.carry_count, 1);
    expect(t, srv.gate_calls[0] > 0 && srv.gate_calls[1] > 0);
    expect(t, scenes.is_loaded(*srv.manager, old, 1) && table_get(*srv.held, old));
    expect_value(t, scene_event_count(srv, .Before_Unload, old), 0);
    expect(t, !scenes.set_scope(*srv.manager, dest, .{
        kind = .Connections
    }), "replacement scope is frozen");
    srv.ready[2] = false;
    scene_join(*h, 2, 102);
    scene_pump(*h);
    expect(t, scenes.is_loaded(*srv.manager, dest, 2) && srv.gate_calls[2] > 0);
    srv.ready[1] = true;
    scene_pump(*h, 2);
    expect(t, scenes.is_loaded(*srv.manager, old, 1), "a late peer also needs migration ACK");
    srv.ready[0] = false;
    srv.ready[2] = true;
    scene_pump(*h, 2);
    expect(t, scenes.is_loaded(*srv.manager, old, 2), "local migration can also hold the barrier");
    srv.ready[0] = true;
    scene_pump(*h);
    expect_value(t, srv.carry_count, 1);
    expect_value(t, scene_event_count(srv, .Replace_Committed, old), 1);
    _, exists := scenes.get_info(*srv.manager, old);
    expect(t, !exists);
    expect(t, srv.manager.config.userdata == cast(*void) (srv), "callbacks preserve caller userdata");
};

scenes_replace_ack_timeout_keeps_old_and_never_commits :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv := *h.endpoints[0];
    srv.manager.config.ready_to_unload = scene_ready_to_unload;
    srv.ready[1] = false;
    old := scene_open(*h, 36, .{
        kind = .Global
    });
    dest := scene_open(*h, 37, .{
        kind = .Global
    }, true);
    // begin 在第一次 uptime update 前调用，不能把 uptime 当成等待时长。

    expect(t, scenes.begin_replace(*srv.manager, old, dest, carry = true));
    h.now = 9000000;
    scene_pump(*h);
    expect_value(t, srv.carry_count, 1);
    expect_value(t, scene_event_count(srv, .Timeout, old), 0);
    h.now += 101;
    scene_pump(*h, 2);
    info, exists := scenes.get_info(*srv.manager, old);
    expect(t, exists && info.phase == .Open && info.replacement == 0);
    expect(t, scenes.is_loaded(*srv.manager, old, 1));
    expect_value(t, scene_event_count(srv, .Replace_Failed, old), 1);
    expect_value(t, scene_event_count(srv, .Replace_Committed, old), 0);
    expect_value(t, scene_event_count(srv, .Before_Unload, old), 0);
    count := srv.gate_calls[1];
    scene_pump(*h, 3);
    expect(t, srv.gate_calls[1] == count, "failure ends polling instead of retaining a pending operation forever");
};

//@endregion
//@region Release-first 的实际资源顺序与失败

scenes_release_first_never_holds_both_and_waits_for_physical_release :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv, cli := *h.endpoints[0], *h.endpoints[1];
    old := scene_open(*h, 38, .{
        kind = .Global
    }, true);
    scene_pump(*h);
    for *e: h.endpoints {
        e.*.single_scene = true;
    }

    srv.auto_complete = false;
    cli.auto_complete = false;
    dest, ok := scenes.replace_release_first(*srv.manager, old, 39, .{
        kind = .Global
    }, load_here = true);
    expect(t, ok && dest != old);
    info, exists := scenes.get_info(*srv.manager, dest);
    expect(t, exists && info.phase == .Waiting);
    expect(t, !scenes.is_loaded(*srv.manager, old, 1));
    scene_join(*h, 2, 102); // Waiting 场景不会提前放置晚加入者。

    scene_pump(*h, 3);
    expect_value(t, (srv.pending).count, 0);
    expect_value(t, (h.endpoints[2].requests).count, 0);
    expect_value(t, cli.pending[0].operation, .Unload);
    scene_finish(cli, old);
    scene_pump(*h, 3);
    expect_value(t, srv.pending[0].handle, old);
    expect_value(t, srv.pending[0].operation, .Unload);
    scene_finish(srv, old);
    scene_pump(*h, 3);
    expect_value(t, srv.pending[0].handle, dest);
    expect_value(t, srv.pending[0].operation, .Load);
    expect_value(t, scene_event_count(srv, .Replace_Committed, old), 0);
    scene_finish(srv, dest);
    scene_pump(*h, 3);
    expect_value(t, cli.pending[0].handle, dest);
    expect_value(t, cli.pending[0].operation, .Load);
    scene_finish(cli, dest);
    scene_pump(*h);
    expect(t, scenes.is_loaded(*srv.manager, dest, 1) && scenes.is_loaded(*srv.manager, dest, 2));
    expect_value(t, scene_event_count(srv, .Replace_Committed, old), 1);
    expect_value(t, scene_event_count(srv, .Replace_Failed, old), 0);
    expect_value(t, srv.carry_count, 0);
};

scenes_release_first_failure_does_not_start_target_or_claim_success :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv, cli := *h.endpoints[0], *h.endpoints[1];
    old := scene_open(*h, 40, .{
        kind = .Global
    }, true);
    scene_pump(*h);
    cli.fail_unload = true;
    dest, ok := scenes.replace_release_first(*srv.manager, old, 41, .{
        kind = .Global
    }, load_here = true);
    expect(t, ok);
    scene_pump(*h);
    _, exists := scenes.get_info(*srv.manager, dest);
    expect(t, !exists && table_get(*srv.held, old) && table_get(*cli.held, old));
    expect_value(t, scene_event_count(srv, .Replace_Failed, old), 1);
    expect_value(t, scene_event_count(srv, .Replace_Committed, old), 0);
    expect(t, (srv.requests).count == 1, "failed old release cannot start target loader");
    cli.fail_unload = false;
    expect(t, scenes.close(*srv.manager, old));
    scene_pump(*h);
};

scenes_release_first_target_failure_and_timeout_are_not_commits :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv, cli := *h.endpoints[0], *h.endpoints[1];
    old := scene_open(*h, 42, .{
        kind = .Global
    }, true);
    scene_pump(*h);
    cli.fail_load = true;
    _, ok := scenes.replace_release_first(*srv.manager, old, 43, .{
        kind = .Global
    }, load_here = true);
    expect(t, ok);
    scene_pump(*h, 20);
    expect_value(t, scene_event_count(srv, .Replace_Failed, old), 1);
    expect_value(t, scene_event_count(srv, .Replace_Committed, old), 0);
    expect(t, (srv.held).count == 0, "old scene is not restored after destructive replacement");
    cli.fail_load = false;
    next := scene_open(*h, 44, .{
        kind = .Global
    }, true);
    scene_pump(*h);
    srv.auto_complete = false;
    _, ok = scenes.replace_release_first(*srv.manager, next, 45, .{
        kind = .Global
    }, load_here = true);
    expect(t, ok);
    scene_pump(*h, 4);
    expect_value(t, srv.pending[0].operation, .Unload);
    h.now += 101;
    scene_pump(*h, 2);
    expect_value(t, scene_event_count(srv, .Replace_Failed, next), 1);
    expect_value(t, scene_event_count(srv, .Replace_Committed, next), 0);
    expect(t, table_get(*srv.held, next), "timeout cannot forget an unfinished engine release");
    scene_finish(srv, next);
    scene_pump(*h);
};

//@endregion
//@region Scope 清理失败重试与无 carry 屏障

scenes_scope_reentry_retries_cleanup_before_loading :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    srv, cli := *h.endpoints[0], *h.endpoints[1];
    scope := scenes.Scope.{ .Connections, transport.Connection_Id.[1],
    }

    id := scene_open(*h, 46, scope);
    scene_pump(*h);
    cli.fail_unload = true;
    expect(t, scenes.set_scope(*srv.manager, id, .{
        kind = .Connections
    }));
    expect(t, scenes.set_scope(*srv.manager, id, scope));
    scene_pump(*h);
    expect_value(t, scenes.connection_state(*srv.manager, id, 1), .Unload_Failed);
    expect(t, !scenes.is_loaded(*srv.manager, id, 1));
    cli.fail_unload = false;
    expect(t, scenes.request_unload(*srv.manager, id, 1));
    scene_pump(*h);
    expect(t, scenes.is_loaded(*srv.manager, id, 1), "retry preserves pending scope reentry");
    expect_value(t, (cli.requests).count, 4); // load, failed unload, retried unload, load
};

scenes_replace_gate_without_carry_drops_departed_peer :: (t: *Test) {
    h: Scene_Hub;
    scene_hub_init(*h);
    defer scene_hub_destroy(*h, t);
    scene_join(*h, 1, 101);
    scene_join(*h, 2, 102);
    srv := *h.endpoints[0];
    srv.manager.config.carry = null;
    srv.manager.config.ready_to_unload = scene_ready_to_unload;
    srv.ready[2] = false;
    old := scene_open(*h, 47, .{
        kind = .Global
    });
    dest := scene_open(*h, 48, .{
        kind = .Global
    });
    scene_pump(*h);
    expect(t, scenes.begin_replace(*srv.manager, old, dest));
    scene_pump(*h, 3);
    expect(t, scenes.is_loaded(*srv.manager, old, 1) && srv.gate_calls[2] > 0);
    expect_value(t, srv.carry_count, 0);
    scenes.peer_leave(*srv.manager, 2);
    scenes.disconnect(*h.endpoints[2].manager);
    scene_pump(*h);
    expect_value(t, scene_event_count(srv, .Replace_Committed, old), 1);
    expect_value(t, scene_event_count(srv, .Replace_Failed, old), 0);
    _, exists := scenes.get_info(*srv.manager, old);
    expect(t, !exists);
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
