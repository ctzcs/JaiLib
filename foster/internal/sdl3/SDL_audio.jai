// SDL_audio.h — 设备流与转换流。
//
// jfoster 之前没有音频绑定（Foster 本身不含音频，音频在 Foster.Audio 里），
// 这里按 SDL 3.4 头文件补上 olib kit/audio 需要的最小集：默认设备流、
// 手动转换流、WAV 解码。
// 布局与签名转写自 SDL3 3.4.12 头文件，与 jacket 自带的完整绑定字段一致。

SDL_AudioDeviceID :: u32;
SDL_AudioFormat   :: u16;

SDL_AudioSpec :: struct {
    format:   SDL_AudioFormat;
    channels: s32;
    freq:     s32;
}

// 不透明句柄（SDL 内部按指针用，Jai 侧只当作地址）。
SDL_AudioStream :: struct {}

SDL_AudioStreamCallback :: #type (userdata: *void, stream: *SDL_AudioStream, additional_amount: s32, total_amount: s32) -> void #c_call;

// SDL_AudioFormat 的编码：有点类型 + 位宽。常用取值直接给出。
SDL_AUDIO_U8    :: 0x0008;
SDL_AUDIO_S8    :: 0x8008;
SDL_AUDIO_S16LE :: 0x8010;   // 32784
SDL_AUDIO_S16BE :: 0x9010;   // 36880
SDL_AUDIO_S32LE :: 0x8020;
SDL_AUDIO_S32BE :: 0x9020;
SDL_AUDIO_F32LE :: 0x8120;   // 33056
SDL_AUDIO_F32BE :: 0x9120;   // 37152

SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK  :: 0xFFFF_FFFF;
SDL_AUDIO_DEVICE_DEFAULT_RECORDING :: 0xFFFF_FFFE;

// 设备
#if OS != .WASM {
SDL_OpenAudioDevice     :: (devid: SDL_AudioDeviceID, spec: *SDL_AudioSpec) -> SDL_AudioDeviceID #foreign SDL3;
SDL_CloseAudioDevice    :: (devid: SDL_AudioDeviceID) #foreign SDL3;
SDL_GetAudioDeviceName  :: (devid: SDL_AudioDeviceID) -> *u8 #foreign SDL3;

// 设备流（内部自己转换 + 自己推音频线程）
SDL_OpenAudioDeviceStream :: (devid: SDL_AudioDeviceID, spec: *SDL_AudioSpec,
                              callback: SDL_AudioStreamCallback, userdata: *void) -> *SDL_AudioStream #foreign SDL3;
SDL_ResumeAudioStreamDevice :: (stream: *SDL_AudioStream) -> bool #foreign SDL3;
SDL_PauseAudioStreamDevice  :: (stream: *SDL_AudioStream) -> bool #foreign SDL3;

// 转换流
SDL_CreateAudioStream    :: (src_spec: *SDL_AudioSpec, dst_spec: *SDL_AudioSpec) -> *SDL_AudioStream #foreign SDL3;
SDL_DestroyAudioStream   :: (stream: *SDL_AudioStream) #foreign SDL3;
SDL_BindAudioStream      :: (devid: SDL_AudioDeviceID, stream: *SDL_AudioStream) -> bool #foreign SDL3;
SDL_SetAudioStreamFormat :: (stream: *SDL_AudioStream, src_spec: *SDL_AudioSpec, dst_spec: *SDL_AudioSpec) -> bool #foreign SDL3;
SDL_SetAudioStreamGain   :: (stream: *SDL_AudioStream, gain: float32) -> bool #foreign SDL3;

SDL_PutAudioStreamData   :: (stream: *SDL_AudioStream, buf: *void, len: s32) -> bool #foreign SDL3;
SDL_GetAudioStreamData   :: (stream: *SDL_AudioStream, buf: *void, len: s32) -> s32 #foreign SDL3;
SDL_GetAudioStreamQueued    :: (stream: *SDL_AudioStream) -> s32 #foreign SDL3;
SDL_GetAudioStreamAvailable :: (stream: *SDL_AudioStream) -> s32 #foreign SDL3;
SDL_ClearAudioStream     :: (stream: *SDL_AudioStream) -> bool #foreign SDL3;
SDL_FlushAudioStream     :: (stream: *SDL_AudioStream) -> bool #foreign SDL3;

// WAV 解码：成功时 audio_buf 由 SDL 分配，调用方用 SDL_free 释放。
SDL_LoadWAV :: (path: *u8, spec: *SDL_AudioSpec, audio_buf: **u8, audio_len: *u32) -> bool #foreign SDL3;
}
