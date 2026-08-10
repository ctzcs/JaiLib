// simple_array.jai
// Port of Ascension/tlib/container/simple_array.odin
// A fixed-capacity array with an alive-count watermark.
// add_element returns a pointer to the newly added element, or null when full.
//
// Note: in the Odin original the struct took ($T: typeid, $N: int) and the
// constructor passed max_size at runtime; here the capacity is a compile-time
// parameter $N (equivalent behavior: fixed capacity, watermark tracking).

Simple_Array :: struct(T: Type, N: int) {
    data:     [N] T;
    alive:    int;
    max_size: int;
}

new_simple_array :: ($T: Type, $N: int) -> Simple_Array(T, N) {
    result: Simple_Array(T, N);
    result.alive    = 0;
    result.max_size = N;
    return result;
}

add_element :: (sa: *Simple_Array($T, $N), elem: T) -> *T {
    if sa.alive >= sa.max_size {
        return null;
    }
    sa.data[sa.alive] = elem;
    sa.alive += 1;
    return *sa.data[sa.alive - 1];
}
