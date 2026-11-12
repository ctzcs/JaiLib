// ink_fluid.jai
// Port of Ascension/src/content/ink_fluid.odin
// 4ltBWj-style GPU fluid: random point emitters + NS velocity-field dye
// advection overlay.
//
// jfoster 版：10 张 ping-pong Target + gfx_blit_pass（片元 blob）；
// 速度仍编码在 RGBA8（v*0.5+0.5）。坐标全链路左上原点，fluid_force
// shader 里的方向性 y 分量已取反以保持屏幕视觉方向（见其 HLSL 头注释）。




FLUID_SIM_SCALE :: 0.85;
FLUID_PRESSURE_ITERS :: 14;
FLUID_DIFFUSE_ITERS :: 1;
FLUID_WARMUP_FRAMES :: 24;

// ---- 各 shader 的 cbuffer 参数结构（与 shaders/hlsl/*.hlsl
// ---- 的 Params 一一对应，全 float4 对齐）。 ----

Fluid_Texel_Params :: struct {
    texel: GM.Vector4; // xy = uTexelSize
}
#assert size_of(Fluid_Texel_Params) == 16;

Fluid_Advect_Params :: struct {
    texel:  GM.Vector4; // xy = uTexelSize; z = uDt; w = uDissipation
    advect: GM.Vector4; // x = uVelScale; y = uAdvectScalar（1 = 标量模式）
}
#assert size_of(Fluid_Advect_Params) == 32;

Fluid_Jacobi_Params :: struct {
    texel: GM.Vector4; // xy = uTexelSize; z = uAlpha; w = uBeta
    mode:  GM.Vector4; // x = uScalar（1 = 标量模式）
}
#assert size_of(Fluid_Jacobi_Params) == 32;

Fluid_Vort_Params :: struct {
    texel: GM.Vector4; // xy = uTexelSize; z = uVorticity
}
#assert size_of(Fluid_Vort_Params) == 16;

Fluid_Force_Params :: struct {
    sim:    GM.Vector4; // xy = uTexelSize; z = uTime; w = uEmitSeed
    force:  GM.Vector4; // x = uCurlStrength; y = uCurlScale; z = uBuoyancy; w = uEmitRadius
    inject: GM.Vector4; // x = uVelInject
}
#assert size_of(Fluid_Force_Params) == 48;

Fluid_Seed_Params :: struct {
    emit: GM.Vector4; // x = uTime; y = uEmitSeed; z = uSpawnRate; w = uEmitRadius
    caps: GM.Vector4; // x = uEmitCap
}
#assert size_of(Fluid_Seed_Params) == 32;

Fluid_Diffuse_Params :: struct {
    sim: GM.Vector4; // xy = uTexelSize; z = uKappa; w = uDt
}
#assert size_of(Fluid_Diffuse_Params) == 16;

Fluid_Display_Params :: struct {
    range: GM.Vector4; // x = uOverlayStrength; y = uDensityLo; z = uDensityHi; w = uAlphaMax
}
#assert size_of(Fluid_Display_Params) == 16;

Ink_Fluid :: struct {
    screen_w: s32;
    screen_h: s32;
    sim_w: s32;
    sim_h: s32;

    time:      float32;
    emit_seed: float32;

    vel:      [2] *F.Target;
    vel_idx:  int;
    dye:      [2] *F.Target;
    dye_idx:  int;
    pressure: [2] *F.Target;
    press_idx: int;

    curl_rt: *F.Target;
    div_rt:  *F.Target;

    sh_force:       *Gfx_Shader;
    sh_curl:        *Gfx_Shader;
    sh_vort:        *Gfx_Shader;
    sh_jacobi:      *Gfx_Shader;
    sh_divergence:  *Gfx_Shader;
    sh_project:     *Gfx_Shader;
    sh_advect:      *Gfx_Shader;
    sh_seed:        *Gfx_Shader;
    sh_dye_diffuse: *Gfx_Shader;
    sh_display:     *Gfx_Shader;
}

fluid_new_emit_seed :: () -> float32 {
    return cast(float32) GetRandomValue(1, 100000) * 0.01;
}

fluid_texel :: (f: *Ink_Fluid) -> GM.Vector4 {
    return .{ x = 1.0 / cast(float) f.sim_w, y = 1.0 / cast(float) f.sim_h, z = 0, w = 0 };
}

fluid_clear_vel :: (f: *Ink_Fluid) {
    // 中性速度 = (0,0) 编码值 ~0.5；对应 raylib 版的 128/255。
    neutral :: Color.{ 128, 128, 0, 255 };
    for i: 0..1 {
        F.graphics_device_clear_color(F.App.device, F.drawable_target_target(f.vel[i]), neutral);
    }
}

fluid_clear_dye :: (f: *Ink_Fluid) {
    for i: 0..1 {
        F.graphics_device_clear_color(F.App.device, F.drawable_target_target(f.dye[i]), BLANK);
    }
}

ink_fluid_init :: (f: *Ink_Fluid, screen_w: s32, screen_h: s32) {
    f.screen_w = screen_w;
    f.screen_h = screen_h;
    f.sim_w = cast(s32) (cast(float32) screen_w * FLUID_SIM_SCALE);
    f.sim_h = cast(s32) (cast(float32) screen_h * FLUID_SIM_SCALE);
    if f.sim_w < 64 {
        f.sim_w = 64;
    }
    if f.sim_h < 64 {
        f.sim_h = 64;
    }

    device := F.App.device;
    f.vel[0] = F.target_create(device, f.sim_w, f.sim_h, "fluid.vel0");
    f.vel[1] = F.target_create(device, f.sim_w, f.sim_h, "fluid.vel1");
    f.dye[0] = F.target_create(device, f.sim_w, f.sim_h, "fluid.dye0");
    f.dye[1] = F.target_create(device, f.sim_w, f.sim_h, "fluid.dye1");
    f.pressure[0] = F.target_create(device, f.sim_w, f.sim_h, "fluid.press0");
    f.pressure[1] = F.target_create(device, f.sim_w, f.sim_h, "fluid.press1");
    f.curl_rt = F.target_create(device, f.sim_w, f.sim_h, "fluid.curl");
    f.div_rt  = F.target_create(device, f.sim_w, f.sim_h, "fluid.div");

    // 采样器数必须与 HLSL 声明一致：双纹理 pass（主 + 辅助）为 2，
    // 单纹理 pass 为 1（SDL_GPU 无反射，按声明数绑定）。
    f.sh_force       = gfx_load_fragment_shader("fluid_force",      2);
    f.sh_curl        = gfx_load_fragment_shader("fluid_curl",       1);
    f.sh_vort        = gfx_load_fragment_shader("fluid_vort",       2);
    f.sh_jacobi      = gfx_load_fragment_shader("fluid_jacobi",     2);
    f.sh_divergence  = gfx_load_fragment_shader("fluid_divergence", 1);
    f.sh_project     = gfx_load_fragment_shader("fluid_project",    2);
    f.sh_advect      = gfx_load_fragment_shader("fluid_advect",     2);
    f.sh_seed        = gfx_load_fragment_shader("fluid_seed",       1);
    f.sh_dye_diffuse = gfx_load_fragment_shader("fluid_dye_diffuse", 1);
    f.sh_display     = gfx_load_fragment_shader("fluid_display",    1);

    f.emit_seed = fluid_new_emit_seed();
    fluid_clear_vel(f);
    fluid_clear_dye(f);

    warmup := INK_TUNING_DEFAULT;
    for _: 0..FLUID_WARMUP_FRAMES-1 {
        ink_fluid_step(f, *warmup, 1.0 / 60.0);
    }
}

ink_fluid_destroy :: (f: *Ink_Fluid) {
    for i: 0..1 {
        F.target_dispose(f.vel[i]);
        F.target_dispose(f.dye[i]);
        F.target_dispose(f.pressure[i]);
    }
    F.target_dispose(f.curl_rt);
    F.target_dispose(f.div_rt);
    gfx_shader_destroy(f.sh_force);
    gfx_shader_destroy(f.sh_curl);
    gfx_shader_destroy(f.sh_vort);
    gfx_shader_destroy(f.sh_jacobi);
    gfx_shader_destroy(f.sh_divergence);
    gfx_shader_destroy(f.sh_project);
    gfx_shader_destroy(f.sh_advect);
    gfx_shader_destroy(f.sh_seed);
    gfx_shader_destroy(f.sh_dye_diffuse);
    gfx_shader_destroy(f.sh_display);
}

fluid_swap :: (idx: *int) {
    <<idx = 1 - <<idx;
}

// ---- 各模拟 pass（全部 = 设参数 + 辅助采样器 + gfx_blit_pass） ----

fluid_jacobi_pass :: (f: *Ink_Fluid, dst: *F.Target, field_tex: *F.Texture, source_tex: *F.Texture, alpha: float32, beta: float32, scalar: s32) {
    texel := fluid_texel(f);
    params := Fluid_Jacobi_Params.{
        texel = .{ x = texel.x, y = texel.y, z = alpha, w = beta },
        mode  = .{ x = cast(float) scalar, y = 0, z = 0, w = 0 },
    };
    gfx_shader_set_params(f.sh_jacobi, *params);
    gfx_shader_set_sampler(f.sh_jacobi, 1, source_tex);
    gfx_blit_pass(F.drawable_target_target(dst), f.sh_jacobi, field_tex, f.sim_w, f.sim_h, BLANK);
}

fluid_advect_pass :: (f: *Ink_Fluid, dst: *F.Target, field_tex: *F.Texture, vel_tex: *F.Texture, dt: float32, dissipation: float32, vel_scale: float32, scalar: s32) {
    texel := fluid_texel(f);
    params := Fluid_Advect_Params.{
        texel  = .{ x = texel.x, y = texel.y, z = dt, w = dissipation },
        advect = .{ x = vel_scale, y = cast(float) scalar, z = 0, w = 0 },
    };
    gfx_shader_set_params(f.sh_advect, *params);
    gfx_shader_set_sampler(f.sh_advect, 1, vel_tex);
    gfx_blit_pass(F.drawable_target_target(dst), f.sh_advect, field_tex, f.sim_w, f.sim_h, BLANK);
}

ink_fluid_step :: (f: *Ink_Fluid, tuning: *Ink_Tuning, dt: float32) {
    if !tuning.fluid_enabled {
        return;
    }

    f.time += dt;
    clamped_dt := clamp(dt, 1.0 / 240.0, 1.0 / 20.0);
    texel := fluid_texel(f);

    // 1. Advect velocity.
    fluid_advect_pass(f, f.vel[1 - f.vel_idx], F.target_texture(f.vel[f.vel_idx]), F.target_texture(f.vel[f.vel_idx]), clamped_dt, 0.998, tuning.fluid_vel_scale, 0);
    fluid_swap(*f.vel_idx);

    // 2. Curl.
    {
        vel_tex := F.target_texture(f.vel[f.vel_idx]);
        params := Fluid_Texel_Params.{ texel = texel };
        gfx_shader_set_params(f.sh_curl, *params);
        gfx_blit_pass(F.drawable_target_target(f.curl_rt), f.sh_curl, vel_tex, f.sim_w, f.sim_h, BLANK);
    }

    // 3. Vorticity confinement.
    {
        dst := f.vel[1 - f.vel_idx];
        vel_tex := F.target_texture(f.vel[f.vel_idx]);
        params := Fluid_Vort_Params.{
            texel = .{ x = texel.x, y = texel.y, z = tuning.fluid_vorticity, w = 0 },
        };
        gfx_shader_set_params(f.sh_vort, *params);
        gfx_shader_set_sampler(f.sh_vort, 1, F.target_texture(f.curl_rt));
        gfx_blit_pass(F.drawable_target_target(dst), f.sh_vort, vel_tex, f.sim_w, f.sim_h, BLANK);
        fluid_swap(*f.vel_idx);
    }

    // 4. Diffusion.
    alpha := tuning.fluid_viscosity;
    beta := 4.0 + alpha;
    vel_src := F.target_texture(f.vel[f.vel_idx]);
    for _: 0..FLUID_DIFFUSE_ITERS-1 {
        fluid_jacobi_pass(f, f.vel[1 - f.vel_idx], F.target_texture(f.vel[f.vel_idx]), vel_src, alpha, beta, 0);
        fluid_swap(*f.vel_idx);
    }

    // 6. Pressure projection.
    {
        vel_tex := F.target_texture(f.vel[f.vel_idx]);
        params := Fluid_Texel_Params.{ texel = texel };
        gfx_shader_set_params(f.sh_divergence, *params);
        gfx_blit_pass(F.drawable_target_target(f.div_rt), f.sh_divergence, vel_tex, f.sim_w, f.sim_h, BLANK);
    }

    div_tex := F.target_texture(f.div_rt);
    for _: 0..FLUID_PRESSURE_ITERS-1 {
        fluid_jacobi_pass(f, f.pressure[1 - f.press_idx], F.target_texture(f.pressure[f.press_idx]), div_tex, 1.0, 4.0, 1);
        fluid_swap(*f.press_idx);
    }

    {
        dst := f.vel[1 - f.vel_idx];
        vel_tex := F.target_texture(f.vel[f.vel_idx]);
        params := Fluid_Texel_Params.{ texel = texel };
        gfx_shader_set_params(f.sh_project, *params);
        gfx_shader_set_sampler(f.sh_project, 1, F.target_texture(f.pressure[f.press_idx]));
        gfx_blit_pass(F.drawable_target_target(dst), f.sh_project, vel_tex, f.sim_w, f.sim_h, BLANK);
        fluid_swap(*f.vel_idx);
    }

    // 7. Force after projection (buoyancy + jet, not cancelled by projection).
    {
        dst := f.vel[1 - f.vel_idx];
        src := F.target_texture(f.vel[f.vel_idx]);
        params := Fluid_Force_Params.{
            sim    = .{ x = texel.x, y = texel.y, z = f.time, w = f.emit_seed },
            force  = .{ x = tuning.fluid_curl_strength, y = tuning.fluid_curl_scale, z = tuning.fluid_buoyancy, w = tuning.fluid_emit_radius },
            inject = .{ x = tuning.fluid_vel_inject, y = 0, z = 0, w = 0 },
        };
        gfx_shader_set_params(f.sh_force, *params);
        gfx_shader_set_sampler(f.sh_force, 1, F.target_texture(f.dye[f.dye_idx]));
        gfx_blit_pass(F.drawable_target_target(dst), f.sh_force, src, f.sim_w, f.sim_h, BLANK);
        fluid_swap(*f.vel_idx);
    }

    // 8. Advect old dye first, then emit new dye.
    fluid_advect_pass(f, f.dye[1 - f.dye_idx], F.target_texture(f.dye[f.dye_idx]), F.target_texture(f.vel[f.vel_idx]), clamped_dt, tuning.fluid_dye_fade, tuning.fluid_dye_advect, 0);
    fluid_swap(*f.dye_idx);

    // 9. RGB dye diffusion.
    {
        params := Fluid_Diffuse_Params.{
            sim = .{ x = texel.x, y = texel.y, z = tuning.fluid_dye_kappa, w = clamped_dt },
        };
        gfx_shader_set_params(f.sh_dye_diffuse, *params);
        gfx_blit_pass(F.drawable_target_target(f.dye[1 - f.dye_idx]), f.sh_dye_diffuse, F.target_texture(f.dye[f.dye_idx]), f.sim_w, f.sim_h, BLANK);
        fluid_swap(*f.dye_idx);
    }

    // 10. Multi-color smoke emission.
    {
        dst := f.dye[1 - f.dye_idx];
        src := F.target_texture(f.dye[f.dye_idx]);
        params := Fluid_Seed_Params.{
            emit = .{ x = f.time, y = f.emit_seed, z = tuning.fluid_spawn_rate, w = tuning.fluid_emit_radius },
            caps = .{ x = tuning.fluid_emit_cap, y = 0, z = 0, w = 0 },
        };
        gfx_shader_set_params(f.sh_seed, *params);
        gfx_blit_pass(F.drawable_target_target(dst), f.sh_seed, src, f.sim_w, f.sim_h, BLANK);
        fluid_swap(*f.dye_idx);
    }
}

ink_fluid_reset :: (f: *Ink_Fluid, tuning: *Ink_Tuning) {
    f.time = 0;
    f.vel_idx = 0;
    f.dye_idx = 0;
    f.press_idx = 0;
    f.emit_seed = fluid_new_emit_seed();
    fluid_clear_vel(f);
    fluid_clear_dye(f);
    for _: 0..FLUID_WARMUP_FRAMES-1 {
        ink_fluid_step(f, tuning, 1.0 / 60.0);
    }
}

// 染料覆盖层：画进当前屏幕合成 pass（alpha 混合叠在风格化结果之上）。
ink_fluid_draw_overlay :: (f: *Ink_Fluid, tuning: *Ink_Tuning, dst_w: s32, dst_h: s32) {
    if !tuning.fluid_enabled || f.sh_display == null {
        return;
    }

    params := Fluid_Display_Params.{
        range = .{ x = tuning.fluid_overlay_strength, y = tuning.fluid_density_lo, z = tuning.fluid_density_hi, w = tuning.fluid_alpha_max },
    };
    gfx_shader_set_params(f.sh_display, *params);

    tex := F.target_texture(f.dye[f.dye_idx]);
    F.batcher_set_texture(gfx_batcher, tex);
    F.batcher_push_sampler(gfx_batcher, F.texture_sampler_make(.LINEAR, F.Texture_Wrap.CLAMP));
    F.batcher_push_material(gfx_batcher, f.sh_display.material);

    w := cast(float) dst_w;
    h := cast(float) dst_h;
    F.batcher_quad_textured(
        gfx_batcher,
        tex,
        .{ x = 0, y = 0 }, .{ x = w, y = 0 },
        .{ x = w, y = h }, .{ x = 0, y = h },
        .{ x = 0, y = 0 }, .{ x = 1, y = 0 },
        .{ x = 1, y = 1 }, .{ x = 0, y = 1 },
        WHITE,
    );

    F.batcher_pop_material(gfx_batcher);
    F.batcher_pop_sampler(gfx_batcher);
}
