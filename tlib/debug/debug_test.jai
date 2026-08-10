#import "Basic";
#import "test_support";
#import "debug/debug";

// The Odin debug module had no test file; these cases check the ported API
// surface. Leak tracking itself is program-level in Jai (see debug.jai notes).

test_debug :: (state: *Test_State) {
    track_create();
    track_destroy();
    expect(state, true, "track_create/track_destroy callable");
}
