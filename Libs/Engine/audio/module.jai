// audio/module.jai — aggregated entry point: `#import "audio"`.
//
// tlib/audio 是 Jai 自带 Sound_Player 模块（jblow 音频系统：WASAPI/
// CoreAudio/ALSA 后端、多实例 Sound_Stream、WAV 解码 + OGG 流式解码、
// VBAP 声像）的薄封装。API 形状对标 DragonLib 的 Foster.Audio，但实现
// 完全委托 Sound_Player——零新增 DLL / FFI，且不依赖 raylib。

#load "audio.jai";
