// voice 算法回环测试：不依赖音频设备。
// Opus/RNNoise 库缺失时跳过对应回环；纯 Jai 抖动缓冲始终测试。


//@region 配置与信号

make_config ::() -> voicelib.Config, bool {
	config: voicelib.Config;
	ok: bool;

	config = voicelib.config_default();
	ok = voicelib.config_init(*config);
	return config, ok;
}

// 指定帧序号的 440Hz 测试帧；幅度 0.3，模拟语音电平。
make_sine_frame ::(frame: int, samples_per_frame: int, amplitude: float32) -> []float32 {
	samples := NewArray(samples_per_frame, float32);
	{ i := 0; while i < samples_per_frame { defer i += 1;
		phase := 2.0 * Math.TAU / 2 * 440.0 * cast(float32)(frame*samples_per_frame+i) / 48000.0;
		samples[i] = amplitude * cast(float32)(Math.sin(phase));
	} }
	return samples;
}

// 归一化互相关（带滞后搜索峰值）：衡量回环还原度。
// Opus 解码输出相对输入有约 312 样本（6.5ms）lookahead 滞后，
// 不做相位对齐的相关度只反映相位差而非波形保真度。
correlation ::(a, b: []float32) -> float32 {
	best: float64 = 0.0;
	max_lag := min((a).count, (b).count) / 2;
	{ lag := -max_lag; while lag < max_lag + 1 { defer lag += 1;
		dot: float64 = 0.0;
		na: float64 = 0.0;
		nb: float64 = 0.0;
		count := 0;
		{ i := 0; while i < min((a).count, (b).count) { defer i += 1;
			j := i + lag;
			if j < 0 || j >= (b).count {
				continue;
			}
			dot += cast(float64)(a[i]) * cast(float64)(b[j]);
			na += cast(float64)(a[i]) * cast(float64)(a[i]);
			nb += cast(float64)(b[j]) * cast(float64)(b[j]);
			count += 1;
		} }
		if count > 64 && na > 0 && nb > 0 {
			best = max(best, dot / (Math.sqrt(na) * Math.sqrt(nb)));
		}
	} }
	return cast(float32)(best);
}

//@endregion

//@region opus 编解码回环


opus_loopback ::(t: *Test) {
	lib: voicelib.Opus_Library;
	if !voicelib.opus_load(*lib) {
		note("opus: SKIPPED (库未找到；放置方式见 thirdparty/voice/README.md)");
		return;
	}
	defer voicelib.opus_dispose(*lib);

	config, ok := make_config();
	expectf(t, true, "config_init: %v", config);
	if !ok {
		expectf(t, false, "config_init 失败");
		return;
	}

	enc, enc_ok := voicelib.opus_encoder_create(*lib, *config, 1200);
	expectf(t, true, "encoder create: %v", enc_ok);
	if !enc_ok {
		expectf(t, false, "编码器创建失败");
		return;
	}
	defer voicelib.opus_encoder_destroy(*enc);

	dec, dec_ok := voicelib.opus_decoder_create(*lib, *config);
	expectf(t, true, "decoder create: %v", dec_ok);
	if !dec_ok {
		expectf(t, false, "解码器创建失败");
		return;
	}
	defer voicelib.opus_decoder_destroy(*dec);

	total_bytes := 0;
	{ frame := 0; while frame < 12 { defer frame += 1;
		samples := make_sine_frame(frame, config.samples_per_frame, 0.3);
		defer release(samples);

		packet, packet_ok := voicelib.opus_encoder_encode(*enc, samples);
		if !packet_ok || (packet).count == 0 {
			expectf(t, false, "第 %d 帧编码失败", frame);
			return;
		}
		if (packet).count > voicelib.OPUS_MAX_PACKET_BYTES {
			expectf(t, false, "第 %d 帧包长 %d 超上限", frame, (packet).count);
			return;
		}
		total_bytes += (packet).count;

		decoded, decode_ok := voicelib.opus_decoder_decode(*dec, packet);
		if !decode_ok {
			expectf(t, false, "第 %d 帧解码失败", frame);
			return;
		}
		if (decoded).count != config.samples_per_frame {
			expectf(t, false, "第 %d 帧解码样本 %d，期望 %d", frame, (decoded).count, config.samples_per_frame);
			return;
		}
		if frame >= 3 { // 前几帧受编码器 lookahead 预热影响，相位未对齐
			score := correlation(samples, decoded);
			if score < 0.85 {
				expectf(t, false, "第 %d 帧回环相关度 %.3f 低于 0.85", frame, score);
				return;
			}
		}
	} }
	expectf(t, true, "12 帧平均码率 %.0f bps", 8.0 * cast(float32)(total_bytes) / (12.0 * config.seconds_per_frame));

	// 丢包补偿：空 data 走 PLC，应吐出完整帧。
	plc, plc_ok := voicelib.opus_decoder_decode(*dec, .[]);
	if !plc_ok || (plc).count != config.samples_per_frame {
		expectf(t, false, "PLC 帧长度异常");
		return;
	}
}

//@endregion

//@region rnnoise 降噪


rnnoise_denoise ::(t: *Test) {
	lib: voicelib.Rnnoise_Library;
	if !voicelib.rnnoise_load(*lib) {
		note("rnnoise: SKIPPED (库未找到；放置方式见 thirdparty/voice/README.md)");
		return;
	}
	defer voicelib.rnnoise_dispose(*lib);

	denoiser, denoiser_ok := voicelib.rnnoise_denoiser_create(*lib);
	if !denoiser_ok {
		expectf(t, false, "降噪器创建失败");
		return;
	}
	defer voicelib.rnnoise_denoiser_destroy(*denoiser);

	// 48kHz 下 480 样本 = 10ms；rnnoise 帧长与 10ms Opus 帧对齐。
	frame := make_sine_frame(0, voicelib.RNNOISE_FRAME_SAMPLES, 0.3);
	defer release(frame);

	probability := voicelib.rnnoise_denoise(*denoiser, frame);
	if probability < 0 || probability > 1 {
		expectf(t, false, "语音概率 %.3f 越界", probability);
		return;
	}
	for sample: frame {
		if Math.isnan(sample) || Math.isinf(sample) || Math.abs(sample) > 1.0 {
			expectf(t, false, "降噪输出越界/非有限值");
			return;
		}
	}
	expectf(t, true, "语音概率 %.3f", probability);
}

//@endregion

//@region 纯 Jai 逻辑（无需库）


config_derivation ::(t: *Test) {
	config := voicelib.config_default();
	if !voicelib.config_init(*config) {
		expectf(t, false, "默认配置 init 失败");
		return;
	}
	if config.samples_per_frame != 960 || config.frame_period_ms != 20 || config.frames_per_second != 50 {
		expectf(t, false, "20ms 派生值错误: %d %d %d", config.samples_per_frame, config.frame_period_ms, config.frames_per_second);
		return;
	}

	config.framesize = .FRAMESIZE_10_MS;
	voicelib.config_init(*config);
	if config.samples_per_frame != 480 {
		expectf(t, false, "10ms 派生值错误: %d", config.samples_per_frame);
		return;
	}

	config.framesize = .FRAMESIZE_40_MS;
	voicelib.config_init(*config);
	if config.samples_per_frame != 1920 {
		expectf(t, false, "40ms 派生值错误: %d", config.samples_per_frame);
		return;
	}
}


jitter_estimation ::(t: *Test) {
	config, ok := make_config();
	if !ok {
		expectf(t, false, "config_init 失败");
		return;
	}

	jitter: voicelib.Jitter;
	voicelib.jitter_init(*jitter, *config);
	defer voicelib.jitter_dispose(*jitter);

	first := voicelib.jitter_update(*jitter, 0.0);
    if first != 0 {
		expectf(t, false, "首个样本应返回 0，得到 %f", first);
		return;
	}

	// 恒定 5ms 抖动的到达序列：稳态 RMS 应接近 5ms 量级且有限。
	offset := 0.005;
	{ frame := 1; while frame < 24 { defer frame += 1;
		arrived := cast(float64)(frame) * 0.02 + (ifx frame % 2 == 0 then offset else -offset);
		value := voicelib.jitter_update(*jitter, arrived);
		if value < 0 || Math.isnan(value) || Math.isinf(value) {
			expectf(t, false, "抖动值异常: %f", value);
			return;
		}
		if frame == 23 && value < 0.002 {
			expectf(t, false, "±5ms 抖动下稳态 RMS %.4fs 过小", value);
			return;
		}
	} }
}

//@endregion

//@region 管线回环（Sender → Receiver）

Relay_Capture :: struct {
	frames: [..]Relayed_Frame;
}

Relayed_Frame :: struct {
	index:     int;
	timestamp: float64;
	data:      []u8;
}

relay_capture ::(index: int, timestamp: float64, data: []u8, user_data: *void) {
	capture := cast(*Relay_Capture)user_data;
	frame := Relayed_Frame.{index = index, timestamp = timestamp};
	if (data).count > 0 {
		frame.data = NewArray(data.count, u8);
		copy_samples(frame.data, data);
	}
	array_add(*capture.frames, frame);
}

relay_capture_dispose ::(capture: *Relay_Capture) {
	for frame: capture.frames {
		if frame.data.count > 0 {
			release(frame.data);
		}
	}
	release(capture.frames);
}

// 跑一遍发送→接收→拉取的完整链路，返回 (输出能量, 说话观察数, underrun 计数)。
pipeline_run ::(
	mode: voicelib.Voice_Receiver_Mode,
	t: *Test,
	opus: *voicelib.Opus_Library,
	rnnoise: *voicelib.Rnnoise_Library,
) -> float64, int, int, bool {
	output_energy: float64;
	speaking_pulls: int;
	underruns: int;
	ok: bool;

	config := voicelib.config_default();
	if !voicelib.config_init(*config) {
		expectf(t, false, "config_init 失败");
		return 0, 0, 0, false;
	}

	capture: Relay_Capture;
	defer relay_capture_dispose(*capture);

	sender: voicelib.Voice_Sender;
	defer voicelib.voice_sender_dispose(*sender);
	if !voicelib.voice_sender_init(*sender, *config, opus, rnnoise, 1200, relay_capture, *capture) {
		expectf(t, false, "sender init 失败");
		return 0, 0, 0, false;
	}

	receiver: voicelib.Voice_Receiver;
	defer voicelib.voice_receiver_dispose(*receiver);
	if !voicelib.voice_receiver_init(*receiver, *config, opus, mode) {
		expectf(t, false, "receiver init 失败（mode=%v）", mode);
		return 0, 0, 0, false;
	}

	// 发 10 帧语音 + 3 帧静音（null 输入）+ 3 帧语音
	{ frame := 0; while frame < 16 { defer frame += 1;
		samples: []float32;
        defer release(samples);
		if frame < 10 || frame >= 13 {
			samples = make_sine_frame(frame, config.samples_per_frame, 0.3);
		}
		voicelib.voice_sender_send(*sender, samples);
	} }

	// 网络直连：全部 relay 帧按序进 receiver
	for frame: capture.frames {
		voicelib.voice_receiver_receive(*receiver, frame.index, frame.timestamp, frame.data);
	}

	// 播放拉取：16 帧 × 20ms = 320ms 内容；拉 32 块覆盖缓冲建立期
	chunk := NewArray(config.samples_per_frame, float32);
	defer release(chunk);
	energy: float64 = 0.0;
	speaking := 0;
	{ pull_index := 0; while pull_index < 32 { defer pull_index += 1;
		if voicelib.voice_receiver_is_speaking(*receiver) {
			speaking += 1;
		}
		voicelib.voice_receiver_pull(*receiver, chunk);
		for sample: chunk {
			energy += cast(float64)(sample) * cast(float64)(sample);
		}
	} }

	return energy, speaking, receiver.underruns, true;
}


voice_pipeline_loopback ::(t: *Test) {
	opus_lib: voicelib.Opus_Library;
	if !voicelib.opus_load(*opus_lib) {
		note("pipeline: SKIPPED (opus 库未找到)");
		return;
	}
	defer voicelib.opus_dispose(*opus_lib);

	rnnoise_lib: voicelib.Rnnoise_Library;
	has_rnnoise := voicelib.rnnoise_load(*rnnoise_lib);
	defer if has_rnnoise {
		voicelib.rnnoise_dispose(*rnnoise_lib);
	}

	// Simple 模式：输出能量显著非零且说话状态被跟踪。
	energy, speaking, underruns, ok := pipeline_run(.Simple, t, *opus_lib, null);
	if !ok {
		return;
	}
	if energy <= 0.001 {
		expectf(t, false, "Simple 模式输出能量 %.5f 过低（未收到声音）", energy);
		return;
	}
	if speaking == 0 {
		expectf(t, false, "Simple 模式从未观察到说话状态");
		return;
	}
	expectf(t, true, "Simple: energy=%.3f speaking=%d underruns=%d", energy, speaking, underruns);

	// 降噪开启时管线可跑通（rnnoise 库存在时）。
	// 注意：rnnoise 对 440Hz 纯音可能判定为非语音而完全滤除——这是降噪器
	// 的正确行为，本用例只验证管线不崩溃且输出有界，不断言能量非零。
	if has_rnnoise {
		energy_denoised, _, _, ok_denoised := pipeline_run(.Simple, t, *opus_lib, *rnnoise_lib);
		if !ok_denoised {
			return;
		}
		if energy_denoised < 0 || Math.isnan(energy_denoised) || Math.isinf(energy_denoised) {
			expectf(t, false, "降噪路径输出能量异常: %f", energy_denoised);
			return;
		}
		expectf(t, true, "Simple+denoise: energy=%.6f（纯音可被完全滤除）", energy_denoised);
	}

	// Neteq 无需库；允许建立期 underrun，但必须有声音输出。
	energy_neteq, speaking_neteq, underruns_neteq, ok_neteq := pipeline_run(.Neteq, t, *opus_lib, null);
	if !ok_neteq {
		return;
	}
	expectf(t, energy_neteq > 0.001, "Neteq 模式输出能量 %.5f 过低", energy_neteq);
	expectf(t, speaking_neteq > 0, "Neteq 模式从未观察到说话状态");
	expectf(t, true, "Neteq: energy=%.3f speaking=%d underruns=%d", energy_neteq, speaking_neteq, underruns_neteq);
}


voice_sender_mute_semantics ::(t: *Test) {
	opus_lib: voicelib.Opus_Library;
	if !voicelib.opus_load(*opus_lib) {
		note("mute: SKIPPED (opus 库未找到)");
		return;
	}
	defer voicelib.opus_dispose(*opus_lib);

	config := voicelib.config_default();
	voicelib.config_init(*config);

	capture: Relay_Capture;
	defer relay_capture_dispose(*capture);

	sender: voicelib.Voice_Sender;
	defer voicelib.voice_sender_dispose(*sender);
	if !voicelib.voice_sender_init(*sender, *config, *opus_lib, null, 1200, relay_capture, *capture) {
		expectf(t, false, "sender init 失败");
		return;
	}

	// 正常帧 → 非空包
	voice: []float32 = make_sine_frame(0, config.samples_per_frame, 0.3);
	voicelib.voice_sender_send(*sender, voice);
	release(voice);
	// null 帧 → 空包（维持节奏）
	voicelib.voice_sender_send(*sender, .[]);
	// 闭麦 → 空包
	sender.is_input_muted = true;
	voice = make_sine_frame(1, config.samples_per_frame, 0.3);
	voicelib.voice_sender_send(*sender, voice);
	release(voice);
	// 聋了 → 空包
	sender.is_input_muted = false;
	sender.is_deafened = true;
	voice = make_sine_frame(2, config.samples_per_frame, 0.3);
	voicelib.voice_sender_send(*sender, voice);
	release(voice);

	if (capture.frames).count != 4 {
		expectf(t, false, "relay 帧数 %d，期望 4", (capture.frames).count);
		return;
	}
	if (capture.frames[0].data).count == 0 {
		expectf(t, false, "正常帧应携带编码数据");
		return;
	}
	for frame: view(capture.frames, 1) {
		if (frame.data).count != 0 {
			expectf(t, false, "帧 %d 应为空包", frame.index);
			return;
		}
	}
	if capture.frames[0].index != 0 || capture.frames[3].index != 3 {
		expectf(t, false, "帧序号异常: %d..%d", capture.frames[0].index, capture.frames[3].index);
		return;
	}
	expectf(t, true, "mute/deafen/null 均发空包，序号连续");
}

//@endregion

//@region 接收端解码状态


voice_receiver_reject_before_decode ::(t: *Test) {
	lib: voicelib.Opus_Library;
	if !voicelib.opus_load(*lib) {
		note("receiver duplicate: SKIPPED (opus 库未找到)");
		return;
	}
	defer voicelib.opus_dispose(*lib);
	config, ok := make_config();
	if !expect(t, ok) {
		return;
	}
	capture: Relay_Capture;
	defer relay_capture_dispose(*capture);
	sender: voicelib.Voice_Sender;
	if !expect(t, voicelib.voice_sender_init(*sender, *config, *lib, null, 1200, relay_capture, *capture)) {
		return;
	}
	defer voicelib.voice_sender_dispose(*sender);
	{ frame := 0; while frame < 6 { defer frame += 1;
		signal := make_sine_frame(frame, 960, 0.3);
		voicelib.voice_sender_send(*sender, signal);
		release(signal);
	} }
	baseline, noisy: voicelib.Voice_Receiver;
	defer voicelib.voice_receiver_dispose(*baseline);
	defer voicelib.voice_receiver_dispose(*noisy);
	if !expect(t, voicelib.voice_receiver_init(*baseline, *config, *lib)) ||
	   !expect(t, voicelib.voice_receiver_init(*noisy, *config, *lib)) {
		return;
	}
	for frame, i: capture.frames {
		voicelib.voice_receiver_receive(*baseline, frame.index, frame.timestamp, frame.data);
		voicelib.voice_receiver_receive(*noisy, frame.index, frame.timestamp, frame.data);
		voicelib.voice_receiver_receive(*noisy, frame.index, frame.timestamp, frame.data);
		if i > 0 {
			previous := capture.frames[i - 1];
			voicelib.voice_receiver_receive(*noisy, previous.index, previous.timestamp, previous.data);
		}
		neteq_expect_same(t, baseline.decoder.pcm, noisy.decoder.pcm);
	}
	expect_value(t, noisy.dropped, 11);
	expect_value(t, noisy.neteq_buffer.stats.dropped_packets, 11);
}
//@endregion

//@region 降噪副本生命周期
// 释放时不还给后备分配器，而是整块写 0xFF（float32 为 NaN）并留到最后统一释放：
// 任何“释放后仍被读取”的缓冲都会确定性地读到 NaN，而不是碰巧还留着旧值。
// 回归：开启 RNNoise 时，降噪副本必须活到 Opus 编码之后。曾在 if 块内 defer delete，
// 编码读到已释放内存，约一半进程发出恒定的垃圾包（接收端看到在说话却没有声音）。

sender_denoised_copy_outlives_encode ::(t: *Test) {
	opus: voicelib.Opus_Library;
	if !voicelib.opus_load(*opus) {
		note("[skip] opus 库缺失");
		return;
	}
	defer voicelib.opus_dispose(*opus);
	rn: voicelib.Rnnoise_Library;
	if !voicelib.rnnoise_load(*rn) {
		note("[skip] rnnoise 库缺失");
		return;
	}
	defer voicelib.rnnoise_dispose(*rn);
	config, ok := make_config();
	if !expect(t, ok) return;

	capture: Relay_Capture;
	defer relay_capture_dispose(*capture);
	sender: voicelib.Voice_Sender;
	defer voicelib.voice_sender_dispose(*sender);
	if !expect(t, voicelib.voice_sender_init(*sender, *config, *opus, *rn, 1200, relay_capture, *capture)) return;

	poison := Poison_Allocator.{backing = context.allocator};


	defer poison_destroy(*poison);
	frames: [12][]float32;
	for *f, i: frames { f.* = make_sine_frame(i, config.samples_per_frame, 0.3); }
	defer { for f: frames { release(f);
}
}
	{
		push_allocator(Allocator.{poison_allocator_proc, *poison});
		for f: frames { voicelib.voice_sender_send(*sender, f);
}
	}

	decoder, dec_ok := voicelib.opus_decoder_create(*opus, *config);
	if !expect(t, dec_ok) return;
	defer voicelib.opus_decoder_destroy(*decoder);
	// RNNoise 需要几帧建立状态，只看后半段；纯音经降噪仍应保留主要成分。
	for frame, i: capture.frames {
		decoded, decode_ok := voicelib.opus_decoder_decode(*decoder, frame.data);
		if !expectf(t, decode_ok, "第 %d 帧解码失败", i) return;
		if i < 6 continue;
		energy: float64;
		for s: decoded {
			if Math.isnan(s) || Math.isinf(s) || Math.abs(s) > 1.5 {
				expectf(t, false, "第 %d 帧解码出非法样本 %v：编码读到了已释放的降噪缓冲", i, s);
				return;
			}
			energy += cast(float64)(s) * cast(float64)(s);
		}
		rms := Math.sqrt(energy / cast(float64)((decoded).count));
		expectf(t, rms > 0.05 && rms < 0.5, "第 %d 帧 RMS %.4f 不像 0.3 幅度的正弦", i, rms);
	}
}
//@endregion
