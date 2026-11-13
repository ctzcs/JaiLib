# Web / wasm 目标 — JS 互操作契约与差距

面向 `jaic 0.35.1` + `lld -flavor wasm`（Jai 自带）。以下每条都是在本机实测评出来的，
不是查文档得来的；怀疑时按「如何复核」重跑一遍。

状态：**M1 完成**。Jai → wasm64 → JS 的调用链已经真跑通（导出、导入、内存、context、
日志、停止信号），`tests/wasm/` 是可运行的证据。**WebGL2 后端还没开始**，见最后一节。

---

## 0. 工具链：wasm-ld 从哪来

jacket 的 `-os wasm` 要一个外部 wasm-ld，通过环境变量 `JAIC_WASM_LD` 指定。本机没有
独立的 `wasm-ld`，但 Jai 自带的 `lld.exe` 加 `-flavor wasm` 就是它：

```bat
@echo off
"D:\MySpace\RefProject\jai\jai\bin\lld.exe" -flavor wasm %*
```

```bat
set JAIC_WASM_LD=%CD%\.build\wasm-ld.bat
jaic main.jai -os wasm -o -exe .build\fw.wasm
```

这个包装同时是**唯一能给 wasm-ld 传额外参数的口子**（`-os wasm` 路径没有
`-extra_linker_options` 之类的入口）。实测有用：要额外导出符号就加 `--export=name`，
要压体积就加 `--strip-debug`（见 §5）。

产物对照（同一个 `main.jai`）：

| 构建 | 大小 | 导出表 |
|---|---|---|
| 默认（带 DWARF） | 541 KB | 9 |
| `-o` | 541 KB | 9 |
| `-o -no_debug_info` | 200 KB | **183**（libc/WASI 全泄漏） |
| `-o` + 链接期 `--strip-debug` | **147 KB** | **9** ← 推荐 |

最后一行是 `tools/wasm/build.py` 用的方案：`-no_debug_info` 会让 jacket 把 `sin`/`malloc`/`memcpy`
这类 WASI shim 一起导出，而链接期 `--strip-debug` 只是丢调试信息，导出表保持干净。

---

## 1. 导出（Jai → JS）

**唯一可用的写法：`#program_export` 作声明前缀 + `#no_context`。**

```jai
#program_export
fw_step :: (dt: float64) -> s32 #no_context { ... }     // 产物：(f64) -> i32
```

实测对照表（用 `wasm` 类型段解析出来的真实签名）：

| 写法 | 产物签名 | 能用吗 |
|---|---|---|
| `#program_export` + `#no_context` | `(f64) -> i32` | ✅ |
| `#program_export`（无 `#no_context`） | `(i64, f64) -> i32` | ❌ 多一个 i64（隐藏 context 指针），JS 得先传 BigInt |
| `#program_export` 写成独立语句 `#program_export` ⏎ `fw_step;` | **根本没有 export** | ❌ jacket 不认这种形式 |
| `#program_export "名字"` | 干净 | ✅ 等同第一种，可自定义导出名 |

补充事实：

* `bool` 参数/返回值 → `i32`（0/1）。
* 多个返回值不是多值返回，而是**第一个参数变成隐藏的 out 指针**：
  `(a: s32, b: s32) -> (r1: s32, r2: s32)` 实测是 `(i64, i32, i32) -> void`。
  桥接口不要用多返回值，改成写指针或 struct。
* 指针参数是 **i64**（wasm64），JS 收到 BigInt。
* `main` 也会被导出（`(i32, i64) -> i32`），`_start` 同样（`() -> void`）。

---

## 2. 导入（JS → Jai）

不加库名的 `#foreign` 声明就够，符号落在 import module **`env`**：

```jai
fw_log :: (ptr: s32, len: s32) #foreign;      // => env.fw_log (i32, i32) -> ()
```

不需要 `--allow-undefined`，也不需要任何链接参数；`#foreign` 的 ABI 是 C 的，声明什么
签名 JS 就收到什么签名。

**桥接口一律用 `s32` 内存偏移而不是指针**：这样 JS 侧全程 Number，不碰 BigInt。
需要传指针时（比如 `fw_canvas_size(w: *s32, h: *s32)`）JS 收到 BigInt，用 `Number(p)`
当偏移即可——已实测。

---

## 3. 内存

* 模块**默认导出 `memory`**，不需要 `--export-memory`。
* 是 **wasm64（Memory64）**：memory 段 flags=`0x4`，初始 130~147 页（约 8.4 MB），无上限。
  jacket 明确不支持 wasm32：
  `error: jaic builds wasm64 (Memory64) only; Jai needs 8-byte pointers`。
* 所以指针 8 字节。JS 侧拿 `instance.exports.memory`，`Uint8Array(memory.buffer, offset, len)`
  里 offset 必须是 Number。
* 浏览器支持（caniuse / MDN，2026-11 查）：Chrome/Edge **133+**、Firefox **134+**、
  Safari **27.3+**，全球覆盖约 **75.6%**。这是「web 目标只能跑新浏览器」的硬约束。
* 普通线性内存可以长到 4 GiB 以上，但 **WASI 部分不能**：WASI preview1 的地址全是
  u32（见 §4），所以现实上限是 4 GiB。

---

## 4. WASI：绕不过去的桩

`-os wasm` 产出的是 WASI 模块。只要用到 `Basic` 的 `print`/`log`/`clock`/`args`，
就会带上这些导入（把 `print` 完全去掉才会消失）：

```
wasi_snapshot_preview1.fd_write / proc_exit / clock_time_get
                      / args_sizes_get / args_get / poll_oneoff
```

host.js 必须给桩。**关键坑**：WASI preview1 规范是为 32 位内存写的，所以
**所有 WASI 参数的地址都是 u32**，即使目标内存是 memory64。jacket 自己的 runtime 就写着：

```jai
// WASI preview 1 is specified for 32-bit memories, so every address it takes
// or fills in is a 32-bit offset.
Span32 :: struct { address: u32; length: u32; }   // = ciovec，8 字节
```

* iovec 步长是 **8 字节**（u32 + u32），不是 16。我第一版按 16 写，`print` 直接
  `RangeError: Invalid typed array length`。
* `nwritten` / `clock_time_get` 的 out 也是 u32 地址。
* `clock_time_get(clock: i32, precision: i64, out: u32)` —— precision 是 i64，JS 收到 BigInt。
* 未知导入统一返回 `0` 是安全的（这些都是 i32 errno）；若哪天出现返回 i64 的导入，
  桩必须返回 `0n`，否则 JS 抛 TypeError。
* `proc_exit` 桩建议**直接抛异常**：正常路径不该调到它，调到就是宿主入口用错了。

---

## 5. context：`#no_context` 里怎么还能用 Jai 运行时

`#no_context` 过程里不能碰 context（`array_add`/`sprint`/`print` 会报
`call-cannot-without-context`）。但导出的入口必须 `#no_context`，于是需要这份样板：

```jai
saved: *#Context;

#program_export
fw_boot :: () -> s32 #no_context {
    ctx := __jai_runtime_init(0, null);     // c_malloc 一个 context + temp storage
    if !ctx return 0;
    saved = ctx;
    push_context saved.* {
        context.logger = my_logger;         // 之后 log() 全走 JS
    }
    return 1;
}

#program_export
fw_step :: (dt: float64) -> s32 #no_context {
    if !saved return 0;
    keep := true;
    push_context saved.* {
        keep = my_update(dt);
        reset_temporary_storage();          // 每帧必须，否则内存一路涨
    }
    return keep ? 1 : 0;
}
```

要点：

* **不要调 `_start`**。它会跑 `main` → `__jai_runtime_fini` → `proc_exit`，实例就废了。
  只调 `fw_boot`。`main` 留个「被调起来了」的告警即可（jacket 需要一个 main 才出可执行文件）。
* `context.logger` 指向的过程**不能加 `#no_context`**：`Logger` 类型带 context 参数，
  签名不匹配会在间接调用处 trap（`null function or function signature mismatch`）。
* `push_context saved.*` 在 `#no_context` 里可用，这是 `Remap_Context` / `Runtime_Support`
  同一个套路。
* 临时内存：每帧 `reset_temporary_storage()`。实测 20,000 帧内存稳定在 9280 KiB 不涨；
  不 reset 的话 `sprint`/`log` 会持续吃堆。
* 别把状态放在 `main` 的栈上（对应 olib `web.odin` 里 `web_relocate_app` 那段注释）——
  用全局量或者自己在 `fw_boot` 里分配。

---

## 6. 复核方法

```bash
python tools/wasm/build.py          # 出 .build/fw.wasm + .build/fw_wasm_b64.js
node foster/tests/wasm/verify.mjs    # 无浏览器验证：900 帧、日志、停止信号全断言
```

看产物结构（导入/导出/内存/签名）：

```js
const m = new WebAssembly.Module(bytes);
WebAssembly.Module.imports(m); WebAssembly.Module.exports(m);
```

浏览器：直接开 `tests/wasm/index.html`（`file://` 走内嵌 base64；`http://` 走 fetch，
两条都在 Chrome/Edge 157 上实测过）。

---

## 7. 差距：WebGL2 后端还差什么

现在能跑的是「日志 + 帧循环 + canvas 尺寸」。画面部分一行都没有。清单：

### 7.1 平台抽象（必须先做，否则 wasm 根本编不过 jfoster）

`module.jai` 现在整条 SDL 链都是无条件 `#load` + `#library`，为 wasm 一 check 就死在
`POSIX` 的 static-assert（SDL3 绑定 → POSIX）。要按 `#if OS == .WASM` 隔离的东西：

| 范围 | 文件 | 量级 |
|---|---|---|
| SDL3 绑定 + `#library` | `internal/sdl3/*`（24 个文件）、`module.jai` 的 3 处 `#library` | 换条件编译，半天 |
| stb/miniz 原生库 | `module.jai` 的 `stb_impl`/`miniz_impl` | 小；wasm 侧要么重编 `.wasm` 要么内联 |
| Window | `window.jai`（44 个过程） | 全部要 web 分支：canvas 尺寸/标题/全屏/DPI/鼠标相对模式。~1 天 |
| App 循环 | `app.jai`（`app_run`/`app_tick`/`app_poll_events`…） | rAF 驱动 + 事件队列，1~2 天 |
| Input | `input/input.jai` + `states`/`virtual`（14 个入口） | 事件从 JS 灌进 `input_on_event`；键盘/鼠标先做，手柄后做，1~2 天 |
| Storage | `storage/*`（27 个过程） | localStorage/IndexedDB 后端，半天~1 天（可复用 olib 的语义） |

### 7.2 Graphics_Device 后端（真活儿）

jfoster 的后端是「SDL_GPU 一个实现」：

* `internal/graphics_device_sdl.jai`：**25 个过程 / 960 行**
* `internal/graphics_device_sdl_draw.jai`：**26 个过程 / 933 行**

WebGL2 要平行实现这 ~51 个过程 / ~1900 行。按 olib `web.odin` 的经验，麻烦点集中在：

1. **句柄模型**：SDL 用不透明指针，WebGL2 用整数对象名。要建「JS 侧句柄表」，
   Jai 侧把 u32 句柄塞进原来存指针的字段（olib 就是这么干的：`web_handle_u32`）。
2. **渲染管线 → program 对象**：SDL_GPU 是「pipeline 对象一次性描述 blend/depth/cull/
   vertex layout」，WebGL2 要拆成 program + VAO + blend state 手动设置。olib 的
   `fw_gl_create_pipeline(...)` 收 11 个标量参数建 program，然后每次 draw 再套状态。
3. **着色器** ✅（资产已就绪，见 §8）：jfoster 现在吃的是预编译 **SPIR-V/DXIL/MSL**
   （`content/shaders/*.hlsl` → `Compiled/*.spv`，`default_resource_data.jai` 直接
   `#load` 二进制）。WebGL2 只吃 **GLSL ES 3.00 文本**。12 个 GLSL ES 3.00 源已经在
   `internal/web/shaders/`，配套 `internal/web/web_shader_source.jai` 和
   `tools/build_glsl_es.py`；W3 只需要 `compileShader`/`linkProgram`。
4. **纹理格式与纹理解码**：SDL_GPU 的格式枚举（R8/RGBA8/SRGB/BCn…）要映射到 WebGL2 的
   internalFormat/format/type；BCn 在 WebGL2 里要扩展，直接不支持更省事。`.qoi`/`.png`
   解码目前靠 stb（原生库），web 侧得改成纯 Jai 或 JS `ImageDecoder`。
5. **命令缓冲/多帧 in flight**：SDL_GPU 有 command buffer + copy pass；WebGL2 没有。
   `sdl_begin_copy_pass`/`sdl_flush_commands` 这类要变成「立即执行 + 状态缓存」。
   olib 的做法是 JS 侧缓存状态、按 draw 顺序直发 GL 调用。
6. **target / 多重采样 / stencil**：render-to-texture 用 FBO，MSAA 用 renderbuffer，
   stencil 状态拆成单独的 depth-stencil 状态对象。
7. **每帧上传**：`sdl_upload_buffer_data`/`set_texture_data` → `bufferSubData`/
   `texSubImage2D`，注意 `UNPACK_FLIP_Y` 与 sRGB 的差异（跨后端像素级比对时会翻车）。

### 7.3 分阶段建议 + 量级

| 阶段 | 内容 | 估时 | 产出 |
|---|---|---|---|
| **W0** ✅ | 桥 + 构建 + 验证（本轮） | 已完成 | `tests/wasm/` |
| **W1** | `#if OS == .WASM` 隔离 SDL/stb/miniz；`jfoster` 模块能在 `-os wasm` 下 check 通过 | 2~3 天 | 空壳能编 |
| **W2** | Window/App/Input/Storage 的 web 分支（无图形） | 4~6 天 | 事件 + 时间 + 存储跑起来 |
| **W3** ✅ | WebGL2 最小后端：clear + 带纹理 quad，像素读回 PASS（312 帧 draw=312 clear=312，第 30 帧读回 3 个像素全对） | 已完成 |
| **W4** | 完整 Batcher/Textured/Msdf（字体/图集/着色器热替换） | 5~7 天 | 2D 管线等价 |
| **W5** | target/FBO、MSAA、stencil、纹理格式矩阵 | 3~5 天 | 与桌面视觉对齐 |
| **W6** | 性能与内存（<4GiB WASI 限制、纹理上限、每帧上传带宽） | 3~5 天 | 可交付 |

**总量级：20~35 人日**（不含美术资产重制）。W3 之前不能对任何人说「web 能跑 jfoster」。

### 7.4 风险点（按危险程度）

1. **Memory64 的浏览器覆盖率**（~75%）：Safari 27.3 之前、以及所有旧内核一律不支持。
   这是 jacket 的硬限制（wasm32 明确不支持），换编译器才能解决，不是我们能在 jfoster 里
   修的。做产品前先确认目标浏览器矩阵。
2. **着色器资产**：6 个默认着色器的 GLSL ES 版本已就绪（§8），剩下的风险只有**自定义
   着色器**：kit 层如果自己写了 HLSL，得走 `tools/build_glsl_es.py` 的转换链再过一遍
   手写/清洗，桌面那套 SPIR-V 不能直接用。另外 shader 热替换
   （`shader_pair_replace.jai`）在 web 不可用（`shader_pair_replace_web.jai` 是诚实桩），
   W4 要设计「GLSL → program 重编译」路径；§8.7 给了现成的探针做法。
3. **两套后端会漂移**：`graphics_device.jai` 是公开校验层，后端只有 `internal/` 下两份，
   同一份 `Draw_Command` 语义要在两边一致（尤其 blend/stencil/采样器）。建议 W3 起就
   建像素级对拍（桌面截一张、web 截一张）。
4. **WASI 4 GiB 上限 + 初始 8.4 MB**：大图集项目要注意；`print` 走的 fd_write 也只能
   寻址 32 位。
5. **没有 source map / 栈回溯**：`-o` 关掉了检查，wasm 报错只有 `wasm-function[NNN]`
   和函数名（未优化构建里名字还在）。调试期用 `python tools/wasm/build.py --debug` 出未优化版。

---

## 8. 着色器资产：GLSL ES 3.00（W3/W4 前置，已完成）

### 8.1 现状：桌面吃二进制，WebGL2 只能吃文本

| 项 | 形态 | 位置 |
|---|---|---|
| 源 | **HLSL**（D3D 风格：`cbuffer ... register(b0, space1)`、`Texture2D` + `SamplerState`、`SV_Position`/`SV_Target0`） | `content/shaders/{Batcher,Textured,Msdf}.hlsl` |
| 编译 | SDL_shadercross：HLSL → SPIR-V → {DXIL, MSL} | `content/shaders/compile.sh` |
| 产物 | 18 个二进制：6 个 `*.vertex`/`*.fragment` × `{spv,dxil,msl}` | `content/shaders/Compiled/` |
| 内嵌 | `#run` + `File.read_entire_file`，按 `device.driver` 选一种 | `graphics/default_resource_data.jai` |
| 上传 | `defaults_load_shader` → `shader_create(device, stage, code, sampler_count, uniform_buffer_count, entry_point)` | `graphics/defaults.jai` |

关键点：`graphics/graphics_device.jai` **从不看字节内容**，只把 `[] u8` 往 backend 传。
所以 web 侧唯一要做的是「同一张表，换成文本」。

6 个默认 stage 的语义（三份 HLSL 共用一个 vertex 结构）：

| program | 顶点属性 | uniform | 采样器 | 入口 |
|---|---|---|---|---|
| Batcher | loc 0/1/2/3 = f32x2 pos, f32x2 tex, **u8x4n** col, **u8x4n** mode（24 B） | vs slot 0: `mat4 Matrix` | fs slot 0: `Texture` | `vertex_main`/`fragment_main` |
| Textured | loc 0/1/2（20 B，PosTexCol） | vs slot 0: `mat4 Matrix` | fs slot 0: `Texture` | 同上 |
| Msdf | loc 0/1/2（24 B，走 Batcher 顶点流） | vs slot 0: `mat4 Matrix`，fs slot 0: `float DistanceRange` | fs slot 0: `Texture` | 同上 |

Batcher 的 solid/gradient/wash 由**顶点属性** `Type`（normalized ubyte4，255→1.0）选，
不是三个 shader：`Type.x` 纹理×顶点色（normal）、`Type.y` 纹理 alpha×顶点色（wash）、
`Type.z` 只要顶点色（**fill = solid**，两端顶点色不同就自动变成 **gradient**——
插值发生在 `vColor` 上）。桌面 SPIR-V 也是同一个 program，因为批处理要求一个 pipeline
吃所有 mode。

### 8.2 工具链实测（本机）

| 工具 | 位置 | 结论 |
|---|---|---|
| `shadercross` | `D:\Tools\ShaderCross\bin` | ✅ HLSL → SPIR-V 直接可用（`Batcher.hlsl` 的 `space2` 寄存器也认） |
| `spirv-cross` | `C:\VulkanSDK\1.4.357.0\Bin` | ✅ `--version 300 --es` 出 GLSL ES 3.00；写文件要用 `--output`（`-o` 不认） |
| `dxc` / `glslangValidator` | 同上 | ✅ 在，但这条链用不到 |
| `shaderc` / `naga` | — | ❌ 没装 |

跑通的链路：

```
shadercross Msdf.hlsl -e fragment_main -t fragment -s HLSL -o x.spv
spirv-cross x.spv --version 300 --es --relax-nan-checks --output x.glsl
```

**但转出来的东西不能当 W3 的源用**，三个硬伤（成品见 `internal/web/shaders/reference/*.glsl`）：

1. Msdf 的 `Texture.GetDimensions()` 被降成**两个** `sampler2D`
   （`SPIRV_Cross_CombinedTextureSampler` + 一个 `...DummySampler` 供 `textureSize()` 用），
   直接违反 `defaults_load_shader` 建立的 `SamplerCount == 1` 契约，W3 会白绑一个纹理单元。
2. 所有名字都变成 `in_var_TEXCOORD0` / `UniformBlock.Matrix` /
   `SPIRV_Cross_CombinedTextureSampler`——HLSL 里的 `Matrix` / `DistanceRange` / `Texture`
   一个都没保住。
3. 矩阵走 `layout(row_major)` + `spvWorkaroundRowMajor()` 恒等函数，`min/max` 外面套
   `isnan()` 护栏。

还有一个**会直接咬人**的坑：spirv-cross 把顶点侧 varying 叫 `out_var_TEXCOORD1`、
片元侧叫 `in_var_TEXCOORD1`；GLSL ES 3.00 的 varying **按名字**链接（varying 上的
`layout(location)` 是 ES 3.10 才有的），所以分开 cross 的两个 stage **链接不上**：

```
FRAGMENT varying in_var_TEXCOORD1 does not match any VERTEX varying
```

生成器里加了一步文本规范化（vertex `out_var_*` → `v_*`，fragment `in_var_*` → `v_*`）
才能过链接。这就是「机械转换只能当参考，不能当交付物」的具体理由。

### 8.3 交付物：12 个 GLSL ES 3.00 源

```
internal/web/shaders/
  batcher.vertex.glsl      batcher.fragment.glsl      <- canonical：W3 编译这 6 个
  textured.vertex.glsl     textured.fragment.glsl
  msdf.vertex.glsl         msdf.fragment.glsl
  reference/
    batcher.vertex.glsl    batcher.fragment.glsl      <- 生成物：等价性 oracle，不参与运行时
    textured.vertex.glsl   textured.fragment.glsl
    msdf.vertex.glsl       msdf.fragment.glsl
```

canonical 是**手写**的，保住 HLSL 的语义与名字：`Matrix` / `DistanceRange` / `Texture`
原样，一个纹理一个 sampler，一个 uniform slot 一个普通 uniform（不是 std140 block）。
默认精度 `precision highp float;`（ES 3.00 的片元阶段必须支持 highp）。

### 8.4 矩阵约定（最容易翻车的一处）

`Draw_Command.VertexUniformBuffers[0]` 里是 jfoster `Matrix4` 的**裸字节**，
`graphics/batcher.jai` 里 `_41/_42` 是平移（System.Numerics，行向量约定）。GLSL 的
`mat4` 是**列主序**，所以 `transpose = false` 上传后 `M_glsl == transpose(M_jfoster)`，于是：

```glsl
uniform mat4 Matrix;
gl_Position = Matrix * vec4(aPosition, 0.0, 1.0);   // == HLSL mul(Matrix, p)
```

W3 侧就只有一行 `gl.uniformMatrix4fv(loc, false, raw_blob)`——**不做任何 CPU 侧转置**，
和桌面 `SDL_PushGPU*UniformData` 推同一份字节。想改成 `vec4(pos) * Matrix` 必须同时把
`transpose` 置 true。这条不是注释级约定：`tools/build_glsl_es.py` 会**渲染对拍**，
用同一个 quad（画在 16,16–48,48）跑两种实现，读回像素并断言包围盒正好落在
`16,16..47,47`——矩阵转置接反的话包围盒立刻变形。

### 8.5 Jai 侧：`web_shader_source.jai`

`internal/web/web_shader_source.jai` 是 `default_resource_data.jai` 的 web 孪生体：

```jai
web_shader_source :: (variant: Web_Shader_Variant, stage: Web_Shader_Stage) -> string
web_shader_reference_source :: (variant: Web_Shader_Variant, stage: Web_Shader_Stage) -> string
WEB_SHADERS / WEB_SHADER_REFERENCE :: Web_Shader_Entry.[...]
WEB_SHADER_PROGRAMS :: Web_Shader_Program.[...]   // attrs / stride / 纹理单元 / uniform slot 数
```

- 内嵌方式：`#run` + `File.read_entire_file`（路径基于 `#filepath`）——**和桌面同一套机制**。
  `#string #load` 在 jacket 里不行（`directive #load is not supported in this position`），
  所以照 `embed_default_resource` 的写法来。
- 它由 `internal/web/graphics_device_web.jai` **文件末尾**的 `#load` 拉进来（放末尾是因为
  被 load 的文件以 `#scope_export` 收尾，放前面会改变后面 `sdl_*` 桩的可见性）。
  `graphics_device_web.jai` 只在 `#if OS == .WASM` 里加载，桌面构建看不到它。
- 不依赖 `graphics/enums.jai`，所以能单独 `#load` 起来检查。调用方手里的 `Shader_Stage`
  一行转换：`ifx gs == .VERTEX then Web_Shader_Stage.VERTEX else Web_Shader_Stage.FRAGMENT`
  （`.COMPUTE` 在 WebGL2 没有对应 stage）。

### 8.6 W3 怎么接（`Draw_Command` → WebGL2）

着色器（每个 program 做一次，然后缓存）：

```jai
vs_src := web_shader_source(.BATCHER, .VERTEX);       // GLSL ES 3.00 文本
vs := gl_create_shader(GL_VERTEX_SHADER, vs_src);      // createShader/shaderSource/compileShader
fs := gl_create_shader(GL_FRAGMENT_SHADER, web_shader_source(.BATCHER, .FRAGMENT));
prog := gl_link_program(vs, fs);                       // linkProgram + getProgramParameter(LINK_STATUS)
```

| `Draw_Command` 字段 | WebGL2 对应 | 三个默认 program 的取值 |
|---|---|---|
| `VertexBuffers[i].Buffer.Format` | `vertexAttribPointer(loc = Element.Index, size, type, normalized, stride, offset)` | Batcher 4 属性/24 B；Textured 3/20；Msdf 3/24 |
| `VertexBuffers[i].InstanceInputRate` | `vertexAttribDivisor(loc, 1)`；`0` = 逐顶点 | 默认 0 |
| `VertexUniformBuffers[0]`（裸字节） | `uniformMatrix4fv(loc("Matrix"), false, bytes)` | vs：64 B = `Matrix4` |
| `FragmentUniformBuffers[0]`（Msdf） | `uniform1f(loc("DistanceRange"), f32 @ offset 0)` | 上传的是 `[4] float32`，只用第 0 个（= HLSL 的 4 字节块） |
| `FragmentSamplers[0].Tex` | `activeTexture(TEXTURE0+0)` + `bindTexture` | `Texture` |
| `FragmentSamplers[0].Sampler` | `bindSampler(0, samplerObj)`（filter/wrap） | 和桌面同一份 `Texture_Sampler` 映射 |
| `BlendMode` | `blendEquationSeparate` + `blendFuncSeparate` + `colorMask` | shader 只输出 premultiplied vec4，混合全在状态里 |
| `CullMode` / `DepthCompare` / `DepthTest*` / `Stencil*` | `enable(CULL_FACE)` / `depthFunc` / `stencilFuncSeparate` | 默认全关 |
| `Viewport` / `Scissor` | `viewport()` / `scissor()` + `enable(SCISSOR_TEST)` | — |
| `IndexBuffer` / `IndexOffset` / `IndexCount` | `drawElements(TRIANGLES, IndexCount, UNSIGNED_INT, IndexOffset*4)` | `IndexOffset = batch.Offset*3`（元素数） |

uniform **slot** 到 shader 的对应：`VertexUniformBuffers[i]` → vs 的第 i 个 uniform slot，
`FragmentUniformBuffers[i]` → fs 的第 i 个。三个默认 program 的 fs 只有 Msdf 用 slot 0，
其余 0 个。超过一个 slot、或者要接自定义着色器时，改成 std140 UBO
（`layout(std140) uniform ...` + `bindBufferBase(UNIFORM_BUFFER, slot, ubo)`）更省事——
`internal/web/shaders/reference/*.glsl` 就是那种写法的现成样本，`WEB_SHADER_PROGRAMS`
里的 `*_uniforms` 记着每个 program 用几个 slot。

### 8.7 一条命令重新生成 / 验证

```bash
python tools/build_glsl_es.py            # 重新生成 reference/ + 验证 12 个 + 检查 Jai 内嵌
python tools/build_glsl_es.py --check    # 只验证；reference/ 与 HLSL 不同步就报错（CI 用）
python tools/build_glsl_es.py --gen-only # 只重新生成（不需要浏览器）
python tools/build_glsl_es.py --gpu      # 用真显卡（ANGLE/D3D11）跑，而不是 SwiftShader
```

默认走 SwiftShader（纯软件、无 GPU 的构建机也能过），`--gpu` 走真驱动。本机两条都过：

```
SwiftShader : ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)), SwiftShader driver)
GPU         : ANGLE (NVIDIA, NVIDIA GeForce RTX 3070, Direct3D11 vs_5_0 ps_5_0, D3D11)
```

验证不需要 GPU、不需要起 server：脚本把 12 个源内联进一个页面，用 headless
Chrome/Edge（`--use-angle=swiftshader`）跑真 WebGL2，再 `--dump-dom` 把结果收回来。
它断言四件事：

1. 12/12 `gl.compileShader` 成功且 `getShaderInfoLog` **为空**；
2. 6/6 program 链接成功；顶点属性 location/type 与 `Batcher_Vertex_Format` / PosTexCol
   一致；canonical 的 uniform 名字集合与 HLSL 一致
   （`Matrix:FLOAT_MAT4`、`Texture:SAMPLER_2D`、`DistanceRange:FLOAT`）；
3. canonical 和 reference 用同一份顶点/uniform/纹理渲染，**逐字节相同**（`maxdiff = 0`），
   覆盖 Batcher 的 normal / wash / fill-solid / fill-gradient 四种；
4. 包围盒必须是 `16,16..47,47`（矩阵约定正确）。

顺带还会生成 `.test_tmp/shader_src_probe/probe.jai`，把 `WEB_SHADERS` 每个条目的字节数和
磁盘文件比对，并跑 `jaic -os wasm -check`——证明内嵌进 wasm 的确实是同一份字节。

### 8.8 还没做 / 下一步

- **自定义着色器**：kit 层要是有自己的 HLSL，`reference/` 那套转换流程能用，但要按
  §8.2 的三条清洗（去重复 sampler、改名、定矩阵约定）。批量做的话建议把清洗步骤也写进
  `tools/build_glsl_es.py`。
- **热替换**：`shader_pair_replace_web.jai` 现在直接返回「不能替换」。W4 的做法是
  GLSL → program 试编译（`linkProgram` 后 `LINK_STATUS == false` 就不换），比桌面那套
  SDL pipeline 探针简单；`tools/build_glsl_es.py` 的 harness 就是现成的探针骨架。
- **参照物**：canonical 与 reference 目前只验证了「渲染结果一致」。等 W3 出第一帧，建议
  桌面截一张、web 截一张做 §7.4 第 3 条说的像素级对拍——那时才能确认 sRGB /
  `UNPACK_FLIP_Y` 这些跨后端差异。


## W3 现状（2026-11-13）

WebGL2 后端已可用：`gl_*` 桥 45 个导入，`internal/web/web_gl.jai`（~560 行枚举翻译 + 句柄缓存），
`sdl_*` 契约过程全部换成真实现（绘制主路径绿），自定义着色器/FBO/compute 是显式桩。

验证方式：`?driver=timeout` 让 host.js 用 `setTimeout(16)` 代替 rAF（Chrome 的
`--virtual-time-budget` 只推进 setTimeout，rAF 全程只触发 1 次），headless 下跑满 300+ 帧：

```
webgl2 : device=1 draw=312 pass=0 clear=312 tex_upload=3 buf_upload=625
webgl2 : shader=2 program=1 pipeline=1 readback=3 pixels=3 gl_error=0
pixel check : result=1 (1=PASS 0=FAIL -1=SKIP，第 30 帧读回)
```

W4 待办：std140 UBO 的 uniform 槽位表（现在按名字硬编码三个默认 program）、
Batcher 四种模式的像素级验证、字体/图集、着色器热替换（GLSL 试编译）、
`default_resource_data.jai` 的二进制裁剪、桌面↔web 像素对拍。

## W4 现状（2026-11-13）

- **std140 UBO**：uniform 按 binding 走，不再按名字 —— vertex slot i → binding i，
  fragment slot i → binding 8+i；矩阵是行主序裸字节（与桌面推同一份字节）。
- **Batcher 四模式**：solid / gradient / wash / fill 在 headless 下各自读回像素通过；
  fill 故意绑纹理并给纹理坐标，颜色仍是纯顶点色（证明真的忽略纹理）。
- **字体 / MSDF**：`internal/web/assets/Roboto.qoi`（212×212，QOI 因为在 wasm 里解不了 PNG），
  `sprite_font_create_from_msdf` 画一行文字，扫描带 1737/9240 非清屏像素；
  `DistanceRange` 走片段 UBO binding 8。
- **着色器热替换**：`shader_pair_replace_web.jai` 按桌面语义实现（候选 → 每个 probe 用
  `web_gl_probe_pipeline` 试建 → 全过才换，地址不变 → 失败 discard）。
  浏览器实测：v1→v2 换成纯黄成功；语法错 / varying 不匹配两次被拒，旧 program 继续画。
- 顺手修两个后端 bug：① VAO 缓存键从「哪个 buffer」改成「(pipeline, buffer)」
  （Batcher 与 Msdf 共用 mesh 时会炸出 750 次 GL_INVALID_OPERATION）；
  ② pre-flight 的 SPIR-V 4 字节对齐规则误伤 GLSL 文本。

`node foster/tests/wasm/verify.mjs` → 44/44；headless 浏览器 `pixel check result=1`。

W5 待办：FBO / render-to-target（`web_gpu.pass_fbo` 挂点已在）、MSAA、`blit_texture`、
桌面↔web 像素对拍、compute（WebGL2 没有，需换赛道）。

## W5 / W6 现状（2026-11-13）

已实现并验证：

- **离屏渲染目标**：FBO + 颜色/深度/模板附件；`begin_render_pass(.TARGET)` 真绑 FBO。
- **MSAA**：`renderbufferStorageMultisample` + `blitFramebuffer` 解析；1× 与 4× 的边缘
  部分覆盖像素计数已能区分（1× = 0，4× = 1，值 `(8,143,24)`）。
- **窗口级 MSAA**：`alpha:false` 下默认 framebuffer 实际是 **RGB8**（实测 RGBA8 的 MS
  renderbuffer 会 `INVALID_OPERATION`），所以窗口 MS FBO 用 RGB8 + D24S8，present 时 resolve。
- **`blit_texture`**：`blitFramebuffer` 同尺寸/缩放两条路径（ES 3.0 要求两端格式一致）。
- **格式矩阵**：未知格式显式拒绝（不再静默回落 RGBA8）；超 `MAX_TEXTURE_SIZE` 返回 0 并诊断。
- **读回诊断**：只支持 8 位 UNORM 颜色（RGBA8/R8/RG8）；浮点与深度明确拒绝并计数。
- **target 缓存收窄**：纹理销毁只作废真的引用了它的 target（`targets_invalidated` / `targets_kept` 可观测）。
- **`preserveDrawingBuffer` 可配**（`?preserve=1`，默认 false）。
- **帧时钟**：wasm 下 `platform_time_seconds()` 改由宿主 dt 累加的虚拟时钟驱动——
  否则 headless 的虚拟时间会让固定步长一帧都跑不出来（这是上一轮 update 停在第 60 帧的根因）。

### Render-to-target 的 Y 方向（2026-11-14 已修复）

矩阵/顶点和窗口坐标保持原约定。每个 target 附件新增一张私有渲染纹理，公开纹理
统一为「逻辑顶行位于 V=0」，与 CPU 上传一致：

- 1×：画到私有纹理，pass 结束时翻转 blit 到公开纹理。
- MSAA：先同坐标 resolve 到私有单采样纹理，再翻转 blit 到公开纹理。
  **不能把 resolve 和翻转合并**：OpenGL ES 3.0 §4.3.3 要求多重采样 resolve 的
  源/目标矩形边界相同。参见 [WebGL2 的 blitFramebuffer 契约及 ES 引用](https://registry.khronos.org/webgl/specs/2.0/#3.7.4)。
- 多个颜色/深度附件各用独立的单附件 FBO 视图复制，避免只解析颜色附件 0。
- 纹理读回和区域 blit 直接使用逻辑 Y，不再重复翻转；多行读回按逻辑顶行起排列。
  窗口/当前渲染 FBO 的读回仍走原来的左上坐标转换。
- 1× target 的 CPU 局部上传/作为 blit 落点会同步私有附件，后续 LOAD 不丢改动。
- blit 临时关闭 scissor，并在成功/异常路径恢复 framebuffer 和 scissor 状态。
  原先 W5 BLIT 上半部为空还有 scissor 裁剪这个独立原因。
- 配对纹理和 FBO 随 target 释放；同时修正深度格式判断中的空 case（Jai 不自动贯穿）。

验证：

```bat
python tools/wasm/build.py
node foster/tests/wasm/verify.mjs
python foster/tests/wasm/verify_webgl.py
python foster/tests/wasm/verify_webgl.py --gpu
```

Node 需支持 Memory64/table64（本机 Node 24.22.1：44/44；PATH 中的 22.17.0 无法加载产物）。
浏览器验证包含固定步长 3,100 帧和原 `index.html?driver=timeout` 的 60 秒虚拟时间：
W3 PIXEL、W4 BATCHER / FONT / HOT-REPLACE、W5 TARGET / BLIT / MSAA / ORIENTATION、
W6 LIMIT / WINDOW-MSAA / 3,000 帧 SOAK 全部是必须通过项。
SwiftShader 和 NVIDIA RTX 3070 / D3D11 均通过，GL errors=0，存活资源稳定。
ORIENTATION 使用非正方形 8×6 非对称像素，覆盖 CPU 上传、1×/4×+深度附件、多行/局部
读回、target→target 采样、局部写入、区域缩放 blit 及纹理/FBO/renderbuffer 释放。
完整报告保存到 `tests/wasm/.build/webgl_report.json`，分别保留 fixed / timer 的结果和日志。

### Program 缓存与 headless 回归（2026-11-14）

- 热替换失败的根因是 program 缓存把哈希值直接用作 shader 对的身份。
  `(vs=15, fs=16)` 和 `(vs=31, fs=32)` 在旧混合函数中生成相同的键，导致
  HotReload 复用 Batcher 的 program。现在表保存完整的两个 `u64` 资源句柄，
  独立计算桶哈希，并逐字段比较身份；shader 销毁时仍按完整键清理缓存。
  实测红→黄替换成功，编译失败和链接失败均保留黄色旧 program。
- Chromium 的 headless 虚拟时间与 GPU 页面合成组合可触发 blit feedback-loop 错误。
  独立的两个 FBO + `setTimeout` 页面也能复现，JavaScript 查询的读写绑定并不相同；
  关闭页面 GPU 合成后消失。验证脚本因此加 `--disable-gpu-compositing`，仅用于
  无头测试，不修改宿主渲染逻辑，也不吞掉 GL 错误。`--gpu` 下查询到的 WebGL renderer
  仍为 NVIDIA RTX 3070 / D3D11；软件测试仍为 SwiftShader。
  手动跑虚拟时间命令时也需要这个参数。正常浏览器无需更改配置。
  另外保留 GPU 页面合成、使用真实时钟连续运行 60 秒：以上像素检查和
  3,000 帧 SOAK 全过，GL errors=0，没有 GL_INVALID_OPERATION 警告。
