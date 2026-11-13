// 一比一移植自 olib tests/core/hotreload/hotreload_test.odin。
// 断言顺序、拆分方式与 olib 一一对应；core:testing.expect / expect_value / expectf
// 换成 test_support.expect（它自带格式化参数，所以 expect_value 直接展开成 ==）。
//
// Jai 侧差异（逐条对应 olib 的写法）：
//   - odin 的 `#+test package hotreload` 直接测包内私有过程；Jai 没有 #+test 与包内私有，
//     这里 `#import "core/hotreload"` 后按模块别名 HR 使用（Jai 的可见性靠命名约定，
//     hot_command / watch_fingerprint / simple_store 这类「包内私有」过程一样可以直接调，
//     与 olib 的测试用法一致）；
//   - 测试过程签名是 `(state: *Test_State)`（test_support 的 Test_State），不写 main；
//     **命名冲突**：olib 的 Game State 也叫 Test_State，这里改名为 Game_State / Game_Services；
//   - odin 的 `os.make_directory_temp` / `os.remove` / `os.write_entire_file` /
//     `os.is_file` 换成 File / File_Utilities 的等价过程（见文件末尾的 hotreload_test_* 辅助）；
//     odin 的 `os.remove` 既能删文件也能删空目录，Jai 侧分开：file_delete / delete_directory；
//   - odin 的 `time.tick_now` / `time.tick_since` 换成 scan_monotonic_nano 的纳秒差；
//   - odin 的 `append(&x, a, b)` → 两次 array_add；`len(x)` → `x.count`；
//     `make([]u8, n)` → 手动设 count + alloc(n)；`delete(...)` → free / array_reset；
//     `raw_data(x)` → `x.data`；`snapshot[:1]` → 复制一份把 count 改成 1；
//   - odin 的结构/切片字面量 `{...}` → `Type.{...}`；`{root}` → `.{ root }`（字段类型已知）；
//   - **新增**一个 olib 没有的用例 hot_mode_selects_scan_and_manual_trigger：只断言
//     Watch 的 Auto/Manual 判定（有没有扫描线程、启动时是否需要一次编译请求、
//     触发文件的修改时间基线、hot_retry 重新置位请求），不发任何子进程，所以结果确定；
//   - **无法移植的用例**：olib 这份测试里没有「真实编译游戏 DLL 并加载」的往返用例
//     （只有 session 拒绝缺失模块的用例，见下）。Jai 侧同样没有：验收用的 jaic 只产出
//     可执行文件、不产出共享库，所以 session 的 dll 往返在当前环境里无法真跑，
//     这部分由 core/hotreload 的 -check 与 session 的缺失模块用例覆盖（见报告）。
#import "Basic" ;
#import "test_support" ;
FILE :: #import "File" ;
FU :: #import "File_Utilities" ;
STRING :: #import "String" ;
ENV :: #import "Extensions/Environment" ;
HR :: #import "core/hotreload" ;
DB :: #import "core/devbuild" ;

 //@region 辅助

 hotreload_test_counter : int ;

 // odin: os.make_directory_temp(parent, prefix)。parent 为空时用系统临时目录。
hotreload_test_temp_directory :: ( prefix : string ) -> string {
base := ENV . environment_variable ( "TEMP" ) ;
if base . count == 0 base = ENV . environment_variable ( "TMP" ) ;
if base . count == 0 base = "." ;
for 0 .. 1023 {
attempt := hotreload_test_counter ;
hotreload_test_counter += 1 ;
candidate := tprint ( "%/%_%_%" , base , prefix , attempt , HR . scan_monotonic_nano ( ) ) ;
if FU . is_directory ( candidate ) continue ;
if ! FILE . make_directory_if_it_does_not_exist ( candidate , true ) continue ;
return candidate ;
}
return "" ;
}

 hotreload_test_join :: ( directory : string , name : string ) -> string {
return tprint ( "%/%" , directory , name ) ;
}

 // 删文件（不存在也算成功）：odin 的 os.remove 对文件与目录是同一个调用。
hotreload_test_remove_file :: ( path : string ) {
if path . count > 0 FILE . file_delete ( path ) ;
}

 // 删目录里的所有文件再删目录本身，让测试不留下垃圾。
hotreload_test_remove_tree :: ( directory : string ) {
if directory . count == 0 return ;
is_directory , _ := FU . is_directory ( directory ) ;
if ! is_directory return ;
files := FU . file_list ( directory ) ;
for files {
FILE . file_delete ( it ) ;
if it . data != null free ( it ) ;
}
if files . data != null free ( files . data ) ;
FILE . delete_directory ( directory ) ;
}

 hotreload_test_now :: ( ) -> s64 {
return HR . scan_monotonic_nano ( ) ;
}

 hotreload_test_since :: ( start : s64 ) -> s64 {
return hotreload_test_now ( ) - start ;
}

 HOTRELOAD_TEST_NS_PER_SECOND :: 1000000000 ;

 hotreload_test_seconds_as_ns :: ( seconds : float64 ) -> s64 {
return cast ( s64 ) ( seconds * cast ( float64 ) HOTRELOAD_TEST_NS_PER_SECOND ) ;
}

 // odin: watch_until_settled。等编译结束，再观察一会儿确认不会继续重编。
hotreload_test_watch_until_settled :: ( state : * Test_State , w : * HR . Watch ) {
deadline := hotreload_test_now ( ) ;
while w . status != . Ready && w . status != . Error {
HR . watch_update ( w , 0.02 ) ;
sleep_milliseconds ( 5 ) ;
if hotreload_test_since ( deadline ) > 30 * HOTRELOAD_TEST_NS_PER_SECOND {
expect ( state , false , "watch did not settle" ) ;
return ;
}
}
settle := hotreload_test_now ( ) ;
while hotreload_test_since ( settle ) < hotreload_test_seconds_as_ns ( 0.5 ) {
HR . watch_update ( w , 0.02 ) ;
sleep_milliseconds ( 5 ) ;
}
}

 // 本文件所在目录（带结尾分隔符）。
hotreload_test_source_directory :: ( ) -> string {
return #filepath ;
}

 // 用 jaic 现编夹具（odin 版是 odin build）；成功返回 exe 路径，失败返回空串。
hotreload_test_build_fixture :: ( state : * Test_State , workspace : string ) -> string {
source := hotreload_test_join ( hotreload_test_join ( hotreload_test_source_directory ( ) , "testdata" ) ,
"pre_command.jai" ) ;
tool := hotreload_test_join ( workspace , "fixture.exe" ) ;
command : [ .. ] string ;
array_add ( * command , "jaic" ) ;
array_add ( * command , source ) ;
array_add ( * command , "-exe" ) ;
array_add ( * command , tool ) ;
st , out , errout , err := DB . exec ( DB . Process_Desc .{ command = command } ) ;
ok := err == . None && st . exited && st . exit_code == 0 && FU . file_exists ( tool ) ;
if ! ok {
expect ( state , false , "夹具编译失败 (%): %%" , err , out , errout ) ;
}
if out . count > 0 free ( out ) ;
if errout . count > 0 free ( errout ) ;
if ! ok return "" ;
return tool ;
}
//@endregion

 //@region 监听：内容变化、增删文件与释放

 // 内容监听须发现文件增删、子目录与不改变大小的编辑；不依赖时间戳精度。
source_changes_and_disposal :: ( state : * Test_State ) {
root := hotreload_test_temp_directory ( "olib_hotreload_test_" ) ;
expect ( state , root != "" , "临时目录创建失败" ) ;
if root == "" return ;
sub := hotreload_test_join ( root , "nested" ) ;
file := hotreload_test_join ( sub , "main.jai" ) ;
added := hotreload_test_join ( root , "new.jai" ) ;
ignored := hotreload_test_join ( root , "cache.dll" ) ;
expect ( state , FILE . make_directory_if_it_does_not_exist ( sub , true ) , "建子目录失败" ) ;
expect ( state , FILE . write_entire_file ( file , "AAAA" ) , "写源文件失败" ) ;
command : [ ] string = .[ "odin" , "-out:{output}" ] ;
roots : [ ] string = .[ root ] ;
w : HR . Watch ;
expect ( state , HR . watch_init ( * w , HR . Watch_Config .{ command = command , roots = roots } ) ,
"watch_init 失败" ) ;
defer {
HR . watch_dispose ( * w ) ;
hotreload_test_remove_file ( file ) ;
hotreload_test_remove_file ( added ) ;
hotreload_test_remove_file ( ignored ) ;
hotreload_test_remove_tree ( sub ) ;
hotreload_test_remove_tree ( root ) ;
}
first , ok := HR . watch_fingerprint ( * w ) ;
expect ( state , ok , "首次指纹应可读" ) ;
FILE . write_entire_file ( file , "BBBB" ) ;
second , ok2 := HR . watch_fingerprint ( * w ) ;
expect ( state , ok2 && first != second , "内容变化应改变指纹" ) ;
FILE . write_entire_file ( ignored , "unwatched" ) ;
third , _ := HR . watch_fingerprint ( * w ) ;
expect ( state , third == second , "非源码扩展名不影响指纹" ) ;
FILE . write_entire_file ( added , "package extra" ) ;
fourth , _ := HR . watch_fingerprint ( * w ) ;
expect ( state , fourth != third , "新增文件应改变指纹" ) ;
FILE . file_delete ( added ) ;
fifth , _ := HR . watch_fingerprint ( * w ) ;
expect ( state , fifth == third , "删掉新增文件后指纹回到原值" ) ;
FILE . file_delete ( file ) ;
sixth , _ := HR . watch_fingerprint ( * w ) ;
expect ( state , sixth != fifth , "删掉源文件应改变指纹" ) ;
hotreload_test_remove_file ( ignored ) ;
hotreload_test_remove_tree ( sub ) ;
hotreload_test_remove_tree ( root ) ;
_ , missing := HR . watch_fingerprint ( * w ) ;
expect ( state , ! missing , "根目录没了应报告不可读" ) ;
}

 // ---- Session：缺失模块不把会话变成 live ----

 session_rejects_missing_module_without_becoming_live :: ( state : * Test_State ) {
s : HR . Session ;
expect ( state , HR . reload ( * s , "absent.dll" ) == . Not_Initialized , "未 init 的会话拒绝 reload" ) ;
expect ( state , HR . init ( * s , 17 ) , "init 失败" ) ;
defer _ = HR . dispose ( * s ) ;
expect ( state , ! HR . init ( * s , 18 ) , "must not overwrite a live session's ownership" ) ;
expect ( state , HR . reload ( * s , "__olib_missing_module__.dll" ) == . File_Error ,
"缺失模块应报 File_Error" ) ;
expect ( state , ! HR . is_live ( * s ) && s . revision == 0 && s . diagnostic . count > 0 ,
"失败不应留下 live 模块，但要有诊断" ) ;
s . busy = true ;
expect ( state , HR . reload ( * s , "absent.dll" ) == . Busy && ! HR . dispose ( * s ) ,
"回调中 reload 是 Busy，dispose 也要拒绝" ) ;
s . busy = false ;
}
//@endregion

 //@region Hot：命令由配置生成，初始化/释放不留下状态

 hot_builds_command_and_validates_config :: ( state : * Test_State ) {
collections : [ ] string = .[ "olib=../olib" , "game=src" ] ;
extra : [ ] string = .[ "-vet" ] ;
command := HR . hot_command ( HR . Hot_Config .{ source = "src/game" , collections = collections ,
args = extra } ) ;
defer HR . hot_command_free ( * command ) ;
expect ( state , command . count == 8 , "命令行应有 8 个参数，实际 %" , command . count ) ;
expect ( state , command [ 2 ] == "src/game" , "source 在第 3 位" ) ;
expect ( state , command [ 4 ] == "-collection:olib=../olib" , "collection 带前缀" ) ;
expect ( state , command [ 6 ] == "-vet" , "额外参数跟在 collection 之后" ) ;
expect ( state , command [ 7 ] == "-out:{output}" , "产物占位符在最后" ) ;
h : HR . Hot ;
expect ( state , ! HR . hot_init ( * h , HR . Hot_Config .{ } ) , "source is required" ) ;
root := hotreload_test_temp_directory ( "olib_hot_test_" ) ;
expect ( state , root != "" , "临时目录创建失败" ) ;
if root == "" return ;
defer hotreload_test_remove_tree ( root ) ;
expect ( state , HR . hot_init ( * h , HR . Hot_Config .{ source = root , quiet = true } ) , "hot_init 失败" ) ;
expect ( state , ! HR . hot_init ( * h , HR . Hot_Config .{ source = root , quiet = true } ) , "already initialized" ) ;
expect ( state , h . version == 0 , "还没加载过模块" ) ;
expect ( state , HR . hot_error ( * h ) == "" , "没有编译失败时 hot_error 为空" ) ;
HR . hot_update ( * h , 0.01 ) ; // 没有模块时不做任何事
HR . hot_render ( * h , 0.01 ) ;
HR . hot_dispose ( * h ) ;
expect ( state , ! h . session . initialized && ! h . watch . initialized , "释放后不留状态" ) ;
}

 // ---- 模式判定：Auto 起扫描线程；Manual 不扫描，靠一次编译请求 + 触发文件 ----

 hot_mode_selects_scan_and_manual_trigger :: ( state : * Test_State ) {
root := hotreload_test_temp_directory ( "olib_hot_mode_" ) ;
expect ( state , root != "" , "临时目录创建失败" ) ;
if root == "" return ;
source := hotreload_test_join ( root , "game.jai" ) ;
trigger := hotreload_test_join ( root , "game.trigger" ) ;
expect ( state , FILE . write_entire_file ( source , "// game\n" ) , "写源文件失败" ) ;
expect ( state , FILE . write_entire_file ( trigger , "go" ) , "写触发文件失败" ) ;
defer hotreload_test_remove_tree ( root ) ;

 auto : HR . Hot ;
expect ( state , HR . hot_init ( * auto , HR . Hot_Config .{ source = root , quiet = true } ) , "Auto init 失败" ) ;
expect ( state , auto . watch . mode == . Auto , "默认是 Auto" ) ;
expect ( state , auto . watch . scanner . thread != null , "Auto 要起后台扫描线程" ) ;
expect ( state , ! auto . watch . pending , "Auto 不等手动请求" ) ;
HR . hot_dispose ( * auto ) ;

 manual : HR . Hot ;
expect ( state , HR . hot_init ( * manual , HR . Hot_Config .{ source = root , quiet = true , mode = . Manual ,
trigger_file = trigger } ) , "Manual init 失败" ) ;
expect ( state , manual . watch . mode == . Manual , "模式是 Manual" ) ;
expect ( state , manual . watch . scanner . thread == null , "Manual 不建扫描线程" ) ;
expect ( state , manual . watch . pending , "Manual 启动时还没有可运行版本，要先编一次" ) ;
expect ( state , manual . watch . trigger_modified != 0 , "已有的触发文件只记基线，不算请求" ) ;
manual . watch . pending = false ; // 假装启动时那次编译已经跑过
HR . hot_retry ( * manual ) ;
expect ( state , manual . watch . pending , "hot_retry 在 Manual 下重新置一次编译请求" ) ;
HR . hot_dispose ( * manual ) ;
}
//@endregion

 //@region pre_command：编译前运行，失败不编译，写入被监听文件时只多编一次
//
// 夹具（testdata/pre_command.jai）充当生成器与编译器：odin 版用 odin build 现编，
// 这里用 jaic 现编。编不出来就直接报失败（不静默跳过），因为本机就是用它构建测试的。
pre_command_runs_before_build_and_converges :: ( state : * Test_State ) {
tool_root := hotreload_test_temp_directory ( "olib_hot_pre_tool_" ) ;
expect ( state , tool_root != "" , "临时目录创建失败" ) ;
if tool_root == "" return ;
tool := hotreload_test_build_fixture ( state , tool_root ) ;
expect ( state , tool != "" , "夹具 exe 应在：%" , tool_root ) ;
if tool == "" return ;

 root := hotreload_test_temp_directory ( "olib_hot_pre_" ) ;
expect ( state , root != "" , "临时目录创建失败" ) ;
if root == "" return ;
source_file := hotreload_test_join ( root , "source.jai" ) ;
generated := hotreload_test_join ( root , "kinds_generated.jai" ) ;
expect ( state , FILE . write_entire_file ( source_file , "// demo\n" ) , "写源文件失败" ) ;
defer {
hotreload_test_remove_tree ( root ) ;
hotreload_test_remove_tree ( tool_root ) ;
}
build : [ ] string = .[ tool , "build" , "-out:{output}" ] ;
generate : [ ] string = .[ tool , "generate" , generated , "// demo // generated\n" ] ;

 // 写入被监听文件：第一次结果作废，第二次内容相同不再写，只多编一次。
{
w : HR . Watch ;
expect ( state , HR . watch_init ( * w , HR . Watch_Config .{ command = build , pre_command = generate ,
roots = .[ root ] , poll_seconds = 0.01 ,
debounce_seconds = 0.01 } ) ,
"watch_init 失败" ) ;
hotreload_test_watch_until_settled ( state , * w ) ;
expect ( state , w . status == . Ready , "状态应是 Ready，实际 %" , w . status ) ;
expect ( state , w . generation == 2 , "写被监听文件应导致多编一次，实际 %" , w . generation ) ;
expect ( state , FU . file_exists ( generated ) , "生成器应写出文件" ) ;
HR . watch_dispose ( * w ) ;
}
// 生成内容已是最新：只编一次。
{
w : HR . Watch ;
expect ( state , HR . watch_init ( * w , HR . Watch_Config .{ command = build , pre_command = generate ,
roots = .[ root ] , poll_seconds = 0.01 ,
debounce_seconds = 0.01 } ) ,
"watch_init 失败" ) ;
hotreload_test_watch_until_settled ( state , * w ) ;
expect ( state , w . status == . Ready , "状态应是 Ready，实际 %" , w . status ) ;
expect ( state , w . generation == 1 , "内容没变只编一次，实际 %" , w . generation ) ;
HR . watch_dispose ( * w ) ;
}
// 前置命令失败：不运行编译命令，诊断能区分生成失败。
{
w : HR . Watch ;
fail_command : [ ] string = .[ tool , "fail" ] ;
expect ( state , HR . watch_init ( * w , HR . Watch_Config .{ command = build , pre_command = fail_command ,
roots = .[ root ] , poll_seconds = 0.01 ,
debounce_seconds = 0.01 } ) ,
"watch_init 失败" ) ;
hotreload_test_watch_until_settled ( state , * w ) ;
expect ( state , w . status == . Error , "前置命令失败应是 Error，实际 %" , w . status ) ;
expect ( state , STRING . begins_with ( w . diagnostic , "Game generate failed" ) ,
"诊断应指出是生成失败：%" , w . diagnostic ) ;
expect ( state , ! FU . file_exists ( w . job . output ) , "前置命令失败时不应跑编译命令" ) ;
expect ( state , w . generation == 1 , "只尝试一次，实际 %" , w . generation ) ;
HR . watch_dispose ( * w ) ;
}
// 不配置前置命令时行为不变；Hot 透传配置。
{
w : HR . Watch ;
expect ( state , HR . watch_init ( * w , HR . Watch_Config .{ command = build , roots = .[ root ] ,
poll_seconds = 0.01 ,
debounce_seconds = 0.01 } ) ,
"watch_init 失败" ) ;
hotreload_test_watch_until_settled ( state , * w ) ;
expect ( state , w . status == . Ready , "状态应是 Ready，实际 %" , w . status ) ;
expect ( state , w . generation == 1 , "只编一次，实际 %" , w . generation ) ;
HR . watch_dispose ( * w ) ;
}
h : HR . Hot ;
expect ( state , HR . hot_init ( * h , HR . Hot_Config .{ source = root , pre_command = generate ,
quiet = true } ) , "hot_init 失败" ) ;
expect ( state , h . watch . pre_command . count == 4 , "Hot 应把 pre_command 原样交给 Watch，实际 %" ,
h . watch . pre_command . count ) ;
HR . hot_dispose ( * h ) ;
}
//@endregion

 //@region simple_api：State 整体交接，堆数据共用，start / stop / drop 各司其职
//
// olib 的 Game State 也叫 Test_State，会撞 test_support 的 Test_State，这里改名 Game_State。

 Game_State :: struct {
value : s32 ;
values : [ .. ] int ; // 堆数据：热重载时新旧版本共用，只在真正退出时 drop 释放
resource : int ; // 模拟资源（如 Batcher）：每个版本自己创建、释放
}

 Game_Services :: struct {
started : int ;
stopped : int ;
dropped : int ;
updated : int ;
rendered : int ;
next_resource : int ;
released : [ 4 ] int ;
}

 game_reset :: ( state : * Game_State , services : * Game_Services ) {
state . value = 7 ;
array_add ( * state . values , 10 ) ;
array_add ( * state . values , 20 ) ;
}

 game_start :: ( state : * Game_State , services : * Game_Services ) {
services . started += 1 ;
services . next_resource += 1 ;
state . resource = services . next_resource ; // 覆盖交接过来的旧资源
}

 game_stop :: ( state : * Game_State , services : * Game_Services ) {
services . released [ services . stopped ] = state . resource ;
services . stopped += 1 ;
}

 game_drop :: ( state : * Game_State , services : * Game_Services ) {
services . dropped += 1 ;
// odin: delete(state.values)
array_reset ( * state . values ) ;
}

 game_update :: ( state : * Game_State , services : * Game_Services , dt : float64 ) {
services . updated += 1 ;
state . value += 1 ;
array_add ( * state . values , cast ( int ) state . value ) ;
}

 game_render :: ( state : * Game_State , services : * Game_Services , dt : float64 ) {
services . rendered += 1 ;
}

 // 模块级 hooks（模块生命周期内地址稳定，simple_api 只保存指针）。
game_hooks : HR . Game_Hooks ( Game_State , Game_Services ) = .{
reset = game_reset , update = game_update , render = game_render ,
start = game_start , stop = game_stop , drop = game_drop ,
host_version = 3 , state_version = 5 ,
} ;

 simple_api_hands_state_over_and_drops_only_at_exit :: ( state : * Test_State ) {
api : HR . API ;
expect ( state , ! HR . simple_api ( HR . API_VERSION + 1 , size_of ( HR . API ) , * api , * game_hooks ) ,
"版本不符必须拒绝" ) ;
bad_hooks : HR . Game_Hooks ( Game_State , Game_Services ) = .{ reset = game_reset } ;
expect ( state , ! HR . simple_api ( HR . API_VERSION , size_of ( HR . API ) , * api , * bad_hooks ) ,
"update and render are required" ) ;
expect ( state , HR . simple_api ( HR . API_VERSION , size_of ( HR . API ) , * api , * game_hooks ) , "simple_api 失败" ) ;
expect ( state , HR . api_valid ( api ) && api . host_version == 3 && api . state_version == 5 ,
"host/state 版本应透传（0 视为 1）" ) ;
services : Game_Services ;
ctx := context ;
old := HR . Call .{ host_context = * ctx , services = * services } ;
// 新局：reset 初始化，start 创建资源 1。
expect ( state , api . load ( * old , HR . Snapshot .{ } ) , "首次 load 应成功" ) ;
api . update ( * old , 0.1 ) ;
api . render ( * old , 0.1 ) ;
expect ( state , services . started == 1 , "start 只跑一次，实际 %" , services . started ) ;
expect ( state , api . snapshot_size ( * old ) == size_of ( Game_State ) , "快照大小就是 State 大小" ) ;
snapshot : [ ] u8 ;
snapshot . count = api . snapshot_size ( * old ) ;
snapshot . data = cast ( * u8 ) alloc ( snapshot . count ) ;
defer free ( snapshot . data ) ;
short := snapshot ;
short . count = 1 ;
expect ( state , ! api . save ( * old , short ) , "缓冲区大小不符必须拒绝" ) ;
// 热重载：旧版本交出 State，新版本 load（不调用 reset），start 换上资源 2，旧版本再 unload。
expect ( state , api . save ( * old , snapshot ) , "交接应成功" ) ;
next := HR . Call .{ host_context = * ctx , services = * services } ;
expect ( state , api . load ( * next , HR . Snapshot .{ data = snapshot , version = 5 } ) ,
"新版本应接受交接过来的快照" ) ;
expect ( state , services . started == 2 , "新版本也要 start，实际 %" , services . started ) ;
old_state := ( cast ( * HR . Simple_Slot ( Game_State ) ) old . instance ) . state ;
api . unload ( * old ) ;
expect ( state , services . stopped == 1 , "旧版本 stop 一次，实际 %" , services . stopped ) ;
expect ( state , services . released [ 0 ] == 1 , "旧版本释放的是它自己的资源 1" ) ;
expect ( state , services . dropped == 0 , "已交接：不释放共用的堆数据" ) ;
restored := ( cast ( * HR . Simple_Slot ( Game_State ) ) next . instance ) . state ;
expect ( state , restored . value == 8 , "reset 的 7 加一次 update，实际 %" , restored . value ) ;
expect ( state , restored . resource == 2 , "资源是新版本创建的 2，实际 %" , restored . resource ) ;
expect ( state , restored . values . data == old_state . values . data , "heap data is shared, not copied" ) ;
expect ( state , restored . values . count == 3 , "交接后堆数据仍是 3 个元素" ) ;
api . update ( * next , 0.1 ) ;
expect ( state , restored . values . count == 3 , "restored 是副本；真实状态在 next 的槽里" ) ;
expect ( state , ( cast ( * HR . Simple_Slot ( Game_State ) ) next . instance ) . state . values . count == 4 ,
"真实状态追加了第 4 个元素" ) ;
// 真正退出：stop 和 drop 各一次。
api . unload ( * next ) ;
expect ( state , services . stopped == 2 , "退出时 stop 再跑一次，实际 %" , services . stopped ) ;
expect ( state , services . released [ 1 ] == 2 , "第二次释放的是资源 2" ) ;
expect ( state , services . dropped == 1 , "真正退出时 drop 一次，实际 %" , services . dropped ) ;
}

 simple_api_keeps_ownership_when_candidate_is_rejected :: ( state : * Test_State ) {
api : HR . API ;
expect ( state , HR . simple_api ( HR . API_VERSION , size_of ( HR . API ) , * api , * game_hooks ) , "simple_api 失败" ) ;
services : Game_Services ;
ctx := context ;
old := HR . Call .{ host_context = * ctx , services = * services } ;
expect ( state , api . load ( * old , HR . Snapshot .{ } ) , "首次 load 应成功" ) ;
snapshot : [ ] u8 ;
snapshot . count = api . snapshot_size ( * old ) ;
snapshot . data = cast ( * u8 ) alloc ( snapshot . count ) ;
defer free ( snapshot . data ) ;
expect ( state , api . save ( * old , snapshot ) , "交接应成功" ) ;
// 新版本拒绝（大小不符）：不调用它的 stop / drop，旧版本继续运行并仍然拥有 State。
rejected := HR . Call .{ host_context = * ctx , services = * services } ;
truncated := snapshot ;
truncated . count = 3 ;
expect ( state , ! api . load ( * rejected , HR . Snapshot .{ data = truncated , version = 5 } ) ,
"大小不符的快照必须拒绝" ) ;
api . unload ( * rejected ) ;
expect ( state , services . stopped == 0 , "被拒绝的候选不 stop" ) ;
expect ( state , services . dropped == 0 , "被拒绝的候选不 drop" ) ;
api . update ( * old , 0.1 ) ; // 继续运行会取消「已交接」标记
api . unload ( * old ) ;
expect ( state , services . dropped == 1 , "退出时仍由旧版本 drop，实际 %" , services . dropped ) ;
}

 Minimal_State :: struct {
count : int ;
}

 minimal_reset :: ( state : * Minimal_State , services : * Game_Services ) {
state . count = 1 ;
}

 minimal_update :: ( state : * Minimal_State , services : * Game_Services , dt : float64 ) {
state . count += 1 ;
}

 minimal_render :: ( state : * Minimal_State , services : * Game_Services , dt : float64 ) {
}

 // 没有资源的游戏只填 reset / update / render，其余回调为 null。
simple_api_works_with_only_required_hooks :: ( state : * Test_State ) {
hooks : HR . Game_Hooks ( Minimal_State , Game_Services ) = .{
reset = minimal_reset , update = minimal_update , render = minimal_render ,
} ;
api : HR . API ;
expect ( state , HR . simple_api ( HR . API_VERSION , size_of ( HR . API ) , * api , * hooks ) , "simple_api 失败" ) ;
expect ( state , api . host_version == 1 && api . state_version == 1 , "0 视为 1" ) ;
services : Game_Services ;
ctx := context ;
call := HR . Call .{ host_context = * ctx , services = * services } ;
expect ( state , api . load ( * call , HR . Snapshot .{ } ) , "首次 load 应成功" ) ;
api . update ( * call , 0.1 ) ;
expect ( state , ( cast ( * HR . Simple_Slot ( Minimal_State ) ) call . instance ) . state . count == 2 ,
"reset 的 1 加一次 update，实际 %" ,
( cast ( * HR . Simple_Slot ( Minimal_State ) ) call . instance ) . state . count ) ;
api . unload ( * call ) ;
expect ( state , true , "只有必填回调的模块能走完整个生命周期" ) ;
}

 // hooks 表：同一个 State/Services 组合永远拿到同一份，不同组合彼此独立。
simple_store_keeps_one_table_per_combination :: ( state : * Test_State ) {
game := HR . simple_store ( Game_State , Game_Services , cast ( * void ) * game_hooks ) ;
expect ( state , game != null , "写进表后应能取回" ) ;
again := HR . simple_store ( Game_State , Game_Services ) ;
expect ( state , again == game , "同一组合拿到同一份 hooks" ) ;
other := HR . simple_store ( Minimal_State , Game_Services ) ;
expect ( state , other != game , "不同组合是另一份" ) ;
expect ( state , HR . simple_store ( Minimal_State , Game_Services ) == other , "再次取回仍是同一份" ) ;
}
//@endregion 

// Loop scopes adapted.
