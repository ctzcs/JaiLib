// 一比一移植自 olib tests/core/localization/localization_test.odin。
// 断言与拆分保持原样；mem.Tracking_Allocator → 本文件的 Test_Allocator，
// testing.expect / testing.expectf → test_support.expect（同一个 proc，带 % 参数）。
#import "Basic" ;
#import "test_support" ;
#import "Extensions/Variant" ; // variant(LC.Arg, 值)：Jai 侧没有 union 聚合字面量
LC :: #import "core/localization" ;

 //@region 测试用分配器（对应 mem.Tracking_Allocator）

 // 记录未释放的块（live 里 null 表示已释放），limited/budget 用来在第 N 次分配后开始失败。
Test_Allocator :: struct {
backing : Allocator ;
live : [ .. ] * void ;
limited : bool ;
budget : s64 ;
}

 test_alloc_proc :: ( mode : Allocator_Mode , size : s64 , old_size : s64 , old_memory : * void , allocator_data : * void ) -> * void {
state := cast ( * Test_Allocator ) allocator_data ;

 if mode == . ALLOCATE {
if state . limited && state . budget <= 0 return null ;
if state . limited state . budget -= 1 ;
memory := state . backing . proc ( . ALLOCATE , size , 0 , null , state . backing . data ) ;
if memory array_add ( * state . live , memory ) ;
return memory ;
}

 if mode == . FREE {
test_mark_released ( state , old_memory ) ;
return state . backing . proc ( . FREE , 0 , old_size , old_memory , state . backing . data ) ;
}

 return state . backing . proc ( mode , size , old_size , old_memory , state . backing . data ) ;
}

 test_mark_released :: ( state : * Test_Allocator , memory : * void ) {
if ! memory return ;
if state . live . count > 0 {
for 0 .. state . live . count - 1 {
if state . live [ it ] == memory {
state . live [ it ] = null ;
return ;
}
}
}
}

 // 等价于 len(tracker.allocation_map)。
test_live_count :: ( state : * Test_Allocator ) -> s64 {
count : s64 ;
if state . live . count > 0 {
for 0 .. state . live . count - 1 {
if state . live [ it ] != null count += 1 ;
}
}
return count ;
}

 test_allocator :: ( state : * Test_Allocator ) -> Allocator {
return Allocator .{ proc = test_alloc_proc , data = cast ( * void ) state } ;
}

 test_begin_tracking :: ( state : * Test_Allocator ) {
state .* = .{ } ;
state . backing = context . allocator ;
}

 // 对应 Odin 的 delete(text, allocator)。
test_free_with :: ( text : string , allocator : Allocator ) {
if text . data allocator . proc ( . FREE , 0 , text . count , text . data , allocator . data ) ;
}

 test_float_from_bits :: ( bits : u64 ) -> float64 {
return ( cast ( * float64 ) * bits ) .* ;
}

 // 对应 strings.has_prefix / strings.has_suffix。
test_has_prefix :: ( text : string , prefix : string ) -> bool {
if prefix . count > text . count return false ;
if prefix . count > 0 {
for 0 .. prefix . count - 1 {
if text [ it ] != prefix [ it ] return false ;
}
}
return true ;
}

 test_has_suffix :: ( text : string , suffix : string ) -> bool {
if suffix . count > text . count return false ;
offset := text . count - suffix . count ;
if suffix . count > 0 {
for 0 .. suffix . count - 1 {
if text [ offset + it ] != suffix [ it ] return false ;
}
}
return true ;
}

 // Odin 的 []Arg{string("中"), i64(-42), f64(1.25)}；Jai 的 Variant 用 variant() 构造。
arg_text :: ( text : string ) -> LC . Arg {
return variant ( LC . Arg , text ) ;
}

 arg_s64 :: ( value : s64 ) -> LC . Arg {
return variant ( LC . Arg , value ) ;
}

 arg_u64 :: ( value : u64 ) -> LC . Arg {
return variant ( LC . Arg , value ) ;
}

 arg_f64 :: ( value : float64 ) -> LC . Arg {
return variant ( LC . Arg , value ) ;
}
//@endregion

 //@region 表事务与回退

 table_replace_fallback_and_borrow :: ( state : * Test_State ) {
tracker : Test_Allocator ;
test_begin_tracking ( * tracker ) ;
a := test_allocator ( * tracker ) ;

 primary : LC . Table ;
fallback : LC . Table ;

 // 输入会复制：load 之后立刻释放克隆，表仍然可用。
input := copy_string ( "{\"k\":\"value\",\"empty\":\"\",\"\":\"blank\"}" ) ;
expect ( state , LC . load ( * primary , input , a ) == . None , "单层字符串对象加载成功" ) ;
free ( input ) ;
expect ( state , LC . load ( * fallback , "{\"k\":\"other\",\"empty\":\"filled\",\"only\":\"fallback\"}" , a ) == . None , "回退表加载成功" ) ;

 text , found := LC . lookup ( * primary , "k" ) ;
expect ( state , found && text == "value" , "primary 查到 k" ) ;
borrowed := text ;

 invalids := string .[
"{\"k\":1}" ,
"{\"k\":null}" ,
"{\"k\":true}" ,
"{\"k\":[]}" ,
"{\"k\":{}}" ,
"[]" ,
"null" ,
"{\"k\":\"a\",\"\\u006b\":\"b\"}" ,
"{\"k\":\"a\",}" ,
"{\"k\":" ,
"{\"k\":\"a\"} false" ,
"/*c*/{\"k\":\"a\"}" ,
"{\"k\":\"\\uD800\"}" ,
] ;
for invalids {
baseline := test_live_count ( * tracker ) ;
expect ( state , LC . load ( * primary , it , a ) != . None , tprint ( "拒绝非法输入 %" , it ) ) ;
expect ( state , test_live_count ( * tracker ) == baseline , "失败不新增分配" ) ;
expect ( state , borrowed == "value" , "失败替换不影响借用内容" ) ;
still , ok := LC . lookup ( * primary , "k" ) ;
expect ( state , ok && still . data == borrowed . data , "失败替换不影响借用指针" ) ;
}

 empty_value , empty_found := LC . lookup_fallback ( * primary , * fallback , "empty" ) ;
expect ( state , empty_found && empty_value == "" , "空字符串不算缺键" ) ;
only_value , only_found := LC . lookup_fallback ( * primary , * fallback , "only" ) ;
expect ( state , only_found && only_value == "fallback" , "只在 primary 缺键时查回退" ) ;
missing_value , missing_found := LC . lookup_fallback ( * primary , * fallback , "missing" ) ;
expect ( state , ! missing_found && missing_value == "" , "都缺失返回空且不自动用 key" ) ;
nil_primary_value , nil_primary_found := LC . lookup_fallback ( null , * fallback , "k" ) ;
expect ( state , nil_primary_found && nil_primary_value == "other" , "primary 可为 nil" ) ;
blank_value , blank_found := LC . lookup ( * primary , "" ) ;
expect ( state , blank_found && blank_value == "blank" , "空键合法" ) ;

 expect ( state , LC . load ( * primary , "{\"new\":\"replacement\"}" , a ) == . None , "成功替换先释放旧表" ) ;
_ , replaced_found := LC . lookup ( * primary , "k" ) ;
expect ( state , ! replaced_found , "替换后旧键消失" ) ;

 LC . dispose ( * primary ) ;
LC . dispose ( * primary ) ;
LC . dispose ( * fallback ) ;
expect ( state , test_live_count ( * tracker ) == 0 , "dispose 可重复调用且不留分配" ) ;
}
//@endregion

 //@region 格式与精确边界

 expect_format :: ( state : * Test_State , pattern : string , args : [ ] LC . Arg , expected : string ) {
result , err := LC . format ( pattern , args , context . allocator ) ;
expect ( state , err == . None && result == expected ,
tprint ( "格式 % 得到 %（%），期望 %" , pattern , result , err , expected ) ) ;
test_free_with ( result , context . allocator ) ;
}

 format_placeholders_and_braces :: ( state : * Test_State ) {
args : [ 3 ] LC . Arg = .[ arg_text ( "中" ) , arg_s64 ( - 42 ) , arg_f64 ( 1.25 ) ] ;
expect_format ( state , "{2:0.##}/{0}/{1}/{0}" , args , "1.25/中/-42/中" ) ;
expect_format ( state , "{{{0}}} {{ }}" , args , "{中} { }" ) ;
expect_format ( state , "{00}" , args , "中" ) ;

 no_args : [ ] LC . Arg ;
expect_format ( state , "literal" , no_args , "literal" ) ;
expect_format ( state , "" , no_args , "" ) ;

 braces : [ 1 ] LC . Arg = .[ arg_text ( "{1}" ) ] ;
expect_format ( state , "{0}" , braces , "{1}" ) ;

 biggest : [ 1 ] LC . Arg = .[ arg_u64 ( 0xffff_ffff_ffff_ffff ) ] ;
expect_format ( state , "{0}/{0:0.00}" , biggest , "18446744073709551615/18446744073709551615.00" ) ;

 smallest : [ 1 ] LC . Arg = .[ arg_s64 ( cast ( s64 ) 0x8000_0000_0000_0000 ) ] ;
expect_format ( state , "{0}/{0:0.00}" , smallest , "-9223372036854775808/-9223372036854775808.00" ) ;

 exact : [ 1 ] LC . Arg = .[ arg_s64 ( 9007199254740993 ) ] ;
expect_format ( state , "{0:0.##}/{0:0.#}/{0:0}" , exact ,
"9007199254740993/9007199254740993/9007199254740993" ) ;
}

 float_rounding_ties_even_and_negative_zero :: ( state : * Test_State ) {
ties : [ 4 ] LC . Arg = .[ arg_f64 ( 2.5 ) , arg_f64 ( 3.5 ) , arg_f64 ( - 2.5 ) , arg_f64 ( - 3.5 ) ] ;
expect_format ( state , "{0:0}/{1:0}/{2:0}/{3:0}" , ties , "2/4/-2/-4" ) ;

 two_digits : [ 2 ] LC . Arg = .[ arg_f64 ( 1.125 ) , arg_f64 ( 1.375 ) ] ;
expect_format ( state , "{0:0.00}/{1:0.00}" , two_digits , "1.12/1.38" ) ;

 one_digit : [ 2 ] LC . Arg = .[ arg_f64 ( 1.25 ) , arg_f64 ( 1.75 ) ] ;
expect_format ( state , "{0:0.#}/{1:0.#}" , one_digit , "1.2/1.8" ) ;

 optional : [ 3 ] LC . Arg = .[ arg_f64 ( 100 ) , arg_f64 ( 1.2 ) , arg_f64 ( 1.999 ) ] ;
expect_format ( state , "{0:0.##}/{1:0.##}/{2:0.##}" , optional , "100/1.2/2" ) ;

 decimal_less : [ 1 ] LC . Arg = .[ arg_f64 ( 2.675 ) ] ;
expect_format ( state , "{0:0.00}" , decimal_less , "2.67" ) ;

 negative_zero := test_float_from_bits ( 0x8000_0000_0000_0000 ) ;
zeros : [ 2 ] LC . Arg = .[ arg_f64 ( negative_zero ) , arg_f64 ( - 0.001 ) ] ;
expect_format ( state , "{0}/{0:0}/{0:0.00}/{1:0.00}/{1:0.##}" , zeros , "0/0/0.00/0.00/0" ) ;

 wide : [ 1 ] LC . Arg = .[ arg_f64 ( 9007199254740992.0 ) ] ;
expect_format ( state , "{0:0.00}" , wide , "9007199254740992.00" ) ;

 denormal : [ 1 ] LC . Arg = .[ arg_f64 ( test_float_from_bits ( 1 ) ) ] ;
expect_format ( state , "{0:0.00}" , denormal , "0.00" ) ;

 above_u64 : [ 1 ] LC . Arg = .[ arg_f64 ( 18446744073709551616.0 ) ] ;
expect_format ( state , "{0:0.00}" , above_u64 , "18446744073709551616.00" ) ;

 max_float : [ 1 ] LC . Arg = .[ arg_f64 ( test_float_from_bits ( 0x7fefffffffffffff ) ) ] ;
result , err := LC . format ( "{0:0.00}" , max_float , context . allocator ) ;
expect ( state , err == . None && result . count == 312 , "最大有限 f64 的固定两位是 312 字节" ) ;
expect ( state , test_has_prefix ( result , "17976931348623157" ) && test_has_suffix ( result , ".00" ) ,
"最大有限 f64 的首尾" ) ;
test_free_with ( result , context . allocator ) ;
}

 format_errors_are_not_partial_results :: ( state : * Test_State ) {
args : [ 2 ] LC . Arg = .[ arg_text ( "text" ) , arg_f64 ( 1 ) ] ;

 patterns := string .[
"prefix {" ,
"prefix }" ,
"{}" ,
"{x}" ,
"{-1}" ,
"{0" ,
"{ 0}" ,
"{0,2}" ,
"{2}" ,
"{999999999999999999999999999999999999999}" ,
"{1:}" ,
"{1:0.0}" ,
"{1:0.###}" ,
"{1:N2}" ,
"{1:0.00x}" ,
"{0:0}" ,
"{1:{0}}" ,
] ;
for patterns {
result , err := LC . format ( it , args , context . allocator ) ;
expect ( state , err != . None && result == "" , tprint ( "拒绝 %（%）" , it , err ) ) ;
test_free_with ( result , context . allocator ) ;
}

 non_finite_bits := u64 .[ 0x7ff0000000000000 , 0xfff0000000000000 , 0x7ff8000000000001 ] ;
for non_finite_bits {
one : [ 1 ] LC . Arg = .[ arg_f64 ( test_float_from_bits ( it ) ) ] ;
result , err := LC . format ( "prefix {0:0.00}" , one , context . allocator ) ;
expect ( state , err == . Non_Finite && result == "" , "非有限值报 Non_Finite" ) ;
test_free_with ( result , context . allocator ) ;
}

 no_args : [ ] LC . Arg ;

 invalid_bytes : [ 1 ] u8 = .[ 0xff ] ;
invalid_text := string .{ 1 , invalid_bytes . data } ;
result , err := LC . format ( invalid_text , no_args , context . allocator ) ;
expect ( state , err == . Invalid_UTF8 && result == "" , "格式文本必须是有效 UTF-8" ) ;
test_free_with ( result , context . allocator ) ;

 invalid_arg : [ 1 ] LC . Arg = .[ arg_text ( invalid_text ) ] ;
result , err = LC . format ( "{0}" , invalid_arg , context . allocator ) ;
expect ( state , err == . Invalid_UTF8 && result == "" , "字符串参数必须是有效 UTF-8" ) ;
test_free_with ( result , context . allocator ) ;

 empty_arg : LC . Arg ;
zero_arg : [ 1 ] LC . Arg = .[ empty_arg ] ;
result , err = LC . format ( "{0}" , zero_arg , context . allocator ) ;
expect ( state , err == . Argument_Type && result == "" , "零值 Arg 报 Argument_Type" ) ;
test_free_with ( result , context . allocator ) ;
}

 formatted_result_outlives_table :: ( state : * Test_State ) {
table : LC . Table ;
a := context . allocator ;
expect ( state , LC . load ( * table , "{\"k\":\"hello {0}\"}" , a ) == . None , "加载模板表" ) ;
pattern , found := LC . lookup ( * table , "k" ) ;
expect ( state , found , "找到模板键" ) ;
args : [ 1 ] LC . Arg = .[ arg_text ( "world" ) ] ;
result , err := LC . format ( pattern , args , a ) ;
LC . dispose ( * table ) ;
expect ( state , err == . None && result == "hello world" , "格式化结果活过表释放" ) ;
test_free_with ( result , a ) ;
}
//@endregion

 //@region 分配失败与清理

 allocation_failure_keeps_table_and_releases_format :: ( state : * Test_State ) {
tracker : Test_Allocator ;
test_begin_tracking ( * tracker ) ;
a := test_allocator ( * tracker ) ;

 format_args : [ 2 ] LC . Arg = .[ arg_f64 ( 2.5 ) , arg_text ( "中" ) ] ;
no_args : [ ] LC . Arg ;

 for 0 .. 19 {
budget := it ;

 table : LC . Table ;
expect ( state , LC . load ( * table , "{\"old\":\"kept\"}" , a ) == . None , "基础表加载" ) ;
baseline := test_live_count ( * tracker ) ;

 tracker . limited = true ;
tracker . budget = budget ;
err := LC . load ( * table , "{\"new\":\"replacement\",\"other\":\"text\"}" , a ) ;
tracker . limited = false ;
if err != . None {
text , found := LC . lookup ( * table , "old" ) ;
expect ( state , found && text == "kept" , "分配失败保旧" ) ;
expect ( state , test_live_count ( * tracker ) == baseline , "分配失败不新增分配" ) ;
}

 LC . dispose ( * table ) ;
expect ( state , test_live_count ( * tracker ) == 0 , "dispose 后归零" ) ;

 tracker . limited = true ;
tracker . budget = budget ;
result , _ := LC . format ( "prefix {0:0.00} {1} suffix" , format_args , a ) ;
test_free_with ( result , a ) ;
tracker . limited = false ;
expect ( state , test_live_count ( * tracker ) == 0 , "format 失败不留分配" ) ;

 out_of_range , range_err := LC . format ( "allocated prefix {2}" , no_args , a ) ;
expect ( state , range_err == . Argument_Index && out_of_range == "" , "越界索引报 Argument_Index" ) ;
expect ( state , test_live_count ( * tracker ) == 0 , "错误路径不留分配" ) ;
}
}
//@endregion 

// Loop scopes adapted.
