// audio/module.jai — 聚合入口：`#import "kit/audio"`。
// 与 olib kit/audio 对位（audio.odin 单文件，这里拆成一个 #load）。
//
// 与 kit/world 相同：`#load` 进来的文件共享这一层的名字，各文件里不再重复
// `#import`，避免「already declared in this scope」。
//
// 两个具名导入（不能写成 `Math :: #import "Math"` 之外的裸导入）：
//   M —— isnan / isinf（olib 的 core:math）
//   F —— jfoster 的 SDL3 绑定（olib 的 vendor:sdl3）
// 都不具名导入会让 jfoster 的 SDL_* 与世界层的名字混在一起；
// 具名后 audio.jai 里一律写 F.SDL_xxx / M.isnan。
#import "Basic";
M :: #import "Math";
F :: #import "foster";

#load "audio.jai";
