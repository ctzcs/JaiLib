// manager/util.jai — 管理器公共工具
// （原 managers.jai 拆分：pool_swap_remove）

#import "Basic";

// Swap-remove an index from an active-indices array, keeping slots stable.
pool_swap_remove :: (items: *[..] int, index: int) -> int {
    last_index := items.count - 1;
    removed := (<<items)[cast(s64) index];
    (<<items)[cast(s64) index] = (<<items)[cast(s64) last_index];
    items.count -= 1;
    return removed;
}
