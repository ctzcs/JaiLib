using Basic;
using Math;

// stb_truetype — web (wasm64) 版本。
//
// `images/font.jai` 的 11 个 `#foreign stb_impl` 声明（stbtt_*）在 desktop 上
// 链的是预编译的 stb_impl.dll/.lib（internal/third_party/stb/build.bat，
// `cl /O2 /LD /DEF:stb_impl.def stb_impl.c`）。native 库进不了 wasm 模块，所以
// wasm 目标下 font.jai 把那 11 行换成 `#load "internal/web/stbtt_web.jai"`。
//
// **为什么只替换这 11 个过程，而不是整个 font.jai**：Font / Font_Character /
// font_get_character / font_get_kerning / font_get_pixels 这些「前端」全是可移植
// 的排版数学，desktop 与 web 必须逐位一致（kit 的位图字体、图集打包、
// sprite_font 都建立在它上面）。只有真正解析 TTF 字节的那一层不可移植，所以只
// 替换那一层 —— 公开 API 在两侧自动保持同一份代码。
//
// 行为：**全部报告失败**。stbtt_InitFont 返回 0，于是 font_load_bytes 走它已有的
// "no fonts in data" 分支，font_load 返回 null。desktop 上加载一个非 TTF 文件时
// 的表现完全一样，所以调用方不需要新分支。所有 out 参数都写 0，绝不留下未初始化
// 的局部量。
//
// W2/W3 的两条路（都记在 README §8）：
//   * 用 jaic -os wasm 把 stb_truetype.h 的 STB_TRUETYPE_IMPLEMENTATION 编成 .o
//     一起链进来（stb 是单头文件 C，这条路最省事）；
//   * 或者放弃运行时栅格化：构建期用 stb 烘成 MSDF/位图图集（olib 的
//     msdf_font 路径），web 侧只读图集。

stbtt_InitFont :: (info: *STBTT_Font_Info, data: *u8, offset: s32) -> s32 {
    // 0 == "not a valid font", the exact value stb returns for a bad blob.
    return 0;
}

stbtt_GetNumberOfFonts :: (data: *u8) -> s32 {
    return 0;
}

stbtt_FindGlyphIndex :: (info: *STBTT_Font_Info, unicode_codepoint: s32) -> s32 {
    return 0;
}

stbtt_ScaleForPixelHeight :: (info: *STBTT_Font_Info, pixels: float) -> float {
    // A 0 scale would make font_get_character divide/multiply into garbage; 1.0 is
    // the identity scale, which keeps every downstream metric finite.
    return 1.0;
}

stbtt_ScaleForMappingEmToPixels :: (info: *STBTT_Font_Info, pixels: float) -> float {
    return 1.0;
}

stbtt_GetFontVMetrics :: (info: *STBTT_Font_Info, ascent: *s32, descent: *s32, lineGap: *s32) {
    // Write through only if the caller actually passed the out parameter.
    if ascent != null ascent.* = 0;
    if descent != null descent.* = 0;
    if lineGap != null lineGap.* = 0;
}

stbtt_GetGlyphKernAdvance :: (info: *STBTT_Font_Info, glyph1: s32, glyph2: s32) -> s32 {
    return 0;
}

stbtt_GetGlyphHMetrics :: (info: *STBTT_Font_Info, glyph_index: s32, advance_width: *s32, left_side_bearing: *s32) {
    if advance_width != null advance_width.* = 0;
    if left_side_bearing != null left_side_bearing.* = 0;
}

stbtt_GetGlyphBox :: (info: *STBTT_Font_Info, glyph_index: s32, x0: *s32, y0: *s32, x1: *s32, y1: *s32) -> s32 {
    if x0 != null x0.* = 0;
    if y0 != null y0.* = 0;
    if x1 != null x1.* = 0;
    if y1 != null y1.* = 0;
    return 0;
}

stbtt_IsGlyphEmpty :: (info: *STBTT_Font_Info, glyph_index: s32) -> s32 {
    // 1 == "empty glyph", so callers skip rasterising it instead of asking for a
    // 0x0 bitmap.
    return 1;
}

stbtt_MakeGlyphBitmapSubpixel :: (info: *STBTT_Font_Info, output: *u8, out_w: s32, out_h: s32, out_stride: s32, scale_x: float, scale_y: float, shift_x: float, shift_y: float, glyph_index: s32) {
    // Deliberately writes nothing: `output` is the caller's buffer and filling it
    // with a guess would look like a rendered glyph. The caller already skips the
    // upload when stbtt_IsGlyphEmpty said the glyph is empty.
}
