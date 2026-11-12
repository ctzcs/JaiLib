#import "Basic";
#import "test_support";
#load "gutwall/folds.jai";
main :: () {
    t := test_begin();
    settings := Gut_Settings.{width=140,height=80,spacing=.85};
    maps, ok := gut_generate(settings); defer gut_maps_destroy(*maps);
    expect(*t, ok && maps.albedo.count == 11200, "generate three maps");
    again, repeat_ok := gut_generate(settings); defer gut_maps_destroy(*again);
    expect(*t, repeat_ok && memcmp(maps.albedo.data,again.albedo.data,maps.albedo.count*4) == 0, "same seed/settings reproduce map");
    settings.seed += 1;
    other, other_ok := gut_generate(settings); defer gut_maps_destroy(*other);
    expect(*t, other_ok && memcmp(maps.albedo.data,other.albedo.data,maps.albedo.count*4) != 0, "seed changes folds");
    valid := true; masked: s64; tissue: s64; min_height: u8=255; max_height: u8;
    for p,i: maps.normal {
        nx := cast(float32) p.r/255*2-1; ny := cast(float32) p.g/255*2-1; nz := cast(float32) p.b/255*2-1;
        if M.abs(nx*nx+ny*ny+nz*nz-1) > .03 || p.a != 255 valid=false;
        if maps.albedo[i].a == 0 masked += 1; else tissue += 1;
        min_height=min(min_height,maps.material[i].r); max_height=max(max_height,maps.material[i].r);
    }
    expect(*t, valid, "normal map encodes unit normals");
    expect(*t, masked > 0 && tissue > 0 && max_height > min_height+50, "boundary mask and raised tissue present");
    cancel: Gut_Cancel; TH.init(*cancel.mutex); defer TH.destroy(*cancel.mutex);
    gut_cancel(*cancel);
    cancelled, cancelled_ok := gut_generate(settings,*cancel);
    expect(*t, !cancelled_ok && cancelled.albedo.count == 0, "cancelled bake releases partial buffers");
    settings.spacing=0;
    invalid, invalid_ok := gut_generate(settings);
    expect(*t, !invalid_ok && invalid.normal.count == 0, "invalid resolution/scale rejected");
    if !test_summary("Gut folds", *t) exit(1);
}

