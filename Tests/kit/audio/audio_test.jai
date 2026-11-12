// kit/audio 回归测试 —— 一比一移植自 olib `tests/kit/audio/audio_test.odin`（859 行）。
//
// 组织方式与 olib 对位：每个 @(test) 对应一个过程，过程名不变，断言顺序与 olib
// 一一对应；签名统一 `(state: *Test_State)`（由 Tests/kit/run_kit_tests.jai 调度），
// 用 Tests/test_support.jai 的 expect / test_summary。本文件不写 main。
//
// Jai 侧差异（断言语义不变）：
//   | olib (Odin)                                  | 这里 (Jai)                                              |
//   | -------------------------------------------- | ------------------------------------------------------- |
//   | testing.expect(t, cond)                       | expect(state, cond, "说明")                              |
//   | testing.expect_value(t, a, b)                 | audio_test_expect_i64 / _f32(state, a, b, "说明")         |
//   | testing.expectf(t, cond, fmt, ..)             | expect(state, cond, "说明 %", args)                       |
//   | sync.Mutex 串行化可选设备用例                   | 无：Jai 侧测试单线程顺序执行，可选设备用例排在最后           |
//   | os.make_directory_temp / os.remove            | 固定目录 .test_tmp/audio_test/（已 gitignore）+ file_delete |
//   | os.write_entire_file / read_entire_file       | File.write_entire_file / read_entire_file                |
//   | endian.get_u32 / put_u32 / get_f32            | audio_test_u32_at / _put_u32_le / _f32_at（按字节自拼）    |
//   | transmute(u32)f32 / transmute(f32)u32         | audio_test_f32_bits / _bits_f32（union 双视）             |
//   | mem.tracking_allocator + allocation_map        | Audio_Test_Counter（数活块 + 可拒绝分配的包装分配器）       |
//   | mem.nil_allocator() / mem.Allocator{}          | Allocator.{}（.proc 为空）                                |
//   | mem.panic_allocator()                         | Audio_Test_Counter.panic_on_use（被用就记一笔，读上下文时校验）|
//   | os.get_env_alloc("OLIB_AUDIO_DEVICE_TEST")     | audio_test_env_is（Windows kernel32 / POSIX getenv）      |
//   | time.sleep(200 * time.Millisecond)             | sleep_milliseconds(200)                                  |
//   | math.sin / math.sqrt / math.PI                 | M.sin / M.sqrt / M.PI                                    |
//   | sdl3.GetAudioDeviceFormat / GetAudioStreamDevice / | jfoster 未绑定，本文件用 #foreign 补声明（audio_test_sdl_*）|
//   | GetCurrentAudioDriver / GetNumAllocations       |                                                          |
//   | raw_data(slice) != raw_data(slice)             | slice.data != slice.data                                 |
//   | len(x)                                         | x.count                                                  |
//
// 夹具 helper 一律 audio_test_ 前缀（聚合进 run_kit_tests 后不会重名）。
#import "Basic";
#import "File";
M :: #import "Math";
F :: #import "jfoster";

AU :: #import "kit/audio";
#import "test_support";

SDL3 :: F.SDL3;

// jfoster 没有覆盖、olib 测试直接调用的 SDL 函数（只在本测试文件里补声明）。
audio_test_sdl_get_audio_device_format :: (devid: u32, spec: *F.SDL_AudioSpec, sample_frames: *s32) -> bool #foreign SDL3 "SDL_GetAudioDeviceFormat";
audio_test_sdl_get_audio_stream_device :: (stream: *F.SDL_AudioStream) -> u32 #foreign SDL3 "SDL_GetAudioStreamDevice";
audio_test_sdl_get_current_audio_driver :: () -> *u8 #foreign SDL3 "SDL_GetCurrentAudioDriver";
audio_test_sdl_num_allocations :: () -> s32 #foreign SDL3 "SDL_GetNumAllocations";

// 环境变量开关（olib 的 os.get_env_alloc）：可选设备用例只在 OLIB_AUDIO_DEVICE_TEST=1 时跑。
#if OS == .WINDOWS {
audio_test_k32 :: #library,system "kernel32";
audio_test_get_env_a :: (name: *u8, buffer: *u8, size: u32) -> u32 #foreign audio_test_k32 "GetEnvironmentVariableA";
} else {
audio_test_libc :: #library,system "c";
audio_test_getenv :: (name: *u8) -> *u8 #foreign audio_test_libc "getenv";
}

//@region 夹具 helper

audio_test_f32_bits :: (v: float32) -> u32 {
    u: union { f: float32; i: u32; }
    u.f = v;
    return u.i;
}

audio_test_bits_f32 :: (bits: u32) -> float32 {
    u: union { f: float32; i: u32; }
    u.i = bits;
    return u.f;
}

audio_test_u32le :: (data: *[..] u8, v: u32) {
    array_add(data, cast,trunc(u8) v);
    array_add(data, cast,trunc(u8) (v >> 8));
    array_add(data, cast,trunc(u8) (v >> 16));
    array_add(data, cast,trunc(u8) (v >> 24));
}

audio_test_u16le :: (data: *[..] u8, v: u16) {
    array_add(data, cast,trunc(u8) v);
    array_add(data, cast,trunc(u8) (v >> 8));
}

audio_test_put_u32_le :: (bytes: [] u8, offset: s64, v: u32) {
    if offset < 0 || offset + 4 > bytes.count return;
    bytes[offset] = cast,trunc(u8) v;
    bytes[offset + 1] = cast,trunc(u8) (v >> 8);
    bytes[offset + 2] = cast,trunc(u8) (v >> 16);
    bytes[offset + 3] = cast,trunc(u8) (v >> 24);
}

audio_test_u32_at :: (bytes: [] u8, offset: s64) -> u32 {
    if offset < 0 || offset + 4 > bytes.count return 0;
    return (cast(u32) bytes[offset]) |
           ((cast(u32) bytes[offset + 1]) << 8) |
           ((cast(u32) bytes[offset + 2]) << 16) |
           ((cast(u32) bytes[offset + 3]) << 24);
}

audio_test_f32_at :: (bytes: [] u8, offset: s64) -> float32 {
    return audio_test_bits_f32(audio_test_u32_at(bytes, offset));
}

// Jai 没有切片语法：显式拼 .data / .count 造视图。
audio_test_view :: (data: [..] u8) -> [] u8 {
    view: [] u8;
    view.data = data.data;
    view.count = data.count;
    return view;
}

// 固定数组 / 指针 + 长度的视图。
audio_test_bytes :: (data: *u8, count: s64) -> [] u8 {
    view: [] u8;
    view.data = data;
    view.count = count;
    return view;
}

// olib 的 bytes[offset:]。
audio_test_from :: (bytes: [] u8, offset: s64) -> [] u8 {
    view: [] u8;
    if offset < 0 || offset > bytes.count return view;
    view.data = bytes.data + offset;
    view.count = bytes.count - offset;
    return view;
}

// olib 的 bytes[from:to]（左闭右开）。
audio_test_cut :: (bytes: [] u8, from: s64, to: s64) -> [] u8 {
    view: [] u8;
    if from < 0 || to > bytes.count || from > to return view;
    view.data = bytes.data + from;
    view.count = to - from;
    return view;
}

audio_test_append_str :: (data: *[..] u8, s: string) {
    for 0..s.count - 1 array_add(data, s[it]);
}

audio_test_env_is :: (name: string, expected: string) -> bool {
    name_buf: [256] u8;
    for 0..name_buf.count - 1 name_buf[it] = 0;
    memcpy(name_buf.data, name.data, name.count);
    name_buf[name.count] = 0;
    #if OS == .WINDOWS {
        buffer: [256] u8;
        for 0..buffer.count - 1 buffer[it] = 0;
        count := audio_test_get_env_a(name_buf.data, buffer.data, cast(u32) buffer.count);
        if count == 0 || cast(s64) count >= buffer.count return false;
        return to_string(buffer.data, cast(s64) count) == expected;
    } else {
        value := audio_test_getenv(name_buf.data);
        if !value return false;
        return to_string(value) == expected;
    }
}

// 测试用固定目录（olib 用 os.make_directory_temp）。
audio_test_dir :: () -> string {
    make_directory_if_it_does_not_exist(".test_tmp", true);
    make_directory_if_it_does_not_exist(".test_tmp/audio_test", true);
    return ".test_tmp/audio_test";
}

// test_support.expect 没有返回值；包一层返回条件，方便 `if !audio_test_check(...) return;`。
audio_test_check :: (state: *Test_State, condition: bool, msg: string, args: ..Any) -> bool {
    expect(state, condition, msg, args);
    return condition;
}

audio_test_expect_i64 :: (state: *Test_State, actual: s64, expected: s64, what: string) -> bool {
    return audio_test_check(state, actual == expected, "%（实际 %，期望 %）", what, actual, expected);
}

audio_test_expect_f32 :: (state: *Test_State, actual: float32, expected: float32, what: string) -> bool {
    return audio_test_check(state, actual == expected, "%（实际 %，期望 %）", what, actual, expected);
}

audio_test_expect_ptr :: (state: *Test_State, actual: *void, expected: *void, what: string) {
    expect(state, actual == expected, "%（指针应保持原值）", what);
}

// olib `sound == Audio_Sound{}` / `device == Audio_Device{}` 的对位。
audio_test_sound_is_zero :: (sound: AU.Audio_Sound) -> bool {
    return sound.samples.data == null && sound.channels == 0 && sound.rate == 0 &&
           sound.allocator.proc == null;
}

audio_test_spec_equal :: (a: F.SDL_AudioSpec, b: F.SDL_AudioSpec) -> bool {
    return a.format == b.format && a.channels == b.channels && a.freq == b.freq;
}

audio_test_pcm_equal :: (a: AU.Audio_PCM_Format, b: AU.Audio_PCM_Format) -> bool {
    return a.channels == b.channels && a.rate == b.rate;
}

audio_test_alloc_samples :: (count: s64) -> [] float32 {
    memory := context.allocator.proc(.ALLOCATE, count * size_of(float32), 0, null, context.allocator.data);
    if !memory return .[];
    result: [] float32;
    result.data = cast(*float32) memory;
    result.count = count;
    return result;
}

audio_test_f32_spec :: (rate: s64, channels: s64) -> F.SDL_AudioSpec {
    return .{ format = F.SDL_AUDIO_F32LE, channels = cast(s32) channels, freq = cast(s32) rate };
}

audio_test_spec_desc :: (spec: F.SDL_AudioSpec) -> string {
    return sprint("%Hz/%ch", spec.freq, spec.channels);
}

// 无设备转换流（olib make_test_device）：input 是流输入格式、output 是流输出格式。
audio_test_make_device :: (state: *Test_State, input: F.SDL_AudioSpec, output: F.SDL_AudioSpec) -> (AU.Audio_Device, bool) {
    src := input;
    dst := output;
    stream := F.SDL_CreateAudioStream(*src, *dst);
    ok := audio_test_check(state, stream != null, "CreateAudioStream % -> %: %", audio_test_spec_desc(input), audio_test_spec_desc(output), to_string(F.SDL_GetError()));
    return .{ stream = stream, input_spec = input, spec = output }, ok;
}

audio_test_read_f32_stream :: (state: *Test_State, device: *AU.Audio_Device) -> [..] float32 {
    out: [..] float32;
    if !audio_test_check(state, F.SDL_FlushAudioStream(device.stream), "FlushAudioStream") return out;
    bytes := F.SDL_GetAudioStreamAvailable(device.stream);
    if !audio_test_check(state, bytes > 0 && cast(s64) bytes % size_of(float32) == 0, "可用字节 %", bytes) return out;
    array_resize(*out, cast(s64) bytes / size_of(float32));
    expect(state, F.SDL_GetAudioStreamData(device.stream, out.data, bytes) == bytes, "读出字节与可读字节一致");
    return out;
}

//@endregion

//@region WAV 元数据与所有权

// olib write_test_wav：8 个 16-bit 样本的 PCM WAV。
audio_test_write_wav :: (state: *Test_State, path: string, rate: s64, channels: s64) -> bool {
    samples: [8] u16 = .[ 0, 8192, 16384, 24576, 32768, 40960, 49152, 57344 ];
    data: [..] u8;
    defer array_free(data);
    audio_test_append_str(*data, "RIFF");
    audio_test_u32le(*data, cast(u32) (36 + 8 * channels * 2));
    audio_test_append_str(*data, "WAVEfmt ");
    audio_test_u32le(*data, 16);
    audio_test_u16le(*data, 1); // PCM
    audio_test_u16le(*data, cast(u16) channels);
    audio_test_u32le(*data, cast(u32) rate);
    audio_test_u32le(*data, cast(u32) (rate * channels * 2));
    audio_test_u16le(*data, cast(u16) (channels * 2));
    audio_test_u16le(*data, 16);
    audio_test_append_str(*data, "data");
    audio_test_u32le(*data, cast(u32) (8 * channels * 2));
    for 0..7 {
        sample := samples[it];
        for 0..channels - 1 {
            audio_test_u16le(*data, sample);
        }
    }
    ok := write_entire_file(path, data.data, data.count);
    return audio_test_check(state, ok, "写夹具 WAV：%", path);
}

// bytes 和路径夹具共用 RIFF 构造；不依赖设备、Storage 或外部资产。
audio_test_wav_bytes :: (payload: [] u8, rate: s64, channels: s64, tag: s64, bits: s64) -> [..] u8 {
    data: [..] u8;
    audio_test_append_str(*data, "RIFF");
    audio_test_u32le(*data, cast(u32) (36 + payload.count + payload.count % 2));
    audio_test_append_str(*data, "WAVEfmt ");
    audio_test_u32le(*data, 16);
    audio_test_u16le(*data, cast(u16) tag);
    audio_test_u16le(*data, cast(u16) channels);
    audio_test_u32le(*data, cast(u32) rate);
    audio_test_u32le(*data, cast(u32) (rate * channels * bits / 8));
    audio_test_u16le(*data, cast(u16) (channels * bits / 8));
    audio_test_u16le(*data, cast(u16) bits);
    audio_test_append_str(*data, "data");
    audio_test_u32le(*data, cast(u32) payload.count);
    array_add(*data, ..payload);
    if payload.count % 2 != 0 array_add(*data, cast(u8) 0);
    return data;
}

sound_load_wav_preserves_format_and_releases :: (state: *Test_State) {
    directory := audio_test_dir();
    wav := sprint("%/sound.wav", directory);
    defer free(wav);
    defer file_delete(wav);
    sound: AU.Audio_Sound;
    defer AU.audio_sound_dispose(*sound);
    rates: [2] s64 = .[ 44100, 48000 ];
    channel_counts: [2] s64 = .[ 1, 2 ];
    for 0..1 {
        rate := rates[it];
        for 0..1 {
            channels := channel_counts[it];
            if !audio_test_write_wav(state, wav, rate, channels) return;
            if !audio_test_check(state, AU.audio_sound_load_wav(*sound, wav), "load_wav 成功") return;
            audio_test_expect_i64(state, sound.channels, channels, "channels 保留源格式");
            audio_test_expect_i64(state, sound.rate, rate, "rate 保留源格式");
            audio_test_expect_i64(state, sound.samples.count, 8 * channels, "样本数 = 8 帧 × 声道");
            audio_test_expect_f32(state, sound.samples[0], 0, "samples[0]");
            audio_test_expect_f32(state, sound.samples[2 * channels], 0.5, "samples[2*channels]");
            audio_test_expect_f32(state, sound.samples[4 * channels], -1, "samples[4*channels]");
        }
    }
    old := sound;
    expect(state, !AU.audio_sound_load_wav(null, wav), "nil sound 被拒绝");
    expect(state, !AU.audio_sound_load_wav(*sound, ""), "空路径被拒绝");
    // 嵌入 NUL 的路径（olib 的 `"%s\x00suffix"`）。
    nul_path: [..] u8;
    defer array_free(nul_path);
    array_add(*nul_path, ..cast([] u8) wav);
    array_add(*nul_path, cast(u8) 0, #char "s", #char "u", #char "f");
    expect(state, !AU.audio_sound_load_wav(*sound, cast(string) nul_path), "路径含 NUL 被拒绝");
    missing := sprint("%.missing", wav);
    defer free(missing);
    expect(state, !AU.audio_sound_load_wav(*sound, missing), "不存在的路径被拒绝");
    not_wav := "not a WAV";
    expect(state, write_entire_file(wav, not_wav.data, not_wav.count), "写入非 WAV 字节");
    expect(state, !AU.audio_sound_load_wav(*sound, wav), "非 WAV 内容被拒绝");
    audio_test_expect_ptr(state, sound.samples.data, old.samples.data, "失败时旧样本保留");
    audio_test_expect_i64(state, sound.channels, old.channels, "失败时旧 channels 保留");
    audio_test_expect_i64(state, sound.rate, old.rate, "失败时旧 rate 保留");
    AU.audio_sound_dispose(*sound);
    expect(state, audio_test_sound_is_zero(sound), "dispose 后回到零值");
    AU.audio_sound_dispose(*sound);
    AU.audio_sound_dispose(null);
}

wav_bytes_integer_depths_and_f32_clipping :: (state: *Test_State) {
    expect(state, cast(u32) F.SDL_WasInit(F.SDL_INIT_AUDIO) == 0, "本用例不初始化音频子系统");
    // WAV PCM 8 为无符号，16/24/32 为有符号，小端；验证极值和符号扩展。
    bit_depths: [4] s64 = .[ 8, 16, 24, 32 ];
    for 0..3 {
        bits := bit_depths[it];
        payload: [..] u8;
        defer array_free(payload);
        if bits == 8 {
            array_add(*payload, cast(u8) 0, cast(u8) 64, cast(u8) 128, cast(u8) 192, cast(u8) 255);
        } else {
            values: [5] u32 = .[ 0x80000000, 0xc0000000, 0, 0x40000000, 0x7fffffff ];
            for 0..4 {
                value := values[it];
                for 0..bits / 8 - 1 {
                    byte_index := it;
                    array_add(*payload, cast,trunc(u8) (value >> cast(u32) (32 - bits + byte_index * 8)));
                }
            }
        }
        bytes := audio_test_wav_bytes(audio_test_view(payload), 44100, 1, 1, bits);
        defer array_free(bytes);
        sound: AU.Audio_Sound;
        defer AU.audio_sound_dispose(*sound);
        if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes)), "PCM % 位解码", bits) {
            return;
        }
        if !audio_test_expect_i64(state, sound.samples.count, 5, "样本数") return;
        expected_values: [4] float32 = .[ -1, -0.5, 0, 0.5 ];
        for 0..3 {
            audio_test_expect_f32(state, sound.samples[it], expected_values[it], sprint("PCM % 位样本 %", bits, it));
        }
        expected := cast(float32) (1 - 1 / M.pow(cast(float64) 2, cast(float64) (bits - 1)));
        expect(state, M.abs(sound.samples[4] - expected) < 0.000001, "PCM % 位满量程样本 ≈ %", bits, expected);
        audio_test_expect_i64(state, sound.channels, 1, "channels");
        audio_test_expect_i64(state, sound.rate, 44100, "rate");
    }
    payload32: [..] u8;
    defer array_free(payload32);
    f32_values: [7] float32 = .[ -2, -1, -0.25, 0, 0.5, 1, 2 ];
    for 0..6 {
        audio_test_u32le(*payload32, audio_test_f32_bits(f32_values[it]));
    }
    bytes32 := audio_test_wav_bytes(audio_test_view(payload32), 48000, 1, 3, 32);
    defer array_free(bytes32);
    sound32: AU.Audio_Sound;
    defer AU.audio_sound_dispose(*sound32);
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound32, audio_test_view(bytes32)), "f32 WAV 解码") return;
    if !audio_test_expect_i64(state, sound32.samples.count, 7, "f32 样本数") return;
    clipped: [7] float32 = .[ -1, -1, -0.25, 0, 0.5, 1, 1 ];
    for 0..6 {
        audio_test_expect_f32(state, sound32.samples[it], clipped[it], "f32 硬裁剪到 [-1,1]");
    }
    // 输入 bytes 仅借用，解码及裁剪都不回写原文件。
    audio_test_expect_f32(state, audio_test_f32_at(audio_test_view(bytes32), 44), -2, "输入字节未被回写");
    // 先转声道再裁剪：L=2/R=0 的 mono 结果为 1，而不是先裁剪源后的 0.5。
    stereo_payload: [8] u8;
    stereo_view := audio_test_bytes(stereo_payload.data, 8);
    audio_test_put_u32_le(stereo_view, 0, audio_test_f32_bits(cast(float32) 2));
    stereo := audio_test_wav_bytes(stereo_view, 48000, 2, 3, 32);
    defer array_free(stereo);
    mono_target: AU.Audio_PCM_Format = .{ channels = 1 };
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound32, audio_test_view(stereo), mono_target), "2 声道 → mono") return;
    if !audio_test_expect_i64(state, sound32.samples.count, 1, "mono 采样数") return;
    audio_test_expect_f32(state, sound32.samples[0], 1, "先转声道再裁剪");
}

wav_chunk_bounds_padding_duplicates_and_trailing_bytes :: (state: *Test_State) {
    payload: [8] u8 = .[ 0, 0, 0, 64, 0, 128, 0, 192 ];
    payload_view := audio_test_bytes(payload.data, 8);
    bytes := audio_test_wav_bytes(payload_view, 44100, 1, 1, 16);
    defer array_free(bytes);
    sound: AU.Audio_Sound;
    defer AU.audio_sound_dispose(*sound);
    // 奇数字节未知 chunk 必须连同 padding 跳过。
    chunked: [..] u8;
    defer array_free(chunked);
    audio_test_append_str(*chunked, "RIFF");
    audio_test_u32le(*chunked, cast(u32) (bytes.count - 8 + 10));
    audio_test_append_str(*chunked, "WAVEJUNK");
    audio_test_u32le(*chunked, 1);
    array_add(*chunked, cast(u8) 7, cast(u8) 0);
    array_add(*chunked, ..audio_test_from(audio_test_view(bytes), 12));
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(chunked)), "跳过奇数字节 JUNK") return;
    audio_test_expect_f32(state, sound.samples[1], 0.5, "JUNK 之后的样本");
    audio_test_append_str(*chunked, "ignored trailing bytes");
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(chunked)), "容忍包络外尾部字节") return;
    audio_test_expect_i64(state, sound.samples.count, 4, "尾部字节不进入样本");
    // RIFF 长度合法、内部 chunk 却截断时，也不能接受部分样本。
    for 12..bytes.count - 1 {
        cut := it;
        short: [..] u8;
        array_resize(*short, cut);
        memcpy(short.data, bytes.data, cut);
        audio_test_put_u32_le(audio_test_view(short), 4, cast(u32) (cut - 8));
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(short)), "截断到 % 字节被拒绝", cut);
        array_free(short);
    }
    extras: [2][2] s64 = .[ .[ 12, 36 ], .[ 36, -1 ] ];
    for 0..1 {
        from := extras[it][0];
        to := extras[it][1];
        duplicate: [..] u8;
        array_add(*duplicate, ..audio_test_view(bytes));
        if to < 0 {
            array_add(*duplicate, ..audio_test_from(audio_test_view(bytes), from));
        } else {
            array_add(*duplicate, ..audio_test_cut(audio_test_view(bytes), from, to));
        }
        audio_test_put_u32_le(audio_test_view(duplicate), 4, cast(u32) (duplicate.count - 8));
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(duplicate)), "重复 chunk（% 起）被拒绝", from);
        array_free(duplicate);
    }
    audio_test_view(bytes)[32] = 1; // PCM block_align 与 channels/bits 不一致
    expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes)), "block_align 不一致被拒绝");
    audio_test_expect_f32(state, sound.samples[1], 0.5, "失败后旧样本仍在");
}

wav_bytes_targets_preserve_duration_pitch_and_channels :: (state: *Test_State) {
    source_rates: [2] s64 = .[ 44100, 48000 ];
    source_channels_list: [2] s64 = .[ 1, 2 ];
    target_rates: [2] s64 = .[ 44100, 48000 ];
    target_channels_list: [2] s64 = .[ 1, 2 ];
    for 0..1 {
        source_rate := source_rates[it];
        for 0..1 {
            source_channels := source_channels_list[it];
            payload: [..] u8;
            defer array_free(payload);
            for 0..source_rate / 10 - 1 {
                frame := it;
                sample := 0.25 * M.sin(2 * M.PI * 1000 * cast(float64) frame / cast(float64) source_rate);
                for 0..source_channels - 1 {
                    audio_test_u32le(*payload, audio_test_f32_bits(cast(float32) sample));
                }
            }
            bytes := audio_test_wav_bytes(audio_test_view(payload), source_rate, source_channels, 3, 32);
            defer array_free(bytes);
            for 0..1 {
                rate := target_rates[it];
                for 0..1 {
                    channels := target_channels_list[it];
                    sound: AU.Audio_Sound;
                    defer AU.audio_sound_dispose(*sound);
                    target: AU.Audio_PCM_Format = .{ rate = rate, channels = channels };
                    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), target),
                               "% → % 目标 %/% 转换成功", audio_test_spec_desc(audio_test_f32_spec(source_rate, source_channels)), audio_test_spec_desc(audio_test_f32_spec(rate, channels)), rate, channels) {
                        return;
                    }
                    audio_test_expect_i64(state, sound.rate, rate, "目标 rate");
                    audio_test_expect_i64(state, sound.channels, channels, "目标 channels");
                    frames := sound.samples.count / channels;
                    if !audio_test_check(state, M.abs(frames - rate / 10) <= 1, "时长 %ms 保持（% 帧）", 100, frames) return;
                    trim := rate / 1000;
                    first, last, crossings := cast(s64) 0, cast(s64) 0, cast(s64) 0;
                    for trim..frames - trim - 1 {
                        frame := it;
                        value := sound.samples[frame * channels];
                        if value >= 0 && sound.samples[(frame - 1) * channels] < 0 {
                            if crossings == 0 first = frame;
                            last = frame;
                            crossings += 1;
                        }
                        if channels == 2 {
                            audio_test_expect_f32(state, value, sound.samples[frame * 2 + 1], "双声道内容一致");
                        }
                    }
                    if !audio_test_check(state, crossings > 90, "过零次数 % > 90", crossings) return;
                    hz := cast(float64) (crossings - 1) * cast(float64) rate / cast(float64) (last - first);
                    expect(state, M.abs(hz - 1000) < 1, "音高保持 1kHz（测得 %）", hz);
                }
            }
            // 零值及逐字段覆盖保留源格式，不意外选择默认设备格式。
            targets: [3] AU.Audio_PCM_Format = .[ .{}, .{ rate = 48000 }, .{ channels = 1 } ];
            for 0..2 {
                sound: AU.Audio_Sound;
                defer AU.audio_sound_dispose(*sound);
                target := targets[it];
                if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), target), "逐字段目标转换") return;
                expected_rate := target.rate;
                if expected_rate == 0 expected_rate = source_rate;
                expected_channels := target.channels;
                if expected_channels == 0 expected_channels = source_channels;
                audio_test_expect_i64(state, sound.rate, expected_rate, "零 rate 沿用源");
                audio_test_expect_i64(state, sound.channels, expected_channels, "零 channels 沿用源");
            }
        }
    }
    // 双声道不同内容折为 mono，不能只把交错数据改标为单声道。
    payload_stereo: [..] u8;
    defer array_free(payload_stereo);
    for 0..31 {
        audio_test_u32le(*payload_stereo, audio_test_f32_bits(0.25));
        audio_test_u32le(*payload_stereo, audio_test_f32_bits(-0.75));
    }
    bytes_stereo := audio_test_wav_bytes(audio_test_view(payload_stereo), 48000, 2, 3, 32);
    defer array_free(bytes_stereo);
    sound_down: AU.Audio_Sound;
    defer AU.audio_sound_dispose(*sound_down);
    down_target: AU.Audio_PCM_Format = .{ channels = 1 };
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound_down, audio_test_view(bytes_stereo), down_target), "双声道折 mono") return;
    audio_test_expect_i64(state, sound_down.samples.count, 32, "折 mono 后帧数不变");
    for 0..sound_down.samples.count - 1 {
        audio_test_expect_f32(state, sound_down.samples[it], -0.25, "左右混音");
    }
}

wav_bytes_failures_preserve_previous_sound :: (state: *Test_State) {
    payload: [8] u8 = .[ 0, 0, 0, 64, 0, 128, 0, 192 ];
    payload_view := audio_test_bytes(payload.data, 8);
    bytes := audio_test_wav_bytes(payload_view, 44100, 1, 1, 16);
    defer array_free(bytes);
    sound: AU.Audio_Sound;
    defer AU.audio_sound_dispose(*sound);
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes)), "初次解码成功") return;
    old := sound;
    expect(state, !AU.audio_sound_load_wav_bytes(null, audio_test_view(bytes)), "nil sound 被拒绝");
    // 每一个截断前缀（含空字节）。
    for 0..audio_test_view(bytes).count - 1 {
        cut := it;
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_cut(audio_test_view(bytes), 0, cut)), "前缀 % 字节被拒绝", cut);
    }
    empty: [] u8;
    expect(state, !AU.audio_sound_load_wav_bytes(*sound, empty), "空切片被拒绝");
    offsets: [6] s64 = .[ 0, 8, 12, 20, 36, 40 ];
    for 0..5 {
        offset := offsets[it];
        corrupt: [..] u8;
        array_add(*corrupt, ..audio_test_view(bytes));
        audio_test_view(corrupt)[offset] = 0xff;
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(corrupt)), "偏移 % 处破坏被拒绝", offset);
        array_free(corrupt);
    }
    empty_payload: [..] u8;
    empty_wav := audio_test_wav_bytes(audio_test_view(empty_payload), 44100, 1, 1, 16);
    defer array_free(empty_wav);
    expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(empty_wav)), "空音频被拒绝");
    half_frame_wav := audio_test_wav_bytes(audio_test_cut(payload_view, 0, 6), 44100, 2, 1, 16);
    defer array_free(half_frame_wav);
    expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(half_frame_wav)), "半帧被拒绝");
    bad_targets: [3] AU.Audio_PCM_Format = .[ .{ channels = -1 }, .{ channels = 9 }, .{ rate = -1 } ];
    for 0..2 {
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), bad_targets[it]), "非法目标 % 被拒绝", it);
    }
    expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), .{ rate = 2147483648 }), "超出 i32 的 rate 被拒绝");
    // 已读入的极端 rate 比在 SDL 转换分配前拒绝。
    slow := audio_test_wav_bytes(payload_view, 1, 1, 1, 16);
    defer array_free(slow);
    extreme: AU.Audio_PCM_Format = .{ rate = 2147483647, channels = 8 };
    expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(slow), extreme), "极端 rate 比提前拒绝");
    audio_test_expect_ptr(state, sound.samples.data, old.samples.data, "失败后旧样本保留");
    audio_test_expect_i64(state, sound.channels, old.channels, "失败后旧 channels 保留");
    audio_test_expect_i64(state, sound.rate, old.rate, "失败后旧 rate 保留");
    expect(state, sound.allocator.proc == old.allocator.proc && sound.allocator.data == old.allocator.data, "失败后旧 allocator 保留");
    audio_test_expect_f32(state, sound.samples[1], 0.5, "失败后旧样本内容保留");
}

wav_bytes_nonfinite_rejected_before_conversion :: (state: *Test_State) {
    bad_bits: [3] u32 = .[ 0x7fc00000, 0x7f800000, 0xff800000 ];
    targets: [2] AU.Audio_PCM_Format = .[ .{}, .{ rate = 44100, channels = 1 } ];
    for 0..2 {
        bits := bad_bits[it];
        payload: [..] u8;
        defer array_free(payload);
        for 0..63 audio_test_u32le(*payload, bits);
        bytes := audio_test_wav_bytes(audio_test_view(payload), 48000, 2, 3, 32);
        defer array_free(bytes);
        for 0..1 {
            target := targets[it];
            sound: AU.Audio_Sound;
            expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), target), "非有限样本被拒绝（% 位模式）", bits);
            expect(state, audio_test_sound_is_zero(sound), "失败时零点不变");
            sound = .{ samples = audio_test_alloc_samples(1), channels = 1, rate = 44100 };
            previous := sound.samples.data;
            expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), target), "非有限样本被拒绝（已有声音）");
            expect(state, sound.samples.data == previous && sound.rate == 44100, "失败时旧声音保留");
            AU.audio_sound_dispose(*sound);
        }
    }
}

// 计数 + 可拒绝分配的包装分配器（olib mem.Tracking_Allocator 的对位）。
Audio_Test_Counter :: struct {
    backing:       Allocator;
    live:          s64; // 当前未释放的块数
    allocations:   s64;
    frees:         s64;
    reject:        bool; // 分配一律失败
    panic_on_use:  bool; // 一旦被调用就计数，用来验证「没有用错上下文分配器」
}

audio_test_counter_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, data: *void) -> *void {
    counter := cast(*Audio_Test_Counter) data;
    if counter.panic_on_use counter.frees += 1000000;
    if mode == .ALLOCATE {
        if counter.reject return null;
        memory := counter.backing.proc(.ALLOCATE, size, 0, null, counter.backing.data);
        if memory {
            counter.live += 1;
            counter.allocations += 1;
        }
        return memory;
    }
    if mode == .FREE {
        if old_memory {
            counter.live -= 1;
            counter.frees += 1;
        }
        return counter.backing.proc(.FREE, 0, 0, old_memory, counter.backing.data);
    }
    return counter.backing.proc(mode, size, old_size, old_memory, counter.backing.data);
}

wav_bytes_allocator_pairing_replacement_and_failure_cleanup :: (state: *Test_State) {
    first: Audio_Test_Counter = .{ backing = context.allocator };
    second: Audio_Test_Counter = .{ backing = context.allocator };
    a := Allocator.{ audio_test_counter_proc, *first };
    b := Allocator.{ audio_test_counter_proc, *second };
    payload: [8] u8 = .[ 0, 0, 0, 64, 0, 128, 0, 192 ];
    payload_view := audio_test_bytes(payload.data, 8);
    bytes := audio_test_wav_bytes(payload_view, 44100, 1, 1, 16);
    defer array_free(bytes);
    unsupported := audio_test_wav_bytes(payload_view, 44100, 1, 0x7777, 16);
    defer array_free(unsupported);
    sound: AU.Audio_Sound;
    defer AU.audio_sound_dispose(*sound);
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), .{}, a), "用分配器 a 解码") return;
    audio_test_expect_i64(state, first.live, 1, "a 上只有一块活跃分配");
    old := sound.samples.data;
    rejecting: Audio_Test_Counter = .{ backing = context.allocator, reject = true };
    reject_allocator := Allocator.{ audio_test_counter_proc, *rejecting };
    for 0..3 {
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), .{}, Allocator.{}), "零分配器被拒绝");
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), .{}, reject_allocator), "分配失败被拒绝");
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_cut(audio_test_view(bytes), 0, 16), .{}, b), "截断 + 分配器 b 被拒绝");
        audio_test_expect_ptr(state, sound.samples.data, old, "失败时旧样本保留");
    }
    audio_test_expect_i64(state, second.live, 0, "b 上没有残留分配");
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), .{ rate = 48000, channels = 2 }, b), "用分配器 b 重新解码") {
        return;
    }
    audio_test_expect_i64(state, first.live, 0, "换分配器后 a 上的旧块被释放");
    audio_test_expect_i64(state, second.live, 1, "b 上有一块活跃分配");
    expect(state, sound.allocator.proc == b.proc && sound.allocator.data == b.data, "Sound 记录分配器 b");
    // 当前 context 与分配器不同时，仍必须用 Sound 保存的 allocator。
    previous := context.allocator;
    panicking: Audio_Test_Counter = .{ backing = previous, panic_on_use = true };
    context.allocator = Allocator.{ audio_test_counter_proc, *panicking };
    AU.audio_sound_dispose(*sound);
    context.allocator = previous;
    audio_test_expect_i64(state, second.live, 0, "dispose 用 Sound 保存的分配器");
    audio_test_expect_i64(state, panicking.allocations, 0, "上下文分配器没被误用");
    expect(state, audio_test_sound_is_zero(sound), "dispose 后回到零值");
    AU.audio_sound_dispose(*sound);
    // SDL 解码/转换中间缓冲亦不泄漏；预热后比较成功与失败路径。
    baseline: s32;
    for 0..4 {
        iteration := it;
        expect(state, AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), .{ rate = 48000 }, a), "循环内解码");
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(bytes), .{}, Allocator.{}), "循环内零分配器");
        expect(state, !AU.audio_sound_load_wav_bytes(*sound, audio_test_view(unsupported), .{}, a), "循环内不支持的 codec");
        AU.audio_sound_dispose(*sound);
        count := audio_test_sdl_num_allocations();
        if iteration == 0 {
            // 排除 SDL 首次使用的全局缓存，不替换进程级 malloc 回调。
            baseline = count;
        } else {
            audio_test_expect_i64(state, count, baseline, "SDL 内部缓冲不泄漏");
        }
    }
    audio_test_expect_i64(state, first.live, 0, "循环后 a 上没有残留");
}

wav_path_and_independent_byte_sources_match :: (state: *Test_State) {
    directory := audio_test_dir();
    path := sprint("%/音频 fixture.wav", directory);
    defer free(path);
    defer file_delete(path);
    payload: [256] u8;
    for 0..255 payload[it] = 192;
    payload_view := audio_test_bytes(payload.data, 256);
    bytes := audio_test_wav_bytes(payload_view, 44100, 1, 1, 8);
    defer array_free(bytes);
    if !audio_test_check(state, write_entire_file(path, bytes.data, bytes.count), "写夹具 WAV（含非 ASCII 文件名）") return;
    file_text, read_ok := read_entire_file(path);
    if !audio_test_check(state, read_ok, "读回夹具 WAV") return;
    defer free(file_text);
    file_bytes: [] u8;
    file_bytes.data = file_text.data;
    file_bytes.count = file_text.count;
    target: AU.Audio_PCM_Format = .{ rate = 48000, channels = 2 };
    from_path, from_memory, from_copy: AU.Audio_Sound;
    defer AU.audio_sound_dispose(*from_path);
    defer AU.audio_sound_dispose(*from_memory);
    defer AU.audio_sound_dispose(*from_copy);
    if !audio_test_check(state, AU.audio_sound_load_wav(*from_path, path, target), "路径入口解码") return;
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*from_memory, audio_test_view(bytes), target), "字节入口解码") return;
    if !audio_test_check(state, AU.audio_sound_load_wav_bytes(*from_copy, file_bytes, target), "文件字节入口解码") return;
    // 来源缓冲可立即改写；结果不能借用文件内容或共享解码内存。
    for 0..255 payload[it] = 0;
    for 0..audio_test_view(bytes).count - 1 audio_test_view(bytes)[it] = 0;
    for 0..file_bytes.count - 1 file_bytes[it] = 0;
    expect(state, from_path.samples.data != from_memory.samples.data, "路径结果拥有独立内存");
    expect(state, from_copy.samples.data != from_memory.samples.data, "字节结果拥有独立内存");
    if !audio_test_expect_i64(state, from_path.samples.count, from_memory.samples.count, "两种来源样本数一致") return;
    if !audio_test_expect_i64(state, from_copy.samples.count, from_memory.samples.count, "文件字节样本数一致") return;
    for 0..from_path.samples.count - 1 {
        audio_test_expect_f32(state, from_path.samples[it], from_memory.samples[it], "路径与内存样本一致");
        audio_test_expect_f32(state, from_path.samples[it], from_copy.samples[it], "文件字节与内存样本一致");
    }
    audio_test_expect_i64(state, from_path.rate, target.rate, "路径结果 rate");
    audio_test_expect_i64(state, from_copy.channels, target.channels, "字节结果 channels");
}
//@endregion
