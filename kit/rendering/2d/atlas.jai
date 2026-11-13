// rendering2d:atlas —— 核心图集：若干页纹理 + 「名字 -> 页号与页内像素矩形」映射。
// 一比一移植自 olib kit/rendering/2d/atlas.odin。
//
// 与来源格式无关：矩形表由各来源（网格/Kenney XML/Aseprite 打包/自定义 proc）产出，
// 经 atlas_from_rects（单页）或 atlas_from_pages（多页）注入。一页放不下时打包器开新页；
// 同一页的精灵可以合批，换页像换图集一样断批。atlas_upload 传 device 后 subtexture 才可用
// （CPU 模式可先做矩形查询）；上传后释放 CPU 像素。
//
// Jai 侧差异（逐条对应 olib 的写法，页/矩形/子图语义不变）：
//   | olib (Odin)                                     | JaiLib (Jai)                                            |
//   | ----------------------------------------------- | ------------------------------------------------------- |
//   | `map[string]Atlas_Region`                       | `HASH.Table(string, Atlas_Region)`（Hash_Table）；Jai 的表按   |
//   |                                                 | 指针传，所以形参是 `*Table`、字段是值（`*atlas.regions`）  |
//   | `for name, rect in rects`（Odin 键值顺序相反）    | `for rect, name: rects.*`（Jai 先值后键）                 |
//   | `name in atlas.regions`                         | `HASH.table_find_pointer(...) != null`                       |
//   | `delete(map)` / `delete(str)`                   | `HASH.deinit(*table)` / `free(key.data)`（先判 null）     |
//   | `foster.Image`（`.Pixels` + `ImageDispose`）      | `F.Image`（`.Data`；`F.image_destroy`）                  |
//   | `foster.Texture`（值类型 + `.Resource`）          | `*F.Texture`（堆对象 + `.handle != 0`）                   |
//   | `foster.RectInt{X,Y,Width,Height}`              | `F.Rect_Int{x,y,w,h}`                                   |
//   | `foster.TextureFromImage(dev, &img, name)`      | `F.texture_create_from_colors(dev, w, h, img.Data, name=…)` |
//   | `foster.SubtextureFromSource / SubtextureMake`  | `F.subtexture_make_source` / `F.subtexture_make`         |
//   | `foster.SubtextureEmpty`                        | `F.Subtexture_Empty`                                    |
//   | `foster.ImageLoadFile(path)`                    | `F.image_load(path)`                                    |
//   | `core:encoding/xml` 的平铺 `doc.elements` 线性扫 | `core/encoding` 的 Xml_Node 树 + `atlas_kenney_walk`（同   |
//   |                                                 | 一条「任意深度的 SubTexture 都收」规则）                    |
//   | `strconv.parse_int`                             | `atlas_parse_int`（同一条十进制 + 正负号规则）              |
//   | `strings.trim_space / has_suffix`               | `STRING.trim` / `STRING.ends_with`                       |
//   | `strings.clone(s)`                              | `copy_string(s)`（clone_owned）                          |
//   | `make([]T, n)` / `delete(x)`                    | `atlas_alloc_array(T, n)` / `free(x.data)`               |
//   | `make([dynamic]string, 0, n, allocator)`        | `atlas_temp_strings`（talloc，olib 默认也是 temp）        |
//   | 内置图标图集 builtin_icons_load / _decode | 使用 #run 相对源码路径嵌入本仓库 assets/icons |
#import "Basic";

//@region 内置图标资产

// Embed relative to this source file, independent of the host working directory.
builtin_icons_embed :: (name: string) -> string {
    bytes, ok := FILE.read_entire_file(tprint("%../../../assets/icons/%", #filepath, name));
    assert(ok && bytes.count > 0, "Missing built-in icon asset: %", name);
    return bytes;
}
BUILTIN_ICONS_XML :: #run builtin_icons_embed("game-icons.xml");
BUILTIN_ICONS_PNG :: #run builtin_icons_embed("game-icons.png");

// Caller owns both results. Pixels retain straight alpha for custom UI uploads.
builtin_icons_decode :: () -> (F.Image, *HASH.Table(string, F.Rect_Int), bool) {
    rects := kenney_build_rects(cast([] u8) BUILTIN_ICONS_XML);
    if rects == null return .{}, null, false;
    image := F.image_decode(cast([] u8) BUILTIN_ICONS_PNG);
    if image.Width != 4096 || image.Height != 4096 {
        F.image_destroy(*image);
        kenney_rects_dispose(rects);
        return .{}, null, false;
    }
    return image, rects, true;
}

// Only initialize an empty target; failure leaves it empty or unchanged.
builtin_icons_load :: (atlas: *Sprite_Atlas, device: *F.Graphics_Device) -> bool {
    if atlas == null || device == null return false;
    if atlas.has_upload || atlas.pages.data != null || atlas.regions.count != 0 return false;
    image, rects, ok := builtin_icons_decode();
    if !ok return false;
    defer kenney_rects_dispose(rects);
    F.image_premultiply(*image);
    atlas_from_rects(atlas, image, rects);
    if !atlas_upload(atlas, device) { atlas_dispose(atlas); return false; }
    return true;
}
//@endregion

//@region 类型

// 图集的一页：源像素与上传后的纹理。源像素只在上传前存在，atlas_upload 成功后释放。
Atlas_Page :: struct {
    image:   F.Image;
    texture: *F.Texture;
}

// 名字对应的区域：所在页、页内像素矩形（裁边后的内容），以及裁边前的原始帧
// （Foster 的 Subtexture.Frame 约定：x、y 为内容相对原始帧的负偏移；零值表示没有裁边）。
Atlas_Region :: struct {
    page:  int;
    rect:  F.Rect_Int;
    frame: F.Rect_Int;
}

Sprite_Atlas :: struct {
    // 构造时一次分配，之后页数不变：atlas_subtexture 返回的 Subtexture 指向页纹理，地址须长期有效。
    pages: [] Atlas_Page;

    // 名字 -> 区域。键为克隆字符串。
    regions: HASH.Table(string, Atlas_Region);

    has_upload: bool;
}
//@endregion

//@region 构造与释放

// 单页：从源图 + 矩形表构造（CPU 形态，不碰 GPU）。图集接管 image；rects 的键会被克隆。
// 需要绘制时再 atlas_upload(&atlas, device)。
atlas_from_rects :: (atlas: *Sprite_Atlas, image: F.Image, rects: *HASH.Table(string, F.Rect_Int)) {
    atlas.* = Sprite_Atlas.{
        pages   = atlas_alloc_array(Atlas_Page, 1),
        regions = HASH.Table(string, Atlas_Region).{},
    };
    atlas.pages[0].image = image;
    for rect, name: rects.* {
        HASH.table_add(*atlas.regions, clone_owned(name), Atlas_Region.{ page = 0, rect = rect });
    }
}

// 多页：图集接管 images（每页一张）；regions 的键会被克隆，页号须在 images 范围内，越界的区域丢弃。
atlas_from_pages :: (atlas: *Sprite_Atlas, images: [] F.Image, regions: *HASH.Table(string, Atlas_Region)) {
    atlas.* = Sprite_Atlas.{
        pages   = atlas_alloc_array(Atlas_Page, images.count),
        regions = HASH.Table(string, Atlas_Region).{},
    };
    for image, i: images atlas.pages[i].image = image;
    for region, name: regions.* {
        if region.page < 0 || region.page >= images.count continue;
        HASH.table_add(*atlas.regions, clone_owned(name), region);
    }
}

// 上传全部页（幂等）；全部成功后释放各页 CPU 像素。任何一页失败则释放已上传的页并返回 false，像素保留。
// 没有 device 的测试/工具流程可以永不上传。
atlas_upload :: (atlas: *Sprite_Atlas, device: *F.Graphics_Device) -> bool {
    if atlas.has_upload return true;
    if device == null || atlas.pages.count == 0 return false;
    for *page, i: atlas.pages {
        if page.image.Width > 0 {
            page.texture = F.texture_create_from_colors(device, page.image.Width, page.image.Height, page.image.Data,
                                                        name = "SpriteAtlas");
        }
        if page.texture == null || page.texture.handle == 0 {
            for *uploaded: array_view(atlas.pages, 0, i) atlas_texture_release(uploaded.texture);
            return false;
        }
    }
    for *page: atlas.pages {
        F.image_destroy(*page.image);
        page.image = F.Image.{};
    }
    atlas.has_upload = true;
    return true;
}

// 释放全部资源（页纹理/源图/区域表）。终止态调用。
atlas_dispose :: (atlas: *Sprite_Atlas) {
    if atlas.pages.data != null {
        for *page: atlas.pages {
            atlas_texture_release(page.texture);
            if page.image.Data.data != null F.image_destroy(*page.image);
        }
        array_free(atlas.pages);
    }
    for region, name: atlas.regions {
        if name.data != null free(name.data);
    }
    HASH.deinit(*atlas.regions);
    atlas.* = Sprite_Atlas.{};
}

// olib: foster.TextureDispose(&page.texture)。jfoster 的贴图是 New 出来的堆对象：
// 先还 GPU 资源（handle 有效且设备未销毁），再 free 结构体。
atlas_texture_release :: (texture: *F.Texture) {
    if texture == null return;
    if texture.handle != 0 && texture.device != null && !texture.device.disposed {
        F.texture_dispose(texture);
    }
    free(texture);
}
//@endregion

//@region 查询

atlas_get :: (atlas: *Sprite_Atlas, name: string) -> (Atlas_Region, bool) {
    region := HASH.table_find_pointer(*atlas.regions, name);
    if region == null return Atlas_Region.{}, false;
    return region.*, true;
}

atlas_has :: (atlas: *Sprite_Atlas, name: string) -> bool {
    return HASH.table_find_pointer(*atlas.regions, name) != null;
}

// 名字列表（temp 分配，仅枚举调试用）。
atlas_names :: (atlas: *Sprite_Atlas) -> [] string {
    names := atlas_temp_strings(atlas.regions.count);
    at := 0;
    for region, name: atlas.regions {
        names[at] = name;
        at += 1;
    }
    return names;
}

// 按名字取可绘制子图，指向区域所在页的纹理；裁边的区域带上原始帧，绘制原点与未裁边时一致。
// 未上传纹理或名字缺失返回 Subtexture_Empty / false。
atlas_subtexture :: (atlas: *Sprite_Atlas, name: string) -> (F.Subtexture, bool) {
    region := HASH.table_find_pointer(*atlas.regions, name);
    if region == null || !atlas.has_upload return F.Subtexture_Empty, false;
    texture := atlas.pages[region.page].texture;
    source := F.Rect.{ cast(float32) region.rect.x, cast(float32) region.rect.y,
                       cast(float32) region.rect.w, cast(float32) region.rect.h };
    if region.frame.w <= 0 || region.frame.h <= 0 {
        // 图集坐标只用于采样；未裁边子图的绘制原点始终是本地 (0, 0)。
        return F.subtexture_make_source(texture, source), true;
    }
    frame := F.Rect.{ cast(float32) region.frame.x, cast(float32) region.frame.y,
                      cast(float32) region.frame.w, cast(float32) region.frame.h };
    return F.subtexture_make(texture, source, frame), true;
}
//@endregion

//@region 网格来源

// atlas:grid —— 等分网格图集来源（对位 DragonLib GridAtlasSource）。
//
// 无坐标文件，按 cellW×cellH 均匀切格，名字为 "r{行}_c{列}"（从 0 起），
// 适合简单 tilesheet。

// 按等分网格产出矩形表（分配于 context.allocator，键随表存活；
// 注入图集后用 grid_rects_dispose 释放原件）。
grid_build_rects :: (atlas_width: int, atlas_height: int, cell_w: int, cell_h: int) -> *HASH.Table(string, F.Rect_Int) {
    rects := New(HASH.Table(string, F.Rect_Int));
    cols := atlas_width / cell_w;
    rows := atlas_height / cell_h;
    for r: 0..rows - 1 {
        for c: 0..cols - 1 {
            key := atlas_grid_key(r, c);
            HASH.table_set(rects, key, F.Rect_Int.{ x = cast(s32) (c * cell_w), y = cast(s32) (r * cell_h),
                                                 w = cast(s32) cell_w, h = cast(s32) cell_h });
        }
    }
    return rects;
}

// 便捷入口：网格图（读 PNG -> 切格 -> 图集，CPU 形态，之后 atlas_upload）。
grid_atlas_load :: (atlas: *Sprite_Atlas, png_path: string, cell_w: int, cell_h: int) -> bool {
    image := F.image_load(png_path);
    if image.Width <= 0 return false;

    rects := grid_build_rects(image.Width, image.Height, cell_w, cell_h);
    atlas_from_rects(atlas, image, rects);
    grid_rects_dispose(rects);
    return true;
}

// 释放 grid_build_rects 的产出（克隆进图集后的原件）。
grid_rects_dispose :: (rects: *HASH.Table(string, F.Rect_Int)) {
    if rects == null return;
    for rect, key: rects.* {
        if key.data != null free(key.data);
    }
    HASH.deinit(rects);
    free(rects);
}

// olib: fmt.aprintf("r%d_c%d", r, c, allocator = context.allocator)。tprint 借 temp，再复制一份持有。
atlas_grid_key :: (row: int, column: int) -> string {
    return copy_string(tprint("r%_c%", row, column));
}
//@endregion

//@region Kenney XML 来源

// atlas:kenney —— Kenney / Starling 风格 XML 图集来源（对位 DragonLib KenneyXmlAtlasSource）。
//
// 格式：<TextureAtlas><SubTexture name x y width height/>…</TextureAtlas>
// 每个子图额外收一份去掉 ".png" 后缀的别名，调用处写短名更省事。

// 解析 Kenney/Starling XML 坐标（分配于 context.allocator，键随表存活；
// 注入图集后用 kenney_rects_dispose 释放原件）。解析失败返回 null。
kenney_build_rects :: (xml_bytes: [] u8) -> *HASH.Table(string, F.Rect_Int) {
    // olib: xml.parse_bytes(xml_bytes)；JaiLib 的 XML 树要求 string 输入（同一条 UTF-8 校验）。
    document, error := XML.xml_parse(cast(string) xml_bytes);
    if error != .None || document == null return null;
    defer XML.xml_destroy(document);

    rects := New(HASH.Table(string, F.Rect_Int));
    // olib 用平铺的 doc.elements 线性扫；JaiLib 的树按层展开，递归收同名元素（结果相同）。
    atlas_kenney_walk(document, rects);
    return rects;
}

// 收集一棵子树里的全部 SubTexture（任意深度）。
atlas_kenney_walk :: (node: *XML.Xml_Node, rects: *HASH.Table(string, F.Rect_Int)) {
    if node == null return;
    if node.name == "SubTexture" {
        name_value, has_name := XML.xml_attribute(node, "name");
        x, y, w, h: s32 = 0, 0, 0, 0;
        value: string;
        has: bool;
        value, has = XML.xml_attribute(node, "x");
        if has x = cast(s32) atlas_parse_int(value);
        value, has = XML.xml_attribute(node, "y");
        if has y = cast(s32) atlas_parse_int(value);
        value, has = XML.xml_attribute(node, "width");
        if has w = cast(s32) atlas_parse_int(value);
        value, has = XML.xml_attribute(node, "height");
        if has h = cast(s32) atlas_parse_int(value);
        if has_name && name_value != "" {
            rect := F.Rect_Int.{ x = x, y = y, w = w, h = h };
            HASH.table_add(rects, copy_string(name_value), rect);
            if STRING.ends_with(name_value, ".png") {
                // 去后缀别名
                alias := atlas_substring(name_value, 0, name_value.count - 4);
                HASH.table_add(rects, copy_string(alias), rect);
            }
        }
    }
    for child: node.children atlas_kenney_walk(child, rects);
}

// 释放 kenney_build_rects 的产出。
kenney_rects_dispose :: (rects: *HASH.Table(string, F.Rect_Int)) {
    if rects == null return;
    for rect, key: rects.* {
        if key.data != null free(key.data);
    }
    HASH.deinit(rects);
    free(rects);
}

// olib: strconv.parse_int(strings.trim_space(s))——只认十进制与正负号，失败返回 0。
atlas_parse_int :: (text: string) -> int {
    trimmed := STRING.trim(text);
    if trimmed.count == 0 return 0;
    negative := false;
    at := 0;
    if trimmed[0] == #char "+" || trimmed[0] == #char "-" {
        negative = trimmed[0] == #char "-";
        at = 1;
    }
    if at >= trimmed.count return 0;
    value := 0;
    while at < trimmed.count {
        c := trimmed[at];
        if c < #char "0" || c > #char "9" return 0;
        value = value * 10 + cast(int) (c - #char "0");
        at += 1;
    }
    if negative return -value;
    return value;
}
//@endregion

//@region 包内共享辅助 —— 字符串克隆 / 路径拼接 / 临时数组（context.allocator，调用方持有）

// olib: strings.clone(s, context.allocator)。
clone_owned :: (text: string) -> string {
    return copy_string(text);
}

join_owned :: (a: string, b: string) -> string {
    if a == "" return clone_owned(b);
    return STRING.join(a, b, separator = "/");
}

// olib: s[:len(s) - n]。Jai 的 Basic 没有 substring（material 包也自带一份）。
atlas_substring :: (text: string, start: int, end: int) -> string {
    if end <= start return "";
    return string.{ data = text.data + start, count = end - start };
}

// olib: make([]T, count)。alloc + 清零；用 free(x.data) 释放。
atlas_alloc_array :: ($T: Type, count: int) -> [] T {
    if count <= 0 return .[];
    memory := alloc(cast(s64) (count * size_of(T)));
    assert(memory != null, "atlas: 分配失败");
    memset(memory, 0, cast(s64) (count * size_of(T)));
    return .{ count, cast(*T) memory };
}

// olib: make([dynamic]string, 0, capacity, allocator = context.temp_allocator)。
// Jai 的对应物是 talloc：随下次 reset_temporary_storage 回收，借用契约相同。
atlas_temp_strings :: (count: int) -> [] string {
    if count <= 0 return .[];
    memory := talloc(cast(s64) (count * size_of(string)));
    assert(memory != null, "atlas: 临时分配失败");
    memset(memory, 0, cast(s64) (count * size_of(string)));
    return .{ count, cast(*string) memory };
}
//@endregion
