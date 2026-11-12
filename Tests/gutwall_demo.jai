#import "Basic";
#import "gfx";
#import "test_support";
ED :: #import "editor";
IB :: #import "thirdparty/imgui_foster";
IM :: #import "ImGui";
J :: #import "threading";
S :: #import "storage";
#load "gutwall/folds.jai";
Uniforms :: struct { light, color, surface, options: GM.Vector4; }
Bake :: struct { settings: Gut_Settings; maps: Gut_Maps; cancel: Gut_Cancel; success: bool; }
bake: Bake;
settings: Gut_Settings;
scheduler: J.Job_Scheduler;
job: *J.Job_Handle;
maps: Gut_Maps;
textures: [3] *F.Texture;
first_textures: [3] *F.Texture;
shader: *Gfx_Shader;
capture_target: *F.Target;
game: S.Game_Storage;
resources,users: S.Directory_Storage;
user_override: string;
editor: ED.Property_Editor;
tests: Test_State;
auto_mode, cancel_mode: bool;
driver: F.Graphics_Driver = .D3D12;
mode: s32;
follow: bool = true;
orbit: bool;
fill, marker: bool = true;
light: Vector2 = .{-5,0};
light_height: float32 = 4.2;
intensity: float32 = 5;
radius: float32 = 15;
normal_strength: float32 = 1;
wetness: float32 = .65;
ambient: float32 = .34;
elapsed: float32;
status: string = "";
uploaded: s64;
verify_frame: s64;
previous,baseline: [] Color;
worker_bake :: (first: s64,end: s64,user: *void,worker: s64) {
    b := cast(*Bake) user;
    b.maps,b.success = gut_generate(b.settings,*b.cancel);
}
regenerate :: () {
    if job != null return;
    bake.settings=settings; bake.success=false; bake.cancel.requested=false;
    job=J.jobs_schedule(*scheduler,worker_bake,*bake);
}
as_colors :: (pixels: []Gut_Pixel) -> []Color { return .{data=cast(*Color) pixels.data,count=pixels.count}; }
export_png :: (path: string,pixels: []Color) -> bool {
    image := F.Image.{Width=maps.width,Height=maps.height,Data=pixels};
    png := F.image_encode_png(image); defer free(png.data);
    return png.count > 0 && S.storage_write(*game.user,path,png);
}
export_maps :: () -> bool {
    a := export_png("GutWallExport/gut-albedo.png",as_colors(maps.albedo));
    n := export_png("GutWallExport/gut-normal.png",as_colors(maps.normal));
    m := export_png("GutWallExport/gut-material.png",as_colors(maps.material));
    return a && n && m;
}
finish_bake :: () {
    if job == null || !J.job_done(job) return;
    J.job_release(job); job=null;
    if !bake.success {
        status="Bake cancelled or invalid settings";
        if auto_mode {expect(*tests,false,"background bake completes");F.app_exit();}
        return;
    }
    gut_maps_destroy(*maps); maps=bake.maps; bake.maps=.{};
    data := []Gut_Pixel.[maps.albedo,maps.normal,maps.material];
    for i: 0..2 {
        if textures[i] != null && (textures[i].Width != maps.width || textures[i].Height != maps.height) {
            F.texture_dispose(textures[i]);free(textures[i]);textures[i]=null;
        }
        if textures[i] == null textures[i]=F.texture_create(F.App.device,maps.width,maps.height,name="gut-map");
        F.texture_set_data(textures[i],as_colors(data[i]));
    }
    uploaded+=1; status="Bake complete";
}
startup :: () {
    gfx_shader_dir=copy_string(gfx_executable_asset_path("gutwall/shaders"));
    gfx_init(); assert(IB.imgui_foster_setup());
    assert(J.jobs_init(*scheduler,1,1)); TH.init(*bake.cancel.mutex);
    assert(S.directory_storage_init(*resources,gfx_executable_asset_path("gutwall")));
    root := ifx user_override.count > 0 then user_override else F.app_user_path();
    assert(S.directory_storage_init(*users,root,true));
    game.user=S.directory_storage(*users); S.game_resources_set(*game,S.directory_storage(*resources));
    shader=gfx_load_fragment_shader("gutwall",3,*game.resources,"shaders"); assert(shader != null);
    regenerate();
}
update :: () {
    ED.imgui_process_input(); finish_bake();
    if IsKeyPressed(.ESCAPE) F.app_exit();
    if cancel_mode { gut_cancel(*bake.cancel); F.app_exit(); }
}
configure :: () {
    uniforms := Uniforms.{light=.{light.x,light.y,light_height,intensity},color=.{.025,.95,.85,1},
        surface=.{normal_strength,wetness,ambient,cast(float32) mode},options=.{radius,ifx fill then 1.0 else 0.0,ifx marker then 1.0 else 0.0,4.5}};
    gfx_shader_set_params(shader,*uniforms);
    gfx_shader_set_sampler(shader,1,textures[1]); gfx_shader_set_sampler(shader,2,textures[2]);
}
different :: (a: []Color,b: []Color) -> bool { return memcmp(a.data,b.data,a.count*4) != 0; }
verify_gpu :: () {
    verify_frame+=1;
    if capture_target == null {
        capture_target=F.target_create(F.App.device,maps.width,maps.height,"gut-capture");
        previous=NewArray(maps.albedo.count,Color); baseline=NewArray(maps.albedo.count,Color);
        expect(*tests, maps.width == 1400 && maps.height == 800 && uploaded == 1,"full-size asynchronous bake uploaded");
        expect(*tests, export_maps(),"export three maps through user storage");
    }
    mode=0;light=.{-5,0};normal_strength=1;wetness=.65;
    names := string.["lit-left","lit-right","lit-flat","lit-dry","albedo","height","normal"];
    if verify_frame == 2 light=.{7,2};
    if verify_frame == 3 normal_strength=0;
    if verify_frame == 4 wetness=0;
    if verify_frame >= 5 && verify_frame <= 7 mode=cast(s32) (verify_frame-4);
    if verify_frame <= 7 {
        configure(); gfx_blit_pass(F.drawable_target_target(capture_target),shader,textures[0],maps.width,maps.height,BLACK);
        pixels:=NewArray(maps.albedo.count,Color); defer free(pixels.data);
        F.texture_get_data(F.target_texture(capture_target),pixels);
        expect(*tests, export_png(tprint("GutWallExport/%.png",names[verify_frame-1]),pixels),"capture %",names[verify_frame-1]);
        if verify_frame == 1 {
            memcpy(baseline.data,pixels.data,pixels.count*4);
            nonblack: s64; for p: pixels if p.r > 20 || p.g > 20 || p.b > 20 nonblack+=1;
            expect(*tests,nonblack > pixels.count/10,"lit output contains visible tissue");
        } else if verify_frame <= 4 expect(*tests,different(pixels,baseline),"light/normal/wetness changes rendered pixels %",names[verify_frame-1]);
        else expect(*tests,different(pixels,previous),"debug map view changes rendered pixels %",names[verify_frame-1]);
        memcpy(previous.data,pixels.data,pixels.count*4);
    }
    if verify_frame == 8 {first_textures=textures;settings.seed+=1;regenerate();}
    if uploaded == 2 {
        expect(*tests,textures[0] == first_textures[0] && textures[1] == first_textures[1] && textures[2] == first_textures[2],"second bake reuses three textures");
        F.app_exit();
    }
}
render :: () {
    gfx_begin_frame(); elapsed+=GetFrameTime(); ED.imgui_begin_frame();
    if auto_mode && elapsed > 60 {expect(*tests,false,"automatic verification finishes within 60 seconds");F.app_exit();}
    if auto_mode && maps.albedo.count > 0 verify_gpu();
    if !auto_mode {
        IM.SetNextWindowSize(.{350,690},.FirstUseEver);
        if IM.Begin("Procedural Gut Wall") {
            IM.Text("Gray-Scott folds | %x%",settings.width,settings.height);
            IM.Text("%",ifx job != null then "Growing folds on worker..." else status);
            _:=IM.SliderInt("View: lit/albedo/height/normal",*mode,0,3);
            _:=IM.Checkbox("Follow mouse",*follow); _:=IM.Checkbox("Orbit light",*orbit);
            _:=IM.Checkbox("Warm fill",*fill); _:=IM.Checkbox("Light marker",*marker);
            _:=IM.SliderFloat("Light X",*light.x,-12,12); _:=IM.SliderFloat("Light Y",*light.y,-8,8);
            _:=IM.SliderFloat("Light height",*light_height,1,9); _:=IM.SliderFloat("Intensity",*intensity,0,12);
            _:=IM.SliderFloat("Radius",*radius,3,24); _:=IM.SliderFloat("Normal strength",*normal_strength,0,2);
            _:=IM.SliderFloat("Wet highlights",*wetness,0,2); _:=IM.SliderFloat("Ambient",*ambient,0,1);
            _:=ED.property_drawer(*editor,"Generation settings",*settings);
            if job == null {
                if IM.Button("Regenerate") regenerate();
                IM.SameLine(); if IM.Button("New seed") {settings.seed+=1;regenerate();}
            } else if IM.Button("Cancel bake") gut_cancel(*bake.cancel);
            if maps.albedo.count > 0 && IM.Button("Export PNG maps") {
                status=ifx export_maps() then "Exported to user/GutWallExport" else "Export failed";
            }
            IM.Text("User directory: %",users.root);
        }
        IM.End();
        if orbit light=.{-3+6*GM.cos(elapsed*.5),4*GM.sin(elapsed*.5)};
        else if follow && !IM.GetIO().WantCaptureMouse {
            mouse:=GetMousePosition(); light=.{(mouse.x/cast(float32) F.window_width_in_pixels(F.App.window)-.5)*28,(mouse.y/cast(float32) F.window_height_in_pixels(F.App.window)-.5)*16};
        }
    }
    if maps.albedo.count > 0 {
        configure();gfx_blit_pass(gfx_backbuffer(),shader,textures[0],F.window_width_in_pixels(F.App.window),F.window_height_in_pixels(F.App.window),BLACK);
    } else gfx_pass_begin(gfx_backbuffer(),BLACK);
    // Separate overlay pass preserves the already rendered scene.
    F.batcher_clear(gfx_batcher); ED.imgui_end_frame(); F.batcher_render(gfx_batcher,gfx_backbuffer());
}
shutdown :: () {
    gut_cancel(*bake.cancel); J.jobs_destroy(*scheduler);
    if cancel_mode expect(*tests,!bake.success,"exit cancels pending worker before GPU upload");
    if job != null {J.job_release(job);job=null;}
    TH.destroy(*bake.cancel.mutex); gut_maps_destroy(*bake.maps); gut_maps_destroy(*maps);
    for textures if it != null {F.texture_dispose(it);free(it);}
    if capture_target != null {F.target_dispose(capture_target);free(capture_target);}
    free(previous.data);free(baseline.data);gfx_shader_destroy(shader);
    S.directory_storage_destroy(*resources);S.directory_storage_destroy(*users);
    ED.property_editor_destroy(*editor);IB.imgui_foster_shutdown();gfx_shutdown();free(gfx_shader_dir);
}
main :: () {
    tests=test_begin();
    for arg: get_command_line_arguments() {
        if arg == "auto" auto_mode=true;
        if arg == "cancel" cancel_mode=true;
        if arg == "vulkan" driver=.VULKAN;
    }
    if auto_mode || cancel_mode user_override=copy_string(gfx_executable_asset_path("../.test_tmp/gutwall"));
    F.App.startup=startup;F.App.update=update;F.App.render=render;F.App.shutdown=shutdown;
    F.app_run(.{application_name="gutwall_demo",window_title="JaiLib GutWall",width=1400,height=800,preferred_graphics_driver=driver});
    F.app_destroy();free(user_override);if !test_summary("GutWall GPU",*tests) exit(1);
}


