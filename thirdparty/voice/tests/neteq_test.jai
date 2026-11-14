// PCM 抖动缓冲回归：不加载任何动态库，不依赖真实时钟或音频设备。

//@region 测试信号

neteq_energy :: (samples: [] float32) -> float64 {
    energy: float64;
    for sample: samples {
        energy += cast(float64) (sample) * cast(float64) (sample);
    }
    return energy;
}

neteq_expect_bounded :: (t: *Test, samples: [] float32, count: int) {
    expect_value(t, (samples).count, count);
    for sample: samples {
        if Math.isnan(sample) || Math.isinf(sample) || Math.abs(sample) > 1 {
            expectf(t, false, "非法输出样本 %v", sample);
            return;
        }
    }
}

neteq_expect_same :: (t: *Test, a, b: [] float32) {
    expect_value(t, (a).count, (b).count);
    for sample, i: a {
        if i >= (b).count || sample != b[i] {
            expectf(t, false, "样本 %d 不一致", i);
            return;
        }
    }
}
//@endregion

//@region 生命周期与包时间轴

neteq_validation :: (t: *Test) {
    for args: ([3] int.[.[0, 1, 960], .[48000, 2, 960], .[48000, 1, 0], .[48000, 1, 1000]]) {
        buf, ok := voicelib.neteq_create(args[0], args[1], args[2]);
        expect(t, !ok);
        voicelib.neteq_destroy(*buf);
    }
    buf, ok := voicelib.neteq_create(48000, 1, 960, max_packets_in_buffer = 0);
    expect(t, !ok);
    voicelib.neteq_destroy(*buf);
    buf, ok = voicelib.neteq_create(48000, 1, 960, min_delay_ms = 50, max_delay_ms = 40);
    expect(t, !ok);
    voicelib.neteq_destroy(*buf);
    buf, ok = voicelib.neteq_create(48000, 1, 960);
    expect(t, ok);
    if !ok {
        return;
    }
    bad: [960] float32;
    expect(t, !voicelib.neteq_insert(*buf, 0, 0, view(bad, 0, 10), 20, 0));
    expect(t, !voicelib.neteq_insert(*buf, 0, 0, view(bad, 0), 10, 0));
    bad[0] = nan32();
    expect(t, !voicelib.neteq_insert(*buf, 0, 0, view(bad, 0), 20, 0));
    expect_value(t, voicelib.neteq_current_buffer_ms(*buf), 0);
    voicelib.neteq_destroy(*buf);
    voicelib.neteq_destroy(*buf);
    expect_value(t, (voicelib.neteq_get_audio(*buf)).count, 0);
    expect_value(t, voicelib.neteq_current_buffer_ms(null), 0);
    voicelib.neteq_destroy(null);
}

neteq_startup_and_exact_pcm :: (t: *Test) {
    for n: (int.[480, 960, 1920]) {
        buf, ok := voicelib.neteq_create(48000, 1, n);
        expect(t, ok);
        if !ok {
            return;
        }
        frame_ms := n / 48;
        signal := make_sine_frame(0, n, 0.3);
        expected := NewArray(n, float32);
        copy_samples(expected, signal);
        expect(t, voicelib.neteq_insert(*buf, 0, 0, signal, frame_ms, 0));
        zero_slice(signal); // 入包必须深拷贝
        audio := voicelib.neteq_get_audio(*buf);
        expect_value(t, buf.operation, voicelib.Neteq_Operation.Buffering);
        expect_value(t, neteq_energy(audio), 0);
        expect_value(t, voicelib.neteq_current_buffer_ms(*buf), cast(u32) (frame_ms));
        expect(t, voicelib.neteq_insert(*buf, 1, cast(u32) (n), expected, frame_ms, cast(float64) (frame_ms) / 1000));
        audio = voicelib.neteq_get_audio(*buf);
        expect_value(t, buf.operation, voicelib.Neteq_Operation.Normal);
        neteq_expect_same(t, audio, expected);
        expect_value(t, voicelib.neteq_current_buffer_ms(*buf), cast(u32) (frame_ms));
        expect(t, voicelib.neteq_insert(*buf, 2, cast(u32) (2 * n), signal, frame_ms, cast(float64) (frame_ms) / 500));
        neteq_expect_same(t, voicelib.neteq_get_audio(*buf), expected);
        expect_value(t, neteq_energy(voicelib.neteq_get_audio(*buf)), 0); // 显式静音不做有声 PLC
        release(signal);
        release(expected);
        voicelib.neteq_destroy(*buf);
    }
}

neteq_reorder_duplicate_and_wrap :: (t: *Test) {
    buf, ok := voicelib.neteq_create(48000, 1, 960);
    expect(t, ok);
    if !ok {
        return;
    }
    defer voicelib.neteq_destroy(*buf);
    base: u32 = 0xfffffe00; // 第二包之前 RTP 时间戳回绕
    for frame: (int.[2, 0, 1]) {
        samples: [960] float32;
        for *sample: samples {
            sample.* = cast(float32) (frame + 1) / 4;
        }
        seq := cast(u16) ((65534 + frame) % 65536);
        expect(t, voicelib.neteq_insert(*buf, seq, wrap_timestamp(cast(u64) base + cast(u64) (frame * 960)), view(samples, 0), 20, 0.04 + cast(float64) (frame) * 0.001));
    }
    samples: [960] float32;
    expect(t, !voicelib.neteq_insert(*buf, 65534, base, view(samples, 0), 20, 0.1));
    expect(t, !voicelib.neteq_insert(*buf, 10, base + 1, view(samples, 0), 20, 0.1));
    {
        frame := 0;
        while frame < 3 {
            defer frame += 1;
            audio := voicelib.neteq_get_audio(*buf);
            neteq_expect_bounded(t, audio, 960);
            for sample: audio {
                if sample != cast(float32) (frame + 1) / 4 {
                    expectf(t, false, "乱序/回绕帧 %d 排序错误", frame);
                    return;
                }
            }
        }
    }
    expect(t, !voicelib.neteq_insert(*buf, 65535, wrap_timestamp(cast(u64) base + 960), view(samples, 0), 20, 0.2));
    expect_value(t, buf.stats.dropped_packets, 3);
}

neteq_capacity_and_restart :: (t: *Test) {
    buf, ok := voicelib.neteq_create(48000, 1, 960, max_packets_in_buffer = 3, max_delay_ms = 60);
    expect(t, ok);
    if !ok {
        return;
    }
    defer voicelib.neteq_destroy(*buf);
    samples: [960] float32;
    {
        frame := 0;
        while frame < 20 {
            defer frame += 1;
            for *sample: samples {
                sample.* = cast(float32) (frame) / 32;
            }
            expect(t, voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), view(samples, 0), 20, cast(float64) (frame) * 0.02));
            expect(t, voicelib.neteq_current_buffer_ms(*buf) <= 60);
        }
    }
    expect_value(t, buf.stats.dropped_packets, 17);
    audio := voicelib.neteq_get_audio(*buf);
    expect_value(t, audio[0], cast(float32) (17) / 32);
    // 跳变到新段，不继续播旧段，也不继承抖动估计。
    expect(t, voicelib.neteq_insert(*buf, 100, 96000, view(samples, 0), 20, 2));
    expect_value(t, voicelib.neteq_current_buffer_ms(*buf), 20);
    voicelib.neteq_get_audio(*buf);
    expect_value(t, buf.operation, voicelib.Neteq_Operation.Buffering);
    expect(t, voicelib.neteq_insert(*buf, 101, 96960, view(samples, 0), 20, 2.02));
    neteq_expect_bounded(t, voicelib.neteq_get_audio(*buf), 960);
    expect_value(t, buf.operation, voicelib.Neteq_Operation.Normal);
}

neteq_fractional_frame_delay_cap :: (t: *Test) {
    for n: (int.[480, 960, 1920]) {
        frame_ms := n / 48;
        cap_ms := cast(u32) (frame_ms * 5 / 2);
        buf, ok := voicelib.neteq_create(48000, 1, n, max_delay_ms = cap_ms, min_delay_ms = cap_ms);
        expect(t, ok);
        if !ok {
            return;
        }
        samples := NewArray(n, float32);
        {
            frame := 0;
            while frame < 2 {
                defer frame += 1;
                expect(t, voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * n), samples, frame_ms, cast(float64) (frame * frame_ms) / 1000));
            }
        }
        voicelib.neteq_get_audio(*buf);
        expect_value(t, buf.operation, voicelib.Neteq_Operation.Normal);
        release(samples);
        voicelib.neteq_destroy(*buf);
    }
}

//@endregion

//@region 自适应延迟、伸缩与 PLC

neteq_adaptive_delay :: (t: *Test) {
    buf, ok := voicelib.neteq_create(48000, 1, 960, max_delay_ms = 100, additional_delay_ms = 10);
    expect(t, ok);
    if !ok {
        return;
    }
    defer voicelib.neteq_destroy(*buf);
    samples: [960] float32;
    {
        frame := 0;
        while frame < 80 {
            defer frame += 1;
            arrival := cast(float64) (frame) * 0.02 + (ifx frame % 2 == 0 then 0.0 else 0.008);
            expect(t, voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), view(samples, 0), 20, arrival));
        }
    }
    expect(t, buf.target_delay_ms > 75 && buf.target_delay_ms <= 100);
    {
        frame := 80;
        while frame < 300 {
            defer frame += 1;
            expect(t, voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), view(samples, 0), 20, cast(float64) (frame) * 0.02));
        }
    }
    expectf(t, Math.abs(buf.target_delay_ms - 50) < 0.01, "稳定网络后目标延迟未回落: %f", buf.target_delay_ms);
}

neteq_waveform_time_stretch :: (t: *Test) {
    for n: (int.[480, 960, 1920]) {
        buf, ok := voicelib.neteq_create(48000, 1, n);
        expect(t, ok);
        if !ok {
            return;
        }
        {
            frame := 0;
            while frame < 6 {
                defer frame += 1;
                signal := make_sine_frame(frame, n, 0.3);
                expect(t, voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * n), signal, n / 48, cast(float64) (frame * n) / 48000));
                release(signal);
            }
        }
        audio := voicelib.neteq_get_audio(*buf);
        expect_value(t, buf.operation, voicelib.Neteq_Operation.Accelerate);
        expect(t, buf.stats.accelerated_samples > 0);
        neteq_expect_bounded(t, audio, n);
        ideal := make_sine_frame(0, n, 0.3);
        expectf(t, correlation(audio, ideal) > 0.98, "伸缩纯音相关性过低，帧长 %d", n);
        release(ideal);
        low, low_ok := voicelib.neteq_create(48000, 1, n);
        expect(t, low_ok);
        if low_ok {
            {
                frame := 0;
                while frame < 2 {
                    defer frame += 1;
                    signal := make_sine_frame(frame, n, 0.3);
                    expect(t, voicelib.neteq_insert(*low, cast(u16) (frame), cast(u32) (frame * n), signal, n / 48, cast(float64) (frame * n) / 48000));
                    release(signal);
                }
            }
            voicelib.neteq_get_audio(*low); // 两帧正常水位降至一帧，确定触发低水位路径
            audio = voicelib.neteq_get_audio(*low);
            expect_value(t, low.operation, voicelib.Neteq_Operation.Preemptive_Expand);
            expect(t, low.stats.expanded_samples > 0);
            neteq_expect_bounded(t, audio, n);
            {
                i := 1;
                while i < (audio).count {
                    defer i += 1;
                    expectf(t, Math.abs(audio[i] - audio[i - 1]) < 0.06, "伸缩拼接不连续");
                }
            }
        }
        voicelib.neteq_destroy(*low);
        voicelib.neteq_destroy(*buf);
    }
}

neteq_loss_concealment_and_recovery :: (t: *Test) {
    buf, ok := voicelib.neteq_create(48000, 1, 960);
    expect(t, ok);
    if !ok {
        return;
    }
    defer voicelib.neteq_destroy(*buf);
    for frame: (int.[0, 2]) {
        signal := make_sine_frame(frame, 960, 0.3);
        expect(t, voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), signal, 20, cast(float64) (frame) * 0.02));
        release(signal);
    }
    voicelib.neteq_get_audio(*buf);
    audio := voicelib.neteq_get_audio(*buf);
    expect_value(t, buf.operation, voicelib.Neteq_Operation.Conceal);
    expect_value(t, buf.stats.concealed_samples, 960);
    expect(t, neteq_energy(audio) > 0.1);
    neteq_expect_bounded(t, audio, 960);
    signal := make_sine_frame(2, 960, 0.3);
    audio = voicelib.neteq_get_audio(*buf);
    expect_value(t, buf.operation, voicelib.Neteq_Operation.Normal);
    expect_value(t, audio[959], signal[959]);
    release(signal);
    first_loss_energy: float64;
    {
        frame := 0;
        while frame < 22 {
            defer frame += 1;
            audio = voicelib.neteq_get_audio(*buf);
            neteq_expect_bounded(t, audio, 960);
            if frame == 0 {
                first_loss_energy = neteq_energy(audio);
            }
            if frame >= 5 {
                expect_value(t, neteq_energy(audio), 0);
            }
        }
    }
    expect(t, first_loss_energy > 0);
    expect_value(t, buf.operation, voicelib.Neteq_Operation.Buffering);
    // 断流重新启动；发送端允许从新的时间轴开始。
    silence: [960] float32;
    {
        frame := 0;
        while frame < 2 {
            defer frame += 1;
            expect(t, voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), view(silence, 0), 20, cast(float64) (frame) * 0.02 + 2));
        }
    }
    expect_value(t, neteq_energy(voicelib.neteq_get_audio(*buf)), 0);
}

neteq_network_trace :: (t: *Test) {
    buf, ok := voicelib.neteq_create(48000, 1, 960, max_delay_ms = 120);
    expect(t, ok);
    if !ok {
        return;
    }
    defer voicelib.neteq_destroy(*buf);
    delivered: [200] bool;
    // 4 秒，包含乱序、重复包、抖动和约 9% 丢包；每 20ms 拉一帧。
    {
        tick := 0;
        while tick < 420 {
            defer tick += 1;
            now_ms := tick * 10;
            {
                frame := 0;
                while frame < 200 {
                    defer frame += 1;
                    if delivered[frame] || frame % 11 == 4 {
                        continue;
                    }
                    pattern := int.[0, 35, 5, 10];
                    arrival_ms := frame * 20 + 20 + pattern[frame % 4];
                    if arrival_ms > now_ms {
                        continue;
                    }
                    signal := make_sine_frame(frame, 960, 0.3);
                    voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), signal, 20, cast(float64) (now_ms) / 1000);
                    if frame % 7 == 0 {
                        expect(t, !voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), signal, 20, cast(float64) (now_ms) / 1000));
                    }
                    release(signal);
                    delivered[frame] = true;
                }
            }
            if tick % 2 == 0 {
                neteq_expect_bounded(t, voicelib.neteq_get_audio(*buf), 960);
                expect(t, voicelib.neteq_current_buffer_ms(*buf) <= 120);
                expect(t, buf.target_delay_ms >= 40 && buf.target_delay_ms <= 120);
            }
        }
    }
    expect(t, buf.stats.concealed_samples > 0);
    expect(t, buf.stats.dropped_packets > 0);
}
//@endregion

//@region 播放块与内存纪律

neteq_receiver_chunking_and_mute :: (t: *Test) {
    config, ok := make_config();
    expect(t, ok);
    a, a_ok := voicelib.neteq_create(48000, 1, 960);
    b, b_ok := voicelib.neteq_create(48000, 1, 960);
    expect(t, a_ok && b_ok);
    if !a_ok || !b_ok {
        voicelib.neteq_destroy(*a);
        voicelib.neteq_destroy(*b);
        return;
    }
    whole := voicelib.Voice_Receiver.{ config = config, mode = .Neteq, neteq_buffer = a, neteq_read = 960 };
    split := voicelib.Voice_Receiver.{ config = config, mode = .Neteq, neteq_buffer = b, neteq_read = 960 };
    Thread.init(*whole.mutex);
    whole.mutex_initialized = true;
    defer voicelib.voice_receiver_dispose(*whole);
    Thread.init(*split.mutex);
    split.mutex_initialized = true;
    defer voicelib.voice_receiver_dispose(*split);
    {
        frame := 0;
        while frame < 6 {
            defer frame += 1;
            signal := make_sine_frame(frame, 960, 0.3);
            expect(t, voicelib.neteq_insert(*whole.neteq_buffer, cast(u16) (frame), cast(u32) (frame * 960), signal, 20, cast(float64) (frame) * 0.02));
            expect(t, voicelib.neteq_insert(*split.neteq_buffer, cast(u16) (frame), cast(u32) (frame * 960), signal, 20, cast(float64) (frame) * 0.02));
            release(signal);
        }
    }
    expected: [9 * 960] float32;
    actual: [9 * 960] float32;
    voicelib.voice_receiver_pull(*whole, view(expected, 0));
    pos := 0;
    for chunk: (int.[1, 127, 512, 801, 2048, 513, 1000, 3638]) {
        voicelib.voice_receiver_pull(*split, view(view(actual, pos), 0, chunk));
        pos += chunk;
    }
    expect_value(t, pos, (actual).count);
    neteq_expect_same(t, view(actual, 0), view(expected, 0));
    expect_value(t, split.neteq_buffer.stats, whole.neteq_buffer.stats);
    // 输出静音应写零，且仍推进消费位置。
    muted: [100] float32;
    split.is_output_muted = true;
    voicelib.voice_receiver_pull(*split, view(muted, 0));
    expect_value(t, neteq_energy(view(muted, 0)), 0);
    expect_value(t, split.neteq_read, 100);
}

neteq_reject_old_packet_outside_window :: (t: *Test) {
    buf, ok := voicelib.neteq_create(48000, 1, 960, max_delay_ms = 80);
    expect(t, ok);
    if !ok {
        return;
    }
    defer voicelib.neteq_destroy(*buf);
    samples: [960] float32;
    for frame: (int.[2, 3, 0]) {
        expect(t, voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), view(samples, 0), 20, cast(float64) (frame) * 0.02));
    }
    // 新包向前可裁剪，旧包不能把整体时间窗拉到 100ms。
    expect(t, !voicelib.neteq_insert(*buf, 65535, 0xfffffc40, view(samples, 0), 20, 0.1));
    expect_value(t, voicelib.neteq_current_buffer_ms(*buf), 60);
}

neteq_runtime_no_allocations :: (t: *Test) {
    buf, ok := voicelib.neteq_create(48000, 1, 960);
    expect(t, ok);
    if !ok {
        return;
    }
    samples: [960] float32;
    previous := context.allocator;
    context.allocator = Allocator.{ panic_alloc, null };
    accepted := true;
    {
        frame := 0;
        while frame < 100 {
            defer frame += 1;
            accepted = voicelib.neteq_insert(*buf, cast(u16) (frame), cast(u32) (frame * 960), view(samples, 0), 20, cast(float64) (frame) * 0.02) && accepted;
            voicelib.neteq_get_audio(*buf);
        }
    }
    voicelib.neteq_destroy(*buf); // 即使当前 allocator 不同，也用初始化时的 allocator 释放
    context.allocator = previous;
    expect(t, accepted);
}
//@endregion
