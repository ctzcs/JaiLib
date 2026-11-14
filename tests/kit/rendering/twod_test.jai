// 一比一移植自 olib tests/kit/rendering/2d/*.odin
// （rendering2d_test / render2d_test / sprite_buffer_test 三个文件里的 CPU 侧用例；
//   olib_include_test 的 hlsli 块大小校验不属于本包移植范围——include 文件不在本仓库，
//   见 kit/rendering/2d/module.jai 第 4 条与 SPRITE_*_BLOCK_SIZE 的注释）。
//
// 断言顺序、数值与诊断文本与 olib 一一对应。Jai 侧的写法差异：
//   | olib (Odin, core:testing)                   | 这里 (Jai, Tests/test_support.jai)                     |
//   | ------------------------------------------- | ------------------------------------------------------ |
//   | testing.expect(t, cond)                     | expect(state, cond, "说明")                             |
//   | testing.expect_value(t, a, b)               | expect(state, a == b, "说明")                           |
//   | testing.expectf(t, cond, "%v", a)           | expect(state, cond, "说明 % -> %", a, b)                 |
//   | 每个测试文件自己的 package                    | 单文件、过程名与 olib 测试名相同                          |
//   | `frame := foster.SubtextureMake(&tex, …)`   | `*F.Texture`（堆对象 + handle），`F.subtexture_make`      |
//   | `foster.GraphicsDevice{…}` 当假设备           | `F.Graphics_Device` + `disposed = false`（jfoster 的零值   |
//   |                                             | 设备是「已销毁」）                                        |
//   | `Texture{Width = 256}`                       | `New(F.Texture)` + Width/Height + handle                 |
//   | `Subtexture.Texture` / `BoundSampler.Texture`| `.Tex`                                                  |
//   | `map[string]T` + `rects^[name]`              | `HASH.Table(string, T)` + `HASH.table_find`              |
//   | `len(x)`                                     | `x.count`                                               |
//   | `[]f32{…}` / `{1, 2}`                        | `.[…]`；结构体比较逐字段（Jai 的数组不能 `==`）             |
//   | `mat.Material_Library{device = &dev}`        | `mat.Material_Library.{ device = *dev }`                |
//   | `make([]T, n, context.temp_allocator)`       | `sh.shader_alloc_array` / `mat.material_temp_array`      |
#import "Basic";
#import "test_support";
F :: #import "foster";
mat :: #import "kit/rendering/material";
sh :: #import "kit/rendering/shader";
HASH :: #import "Hash_Table";

builtin_icons_assets_decode :: (state: *Test_State) {
    image, rects, ok := builtin_icons_decode();
    expect(state, ok, "embedded icon PNG/XML decode without CWD assets");
    if !ok return;
    defer F.image_destroy(*image);
    defer kenney_rects_dispose(rects);
    expect(state, image.Width == 4096 && image.Height == 4096, "icon atlas dimensions");
    expect(state, rects.count == 815, "all 815 icon names are available");
    rect := HASH.table_find_pointer(rects, "game/action-points");
    expect(state, rect != null && rect.w == 128 && rect.h == 128, "named icon resolves to its original region");
    atlas: Sprite_Atlas;
    expect(state, !builtin_icons_load(*atlas, null), "missing GPU rejected without changing target");
    expect(state, atlas.pages.count == 0 && !atlas.has_upload, "rejected load leaves empty target");
}

#import "kit/rendering/2d";

//@region 工具

// Jai 的定长数组没有 ==（只做逐元素比较），向量交给这个。
floats4_eq :: (a: [4] float32, b: [4] float32) -> bool {
    for i: 0..3 {
        if a[i] != b[i] return false;
    }
    return true;
}

vec2_eq :: (a: F.Vector2, b: F.Vector2) -> bool {
    return a.x == b.x && a.y == b.y;
}

// 只构造纹理尺寸元数据，不创建 GPU 资源（olib 的零值 foster.Texture + Width/Height）。
// handle 非零只是为了走真实的就绪判据；device 为 null，释放路径不会碰 GPU。
fake_texture :: (width: s32, height: s32) -> *F.Texture {
    texture := New(F.Texture);
    texture.Width = width;
    texture.Height = height;
    texture.handle = 1;
    return texture;
}

// olib: atlas_key(rects, name) —— 名字 -> 矩形。
rect_table_get :: (rects: *HASH.Table(string, F.Rect_Int), name: string) -> (F.Rect_Int, bool) {
    found, value := HASH.table_find(rects, name);
    return value, found;
}

// olib: delete(map)。键是 copy_string 出来的，逐个还掉再收表。
region_table_dispose :: (regions: *HASH.Table(string, Atlas_Region)) {
    if regions == null return;
    for region, name: regions.* {
        if name.data != null free(name.data);
    }
    HASH.deinit(regions);
}

// aseprite_expand_tag / animation_set 的切片产物（atlas_alloc_array）用 free(x.data) 还。
free_strings :: (values: [] string) {
    if values.data != null free(values.data);
}

free_floats :: (values: [] float32) {
    if values.data != null free(values.data);
}

//@endregion

//@region 图集子图与网格 / Kenney 来源（olib rendering2d_test 第一批）

// 裁剪图集的绘制坐标必须保留 draw 坐标的原点：帧内偏移只影响 UV。
frame_corners_preserve_trim_atlas_and_origin :: (state: *Test_State) {
    texture := fake_texture(256, 128);
    defer free(texture);
    frame := F.subtexture_make(texture, F.Rect.{ 64, 32, 32, 16 }, F.Rect.{ -4, -6, 48, 32 });
    corners := render2d_frame_corners(frame, F.Vector2.{ 24, 16 }, F.Matrix3x2.{ 2, 0, 0, 3, 100, 50 });
    expect(state, vec2_eq(corners[0], F.Vector2.{ 60, 20 }), "第一角 % -> (60, 20)", corners[0]);
    expect(state, vec2_eq(corners[2], F.Vector2.{ 124, 68 }), "对角 % -> (124, 68)", corners[2]);
    expect(state, vec2_eq(frame.TexCoords[0], F.Vector2.{ 0.25, 0.25 }), "UV 起点 % -> (0.25, 0.25)",
    frame.TexCoords[0]);
    expect(state, vec2_eq(frame.TexCoords[2], F.Vector2.{ 0.375, 0.375 }), "UV 终点 % -> (0.375, 0.375)",
    frame.TexCoords[2]);
}

// 4 列 x 2 行，名字 r{行}_c{列}，越界名字查不到。
grid_build_rects_cells :: (state: *Test_State) {
    rects := grid_build_rects(64, 32, 16, 16);
    defer grid_rects_dispose(rects);

    expect(state, rects.count == 8, "应有 8 格: %", rects.count);

    r0c0, ok0 := rect_table_get(rects, "r0_c0");
    expect(state, ok0 && r0c0 == F.Rect_Int.{ 0, 0, 16, 16 }, "r0_c0 应为 (0, 0, 16, 16)");
    r0c3, ok3 := rect_table_get(rects, "r0_c3");
    expect(state, ok3 && r0c3 == F.Rect_Int.{ 48, 0, 16, 16 }, "r0_c3 应为 (48, 0, 16, 16)");
    r1c1, ok1 := rect_table_get(rects, "r1_c1");
    expect(state, ok1 && r1c1 == F.Rect_Int.{ 16, 16, 16, 16 }, "r1_c1 应为 (16, 16, 16, 16)");

    _, missing := rect_table_get(rects, "r2_c0"); // 只有两行
    expect(state, !missing, "越界行查不到");
}

// 3 个子图 + 2 个去 .png 别名；没有后缀的只有本名。
KENNEY_XML :: "<TextureAtlas imagePath=\"sheet.png\"><SubTexture name=\"player_idle0.png\" x=\"0\" y=\"0\" width=\"16\" height=\"24\"/><SubTexture name=\"player_idle1.png\" x=\"16\" y=\"0\" width=\"16\" height=\"24\"/><SubTexture name=\"coin\" x=\"32\" y=\"0\" width=\"8\" height=\"8\"/></TextureAtlas>";

kenney_build_rects_parse :: (state: *Test_State) {
    xml: string = KENNEY_XML;
    rects := kenney_build_rects(cast([] u8) xml);
    defer if rects != null kenney_rects_dispose(rects);

    expect(state, rects != null, "解析失败");
    if rects == null return;
    expect(state, rects.count == 5, "3 子图 + 2 个去 .png 别名: %", rects.count);

    full, ok_full := rect_table_get(rects, "player_idle0.png");
    expect(state, ok_full && full == F.Rect_Int.{ 0, 0, 16, 24 }, "player_idle0.png 应为 (0, 0, 16, 24)");

    alias, ok_alias := rect_table_get(rects, "player_idle0"); // 去后缀别名
    expect(state, ok_alias && alias == F.Rect_Int.{ 0, 0, 16, 24 }, "去后缀别名指向同一矩形");

    coin, ok_coin := rect_table_get(rects, "coin"); // 无后缀只有本名
    expect(state, ok_coin && coin == F.Rect_Int.{ 32, 0, 8, 8 }, "coin 应为 (32, 0, 8, 8)");

    _, nope := rect_table_get(rects, "absent");
    expect(state, !nope, "不存在的名字");
}

// 图集中的偏移只能影响 UV，不能把图标顶点移到本地原点之外。
atlas_subtexture_uses_local_origin :: (state: *Test_State) {
    atlas: Sprite_Atlas;
    defer atlas_dispose(*atlas);
    atlas.pages = atlas_alloc_array(Atlas_Page, 1);
    atlas.regions = HASH.Table(string, Atlas_Region).{};
    HASH.table_add(*atlas.regions, copy_string("ui/test"),
    Atlas_Region.{ rect = F.Rect_Int.{ 266, 398, 128, 128 } });
    // 这里只构造纹理尺寸元数据，不创建 GPU 资源。
    atlas.pages[0].texture = fake_texture(4096, 4096);

    _, before_upload := atlas_subtexture(*atlas, "ui/test");
    expect(state, !before_upload, "上传前没有子图");
    atlas.has_upload = true;
    sub, ok := atlas_subtexture(*atlas, "ui/test");
    expect(state, ok && sub.Tex == atlas.pages[0].texture, "子图指向该页纹理");
    expect(state, sub.Frame == F.Rect.{ 0, 0, 128, 128 }, "未裁边：Frame 就是内容矩形");
    expect(state, vec2_eq(sub.DrawCoords[0], F.Vector2.{ 0, 0 }), "绘制原点在本地 (0, 0)");
    expect(state, vec2_eq(sub.DrawCoords[2], F.Vector2.{ 128, 128 }), "绘制右下角在本地 (128, 128)");
    expect(state, vec2_eq(sub.TexCoords[0], F.Vector2.{ 266.0 / 4096, 398.0 / 4096 }),
    "UV 起点取图集偏移 %", sub.TexCoords[0]);
    expect(state, vec2_eq(sub.TexCoords[2], F.Vector2.{ 394.0 / 4096, 526.0 / 4096 }),
    "UV 终点取图集偏移 %", sub.TexCoords[2]);
    _, missing := atlas_subtexture(*atlas, "missing");
    expect(state, !missing, "缺失名字返回 false");
}

// 多页：子图指向区域所在页的纹理；裁边的区域保留原始帧，绘制位置与未裁边时一致；越界页号的区域丢弃。
atlas_pages_pick_texture_and_keep_trim :: (state: *Test_State) {
    images := atlas_alloc_array(F.Image, 2);
    images[0] = F.image_create(64, 64);
    images[1] = F.image_create(32, 32);
    regions := HASH.Table(string, Atlas_Region).{};
    defer region_table_dispose(*regions);
    HASH.table_add(*regions, copy_string("a"), Atlas_Region.{ page = 0, rect = F.Rect_Int.{ 0, 0, 16, 16 } });
    // 原始帧 20×20，裁边后内容 10×12，位于原始帧内的 (4, 3)
    HASH.table_add(*regions, copy_string("b"), Atlas_Region.{ page = 1, rect = F.Rect_Int.{ 8, 8, 10, 12 },
    frame = F.Rect_Int.{ -4, -3, 20, 20 } });
    HASH.table_add(*regions, copy_string("bad"), Atlas_Region.{ page = 2, rect = F.Rect_Int.{ 0, 0, 1, 1 } });

    atlas: Sprite_Atlas;
    atlas_from_pages(*atlas, images, *regions);
    defer atlas_dispose(*atlas);
    expect(state, atlas.pages.count == 2, "两页: %", atlas.pages.count);
    expect(state, !atlas_has(*atlas, "bad"), "越界页号的区域丢弃");
    region, found := atlas_get(*atlas, "b");
    expect(state, found && region.page == 1, "b 保留在第 1 页");

    for *page: atlas.pages page.texture = fake_texture(page.image.Width, page.image.Height);
    atlas.has_upload = true; // 只验证子图计算；atlas_dispose 跳过没有 GPU 资源的纹理
    a, a_ok := atlas_subtexture(*atlas, "a");
    b, b_ok := atlas_subtexture(*atlas, "b");
    expect(state, a_ok && b_ok && a.Tex == atlas.pages[0].texture && b.Tex == atlas.pages[1].texture,
    "子图各自指向所在页的纹理");
    expect(state, vec2_eq(b.DrawCoords[0], F.Vector2.{ 4, 3 }), "裁边内容起点 % -> (4, 3)", b.DrawCoords[0]);
    expect(state, vec2_eq(b.DrawCoords[2], F.Vector2.{ 14, 15 }), "裁边内容终点 % -> (14, 15)", b.DrawCoords[2]);
    expect(state, vec2_eq(b.TexCoords[0], F.Vector2.{ 8.0 / 32, 8.0 / 32 }), "UV 起点 %", b.TexCoords[0]);
    expect(state, vec2_eq(F.subtexture_size(b), F.Vector2.{ 20, 20 }), "尺寸取原始帧 %");
}

//@endregion

//@region Animation_Set 动画采样

// 各帧中点命中对应帧；loop 回绕；不循环夹到最后帧；未知名字返回 null。
animation_set_get_frame_at_walks :: (state: *Test_State) {
    sprite: Animation_Set;
    animation_set_init(*sprite, "coin");
    defer animation_set_dispose(*sprite);

    // 3 帧：0.1s / 0.2s / 0.3s，动画覆盖全部
    durations: [3] float32 = .[0.1, 0.2, 0.3];
    for i: 0..2 animation_set_add_frame(*sprite, F.Subtexture_Empty, durations[i]);
    animation_set_add_animation(*sprite, "spin", 0, 3);

    anim := animation_set_get_animation(*sprite, "spin");
    expect(state, anim != null, "应找到动画");
    if anim == null return;

    total: float32 = 0;
    for i: 0..2 total += durations[i];
    expect(state, anim.duration == total, "总时长 0.6: % -> %", anim.duration, total);

    // 各帧中点采样
    cases: [3] float32 = .[0.05, 0.2, 0.45];
    for i: 0..2 {
        frame, ok := animation_set_get_frame_at(*sprite, anim, cases[i], true);
        index := frame_duration_index(durations, frame.duration);
        expect(state, ok && index == i, "t=% 应命中帧 %, 实际 %", cases[i], i, index);
    }

    // loop：循环回绕到第 0 帧
    wrap, ok := animation_set_get_frame_at(*sprite, anim, 0.65, true);
    expect(state, ok && wrap.duration == durations[0], "回绕到第 0 帧: %", wrap.duration);

    // 不循环：超出夹到最后帧
    clamp, ok2 := animation_set_get_frame_at(*sprite, anim, 99, false);
    expect(state, ok2 && clamp.duration == durations[2], "夹到最后帧: %", clamp.duration);

    // 未知动画名
    expect(state, animation_set_get_animation(*sprite, "nope") == null, "未知动画名返回 null");
}

frame_duration_index :: (durations: [3] float32, d: float32) -> int {
    for i: 0..2 {
        if durations[i] == d return i;
    }
    return -1;
}
//@endregion

//@region Aseprite slug 与 tag 展开

// 小写、非字母数字归为下划线、去掉首尾与重复的下划线。
aseprite_slug_cleans_names :: (state: *Test_State) {
    cases: [5][2] string = .[
    .["Hero Idle", "hero_idle"],
    .["player-2.WALK!!", "player_2_walk"],
    .["  _leading", "leading"],
    .["trailing__", "trailing"],
    .["MiXeD CaSe", "mixed_case"],
    ];
    for tc: cases {
        slug := aseprite_slug(tc[0]);
        defer if slug.data != null free(slug.data);
        expect(state, slug == tc[1], "slug(%) = %, want %", tc[0], slug, tc[1]);
    }
}

// 正向 / 反向 / 乒乓 / 反乒乓的帧序；越界区间被钳制。
aseprite_expand_tag_variants :: (state: *Test_State) {
    regions := atlas_alloc_array(string, 3);
    durations := atlas_alloc_array(float32, 3);
    regions[0], regions[1], regions[2] = "a", "b", "c";
    durations[0], durations[1], durations[2] = 0.1, 0.1, 0.1;

    fwd, fwd_d := aseprite_expand_tag(regions, durations, 0, 2, .FORWARD);
    expect(state, fwd.count == 3 && fwd[0] == "a", "Forward 应展开为 a b c: %", fwd.count);
    expect(state, fwd_d.count == 3, "Forward 时长同步");
    free_strings(fwd);
    free_floats(fwd_d);

    rev, rev_d := aseprite_expand_tag(regions, durations, 0, 2, .REVERSE);
    expect(state, rev.count == 3 && rev[0] == "c" && rev[2] == "a", "Reverse 应展开为 c b a");
    free_strings(rev);
    free_floats(rev_d);

    // a b c -> a b c b
    pp, pp_d := aseprite_expand_tag(regions, durations, 0, 2, .PINGPONG);
    expect(state, pp.count == 4 && pp[0] == "a" && pp[2] == "c" && pp[3] == "b",
    "PingPong 应展开为 a b c b: %", pp.count);
    expect(state, pp_d.count == 4, "PingPong 时长同步");
    free_strings(pp);
    free_floats(pp_d);

    // 反转后 c b a -> c b a b
    ppr, ppr_d := aseprite_expand_tag(regions, durations, 0, 2, .PINGPONG_REVERSE);
    expect(state, ppr.count == 4 && ppr[0] == "c" && ppr[3] == "b", "PingPongReverse 应展开为 c b a b");
    free_strings(ppr);
    free_floats(ppr_d);

    // 越界区间被钳制
    oob, oob_d := aseprite_expand_tag(regions, durations, 1, 99, .FORWARD);
    expect(state, oob.count == 2 && oob[0] == "b" && oob[1] == "c", "越界区间钳制到 b c");
    free_strings(oob);
    free_floats(oob_d);

    free(regions.data);
    free(durations.data);
}

// clip 独立拥有 controller / name：同一文件的多条动画共用控制器名、名字可为字面量，也能各自释放。
aseprite_clips_own_their_strings :: (state: *Test_State) {
    controller := clone_owned("hero");
    defer if controller.data != null free(controller.data);
    frames: [2] string = .["hero/0", "hero/1"];
    durations: [2] float32 = .[0.1, 0.2];
    first := aseprite_make_clip(controller, "default", array_view(frames, 0, 2), array_view(durations, 0, 2), true);
    second := aseprite_make_clip(controller, "walk", array_view(frames, 0, 2), array_view(durations, 0, 2), false);
    expect(state, first.controller == "hero" && first.controller.data != second.controller.data,
    "两条剪辑各自持有 controller");
    expect(state, first.controller.data != controller.data, "clip 复制入参而不是借用");
    expect(state, first.name == "default" && second.name == "walk" && !second.loop, "名字与 loop 独立");
    expect(state, first.frames.count == 2 && second.frames.count == 2, "帧表已克隆");
    built_clip_dispose(*first);
    built_clip_dispose(*second);
}
//@endregion

//@region 常驻精灵实例缓冲

// 记录布局就是 GPU 的前 80 字节：rect / uv / tint 偏移与 stride 都要对。
sprite_item_matches_gpu_record_layout :: (state: *Test_State) {
    // 带裁剪的子图：Source 在贴图 (32,64) 起 16x8，Frame 为未裁剪的 24x24（裁掉左右各 4 像素、上下各 8 像素）。
    texture := fake_texture(128, 128);
    defer free(texture);
    frame := F.subtexture_make(texture, F.Rect.{ 32, 64, 16, 8 }, F.Rect.{ -4, -8, 24, 24 });
    item := sprite_item_make(frame, F.Vector2.{ 12, 12 }, F.Matrix3x2.{ 2, 0, 0, 3, 100, 200 }, .[0.5, 0.25, 1, 1]);
    expect(state, floats4_eq(item.rect, .[-8, -4, 16, 8]), "局部矩形 = 裁剪起点 - 锚点 %", item.rect);
    expect(state, floats4_eq(item.uv, .[0.25, 0.5, 0.125, 0.0625]), "UV 矩形 %.", item.uv);
    expect(state, size_of(Sprite_Item) == 80, "与 GPU 记录同一布局: %", size_of(Sprite_Item));
    expect(state, offset_of(Sprite_Item, "tint") == 64, "tint 偏移 64");
    expect(state, sprite_stride(0) == 80, "无字段 stride 80: %", sprite_stride(0));
    expect(state, sprite_stride(2) == 112, "两个字段 stride 112: %", sprite_stride(2));
}

// 缓冲创建的各种拒绝路径与 r2d.buffer 的错误码都在提交前返回。
sprite_buffer_guards_and_draw_errors :: (state: *Test_State) {
    buf: Sprite_Buffer;
    device: F.Graphics_Device;
    library := mat.Material_Library.{ device = *device };
    plain_passes := sh.shader_alloc_array(sh.Pass_Desc, 1);
    plain_passes[0] = sh.Pass_Desc.{ draw = .Sprite };
    plain := mat.Material_Shader.{ desc = sh.Shader_Desc.{ passes = plain_passes } };
    instanced_passes := sh.shader_alloc_array(sh.Pass_Desc, 1);
    instanced_passes[0] = sh.Pass_Desc.{ draw = .Sprite };
    instanced := mat.Material_Shader.{ desc = sh.Shader_Desc.{ passes = instanced_passes, instanced = true } };

    expect(state, sprite_buffer_init(*buf, null, 10) == "Material is not loaded", "没有材质");
    no_owner := mat.Material.{ shader = *instanced };
    expect(state, sprite_buffer_init(*buf, *no_owner, 10) == "Material is not loaded", "材质没有 owner");
    plain_material := mat.Material.{ owner = *library, shader = *plain };
    expect(state, sprite_buffer_init(*buf, *plain_material, 10) == "Sprite buffers require an Instanced sprite shader",
    "非 instanced Shader");
    ok_material := mat.Material.{ owner = *library, shader = *instanced };
    expect(state, sprite_buffer_init(*buf, *ok_material, 0) == "Sprite buffer capacity must be positive",
    "容量必须为正");

    items: [2] Sprite_Item;
    expect(state, !sprite_buffer_upload(*buf, array_view(items, 0, 2)), "未创建");
    buf.capacity = 1;
    expect(state, !sprite_buffer_upload(*buf, array_view(items, 0, 2)), "超出容量");
    expect(state, !sprite_buffer_upload(*buf, array_view(items, 0, 1), 1), "起始下标越界");
    buf.capacity, buf.slots = 2, 2;
    short_values := mat.material_temp_array([4] float32, 3);
    expect(state, !sprite_buffer_upload(*buf, array_view(items, 0, 2), 0, array_view(short_values, 0, 3)),
    "values 长度应为 2×2");

    // r2d.buffer 的错误码：都在提交前返回。
    r: Render2D;
    r.library = *library;
    defer dispose(*r);
    render2d_reset_state(*r);
    atlas := fake_texture(16, 16);
    defer free(atlas);
    expect(state, buffer(*r, null, *buf, 1, atlas) == mat.Draw_Error.Missing_Material, "没有材质");
    expect(state, buffer(*r, *plain_material, *buf, 1, atlas) == mat.Draw_Error.Not_Instanced_Shader,
    "非 instanced Shader");
    programs := sh.shader_alloc_array(*F.Shader, 1);
    instanced.instanced_vertex = programs;
    ok_material.shader = *instanced;
    expect(state, buffer(*r, *ok_material, null, 1, atlas) == mat.Draw_Error.Instance_Buffer_Required,
    "缓冲未创建");
    expect(state, buffer(*r, *ok_material, *buf, 1, atlas) == mat.Draw_Error.Instance_Mismatch,
    "材质 0 个字段，缓冲 2 个");
    buf.slots = 0;
    expect(state, buffer(*r, *ok_material, *buf, 1, null) == mat.Draw_Error.Missing_Sprite_Texture,
    "缺帧贴图");
}
//@endregion

//@region Render2D 状态栈 / 错误码 / 分段（olib render2d_test）

// 只检查 CPU 侧的状态栈；不创建窗口，也不伪造 GPU 句柄。
render2d_stacks_follow_batcher_semantics :: (state: *Test_State) {
    r: Render2D;
    defer dispose(*r);
    render2d_reset_state(*r);
    expect(state, vec2_eq(render2d_transform(*r, F.Vector2.{ 2, 3 }), F.Vector2.{ 2, 3 }), "单位变换");

    push_matrix_trs(*r, F.Vector2.{ 10, 0 }, F.Vector2.{ 1, 1 }, 0); // 相机
    push_matrix_trs(*r, F.Vector2.{ 0, 0 }, F.Vector2.{ 2, 2 }, 0); // 物体：先缩放，再接相机平移
    expect(state, vec2_eq(render2d_transform(*r, F.Vector2.{ 1, 1 }), F.Vector2.{ 12, 2 }), "缩放再平移 %");
    pop_matrix(*r);
    expect(state, vec2_eq(render2d_transform(*r, F.Vector2.{ 1, 1 }), F.Vector2.{ 11, 1 }), "弹出物体后只剩相机 %");
    push_matrix(*r, F.Matrix3x2.{ 1, 0, 0, 1, 5, 5 }, relative = false);
    expect(state, vec2_eq(render2d_transform(*r, F.Vector2.{ 0, 0 }), F.Vector2.{ 5, 5 }), "相对 = false 直接替换 %");
    pop_matrix(*r);
    pop_matrix(*r);
    pop_matrix(*r); // 空栈弹出不改变状态
    expect(state, vec2_eq(render2d_transform(*r, F.Vector2.{ 1, 1 }), F.Vector2.{ 1, 1 }), "栈空回到单位变换");

    push_mode(*r, .FILL);
    expect(state, r.mode_color == F.Color.{ 0, 0, 255, 0 }, "Fill 模式色");
    pop_mode(*r);
    expect(state, r.mode_color == F.Color.{ 255, 0, 0, 0 }, "Normal 模式色");

    push_scissor(*r, F.Rect_Int.{ 1, 2, 3, 4 });
    push_scissor(*r, F.Rect_Int.{ 5, 6, 7, 8 });
    pop_scissor(*r);
    expect(state, r.has_scissor && r.scissor == F.Rect_Int.{ 1, 2, 3, 4 }, "弹出后恢复上一层裁剪");
    pop_scissor(*r);
    expect(state, !r.has_scissor, "裁剪栈空");

    push_blend(*r, F.Blend_Mode_NonPremultiplied);
    push_sampler(*r, F.texture_sampler_make(.LINEAR, .REPEAT));
    expect(state, r.blend == F.Blend_Mode_NonPremultiplied, "混合方式入栈");
    // 提交后（即使没有记录）恢复默认状态。
    expect(state, submit(*r, View.{}) == mat.Draw_Error.None, "空提交返回 None");
    expect(state, r.blend == F.Blend_Mode_Premultiply && r.sampler == F.texture_sampler_make(.NEAREST, .CLAMP),
    "提交后恢复默认混合与采样");
    expect(state, r.blend_stack.count == 0, "栈已清空: %", r.blend_stack.count);
}

// 记录阶段的错误码：没设备 / 没材质 / 设备不符 / 缺帧贴图；零长度线段与步数不足的圆不记录也不报错。
render2d_record_reports_errors :: (state: *Test_State) {
    r: Render2D;
    defer dispose(*r);
    expect(state, rect(*r, F.Rect.{ 0, 0, 1, 1 }, F.Color_White) == mat.Draw_Error.Missing_Device, "没有设备");

    device: F.Graphics_Device;
    device.disposed = false;
    other: F.Graphics_Device;
    other.disposed = false;
    library := mat.Material_Library.{ device = *device };
    r.library = *library;
    render2d_reset_state(*r);
    expect(state, rect(*r, F.Rect.{ 0, 0, 1, 1 }, F.Color_White) == mat.Draw_Error.Missing_Material, "没有材质");
    foreign_library := mat.Material_Library.{ device = *other };
    shader: mat.Material_Shader;
    alien := mat.Material.{ owner = *foreign_library, shader = *shader };
    expect(state, rect(*r, F.Rect.{ 0, 0, 1, 1 }, F.Color_White, *alien) == mat.Draw_Error.Device_Mismatch,
    "材质属于别的设备");
    expect(state, texture(*r, null, F.Matrix3x2.{ 1, 0, 0, 1, 0, 0 }) == mat.Draw_Error.Missing_Sprite_Texture,
    "空贴图");
    expect(state, image(*r, F.Subtexture_Empty, F.Matrix3x2.{ 1, 0, 0, 1, 0, 0 }) ==
    mat.Draw_Error.Missing_Sprite_Texture, "空子图");
    // 零长度线段、步数不足的圆不记录也不报错。
    expect(state, line(*r, F.Vector2.{ 1, 1 }, F.Vector2.{ 1, 1 }, 2, F.Color_White, *alien) == mat.Draw_Error.None,
    "零长度线段");
    expect(state, circle(*r, F.Vector2.{ 0, 0 }, 1, 2, F.Color_White, *alien) == mat.Draw_Error.None, "步数不足的圆");
    expect(state, r.vertices.count == 0, "没有记录顶点: %", r.vertices.count);
}

// 段的拆分条件：材质、Pass、帧贴图、采样器、混合、裁剪或材质 revision 任何一项不同都开新段。
render2d_runs_split_on_state_and_parameters :: (state: *Test_State) {
    r: Render2D;
    defer dispose(*r);
    device: F.Graphics_Device;
    device.disposed = false;
    library := mat.Material_Library.{ device = *device };
    r.library = *library;
    render2d_reset_state(*r);

    fields := sh.shader_alloc_array(sh.Field, 3);
    fields[0] = sh.Field.{ id = "texture", name = "texture", kind = .Texture };
    fields[1] = sh.Field.{ id = "strength", name = "strength", kind = .Scalar, maximum = 1 };
    fields[2] = sh.Field.{ id = "mask", name = "mask", kind = .Texture };
    schema := sh.Schema.{ name = "Glow", preview = "2d", fields = fields };
    passes := sh.shader_alloc_array(sh.Pass_Desc, 1);
    passes[0] = sh.Pass_Desc.{ id = "main", params = "Glow", output = "color", draw = .Sprite,
    sprite_texture = "texture" };
    shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ name = "Glow", output = "color", preview = "2d",
    passes = passes } };
    // jfoster 的 Material 是堆对象，两个阶段都要挂上可用的程序（material_program_ready）。
    vertex_program := New(F.Shader);
    vertex_program.Stage = .VERTEX;
    vertex_program.handle = 1;
    fragment_program := New(F.Shader);
    fragment_program.Stage = .FRAGMENT;
    fragment_program.handle = 1;
    gpu := F.material_create(vertex_program, fragment_program);
    defer F.material_destroy(gpu);
    values := sh.shader_alloc_array(sh.Value, 3); // 参数 strength 为 0.5
    values[1] = sh.Value.{ number = .[0.5, 0, 0, 0] };
    white := fake_texture(8, 8);
    defer free(white);
    atlas := fake_texture(64, 64);
    defer free(atlas);
    samplers := sh.shader_alloc_array(F.Bound_Sampler, 2);
    samplers[0] = F.Bound_Sampler.{ Tex = white };
    samplers[1] = F.Bound_Sampler.{ Tex = white };
    bindings := sh.shader_alloc_array(mat.Material_Binding, 1);
    bindings[0] = mat.Material_Binding.{ schema = schema, values = values, material = gpu, samplers = samplers };
    material := mat.Material.{ owner = *library, shader = *shader, bindings = bindings };
    selection := mat.Pass_Selection.{ count = 1 };

    render2d_run_begin(*r, *material, "", atlas, selection, null);
    run := *r.runs[0];
    expect(state, render2d_run_matches(*r, run, *material, "", atlas, selection), "同参数继续合批");
    run.quad_count = RENDER2D_BATCH_QUADS;
    expect(state, !render2d_run_matches(*r, run, *material, "", atlas, selection), "达到段上限就断批");
    run.quad_count = 0;
    expect(state, r.snapshots[0].Fragment.Samplers[0].Tex == atlas, "帧贴图替换到 sprite_texture 槽");
    expect(state, r.snapshots[0].Fragment.UniformBuffers[1].count == 16,
    ".oshader Shader 的参数在片元槽 1: %", r.snapshots[0].Fragment.UniformBuffers[1].count);

    expect(state, !render2d_run_matches(*r, run, *material, "", white, selection), "换帧贴图断批");
    expect(state, !render2d_run_matches(*r, run, *material, "outline", atlas, selection), "换 Pass 断批");
    push_blend(*r, F.Blend_Mode_NonPremultiplied);
    expect(state, !render2d_run_matches(*r, run, *material, "", atlas, selection), "换混合断批");
    pop_blend(*r);
    push_scissor(*r, F.Rect_Int.{ 0, 0, 4, 4 });
    expect(state, !render2d_run_matches(*r, run, *material, "", atlas, selection), "换裁剪断批");
    pop_scissor(*r);
    expect(state, render2d_run_matches(*r, run, *material, "", atlas, selection), "恢复后可以继续合批");
    // material_set_number / material_set_texture / reload 递增 revision：快照过期，开新段。
    material.revision += 1;
    expect(state, !render2d_run_matches(*r, run, *material, "", atlas, selection), "revision 变化断批");

    // 有记录但目标无效：返回错误并清空记录，快照留待复用。
    expect(state, submit(*r, View.{}) == mat.Draw_Error.Invalid_Target, "目标无效");
    expect(state, r.runs.count == 0, "记录已清空: %", r.runs.count);
    expect(state, r.snapshot_count == 0, "快照计数归零: %", r.snapshot_count);
    expect(state, r.snapshots.count == 1, "快照留待复用: %", r.snapshots.count);
}

// 每个 Pass 的 [Instance] 数值各占一段：首项是两条轴，之后按 Pass 顺序连续存放。
render2d_instance_values_preserve_each_pass :: (state: *Test_State) {
    r: Render2D;
    defer dispose(*r);
    fields := sh.shader_alloc_array(sh.Field, 1);
    fields[0] = sh.Field.{ id = "hue", name = "hue", kind = .Scalar, instance = true, maximum = 1 };
    schema := sh.Schema.{ fields = fields };
    passes := sh.shader_alloc_array(sh.Pass_Desc, 2);
    shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ passes = passes } };
    values0 := sh.shader_alloc_array(sh.Value, 1);
    values0[0] = sh.Value.{ number = .[0.2, 0, 0, 0] };
    values1 := sh.shader_alloc_array(sh.Value, 1);
    values1[0] = sh.Value.{ number = .[0.8, 0, 0, 0] };
    bindings := sh.shader_alloc_array(mat.Material_Binding, 2);
    bindings[0] = mat.Material_Binding.{ schema = schema, values = values0 };
    bindings[1] = mat.Material_Binding.{ schema = schema, values = values1 };
    material := mat.Material.{ shader = *shader, bindings = bindings };
    // 开段时每个所选 Pass 建一张表（Pass i 用绑定 i）。
    tables: [2] mat.Instance_Table;
    tables[0] = mat.instance_table_make(passes[0], bindings[0]);
    tables[1] = mat.instance_table_make(passes[1], bindings[1]);
    // 记录首项是两条轴，之后是各 Pass 的数值。
    axes: [4] float32 = .[2, 0, 0, 3];
    expect(state, render2d_record_instances(*r, array_view(tables, 0, 2), null, axes) == 1,
    "首次记录从下标 1 开始（0 保留）");
    expect(state, floats4_eq(r.instance_values[1], axes), "首项是两条轴 %", r.instance_values[1]);
    expect(state, r.instance_values[2][0] == 0.2, "Pass 0 的值: %", r.instance_values[2][0]);
    expect(state, r.instance_values[3][0] == 0.8, "Pass 1 的值: %", r.instance_values[3][0]);
    // 本次覆盖只改这一个精灵的值，按字段范围钳制。
    hue: mat.Instance_Values;
    hue.numbers[0] = .[1.5, 0, 0, 0];
    hue.set = 1;
    expect(state, render2d_record_instances(*r, array_view(tables, 0, 2), *hue, axes) == 4, "第二条记录从下标 4 开始");
    expect(state, r.instance_values[5][0] == 1, "覆盖值按 maximum 钳到 1: %", r.instance_values[5][0]);
    expect(state, r.instance_values[6][0] == 1, "第二个 Pass 同样钳到 1: %", r.instance_values[6][0]);
}
//@endregion

// Loop scopes adapted.
