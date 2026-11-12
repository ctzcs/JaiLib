// audio.jai
// tlib 音频模块：Jai Sound_Player 的薄封装，API 形状对标 Foster.Audio。
//
// 不依赖 raylib——为 SDL2 迁移铺路。3D 空间化（VBAP/听者/多普勒）Sound_Player
// 本身支持（update_listener + stream 的 position/radius/SPATIALIZED），本期
// 只留 passthrough 接口，不做高层封装。
//
// 典型用法：
//
//   audio_init();
//   defer audio_shutdown();
//   swish := audio_load_sound("swish.wav");  // WAV=全量解码
//   music := audio_load_sound("theme.ogg");  // OGG=压缩流式
//   audio_play(music, .MUSIC, loop = true);
//   inst := audio_play(swish, .GENERAL_SFX);
//   audio_instance_set_volume(inst, 0.8);
//   audio_instance_set_rate(inst, 1.2);   // 音高/变速
//
// 注意：Sound_Data 必须在播放期间保持存活——audio_load_sound 的返回值由
// 本模块的注册表持有并负责释放（audio_free_sound / audio_shutdown）。

#import "Basic";
#import "Hash_Table";

SP :: #import "Sound_Player";
M  :: #import "Math"; // Vector3 / Quaternion（别名导入，避免 Math.Vector2 污染全局）

// ===========================================================================
// 配置与生命周期
// ===========================================================================

Audio_Config :: struct {
    // 混音线程自更新（true = 无需每帧调 audio_update）。
    update_from_a_thread := true;
    // 窗口失焦时是否继续出声（多数 OS 不支持）。
    audible_when_not_focused := false;
    // true = 流默认长活；false = 需每帧 keep（标记式管理，适合一次性特效）。
    keep_sounds_alive_by_default := true;
    // 感知音量（0..1，内部做感知->线性换算）。
    master_volume := 1.0;
}

audio_initialized: bool;

// 初始化音频设备与混音线程。失败（如无输出设备）返回 false——游戏应可在
// 无声模式下继续运行。
audio_init :: (config: Audio_Config) -> bool {
    ok := SP.sound_player_init(.{
        update_from_a_thread             = config.update_from_a_thread,
        audible_when_window_is_not_in_focus = config.audible_when_not_focused,
        keep_sounds_alive_by_default     = config.keep_sounds_alive_by_default,
    });
    if ok {
        audio_initialized = true;
        SP.set_master_volume(config.master_volume);
    }
    return ok;
}

// 终止音频系统并释放注册表里的全部 Sound_Data。
audio_shutdown :: () {
    if !audio_initialized return;

    SP.sound_player_shutdown(); // 先停设备/混音线程，流不再引用解码缓冲
    for audio_registry {
        free_sound_data(*it.data);
        free(it.path);
        free(it);
    }
    deinit(*audio_registry);
    audio_initialized = false;
}

// 每帧调用（update_from_a_thread=true 时为 no-op，保留以便切换线程模型）。
audio_update :: () {
    if !audio_initialized return;
    SP.update();
}

// 主音量（感知刻度 0..1）。
audio_set_master_volume :: (volume: float) {
    SP.set_master_volume(volume);
}

// 分类音量（GENERAL_SFX / AMBIENCES / FOOTSTEPS / UI / MUSIC）。
audio_set_category_volume :: (category: SP.Sound_Category, volume: float) {
    // SP 未提供 setter，直接写它的 mix_levels 表（混音线程只读该 float，
    // 与 SP 自身 set_master_volume 的写法同级）。
    SP.mix_levels[cast(int) category] = volume;
}

// ===========================================================================
// 声音（资产）加载
// ===========================================================================

Audio_Sound :: struct {
    data: SP.Sound_Data; // WAV=LINEAR_SAMPLE_ARRAY（全量解码）；OGG=OGG_COMPRESSED（流式）
    path: string;        // 注册表键，克隆持有
}

// 已加载声音注册表（路径 -> 声音），同一文件重复加载返回同一实例。
audio_registry: Table(string, *Audio_Sound);

// 加载声音文件（.wav 全量解码；.ogg 压缩流式）。失败打印错误并返回 null。
// 返回值由注册表持有，播放期间保持存活；用 audio_free_sound 释放。
audio_load_sound :: (path: string) -> *Audio_Sound {
    existing, found := table_find(*audio_registry, path);
    if found return existing;

    data := SP.load_audio_file(path, true);
    if !data.loaded {
        print("audio: 无法加载 %\n", path);
        return null;
    }

    sound := New(Audio_Sound);
    sound.data = data;
    sound.path = copy_string(path);
    table_set(*audio_registry, sound.path, sound);
    return sound;
}

// 释放一个声音（仍在播放的流会失效——先 audio_stop_all）。
audio_free_sound :: (sound: *Audio_Sound) {
    table_remove(*audio_registry, sound.path);
    free_sound_data(*sound.data);
    free(sound.path);
    free(sound);
}

audio_sound_loaded :: (sound: *Audio_Sound) -> bool {
    return sound != null && sound.data.loaded;
}

// ===========================================================================
// 实例（一次性播放）
// ===========================================================================

Audio_Instance :: SP.Sound_Stream;

// 播放一个实例并立即启动。volume 0..1（感知刻度），rate 为变速/音高倍率。
audio_play :: (sound: *Audio_Sound, category: SP.Sound_Category = .GENERAL_SFX, loop := false, volume := 1.0, rate := 1.0) -> *Audio_Instance {
    stream := SP.make_stream(*sound.data, category);
    if loop {
        SP.set_repeating(stream, true);
    }
    stream.user_volume_scale = volume;
    stream.rate_scale        = rate;
    SP.start_playing(stream);
    return stream;
}

// ---- 实例控制（Sound_Player 的流字段可现场改；写 volume/rate 走它的
// 平滑插值路径，无需自己加锁） ----

audio_instance_set_volume :: (instance: *Audio_Instance, volume: float) {
    instance.user_volume_scale = volume;
}

audio_instance_get_volume :: (instance: *Audio_Instance) -> float {
    return instance.user_volume_scale;
}

// 变速/音高（1.0 = 原速）。
audio_instance_set_rate :: (instance: *Audio_Instance, rate: float) {
    instance.rate_scale = rate;
}

audio_instance_set_loop :: (instance: *Audio_Instance, loop: bool) {
    SP.set_repeating(instance, loop);
}

// 静音/恢复（不改变 volume 设置）。
audio_instance_set_muted :: (instance: *Audio_Instance, muted: bool) {
    instance.inaudible = muted;
}

// 停止单个实例。Sound_Player 没有单流 stop API，这里以"静音 + 不保活"
// 近似（keep_sounds_alive_by_default=false 时流会被回收）。
audio_instance_stop :: (instance: *Audio_Instance) {
    instance.inaudible = true;
    instance.user_flags &= ~.DO_NOT_KILL;
}

// 播放进度（秒）。
audio_instance_time :: (instance: *Audio_Instance) -> float {
    data := instance.sound_data;
    if data.nchannels == 0 return 0;
    samples := instance.play_cursor; // 已是 per-channel 样本数
    return cast(float) samples / cast(float) data.sampling_rate;
}

// 停止某 manager_id 的全部声音（Sound_Player 的 abrupt stop；-1 = 全部）。
audio_stop_all :: (manager_id := -1) {
    SP.stop_all_sounds_abruptly(manager_id);
}

// ===========================================================================
// 3D 空间化 passthrough（本期不做高层封装，留接口）
// ===========================================================================

audio_set_listener :: (position: M.Vector3, orientation: M.Quaternion) {
    SP.update_listener(position, orientation);
}

audio_instance_set_position :: (instance: *Audio_Instance, position: M.Vector3, inner_radius := 0.5, outer_radius := 10.0) {
    instance.user_flags |= .SPATIALIZED;
    instance.position     = position;
    instance.inner_radius = inner_radius;
    instance.outer_radius = outer_radius;
}

// ===========================================================================
// 内部
// ===========================================================================

// 释放 Sound_Data 拥有的文件字节缓冲（WAV 的线性样本与 OGG 的压缩数据
// 都在其内；samples/decoder 只是指入其中的视图，不单独释放）。
free_sound_data :: (data: *SP.Sound_Data) {
    if !data.loaded return;
    if data.buffer.count > 0 free(data.buffer);
    data.buffer.count = 0;
    data.loaded = false;
}
