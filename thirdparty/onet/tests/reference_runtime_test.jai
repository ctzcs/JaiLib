#scope_file
objects :: #import "thirdparty/onet/objects";
nr :: #import "thirdparty/onet/runtime";
session :: #import "thirdparty/onet/session";
transport :: #import "thirdparty/onet/transport";
#scope_export

//@region 真实对象流中的接收端引用与生命周期

RR_State :: struct {
    target: nr.Object_Reference;
}

rr_free :: (p: *void) {
    free((cast(*RR_State) p));
}

rr_factory :: () -> *objects.Component {
    st := new_one(RR_State);
    c := objects.component_make(9924);
    c.userdata, c.destroy_userdata = st, rr_free;
    objects.member_custom(c, *st.target, nr.object_reference_codec(0x1B800));
    return c;
}

rr_hidden :: (obj: *objects.Network_Object, connection: transport.Connection_Id, user: *void) -> bool {
    return obj.id != 2 || !((cast(*bool) user)).*;
}

reference_runtime_resolves_late_admission_local_instance_and_withdrawal :: (t: *Test) {
    s, a: RT_Node;
    rt_init(*s, true);
    rt_init(*a, false);
    defer rt_shutdown((*RT_Node).[*s, *a]);
    objects.register_factory(*s.reg, 9924, rr_factory);
    objects.register_factory(*a.reg, 9924, rr_factory);
    source := objects.spawn(*s.reg, 0);
    array_add(*source.components, rr_factory());
    target := rt_spawn(*s, 8);
    st := (cast(*RR_State) source.components[0].userdata);
    assert(nr.object_reference_set_target(*s.r.server, *st.target, target));
    hidden := true;
    s.r.server.visibility, s.r.server.visibility_userdata = rr_hidden, *hidden;
    assert(session.start_server(*s.s, 0) && session.start_client(*a.s, "127.0.0.1", session.bound_port(*s.s)));
    nodes := (*RT_Node).[*s, *a];
    rt_pump(nodes, 80);
    mirror, ok := objects.get(*a.reg, source.id);
    if !expect(t, ok) {
        return;
    }

    ref := *((cast(*RR_State) mirror.components[0].userdata)).target;
    expect(t, nr.object_reference_target(*a.r.client, ref) == null && ref.identity.id == (cast, trunc(u64)(target.id)));
    hidden = false;
    rt_pump(nodes, 60);
    local := nr.object_reference_target(*a.r.client, ref);
    expect(t, local != null && local != target && local.id == target.id);
    hidden = true;
    rt_pump(nodes, 60);
    expect(t, nr.object_reference_target(*a.r.client, ref) == null);
    hidden = false;
    rt_pump(nodes, 60);
    expect(t, nr.object_reference_target(*a.r.client, ref) != null);
    assert(objects.despawn(*s.reg, target.id));
    rt_pump(nodes, 60);
    expect(t, nr.object_reference_target(*a.r.client, ref) == null && ref.identity.id != 0);
}

//@endregion
//@region Registry身份耗尽

reference_runtime_object_ids_never_wrap_or_overwrite_tombstones :: (t: *Test) {
    reg: objects.Registry;
    objects.registry_init(*reg);
    defer objects.registry_destroy(*reg);
    reg.next_id = (cast, trunc(u32)(4294967295));
    last := objects.spawn(*reg, 0);
    expect(t, last != null && (cast, trunc(u32)(last.id)) == (cast, trunc(u32)(4294967295)) && reg.next_id == 0);
    expect(t, objects.spawn(*reg, 0) == null && reg.active_count == 1);
    reg.next_id = (cast, trunc(u32)(4294967295));
    expect(t, objects.spawn(*reg, 0) == null && table_get(*reg.objects, last.id) == last);
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
