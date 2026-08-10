// ink_fluid.jai
// Port of Ascension/src/content/ink_fluid.odin
// 4ltBWj-style GPU fluid: random point emitters + NS velocity-field dye
// advection overlay.

#import "Basic";
#import "bindings/raylib";
#import "core/screen";
#import "content/asset_storage";
#import "content/render/ink_post";

FLUID_SIM_SCALE :: 0.85;
FLUID_PRESSURE_ITERS :: 14;
FLUID_DIFFUSE_ITERS :: 1;
FLUID_WARMUP_FRAMES :: 24;

Ink_Fluid :: struct {
    sim_w: s32;
    sim_h: s32;

    time:      float32;
    emit_seed: float32;

    vel:      [2] RenderTexture;
    vel_idx:  int;
    dye:      [2] RenderTexture;
    dye_idx:  int;
    pressure: [2] RenderTexture;
    press_idx: int;

    curl_rt: RenderTexture;
    div_rt:  RenderTexture;

    sh_force:      Shader;
    sh_curl:       Shader;
    sh_vort:       Shader;
    sh_jacobi:     Shader;
    sh_divergence: Shader;
    sh_project:    Shader;
    sh_advect:     Shader;
    sh_seed:       Shader;
    sh_dye_diffuse: Shader;
    sh_display:    Shader;

    loc_time:          s32;
    loc_emit_seed:     s32;
    loc_curl_strength: s32;
    loc_curl_scale:    s32;
    loc_buoyancy:      s32;
    loc_emit_radius:   s32;
    loc_vel_inject:    s32;
    loc_vorticity:     s32;
    loc_alpha:         s32;
    loc_beta:          s32;
    loc_scalar:        s32;
    loc_dt:            s32;
    loc_dissipation:   s32;
    loc_vel_scale:     s32;
    loc_advect_scalar: s32;
    loc_spawn_rate:    s32;
    loc_dye_fade:      s32;
    loc_overlay:       s32;
    loc_density_lo:    s32;
    loc_density_hi:    s32;
    loc_alpha_max:     s32;
    loc_emit_cap:      s32;
    loc_dye_kappa:     s32;
    loc_dye_diffuse_tex: s32;
    loc_bleed:         s32;
    loc_display_tex:   s32;
    loc_display_res:   s32;
    loc_force_tex:     s32;
    loc_dye_tex:       s32;
    loc_curl_tex:      s32;
    loc_vel_tex:       s32;
    loc_seed_tex:      s32;
    loc_u_source:      s32;
    loc_jacobi_field:  s32;
    loc_u_velocity:    s32;
    loc_u_pressure:    s32;
    loc_u_field:       s32;
    loc_div_tex:       s32;
    loc_proj_vel:      s32;
}

fluid_sim_src :: (f: *Ink_Fluid) -> Rectangle {
    return .{ x = 0, y = 0, width = cast(float32) f.sim_w, height = -cast(float32) f.sim_h };
}

fluid_screen_dest :: () -> Rectangle {
    return .{ x = 0, y = 0, width = cast(float32) SCREEN_WIDTH, height = cast(float32) SCREEN_HEIGHT };
}

fluid_blt :: (f: *Ink_Fluid, tex: Texture) {
    DrawTextureRec(tex, fluid_sim_src(f), Vector2.{ x = 0, y = 0 }, WHITE);
}

fluid_set_texel :: (shader: Shader, w: s32, h: s32) {
    texel := Vector2.{ x = 1.0 / cast(float32) w, y = 1.0 / cast(float32) h };
    loc := GetShaderLocation(shader, "uTexelSize");
    if loc >= 0 {
        SetShaderValue(shader, loc, cast(*void) *texel, .VEC2);
    }
}

fluid_clear_vel :: (f: *Ink_Fluid) {
    for i: 0..1 {
        BeginTextureMode(f.vel[cast(s64) i]);
        ClearBackground(Color.{ r = 128, g = 128, b = 0, a = 255 });
        EndTextureMode();
    }
}

fluid_clear_dye :: (f: *Ink_Fluid) {
    for i: 0..1 {
        BeginTextureMode(f.dye[cast(s64) i]);
        ClearBackground(BLANK);
        EndTextureMode();
    }
}

fluid_new_emit_seed :: () -> float32 {
    return cast(float32) GetRandomValue(1, 100000) * 0.01;
}

ink_fluid_init :: (f: *Ink_Fluid) {
    f.sim_w = cast(s32) (cast(float32) SCREEN_WIDTH * FLUID_SIM_SCALE);
    f.sim_h = cast(s32) (cast(float32) SCREEN_HEIGHT * FLUID_SIM_SCALE);
    if f.sim_w < 64 {
        f.sim_w = 64;
    }
    if f.sim_h < 64 {
        f.sim_h = 64;
    }

    f.vel[0] = LoadRenderTexture(f.sim_w, f.sim_h);
    f.vel[1] = LoadRenderTexture(f.sim_w, f.sim_h);
    f.dye[0] = LoadRenderTexture(f.sim_w, f.sim_h);
    f.dye[1] = LoadRenderTexture(f.sim_w, f.sim_h);
    f.pressure[0] = LoadRenderTexture(f.sim_w, f.sim_h);
    f.pressure[1] = LoadRenderTexture(f.sim_w, f.sim_h);
    f.curl_rt = LoadRenderTexture(f.sim_w, f.sim_h);
    f.div_rt = LoadRenderTexture(f.sim_w, f.sim_h);

    for i: 0..1 {
        SetTextureFilter(f.vel[cast(s64) i].texture, .BILINEAR);
        SetTextureFilter(f.dye[cast(s64) i].texture, .BILINEAR);
        SetTextureFilter(f.pressure[cast(s64) i].texture, .BILINEAR);
    }
    SetTextureFilter(f.curl_rt.texture, .BILINEAR);

    f.sh_force = load_shader_pair(.FluidVs, .FluidForceFs);
    f.sh_curl = load_shader_pair(.FluidVs, .FluidCurlFs);
    f.sh_vort = load_shader_pair(.FluidVs, .FluidVortFs);
    f.sh_jacobi = load_shader_pair(.FluidVs, .FluidJacobiFs);
    f.sh_divergence = load_shader_pair(.FluidVs, .FluidDivergenceFs);
    f.sh_project = load_shader_pair(.FluidVs, .FluidProjectFs);
    f.sh_advect = load_shader_pair(.FluidVs, .FluidAdvectFs);
    f.sh_seed = load_shader_pair(.FluidVs, .FluidSeedFs);
    f.sh_dye_diffuse = load_shader_pair(.FluidVs, .FluidDyeDiffuseFs);
    f.sh_display = load_shader_pair(.FluidVs, .FluidDisplayFs);

    f.loc_time = GetShaderLocation(f.sh_force, "uTime");
    f.loc_emit_seed = GetShaderLocation(f.sh_force, "uEmitSeed");
    f.loc_curl_strength = GetShaderLocation(f.sh_force, "uCurlStrength");
    f.loc_curl_scale = GetShaderLocation(f.sh_force, "uCurlScale");
    f.loc_buoyancy = GetShaderLocation(f.sh_force, "uBuoyancy");
    f.loc_emit_radius = GetShaderLocation(f.sh_force, "uEmitRadius");
    f.loc_vel_inject = GetShaderLocation(f.sh_force, "uVelInject");
    f.loc_vorticity = GetShaderLocation(f.sh_vort, "uVorticity");
    f.loc_alpha = GetShaderLocation(f.sh_jacobi, "uAlpha");
    f.loc_beta = GetShaderLocation(f.sh_jacobi, "uBeta");
    f.loc_scalar = GetShaderLocation(f.sh_jacobi, "uScalar");
    f.loc_dt = GetShaderLocation(f.sh_advect, "uDt");
    f.loc_dissipation = GetShaderLocation(f.sh_advect, "uDissipation");
    f.loc_vel_scale = GetShaderLocation(f.sh_advect, "uVelScale");
    f.loc_advect_scalar = GetShaderLocation(f.sh_advect, "uAdvectScalar");
    f.loc_spawn_rate = GetShaderLocation(f.sh_seed, "uSpawnRate");
    f.loc_dye_fade = GetShaderLocation(f.sh_seed, "uFade");
    f.loc_overlay = GetShaderLocation(f.sh_display, "uOverlayStrength");
    f.loc_density_lo = GetShaderLocation(f.sh_display, "uDensityLo");
    f.loc_density_hi = GetShaderLocation(f.sh_display, "uDensityHi");
    f.loc_alpha_max = GetShaderLocation(f.sh_display, "uAlphaMax");
    f.loc_emit_cap = GetShaderLocation(f.sh_seed, "uEmitCap");
    f.loc_dye_kappa = GetShaderLocation(f.sh_dye_diffuse, "uKappa");
    f.loc_dye_diffuse_tex = GetShaderLocation(f.sh_dye_diffuse, "texture0");
    f.loc_bleed = GetShaderLocation(f.sh_display, "uBleedSoftness");
    f.loc_display_tex = GetShaderLocation(f.sh_display, "texture0");
    f.loc_display_res = GetShaderLocation(f.sh_display, "uResolution");
    f.loc_force_tex = GetShaderLocation(f.sh_force, "texture0");
    f.loc_dye_tex = GetShaderLocation(f.sh_force, "uDye");
    f.loc_curl_tex = GetShaderLocation(f.sh_curl, "texture0");
    f.loc_vel_tex = GetShaderLocation(f.sh_vort, "uVelocity");
    f.loc_seed_tex = GetShaderLocation(f.sh_seed, "texture0");
    f.loc_u_source = GetShaderLocation(f.sh_jacobi, "uSource");
    f.loc_jacobi_field = GetShaderLocation(f.sh_jacobi, "uField");
    f.loc_u_velocity = GetShaderLocation(f.sh_advect, "uVelocity");
    f.loc_u_pressure = GetShaderLocation(f.sh_project, "uPressure");
    f.loc_u_field = GetShaderLocation(f.sh_advect, "uField");
    f.loc_div_tex = GetShaderLocation(f.sh_divergence, "texture0");
    f.loc_proj_vel = GetShaderLocation(f.sh_project, "uVelocity");

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
        UnloadRenderTexture(f.vel[cast(s64) i]);
        UnloadRenderTexture(f.dye[cast(s64) i]);
        UnloadRenderTexture(f.pressure[cast(s64) i]);
    }
    UnloadRenderTexture(f.curl_rt);
    UnloadRenderTexture(f.div_rt);
    UnloadShader(f.sh_force);
    UnloadShader(f.sh_curl);
    UnloadShader(f.sh_vort);
    UnloadShader(f.sh_jacobi);
    UnloadShader(f.sh_divergence);
    UnloadShader(f.sh_project);
    UnloadShader(f.sh_advect);
    UnloadShader(f.sh_seed);
    UnloadShader(f.sh_dye_diffuse);
    UnloadShader(f.sh_display);
}

fluid_swap :: (idx: *int) {
    <<idx = 1 - <<idx;
}

fluid_jacobi_pass :: (f: *Ink_Fluid, dst: RenderTexture, field_tex: Texture, source_tex: Texture, alpha: float32, beta: float32, scalar: s32) {
    alpha_v := alpha;
    beta_v := beta;
    scalar_v := scalar;
    BeginTextureMode(dst);
    ClearBackground(BLANK);
    BeginShaderMode(f.sh_jacobi);
    fluid_set_texel(f.sh_jacobi, f.sim_w, f.sim_h);
    SetShaderValue(f.sh_jacobi, f.loc_alpha, cast(*void) *alpha_v, .FLOAT);
    SetShaderValue(f.sh_jacobi, f.loc_beta, cast(*void) *beta_v, .FLOAT);
    SetShaderValue(f.sh_jacobi, f.loc_scalar, cast(*void) *scalar_v, .INT);
    SetShaderValueTexture(f.sh_jacobi, f.loc_jacobi_field, field_tex);
    SetShaderValueTexture(f.sh_jacobi, f.loc_u_source, source_tex);
    fluid_blt(f, field_tex);
    EndShaderMode();
    EndTextureMode();
}

fluid_advect_pass :: (f: *Ink_Fluid, dst: RenderTexture, field_tex: Texture, vel_tex: Texture, dt: float32, dissipation: float32, vel_scale: float32, scalar: s32) {
    dt_v := dt;
    dissipation_v := dissipation;
    vel_scale_v := vel_scale;
    scalar_v := scalar;
    BeginTextureMode(dst);
    ClearBackground(BLANK);
    BeginShaderMode(f.sh_advect);
    fluid_set_texel(f.sh_advect, f.sim_w, f.sim_h);
    SetShaderValue(f.sh_advect, f.loc_dt, cast(*void) *dt_v, .FLOAT);
    SetShaderValue(f.sh_advect, f.loc_dissipation, cast(*void) *dissipation_v, .FLOAT);
    SetShaderValue(f.sh_advect, f.loc_vel_scale, cast(*void) *vel_scale_v, .FLOAT);
    SetShaderValue(f.sh_advect, f.loc_advect_scalar, cast(*void) *scalar_v, .INT);
    SetShaderValueTexture(f.sh_advect, f.loc_u_field, field_tex);
    SetShaderValueTexture(f.sh_advect, f.loc_u_velocity, vel_tex);
    fluid_blt(f, field_tex);
    EndShaderMode();
    EndTextureMode();
}

fluid_set_emit_uniforms :: (f: *Ink_Fluid, tuning: *Ink_Tuning, shader: Shader) {
    seed := f.emit_seed;
    radius := tuning.fluid_emit_radius;
    time := f.time;

    loc_time := GetShaderLocation(shader, "uTime");
    loc_seed := GetShaderLocation(shader, "uEmitSeed");
    loc_radius := GetShaderLocation(shader, "uEmitRadius");
    if loc_time >= 0 {
        SetShaderValue(shader, loc_time, cast(*void) *time, .FLOAT);
    }
    if loc_seed >= 0 {
        SetShaderValue(shader, loc_seed, cast(*void) *seed, .FLOAT);
    }
    if loc_radius >= 0 {
        SetShaderValue(shader, loc_radius, cast(*void) *radius, .FLOAT);
    }
}

fluid_dye_diffuse_pass :: (f: *Ink_Fluid, dst: RenderTexture, src: Texture, kappa: float32, dt: float32) {
    kappa_v := kappa;
    dt_v := dt;
    BeginTextureMode(dst);
    ClearBackground(BLANK);
    BeginShaderMode(f.sh_dye_diffuse);
    fluid_set_texel(f.sh_dye_diffuse, f.sim_w, f.sim_h);
    SetShaderValue(f.sh_dye_diffuse, f.loc_dye_kappa, cast(*void) *kappa_v, .FLOAT);
    SetShaderValue(f.sh_dye_diffuse, GetShaderLocation(f.sh_dye_diffuse, "uDt"), cast(*void) *dt_v, .FLOAT);
    SetShaderValueTexture(f.sh_dye_diffuse, f.loc_dye_diffuse_tex, src);
    fluid_blt(f, src);
    EndShaderMode();
    EndTextureMode();
}

ink_fluid_step :: (f: *Ink_Fluid, tuning: *Ink_Tuning, dt: float32) {
    if !tuning.fluid_enabled {
        return;
    }

    f.time += dt;
    clamped_dt := clamp(dt, 1.0 / 240.0, 1.0 / 20.0);

    // 1. Advect velocity.
    scalar_vel: s32 = 0;
    fluid_advect_pass(f, f.vel[1 - f.vel_idx], f.vel[f.vel_idx].texture, f.vel[f.vel_idx].texture, clamped_dt, 0.998, tuning.fluid_vel_scale, scalar_vel);
    fluid_swap(*f.vel_idx);

    // 2. Curl.
    {
        vel_tex := f.vel[f.vel_idx].texture;
        BeginTextureMode(f.curl_rt);
        ClearBackground(BLANK);
        BeginShaderMode(f.sh_curl);
        fluid_set_texel(f.sh_curl, f.sim_w, f.sim_h);
        SetShaderValueTexture(f.sh_curl, f.loc_curl_tex, vel_tex);
        fluid_blt(f, vel_tex);
        EndShaderMode();
        EndTextureMode();
    }

    // 3. Vorticity confinement.
    {
        dst := f.vel[1 - f.vel_idx];
        vel_tex := f.vel[f.vel_idx].texture;
        vort := tuning.fluid_vorticity;
        BeginTextureMode(dst);
        ClearBackground(BLANK);
        BeginShaderMode(f.sh_vort);
        fluid_set_texel(f.sh_vort, f.sim_w, f.sim_h);
        SetShaderValue(f.sh_vort, f.loc_vorticity, cast(*void) *vort, .FLOAT);
        SetShaderValueTexture(f.sh_vort, f.loc_vel_tex, vel_tex);
        SetShaderValueTexture(f.sh_vort, GetShaderLocation(f.sh_vort, "uCurl"), f.curl_rt.texture);
        fluid_blt(f, vel_tex);
        EndShaderMode();
        EndTextureMode();
        fluid_swap(*f.vel_idx);
    }

    // 4. Diffusion.
    alpha := tuning.fluid_viscosity;
    beta := 4.0 + alpha;
    scalar_vec: s32 = 0;
    vel_src := f.vel[f.vel_idx].texture;
    for _: 0..FLUID_DIFFUSE_ITERS-1 {
        fluid_jacobi_pass(f, f.vel[1 - f.vel_idx], f.vel[f.vel_idx].texture, vel_src, alpha, beta, scalar_vec);
        fluid_swap(*f.vel_idx);
    }

    // 6. Pressure projection.
    {
        vel_tex := f.vel[f.vel_idx].texture;
        BeginTextureMode(f.div_rt);
        ClearBackground(BLANK);
        BeginShaderMode(f.sh_divergence);
        fluid_set_texel(f.sh_divergence, f.sim_w, f.sim_h);
        SetShaderValueTexture(f.sh_divergence, f.loc_div_tex, vel_tex);
        fluid_blt(f, vel_tex);
        EndShaderMode();
        EndTextureMode();
    }

    scalar_on: s32 = 1;
    div_tex := f.div_rt.texture;
    for _: 0..FLUID_PRESSURE_ITERS-1 {
        fluid_jacobi_pass(f, f.pressure[1 - f.press_idx], f.pressure[f.press_idx].texture, div_tex, 1.0, 4.0, scalar_on);
        fluid_swap(*f.press_idx);
    }

    {
        dst := f.vel[1 - f.vel_idx];
        vel_tex := f.vel[f.vel_idx].texture;
        BeginTextureMode(dst);
        ClearBackground(BLANK);
        BeginShaderMode(f.sh_project);
        fluid_set_texel(f.sh_project, f.sim_w, f.sim_h);
        SetShaderValueTexture(f.sh_project, f.loc_proj_vel, vel_tex);
        SetShaderValueTexture(f.sh_project, f.loc_u_pressure, f.pressure[f.press_idx].texture);
        fluid_blt(f, vel_tex);
        EndShaderMode();
        EndTextureMode();
        fluid_swap(*f.vel_idx);
    }

    // 7. Force after projection (buoyancy + jet, not cancelled by projection).
    {
        dst := f.vel[1 - f.vel_idx];
        src := f.vel[f.vel_idx].texture;
        curl_scale := tuning.fluid_curl_scale;
        buoyancy := tuning.fluid_buoyancy;
        vel_inject := tuning.fluid_vel_inject;
        BeginTextureMode(dst);
        ClearBackground(BLANK);
        BeginShaderMode(f.sh_force);
        fluid_set_texel(f.sh_force, f.sim_w, f.sim_h);
        fluid_set_emit_uniforms(f, tuning, f.sh_force);
        SetShaderValue(f.sh_force, f.loc_curl_strength, cast(*void) *tuning.fluid_curl_strength, .FLOAT);
        SetShaderValue(f.sh_force, f.loc_curl_scale, cast(*void) *curl_scale, .FLOAT);
        SetShaderValue(f.sh_force, f.loc_buoyancy, cast(*void) *buoyancy, .FLOAT);
        SetShaderValue(f.sh_force, f.loc_vel_inject, cast(*void) *vel_inject, .FLOAT);
        SetShaderValue(f.sh_force, f.loc_emit_radius, cast(*void) *tuning.fluid_emit_radius, .FLOAT);
        SetShaderValueTexture(f.sh_force, f.loc_force_tex, src);
        SetShaderValueTexture(f.sh_force, f.loc_dye_tex, f.dye[f.dye_idx].texture);
        fluid_blt(f, src);
        EndShaderMode();
        EndTextureMode();
        fluid_swap(*f.vel_idx);
    }

    // 8. Advect old dye first, then emit new dye.
    scalar_dye: s32 = 0;
    fluid_advect_pass(f, f.dye[1 - f.dye_idx], f.dye[f.dye_idx].texture, f.vel[f.vel_idx].texture, clamped_dt, tuning.fluid_dye_fade, tuning.fluid_dye_advect, scalar_dye);
    fluid_swap(*f.dye_idx);

    // 9. RGB dye diffusion.
    fluid_dye_diffuse_pass(f, f.dye[1 - f.dye_idx], f.dye[f.dye_idx].texture, tuning.fluid_dye_kappa, clamped_dt);
    fluid_swap(*f.dye_idx);

    // 10. Multi-color smoke emission.
    {
        dst := f.dye[1 - f.dye_idx];
        src := f.dye[f.dye_idx].texture;
        spawn := tuning.fluid_spawn_rate;
        emit_cap := tuning.fluid_emit_cap;
        BeginTextureMode(dst);
        ClearBackground(BLANK);
        BeginShaderMode(f.sh_seed);
        fluid_set_emit_uniforms(f, tuning, f.sh_seed);
        SetShaderValue(f.sh_seed, f.loc_spawn_rate, cast(*void) *spawn, .FLOAT);
        SetShaderValue(f.sh_seed, f.loc_emit_cap, cast(*void) *emit_cap, .FLOAT);
        SetShaderValue(f.sh_seed, GetShaderLocation(f.sh_seed, "uEmitRadius"), cast(*void) *tuning.fluid_emit_radius, .FLOAT);
        SetShaderValueTexture(f.sh_seed, f.loc_seed_tex, src);
        fluid_blt(f, src);
        EndShaderMode();
        EndTextureMode();
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

ink_fluid_draw_overlay :: (f: *Ink_Fluid, tuning: *Ink_Tuning) {
    if !tuning.fluid_enabled {
        return;
    }

    overlay := tuning.fluid_overlay_strength;
    density_lo := tuning.fluid_density_lo;
    density_hi := tuning.fluid_density_hi;
    alpha_max := tuning.fluid_alpha_max;
    src := fluid_sim_src(f);
    dest := fluid_screen_dest();
    tex := f.dye[f.dye_idx].texture;

    BeginBlendMode(.ALPHA);
    BeginShaderMode(f.sh_display);
    SetShaderValue(f.sh_display, f.loc_overlay, cast(*void) *overlay, .FLOAT);
    SetShaderValue(f.sh_display, f.loc_density_lo, cast(*void) *density_lo, .FLOAT);
    SetShaderValue(f.sh_display, f.loc_density_hi, cast(*void) *density_hi, .FLOAT);
    SetShaderValue(f.sh_display, f.loc_alpha_max, cast(*void) *alpha_max, .FLOAT);
    DrawTexturePro(tex, src, dest, Vector2.{ x = 0, y = 0 }, 0, WHITE);
    EndShaderMode();
    EndBlendMode();
}
