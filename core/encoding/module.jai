// encoding/module.jai — 聚合入口：`#import "core/encoding"`。
//
// 与 olib core/encoding 的对位关系：
//   csv.jai          —— olib core/encoding/csv.odin（CSV -> struct，表驱动配置）
//   json.jai         —— olib core/encoding/json.odin（Value 树 + struct 双向序列化）
//   ordered_json.jai —— olib core/encoding/ordered_json/ordered_json.odin
//                        （有序、独占所有权、精确数字词法的 JSON 树）
//   xml.jai          —— 无 olib 对应：JaiLib 扩展，UTF-8 XML 树（从 Libs/Engine/encoding 平移）
//
// olib 侧前三个是同一个包 `encoding` 加一个子包 `ordered_json`；Jai 一个目录一个包，
// 所以四份实现合成同一个包，靠名字前缀区分内部辅助（csv_* / json_* / oj_* / xml_*）。
// 公开 API 的名字照 olib 不变，唯一的例外是 ordered_json 的 `remove`（Jai 关键字，
// 改名为 remove_key）。
//
// 本文件只做 #load 聚合，不含任何实现；测试见 Tests/core/encoding/encoding_test.jai。
#load "csv.jai";
#load "json.jai";
#load "ordered_json.jai";
#load "xml.jai";
