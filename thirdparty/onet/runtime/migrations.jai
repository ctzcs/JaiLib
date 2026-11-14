#scope_file
core :: #import "thirdparty/onet/core";
objects :: #import "thirdparty/onet/objects";
scenes :: #import "thirdparty/onet/scenes";
transport :: #import "thirdparty/onet/transport";
#scope_export

//@region 有界迁移ACK集合

Migration :: struct {
    target: scenes.Handle;
    objects: [..] objects.Network_Id;
}

migration_candidates :: (w: *World, old: scenes.Handle) -> (ids: [..] objects.Network_Id) {
    for obj, id: w.registry.objects {
        if obj != null && obj.active && obj.scene == (cast, trunc(u32)(old)) {
            array_add(*ids, id);
        }
    }

    return;
}

forget_migration :: (w: *World, old: scenes.Handle) {
    {
        m := table_get(*w.migrations, old);
        if
        m != null {
            release(m.objects);
            free(m);
            H.table_remove(*w.migrations, old);
        }
    }
}

remember_migration :: (w: *World, old, target: scenes.Handle, candidates: [..] objects.Network_Id) {
    ids := candidates; // 接管数组；仅在这里调整本机数组头。

    forget_migration(w, old);
    kept := 0;
    for id: ids {
        {
            obj, ok := objects.get(w.registry, id);
            if
            ok && obj.scene == (cast, trunc(u32)(target)) {
                ids[kept] = id;
                kept += 1;
            }
        }
    }

    array_resize(*ids, kept);
    m := new_one(Migration);
    m.target, m.objects = target, ids;
    H.table_set(*w.migrations, old, m);
}

migration_ready :: (w: *World, old, target: scenes.Handle, connection: transport.Connection_Id) -> bool {
    m := table_get(*w.migrations, old);
    if m == null || m.target != target || (m.objects).count == 0 {
        return true;
    }

    p := table_get(*w.peers, connection);
    if p == null {
        return true;
    }

    ack := objects.snapshot_find(view(p.state.sent, 0), p.state.acknowledged);
    if ack == null {
        return false;
    }

    for id: m.objects {
        image := objects.image_find(ack, id);
        obj, exists := objects.get(w.registry, id);
        if !exists || !visible(obj, connection, w) {
            if image.data != null {
                return false;
            }

            continue;
        }

        if image.data == null || obj.scene == (cast, trunc(u32)(old)) {
            return false;
        }

        r: core.Reader;
        core.reader_init(*r, image);
        _ = core.read_uint32(*r, .Uncompressed);
        if core.read_uint32(*r, .Uncompressed) != obj.scene || r.err != .None {
            return false;
        }
    }

    return true;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
