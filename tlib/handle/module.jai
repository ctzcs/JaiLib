// handle/module.jai — aggregated entry point: `#import "handle"`.
//
// Unlike the other tlib modules this one uses NAMESPACED aggregation instead
// of #load: the four handle implementations all define the same top-level
// names (Handle/Pool/add/get/delete...), so merging them textually would
// collide. Callers use the aliases below, exactly like the tests and
// tween/manager.jai already do (HA/HMF/HMG/HMV).

HA :: #import "handle/handle_array/handle_array";
HMF :: #import "handle/handle_map_fixed/handle_map";
HMG :: #import "handle/handle_map_growing/handle_map";
HMV :: #import "handle/handle_map_virtual/handle_map";
