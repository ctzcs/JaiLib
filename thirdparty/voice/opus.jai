// libopus 官方 C 库的动态加载绑定与编解码包装。
//
// 对应 MetaVoiceChat 的 VcEncoder/VcDecoder（其 C# 实现是 Concentus；
// Jai 侧直接绑定原生 libopus，码流完全兼容）。
// ctl 调用按值/指针两种第三参形态各取一次符号：C 变参在 Win x64 与
// System V ABI 下第 3 参数均走整型寄存器，固定签名调用安全。

//@region 常量（与 opus_defines.h 对齐）

Opus_Application :: enum int {
    VOIP = 2048;
    AUDIO = 2049;
    RESTRICTED_LOWDELAY = 2051;
}

Opus_Signal :: enum int {
    VOICE = 3001;
    MUSIC = 3002;
}

Opus_Bandwidth :: enum int {
    NARROWBAND = 1101;
    MEDIUMBAND = 1102;
    WIDEBAND = 1103;
    SUPERWIDEBAND = 1104;
    FULLBAND = 1105;
}

OPUS_OK :: 0;
OPUS_BAD_ARG :: -1;

OPUS_SET_APPLICATION_REQUEST :: 4000;
OPUS_SET_BITRATE_REQUEST :: 4002;
OPUS_SET_MAX_BANDWIDTH_REQUEST :: 4004;
OPUS_SET_BANDWIDTH_REQUEST :: 4008;
OPUS_SET_COMPLEXITY_REQUEST :: 4010;
OPUS_SET_SIGNAL_REQUEST :: 4024;
OPUS_GET_LOOKAHEAD_REQUEST :: 4027;
OPUS_SET_LSB_DEPTH_REQUEST :: 4036;
OPUS_RESET_STATE_REQUEST :: 4028;

OPUS_AUTO :: -1000;
OPUS_BITRATE_MAX :: -1;

// Opus 单包最大字节 RFC 6716。
OPUS_MAX_PACKET_BYTES :: 1275;

//@endregion

//@region 库加载

Opus_Encoder_Create_Proc :: #type (fs: s32, channels: s32, application: s32, error: *s32) -> *void #c_call;
Opus_Encoder_Destroy_Proc :: #type (st: *void) #c_call;
Opus_Encoder_Ctl_Value_Proc :: #type (st: *void, request: s32, value: s32) -> s32 #c_call;
Opus_Encoder_Ctl_Out_Proc :: #type (st: *void, request: s32, out: *s32) -> s32 #c_call;
Opus_Encode_Float_Proc :: #type (st: *void, pcm: *float32, frame_size: s32, data: *u8, max_data_bytes: s32) -> s32 #c_call;
Opus_Decoder_Create_Proc :: #type (fs: s32, channels: s32, error: *s32) -> *void #c_call;
Opus_Decoder_Destroy_Proc :: #type (st: *void) #c_call;
Opus_Decode_Float_Proc :: #type (st: *void, data: *u8, len: s32, pcm: *float32, frame_size: s32, decode_fec: s32) -> s32 #c_call;
Opus_Get_Version_Proc :: #type () -> *u8 #c_call;

Opus_Library :: struct {
    library: *void;

    encoder_create: Opus_Encoder_Create_Proc;
    encoder_destroy: Opus_Encoder_Destroy_Proc;
    encoder_ctl_value: Opus_Encoder_Ctl_Value_Proc;
    encoder_ctl_out: Opus_Encoder_Ctl_Out_Proc;
    encode_float: Opus_Encode_Float_Proc;

    decoder_create: Opus_Decoder_Create_Proc;
    decoder_destroy: Opus_Decoder_Destroy_Proc;
    decode_float: Opus_Decode_Float_Proc;

    get_version_string: Opus_Get_Version_Proc;
}

// Windows：opus.dll（vcpkg/官方发布）。Linux/macOS 的库名见 shared_library_file。
// lib 由调用方持有（值语义）；成功填充字段，失败时 lib 保持零值。
opus_load :: (lib: *Opus_Library) -> bool {
    if lib == null {
        return false;
    }
    library, loaded := load_shared_library(shared_library_file("opus"));
    if !loaded {
        return false;
    }

    lib.library = library;

    lib.encoder_create = cast(Opus_Encoder_Create_Proc) (shared_symbol_ptr(library, "opus_encoder_create"));
    lib.encoder_destroy = cast(Opus_Encoder_Destroy_Proc) (shared_symbol_ptr(library, "opus_encoder_destroy"));
    lib.encoder_ctl_value = cast(Opus_Encoder_Ctl_Value_Proc) (shared_symbol_ptr(library, "opus_encoder_ctl"));
    lib.encoder_ctl_out = cast(Opus_Encoder_Ctl_Out_Proc) (shared_symbol_ptr(library, "opus_encoder_ctl"));
    lib.encode_float = cast(Opus_Encode_Float_Proc) (shared_symbol_ptr(library, "opus_encode_float"));

    lib.decoder_create = cast(Opus_Decoder_Create_Proc) (shared_symbol_ptr(library, "opus_decoder_create"));
    lib.decoder_destroy = cast(Opus_Decoder_Destroy_Proc) (shared_symbol_ptr(library, "opus_decoder_destroy"));
    lib.decode_float = cast(Opus_Decode_Float_Proc) (shared_symbol_ptr(library, "opus_decode_float"));

    lib.get_version_string = cast(Opus_Get_Version_Proc) (shared_symbol_ptr(library, "opus_get_version_string"));

    if lib.encoder_create == null || lib.encoder_destroy == null || lib.encoder_ctl_value == null ||
       lib.encoder_ctl_out == null || lib.encode_float == null ||
       lib.decoder_create == null || lib.decoder_destroy == null || lib.decode_float == null ||
       lib.get_version_string == null {
        opus_dispose(lib);
        return false;
    }
    return true;
}

opus_dispose :: (lib: *Opus_Library) {
    if lib == null {
        return;
    }
    unload_shared_library(lib.library);
    lib.* = .{};
}

opus_version :: (lib: *Opus_Library) -> string {
    if lib == null || lib.get_version_string == null {
        return "";
    }
    return to_string(lib.get_version_string());
}

//@endregion

//@region 编码器

Opus_Encoder :: struct {
    lib: *Opus_Library;
    handle: *void;
    buffer: [] u8; // 编码输出缓冲，编码器所有
    frame_samples: int;
    sample_rate: int;
    has_encoded: bool;
}

// 48kHz 单声道语音编码器；复杂度 0-10，其余含义对齐 VcEncoder。
// max_data_bytes_per_packet 上限 1275。
opus_encoder_create :: (
    lib: *Opus_Library,
    config: *Config,
    max_data_bytes_per_packet: int,
) -> Opus_Encoder, bool {
    enc: Opus_Encoder;
    ok: bool;

    if lib == null {
        return .{}, false;
    }
    max_bytes := min(max_data_bytes_per_packet, OPUS_MAX_PACKET_BYTES);
    if max_bytes <= 0 || config.samples_per_frame <= 0 {
        return .{}, false;
    }

    error_code: s32;
    handle := lib.encoder_create(cast(s32) (config.sample_rate), 1, cast(s32) (config.application), *error_code);
    if handle == null || error_code != OPUS_OK {
        return .{}, false;
    }

    // 对齐 VcEncoder 的属性设置；libopus 48kHz 下均为有效值，失败不致命。
    lib.encoder_ctl_value(handle, OPUS_SET_COMPLEXITY_REQUEST, cast(s32) (clamp(config.complexity, 0, 10)));
    lib.encoder_ctl_value(handle, OPUS_SET_SIGNAL_REQUEST, cast(s32) config.signal);
    lib.encoder_ctl_value(handle, OPUS_SET_MAX_BANDWIDTH_REQUEST, cast(s32) config.max_bandwidth);
    lib.encoder_ctl_value(handle, OPUS_SET_LSB_DEPTH_REQUEST, BITS_PER_SAMPLE);

    enc = .{
        lib = lib,
        handle = handle,
        buffer = NewArray(max_bytes, u8),
        frame_samples = config.samples_per_frame,
        sample_rate = config.sample_rate,
    };
    return enc, true;
}

// 编码一帧；返回的切片借用编码器内部缓冲，仅在下一次 encode 前有效。
opus_encoder_encode :: (enc: *Opus_Encoder, samples: [] float32) -> [] u8, bool {
    data: [] u8;
    ok: bool;

    if enc == null || enc.handle == null || (samples).count != enc.frame_samples {
        return .[], false;
    }
    written := enc.lib.encode_float(
        enc.handle, *samples[0], cast(s32) ((samples).count), *enc.buffer[0], cast(s32) ((enc.buffer).count),
    );
    if written <= 0 {
        return .[], false;
    }
    enc.has_encoded = true;
    return view(enc.buffer, 0, written), true;
}

opus_encoder_reset :: (enc: *Opus_Encoder) {
    if enc != null && enc.handle != null {
        enc.lib.encoder_ctl_value(enc.handle, OPUS_RESET_STATE_REQUEST, 0);
    }
}

opus_encoder_destroy :: (enc: *Opus_Encoder) {
    if enc == null {
        return;
    }
    if enc.handle != null {
        enc.lib.encoder_destroy(enc.handle);
    }
    release(enc.buffer);
    enc.* = .{};
}

//@endregion

//@region 解码器

Opus_Decoder :: struct {
    lib: *Opus_Library;
    handle: *void;
    pcm: [] float32; // 解码输出缓冲，解码器所有
    frame_samples: int;
    sample_rate: int;
    has_decoded: bool;
}

opus_decoder_create :: (lib: *Opus_Library, config: *Config) -> Opus_Decoder, bool {
    dec: Opus_Decoder;
    ok: bool;

    if lib == null || config.samples_per_frame <= 0 {
        return .{}, false;
    }
    error_code: s32;
    handle := lib.decoder_create(cast(s32) (config.sample_rate), 1, *error_code);
    if handle == null || error_code != OPUS_OK {
        return .{}, false;
    }
    dec = .{
        lib = lib,
        handle = handle,
        pcm = NewArray(config.samples_per_frame, float32),
        frame_samples = config.samples_per_frame,
        sample_rate = config.sample_rate,
    };
    return dec, true;
}

// 解码一包；返回切片借用解码器内部缓冲，仅在下一次 decode 前有效。
// data 允许为空切片（丢包补偿/DTX 恢复，走 PLC）。decode_fec 只在携带
// in-band FEC 的包上有效。样本数非正按失败处理。
opus_decoder_decode :: (dec: *Opus_Decoder, data: [] u8, decode_fec := false) -> [] float32, bool {
    samples: [] float32;
    ok: bool;

    if dec == null || dec.handle == null {
        return .[], false;
    }
    data_ptr: *u8 = null;
    if (data).count > 0 {
        data_ptr = *data[0];
    }
    written := dec.lib.decode_float(
        dec.handle, data_ptr, cast(s32) ((data).count), *dec.pcm[0], cast(s32) ((dec.pcm).count), cast(s32) (ifx decode_fec then 1 else 0),
    );
    if written <= 0 {
        return .[], false;
    }
    dec.has_decoded = true;
    return view(dec.pcm, 0, written), true;
}

opus_decoder_destroy :: (dec: *Opus_Decoder) {
    if dec == null {
        return;
    }
    if dec.handle != null {
        dec.lib.decoder_destroy(dec.handle);
    }
    release(dec.pcm);
    dec.* = .{};
}

//@endregion
