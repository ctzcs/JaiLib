#scope_file

#scope_export

//@region 布局与批量结构变更

World_Selection :: (id: System_Id, user: *void) -> bool;

world_layout_hash :: (w: *Simulation_World, selection: World_Selection = null, user: *void = null, incarnations: [] u64 = .[]) -> u32 {
    h := (cast, trunc(u32)(2166136261));
    for s, i: w.systems {
        if selection != null && !selection(s.config.id, user) {
            continue;
        }

        inc := s.config.incarnation;
        if (incarnations).count > 0 {
            inc = incarnations[i];
        }

        for n: (u64.[(cast, trunc(u64)(s.config.id)), (cast, trunc(u64)(s.config.schema)), inc, (cast, trunc(u64)(s.config.state_size)), (cast, trunc(u64)(s.config.input_size))]) {
            {
                j := 0;
                while j < 8 {
                    defer j += 1;
                    h = (h ^ (cast, trunc(u32)((cast, trunc(u8)(n >> (cast, trunc(u64)(j * 8))))))) * 16777619;
                }
            }
        }
    }

    return (ifx h == 0 then 1 else h);
}

// 先移除全部无效userdata，再重建一次；结构批量销毁不会访问另一已销毁对象。

world_unregister_batch :: (w: *Simulation_World, ids: [] System_Id) -> int {
    if !w.initialized || w.busy {
        return 0;
    }

    kept, removed := 0, 0;
    for s: w.systems {
        remove_flag := false;
        for id: ids {
            if s.config.id == id {
                remove_flag = true;
                break;
            }
        }

        if remove_flag {
            release(s.config.defaults, w.allocator);
            release(s.config.carry_mask, w.allocator);
            free(s, w.allocator);
            removed += 1;
        } else {
            w.systems[kept] = s;
            kept += 1;
        }
    }

    array_resize(*w.systems, kept);
    if removed > 0 {
        world_rebuild(w);
    }

    return removed;
}

world_has_owner :: (w: *Simulation_World, owner: u32) -> bool {
    for s: w.systems {
        if (cast, trunc(u32)(s.config.owner)) == owner {
            return true;
        }
    }

    return false;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
