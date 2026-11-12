// entities/module.jai — 聚合入口：`#import "core/entities"`。
// olib core/entities 只有一个文件 entities.odin，这里对位成同一个包：
//   entities.jai —— Handle / Base / Entity_Ptr / Entities / Buffer，生命周期
//                   （init / shutdown / clear / clone / reserve）、创建销毁
//                   （create / destroy）、查询（get / get_sub / get_values /
//                   get_buffer / available_slots / get_entity_base）与迭代
//                   （begin_val / next_val / begin_sub / next_sub）。
//
// 本文件只做 #load 聚合，不含任何实现；测试见 Tests/core/entities/entities_test.jai。
#load "entities.jai";
