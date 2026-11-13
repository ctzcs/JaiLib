// Hash_Table 兼容层。
//
// 官方 Jai 的 `map_get(*t, key)` 返回 `(value, found)`，而 jacket 返回
// `(found, value)` —— 同一个调用在两个编译器下语义相反。`table_find_pointer`
// 两边签名一致（`-> *Value`，缺失返回 null），所以仓库统一走这个包装。
map_get :: (t: *Table($K, $V), key: K) -> (V, bool) {
    p := table_find_pointer(t, key);
    if p == null {
        value: V;
        return value, false;
    }
    return <<p, true;
}
