#import "Basic";
F :: #import "foster";

batch: *F.Batcher;
source: *F.Texture;
target16, target32: *F.Target;
values := float32.[2, 0.25, 0.5, 1, 4, 0.5, 0.25, 1];

main :: () {
    F.App.startup = start;
    F.App.render = render;
    F.App.shutdown = stop;
    F.app_run(.{ application_name = "HDR target regression", width = 32, height = 32, update_mode = F.update_mode_unlocked() });
    F.app_destroy();
}

start :: () {
    batch = F.batcher_create(F.App.device);
    source = F.texture_create(F.App.device, 2, 1, .R32G32B32A32_FLOAT);
    F.texture_set_data(source, values);
    target16 = F.target_create_formats(F.App.device, 2, 1, .[.R16G16B16A16_FLOAT]);
    target32 = F.target_create_formats(F.App.device, 2, 1, .[.R32G32B32A32_FLOAT]);
}

render :: () {
    for target: *F.Target.[target16, target32] {
        F.batcher_clear(batch);
        F.batcher_image_full(batch, source, F.Color_White);
        F.batcher_render(batch, F.drawable_target_target(target));
    }
    half: [8] u16;
    F.texture_get_data(F.target_texture(target16), half);
    assert(half[0] == 0x4000 && half[4] == 0x4400, "Float16 clamped HDR to 1");
    assert(half[1] == 0x3400 && half[2] == 0x3800 && half[3] == 0x3c00);
    full: [8] float32;
    F.texture_get_data(F.target_texture(target32), full);
    for value, i: values assert(full[i] == value, "Float32 target changed channel %", i);
    print("hdr_targets: PASS (Float16/Float32 preserve values above 1)\n");
    F.app_exit();
}

stop :: () {
    F.batcher_destroy(batch);
    F.texture_dispose(source);
    free(source);
    F.target_dispose(target16);
    free(target16);
    F.target_dispose(target32);
    free(target32);
}
