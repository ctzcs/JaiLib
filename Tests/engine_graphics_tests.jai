#import "Basic";
#import "File";
#import "gfx";
#import "test_support";
GA :: #import "graphics_assets";
AT :: #import "asset";
CF :: #import "thirdparty/clay_foster";
state: Test_State;
driver: F.Graphics_Driver = .D3D12;
custom_draw :: (b: *F.Batcher, bounds: CF.clay.BoundingBox, data: *void, user: *void) {
    if data != user return;
    F.batcher_rect(b, .{bounds.x, bounds.y, bounds.width, bounds.height}, .{0, 0, 255, 255});
}

startup :: () {
    gfx_init();
    expect(*state, make_directory_if_it_does_not_exist(".test_tmp/gpu/Assets", true), "create texture fixture directory");
    image := F.image_create(8, 8, .{255, 0, 0, 255});
    defer F.image_destroy(*image);
    png := F.image_encode_png(image);
    expect(*state, write_entire_file(".test_tmp/gpu/Assets/red.png", cast(string) png), "write texture fixture");
    free(png.data);
    _, error := AT.import_all(".test_tmp/gpu/Assets", ".test_tmp/gpu/Library");
    expect(*state, error == .None, "import texture fixture");
    manager: GA.Texture_Manager;
    error = GA.textures_init(*manager, F.App.device, .{library_root = ".test_tmp/gpu/Library"});
    expect(*state, error == .None, "init GPU resource manager");
    defer GA.textures_destroy(*manager);
    a, e1 := GA.texture_acquire_path(*manager, "red.png");
    b, e2 := GA.texture_acquire_path(*manager, "red.png");
    expect(*state, e1 == .None && e2 == .None && a.idx == b.idx && a.gen == b.gen, "repeated acquisition reuses one GPU texture");
    tex := GA.texture_get(*manager, a);
    pixels: [64] Color;
    F.texture_get_data(tex, pixels);
    expect(*state, pixels[32].r == 255 && pixels[32].g == 0, "uploaded texture readback");
    _ := GA.texture_release(*manager, a);
    expect(*state, GA.texture_get(*manager, b) == tex, "one reference keeps GPU texture alive");
    _ := GA.texture_release(*manager, b);
    expect(*state, GA.texture_get(*manager, a) == null && !GA.texture_release(*manager, a), "last release invalidates old handles");
    c, _ := GA.texture_acquire_path(*manager, "red.png");
    expect(*state, c.gen != a.gen && GA.texture_get(*manager, a) == null, "reload does not revive stale handle");
    defer GA.texture_release(*manager, c);
    atlas: GA.Sprite_Atlas;
    defer GA.atlas_destroy(*atlas);
    expect(*state, GA.atlas_load_json(*atlas, *manager, "{\"image\":\"red.png\",\"sprites\":[{\"name\":\"red\",\"x\":0,\"y\":0,\"w\":8,\"h\":8}]}"), "load atlas metadata through asset manifest");
    sprite, found := GA.atlas_get(*atlas, "red");
    expect(*state, found && sprite.image.Source.w == 8, "lookup named sprite");
    expect(*state, !GA.atlas_load_json(*atlas, *manager, "{} trailing"), "reject trailing JSON");
    expect(*state, !GA.atlas_load_json(*atlas, *manager, "{\"image\":\"red.png\",\"sprites\":[{\"name\":\"bad\",\"w\":90,\"h\":90}]}"), "reject atlas rectangle outside its texture");
    _, kept := GA.atlas_get(*atlas, "red");
    expect(*state, kept && manager.records.num == 1 && GA.POOL.get(manager.records, c).references == 2, "failed atlas reload keeps old sprite and releases temporary reference");
    green := F.image_create(8, 8, .{0, 255, 0, 255}); defer F.image_destroy(*green);
    packed: GA.Sprite_Atlas; defer GA.atlas_destroy(*packed);
    names := string.["red", "green"]; images := F.Image.[image, green];
    expect(*state, GA.atlas_pack(*packed, F.App.device, names, images, 16), "pack multi-page atlas");
    expect(*state, packed.pages.count == 2, "small page size creates two pages");
    target := F.target_create(F.App.device, 64, 64, "atlas-test");
    defer { F.target_dispose(target); free(target); }
    draw := F.drawable_target_target(target);
    gfx_pass_begin(draw, BLACK);
    expect(*state, GA.atlas_draw(*packed, gfx_batcher, "green", .{8, 8}, WHITE, .{4, 4}), "draw named sprite");
    gfx_pass_end(draw);
    output: [4096] Color;
    F.texture_get_data(F.target_texture(target), output);
    expect(*state, output[16 * 64 + 16].g == 255 && output[16 * 64 + 16].r == 0, "packed sprite pixels retain correct source and scale");
    icon := CF.clay.ImageElementConfig.{imageData = GA.texture_get(*manager, c)};
    custom := CF.clay.CustomElementConfig.{customData = *state};
    commands: [4] CF.clay.RenderCommand;
    commands[0] = .{commandType = .IMAGE, boundingBox = .{4, 4, 32, 32}, config = .{imageElementConfig = *icon}};
    commands[1] = .{commandType = .SCISSOR_START, boundingBox = .{40, 8, 8, 8}};
    commands[2] = .{commandType = .CUSTOM, boundingBox = .{36, 4, 24, 24}, config = .{customElementConfig = *custom}};
    commands[3] = .{commandType = .SCISSOR_END};
    render_commands := CF.clay.RenderCommandArray.{capacity = 4, length = 4, internalArray = commands.data};
    CF.clay_foster_set_custom_draw(custom_draw, *state);
    gfx_pass_begin(draw, BLACK);
    CF.clay_foster_render(gfx_batcher, *render_commands);
    expect(*state, gfx_batcher.scissorDepth == 0 && !gfx_batcher.current_batch.HasScissor, "clay balances clipping state");
    gfx_pass_end(draw);
    F.texture_get_data(F.target_texture(target), output);
    expect(*state, output[24 * 64 + 24].r == 255 && output[37 * 64 + 24].r == 0, "clay image fits computed layout bounds");
    expect(*state, output[10 * 64 + 42].b == 255 && output[20 * 64 + 42].b == 0, "custom callback receives data and obeys clipping");
    CF.clay_foster_shutdown();
}
render :: () { F.app_exit(); }
shutdown :: () { gfx_shutdown(); }
main :: () {
    state = test_begin();
    for arg: get_command_line_arguments() if arg == "vulkan" driver = .VULKAN;
    F.App.startup = startup; F.App.render = render; F.App.shutdown = shutdown;
    F.app_run(.{application_name = "engine_graphics_tests", width = 320, height = 240, preferred_graphics_driver = driver});
    F.app_destroy();
    if !test_summary("engine graphics", *state) exit(1);
}
