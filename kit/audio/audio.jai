// audio —— SDL3 音频的最小可用层（native only）。
// 一比一移植自 olib `kit/audio/audio.odin`（412 行）。
// Audio_Sound 为源格式或显式目标格式的交错 f32；audio_play 先转为固定流输入格式，
// SDL 流再转为设备格式。多次 play 是串行排队，不是多路混音。
//
// 公开名（过程名、结构体名、字段名）、参数顺序、返回语义与 olib 完全一致：
// audio_init / audio_shutdown / AUDIO_DEVICE_SAMPLE_RATE / Audio_Device /
// audio_device_open / audio_device_close / audio_device_open_recording /
// audio_device_read / audio_device_available_samples / audio_recording_device_names /
// Audio_Sound / audio_sound_dispose / Audio_PCM_Format / audio_sound_load_wav_bytes /
// audio_sound_load_wav / audio_play / apply_volume。
//
// Jai 侧差异（对外行为不变，逐条对应 olib 的写法）：
//   | olib (Odin)                                  | JaiLib (Jai)                                              |
//   | -------------------------------------------- | --------------------------------------------------------- |
//   | sdl3.AudioSpec{format = .F32, ...}           | F.SDL_AudioSpec.{ format = AUDIO_F32, ... }               |
//   | int / rawptr / [^]u8 / c.int                 | s64 / *void / *u8 / s32                                   |
//   | max(i32) 作上界                              | 2147483647 常量（Jai 无 max(i32) 类型极限写法）            |
//   | context.allocator = mem.Allocator            | context.allocator = Basic.Allocator（字段是 .proc）        |
//   | allocator.procedure == nil                   | !allocator.proc                                           |
//   | make([]f32, n, alloc) / delete(slice, alloc) | allocator.proc(.ALLOCATE / .FREE, ...) + memcpy（无头分配）|
//   | strings.clone(s) / delete(s)                 | copy_string(s) / free(s)                                  |
//   | delete(names)（切片）                         | array_free(names)（[..]T 与 []T 两个重载都可用）            |
//   | for i in 0..<n                               | for 0..n - 1（Jai 的 a..b 是闭区间）                       |
//   | for offset := 0; cond; offset += k           | while 循环（Jai 没有 C 风格 for）                          |
//   | switch chunk { case "fmt ": ... }            | if / else if 链（Jai 无 switch；if-switch 只接受整数常量）  |
//   | endian.get_u32 / get_u16 / get_f32           | audio_u16_le / audio_u32_le / audio_f32_*（按字节自拼）     |
//   | transmute(u32)f32 / transmute(f32)u32        | audio_bits_f32（union 双视；Jai 没有 transmute）            |
//   | math.is_nan / math.is_inf                    | M.isnan / M.isinf（Math 模块）                             |
//   | mem.copy(dst, src, n)                        | memcpy(dst, src, n)                                       |
//   | ptr[:n] / (cast([^]f32)p)[:n]                | 显式填 .data / .count 构造切片（Jai 无切片语法）             |
//   | device == Audio_Device{}                     | 本文件内的 operator ==（Jai 结构体比较必须显式声明）         |
//   | ifx cond then a else b（运行期值）            | 运行期分支用 if；ifx 只用于编译期常量                       |
//   | @(private)                                   | 无等价物：内部过程统一加 audio_ / audio_sdl_ 前缀           |
//   | sdl3.Xxx（vendor 绑定全量）                   | jfoster 缺的少数函数在本文件用 #foreign 补声明（见下）       |
//
// jfoster 的 SDL3 绑定覆盖设备流 / 转换流 / SDL_LoadWAV / Queued / Available /
// Resume / Pause / Gain / Clear / Flush，但缺 olib 用到的几项；本文件在
// 「补充绑定」区补声明，库声明仍复用 jfoster 根模块的 SDL3（不改 jfoster 仓库）：
//   SDL_GetAudioStreamFormat / SDL_GetAudioStreamDevice / SDL_GetAudioDeviceFormat /
//   SDL_ConvertAudioSamples / SDL_IOFromConstMem / SDL_LoadWAV_IO / SDL_LoadFile /
//   SDL_GetAudioRecordingDevices（SDL_free 已由 jfoster 提供）。
// 本地名一律 audio_sdl_ 前缀（避免聚合后与 jfoster 的 SDL_* 名字相撞），符号名照旧。
//
// 分配器契约与 olib 相同：Audio_Sound 记录 allocator，audio_sound_dispose 用它释放；
// 零 allocator 沿用 context.allocator。Jai 侧「拥有切片」= allocator.proc 直接分配的
// 裸块（没有 Basic 动态数组头），因此 sound.samples 可以安全地只带 .data / .count。

//@region 补充绑定 —— jfoster 未覆盖、olib 需要的 SDL3 函数

// 复用 jfoster 根模块的库声明（`SDL3 :: #library ...` 按平台挑 dll/lib）。
SDL3 :: F.SDL3;

audio_sdl_get_audio_stream_format :: (stream: *F.SDL_AudioStream, src_spec: *F.SDL_AudioSpec, dst_spec: *F.SDL_AudioSpec) -> bool #foreign SDL3 "SDL_GetAudioStreamFormat";
audio_sdl_get_audio_stream_device :: (stream: *F.SDL_AudioStream) -> u32 #foreign SDL3 "SDL_GetAudioStreamDevice";
audio_sdl_get_audio_device_format :: (devid: u32, spec: *F.SDL_AudioSpec, sample_frames: *s32) -> bool #foreign SDL3 "SDL_GetAudioDeviceFormat";
audio_sdl_convert_audio_samples :: (
    src_spec: *F.SDL_AudioSpec, src_data: *u8, src_len: s32,
    dst_spec: *F.SDL_AudioSpec, dst_data: **u8, dst_len: *s32,
) -> bool #foreign SDL3 "SDL_ConvertAudioSamples";
audio_sdl_io_from_const_mem :: (memory: *void, size: u64) -> *void #foreign SDL3 "SDL_IOFromConstMem";
audio_sdl_load_wav_io :: (src: *void, closeio: bool, spec: *F.SDL_AudioSpec, audio_buf: **u8, audio_len: *u32) -> bool #foreign SDL3 "SDL_LoadWAV_IO";
audio_sdl_load_file :: (file: *u8, datasize: *u64) -> *void #foreign SDL3 "SDL_LoadFile";
audio_sdl_get_audio_recording_devices :: (count: *s32) -> *u32 #foreign SDL3 "SDL_GetAudioRecordingDevices";

// olib 写 `.F32`：SDL 的 AudioFormat 位域里 32 位浮点，本机字节序即 F32LE
// （Windows / macOS / Linux 的目标平台都是小端）。
AUDIO_F32 :: F.SDL_AUDIO_F32LE;

//@region 结构体比较 —— Jai 不会为结构体生成 operator ==，显式声明后才可写 `a == b`。
// 位置在文件末尾（Audio_Device / Audio_Sound 先要声明）。

operator == :: (a: F.SDL_AudioSpec, b: F.SDL_AudioSpec) -> bool {
    return a.format == b.format && a.channels == b.channels && a.freq == b.freq;
}
//@endregion
//@endregion

//@region 字节/位读取 helper —— 对位 olib 的 core:encoding/endian 与 SDL 宏

// 读小端 u16；越界返回 0（olib 靠包络校验保证下标合法，这里只是冗余守卫，
// 避免 Jai 的边界检查在畸形输入上 trap）。
audio_u16_le :: (bytes: [] u8, offset: s64) -> u16 {
    if offset < 0 || offset + 2 > bytes.count return 0;
    return cast(u16) ((cast(u32) bytes[offset]) | ((cast(u32) bytes[offset + 1]) << 8));
}

audio_u32_le :: (bytes: [] u8, offset: s64) -> u32 {
    if offset < 0 || offset + 4 > bytes.count return 0;
    return (cast(u32) bytes[offset]) |
           ((cast(u32) bytes[offset + 1]) << 8) |
           ((cast(u32) bytes[offset + 2]) << 16) |
           ((cast(u32) bytes[offset + 3]) << 24);
}

audio_u32_be :: (bytes: [] u8, offset: s64) -> u32 {
    if offset < 0 || offset + 4 > bytes.count return 0;
    return ((cast(u32) bytes[offset]) << 24) |
           ((cast(u32) bytes[offset + 1]) << 16) |
           ((cast(u32) bytes[offset + 2]) << 8) |
           (cast(u32) bytes[offset + 3]);
}

// u32 <-> f32 的比特重解释：Jai 没有 transmute，用 union 取同一块内存的另一种读法。
audio_bits_f32 :: (bits: u32) -> float32 {
    u: union { f: float32; i: u32; }
    u.i = bits;
    return u.f;
}

// 取 bytes[offset..offset+count-1] 的只读字符串视图（不复制）。
audio_string_at :: (bytes: [] u8, offset: s64, count: s64) -> string {
    if offset < 0 || count < 0 || offset + count > bytes.count return "";
    return to_string(bytes.data + offset, count);
}

// SDL_AUDIO_FRAMESIZE 宏：每帧字节数 =（format 低 8 位 / 8）* 声道数。
audio_framesize :: (spec: F.SDL_AudioSpec) -> s64 {
    bytes_per_sample := cast(s64) (spec.format & 0xFF) >> 3;
    return bytes_per_sample * cast(s64) spec.channels;
}
//@endregion

//@region 初始化

audio_init :: () -> bool {
    return F.SDL_InitSubSystem(F.SDL_INIT_AUDIO);
}

audio_shutdown :: () {
    F.SDL_QuitSubSystem(F.SDL_INIT_AUDIO);
}

// 默认回放设备 + 队列模式流。零值可用；close 必须早于 audio_shutdown。
// 格式字段只读，不要从外部改变 stream 的输入格式；原始 PCM 入队须匹配 input_spec。
// is_recording 为 true 时是录音设备（audio_device_open_recording 打开），
// 只能 read，audio_play 会拒绝。
Audio_Device :: struct {
    stream:       *F.SDL_AudioStream;
    spec:         F.SDL_AudioSpec; // 打开时绑定设备的实际格式快照，不是入队格式
    input_spec:   F.SDL_AudioSpec; // 固定的应用侧格式：本机字节序 F32
    is_recording: bool;
}

AUDIO_DEVICE_SAMPLE_RATE :: 48000;

// channels/sample_rate 指定流输入（默认 F32/2ch/48000），不是强制物理设备格式。
// 需先 audio_init；拒绝 nil、重复打开及非法格式。任何失败保留 device 原值。
audio_device_open :: (
    device: *Audio_Device,
    channels: s64 = 2,
    sample_rate: s64 = AUDIO_DEVICE_SAMPLE_RATE,
) -> bool {
    if !device || device.stream != null || !audio_pcm_format_valid(channels, sample_rate) {
        return false;
    }
    desired: F.SDL_AudioSpec = .{
        format   = AUDIO_F32,
        channels = cast(s32) channels,
        freq     = cast(s32) sample_rate,
    };
    stream := F.SDL_OpenAudioDeviceStream(F.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, *desired, null, null);
    if !stream return false;

    input_spec: F.SDL_AudioSpec;
    obtained: F.SDL_AudioSpec;
    if !audio_sdl_get_audio_stream_format(stream, *input_spec, null) ||
       !audio_sdl_get_audio_device_format(audio_sdl_get_audio_stream_device(stream), *obtained, null) ||
       !F.SDL_ResumeAudioStreamDevice(stream) {
        F.SDL_DestroyAudioStream(stream);
        return false;
    }

    device.* = .{ stream = stream, spec = obtained, input_spec = input_spec };
    return true;
}

audio_device_close :: (device: *Audio_Device) {
    if !device return;
    if device.stream != null {
        F.SDL_DestroyAudioStream(device.stream);
    }
    device.* = .{};
}

//@region 录音设备

// 默认录音设备 + 拉取模式流；应用侧格式固定 F32/交错（input_spec 记录该格式，
// 与回放命名一致：对录音而言它是「读出格式」）。需先 audio_init；拒绝 nil、
// 重复打开及非法格式。任何失败保留 device 原值。
audio_device_open_recording :: (
    device: *Audio_Device,
    channels: s64 = 1,
    sample_rate: s64 = AUDIO_DEVICE_SAMPLE_RATE,
) -> bool {
    if !device || device.stream != null || !audio_pcm_format_valid(channels, sample_rate) {
        return false;
    }
    desired: F.SDL_AudioSpec = .{
        format   = AUDIO_F32,
        channels = cast(s32) channels,
        freq     = cast(s32) sample_rate,
    };
    stream := F.SDL_OpenAudioDeviceStream(F.SDL_AUDIO_DEVICE_DEFAULT_RECORDING, *desired, null, null);
    if !stream return false;

    // 录音方向：设备写入 src、应用读取 dst，应用侧格式取 dst。
    read_spec: F.SDL_AudioSpec;
    obtained: F.SDL_AudioSpec;
    if !audio_sdl_get_audio_stream_format(stream, null, *read_spec) ||
       !audio_sdl_get_audio_device_format(audio_sdl_get_audio_stream_device(stream), *obtained, null) ||
       !F.SDL_ResumeAudioStreamDevice(stream) {
        F.SDL_DestroyAudioStream(stream);
        return false;
    }

    device.* = .{ stream = stream, spec = obtained, input_spec = read_spec, is_recording = true };
    return true;
}

// 非阻塞拉取录音样本（已转为打开时指定格式）；返回写入 samples 的样本数，
// 无数据返回 0。只对录音设备有效。
audio_device_read :: (device: *Audio_Device, samples: [] float32) -> s64 {
    if !device || device.stream == null || !device.is_recording || samples.count == 0 {
        return 0;
    }
    got := F.SDL_GetAudioStreamData(device.stream, samples.data, cast(s32) (samples.count * size_of(float32)));
    if got <= 0 return 0;
    return cast(s64) got / size_of(float32);
}

// 当前可读样本数（F32 样本计，非字节）。只对录音设备有效。
audio_device_available_samples :: (device: *Audio_Device) -> s64 {
    if !device || device.stream == null || !device.is_recording {
        return 0;
    }
    return cast(s64) F.SDL_GetAudioStreamAvailable(device.stream) / size_of(float32);
}

// 枚举录音设备名；结果为深拷贝切片（context.allocator），由调用方释放：
// olib 是 `delete(每个 name)` + `delete(names)`，Jai 对应 `free(每个 name)` + `array_free(names)`。
// 失败返回空切片。
audio_recording_device_names :: () -> [] string {
    count: s32;
    ids := audio_sdl_get_audio_recording_devices(*count);
    if !ids || count <= 0 {
        return .[];
    }
    defer F.SDL_free(ids);
    list: [..] string;
    array_resize(*list, cast(s64) count);
    ok := true;
    for 0..cast(s64) count - 1 {
        cname := F.SDL_GetAudioDeviceName(ids[it]);
        if !cname {
            list[it] = "";
            ok = false;
            continue;
        }
        list[it] = copy_string(to_string(cname));
    }
    if !ok {
        for 0..list.count - 1 {
            if list[it].count > 0 free(list[it]);
        }
        array_free(list);
        return .[];
    }
    return list;
}
//@endregion

audio_pcm_format_valid :: (channels: s64, rate: s64) -> bool {
    return channels >= 1 && channels <= 8 && rate > 0 && rate <= 2147483647;
}
//@endregion

//@region 声音

// 本机字节序 f32 交错样本；channels 为 1..8，rate 为正的 i32 范围 Hz。
// len(samples) 必须非零且为完整帧（帧数 = len / channels），时长 = 帧数 / rate。
// WAV 解码可保留源声道/采样率或显式转换，不依赖设备或 audio_init。
// audio_play 只借用、不修改样本；手工构造时调用方保证样本有限。
// 解码结果记录 allocator，由 dispose 释放；不可复制拥有者后分别 dispose。
// 手工构造的拥有切片可指定 allocator；零 allocator 沿用旧契约（context.allocator）。
// 借入的切片不要 dispose；零值可直接装载、释放。
Audio_Sound :: struct {
    samples:   [] float32;
    channels:  s64;
    rate:      s64;
    allocator: Allocator;
}

audio_sound_dispose :: (sound: *Audio_Sound) {
    if !sound return;
    if sound.samples.data != null {
        allocator := sound.allocator;
        if !allocator.proc {
            allocator = context.allocator;
        }
        allocator.proc(.FREE, 0, 0, sound.samples.data, allocator.data);
    }
    sound.* = .{};
}

// 目标始终为本机字节序、交错 F32；零字段逐项沿用源 WAV 格式。
// 非零 channels 为 1..8，rate 为正的 i32 范围 Hz，不代表物理设备格式。
Audio_PCM_Format :: struct {
    channels: s64;
    rate:     s64;
}

// 从完整 WAV 字节解码；只在调用期间借用 bytes，结果由 allocator 独立拥有。
// 拒绝截断/空音频、非有限浮点样本；转换完成后将有限样本硬裁剪到 [-1,1]。
// sound 须为空或拥有样本；成功释放旧声音，任何失败保旧（含分配失败）。
audio_sound_load_wav_bytes :: (
    sound: *Audio_Sound,
    bytes: [] u8,
    target: Audio_PCM_Format = .{},
    allocator := context.allocator,
) -> bool {
    if !sound || !allocator.proc ||
       target.channels < 0 || target.channels > 8 ||
       target.rate < 0 || target.rate > 2147483647 || !audio_wav_envelope_valid(bytes) {
        return false;
    }
    // 只把已验证的 RIFF 包络交给 SDL，忽略包络外的尾部字节。
    riff_size := audio_u32_le(bytes, 4);
    io := audio_sdl_io_from_const_mem(bytes.data, cast(u64) riff_size + 8);
    if !io return false;
    spec: F.SDL_AudioSpec;
    buf: *u8;
    buf_len: u32;
    // closeio 同时覆盖 SDL 解码失败的 IO 释放，不改变进程级 WAV 容错 hints。
    if !audio_sdl_load_wav_io(io, true, *spec, *buf, *buf_len) return false;
    defer { if buf F.SDL_free(buf); }
    frame_bytes := audio_framesize(spec);
    if !audio_pcm_format_valid(cast(s64) spec.channels, cast(s64) spec.freq) ||
       frame_bytes <= 0 || buf_len == 0 || cast(s64) buf_len > 2147483647 ||
       cast(s64) buf_len % frame_bytes != 0 {
        return false;
    }
    // 先拒绝浮点源中的 NaN/Inf，不能让 SDL 重采样/声道转换隐藏错误输入。
    if spec.format == F.SDL_AUDIO_F32LE || spec.format == F.SDL_AUDIO_F32BE {
        src_samples: [] u8;
        src_samples.data = buf;
        src_samples.count = cast(s64) buf_len;
        little := spec.format == F.SDL_AUDIO_F32LE;
        offset := cast(s64) 0;
        while offset < src_samples.count {
            bits: u32;
            if little {
                bits = audio_u32_le(src_samples, offset);
            } else {
                bits = audio_u32_be(src_samples, offset);
            }
            sample := audio_bits_f32(bits);
            if M.isnan(sample) || M.isinf(sample) return false;
            offset += size_of(float32);
        }
    }
    channels := target.channels;
    if channels == 0 channels = cast(s64) spec.channels;
    rate := target.rate;
    if rate == 0 rate = cast(s64) spec.freq;
    frames := cast(s64) buf_len / frame_bytes;
    out_frames := (frames * rate + cast(s64) spec.freq - 1) / cast(s64) spec.freq;
    if out_frames > 2147483647 / (channels * size_of(float32)) return false;
    dst_spec: F.SDL_AudioSpec = .{ format = AUDIO_F32, channels = cast(s32) channels, freq = cast(s32) rate };
    dst: *u8;
    dst_len: s32;
    if !audio_sdl_convert_audio_samples(*spec, buf, cast(s32) buf_len, *dst_spec, *dst, *dst_len) {
        return false;
    }
    defer { if dst F.SDL_free(dst); }
    if dst_len <= 0 || cast(s64) dst_len % (channels * size_of(float32)) != 0 return false;
    samples: [] float32;
    samples.data = cast(*float32) dst;
    samples.count = cast(s64) dst_len / size_of(float32);
    for 0..samples.count - 1 {
        sample := samples[it];
        if M.isnan(sample) || M.isinf(sample) return false;
        samples[it] = clamp(sample, cast(float32) -1, cast(float32) 1);
    }
    // make([]f32, n, allocator) 的对位：裸块分配 + 失败返回 false（保旧）。
    memory := allocator.proc(.ALLOCATE, samples.count * size_of(float32), 0, null, allocator.data);
    if !memory return false;
    memcpy(memory, dst, samples.count * size_of(float32));
    audio_sound_dispose(sound);
    out: [] float32;
    out.data = cast(*float32) memory;
    out.count = samples.count;
    sound.* = .{ samples = out, channels = channels, rate = rate, allocator = allocator };
    return true;
}

// 路径接口保持旧调用兼容，默认保留源 rate/channels；与 bytes 接口共用解码契约。
audio_sound_load_wav :: (
    sound: *Audio_Sound,
    path: string,
    target: Audio_PCM_Format = .{},
    allocator := context.allocator,
) -> bool {
    if !sound || path.count == 0 || path.count >= 4096 return false;
    for 0..path.count - 1 {
        if path[it] == 0 return false;
    }
    path_buf: [4096] u8;
    memcpy(path_buf.data, path.data, path.count);
    path_buf[path.count] = 0;
    c_path := path_buf.data;
    length: u64;
    bytes := audio_sdl_load_file(c_path, *length);
    if !bytes return false;
    defer F.SDL_free(bytes);
    if length > 2147483647 return false;
    view: [] u8;
    view.data = cast(*u8) bytes;
    view.count = cast(s64) length;
    return audio_sound_load_wav_bytes(sound, view, target, allocator);
}

// 只验证 RIFF/WAVE 的有界 chunk 包络，样本 codec 仍由 SDL 解码。
// SDL 默认可接受截断 WAV；这里拒绝缺失字节/半帧，不修改全局 hints。
audio_wav_envelope_valid :: (bytes: [] u8) -> bool {
    if bytes.count < 12 || bytes.count > 2147483647 ||
       audio_string_at(bytes, 0, 4) != "RIFF" || audio_string_at(bytes, 8, 4) != "WAVE" {
        return false;
    }
    size := audio_u32_le(bytes, 4);
    if cast(s64) size + 8 > bytes.count || size < 4 return false;
    end := cast(s64) size + 8;
    has_format := false;
    has_data := false;
    block_align := cast(s64) 0;
    data_size := cast(s64) 0;
    uncompressed := false;
    offset := cast(s64) 12;
    while offset < end {
        if end - offset < 8 return false;
        chunk := audio_string_at(bytes, offset, 4);
        length := cast(s64) audio_u32_le(bytes, offset + 4);
        offset += 8;
        padded := length + length % 2;
        if padded > end - offset return false;
        if chunk == "fmt " {
            if has_format || length < 16 return false;
            has_format = true;
            tag := audio_u16_le(bytes, offset);
            alignment := audio_u16_le(bytes, offset + 12);
            block_align = cast(s64) alignment;
            uncompressed = tag == 1 || tag == 3 || tag == 0xfffe;
            if uncompressed {
                channels := audio_u16_le(bytes, offset + 2);
                bits := audio_u16_le(bytes, offset + 14);
                if channels == 0 || channels > 8 || bits == 0 || bits % 8 != 0 ||
                   block_align != cast(s64) channels * (cast(s64) bits / 8) {
                    return false;
                }
            }
        } else if chunk == "data" {
            if has_data || length == 0 return false;
            has_data = true;
            data_size = length;
        }
        offset += padded;
    }
    return has_format && has_data && block_align > 0 &&
           (!uncompressed || data_size % block_align == 0);
}

// 一次性 whole-buffer 串行入队（短音效），不是混音，也不适合连续音频分块重采样。
// Sound 的 rate/channels 与 input_spec 不同则用 SDL 转换；设备侧转换由 stream 完成。
// 有限 volume 钳制到 [0,1]（不做样本硬裁剪）。拒绝 nil、空/半帧、非法元数据、
// 超出 SDL i32 字节长度及非有限 volume；失败不入队，Sound 始终不变。
// SDL 复制入队数据，返回后即可释放 Sound。转换/缩放临时缓冲在本调用内释放。
audio_play :: (device: *Audio_Device, sound: *Audio_Sound, volume: float32 = 1) -> bool {
    if !device || device.stream == null || !sound return false;
    if device.is_recording return false; // 录音流方向相反，不能入队播放
    if !audio_pcm_format_valid(sound.channels, sound.rate) || sound.samples.count == 0 ||
       sound.samples.count % sound.channels != 0 ||
       sound.samples.count > 2147483647 / size_of(float32) ||
       device.input_spec.format != AUDIO_F32 ||
       !audio_pcm_format_valid(cast(s64) device.input_spec.channels, cast(s64) device.input_spec.freq) ||
       M.isnan(volume) || M.isinf(volume) {
        return false;
    }

    data := sound.samples;
    converted: *u8;
    defer { if converted F.SDL_free(converted); }
    if sound.channels != cast(s64) device.input_spec.channels || sound.rate != cast(s64) device.input_spec.freq {
        // 转换后长度也必须适合 SDL 的 i32 字节数；先算上界，避免巨大分配。
        frames := data.count / sound.channels;
        out_frames := (frames * cast(s64) device.input_spec.freq + sound.rate - 1) / sound.rate;
        if out_frames > 2147483647 / (cast(s64) device.input_spec.channels * size_of(float32)) {
            return false;
        }
        src_spec: F.SDL_AudioSpec = .{
            format   = AUDIO_F32,
            channels = cast(s32) sound.channels,
            freq     = cast(s32) sound.rate,
        };
        dst_spec := device.input_spec;
        converted_len: s32;
        if !audio_sdl_convert_audio_samples(
            *src_spec, cast(*u8) data.data, cast(s32) (data.count * size_of(float32)),
            *dst_spec, *converted, *converted_len,
        ) {
            return false;
        }
        if converted_len <= 0 || cast(s64) converted_len % (cast(s64) dst_spec.channels * size_of(float32)) != 0 {
            return false;
        }
        data.data = cast(*float32) converted;
        data.count = cast(s64) converted_len / size_of(float32);
    }

    vol := clamp(volume, cast(float32) 0, cast(float32) 1);
    scaled: [] float32;
    defer { if scaled.data != null context.allocator.proc(.FREE, 0, 0, scaled.data, context.allocator.data); }
    if vol != 1 {
        // olib 用 make([]f32, len(data))（context.allocator）：分配失败时直接返回 false。
        memory := context.allocator.proc(.ALLOCATE, data.count * size_of(float32), 0, null, context.allocator.data);
        if !memory return false;
        scaled.data = cast(*float32) memory;
        scaled.count = data.count;
        for 0..data.count - 1 {
            scaled[it] = data[it] * vol;
        }
        data = scaled;
    }

    return F.SDL_PutAudioStreamData(device.stream, data.data, cast(s32) (data.count * size_of(float32)));
}
//@endregion

//@region 样本级音量与裁剪

// 样本级音量缩放 + 硬裁剪到 [-1,1]。dst 与 src 可同片；供自定义混音器使用。
apply_volume :: (dst: [] float32, src: [] float32, volume: float32) {
    n := min(dst.count, src.count);
    for 0..n - 1 {
        v := src[it] * volume;
        if v > 1 {
            v = 1;
        } else if v < -1 {
            v = -1;
        }
        dst[it] = v;
    }
}
//@endregion

//@region 结构体比较 —— 对位 olib 测试里的 `sound == Audio_Sound{}` 这类断言

operator == :: (a: Audio_PCM_Format, b: Audio_PCM_Format) -> bool {
    return a.channels == b.channels && a.rate == b.rate;
}

operator == :: (a: Audio_Device, b: Audio_Device) -> bool {
    return a.stream == b.stream && a.spec == b.spec &&
           a.input_spec == b.input_spec && a.is_recording == b.is_recording;
}

operator == :: (a: Audio_Sound, b: Audio_Sound) -> bool {
    return a.samples.data == b.samples.data && a.samples.count == b.samples.count &&
           a.channels == b.channels && a.rate == b.rate &&
           a.allocator.proc == b.allocator.proc && a.allocator.data == b.allocator.data;
}
//@endregion
