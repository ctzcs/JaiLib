// 语音链路配置，直译自 MetaVoiceChat 的 VcConfig（MIT）。
// 固定 48kHz 单声道（Opus 语音标准形态）；帧长只支持 10/20/40ms。

SAMPLES_PER_SECOND :: 48_000;
BITS_PER_SAMPLE :: 16;

Opus_Framesize :: enum int {
	FRAMESIZE_10_MS = 10;
	FRAMESIZE_20_MS = 20;
	FRAMESIZE_40_MS = 40;
}

Config :: struct {
	// Opus 编码偏好
	application:   Opus_Application;
	complexity:    int; // 0 最快，10 质量最高
	signal:        Opus_Signal;
	max_bandwidth: Opus_Bandwidth;

	// 帧长（毫秒）：480/960/1920 样本。越长越省流量，但丢包敏感、缓冲延迟大。
	framesize: Opus_Framesize;

	// 抖动估计窗口（秒）与偏移均值窗口（次数）
	jitter_time_window:        float32;
	jitter_mean_offset_window: int;

	// 输出端读/写指针间保留的最小帧数（分数帧）；过小会重叠，过大延迟高
	output_min_buffer_size: float32;

	// ---- 以下为派生值，由 config_init 填写，不要手工设置 ----
	sample_rate:       int;
	frame_period_ms:   int;
	frames_per_second: int;
	seconds_per_frame: float32;
	samples_per_frame: int;
}

// 默认值对齐 VcConfig：VOIP、复杂度 6、语音信号、20ms 帧。
config_default ::() -> Config {
	config: Config;

	config = .{
		application   = Opus_Application.VOIP,
		complexity    = 6,
		signal        = Opus_Signal.VOICE,
		max_bandwidth = Opus_Bandwidth.FULLBAND,
		framesize     = .FRAMESIZE_20_MS,

		jitter_time_window        = 0.240,
		jitter_mean_offset_window = 100,
		output_min_buffer_size    = 2.0,
	};
	return config;
}

// 按当前可调项计算派生值；framesize 非法时返回 false 并保持原状。
config_init ::(config: *Config) -> bool {
	if config == null {
		return false;
	}
	if config.framesize == {
	case .FRAMESIZE_10_MS, .FRAMESIZE_20_MS, .FRAMESIZE_40_MS;
		config.frame_period_ms = cast(int)config.framesize;
	case;
		return false; // 对齐 VcConfig：2.5/5/60ms 等不支持
	}
	config.sample_rate = SAMPLES_PER_SECOND;
	config.frames_per_second = 1000 / config.frame_period_ms;
	config.seconds_per_frame = cast(float32)(config.frame_period_ms) / 1000;
	config.samples_per_frame = SAMPLES_PER_SECOND / config.frames_per_second;
	return true;
}
