#import "Basic";
#import "test_support";
#import "container/simple_array_test";
#import "debug/debug_test";
#import "profiler/profiler_test";
#import "handle/handle_array/handle_array_test";
#import "handle/handle_map_fixed/handle_map_test";
#import "handle/handle_map_growing/handle_map_test";
#import "handle/handle_map_virtual/handle_map_test";
#import "entities/entities_test";
#import "encoding/encoding_test";
#import "tween/tween_test";

// tlib self-test runner. Build with:
//   jai -no_cwd -import_dir tlib tlib/run_tests.jai
// Module test files are imported below as they are ported.

main :: () {
    all_ok := true;

    // container
    st := test_begin(); test_simple_array(*st); all_ok &= test_summary("container/simple_array", *st);

    // debug
    st = test_begin(); test_debug(*st); all_ok &= test_summary("debug", *st);

    // profiler
    st = test_begin(); test_profiler(*st); all_ok &= test_summary("profiler", *st);

    // handle/handle_array
    st = test_begin(); test_handle_array(*st); all_ok &= test_summary("handle/handle_array", *st);

    // handle/handle_map_fixed
    st = test_begin(); test_handle_map_fixed(*st); all_ok &= test_summary("handle/handle_map_fixed", *st);

    // handle/handle_map_growing
    st = test_begin(); test_handle_map_growing(*st); all_ok &= test_summary("handle/handle_map_growing", *st);

    // handle/handle_map_virtual
    st = test_begin(); test_handle_map_virtual(*st); all_ok &= test_summary("handle/handle_map_virtual", *st);

    // entities
    st = test_begin(); test_entities_basic(*st); test_entities_iter_val(*st); test_entities_iter_sub(*st); all_ok &= test_summary("entities", *st);

    // encoding
    st = test_begin(); test_encoding_csv(*st); test_encoding_json(*st); all_ok &= test_summary("encoding", *st);

    // tween
    st = test_begin(); test_tween_values(*st); test_tween_manager(*st); test_tween_sequence(*st); all_ok &= test_summary("tween", *st);

    if all_ok {
        print("\nALL TESTS PASSED\n");
    } else {
        print("\nSOME TESTS FAILED\n");
    }
}
