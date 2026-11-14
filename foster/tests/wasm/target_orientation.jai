// Non-square, asymmetric rows catch double flips and partial-region mistakes.
sample_target_orientation_verify :: (device: *Graphics_Device, width: s32, height: s32) {
    if sample_gl_stats(11) <= 0 {
        log_info("W5 ORIENTATION: SKIP (no WebGL2)");
        return;
    }
    before_tex := sample_gl_stats(19);
    before_fbo := sample_gl_stats(23);
    before_rb := sample_gl_stats(24);
    before_errors := sample_gl_stats(10);
    source := texture_create(device, 8, 6, .COLOR, .NONE, .ONE, "orientation-upload");
    expected: [48] Color;
    got: [48] Color;
    for y: 0..5 for x : 0..7 expected[y * 8 + x] = .{ cast(u8) (20 + y * 30), cast(u8) (10 + x * 20), 40, 255 };
    texture_set_data(source, expected);
    texture_get_data(source, got);
    ok := true;
    for c, i: got if c != expected[i] {
        ok = false;
        log_info(tprint("ORIENT mismatch line % pixel % got % want %", #line, i, sample_color_text(c), sample_color_text(expected[i])));
    }

    for samples: Sample_Count.[.ONE, .FOUR] {
        infos: [2] Target_Attachment_Info = .[
            .{ Format = .COLOR, SampleCount = samples },
            .{ Format = .DEPTH24STENCIL8, SampleCount = samples }
        ];
        target := target_create_attachments(device, 8, 6, infos, "orientation-target");
        chain := target_create(device, 8, 6, "orientation-chain");
        tex := target_texture(target);
        b := sample.w5_batcher;
        batcher_clear(b);
        batcher_set_sampler(b, texture_sampler_make(.NEAREST, .CLAMP));
        batcher_image_full(b, source, Color_White);
        batcher_render(b, drawable_target_target(target));
        // Read while the pass is open. Multi-row buffers must be top-down.
        texture_get_data(tex, got);
        for c, i: got if c != expected[i] {
            ok = false;
            log_info(tprint("ORIENT mismatch line % pixel % got % want %", #line, i, sample_color_text(c), sample_color_text(expected[i])));
        }
        region: [6] Color;
        texture_get_data_region(tex, region, .{ 2, 1, 3, 2 });
        for c, i: region if c != expected[(1 + i / 3) * 8 + 2 + i % 3] ok = false;

        // Sample target -> target, then read it back; no alternating flips.
        batcher_clear(b);
        batcher_image_full(b, tex, Color_White);
        batcher_render(b, drawable_target_target(chain));
        texture_get_data(target_texture(chain), got);
        for c, i: got if c != expected[i] {
            ok = false;
            log_info(tprint("ORIENT mismatch line % pixel % got % want %", #line, i, sample_color_text(c), sample_color_text(expected[i])));
        }

        // Write an asymmetric region into an already built target, then re-enter
        // without clearing. Both the upload and untouched rows must survive.
        patch: [2] Color = .[Color_Red, Color_Blue];
        texture_set_data_region(target_texture(chain), patch, .{ 1, 1, 1, 2 });
        batcher_clear(b);
        batcher_rect_xy(b, 7, 5, 1, 1, Color_White);
        batcher_render(b, drawable_target_target(chain));
        texture_get_data(target_texture(chain), got);
        for c, i: got {
            want := expected[i];
            if i == 9 want = Color_Red;
            if i == 17 want = Color_Blue;
            if i == 47 want = Color_White;
            if c != want {
                ok = false;
                log_info(tprint("ORIENT write samples=% pixel % got % want %", samples, i, sample_color_text(c), sample_color_text(want)));
            }
        }

        // Nonzero source/destination Y, with nearest scaling, into a target.
        texture_blit_region(tex, .{ 0, 1, 8, 2 }, target_texture(chain), .{ 0, 4, 4, 2 }, .NEAREST);
        texture_get_data(target_texture(chain), got);
        for y: 0..1 for x : 0..3 if got[(4 + y) * 8 + x] != expected[(1 + y) * 8 + x * 2 + 1] {
            ok = false;
            log_info(tprint("ORIENT blit samples=% x=% y=% got=% want=%", samples, x, y, sample_color_text(got[(4 + y) * 8 + x]), sample_color_text(expected[(1 + y) * 8 + x * 2 + 1])));
        }

        // Return to the window before destroying attachments referenced by a pass.
        sample_w5_present(device, drawable_target_window(App.window), width, height);
        target_dispose(target);
        target_dispose(chain);
        free(target);
        free(chain);
    }
    texture_dispose(source);
    free(source);
    log_info(tprint("ORIENT resources %/%/% -> %/%/%", before_tex, before_fbo, before_rb, sample_gl_stats(19), sample_gl_stats(23), sample_gl_stats(24)));
    if before_tex != sample_gl_stats(19) || before_fbo != sample_gl_stats(23) || before_rb != sample_gl_stats(24) ok = false;
    if before_errors != sample_gl_stats(10) ok = false;
    log_info(tprint("W5 ORIENTATION: % (upload, 1x/4x+depth, multi-row region, target chain, partial write/blit, release)", ifx ok then "PASS" else "FAIL"));
}
