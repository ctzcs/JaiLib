#scope_module
KeyHash :: #import "Hash";

hash_Assembly_Key :: (k: Assembly_Key) -> u32 {
    return KeyHash.get_hash(k.invoker, KeyHash.get_hash(k.connection, cast(u32) 5381));
}

equal_Assembly_Key :: (a, b: Assembly_Key) -> bool {
    return a.connection == b.connection && a.invoker == b.invoker;
}
