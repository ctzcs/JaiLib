// asset/module.jai — aggregated entry point: `#import "asset"`.
// Jai port of olib engine/asset (ofoster 资源管线 v1); flattened one level
// (olib path: engine/asset -> tlib/asset).
//
// The merged files keep disjoint top-level names, so a flat #load works
// (unlike tlib/handle, which needs namespace aliases). Test files are
// intentionally not loaded (they have their own test procs wired into
// tlib/run_tests.jai).

#load "util.jai";
#load "qoi.jai";
#load "blob.jai";
#load "loader.jai";
#load "meta.jai";
#load "manifest.jai";
#load "importer.jai";
#load "asset.jai";
