#scope_file
c :: #import "thirdparty/onet/collections";
#scope_export

COLLECTION_ELEMENT_LIMIT :: c.MAX_ELEMENTS;

//@region Collection codecs and runtime scheduling
// Register initialized owners with member_custom. Factories configure the same
// schemas, element codecs, comparator, limits and desired history on all peers.

collection_sequence_codec :: ($T: Type, schema: u32) -> Value_Codec {
    b := c.sequence_bridge(T, schema);
    return .{
        schema = b.schema, write = b.write, read = b.read, destroy = b.destroy,
        begin_tick = (p: *void, tick: u64) {
            c.sequence_tick((cast(*c.Sequence(T)) p), tick);
        },
        set_replaying = (p: *void, replaying: bool) {
            ((cast(*c.Sequence(T)) p)).timeline.replaying = replaying;
        },
    }
}

collection_dictionary_codec :: ($K, $V: Type, schema: u32) -> Value_Codec {
    b := c.dictionary_bridge(K, V, schema);
    return .{
        schema = b.schema, write = b.write, read = b.read, destroy = b.destroy,
        begin_tick = (p: *void, tick: u64) {
            c.dictionary_tick((cast(*c.Dictionary(K, V)) p), tick);
        },
        set_replaying = (p: *void, replaying: bool) {
            ((cast(*c.Dictionary(K, V)) p)).timeline.replaying = replaying;
        },
    }
}

collection_hashset_codec :: ($T: Type, schema: u32) -> Value_Codec {
    b := c.hashset_bridge(T, schema);
    return .{
        schema = b.schema, write = b.write, read = b.read, destroy = b.destroy,
        begin_tick = (p: *void, tick: u64) {
            c.dictionary_tick(*((cast(*c.HashSet(T)) p)).dictionary, tick);
        },
        set_replaying = (p: *void, replaying: bool) {
            ((cast(*c.HashSet(T)) p)).dictionary.timeline.replaying = replaying;
        },
    }
}

// Call before the fixed-tick simulation/inbound apply. Idempotent for a repeated
// tick clears tick-local Changes and consumed pulls, not unread commit events.
// This is deliberately independent of serving/ACKing any individual connection.

begin_tick :: (reg: *Registry, tick: u64) {
    // Replaying historical ticks must not drain a live tick's unsent log or
    // rewind its non-predictable collection history.

    if !reg.replaying && (!reg.collection_tick_started || tick >= reg.collection_tick) {
        reg.collection_tick = tick;
        reg.collection_tick_started = true;
    }

    for obj, _: reg.objects {
        if obj != null && obj.active {
            collection_sync_object(reg, obj, !reg.replaying);
        }
    }
}

// Collections are not predictable: every public mutator refuses local writes
// during replay, including equal/no-op writes. Authoritative wire reads remain
// legal and preserve the replay flag. Call false in a defer after replay.

set_replaying :: (reg: *Registry, replaying: bool) {
    reg.replaying = replaying;
    for obj, _: reg.objects {
        if obj != null {
            collection_sync_object(reg, obj, false);
        }
    }
}

collection_sync_object :: (reg: *Registry, obj: *Network_Object, tick: bool) {
    for comp: obj.components {
        for *m: comp.members {
            if m.*.kind != .Custom {
                continue;
            }

            if tick && reg.collection_tick_started && m.*.codec.begin_tick != null {
                m.*.codec.begin_tick(m.*.ptr, reg.collection_tick);
            }

            if m.*.codec.set_replaying != null {
                m.*.codec.set_replaying(m.*.ptr, reg.replaying);
            }
        }
    }
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
