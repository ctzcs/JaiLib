// ui:backend —— clay RenderCommand -> UI_Op 翻译（CPU 可测）+ Render2D 发射。
//
// clay 0.14 的渲染命令带 elementId + renderData（与 olib 同款）：
//   - elementId 是命令所属的元素（文字行、描边、scissor 结束也都填了），所以视觉变换直接按它
//     查视觉树，不再需要「命令 id -> 元素 id」的派生 id 表；
//   - renderData 是 {rectangle|border|text|image|custom|clip} 的 union，颜色字段叫 backgroundColor；
//   - 图片与九宫格的染色走 renderData.image/custom.backgroundColor（声明时写 tint）。

//@region 翻译

UI_Op_Kind :: enum {
    Quad; // 纯色或贴图四边形
    Scissor_Start;
    Scissor_End;
}

UI_Op :: struct {
    kind: UI_Op_Kind;
    // 已合成的逻辑坐标变换；零值 op 保持旧版轴对齐行为。
    transformed: bool;
    transform: F.Matrix3x2;

    // Quad 有效字段
    x0, y0, x1, y1: float32; // 逻辑像素（左上/右下）
    u0, v0, u1, v1: float32; // UV（纯色时 0..1）
    color: F.Color;
    texture: *F.Texture; // null = 纯色
    msdf: bool;
    font_id: int;
    radius: float32; // 圆角半径（<1 走直角路径）

    // Scissor 有效字段
    clip_x, clip_y, clip_w, clip_h: float32;
}

// 把 clay 渲染命令翻译成操作流（调用方 ui_ops_dispose）。
ui_translate :: (ctx: *UI_Context, commands: clay.ClayArray(clay.RenderCommand)) -> [..] UI_Op {
    ops: [..] UI_Op;
    ui_translate_into(ctx, commands, *ops);
    return ops;
}

// 复用输出容量；命令、字体纹理指针仅在本帧内有效。

// clay 的 Color 是 [4] float，数组不能直接 ==；零值判断单独写一个。
ui_color_is_zero :: (c: clay.Color) -> bool {
    return c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 0;
}

ui_translate_into :: (ctx: *UI_Context, commands: clay.ClayArray(clay.RenderCommand), ops: *[..] UI_Op) {
    ops.count = 0;
    // 焦点框插在焦点元素最后一条命令（clay 的描边在子元素之后）之后：同一层、同一裁剪。
    ring_at := -1;
    ring_bb: clay.BoundingBox;
    cmds := commands; // 取址需要局部变量
    for i: 0..cmds.length - 1 {
        cmd := clay.RenderCommandArray_Get(*cmds, i);
        if cmd == null continue;
        bb := cmd.boundingBox;
        op_start := ops.count;
        // 带裁剪的焦点元素（如文本框）：焦点框放在它自己的裁剪结束之后，外扩部分不被裁掉。
        // SCISSOR_START 不算「自己的命令」：浮动根（如文本框的光标）的根级裁剪起点也带
        // 焦点元素的 elementId（clay 用 root.clipElementId 填 elementId），若把它算进来，
        // ring_at 会停在那条 SCISSOR_START 之后，焦点框就落进这条裁剪里了。
        // clay 的根级 SCISSOR_END 不带 elementId（默认 0），也就无法把 ring_at 挪回来。
        focused := ctx.focused_id != 0 && cmd.elementId == ctx.focused_id
                && cmd.commandType != .SCISSOR_START;
        if focused && ring_at < 0 && cmd.commandType != .SCISSOR_END {
            ring_bb = bb;
        }

        if cmd.commandType == .RECTANGLE {
            r := cmd.renderData.rectangle.cornerRadius;
            radius := min(min(r.topLeft, r.topRight), min(r.bottomLeft, r.bottomRight));
            append_rect_op(ops, bb, ui_color(cmd.renderData.rectangle.backgroundColor), radius);
        } else if cmd.commandType == .BORDER {
            // 四边展开（betweenChildren 的内部分隔线不在此路径）
            b := cmd.renderData.border;
            l := cast(float32) b.width.left;
            r := cast(float32) b.width.right;
            t := cast(float32) b.width.top;
            bo := cast(float32) b.width.bottom;
            col := ui_color(b.color);
            x0, y0 := bb.x, bb.y;
            x1, y1 := bb.x + bb.width, bb.y + bb.height;
            if t > 0 array_add(ops, quad(x0, y0, x1, y0 + t, col));
            if bo > 0 array_add(ops, quad(x0, y1 - bo, x1, y1, col));
            if l > 0 array_add(ops, quad(x0, y0, x0 + l, y1, col));
            if r > 0 array_add(ops, quad(x1 - r, y0, x1, y1, col));
        } else if cmd.commandType == .IMAGE {
            data := cmd.renderData.image;
            texture := cast(*F.Texture) data.imageData;
            // clay 原生图像声明未指定颜色时按无染色处理。
            tint := F.Color_White;
            if !ui_color_is_zero(data.backgroundColor) tint = ui_color(data.backgroundColor);
            array_add(ops, UI_Op.{
                kind = .Quad,
                x0 = bb.x, y0 = bb.y, x1 = bb.x + bb.width, y1 = bb.y + bb.height,
                color = tint,
                texture = texture,
                u1 = 1, v1 = 1,
            });
        } else if cmd.commandType == .CUSTOM {
            // 只接受当前帧 image_pool 中对齐的指针，避免解释调用者的 customData。
            custom := cmd.renderData.custom;
            if custom.customData != null {
                address := cast(u64) custom.customData;
                base := cast(u64) ctx.image_pool.data;
                if address >= base {
                    offset := address - base;
                    stride := cast(u64) size_of(UI_Image_Data);
                    if offset < cast(u64) (ctx.image_len * size_of(UI_Image_Data)) &&
                       offset % stride == 0 {
                        data := ctx.image_pool[cast(int) (offset / stride)];
                        sub := data.sub;
                        tint := ui_color(custom.backgroundColor);
                        if sub.Frame.w > 0 && sub.Frame.h > 0 {
                            if data.source_border > 0 {
                                ui_translate_nine_slice(ops, bb, data, tint);
                            } else {
                                sx := bb.width / sub.Frame.w;
                                sy := bb.height / sub.Frame.h;
                                array_add(ops, UI_Op.{
                                    x0 = bb.x + sub.DrawCoords[0].x * sx, y0 = bb.y + sub.DrawCoords[0].y * sy,
                                    x1 = bb.x + sub.DrawCoords[2].x * sx, y1 = bb.y + sub.DrawCoords[2].y * sy,
                                    u0 = sub.TexCoords[0].x, v0 = sub.TexCoords[0].y,
                                    u1 = sub.TexCoords[2].x, v1 = sub.TexCoords[2].y,
                                    texture = sub.Tex, color = tint,
                                });
                            }
                        }
                    }
                }
            }
        } else if cmd.commandType == .TEXT {
            data := cmd.renderData.text;
            font := ui_font_of(ctx, cast(int) data.fontId);
            if font != null && font.Size > 0 {
                aw, ah := ui_msdf_atlas_size(font);
                if aw > 0 && ah > 0 {
                    text := string.{ count = cast(s64) data.stringContents.length, data = cast(*u8) data.stringContents.chars };
                    col := ui_color(data.textColor);
                    texture := ui_texture_of(ctx, cast(int) data.fontId);
                    scale := cast(float32) data.fontSize / font.Size;
                    // 基线：boundingBox 顶 + 字体上行（clay 的文字盒从行顶开始）
                    baseline := bb.y + font.Ascent * scale;
                    em := cast(float32) data.fontSize;
                    msdf := false;
                    font_id := cast(int) data.fontId;
                    if font_id >= 0 && font_id < ctx.font_renderers.count {
                        msdf = ctx.font_renderers[font_id].kind == .MSDF;
                    }
                    x := bb.x;
                    prev: s32 = -1;
                    rest := text;
                    while true {
                        code, size := ui_utf8_next(*rest);
                        if size <= 0 break;
                        if prev >= 0 {
                            x += ui_msdf_kerning(font, prev, cast(s32) code) * scale;
                            x += cast(float32) data.letterSpacing;
                        }
                        found, glyph := ui_msdf_glyph(font, cast(s32) code);
                        if found {
                            gx := x + glyph.pl * em;
                            gy := baseline + glyph.pt * em;
                            array_add(ops, UI_Op.{
                                kind = .Quad,
                                x0 = gx, y0 = gy,
                                x1 = gx + (glyph.pr - glyph.pl) * em,
                                y1 = gy + (glyph.pb - glyph.pt) * em,
                                u0 = glyph.al, v0 = glyph.at, u1 = glyph.ar, v1 = glyph.ab,
                                color = col,
                                texture = texture,
                                font_id = font_id,
                                msdf = msdf,
                            });
                            x += glyph.Advance * scale;
                        } else {
                            x += font.Size * scale * 0.5;
                        }
                        prev = cast(s32) code;
                    }
                }
            }
        } else if cmd.commandType == .SCISSOR_START {
            array_add(ops, UI_Op.{
                kind = .Scissor_Start,
                clip_x = bb.x, clip_y = bb.y, clip_w = bb.width, clip_h = bb.height,
            });
        } else if cmd.commandType == .SCISSOR_END {
            array_add(ops, UI_Op.{ kind = .Scissor_End });
        }

        // 视觉变换覆盖本命令产生的全部 op（也覆盖提前 continue 的路径）。
        // cmd.elementId 连文字行、描边、scissor 结束命令都填了，直接查视觉树即可。
        ui_visual_apply_ops(ctx, cmd.elementId, ops, op_start);
        // 焦点框放在焦点元素最后一条命令之后；SCISSOR_END 也算（裁剪元素要画在自己的裁剪之外）。
        if focused ring_at = ops.count;
    }
    if ring_at >= 0 {
        // 焦点元素没有任何属于自己的绘制命令时退回它的布局矩形。
        if ring_bb.width <= 0 || ring_bb.height <= 0 {
            ring_bb = clay.GetElementData(.{ id = ctx.focused_id }).boundingBox;
        }
        ui_translate_focus_ring(ctx, ops, ring_at, ring_bb);
    }
}

ui_translate_focus_ring :: (ctx: *UI_Context, ops: *[..] UI_Op, at: int, element: clay.BoundingBox) {
    style := ctx.focus_style;
    if style.hidden || ctx.focus_ring_hidden || (style.keyboard_only && ctx.focus_by_pointer) return;
    bb := element;
    bb.x -= style.offset;
    bb.y -= style.offset;
    bb.width += style.offset * 2;
    bb.height += style.offset * 2;
    if bb.width <= 0 || bb.height <= 0 return;
    ring: [..] UI_Op;
    defer array_free(ring);
    if style.image.Tex != null && style.image.Frame.w > 0 && style.image.Frame.h > 0 {
        tint := style.color;
        if ui_fcolor_is_zero(tint) tint = F.Color_White;
        if style.image_source_border > 0 {
            ui_translate_nine_slice(*ring, bb, UI_Image_Data.{
                sub = style.image, source_border = style.image_source_border,
                border = style.image_border,
            }, tint);
        } else {
            sub := style.image;
            array_add(*ring, UI_Op.{
                x0 = bb.x, y0 = bb.y, x1 = bb.x + bb.width, y1 = bb.y + bb.height,
                u0 = sub.TexCoords[0].x, v0 = sub.TexCoords[0].y,
                u1 = sub.TexCoords[2].x, v1 = sub.TexCoords[2].y,
                texture = sub.Tex, color = tint,
            });
        }
    } else {
        w := min(max(style.width, 0), min(bb.width * 0.5, bb.height * 0.5));
        x0, y0, x1, y1 := bb.x, bb.y, bb.x + bb.width, bb.y + bb.height;
        array_add(*ring, quad(x0, y0, x1, y0 + w, style.color));
        array_add(*ring, quad(x0, y1 - w, x1, y1, style.color));
        array_add(*ring, quad(x0, y0 + w, x0 + w, y1 - w, style.color));
        array_add(*ring, quad(x1 - w, y0 + w, x1, y1 - w, style.color));
    }
    ui_visual_apply_ops(ctx, ctx.focused_id, *ring, 0);
    ui_ops_insert(ops, at, ring);
}

// 把 slice 插到 dynamic array 的第 at 个位置。
ui_ops_insert :: (ops: *[..] UI_Op, at: int, insert: [] UI_Op) {
    if insert.count <= 0 return;
    base := ops.count;
    array_resize(ops, base + insert.count);
    if at < 0 at = 0;
    if at > base at = base;
    tail := base - at;
    if tail > 0 {
        memcpy(ops.data + at + insert.count, ops.data + at, tail * size_of(UI_Op));
    }
    for op, i: insert ops.*[at + i] = op;
}

ui_translate_nine_slice :: (ops: *[..] UI_Op, bb: clay.BoundingBox, data: UI_Image_Data, color: F.Color) {
    if bb.width <= 0 || bb.height <= 0 return;
    if data.sub.Tex == null return;
    b := min(data.border, min(bb.width, bb.height) * 0.5);
    x: [4] float32 = .[bb.x, bb.x + b, bb.x + bb.width - b, bb.x + bb.width];
    y: [4] float32 = .[bb.y, bb.y + b, bb.y + bb.height - b, bb.y + bb.height];
    u: [4] float32 = .[0, data.source_border / data.sub.Frame.w,
                         1 - data.source_border / data.sub.Frame.w, 1];
    v: [4] float32 = .[0, data.source_border / data.sub.Frame.h,
                         1 - data.source_border / data.sub.Frame.h, 1];
    for row: 0..2 {
        for col: 0..2 {
            if x[col + 1] <= x[col] || y[row + 1] <= y[row] continue;
            array_add(ops, UI_Op.{
                x0 = x[col], y0 = y[row], x1 = x[col + 1], y1 = y[row + 1],
                u0 = u[col], v0 = v[row], u1 = u[col + 1], v1 = v[row + 1],
                texture = data.sub.Tex, color = color,
            });
        }
    }
}

ui_ops_dispose :: (ops: *[..] UI_Op) {
    array_free(ops.*);
    ops.* = [..] UI_Op.{};
}
//@endregion

//@region 发射

// 结束布局并复用 ctx 内操作缓冲。调用者仍负责 r2d.submit。
ui_draw :: (ctx: *UI_Context, r: *r2d.Render2D) {
    commands := ui_end(ctx);
    ui_translate_into(ctx, commands, *ctx.ops);
    ui_render(ctx, r, *ctx.ops);
}

// UI 使用自己的像素变换，退出时恢复 Render2D 的状态栈；外部 scissor 作为根裁剪。
ui_render :: (ctx: *UI_Context, r: *r2d.Render2D, ops: *[..] UI_Op) {
    if r.library == null return;
    if op_has_rounded(ops) _ = ui_ensure_corner_texture(ctx, r.library.device);
    r2d.push_matrix_trs(r, ctx.viewport_origin, .{ ctx.scale, ctx.scale }, 0, false);
    defer r2d.pop_matrix(r);
    r2d.push_sampler(r, F.texture_sampler_make(.LINEAR, .CLAMP));
    defer r2d.pop_sampler(r);
    r2d.push_blend(r, F.Blend_Mode_Premultiply);
    defer r2d.pop_blend(r);
    r2d.push_mode(r, .NORMAL);
    defer r2d.pop_mode(r);
    root := ui_pixel_clip(ctx, .{ 0, 0, ctx.width, ctx.height });
    if r.has_scissor root = ui_clip_intersection(root, r.scissor);
    r2d.push_scissor(r, root);
    clip_depth := 1;
    defer {
        while clip_depth > 1 {
            r2d.pop_scissor(r);
            clip_depth -= 1;
        }
        r2d.pop_scissor(r);
    }
    for op: ops.* {
        if op.kind == .Quad {
            if r.scissor.w <= 0 || r.scissor.h <= 0 continue;
            // MSDF 字形用内置 Text_Msdf 材质；其余（位图字形、图片、纯色、圆角）用默认材质。
            material: *mat.Material;
            if op.msdf {
                material = ui_msdf_material(ctx, op.font_id, r.library);
                if material == null continue;
            }
            if op.transformed r2d.push_matrix_raw(r, ui_visual_pixel_matrix(ctx, op.transform), false);
            if op.radius >= 1 && ctx.corner_texture_ok {
                ui_emit_rounded(r, ctx.corner_texture, op);
            } else if op.texture != null {
                r2d.quad_texture(r, op.texture,
                    .{ op.x0, op.y0 }, .{ op.x1, op.y0 }, .{ op.x1, op.y1 }, .{ op.x0, op.y1 },
                    .{ op.u0, op.v0 }, .{ op.u1, op.v0 }, .{ op.u1, op.v1 }, .{ op.u0, op.v1 },
                    op.color, material);
            } else {
                r2d.rect(r, F.Rect.{ op.x0, op.y0, op.x1 - op.x0, op.y1 - op.y0 }, op.color);
            }
            if op.transformed r2d.pop_matrix(r);
        } else if op.kind == .Scissor_Start {
            clip := ui_pixel_clip(ctx, .{ op.clip_x, op.clip_y, op.clip_w, op.clip_h });
            r2d.push_scissor(r, ui_clip_intersection(r.scissor, clip));
            clip_depth += 1;
        } else if op.kind == .Scissor_End {
            if clip_depth > 1 {
                r2d.pop_scissor(r);
                clip_depth -= 1;
            }
        }
    }
}

ui_pixel_clip :: (ctx: *UI_Context, rect: F.Rect) -> F.Rect_Int {
    x0 := cast(s32) JM.floor(ctx.viewport_origin.x + rect.x * ctx.scale);
    y0 := cast(s32) JM.floor(ctx.viewport_origin.y + rect.y * ctx.scale);
    x1 := cast(s32) JM.ceil(ctx.viewport_origin.x + (rect.x + rect.w) * ctx.scale);
    y1 := cast(s32) JM.ceil(ctx.viewport_origin.y + (rect.y + rect.h) * ctx.scale);
    return .{ x0, y0, max(x1 - x0, 0), max(y1 - y0, 0) };
}

ui_clip_intersection :: (a: F.Rect_Int, b: F.Rect_Int) -> F.Rect_Int {
    x := max(a.x, b.x);
    y := max(a.y, b.y);
    return .{ x, y,
               max(min(a.x + a.w, b.x + b.w) - x, 0),
               max(min(a.y + a.h, b.y + b.h) - y, 0) };
}

UI_Font_Kind :: enum {
    Bitmap;
    MSDF;
}

UI_Font_Renderer :: struct {
    kind: UI_Font_Kind;
    material: *mat.Material; // MSDF 字体：内置 Text_Msdf 材质实例，归材质库所有
}

// 每种 MSDF 字体一个 Text_Msdf 材质实例，distance_range 取字体图集的距离范围；首次使用时在材质库里创建。
ui_msdf_material :: (ctx: *UI_Context, id: int, library: *mat.Material_Library) -> *mat.Material {
    if id < 0 || id >= ctx.font_renderers.count return null;
    renderer := *ctx.font_renderers[id];
    if renderer.material == null {
        material, reason := mat.material_create(library, mat.BUILTIN_TEXT);
        if reason != "" return null;
        distance: float32 = 4;
        if id < ctx.fonts.count && ctx.fonts[id] != null && ctx.fonts[id].DistanceRange > 0 {
            distance = ctx.fonts[id].DistanceRange;
        }
        _ = mat.material_set_number(material, mat.BUILTIN_TEXT, "distance_range", .[distance, 0, 0, 0]);
        renderer.material = material;
    }
    return renderer.material;
}

op_has_rounded :: (ops: *[..] UI_Op) -> bool {
    for op: ops.* if op.kind == .Quad && op.radius >= 1 return true;
    return false;
}

// 圆盘纹理：预乘 alpha、1px 盒式过滤边缘（预乘混合下无白边）。
ui_ensure_corner_texture :: (ctx: *UI_Context, device: *F.Graphics_Device) -> bool {
    if ctx.corner_texture_ok return true;
    if device == null return false;

    N :: 128;
    pixels := NewArray(N * N, F.Color, true);
    if pixels.data == null return false;
    defer free(pixels.data);
    c := cast(float32) (N - 1) * 0.5;
    r := cast(float32) N * 0.5;
    for y: 0..N - 1 {
        for x: 0..N - 1 {
            dx := cast(float32) x + 0.5 - c;
            dy := cast(float32) y + 0.5 - c;
            d := JM.sqrt(dx * dx + dy * dy);
            t := clamp(r - d + 0.5, 0, 1);
            a := cast(u8) (t * 255);
            pixels[y * N + x] = .{ a, a, a, a };
        }
    }
    tex := F.texture_create_from_colors(device, N, N, pixels, .NONE, "ui corner disc");
    if tex == null || tex.handle == 0 return false;

    ctx.corner_texture = tex;
    ctx.corner_texture_ok = true;
    return true;
}

// 圆角矩形 9-patch：4 个角采圆盘对应象限（Normal 模式），5 个纯色矩形条（Render2D 自动用 Fill）。
// r 钳到半宽/半高（全圆/胶囊自动成立）。
ui_emit_rounded :: (r: *r2d.Render2D, disc: *F.Texture, op: UI_Op) {
    w := op.x1 - op.x0;
    h := op.y1 - op.y0;
    radius := min(op.radius, min(w * 0.5, h * 0.5));
    if radius < 1 { // 退化成直角
        r2d.rect(r, F.Rect.{ op.x0, op.y0, w, h }, op.color);
        return;
    }

    // 4 角（象限 UV：TL(0,0)-(0.5,0.5) TR/BR/BL 顺时针）
    ui_emit_corner(r, disc, op.x0, op.y0, 0, 0, radius, op.color); // TL
    ui_emit_corner(r, disc, op.x1 - radius, op.y0, 0.5, 0, radius, op.color); // TR
    ui_emit_corner(r, disc, op.x1 - radius, op.y1 - radius, 0.5, 0.5, radius, op.color); // BR
    ui_emit_corner(r, disc, op.x0, op.y1 - radius, 0, 0.5, radius, op.color); // BL

    // 5 个填充条（零尺寸自动跳过）
    ui_emit_bar(r, op.x0 + radius, op.y0, w - 2 * radius, radius, op.color); // 上条
    ui_emit_bar(r, op.x0 + radius, op.y1 - radius, w - 2 * radius, radius, op.color); // 下条
    ui_emit_bar(r, op.x0, op.y0 + radius, radius, h - 2 * radius, op.color); // 左条
    ui_emit_bar(r, op.x1 - radius, op.y0 + radius, radius, h - 2 * radius, op.color); // 右条
    ui_emit_bar(r, op.x0 + radius, op.y0 + radius, w - 2 * radius, h - 2 * radius, op.color); // 中心
}

ui_emit_corner :: (r: *r2d.Render2D, disc: *F.Texture, px: float32, py: float32,
                   u0: float32, v0: float32, size: float32, color: F.Color) {
    r2d.quad_texture(r, disc,
        .{ px, py },
        .{ px + size, py },
        .{ px + size, py + size },
        .{ px, py + size },
        .{ u0, v0 }, .{ u0 + 0.5, v0 }, .{ u0 + 0.5, v0 + 0.5 }, .{ u0, v0 + 0.5 },
        color);
}

ui_emit_bar :: (r: *r2d.Render2D, x: float32, y: float32, w: float32, h: float32, color: F.Color) {
    if w <= 0.01 || h <= 0.01 return;
    r2d.rect(r, F.Rect.{ x, y, w, h }, color);
}
//@endregion

//@region 内部

append_rect_op :: (ops: *[..] UI_Op, bb: clay.BoundingBox, color: F.Color, radius: float32) {
    array_add(ops, UI_Op.{
        kind = .Quad,
        x0 = bb.x, y0 = bb.y, x1 = bb.x + bb.width, y1 = bb.y + bb.height,
        color = color,
        radius = radius,
    });
}

quad :: (x0: float32, y0: float32, x1: float32, y1: float32, color: F.Color) -> UI_Op {
    return UI_Op.{
        kind = .Quad,
        x0 = x0, y0 = y0, x1 = x1, y1 = y1,
        color = color,
    };
}

// clay 的颜色是 0..1 浮点 + 直通 alpha；UI 颜色是预乘 u8。
ui_color :: (c: clay.Color) -> F.Color {
    a := clamp(c[3], 0.0, 1.0);
    return F.Color.{
        cast(u8) (clamp(c[0], 0.0, 1.0) * a * 255 + 0.5),
        cast(u8) (clamp(c[1], 0.0, 1.0) * a * 255 + 0.5),
        cast(u8) (clamp(c[2], 0.0, 1.0) * a * 255 + 0.5),
        cast(u8) (a * 255 + 0.5),
    };
}
//@endregion
