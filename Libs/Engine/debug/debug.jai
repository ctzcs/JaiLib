// debug.jai
// Port of Ascension/tlib/debug/debug.odin
//
// The Odin original exposed per-scope tracking allocators:
//   @(deferred_out=track_destroy) track_create(...) -> runtime.Allocator
// Jai has no equivalent per-instance tracking allocator; its Memory_Debugger
// is global and is enabled at the program level:
//
//     #import "Basic"()(MEMORY_DEBUGGER=true);
//
// which hooks alloc/free/realloc, and report_memory_leaks() then prints
// leaked allocations and bad frees (see modules/Basic/examples/memory_debugger.jai).
//
// track_create / track_destroy are kept for API parity with the Odin original;
// track_destroy is a no-op because the report is emitted by the program-level
// debugger, and the backing allocator is Jai's default allocator.

track_create :: () {
    // Nothing to create: memory debugging is enabled globally at import time.
}

track_destroy :: () {
    // The program-level Memory_Debugger reports leaks; nothing to tear down here.
}
