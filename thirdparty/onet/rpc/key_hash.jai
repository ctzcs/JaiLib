#scope_module
KeyHash :: #import "Hash";

hash_Receive_Key :: (k: Receive_Key) -> u32 {
    return KeyHash.get_hash(k.channel, KeyHash.get_hash(k.connection, cast(u32) 5381));
}

equal_Receive_Key :: (a, b: Receive_Key) -> bool {
    return a.connection == b.connection && a.channel == b.channel;
}
