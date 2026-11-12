// tween/module.jai — 聚合入口：`#import "core/tween"`。
// 与 olib core/tween 的六个文件一一对位（olib 同属 package tween，这里用 #load
// 合成同一个包）：
//   interpolated.jai     —— Transition / Interpolated / 缓动曲线
//   tween.jai            —— Tween / Tween_Config / Repeat_Mode 与采样
//   damp.jai             —— approach / smooth_damp / spring（无节点目标追随）
//   manager.jai          —— 节点池、播放控制、帧推进、自动清理
//   managed_tween.jai    —— setter/指针/属性三种托管注册
//   managed_sequence.jai —— Sequence 时间轴组装
//
// 本文件只做 #load 聚合，不含任何实现；测试见 Tests/core/tween/tween_test.jai。
#load "interpolated.jai";
#load "tween.jai";
#load "damp.jai";
#load "manager.jai";
#load "managed_tween.jai";
#load "managed_sequence.jai";
