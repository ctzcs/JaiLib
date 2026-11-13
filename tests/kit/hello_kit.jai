// hello_kit —— 用新的 core/ + kit/ 树画一帧的最小例子（不再依赖 Libs/Engine）。
//
// 组成：
//   jfoster   —— 窗口、SDL_GPU 设备、事件循环（App.startup/update/render/shutdown）
//   kit/world —— Camera2D（世界 → 屏幕的 3x2 矩阵）
//   kit/rendering/material —— 材质库 + 内置 Sprite 材质
//   kit/rendering/2d       —— Render2D（合批、相机矩阵、矩形/文字）
//
// 构建（仓库根）：
//   jaic -import_dir "D:/MySpace/Github" -import_dir . -output_path bin -exe hello_kit Tests/kit/hello_kit.jai
// 运行：bin\hello_kit.exe  （加 auto 参数画 120 帧后自动退出）
#import "Basic" ;
F :: #import "foster" ;
MAT :: #import "kit/rendering/material" ;
R2D :: #import "kit/rendering/2d" ;
W :: #import "kit/world" ;

 Hello :: struct {
library : MAT . Material_Library ;
renderer : R2D . Render2D ;
camera : W . Camera2D ;

 ready : bool ;
error : string ;
frames : s64 ;
auto_mode : bool ;
}

 hello : Hello ;

 startup :: ( ) {
hello . library . device = F . App . device ;
// jfoster 的默认资源（内置 Batcher/MSDF 材质）是惰性创建的；kit 的内置 Sprite 材质
// 直接借用它，所以要先触发一次。
_ := F . defaults_batch_material ( F . App . device ) ;
W . camera2d_init ( * hello . camera , 960 , 540 ) ;

 reason := R2D . init ( * hello . renderer , * hello . library ) ;
if reason != "" {
hello . error = reason ;
F . log_error ( tprint ( "Render2D 初始化失败: %" , reason ) ) ;
return ;
}
hello . ready = true ;
if hello . auto_mode {
passed := gpu_probe ( ) ;
if passed {
print ( "[hello_kit] gpu probe: PASS
" ) ;
} else {
print ( "[hello_kit] gpu probe: FAIL
" ) ;
hello . ready = false ;
hello . error = "gpu probe failed" ;
}
}
}

 // auto 模式下的一次性 GPU 像素自检：画进离屏 Target 再读回，证明整条渲染链真的出了像素。
gpu_probe :: ( ) -> bool {
probe := F . target_create ( F . App . device , 64 , 64 ) ;
if probe == null return false ;

 target := F . drawable_target_target ( probe ) ;
F . graphics_device_clear_color ( F . App . device , target , .{ 0 , 0 , 0 , 255 } ) ;

 R2D . reset ( * hello . renderer ) ;
R2D . rect ( * hello . renderer , F . Rect .{ 8 , 8 , 48 , 48 } , F . Color .{ 255 , 255 , 255 , 255 } ) ;

 view : R2D . View ;
view . target = target ;
view . time = 0 ;
view . delta_time = 0 ;
view . frame = 0 ;
pointer : [ 2 ] float32 = .[ 0 , 0 ] ;
view . pointer = pointer ;
if R2D . submit ( * hello . renderer , view ) != . None return false ;

 pixels : [ 64 * 64 ] F . Color ;
F . texture_get_data ( F . target_texture ( probe ) , pixels ) ;
center := pixels [ 32 * 64 + 32 ] ;
corner := pixels [ 1 * 64 + 1 ] ;
F . target_dispose ( probe ) ;
print ( "[hello_kit] probe center=(%,%,%,%) corner=(%,%,%,%)
" ,
center . r , center . g , center . b , center . a , corner . r , corner . g , corner . b , corner . a ) ;
return center . r > 200 && center . g > 200 && center . b > 200 && corner . r < 40 ;
}

 update :: ( ) {
if F . keyboard_pressed ( F . input_keyboard ( F . App . input ) , . ESCAPE ) F . app_exit ( ) ;
}

 render :: ( ) {
target := F . drawable_target_window ( F . App . window ) ;
F . graphics_device_clear_color ( F . App . device , target , .{ 24 , 28 , 36 , 255 } ) ;

 if hello . ready {
width := F . drawable_target_width_in_pixels ( target ) ;
height := F . drawable_target_height_in_pixels ( target ) ;
W . camera2d_set_viewport ( * hello . camera , width , height ) ;

 R2D . reset ( * hello . renderer ) ;
R2D . push_matrix ( * hello . renderer , W . camera2d_matrix ( * hello . camera ) ) ;
R2D . rect ( * hello . renderer , F . Rect .{ - 120 , - 70 , 240 , 140 } , F . Color .{ 102 , 191 , 255 , 255 } ) ;
R2D . rect ( * hello . renderer , F . Rect .{ - 60 , - 20 , 120 , 40 } , F . Color .{ 255 , 255 , 255 , 255 } ) ;
R2D . pop_matrix ( * hello . renderer ) ;

 view : R2D . View ;
view . target = target ;
view . time = cast ( float32 ) F . App . time . elapsed ;
view . delta_time = cast ( float32 ) ( F . App . time . elapsed - F . App . time . previous ) ;
view . frame = F . App . time . frame ;
pointer : [ 2 ] float32 = .[ 0 , 0 ] ;
view . pointer = pointer ;
reason := R2D . submit ( * hello . renderer , view ) ;
if reason != . None && hello . frames == 0 {
F . log_error ( tprint ( "Render2D 提交失败: %" , reason ) ) ;
}
}

 hello . frames += 1 ;
if hello . auto_mode && hello . frames >= 120 F . app_exit ( ) ;
}

 shutdown :: ( ) {
if hello . ready R2D . dispose ( * hello . renderer ) ;
MAT . material_library_dispose ( * hello . library ) ;
if hello . ready {
print ( "[hello_kit] % frames rendered
" , hello . frames ) ;
} else {
print ( "[hello_kit] FAILED: %
" , hello . error ) ;
}
}

 main :: ( ) {
args := get_command_line_arguments ( ) ;
for arg : args {
if arg == "auto" hello . auto_mode = true ;
}

 F . App . startup = startup ;
F . App . update = update ;
F . App . render = render ;
F . App . shutdown = shutdown ;
F . app_run ( F . App_Config .{
application_name = "HelloKit" ,
window_title = "Hello Kit — core/ + kit/" ,
width = 960 ,
height = 540 ,
} ) ;
F . app_destroy ( ) ;
} 

// Loop scopes adapted.
