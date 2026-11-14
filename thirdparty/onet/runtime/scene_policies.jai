#scope_file
objects :: #import "thirdparty/onet/objects";
scenes :: #import "thirdparty/onet/scenes";
transport :: #import "thirdparty/onet/transport";
#scope_export

//@region Explicit typed scene policy binding, no World fields or global state

Scene_Rollback_Barrier :: struct {
    generation, minimum_sequence: u64;
}

Scene_Rollback :: struct {
    target: scenes.Handle;
    barriers: H.Table(transport.Connection_Id, Scene_Rollback_Barrier);
}

Scene_Policy_Binding :: struct {
    world: *World;

    carry: scenes.Carry_Binding;

    rollbacks: H.Table(scenes.Handle, *Scene_Rollback);

    previous_guard: #type (*void, scenes.Handle) -> bool;

    previous_guard_user: *void;
}

// Bind after runtime.init, before replacements. Keep this binding at a stable
// address until scene_policies_unbind succeeds, before destroying the Runtime.
// Existing scene_carry/scene_ready keep their frozen per-peer migration ACK set.

scene_policies_bind :: (b: *Scene_Policy_Binding, w: *World, config: scenes.Carry_Config) -> bool {
    if b.world != null || w == null || !w.initialized || !w.authority || (w.migrations).count != 0 {
        return false;
    }

    for s, _: w.scenes.scenes {
        if s.replacement != 0 || s.release_from != 0 {
            return false;
        }
    }

    if !scenes.carry_binding_init(*b.carry, w.registry, w.scene_callbacks, config) {
        return false;
    }

    if !scenes.bind_carry_policy(*w.scenes, *b.carry.policy) {
        scenes.carry_binding_destroy(*b.carry);
        return false;
    }

    b.world = w;
    b.rollbacks = new_table(scenes.Handle, *Scene_Rollback);
    b.previous_guard, b.previous_guard_user = w.scenes.config.release_guard, w.scenes.config.release_guard_userdata;
    b.carry.on_rollback, b.carry.rollback_userdata = scene_policy_rollback, b;
    w.scene_callbacks = scenes.carry_binding_config(*b.carry);
    w.scenes.config.carry = scene_carry;
    w.scenes.config.release_guard, w.scenes.config.release_guard_userdata = scene_policy_release_guard, b;
    return true;
}

scene_policy_rollback :: (user: *void, old, target: scenes.Handle, ids: [] objects.Network_Id) {
    b := (cast(*Scene_Policy_Binding) user);
    frozen := new_dynamic(objects.Network_Id, 0);
    array_add(*frozen, ..ids);
    // The objects are already restored to old. Freeze this inverse migration too:
    // target resources cannot unload until clients ACK restoration or removal.

    remember_migration(b.world, target, old, frozen);
    r := new_one(Scene_Rollback);
    r.target = old;
    r.barriers = new_table(transport.Connection_Id, Scene_Rollback_Barrier);
    for peer, connection: b.world.peers {
        H.table_set(*r.barriers, connection, .{
            peer.generation, peer.state.next_sequence,
        });
    }

    H.table_set(*b.rollbacks, target, r);
}

scene_policy_release_guard :: (user: *void, h: scenes.Handle) -> bool {
    b := (cast(*Scene_Policy_Binding) user);
    if b.previous_guard != null && !b.previous_guard(b.previous_guard_user, h) {
        return false;
    }

    r, pending := table_get(*b.rollbacks, h);
    if !pending {
        return true;
    }

    for peer, connection: b.world.peers {
        barrier, existed := table_get(*r.barriers, connection);
        if existed && barrier.generation == peer.generation && (barrier.minimum_sequence == 0 || peer.state.acknowledged < barrier.minimum_sequence) {
            return false;
        }

        if !migration_ready(b.world, h, r.target, connection) {
            return false;
        }
    }

    forget_migration(b.world, h);
    release(r.barriers);
    free(r);
    H.table_remove(*b.rollbacks, h);
    return true;
}

// Optional housekeeping when a failed destination stays open. Close itself also
// polls its guard automatically; no application pumping is needed for safety.

scene_policies_update :: (b: *Scene_Policy_Binding) {
    if b.world == null {
        return;
    }

    for _, h: b.rollbacks {
        scene_policy_release_guard(b, h);
    }
}

scene_policies_unbind :: (b: *Scene_Policy_Binding) -> bool {
    if b.world == null {
        return true;
    }

    w := b.world;
    scene_policies_update(b);
    if (w.migrations).count != 0 || (b.rollbacks).count != 0 || (b.carry.policy.transactions).count != 0 {
        return false;
    }

    for s, _: w.scenes.scenes {
        if s.replacement != 0 || s.release_from != 0 || s.local.busy {
            return false;
        }
    }

    w.scene_callbacks = b.carry.callbacks;
    w.scenes.config.carry = null;
    if w.scene_callbacks.carry != null {
        w.scenes.config.carry = scene_carry;
    }

    w.scenes.config.release_guard, w.scenes.config.release_guard_userdata = b.previous_guard, b.previous_guard_user;
    if w.scenes.config.carry_policy == *b.carry.policy {
        w.scenes.config.carry_policy = null;
        b.carry.policy.manager = null;
    }

    scenes.carry_binding_destroy(*b.carry);
    release(b.rollbacks);
    b.* = .{
    };
    return true;
};

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
