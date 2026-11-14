// Jai equivalents of the public ID macros in upstream/include/box2d/id.h.
B2_IS_NULL :: (id: $T) -> bool {
    return id.index1 == 0;
}

B2_IS_NON_NULL :: (id: $T) -> bool {
    return id.index1 != 0;
}

// As in C, ID_EQUALS accepts body/shape/chain/joint IDs, not world IDs.
B2_ID_EQUALS :: (a: $T, b: T) -> bool {
    return a.index1 == b.index1 && a.world0 == b.world0 && a.generation == b.generation;
}
