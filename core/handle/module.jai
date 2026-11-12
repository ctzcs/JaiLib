// handle/ 聚合入口：与 olib core/handle 的五个子包一一对位。
//   soa     —— 槽位对齐的实体存储（默认选择）
//   array   —— 可扩容槽位数组（值不按列存放时的默认选择）
//   fixed   —— 内嵌固定容量，容器不分配堆内存
//   growing —— 指针数组 + 增长型 arena（地址稳定）
//   virtual —— 一次性预留 arena + 连续存储（地址稳定）
//
// 各子实现顶层符号同名（Handle / Pool / add / clear / delete / ...），
// 聚合必须走命名空间别名（同 Libs/Engine/handle/module.jai 的做法）。
// 本文件只做 #load 聚合，不含任何实现。
HANDLE_SOA :: #import "core/handle/soa";
HANDLE_ARRAY :: #import "core/handle/array";
HANDLE_FIXED :: #import "core/handle/fixed";
HANDLE_GROWING :: #import "core/handle/growing";
HANDLE_VIRTUAL :: #import "core/handle/virtual";
