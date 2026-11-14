// rendering2d:atlas_aseprite —— .aseprite 目录 -> 图集的构建器（对位 DragonLib AsepriteAtlasBuilder）。
// 一比一移植自 olib kit/rendering/2d/atlas_aseprite.odin。
//
// 解析 .aseprite 二进制（jfoster 的 Aseprite），拍平可见图层渲染每一帧
// （bg/shadow 这类预览图层默认跳过），frame tag 变成命名动画、帧时长毫秒
// 转秒；装箱用 jfoster 的 Packer（行装箱 + 透明裁剪 + 边缘出血 + 重复帧
// 合并）。一页放不下 max_size 时自动开新页。PingPong 标签展开帧列表（a b c -> a b c b），Reverse 反转帧序。
//
// 注意：构建器固定 Trim=true（packer_add 立即拷贝像素，渲染帧当轮释放）；
// 本文件只在 native 目标可用（目录枚举依赖 SDL 文件系统）。
//
// Jai 侧差异（逐条对应 olib 的写法，解析/展开/打包产物不变）：
//   | olib (Odin)                                        | JaiLib (Jai)                                          |
//   | -------------------------------------------------- | ----------------------------------------------------- |
//   | foster.Packer{Trim, Padding, MaxSize, …}            | F.packer_create(F.Packer_Options.{…})                 |
//   | foster.PackerAdd(packer, name, image)               | F.packer_add(packer, name, image.Data, image.Width, image.Height) |
//   | out := foster.PackerPack(&packer)                   | F.packer_pack(*packer)，产物就是 packer.Pages/Output    |
//   | delete(output.Pages) / delete(output.Entries)       | F.packer_destroy（Pages 已置空，只回收数组）             |
//   | foster.AsepriteLoad(data) -> Aseprite（值）          | F.aseprite_parse(data) -> *Aseprite（失败返回 null）    |
//   | foster.AsepriteDispose(&doc)                        | F.aseprite_destroy(doc)                               |
//   | foster.AsepriteRenderAllFrames(&doc, filter)        | 逐帧 F.aseprite_render_frame(doc, i, filter)          |
//   | AsepriteFrame.Duration（毫秒 f32）                   | Aseprite_Frame.DurationMS（u16 毫秒）                  |
//   | AsepriteTag.Direction / .From / .To                 | Aseprite_Tag.LoopDirection / .From / .To（u16）        |
//   | .Forward / .Reverse / .PingPong / .PingPongReverse  | .FORWARD / .REVERSE / .PINGPONG / .PINGPONG_REVERSE    |
//   | AsepriteLayerFilter + context.user_ptr 传跳过表      | 文件级 aseprite_skip_layers（Jai 的 proc 指针不能捕获   |
//   |                                                    | 环境；仅在 aseprite_pack_file 的渲染期间有效，同 olib 的 |
//   |                                                    | 「调用期间有效」约定）                                   |
//   | os.read_entire_file_from_path                      | FILE.read_entire_file（返回 []u8, bool）               |
//   | os.read_all_directory_by_path                      | F.folder_enum + F.folder_exists（jacket 的 SDL 层，     |
//   |                                                    | 递归自己展开）                                          |
//   | strings.to_lower / has_suffix / last_index          | STRING.to_lower_copy / ends_with / find_index_from_right |
//   | fmt.aprintf("%s/%d", …)                            | copy_string(tprint("%/%", …))                         |
//   | `for i := from; i <= to; i += 1`                   | `while i <= to`（Jai 没有 C 风格 for）                  |
//   | `delete(packer.Sources)`                            | F.packer_destroy 一并释放                              |
//   | 区域名（PackerAdd 借用的字符串）不回收                 | 打包完由 aseprite_build 统一 free（同 olib 的生命周期     |
//   |                                                    | 契约，只是不泄漏）                                       |
//   | 名字/时长切片 `delete`                               | atlas_alloc_array + array_free                        |
//   | @(private)                                         | 去掉标注，内部过程加 aseprite_ / built_ 前缀             |
#import "Basic";

//@region 类型 —— 打包产物

// 一条自动生成的动画：controller 来自 .aseprite 文件名，name 来自 frame tag。
Built_Clip :: struct {
    controller: string;
    name: string;
    frames: [] string; // 区域名列表（克隆，随 clip 释放）
    durations: [] float32; // 与 frames 一一对应（秒）
    loop: bool;
}

// 打包产物：每页的图集像素 + 区域表（页号、页内矩形、裁边帧）+ 自动生成的动画剪辑。
// 所有字符串均为克隆（context.allocator），built_atlas_dispose 统一释放；atlas_from_built 接管页与区域。
Built_Atlas :: struct {
    pages: [] F.Image;
    regions: HASH.Table(string, Atlas_Region);
    clips: [..] Built_Clip;
    source_count: int; // 参与打包的 .aseprite 文件数
}
//@endregion

//@region 构建配置

Aseprite_Build_Config :: struct {
    padding: int; // 区域间距（>=2 时启用边缘出血）
    max_size: int; // 每页最大边长；放不下时开新页
    skip_layers: [] string; // 拍平时跳过的图层名（大小写不敏感）
}

ASEPRITE_BUILD_DEFAULT :: Aseprite_Build_Config.{
    padding = 2,
    max_size = 8192,
    skip_layers = .["bg", "shadow"],
}
//@endregion

//@region 构建

// 扫描目录（递归）里的所有 .aseprite，渲染帧并装箱成图集（一页或多页）。
// 没有源文件时返回 false。
aseprite_build :: (root: string, config := ASEPRITE_BUILD_DEFAULT) -> (Built_Atlas, bool) {
    files: [..] string;
    defer {
        for name: files {
            if name.data != null free(name.data);
        }
        if files.data != null array_free(files);
    }
    aseprite_collect(root, "", *files);
    if files.count == 0 return Built_Atlas.{}, false;
    aseprite_sort_files(*files); // 稳定打包顺序

    packer := F.packer_create(F.Packer_Options.{
        Trim = true,
        Padding = cast(s32) config.padding,
        MaxSize = cast(s32) config.max_size,
        DuplicateEdges = config.padding >= 2,
        CombineDuplicates = true,
    });
    defer F.packer_destroy(*packer);

    clips: [..] Built_Clip;
    clips_moved := false; // 所有权转移进产物后，defer 不再释放
    defer if !clips_moved {
        for *clip: clips built_clip_dispose(clip);
        if clips.data != null array_free(clips);
    }

    source_count := 0;
    for path: files {
        if aseprite_pack_file(*packer, *clips, path, config.skip_layers) source_count += 1;
    }

    F.packer_pack(*packer);
    // 区域名是 packer_add 借用的（olib 传给 PackerAdd 的那份）；建完区域表后就由这里释放。
    defer for source: packer.sources {
        if source.Name.data != null free(source.Name.data);
    }
    if packer.Pages.count == 0 {
        return Built_Atlas.{}, false;
    }

    clips_moved = true; // clips 从这里起归产物所有
    result := Built_Atlas.{
        pages = atlas_alloc_array(F.Image, packer.Pages.count), // 接管每页像素
        regions = HASH.Table(string, Atlas_Region).{},
        clips = clips,
        source_count = source_count,
    };
    for page, i: packer.Pages result.pages[i] = page;
    packer.Pages.count = 0; // 像素已接管，packer_destroy 不再释放它们
    for entry: packer.Output {
        HASH.table_add(*result.regions, clone_owned(entry.Name),
                  Atlas_Region.{ page = cast(int) entry.Page, rect = entry.Source, frame = entry.Frame });
    }
    return result, true;
}

// 释放打包产物（字符串/切片/图集像素）。
built_atlas_dispose :: (built: *Built_Atlas) {
    for *clip: built.clips built_clip_dispose(clip);
    if built.clips.data != null array_free(built.clips);
    for region, name: built.regions {
        if name.data != null free(name.data);
    }
    HASH.deinit(*built.regions);
    for *page: built.pages {
        if page.Data.data != null F.image_destroy(page);
    }
    if built.pages.data != null array_free(built.pages);
    built.* = Built_Atlas.{};
}

// 用打包产物构造图集：图集接管每页像素与区域表（built 里随之清空），动画剪辑仍归 built。
// 之后照常 atlas_upload；built 仍须 built_atlas_dispose 释放剪辑。
atlas_from_built :: (atlas: *Sprite_Atlas, built: *Built_Atlas) {
    atlas.* = Sprite_Atlas.{
        pages = atlas_alloc_array(Atlas_Page, built.pages.count),
        regions = built.regions,
    };
    for image, i: built.pages atlas.pages[i].image = image;
    if built.pages.data != null array_free(built.pages);
    built.pages = .[];
    built.regions = HASH.Table(string, Atlas_Region).{};
}
//@endregion

//@region 内部

// 拍平时跳过的图层名（已小写）；aseprite_layer_filter 读它。
// olib 用 context.user_ptr 传同一份表，Jai 的 proc 指针不能带捕获，改用文件级变量——
// 与 olib 一样，只在 aseprite_pack_file 的渲染调用期间有效，渲染结束即清空。
aseprite_skip_layers: [] string;

// olib 的 AsepriteLayerFilter：没有 userdata 参数，跳过图层表经环境传入
aseprite_layer_filter :: (layer: F.Aseprite_Layer) -> bool {
    if layer.Name == "" return true;
    lower := STRING.to_lower_copy(layer.Name);
    defer if lower.data != null free(lower.data);
    for name: aseprite_skip_layers {
        if lower == name return false;
    }
    return true;
}

// 渲染并装箱一个 .aseprite 文件，把它的动画追加到 clips。
// 文件读不出或没有帧时返回 false，不影响已有结果。
aseprite_pack_file :: (packer: *F.Packer, clips: *[..] Built_Clip, path: string, skip_layers: [] string) -> bool {
    data, read_ok := FILE.read_entire_file(path);
    if !read_ok || data.count == 0 {
        if data.data != null free(data.data);
        return false;
    }
    defer if data.data != null free(data.data);
    doc := F.aseprite_parse(cast([] u8) data);
    if doc == null return false;
    defer F.aseprite_destroy(doc);
    if doc.Frames.count == 0 return false;

    controller := aseprite_slug(aseprite_base_name(path));
    defer if controller.data != null free(controller.data);

    // 拍平渲染：跳过预览图层。
    rendered := atlas_alloc_array(F.Image, doc.Frames.count);
    defer {
        for *frame: rendered {
            if frame.Data.data != null F.image_destroy(frame);
        }
        if rendered.data != null array_free(rendered);
    }
    aseprite_skip_layers = skip_layers;
    for i: 0..doc.Frames.count - 1 {
        rendered[i] = F.aseprite_render_frame(doc, cast(s32) i, aseprite_layer_filter);
    }
    aseprite_skip_layers = .[];

    region_names := atlas_alloc_array(string, doc.Frames.count);
    defer if region_names.data != null array_free(region_names);
    durations := atlas_alloc_array(float32, doc.Frames.count);
    defer if durations.data != null array_free(durations);

    for i: 0..rendered.count - 1 {
        region_names[i] = copy_string(tprint("%/%", controller, i));
        // Trim=true：立即拷贝像素
        F.packer_add(packer, region_names[i], rendered[i].Data, rendered[i].Width, rendered[i].Height);
    }
    for i: 0..doc.Frames.count - 1 {
        // 帧时长毫秒 -> 秒；至少 1ms 防 0 时长卡死采样
        durations[i] = cast(float32) max(cast(int) doc.Frames[i].DurationMS, 1) / 1000.0;
    }

    if doc.Tags.count == 0 {
        default_clip := aseprite_make_clip(controller, "default", region_names, durations, true);
        array_add(clips, default_clip);
        return true;
    }
    for *tag: doc.Tags {
        tag_name := aseprite_slug(ifx tag.Name != "" then tag.Name else "clip");
        defer if tag_name.data != null free(tag_name.data);
        frames, durs := aseprite_expand_tag(region_names, durations, cast(int) tag.From, cast(int) tag.To,
                                           tag.LoopDirection);
        clip := aseprite_make_clip(controller, tag_name, frames, durs, true);
        if frames.data != null array_free(frames);
        if durs.data != null array_free(durs);
        array_add(clips, clip);
    }
    return true;
}

built_clip_dispose :: (clip: *Built_Clip) {
    if clip.controller.data != null free(clip.controller.data);
    if clip.name.data != null free(clip.name.data);
    if clip.frames.data != null {
        for name: clip.frames {
            if name.data != null free(name.data); // 区域名是 aseprite_make_clip 克隆的
        }
        array_free(clip.frames);
    }
    if clip.durations.data != null array_free(clip.durations);
    clip.* = Built_Clip.{};
}

// 复制全部入参：clip 独立拥有 controller / name / 区域名 / 时长，由 built_clip_dispose 释放。
aseprite_make_clip :: (controller: string, name: string, frames: [] string, durations: [] float32, loop: bool) -> Built_Clip {
    owned_frames := atlas_alloc_array(string, frames.count);
    owned_durs := atlas_alloc_array(float32, frames.count);
    for i: 0..frames.count - 1 {
        owned_frames[i] = clone_owned(frames[i]);
        owned_durs[i] = durations[i];
    }
    return Built_Clip.{
        controller = clone_owned(controller),
        name = clone_owned(name),
        frames = owned_frames,
        durations = owned_durs,
        loop = loop,
    };
}

// 展开一个 frame tag 的帧区间（含 Reverse / PingPong / PingPongReverse）。
// 返回新分配的切片（context.allocator，调用方释放）。
aseprite_expand_tag :: (regions: [] string, durations: [] float32, from: int, to: int,
                        direction: F.Aseprite_Loop_Direction) -> ([] string, [] float32) {
    indices: [..] int;
    defer if indices.data != null array_free(indices);

    i := from;
    while i <= to {
        if i >= 0 && i < regions.count {
            array_add(*indices, i);
        }
        i += 1;
    }
    if direction == .REVERSE {
        reverse_indices(array_view(indices, 0, indices.count));
    } else if direction == .PINGPONG || direction == .PINGPONG_REVERSE {
        // a b c -> a b c b（PingPongReverse 先反转再补回程）
        if direction == .PINGPONG_REVERSE {
            reverse_indices(array_view(indices, 0, indices.count));
        }
        i = indices.count - 2;
        while i >= 1 {
            array_add(*indices, indices[i]);
            i -= 1;
        }
    }

    frames := atlas_alloc_array(string, indices.count);
    durs := atlas_alloc_array(float32, indices.count);
    // 注意 Jai 的数组双变量迭代也是 (值, 下标)，与 Odin 的切片迭代一致。
    for region_index, position: indices {
        frames[position] = regions[region_index];
        durs[position] = durations[region_index];
    }
    return frames, durs;
}

reverse_indices :: (indices: [] int) {
    i := 0;
    while i < indices.count / 2 {
        other := indices[indices.count - 1 - i];
        indices[indices.count - 1 - i] = indices[i];
        indices[i] = other;
        i += 1;
    }
}

// 把子图名字清洗成稳定标识符（小写、非字母数字归为下划线）。
// 超长名字截断到 256 字符。
aseprite_slug :: (name: string) -> string {
    buf: [256] u8;
    n := 0;
    last_underscore := true; // 前导不产生下划线
    for c: name {
        if n >= buf.count break;
        alnum := (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") ||
                 (c >= #char "0" && c <= #char "9");
        if alnum {
            buf[n] = ifx c >= #char "A" && c <= #char "Z" then c + (#char "a" - #char "A") else c;
            n += 1;
            last_underscore = false;
        } else if !last_underscore {
            buf[n] = #char "_";
            n += 1;
            last_underscore = true;
        }
    }
    while n > 0 && buf[n - 1] == #char "_" {
        n -= 1;
    }
    return clone_owned(string.{ data = *buf[0], count = n });
}

aseprite_base_name :: (path: string) -> string {
    slash := STRING.find_index_from_right(path, #char "/");
    back := STRING.find_index_from_right(path, #char "\\");
    sep := max(slash, back);
    base := path;
    if sep >= 0 base = atlas_substring(path, cast(int) sep + 1, path.count);
    dot := STRING.find_index_from_right(base, #char ".");
    if dot > 0 return atlas_substring(base, 0, cast(int) dot);
    return base;
}

aseprite_collect :: (root: string, rel: string, out: *[..] string) {
    joined := rel != "";
    dir := root;
    if joined dir = join_owned(root, rel);
    defer if joined {
        if dir.data != null free(dir.data);
    }
    names, ok := F.folder_enum(dir, "*", false);
    if !ok return;
    defer {
        for name: names {
            if name.data != null free(name.data);
        }
        if names.data != null array_free(names);
    }

    for name: names {
        if name == "." || name == ".." continue;
        child_rel := join_owned(rel, name);
        defer if child_rel.data != null free(child_rel.data);
        full := join_owned(root, child_rel);
        lower := STRING.to_lower_copy(name);
        defer if lower.data != null free(lower.data);
        if F.folder_exists(full) {
            aseprite_collect(root, child_rel, out);
            if full.data != null free(full.data);
            continue;
        }
        if STRING.ends_with(lower, ".aseprite") {
            array_add(out, full); // 完整路径，随 out 释放
        } else if full.data != null {
            free(full.data);
        }
    }
}

// 插入排序：文件名有序保证打包结果稳定。
aseprite_sort_files :: (files: *[..] string) {
    for i: 1..files.count - 1 {
        f := files.*[i];
        j := i;
        while j > 0 && STRING.compare(files.*[j - 1], f) > 0 {
            files.*[j] = files.*[j - 1];
            j -= 1;
        }
        files.*[j] = f;
    }
}
//@endregion
