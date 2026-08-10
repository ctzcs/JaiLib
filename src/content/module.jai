// content/module.jai
// Aggregated content module: #load merges every content file (text-level
// include), so `#import "content"` brings in all their top-level symbols —
// including the symbols they import — with a single line.
//
// Layout: all subfolders are pure organization — core/ (const/defs/utils),
// render/ (particle/ink_post/ink_fluid), entity/, manager/ — and none of them
// has a module.jai; every file is registered directly here (single-level
// aggregation). Subfolders therefore can't be imported by directory name —
// use `#import "content"` for everything, or a concrete file path.
//
// game.jai is deliberately NOT loaded here (it imports this module; loading
// it would create a circular include).
//
// NOTE: this relies on #load's text-inclusion semantics. The files keep
// their internal `#import "content/..."` lines; Jai's module cache dedupes
// them against these #loads, and top-level names across the files must stay
// unique (checked when adding new files).


#load "asset_storage.jai";
#load "assets.jai";
#load "atlas.jai";
#load "atlas_draw.jai";
#load "gen_csv.jai";

//core
#load "core/const.jai";
#load "core/defs.jai";
#load "core/utils.jai";

//managers
#load "manager/util.jai";
#load "manager/player.jai";
#load "manager/tree.jai";
#load "manager/leaf.jai";
#load "manager/popup.jai";

//entities
#load "entity/base.jai";
#load "entity/leaf.jai";
#load "entity/player.jai";
#load "entity/round.jai";
#load "entity/ui_flow.jai";

//render
#load "render/ink_post.jai";
#load "render/ink_fluid.jai";
#load "render/particle.jai";