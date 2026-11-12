#import "Basic";
#import "test_support";
#import "container/simple_array_test";
#import "debug/debug_test";
#import "profiler/profiler_test";
#import "handle/handle_array/handle_array_test";
#import "handle/handle_map/handle_map_test";
#import "entities/entities_test";
#import "encoding/encoding_test";
#import "asset/asset_test";
#import "audio/audio_test";
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
    st = test_begin(); test_handle_array(*st); test_handle_array_clear_preserves_generations(*st); test_handle_array_clear_destroys_once(*st); test_handle_array_remove_clear_never_allocate(*st); all_ok &= test_summary("handle/handle_array", *st);

    // handle/handle_map
    st = test_begin(); test_handle_map(*st); all_ok &= test_summary("handle/handle_map", *st);

    // entities
    st = test_begin(); test_entities_basic(*st); test_entities_iter_val(*st); test_entities_iter_sub(*st); test_entities_handle_validation(*st); all_ok &= test_summary("entities", *st);

    // encoding
    st = test_begin(); test_encoding_csv(*st); test_encoding_json(*st); all_ok &= test_summary("encoding", *st);

    // asset
    st = test_begin();
    test_asset_guid(*st);
    test_asset_blob(*st);
    test_asset_meta(*st);
    test_asset_import_load(*st);
    test_asset_importer_version(*st);
    test_asset_map_storage(*st);
    test_asset_orphan_meta(*st);
    test_asset_manifest(*st);
    test_asset_pipeline_example(*st);
    all_ok &= test_summary("asset", *st);

    // audio
    st = test_begin(); test_audio(*st); all_ok &= test_summary("audio", *st);

    // tween
    st = test_begin(); test_tween_values(*st); test_tween_manager(*st); test_tween_sequence(*st); all_ok &= test_summary("tween", *st);

    if all_ok {
        print("\nALL TESTS PASSED\n");
    } else {
        print("\nSOME TESTS FAILED\n");
        exit(1);
    }
}
