#scope_file

#scope_export

//@region Shared loader scheduler and physical resource ownership

Resource_Key :: struct {
    namespace: u64;
    handle: Handle;
}

Loader_Ticket :: struct {
    key: Resource_Key;
    asset: Asset_Id;
    serial: u64;
    operation: Operation;
}

Loader_Config :: struct {
    userdata: *void;

    request: #type (*void, Loader_Ticket);

    cancel: #type (*void, Loader_Ticket);
    // advisory; completion remains mandatory

    max_operations: int;
    // 0 unlimited, >0 global across every borrowing Manager

    max_resident: int;
    // 0 unlimited physical scenes, not simultaneous operations

    max_resources, max_requests: int;
}

Loader_Request :: struct {
    manager: *Manager;
    ticket: Ticket;
    cancelled, cancel_sent, cleanup, cleanup_failed: bool;
    order: u64;
}

Loader_Resource :: struct {
    asset: Asset_Id;

    held: bool;

    owners: H.Table(*Manager, bool);

    queue: [..] *Loader_Request;

    active: *Loader_Request;

    physical: Loader_Ticket;
}

Loader_Completion :: struct {
    ticket: Loader_Ticket;
    success: bool;
}

Loader_Progress :: struct {
    ticket: Loader_Ticket;
    value: float32;
}

Loader :: struct {
    config: Loader_Config;

    resources: H.Table(Resource_Key, *Loader_Resource, hash_Resource_Key, equal_Resource_Key);

    next_serial, next_order: u64;

    active, requests: int;

    stopping, initialized: bool;

    mutex: Thread.Mutex;

    completions, draining: [..] Loader_Completion;

    progress, draining_progress: [..] Loader_Progress;
}

loader_init :: (l: *Loader, config: Loader_Config) -> bool {
    if l.initialized || config.request == null || config.max_operations < 0 || config.max_resident < 0 {
        return false;
    }

    l.config = config;
    if l.config.max_resources <= 0 {
        l.config.max_resources = 1024;
    }

    if l.config.max_requests <= 0 {
        l.config.max_requests = 4096;
    }

    l.resources = new_table(Resource_Key, *Loader_Resource, hash_function = hash_Resource_Key, compare_function = equal_Resource_Key);
    l.next_serial, l.next_order = 1, 1;
    Thread.init(*l.mutex);
    l.initialized = true;
    return true;
}

loader_key :: (m: *Manager, h: Handle) -> Resource_Key {
    ns := m.config.loader_namespace;
    if ns == 0 {
        ns = (cast, trunc(u64)((cast, trunc(u64) m)));
    }
    // host sharing is explicit, never asset-ID aliasing

    return .{
        ns, h,
    };
}

loader_submit :: (l: *Loader, m: *Manager, t: Ticket) -> bool {
    if !l.initialized || (l.stopping && t.operation == .Load) || l.requests >= l.config.max_requests || l.next_order == 0 {
        return false;
    }

    key := loader_key(m, t.handle);
    r := table_get(*l.resources, key);
    if r == null {
        if (l.resources).count >= l.config.max_resources {
            return false;
        }

        r = new_one(Loader_Resource);
        r.asset = t.asset;
        r.owners = new_table(*Manager, bool);
        H.table_set(*l.resources, key, r);
    }

    if r.asset != t.asset {
        return false;
    }

    q := new_one(Loader_Request);
    q.* = .{
        manager = m, ticket = t, order = l.next_order,
    };
    l.next_order += 1;
    array_add(*r.queue, q);
    l.requests += 1;
    return true;
};

loader_report :: (l: *Loader, q: *Loader_Request, success: bool) {
    queue_completion(q.manager, q.ticket, success, q.ticket.operation);
    l.requests -= 1;
    free(q);
}

// Queued loads cancel immediately; active loads retain ownership until physical
// completion and compensating unload. Never cancel the last owner's release.

loader_cancel :: (l: *Loader, m: *Manager, t: Ticket) -> bool {
    if !l.initialized || t.operation != .Load {
        return false;
    }

    r := table_get(*l.resources, loader_key(m, t.handle));
    if r == null {
        return false;
    }

    for q, i: r.queue {
        if q.manager == m && q.ticket == t {
            array_ordered_remove_by_index(*r.queue, i);
            loader_report(l, q, false);
            return true;
        }
    }

    q := r.active;
    if q == null || q.manager != m || q.ticket != t {
        return false;
    }

    q.cancelled = true;
    if !q.cleanup && !q.cancel_sent && l.config.cancel != null {
        q.cancel_sent = true;
        l.config.cancel(l.config.userdata, r.physical);
    }

    return true;
}

// Any-thread completion ingestion; the stable Loader must outlive all producers.

loader_complete :: (l: *Loader, t: Loader_Ticket, success: bool) -> bool {
    if t.serial == 0 || t.key.handle == 0 {
        return false;
    }

    Thread.lock(*l.mutex);
    defer Thread.unlock(*l.mutex);
    if !l.initialized {
        return false;
    }

    array_add(*l.completions, .{
        t, success
    });
    return true;
};

loader_resident_count :: (l: *Loader) -> (count: int) {
    for r, _: l.resources {
        if r.held || (r.active != null && !r.active.cleanup && r.physical.operation == .Load) {
            count += 1;
        }
    };
    return;
}

loader_start :: (l: *Loader, key: Resource_Key, r: *Loader_Resource, q: *Loader_Request, op: Operation) -> bool {
    if l.next_serial == 0 {
        return false;
    }

    r.active = q;
    r.physical = .{
        key, r.asset, l.next_serial, op,
    };
    l.next_serial += 1;
    l.active += 1;
    l.config.request(l.config.userdata, r.physical);
    return true;
};

loader_update :: (l: *Loader) {
    if !l.initialized {
        return;
    }

    Thread.lock(*l.mutex);
    l.completions, l.draining = l.draining, l.completions;
    Thread.unlock(*l.mutex);
    Thread.lock(*l.mutex);
    l.progress, l.draining_progress = l.draining_progress, l.progress;
    Thread.unlock(*l.mutex);
    for update: l.draining_progress {
        r := table_get(*l.resources, update.ticket.key);
        if r != null && r.active != null && !r.active.cleanup && !r.active.cancelled && r.physical == update.ticket {
            notify_load_progress(r.active.manager, r.active.ticket, update.value);
        }
    }

    array_reset_keeping_memory(*l.draining_progress);
    for done: l.draining {
        r := table_get(*l.resources, done.ticket.key);
        if r == null || r.active == null || r.physical != done.ticket {
            continue;
        }

        q := r.active;
        l.active -= 1;
        if q.cleanup {
            if !done.success {
                q.cleanup_failed = true;
                r.physical = .{
                };
                continue;
            };
            // explicit retry, never forget held resources

            r.held = false;
            r.active = null;
            loader_report(l, q, false);
        } else if q.ticket.operation == .Load {
            if !done.success {
                r.active = null;
                loader_report(l, q, false);
                continue;
            }

            r.held = true;
            if q.cancelled || l.stopping {
                q.cleanup = true;
                if !loader_start(l, done.ticket.key, r, q, .Unload) {
                    q.cleanup_failed = true;
                    r.physical = .{
                    };
                }
            } else {
                H.table_set(*r.owners, q.manager, true);
                r.active = null;
                loader_report(l, q, true);
            }
        } else {
            if done.success {
                r.held = false;
                H.table_remove(*r.owners, q.manager);
            }

            r.active = null;
            loader_report(l, q, done.success);
        }
    }

    array_reset_keeping_memory(*l.draining);
    while true {
        chosen: *Loader_Resource;
        key: Resource_Key;
        best: *Loader_Request;
        for r, k: l.resources {
            if r.active != null || (r.queue).count == 0 {
                continue;
            }

            q := r.queue[0];
            physical := !q.cancelled && ((q.ticket.operation == .Load && !r.held) || (q.ticket.operation == .Unload && r.held && table_get(*r.owners, q.manager) && (r.owners).count == 1));
            if physical {
                if l.config.max_operations > 0 && l.active >= l.config.max_operations {
                    continue;
                }

                if q.ticket.operation == .Load && l.config.max_resident > 0 && loader_resident_count(l) >= l.config.max_resident {
                    continue;
                }
            }

            if best == null || q.order < best.order {
                chosen, key, best = r, k, q;
            }
        }

        if chosen == null {
            break;
        }

        r, q := chosen, best;
        array_ordered_remove_by_index(*r.queue, 0);
        if q.cancelled || (l.stopping && q.ticket.operation == .Load) {
            loader_report(l, q, false);
            continue;
        }

        if q.ticket.operation == .Load && r.held {
            H.table_set(*r.owners, q.manager, true);
            loader_report(l, q, true);
            continue;
        }

        if q.ticket.operation == .Unload && (!r.held || !table_get(*r.owners, q.manager)) {
            loader_report(l, q, true);
            continue;
        }

        if q.ticket.operation == .Unload && (r.owners).count > 1 {
            H.table_remove(*r.owners, q.manager);
            loader_report(l, q, true);
            continue;
        }

        if !loader_start(l, key, r, q, q.ticket.operation) {
            loader_report(l, q, false);
        }
    }

    for r, key: l.resources {
        if !r.held && r.active == null && (r.queue).count == 0 && (r.owners).count == 0 {
            release(r.queue);
            release(r.owners);
            free(r);
            H.table_remove(*l.resources, key);
        }
    }
}

loader_retry_cleanup :: (l: *Loader, key: Resource_Key) -> bool {
    r := table_get(*l.resources, key);
    if r == null || r.active == null || !r.active.cleanup_failed {
        return false;
    }

    if l.config.max_operations > 0 && l.active >= l.config.max_operations {
        return false;
    }

    r.active.cleanup_failed = false;
    return loader_start(l, key, r, r.active, .Unload);
}

loader_reference_count :: (l: *Loader, key: Resource_Key) -> int {
    r := table_get(*l.resources, key);
    if r == null {
        return 0;
    };
    return (r.owners).count;
}

loader_shutdown :: (l: *Loader) {
    if !l.initialized {
        return;
    };
    l.stopping = true;
    // Owners are NOT force-released: managers must pass their existing migration
    // and remote-unload ACK barriers before submitting final releases.

    for r, _: l.resources {
        {
            i := (r.queue).count - 1;
            while i >= 0 {
                defer i -= 1;
                q := r.queue[i];
                if q.ticket.operation == .Load {
                    array_ordered_remove_by_index(*r.queue, i);
                    loader_report(l, q, false);
                }
            }
        }

        {
            q := r.active;
            if
            q != null && q.ticket.operation == .Load {
                loader_cancel(l, q.manager, q.ticket);
            }
        }
    }
}

loader_destroy :: (l: *Loader) -> bool {
    if !l.initialized {
        return true;
    }

    if !l.stopping || (l.resources).count != 0 || l.requests != 0 || l.active != 0 {
        return false;
    }

    // Caller has stopped/joined completion producers before destruction.

    Thread.lock(*l.mutex);
    l.initialized = false;
    release(l.completions);
    Thread.unlock(*l.mutex);
    release(l.progress);
    release(l.draining_progress);
    release(l.draining);
    release(l.resources);
    Thread.destroy(*l.mutex);
    l.* = .{
    };
    return true;
};

//@endregion
//@region Physical progress and externally vanished shared content

loader_notify_progress :: (l: *Loader, t: Loader_Ticket, progress: float32) -> bool {
    if t.serial == 0 || t.operation != .Load || Math.isnan(progress) || Math.isinf(progress) {
        return false;
    }

    Thread.lock(*l.mutex);
    defer Thread.unlock(*l.mutex);
    if !l.initialized || (l.progress).count >= MAX_PROGRESS_UPDATES {
        return false;
    }

    array_add(*l.progress, .{
        t, progress
    });
    return true;
};

// Loop-only. Called only after the engine has destroyed the physical content.
// Refuse while a producer owns a physical operation: it must first be cancelled
// and completed. Queued logical requests are explicitly settled, never leaked.

loader_external_unload :: (l: *Loader, m: *Manager, h: Handle) -> bool {
    if !l.initialized {
        return false;
    }

    key := loader_key(m, h);
    r := table_get(*l.resources, key);
    if r == null {
        return true;
    }

    if r.active != null {
        return false;
    }

    for _, owner: r.owners {
        if owner == m {
            continue;
        }

        {
            s := table_get(*owner.scenes, h);
            if
            s != null {
                s.local.held, s.local.desired = false, false;
                s.phase = .Closing;
                // The owning authority is forgetting this instance, not asking for a
                // new release: don't invent an unsolicited host-client report.

                s.report_ready, s.report_sent = true, true;
            }
        }
    }

    for q: r.queue {
        loader_report(l, q, q.ticket.operation == .Unload);
    }

    release(r.queue);
    release(r.owners);
    free(r);
    H.table_remove(*l.resources, key);
    return true;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.

operator == :: (a, b: Resource_Key) -> bool {
    return a.namespace == b.namespace && a.handle == b.handle;
}

operator == :: (a, b: Loader_Ticket) -> bool {
    return a.key == b.key && a.asset == b.asset && a.serial == b.serial && a.operation == b.operation;
}

operator == :: (a, b: Ticket) -> bool {
    return a.handle == b.handle && a.asset == b.asset && a.serial == b.serial && a.revision == b.revision && a.operation == b.operation;
}

// Cast semantics adapted.
