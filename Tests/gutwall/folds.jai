// Port of DragonLib 0466793 GutFoldTexture.cs: Gray-Scott folds, smoothed
// heights, tangent normals and material channels. No ECS or graphics dependency.
#import "Basic";
M :: #import "Math";
TH :: #import "Thread"(LOAD_THREAD_GROUP=false);
Gut_Pixel :: struct { r,g,b,a: u8; }
Gut_Settings :: struct {
    seed: s32 = 42;
    spacing: float32 = .28;
    bend: float32 = 1.1;
    groove_width: float32 = .48;
    detail: float32 = .65;
    wall_arch: float32 = 2.1;
    puffiness: float32 = .46;
    width: s32 = 1400;
    height: s32 = 800;
}
Gut_Maps :: struct { albedo, normal, material: [] Gut_Pixel; width,height: s32; }
Gut_Cancel :: struct { mutex: TH.Mutex; requested: bool; }
gut_cancelled :: (cancel: *Gut_Cancel) -> bool {
    if cancel == null return false;
    TH.lock(*cancel.mutex); defer TH.unlock(*cancel.mutex); return cancel.requested;
}
gut_cancel :: (cancel: *Gut_Cancel) {
    TH.lock(*cancel.mutex); cancel.requested = true; TH.unlock(*cancel.mutex);
}
gut_maps_destroy :: (maps: *Gut_Maps) {
    free(maps.albedo.data); free(maps.normal.data); free(maps.material.data); <<maps = .{};
}
gut_smooth :: inline (a: float32,b: float32,v: float32) -> float32 { t := clamp((v-a)/(b-a), cast(float32) 0,cast(float32) 1); return t*t*(3-2*t); }
gut_mix :: inline (a: float32,b: float32,t: float32) -> float32 { return a+(b-a)*t; }
gut_hash :: (x: s32,y: s32,seed: s32) -> float32 {
    // Bit casts are deliberate: coordinates can be negative and arithmetic wraps.
    h := cast,trunc(u32) x * 0x8da6b343 ^ cast,trunc(u32) y * 0xd8163841 ^ cast,trunc(u32) seed * 0xcb1ab31f;
    h = (h ^ (h >> 16)) * 0x7feb352d; h = (h ^ (h >> 15)) * 0x846ca68b;
    return cast(float32) ((h ^ (h >> 16)) & 0xffffff) / 16777215.0;
}
gut_noise :: (p: M.Vector2, seed: s32) -> float32 {
    x := cast(s32) M.floor(p.x); y := cast(s32) M.floor(p.y);
    fx := p.x - cast(float32) x; fy := p.y - cast(float32) y;
    fx = fx*fx*(3-2*fx); fy = fy*fy*(3-2*fy);
    return gut_mix(gut_mix(gut_hash(x,y,seed),gut_hash(x+1,y,seed),fx),
        gut_mix(gut_hash(x,y+1,seed),gut_hash(x+1,y+1,seed),fx),fy);
}
gut_fbm :: (p: M.Vector2, seed: s32) -> float32 {
    return (gut_noise(p,seed)+.5*gut_noise(.{p.x*2.03+7.1,p.y*2.03+7.1},seed)
        +.25*gut_noise(.{p.x*4.07-3.7,p.y*4.07-3.7},seed))/1.75;
}
gut_encode :: (r: float32,g: float32,b: float32,a: float32) -> Gut_Pixel {
    return .{cast(u8) (clamp(r,cast(float32) 0,cast(float32) 1)*255),cast(u8) (clamp(g,cast(float32) 0,cast(float32) 1)*255),
        cast(u8) (clamp(b,cast(float32) 0,cast(float32) 1)*255),cast(u8) (clamp(a,cast(float32) 0,cast(float32) 1)*255)};
}
gut_boundary :: (y: float32) -> float32 { return -6+1.5*gut_sin(y*.26)+.16*y; }
gut_sample :: (v: []float32, w: s64,h: s64, px: float32,py: float32) -> float32 {
    x := cast(s64) M.floor(px); y := cast(s64) M.floor(py);
    tx := px-cast(float32) x; ty := py-cast(float32) y;
    x0 := clamp(x,0,w-1); x1 := clamp(x+1,0,w-1); y0 := clamp(y,0,h-1); y1 := clamp(y+1,0,h-1);
    return gut_mix(gut_mix(v[x0+y0*w],v[x1+y0*w],tx),gut_mix(v[x0+y1*w],v[x1+y1*w],tx),ty);
}
gut_generate :: (settings: Gut_Settings, cancel: *Gut_Cancel = null) -> (Gut_Maps, bool) {
    if settings.width < 8 || settings.height < 8 || settings.width > 4096 || settings.height > 4096
        || settings.spacing < .25 || settings.spacing > .85 return .{}, false;
    fw := cast(s64) clamp(cast(s32) (28/(settings.spacing*.20)),160,560);
    fh := fw*16/28; count := fw*fh;
    u := NewArray(count,float32); v := NewArray(count,float32);
    nu := NewArray(count,float32); nv := NewArray(count,float32);
    weights := NewArray(count,M.Vector4); feed := NewArray(count,float32); kill := NewArray(count,float32);
    defer { free(u.data);free(v.data);free(nu.data);free(nv.data);free(weights.data);free(feed.data);free(kill.data); }
    seed := settings.seed;
    for y: 0..fh-1 for x: 0..fw-1 {
        i := x+y*fw;
        px := (cast(float32) x+.5)*28/cast(float32) fw-14;
        py := (cast(float32) y+.5)*16/cast(float32) fh-8;
        sx := cast(s32) (x/20); sy := cast(s32) (y/20);
        ax := (cast(float32) sx+.5+.65*(gut_hash(sx,sy,seed)-.5))*20-cast(float32) x;
        ay := (cast(float32) sy+.5+.65*(gut_hash(sx,sy,seed+101)-.5))*20-cast(float32) y;
        active := 1-gut_smooth(5,6,gut_sqrt(ax*ax+ay*ay));
        u[i] = 1-.5*active; v[i] = .25*active;
        angle := settings.bend*(.62*gut_sin(py*.85+gut_sin(px*.65))+.42*gut_sin(px*1.05-py*.45));
        s := gut_sin(angle); c := gut_cos(angle);
        weights[i] = .{.60+.55*s*s,.60+.55*c*c,.10+.18*s*c,.10-.18*s*c};
        region := gut_fbm(.{px*.65,py*.65},seed+271); feed[i]=.025+.030*region; kill[i]=.055+.010*region;
    }
    for step: 0..1599 {
        if gut_cancelled(cancel) return .{}, false;
        for y: 0..fh-1 {
            row := y*fw; above := ((y+fh-1)%fh)*fw; below := ((y+1)%fh)*fw;
            for x: 0..fw-1 {
                i := row+x; left := (x+fw-1)%fw; right := (x+1)%fw; w := weights[i];
                center := 2*(w.x+w.y+w.z+w.w);
                lu := w.x*(u[row+left]+u[row+right])+w.y*(u[above+x]+u[below+x])
                    +w.z*(u[above+left]+u[below+right])+w.w*(u[above+right]+u[below+left])-center*u[i];
                lv := w.x*(v[row+left]+v[row+right])+w.y*(v[above+x]+v[below+x])
                    +w.z*(v[above+left]+v[below+right])+w.w*(v[above+right]+v[below+left])-center*v[i];
                reaction := u[i]*v[i]*v[i];
                nu[i] = clamp(u[i]+.16*lu-reaction+feed[i]*(1-u[i]),cast(float32) 0,cast(float32) 1);
                nv[i] = clamp(v[i]+.07*lv+reaction-(feed[i]+kill[i])*v[i],cast(float32) 0,cast(float32) 1);
            }
        }
        u, nu = nu, u; v, nv = nv, v;
    }
    width := cast(s64) settings.width; height := cast(s64) settings.height; size := width*height;
    heights := NewArray(size,float32); profiles := NewArray(size,float32);
    variation := NewArray(size,float32); striation := NewArray(size,float32); temporary := NewArray(size,float32);
    defer {free(heights.data);free(profiles.data);free(variation.data);free(striation.data);free(temporary.data);}
    dx_pixel := 28/cast(float32) width; dy_pixel := 16/cast(float32) height;
    for y: 0..height-1 {
        if gut_cancelled(cancel) return .{},false;
        for x: 0..width-1 {
            i := x+y*width; px := (cast(float32) x+.5)*dx_pixel-14; py := (cast(float32) y+.5)*dy_pixel-8;
            p := M.Vector2.{px,py}; d := px-gut_boundary(py); if d <= 0 continue;
            ox := (gut_fbm(.{px*.70,py*.70},seed)-.5)*settings.spacing*.9;
            oy := (gut_fbm(.{px*.70+17.3,py*.70-4.2},seed)-.5)*settings.spacing*.9;
            concentration := gut_sample(v,fw,fh,(px+ox+14)/28*cast(float32) fw-.5,(py+oy+8)/16*cast(float32) fh-.5);
            profile := gut_pow(gut_sin(clamp(concentration/.52,cast(float32) 0,cast(float32) 1)*GUT_PI*.5),.28+.38*settings.groove_width);
            profiles[i]=profile; variation[i]=gut_fbm(.{px*.43,py*.43},seed+573);
            fine := gut_sin(profile*12.57+.45*gut_noise(.{px*1.4,py*1.4},seed)); striation[i]=fine;
            tissue := .12+settings.puffiness*(.85+.30*variation[i])*profile+settings.detail*.004*fine*gut_sin(profile*GUT_PI);
            arch := settings.wall_arch*gut_exp(-gut_pow((d-5)/6,2))*gut_smooth(0,1.2,d)*(.88+.12*gut_sin(py*.48+.6*gut_sin(px*.22)));
            cushion := settings.wall_arch*.08*gut_fbm(.{px*.55,py*.55},seed+97)*gut_smooth(0,1,d);
            rim := .38*gut_exp(-gut_pow((d-.24)/.24,2));
            heights[i]=gut_smooth(0,.10,d)*(arch+cushion+tissue+rim);
        }
    }
    kernel := float32.[.0625,.25,.375,.25,.0625];
    for y: 0..height-1 for x: 0..width-1 for k: -2..2 temporary[x+y*width] += heights[clamp(x+k,0,width-1)+y*width]*kernel[k+2];
    for y: 0..height-1 for x: 0..width-1 {
        heights[x+y*width]=0;
        for k: -2..2 heights[x+y*width] += temporary[x+clamp(y+k,0,height-1)*width]*kernel[k+2];
    }
    maps := Gut_Maps.{width=settings.width,height=settings.height,
        albedo=NewArray(size,Gut_Pixel),normal=NewArray(size,Gut_Pixel),material=NewArray(size,Gut_Pixel)};
    for y: 0..height-1 {
        if gut_cancelled(cancel) {gut_maps_destroy(*maps);return .{},false;}
        for x: 0..width-1 {
            i := x+y*width; px := (cast(float32) x+.5)*dx_pixel-14; py := (cast(float32) y+.5)*dy_pixel-8;
            d := px-gut_boundary(py); mask := gut_smooth(0,.10,d); profile := profiles[i];
            grain := gut_noise(.{px*9,py*9},seed); mottle := gut_fbm(.{px*.7,py*.7},seed);
            t := gut_smooth(.08,.92,profile);
            r := gut_mix(.24,.48,t); g := gut_mix(.15,.35,t); b := gut_mix(.080,.19,t);
            band := gut_exp(-gut_pow((profile-.28)/.11,2))*.12;
            r=gut_mix(r,.38,band);g=gut_mix(g,.29,band);b=gut_mix(b,.145,band);
            mult := (.76+.14*variation[i]+.18*mottle+.08*grain)*(1-settings.detail*.09*gut_smooth(.25,1,-striation[i]));
            rim := gut_exp(-gut_pow((d-.20)/.30,2))*.8;
            maps.albedo[i]=gut_encode(gut_mix(r*mult,.62,rim),gut_mix(g*mult,.36,rim),gut_mix(b*mult,.065,rim),mask);
            dx := (heights[min(x+1,width-1)+y*width]-heights[max(x-1,0)+y*width])/(2*dx_pixel);
            dy := (heights[x+min(y+1,height-1)*width]-heights[x+max(y-1,0)*width])/(2*dy_pixel);
            inv := 1/gut_sqrt(dx*dx+dy*dy+1);
            maps.normal[i]=gut_encode(-dx*inv*.5+.5,-dy*inv*.5+.5,inv*.5+.5,1);
            maps.material[i]=gut_encode(heights[i]/4.5,.46+.15*grain,.72+.28*gut_smooth(.02,.70,profile),mask);
        }
    }
    return maps,true;
}


gut_pow :: (a: float32,b: float32) -> float32 { return cast(float32) M.pow(a,b); }
gut_sin :: (a: float32) -> float32 { return cast(float32) M.sin(a); }
gut_cos :: (a: float32) -> float32 { return cast(float32) M.cos(a); }
gut_exp :: (a: float32) -> float32 { return cast(float32) M.exp(a); }
gut_sqrt :: (a: float32) -> float32 { return cast(float32) M.sqrt(a); }


GUT_PI: float32 = 3.1415927;



