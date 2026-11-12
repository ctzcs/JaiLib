// handle/ 聚合入口：handle_array（slotmap 型句柄数组，asset 管线在用）
// 与 handle_map（arena 增长的 Pool<Key,Value>，≈ DragonLib KeyIndexStore）。
// 两者顶层符号同名（Handle/Pool），聚合必须走命名空间别名。
HA :: #import "handle/handle_array/handle_array";
HM :: #import "handle/handle_map/handle_map";
