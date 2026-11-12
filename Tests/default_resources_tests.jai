// Runtime regression for embedded jfoster defaults. Run from an empty CWD.
#import "Basic";
#import "test_support";
#import "demo_console";
F :: #import "jfoster";

state: Test_State;
original_cwd: string;
driver: F.Graphics_Driver = .D3D12;

startup :: () {
    expect(*state, get_working_directory() == original_cwd, "App startup preserves caller working directory");
    for name: string.["Batcher", "Textured", "Msdf"] {
        for stage: F.Shader_Stage.[.VERTEX, .FRAGMENT] {
            dxil := F.defaults_shader_bytes(name, stage, .D3D12);
            spv := F.defaults_shader_bytes(name, stage, .VULKAN);
            msl := F.defaults_shader_bytes(name, stage, .METAL);
            expect(*state, dxil.count > 4 && dxil[0] == 68 && dxil[1] == 88 && dxil[2] == 66 && dxil[3] == 67, "embedded DXIL container header");
            expect(*state, spv.count > 4 && spv[0] == 3 && spv[1] == 2 && spv[2] == 35 && spv[3] == 7, "embedded SPIR-V header");
            expect(*state, msl.count > 0, "embedded Metal shader exists");
        }
    }
    expect(*state, F.defaults_shader_bytes("missing", .VERTEX, driver).count == 0, "unknown default does not fall back to disk");
    expect(*state, F.defaults_shader_bytes("Batcher", .VERTEX, .NONE).count == 0, "unsupported driver has no default blob");
    materials: [3] *F.Material = .[F.defaults_batch_material(F.App.device), F.defaults_textured_material(F.App.device), F.defaults_msdf_material(F.App.device)];
    for mat: materials {
        expect(*state, mat.Vertex.shader.handle != 0 && mat.Fragment.shader.handle != 0, "embedded shaders create native GPU resources");
    }
    font := F.defaults_msdf_font(F.App.device);
    expect(*state, font.Atlas.Width == 212 && font.Atlas.Height == 212, "embedded Roboto atlas decodes");
    expect(*state, font.Glyphs.count == 95, "embedded Roboto JSON decodes ASCII glyphs");
    glyph := font.Glyphs[1];
    expect(*state, glyph.Unicode == 33 && glyph.ar > glyph.al && glyph.ab > glyph.at && glyph.pr > glyph.pl, "glyph bounds use atlas JSON field names");
    expect(*state, F.defaults_msdf_font(F.App.device) == font, "default font is cached per device");
    expect(*state, F.defaults_font_license().count > 0, "embedded font license is available");
    boolean, parsed := F.json_parse("true");
    expect(*state, parsed && boolean.kind == .BOOL_V && boolean.truthy, "JSON literal comparison accepts true");
    target := F.target_create(F.App.device, 16, 16);
    batcher := F.batcher_create(F.App.device);
    F.graphics_device_clear_color(F.App.device, F.drawable_target_target(target), .{0, 0, 0, 255});
    F.batcher_rect_xy(batcher, 0, 0, 16, 16, .{40, 120, 200, 255});
    F.batcher_render(batcher, F.drawable_target_target(target));
    pixels: [16 * 16] F.Color;
    F.texture_get_data(F.target_texture(target), pixels);
    pixel := pixels[8 * 16 + 8];
    expect(*state, pixel.r == 40 && pixel.g == 120 && pixel.b == 200, "embedded Batcher shader renders expected pixels");
    F.batcher_destroy(batcher);
    F.target_dispose(target); free(target);
}

main :: () {
    state = test_begin();
    original_cwd = copy_string(get_working_directory());
    defer free(original_cwd.data);
    for get_command_line_arguments() if it == "vulkan" driver = .VULKAN;
    F.App.startup = startup;
    F.App.render = () => { F.app_exit(); };
    F.app_run(.{application_name = "embedded defaults test", window_title = "jfoster embedded resources test", width = 320, height = 180,
        preferred_graphics_driver = driver});
    F.app_destroy();
    expect(*state, get_working_directory() == original_cwd, "App shutdown preserves caller working directory");
    demo_console_finish(test_summary("embedded defaults", *state));
}
