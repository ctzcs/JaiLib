// audio_test.jai
// tlib/audio 无设备依赖测试：WAV 解析、注册表语义、分类音量、实例时间换算。
// 真实发声走 samples/audio_demo.jai（不进测试门禁——CI 可能没有音频设备）。

#import "Basic";
#import "test_support";
#import "Hash_Table";

AU :: #import "audio";
SP :: #import "Sound_Player";
AF :: #import "File";   // File 模块别名（FI 与 asset_test 的顶层名冲突）
AM :: #import "Math";

// 生成一个最小 RIFF PCM s16 mono WAV（正弦波），返回写入的样本数。
write_test_wav :: (state: *Test_State, path: string, nsamples: int, rate := 44100) -> int {
    buf: String_Builder;
    append(*buf, "RIFF");
    le_u32(*buf, 36 + nsamples * 2);
    append(*buf, "WAVE");
    append(*buf, "fmt ");
    le_u32(*buf, 16);        // fmt chunk size
    le_u16(*buf, 1);         // PCM
    le_u16(*buf, 1);         // mono
    le_u32(*buf, rate);      // sample rate
    le_u32(*buf, rate * 2);  // byte rate
    le_u16(*buf, 2);         // block align
    le_u16(*buf, 16);        // bits per sample
    append(*buf, "data");
    le_u32(*buf, nsamples * 2);
    for 0..nsamples-1 {
        t := cast(float) it / cast(float) rate;
        v := cast(int) (AM.sin(t * 440.0 * 3.14159265 * 2.0) * 12000.0);
        le_u16(*buf, v);
    }
    data := builder_to_string(*buf);
    ok := AF.write_entire_file(path, data);
    free(data);
    expect(state, ok, "写测试 wav %", path);
    return nsamples;
}

le_u32 :: (buf: *String_Builder, v: int) {
    append(buf, cast(u8) (v       & 0xFF));
    append(buf, cast(u8) (v >> 8  & 0xFF));
    append(buf, cast(u8) (v >> 16 & 0xFF));
    append(buf, cast(u8) (v >> 24 & 0xFF));
}

le_u16 :: (buf: *String_Builder, v: int) {
    append(buf, cast(u8) (v      & 0xFF));
    append(buf, cast(u8) (v >> 8 & 0xFF));
}

test_audio :: (state: *Test_State) {
    _ := AF.make_directory_if_it_does_not_exist(".test_tmp/audio", true);
    path := ".test_tmp/audio/test.wav";

    // ---- WAV 解析（纯解析路径，无需音频设备） ----
    nsamples := write_test_wav(state, path, 4410); // 0.1s
    data := SP.load_audio_file(path, true);
    expect(state, data.loaded, "wav 应成功加载");
    expect(state, data.type == .LINEAR_SAMPLE_ARRAY, "wav 解码为线性样本");
    expect(state, data.nchannels == 1, "单声道");
    expect(state, data.sampling_rate == 44100, "采样率 44100");
    expect(state, data.nsamples_times_nchannels == nsamples, "样本数 %（实际 %）", nsamples, data.nsamples_times_nchannels);
    free(data.buffer);

    // ---- 注册表语义：重复加载同一文件返回同一实例；释放后可重新加载 ----
    s1 := AU.audio_load_sound(path);
    expect(state, s1 != null, "audio_load_sound 成功");
    s2 := AU.audio_load_sound(path);
    expect(state, s2 == s1, "同一文件命中注册表缓存");
    expect(state, AU.audio_sound_loaded(s1), "audio_sound_loaded");

    AU.audio_free_sound(s1);
    s3 := AU.audio_load_sound(path);
    expect(state, s3 != null && s3 != s1, "释放后重新加载得到新实例");
    AU.audio_free_sound(s3);

    // ---- 分类音量直写 SP 的 mix_levels ----
    AU.audio_set_category_volume(.UI, 0.5);
    expect(state, SP.mix_levels[cast(int) SP.Sound_Category.UI] == 0.5, "UI 分类音量 0.5");
    AU.audio_set_category_volume(.UI, 1.0);

    // ---- 实例时间换算（构造假流，不触设备） ----
    fake_data: SP.Sound_Data;
    fake_data.sampling_rate = 44100;

    fake: AU.Audio_Instance;
    fake.sound_data = *fake_data;
    fake.play_cursor = 44100;
    expect(state, AU.audio_instance_time(*fake) == 1.0, "44100 样本 @44.1kHz = 1.0s");
    fake.play_cursor = 22050;
    expect(state, AU.audio_instance_time(*fake) == 0.5, "22050 样本 @44.1kHz = 0.5s");
}
