// audio_demo.jai
// 无窗口音频 demo（对标 olib asset example 的"无头可跑"性质）：
// 程序生成正弦波 WAV -> audio_play 多实例（不同音量/音高/循环）-> 3 秒后退出。
//
// 构建：  jai -no_cwd -import_dir . -import_dir bindings samples/audio_demo.jai
// 运行：  需要可用音频输出设备；无声环境会打印提示并正常退出。

#import "Basic";
#import "File";
#import "Math";

AU :: #import "audio";

main :: () {
    ok := AU.audio_init(.{});
    if !ok {
        print("audio_demo: 音频初始化失败（无输出设备？），退出。\n");
        return;
    }

    _ := make_directory_if_it_does_not_exist(".test_tmp", true);
    path := ".test_tmp/audio_demo.wav";
    write_demo_wav(path, 44100 * 2); // 2 秒 A4 正弦，带淡入淡出

    sound := AU.audio_load_sound(path);
    if sound == null {
        print("audio_demo: 生成/加载 wav 失败。\n");
        AU.audio_shutdown();
        return;
    }

    AU.audio_set_category_volume(.MUSIC, 0.9);

    // 1) 循环"背景音"：低音量、原速。
    bg := AU.audio_play(sound, .MUSIC, loop = true, volume = 0.35);
    // 2) 两个一次性实例：不同音高（rate）模拟变调。
    AU.audio_play(sound, .GENERAL_SFX, volume = 0.8, rate = 1.5);
    AU.audio_play(sound, .GENERAL_SFX, volume = 0.6, rate = 0.75);

    print("audio_demo: 播放 3 秒...\n");
    start := current_time_monotonic();
    while true {
        elapsed_ms, _ := to_milliseconds(current_time_monotonic() - start);
        if elapsed_ms >= 3000 break;

        // 播到一半把背景音量拉高一点，验证实时音量控制。
        if elapsed_ms >= 1500 {
            AU.audio_instance_set_volume(bg, 0.6);
        }
        AU.audio_update();
        sleep_milliseconds(10);
    }

    AU.audio_stop_all();
    AU.audio_shutdown();   // 音源随 registry 在 shutdown 里统一释放（先 join 线程）
    print("audio_demo: 完成。\n");
}

// 2 秒 44.1kHz 正弦 + 首尾 20ms 淡入淡出，最小 RIFF PCM s16 mono。
write_demo_wav :: (path: string, nsamples: int) {
    buf: String_Builder;
    append(*buf, "RIFF");
    le_u32(*buf, 36 + nsamples * 2);
    append(*buf, "WAVE");
    append(*buf, "fmt ");
    le_u32(*buf, 16);
    le_u16(*buf, 1);         // PCM
    le_u16(*buf, 1);         // mono
    le_u32(*buf, 44100);
    le_u32(*buf, 44100 * 2);
    le_u16(*buf, 2);
    le_u16(*buf, 16);
    append(*buf, "data");
    le_u32(*buf, nsamples * 2);

    fade := 44100 / 50; // ~20ms
    for 0..nsamples-1 {
        t := cast(float) it / 44100.0;
        v := sin(t * 440.0 * PI * 2.0) * 12000.0;
        if it < fade            v *= cast(float) it / cast(float) fade;
        if it > nsamples - fade v *= cast(float) (nsamples - it) / cast(float) fade;
        le_u16(*buf, cast(int) v);
    }

    data := builder_to_string(*buf);
    _ := write_entire_file(path, data);
    free(data);
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
