// ink_post.jai — 水墨后处理（samples/fluid2d 的组成部分，经 main.jai
// #load 合并；依赖由 main 的 #import "gfx" 提供）。
//
// 场景/风格化各为一张 Target；风格化 pass = gfx_blit_pass（ink_post
// 片元 blob），合成 = batcher_image。左上原点坐标，无 GL 翻转。

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

// 与 shaders/hlsl/ink_post.hlsl 的 cbuffer Params 一一对应
// （全 float4 对齐，杜绝 HLSL/Jai 打包错位）。
Ink_Post_Params :: struct {
    res:   GM.Vector4; // xy = uResolution
    paper: GM.Vector4; // x = uPaperStrength; y = uRampContrast; z = uEdgeWidth; w = uEdgeThreshold
    edge:  GM.Vector4; // x = uEdgeStrength
}
#assert size_of(Ink_Post_Params) == 48;

Ink_Post :: struct {
    width:     s32;
    height:    s32;
    scene_rt:    *F.Target;
    stylized_rt: *F.Target;
    shader:      *Gfx_Shader;
}

ink_post_init :: (ip: *Ink_Post, width: s32, height: s32) {
    ip.width  = width;
    ip.height = height;
    ip.scene_rt    = F.target_create(F.App.device, width, height, "ink.scene");
    ip.stylized_rt = F.target_create(F.App.device, width, height, "ink.stylized");
    ip.shader      = gfx_load_fragment_shader("ink_post", 1);
}

ink_post_destroy :: (ip: *Ink_Post) {
    F.target_dispose(ip.scene_rt);
    F.target_dispose(ip.stylized_rt);
    gfx_shader_destroy(ip.shader);
}

// 场景阶段（世界绘制走全局 batcher）。
ink_post_begin_scene :: (ip: *Ink_Post) {
    gfx_pass_begin(F.drawable_target_target(ip.scene_rt), PAPER_COLOR);
}

ink_post_end_scene :: (ip: *Ink_Post) {
    gfx_pass_end(F.drawable_target_target(ip.scene_rt));
}

ink_post_render_stylized :: (ip: *Ink_Post, tuning: *Ink_Tuning) {
    if ip.shader == null {
        // 无 shader blob 时直接把场景搬进风格化目标（保持管线可跑）。
        gfx_blit_pass(F.drawable_target_target(ip.stylized_rt), null, F.target_texture(ip.scene_rt), ip.width, ip.height, PAPER_COLOR);
        return;
    }

    params := Ink_Post_Params.{
        res   = .{ x = cast(float) ip.width, y = cast(float) ip.height, z = 0, w = 0 },
        paper = .{ x = tuning.paper_strength, y = tuning.ramp_contrast, z = tuning.edge_width, w = tuning.edge_threshold },
        edge  = .{ x = tuning.edge_strength, y = 0, z = 0, w = 0 },
    };
    gfx_shader_set_params(ip.shader, *params);

    gfx_blit_pass(F.drawable_target_target(ip.stylized_rt), ip.shader, F.target_texture(ip.scene_rt), ip.width, ip.height, PAPER_COLOR);
}

// 合成阶段：把风格化结果按 (dst_w, dst_h) 拉伸画进当前屏幕 pass
//（窗口开了 HIGH_PIXEL_DENSITY，backbuffer 是物理像素——用实际尺寸，别硬编码）。
ink_post_draw_stylized :: (ip: *Ink_Post, dst_w: s32, dst_h: s32) {
    tex := F.target_texture(ip.stylized_rt);
    F.batcher_set_texture(gfx_batcher, tex);
    F.batcher_push_sampler(gfx_batcher, F.texture_sampler_make(.LINEAR, F.Texture_Wrap.CLAMP));
    w := cast(float) dst_w;
    h := cast(float) dst_h;
    F.batcher_quad_textured(
        gfx_batcher, tex,
        .{ x = 0, y = 0 }, .{ x = w, y = 0 }, .{ x = w, y = h }, .{ x = 0, y = h },
        .{ x = 0, y = 0 }, .{ x = 1, y = 0 }, .{ x = 1, y = 1 }, .{ x = 0, y = 1 },
        WHITE,
    );
    F.batcher_pop_sampler(gfx_batcher);
}
