#scope_file

#scope_export

//@region 远端时钟、抖动与播放水位

Clock_Config :: struct {
    fixed_ms: float64;
    interpolation_ticks, input_lead_ticks, max_lead_ticks: int;
}

Remote_Clock :: struct {
    config: Clock_Config;

    offset_ms, rtt_ms, minimum_rtt_ms, jitter_ms: float64;

    remote_ms, local_received_ms, last_now_ms: float64;

    remote_tick, released: Tick;

    initialized, sampled: bool;
}

clock_init :: (c: *Remote_Clock, config: Clock_Config) -> Status {
    cfg := config;
    if !finite(cfg.fixed_ms) || cfg.fixed_ms <= 0 || cfg.fixed_ms > 10000 || cfg.interpolation_ticks < 0 || cfg.input_lead_ticks < 0 {
        return .Invalid_Config;
    }

    if cfg.max_lead_ticks == 0 {
        cfg.max_lead_ticks = 32;
    }

    if cfg.max_lead_ticks < 1 || cfg.max_lead_ticks > 1024 || cfg.input_lead_ticks > cfg.max_lead_ticks {
        return .Invalid_Config;
    }

    c.* = Remote_Clock.{
        config = cfg, initialized = true,
    };

    return .Ok;
}

clock_reset :: (c: *Remote_Clock) {
    cfg := c.config;
    c.* = Remote_Clock.{
        config = cfg, initialized = true,
    };
}

// remote_ms是回应端发包时的时钟；sent/received来自同一本机单调时钟。

clock_observe :: (c: *Remote_Clock, sent_ms, received_ms, remote_ms: float64, remote_tick: Tick) -> Status {
    if !c.initialized {
        return .Not_Ready;
    }

    if !finite(sent_ms) || !finite(received_ms) || !finite(remote_ms) || sent_ms < 0 || received_ms < sent_ms || remote_ms < 0 || received_ms - sent_ms > 120000 {
        return .Invalid_Data;
    }

    if c.sampled && (received_ms < c.local_received_ms || remote_ms < c.remote_ms || remote_tick < c.remote_tick) {
        return .Stale;
    }

    rtt := received_ms - sent_ms;
    offset := remote_ms - (sent_ms + received_ms) * 0.5;
    if !c.sampled {
        c.offset_ms, c.rtt_ms, c.minimum_rtt_ms, c.jitter_ms = offset, rtt, rtt, 0;
    } else {
        error := Math.abs(rtt - c.rtt_ms);
        c.jitter_ms += (error - c.jitter_ms) * 0.25;
        c.rtt_ms += (rtt - c.rtt_ms) * 0.125;
        c.minimum_rtt_ms = min(c.minimum_rtt_ms, rtt);
        // 新的低延迟样本权重较高；限制单次校时避免抖动令播放时间跳变。

        weight := (ifx rtt <= c.minimum_rtt_ms + 1 then 0.5 else 0.1);
        c.offset_ms += clamp((offset - c.offset_ms) * weight, -c.config.fixed_ms, c.config.fixed_ms);
    }

    c.remote_ms, c.remote_tick, c.local_received_ms = remote_ms, remote_tick, received_ms;
    c.last_now_ms = max(c.last_now_ms, received_ms);
    c.sampled = true;
    return .Ok;
}

clock_shift_tick :: (base: Tick, delta: float64) -> Tick {
    d := clamp(Math.floor(delta), -1000000, 1000000);
    if d >= 0 {
        n := (cast, trunc(u64)(d));
        return (ifx n > MAX_TICK - base then MAX_TICK else base + n);
    }

    n := (cast, trunc(u64)(-d));
    return (ifx n > base then 0 else base - n);
}

clock_estimate_tick :: (c: *Remote_Clock, now_ms: float64) -> (Tick, Status) {
    if !c.initialized || !c.sampled {
        return 0, .Not_Ready;
    }

    if !finite(now_ms) || now_ms < c.last_now_ms {
        return 0, .Stale;
    }

    c.last_now_ms = now_ms;
    return clock_shift_tick(c.remote_tick, (now_ms + c.offset_ms - c.remote_ms) / c.config.fixed_ms), .Ok;
}

clock_prediction_tick :: (c: *Remote_Clock, now_ms: float64) -> (Tick, Status) {
    estimate, status := clock_estimate_tick(c, now_ms);
    if status != .Ok {
        return 0, status;
    }

    lead := clamp((cast(int) (Math.ceil((c.rtt_ms * 0.5 + c.jitter_ms * 2) / c.config.fixed_ms))) + c.config.input_lead_ticks, 1, c.config.max_lead_ticks);
    return clock_shift_tick(estimate, (cast(float64) (lead))), .Ok;
}

clock_release_tick :: (c: *Remote_Clock, now_ms: float64) -> (Tick, Status) {
    estimate, status := clock_estimate_tick(c, now_ms);
    if status != .Ok {
        return 0, status;
    }

    delay := c.config.interpolation_ticks + (cast(int) (Math.ceil(c.jitter_ms / c.config.fixed_ms)));
    released := clock_shift_tick(estimate, -(cast(float64) (delay)));
    c.released = max(c.released, released);
    return c.released, .Ok;
}

//@endregion
// Iterator semantics adapted.
// Loop scopes adapted.
// Cast semantics adapted.
