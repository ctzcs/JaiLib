// 一比一移植自 olib tests/core/curve/curve_test.odin。
// 断言数值与拆分方式保持原样，只把 core:testing.expect 换成 test_support.expect。
#import "Basic" ;
#import "Math" ;
#import "test_support" ;
CV :: #import "core/curve" ;

 //@region 曲线值与参数约定

 sample_endpoints_and_midpoints :: ( state : * Test_State ) {
p : [ 4 ] float32 = .[ 0 , 2 , 4 , 8 ] ;
expect ( state , CV . sample ( . Linear , p , 0.25 ) == 2 , "Linear 0.25" ) ;
expect ( state , CV . sample ( . Bezier , p , 0 ) == 0 , "Bezier 起点" ) ;
expect ( state , CV . sample ( . Bezier , p , 1 ) == 8 , "Bezier 终点" ) ;
expect ( state , CV . sample ( . Bezier , p , 0.5 ) == 3.25 , "Bezier 中点" ) ;
expect ( state , CV . sample ( . Hermite , p , 0 ) == 0 , "Hermite 起点" ) ;
expect ( state , CV . sample ( . Hermite , p , 1 ) == 8 , "Hermite 终点" ) ;
expect ( state , CV . sample ( . Catmull_Rom , p , 0 ) == 2 , "Catmull_Rom 起点" ) ;
expect ( state , CV . sample ( . Catmull_Rom , p , 1 ) == 4 , "Catmull_Rom 终点" ) ;
expect ( state , abs ( CV . sample ( . B_Spline , p , 0 ) - 2 ) < 1e-6 , "B_Spline 起点" ) ;
expect ( state , abs ( CV . sample ( . B_Spline , p , 1 ) - cast ( float32 ) ( 26.0 / 6.0 ) ) < 1e-6 , "B_Spline 终点" ) ;
// 参数不夹紧，支持多项式外推。
expect ( state , CV . sample ( . Linear , p , - 0.5 ) == - 4 , "Linear 外推左" ) ;
expect ( state , CV . sample ( . Linear , p , 1.5 ) == 12 , "Linear 外推右" ) ;
}

 hermite_tangents_and_cardinal :: ( state : * Test_State ) {
values : [ 4 ] float32 = .[ 2 , 3 , 8 , - 2 ] ;
h := cast ( float32 ) 0.001 ;
start_derivative := ( CV . sample_hermite_tangents ( values , h ) -
CV . sample_hermite_tangents ( values , - h ) ) / ( 2 * h ) ;
end_derivative := ( CV . sample_hermite_tangents ( values , 1 + h ) -
CV . sample_hermite_tangents ( values , 1 - h ) ) / ( 2 * h ) ;
expect ( state , abs ( start_derivative - 3 ) < 0.01 , "Hermite 起点导数" ) ;
expect ( state , abs ( end_derivative + 2 ) < 0.01 , "Hermite 终点导数" ) ;
expect ( state , CV . sample_hermite ( cast ( float32 ) 2 , cast ( float32 ) 3 , cast ( float32 ) 8 , cast ( float32 ) - 2 , 0.5 ) ==
CV . sample_hermite_tangents ( values , 0.5 ) , "sample_hermite 与切线版一致" ) ;
p : [ 4 ] float32 = .[ - 3 , 1 , 5 , 2 ] ;
for 0 .. 20 {
u := cast ( float32 ) it / 20 ;
expect ( state , abs ( CV . sample_cardinal ( p , u , 0.5 ) - CV . sample_catmull_rom ( p , u ) ) < 1e-5 ,
"cardinal 0.5 == catmull_rom (u=%)" , u ) ;
expect ( state , abs ( CV . sample_cardinal ( p , u , 0 ) -
CV . sample_hermite ( cast ( float32 ) 1 , cast ( float32 ) 0 , cast ( float32 ) 5 , cast ( float32 ) 0 , u ) ) < 1e-5 , "cardinal 0 == hermite (u=%)" , u ) ;
}
}

 vector_sampling_and_constant_invariance :: ( state : * Test_State ) {
p2 : [ 4 ] [ 2 ] float32 = .[ .[ 0 , 0 ] , .[ 2 , 4 ] , .[ 4 , 2 ] , .[ 8 , 6 ] ] ;
mid := CV . sample_bezier ( p2 , 0.5 ) ;
expect ( state , mid [ 0 ] == 3.25 && mid [ 1 ] == 3 , "vec2 Bezier 中点" ) ;
p3 : [ 4 ] [ 3 ] float32 = .[ .[ 1 , 2 , 3 ] , .[ 1 , 2 , 3 ] , .[ 1 , 2 , 3 ] , .[ 1 , 2 , 3 ] ] ;
p4 : [ 4 ] [ 4 ] float32 = .[ .[ 1 , 2 , 3 , 4 ] , .[ 1 , 2 , 3 , 4 ] , .[ 1 , 2 , 3 , 4 ] , .[ 1 , 2 , 3 , 4 ] ] ;
kinds : [ 5 ] CV . Kind = .[ . Linear , . Bezier , . Hermite , . Catmull_Rom , . B_Spline ] ;
for kind : kinds {
for 0 .. 10 {
u := cast ( float32 ) it / 10 ;
// Jai 没有数组减法：逐分量比较，等价于 linalg.length(sample - p0) < 1e-5。
v3 := CV . sample ( kind , p3 , u ) ;
v4 := CV . sample ( kind , p4 , u ) ;
d3 := ( v3 [ 0 ] - p3 [ 0 ] [ 0 ] ) * ( v3 [ 0 ] - p3 [ 0 ] [ 0 ] ) + ( v3 [ 1 ] - p3 [ 0 ] [ 1 ] ) * ( v3 [ 1 ] - p3 [ 0 ] [ 1 ] ) +
( v3 [ 2 ] - p3 [ 0 ] [ 2 ] ) * ( v3 [ 2 ] - p3 [ 0 ] [ 2 ] ) ;
d4 := ( v4 [ 0 ] - p4 [ 0 ] [ 0 ] ) * ( v4 [ 0 ] - p4 [ 0 ] [ 0 ] ) + ( v4 [ 1 ] - p4 [ 0 ] [ 1 ] ) * ( v4 [ 1 ] - p4 [ 0 ] [ 1 ] ) +
( v4 [ 2 ] - p4 [ 0 ] [ 2 ] ) * ( v4 [ 2 ] - p4 [ 0 ] [ 2 ] ) + ( v4 [ 3 ] - p4 [ 0 ] [ 3 ] ) * ( v4 [ 3 ] - p4 [ 0 ] [ 3 ] ) ;
expect ( state , d3 < 1e-10 , "常量控制点 vec3 不变 (%)" , kind ) ;
expect ( state , d4 < 1e-10 , "常量控制点 vec4 不变 (%)" , kind ) ;
}
}
} 

// Loop scopes adapted.
