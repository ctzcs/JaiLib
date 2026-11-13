// 语音编排层：对应 MetaVc 的发送/接收路径与 OnAudioFilterReadVcOutput
// 的播放调度。采集与播放设备由宿主接入（如 kit/audio）；本层只做
// 管线逻辑：降噪 → 编码 → relay 回调；receive → 解码 → 抖动缓冲 → 拉取。
//
// 线程模型：receive 在网络/主线程调用，pull 在音频驱动处调用；
// 内部一把互斥锁只保护内存操作（解码与缓冲），无系统调用。
// 帧协议对齐原版：seq = index % 65536，rtp ts = index * samplesPerFrame，
// 空包 = 静音帧（维持节奏，neteq 侧照常插入零样本包）。


//@region 发送端

// 编码完成后的出口；data 为空切片表示静音帧（闭麦/无输入/被拒收）。
Relay_Frame_Proc :: #type(index: int, timestamp: float64, data: []u8, user_data: *void);

Voice_Sender :: struct {
	config: Config; // 已 config_init 的拷贝
	opus:    *Opus_Library;
	encoder: Opus_Encoder;

	rnnoise:    *Rnnoise_Library; // 可选；null 表示不降噪
	denoiser:   Rnnoise_Denoiser;
	has_denoiser: bool;

	frame_index: int;
	stopwatch:   Stopwatch; // 发送侧时间戳（秒）

	is_input_muted: bool;
	is_deafened:    bool; // 原版语义：聋了也发空包

	relay:     Relay_Frame_Proc;
	user_data: *void;
}

// config 须已 init；rnnoise 传 null 跳过降噪（帧长非 480 整数倍时同样跳过）。
// max_packet_bytes 上限 1275。失败保持 sender 零值。
voice_sender_init ::(
	sender: *Voice_Sender,
	config: *Config,
	opus: *Opus_Library,
	rnnoise: *Rnnoise_Library,
	max_packet_bytes: int,
	relay: Relay_Frame_Proc,
	user_data: *void,
) -> bool {
	if sender == null || config == null || opus == null || relay == null {
		return false;
	}
	encoder, ok := opus_encoder_create(opus, config, max_packet_bytes);
	if !ok {
		return false;
	}

	sender.* = .{
		config = config.*,
		opus = opus,
		encoder = encoder,
		rnnoise = rnnoise,
		relay = relay,
		user_data = user_data,
	};

	// rnnoise 帧固定 480 样本；10/20/40ms 帧长均为其整数倍。
	if rnnoise != null && config.samples_per_frame % RNNOISE_FRAME_SAMPLES == 0 {
		denoiser, denoiser_ok := rnnoise_denoiser_create(rnnoise);
		if denoiser_ok {
			sender.denoiser = denoiser;
			sender.has_denoiser = true;
		}
	}
	return true;
}

// 送入一帧采集样本（len 必须 == samples_per_frame；null 表示本帧无输入，
// 与静音同样发空包维持帧节奏）。返回是否触发了 relay。
voice_sender_send ::(sender: *Voice_Sender, samples: []float32) -> bool {
	if sender == null || sender.relay == null {
		return false;
	}
	if !sender.stopwatch.running {
		stopwatch_start(*sender.stopwatch);
	}
	index := sender.frame_index;
	sender.frame_index += 1;
	timestamp := stopwatch_seconds(sender.stopwatch);

	should_relay_empty := samples.count == 0 || (samples).count != sender.config.samples_per_frame ||
		sender.is_input_muted || sender.is_deafened;

	if should_relay_empty {
		sender.relay(index, timestamp, .[], sender.user_data);
		return true;
	}

	frame := samples;
	// 降噪副本在函数作用域释放：必须活到下面的 Opus 编码之后（defer 写在 if 块里会在块尾就释放）。
	denoised: []float32;
	defer release(denoised);
	if sender.has_denoiser {
		// 降噪在副本上做，不修改调用方样本；帧长为 480 的整数倍时逐块处理。
		denoised = NewArray(samples.count, float32);
		copy_samples(denoised, samples);
		chunks := (denoised).count / RNNOISE_FRAME_SAMPLES;
		{ c := 0; while c < chunks { defer c += 1;
			rnnoise_denoise(*sender.denoiser, view(view(denoised, c * RNNOISE_FRAME_SAMPLES), 0, RNNOISE_FRAME_SAMPLES));
		} }
		frame = denoised;
	}

	data, encoded := opus_encoder_encode(*sender.encoder, frame);
	if !encoded {
		sender.relay(index, timestamp, .[], sender.user_data);
		return true;
	}
	sender.relay(index, timestamp, data, sender.user_data);
	return true;
}

voice_sender_dispose ::(sender: *Voice_Sender) {
	if sender == null {
		return;
	}
	if sender.has_denoiser {
		rnnoise_denoiser_destroy(*sender.denoiser);
	}
	opus_encoder_destroy(*sender.encoder);
	sender.* = .{};
}

//@endregion

//@region 接收端

Voice_Receiver_Mode :: enum {
	Simple; // 按到达顺序播放的简单 PCM 队列
	Neteq; // 纯 Jai 自适应抖动缓冲；无额外动态库
}

Voice_Receiver :: struct {
	config: Config;
	opus:    *Opus_Library;
	decoder: Opus_Decoder;
	jitter:  Jitter;

	mode:         Voice_Receiver_Mode;
	neteq_buffer: Neteq_Buffer;
	neteq_read:   int; // 当前输出帧已读量，保留不同大小播放块之间的余样本
	mutex:        Thread.Mutex;
    mutex_initialized: bool;

	// Simple 模式：样本队列
	ring:      [..]float32;
	ring_read: int;

	is_speaking:     bool;
	is_output_muted: bool;
	underruns:       int;
	dropped:         int;
	target_latency_frames: float32;
}

// config 须已 init；Neteq 不需要加载库。初始化后不可复制 receiver（含互斥锁）。
voice_receiver_init ::(
	receiver: *Voice_Receiver,
	config: *Config,
	opus: *Opus_Library,
	mode: Voice_Receiver_Mode = .Neteq,
	additional_delay_ms: u32 = 0,
) -> bool {
	if receiver == null || config == null || opus == null {
		return false;
	}
	decoder, ok := opus_decoder_create(opus, config);
	if !ok {
		return false;
	}
	receiver.* = .{
		config = config.*,
		opus = opus,
		decoder = decoder,
		mode = mode,
	};
	Thread.init(*receiver.mutex);
    receiver.mutex_initialized = true;
    jitter_init(*receiver.jitter, *receiver.config);
	if mode == .Neteq {
		buffer, neteq_ok := neteq_create(
			config.sample_rate, 1, config.samples_per_frame,
			max_packets_in_buffer = 64,
			max_delay_ms = 400,
			additional_delay_ms = additional_delay_ms,
		);
		if !neteq_ok {
			voice_receiver_dispose(receiver);
			return false;
		}
		receiver.neteq_buffer = buffer;
		receiver.neteq_read = (buffer.pcm).count;
	} else {
		capacity_frames := cast(int)(config.output_min_buffer_size) + 8;
		receiver.ring = make_ring(capacity_frames * config.samples_per_frame);
	}
	return true;
}

// 网络侧入口：空 data = 静音帧，timestamp 为发送侧秒；本地到达时间由缓冲器记录。
voice_receiver_receive ::(receiver: *Voice_Receiver, index: int, timestamp: float64, data: []u8) {
	if receiver == null || receiver.decoder.handle == null || index < 0 {
		return;
	}
	Thread.lock(*receiver.mutex);
	defer Thread.unlock(*receiver.mutex);
	if receiver.mode == .Neteq {
		seq := cast(u16)(cast(u64)(index) % 65536);
		ts := cast(u32)((cast(u64)(index) * cast(u64)(receiver.config.samples_per_frame)) % 4294967296);
		buffer := *receiver.neteq_buffer;
		// Opus 有状态：重复/逆序/已播放包必须在解码前拒收，缺口交给 PCM PLC。
		if (buffer.has_arrival && neteq_timestamp_diff(ts, buffer.last_timestamp) <= 0) ||
		   (buffer.started && neteq_timestamp_diff(ts, buffer.play_timestamp) < 0) {
			receiver.dropped += 1;
			buffer.stats.dropped_packets += 1;
			return;
		}
		receiver.is_speaking = (data).count > 0;
		// 解码器返回借用缓冲；neteq_insert 深拷贝到已预分配的包槽。
		samples: []float32;
		if (data).count > 0 {
			decoded: bool;
			samples, decoded = opus_decoder_decode(*receiver.decoder, data);
			if !decoded || (samples).count != receiver.config.samples_per_frame {
				return;
			}
		} else {
			samples = receiver.decoder.pcm;
			zero_slice(samples);
		}
		if !neteq_insert(*receiver.neteq_buffer, seq, ts, samples, receiver.config.frame_period_ms) {
			receiver.dropped += 1;
		}
		receiver.target_latency_frames = cast(float32)(receiver.neteq_buffer.target_delay_ms) / cast(float32)(receiver.config.frame_period_ms);
		return;
	}

	receiver.is_speaking = (data).count > 0;
	receiver.target_latency_frames = receiver.config.output_min_buffer_size +
		jitter_update(*receiver.jitter, timestamp) / receiver.config.seconds_per_frame;
	if (data).count == 0 {
		return;
	}
	samples, decoded := opus_decoder_decode(*receiver.decoder, data);
	if decoded && (samples).count == receiver.config.samples_per_frame {
		voice_receiver_ring_push_locked(receiver, samples);
	}
}

// 音频驱动拉取任意块；不足部分填零/PLC。静音不冻结播放指针。
voice_receiver_pull ::(receiver: *Voice_Receiver, out: []float32) -> int {
	if receiver == null || (out).count == 0 {
		return 0;
	}
	zero_slice(out);
	Thread.lock(*receiver.mutex);
	defer Thread.unlock(*receiver.mutex);
	if receiver.mode == .Neteq && (receiver.neteq_buffer.pcm).count > 0 {
		written := 0;
		underrun := false;
		while written < (out).count {
			if receiver.neteq_read >= (receiver.neteq_buffer.pcm).count {
				neteq_get_audio(*receiver.neteq_buffer);
				receiver.neteq_read = 0;
			}
			operation := receiver.neteq_buffer.operation;
			underrun = underrun || operation == .Buffering || operation == .Conceal;
			audio := view(receiver.neteq_buffer.pcm, receiver.neteq_read);
			take := min((audio).count, (out).count - written);
			copy_samples(view(view(out, written), 0, take), view(audio, 0, take));
			receiver.neteq_read += take;
			written += take;
		}
		if underrun {
			receiver.underruns += 1;
		}
	} else {
		available := (receiver.ring).count - receiver.ring_read;
		take := min(available, (out).count);
		copy_samples(out, view(view(receiver.ring, receiver.ring_read), 0, take));
		receiver.ring_read += take;
		if receiver.ring_read >= receiver.config.samples_per_frame * 4 ||
		   (receiver.ring_read > 0 && receiver.ring_read == (receiver.ring).count) {
			remaining := (receiver.ring).count - receiver.ring_read;
			copy_samples(view(receiver.ring, 0, remaining), view(receiver.ring, receiver.ring_read));
			array_resize(*receiver.ring, remaining);
			receiver.ring_read = 0;
		}
		if take < (out).count {
			receiver.underruns += 1;
		}
	}
	if receiver.is_output_muted {
		zero_slice(out);
	}
	return (out).count;
}

voice_receiver_is_speaking ::(receiver: *Voice_Receiver) -> bool {
	if receiver == null {
		return false;
	}
	Thread.lock(*receiver.mutex);
	defer Thread.unlock(*receiver.mutex);
	return receiver.is_speaking;
}

// 包含当前播放帧尚未取走的尾部；不包含 PLC 和启动静音。
voice_receiver_buffer_ms ::(receiver: *Voice_Receiver) -> int {
	if receiver == null || receiver.config.sample_rate == 0 {
		return 0;
	}
	Thread.lock(*receiver.mutex);
	defer Thread.unlock(*receiver.mutex);
	if receiver.mode == .Neteq {
		remaining := 0;
		if receiver.neteq_buffer.operation != .Buffering && receiver.neteq_buffer.operation != .Conceal {
			remaining = (receiver.neteq_buffer.pcm).count - receiver.neteq_read;
		}
		return cast(int)(neteq_current_buffer_ms(*receiver.neteq_buffer)) + remaining * 1000 / receiver.config.sample_rate;
	}
	return ((receiver.ring).count - receiver.ring_read) * 1000 / receiver.config.sample_rate;
}

voice_receiver_dispose ::(receiver: *Voice_Receiver) {
	if receiver == null {
		return;
	}
	opus_decoder_destroy(*receiver.decoder);
	neteq_destroy(*receiver.neteq_buffer);
	release(receiver.ring);
	jitter_dispose(*receiver.jitter);
    if receiver.mutex_initialized Thread.destroy(*receiver.mutex);
	receiver.* = .{};
}
//@endregion

//@region 简单队列（持锁调用）

voice_receiver_ring_push_locked ::(receiver: *Voice_Receiver, samples: []float32) {
	frame_samples := receiver.config.samples_per_frame;
	array_add(*receiver.ring, ..samples);
	high := cast(int)(receiver.target_latency_frames + 2.0) * frame_samples;
	buffered := (receiver.ring).count - receiver.ring_read;
	if buffered > high {
		drop := buffered - high;
		drop -= drop % frame_samples;
		receiver.ring_read += drop;
		receiver.dropped += 1;
	}
}
//@endregion
