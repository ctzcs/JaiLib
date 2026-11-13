# voice（Jai）

从 olib `d3943f1b4608fdc22983ac57f73332f0ada1e3ae` 的 `thirdparty/voice`
迁移。上游语音编排源于 MetaVoiceChat（Connor Myers，MIT）；Opus 和 RNNoise
通过原生 C ABI 动态加载。PCM 自适应缓冲为 Jai 实现，无需 Rust 或 NetEQ 动态库。
保留参照仓库的 `LICENSE-NETEQ`；原生依赖的许可随各自发行包提供。

```jai
Voice :: #import "thirdparty/voice";
```

编译时添加 `-import_dir <JaiLib>`。支持 48 kHz 单声道、10/20/40 ms 帧，
配置、抖动估计、Opus 编解码、可选 RNNoise、PCM 缓冲/丢包补偿、收发管线和静音。
设备采集/播放与网络传输由宿主接入；用法和回调示例见 `tests/voicelib_test.jai`。
receiver 初始化后不可复制；receive/pull 通过内部互斥锁同步。
Opus 包在解码前拒收重复和逆序帧；PCM 缓冲接口支持乱序插入。

## 原生依赖与验证

Windows 需要 `opus.dll`、`rnnoise.dll`（x64）；Linux/macOS 使用对应的
`libopus.so`/`librnnoise.so` 或 `.dylib`。加载器依次尝试系统库搜索路径、
`VOICE_LIB_DIR`、当前目录的 `build/`。本仓库不捆绑这两个动态库。

```powershell
$env:VOICE_LIB_DIR = 'C:\path\to\voice-libraries'
python tools/check/main.py --only voice
```

20 组测试覆盖真实 Opus 编解码、RNNoise、收发回环、缓冲回绕、乱序/迟到拒收、
任意播放块大小、静音、内存所有权和运行期零分配，共 4,616 项断言。
测试要求两个原生库齐全，缺失会失败，不把跳过当通过。
已在 Windows x64、jacket 0.35.1 验证；其他平台和真实音频设备尚未验收。
