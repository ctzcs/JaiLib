#scope_module
using Basic;
using Math;
using Hash_Table;
#scope_module

// jfoster — WebGL2 侧的枚举翻译、句柄缓存与绘制状态（W3）。
//
// ===========================================================================
// 这个文件在分层里的位置
// ===========================================================================
// 三层的分工，和 SDL_GPU 后端一一对应：
//
//   graphics/graphics_device.jai          公开校验层（两端共用，W1 起一字未改）
//   internal/web/graphics_device_web.jai  后端：把 Draw_Command 翻成一串命令
//   internal/web/web_gl.jai               **本文件**：jfoster 枚举 → GL 常量、
//                                         program/pipeline/sampler 的句柄缓存
//   web_bridge.jai 的 gl_*                哑通道：参数只有标量和内存偏移
//   tests/wasm/host.js 的 makeGl()      真正调用 WebGL2 的那一层
//
// **枚举翻译放在 Jai 侧**不是为了好看：桌面后端的 sdl_get_blend_state /
// sdl_get_vertex_format / sdl_get_sampler 同样在 Jai 侧做这件事，两边只有一份
// 「jfoster 语义」，host.js 里没有一行 jfoster 的知识。这样 W4/W5 把状态矩阵补齐
// 时，改动落在可以被 `jaic -check` 抓住的地方，而不是 JS 里。
//
// ===========================================================================
// 句柄模型
// ===========================================================================
// JS 侧一张数组 `objects[id]`（1 起，0 = 无效），Jai 侧把这个 id 塞进
// GPU_Resource 现有的指针字段：
//
//     res.texture = cast(*SDL_GPUTexture) cast(*void) gl_texture_id;
//
// 于是 `sdl_*` 的函数签名、GPU_Resource 的字段、graphics_device.jai 的校验
// 全部不用改（README §7.2 第 1 条说的就是这件事）。指针字段里放整数只在
// 本文件与 graphics_device_web.jai 里出现，且永远经过 web_gl_id() 提取。
//
// 为什么不用真指针：WebGL2 的「对象名」是 GLuint，但一次 createProgram 会长出
// program + VAO 两份状态，deleteShader 之后 program 还活着……这些都是 JS 侧
// 的生命周期，Jai 侧只需要一个稳定的整数。用表下标（而不是 WebGL 的 GLuint）
// 也让 JS 侧能把「属性布局」「uniform 位置缓存」挂在同一个 id 上。
//
// ===========================================================================
// 每个 Draw_Command 变成什么
// ===========================================================================
// 完整映射表见 internal/web/README.md §8.6。要点：
//   * pipeline 只吃 program + 顶点布局（VAO）；blend/cull/depth/stencil/scissor
//     是**每次 draw 重设的状态**，因为 WebGL2 没有状态对象。桌面把它们塞进
//     SDL_GPUGraphicsPipeline，web 侧拆成 gl_set_*。
//   * uniform 按**槽位**定位：槽位就是 std140 uniform block 的 binding point
//     （见下面「uniform 槽位 → std140 block 的 binding point」）。W3 曾经按名字
//     硬编码三个默认 program，W4 起那条路没有了。

// ---------------------------------------------------------------------------
// GL 常量
// ---------------------------------------------------------------------------
// 只有后端用得到的那些。数值来自 Khronos 的 GL 头文件（WebGL2 == GL ES 3.0），
// 和 host.js 里写死的那些**不是同一份**：host.js 只定义它内部要用的（比如
// ATTACHMENT 相关），跨语言传的枚举一律由这里翻好再传下去。

// buffer target / usage
GL_ARRAY_BUFFER :: 0x8892;
GL_ELEMENT_ARRAY_BUFFER :: 0x8893;

// primitive
GL_TRIANGLES :: 0x0004;

// data types
GL_BYTE :: 0x1400;
GL_UNSIGNED_BYTE :: 0x1401;
GL_SHORT :: 0x1402;
GL_UNSIGNED_SHORT :: 0x1403;
GL_INT :: 0x1404;
GL_UNSIGNED_INT :: 0x1405;
GL_FLOAT :: 0x1406;
GL_HALF_FLOAT :: 0x140B;

// shader stages
GL_VERTEX_SHADER :: 0x8B31;
GL_FRAGMENT_SHADER :: 0x8B30;

// filters / wrap
GL_NEAREST :: 0x2600;
GL_LINEAR :: 0x2601;
GL_REPEAT :: 0x2901;
GL_CLAMP_TO_EDGE :: 0x812F;
GL_MIRRORED_REPEAT :: 0x8370;

// blend factors
GL_ZERO :: 0;
GL_ONE :: 1;
GL_SRC_COLOR :: 0x0300;
GL_ONE_MINUS_SRC_COLOR :: 0x0301;
GL_SRC_ALPHA :: 0x0302;
GL_ONE_MINUS_SRC_ALPHA :: 0x0303;
GL_DST_ALPHA :: 0x0304;
GL_ONE_MINUS_DST_ALPHA :: 0x0305;
GL_DST_COLOR :: 0x0306;
GL_ONE_MINUS_DST_COLOR :: 0x0307;
GL_SRC_ALPHA_SATURATE :: 0x0308;
GL_CONSTANT_COLOR :: 0x8001;
GL_ONE_MINUS_CONSTANT_COLOR :: 0x8002;

// blend ops
GL_FUNC_ADD :: 0x8006;
GL_FUNC_SUBTRACT :: 0x800A;
GL_FUNC_REVERSE_SUBTRACT :: 0x800B;
GL_MIN :: 0x8007;
GL_MAX :: 0x8008;

// depth / stencil compare
GL_NEVER :: 0x0200;
GL_LESS :: 0x0201;
GL_EQUAL :: 0x0202;
GL_LEQUAL :: 0x0203;
GL_GREATER :: 0x0204;
GL_NOTEQUAL :: 0x0205;
GL_GEQUAL :: 0x0206;
GL_ALWAYS :: 0x0207;

// stencil ops（GL_ZERO 上面已经有了，值相同）
GL_KEEP :: 0x1E00;
GL_REPLACE :: 0x1E01;
GL_INCR :: 0x1E02;
GL_DECR :: 0x1E03;
GL_INVERT :: 0x150A;
GL_INCR_WRAP :: 0x8507;
GL_DECR_WRAP :: 0x8508;

// cull face
GL_FRONT :: 0x0404;
GL_BACK :: 0x0405;

// clear bits
GL_DEPTH_BUFFER_BIT :: 0x0100;
GL_STENCIL_BUFFER_BIT :: 0x0400;
GL_COLOR_BUFFER_BIT :: 0x4000;

// sized internal formats（texStorage2D 要的是这些，不是 GL_RGBA 那种组合式）
GL_R8 :: 0x8229;
GL_RG8 :: 0x822B;
GL_RGB8 :: 0x8051; // [W6] 窗口级 MSAA 的 renderbuffer 用它，见 web_gl_window_msaa_ensure
GL_RGBA8 :: 0x8058;
GL_SRGB8_ALPHA8 :: 0x8C43;
GL_R16F :: 0x822D;
GL_RG16F :: 0x822F;
GL_RGBA16F :: 0x881A;
GL_RGBA32F :: 0x8814;
GL_DEPTH_COMPONENT16 :: 0x81A5;
GL_DEPTH_COMPONENT24 :: 0x81A6;
GL_DEPTH_COMPONENT32F :: 0x8CAC;
GL_DEPTH24_STENCIL8 :: 0x88F0;
GL_DEPTH32F_STENCIL8 :: 0x8CAD;

// 上传/读回时用的「数据格式」
GL_RED :: 0x1903;
GL_RG :: 0x8227;
GL_RGBA :: 0x1908;
GL_BGRA :: 0x80E1;
GL_DEPTH_COMPONENT :: 0x1902;
GL_DEPTH_STENCIL :: 0x84F9;
GL_UNSIGNED_INT_24_8 :: 0x84FA;
GL_FLOAT_32_UNSIGNED_INT_24_8_REV :: 0x8DAD;

// framebuffer / 附件点（W5）
//
// COLOR_ATTACHMENTi 是**连续**的（0x8CE0 + i），所以第 i 个颜色附件的点用加法算；
// 深度与深度模板是分开的两个点，挂错了 checkFramebufferStatus 会直接说
// FRAMEBUFFER_INCOMPLETE_ATTACHMENT。
GL_COLOR_ATTACHMENT0 :: 0x8CE0;
GL_DEPTH_ATTACHMENT :: 0x8D00;
GL_STENCIL_ATTACHMENT :: 0x8D20;
GL_DEPTH_STENCIL_ATTACHMENT :: 0x821A;

GL_FRAMEBUFFER_COMPLETE :: 0x8CD5;
GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT :: 0x8CD6;
GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT :: 0x8CD7;
GL_FRAMEBUFFER_UNSUPPORTED :: 0x8CDD;
GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE :: 0x8D56;

// glBlitFramebuffer 的 mask 位（和 GL 的 COLOR/DEPTH/STENCIL_BUFFER_BIT 不是同一
// 组数值：那三个在 Jai 侧是 0x4000/0x0100/0x0400，用来做 glClear；blit 的 mask 是
// 我们自己定义的三位，host.js 翻成 GL 的位）。见 host.js :: BLIT_COLOR。
WEB_BLIT_COLOR :: 1;
WEB_BLIT_DEPTH :: 2;
WEB_BLIT_STENCIL :: 4;

// GLSL 那边声明的 sampler 名字（三个默认 program 都一样，见 §8.6）
WEB_SAMPLER_UNIFORM_NAME :: "Texture";

//
// 枚举翻译
//

web_gl_blend_factor :: (factor: Blend_Factor) -> s32 {
    if factor == {
        case .ZERO; return GL_ZERO;
        case .ONE; return GL_ONE;
        case .SRC_COLOR; return GL_SRC_COLOR;
        case .ONE_MINUS_SRC_COLOR; return GL_ONE_MINUS_SRC_COLOR;
        case .DST_COLOR; return GL_DST_COLOR;
        case .ONE_MINUS_DST_COLOR; return GL_ONE_MINUS_DST_COLOR;
        case .SRC_ALPHA; return GL_SRC_ALPHA;
        case .ONE_MINUS_SRC_ALPHA; return GL_ONE_MINUS_SRC_ALPHA;
        case .DST_ALPHA; return GL_DST_ALPHA;
        case .ONE_MINUS_DST_ALPHA; return GL_ONE_MINUS_DST_ALPHA;
        case .CONSTANT_COLOR; return GL_CONSTANT_COLOR;
        case .ONE_MINUS_CONSTANT_COLOR; return GL_ONE_MINUS_CONSTANT_COLOR;
        case .SRC_ALPHA_SATURATE; return GL_SRC_ALPHA_SATURATE;
    }
    return GL_ONE;
}

web_gl_blend_op :: (op: Blend_Op) -> s32 {
    if op == {
        case .ADD; return GL_FUNC_ADD;
        case .SUBTRACT; return GL_FUNC_SUBTRACT;
        case .REVERSE_SUBTRACT; return GL_FUNC_REVERSE_SUBTRACT;
        case .MIN; return GL_MIN;
        case .MAX; return GL_MAX;
    }
    return GL_FUNC_ADD;
}

// Blend_Mask → glColorMask 的四个 bool。返回值用位打包：bit0 R, bit1 G, bit2 B, bit3 A。
web_gl_blend_mask_bits :: (mask: Blend_Mask) -> s32 {
    bits: s32 = 0;
    if (mask & .RED) != 0 bits |= 1;
    if (mask & .GREEN) != 0 bits |= 2;
    if (mask & .BLUE) != 0 bits |= 4;
    if (mask & .ALPHA) != 0 bits |= 8;
    return bits;
}

web_gl_compare :: (op: Depth_Compare) -> s32 {
    if op == {
        case .ALWAYS; return GL_ALWAYS;
        case .NEVER; return GL_NEVER;
        case .LESS; return GL_LESS;
        case .EQUAL; return GL_EQUAL;
        case .LESS_OR_EQUAL; return GL_LEQUAL;
        case .GREATER; return GL_GREATER;
        case .NOT_EQUAL; return GL_NOTEQUAL;
        case .GREATER_OR_EQUAL; return GL_GEQUAL;
    }
    return GL_ALWAYS;
}

web_gl_stencil_op :: (op: Stencil_Op) -> s32 {
    if op == {
        case .INVALID; return GL_KEEP;
        case .KEEP; return GL_KEEP;
        case .ZERO; return GL_ZERO;
        case .REPLACE; return GL_REPLACE;
        case .INCREMENT_AND_CLAMP; return GL_INCR;
        case .DECREMENT_AND_CLAMP; return GL_DECR;
        case .INVERT; return GL_INVERT;
        case .INCREMENT_AND_WRAP; return GL_INCR_WRAP;
        case .DECREMENT_AND_WRAP; return GL_DECR_WRAP;
    }
    return GL_KEEP;
}

// 0 = 不剔除（glDisable(CULL_FACE)），否则 GL_FRONT / GL_BACK。
web_gl_cull :: (mode: Cull_Mode) -> s32 {
    if mode == {
        case .NONE; return 0;
        case .FRONT; return GL_FRONT;
        case .BACK; return GL_BACK;
    }
    return 0;
}

web_gl_filter :: (filter: Texture_Filter) -> s32 {
    if filter == .NEAREST return GL_NEAREST;
    return GL_LINEAR;
}

web_gl_wrap :: (wrap: Texture_Wrap) -> s32 {
    if wrap == {
        case .REPEAT; return GL_REPEAT;
        case .MIRRORED_REPEAT; return GL_MIRRORED_REPEAT;
        case .CLAMP; return GL_CLAMP_TO_EDGE;
    }
    return GL_REPEAT;
}

web_gl_index_type :: (format: Index_Format) -> s32 {
    if format == .SIXTEEN return GL_UNSIGNED_SHORT;
    return GL_UNSIGNED_INT;
}

// 纹理格式三分量：texStorage2D 的 internalformat、texSubImage2D 的 format 和 type。
//
// ===========================================================================
// 格式矩阵（W5：这张表是唯一的一张，不再有「兜底成 RGBA8」）
// ===========================================================================
// jfoster 的 Texture_Format 一共 8 个值（graphics/enums.jai），WebGL2 全都支持，
// 但每一行的 internal / upload / readback 三元组都不一样，写错了不会报错、只会
// 出错误的像素（R8 用 RGBA 读回 ⇒ INVALID_OPERATION；深度用 RGBA 读回 ⇒ 同样）。
//
//   jfoster       texStorage2D internal       texSubImage2D (format,type)   渲染目标
//   ------------  --------------------------  ----------------------------   --------
//   R8G8B8A8      GL_RGBA8            0x8058   RGBA / UNSIGNED_BYTE          颜色
//   R8            GL_R8               0x8229   RED  / UNSIGNED_BYTE          颜色
//   R8G8          GL_RG8              0x822B   RG   / UNSIGNED_BYTE          颜色
//   DEPTH16       GL_DEPTH_COMPONENT16  0x81A5 DEPTH_COMPONENT / USHORT      深度
//   DEPTH24       GL_DEPTH_COMPONENT24  0x81A6 DEPTH_COMPONENT / UINT        深度
//   DEPTH32       GL_DEPTH_COMPONENT32F 0x8CAC DEPTH_COMPONENT / FLOAT       深度
//   DEPTH24STENCIL8  GL_DEPTH24_STENCIL8 0x88F0 DEPTH_STENCIL / UINT_24_8    深度+模板
//   DEPTH32STENCIL8  GL_DEPTH32F_STENCIL8 0x8CAD DEPTH_STENCIL / FLOAT_32_... 深度+模板
//
// **不在表里 = 明确失败**：返回值 known=false，调用方（sdl_create_texture）打一条
// log_error 并且**不建纹理**。W3 那版是「悄悄用 RGBA8 建一张」，那会让一个未来
// 加进枚举的 BC7 静默变成一张空白的 RGBA 纹理 —— 这是最糟的一种降级。
//
// 任务清单里提到的 BGRA8 / RGBA16F 为什么不在 jfoster 这侧：
//   * BGRA8 —— WebGL2 **没有** BGRA8 的 sized internal format（BGRA 只是
//     EXT_texture_format_BGRA8888 给的上传格式），所以它当不了纹理存储/渲染目标。
//     SDL 那边有 SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM，于是 web_gl_sdl_internal_format
//     对它返回 0（= 不支持），SDL_GPUTextureSupportsFormat 据此诚实报 false。
//   * RGBA16F —— WebGL2 核心支持 GL_RGBA16F（0x881A），但**渲染**到它要
//     EXT_color_buffer_float。表里留着它（host.js 的 gl_get_param(11) 报扩展在不在），
//     只是 jfoster 的 Texture_Format 还没有浮点值，所以从公开 API 走不到 ——
//     web_gl_sdl_internal_format 里能查到，作为「将来加枚举时照抄」的现成一行。
web_gl_texture_formats :: (format: Texture_Format) -> (internal_format: s32, data_format: s32, data_type: s32, known: bool) {
    if format == {
        case .R8G8B8A8; return GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, true;
        case .R8; return GL_R8, GL_RED, GL_UNSIGNED_BYTE, true;
        case .R8G8; return GL_RG8, GL_RG, GL_UNSIGNED_BYTE, true;
        case .DEPTH16; return GL_DEPTH_COMPONENT16, GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, true;
        case .DEPTH24; return GL_DEPTH_COMPONENT24, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, true;
        case .DEPTH32; return GL_DEPTH_COMPONENT32F, GL_DEPTH_COMPONENT, GL_FLOAT, true;
        case .DEPTH24STENCIL8; return GL_DEPTH24_STENCIL8, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, true;
        case .DEPTH32STENCIL8; return GL_DEPTH32F_STENCIL8, GL_DEPTH_STENCIL, GL_FLOAT_32_UNSIGNED_INT_24_8_REV, true;
    }
    return 0, 0, 0, false; // 明确「没有对应」，不是 0x8058
}

// 这张 jfoster 格式能不能当渲染目标？8 个全都是 renderable：
//   R8/RG8/RGBA8 是 ES 3.0 的 required color-renderable 格式；
//   四个深度/深度模板是 required depth-renderable 格式。
// 单列一个函数是为了让 sdl_create_texture 的拒绝理由具体（「格式不认识」和
// 「这个格式只能采样、不能画」是两种错误）。
web_gl_texture_format_renderable :: (format: Texture_Format) -> bool {
    internal, _, _, known := web_gl_texture_formats(format);
    return known && internal != 0;
}

// SDL_GPUTextureFormat → texStorage2D 的 sized internal format。0 = WebGL2 里没有。
//
// 这张表比上面那张宽，因为 SDL 的枚举宽：它要能回答 SDL_GPUTextureSupportsFormat
// 对**任意** SDL 格式的询问（那是个 bool，不是「帮我建一张」）。凡是这里返回 0
// 的，SupportsFormat 一律 false —— 包括 B8G8R8A8（见上面格式矩阵的说明）。
//
// RGBA16F/R16F/RG16F/RGBA32F 只在 EXT_color_buffer_float 下才能当渲染目标；
// 采样它们是核心功能。所以这三个在「能不能创建」这一层是 true，在
// 「能不能当 target 附件」这一层由 web_gl_sdl_format_renderable 再问一次扩展。
web_gl_sdl_internal_format :: (format: SDL_GPUTextureFormat) -> s32 {
    if format == {
        case .SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM; return GL_RGBA8;
        case .SDL_GPU_TEXTUREFORMAT_R8_UNORM; return GL_R8;
        case .SDL_GPU_TEXTUREFORMAT_R8G8_UNORM; return GL_RG8;
        case .SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT; return GL_RGBA16F;
        case .SDL_GPU_TEXTUREFORMAT_R16_FLOAT; return GL_R16F;
        case .SDL_GPU_TEXTUREFORMAT_R16G16_FLOAT; return GL_RG16F;
        case .SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT; return GL_RGBA32F;
        case .SDL_GPU_TEXTUREFORMAT_D16_UNORM; return GL_DEPTH_COMPONENT16;
        case .SDL_GPU_TEXTUREFORMAT_D24_UNORM; return GL_DEPTH_COMPONENT24;
        case .SDL_GPU_TEXTUREFORMAT_D32_FLOAT; return GL_DEPTH_COMPONENT32F;
        case .SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT; return GL_DEPTH24_STENCIL8;
        case .SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT; return GL_DEPTH32F_STENCIL8;
    }
    // 明确不支持的那一类，逐条写出来，免得以后有人以为是漏了：
    //   B8G8R8A8_UNORM / _SRGB  —— WebGL2 没有 BGRA8 的 sized internal format
    //   BC*_RGBA_UNORM / ASTC*   —— 要扩展（且 jfoster 不压缩上传）
    //   R16/R16G16/R16G16B16A16_UNORM/S*、R10G10B10A2、B5G6R5…、UINT/INT  —— 没有对应
    return 0;
}

// 「这张 SDL 格式能不能当渲染目标」——多重采样 / renderbuffer 也走这个判断，
// 因为 renderbufferStorageMultisample 的 internalformat 必须是 color-renderable。
web_gl_sdl_format_renderable :: (format: SDL_GPUTextureFormat) -> bool {
    internal := web_gl_sdl_internal_format(format);
    if internal == 0 return false;
    if internal == GL_RGBA16F || internal == GL_R16F || internal == GL_RG16F || internal == GL_RGBA32F {
        // 浮点渲染要扩展；没有扩展时 renderbufferStorage 会直接 INVALID_ENUM/OPERATION。
        return web_gpu.float_renderable;
    }
    return true;
}

// 深度/模板侧：它决定挂哪个附件点（DEPTH_ATTACHMENT vs DEPTH_STENCIL_ATTACHMENT）。
web_gl_sdl_format_is_depth :: (format: SDL_GPUTextureFormat) -> bool {
    return format == .SDL_GPU_TEXTUREFORMAT_D16_UNORM ||
           format == .SDL_GPU_TEXTUREFORMAT_D24_UNORM ||
           format == .SDL_GPU_TEXTUREFORMAT_D32_FLOAT ||
           format == .SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT ||
           format == .SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
}

web_gl_sdl_format_has_stencil :: (format: SDL_GPUTextureFormat) -> bool {
    return format == .SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT ||
           format == .SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
}

// SDL_GPUSampleCount → 数值（1/2/4/8）。renderbufferStorageMultisample 要的是数。
web_gl_sdl_sample_count :: (count: SDL_GPUSampleCount) -> s32 {
    if count == {
        case .SDL_GPU_SAMPLECOUNT_1; return 1;
        case .SDL_GPU_SAMPLECOUNT_2; return 2;
        case .SDL_GPU_SAMPLECOUNT_4; return 4;
        case .SDL_GPU_SAMPLECOUNT_8; return 8;
    }
    return 1;
}

// 十六进制格式化（Jai 的 tprint 只认 `%` 占位符，没有 printf 的 `%x`）。
//
// 返回的是**指向静态缓冲区**的视图：不分配，也不能跨下一次调用保存 —— 只给
// 「FBO 状态 0x8CD6」这类日志用，和 web_gl_string 一样的约定。
WEB_GL_HEX_BUFFER_SIZE :: 16;
web_gl_hex_buffer: [WEB_GL_HEX_BUFFER_SIZE] u8;

web_gl_hex :: (value: s32) -> string {
    digits :: "0123456789ABCDEF";
    v := cast(u32) value;

    n: s32 = 0;
    web_gl_hex_buffer[n] = #char "0";
    n += 1;
    web_gl_hex_buffer[n] = #char "x";
    n += 1;

    // 数一下有几个 nibble，从最高位开始写（0 就写一个 "0"）。
    nibbles: s32 = 0;
    t := v;
    while t != 0 {
        nibbles += 1;
        t >>= 4;
    }
    if nibbles == 0 {
        web_gl_hex_buffer[n] = #char "0";
        n += 1;
    } else {
        i: s32 = nibbles - 1;
        while i >= 0 {
            shift := cast(u32) (i * 4);
            web_gl_hex_buffer[n] = digits[(v >> shift) & 15];
            n += 1;
            i -= 1;
        }
    }
    return web_str_of(*web_gl_hex_buffer[0], n);
}

// Vertex_Type → vertexAttribPointer 的 (type, size)。size 是分量个数。
web_gl_vertex_type :: (type: Vertex_Type) -> (gl_type: s32, components: s32) {
    if type == {
        case .FLOAT; return GL_FLOAT, 1;
        case .FLOAT2; return GL_FLOAT, 2;
        case .FLOAT3; return GL_FLOAT, 3;
        case .FLOAT4; return GL_FLOAT, 4;
        case .BYTE4; return GL_BYTE, 4;
        case .UBYTE4; return GL_UNSIGNED_BYTE, 4;
        case .SHORT2; return GL_SHORT, 2;
        case .USHORT2; return GL_UNSIGNED_SHORT, 2;
        case .SHORT4; return GL_SHORT, 4;
        case .USHORT4; return GL_UNSIGNED_SHORT, 4;
        case .NONE; return 0, 0;
    }
    return 0, 0;
}

//
// uniform 槽位 → std140 block 的 binding point（W4）
//
// ===========================================================================
// 为什么不再需要名字
// ===========================================================================
// SDL_GPU 用**槽位编号**寻址 uniform buffer（HLSL 的 register(bN, spaceM)）。
// WebGL2 用 **binding point**：GLSL 里写 `layout(std140) uniform SomeBlock { ... }`，
// 程序链接后用 gl.uniformBlockBinding(program, blockIndex, binding) 把某个 block
// 钉到一个 binding 号上，再用 gl.bindBufferBase(UNIFORM_BUFFER, binding, ubo) 提供
// 数据。于是「槽位就是 binding 号」，一条名字都不用查 —— 这正是 W3 剩下的那个
// 限制的解法（README §8.6 末尾说的「改成 std140 UBO 更省事」）。
//
//   Draw_Command.VertexUniformBuffers[slot]    →  binding  slot            (0..7)
//   Draw_Command.FragmentUniformBuffers[slot]  →  binding  8 + slot        (8..15)
//
// 为什么片元要偏移 8：binding point 是**整个 context 一个扁平命名空间**（不像
// SDL_GPU 那样顶点/片元各一套槽位），偏移量就是 MAX_UNIFORM_BUFFERS，两个 stage
// 的 slot 0 才不会撞在同一个 binding 上。GL ES 3.0 至少保证
// MAX_UNIFORM_BUFFER_BINDINGS >= 24 > 16，所以 0..15 永远够用。
//
// 谁来认 block 属于哪个 stage / 第几个槽位：**JS 侧链接后自己查**
// （host.js :: bindUniformBlocks，用 UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER /
// _FRAGMENT_SHADER + 该 stage 内的声明顺序），画完日志里能看见
// `vertex slot 0 -> binding 0 (JfosterVertexUniforms, 64B)`。Jai 侧只认 binding 号。
//
// std140 的布局必须和桌面推的字节一致（这是「逐字节同源」的另一半）：
//   * `mat4 Matrix`   → 64 B，偏移 0  == jfoster Matrix4 的裸字节（见 shaders/
//                        batcher.vertex.glsl 里关于 transpose 的长注释）
//   * `float DistanceRange` → 偏移 0，block 被补齐到 16 B == sprite_font 推的
//                        [4] float32
// 所以后端做的事只有一件：把 uniform_buffer_get() 那一段字节原样 bufferSubData。
//

WEB_UNIFORM_FRAGMENT_BASE :: 8; // == MAX_UNIFORM_BUFFERS（graphics/draw_command.jai）
WEB_MAX_UNIFORM_BINDINGS :: 16; // vertex 0..7 + fragment 8..15

web_gl_uniform_binding_point :: (stage: Shader_Stage, slot: s32) -> s32 {
    if slot < 0 || slot >= MAX_UNIFORM_BUFFERS return -1;
    if stage == .VERTEX return slot;
    if stage == .FRAGMENT return WEB_UNIFORM_FRAGMENT_BASE + slot;
    return -1; // 计算阶段没有 uniform block 这条路
}

// 采样器仍然按名字取：GLSL ES 3.00 不允许 opaque 类型（sampler2D）出现在
// uniform block 里，所以它是唯一需要名字的东西。约定（写进 README §8.6）：
// 槽 0 叫 Texture，槽 i > 0 叫 Texture<i>。三个默认 program 都只有槽 0。
//
// 这里返回的是指向**静态缓存**的 string（第二次起不再分配），调用方只把它交给
// gl_* 的 (ptr, len)，不会跨帧保存。
web_sampler_names: [MAX_BOUND_SAMPLERS] string;

web_gl_sampler_name :: (slot: s32) -> string {
    if slot < 0 || slot >= MAX_BOUND_SAMPLERS return "";
    if slot == 0 return WEB_SAMPLER_UNIFORM_NAME;
    if web_sampler_names[slot].count <= 0 {
        web_sampler_names[slot] = tprint("%%", WEB_SAMPLER_UNIFORM_NAME, slot);
    }
    return web_sampler_names[slot];
}

// 名字 → 变体（只在「调用方塞进来的不是 GLSL 文本」时兜底用；表本身在
// web_shader_source.jai 的 web_shader_variant_of_name —— graphics/
// default_resource_data.jai 的 wasm 分支也要用它）。
web_gl_stage_of :: (stage: Shader_Stage) -> (gl_stage: s32, web_stage: Web_Shader_Stage, found: bool) {
    if stage == .VERTEX return GL_VERTEX_SHADER, .VERTEX, true;
    if stage == .FRAGMENT return GL_FRAGMENT_SHADER, .FRAGMENT, true;
    return 0, .VERTEX, false; // .COMPUTE：WebGL2 没有 compute stage
}

//
// 句柄 ↔ 整数
//
// GPU_Resource 的指针字段里存的是 JS 侧对象表的下标。这两个函数是所有
// cast 的唯一出入口——别在别处直接转。
//

web_gl_id :: (ptr: *void) -> s32 {
    return cast(s32) cast(u64) ptr;
}

web_gl_ptr :: (id: s32) -> *void {
    if id <= 0 return null;
    return cast(*void) id;
}

//
// 设备级状态
//
// 浏览器里一个页面只有一个 canvas、一个 WebGL2 context，所以这份状态是全局量，
// 而不是挂在 Graphics_Device 上（Graphics_Device 是与桌面共用的结构，W1 之后
// 它一个字段都没动，也不该为 web 加字段）。
//

WEB_MAX_ATTRIBUTES :: 64; // 和桌面 sdl_get_graphics_pipeline 的 vertex_attributes[64] 一致

// 一个已链接 program 的缓存条目。句柄是 fw 的 GPU_Resource.handle（不是 GL 名字）：
// 它们就是键的原料，也是 shader 销毁时找出「哪些 program 属于它」的依据。
// A hash chooses a bucket; it must not replace the shader pair's identity.
Web_Program_Key :: struct {
    vs: Graphics_Resource_Handle;
    fs: Graphics_Resource_Handle;
}

web_gl_program_key_hash :: (key: Web_Program_Key) -> u32 {
    return cast(u32) web_gl_hash_combine(web_gl_hash_mix(key.vs), key.fs);
}

web_gl_program_key_equal :: (a: Web_Program_Key, b: Web_Program_Key) -> bool {
    return a.vs == b.vs && a.fs == b.fs;
}

Web_Program_Entry :: struct {
    id: s32; // JS 侧 program 对象 id
    vs: Graphics_Resource_Handle;
    fs: Graphics_Resource_Handle;
}

// Render targets keep private GL-oriented attachments and public textures whose
// V=0 row is the logical top, matching CPU uploads and the desktop API.
// 1x:   private texture -> flipped public texture.
// MSAA: renderbuffer -> same-bounds private texture -> flipped public texture.
// Each surface has single-attachment FBO views, so resolve/copy selects exactly
// that color or depth/stencil attachment. Entry.fbo/ms_fbo are the draw FBOs.
Web_Target_Surface :: struct {
    texture: s32;
    fbo: s32;
    ms_fbo: s32;
    sampled_fbo: s32;
    public_texture: s32;
    mask: s32;
}

Web_Target_Entry :: struct {
    fbo: s32; // private render-oriented textures (also MSAA resolve storage)
    ms_fbo: s32; // 多重采样 FBO；0 = 不是 MSAA
    width: s32;
    height: s32;
    sample_count: s32; // 1 = 单采样
    color_count: s32;
    has_depth: bool;
    resolve_depth: bool; // MSAA + 有深度附件：解析时要带 DEPTH bit
    resolve_stencil: bool;
    surfaces: [..] Web_Target_Surface;
    renderbuffers: [..] s32; // 建过的 renderbuffer（销毁时一起删）
    built: bool;
    complete: bool; // false = 建过但 FBO 不完整，后续 pass 直接失败
    warned: bool; // FBO 不完整的日志只打一次
}

// [W6] 窗口级 MSAA。桌面是「把整帧画到一张超采样的离屏 backbuffer，present 时
// blit 到 swapchain」；web 上窗口就是 canvas，等价物是「建一张窗口大小的 MS FBO，
// 每帧画它，end pass 时 blitFramebuffer 到 0 号 FBO」。
//
// 颜色附件为什么是 **RGB8** 而不是 RGBA8：WebGL 在 `alpha:false` 下默认
// framebuffer 的真实存储是 RGB8，而 ES 3.0 的 blitFramebuffer 对多重采样解析要求
// 两端 internalformat **完全一致** —— RGBA8 → RGB8 实测直接 INVALID_OPERATION
// （0x502，见 .test_tmp/probe_ms 的探针）。RGB8 → RGB8 通过。
//
// 深度/模板：canvas 的默认 framebuffer 带 depth+stencil（host.js 建 context 时
// 就是这么要的），所以 MS FBO 也必须挂一个 D24S8 renderbuffer，否则窗口上的
// 深度测试在 MSAA 打开后静默失效。深度**不解析**（blit 深度到默认 framebuffer
// 是非法的），也就是「每帧结束深度丢弃」—— 与桌面 swapchain 的行为一致。
Web_Window_MS :: struct {
    fbo: s32;
    color_rb: s32;
    depth_rb: s32;
    width: s32;
    height: s32;
    samples: s32;
    ready: bool;
    failed: bool; // 建过一次就失败 → 不再重试（每帧重试只会刷屏）
}

Web_GPU_State :: struct {
    device: s32; // JS 侧 device id；0 = 没有 WebGL2

    // 当前 render pass 指向的 framebuffer：0 = canvas 的默认 FBO。
    // 其余 pass 状态（目标/尺寸/已绑资源/视口/裁剪）放在 Graphics_Device 里，
    // 与桌面后端的字段一一对应 —— 见 graphics_device_web.jai 的 sdl_begin_render_pass。
    pass_fbo: s32;
    // [W5] 这个 pass 画在哪个 Target 上（0 = 窗口）。end_render_pass 要用它决定
    // 「要不要做 MSAA resolve」—— 桌面的等价物是 attachment 的 store_op = RESOLVE，
    // 由驱动在 end pass 时执行。
    pass_target: Graphics_Resource_Handle;
    // [W6] 这个 pass 画在**窗口**上（且窗口级 MSAA 生效）。窗口的 resolve 目标
    // 是 0 号 FBO（canvas），所以它没法用 pass_target 表达。
    pass_window: bool;

    // [W4] 「顶点缓冲 / 索引缓冲的绑定属于哪个 pipeline」。
    //
    // WebGL2 里 vertexAttribPointer 和 ELEMENT_ARRAY_BUFFER 都是 **VAO 状态**，
    // 而 VAO 属于 pipeline。所以「同一个 mesh 缓冲被两条不同的 pipeline 用」时，
    // 第二条 pipeline 的 VAO 必须**重新**设一遍指针 —— 桌面只需要看「槽位里是哪个
    // buffer」，因为那边的绑定是 command buffer 上的全局状态。
    //
    // 这两个字段就是补上的那一半 key：graphics_device_web.jai :: sdl_perform_draw
    // 用 (pipeline, buffer) 而不是 (buffer) 来决定是否重绑。W3 单 pipeline 时永远
    // 命中不了这个分支，W4 的 Batcher（同一块 mesh 既走 Batcher program 又走 Msdf
    // program）第一次就撞上了 GL_INVALID_OPERATION "no buffer is bound to enabled
    // attribute"。
    vb_owner_pipeline: s32;
    ib_owner_pipeline: s32;

    // 缓存
    //
    // programs 存的是「键 + 拥有它的两个 shader 句柄」：句柄进键是为了让
    // hot-replace（ShaderPairTryReplace 换掉 shader 的 GPU 资源但保留 *Shader 的
    // 地址）自然产生新键；存下句柄是为了 shader 销毁时能精确回收旧 program
    // （见 web_gl_purge_programs_for）。
    programs: Table(Web_Program_Key, Web_Program_Entry, web_gl_program_key_hash, web_gl_program_key_equal);
    pipelines: Table(u64, s32); // key = 与桌面同构的大哈希（sdl_get_graphics_pipeline）
    samplers: Table(u32, s32); // key = texture_sampler_key

    // std140 uniform buffer：一个 binding point 一个 UBO，整块重传（W4）。
    // 下标就是 binding 号（web_gl_uniform_binding_point）。
    uniform_buffers: [WEB_MAX_UNIFORM_BINDINGS] s32;
    uniform_capacities: [WEB_MAX_UNIFORM_BINDINGS] s32;

    // [W5] render-to-target / MSAA
    //
    // 一个 TARGET 句柄 → 它那张 FBO 的缓存（懒建：attachment 是在 target 之后
    // 一个个 create_texture 出来的，所以 target_create 的时候还什么都不知道）。
    // 生命周期由 sdl_destroy_resource(.TARGET) → web_gl_target_release 收尾。
    targets: Table(u32, Web_Target_Entry);
    // 一张纹理 → 它的（单附件）FBO。blitFramebuffer 和 readPixels 都需要
    // 「一张纹理当作附件」的 FBO，而这两件事都很频繁（每帧的 MSAA resolve、
    // 每次读回），所以缓存而不是每次建。
    texture_fbos: Table(u32, s32);

    // 设备能力（gl_device_create 时问一次）
    float_renderable: bool; // EXT_color_buffer_float 在不在
    max_samples: s32; // gl_get_param(5)
    max_renderbuffer: s32; // gl_get_param(9)
    max_color_attachments: s32;
    max_texture_size: s32; // [W6] gl_get_param(2)：超过它的纹理创建要明确失败

    // [W6] 窗口级 MSAA（见 Web_Window_MS 的说明）
    window_msaa_wanted: bool; // graphics_device_web 的 sdl_device_create 打开
    window_msaa_samples: s32; // 期望的采样数（会被 MAX_SAMPLES 夹住）
    window_ms: Web_Window_MS;

    // gl_create_pipeline 的属性表缓冲：每个属性 8 个 s32
    // (slot, location, size, type, normalized, stride, offset, divisor)
    attr_scratch: [WEB_MAX_ATTRIBUTES * 8] s32;

    // 客观计数（fw_stats / 报告用）
    passes: s32;
    clears: s32;
    draws: s32;
    texture_uploads: s32;
    buffer_uploads: s32;
    shaders_compiled: s32;
    programs_linked: s32;
    programs_released: s32; // hot-replace / shader 销毁回收掉的旧 program
    pipelines_created: s32;
    uniform_uploads: s32; // 推了多少次 std140 block（每 draw 每槽一次）
    readbacks: s32;
    gl_errors: s32;
    draw_skips: s32;
    // [W5]
    targets_built: s32; // 建了几个 target FBO（含重建）
    target_incomplete: s32; // 多少次 checkFramebufferStatus 不是 COMPLETE
    target_resolves: s32; // 多少次 MSAA resolve（blitFramebuffer ms → resolve）
    msaa_targets: s32; // 采样数 > 1 的 target 数
    blits: s32; // sdl_blit_texture 成功的次数
    blit_failures: s32; // 被拒的次数（格式不匹配 / GL 报错）
    unsupported_formats: s32; // 「格式不认识」导致创建被拒的次数
    // [W6]
    texture_size_rejections: s32; // 超过 MAX_TEXTURE_SIZE 被拒的次数
    renderbuffer_size_rejections: s32; // 超过 MAX_RENDERBUFFER_SIZE 被拒的次数
    readback_refusals: s32; // 读回被明确拒绝的次数（格式不支持 / 深度）
    readback_unsupported_format: s32; // 其中「不是 RGBA8/R8/RG8」的那一类
    window_resolves: s32; // 窗口级 MSAA 的 resolve 次数
    window_msaa_rebuilt: s32; // 窗口 MS FBO 重建次数（尺寸变化）
    targets_invalidated: s32; // 因纹理销毁而作废的 target 数（W6 收窄后应远小于旧值）
    targets_kept: s32; // 纹理销毁时被**保住**的 target 数（W6 的证据）

    // 一次性日志的开关（避免每帧刷屏）
    warned_no_gl: bool;
    warned_no_shader: bool;
    warned_no_uniform: bool;
    warned_texture_data: bool;
    warned_target_draw: bool;
    warned_msaa: bool;
    warned_base_vertex: bool;
    warned_blit_format: bool; // blit 两边格式不同（ES 3.0 的 blitFramebuffer 要求相同）
    warned_depth_readback: bool; // 想读回深度纹理
    warned_msaa_supported: bool; // 采样数超过 MAX_SAMPLES
    warned_readback_format: bool; // [W6] 读回只支持 8 位 UNORM（RGBA8 / R8 / RG8）
    warned_window_msaa: bool; // [W6] 窗口级 MSAA 的降级说明只打一次
    warned_readback_refusal: bool; // [W6] 「这个格式不能读回」的 error 只打一次
}

web_gpu: Web_GPU_State;

web_gpu_reset :: () {
    web_gpu.device = 0;
    web_gpu.pass_fbo = 0;
    web_gpu.pass_target = 0;
    web_gpu.pass_window = false;
    web_gpu.window_msaa_wanted = false;
    web_gpu.window_msaa_samples = 1;
    web_gpu.window_ms.fbo = 0;
    web_gpu.window_ms.color_rb = 0;
    web_gpu.window_ms.depth_rb = 0;
    web_gpu.window_ms.width = 0;
    web_gpu.window_ms.height = 0;
    web_gpu.window_ms.samples = 1;
    web_gpu.window_ms.ready = false;
    web_gpu.window_ms.failed = false;
    web_gpu.max_texture_size = 0;
    web_gpu.vb_owner_pipeline = 0;
    web_gpu.ib_owner_pipeline = 0;
    table_reset(*web_gpu.programs);
    table_reset(*web_gpu.pipelines);
    table_reset(*web_gpu.samplers);
    for entry: web_gpu.targets {
        array_free(entry.surfaces);
        array_free(entry.renderbuffers);
    }
    table_reset(*web_gpu.targets);
    table_reset(*web_gpu.texture_fbos);
    for i: 0..WEB_MAX_UNIFORM_BINDINGS - 1 {
        web_gpu.uniform_buffers[i] = 0;
        web_gpu.uniform_capacities[i] = 0;
    }
    web_gpu.float_renderable = false;
    web_gpu.max_samples = 1;
    web_gpu.max_renderbuffer = 0;
    web_gpu.max_color_attachments = 1;
    web_gpu.warned_no_gl = false;
    web_gpu.warned_no_shader = false;
    web_gpu.warned_no_uniform = false;
    web_gpu.warned_texture_data = false;
    web_gpu.warned_target_draw = false;
    web_gpu.warned_msaa = false;
    web_gpu.warned_base_vertex = false;
    web_gpu.warned_blit_format = false;
    web_gpu.warned_depth_readback = false;
    web_gpu.warned_msaa_supported = false;
    web_gpu.warned_readback_format = false;
    web_gpu.warned_window_msaa = false;
    web_gpu.warned_readback_refusal = false;
    web_gpu.targets_built = 0;
    web_gpu.target_incomplete = 0;
    web_gpu.target_resolves = 0;
    web_gpu.msaa_targets = 0;
    web_gpu.blits = 0;
    web_gpu.blit_failures = 0;
    web_gpu.unsupported_formats = 0;
    web_gpu.texture_size_rejections = 0;
    web_gpu.renderbuffer_size_rejections = 0;
    web_gpu.readback_refusals = 0;
    web_gpu.readback_unsupported_format = 0;
    web_gpu.window_resolves = 0;
    web_gpu.window_msaa_rebuilt = 0;
    web_gpu.targets_invalidated = 0;
    web_gpu.targets_kept = 0;
}

// 把一段 UTF-8 交给 gl_*（它们只收内存偏移 + 长度）。
web_gl_str_off :: (s: string) -> s32 {
    if s.count <= 0 return 0;
    return web_str_off(s);
}

// bool → 0/1。`ifx b then 1 else 0` 的类型是 s64（Jai 对整数字面量 ifx 的推断），
// 直接塞进 s32 参数/数组会被 implicit-narrowing 抓住，所以统一走这里。
web_b32 :: (v: bool) -> s32 {
    if v return 1;
    return 0;
}

// string.count 是 s64，桥接口一律 s32 —— 用一个函数收口，免得每个调用点都写
// `cast(s32)`（漏一处就是 call-mismatch）。
web_gl_str_len :: (s: string) -> s32 {
    if s.count <= 0 return 0;
    return cast(s32) s.count;
}

// 任意 Jai 内存 → 桥接口要的 s32 偏移（wasm64 的指针是 8 字节，先转 u64 再截断；
// WASI preview1 的地址空间是 u32，见 README §4，所以截断是安全的）。
web_gl_off :: (ptr: *void) -> s32 {
    if ptr == null return 0;
    return cast(s32) cast(u64) ptr;
}

// SDL_GPUTextureFormat → texSubImage2D / readPixels 的 (format, type)。
// 和 web_gl_texture_formats 是同一张表的两个方向：创建时用 jfoster 的
// Texture_Format，上传时手上只剩 GPU_Resource.format（SDL 枚举，纹理创建后就
// 丢掉了原枚举），所以两个方向都得有。桌面那边不需要是因为驱动自己知道。
//
// 返回 (0, 0) = 这张 SDL 格式没有可用的上传/读回通道。调用方必须当成**失败**处理
// （W3 那版是「回落成 RGBA/UNSIGNED_BYTE」，对 R8 来说那会把 1 字节/像素的数据
// 当成 4 字节读完 —— 静默越界读，比失败糟糕得多）。
web_gl_sdl_data_format :: (format: SDL_GPUTextureFormat) -> (data_format: s32, data_type: s32) {
    if format == .SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM return GL_RGBA, GL_UNSIGNED_BYTE;
    if format == .SDL_GPU_TEXTUREFORMAT_R8_UNORM return GL_RED, GL_UNSIGNED_BYTE;
    if format == .SDL_GPU_TEXTUREFORMAT_R8G8_UNORM return GL_RG, GL_UNSIGNED_BYTE;
    if format == .SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT return GL_RGBA, GL_HALF_FLOAT;
    if format == .SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT return GL_RGBA, GL_FLOAT;
    if format == .SDL_GPU_TEXTUREFORMAT_D16_UNORM return GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT;
    if format == .SDL_GPU_TEXTUREFORMAT_D24_UNORM return GL_DEPTH_COMPONENT, GL_UNSIGNED_INT;
    if format == .SDL_GPU_TEXTUREFORMAT_D32_FLOAT return GL_DEPTH_COMPONENT, GL_FLOAT;
    if format == .SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT return GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8;
    if format == .SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT return GL_DEPTH_STENCIL, GL_FLOAT_32_UNSIGNED_INT_24_8_REV;
    return 0, 0;
}

// 读回时挂哪个附件点。深度/模板纹理挂 COLOR_ATTACHMENT0 会得到
// FRAMEBUFFER_INCOMPLETE_ATTACHMENT，所以「读哪张纹理」和「挂在哪里」是同一件事。
// 注意：WebGL2 的 readPixels **没有**读深度的合法组合（ES 3.0 只在 read buffer 为
// NONE 且 format=DEPTH_COMPONENT 时允许，WebGL2 把这个组合禁掉了），所以深度纹理
// 在 web 上只能当渲染目标/采样源，不能读回 —— sdl_get_texture_data 会明确拒绝。
web_gl_sdl_read_attachment :: (format: SDL_GPUTextureFormat) -> s32 {
    if web_gl_sdl_format_has_stencil(format) return GL_DEPTH_STENCIL_ATTACHMENT;
    if web_gl_sdl_format_is_depth(format) return GL_DEPTH_ATTACHMENT;
    return GL_COLOR_ATTACHMENT0;
}

// 第 i 个颜色附件的附件点。
web_gl_color_attachment :: (index: s32) -> s32 {
    if index < 0 || index >= MAX_COLOR_ATTACHMENTS return GL_COLOR_ATTACHMENT0;
    return GL_COLOR_ATTACHMENT0 + index;
}

//
// 小工具
//

// 和桌面 sdl_get_graphics_pipeline 里的那两个一样（乘同余混合，避免把相邻的
// 枚举值散成相邻的桶）。重复 6 行而不是从 desktop 文件导出，理由同
// graphics_device_web.jai 里的 sdl_get_texture_format。
web_gl_hash_mix :: (h: u64) -> u64 {
    x := h;
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

web_gl_hash_combine :: (h: u64, v: u64) -> u64 {
    return web_gl_hash_mix(h ^ v);
}

// texture_sampler 的打包 key（与桌面 texture_sampler_key 完全相同，
// 因为 d.samplers 这张表两边都在用）。
web_gl_sampler_key :: (sampler: Texture_Sampler) -> u32 {
    f := cast(u32) sampler.Filter;
    x := cast(u32) sampler.WrapX;
    y := cast(u32) sampler.WrapY;
    return f | (x << 1) | (y << 3);
}

//
// std140 uniform buffer 上传（W4）
//

// 把一段 uniform 字节推到 (stage, slot) 对应的 binding point 上。
//
// 桌面每次 draw 都 SDL_PushGPU*UniformData(slot, bytes) —— 一整块覆盖；这里同样
// 整块 bufferSubData 再 bindBufferBase。UBO 按 binding 复用（一个 binding 一个
// GL buffer），所以稳态下每帧不会新建对象，只是重传 64 / 16 字节。
//
// 返回 false 表示这次上传没能落到 GL 上（没有 context / 槽位越界 / GL 拒绝），
// 调用方按「这个槽位这次没有 uniform」处理，与桌面推失败时的效果一致。
web_gl_upload_uniform_block :: (stage: Shader_Stage, slot: s32, data: [] u8) -> bool {
    if web_gpu.device <= 0 return false;
    if data.count <= 0 return false;

    binding := web_gl_uniform_binding_point(stage, slot);
    if binding < 0 || binding >= WEB_MAX_UNIFORM_BINDINGS return false;

    needed := cast(s32) data.count;
    ubo := web_gpu.uniform_buffers[binding];
    capacity := web_gpu.uniform_capacities[binding];

    if ubo <= 0 || capacity < needed {
        capacity = needed;
        if capacity < 16 capacity = 16; // 最小 std140 block 是 16 B（vec4 对齐）
        if ubo <= 0 {
            ubo = gl_create_uniform_buffer(capacity);
            if ubo <= 0 {
                web_gl_check_error("create_uniform_buffer");
                return false;
            }
        }
        web_gpu.uniform_buffers[binding] = ubo;
        web_gpu.uniform_capacities[binding] = capacity;
    }

    if gl_set_uniform_buffer_data(ubo, web_gl_off(data.data), needed, 0, capacity) <= 0 {
        web_gl_check_error("set_uniform_buffer_data");
        return false;
    }
    if gl_bind_uniform_buffer(ubo, binding) <= 0 {
        web_gl_check_error("bind_uniform_buffer");
        return false;
    }
    web_gpu.uniform_uploads += 1;
    return true;
}

// 一个 shader 的 GPU 资源没了，所有由它链接出来的 program 也必须消失：键里含
// 句柄，所以这里能精确挑出来（hot-replace 时旧 program 不会被下一次 draw 复用）。
// 桌面等价物是 sdl_release_graphics_pipelines_associated_with（release 掉依赖
// 该 shader 的所有 graphics pipeline）。
web_gl_purge_programs_for :: (handle: Graphics_Resource_Handle) {
    if handle == 0 return;

    doomed: [..] Web_Program_Key;
    for entry, key: web_gpu.programs {
        if entry.vs == handle || entry.fs == handle array_add(*doomed, key);
    }
    if doomed.count <= 0 {
        array_free(doomed);
        return;
    }
    for key: doomed {
        p := table_find_pointer(*web_gpu.programs, key);
        if p != null {
            gl_destroy_program(p.id);
            web_gpu.programs_released += 1;
        }
        table_remove(*web_gpu.programs, key);
    }
    array_free(doomed);
}

// 一个 shader 的 handle 背后到底有没有可用的 GL 对象？
//
// `sdl_create_shader` 在 compileShader 失败时**仍然返回一个有效 handle**，只是
// `res.shader` 留 null（GLSL 是文本、创建时就编译，失败点比桌面早）。热替换要在
// 探针失败时分辨「候选没编译过」和「编译过了但链接/VAO 失败」，所以需要这一问。
//
// 为什么不让调用方看 `res.shader`：指针字段里放整数这件事只允许出现在本文件和
// graphics_device_web.jai 里（README §7.2 第 1 条），所以判据也收在这里。
web_gl_shader_compiled :: (d: *Graphics_Device, shader: *Shader) -> bool {
    if d == null || shader == null return false;
    res := sdl_find_resource(d, shader.handle);
    if res == null return false;
    return web_gl_id(res.shader) > 0;
}

//
// render target（W5）：把 GPU_Resource 的附件列表拼成 FBO
//
// 这里是 W5 的核心。三件事必须同时成立，否则画出来的东西要么黑、要么错、要么
// 只在 MSAA 下错（后者最难查）：
//
//  1. **附件点**：第 i 个颜色附件是 COLOR_ATTACHMENT0+i，深度是 DEPTH_ATTACHMENT，
//     深度+模板是 DEPTH_STENCIL_ATTACHMENT（挂错点 = INCOMPLETE_ATTACHMENT）。
//  2. **解析纹理不能当独立附件**：sdl_create_texture 建 MSAA 纹理时会顺手建一张
//     解析纹理，而解析纹理也带着 target_binding（桌面就是这么做的），所以它会
//     出现在 target.attachments 里。如果照单全收，它会被挂成第二个颜色附件 ——
//     FBO 大概还是"完整"的，于是画到 COLOR_ATTACHMENT1 的东西永远不显示。
//     web_gl_target_build 先扫一遍「谁是别人的解析目标」，把这些句柄跳过。
//  3. **样本数一致**：MSAA 的 FBO 里，所有附件（颜色 + 深度）的样本数必须相同，
//     否则 INCOMPLETE_MULTISAMPLE。这一条由 input 的 SampleCount 决定，但深度附件
//     是同一个 Target_Attachment_Info 列表里的另一行 —— 所以谁要是写了
//     「颜色 4×、深度 1×」这种组合，这里就是能抓住它的地方。
//
// 懒建的时机：Target 先 create，附件纹理之后一个个 create_texture（每个都把句柄
// 塞进 target.attachments），所以 sdl_create_target 的时候手上什么都没有。
// 第一次 begin_render_pass 时才拼 FBO，之后命中缓存。
//

web_gl_handle_in :: (list: [] Graphics_Resource_Handle, count: s32, handle: Graphics_Resource_Handle) -> bool {
    for i: 0..count - 1 if list[i] == handle return true;
    return false;
}

// 一张纹理「拿来采样/读回/当 blit 源」时到底用哪张 GL 纹理？
// 多重采样的附件自己不是纹理（WebGL2 的 MS 附件是 renderbuffer），真正有像素的是
// 它的解析纹理 —— 和桌面的 sdl_sampler_texture 是同一个跳转。
web_gl_resolved_texture_id :: (d: *Graphics_Device, res: *GPU_Resource) -> s32 {
    if res == null return 0;
    if res.multi_sample_resolve != 0 {
        resolve := sdl_find_resource(d, res.multi_sample_resolve);
        if resolve != null return web_gl_id(resolve.texture);
    }
    return web_gl_id(res.texture);
}

// 一张纹理的（单附件）FBO，缓存。blit 和 readPixels 都要它。
web_gl_texture_fbo :: (d: *Graphics_Device, res: *GPU_Resource) -> s32 {
    if res == null || web_gpu.device <= 0 return 0;
    texture_id := web_gl_resolved_texture_id(d, res);
    if texture_id <= 0 return 0;

    key := cast(u32) texture_id;
    cached := table_find_pointer(*web_gpu.texture_fbos, key);
    if cached != null return <<cached;

    fbo := gl_create_framebuffer();
    if fbo <= 0 return 0;

    point := web_gl_sdl_read_attachment(res.format);
    status := gl_attach_texture(fbo, point, texture_id);
    if status != GL_FRAMEBUFFER_COMPLETE {
        log_warning(tprint("web/gl: 纹理 %（%) 不能单独当附件（FBO 状态 %）—— blit / 读回用不了它",
                           texture_id, res.format, web_gl_hex(status)));
        gl_destroy_framebuffer(fbo);
        return 0;
    }
    table_set(*web_gpu.texture_fbos, key, fbo);
    return fbo;
}

// Allocate one private attachment and a single-attachment view for copies.
// Separate views make every MRT attachment resolve independently.
web_gl_target_surface :: (d: *Graphics_Device, entry: *Web_Target_Entry,
                          res: *GPU_Resource, internal: s32, point: s32,
                          samples: s32) -> s32 {
    surface: Web_Target_Surface;
    surface.public_texture = web_gl_resolved_texture_id(d, res);
    surface.sampled_fbo = web_gl_texture_fbo(d, res);
    surface.mask = WEB_BLIT_COLOR;
    view_point := cast(s32) GL_COLOR_ATTACHMENT0;
    if web_gl_sdl_format_is_depth(res.format) {
        view_point = point;
        surface.mask = WEB_BLIT_DEPTH;
        if web_gl_sdl_format_has_stencil(res.format) surface.mask |= WEB_BLIT_STENCIL;
    }
    surface.texture = gl_create_texture(entry.width, entry.height, internal,
                                       GL_NEAREST, GL_NEAREST, GL_CLAMP_TO_EDGE, GL_CLAMP_TO_EDGE);
    surface.fbo = gl_create_framebuffer();
    if samples > 1 surface.ms_fbo = gl_create_framebuffer();
    array_add(*entry.surfaces, surface); // own even partially constructed storage
    if surface.texture <= 0 || surface.fbo <= 0 || surface.sampled_fbo <= 0 return 0;
    if samples > 1 && surface.ms_fbo <= 0 return 0;
    if gl_attach_texture(surface.fbo, view_point, surface.texture) != GL_FRAMEBUFFER_COMPLETE return 0;
    // Preserve uploads made before this target was first used (LOAD semantics).
    if samples == 1 {
        if gl_blit_framebuffer(surface.sampled_fbo, surface.fbo,
                               0, 0, entry.width, entry.height,
                               0, entry.height, entry.width, 0,
                               surface.mask, GL_NEAREST) <= 0 return 0;
    }
    return surface.texture;
}

// CPU uploads / texture blits modify the public texture. Keep a built 1x
// attachment in sync, including writes while its pass is still open.
web_gl_texture_written :: (d: *Graphics_Device, res: *GPU_Resource) {
    texture := web_gl_resolved_texture_id(d, res);
    for entry: web_gpu.targets {
        if !entry.complete || entry.sample_count > 1 continue;
        for surface: entry.surfaces {
            if surface.public_texture != texture continue;
            if gl_blit_framebuffer(surface.sampled_fbo, surface.fbo,
                                   0, 0, entry.width, entry.height,
                                   0, entry.height, entry.width, 0,
                                   surface.mask, GL_NEAREST) <= 0 web_gpu.blit_failures += 1;
        }
    }
}

// 一个 target 的 entry（懒建）。返回 null 表示「这个 target 建不起来」。
web_gl_target_entry :: (d: *Graphics_Device, handle: Graphics_Resource_Handle) -> *Web_Target_Entry {
    if handle == 0 || web_gpu.device <= 0 return null;

    key := cast(u32) handle;
    cached := table_find_pointer(*web_gpu.targets, key);
    if cached != null {
        if cached.built return cached;
        // 「建过但失败」的 target：不再重试，直接报同一个结论（重试只会刷屏）。
        return null;
    }

    target_res := sdl_find_resource(d, handle);
    if target_res == null || target_res.kind != .TARGET return null;

    entry: Web_Target_Entry;
    entry.width = target_res.width;
    entry.height = target_res.height;
    entry.sample_count = 1;
    entry.complete = false;
    entry.built = false;

    // [W6] renderbuffer 上限：MSAA 靶子的大小受 MAX_RENDERBUFFER_SIZE 约束（它通常
    // 等于 MAX_TEXTURE_SIZE，但 ES 3.0 只保证 >= 2048）。超了要在建**之前**拒绝，
    // 否则 renderbufferStorageMultisample 会留一个 0 大小的存储，FBO 变成
    // INCOMPLETE_ATTACHMENT，而日志只会说"不完整"。
    if web_gpu.max_renderbuffer > 0 &&
       (entry.width > web_gpu.max_renderbuffer || entry.height > web_gpu.max_renderbuffer) {
        web_gpu.renderbuffer_size_rejections += 1;
        log_error(tprint("web/gl: target % 的 %x% 超过 MAX_RENDERBUFFER_SIZE = % —— 不能用 renderbuffer 附件",
                         handle, entry.width, entry.height, web_gpu.max_renderbuffer));
        entry.built = true;
        entry.complete = false;
        table_set(*web_gpu.targets, key, entry);
        return null;
    }

    // (2) 谁是别人的解析目标 —— 这些句柄不能当独立附件挂。
    resolve_handles: [MAX_COLOR_ATTACHMENTS * 2 + 2] Graphics_Resource_Handle;
    resolve_count: s32 = 0;
    for att: target_res.attachments {
        r := sdl_find_resource(d, att);
        if r == null || r.kind != .TEXTURE continue;
        if r.multi_sample_resolve != 0 && resolve_count < resolve_handles.count {
            resolve_handles[resolve_count] = r.multi_sample_resolve;
            resolve_count += 1;
        }
    }

    entry.fbo = gl_create_framebuffer();
    if entry.fbo <= 0 {
        log_error(tprint("web/gl: target % 建不出 framebuffer", handle));
        table_set(*web_gpu.targets, key, entry);
        return null;
    }

    ok := true;
    for att: target_res.attachments {
        r := sdl_find_resource(d, att);
        if r == null || r.kind != .TEXTURE continue;
        if web_gl_handle_in(array_view(resolve_handles, 0, resolve_count), resolve_count, att) continue;

        internal := web_gl_sdl_internal_format(r.format);
        if internal == 0 {
            log_error(tprint("web/gl: target % 的附件 % 用了 WebGL2 没有的格式 % —— FBO 放弃",
                             handle, att, r.format));
            web_gpu.unsupported_formats += 1;
            ok = false;
            break;
        }

        is_depth := web_gl_sdl_format_is_depth(r.format);
        samples := web_gl_sdl_sample_count(r.sample_count);
        if samples > web_gpu.max_samples {
            if !web_gpu.warned_msaa_supported {
                web_gpu.warned_msaa_supported = true;
                log_error(tprint("web/gl: 请求 % 倍采样，但这台设备的 MAX_SAMPLES = % —— 该附件按 % 创建",
                                 samples, web_gpu.max_samples, web_gpu.max_samples));
                web_gpu.warned_msaa_supported = true;
            }
            samples = web_gpu.max_samples;
            if samples < 1 samples = 1;
        }

        depth_point := cast(s32) (ifx web_gl_sdl_format_has_stencil(r.format) then GL_DEPTH_STENCIL_ATTACHMENT else GL_DEPTH_ATTACHMENT);
        if is_depth {
            if entry.has_depth continue; // 一个 target 只能有一个深度附件
            entry.has_depth = true;
            entry.resolve_stencil = web_gl_sdl_format_has_stencil(r.format);

            // 深度侧：MSAA 时 ms_fbo 上放 renderbuffer，fbo 上放解析纹理。
            depth_texture := web_gl_target_surface(d, *entry, r, internal, depth_point, samples);
            if depth_texture <= 0 {
                ok = false;
                break;
            }
            if samples > 1 {
                if entry.ms_fbo <= 0 entry.ms_fbo = gl_create_framebuffer();
                if entry.ms_fbo <= 0 {
                    ok = false;
                    break;
                }
                rb := gl_create_renderbuffer(internal, entry.width, entry.height, samples);
                if rb <= 0 {
                    ok = false;
                    break;
                }
                array_add(*entry.renderbuffers, rb);
                surface := entry.surfaces[entry.surfaces.count - 1];
                if gl_attach_renderbuffer(surface.ms_fbo, depth_point, rb) != GL_FRAMEBUFFER_COMPLETE {
                    ok = false;
                    break;
                }
                point := cast(s32) (ifx entry.resolve_stencil then GL_DEPTH_STENCIL_ATTACHMENT else GL_DEPTH_ATTACHMENT);
                status := gl_attach_renderbuffer(entry.ms_fbo, point, rb);
                if status != GL_FRAMEBUFFER_COMPLETE {
                    log_error(tprint("web/gl: target % 的深度 renderbuffer 挂不上（状态 %）",
                                     handle, web_gl_hex(status)));
                    web_gpu.target_incomplete += 1;
                    ok = false;
                    break;
                }
                if samples > entry.sample_count entry.sample_count = samples;
                entry.resolve_depth = true;
            }
            if depth_texture > 0 {
                point := cast(s32) (ifx entry.resolve_stencil then GL_DEPTH_STENCIL_ATTACHMENT else GL_DEPTH_ATTACHMENT);
                status := gl_attach_texture(entry.fbo, point, depth_texture);
                if status != GL_FRAMEBUFFER_COMPLETE {
                    log_error(tprint("web/gl: target % 的深度纹理 % 挂不上（状态 %）",
                                     handle, depth_texture, web_gl_hex(status)));
                    web_gpu.target_incomplete += 1;
                    ok = false;
                    break;
                }
            }
        } else {
            point := web_gl_color_attachment(entry.color_count);
            if entry.color_count >= web_gpu.max_color_attachments {
                log_error(tprint("web/gl: target % 的颜色附件超过了 MAX_COLOR_ATTACHMENTS = %",
                                 handle, web_gpu.max_color_attachments));
                ok = false;
                break;
            }
            texture_id := web_gl_target_surface(d, *entry, r, internal, point, samples);
            if texture_id <= 0 {
                log_error(tprint("web/gl: target % 的颜色附件 % 没有可用的纹理（多重采样附件的解析纹理缺失？）",
                                 handle, att));
                ok = false;
                break;
            }
            if samples > 1 {
                if entry.ms_fbo <= 0 entry.ms_fbo = gl_create_framebuffer();
                if entry.ms_fbo <= 0 {
                    ok = false;
                    break;
                }
                rb := gl_create_renderbuffer(internal, entry.width, entry.height, samples);
                if rb <= 0 {
                    ok = false;
                    break;
                }
                array_add(*entry.renderbuffers, rb);
                surface := entry.surfaces[entry.surfaces.count - 1];
                if gl_attach_renderbuffer(surface.ms_fbo, GL_COLOR_ATTACHMENT0, rb) != GL_FRAMEBUFFER_COMPLETE {
                    ok = false;
                    break;
                }
                status := gl_attach_renderbuffer(entry.ms_fbo, point, rb);
                if status != GL_FRAMEBUFFER_COMPLETE {
                    log_error(tprint("web/gl: target % 的颜色 renderbuffer 挂不上（状态 %）",
                                     handle, web_gl_hex(status)));
                    web_gpu.target_incomplete += 1;
                    ok = false;
                    break;
                }
                if samples > entry.sample_count entry.sample_count = samples;
            }
            // Private render-oriented texture; published with a flip when the pass ends.
            status := gl_attach_texture(entry.fbo, point, texture_id);
            if status != GL_FRAMEBUFFER_COMPLETE {
                log_error(tprint("web/gl: target % 的颜色纹理 % 挂不上（状态 %）",
                                 handle, texture_id, web_gl_hex(status)));
                web_gpu.target_incomplete += 1;
                ok = false;
                break;
            }
            entry.color_count += 1;
        }
    }

    if ok && entry.color_count <= 0 {
        log_error(tprint("web/gl: target % 没有任何颜色附件 —— 不能画", handle));
        ok = false;
    }

    if ok {
        // 绘制时绑的是 ms_fbo（有 MSAA）或 fbo；两张都要完整。
        status := gl_framebuffer_status(entry.fbo);
        if status != GL_FRAMEBUFFER_COMPLETE {
            log_error(tprint("web/gl: target % 的单采样 FBO 不完整（状态 %）", handle, web_gl_hex(status)));
            web_gpu.target_incomplete += 1;
            ok = false;
        }
        if ok && entry.ms_fbo > 0 {
            status = gl_framebuffer_status(entry.ms_fbo);
            if status != GL_FRAMEBUFFER_COMPLETE {
                log_error(tprint("web/gl: target % 的多重采样 FBO 不完整（状态 %）—— 检查所有附件的样本数是否一致",
                                 handle, web_gl_hex(status)));
                web_gpu.target_incomplete += 1;
                ok = false;
            }
        }
    }

    entry.built = true;
    entry.complete = ok;
    web_gpu.targets_built += 1;
    if ok && entry.sample_count > 1 web_gpu.msaa_targets += 1;

    table_set(*web_gpu.targets, key, entry);

    if ok {
        log_info(tprint("web/gl: target % 的 FBO 就绪 —— %x%, % 个颜色附件%, % 倍采样",
                        handle, entry.width, entry.height, entry.color_count,
                        ifx entry.has_depth then " + 深度" else "", entry.sample_count));
    }
    if !ok return null;
    return table_find_pointer(*web_gpu.targets, key);
}

// begin_render_pass 用：绘制目标 FBO（MSAA 时是 ms_fbo）。
web_gl_target_pass_fbo :: (d: *Graphics_Device, handle: Graphics_Resource_Handle) -> (fbo: s32, size: Point2, found: bool) {
    entry := web_gl_target_entry(d, handle);
    if entry == null || !entry.complete return 0, Point2_Zero, false;
    fbo = ifx entry.ms_fbo > 0 then entry.ms_fbo else entry.fbo;
    return fbo, .{ entry.width, entry.height }, true;
}

// Publish a target without changing the shared vertex/matrix convention.
// ES 3.0 requires identical source/destination bounds for an MSAA resolve:
// first resolve in render orientation, then flip the single-sample image.
web_gl_target_resolve :: (d: *Graphics_Device, handle: Graphics_Resource_Handle) -> bool {
    if handle == 0 || web_gpu.device <= 0 return false;
    entry := web_gl_target_entry(d, handle);
    if entry == null || !entry.complete return false;
    for surface: entry.surfaces {
        if surface.ms_fbo > 0 {
            if gl_blit_framebuffer(surface.ms_fbo, surface.fbo,
                                   0, 0, entry.width, entry.height,
                                   0, 0, entry.width, entry.height,
                                   surface.mask, GL_NEAREST) <= 0 {
                web_gpu.blit_failures += 1;
                return false;
            }
        }
        if gl_blit_framebuffer(surface.fbo, surface.sampled_fbo,
                               0, 0, entry.width, entry.height,
                               0, entry.height, entry.width, 0,
                               surface.mask, GL_NEAREST) <= 0 {
            web_gpu.blit_failures += 1;
            return false;
        }
    }
    web_gpu.target_resolves += 1;
    return true;
}

// target 没了：连同它的 FBO / renderbuffer 一起回收。
web_gl_target_release :: (handle: Graphics_Resource_Handle) {
    if handle == 0 return;
    key := cast(u32) handle;
    pointer := table_find_pointer(*web_gpu.targets, key);
    if pointer == null return;
    for surface: pointer.surfaces {
        if surface.ms_fbo > 0 gl_destroy_framebuffer(surface.ms_fbo);
        if surface.fbo > 0 gl_destroy_framebuffer(surface.fbo);
        if surface.texture > 0 gl_destroy_texture(surface.texture);
    }
    array_free(pointer.surfaces);
    for rb: pointer.renderbuffers gl_destroy_renderbuffer(rb);
    array_free(pointer.renderbuffers);
    if pointer.ms_fbo > 0 gl_destroy_framebuffer(pointer.ms_fbo);
    if pointer.fbo > 0 gl_destroy_framebuffer(pointer.fbo);
    table_remove(*web_gpu.targets, key);
}

// 一张纹理没了：它的临时 FBO 也没意义了；如果它被某个 target 挂着，那个 target
// 的 FBO 已经指向一张被删的纹理，必须重建（否则画上去的像素消失得无声无息）。
//
// [W6] 从「作废所有 target」改成「**只**作废真的引用了这张纹理的 target」。
//
// W5 的写法是 `for entry, k: web_gpu.targets` 全删：实现简单、不可能漏，但代价是
// 高频 dispose 时（每帧建一张临时纹理再扔掉，比如视频帧 / 动态图集）**所有** target
// 的 FBO + renderbuffer 每帧被重新建一遍。一帧几十个 GL 对象不说，renderbuffer
// 的重新分配会真的触发显存分配 —— 实测 3000 帧 4 个 target 会出现 12000 次
// createFramebuffer + 9000 次 createRenderbuffer，帧时间直接翻倍。
//
// 现在按 target 的 attachments 列表精确匹配：只有引用这张纹理（或它的解析纹理，
// 两者都登记在 attachments 里）的 target 被作废，其余缓存原样保留。
// `targets_invalidated` / `targets_kept` 就是这件事的客观计数（W6 报告里有）。
web_gl_texture_released :: (d: *Graphics_Device, handle: Graphics_Resource_Handle, texture_id: s32) {
    if texture_id > 0 {
        key := cast(u32) texture_id;
        pointer := table_find_pointer(*web_gpu.texture_fbos, key);
        if pointer != null {
            gl_destroy_framebuffer(<<pointer);
            table_remove(*web_gpu.texture_fbos, key);
        }
    }

    if handle == 0 || web_gpu.targets.count <= 0 return;

    doomed: [..] u32;
    for entry, k: web_gpu.targets {
        target_handle := cast(Graphics_Resource_Handle) k;
        target_res := sdl_find_resource(d, target_handle);
        if target_res == null || target_res.kind != .TARGET continue;

        referenced := false;
        for att: target_res.attachments {
            if att == handle {
                referenced = true;
                break;
            }
        }
        if referenced array_add(*doomed, k);
    }

    kept := web_gpu.targets.count - doomed.count;
    if kept > 0 web_gpu.targets_kept += cast(s32) kept;
    for k: doomed {
        web_gl_target_release(cast(Graphics_Resource_Handle) k);
        web_gpu.targets_invalidated += 1;
    }
    array_free(doomed);
}

// Publish an open target before texture readback/blit, for both 1x and MSAA.
web_gl_resolve_open_pass :: (d: *Graphics_Device) {
    if d == null || d.render_pass == null return;
    if web_gpu.device <= 0 return;
    if web_gpu.pass_target != 0 {
        pointer := table_find_pointer(*web_gpu.targets, cast(u32) web_gpu.pass_target);
        if pointer != null && pointer.complete {
            web_gl_target_resolve(d, web_gpu.pass_target);
        }
        return;
    }
    if web_gpu.pass_window && web_gpu.window_ms.ready {
        web_gl_window_msaa_resolve();
    }
}

// 读回时必须绑哪个 framebuffer？
//
//   * 没有 pass：canvas（0）。
//   * pass 画在 target 上：那个 target 的**单采样** FBO（MSAA 时先 resolve；直接读
//     ms_fbo 是 INVALID_OPERATION —— WebGL2 不允许 readPixels 读多重采样附件）。
//   * pass 画在窗口上：先 resolve 窗口的 MS FBO，然后读 0 号 FBO。
//
// 返回 -1 表示「让 JS 用当前绑定」（只有在窗口单采样时才对，保留给老调用点）。
web_gl_readback_fbo :: (d: *Graphics_Device) -> s32 {
    if d == null || d.render_pass == null return 0;
    if web_gpu.device <= 0 return 0;

    if web_gpu.pass_target != 0 {
        pointer := table_find_pointer(*web_gpu.targets, cast(u32) web_gpu.pass_target);
        if pointer == null return web_gpu.pass_fbo;
        if pointer.ms_fbo > 0 && pointer.fbo > 0 {
            web_gl_target_resolve(d, web_gpu.pass_target);
            return pointer.fbo;
        }
        return pointer.fbo;
    }

    if web_gpu.pass_window && web_gpu.window_ms.ready {
        web_gl_window_msaa_resolve();
    }
    return 0;
}

//
// 窗口级 MSAA（W6）
//

// 请求窗口级 MSAA。由 graphics_device_web.jai :: sdl_device_create 在
// App_Flags.MULTI_SAMPLED_BACK_BUFFER 打开时调用。
web_gl_window_msaa_configure :: (samples: s32) {
    wanted := samples;
    if wanted < 2 {
        wanted = 4;
    } // 只说了"要 MSAA"：按桌面默认 4×
    if web_gpu.max_samples > 0 && wanted > web_gpu.max_samples wanted = web_gpu.max_samples;
    web_gpu.window_msaa_samples = wanted;
    web_gpu.window_msaa_wanted = wanted > 1;
}

// 建/重建窗口大小的 MS FBO。尺寸变了就整个重建（renderbuffer 的存储是固定的）。
web_gl_window_msaa_ensure :: (width: s32, height: s32) -> bool {
    if !web_gpu.window_msaa_wanted || web_gpu.device <= 0 return false;
    if width <= 0 || height <= 0 return false;
    if web_gpu.window_ms.failed return false;

    ms := *web_gpu.window_ms;
    if ms.ready && ms.width == width && ms.height == height return true;

    // 尺寸上限：renderbuffer 有自己的 MAX_RENDERBUFFER_SIZE（通常 = MAX_TEXTURE_SIZE，
    // 但不保证）。超了就明确关掉窗口 MSAA，而不是让 renderbufferStorage 静默失败。
    biggest := max(width, height);
    if web_gpu.max_renderbuffer > 0 && biggest > web_gpu.max_renderbuffer {
        web_gpu.window_ms.failed = true;
        web_gpu.renderbuffer_size_rejections += 1;
        log_error(tprint("web/gl: 窗口级 MSAA 需要 %x% 的 renderbuffer，超过 MAX_RENDERBUFFER_SIZE = % —— 窗口退回单采样",
                         width, height, web_gpu.max_renderbuffer));
        return false;
    }

    samples := min(web_gpu.window_msaa_samples, max(web_gpu.max_samples, cast(s32) 1));
    if samples < 2 {
        web_gpu.window_msaa_wanted = false;
        return false;
    }

    if ms.ready web_gl_window_msaa_release();

    fbo := gl_create_framebuffer();
    if fbo <= 0 {
        web_gpu.window_ms.failed = true;
        log_error("web/gl: 窗口级 MSAA 建不出 framebuffer —— 退回单采样");
        return false;
    }

    // 颜色：RGB8（见 Web_Window_MS 的说明：blitFramebuffer 要求两端格式完全一致）
    color_rb := gl_create_renderbuffer(GL_RGB8, width, height, samples);
    if color_rb <= 0 {
        gl_destroy_framebuffer(fbo);
        web_gpu.window_ms.failed = true;
        log_error(tprint("web/gl: 窗口级 MSAA 的颜色 renderbuffer 建不起来（%x%, %×）—— 退回单采样",
                         width, height, samples));
        return false;
    }
    status := gl_attach_renderbuffer(fbo, GL_COLOR_ATTACHMENT0, color_rb);
    if status != GL_FRAMEBUFFER_COMPLETE {
        gl_destroy_renderbuffer(color_rb);
        gl_destroy_framebuffer(fbo);
        web_gpu.window_ms.failed = true;
        log_error(tprint("web/gl: 窗口级 MSAA 的颜色附件挂不上（FBO 状态 %）—— 退回单采样", web_gl_hex(status)));
        return false;
    }

    // 深度+模板：canvas 的默认 framebuffer 两者都有（host.js 建 context 时就要了），
    // 这里必须跟着，否则打开 MSAA 之后窗口上的深度测试会静默失效。
    depth_rb := gl_create_renderbuffer(GL_DEPTH24_STENCIL8, width, height, samples);
    if depth_rb > 0 {
        status = gl_attach_renderbuffer(fbo, GL_DEPTH_STENCIL_ATTACHMENT, depth_rb);
        if status != GL_FRAMEBUFFER_COMPLETE {
            log_warning(tprint("web/gl: 窗口级 MSAA 的深度/模板附件挂不上（状态 %）—— 只有颜色；窗口上的深度测试会失效", web_gl_hex(status)));
            gl_destroy_renderbuffer(depth_rb);
            depth_rb = 0;
        }
    } else {
        log_warning("web/gl: 窗口级 MSAA 的深度 renderbuffer 建不起来 —— 窗口上的深度测试会失效");
    }

    status = gl_framebuffer_status(fbo);
    if status != GL_FRAMEBUFFER_COMPLETE {
        if depth_rb > 0 gl_destroy_renderbuffer(depth_rb);
        gl_destroy_renderbuffer(color_rb);
        gl_destroy_framebuffer(fbo);
        web_gpu.window_ms.failed = true;
        log_error(tprint("web/gl: 窗口级 MSAA 的 FBO 不完整（状态 %）—— 退回单采样", web_gl_hex(status)));
        return false;
    }

    ms.fbo = fbo;
    ms.color_rb = color_rb;
    ms.depth_rb = depth_rb;
    ms.width = width;
    ms.height = height;
    ms.samples = samples;
    ms.ready = true;
    web_gpu.window_msaa_rebuilt += 1;

    log_info(tprint("web/gl: 窗口级 MSAA 就绪 —— %x%，%× 采样（RGB8 + D24S8 renderbuffer），present 时 blit 到 0 号 FBO",
                    width, height, samples));
    return true;
}

web_gl_window_msaa_release :: () {
    ms := *web_gpu.window_ms;
    if ms.depth_rb > 0 gl_destroy_renderbuffer(ms.depth_rb);
    if ms.color_rb > 0 gl_destroy_renderbuffer(ms.color_rb);
    if ms.fbo > 0 gl_destroy_framebuffer(ms.fbo);
    ms.depth_rb = 0;
    ms.color_rb = 0;
    ms.fbo = 0;
    ms.width = 0;
    ms.height = 0;
    ms.samples = 1;
    ms.ready = false;
}

// 窗口级 MSAA 的 resolve：ms_fbo → 0 号 FBO（canvas）。
//
// 失败一次就彻底关掉：每帧一次无效的 blitFramebuffer 既刷日志也真的花时间。
// 最可能的失败原因是「两端格式不一致」—— 某些驱动把 alpha:false 的默认
// framebuffer 做成 RGBA8，这时 RGB8 → RGBA8 会被 ES 3.0 拒绝（要 ES 3.1 才放宽）。
web_gl_window_msaa_resolve :: () -> bool {
    ms := *web_gpu.window_ms;
    if !ms.ready || web_gpu.device <= 0 return false;

    ok := gl_blit_framebuffer(ms.fbo, 0,
                              0, 0, ms.width, ms.height,
                              0, 0, ms.width, ms.height,
                              WEB_BLIT_COLOR, GL_NEAREST);
    if ok <= 0 {
        web_gpu.blit_failures += 1;
        if !web_gpu.warned_window_msaa {
            web_gpu.warned_window_msaa = true;
            log_error(tprint("web/gl: 窗口级 MSAA 的 resolve（%x% → 0 号 FBO）失败 —— 关掉窗口 MSAA 退回单采样；最常见的原因是默认 framebuffer 不是 RGB8（ES 3.0 的 blitFramebuffer 要求两端格式一致）",
                             ms.width, ms.height));
        }
        web_gl_window_msaa_release();
        web_gpu.window_msaa_wanted = false;
        return false;
    }
    web_gpu.window_resolves += 1;
    return true;
}

//
// [W6] 内存 / 对象计数的读取入口
//
// 任务是「跑 3000+ 帧，记录 memory.buffer.byteLength 与各类对象计数（texture /
// buffer / program / pipeline / fbo），断言不单调增长」。线性内存的大小只有 JS
// 侧知道（memory.buffer.byteLength），而 Jai 侧能数的是**缓存表**的条目数 ——
// 两个数字合起来才说明「没有泄漏」：内存不涨说明临时/持久分配都被回收了，
// 缓存表不涨说明程序/管线/target 的缓存没有随帧数增长。
//
// 走 fw_stats(200 + which)：和 100+ 的 gl 计数同一个通道，宿主脚本只需要一个
// 读数接口。resource 计数是 O(resources) 的表遍历，只在每 300 帧的报告里调。
//
web_gl_count_resources :: (d: *Graphics_Device, kind: GPU_Resource_Kind) -> s32 {
    if d == null return 0;
    n: s32 = 0;
    for res: d.resources {
        if res == null continue;
        if res.kind == kind n += 1;
    }
    return n;
}

web_gpu_stat :: (d: *Graphics_Device, which: s32) -> s32 {
    if which == 0 return cast(s32) (web_gpu.programs.count);
    if which == 1 return cast(s32) (web_gpu.pipelines.count);
    if which == 2 return cast(s32) (web_gpu.samplers.count);
    if which == 3 return cast(s32) (web_gpu.targets.count);
    if which == 4 return cast(s32) (web_gpu.texture_fbos.count);
    if which == 5 return cast(s32) (web_gpu.targets_built);
    if which == 6 return cast(s32) (web_gpu.target_resolves);
    if which == 7 return cast(s32) (web_gpu.target_incomplete);
    if which == 8 return cast(s32) (web_gpu.blits);
    if which == 9 return cast(s32) (web_gpu.window_resolves);
    if which == 10 return cast(s32) (web_gpu.window_ms.samples);
    if which == 11 return cast(s32) (web_gpu.msaa_targets);
    if which == 12 return cast(s32) (web_gpu.texture_size_rejections);
    if which == 13 return cast(s32) (web_gl_count_resources(d, .TEXTURE));
    if which == 14 return cast(s32) (web_gl_count_resources(d, .BUFFER));
    if which == 15 return cast(s32) (web_gpu.readback_refusals);
    if which == 16 return cast(s32) (web_gpu.readback_unsupported_format);
    if which == 17 return cast(s32) (web_gpu.targets_invalidated);
    if which == 18 return cast(s32) (web_gpu.targets_kept);
    if which == 19 return cast(s32) (web_gpu.window_msaa_rebuilt);
    if which == 20 return cast(s32) (web_gpu.renderbuffer_size_rejections);
    if which == 21 return cast(s32) (web_gl_count_resources(d, .TARGET));
    if which == 22 return cast(s32) (web_gpu.max_texture_size);
    if which == 23 return cast(s32) (web_gpu.max_samples);
    if which == 24 return cast(s32) (web_gpu.blit_failures);
    if which == 25 return cast(s32) (web_gpu.draw_skips);
    return -1;
}

// 取样用的过滤器：桌面把同一个 filter 同时给 min/mag（没有 mipmap），这里一致。
web_gl_get_sampler :: (d: *Graphics_Device, sampler: Texture_Sampler) -> s32 {
    key := web_gl_sampler_key(sampler);

    found_ptr := table_find_pointer(*web_gpu.samplers, key);
    if found_ptr != null return <<found_ptr;

    filter := web_gl_filter(sampler.Filter);
    id := gl_create_sampler(filter, filter, web_gl_wrap(sampler.WrapX), web_gl_wrap(sampler.WrapY));
    if id <= 0 return 0;

    table_set(*web_gpu.samplers, key, id);
    return id;
}
