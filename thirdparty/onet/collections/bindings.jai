#scope_file
core :: #import "thirdparty/onet/core";
v :: #import "thirdparty/onet/values";
#scope_export

Bridge_Writer :: core.Writer;

//@region Explicit object bindings
// Initialized containers ARE bindings, not values.Binding(T). Their owning
// network value contains the authoritative state, sparse prior heads and a
// bounded revision/tick journal. Per-peer ACK byte deltas therefore retain all
// unseen operations independently of serialization order and dropped packets.
// A new observer starts at the absolute baseline without historical events.
// A journal gap recovers absolutely; no guessed operations are emitted.

sequence_bridge :: ($T: Type, schema: u32) -> v.Bridge {
    if schema == 0 {
        return .{
        };
    }

    return .{
        schema = schema,
        write = (w: *core.Writer, p: *void) {
            sequence_network_write((cast(*Sequence(T)) p), w);
        },
        read = (r: *core.Reader, p: *void) -> bool {
            return sequence_network_read((cast(*Sequence(T)) p), r);
        },
        destroy = (p: *void) {
            destroy((cast(*Sequence(T)) p));
        },
    }
}

dictionary_bridge :: ($K, $V: Type, schema: u32) -> v.Bridge {
    if schema == 0 {
        return .{
        };
    }

    return .{
        schema = schema,
        write = (w: *core.Writer, p: *void) {
            map_network_write((cast(*Dictionary(K, V)) p), w);
        },
        read = (r: *core.Reader, p: *void) -> bool {
            return map_network_read((cast(*Dictionary(K, V)) p), r);
        },
        destroy = (p: *void) {
            dictionary_destroy((cast(*Dictionary(K, V)) p));
        },
    }
}

hashset_bridge :: ($T: Type, schema: u32) -> v.Bridge {
    if schema == 0 {
        return .{
        };
    }

    return .{
        schema = schema,
        write = (w: *core.Writer, p: *void) {
            map_network_write(*((cast(*HashSet(T)) p)).dictionary, w);
        },
        read = (r: *core.Reader, p: *void) -> bool {
            return map_network_read(*((cast(*HashSet(T)) p)).dictionary, r);
        },
        destroy = (p: *void) {
            hashset_destroy((cast(*HashSet(T)) p));
        },
    }
}

//@endregion
// Cast semantics adapted.
// Loop scopes adapted.
// Iterator semantics adapted.
