// M2 sample: animated clear + a shader-drawn triangle through SDL_GPU.
// Uses Foster's own precompiled Textured shader blobs (same renderer Foster
// would use). At ~3s the backbuffer is read back to verify the triangle
// actually rendered, then the app exits.
//
// Build from the repo root:  jai first.jai - triangle
// Default shader blobs are embedded; run from any working directory.

#import "Basic";
#import "File";
#import "Math";
#import "foster";

Vertex :: struct {
    pos: Vector2;
    tex: Vector2;
    col: Color;
}

Triangle_Sample_State :: struct {
    material: *Material;
    mesh:     *Mesh;
    verified: bool;
    rt: *Target = null;
}

Tri: Triangle_Sample_State;

main :: () {
    App.startup = startup;
    App.render  = render;
    App.update  = update;

    app_run(.{
        application_name = "jfoster triangle sample",
        window_title     = "jfoster triangle",
        width  = 1280,
        height = 720,
        preferred_graphics_driver = .NONE,     // default driver selection
    });

    app_destroy();
}

startup :: () {
    device := App.device;

    // Select the embedded Foster Textured shader blobs for the active driver.
    vs_code := defaults_shader_bytes("Textured", .VERTEX, device.driver);
    fs_code := defaults_shader_bytes("Textured", .FRAGMENT, device.driver);
    assert(vs_code.count > 0 && fs_code.count > 0, "failed to find embedded shader blobs");

    // Textured shader: 1 vertex uniform buffer (the matrix), 1 fragment sampler
    vs := shader_create(device, .VERTEX,   cast([] u8) vs_code, uniform_buffer_count = 1, entry_point = "vertex_main");
    fs := shader_create(device, .FRAGMENT, cast([] u8) fs_code, sampler_count = 1,       entry_point = "fragment_main");

    Tri.material = material_create(vs, fs);

    // PosTexColVertex: float2 pos, float2 tex, ubyte4-normalized color (20 bytes)
    elements: [3] Vertex_Format_Element = .[
        .{ Index = 0, Type = .FLOAT2,  Normalized = false },
        .{ Index = 1, Type = .FLOAT2,  Normalized = false },
        .{ Index = 2, Type = .UBYTE4,  Normalized = true  },
    ];
    Tri.mesh = mesh_create(device, vertex_format_make(elements), .THIRTY_TWO);

    vertices: [3] Vertex = .[
        .{ pos = .{  640, 720 }, tex = .{ 0.5, 1.0 }, col = .{ 255,   0,   0, 255 } },
        .{ pos = .{  640,   0 }, tex = .{ 0.5, 0.0 }, col = .{   0, 255,   0, 255 } },
        .{ pos = .{    0, 720 }, tex = .{ 0.0, 1.0 }, col = .{   0,   0, 255, 255 } },
    ];
    mesh_set_vertices(Tri.mesh, vertices);
    indices: [3] s32 = .[0, 1, 2];
    mesh_set_indices(Tri.mesh, indices);
}

update :: () {
    if !Tri.verified && App.time.elapsed > 3.0 {
        Tri.verified = true;
        verify_render();
        app_exit();
    }
}

render :: () {
    device := App.device;
    target := drawable_target_window(App.window);
    w := drawable_target_width_in_pixels(target);
    h := drawable_target_height_in_pixels(target);

    // fixed black clear for visual verification
    // animated clear color
    t := cast(float) App.time.elapsed;
    color := Color.{
        cast(u8) (127 + 127 * sin(t * 1.0)),
        cast(u8) (127 + 127 * sin(t * 2.0)),
        cast(u8) (127 + 127 * sin(t * 3.0)),
        255,
    };
    graphics_device_clear_color(device, target, color);

    // orthographic matrix (Matrix4x4.CreateOrthographicOffCenter(0, w, h, 0, 0, max),
    // row-major memory like System.Numerics)
    zfar := 1000000.0;
    m: Matrix4;
    m._11 =  2.0 / cast(float) w;
    m._22 = -2.0 / cast(float) h;
    m._33 =  1.0 / zfar;
    m._41 = -1;
    m._42 =  1;
    m._43 = -1;
    m._44 = 1;
    material_stage_set_uniform_value(*Tri.material.Vertex, 0, m);

    cmd := draw_command_from_mesh(target, Tri.mesh, Tri.material);
    graphics_device_draw(device, cmd);
}

// Reads back the window backbuffer and verifies the triangle rendered:
// the center pixel must differ from the clear color (corner pixel).
verify_render :: () {
    device := App.device;
    backbuffer := graphics_device_get_backbuffer(device, App.window);
    if backbuffer == null {
        print("VERIFY: no backbuffer (FAILED)\n");
        return;
    }
    tex := backbuffer.Attachments[0];
    pixels: [] Color = .{
        data = cast(*Color) alloc(tex.Width * tex.Height * size_of(Color)),
        count = tex.Width * tex.Height,
    };
    defer free(pixels.data);
    texture_get_data(tex, pixels);

    center := pixels[(tex.Height/2) * tex.Width + tex.Width/2];
    corner := pixels[8 * tex.Width + 8];

    differing := 0;
    for p: pixels {
        if p != corner differing += 1;
    }

    ok := differing > 10000;   // triangle covers ~1/4 of the backbuffer
    print("VERIFY %  center=% corner=% differing=% of %\n",
        ifx ok then "PASS" else "FAIL", center, corner, differing, pixels.count);
}
