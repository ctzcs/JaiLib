// 纯 Jai PCM 自适应抖动缓冲：RTP 排序、到达抖动估计、波形匹配伸缩与衰减 PLC。
// 仅支持本包的 48kHz 单声道、10/20/40ms 固定帧；不是完整 WebRTC NetEQ 移植。
// 缓冲器独占其内存，不可复制后分别销毁；调用方负责串行访问。
// 设计参考 neteq 0.7.1（Security Union LLC）；参考许可见 LICENSE-NETEQ。


//@region 缓冲器与生命周期

Neteq_Operation :: enum {
	Buffering;
	Normal;
	Accelerate;
	Preemptive_Expand;
	Conceal;
}

Neteq_Stats :: struct {
	dropped_packets:     int;
	concealed_samples:   int;
	accelerated_samples: int;
	expanded_samples:    int;
}

Neteq_Packet :: struct {
	active:    bool;
	sequence:  u16;
	timestamp: u32;
	samples:   []float32;
}

Neteq_Buffer :: struct {
	pcm:             []float32; // 借用输出；下一次 get_audio 前有效
	sample_rate:     int;
	channels:        int;
	operation:       Neteq_Operation;
	stats:           Neteq_Stats;
	target_delay_ms: float64;
	jitter_ms:       float64;

	allocator:       Allocator;
	packets:         []Neteq_Packet;
	storage:         []float32;
	input:           []float32;
	present:         []bool;
	history:         []float32;
	origin:          float64;
	frame_ms:        int;
	max_delay_ms:    int;
	base_delay_ms:   int;
	started:         bool;
	play_timestamp:  u32;
	has_arrival:     bool;
	last_timestamp:  u32;
	last_arrival:    float64;
	history_valid:   bool;
	plc_period:      int;
	plc_phase:       int;
	loss_samples:    int;
	plc_gain:        float32;
	recovery_left:   int;
}

// 初始化时分配全部存储；insert/get_audio 不分配内存。
neteq_create ::(
	sample_rate: int,
	channels: int,
	samples_per_frame: int,
	max_packets_in_buffer := 128,
	max_delay_ms: u32 = 400,
	min_delay_ms: u32 = 0,
	additional_delay_ms: u32 = 0,
) -> Neteq_Buffer, bool {
	buf: Neteq_Buffer;
	ok: bool;

	if sample_rate != 48_000 || channels != 1 ||
	   (samples_per_frame != 480 && samples_per_frame != 960 && samples_per_frame != 1920) ||
	   max_packets_in_buffer <= 0 || max_packets_in_buffer > 512 {
		return .{}, false;
	}
	frame_ms := samples_per_frame * 1000 / sample_rate;
	if max_delay_ms < cast(u32)(frame_ms) || min_delay_ms > max_delay_ms ||
	   additional_delay_ms > max_delay_ms - min_delay_ms {
		return .{}, false;
	}
	// 只存整帧，上限向下对齐；否则 50ms 窗口只能存两帧 20ms，却会等待 50ms。
	limit_ms := min(cast(int)(max_delay_ms) / frame_ms, max_packets_in_buffer) * frame_ms;
	base_ms := min(max(frame_ms * 2, cast(int)(min_delay_ms)) + cast(int)(additional_delay_ms), limit_ms);
	buf = .{
		pcm = NewArray(samples_per_frame, float32),
		sample_rate = sample_rate,
		channels = channels,
		allocator = context.allocator,
		packets = NewArray(max_packets_in_buffer, Neteq_Packet),
		storage = NewArray(max_packets_in_buffer * samples_per_frame, float32),
		input = NewArray(samples_per_frame + sample_rate / 100, float32),
		present = NewArray(samples_per_frame + sample_rate / 100, bool),
		history = NewArray(samples_per_frame, float32),
		origin = monotonic_seconds(),
		frame_ms = frame_ms,
		max_delay_ms = limit_ms,
		base_delay_ms = base_ms,
		target_delay_ms = cast(float64)(base_ms),
	};
	for *packet, i: buf.packets {
		packet.samples = view(view(buf.storage, i * samples_per_frame), 0, samples_per_frame);
	}
	return buf, true;
}

neteq_destroy ::(buf: *Neteq_Buffer) {
	if buf == null {
		return;
	}
	release(buf.pcm, buf.allocator);
	release(buf.packets, buf.allocator);
	release(buf.storage, buf.allocator);
	release(buf.input, buf.allocator);
	release(buf.present, buf.allocator);
	release(buf.history, buf.allocator);
	buf.* = .{};
}
//@endregion

//@region 入包与水位

// 深拷贝 PCM；拒收重复、重叠、过期及非法包。空切片不代表静音，静音应传整帧零。
// arrival_seconds 默认为本地单调时间；可显式传入同一时基的到达秒数以重放网络轨迹。
neteq_insert ::(
	buf: *Neteq_Buffer,
	sequence: u16,
	timestamp: u32,
	samples: []float32,
	duration_ms: int,
	arrival_seconds: float64 = -1,
) -> bool {
	if buf == null || (buf.pcm).count == 0 {
		return false;
	}
	if (samples).count != (buf.pcm).count || duration_ms != buf.frame_ms ||
	   Math.isnan(arrival_seconds) || Math.isinf(arrival_seconds) {
		buf.stats.dropped_packets += 1;
		return false;
	}
	for sample: samples {
		if Math.isnan(sample) || Math.isinf(sample) {
			buf.stats.dropped_packets += 1;
			return false;
		}
	}
	arrival := arrival_seconds;
	if arrival < 0 {
		arrival = (monotonic_seconds() - buf.origin);
	}
	max_samples := buf.max_delay_ms * buf.sample_rate / 1000;
	// 超过整个延迟窗的向前跳变视为新段；反向旧包不重置播放时钟。
	if buf.has_arrival && neteq_timestamp_diff(timestamp, buf.last_timestamp) > max_samples {
		for *packet: buf.packets {
			if packet.active {
				buf.stats.dropped_packets += 1;
			}
			packet.active = false;
		}
		buf.started = false;
		buf.has_arrival = false;
		buf.history_valid = false;
		buf.loss_samples = 0;
		buf.recovery_left = 0;
		buf.jitter_ms = 0;
	}
	if buf.started && neteq_timestamp_diff(timestamp, buf.play_timestamp) < 0 {
		buf.stats.dropped_packets += 1;
		return false;
	}
	for packet: buf.packets {
		if packet.active && (packet.sequence == sequence ||
		   Math.abs(neteq_timestamp_diff(timestamp, packet.timestamp)) < (buf.pcm).count) {
			buf.stats.dropped_packets += 1;
			return false;
		}
	}
	for packet: buf.packets {
		if packet.active && neteq_timestamp_diff(packet.timestamp, timestamp) + (buf.pcm).count > max_samples {
			buf.stats.dropped_packets += 1;
			return false;
		}
	}

	// 超出时间窗或容量时保留新数据，播放指针随被丢弃的旧数据前移。
	trimmed := false;
	for *packet: buf.packets {
		if packet.active && neteq_timestamp_diff(timestamp, packet.timestamp) + (buf.pcm).count > max_samples {
			packet.active = false;
			buf.stats.dropped_packets += 1;
			trimmed = true;
		}
	}
	slot := -1;
	for packet, i: buf.packets {
		if !packet.active {
			slot = i;
			break;
		}
	}
	if slot < 0 {
		slot = neteq_oldest_packet(buf);
		if neteq_timestamp_diff(timestamp, buf.packets[slot].timestamp) < 0 {
			buf.stats.dropped_packets += 1;
			return false;
		}
		buf.stats.dropped_packets += 1;
		trimmed = true;
	}
	packet := *buf.packets[slot];
	packet.active = true;
	packet.sequence = sequence;
	packet.timestamp = timestamp;
	for sample, i: samples {
		packet.samples[i] = clamp(sample, -1, 1);
	}
	if trimmed && buf.started {
		first := neteq_oldest_packet(buf);
		if first >= 0 && neteq_timestamp_diff(buf.packets[first].timestamp, buf.play_timestamp) > 0 {
			buf.play_timestamp = buf.packets[first].timestamp;
			buf.recovery_left = buf.sample_rate / 200;
		}
	}
	if !buf.has_arrival {
		buf.has_arrival = true;
		buf.last_timestamp = timestamp;
		buf.last_arrival = arrival;
	} else {
        delta := neteq_timestamp_diff(timestamp, buf.last_timestamp);
        if delta > 0 && arrival >= buf.last_arrival {
		deviation_ms := (arrival - buf.last_arrival) * 1000 - cast(float64)(delta) * 1000 / cast(float64)(buf.sample_rate);
		buf.jitter_ms += (Math.abs(deviation_ms) - buf.jitter_ms) / 16;
		buf.last_timestamp = timestamp;
		buf.last_arrival = arrival;
	}
    }
	buf.target_delay_ms = clamp(cast(float64)(buf.base_delay_ms) + 4 * buf.jitter_ms,
		cast(float64)(buf.base_delay_ms), cast(float64)(buf.max_delay_ms));
	return true;
}

// 只计真实待播 PCM，不把时间戳空洞和 PLC 计入水位。
neteq_current_buffer_ms ::(buf: *Neteq_Buffer) -> u32 {
	if buf == null || (buf.pcm).count == 0 {
		return 0;
	}
	return cast(u32)(neteq_buffered_samples(buf) * 1000 / buf.sample_rate);
}

neteq_timestamp_diff ::(a, b: u32) -> int {
	delta := (cast(s64)a - cast(s64)b) & 0xffffffff;
    if delta >= 0x80000000 delta -= 0x100000000;
    return delta; // RTP 模 2*32；所有有效包都处于半周期以内
}

neteq_oldest_packet ::(buf: *Neteq_Buffer) -> int {
	oldest := -1;
	for packet, i: buf.packets {
		if packet.active && (oldest < 0 || neteq_timestamp_diff(packet.timestamp, buf.packets[oldest].timestamp) < 0) {
			oldest = i;
		}
	}
	return oldest;
}

neteq_buffered_samples ::(buf: *Neteq_Buffer) -> int {
	count := 0;
	for packet: buf.packets {
		if packet.active {
			consumed := ifx buf.started then clamp(neteq_timestamp_diff(buf.play_timestamp, packet.timestamp), 0, (buf.pcm).count) else 0;
			count += (buf.pcm).count - consumed;
		}
	}
	return count;
}
//@endregion

//@region 播放与水位调节

// 始终输出配置的一帧；建立水位时输出静音，缺包时输出 PLC。
// 音频设备块大小不同时，调用方必须保留本帧未用完的尾部。
neteq_get_audio ::(buf: *Neteq_Buffer) -> []float32 {
	if buf == null || (buf.pcm).count == 0 {
		return .[];
	}
	zero_slice(buf.pcm);
	buf.operation = .Buffering;
	buffered := neteq_buffered_samples(buf);
	if !buf.started {
		if cast(float64)(buffered) * 1000 / cast(float64)(buf.sample_rate) + 0.001 < buf.target_delay_ms {
			return buf.pcm;
		}
		oldest := neteq_oldest_packet(buf);
		if oldest < 0 {
			return buf.pcm;
		}
		buf.play_timestamp = buf.packets[oldest].timestamp;
		buf.started = true;
	}

	zero_slice(buf.input);
	zero_slice(buf.present);
	for packet: buf.packets {
		if !packet.active {
			continue;
		}
		start := neteq_timestamp_diff(packet.timestamp, buf.play_timestamp);
		lo := max(0, start);
		hi := min((buf.input).count, start + (buf.pcm).count);
		if hi > lo {
			copy_samples(view(buf.input, lo, hi), view(packet.samples, lo - start, hi - start));
			for *valid: view(buf.present, lo, hi) {
				valid.* = true;
			}
		}
	}
	contiguous := 0;
	for valid: buf.present {
		if !valid {
			break;
		}
		contiguous += 1;
	}
	count := (buf.pcm).count;
	consumed := count;
	level_ms := cast(float64)(buffered) * 1000 / cast(float64)(buf.sample_rate);
	buf.operation = .Normal;
	// 波形匹配的短段删除/重复，不通过重采样改变整帧音高。
	if contiguous >= count && buf.loss_samples == 0 && buf.recovery_left == 0 {
		mid := count / 2;
		window := buf.sample_rate / 400;
		min_lag := buf.sample_rate / 1000;
		max_lag := min(mid, buf.sample_rate / 100);
		lag := 0;
		if level_ms > buf.target_delay_ms + cast(float64)(buf.frame_ms) {
			max_lag = min(max_lag, contiguous - count);
			if max_lag >= min_lag {
				lag = neteq_match_lag(buf.input, mid, window, min_lag, max_lag, 1);
				buf.operation = .Accelerate;
				buf.stats.accelerated_samples += lag;
			}
		} else if level_ms < buf.target_delay_ms - cast(float64)(buf.frame_ms) / 2 {
			lag = -neteq_match_lag(buf.input, mid, window, min_lag, max_lag, -1);
			buf.operation = .Preemptive_Expand;
			buf.stats.expanded_samples -= lag;
		}
		if lag != 0 {
			copy_samples(view(buf.pcm, 0, mid), view(buf.input, 0, mid));
			{ i := mid; while i < mid + window { defer i += 1;
				weight := cast(float32)(i - mid + 1) / cast(float32)(window);
				buf.pcm[i] = buf.input[i] + (buf.input[i + lag] - buf.input[i]) * weight;
			} }
			copy_samples(view(buf.pcm, mid + window), view(buf.input, mid + window + lag, count + lag));
			consumed += lag;
		} else {
			copy_samples(buf.pcm, view(buf.input, 0, count));
		}
	} else {
		copy_samples(buf.pcm, view(buf.input, 0, count));
	}

	concealed := false;
	fade_samples := buf.sample_rate / 200;
	for *sample, i: buf.pcm {
		if !buf.present[i] {
			concealed = true;
			buf.loss_samples += 1;
			buf.plc_gain = max(0.0, 1 - cast(float32)(buf.loss_samples) / cast(float32)(buf.sample_rate / 10));
			sample.* = neteq_plc_sample(buf) * buf.plc_gain;
			buf.stats.concealed_samples += 1;
			buf.recovery_left = fade_samples;
		} else {
			buf.loss_samples = 0;
			if buf.recovery_left > 0 {
				weight := 1 - cast(float32)(buf.recovery_left) / cast(float32)(fade_samples);
				sample.* = sample.* * weight + neteq_plc_sample(buf) * buf.plc_gain * (1 - weight);
				buf.recovery_left -= 1;
			}
		}
	}
	if concealed {
		buf.operation = .Conceal;
	} else {
		copy_samples(buf.history, buf.pcm);
		buf.history_valid = true;
		window := buf.sample_rate / 400;
		buf.plc_period = neteq_match_lag(buf.history, count - window, window,
			buf.sample_rate / 500, min(buf.sample_rate / 80, count - window), -1);
		buf.plc_phase = 0;
	}
	buf.play_timestamp = cast(u32)((cast(u64)buf.play_timestamp + cast(u64)consumed) & 0xffffffff);
	for *packet: buf.packets {
		if packet.active && neteq_timestamp_diff(packet.timestamp, buf.play_timestamp) + count <= 0 {
			packet.active = false;
		}
	}
	// 长时间断流后重新建立水位，而不是持续追赶一个已经过时的播放时间轴。
	if buf.loss_samples >= buf.max_delay_ms * buf.sample_rate / 1000 && neteq_oldest_packet(buf) < 0 {
		buf.started = false;
		buf.has_arrival = false;
		buf.history_valid = false;
		buf.loss_samples = 0;
		buf.jitter_ms = 0;
		buf.target_delay_ms = cast(float64)(buf.base_delay_ms);
	}
	return buf.pcm;
}
//@endregion

//@region 波形匹配与丢包补偿

neteq_match_lag ::(samples: []float32, start, window, min_lag, max_lag, direction: int) -> int {
	best := min_lag;
	best_score: float64 = -2;
	// 每隔 4 样本估计相关度，搜索仍逐样本进行，避免相位精度降至 12kHz。
	for lag: min_lag..max_lag {
		dot, aa, bb: float64;
		{ i := 0; while i < window { defer i += 4;
			a := cast(float64)(samples[start + i]);
			b := cast(float64)(samples[start + i + direction * lag]);
			dot += a * b;
			aa += a * a;
			bb += b * b;
		} }
		score := dot / Math.sqrt(max(aa * bb, 1e-20));
		if score > best_score {
			best_score = score;
			best = lag;
		}
	}
	return best;
}

neteq_plc_sample ::(buf: *Neteq_Buffer) -> float32 {
	if !buf.history_valid || buf.plc_period <= 0 {
		return 0;
	}
	sample := buf.history[(buf.history).count - buf.plc_period + buf.plc_phase];
	buf.plc_phase = (buf.plc_phase + 1) % buf.plc_period;
	return sample;
}
//@endregion




