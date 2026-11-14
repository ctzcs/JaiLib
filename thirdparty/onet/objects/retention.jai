#scope_file
transport :: #import "thirdparty/onet/transport";
#scope_export
// 控制权租约不是登录凭据。identity必须来自服务器已验证身份，不可直接信任客户端。
//@region 控制权租约

Control_Token :: struct {
    object: Network_Id;
    generation: u64;
}

Control_Retention :: struct {
    generation: u64;
    identity: string;
    expires_ms: s64;
}

// Revoke without reusing generations. Also safe for an absent record.

forget_retained :: (reg: *Registry, id: Network_Id) {
    record, exists := table_get(*reg.retained, id);
    if !exists {
        return;
    }

    release(record.identity);
    H.table_set(*reg.retained, id, .{
    });
}

retain_controller :: (reg: *Registry, id: Network_Id, identity: string, now_ms: s64, duration_ms: int) -> (Control_Token, bool) {
    obj, ok := get(reg, id);
    if !ok || !reg.authoritative || (identity).count == 0 || (identity).count > 256 || duration_ms <= 0 || duration_ms > 24 * 60 * 60 * 1000 || reg.next_retention == 0 || now_ms > (cast, trunc(s64)(9223372036854775807)) - (cast, trunc(s64)(duration_ms)) {
        return .{
        }, false;
    };

    // identity may itself be borrowed from the current record.

    record := Control_Retention.{
        generation = reg.next_retention, identity = copy_string(identity), expires_ms = now_ms + (cast, trunc(s64)(duration_ms)),
    };

    forget_retained(reg, id);
    reg.next_retention += 1;
    H.table_set(*reg.retained, id, record);
    obj.owner = SERVER_OWNED;
    return Control_Token.{
        id, record.generation,
    }, true;
};

claim_controller :: (reg: *Registry, token: Control_Token, connection: transport.Connection_Id, verified_identity: string, now_ms: s64) -> bool {
    obj, ok := get(reg, token.object);
    record := table_get(*reg.retained, token.object);
    if !ok || !reg.authoritative || connection == 0 || obj.owner != SERVER_OWNED || token.generation == 0 || record.generation != token.generation || record.identity == "" || record.identity != verified_identity || now_ms >= record.expires_ms {
        return false;
    }

    obj.owner = connection;
    forget_retained(reg, token.object);
    return true;
}

expire_retained :: (reg: *Registry, now_ms: s64) {
    for record, id: reg.retained {
        obj, exists := get(reg, id);
        if record.generation != 0 && (!exists || obj.owner != SERVER_OWNED || now_ms >= record.expires_ms) {
            forget_retained(reg, id);
        }
    }
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
