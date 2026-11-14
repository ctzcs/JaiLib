#scope_module
KeyHash :: #import "Hash";

hash_Reference :: (k: Reference) -> u32 {
    return KeyHash.get_hash(k.generation, KeyHash.get_hash(k.id, cast(u32) 5381));
}

equal_Reference :: (a, b: Reference) -> bool {
    return a.id == b.id && a.generation == b.generation;
}
