// 一比一移植自 olib tests/kit/world/world_test.odin。
// 断言顺序、数值容差与拆分方式保持原样；Odin 的 testing.expect 换成 test_support.expect，
// 向量从 [N]f32 变成 Math.Vector2/Vector3（字段 .x/.y/.z）。
#import "Basic" ;
#import "Math" ;
#import "test_support" ;
W :: #import "kit/world" ;

 //@region Camera2D

 camera2d_identity_centering :: ( state : * Test_State ) {
cam : W . Camera2D ;
W . camera2d_init ( * cam , 1280 , 720 ) ;

 // 默认 zoom=1 ppu=32：原点在屏幕中心，一个世界单位 = 32 像素
s := W . camera2d_world_to_screen ( * cam , W . Vec2 .{ 0 , 0 } ) ;
expect ( state , s . x == 640 && s . y == 360 , "原点应在屏幕中心: %, %" , s . x , s . y ) ;
s1 := W . camera2d_world_to_screen ( * cam , W . Vec2 .{ 1 , 0 } ) ;
expect ( state , s1 . x == 640 + 32 && s1 . y == 360 , "(1,0) 应右移 32px: %, %" , s1 . x , s1 . y ) ;
}

 camera2d_roundtrip :: ( state : * Test_State ) {
cam : W . Camera2D ;
W . camera2d_init ( * cam , 1920 , 1080 ) ;
W . camera2d_set_position ( * cam , W . Vec2 .{ 12.5 , - 3.25 } ) ;
W . camera2d_set_rotation ( * cam , 0.7 ) ;
W . camera2d_set_zoom ( * cam , 2.5 ) ;

 world := W . Vec2 .{ 4.2 , - 9.8 } ;
screen := W . camera2d_world_to_screen ( * cam , world ) ;
back , ok := W . camera2d_screen_to_world ( * cam , screen ) ;
expect ( state , ok , "screen_to_world 应成功" ) ;
expect ( state , abs ( back . x - world . x ) < 1.0e-3 && abs ( back . y - world . y ) < 1.0e-3 ,
"roundtrip 应还原: got %, % want %, %" , back . x , back . y , world . x , world . y ) ;

 // 旋转后的轴对齐检查：相机自身位置的屏幕投影仍是中心
center := W . camera2d_world_to_screen ( * cam , cam . position ) ;
expect ( state , abs ( center . x - 960 ) < 1.0e-3 && abs ( center . y - 540 ) < 1.0e-3 ,
"相机中心应投影到视口中心: %, %" , center . x , center . y ) ;
}

 camera2d_dirty_tracking :: ( state : * Test_State ) {
cam : W . Camera2D ;
W . camera2d_init ( * cam , 800 , 600 ) ;

 m1 := W . camera2d_matrix ( * cam ) ;
m2 := W . camera2d_matrix ( * cam ) ;
expect ( state , W . matrix3x2_equal ( m1 , m2 ) , "无变化不重建（dirty 已清）" ) ;

 W . camera2d_set_zoom ( * cam , 2 ) ;
m3 := W . camera2d_matrix ( * cam ) ;
expect ( state , ! W . matrix3x2_equal ( m3 , m1 ) , "改 zoom 后矩阵应变化" ) ;

 W . camera2d_set_viewport ( * cam , 800 , 600 ) ; // 同值不弄脏
expect ( state , ! cam . dirty , "同值 viewport 不应弄脏" ) ;
}

 camera2d_singular_rejected :: ( state : * Test_State ) {
cam : W . Camera2D ;
W . camera2d_init ( * cam , 800 , 600 ) ;
W . camera2d_set_zoom ( * cam , 0 ) ; // 缩放为零 → 矩阵不可逆

 _ , ok := W . camera2d_screen_to_world ( * cam , W . Vec2 .{ 400 , 300 } ) ;
expect ( state , ! ok , "zoom=0 时 screen_to_world 应失败" ) ;
}
//@endregion

 //@region SceneRouter

 Screen :: enum { Title ; Menu ; Game ; }

 scene_router_transitions :: ( state : * Test_State ) {
r : W . Scene_Router ( Screen ) ;
W . scene_router_init ( * r , Screen . Title ) ;
expect ( state , r . Current == Screen . Title && ! r . Transitioning && r . Progress == 1 , "初始状态" ) ;

 // duration=0：立即切换
W . scene_router_switch ( * r , Screen . Menu ) ;
expect ( state , r . Current == Screen . Menu && r . Previous == Screen . Title && ! r . Transitioning && r . Progress == 1 ,
"duration=0 立即切换" ) ;

 // duration=0.5：进入过渡，Current 立即更新、Progress 从 0 推进
W . scene_router_switch ( * r , Screen . Game , 0.5 ) ;
expect ( state , r . Current == Screen . Game && r . Previous == Screen . Menu && r . Transitioning && r . Progress == 0 ,
"进入过渡" ) ;

 W . scene_router_update ( * r , 0.25 ) ;
expect ( state , r . Transitioning && r . Progress == 0.5 , "过渡进度 0.5" ) ;

 W . scene_router_update ( * r , 0.25 ) ;
expect ( state , ! r . Transitioning && r . Progress == 1 , "过渡结束" ) ;

 // 过渡结束后 update 无副作用；切到当前屏幕无操作
W . scene_router_update ( * r , 10 ) ;
expect ( state , r . Current == Screen . Game && r . Progress == 1 , "结束后 update 无副作用" ) ;
W . scene_router_switch ( * r , Screen . Game , 1.0 ) ;
expect ( state , ! r . Transitioning && r . Previous == Screen . Menu , "切到当前屏幕无操作" ) ;
}
//@endregion

 //@region Matrix4

 expect_identity :: ( state : * Test_State , m : W . Matrix4 ) {
for col : 0 .. 3 {
col_vec := W . matrix4_c ( m , col ) ;
for row : 0 .. 3 {
want : float32 = 0 ;
if col == row want = 1 ;
got := col_vec [ row ] ;
expect ( state , abs ( got - want ) < 1.0e-4 , "(% ,%) 应为 %, 实际 %" , row , col , want , got ) ;
}
}
}

 matrix4_inverse_roundtrip :: ( state : * Test_State ) {
m := W . matrix4_multiply (
W . matrix4_look_at ( W . Vec3 .{ 1 , 2 , 5 } , W . Vec3 .{ 0 , 0 , 0 } , W . Vec3 .{ 0 , 1 , 0 } ) ,
W . matrix4_multiply (
W . matrix4_translation ( 3 , - 2 , 1 ) ,
W . matrix4_scaling ( 2 , 2 , 2 ) ,
) ,
) ;
inv , ok := W . matrix4_inverse ( m ) ;
expect ( state , ok , "可逆矩阵应求逆成功" ) ;

 roundtrip := W . matrix4_multiply ( m , inv ) ;
expect_identity ( state , roundtrip ) ;

 // 平移矩阵的逆恰好是反向平移
tm := W . matrix4_translation ( 1 , 2 , 3 ) ;
ti , ok2 := W . matrix4_inverse ( tm ) ;
expect ( state , ok2 , "平移矩阵可逆" ) ;
expect_identity ( state , W . matrix4_multiply ( tm , ti ) ) ;

 // 零缩放不可逆
_ , ok3 := W . matrix4_inverse ( W . matrix4_scaling ( 1 , 0 , 1 ) ) ;
expect ( state , ! ok3 , "零缩放不可逆" ) ;
}

 matrix4_look_at_maps_eye_to_origin :: ( state : * Test_State ) {
eye := W . Vec3 .{ 0 , 2 , 8 } ;
view := W . matrix4_look_at ( eye , W . Vec3 .{ 0 , 0 , 0 } , W . Vec3 .{ 0 , 1 , 0 } ) ;

 p , ok := W . matrix4_transform_point ( view , eye ) ;
expect ( state , ok , "look_at 变换成功" ) ;
expect ( state , abs ( p . x ) < 1.0e-5 && abs ( p . y ) < 1.0e-5 && abs ( p . z ) < 1.0e-5 ,
"eye 应映射到视空间原点: %, %, %" , p . x , p . y , p . z ) ;

 // 视线上的点（eye 向 target 走一半）应在 -Z 轴上
eye_target := W . Vec3 .{ 0 , - 1 , - 4 } ; // target-eye 的一半
ahead_pt := W . Vec3 .{ eye . x + eye_target . x , eye . y + eye_target . y , eye . z + eye_target . z } ;
ahead , ok2 := W . matrix4_transform_point ( view , ahead_pt ) ;
expect ( state , ok2 && abs ( ahead . x ) < 1.0e-5 && abs ( ahead . y ) < 1.0e-5 && ahead . z < 0 ,
"视线上的点应在 -Z 轴" ) ;
}

 matrix4_perspective_depth_range :: ( state : * Test_State ) {
proj := W . matrix4_perspective_fov ( PI / 3 , 16.0 / 9.0 , 0.05 , 250 ) ;

 // RH：眼前 z 为负。近平面 z=-near 处 NDC≈0，far 平面 NDC≈1（w=-z）
near_h := W . matrix4_transform_vec4 ( proj , W . vec4 ( 0 , 0 , - 0.05 , 1 ) ) ;
far_h := W . matrix4_transform_vec4 ( proj , W . vec4 ( 0 , 0 , - 250 , 1 ) ) ;
expect ( state , abs ( near_h [ 2 ] / near_h [ 3 ] ) < 1.0e-4 , "近平面 NDC≈0" ) ;
expect ( state , abs ( far_h [ 2 ] / far_h [ 3 ] - 1 ) < 1.0e-4 , "远平面 NDC≈1" ) ;
}

 matrix4_orthographic_boundaries_and_axis_flip :: ( state : * Test_State ) {
projection , ok := W . matrix4_orthographic_off_center ( - 3 , 7 , - 2 , 6 , 2 , 18 ) ;
expect ( state , ok , "orthographic_off_center 成功" ) ;
if ! ok return ;

 pairs : [ 3 ] [ 2 ] W . Vec3 = .[
.[ W . Vec3 .{ - 3 , - 2 , - 2 } , W . Vec3 .{ - 1 , - 1 , 0 } ] ,
.[ W . Vec3 .{ 7 , 6 , - 18 } , W . Vec3 .{ 1 , 1 , 1 } ] ,
.[ W . Vec3 .{ 2 , 2 , - 10 } , W . Vec3 .{ 0 , 0 , 0.5 } ] ,
] ;
for pair : pairs {
actual , transformed := W . matrix4_transform_point ( projection , pair [ 0 ] ) ;
expect ( state , transformed , "边界点变换成功" ) ;
expect ( state , abs ( actual . x - pair [ 1 ] . x ) < 1.0e-6 , "边界点 x" ) ;
expect ( state , abs ( actual . y - pair [ 1 ] . y ) < 1.0e-6 , "边界点 y" ) ;
expect ( state , abs ( actual . z - pair [ 1 ] . z ) < 1.0e-6 , "边界点 z" ) ;
}

 centered , centered_ok := W . matrix4_orthographic ( 10 , 8 , 2 , 18 ) ;
explicit , explicit_ok := W . matrix4_orthographic_off_center ( - 5 , 5 , - 4 , 4 , 2 , 18 ) ;
expect ( state , centered_ok && explicit_ok && W . matrix4_equal ( centered , explicit ) ,
"居中版与显式版应相同" ) ;

 screen , screen_ok := W . matrix4_orthographic_off_center ( 0 , 800 , 600 , 0 , 0 , 1 ) ;
top_left , _ := W . matrix4_transform_point ( screen , W . Vec3 .{ 0 , 0 , 0 } ) ;
bottom_right , _ := W . matrix4_transform_point ( screen , W . Vec3 .{ 800 , 600 , - 1 } ) ;
expect ( state , screen_ok && top_left . x == - 1 && top_left . y == 1 && top_left . z == 0 ,
"屏幕左上角映射到 (-1, 1, 0)" ) ;
expect ( state , bottom_right . x == 1 && bottom_right . y == - 1 && bottom_right . z == 1 ,
"屏幕右下角映射到 (1, -1, 1)" ) ;
}

 matrix4_orthographic_large_world_and_height_roundtrip :: ( state : * Test_State ) {
projection , ok := W . matrix4_orthographic ( 4096 , 4096 , 0 , 8192 ) ;
view := W . matrix4_look_at ( W . Vec3 .{ 2048 , 4096 , 2048 } , W . Vec3 .{ 2048 , 0 , 2048 } , W . Vec3 .{ 0 , 0 , - 1 } ) ;
combined := W . matrix4_multiply ( view , projection ) ;
inverse , invertible := W . matrix4_inverse ( combined ) ;
expect ( state , ok && invertible , "大世界矩阵可逆" ) ;
if ! ( ok && invertible ) return ;

 points : [ 3 ] W . Vec3 = .[ W . Vec3 .{ 0 , 0 , 0 } , W . Vec3 .{ 4096 , 0 , 4096 } , W . Vec3 .{ 1024 , 128 , 3072 } ] ;
for point : points {
ndc , projected := W . matrix4_transform_point ( combined , point ) ;
back , restored := W . matrix4_transform_point ( inverse , ndc ) ;
expect ( state , projected && restored , "投影与还原成功" ) ;
expect ( state , abs ( back . x - point . x ) < 0.002 && abs ( back . y - point . y ) < 0.002 && abs ( back . z - point . z ) < 0.002 ,
"往返还原 (% ,% ,%) -> (% ,% ,%)" , point . x , point . y , point . z , back . x , back . y , back . z ) ;
}

 // glTF 的列向量/列主序数组，显式转为等效行向量矩阵的行主序输入。
gltf : [ 16 ] float32 = .[ 1 , 0 , 0 , 0 , 0 , 1 , 0 , 0 , 0 , 0 , 1 , 0 , 11 , 13 , 17 , 1 ] ;
adapted := W . matrix4_from_row_major ( gltf ) ;
translated , translated_ok := W . matrix4_transform_point ( adapted , W . Vec3 .{ 1 , 2 , 3 } ) ;
expect ( state , translated_ok && translated . x == 12 && translated . y == 15 && translated . z == 20 ,
"row_major 适配后平移应为 (12, 15, 20)" ) ;
}

 matrix4_orthographic_rejects_invalid_ranges :: ( state : * Test_State ) {
bounds_list : [ 7 ] [ 6 ] float32 = .[
.[ 1 , 1 , - 1 , 1 , 0 , 1 ] ,
.[ - 1 , 1 , 2 , 2 , 0 , 1 ] ,
.[ - 1 , 1 , - 1 , 1 , - 1 , 1 ] ,
.[ - 1 , 1 , - 1 , 1 , 2 , 2 ] ,
.[ - 1 , 1 , - 1 , 1 , 2 , 1 ] ,
.[ FLOAT32_NAN , 1 , - 1 , 1 , 0 , 1 ] ,
.[ - 1 , FLOAT32_INFINITY , - 1 , 1 , 0 , 1 ] ,
] ;
for bounds : bounds_list {
m , accepted := W . matrix4_orthographic_off_center ( bounds [ 0 ] , bounds [ 1 ] , bounds [ 2 ] , bounds [ 3 ] , bounds [ 4 ] , bounds [ 5 ] ) ;
expect ( state , ! accepted && W . matrix4_equal ( m , W . MATRIX4_IDENTITY ) , "非法范围应被拒绝并返回单位阵" ) ;
}
_ , zero := W . matrix4_orthographic ( 0 , 10 , 0 , 1 ) ;
_ , negative := W . matrix4_orthographic ( 10 , - 1 , 0 , 1 ) ;
expect ( state , ! zero && ! negative , "零/负尺寸应被拒绝" ) ;
}
//@endregion

 //@region Camera3D / Frustum3D

 camera3d_frustum_culling :: ( state : * Test_State ) {
cam : W . Camera3D ;
W . camera3d_init ( * cam , 1280 , 720 ) ; // eye (0,2,8) -> 原点

 f := W . camera3d_frustum ( * cam ) ;

 expect ( state , W . frustum_contains_point ( f , W . Vec3 .{ 0 , 0 , 0 } ) , "目标点在视锥内" ) ;
expect ( state , W . frustum_contains_point ( f , W . Vec3 .{ 0 , 2 , 7.9 } ) , "眼前" ) ;
expect ( state , ! W . frustum_contains_point ( f , W . Vec3 .{ 0 , 0 , 100 } ) , "身后（z 正方向远离视线）" ) ;
expect ( state , ! W . frustum_contains_point ( f , W . Vec3 .{ 500 , 0 , 0 } ) , "远超右侧" ) ;

 expect ( state , W . frustum_intersects_aabb ( f , W . Vec3 .{ - 1 , - 1 , - 1 } , W . Vec3 .{ 1 , 1 , 1 } ) , "中心盒子相交" ) ;
expect ( state , ! W . frustum_intersects_aabb ( f , W . Vec3 .{ - 500 , - 10 , - 12 } , W . Vec3 .{ - 490 , 10 , - 8 } ) , "身后盒子不相交" ) ;
}

 camera3d_screen_point_to_ray_center :: ( state : * Test_State ) {
cam : W . Camera3D ;
W . camera3d_init ( * cam , 1280 , 720 ) ;

 ray , ok := W . camera3d_screen_point_to_ray ( * cam , W . Vec2 .{ 640 , 360 } ) ; // 屏幕中心
expect ( state , ok , "中心点应生成射线" ) ;

 // 中心射线应穿过 target（原点）附近
d , hit := W . ray3d_hit_sphere ( ray , W . Vec3 .{ 0 , 0 , 0 } , 0.5 ) ;
expect ( state , hit && d > 0 && d < 20 , "中心射线应命中原点附近: hit=% d=%" , hit , d ) ;

 // 视口无效
W . camera3d_set_viewport ( * cam , 0 , 0 ) ;
_ , ok2 := W . camera3d_screen_point_to_ray ( * cam , W . Vec2 .{ 5 , 5 } ) ;
expect ( state , ! ok2 , "无效视口应失败" ) ;
}
//@endregion

 //@region Ray3D

 ray3d_intersections :: ( state : * Test_State ) {
ray , made := W . ray3d_make ( W . Vec3 .{ 0 , 0 , - 5 } , W . Vec3 .{ 0 , 0 , 1 } ) ;
expect ( state , made , "射线创建成功" ) ;

 // AABB：正前方盒子
d , hit := W . ray3d_hit_aabb ( ray , W . Vec3 .{ - 1 , - 1 , 0 } , W . Vec3 .{ 1 , 1 , 2 } ) ;
expect ( state , hit && abs ( d - 5 ) < 1.0e-5 , "AABB 命中距离 5" ) ;
_ , miss := W . ray3d_hit_aabb ( ray , W . Vec3 .{ 10 , 10 , 10 } , W . Vec3 .{ 11 , 11 , 11 } ) ;
expect ( state , ! miss , "AABB 未命中" ) ;

 // 三角形：XY 面上、朝向 -Z 的三角形，单面/双面
tri_a := W . Vec3 .{ - 1 , - 1 , 0 } ; tri_b := W . Vec3 .{ 1 , - 1 , 0 } ; tri_c := W . Vec3 .{ 0 , 1 , 0 } ;
td , thit := W . ray3d_hit_triangle ( ray , tri_a , tri_b , tri_c , true ) ;
expect ( state , thit && abs ( td - 5 ) < 1.0e-5 , "三角形命中距离 5" ) ;
back , _ := W . ray3d_make ( W . Vec3 .{ 0 , 0 , 5 } , W . Vec3 .{ 0 , 0 , 1 } ) ;
_ , no_back := W . ray3d_hit_triangle ( back , tri_a , tri_b , tri_c , false ) ;
expect ( state , ! no_back , "单面三角形不应从背后命中" ) ;

 // 球：正前方 r=1（origin z=-5，球心 z=3，最近点距离 7）
sd , shit := W . ray3d_hit_sphere ( ray , W . Vec3 .{ 0 , 0 , 3 } , 1 ) ;
expect ( state , shit && abs ( sd - 7 ) < 1.0e-5 , "球命中距离 7" ) ;
inside , ihit := W . ray3d_hit_sphere ( ray , W . Vec3 .{ 0 , 0 , - 5 } , 2 ) ; // origin 在球内
expect ( state , ihit && inside == 0 , "球内起点返回 0" ) ;

 // 平面：z=0
pd , phit := W . ray3d_hit_plane ( ray , W . Vec3 .{ 0 , 0 , 0 } , W . Vec3 .{ 0 , 0 , 1 } ) ;
expect ( state , phit && abs ( pd - 5 ) < 1.0e-5 , "平面命中距离 5" ) ;
_ , parallel := W . ray3d_hit_plane ( ray , W . Vec3 .{ 0 , 0 , 0 } , W . Vec3 .{ 1 , 0 , 0 } ) ; // 射线平行于平面
expect ( state , ! parallel , "平行于平面不应命中" ) ;

 // at 采样与零方向拒绝
p := W . ray3d_at ( ray , 5 ) ;
expect ( state , p . x == 0 && p . y == 0 && p . z == 0 , "at(5) 应到原点" ) ;
_ , zero := W . ray3d_make ( W . Vec3 .{ 0 , 0 , 0 } , W . Vec3 .{ 0 , 0 , 0 } ) ;
expect ( state , ! zero , "零方向射线应被拒绝" ) ;
}
//@endregion 

// Loop scopes adapted.

quaternion_rotation_preserves_basis :: (state:*Test_State) {
    angles:=float32.[-.7,.4,1.5707963];
    for angle:angles for axis:0..2 {
        q:[4]float32; q[axis]=sin(angle*.5); q[3]=cos(angle*.5);
        m:=W.matrix4_from_quaternion(q);
        basis:=W.Vec3.[.{1,0,0},.{0,1,0},.{0,0,1}];
        for v:basis { r:=W.matrix4_transform_vector(m,v); expect(state,abs(W.v3_dot(r,r)-1)<.00001,"Quaternion rotation must preserve unit length"); }
        for i:0..2 for j:i+1..2 expect(state,abs(W.v3_dot(W.matrix4_transform_vector(m,basis[i]),W.matrix4_transform_vector(m,basis[j])))<.00001,"Rotated axes must stay orthogonal");
    }
    pitch:float32=-.7; yaw:float32=.4;
    m:=W.matrix4_multiply(W.matrix4_from_quaternion(.[sin(-pitch*.5),0,0,cos(pitch*.5)]),W.matrix4_from_quaternion(.[0,sin(-yaw*.5),0,cos(yaw*.5)]));
    d:=W.matrix4_transform_vector(m,.{0,0,-1});
    expect(state,abs(d.x+sin(yaw)*cos(pitch))<.00001 && abs(d.y-sin(pitch))<.00001 && abs(d.z+cos(yaw)*cos(pitch))<.00001,"Combined FPS pitch/yaw must align the beam and aim ray");
}
