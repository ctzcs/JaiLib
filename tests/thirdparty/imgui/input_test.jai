// Tests/thirdparty/imgui/input_test.jai
// 一比一移植自 olib tests/thirdparty/imgui/imgui_impl_ofoster/input_test.odin（本仓库唯一没搬的
// 第三方测试）。断言顺序、断言语义对位；用例名在 olib 原名基础上补上被验证的契约。
//
// 被测代码：thirdparty/imgui_foster.jai（ImGui → jfoster 后端）+ jacket 自带的 ImGui 模块。
//
// Jai 侧写法差异（只影响测试写法，被验证的行为不变）
//   | olib (Odin, core:testing)                    | 这里 (Jai, Tests/test_support.jai)              |
//   | -------------------------------------------- | ----------------------------------------------- |
//   | testing.expect(t, cond, "msg")                | expect(state, cond, tprint("msg %", v))                 |
//   | testing.expect_value(t, a, b)                 | expect(state, a == b, tprint("msg % %", a, b))          |
//   | @(test) 属性 + 名字                		    | (state: *Test_State) 过程，runner 统一调度       |
//   | `defer release_text_input()`                  | `defer imgui_input_close();`（同为过程作用域）   |
//   | SDL dummy 驱动 + 真窗口					    | 同一个隐藏窗口（SDL_WINDOW_HIDDEN），不建 GPU    |
//
// 为什么要一个隐藏窗口：imgui_foster 的输入路径（imgui_foster_process_input / _new_frame）直接读
// `jfoster.App.window`（window_focused、window_size_in_pixels 都会 assert handle != null），所以
// 「假输入事件序列」需要一个真实但隐藏的 SDL 窗口。ImGui 侧则是纯 headless：CreateContext() + 自己
// 烘一张字体图集（把 TexID 指向图集本身，没有渲染后端会去解引用），帧推进、按键/鼠标/文本事件全走
// ImGui 真实的 event queue（NewFrame 里 UpdateInputEvents），断言读的是 ImGui 自己的状态而不是
// 后端的中间变量。唯一跳过的分支是 update_mouse_cursor：harness 打开 ConfigFlags.NoMouseCursorChange，
// 免得测试去改真实系统光标（同时这条 guard 本身也在 new_frame 用例里被断言）。
//
// 没搬过来的两例（见文件末尾「跳过项」注释）：olib 那两个 @(test) 验证的是 SDL 文本输入会话的
// 归属（set_ime_data / release_text_input / text_input_owned）和 IME 光标矩形（text_input_area），
// 这两个函数在 thirdparty/imgui_foster.jai 里根本不存在（后端还没接 IME / 平台回调），所以没有可
// 断言的被测对象；伪造一份实现再测自己等于什么都验不到。

 #import "Basic" ;
#import "thirdparty/imgui" ;
IMGF :: #import "foster" ;
IF :: #import "thirdparty/imgui/imgui_foster" ;
#import "test_support" ;

 //@region headless harness（隐藏 SDL 窗口 + headless ImGui 上下文）

 // KEY_MAP_SIZE 是从后端借来的常量（512 = SDL scancode 空间）。
IMGUI_INPUT_KEY_MAP_SIZE :: IF . KEY_MAP_SIZE ;

 // 后端 setup_keymap() 写进 key_map 的条目数：字母 26 + 数字 10 + 标点 11（APOSTROPHE COMMA MINUS
// PERIOD SLASH SEMICOLON EQUALS LEFT_BRACKET BACKSLASH RIGHT_BRACKET GRAVE）+ SPACE/ESCAPE/RETURN/
// TAB/BACKSPACE 5 + 编辑与导航 10（INSERT DELETE RIGHT LEFT DOWN UP PAGE_UP PAGE_DOWN HOME END）
// + 锁与系统键 5（CAPS_LOCK SCROLL_LOCK NUM_LOCK PRINT_SCREEN PAUSE）+ 功能键 12 + 修饰键 8
// + 小键盘 16（KP_0..KP_9、KP_PERIOD、KP_DIVIDE、KP_MULTIPLY、KP_MINUS、KP_PLUS、KP_ENTER）= 103。
// olib 的表里还多 .Application->.Menu、.KeypadEquals->.KeypadEqual 与 F13..F24（共 12 条），
// 而 jfoster 的 Keys 里没有这三个成员 —— 见 keymap_leaves_unmapped_scancodes_none 的说明。
IMGUI_INPUT_EXPECTED_MAP_ENTRIES :: 103 ;

 Imgui_Input_Harness :: struct {
window : * IMGF . Window ; // -> imgui_input_window（模块级静态，不 new）
input : IMGF . Input ; // App.input 指向它；测试直接写 State.Keyboard / State.Mouse
context : * ImGuiContext ;
open : bool ;
}

 imgui_input_window : IMGF . Window ;
imgui_input_harness : Imgui_Input_Harness ;

 // 建隐藏窗口 + headless 上下文，并把后端需要的全局（App.window / App.input / App.time）接好。
// 返回 false 只可能是 SDL 建不出窗口（无视频驱动）——调用方打印跳过原因，不假装通过。
imgui_input_open :: ( label : string ) -> bool {
    assert(DOCK_ABI.docking_layout_check(), "ImGui docking ABI mismatch");
    if imgui_input_harness . open return true ;

 if ! IMGF . SDL_Init ( . SDL_INIT_VIDEO ) return false ;

 handle := IMGF . SDL_CreateWindow ( temp_c_string ( label ) , 640 , 480 , . SDL_WINDOW_HIDDEN ) ;
if handle == null {
IMGF . SDL_Quit ( ) ;
return false ;
}

 imgui_input_window = .{ } ;
imgui_input_window . title = label ;
imgui_input_window . handle = handle ;
imgui_input_window . id = cast ( u32 ) IMGF . SDL_GetWindowID ( handle ) ;
imgui_input_harness . window = * imgui_input_window ;
imgui_input_harness . input = .{ } ;
imgui_input_harness . context = CreateContext ( ) ;

 io := GetIO ( ) ;
io . IniFilename = null ; // 测试不写 imgui.ini
io . LogFilename = null ;
// 别让测试碰真实系统光标（这条 guard 在 new_frame 用例里单独断言）。
io . ConfigFlags_ = io . ConfigFlags_ | . NoMouseCursorChange ;

 // 自建字体图集：NewFrame 断言图集已 built。TexID 指向图集自身即可，没有渲染后端会解引用它。
pixels : * u8 ;
width , height : s32 ;
IF . FontAtlas_GetTexDataAsRGBA32 ( io . Fonts , * pixels , * width , * height ) ;
if pixels == null {
imgui_input_close ( ) ;
return false ;
}
io . Fonts . TexID = cast ( * void ) io . Fonts ;

 // 后端读的是 jfoster 的全局 App（setup() 正常由 app_run 填好；这里手工接上）。
IMGF . App . window = imgui_input_harness . window ;
IMGF . App . input = * imgui_input_harness . input ;
IMGF . App . time . elapsed = 0.0 ;

 // 后端的状态跨过程存活（模块全局）：每开一个 harness 都归零，免得上个用例残留。
IF . last_frame_focused = false ;
IF . last_control_pressed = false ;
IF . last_shift_pressed = false ;
IF . last_alt_pressed = false ;
IF . last_super_pressed = false ;
IF . last_render_elapsed = 0.0 ;
IF . current_mouse_cursor = . COUNT ;

 // 与 imgui_foster_setup() 相同的输入侧步骤（少 setup_font_texture：那条要 GPU 设备）。
IF . imgui_initialized = true ;
IF . setup_keymap ( ) ;
IF . setup_backend ( ) ;

 imgui_input_harness . open = true ;
return true ;
}

 imgui_input_close :: ( ) {
if ! imgui_input_harness . open return ;

 IMGF . App . window = null ;
IMGF . App . input = null ;
IF . imgui_initialized = false ;

 if imgui_input_harness . context != null {
DestroyContext ( imgui_input_harness . context ) ;
imgui_input_harness . context = null ;
}
if imgui_input_window . handle != null {
IMGF . SDL_DestroyWindow ( imgui_input_window . handle ) ;
imgui_input_window . handle = null ;
}
IMGF . SDL_Quit ( ) ;
imgui_input_harness . open = false ;
}

 // 一个后端 step：先投递本 step 的假输入，再开帧；观察完用 imgui_input_frame_end 收帧。
imgui_input_frame_begin :: ( ) {
IF . imgui_foster_process_input ( ) ;
IF . imgui_foster_new_frame ( ) ;
}

 imgui_input_frame_end :: ( ) {
Render ( ) ;
}

 imgui_input_keyboard :: ( ) -> * IMGF . Keyboard_State { return IMGF . input_keyboard ( * imgui_input_harness . input ) ; }
imgui_input_mouse :: ( ) -> * IMGF . Mouse_State { return IMGF . input_mouse ( * imgui_input_harness . input ) ; }

 // 模拟 jfoster 的键盘一步：按下 = down + pressed，松开 = released（down 由调用方维护）。
imgui_input_key_press :: ( key : IMGF . Keys ) {
kb := imgui_input_keyboard ( ) ;
kb . down [ cast ( s32 ) key ] = true ;
kb . pressed [ cast ( s32 ) key ] = true ;
kb . released [ cast ( s32 ) key ] = false ;
}

 imgui_input_key_release :: ( key : IMGF . Keys ) {
kb := imgui_input_keyboard ( ) ;
kb . down [ cast ( s32 ) key ] = false ;
kb . pressed [ cast ( s32 ) key ] = false ;
kb . released [ cast ( s32 ) key ] = true ;
}

 // 清掉 pressed/released（jfoster 的 keyboard_state_step 每帧做的事），down 保持不变。
imgui_input_keys_step :: ( ) {
kb := imgui_input_keyboard ( ) ;
for * p , i : kb . pressed p .* = false ;
for * r , i : kb . released r .* = false ;
}

 imgui_input_mouse_press :: ( button : IMGF . Mouse_Buttons ) {
m := imgui_input_mouse ( ) ;
m . down [ cast ( s32 ) button ] = true ;
m . pressed [ cast ( s32 ) button ] = true ;
m . released [ cast ( s32 ) button ] = false ;
}

 imgui_input_mouse_release :: ( button : IMGF . Mouse_Buttons ) {
m := imgui_input_mouse ( ) ;
m . down [ cast ( s32 ) button ] = false ;
m . pressed [ cast ( s32 ) button ] = false ;
m . released [ cast ( s32 ) button ] = true ;
}

 imgui_input_mouse_step :: ( ) {
m := imgui_input_mouse ( ) ;
for * p , i : m . pressed p .* = false ;
for * r , i : m . released r .* = false ;
}

 // `*u8`（ImGui 的 *char 字段）与 Jai string 逐字节比较：不分配、不依赖 `%s`（运行期会崩）。
imgui_c_string_equals :: ( text : * u8 , expected : string ) -> bool {
if text == null return false ;
for i : 0 .. expected . count - 1 {
if text [ i ] != expected [ i ] return false ;
}
return text [ expected . count ] == 0 ;
}

 //@endregion

 //@region SDL scancode -> ImGui Key 映射表

 // key_map[scancode] 断言；scancode 直接用数字（表就是按 SDL scancode 下标索引的）。
// 消息里带上组名，失败时一眼看出断的是哪一段映射。
imgui_input_expect_map :: ( state : * Test_State , scancode : s64 , want : Key , group : string ) {
got := IF . key_map [ scancode ] ;
expect ( state , got == want , tprint ( "key_map[%] (%): got % want %" , scancode , group , cast ( s32 ) got , cast ( s32 ) want ) ) ;
}

 imgui_input_expect_map_none :: ( state : * Test_State , scancode : s64 , group : string ) {
got := IF . key_map [ scancode ] ;
expect ( state , got == . None , tprint ( "key_map[%] (%): got % want None (unmapped)" , scancode , group , cast ( s32 ) got ) ) ;
}

 // 字母 A..Z、数字 1..9/0、标点：SDL scancode 与 ImGui Key 都不是同一套编号，逐条钉死。
keymap_maps_letters_digits_and_punctuation :: ( state : * Test_State ) {
IF . setup_keymap ( ) ;

 // 字母：SDL 4..29 连续，ImGui Key.A..Z 连续。
for i : 0 .. 25 {
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . A + i ,
cast ( Key ) ( cast ( s32 ) Key . A + i ) , "letters A..Z" ) ;
}

 // 数字 1..9：SDL 30..38 -> ImGui _1(537).._9(545)。
for i : 0 .. 8 {
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . NUM_1 + i ,
cast ( Key ) ( cast ( s32 ) Key . _1 + i ) , "digits 1..9" ) ;
}
// 数字 0 在 SDL 里排在 9 之后（39），ImGui 里排在 1 之前（536）——顺序不同，单独钉。
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . NUM_0 , . _0 , "digit 0" ) ;

 // 标点：负数用 Main 键盘区，映射到同名 ImGui Key（Equals -> Equal，Grave -> GraveAccent）。
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . APOSTROPHE , . Apostrophe , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . COMMA , . Comma , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . MINUS , . Minus , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . PERIOD , . Period , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . SLASH , . Slash , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . SEMICOLON , . Semicolon , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . EQUALS , . Equal , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . LEFT_BRACKET , . LeftBracket , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . BACKSLASH , . Backslash , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . RIGHT_BRACKET , . RightBracket , "punctuation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . GRAVE , . GraveAccent , "punctuation" ) ;
}

 // 控制键、编辑键、导航键：名字完全不同的（RETURN -> Enter、RIGHT -> RightArrow）最容易写错。
keymap_maps_control_navigation_and_editing_keys :: ( state : * Test_State ) {
IF . setup_keymap ( ) ;

 imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . ESCAPE , . Escape , "control" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . RETURN , . Enter , "control" ) ; // RETURN != Return
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . TAB , . Tab , "control" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . BACKSPACE , . Backspace , "editing" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . SPACE , . Space , "control" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . INSERT , . Insert , "editing" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . DELETE , . Delete , "editing" ) ;

 imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . RIGHT , . RightArrow , "navigation" ) ; // 不是 .Right
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . LEFT , . LeftArrow , "navigation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . DOWN , . DownArrow , "navigation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . UP , . UpArrow , "navigation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . HOME , . Home , "navigation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . END , . End , "navigation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . PAGE_UP , . PageUp , "navigation" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . PAGE_DOWN , . PageDown , "navigation" ) ;

 imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . CAPS_LOCK , . CapsLock , "locks" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . SCROLL_LOCK , . ScrollLock , "locks" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . NUM_LOCK , . NumLock , "locks" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . PRINT_SCREEN , . PrintScreen , "locks" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . PAUSE , . Pause , "locks" ) ;
}

 // 功能键 F1..F12 与小键盘：F1..F12 两侧连续偏移一致；小键盘 0/1..9 两侧顺序不同，
// 而且 +/-, *, / 映射到 ImGui 的 KeypadAdd/Subtract/Multiply/Divide（名字完全不同）。
keymap_maps_function_keys_and_keypad :: ( state : * Test_State ) {
IF . setup_keymap ( ) ;

 for i : 0 .. 11 {
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . F1 + i ,
cast ( Key ) ( cast ( s32 ) Key . F1 + i ) , "function keys F1..F12" ) ;
}

 // SDL KP_1..KP_9 = 89..97，ImGui Keypad1..9 = 601..609。
for i : 0 .. 8 {
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . KP_1 + i ,
cast ( Key ) ( cast ( s32 ) Key . Keypad1 + i ) , "keypad 1..9" ) ;
}
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . KP_0 , . Keypad0 , "keypad 0" ) ;

 imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . KP_PERIOD , . KeypadDecimal , "keypad ops" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . KP_DIVIDE , . KeypadDivide , "keypad ops" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . KP_MULTIPLY , . KeypadMultiply , "keypad ops" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . KP_MINUS , . KeypadSubtract , "keypad ops" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . KP_PLUS , . KeypadAdd , "keypad ops" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . KP_ENTER , . KeypadEnter , "keypad ops" ) ;
}

 // 修饰键：左右两侧必须是两个不同的 ImGui Key（ImGui 靠它们自己合并 ImGuiMod_*），
// 而且不能把左右任何一侧漏成 None（漏了 = 那一侧按下去永远不会触发快捷键）。
keymap_maps_modifiers_to_both_sides :: ( state : * Test_State ) {
IF . setup_keymap ( ) ;

 imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . LEFT_CONTROL , . LeftCtrl , "modifiers" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . RIGHT_CONTROL , . RightCtrl , "modifiers" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . LEFT_SHIFT , . LeftShift , "modifiers" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . RIGHT_SHIFT , . RightShift , "modifiers" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . LEFT_ALT , . LeftAlt , "modifiers" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . RIGHT_ALT , . RightAlt , "modifiers" ) ;
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . LEFT_OS , . LeftSuper , "modifiers" ) ; // OS = Win 键
imgui_input_expect_map ( state , cast ( s64 ) IMGF . Keys . RIGHT_OS , . RightSuper , "modifiers" ) ;

 // 左右互不相同（写错成同一个是这类表最常见的复制粘贴 bug）。
expect ( state , IF . key_map [ cast ( s64 ) IMGF . Keys . LEFT_CONTROL ] != IF . key_map [ cast ( s64 ) IMGF . Keys . RIGHT_CONTROL ] ,
"left/right ctrl map to different ImGui keys" ) ;
expect ( state , IF . key_map [ cast ( s64 ) IMGF . Keys . LEFT_SHIFT ] != IF . key_map [ cast ( s64 ) IMGF . Keys . RIGHT_SHIFT ] ,
"left/right shift map to different ImGui keys" ) ;
expect ( state , IF . key_map [ cast ( s64 ) IMGF . Keys . LEFT_ALT ] != IF . key_map [ cast ( s64 ) IMGF . Keys . RIGHT_ALT ] ,
"left/right alt map to different ImGui keys" ) ;
expect ( state , IF . key_map [ cast ( s64 ) IMGF . Keys . LEFT_OS ] != IF . key_map [ cast ( s64 ) IMGF . Keys . RIGHT_OS ] ,
"left/right super map to different ImGui keys" ) ;
}

 // 没映射的 scancode 必须是 .None（后端靠它跳过枚举空洞，不能随便落到某个 Key 上）。
keymap_leaves_unmapped_scancodes_none :: ( state : * Test_State ) {
IF . setup_keymap ( ) ;

 // 0 = SDL_SCANCODE_UNKNOWN。
imgui_input_expect_map_none ( state , 0 , "unknown scancode" ) ;
// 50 = SDL_SCANCODE_NONUSHASH（jfoster 的 Keys 里没有这个成员，后端也没映射）。
imgui_input_expect_map_none ( state , 50 , "non-US hash" ) ;
// 103 = SDL_SCANCODE_KP_EQUALS：ImGui 有 KeypadEqual，但 jfoster 的 Keys 没有 KP_EQUALS，
// 后端就没法映射 —— 这里是「olib 有、本仓库缺」的那条（olib 的 key_map 里 .KeypadEquals -> .KeypadEqual）。
imgui_input_expect_map_none ( state , 103 , "keypad equals (not portable: jfoster has no KP_EQUALS)" ) ;
// 小键盘逗号附近 / 应用键（SDL_SCANCODE_APPLICATION = 101）、电源键（102）：都没映射。
imgui_input_expect_map_none ( state , 101 , "application/menu key (olib maps it to .Menu)" ) ;
imgui_input_expect_map_none ( state , 102 , "power key" ) ;
// F13..F24（SDL 104..115）：ImGui 有 Key.F13..F24，jfoster 的 Keys 到 F12 就停了。
imgui_input_expect_map_none ( state , 104 , "F13 (not portable: jfoster has no F13)" ) ;
imgui_input_expect_map_none ( state , 115 , "F24 (not portable: jfoster has no F24)" ) ;
// 100..127 里的空洞、以及 232..510（最后一个有名字的 scancode 是 231 = RIGHT_OS）。
imgui_input_expect_map_none ( state , 105 , "scancode gap" ) ;
imgui_input_expect_map_none ( state , 200 , "scancode gap" ) ;
imgui_input_expect_map_none ( state , 232 , "just past the last named scancode" ) ;
imgui_input_expect_map_none ( state , 300 , "SDL keycode space, not scancodes" ) ;
// 边界：表尾最后一个下标（512 个元素，0..511）。写出 512 就是越界读。
imgui_input_expect_map_none ( state , IMGUI_INPUT_KEY_MAP_SIZE - 1 , "last table slot" ) ;
}

 // 表是按 SDL *scancode* 索引的（不是 keycode）：97 是 keycode 'a'，若按 keycode 建表就会命中；
// 49 是 scancode BACKSLASH，若按 keycode 建表则 '1'(49) 会命中 —— 两个方向都能区分开。
// 同时统计条目总数 + 无重复 + 全部落在 ImGui 的具名键区间（不能是 ImGuiMod_* 那种 4096）。
keymap_table_is_scancode_indexed_and_within_bounds :: ( state : * Test_State ) {
IF . setup_keymap ( ) ;

 imgui_input_expect_map ( state , 4 , . A , "scancode 4 is A" ) ;
imgui_input_expect_map ( state , 30 , . _1 , "scancode 30 is 1" ) ;
imgui_input_expect_map ( state , 49 , . Backslash , "scancode 49 is backslash (keycode 49 would be '1')" ) ;
// 反证：SDL *keycode* 'a' = 97，而 97 在 scancode 空间是 KP_9 —— 表里必须是 Keypad9。
// 如果谁把表改成按 keycode 索引，这一条和上面的 4/_1 会同时炸。
imgui_input_expect_map ( state , 97 , . Keypad9 , "scancode 97 is KP_9 (keycode 'a' is not used as an index)" ) ;
// keycode 'z' = 122 在 scancode 空间没有名字，必须是空的。
imgui_input_expect_map_none ( state , 122 , "keycode 'z' is not a scancode" ) ;

 // setup_keymap() 是纯赋值（直接写 key_map 本体，不是副本），重复调用必须幂等。
count_first := 0 ;
for i : 0 .. IMGUI_INPUT_KEY_MAP_SIZE - 1 if IF . key_map [ i ] != . None count_first += 1 ;
IF . setup_keymap ( ) ;
count_second := 0 ;
for i : 0 .. IMGUI_INPUT_KEY_MAP_SIZE - 1 if IF . key_map [ i ] != . None count_second += 1 ;
expect ( state , count_first == count_second , tprint ( "setup_keymap is idempotent (% then %)" , count_first , count_second ) ) ;

 mapped : [ IMGUI_INPUT_KEY_MAP_SIZE ] Key ;
count := 0 ;
for i : 0 .. IMGUI_INPUT_KEY_MAP_SIZE - 1 {
if IF . key_map [ i ] == . None continue ;
mapped [ count ] = IF . key_map [ i ] ;
count += 1 ;
}
expect ( state , count == IMGUI_INPUT_EXPECTED_MAP_ENTRIES , tprint ( "key_map has % mapped scancodes, expected %" , count , IMGUI_INPUT_EXPECTED_MAP_ENTRIES ) ) ;
expect ( state , count <= IMGUI_INPUT_KEY_MAP_SIZE , "mapped count fits the table" ) ;

 duplicates := 0 ;
for i : 0 .. count - 1 {
for j : i + 1 .. count - 1 {
if mapped [ i ] == mapped [ j ] duplicates += 1 ;
}
}
expect ( state , duplicates == 0 , tprint ( "no two scancodes share one ImGui key (% duplicates)" , duplicates ) ) ;

 // 映射目标必须是「具名键」：要么 None，要么 >= Key.Tab(512) 且 < Key.COUNT(652)。
// 落到 ImGuiMod_Ctrl(4096) 之类会编译得过、但 ImGui 当不了普通键按。
out_of_range := 0 ;
for i : 0 .. count - 1 {
value := cast ( s32 ) mapped [ i ] ;
if value < cast ( s32 ) Key . Tab || value >= cast ( s32 ) Key . COUNT out_of_range += 1 ;
}
expect ( state , out_of_range == 0 , tprint ( "% mapped keys are outside [Key.Tab, Key.COUNT)" , out_of_range ) ) ;
}

 //@endregion

 //@region 后端接线与帧推进

 // setup_backend()：平台名、光标能力标志、剪贴板回调、鼠标初值（olib 的 setup_platform_io 同款接线）。
backend_setup_wires_platform_name_flags_and_clipboard :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui backend setup" ) {
print ( "  [skip] backend_setup...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 io := GetIO ( ) ;
expect ( state , io . BackendPlatformName != null , "BackendPlatformName is set" ) ;
expect ( state , imgui_c_string_equals ( io . BackendPlatformName , "imgui_impl_foster" ) ,
"BackendPlatformName is imgui_impl_foster" ) ;
expect ( state , ( io . BackendFlags_ & . HasMouseCursors ) != 0 , "BackendFlags has HasMouseCursors" ) ;
expect ( state , io . SetClipboardTextFn != null , "SetClipboardTextFn is installed" ) ;
expect ( state , io . GetClipboardTextFn != null , "GetClipboardTextFn is installed" ) ;
expect ( state , io . MousePos . x == 0.0 && io . MousePos . y == 0.0 , "MousePos starts at 0,0" ) ;

 // imgui_foster_setup() 会给窗口开文本输入（Keyboard_State.Text 的前提）；这里不做（要 GPU），
// 但 setup_keymap()/setup_backend() 这两步已经在 open 里跑过，上面的断言就是它们的效果。
expect ( state , IMGF . App . window != null , "backend reads App.window" ) ;
}

 // 帧推进：DisplaySize 跟窗口像素尺寸一致、FramebufferScale 恒为 1,1、DeltaTime 只吃正向增量
// （与 olib 的 NewFrame 用 force_focus/display_size 手工喂一个道理，只是这里读真实窗口）。
new_frame_mirrors_window_pixel_size_and_delta_time :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui frame advance" ) {
print ( "  [skip] new_frame...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 io := GetIO ( ) ;
pixels := IMGF . window_size_in_pixels ( imgui_input_harness . window ) ;
expect ( state , pixels . x > 0 && pixels . y > 0 , tprint ( "hidden window reports a pixel size (%x%)" , pixels . x , pixels . y ) ) ;

 IMGF . App . time . elapsed = 0.5 ;
imgui_input_frame_begin ( ) ;
expect ( state , io . DisplaySize . x == cast ( float ) pixels . x && io . DisplaySize . y == cast ( float ) pixels . y , tprint ( "DisplaySize = window pixel size, got % want %x%" , io . DisplaySize , pixels . x , pixels . y ) ) ;
expect ( state , io . DisplayFramebufferScale . x == 1.0 && io . DisplayFramebufferScale . y == 1.0 , tprint ( "DisplayFramebufferScale is 1,1 (jfoster draws in physical pixels), got %" , io . DisplayFramebufferScale ) ) ;
expect ( state , io . DeltaTime == 0.5 , tprint ( "first frame DeltaTime = elapsed, got %" , io . DeltaTime ) ) ;
// NoMouseCursorChange 短接了 update_mouse_cursor：current_mouse_cursor 原地不动（.COUNT 初值）。
expect ( state , IF . current_mouse_cursor == . COUNT ,
"update_mouse_cursor is short-circuited by NoMouseCursorChange" ) ;
imgui_input_frame_end ( ) ;

 IMGF . App . time . elapsed = 0.75 ;
imgui_input_frame_begin ( ) ;
expect ( state , io . DeltaTime == 0.25 , tprint ( "DeltaTime is the elapsed delta, got %" , io . DeltaTime ) ) ;
imgui_input_frame_end ( ) ;

 // 时间没往前走（同一 step 被重复调用）时保留上一次的 DeltaTime，不会塞 0 进去。
imgui_input_frame_begin ( ) ;
expect ( state , io . DeltaTime == 0.25 , tprint ( "non-positive delta keeps the previous DeltaTime, got %" , io . DeltaTime ) ) ;
imgui_input_frame_end ( ) ;

 // 焦点：后端轮询 window_focused，只在「和上一帧不同」时发 AddFocusEvent。隐藏窗口从来
// 不聚焦，所以 last_frame_focused 一直是 false；把上一帧伪造成已聚焦后，下一 step 必须走
// 那个分支并把它同步回来（真实焦点切换要显示窗口，会弹窗，这里不碰）。
expect ( state , ! IMGF . window_focused ( imgui_input_harness . window ) , "hidden window reports no focus" ) ;
expect ( state , ! IF . last_frame_focused , "process_input recorded the unfocused state" ) ;
IF . last_frame_focused = true ;
imgui_input_frame_begin ( ) ;
expect ( state , ! IF . last_frame_focused , "the focus-transition branch runs and resyncs last_frame_focused" ) ;
imgui_input_frame_end ( ) ;
}

 //@endregion

 //@region 键盘事件：按下 / 保持 / 松开，以及「一步内按下又松开」

 // scancode -> ImGui Key -> io.KeysDown 的整条链：后端每 step 只发变化，ImGui 在 NewFrame 里消费。
key_events_report_down_pressed_and_released :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui key events" ) {
print ( "  [skip] key_events...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 imgui_input_key_press ( IMGF . Keys . A ) ;
imgui_input_frame_begin ( ) ;
expect ( state , IsKeyDown ( . A ) , "press: IsKeyDown(A)" ) ;
expect ( state , IsKeyPressed ( . A ) , "press: IsKeyPressed(A)" ) ;
expect ( state , ! IsKeyReleased ( . A ) , "press: not released" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 // 持续按住：down 保持，pressed 只在第一帧为真（后端只在变化时发事件）。
imgui_input_frame_begin ( ) ;
expect ( state , IsKeyDown ( . A ) , "hold: IsKeyDown(A)" ) ;
expect ( state , ! IsKeyPressed ( . A ) , "hold: IsKeyPressed(A) is false" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 imgui_input_key_release ( IMGF . Keys . A ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! IsKeyDown ( . A ) , "release: IsKeyDown(A) is false" ) ;
expect ( state , IsKeyReleased ( . A ) , "release: IsKeyReleased(A)" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 imgui_input_frame_begin ( ) ;
expect ( state , ! IsKeyReleased ( . A ) , "next frame: released clears" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 // 没映射的 scancode 即使按住也不会进 ImGui（枚举空洞不会误触某个 Key）。
kb := imgui_input_keyboard ( ) ;
kb . down [ cast ( s32 ) IMGF . Keys . RIGHT_OS + 1 ] = true ; // 232：表里没有映射
imgui_input_frame_begin ( ) ;
expect ( state , ! IsKeyDown ( . LeftSuper ) && ! IsKeyDown ( . RightSuper ) ,
"unmapped scancode does not touch ImGui keys" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;
kb . down [ cast ( s32 ) IMGF . Keys . RIGHT_OS + 1 ] = false ;
}

 // 回归：同一 step 内按下又松开（快速点按 / 帧卡顿）时后端必须先发 down 再发 up。
// 旧写法 `if pressed { down } else if released { up }` 会吞掉 up，ImGui 认为键一直按着
// （连按 Backspace 删到只剩一个字符就是这个症状）。
//
// 时序说明：ImGui 默认 ConfigInputTrickleEventQueue = true，同一帧里成对的 down+up 会被它拆到
// 相邻两帧（先让宿主看到 pressed，再让宿主看到 released）。所以这里的契约是：
//   第 1 帧 —— pressed 可见（按下没被吞掉）；第 2 帧 —— released 可见且键已抬起。
// 用 else if 吞掉 up 的写法会让第 2 帧 IsKeyDown 仍然为真（键卡死），这两条断言就是钉它的。
press_and_release_in_one_step_does_not_stick :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui key press+release in one step" ) {
print ( "  [skip] press_and_release...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 kb := imgui_input_keyboard ( ) ;
kb . down [ cast ( s32 ) IMGF . Keys . B ] = false ;
kb . pressed [ cast ( s32 ) IMGF . Keys . B ] = true ;
kb . released [ cast ( s32 ) IMGF . Keys . B ] = true ;

 imgui_input_frame_begin ( ) ;
expect ( state , IsKeyPressed ( . B ) , "press+release in one step: the press is not swallowed by the release" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 // 第 2 帧：up 到了，键不能还按着（这一条就是「卡键」回归）。
imgui_input_frame_begin ( ) ;
expect ( state , ! IsKeyDown ( . B ) , "press+release in one step: the key is up on the next frame (no stuck key)" ) ;
expect ( state , IsKeyReleased ( . B ) , "press+release in one step: the release is delivered on the next frame" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 imgui_input_frame_begin ( ) ;
expect ( state , ! IsKeyDown ( . B ) , "press+release in one step: the key stays up" ) ;
expect ( state , ! IsKeyReleased ( . B ) , "press+release in one step: the release flag clears" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;
}

 //@endregion

 //@region 修饰键与快捷键

 // 左右两侧各自成键，合并后的 io.KeyCtrl/KeyShift/KeyAlt/KeySuper 只有一侧按住也要为真
// （后端每 step 发 ImGuiMod_* 的聚合事件，靠的就是这里）。
modifier_events_feed_left_right_and_aggregate_flags :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui modifiers" ) {
print ( "  [skip] modifier_events...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 io := GetIO ( ) ;

 // 右侧 Shift：RightShift 为真、LeftShift 为假，聚合 KeyShift 为真。
imgui_input_key_press ( IMGF . Keys . RIGHT_SHIFT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , IsKeyDown ( . RightShift ) , "RightShift reaches ImGui as RightShift" ) ;
expect ( state , ! IsKeyDown ( . LeftShift ) , "right shift does not set LeftShift" ) ;
expect ( state , io . KeyShift , "right shift sets the aggregate io.KeyShift" ) ;
expect ( state , ! io . KeyCtrl && ! io . KeyAlt && ! io . KeySuper , "only shift is aggregated" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 imgui_input_key_release ( IMGF . Keys . RIGHT_SHIFT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . KeyShift , "releasing right shift clears the aggregate" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 // 右侧 Ctrl 同样能撑起聚合标志（只看左侧的实现会漏掉这一半）。
imgui_input_key_press ( IMGF . Keys . RIGHT_CONTROL ) ;
imgui_input_frame_begin ( ) ;
expect ( state , IsKeyDown ( . RightCtrl ) , "RightCtrl reaches ImGui as RightCtrl" ) ;
expect ( state , ! IsKeyDown ( . LeftCtrl ) , "right ctrl does not set LeftCtrl" ) ;
expect ( state , io . KeyCtrl , "right ctrl sets the aggregate io.KeyCtrl" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;
imgui_input_key_release ( IMGF . Keys . RIGHT_CONTROL ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . KeyCtrl , "releasing right ctrl clears the aggregate" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 // 左侧 Alt / 左侧 Super（SDL 里叫 OS 键）。
imgui_input_key_press ( IMGF . Keys . LEFT_ALT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , IsKeyDown ( . LeftAlt ) , "LeftAlt reaches ImGui as LeftAlt" ) ;
expect ( state , io . KeyAlt , "left alt sets the aggregate io.KeyAlt" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;
imgui_input_key_release ( IMGF . Keys . LEFT_ALT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . KeyAlt , "releasing left alt clears the aggregate" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 imgui_input_key_press ( IMGF . Keys . LEFT_OS ) ;
imgui_input_frame_begin ( ) ;
expect ( state , IsKeyDown ( . LeftSuper ) , "LeftOS reaches ImGui as LeftSuper" ) ;
expect ( state , io . KeySuper , "left super sets the aggregate io.KeySuper" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;
imgui_input_key_release ( IMGF . Keys . LEFT_OS ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . KeySuper , "releasing left super clears the aggregate" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 // 两侧同时按住、松开一侧：聚合标志必须还立着（后端发的是聚合值的电平）。
imgui_input_key_press ( IMGF . Keys . LEFT_SHIFT ) ;
imgui_input_key_press ( IMGF . Keys . RIGHT_SHIFT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . KeyShift , "both shifts down" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 imgui_input_key_release ( IMGF . Keys . LEFT_SHIFT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . KeyShift , "releasing only left shift keeps io.KeyShift (right still held)" ) ;
expect ( state , IsKeyDown ( . RightShift ) && ! IsKeyDown ( . LeftShift ) , "right shift still down" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 imgui_input_key_release ( IMGF . Keys . RIGHT_SHIFT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . KeyShift , "releasing the last shift clears io.KeyShift" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;
}

 // 「快捷键入的构造」：Ctrl+S 这种组合，用后端投递的事件应当能在同一帧里同时看到
// 聚合修饰键与目标键的 pressed —— 这是 ImGui 1.89 里写快捷键的既有做法
// （jacket 的 ImGui 模块是 1.89.6，还没有 ImGuiKeyChord 版的 Shortcut/IsKeyChordPressed）。
ctrl_plus_key_builds_a_shortcut :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui ctrl+s shortcut" ) {
print ( "  [skip] ctrl_plus_key...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 io := GetIO ( ) ;

 imgui_input_key_press ( IMGF . Keys . LEFT_CONTROL ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . KeyCtrl , "ctrl frame: io.KeyCtrl" ) ;
expect ( state , ! IsKeyPressed ( . S ) , "ctrl frame: S not pressed yet" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 // Ctrl 保持按住，按下 S：同一帧里 KeyCtrl + IsKeyPressed(S) 同时为真。
imgui_input_key_press ( IMGF . Keys . S ) ;
imgui_input_frame_begin ( ) ;
shortcut := io . KeyCtrl && IsKeyPressed ( . S ) ;
expect ( state , shortcut , tprint ( "ctrl+S shortcut fires (KeyCtrl=% KeyS=% S pressed=% ...)" , io . KeyCtrl , IsKeyDown ( . S ) , IsKeyPressed ( . S ) ) ) ;
expect ( state , IsKeyDown ( . LeftCtrl ) , "the individual LeftCtrl key is still down too" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 // 松开 Ctrl 后 S 仍按着，但快捷键不再重复触发。
imgui_input_key_release ( IMGF . Keys . LEFT_CONTROL ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . KeyCtrl , "ctrl released: io.KeyCtrl false" ) ;
expect ( state , IsKeyDown ( . S ) , "S is still held" ) ;
expect ( state , ! IsKeyPressed ( . S ) , "S is not pressed again while held (no repeat" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;

 imgui_input_key_release ( IMGF . Keys . S ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! IsKeyDown ( . S ) , "S released" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;
}

 //@endregion

 //@region 文本输入

 // jfoster 把本 step 的 UTF-8 文本累积在 Keyboard_State.Text 里；后端按码点逐个
// AddInputCharacter（这里只验投递，InputText 控件本身不属于本后端的职责）。
text_input_becomes_utf8_codepoints :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui text input" ) {
print ( "  [skip] text_input...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 io := GetIO ( ) ;
kb := imgui_input_keyboard ( ) ;
append ( * kb . Text , "abc 中" ) ;

 imgui_input_frame_begin ( ) ;
expect ( state , io . InputQueueCharacters . Size == 5 , tprint ( "\"abc 中\" queues 5 codepoints, got %" , io . InputQueueCharacters . Size ) ) ;
if io . InputQueueCharacters . Size == 5 {
expect ( state , cast ( s32 ) io . InputQueueCharacters . Data [ 0 ] == 97 , "codepoint 0 = 'a' (97)" ) ;
expect ( state , cast ( s32 ) io . InputQueueCharacters . Data [ 1 ] == 98 , "codepoint 1 = 'b' (98)" ) ;
expect ( state , cast ( s32 ) io . InputQueueCharacters . Data [ 2 ] == 99 , "codepoint 2 = 'c' (99)" ) ;
expect ( state , cast ( s32 ) io . InputQueueCharacters . Data [ 3 ] == 32 , "codepoint 3 = ' ' (32)" ) ;
// 中文是 3 字节 UTF-8；后端历史上在这里踩过「先在 u8 上移位再 cast」的坑，
// 解出来的码点会变成低字节垃圾（输入不了中文的根因）。
expect ( state , cast ( s32 ) io . InputQueueCharacters . Data [ 4 ] == 0x4E2D , tprint ( "codepoint 4 = U+4E2D (中), got 0x%" , cast ( s32 ) io . InputQueueCharacters . Data [ 4 ] ) ) ;
}
imgui_input_frame_end ( ) ;

 // 没有新文本的 step 不投递任何字符。
imgui_input_frame_begin ( ) ;
expect ( state , io . InputQueueCharacters . Size == 0 , tprint ( "empty text queues no codepoints, got %" , io . InputQueueCharacters . Size ) ) ;
imgui_input_frame_end ( ) ;

 // 混合串：ASCII + 2 字节 + 3 字节，逐码点按顺序投递。
append ( * kb . Text , "é中x" ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . InputQueueCharacters . Size == 3 , tprint ( "3 codepoints for \"é中x\", got %" , io . InputQueueCharacters . Size ) ) ;
if io . InputQueueCharacters . Size == 3 {
expect ( state , cast ( s32 ) io . InputQueueCharacters . Data [ 0 ] == 0xE9 , "codepoint 0 = U+00E9 (é)" ) ;
expect ( state , cast ( s32 ) io . InputQueueCharacters . Data [ 1 ] == 0x4E2D , "codepoint 1 = U+4E2D (中)" ) ;
expect ( state , cast ( s32 ) io . InputQueueCharacters . Data [ 2 ] == 120 , "codepoint 2 = 'x' (120)" ) ;
}
imgui_input_frame_end ( ) ;
}

 // 非法字节（孤立续接字节 0x80）解出码点 0，后端用 `if cp > 0` 把它挡在 ImGui 之外
// （否则 ImGui 会收到 U+0000 这种控制字符）。
invalid_utf8_queues_no_character :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui invalid utf8" ) {
print ( "  [skip] invalid_utf8...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 io := GetIO ( ) ;
kb := imgui_input_keyboard ( ) ;
append ( * kb . Text , "\x80" ) ;

 imgui_input_frame_begin ( ) ;
expect ( state , io . InputQueueCharacters . Size == 0 , tprint ( "a lone continuation byte queues nothing, got % codepoints" , io . InputQueueCharacters . Size ) ) ;
imgui_input_frame_end ( ) ;
}

 //@endregion

 //@region 鼠标

 // 鼠标按键索引：jfoster 的 Mouse_Buttons 是 NONE/LEFT/MIDDLE/RIGHT/X1/X2 = 0..5，
// ImGui 的鼠标键是 Left/Right/Middle = 0/1/2（没有 X1/X2 的常量名，但数组有 5 格）。
// 后端按调用点显式换算，这里钉住换算结果（写反 Middle/RIGHT 是这类桥最典型的 bug）。
mouse_buttons_position_and_wheel_reach_imgui :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui mouse" ) {
print ( "  [skip] mouse_buttons...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 io := GetIO ( ) ;

 // ImGui 的 0 = 左键：jfoster 的 LEFT 是 1，不是 0 —— 直接把 jfoster 的下标当 ImGui 下标用就会错位。
expect ( state , cast ( s32 ) IMGF . Mouse_Buttons . LEFT == 1 ,
"jfoster LEFT is 1 (so it cannot be forwarded raw as ImGui button index)" ) ;
expect ( state , cast ( s32 ) IMGF . Mouse_Buttons . MIDDLE == 2 && cast ( s32 ) IMGF . Mouse_Buttons . RIGHT == 3 ,
"jfoster MIDDLE=2 RIGHT=3 (swapped relative to ImGui's Right=1/Middle=2)" ) ;

 m := imgui_input_mouse ( ) ;
m . Position = .{ 100.0 , 200.0 } ;
imgui_input_mouse_press ( IMGF . Mouse_Buttons . LEFT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . MousePos . x == 100.0 && io . MousePos . y == 200.0 , tprint ( "MousePos follows jfoster's pointer, got %" , io . MousePos ) ) ;
expect ( state , io . MouseDown [ 0 ] , "left button -> ImGui button 0 (MouseDown[0])" ) ;
expect ( state , ! io . MouseDown [ 1 ] , "left button must not set ImGui button 1 (right)" ) ;
expect ( state , ! io . MouseDown [ 2 ] , "left button must not set ImGui button 2 (middle)" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;

 // 滚轮单独一步：ImGui 默认 ConfigInputTrickleEventQueue=true，会把「同一批里的按键变化」和
// 「滚轮」拆到相邻两帧（先按键后滚轮）。只投递滚轮（没有按键变化）时它当帧生效。
m . WheelValue = .{ 1.0 , 2.0 } ;
imgui_input_frame_begin ( ) ;
expect ( state , io . MouseWheel == 2.0 , tprint ( "vertical wheel -> MouseWheel, got %" , io . MouseWheel ) ) ;
expect ( state , io . MouseWheelH == 1.0 , tprint ( "horizontal wheel -> MouseWheelH, got %" , io . MouseWheelH ) ) ;
imgui_input_frame_end ( ) ;
m . WheelValue = .{ 0.0 , 0.0 } ;

 // 释放：down 归零，且没有滚轮事件时 MouseWheel 保持 0（ImGui 在 EndFrame 清它）。
imgui_input_mouse_release ( IMGF . Mouse_Buttons . LEFT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . MouseDown [ 0 ] , "left button released" ) ;
expect ( state , io . MouseWheel == 0.0 , "no wheel event when jfoster reports 0" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;

 // 右键 -> ImGui button 1、中键 -> ImGui button 2（顺序与 jfoster 的 MIDDLE=2/RIGHT=3 相反）。
imgui_input_mouse_press ( IMGF . Mouse_Buttons . RIGHT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . MouseDown [ 1 ] , "jfoster RIGHT -> ImGui button 1" ) ;
expect ( state , ! io . MouseDown [ 2 ] , "jfoster RIGHT must not land on ImGui button 2" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;
imgui_input_mouse_release ( IMGF . Mouse_Buttons . RIGHT ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . MouseDown [ 1 ] , "right button released" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;

 imgui_input_mouse_press ( IMGF . Mouse_Buttons . MIDDLE ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . MouseDown [ 2 ] , "jfoster MIDDLE -> ImGui button 2" ) ;
expect ( state , ! io . MouseDown [ 1 ] , "jfoster MIDDLE must not land on ImGui button 1" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;
imgui_input_mouse_release ( IMGF . Mouse_Buttons . MIDDLE ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . MouseDown [ 2 ] , "middle button released" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;

 // 侧键 X1/X2 -> ImGui button 3/4（ImGui 的 Io.MouseDown 有 5 格）。
imgui_input_mouse_press ( IMGF . Mouse_Buttons . X1 ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . MouseDown [ 3 ] , "jfoster X1 -> ImGui button 3" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;
imgui_input_mouse_release ( IMGF . Mouse_Buttons . X1 ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . MouseDown [ 3 ] , "X1 released" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;

 imgui_input_mouse_press ( IMGF . Mouse_Buttons . X2 ) ;
imgui_input_frame_begin ( ) ;
expect ( state , io . MouseDown [ 4 ] , "jfoster X2 -> ImGui button 4" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;
imgui_input_mouse_release ( IMGF . Mouse_Buttons . X2 ) ;
imgui_input_frame_begin ( ) ;
expect ( state , ! io . MouseDown [ 4 ] , "X2 released" ) ;
imgui_input_frame_end ( ) ;
imgui_input_mouse_step ( ) ;
}

 //@endregion

 //@region 生命周期与其它后端入口

 // shutdown 之后 process_input 必须彻底空转（imgui_initialized=false 的 guard），
// 否则关掉的上下文会被继续灌事件。
shutdown_stops_input_forwarding :: ( state : * Test_State ) {
if ! imgui_input_open ( "imgui shutdown" ) {
print ( "  [skip] shutdown...: no SDL video driver\n" ) ;
return ;
}
defer imgui_input_close ( ) ;

 io := GetIO ( ) ;
expect ( state , IF . imgui_initialized , "open() leaves the backend initialized" ) ;

 IF . imgui_foster_shutdown ( ) ;
expect ( state , ! IF . imgui_initialized , "shutdown clears imgui_initialized" ) ;
expect ( state , IF . font_texture == null , "shutdown releases the font texture" ) ;

 imgui_input_key_press ( IMGF . Keys . C ) ;
imgui_input_mouse_press ( IMGF . Mouse_Buttons . MIDDLE ) ;
// 帧照常推进（new_frame 不看 imgui_initialized），但输入必须一点都进不来。
imgui_input_frame_begin ( ) ;
expect ( state , ! IsKeyDown ( . C ) , "no key events after shutdown" ) ;
expect ( state , ! io . MouseDown [ 2 ] , "no mouse events after shutdown" ) ;
imgui_input_frame_end ( ) ;
imgui_input_keys_step ( ) ;
imgui_input_mouse_step ( ) ;
imgui_input_mouse_release ( IMGF . Mouse_Buttons . MIDDLE ) ;
imgui_input_key_release ( IMGF . Keys . C ) ;

 // 让 harness_close 状态一致（它自己也会清）。
IF . imgui_initialized = true ;
}

 // imgui_foster_register_texture 只是把 *Texture 原样包成 ImTextureID（给 ImGui.Image 用）。
register_texture_wraps_pointer :: ( state : * Test_State ) {
texture : IMGF . Texture ;
id := IF . imgui_foster_register_texture ( * texture ) ;
expect ( state , id == cast ( * void ) * texture , "register_texture returns the same pointer as ImTextureID" ) ;
expect ( state , id != null , "register_texture does not null out the pointer" ) ;
}

 //@endregion

 //@region utf8_decode（文本输入的解码核心）

 utf8_decode_ascii_and_two_byte :: ( state : * Test_State ) {
code , length := IF . utf8_decode ( "A" , 0 ) ;
expect ( state , code == 65 , tprint ( "ASCII 'A' -> 65, got %" , code ) ) ;
expect ( state , length == 1 , tprint ( "ASCII advances 1 byte, got %" , length ) ) ;

 code , length = IF . utf8_decode ( "abc" , 1 ) ;
expect ( state , code == 98 , tprint ( "'b' at index 1 -> 98, got %" , code ) ) ;
expect ( state , length == 1 , tprint ( "ASCII advances 1 byte, got %" , length ) ) ;

 // é = C3 A9（2 字节）
code , length = IF . utf8_decode ( "é" , 0 ) ;
expect ( state , code == 0xE9 , tprint ( "é -> U+00E9, got 0x%" , code ) ) ;
expect ( state , length == 2 , tprint ( "é advances 2 bytes, got %" , length ) ) ;
}

 utf8_decode_three_and_four_byte :: ( state : * Test_State ) {
// 中 = E4 B8 AD（3 字节）
code , length := IF . utf8_decode ( "中" , 0 ) ;
expect ( state , code == 0x4E2D , tprint ( "中 -> U+4E2D, got 0x%" , code ) ) ;
expect ( state , length == 3 , tprint ( "中 advances 3 bytes, got %" , length ) ) ;

 // 混合串里定位
code , length = IF . utf8_decode ( "abc 中" , 4 ) ;
expect ( state , code == 0x4E2D , tprint ( "中 at index 4 -> U+4E2D, got 0x%" , code ) ) ;
expect ( state , length == 3 , tprint ( "中 advances 3 bytes, got %" , length ) ) ;

 // 😀 = F0 9F 98 80（4 字节）
code , length = IF . utf8_decode ( "😀" , 0 ) ;
expect ( state , code == 0x1F600 , tprint ( "😀 -> U+1F600, got 0x%" , code ) ) ;
expect ( state , length == 4 , tprint ( "😀 advances 4 bytes, got %" , length ) ) ;
}

 utf8_decode_rejects_invalid_and_truncated :: ( state : * Test_State ) {
// 孤立续接字节 0x80：返回 0（调用方据此丢弃）。
code , length := IF . utf8_decode ( "\x80" , 0 ) ;
expect ( state , code == 0 , tprint ( "lone continuation byte -> 0, got 0x%" , code ) ) ;
expect ( state , length == 1 , tprint ( "invalid byte still advances 1 (no infinite loop), got %" , length ) ) ;

 // 截断的 3 字节序列（只有 2 字节）：不能越界读，返回 0/1。
code , length = IF . utf8_decode ( "\xE4\xB8" , 0 ) ;
expect ( state , code == 0 , tprint ( "truncated 3-byte sequence -> 0, got 0x%" , code ) ) ;
expect ( state , length == 1 , tprint ( "truncated 3-byte sequence advances 1, got %" , length ) ) ;

 // 截断的 4 字节序列（只有 3 字节）。
code , length = IF . utf8_decode ( "\xF0\x9F\x98" , 0 ) ;
expect ( state , code == 0 , tprint ( "truncated 4-byte sequence -> 0, got 0x%" , code ) ) ;
expect ( state , length == 1 , tprint ( "truncated 4-byte sequence advances 1, got %" , length ) ) ;

 // 位于串尾的 3 字节字符（i + 2 == count - 1）：边界不能判失败。
code , length = IF . utf8_decode ( "\xE4\xB8\xAD" , 0 ) ;
expect ( state , code == 0x4E2D , tprint ( "3-byte char at end of string decodes, got 0x%" , code ) ) ;

 // 2 字节前缀但串尾只有 1 字节。
code , length = IF . utf8_decode ( "\xC3" , 0 ) ;
expect ( state , code == 0 , tprint ( "truncated 2-byte sequence -> 0, got 0x%" , code ) ) ;
expect ( state , length == 1 , tprint ( "truncated 2-byte sequence advances 1, got %" , length ) ) ;
}

 //@endregion

 // 跳过项（olib input_test.odin 里两个 @(test)，本仓库没有对应被测对象）
//
//   1. text_widget_starts_sdl_and_accepts_utf8_then_releases_it
//      测的是「SDL 文本输入会话的归属」：setup_platform_io 装 Platform_SetImeDataFn、set_ime_data
//      按 WantTextInput/AppFocusLost/NoKeyboard 开关 SDL 文本输入、text_input_owned 保证只关自己
//      开的会话、Esc/Enter 结束编辑后释放。thirdparty/imgui_foster.jai 里没有 set_ime_data /
//      release_text_input / text_input_owned，也没有 Platform_SetImeDataFn 的接线（imgui_foster_setup
//      只在启动时 window_start_text_input 一次，从不释放），所以这一例没有可断言的对象。
//      等后端补上 IME 桥之后照 olib 这个用例直接搬即可（jfoster 侧已经有 window_start_text_input /
//      window_stop_text_input / window_set_text_input_area）。
//
//   2. ime_caret_converts_global_logical_position_to_window_pixels
//      测 text_input_area(data, viewport, framebuffer_scale) 的坐标换算。后端没有这个函数
//      （同上：IME 桥未接），也没有 framebuffer_scale 的概念（jfoster 直接按物理像素画，后端把
//      DisplayFramebufferScale 恒设 1,1 —— 这一点在 new_frame_mirrors_window_pixel_size 里有断言）。
//
//   除了这两例，还有两处后端入口没有测试覆盖，原因是它们要 GPU 设备：
//     - imgui_foster_setup()（setup_font_texture -> texture_create_from_pixels 需要 App.device）
//     - imgui_foster_render()（要一个 jfoster Batcher + 真实 Texture 才能 append 三角形）
//   其余输入侧入口（process_input / new_frame / setup_keymap / setup_backend / register_texture /
//   shutdown / utf8_decode）全部有断言覆盖。 

// Loop scopes adapted.

#scope_file
DOCK_ABI :: #import "thirdparty/imgui/docking";
