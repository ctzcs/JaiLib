// ink_post.jai
// Port of Ascension/src/content/ink_post.odin
// Ink-style post-processing: render the scene offscreen, then stylize it.

#import "Basic";
#import "bindings/raylib";
#import "core/screen";
#import "content/asset_storage";

Ink_Tuning :: struct {
    enabled:              bool;
    paper_strength:       float32;
    ramp_contrast:        float32;
    edge_width:           float32;
    edge_threshold:       float32;
    edge_strength:        float32;
    fluid_enabled:        bool;
    fluid_spawn_rate:     float32;
    fluid_emit_radius:    float32;
    fluid_vel_inject:     float32;
    fluid_vorticity:      float32;
    fluid_curl_strength:  float32;
    fluid_curl_scale:     float32;
    fluid_viscosity:      float32;
    fluid_vel_scale:      float32;
    fluid_dye_advect:     float32;
    fluid_buoyancy:       float32;
    fluid_dye_fade:       float32;
    fluid_dye_kappa:      float32;
    fluid_overlay_strength: float32;
    fluid_density_lo:     float32;
    fluid_density_hi:     float32;
    fluid_alpha_max:      float32;
    fluid_emit_cap:       float32;
    fluid_bleed_softness: float32;
}

INK_TUNING_DEFAULT :: Ink_Tuning.{
    enabled = true,
    paper_strength = 0.18,
    ramp_contrast = 0.78,
    edge_width = 1.4,
    edge_threshold = 0.22,
    edge_strength = 0.55,
    fluid_enabled = true,
    fluid_spawn_rate = 0.28,
    fluid_emit_radius = 0.055,
    fluid_vel_inject = 0.32,
    fluid_vorticity = 0.48,
    fluid_curl_strength = 0.50,
    fluid_curl_scale = 1.2,
    fluid_viscosity = 0.04,
    fluid_vel_scale = 0.55,
    fluid_dye_advect = 0.32,
    fluid_buoyancy = 0.12,
    fluid_dye_fade = 0.9965,
    fluid_dye_kappa = 0.18,
    fluid_overlay_strength = 1.15,
    fluid_density_lo = 0.0,
    fluid_density_hi = 0.08,
    fluid_alpha_max = 0.95,
    fluid_emit_cap = 1.05,
    fluid_bleed_softness = 0.04,
};

PAPER_COLOR :: WHITE;

Ink_Post :: struct {
    scene_rt:           RenderTexture;
    stylized_rt:        RenderTexture;
    shader:             Shader;
    loc_resolution:     s32;
    loc_paper_strength: s32;
    loc_ramp_contrast:  s32;
    loc_edge_width:     s32;
    loc_edge_threshold: s32;
    loc_edge_strength:  s32;
}

ink_post_init :: (ip: *Ink_Post) {
    ip.scene_rt = LoadRenderTexture(SCREEN_WIDTH, SCREEN_HEIGHT);
    ip.stylized_rt = LoadRenderTexture(SCREEN_WIDTH, SCREEN_HEIGHT);
    SetTextureFilter(ip.stylized_rt.texture, .BILINEAR);
    ip.shader = load_shader_pair(.InkPostVs, .InkPostFs);
    ip.loc_resolution = GetShaderLocation(ip.shader, "uResolution");
    ip.loc_paper_strength = GetShaderLocation(ip.shader, "uPaperStrength");
    ip.loc_ramp_contrast = GetShaderLocation(ip.shader, "uRampContrast");
    ip.loc_edge_width = GetShaderLocation(ip.shader, "uEdgeWidth");
    ip.loc_edge_threshold = GetShaderLocation(ip.shader, "uEdgeThreshold");
    ip.loc_edge_strength = GetShaderLocation(ip.shader, "uEdgeStrength");
}

ink_post_destroy :: (ip: *Ink_Post) {
    UnloadRenderTexture(ip.scene_rt);
    UnloadRenderTexture(ip.stylized_rt);
    UnloadShader(ip.shader);
}

ink_post_begin_scene :: (ip: *Ink_Post) {
    BeginTextureMode(ip.scene_rt);
    ClearBackground(PAPER_COLOR);
}

ink_post_end_scene :: (ip: *Ink_Post) {
    EndTextureMode();
}

ink_post_set_uniforms :: (ip: *Ink_Post, tuning: *Ink_Tuning) {
    w := cast(float32) SCREEN_WIDTH;
    h := cast(float32) SCREEN_HEIGHT;
    res := Vector2.{ x = w, y = h };
    SetShaderValue(ip.shader, ip.loc_resolution, cast(*void) *res, .VEC2);
    SetShaderValue(ip.shader, ip.loc_paper_strength, cast(*void) *tuning.paper_strength, .FLOAT);
    SetShaderValue(ip.shader, ip.loc_ramp_contrast, cast(*void) *tuning.ramp_contrast, .FLOAT);
    SetShaderValue(ip.shader, ip.loc_edge_width, cast(*void) *tuning.edge_width, .FLOAT);
    SetShaderValue(ip.shader, ip.loc_edge_threshold, cast(*void) *tuning.edge_threshold, .FLOAT);
    SetShaderValue(ip.shader, ip.loc_edge_strength, cast(*void) *tuning.edge_strength, .FLOAT);
}

ink_post_render_stylized :: (ip: *Ink_Post, tuning: *Ink_Tuning) {
    w := cast(float32) SCREEN_WIDTH;
    h := cast(float32) SCREEN_HEIGHT;
    src := Rectangle.{ x = 0, y = 0, width = w, height = -h };

    BeginTextureMode(ip.stylized_rt);
    ClearBackground(PAPER_COLOR);
    if tuning.enabled {
        ink_post_set_uniforms(ip, tuning);
        BeginShaderMode(ip.shader);
    }
    DrawTextureRec(ip.scene_rt.texture, src, Vector2.{ x = 0, y = 0 }, WHITE);
    if tuning.enabled {
        EndShaderMode();
    }
    EndTextureMode();
}

ink_post_draw_stylized :: (ip: *Ink_Post) {
    w := cast(float32) SCREEN_WIDTH;
    h := cast(float32) SCREEN_HEIGHT;
    src := Rectangle.{ x = 0, y = 0, width = w, height = -h };
    DrawTextureRec(ip.stylized_rt.texture, src, Vector2.{ x = 0, y = 0 }, WHITE);
}
