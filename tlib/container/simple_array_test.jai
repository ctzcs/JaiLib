#import "Basic";
#import "test_support";
#import "container/simple_array";

// Port of the semantics of Ascension/tlib (simple_array had no Odin test file;
// these cases exercise the documented behavior of Simple_Array).

test_simple_array :: (state: *Test_State) {
    sa := new_simple_array(int, 3);
    expect(state, sa.max_size == 3, "max_size is 3");
    expect(state, sa.alive == 0, "alive starts at 0");

    p0 := add_element(*sa, 10);
    expect(state, p0 != null, "add returns pointer for first element");
    p1 := add_element(*sa, 20);
    p2 := add_element(*sa, 30);
    expect(state, sa.alive == 3, "alive is 3 after 3 adds");

    p3 := add_element(*sa, 40);
    expect(state, p3 == null, "add beyond capacity returns null");
    expect(state, sa.alive == 3, "alive unchanged when full");

    expect(state, sa.data[0] == 10, "data[0] == 10");
    expect(state, sa.data[1] == 20, "data[1] == 20");
    expect(state, sa.data[2] == 30, "data[2] == 30");

    <<p1 = 99;
    expect(state, sa.data[1] == 99, "returned pointer can write through");
    expect(state, <<p0 == 10, "deref of first pointer reads 10");
}
