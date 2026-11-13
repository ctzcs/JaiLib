// 到达时间抖动估计，直译自 MetaVoiceChat 的 VcJitter（MIT）。
//
// 在时间窗内统计「本地时钟 − 发送时钟」偏移的均方根，作为目标缓冲
// 延迟的附加项。首个样本建立基准，返回 0。


Jitter :: struct {
	time_window:        float64;
	mean_offset_window: int;

	stopwatch: Stopwatch; // 本地单调时钟

	entries: [..]Jitter_Entry; // (发送时间戳, 本地时间戳) 窗口
	offsets: [..]float64; // 本地 − 发送 偏移窗口
}

Jitter_Entry :: struct {
	timestamp:       float64; // 发送侧时间戳（秒）
	local_timestamp: float64; // 本地单调时间戳（秒）
}

jitter_init ::(jitter: *Jitter, config: *Config) {
	if jitter == null || config == null {
		return;
	}
	jitter.time_window = cast(float64)(config.jitter_time_window);
	jitter.mean_offset_window = config.jitter_mean_offset_window;
}

// 送入一个到达帧的发送侧时间戳，返回当前 RMS 抖动（秒）。
jitter_update ::(jitter: *Jitter, timestamp: float64) -> float32 {
	if jitter == null {
		return 0;
	}
	if !jitter.stopwatch.running {
		stopwatch_start(*jitter.stopwatch);
		array_reset(*jitter.entries);
		array_reset(*jitter.offsets);
		return 0;
	}

	local := jitter_local_seconds(jitter);

	array_add(*jitter.entries, Jitter_Entry.{timestamp, local});
	while (jitter.entries).count > 0 && local - jitter.entries[0].local_timestamp > jitter.time_window {
		array_ordered_remove_by_index(*jitter.entries, 0);
	}

	array_add(*jitter.offsets, local - timestamp);
	while (jitter.offsets).count > jitter.mean_offset_window {
		array_ordered_remove_by_index(*jitter.offsets, 0);
	}

	if (jitter.entries).count == 0 || (jitter.offsets).count == 0 {
		return 0;
	}

	mean_offset: float64 = 0.0;
	for offset: jitter.offsets {
		mean_offset += offset;
	}
	mean_offset /= cast(float64)((jitter.offsets).count);

	square_sum: float64 = 0.0;
	for entry: jitter.entries {
		deviation := mean_offset + entry.timestamp - entry.local_timestamp;
		square_sum += deviation * deviation;
	}
	return cast(float32)(Math.sqrt(square_sum / cast(float64)((jitter.entries).count)));
}

jitter_local_seconds ::(jitter: *Jitter) -> float64 {
	return stopwatch_seconds(jitter.stopwatch);
}

jitter_dispose ::(jitter: *Jitter) {
	if jitter == null {
		return;
	}
	release(jitter.entries);
	release(jitter.offsets);
	jitter.* = .{};
}
