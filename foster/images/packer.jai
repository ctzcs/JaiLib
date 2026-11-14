using Basic;
using Math;
#scope_module

// Port of Foster Framework/Images/Packer.cs — grow-right/grow-down
// guillotine packer with alpha-trim, padding and duplicate-edge options.

Packer_Options :: struct {
    Trim: bool = true; // trim transparent pixels from sources
    MaxSize: s32 = 8192;
    Padding: s32 = 1; // total, split half/half around each entry
    DuplicateEdges: bool = false; // copy edge pixels into padding (needs padding >= 2)
    PowerOfTwo: bool = false;
    CombineDuplicates: bool = false; // hash-based dedupe (Foster's 33-rolling-hash)
}

Packer_Source :: struct {
    Index: s32;
    Name: string;
    Hash: u32;
    Packed: Rect_Int; // where it was placed (incl. padding)
    Frame: Rect_Int; // offset of the trimmed rect inside the original image (can be negative)
    BufferIndex: s32;
    BufferLength: s32;
    DuplicateOf: s32 = -1;
}

Packer_Output_Entry :: struct {
    Index: s32;
    Name: string;
    Page: s32;
    Source: Rect_Int;
    Frame: Rect_Int;
}

Packer :: struct {
    Options: Packer_Options;

    sources: [..] Packer_Source;
    buffer: [..] Color; // shared trimmed-pixel buffer
    Pages: [..] Image;
    Output: [..] Packer_Output_Entry;
    page_assignment: [..] s32;
}

packer_create :: (options: Packer_Options) -> Packer {
    p: Packer;
    p.Options = options;
    return p;
}

packer_destroy :: (p: *Packer) {
    for img, i: p.Pages image_destroy(*p.Pages[i]);
    array_free(p.Pages);
    array_free(p.sources);
    array_free(p.buffer);
    array_free(p.Output);
    array_free(p.page_assignment);
}

// Adds an image; duplicates (by hash) are collapsed when CombineDuplicates.
packer_add :: (p: *Packer, name: string, pixels: [] Color, width: s32, height: s32) {
    src := Packer_Source.{ Index = cast(s32) p.sources.count, Name = name };

    rect := Rect_Int.{ 0, 0, width, height };

    if p.Options.Trim {
        // find alpha-bounding box with 4 directional scans
        min_x := width;
        max_x := -1;
        min_y := height;
        max_y := -1;
        for y: 0..height - 1 {
            for x: 0..width - 1 {
                if pixels[y * width + x].a > 0 {
                    if x < min_x min_x = x;
                    if x > max_x max_x = x;
                    if y < min_y min_y = y;
                    if y > max_y max_y = y;
                }
            }
        }
        if max_x >= min_x && max_y >= min_y {
            rect = Rect_Int.{ min_x, min_y, cast(s32) (max_x - min_x + 1), cast(s32) (max_y - min_y + 1) };
        } else {
            rect = Rect_Int.{ 0, 0, 0, 0 };
        }
    }

    // hash over the trimmed region
    hash: u32 = 0;
    for y: 0..(rect.h - 1) {
        for x: 0..(rect.w - 1) {
            c := pixels[(rect.y + y) * width + (rect.x + x)];
            hash = hash * 33 + color_rgba(c);
        }
    }
    src.Hash = hash;

    // duplicate?
    if p.Options.CombineDuplicates {
        for other: p.sources {
            if other.Hash == hash && other.DuplicateOf == -1 {
                // Foster compares by hash only (noted upstream); accept it
                src.DuplicateOf = other.Index;
                src.Packed = .{ 0, 0, 0, 0 };
                src.BufferIndex = 0;
                src.BufferLength = 0;
                array_add(*p.sources, src);
                return;
            }
        }
    }

    // frame records where the trimmed rect sits in the original
    src.Frame = .{ -rect.x, -rect.y, width, height };

    // append trimmed pixels into the shared buffer
    src.BufferIndex = cast(s32) p.buffer.count;
    src.BufferLength = rect.w * rect.h;
    array_reserve(*p.buffer, p.buffer.count + src.BufferLength);
    for y: 0..(rect.h - 1) {
        for x: 0..(rect.w - 1) {
            array_add(*p.buffer, pixels[(rect.y + y) * width + (rect.x + x)]);
        }
    }

    array_add(*p.sources, src);
}

packer_pack :: (p: *Packer) {
    half := p.Options.Padding / 2;

    // sort by area descending
    sorted: [..] s32;
    for s: p.sources array_add(*sorted, s.Index);
    for i: 1..(sorted.count - 1) { // insertion sort
        key := sorted[i];
        j := i - 1;
        while j >= 0 {
            a := p.sources[sorted[j]];
            b := p.sources[key];
            if a.Frame.w * a.Frame.h >= b.Frame.w * b.Frame.h break;
            sorted[j + 1] = sorted[j];
            j -= 1;
        }
        sorted[j + 1] = key;
    }

    // pack pages until all sources placed
    placed: [..] bool;
    array_resize(*placed, p.sources.count);
    for *b: placed b.* = false;

    while true {
        // gather remaining real (non-duplicate) sources for this page
        remaining := 0;
        for s: p.sources {
            if s.DuplicateOf != -1 continue;
            idx := s.Index;
            if idx >= 0 && idx < placed.count && !placed[idx] remaining += 1;
        }
        if remaining == 0 break;

        // simple shelf/skyline: place left-to-right, wrap rows
        page_w := 0;
        page_h := 0;
        row_h := 0;
        x := 0;
        y := 0;
        entries: [..] s32;

        for idx: sorted {
            s := *p.sources[idx];
            if s.DuplicateOf != -1 continue;
            if placed[idx] continue;

            w := cast(s64) s.Frame.w + p.Options.Padding;
            h := cast(s64) s.Frame.h + p.Options.Padding;

            if w > p.Options.MaxSize || h > p.Options.MaxSize {
                log_warning(tprint("packer: source '%' (%,%) exceeds MaxSize %", s.Name, w, h, p.Options.MaxSize));
                placed[idx] = true;
                continue;
            }

            if x + w > cast(s64) p.Options.MaxSize {
                x = 0;
                y += row_h;
                row_h = 0;
            }
            if y + h > cast(s64) p.Options.MaxSize break;

            s.Packed = Rect_Int.{ cast(s32) (x + half), cast(s32) (y + half), s.Frame.w, s.Frame.h };
            x += cast(s32) w;
            if h > row_h row_h = cast(s32) h;
            if x > page_w page_w = cast(s32) x;
            if y + cast(s64) row_h > page_h page_h = cast(s32) (y + row_h);
            array_add(*entries, idx);
            placed[idx] = true;
        }

        // round up
        if p.Options.PowerOfTwo {
            pw: s64 = 1;
            while pw < page_w pw *= 2;
            ph := 1;
            while ph < page_h ph *= 2;
            page_w = pw;
            page_h = ph;
        }
        if page_w <= 0 page_w = 1;
        if page_h <= 0 page_h = 1;

        // create the page and blit
        page := image_create(cast(s32) page_w, cast(s32) page_h);
        for idx: entries {
            s := p.sources[idx];
            // 本地补丁 #5：必须从该 source 自己的 BufferIndex 切片读——原实现
            // 每个字形都从共享 buffer 头部拷贝，图集里全是开头几字节的重排噪声。
            image_copy_pixels(*page, array_view(p.buffer, s.BufferIndex, s.BufferLength),
                              s.Frame.w, s.Frame.h,
                              0, 0, s.Frame.w, s.Frame.h,
                              s.Packed.x, s.Packed.y);

            // duplicate edges
            if p.Options.DuplicateEdges && p.Options.Padding >= 2 {
                // left/right/top/bottom strips
                for yy: 0..s.Frame.h - 1 {
                    if s.Packed.x > 0 {
                        image_set_pixel(*page, s.Packed.x - 1, s.Packed.y + yy, image_pixel(*page, s.Packed.x, s.Packed.y + yy));
                    }
                    if s.Packed.x + s.Frame.w < page.Width {
                        image_set_pixel(*page, s.Packed.x + s.Frame.w, s.Packed.y + yy, image_pixel(*page, s.Packed.x + s.Frame.w - 1, s.Packed.y + yy));
                    }
                }
                for px: 0..s.Frame.w - 1 {
                    if s.Packed.y > 0 {
                        image_set_pixel(*page, s.Packed.x + px, s.Packed.y - 1, image_pixel(*page, s.Packed.x + px, s.Packed.y));
                    }
                    if s.Packed.y + s.Frame.h < page.Height {
                        image_set_pixel(*page, s.Packed.x + px, s.Packed.y + s.Frame.h, image_pixel(*page, s.Packed.x + px, s.Packed.y + s.Frame.h - 1));
                    }
                }
            }
        }
        array_add(*p.Pages, page);
        while p.page_assignment.count < p.sources.count {
            array_add(*p.page_assignment, 0);
        }
        for idx: entries p.page_assignment[idx] = cast(s32) (p.Pages.count - 1);
        array_free(entries);
    }

    // build output entries; empty/duplicates resolve to their originals
    page_count := cast(s32) p.Pages.count;
    if page_count == 0 page_count = 1;

    for s: p.sources {
        entry := Packer_Output_Entry.{ Index = s.Index, Name = s.Name, Page = page_count, Source = s.Packed, Frame = s.Frame };

        if s.BufferLength == 0 {
            if s.DuplicateOf >= 0 && s.DuplicateOf < p.sources.count {
                d := p.sources[s.DuplicateOf];
                entry.Page = 0;
                entry.Source = d.Packed;
                entry.Frame = d.Frame;
            } else {
                entry.Page = page_count; // Foster: empties get the final page number
            }
        } else {
            entry.Page = packer_page_of(p, s.Index);
        }

        array_add(*p.Output, entry);
    }

    array_free(sorted);
    array_free(placed);
}

packer_page_of :: (p: *Packer, index: s32) -> s32 {
    if index >= 0 && index < p.page_assignment.count return p.page_assignment[index];
    return 0;
}
