// Jai equivalents of the public ID macros in upstream/include/box3d/id.h.
B3_IS_NULL :: (id: $T) -> bool {
    return id.index1 == 0;
}

B3_IS_NON_NULL :: (id: $T) -> bool {
    return id.index1 != 0;
}

// As in C, ID_EQUALS accepts body/shape/joint/contact IDs, not world IDs.
B3_ID_EQUALS :: (a: $T, b: T) -> bool {
    return a.index1 == b.index1 && a.world0 == b.world0 && a.generation == b.generation;
}
