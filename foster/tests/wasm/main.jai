// jfoster — W2/W3/W4 验收示例：**真的**用 jfoster 的 App 跑在浏览器里，并且真的出像素
//
// 这个文件是 W2（平台层）、W3（WebGL2 最小可绘制后端）、W4（std140 UBO /
// Batcher 四模式 / 字体图集 / 着色器热替换）三段的验收载体：
//
//   W2 验的东西（浏览器控制台里能一条条看到）：
//     1. App.update 被宿主一帧一帧驱动（帧号 / dt / 累积时间）
//     2. 窗口尺寸来自 canvas（window_size / window_size_in_pixels / content scale）
//     3. 键盘真的进了 Input（keyboard_down/pressed，事件计数来自 fw_stats）
//     4. 鼠标位置 / 滚轮 / 焦点事件进得来
//     5. 存档走 app_user_path 的虚拟根（OPFS/localStorage），写→读→列目录闭环
//     6. 剪贴板写→读闭环
//     7. App.exit → fw_step 返回 0 → 宿主停 rAF
//
//   W3 验的东西（每帧都在画，第 30 帧做一次读回断言）：
//     8. clear：整块画布先被清成 (16,32,48,255)
//     9. 一个**带纹理**的 quad：走默认 Textured program（GLSL ES 3.00）+ 8×8
//        纹理（左半红、右半蓝）+ 正交矩阵 + 索引绘制
//    10. 从 Jai 侧 gl.readPixels 读回三块像素并断言颜色：
//          quad 内左半 = (255,0,0,255)    ← 纹理 + 顶点色 + 矩阵 + 视口全对
//          quad 内右半 = (0,0,255,255)    ← 纹理坐标真的映射上了
//          quad 外    = (16,32,48,255)    ← 几何边界正确（没有铺满全屏）
//    11. fw_stats(100+i) 报 GL 侧计数（draw / pass / clear / upload / shader /
//        program / pipeline / readback / GL error）—— 每一条都是客观数字
//
//   W4 验的东西（本文件新增的三段）：
//    12. **Batcher 四模式像素验证**：solid / gradient / wash / fill 各画一块，
//        读回各自中心的像素并断言颜色。Batcher 顶点 24 字节 4 属性
//        （pos f32×2 / tex f32×2 / col u8×4n / mode u8×4n），其中 mode 是
//        fragment 里那三个分量，决定「乘纹理 / 只用纹理 alpha / 纯顶点色」。
//        fill 那一块**故意绑了纹理并给了纹理坐标**，断言颜色仍然是纯顶点色 ——
//        这是 fill 模式真的忽略纹理的证据；wash 那一块断言的是 alpha 混合后的
//        颜色（纹理 alpha = 128/255），这是 wash 真的只吃 alpha 的证据。
//    13. **字体 / MSDF 图集**：用内嵌的 Roboto MSDF 图集（wasm 侧是
//        internal/web/assets/Roboto.qoi，和桌面同一个 PNG 的同一批像素）建
//        Sprite_Font，画一行文字，读回一整条扫描带数非清屏像素 → 证明「不是
//        全空白」。DistanceRange 走片段 UBO binding 8（= 8 + fragment slot 0），
//        由 sprite_font_create_from_msdf 推的 [DistanceRange,0,0,0] 共 16 字节。
//    14. **着色器热替换**：ShaderPairTryReplace 用真 GLSL 候选 + web_gl_probe_pipeline
//        逐条 probe 试建，全过才就地换掉 vertex/fragment（地址不变）。三段实测：
//          a) 换成一个**有效但不画纹理**的片元 shader → 读回像素从红变成黄（真的换了）；
//          b) 换成一个**语法错**的片元 shader → 返回 false（编译失败）；
//          c) 换成一个**能编译但对不上 varying** 的片元 shader → 返回 false（链接失败）；
//        b) 与 c) 之后都再读一次同一像素，必须还是 a) 的黄 —— 旧 program 仍然在画。
//
//   W5 验的东西（离屏 Target / MSAA / blit，本文件新增的三段）：
//    15. **离屏 Target（FBO）**：建一张 256×256 的 Target，把四色象限画进去
//        （走 Batcher，fill 模式），再把它**当纹理**画到窗口左侧，然后从屏幕读回
//        四个象限的采样点并断言颜色。这是「渲染到纹理 → 采样这张纹理」的完整闭环：
//        任何一步（FBO 拼装、附件、纹理采样、blit/采样路径）错都会让读回值不对。
//    16. **MSAA 1× vs 4×**：同一个 256×256 尺寸建两张 Target，只有 Sample_Count
//        不同（.ONE / .FOUR），两边画**同一个** 45° 三角形（顶点 (0,0) (256,0)
//        (0,256)，斜边 x+y=256 正好穿过像素角点）。读回同一条边所在的行，数
//        「部分覆盖像素」（既不是清屏色也不是三角形色）：
//          1× → 0 个（像素中心恰好落在边上，光栅化按填充规则一致地算内/外）
//          4× → 1 个（每行恰好一个像素的 4 个子样本被边界分开 = 2/4 覆盖，
//                resolve 后 = (0+0+16+16)/4=8, (255+255+32+32)/4=143, 48/2=24）
//        0 → 1 这个变化就是「MSAA 真的在采样，而不是把 sample count 记了一下」。
//    17. **blit_texture**：同尺寸、同格式从 target 的附件拷到一张普通纹理
//        （glBlitFramebuffer），再从**落点纹理**读回四个象限断言 —— 证明拷贝
//        真的发生了，而不是「源和目标碰巧一样」。
//
//   W6 验的东西（窗口级 MSAA / 超限拒绝 / 内存 soak）：
//    18. **窗口级 MSAA**：app_run 的 flags 里带 MULTI_SAMPLED_BACK_BUFFER。断言
//        `App.device.backbuffer_format.SampleCount` 报的是**真实**样本数（不是被
//        静默降级成 1），并且和 fw_stats(200+10)（窗口 MS FBO 的 samples）一致、
//        fw_stats(200+9)（present 时的 resolve 次数）> 0；再读回一帧，确认画面
//        （W3 的红/蓝 + 清屏色）在 MSAA 下仍然正常。
//    19. **超限拒绝**：故意建一张比 MAX_TEXTURE_SIZE 大的纹理（fw_stats(200+22)
//        给出上限），断言拿到的是 **0 句柄**（不是「有效但不可用」），并且
//        fw_stats(200+12)（texture_size_rejections）加了 1 —— 日志里那行
//        "超过 MAX_TEXTURE_SIZE ... 拒绝创建" 由后端打印。
//    20. **内存 soak**：跑到第 3000 帧，每 500 帧打印一次
//        memory.buffer.byteLength（`fw_memory_bytes`）+ fw_stats(200+i) 里的存活
//        计数（program / pipeline / sampler / target 缓存表、纹理 / 缓冲资源数），
//        断言：内存**没有**单调增长（首尾 Δ<=0）且各存活计数首尾完全相等。
//
// 构建：python tools/wasm/build.py        验证：node foster/tests/wasm/verify.mjs
// 浏览器：直接打开 tests\wasm\index.html（内嵌 base64，file:// 可用）
//        或 python -m http.server 8000 -d tests\wasm
//        headless：chrome --headless=new --disable-gpu-compositing --virtual-time-budget=12000
//                  --dump-dom "http://localhost:8000/index.html?driver=timeout"
//        注意 headless 的 canvas 是 322×182（CSS 320×180 + 1px 边框），所有采样点
//        都按画布百分比算，所以分辨率变了断言不用改。
//        跑满 W6 的内存 soak 需要 3000 帧 ≈ 3000×16ms 的虚拟时间：
//                  --virtual-time-budget=60000
//        推荐 python foster/tests/wasm/verify_webgl.py：同时检查固定步长与原页面定时器路径。
//        仅无头虚拟时间关闭 GPU compositor，避免 Chromium 的 blit binding 错误；
//        WebGL 本身仍使用选择的 GPU/SwiftShader，正常浏览器无需这个开关。

#import "Basic";
#import "foster";

// ---------------------------------------------------------------- 示例配置
STOP_AFTER_SECONDS :: 15.0;
LOG_EVERY_N_FRAMES :: 60; // 1 秒一条心跳（60 fps 定步长）
REPORT_EVERY_N_FRAMES :: 300; // 5 秒一条完整状态报告
PIXEL_CHECK_FRAME :: 30; // 第 30 帧做一次像素读回断言（给 rAF 一点时间稳定）

// W4 热替换的三个时间点。都排在 PIXEL_CHECK_FRAME 之后，于是「换之前」的像素
// 已经由 12/13 那一次断言抓在手里了。
HOTRELOAD_GOOD_FRAME :: 60; // 换成一个有效的候选（应该成功）
HOTRELOAD_BAD_COMPILE_FRAME :: 90; // 换成语法错的候选（编译失败，应该被拒）
HOTRELOAD_BAD_LINK_FRAME :: 120; // 换成 varying 不匹配的候选（链接失败，应该被拒）
HOTRELOAD_SUMMARY_FRAME :: 150; // 打印热替换的完整结论

// W5/W6 的检查帧。都排在 PIXEL_CHECK_FRAME 之后（屏幕已经稳定画了几帧），
// 又排在热替换之前（热替换会换掉自己那块 quad 的像素，别互相干扰）。
W5_CHECK_FRAME :: 40; // 离屏 target 的屏幕读回 + blit + 超限拒绝
W5_MSAA_FRAME :: 45; // MSAA 1× / 4× 的部分覆盖对比
W6_WINDOW_MSAA_FRAME :: 50; // 窗口级 MSAA 的能力/降级断言 + 一帧画面读回

// W3 的 quad：纹理 8×8，左 4 列红、右 4 列蓝（NEAREST，所以边界是硬的）。
QUAD_TEXTURE_SIZE :: 8;
QUAD_TEXTURE_SPLIT :: 4;

// W4 Batcher 用的纹理：4×4，全部 texel 都是 (200,100,50,128)。
//   * wash 模式只吃 alpha（128/255），于是结果是一层半透明灰盖在清屏色上；
//   * fill 模式完全忽略它（断言颜色 = 纯顶点色）；
//   * 故意和 W3 的 8×8 不同尺寸，读回/记录时不会混淆。
BATCH_TEXTURE_SIZE :: 4;
BATCH_TEX_COLOR :: Color.{ 200, 100, 50, 128 };

// 清屏色。故意不是黑也不是白：读回断言里它必须能被区分出来。
CLEAR_COLOR :: Color.{ 16, 32, 48, 255 };

// 期望的读回值。写成常量，报告里和实际读回值并排打印。
EXPECT_LEFT :: Color.{ 255, 0, 0, 255 };
EXPECT_RIGHT :: Color.{ 0, 0, 255, 255 };
EXPECT_OUTSIDE :: CLEAR_COLOR;

// --- W4：Batcher 四模式的期望值 ---
// 四块都画在 y = 22%..36% 的横条上，各自居中采样。
EXPECT_SOLID :: Color.{ 255, 0, 0, 255 }; // fill 模式 + 单色红
GRAD_LEFT :: Color.{ 255, 0, 0, 255 }; // 渐变左端
GRAD_RIGHT :: Color.{ 0, 0, 255, 255 }; // 渐变右端
EXPECT_FILL :: Color.{ 0, 255, 0, 255 }; // fill 模式 + 顶点色绿（纹理被忽略）
// wash：oColor = texture.a * vColor = (128/255, 128/255, 128/255, 128/255)，
// 再按 Blend_Mode_Premultiply（src ONE / dst ONE_MINUS_SRC_ALPHA）盖在清屏色上：
//   128/255 + (16/255)*(127/255)  → 135.97 → 136
//   128/255 + (32/255)*(127/255)  → 143.94 → 144
//   128/255 + (48/255)*(127/255)  → 151.91 → 152
//   alpha  = 128/255 + 1*(127/255) = 1            → 255
// 浮点→UNORM8 的舍入由驱动决定，所以这一条用 ±2 的容差断言（其余用精确相等）。
EXPECT_WASH :: Color.{ 136, 144, 152, 255 };
WASH_TOLERANCE :: 2;

// --- W4：热替换用的那一小块 quad ---
// 用 W3 那张 8×8 红/蓝纹理（PosTexCol 顶点格式），画在右侧 78%..96% / 40%..56%。
// 采样点落在左半 → 期望红；换过候选之后 → 期望黄。
EXPECT_HR_V1 :: Color.{ 255, 0, 0, 255 };
EXPECT_HR_V2 :: Color.{ 255, 255, 0, 255 }; // 候选 v2 输出 vec4(1,1,0,1)

// 热替换的两个候选片元 shader（都是完整的 GLSL ES 3.00 文本）。
//
// 为什么候选必须自带两份：ShaderPairTryReplace 和桌面一样，会为**两个阶段**各建
// 一个候选 shader（vertex_info + fragment_info）。顶点那一侧我们原样再给一遍，
// 片元那一侧换成想试的东西 —— 和真正热重载一个 .glsl 文件的做法一致。
HR_VERTEX_GLSL :: "#version 300 es\nprecision highp float;\nlayout(std140) uniform JfosterVertexUniforms { mat4 Matrix; } vs_uniforms;\nlayout(location = 0) in vec2 aPosition;\nlayout(location = 1) in vec2 aTexCoord;\nlayout(location = 2) in vec4 aColor;\nout vec2 vTexCoord;\nout vec4 vColor;\nvoid main() { vTexCoord = aTexCoord; vColor = aColor; gl_Position = vs_uniforms.Matrix * vec4(aPosition, 0.0, 1.0); }\n";

HR_FRAGMENT_V1_GLSL :: "#version 300 es\nprecision highp float;\nuniform sampler2D Texture;\nin vec2 vTexCoord;\nin vec4 vColor;\nlayout(location = 0) out vec4 oColor;\nvoid main() { oColor = texture(Texture, vTexCoord) * vColor; }\n";

// 有效、但完全不采样纹理：整个 quad 变成纯黄。
HR_FRAGMENT_V2_GLSL :: "#version 300 es\nprecision highp float;\nuniform sampler2D Texture;\nin vec2 vTexCoord;\nin vec4 vColor;\nlayout(location = 0) out vec4 oColor;\nvoid main() { oColor = vec4(1.0, 1.0, 0.0, 1.0); }\n";

// 语法错：少了分号。compileShader 就会失败，根本走不到 linkProgram。
HR_FRAGMENT_SYNTAX_GLSL :: "#version 300 es\nprecision highp float;\nuniform sampler2D Texture;\nin vec2 vTexCoord;\nin vec4 vColor;\nlayout(location = 0) out vec4 oColor;\nvoid main() { oColor = vec4(1.0, 0.0, 1.0, 1.0) }\n";

// 能编译、但和顶点阶段对不上：vColor 在顶点是 vec4，在片元是 vec3。
// 链接器必须拒绝它 —— 这条用来证明「probe 阶段也会拒绝」，不只是编译期。
HR_FRAGMENT_LINK_GLSL :: "#version 300 es\nprecision highp float;\nin vec2 vTexCoord;\nin vec3 vColor;\nlayout(location = 0) out vec4 oColor;\nvoid main() { oColor = vec4(vColor, 1.0); }\n";

// ------------------------------------------------------------- W5：离屏 Target
//
// 一张 256×256 的离屏 Target 同时被三个子任务用：四色象限（渲染到纹理）、
// MSAA 1×/4× 的对比、blit_texture 的源。尺寸取 256 是因为它正好是 2 的幂、
// 远小于任何设备的 MAX_TEXTURE_SIZE / MAX_RENDERBUFFER_SIZE，而且「四象限」
// 和「45° 斜边穿像素角点」在 256 上都好算。
W5_TARGET_SIZE :: 256;
// 象限之外的清屏色：故意三个通道都和四个象限色不同，任何一处「画漏了」都读得出来。
W5_TARGET_CLEAR :: Color.{ 90, 30, 120, 255 };

W5_Q_TL :: Color.{ 255, 0, 0, 255 }; // 左上 红
W5_Q_TR :: Color.{ 0, 255, 0, 255 }; // 右上 绿
W5_Q_BL :: Color.{ 0, 0, 255, 255 }; // 左下 蓝
W5_Q_BR :: Color.{ 255, 255, 0, 255 }; // 右下 黄

// 「把 target 当纹理画到窗口」的那块屏幕区域：左侧 2%..22%、纵向 62%..92%。
// 刻意避开 W3 的 quad（25%..75% / 62%..96%）、Batcher 横条（22%..36%）、
// 字体扫描带（38.5%..60.5%）和热替换那块（78%..96% / 40%..56%），
// 于是它不会污染任何一个既有断言的采样点。
W5_SCREEN_X :: 0.02;
W5_SCREEN_Y :: 0.62;
W5_SCREEN_W :: 0.20;
W5_SCREEN_H :: 0.30;

// MSAA 对比用：画进两张 Target 的同一个三角形（像素空间中）
//   v0=(0,0)  v1=(256,0)  v2=(0,256)   ← 斜边就是 x+y=256，穿过每个像素的角点
// 于是 1× 采样「没有部分覆盖像素」，4× 采样「每行恰好一个」。
MSAA_TRI_GREEN :: Color.{ 0, 255, 0, 255 }; // 三角形色（清屏色仍用 CLEAR_COLOR）
MSAA_EDGE_ROW :: 128; // 读回的那一行（左上原点）

// 读回缓冲的哨兵值：(1,2,3,4) 不可能是任何断言期望的颜色，也不可能是清屏色 /
// 三角形色 / 象限色。读回真的发生却没写这块内存时，值就还是它 —— 于是
// 「读失败」不会被算成「读到一片黑」，也不会被算成 PASS。
TEXTURE_PIXEL_SENTINEL :: Color.{ 1, 2, 3, 4 };
// 4× 的部分覆盖像素期望值：2/4 覆盖 → (0+0+16+16)/4, (255+255+32+32)/4, (0+0+48+48)/4
EXPECT_MSAA_PARTIAL :: Color.{ 8, 143, 24, 255 };
MSAA_PARTIAL_TOLERANCE :: 3; // 驱动在 resolve 时的舍入，实测是精确值

// ------------------------------------------------------- W6：soak / 超限拒绕
//
// 内存 soak 的时间表：第 500 帧开始，每 500 帧采一次，到第 3000 帧出结论。
// 500 帧之后才采，是因为前 500 帧里后端的缓存表（program/pipeline/sampler/
// target FBO/纹理 FBO）还在按需懒建 —— 那时候涨是应该的，不是泄漏。
W6_SOAK_FIRST_FRAME :: 500;
W6_SOAK_EVERY :: 500;
W6_SOAK_LAST_FRAME :: 3000;
W6_SOAK_MAX_SAMPLES :: 8;
// 首尾内存允许的增长（字节）。wasm 的页只增不减，所以「完全不涨」是可以要求的；
// 留 0 是有意的：一旦某次改动让它每帧多留一块，这个断言就是第一个报警的。
W6_SOAK_MEM_TOLERANCE :: 0;

// ---------------------------------------------------------------- 顶点格式
//
// 与默认 Textured program 的 PosTexCol 顶点流一一对应（20 字节）：
//   loc 0 vec2 位置   loc 1 vec2 纹理坐标   loc 2 vec4 颜色（ubyte4 归一化）
// 字段顺序就是内存顺序，mesh_set_vertices 直接把这块字节上传上去。
Vertex :: struct {
    pos: Vector2;
    tex: Vector2;
    col: Color;
}

// ---------------------------------------------------------------- 示例状态
//
// 全放全局量：wasm 的线性内存不会因为 main 返回就失效，但把状态挂在 main 的
// 栈帧上是 W0 就踩过的坑（olib 的 web_relocate_app 就是为这个存在的）。
sample: Sample_State;

Hotreload_State :: struct {
    vs, fs: *Shader; // 就地热替换的那一对（地址不变）
    mat: *Material;
    mesh: *Mesh;
    vertex_glsl: string;
    fragment_glsl: string; // 当前生效的那份（提交后更新）

    ok_good: bool; // 第 60 帧：换成 v2 应该成功
    ok_syntax: bool; // 第 90 帧：语法错应该失败
    ok_link: bool; // 第 120 帧：varying 不匹配应该失败
    err_syntax: string;
    err_link: string;

    before: Color; // 换之前的像素
    after_good: Color; // 换成功之后的像素
    after_syntax: Color; // 语法错被拒之后的像素（必须 == after_good）
    after_link: Color; // 链接错被拒之后的像素（必须 == after_good）
    have_before: bool;
    have_after_good: bool;
    have_after_syntax: bool;
    have_after_link: bool;
};

Sample_State :: struct {
    updates: s32; // App.update 被调了多少次
    heartbeats: s32;
    last_dt: float64;
    elapsed: float64;
    store: *Storage_Container;
    storage_ok: bool;
    clipboard_ok: bool;
    last_key: string;
    pressed_total: s32;
    seen_focus: bool;

    // ---- W3: WebGL2 图形 ----
    material: *Material; // 默认 Textured program（名字 = "Textured"）
    mesh: *Mesh;
    texture: *Texture;
    graphics_ok: bool; // 材质/网格/纹理都建起来了
    pixel_checked: bool; // 读回断言只做一次
    pixel_result: s32; // 1 = 通过 0 = 失败 -1 = 跳过（宿主没有 WebGL2）
    frames_drawn: s32;

    // ---- W4: Batcher 四模式 ----
    batcher: *Batcher;
    batch_tex: *Texture;
    batch_ok: bool;
    batch_result: s32; // 1 PASS / 0 FAIL / -1 SKIP
    solid_px: Color;
    grad_l_px: Color;
    grad_r_px: Color;
    wash_px: Color;
    fill_px: Color;

    // ---- W4: 字体 / MSDF ----
    // Msdf_Font 是 jfoster 模块私有的类型（images/msdf_font.jai 用的是 #scope_module），
    // 所以这里不存指针、只存从它身上取到的数（尺寸 / DistanceRange / 墨迹数）。
    // 图集指针本身只在 sample_font_startup 的栈上用一次。
    font: *Sprite_Font;
    font_ok: bool;
    font_result: s32; // 1 PASS / 0 FAIL / -1 SKIP
    font_pixels: s32; // 扫描带里非清屏像素的个数
    font_scanned: s32; // 扫描带总像素数
    font_distance_range: float;
    font_atlas_w: s32;
    font_atlas_h: s32;
    font_atlas_ink: s32; // CPU 侧图集里非零 texel 的个数（QOI 解码是否真的解出东西）
    scan: [..] Color; // web_read_pixels 的落点

    // ---- W4: 着色器热替换 ----
    hr: Hotreload_State;
    hr_result: s32; // 1 PASS / 0 FAIL / -1 SKIP
    hr_reported: bool;

    // ---- W5: 离屏 Target / MSAA / blit ----
    // 全部在 startup 建好：soak 阶段再分配的话，「存活计数不变」这条断言会自动
    // 失效（分不清「泄漏」和「这个功能第一次跑」）。
    w5_batcher: *Batcher; // 离屏绘制专用的第二个 Batcher（不打断窗口那个）
    w5_target: *Target; // 256×256、单采样：四色象限的落点
    w5_screen_mat: *Material; // 把 target 的附件当纹理画到窗口（克隆 Textured）
    w5_screen_mesh: *Mesh; // PosTexCol，4 顶点 + 6 索引
    w5_blit_dst: *Texture; // blit_texture 的落点
    ms1_target: *Target; // 256×256、Sample_Count.ONE
    ms4_target: *Target; // 256×256、Sample_Count.FOUR
    w5_ok: bool; // 上面这些都建起来了
    w5_checked: bool;
    w5_result: s32; // 1 PASS / 0 FAIL / -1 SKIP
    w5_px: [4] Color; // 屏幕上读回的四个象限（TL TR BL BR）
    blit_px: [4] Color; // blit 之后从落点纹理读回的四个象限
    blit_result: s32;
    edge_row: [..] Color; // 读回一行像素的落点（复用，避免每帧分配）
    msaa_result: s32;
    msaa_partial_1x: s32;
    msaa_partial_4x: s32;
    msaa_edge_1x: Color;
    msaa_edge_4x: Color;
    msaa_edge_x_1x: s32;
    msaa_edge_x_4x: s32;
    msaa_reported: bool;
    limit_result: s32;
    limit_max: s32; // MAX_TEXTURE_SIZE（fw_stats(200+22)）
    limit_handle: s32; // 超限纹理拿到的句柄（必须是 0）

    // ---- W6: 窗口级 MSAA ----
    w6_window_result: s32;
    w6_window_reported: bool;
    w6_bb_samples: s32; // backbuffer_format.SampleCount 的真实值
    w6_ms_samples: s32; // fw_stats(200+10)：窗口 MS FBO 的 samples
    w6_resolves: s32; // fw_stats(200+9)：present 时的 resolve 次数

    // ---- W6: 内存 soak ----
    soak_result: s32;
    soak_samples: s32;
    soak_frames: [W6_SOAK_MAX_SAMPLES] s32;
    soak_mem: [W6_SOAK_MAX_SAMPLES] s32;
    soak_programs: [W6_SOAK_MAX_SAMPLES] s32;
    soak_pipelines: [W6_SOAK_MAX_SAMPLES] s32;
    soak_samplers: [W6_SOAK_MAX_SAMPLES] s32;
    soak_targets: [W6_SOAK_MAX_SAMPLES] s32;
    soak_tex_fbos: [W6_SOAK_MAX_SAMPLES] s32;
    soak_textures: [W6_SOAK_MAX_SAMPLES] s32;
    soak_buffers: [W6_SOAK_MAX_SAMPLES] s32;
    soak_target_res: [W6_SOAK_MAX_SAMPLES] s32;
}

// 跨平台读数包装：桌面构建没有 web_stats，所以 #if 隔离（桌面版永远返回 -1）。
sample_stats :: (which: s32) -> s32 {
    #if OS == .WASM {
        return web_stats(which);
    }
    return -1;
}

// W3 的 GL 侧计数：fw_stats(100 + i) 直接转发到 gl_stats(i)。
//   100 draw   101 pass   102 clear   103 纹理上传   104 缓冲上传   105 shader
//   106 program 107 pipeline 108 readback 109 读到像素数 110 GL error 111 有设备
sample_gl_stats :: (which: s32) -> s32 {
    #if OS == .WASM {
        return web_stats(100 + which);
    }
    return -1;
}

// [W6] 后端自己的计数：fw_stats(200 + i) 转发到 web_gpu_stat(i)。
//   0 program 缓存  1 pipeline 缓存  2 sampler 缓存  3 target 缓存（表条目）
//   4 纹理 FBO 缓存  5 target 建成功  6 target resolve  7 target 不完整
//   8 blit 成功     9 窗口 resolve  10 窗口 MS 的 samples  11 MSAA target 数
//   12 纹理尺寸拒绝 13 TEXTURE 资源数 14 BUFFER 资源数 15 读回拒绝
//  16 读回格式不支持 17 target 失效 18 target 保留 19 窗口 MS 重建
//  20 renderbuffer 尺寸拒绝 21 TARGET 资源数 22 MAX_TEXTURE_SIZE
//  23 MAX_SAMPLES  24 blit 失败  25 draw 跳过
sample_gpu_stat :: (which: s32) -> s32 {
    #if OS == .WASM {
        return web_stats(200 + which);
    }
    return -1;
}

// [W6] 线性内存当前字节数（只有 JS 侧知道，见 internal/web/web_bridge.jai）。
sample_memory_bytes :: () -> s32 {
    #if OS == .WASM {
        return web_linear_memory_bytes();
    }
    return -1;
}

// Sample_Count → 数字。枚举没有内建取值，手写一张表比 cast 可靠
// （cast 依赖声明顺序，读起来还得回头数）。
sample_sample_count_value :: (s: Sample_Count) -> s32 {
    if s == {
        case .ONE; return 1;
        case .TWO; return 2;
        case .FOUR; return 4;
        case .EIGHT; return 8;
    }
    return 1;
}

// 像素坐标 → NDC 的正交矩阵，原点左上（和 W3/W4 的矩阵完全一致）。
// 单独抽出来是因为 W5 有 4 个不同的绘制目标（窗口 / 256 的 target ×3），
// 每个都要按各自尺寸算一遍。
sample_ortho :: (width: s32, height: s32) -> Matrix4 {
    zfar := 1000000.0;
    m: Matrix4;
    m._11 = 2.0 / cast(float) width;
    m._22 = -2.0 / cast(float) height;
    m._33 = 1.0 / zfar;
    m._41 = -1;
    m._42 = 1;
    m._43 = -1;
    m._44 = 1;
    return m;
}

// 从 Jai 侧读回 canvas 默认 framebuffer 的一个像素（RGBA8，左上原点）。
// 一次读 1×1 —— 这是验收探针，不是渲染路径。
sample_read_pixel :: (x: s32, y: s32) -> (color: Color, ok: bool) {
    #if OS == .WASM {
        c: Color;
        if web_read_pixel(x, y, *c) return c, true;
    }
    return Color.{ 0, 0, 0, 0 }, false;
}

// 一次读一整条带（RGBA8）。用在「数非清屏像素」这种需要遍历的断言上 ——
// 逐像素调 gl.readPixels 会是几千次 GPU 同步，慢到没意义。
sample_read_strip :: (x: s32, y: s32, w: s32, h: s32) -> (pixels: [] Color, ok: bool) {
    #if OS == .WASM {
        if w <= 0 || h <= 0 return .[], false;
        count := w * h;
        array_resize(*sample.scan, count);
        if web_read_pixels(x, y, w, h, sample.scan.data, count * 4) {
            return array_view(sample.scan, 0, count), true;
        }
    }
    return .[], false;
}

// 颜色近似比较（wash 的 alpha 混合结果会受驱动舍入影响）。
sample_color_near :: (a: Color, b: Color, tolerance: s32) -> bool {
    return abs(cast(s32) a.r - cast(s32) b.r) <= tolerance &&
           abs(cast(s32) a.g - cast(s32) b.g) <= tolerance &&
           abs(cast(s32) a.b - cast(s32) b.b) <= tolerance &&
           abs(cast(s32) a.a - cast(s32) b.a) <= tolerance;
}

sample_color_text :: (c: Color) -> string {
    return tprint("(% ,% ,% ,%)", c.r, c.g, c.b, c.a);
}

// 归一化坐标 → 设备像素 Rect。整个示例的画布布局都用「占画布的百分比」表达，
// 于是 320×180（headless，DPR 1）和 640×360（node 宿主，DPR 2）算出同一套相对
// 位置，断言点不用为分辨率写两遍。
sample_rect :: (width: s32, height: s32, fx: float, fy: float, fw: float, fh: float) -> Rect {
    w := cast(float) width;
    h := cast(float) height;
    return Rect.{ fx * w, fy * h, fw * w, fh * h };
}

// ---------------------------------------------------------------- 生命周期
main :: () {
    App.startup = sample_startup;
    App.update = sample_update;
    App.render = sample_render;

    app_run(.{
        application_name = "jfoster wasm sample",
        window_title = "jfoster wasm / W2（点击画布后按键，ESC 退出）",
        width = 960,
        height = 540,
        resizable = true,
        // [W6] 窗口级 MSAA：web 后端把它落地成「窗口大小的 MS FBO + present 时
        // resolve 到 0 号 FBO」。设备不支持时后端会明确降级并打一条日志，
        // 于是 backbuffer_format.SampleCount 报的永远是**真实**生效的样本数。
        flags = .MULTI_SAMPLED_BACK_BUFFER,
    });

    // web 目标下 app_run 只是 setup，帧循环归宿主，所以这里 **不能** app_destroy：
    // 拆掉的东西下一帧还要用。收尾在 app_web_stop（fw_step 返回 0 时）。
    #if OS != .WASM {
        app_destroy();
    }
}

sample_startup :: () {
    log_info("sample: startup —— 窗口尺寸/像素比来自 canvas");

    size := window_size(App.window);
    pixels := window_size_in_pixels(App.window);
    scale := window_content_scale(App.window);
    log_info(tprint("sample: window css=%x% device=%x% scale=%",
                    size.x, size.y, pixels.x, pixels.y, scale.x));

    // [L-022] 文本输入锚点：让 IME 候选窗贴着画布左上角
    window_start_text_input(App.window);
    window_set_text_input_area(App.window, Rect.{ 8, 8, 16, 16 });

    // 存档根是虚拟的（"/save/"），但 Storage_Container 的用法和桌面一字不差。
    sample.store = directory_storage_create(app_user_path());
    log_info(tprint("sample: 存档根 = '%'（web: localStorage/OPFS 虚拟键空间）", sample.store.Root));

    sample_graphics_startup();
}

// ------------------------------------------------------------- W3：图形
//
// 只用**公开 API**：defaults_textured_material / texture_create_from_colors /
// mesh_create / material_stage_set_uniform_value / graphics_device_clear_color /
// draw_command_from_mesh / graphics_device_draw。一个 sdl_* / gl_* 都没直接调，
// 也就是说这段代码在桌面上同样能编译、同样能画 —— 这正是 W3 想要的证据：
// 后端换了，应用层一行都不用改。
sample_graphics_startup :: () {
    device := App.device;
    if device == null {
        log_warning("sample: 没有 Graphics_Device，跳过后端初始化");
        return;
    }

    // 默认 Textured program。web 后端靠 shader.Name（"Textured"）挑 GLSL ES
    // 3.00 源，所以必须走 defaults_*（它会把名字传下去），不能自己 shader_create。
    sample.material = defaults_textured_material(device);
    if sample.material == null {
        log_error("sample: 取默认 Textured 材质失败");
        return;
    }

    // 8×8 纹理：左 4 列红、右 4 列蓝。NEAREST + 明确的纹理坐标，读回时颜色是硬的。
    pixels: [QUAD_TEXTURE_SIZE * QUAD_TEXTURE_SIZE] Color;
    for y: 0..QUAD_TEXTURE_SIZE - 1 {
        for x: 0..QUAD_TEXTURE_SIZE - 1 {
            pixels[y * QUAD_TEXTURE_SIZE + x] =
                ifx x < QUAD_TEXTURE_SPLIT then Color.{ 255, 0, 0, 255 } else Color.{ 0, 0, 255, 255 };
        }
    }
    sample.texture = texture_create_from_colors(device, QUAD_TEXTURE_SIZE, QUAD_TEXTURE_SIZE, pixels,
                                                name = "w3_quad");

    // PosTexCol：float2 位置、float2 纹理坐标、ubyte4 归一化颜色（20 字节）。
    // 和 internal/web/shaders/textured.vertex.glsl 里 layout(location=0/1/2) 逐一对应。
    elements: [3] Vertex_Format_Element = .[
        .{ Index = 0, Type = .FLOAT2, Normalized = false },
        .{ Index = 1, Type = .FLOAT2, Normalized = false },
        .{ Index = 2, Type = .UBYTE4, Normalized = true },
    ];
    sample.mesh = mesh_create(device, vertex_format_make(elements), .THIRTY_TWO, "w3_quad");

    sample.material.Fragment.Samplers[0] = .{
        Tex = sample.texture,
        Sampler = texture_sampler_make(.NEAREST, .CLAMP),
    };

    sample.graphics_ok = true;
    log_info("sample: W3 图形已初始化 —— Textured program + 8x8 纹理 + PosTexCol 网格（索引绘制）");

    sample_batcher_startup(device);
    sample_font_startup(device);
    sample_hotreload_startup(device);
    sample_w5_startup(device); // W5/W6 的资源（离屏 target / MSAA / blit）
}

// ------------------------------------------------------- W4：Batcher 四模式
sample_batcher_startup :: (device: *Graphics_Device) {
    // 4×4 单色纹理：wash 只吃它的 alpha（128），fill 完全忽略它。
    texels: [BATCH_TEXTURE_SIZE * BATCH_TEXTURE_SIZE] Color;
    for i: 0..BATCH_TEXTURE_SIZE * BATCH_TEXTURE_SIZE - 1 texels[i] = BATCH_TEX_COLOR;
    sample.batch_tex = texture_create_from_colors(device, BATCH_TEXTURE_SIZE, BATCH_TEXTURE_SIZE, texels,
                                                  name = "w4_batch_tex");

    sample.batcher = batcher_create(device, "w4_batcher");
    if sample.batcher == null {
        log_error("sample: Batcher 建不起来 —— 四模式验证会 SKIP");
        return;
    }
    sample.batch_ok = true;
    log_info("sample: W4 Batcher 已建（24 字节 4 属性顶点 + 4x4 纹理）—— solid/gradient/wash/fill 各画一块");
}

// 四模式各画一次。顺序是刻意的：
//   solid → gradient 走 fill 模式（batcher_rect* 内部固定发 Batcher_Mode_Fill）；
//   wash  → batcher_push_mode(.WASH) + 带纹理坐标的 quad；
//   fill  → batcher_push_mode(.FILL) + **同样带纹理坐标、同一张纹理**，
//           于是「颜色仍然是纯顶点色」就证明了 fill 真的不采样纹理。
// 四块的状态（材质 / 纹理 / 采样器 / 混合）完全相同，所以它们会合并成**一个**
// batch —— 这正是 Batcher 该有的行为，顺便也被验证了。
sample_batcher_render :: (b: *Batcher, target: Drawable_Target, width: s32, height: s32) {
    if b == null || !sample.batch_ok return;

    batcher_clear(b);
    batcher_set_texture(b, sample.batch_tex);
    batcher_set_sampler(b, texture_sampler_make(.NEAREST, .CLAMP));

    // (1) solid —— 单色块（fill 模式，没有纹理坐标 → 采样点固定，乘 0 忽略）
    batcher_rect(b, sample_rect(width, height, 0.02, 0.22, 0.20, 0.14), EXPECT_SOLID);

    // (2) gradient —— 水平渐变：左端红、右端蓝，插值发生在 vColor 上。
    //     四角色的顺序是 quad 的 v0..v3 = (左上, 右上, 右下, 左下) —— 所以是
    //     「左红 / 右蓝 / 右蓝 / 左红」。写成 (红,红,蓝,蓝) 会得到一条**竖直**
    //     渐变（第一次跑就是这么写错的：两个采样点都读到中间色 (130,0,125)）。
    batcher_rect_gradient(b, sample_rect(width, height, 0.26, 0.22, 0.20, 0.14),
                          GRAD_LEFT, GRAD_RIGHT, GRAD_RIGHT, GRAD_LEFT);

    // (3) wash —— 只用纹理 alpha：oColor = texture.a * vColor
    {
        r := sample_rect(width, height, 0.50, 0.22, 0.20, 0.14);
        batcher_push_mode(b, .WASH);
        batcher_quad_textured(b, sample.batch_tex,
            .{ r.x, r.y }, .{ r.x + r.w, r.y },
            .{ r.x + r.w, r.y + r.h }, .{ r.x, r.y + r.h },
            .{ 0.0, 0.0 }, .{ 1.0, 0.0 }, .{ 1.0, 1.0 }, .{ 0.0, 1.0 },
            Color_White);
        batcher_pop_mode(b);
    }

    // (4) fill —— 同一张纹理、同样的纹理坐标，但颜色必须完全由顶点色决定
    {
        r := sample_rect(width, height, 0.74, 0.22, 0.20, 0.14);
        batcher_push_mode(b, .FILL);
        batcher_quad_textured(b, sample.batch_tex,
            .{ r.x, r.y }, .{ r.x + r.w, r.y },
            .{ r.x + r.w, r.y + r.h }, .{ r.x, r.y + r.h },
            .{ 0.0, 0.0 }, .{ 1.0, 0.0 }, .{ 1.0, 1.0 }, .{ 0.0, 1.0 },
            EXPECT_FILL);
        batcher_pop_mode(b);
    }
}

// ------------------------------------------------------- W4：字体 / MSDF
sample_font_startup :: (device: *Graphics_Device) {
    // 内嵌图集：desktop 是 content/fonts/Compiled/Roboto.png，wasm 是
    // internal/web/assets/Roboto.qoi（同一个 PNG 的同一批像素，QOI 只是容器）。
    // 这一句同时把 JSON 指标和图集都解出来（images/msdf_font.jai）。
    msdf := defaults_msdf_font(device);
    if msdf == null {
        log_error("sample: 内嵌 Roboto MSDF 图集解不出来 —— 字体验证会 SKIP");
        return;
    }
    sample.font_atlas_w = msdf.Atlas.Width;
    sample.font_atlas_h = msdf.Atlas.Height;
    sample.font_distance_range = msdf.DistanceRange;

    // CPU 侧再确认一次「图集不是一片空白」：数非全零 texel。MSDF 图集的背景是
    // (0,0,0,255)（距离场里代表「远离字形」），字形周围的 texel 至少有一个通道
    // 非零。这一步不经过 GPU，是 QOI 解码本身的证据。
    ink: s32 = 0;
    for c: msdf.Atlas.Data {
        if c.r != 0 || c.g != 0 || c.b != 0 ink += 1;
    }
    sample.font_atlas_ink = ink;

    // Sprite_Font 的图集路径：把 msdf 的每个字形按 atlasBounds 变成 Subtexture，
    // 图集本身作为一张纹理上传 —— 之后 batcher_subtexture_at 画的就是它。
    sample.font = sprite_font_create_from_msdf(device, msdf);
    if sample.font == null {
        log_error("sample: Sprite_Font 建不起来 —— 字体验证会 SKIP");
        return;
    }
    sample.font_ok = true;

    // DistanceRange 走的是片段 UBO（binding 8 = 8 + fragment slot 0）。
    // 这里把 Jai 侧看到的字节打印出来，和 host.js 日志里
    // "fragment slot 0 -> binding 8 (JfosterFragmentUniforms, 16B)" 对上。
    bytes := material_stage_get_uniform(*sample.font.Mat.Fragment, 0);
    log_info(tprint("sample: W4 字体 —— 图集 %x% / 非空 texel % / DistanceRange=%（片段 UBO 槽 0 = % 字节）",
                    sample.font_atlas_w, sample.font_atlas_h, sample.font_atlas_ink,
                    sample.font_distance_range, cast(s32) bytes.count));
}

// 用 Sprite_Font 画一行字。走的是 Batcher（sprite_font_draw 内部 push/pop
// matrix/material/sampler + batcher_subtexture_at），所以它和四模式那四块共享
// 同一个 Batcher —— 材质不同自然会 split 出一个新 batch。
sample_font_render :: (b: *Batcher, width: s32, height: s32) {
    if b == null || !sample.font_ok return;

    at := Vector2.{ 0.03 * cast(float) width, 0.40 * cast(float) height };
    sprite_font_draw(sample.font, b, "jfoster W4", at, Color_White);
}

// ------------------------------------------------------ W4：着色器热替换
sample_hotreload_startup :: (device: *Graphics_Device) {
    hr := *sample.hr;

    // v1 的两个阶段：顶点用 PosTexCol + std140 mat4（和 Textured 同一套约定），
    // 片元就是 texture * color —— 和默认 Textured program 等价。
    //
    // 注意这里**故意自己 shader_create**（不走 defaults_*）：热替换的对象必须是
    // 我们自己拥有的一对 shader，这样换掉它不会影响默认材质。
    hr.vertex_glsl = HR_VERTEX_GLSL;
    hr.fragment_glsl = HR_FRAGMENT_V1_GLSL;

    hr.vs = shader_create(device, .VERTEX, cast([] u8) hr.vertex_glsl,
                          uniform_buffer_count = 1,
                          entry_point = "main", name = "HotReload");
    hr.fs = shader_create(device, .FRAGMENT, cast([] u8) hr.fragment_glsl,
                          sampler_count = 1,
                          entry_point = "main", name = "HotReload");
    if hr.vs == null || hr.fs == null {
        log_error("sample: 热替换的那一对 shader 建不起来 —— 验证会 SKIP");
        return;
    }

    hr.mat = material_create(hr.vs, hr.fs);
    hr.mat.Fragment.Samplers[0] = .{
        Tex = sample.texture,
        Sampler = texture_sampler_make(.NEAREST, .CLAMP),
    };

    // 复用 W3 的 PosTexCol 顶点格式（20 字节、3 属性），画一小块。
    elements: [3] Vertex_Format_Element = .[
        .{ Index = 0, Type = .FLOAT2, Normalized = false },
        .{ Index = 1, Type = .FLOAT2, Normalized = false },
        .{ Index = 2, Type = .UBYTE4, Normalized = true },
    ];
    hr.mesh = mesh_create(device, vertex_format_make(elements), .THIRTY_TWO, "w4_hotreload");

    log_info("sample: W4 热替换目标已就位 —— 'HotReload' pair（v1 = texture*color）");
}

// 画那一小块（每帧都画，候选换掉之后同一块会变颜色）。
sample_hotreload_render :: (device: *Graphics_Device, target: Drawable_Target, width: s32, height: s32) {
    hr := *sample.hr;
    if hr.mat == null || hr.mesh == null return;

    r := sample_rect(width, height, 0.78, 0.40, 0.18, 0.16);

    // 正交矩阵：像素坐标 → NDC，原点左上（和 W3 的 quad 完全一致）。
    zfar := 1000000.0;
    m: Matrix4;
    m._11 = 2.0 / cast(float) width;
    m._22 = -2.0 / cast(float) height;
    m._33 = 1.0 / zfar;
    m._41 = -1;
    m._42 = 1;
    m._43 = -1;
    m._44 = 1;
    material_stage_set_uniform_value(*hr.mat.Vertex, 0, m);

    white := Color_White;
    vertices: [4] Vertex = .[
        .{ pos = .{ r.x, r.y }, tex = .{ 0.0, 0.0 }, col = white },
        .{ pos = .{ r.x + r.w, r.y }, tex = .{ 1.0, 0.0 }, col = white },
        .{ pos = .{ r.x + r.w, r.y + r.h }, tex = .{ 1.0, 1.0 }, col = white },
        .{ pos = .{ r.x, r.y + r.h }, tex = .{ 0.0, 1.0 }, col = white },
    ];
    indices: [6] s32 = .[0, 1, 2, 0, 2, 3];
    mesh_set_vertices(hr.mesh, vertices);
    mesh_set_indices(hr.mesh, indices);

    cmd := draw_command_from_mesh(target, hr.mesh, hr.mat);
    graphics_device_draw(device, cmd);
}

// 热替换的 probe 命令：就是上面那一块的 Draw_Command。ShaderPairTryReplace 会
// 忽略它的两个 shader 字段，只拿它的 target / 顶点布局 / 渲染状态去试建 pipeline。
sample_hotreload_probe :: (target: Drawable_Target) -> Draw_Command {
    return draw_command_from_mesh(target, sample.hr.mesh, sample.hr.mat);
}

// 真正调 ShaderPairTryReplace。`which` 选候选：
//   1 = v2（有效，应该成功）
//   2 = 语法错（编译失败）
//   3 = varying 类型不匹配（链接失败）
sample_hotreload_try :: (device: *Graphics_Device, target: Drawable_Target, which: s32) -> (ok: bool, error: string) {
    hr := *sample.hr;
    if hr.vs == null || hr.fs == null return false, "hot-replace harness not initialised";

    fragment_text := HR_FRAGMENT_V2_GLSL;
    tag := "v2(texture ignored)";
    if which == 2 {
        fragment_text = HR_FRAGMENT_SYNTAX_GLSL;
        tag = "syntax error";
    }
    if which == 3 {
        fragment_text = HR_FRAGMENT_LINK_GLSL;
        tag = "varying mismatch";
    }

    vertex_info := Shader_Create_Info.{
        Stage = .VERTEX,
        Bytes = cast([] u8) hr.vertex_glsl,
        SamplerCount = 0,
        UniformBufferCount = 1,
        EntryPoint = "main",
    };
    fragment_info := Shader_Create_Info.{
        Stage = .FRAGMENT,
        Bytes = cast([] u8) fragment_text,
        SamplerCount = 1,
        UniformBufferCount = 0,
        EntryPoint = "main",
    };

    probes: [1] Draw_Command;
    probes[0] = sample_hotreload_probe(target);

    log_info(tprint("sample: 热替换尝试 '%' —— 候选 = % / % 字节", tag,
                    cast(s32) vertex_info.Bytes.count, cast(s32) fragment_info.Bytes.count));

    ok, error := ShaderPairTryReplace(hr.vs, hr.fs, device, vertex_info, fragment_info,
                                      array_view(probes, 0, 1));
    if ok {
        hr.fragment_glsl = fragment_text;
        log_info(tprint("sample: 热替换 '%' 成功 —— 新片元 % 字节已就地生效（*Shader 地址不变）",
                        tag, cast(s32) fragment_text.count));
        return true, "";
    }
    log_info(tprint("sample: 热替换 '%' 被拒 —— %", tag, error));
    return false, error;
}

// ---------------------------------------------------------------- 每帧绘制
sample_render :: () {
    sample_graphics_render();

    if !sample.pixel_checked && sample.updates >= PIXEL_CHECK_FRAME {
        sample.pixel_checked = true;
        sample_graphics_verify();
        sample_batcher_verify();
        sample_font_verify();
    }

    // ---- W5/W6：三个检查帧（都在窗口 pass 还开着的时候读回） ----
    if !sample.w5_checked && sample.updates >= W5_CHECK_FRAME {
        sample.w5_checked = true;
        width := window_width_in_pixels(App.window);
        height := window_height_in_pixels(App.window);
        sample_w5_verify(App.device, width, height); // 屏幕读回 + blit + 超限
    }
    if !sample.msaa_reported && sample.updates >= W5_MSAA_FRAME {
        sample.msaa_reported = true;
        width := window_width_in_pixels(App.window);
        height := window_height_in_pixels(App.window);
        sample_msaa_verify(App.device, drawable_target_window(App.window), width, height);
    }
    if !sample.w6_window_reported && sample.updates >= W6_WINDOW_MSAA_FRAME {
        sample.w6_window_reported = true;
        width := window_width_in_pixels(App.window);
        height := window_height_in_pixels(App.window);
        sample_w6_window_verify(width, height);
    }

    sample_hotreload_poll();

    if !sample.hr_reported && sample.updates >= HOTRELOAD_SUMMARY_FRAME {
        sample.hr_reported = true;
        sample_hotreload_verify();
    }
}

// 每帧：clear + 四组内容。
sample_graphics_render :: () {
    device := App.device;
    if device == null || !sample.graphics_ok return;

    target := drawable_target_window(App.window);
    width := drawable_target_width_in_pixels(target);
    height := drawable_target_height_in_pixels(target);
    if width <= 0 || height <= 0 return;

    // (1) clear 到 CLEAR_COLOR
    graphics_device_clear_color(device, target, CLEAR_COLOR);

    // (2) W3 的带纹理 quad：占画布 25%..75% 宽、62%..96% 高
    {
        //     正交矩阵：像素坐标 → NDC，原点左上，和桌面样本完全一致
        //     (Matrix4x4.CreateOrthographicOffCenter(0, w, h, 0, 0, zfar))
        zfar := 1000000.0;
        m: Matrix4;
        m._11 = 2.0 / cast(float) width;
        m._22 = -2.0 / cast(float) height;
        m._33 = 1.0 / zfar;
        m._41 = -1;
        m._42 = 1;
        m._43 = -1;
        m._44 = 1;
        material_stage_set_uniform_value(*sample.material.Vertex, 0, m);

        r := sample_rect(width, height, 0.25, 0.62, 0.50, 0.34);
        white := Color.{ 255, 255, 255, 255 };

        vertices: [4] Vertex = .[
            .{ pos = .{ r.x, r.y }, tex = .{ 0.0, 0.0 }, col = white },
            .{ pos = .{ r.x + r.w, r.y }, tex = .{ 1.0, 0.0 }, col = white },
            .{ pos = .{ r.x + r.w, r.y + r.h }, tex = .{ 1.0, 1.0 }, col = white },
            .{ pos = .{ r.x, r.y + r.h }, tex = .{ 0.0, 1.0 }, col = white },
        ];
        indices: [6] s32 = .[0, 1, 2, 0, 2, 3];

        mesh_set_vertices(sample.mesh, vertices);
        mesh_set_indices(sample.mesh, indices);

        cmd := draw_command_from_mesh(target, sample.mesh, sample.material);
        graphics_device_draw(device, cmd);
    }

    // (3) W4：Batcher 四模式 + 一行文字（同一个 Batcher，一次 render）
    if sample.batcher != null && sample.batch_ok {
        sample_batcher_render(sample.batcher, target, width, height);
        sample_font_render(sample.batcher, width, height);
        batcher_render(sample.batcher, target);
    }

    // (4) W4：热替换的那一小块
    sample_hotreload_render(device, target, width, height);

    // (5) W5：离屏 target 画四色象限 → 当纹理画回窗口。
    //     放在最后是因为它会**切一次 render pass**（窗口 → target → 窗口），
    //     前面所有画到窗口的东西都还在同一个 pass 里。
    sample_w5_render(device, target, width, height);

    sample.frames_drawn += 1;
}

// 读回三块像素并断言。同一帧里 clear + draw 之后立刻读，所以读到的就是刚画的那帧
// （浏览器要到任务结束才合成，drawing buffer 这时还没被清）。
sample_graphics_verify :: () {
    if !sample.graphics_ok {
        sample.pixel_result = -1;
        log_info("W3 PIXEL: SKIP —— 图形没初始化（宿主没有 WebGL2？）");
        return;
    }

    width := window_width_in_pixels(App.window);
    height := window_height_in_pixels(App.window);
    if width <= 0 || height <= 0 {
        sample.pixel_result = -1;
        log_info("W3 PIXEL: SKIP —— 画布尺寸为 0");
        return;
    }

    // 三个探针点（左上原点，设备像素）：
    //   quad 内部左半：x = 37.5% 宽，y = 79% 高   → 期望红
    //   quad 内部右半：x = 62.5% 宽，y = 79% 高   → 期望蓝
    //   quad 之外    ：x = 5% 宽，y = 5% 高      → 期望清屏色（上面什么都没画）
    left_x := cast(s32) (cast(float) width * 0.375);
    right_x := cast(s32) (cast(float) width * 0.625);
    mid_y := cast(s32) (cast(float) height * 0.79);
    out_x := cast(s32) (cast(float) width * 0.05);
    out_y := cast(s32) (cast(float) height * 0.05);

    left, ok_left := sample_read_pixel(left_x, mid_y);
    right, ok_right := sample_read_pixel(right_x, mid_y);
    outside, ok_out := sample_read_pixel(out_x, out_y);

    if !ok_left || !ok_right || !ok_out {
        sample.pixel_result = -1;
        log_info(tprint("W3 PIXEL: SKIP —— 读回失败（这个宿主没有 WebGL2；draw 计数=%）", sample_gl_stats(0)));
        return;
    }

    ok := left == EXPECT_LEFT && right == EXPECT_RIGHT && outside == EXPECT_OUTSIDE;
    sample.pixel_result = 0;
    if ok sample.pixel_result = 1;

    log_info(tprint("W3 PIXEL left  @ (%,%) = (%,%,%,%) 期望 (%,%,%,%)", left_x, mid_y,
                    left.r, left.g, left.b, left.a,
                    EXPECT_LEFT.r, EXPECT_LEFT.g, EXPECT_LEFT.b, EXPECT_LEFT.a));
    log_info(tprint("W3 PIXEL right @ (%,%) = (%,%,%,%) 期望 (%,%,%,%)", right_x, mid_y,
                    right.r, right.g, right.b, right.a,
                    EXPECT_RIGHT.r, EXPECT_RIGHT.g, EXPECT_RIGHT.b, EXPECT_RIGHT.a));
    log_info(tprint("W3 PIXEL out   @ (%,%) = (%,%,%,%) 期望 (%,%,%,%)", out_x, out_y,
                    outside.r, outside.g, outside.b, outside.a,
                    EXPECT_OUTSIDE.r, EXPECT_OUTSIDE.g, EXPECT_OUTSIDE.b, EXPECT_OUTSIDE.a));
    log_info(tprint("W3 PIXEL: %  （draw=% pass=% clear=% tex_upload=% buf_upload=% shader=% program=% pipeline=% readback=% gl_error=%）",
                    ifx ok then "PASS" else "FAIL",
                    sample_gl_stats(0), sample_gl_stats(1), sample_gl_stats(2), sample_gl_stats(3),
                    sample_gl_stats(4), sample_gl_stats(5), sample_gl_stats(6), sample_gl_stats(7),
                    sample_gl_stats(8), sample_gl_stats(10)));
}

// ------------------------------------------------ W4：Batcher 四模式断言
sample_batcher_verify :: () {
    if !sample.batch_ok {
        sample.batch_result = -1;
        log_info("W4 BATCHER: SKIP —— Batcher 没建起来");
        return;
    }

    width := window_width_in_pixels(App.window);
    height := window_height_in_pixels(App.window);
    if width <= 0 || height <= 0 {
        sample.batch_result = -1;
        log_info("W4 BATCHER: SKIP —— 画布尺寸为 0");
        return;
    }

    // 四块的采样点：横条 y = 22%..36%，各自水平居中；渐变取左右 1/4 处。
    mid_y := cast(s32) (cast(float) height * 0.29);
    solid_x := cast(s32) (cast(float) width * 0.12);
    grad_lx := cast(s32) (cast(float) width * (0.26 + 0.20 * 0.25));
    grad_rx := cast(s32) (cast(float) width * (0.26 + 0.20 * 0.75));
    wash_x := cast(s32) (cast(float) width * 0.60);
    fill_x := cast(s32) (cast(float) width * 0.84);

    solid, ok_solid := sample_read_pixel(solid_x, mid_y);
    grad_l, ok_gl := sample_read_pixel(grad_lx, mid_y);
    grad_r, ok_gr := sample_read_pixel(grad_rx, mid_y);
    wash, ok_wash := sample_read_pixel(wash_x, mid_y);
    fill, ok_fill := sample_read_pixel(fill_x, mid_y);

    if !ok_solid || !ok_gl || !ok_gr || !ok_wash || !ok_fill {
        sample.batch_result = -1;
        log_info("W4 BATCHER: SKIP —— 读回失败（这个宿主没有 WebGL2）");
        return;
    }

    sample.solid_px = solid;
    sample.grad_l_px = grad_l;
    sample.grad_r_px = grad_r;
    sample.wash_px = wash;
    sample.fill_px = fill;

    // solid / fill / 渐变的两个端点都是「不透明覆盖」，颜色应当精确。
    ok_s := solid == EXPECT_SOLID;
    // 渐变：25% 处 ≈ lerp(red, blue, 0.25) = (191,0,64)，75% 处 ≈ (64,0,191)。
    // 允许 ±4：像素中心与顶点位置之间的半像素误差会带来一点点偏差。
    grad_l_ok := sample_color_near(grad_l, Color.{ 191, 0, 64, 255 }, 4);
    grad_r_ok := sample_color_near(grad_r, Color.{ 64, 0, 191, 255 }, 4);
    grad_ok := grad_l_ok && grad_r_ok && grad_l.r > grad_r.r && grad_r.b > grad_l.b;
    // wash：alpha 混合结果（驱动舍入 → ±2）
    wash_ok := sample_color_near(wash, EXPECT_WASH, WASH_TOLERANCE);
    // fill：显式纹理坐标 + 绑了纹理，颜色仍然必须是纯顶点色
    fill_ok := fill == EXPECT_FILL;

    ok := ok_s && grad_ok && wash_ok && fill_ok;
    sample.batch_result = 0;
    if ok sample.batch_result = 1;

    log_info(tprint("W4 BATCHER solid   @ (%,%) = % 期望 %  %",
                    solid_x, mid_y, sample_color_text(solid), sample_color_text(EXPECT_SOLID),
                    ifx ok_s then "PASS" else "FAIL"));
    log_info(tprint("W4 BATCHER gradient@ (%,%) = % 期望 (191,0,64,255)  %",
                    grad_lx, mid_y, sample_color_text(grad_l), ifx grad_l_ok then "PASS" else "FAIL"));
    log_info(tprint("W4 BATCHER gradient@ (%,%) = % 期望 (64,0,191,255)  %",
                    grad_rx, mid_y, sample_color_text(grad_r), ifx grad_r_ok then "PASS" else "FAIL"));
    log_info(tprint("W4 BATCHER wash    @ (%,%) = % 期望 % (±%)  %",
                    wash_x, mid_y, sample_color_text(wash), sample_color_text(EXPECT_WASH),
                    WASH_TOLERANCE, ifx wash_ok then "PASS" else "FAIL"));
    log_info(tprint("W4 BATCHER fill    @ (%,%) = % 期望 %  %（纹理被忽略）",
                    fill_x, mid_y, sample_color_text(fill), sample_color_text(EXPECT_FILL),
                    ifx fill_ok then "PASS" else "FAIL"));
    log_info(tprint("W4 BATCHER: %  （4 个模式各一块 / 1 个 batch / 顶点 24 字节 4 属性）",
                    ifx ok then "PASS" else "FAIL"));
}

// ------------------------------------------------ W4：字体 / MSDF 断言
sample_font_verify :: () {
    if !sample.font_ok {
        sample.font_result = -1;
        log_info("W4 FONT: SKIP —— Sprite_Font 没建起来");
        return;
    }

    width := window_width_in_pixels(App.window);
    height := window_height_in_pixels(App.window);
    if width <= 0 || height <= 0 {
        sample.font_result = -1;
        log_info("W4 FONT: SKIP —— 画布尺寸为 0");
        return;
    }

    // 扫描带：文字画在 y = 40% 处、x 从 3% 开始。带子取 x 2%..74%、高 22% 画布
    // （上限 72 设备像素），覆盖整行字的上下沿。
    //
    // 上沿从 38.5% 起（不是 36%）：Batcher 四模式那条横条的下沿正好在 36%，
    // 第一次写成 36% 时扫描带的第一行把四块色块的最后一像素也数了进来，
    // 「墨迹 x 范围 0..218」把整条带都算成了字。
    strip_x := cast(s32) (cast(float) width * 0.02);
    strip_y := cast(s32) (cast(float) height * 0.385);
    strip_w := cast(s32) (cast(float) width * 0.72);
    strip_h := cast(s32) (cast(float) height * 0.22);
    if strip_h > 72 strip_h = 72;
    if strip_w > 512 strip_w = 512;
    if strip_x + strip_w > width strip_w = width - strip_x;
    if strip_y + strip_h > height strip_h = height - strip_y;

    pixels, ok := sample_read_strip(strip_x, strip_y, strip_w, strip_h);
    if !ok {
        sample.font_result = -1;
        log_info("W4 FONT: SKIP —— 读回失败（这个宿主没有 WebGL2）");
        return;
    }

    // 数「不是清屏色」的像素。字形边缘有 MSDF 抗锯齿，所以任何非零覆盖都会偏
    // 离清屏色 —— 计数本身就是覆盖率。
    non_clear: s32 = 0;
    min_x: s32 = strip_w;
    max_x: s32 = -1;
    for i: 0..cast(s32) pixels.count - 1 {
        if pixels[i] != CLEAR_COLOR {
            non_clear += 1;
            x := i % strip_w;
            if x < min_x min_x = x;
            if x > max_x max_x = x;
        }
    }
    sample.font_pixels = non_clear;
    sample.font_scanned = strip_w * strip_h;

    // 三条断言：真的有东西 / 不止一两个杂点 / 不是整块铺满（那说明画的不是字）。
    enough_ink := non_clear >= 100;
    not_blob := non_clear * 2 <= sample.font_scanned;
    atlas_ok := sample.font_atlas_ink > 0 && sample.font_atlas_w > 0;
    ok_all := enough_ink && not_blob && atlas_ok;

    sample.font_result = 0;
    if ok_all sample.font_result = 1;

    log_info(tprint("W4 FONT atlas   : %x%  DistanceRange=%  非空 texel=%",
                    sample.font_atlas_w, sample.font_atlas_h,
                    sample.font_distance_range, sample.font_atlas_ink));
    // 千分比用整数打（tprint 的 % 就是占位符，`%.1f` / `%%` 这类 printf 写法不认，
    // 第一次写成 `%.1f%%` 时日志里出现了 "1.943018.1f0218" 这种鬼东西）。
    permille := 1000 * non_clear / max(1, sample.font_scanned);
    log_info(tprint("W4 FONT scan    : (% ,%) %x%  非清屏像素 = %/%  千分比 = %",
                    strip_x, strip_y, strip_w, strip_h,
                    non_clear, sample.font_scanned, permille));
    log_info(tprint("W4 FONT ink x   : % .. % （相对扫描带左沿）", min_x, max_x));
    log_info(tprint("W4 FONT: %  （有墨=% 非铺满=% 图集非空=%；DistanceRange 走片段 UBO binding 8）",
                    ifx ok_all then "PASS" else "FAIL",
                    ifx enough_ink then "PASS" else "FAIL",
                    ifx not_blob then "PASS" else "FAIL",
                    ifx atlas_ok then "PASS" else "FAIL"));
}

// ---------------------------------------------- W4：热替换的三个读回点
//
// 渲染顺序保证这三个函数都在「这一帧已经画完」之后被调用（sample_render 里
// sample_graphics_render 在最前面）。读的是同一块 quad 的中心，所以前后可以直接比。
sample_hotreload_poll :: () {
    hr := *sample.hr;
    if hr.mat == null return;

    width := window_width_in_pixels(App.window);
    height := window_height_in_pixels(App.window);
    if width <= 0 || height <= 0 return;

    // 采样点落在 quad 的左半（8×8 纹理的红半），x = 82%、y = 48%。
    px := cast(s32) (cast(float) width * 0.82);
    py := cast(s32) (cast(float) height * 0.48);
    color, ok := sample_read_pixel(px, py);
    if !ok return;

    if !sample.pixel_checked return; // 画面还没稳定，先不记

    if !sample.hr.have_before && sample.updates == PIXEL_CHECK_FRAME {
        sample.hr.before = color;
        sample.hr.have_before = true;
        log_info(tprint("W4 HOT-REPLACE before : % @ (%,%)", sample_color_text(color), px, py));
        return;
    }
    if sample.hr.have_before && !sample.hr.have_after_good && hr.ok_good && sample.updates > HOTRELOAD_GOOD_FRAME {
        sample.hr.after_good = color;
        sample.hr.have_after_good = true;
        log_info(tprint("W4 HOT-REPLACE after v2 : % @ (%,%) 期望 %（% ）",
                        sample_color_text(color), px, py, sample_color_text(EXPECT_HR_V2),
                        ifx color == EXPECT_HR_V2 then "PASS" else "FAIL"));
        return;
    }
    if sample.hr.have_after_good && !sample.hr.have_after_syntax && sample.updates > HOTRELOAD_BAD_COMPILE_FRAME {
        sample.hr.after_syntax = color;
        sample.hr.have_after_syntax = true;
        log_info(tprint("W4 HOT-REPLACE after rejected(compile) : % 期望仍为 %（% ）",
                        sample_color_text(color), sample_color_text(EXPECT_HR_V2),
                        ifx color == EXPECT_HR_V2 then "PASS（旧 program 仍在画）" else "FAIL"));
        return;
    }
    if sample.hr.have_after_syntax && !sample.hr.have_after_link && sample.updates > HOTRELOAD_BAD_LINK_FRAME {
        sample.hr.after_link = color;
        sample.hr.have_after_link = true;
        log_info(tprint("W4 HOT-REPLACE after rejected(link)    : % 期望仍为 %（% ）",
                        sample_color_text(color), sample_color_text(EXPECT_HR_V2),
                        ifx color == EXPECT_HR_V2 then "PASS（旧 program 仍在画）" else "FAIL"));
        return;
    }
}

sample_hotreload_verify :: () {
    hr := *sample.hr;
    if hr.mat == null {
        sample.hr_result = -1;
        log_info("W4 HOT-REPLACE: SKIP —— harness 没建起来");
        return;
    }
    if !hr.have_before || !hr.have_after_good || !hr.have_after_syntax || !hr.have_after_link {
        sample.hr_result = -1;
        log_info(tprint("W4 HOT-REPLACE: SKIP —— 读回不完整（宿主没有 WebGL2？）before=% after_good=% rejected=%",
                        hr.have_before, hr.have_after_good, hr.have_after_syntax));
        return;
    }

    swap_worked := hr.before == EXPECT_HR_V1 && hr.after_good == EXPECT_HR_V2;
    compile_rejected := !hr.ok_syntax && hr.err_syntax != "";
    link_rejected := !hr.ok_link && hr.err_link != "";
    old_survived := hr.after_syntax == hr.after_good && hr.after_link == hr.after_good;

    ok := swap_worked && compile_rejected && link_rejected && old_survived;
    sample.hr_result = 0;
    if ok sample.hr_result = 1;

    log_info(tprint("W4 HOT-REPLACE swap    : before=% → after=%  交换真的生效=%",
                    sample_color_text(hr.before), sample_color_text(hr.after_good), swap_worked));
    log_info(tprint("W4 HOT-REPLACE compile : ok=% error='%'", hr.ok_syntax, hr.err_syntax));
    log_info(tprint("W4 HOT-REPLACE link    : ok=% error='%'", hr.ok_link, hr.err_link));
    log_info(tprint("W4 HOT-REPLACE survive : 被拒后仍是 %（编译错后 %，链接错后 %）旧 program 仍在画=%",
                    sample_color_text(hr.after_good), sample_color_text(hr.after_syntax),
                    sample_color_text(hr.after_link), old_survived));
    log_info(tprint("W4 HOT-REPLACE: %  （program 链接数=% 回收数见 gl 统计）",
                    ifx ok then "PASS" else "FAIL", sample_gl_stats(6)));
}

// ============================================================ W5：离屏 Target
//
// 三段证据共用一张 256×256 的 target。资源全部在 startup 建好（见 Sample_State
// 里的说明），检查帧只做「画 + 读回」，于是 soak 阶段的存活计数是干净的。
sample_w5_startup :: (device: *Graphics_Device) {
    // (1) 单采样 target：四色象限的落点，同时也是 blit 的源
    sample.w5_target = target_create(device, W5_TARGET_SIZE, W5_TARGET_SIZE, "w5_quad");

    // (2) 两张同尺寸 target，**只有 SampleCount 不同** —— MSAA 的 1×/4× 对照。
    //     4× 的附件在 web 后端是 renderbuffer（WebGL2 没有 MS 纹理），端 pass 时
    //     blitFramebuffer 解析到它的单采样解析纹理；读回走的就是那张解析纹理。
    infos: [1] Target_Attachment_Info;
    infos[0] = .{ Format = .COLOR, Flags = .NONE, SampleCount = .ONE };
    sample.ms1_target = target_create_attachments(device, W5_TARGET_SIZE, W5_TARGET_SIZE,
                                                 array_view(infos, 0, 1), "w5_ms1x");
    infos[0].SampleCount = .FOUR;
    sample.ms4_target = target_create_attachments(device, W5_TARGET_SIZE, W5_TARGET_SIZE,
                                                 array_view(infos, 0, 1), "w5_ms4x");

    // (3) 把 target 的附件当纹理采样：克隆默认 Textured 材质（连 vertex UBO 一起
    //     复制过来），只换片段 sampler 0。之所以要克隆而不是复用 defaults_* 那份，
    //     是因为那份是设备级共享缓存 —— 改了它 W3 的 quad 就跟着变。
    if sample.material != null && sample.w5_target != null {
        sample.w5_screen_mat = material_clone(sample.material);
        if sample.w5_screen_mat != null {
            sample.w5_screen_mat.Fragment.Samplers[0] = .{
                Tex = target_texture(sample.w5_target),
                Sampler = texture_sampler_make(.NEAREST, .CLAMP),
            };
        }
    }

    elements: [3] Vertex_Format_Element = .[
        .{ Index = 0, Type = .FLOAT2, Normalized = false },
        .{ Index = 1, Type = .FLOAT2, Normalized = false },
        .{ Index = 2, Type = .UBYTE4, Normalized = true },
    ];
    sample.w5_screen_mesh = mesh_create(device, vertex_format_make(elements), .THIRTY_TWO, "w5_screen");

    // 离屏绘制用独立 Batcher：和窗口那个共用会互相 batcher_clear。
    sample.w5_batcher = batcher_create(device, "w5_batcher");
    // blit_texture 的落点：普通纹理（不是附件），同尺寸同格式。
    sample.w5_blit_dst = texture_create(device, W5_TARGET_SIZE, W5_TARGET_SIZE, .COLOR, .NONE, .ONE,
                                        "w5_blit_dst");

    array_resize(*sample.edge_row, W5_TARGET_SIZE);

    ok := sample.w5_target != null && sample.w5_screen_mat != null && sample.w5_screen_mesh != null &&
          sample.w5_batcher != null && sample.w5_blit_dst != null &&
          sample.ms1_target != null && sample.ms4_target != null &&
          sample.w5_target.handle != 0 && sample.ms1_target.handle != 0 && sample.ms4_target.handle != 0;
    sample.w5_ok = ok;

    if ok {
        log_info(tprint("sample: W5 已就位 —— %x% 离屏 target（四色象限）+ MSAA 1×/4× 各一张 + blit 落点纹理",
                        W5_TARGET_SIZE, W5_TARGET_SIZE));
    } else {
        log_error("sample: W5 的资源没建全 —— 离屏/MSAA/blit 三段会 SKIP");
    }
}

// 每帧：先把四色象限画进离屏 target，再把它当纹理画回窗口。
sample_w5_render :: (device: *Graphics_Device, window_target: Drawable_Target, width: s32, height: s32) {
    if !sample.w5_ok || device == null return;

    // ---- 离屏：clear + 四个 fill 模式的矩形（Batcher，走 FBO 而不是 canvas）
    offscreen := drawable_target_target(sample.w5_target);
    graphics_device_clear_color(device, offscreen, W5_TARGET_CLEAR);
    {
        b := sample.w5_batcher;
        half := 0.5 * cast(float) W5_TARGET_SIZE;
        batcher_clear(b);
        batcher_set_texture(b, sample.batch_tex);
        batcher_set_sampler(b, texture_sampler_make(.NEAREST, .CLAMP));
        batcher_rect_xy(b, 0, 0, half, half, W5_Q_TL);
        batcher_rect_xy(b, half, 0, half, half, W5_Q_TR);
        batcher_rect_xy(b, 0, half, half, half, W5_Q_BL);
        batcher_rect_xy(b, half, half, half, half, W5_Q_BR);
        batcher_render(b, offscreen);
    }

    // ---- 上屏（顺带把 window pass 重新打开，见 sample_w5_present 的说明）
    sample_w5_present(device, window_target, width, height);
}

// 把 target 的附件纹理画到窗口的那块固定区域。
//
// 这个函数还有一个**时序**职责：W5/W6 的探针会为了读回而开别人的 render pass，
// 一帧的最后一次 pass 必须是窗口的 —— 否则 present 时 resolve 的是那个 target 的
// MS FBO，canvas 上留下的是上一帧。所以探针末尾都再调一次这里。
sample_w5_present :: (device: *Graphics_Device, window_target: Drawable_Target, width: s32, height: s32) {
    if device == null || sample.w5_screen_mat == null || sample.w5_screen_mesh == null return;
    if width <= 0 || height <= 0 return;

    r := sample_rect(width, height, W5_SCREEN_X, W5_SCREEN_Y, W5_SCREEN_W, W5_SCREEN_H);
    material_stage_set_uniform_value(*sample.w5_screen_mat.Vertex, 0, sample_ortho(width, height));

    white := Color_White;
    vertices: [4] Vertex = .[
        .{ pos = .{ r.x, r.y }, tex = .{ 0.0, 0.0 }, col = white },
        .{ pos = .{ r.x + r.w, r.y }, tex = .{ 1.0, 0.0 }, col = white },
        .{ pos = .{ r.x + r.w, r.y + r.h }, tex = .{ 1.0, 1.0 }, col = white },
        .{ pos = .{ r.x, r.y + r.h }, tex = .{ 0.0, 1.0 }, col = white },
    ];
    indices: [6] s32 = .[0, 1, 2, 0, 2, 3];
    mesh_set_vertices(sample.w5_screen_mesh, vertices);
    mesh_set_indices(sample.w5_screen_mesh, indices);

    cmd := draw_command_from_mesh(window_target, sample.w5_screen_mesh, sample.w5_screen_mat);
    graphics_device_draw(device, cmd);
}

// 从一张**纹理**读回一个像素（左上原点）。读失败时返回哨兵值，不会被误判成 PASS。
// MSAA 附件的读回由后端先 resolve 到解析纹理（sdl_get_texture_data 里那条路径）。
sample_texture_pixel :: (tex: *Texture, x: s32, y: s32) -> Color {
    if tex == null return Color.{ 0, 0, 0, 0 };
    if sample.edge_row.count < 1 array_resize(*sample.edge_row, 1);
    sample.edge_row[0] = TEXTURE_PIXEL_SENTINEL;
    texture_get_data_region(tex, sample.edge_row, .{ x, y, 1, 1 });
    return sample.edge_row[0];
}

// ------------------------------------------- W5(1)：目标纹理上屏 + 屏幕读回
sample_w5_verify :: (device: *Graphics_Device, width: s32, height: s32) {
    if !sample.w5_ok || device == null {
        sample.w5_result = -1;
        log_info("W5 TARGET: SKIP —— 离屏 target / 上屏材质没建起来");
        return;
    }
    if width <= 0 || height <= 0 {
        sample.w5_result = -1;
        log_info("W5 TARGET: SKIP —— 画布尺寸为 0");
        return;
    }

    // 屏幕上那块 quad 的四个象限中心（左上原点，设备像素）
    r := sample_rect(width, height, W5_SCREEN_X, W5_SCREEN_Y, W5_SCREEN_W, W5_SCREEN_H);
    expects: [4] Color = .[W5_Q_TL, W5_Q_TR, W5_Q_BL, W5_Q_BR];
    names: [4] string = .["TL", "TR", "BL", "BR"];
    offsets: [2] float = .[0.25, 0.75];

    all_ok := true;
    read_ok_any := false;
    for k: 0..3 {
        ox := offsets[k % 2];
        oy := offsets[k / 2];
        px := cast(s32) (r.x + r.w * ox);
        py := cast(s32) (r.y + r.h * oy);
        c, read_ok := sample_read_pixel(px, py);
        if read_ok read_ok_any = true;
        sample.w5_px[k] = c;
        good := read_ok && c == expects[k];
        if !good all_ok = false;
        // 读不到像素（Node 校验宿主 / 没有 WebGL2）时说 SKIP，不说 FAIL ——
        // 「没验」和「验失败」是两件事，混在一起会让人以为像素错了。
        status := ifx !read_ok then "SKIP（读回失败）" else ifx good then "PASS" else "FAIL";
        log_info(tprint("W5 TARGET screen %  @ (%,%) = % 期望 %  %",
                        names[k], px, py, sample_color_text(c), sample_color_text(expects[k]),
                        status));
    }

    if !read_ok_any {
        sample.w5_result = -1;
        log_info("W5 TARGET: SKIP —— 屏幕上读不到像素（这个宿主没有 WebGL2）");
    } else {
        sample.w5_result = 0;
        if all_ok sample.w5_result = 1;
        log_info(tprint("W5 TARGET: %  （%x% 离屏 target → 当纹理采样 → 屏幕读回四象限）",
                        ifx all_ok then "PASS" else "FAIL", W5_TARGET_SIZE, W5_TARGET_SIZE));
    }

    sample_blit_verify(device);
    sample_target_orientation_verify(device, width, height);
    sample_limit_verify(device);
}

// --------------------------------------------------- W5(3)：blit_texture
//
// 同尺寸、同格式（RGBA8 → RGBA8）→ 后端走一次 glBlitFramebuffer。从**落点纹理**
// 读回四个象限：源和目标内容一开始完全不同（落点纹理从没被写过），所以读对了
// 就说明拷贝真的发生了。
sample_blit_verify :: (device: *Graphics_Device) {
    if !sample.w5_ok || sample.w5_blit_dst == null {
        sample.blit_result = -1;
        log_info("W5 BLIT: SKIP —— 没有落点纹理");
        return;
    }

    blits_before := sample_gpu_stat(8);
    texture_blit(target_texture(sample.w5_target), sample.w5_blit_dst, .NEAREST);
    blits_after := sample_gpu_stat(8);

    expects: [4] Color = .[W5_Q_TL, W5_Q_TR, W5_Q_BL, W5_Q_BR];
    names: [4] string = .["TL", "TR", "BL", "BR"];
    half: s32 = W5_TARGET_SIZE / 2;
    quarter: s32 = half / 2;

    all_ok := true;
    read_ok_any := false;
    for k: 0..3 {
        x: s32 = quarter;
        y: s32 = quarter;
        if (k % 2) == 1 x = half + quarter;
        if (k / 2) == 1 y = half + quarter;
        got := sample_texture_pixel(sample.w5_blit_dst, x, y);
        read_ok := got != TEXTURE_PIXEL_SENTINEL;
        if read_ok read_ok_any = true;
        sample.blit_px[k] = got;
        good := read_ok && got == expects[k];
        if !good all_ok = false;
        status := ifx !read_ok then "SKIP（读回失败）" else ifx good then "PASS" else "FAIL";
        log_info(tprint("W5 BLIT %  @ (%,%) = % 期望 %  %", names[k], x, y,
                        sample_color_text(got), sample_color_text(expects[k]), status));
    }

    if !read_ok_any {
        sample.blit_result = -1;
        log_info("W5 BLIT: SKIP —— 纹理读回拿不到像素（这个宿主没有 WebGL2）");
        return;
    }
    sample.blit_result = 0;
    if all_ok sample.blit_result = 1;
    log_info(tprint("W5 BLIT: %  （blitFramebuffer %x% → %x%，从落点纹理读回；blits %→%）",
                    ifx all_ok then "PASS" else "FAIL",
                    W5_TARGET_SIZE, W5_TARGET_SIZE, W5_TARGET_SIZE, W5_TARGET_SIZE,
                    blits_before, blits_after));
}

// ------------------------------------------------ W6(6)：超限纹理的明确拒绝
//
// 一张超过 MAX_TEXTURE_SIZE 的纹理：后端必须**返回 0 句柄**并在日志里说清楚，
// 而不是给出一个「有效但不可用」的句柄（后面每次采样都是黑的，还查不出来）。
sample_limit_verify :: (device: *Graphics_Device) {
    if device == null || sample_gl_stats(11) <= 0 || sample_gpu_stat(22) <= 0 {
        sample.limit_result = -1;
        log_info("W6 LIMIT: SKIP —— 这个宿主没有 WebGL2（没有 MAX_TEXTURE_SIZE 可对照）");
        return;
    }

    max_size := sample_gpu_stat(22);
    sample.limit_max = max_size;

    rejections_before := sample_gpu_stat(12);
    too_big := texture_create(device, max_size + 64, 16, .COLOR, .NONE, .ONE, "w6_too_big");
    handle: s32 = -1;
    if too_big != null handle = cast(s32) too_big.handle;
    rejections_after := sample_gpu_stat(12);
    sample.limit_handle = handle;

    ok := handle == 0 && rejections_after == rejections_before + 1;
    sample.limit_result = 0;
    if ok sample.limit_result = 1;
    log_info(tprint("W6 LIMIT: %  —— 请求 %x% 的纹理（MAX_TEXTURE_SIZE=%）→ 句柄=% 拒绝计数 %→%",
                    ifx ok then "PASS" else "FAIL", max_size + 64, 16, max_size, handle,
                    rejections_before, rejections_after));
    log_info("W6 LIMIT: 上面的日志里应有后端打的一行「纹理 'w6_too_big' 的尺寸 ... 超过 MAX_TEXTURE_SIZE = ... —— 拒绝创建（不降级、不崩溃）」");
}

// ------------------------------------------------------ W5(2)：MSAA 1× vs 4×
//
// 同一个 45° 三角形画进 Sample_Count 不同的两张 target，读回**同一条边所在的
// 行**，数「部分覆盖像素」（既不是清屏色、也不是三角形色）。
sample_msaa_probe :: (device: *Graphics_Device, target: *Target) -> (partial: s32, edge_px: Color, edge_x: s32, read_ok: bool) {
    partial = 0;
    edge_px = Color.{ 0, 0, 0, 0 };
    edge_x = -1;
    read_ok = false;
    if device == null || target == null || sample.w5_batcher == null return;

    off := drawable_target_target(target);
    graphics_device_clear_color(device, off, CLEAR_COLOR);
    {
        b := sample.w5_batcher;
        batcher_clear(b);
        batcher_set_texture(b, sample.batch_tex);
        batcher_set_sampler(b, texture_sampler_make(.NEAREST, .CLAMP));
        s := cast(float) W5_TARGET_SIZE;
        batcher_triangle(b, .{ 0.0, 0.0 }, .{ s, 0.0 }, .{ 0.0, s }, MSAA_TRI_GREEN);
        batcher_render(b, off);
    }

    tex := target_texture(target);
    if tex == null || tex.handle == 0 return;

    // 读回一行。先填哨兵：读失败（没有 GL / FBO 不完整）时不会被算成「全清屏」。
    array_resize(*sample.edge_row, W5_TARGET_SIZE);
    for i: 0..W5_TARGET_SIZE - 1 sample.edge_row[i] = TEXTURE_PIXEL_SENTINEL;
    texture_get_data_region(tex, sample.edge_row, .{ 0, MSAA_EDGE_ROW, W5_TARGET_SIZE, 1 });

    sentinels: s32 = 0;
    for k: 0..W5_TARGET_SIZE - 1 {
        c := sample.edge_row[k];
        if c == TEXTURE_PIXEL_SENTINEL {
            sentinels += 1;
            continue;
        }
        if c == CLEAR_COLOR continue; // 完全在三角形外
        if c == MSAA_TRI_GREEN continue; // 完全在三角形内
        if partial == 0 {
            edge_px = c;
            edge_x = cast(s32) k;
        }
        partial += 1;
    }
    read_ok = sentinels == 0;
}

sample_msaa_verify :: (device: *Graphics_Device, window_target: Drawable_Target, width: s32, height: s32) {
    if !sample.w5_ok || sample.ms1_target == null || sample.ms4_target == null {
        sample.msaa_result = -1;
        log_info("W5 MSAA: SKIP —— target / batcher 没建起来");
        return;
    }

    read_ok_1x := false;
    read_ok_4x := false;
    {
        n, px, xi, ok := sample_msaa_probe(device, sample.ms1_target);
        sample.msaa_partial_1x = n;
        sample.msaa_edge_1x = px;
        sample.msaa_edge_x_1x = xi;
        read_ok_1x = ok;
    }
    {
        n, px, xi, ok := sample_msaa_probe(device, sample.ms4_target);
        sample.msaa_partial_4x = n;
        sample.msaa_edge_4x = px;
        sample.msaa_edge_x_4x = xi;
        read_ok_4x = ok;
    }

    // 探针最后停在 ms4 的 target pass 上：把 window pass 重新打开（见 sample_w5_present）。
    sample_w5_present(device, window_target, width, height);

    one_ok := sample.msaa_partial_1x == 0;
    four_ok := sample.msaa_partial_4x >= 1;
    value_ok := sample_color_near(sample.msaa_edge_4x, EXPECT_MSAA_PARTIAL, MSAA_PARTIAL_TOLERANCE);

    status_1 := ifx !read_ok_1x then "SKIP（读回失败）" else ifx one_ok then "PASS" else "FAIL";
    status_4 := ifx !read_ok_4x then "SKIP（读回失败）" else ifx (four_ok && value_ok) then "PASS" else "FAIL";
    log_info(tprint("W5 MSAA 1x : y=% 那一行的部分覆盖像素 = %（期望 0 —— 像素中心恰好落在斜边上）%",
                    MSAA_EDGE_ROW, sample.msaa_partial_1x, status_1));
    log_info(tprint("W5 MSAA 4x : 同一行的部分覆盖像素 = % @ x=% 值 = % 期望 %（±%）%",
                    sample.msaa_partial_4x, sample.msaa_edge_x_4x,
                    sample_color_text(sample.msaa_edge_4x), sample_color_text(EXPECT_MSAA_PARTIAL),
                    MSAA_PARTIAL_TOLERANCE, status_4));

    if !read_ok_1x || !read_ok_4x {
        sample.msaa_result = -1;
        log_info("W5 MSAA: SKIP —— 两张 target 的像素都读不回来（这个宿主没有 WebGL2；读到的是哨兵）");
        return;
    }
    ok := one_ok && four_ok && value_ok;
    sample.msaa_result = 0;
    if ok sample.msaa_result = 1;
    log_info(tprint("W5 MSAA: %  （0 → % 就是「4 个子样本真的被采样」的证据；MSAA target 数=%）",
                    ifx ok then "PASS" else "FAIL", sample.msaa_partial_4x, sample_gpu_stat(11)));
}

// ========================================================= W6：窗口级 MSAA
//
// MULTI_SAMPLED_BACK_BUFFER 在 web 上的落地是「窗口大小的 MS FBO + present 时
// resolve 到 0 号 FBO」。这里断言三件事：报告的样本数是**真实**的（不是被静默
// 降级成 1）、后端真的建了那张 MS FBO（samples > 0）、resolve 真的在发生
// （window_resolves > 0）。再读回一帧，确认画面在 MSAA 下仍然正常。
sample_w6_window_verify :: (width: s32, height: s32) {
    device := App.device;
    if device == null {
        sample.w6_window_result = -1;
        log_info("W6 WINDOW-MSAA: SKIP —— 没有 Graphics_Device");
        return;
    }

    bb := sample_sample_count_value(device.backbuffer_format.SampleCount);
    ms := sample_gpu_stat(10); // window_ms.samples（MS FBO 真实建出来的）
    resolves := sample_gpu_stat(9); // window_resolves（present 时的 resolve 次数）
    max_samples := sample_gpu_stat(23);
    sample.w6_bb_samples = bb;
    sample.w6_ms_samples = ms;
    sample.w6_resolves = resolves;

    // 读回一帧：W3 的 quad 左右 + 清屏色，MSAA 下必须仍然是**精确**值
    // （采样点都在色块内部，AA 只影响边缘）。
    frame_ok := false;
    read_ok_any := false;
    if width > 0 && height > 0 {
        left_x := cast(s32) (cast(float) width * 0.375);
        right_x := cast(s32) (cast(float) width * 0.625);
        mid_y := cast(s32) (cast(float) height * 0.79);
        out_x := cast(s32) (cast(float) width * 0.05);
        out_y := cast(s32) (cast(float) height * 0.05);
        left, ok_l := sample_read_pixel(left_x, mid_y);
        right, ok_r := sample_read_pixel(right_x, mid_y);
        out, ok_o := sample_read_pixel(out_x, out_y);
        read_ok_any = ok_l && ok_r && ok_o;
        frame_ok = read_ok_any &&
                   left == EXPECT_LEFT && right == EXPECT_RIGHT && out == EXPECT_OUTSIDE;
        log_info(tprint("W6 WINDOW-MSAA frame : left=% right=% out=% （MSAA 下的画面）正常=%",
                        sample_color_text(left), sample_color_text(right),
                        sample_color_text(out), frame_ok));
    }

    ok := bb > 1 && ms == bb && resolves > 0 && max_samples >= bb && frame_ok;
    if !read_ok_any {
        sample.w6_window_result = -1;
        log_info(tprint("W6 WINDOW-MSAA: SKIP —— 读不回像素（这个宿主没有 WebGL2）；报出来的样本数 backbuffer=% MS FBO=% MAX_SAMPLES=% resolve=%",
                        bb, ms, max_samples, resolves));
        return;
    }
    sample.w6_window_result = 0;
    if ok sample.w6_window_result = 1;
    log_info(tprint("W6 WINDOW-MSAA: %  —— backbuffer_format.SampleCount=%（真实值）窗口 MS FBO samples=% MAX_SAMPLES=% resolve 次数=%",
                    ifx ok then "PASS" else "FAIL", bb, ms, max_samples, resolves));
}

// ============================================================ W6：内存 soak
//
// 每 500 帧采一次：memory.buffer.byteLength（只有 JS 知道）+ fw_stats(200+i) 的
// 存活计数（Jai 侧缓存表 + GPU 资源表）。
sample_soak_poll :: () {
    if sample.updates < W6_SOAK_FIRST_FRAME || sample.updates > W6_SOAK_LAST_FRAME return;
    if (sample.updates - W6_SOAK_FIRST_FRAME) % W6_SOAK_EVERY != 0 return;

    i: s32 = sample.soak_samples;
    if i >= W6_SOAK_MAX_SAMPLES return;

    sample.soak_frames[i] = sample.updates;
    sample.soak_mem[i] = sample_memory_bytes();
    sample.soak_programs[i] = sample_gpu_stat(0);
    sample.soak_pipelines[i] = sample_gpu_stat(1);
    sample.soak_samplers[i] = sample_gpu_stat(2);
    sample.soak_targets[i] = sample_gpu_stat(3);
    sample.soak_tex_fbos[i] = sample_gpu_stat(4);
    sample.soak_textures[i] = sample_gpu_stat(13);
    sample.soak_buffers[i] = sample_gpu_stat(14);
    sample.soak_target_res[i] = sample_gpu_stat(21);
    sample.soak_samples += 1;

    log_info(tprint("W6 SOAK #% frame %: memory=% B programs=% pipelines=% samplers=% targets=% texture_fbos=% 资源(texture/buffer/target)=%/%/%",
                    i, sample.updates, sample.soak_mem[i],
                    sample.soak_programs[i], sample.soak_pipelines[i], sample.soak_samplers[i],
                    sample.soak_targets[i], sample.soak_tex_fbos[i],
                    sample.soak_textures[i], sample.soak_buffers[i], sample.soak_target_res[i]));

    if sample.updates == W6_SOAK_LAST_FRAME sample_soak_report();
}

sample_soak_report :: () {
    n := sample.soak_samples;
    if n < 2 {
        sample.soak_result = -1;
        log_info(tprint("W6 SOAK: SKIP —— 只采到 % 个样本（帧数不够）", n));
        return;
    }

    mem_first := sample.soak_mem[0];
    mem_last := sample.soak_mem[n - 1];
    mem_growth := mem_last - mem_first;

    // 「单调增长」= 每一个相邻对都更大。内存 soak 要证伪的就是它。
    monotonic := true;
    for i: 1..n - 1 {
        if sample.soak_mem[i] <= sample.soak_mem[i - 1] monotonic = false;
    }

    // 存活计数：首尾必须完全相等（只增不减就是泄漏）。
    counts_ok := true;
    for i: 1..n - 1 {
        if sample.soak_programs[i] != sample.soak_programs[0] counts_ok = false;
        if sample.soak_pipelines[i] != sample.soak_pipelines[0] counts_ok = false;
        if sample.soak_samplers[i] != sample.soak_samplers[0] counts_ok = false;
        if sample.soak_targets[i] != sample.soak_targets[0] counts_ok = false;
        if sample.soak_tex_fbos[i] != sample.soak_tex_fbos[0] counts_ok = false;
        if sample.soak_textures[i] != sample.soak_textures[0] counts_ok = false;
        if sample.soak_buffers[i] != sample.soak_buffers[0] counts_ok = false;
        if sample.soak_target_res[i] != sample.soak_target_res[0] counts_ok = false;
    }

    mem_ok := mem_growth <= W6_SOAK_MEM_TOLERANCE;
    ok := mem_ok && !monotonic && counts_ok;
    sample.soak_result = 0;
    if ok sample.soak_result = 1;

    log_info(tprint("W6 SOAK memory: frame % → %  memory % B → % B（Δ=%，容差 %）不单调增长=%  PASS=%",
                    sample.soak_frames[0], sample.soak_frames[n - 1], mem_first, mem_last,
                    mem_growth, W6_SOAK_MEM_TOLERANCE, !monotonic, mem_ok));
    log_info(tprint("W6 SOAK alive : programs=% pipelines=% samplers=% targets=% texture_fbos=% 资源(texture/buffer/target)=%/%/% 首尾相等=%",
                    sample.soak_programs[0], sample.soak_pipelines[0], sample.soak_samplers[0],
                    sample.soak_targets[0], sample.soak_tex_fbos[0],
                    sample.soak_textures[0], sample.soak_buffers[0], sample.soak_target_res[0],
                    counts_ok));
    log_info(tprint("W6 SOAK: %  （% 个样本 / % 帧；内存首尾 Δ=%，存活计数首尾相等=%）",
                    ifx ok then "PASS" else "FAIL", n, W6_SOAK_LAST_FRAME, mem_growth, counts_ok));
}

// ---------------------------------------------------------------- 更新
sample_update :: () {
    sample.updates += 1;
    dt := 1.0 / 60.0; // fixed step 60：一个 update 一个定步
    sample.elapsed += dt;
    sample.last_dt = dt;

    kb := input_keyboard(App.input);
    ms := input_mouse(App.input);

    // ---- 键盘：ESC 退出，其余按键只统计 ----
    if keyboard_pressed(kb, .ESCAPE) {
        log_info(tprint("sample: ESC 按下 —— 请求退出（第 % 帧）", sample.updates));
        app_exit();
        return;
    }

    down_count: s32;
    for d: kb.down if d down_count += 1;
    if down_count > 0 && sample.last_key == "" {
        p := keyboard_first_pressed(kb);
        if p >= 0 {
            sample.pressed_total += 1;
            sample.last_key = tprint("scancode %", p);
            log_info(tprint("sample: 按键进入 Input —— % （当前按下 % 个键）", sample.last_key, down_count));
        }
    } else if down_count == 0 {
        sample.last_key = "";
    }

    // ---- 心跳：证明 App.update 是被宿主一帧一帧驱动的 ----
    if sample.updates % LOG_EVERY_N_FRAMES == 0 {
        sample.heartbeats += 1;
        log_info(tprint("sample: update #% elapsed=%s mouse=%x% keys_down=% events=%",
                        sample.updates, sample.elapsed, ms.Position.x, ms.Position.y,
                        down_count, sample_stats(10)));
    }

    // ---- W4：热替换的三个时间点 ----
    //
    // 放在 update 里（不是 render）是硬要求：ShaderPairTryReplace 会销毁旧 shader、
    // 连带回收依赖它的 pipeline，如果这时 render pass 还开着，后端手里就有悬空
    // handle。上一帧的 graphics_device_present 已经 end_render_pass 了，所以
    // update 是唯一安全的位置 —— 桌面版的分支检查 device.render_pass != null
    // 会在别处把这件事抓住。
    if sample.updates == HOTRELOAD_GOOD_FRAME || sample.updates == HOTRELOAD_BAD_COMPILE_FRAME ||
       sample.updates == HOTRELOAD_BAD_LINK_FRAME {
        device := App.device;
        target := drawable_target_window(App.window);
        which: s32 = 1;
        if sample.updates == HOTRELOAD_BAD_COMPILE_FRAME which = 2;
        if sample.updates == HOTRELOAD_BAD_LINK_FRAME which = 3;

        ok, error := sample_hotreload_try(device, target, which);
        if which == 1 sample.hr.ok_good = ok;
        // copy_string：ShaderPairTryReplace 返回的是 tprint 的**临时缓冲**，
        // 下一次 tprint 就会把它覆盖掉。直接存指针会在报告里打出毫无关系的
        // 另一行日志（第一次跑就是这样）。要留住内容就得自己复制。
        if which == 2 {
            sample.hr.ok_syntax = ok;
            if !ok sample.hr.err_syntax = copy_string(error);
        }
        if which == 3 {
            sample.hr.ok_link = ok;
            if !ok sample.hr.err_link = copy_string(error);
        }
    }

    // ---- W6：内存 soak 的采样点（第 500/1000/…/3000 帧） ----
    sample_soak_poll();

    // ---- 5 秒一次的全量报告 + 存档/剪贴板闭环 ----
    if sample.updates % REPORT_EVERY_N_FRAMES == 0 {
        sample_report();
    }
}

sample_report :: () {
    size := window_size(App.window);
    pixels := window_size_in_pixels(App.window);
    ms := input_mouse(App.input);

    log_info("=========== sample report ===========");
    log_info(tprint("  frames        : update=% fw_stats=% app_time=%",
                    sample.updates, sample_stats(0), cast(s32) App.time.frame));
    log_info(tprint("  elapsed       : %s", sample.elapsed));
    log_info(tprint("  window css    : %x%", size.x, size.y));
    log_info(tprint("  canvas device : %x%", pixels.x, pixels.y));
    log_info(tprint("  dpr           : % /100", sample_stats(13)));
    log_info(tprint("  mouse         : %x%", ms.Position.x, ms.Position.y));
    log_info(tprint("  dom events    : total=% text=% resize=%",
                    sample_stats(10), sample_stats(11), sample_stats(14)));
    log_info(tprint("  keyboard      : pressed_total=% key_events=% current_down=%",
                    sample.pressed_total, sample_stats(10), sample_stats(6)));

    // W3：GL 侧的客观计数 + 第一次读回断言的结果
    log_info(tprint("  webgl2        : device=% draw=% pass=% clear=% tex_upload=% buf_upload=%",
                    sample_gl_stats(11), sample_gl_stats(0), sample_gl_stats(1),
                    sample_gl_stats(2), sample_gl_stats(3), sample_gl_stats(4)));
    log_info(tprint("  webgl2        : shader=% program=% pipeline=% readback=% pixels=% gl_error=%",
                    sample_gl_stats(5), sample_gl_stats(6), sample_gl_stats(7),
                    sample_gl_stats(8), sample_gl_stats(9), sample_gl_stats(10)));
    log_info(tprint("  pixel check   : result=% （1=PASS 0=FAIL -1=SKIP，第 % 帧读回）",
                    sample.pixel_result, PIXEL_CHECK_FRAME));
    log_info(tprint("  batcher check : result=% （solid/gradient/wash/fill）", sample.batch_result));
    log_info(tprint("  font check    : result=% （图集 %x% / 非清屏 %/%）",
                    sample.font_result, sample.font_atlas_w, sample.font_atlas_h,
                    sample.font_pixels, sample.font_scanned));
    log_info(tprint("  hot-replace   : result=% （swap=% 编译被拒=% 链接被拒=% 旧 program 存活=%）",
                    sample.hr_result, sample.hr.ok_good, !sample.hr.ok_syntax,
                    !sample.hr.ok_link,
                    sample.hr.after_syntax == sample.hr.after_good && sample.hr.have_after_syntax));
    // W5：离屏 target / MSAA / blit 三段
    log_info(tprint("  W5 target     : result=% （屏幕四象限 TL/TR/BL/BR = % % % %）",
                    sample.w5_result,
                    sample_color_text(sample.w5_px[0]), sample_color_text(sample.w5_px[1]),
                    sample_color_text(sample.w5_px[2]), sample_color_text(sample.w5_px[3])));
    log_info(tprint("  W5 blit       : result=% （blits=% 落点纹理读回 = % % % %）",
                    sample.blit_result, sample_gpu_stat(8),
                    sample_color_text(sample.blit_px[0]), sample_color_text(sample.blit_px[1]),
                    sample_color_text(sample.blit_px[2]), sample_color_text(sample.blit_px[3])));
    log_info(tprint("  W5 msaa       : result=% （1x 部分覆盖=% 4x 部分覆盖=% 4x 边像素=% MSAA target 数=%）",
                    sample.msaa_result, sample.msaa_partial_1x, sample.msaa_partial_4x,
                    sample_color_text(sample.msaa_edge_4x), sample_gpu_stat(11)));
    log_info(tprint("  W6 limit      : result=% （MAX_TEXTURE_SIZE=% 超限句柄=% 拒绝计数=%）",
                    sample.limit_result, sample.limit_max, sample.limit_handle, sample_gpu_stat(12)));
    log_info(tprint("  W6 window msaa: result=% （backbuffer samples=% MS FBO samples=% resolve=% MAX_SAMPLES=%）",
                    sample.w6_window_result, sample.w6_bb_samples, sample.w6_ms_samples,
                    sample.w6_resolves, sample_gpu_stat(23)));
    last_soak := cast(s32) (ifx sample.soak_samples > 0 then sample.soak_samples - 1 else 0);
    log_info(tprint("  W6 soak       : result=% （样本=% 首帧内存=%B 末帧内存=%B）",
                    sample.soak_result, sample.soak_samples,
                    sample.soak_mem[0], sample.soak_mem[last_soak]));
    log_info(tprint("  memory        : linear=% B", sample_memory_bytes()));
    log_info(tprint("  target cache  : targets=% texture_fbos=% targets_built=% resolves=% incomplete=% 资源(TEX/BUF/TARGET)=%/%/%",
                    sample_gpu_stat(3), sample_gpu_stat(4), sample_gpu_stat(5), sample_gpu_stat(6),
                    sample_gpu_stat(7), sample_gpu_stat(13), sample_gpu_stat(14), sample_gpu_stat(21)));

    log_info(tprint("  frames drawn  : %", sample.frames_drawn));

    sample_storage_roundtrip();
    sample_clipboard_roundtrip();

    log_info("=====================================");
}

// --------------------------------------------------------------- 存档闭环
sample_storage_roundtrip :: () {
    if sample.store == null {
        log_warning("sample: 没有存档容器，跳过存档检验");
        return;
    }

    frame := sample.updates;
    payload := tprint("jfoster wasm save @ update % elapsed %s",
                      frame, sample.elapsed);

    wrote := storage_write_all_text(sample.store, "t2_roundtrip.txt", payload);
    if !wrote {
        log_warning("sample: 存档写入失败（宿主没有存储后端？）");
        return;
    }

    read_back := storage_read_all_text(sample.store, "t2_roundtrip.txt");
    exists := storage_file_exists(sample.store, "t2_roundtrip.txt");
    entries := storage_enumerate(sample.store, "", "*", false);

    sample.storage_ok = exists && read_back == payload;

    log_info(tprint("  storage write : '%' -> % 字节, ok=%", "t2_roundtrip.txt", payload.count, wrote));
    log_info(tprint("  storage read  : % 字节, 往返一致=%", read_back.count, sample.storage_ok));
    log_info(tprint("  storage list  : count=%", entries.count));

    // 顺带删掉，免得每次刷新都堆一个键（也证明 remove 通了）
    if frame > REPORT_EVERY_N_FRAMES {
        deleted := storage_remove(sample.store, "t2_roundtrip.txt");
        log_info(tprint("  storage remove: %", deleted));
    }
}

sample_clipboard_roundtrip :: () {
    text := tprint("jfoster-wasm-clipboard-%", sample.updates);
    input_clipboard_set(App.input, text);
    got := input_clipboard_get(App.input);
    sample.clipboard_ok = got == text;
    log_info(tprint("  clipboard     : set/get 一致=% （'%'）", sample.clipboard_ok, got));
}

#load "target_orientation.jai";
