// imgui_demo — ImGui 集成回归示例（字体图集 / 输入管线 / 常用控件）。
//
// 覆盖路径：imgui_foster 后端（DrawData → Batcher、字体图集上传、
// 键盘 keymap / 文本输入 / 鼠标 / 光标 / 剪贴板）+ gfx 的 imgui 帧便利层。
//
// Build: build_imgui_demo.bat（或按其内注释手工调 jai）
// Run（仓库根为 CWD）:
//   bin\imgui_demo.exe           交互窗口
//   bin\imgui_demo.exe auto      自动验证输入管线后退出：
//                                程序化挪鼠标 → 打印 io.MousePos，
//                                坐标跟随即证明 SDL 事件 → jfoster 输入态
//                                → imgui_foster_process_input → io 全链路通。

#import "Basic";
#import "File";
#import "gfx";

JF    :: #import "jfoster";   // 回调挂接 / 鼠标 warp 走本模块引用
IMGUI :: #import "ImGui";     // widgets API
ED :: #import "editor";
IMGF  :: #import "thirdparty/imgui_foster";   // 后端生命周期

auto_arg_frames: s64;
e2e_failed:     bool;
update_step:     s64;

state_frame:    s64;
state_text_buf: [256] u8;
state_slider:   float = 0.35;
state_check:    bool  = true;
state_clicks:   s32;

// 字体链优先 CJK 字体（中文输入/显示需要字形；consola 等纯 ASCII 字体
// 会把中文渲成 '?'）。纯 .ttf 在前，.ttc（stbtt 偏移 0 取首个字面）在后。
pick_font :: () -> string {
    probe_font :: (path: string) -> bool {
        f, ok := file_open(path);
        if ok file_close(*f);
        return ok;
    }
    if probe_font("Tests/fonts/default.ttf")     return "Tests/fonts/default.ttf";
    if probe_font("C:/Windows/Fonts/simhei.ttf")   return "C:/Windows/Fonts/simhei.ttf";
    if probe_font("C:/Windows/Fonts/Deng.ttf")     return "C:/Windows/Fonts/Deng.ttf";
    if probe_font("C:/Windows/Fonts/msyh.ttc")     return "C:/Windows/Fonts/msyh.ttc";
    if probe_font("C:/Windows/Fonts/consola.ttf")  return "C:/Windows/Fonts/consola.ttf";
    return "";   // 空串 = ImGui 内置默认字体（仍可渲染 ASCII）
}

// HUD uses embedded MSDF; ImGui keeps its own Chinese font atlas.
startup :: () {
    font := pick_font();          // CJK 优先 → ImGui（中文输入/显示）
    gfx_init();                 // 内嵌 Roboto MSDF → gfx HUD 文本层
    _ := IMGF.imgui_foster_setup(font);
}

shutdown :: () {
    IMGF.imgui_foster_shutdown();
    gfx_shutdown();
}

push_key :: (scancode: JF.SDL_Scancode, down: bool) {
    ev: JF.SDL_Event;
    ev.key = .{
        type     = ifx down then .SDL_EVENT_KEY_DOWN else .SDL_EVENT_KEY_UP,
        windowID = JF.App.window.id,
        scancode = scancode,
        down     = down,
    };
    _ = JF.SDL_PushEvent(*ev);
}

// SDL_TextInputEvent.text 是 *u8：事件要等下一次 poll 才被消费，
// 指针必须指向持久内存。
inject_text_c: [8] u8;   // 模块级变量，天然持久

push_text :: (bytes: ..u8) {
    for i: 0..bytes.count-1 inject_text_c[i] = bytes[i];
    inject_text_c[bytes.count] = 0;
    ev: JF.SDL_Event;
    ev.text = .{
        type     = .SDL_EVENT_TEXT_INPUT,
        windowID = JF.App.window.id,
        text     = *inject_text_c[0],
    };
    _ = JF.SDL_PushEvent(*ev);
}

ime_debug: bool;   // "ime" 参数：打印收到的每个真实文本事件（配合输入法手动测试）

on_text_hook :: (text: string, window: *JF.Window) {
    if !ime_debug return;
    hex: String_Builder;
    for text append(*hex, tprint("%x ", it));
    print("IME-EVENT text=[%] bytes=[%]\n", text, builder_to_string(*hex));
}

push_mouse_button :: (down: bool) {
    ev: JF.SDL_Event;
    ev.button = .{
        type     = ifx down then .SDL_EVENT_MOUSE_BUTTON_DOWN else .SDL_EVENT_MOUSE_BUTTON_UP,
        windowID = JF.App.window.id,
        button   = 1,   // SDL_BUTTON_LEFT
        down     = down,
        clicks   = 1,
        x        = 150, y = 105,
    };
    _ = JF.SDL_PushEvent(*ev);
}

update :: () {
    update_step += 1;

    // auto 模式端到端注入（事件在下一个 step 的 poll 被消费）：
    //   挪鼠标到输入框 → 点按激活 → 打 "a" → 打 "你" → Backspace。
    // 预期：E2E 打印里 buf 从 "a你" 变成 "a"（激活点击 + 键盘 + 文本 +
    // 中文 + 删除全链路一次验证）。
    if auto_arg_frames > 0 {
        if update_step == 30 JF.window_set_mouse_position(JF.App.window, .{ x = 150, y = 105 });
        if update_step == 33 push_mouse_button(true);
        if update_step == 35 push_mouse_button(false);
        if update_step == 46 {
            // 直接喂 jfoster input_text —— 与 SDL_EVENT_TEXT_INPUT 到达后
            // 走的是同一条下游路径（Text builder → State → imgui 层）。
            JF.input_text(JF.App.input, "你", JF.App.window);
        }
        if update_step == 48 {
            push_key(.SDL_SCANCODE_A, true);
            push_text(97);   // "a"
        }
        if update_step == 48 {
            push_key(.SDL_SCANCODE_A, false);
        }
        if update_step == 50 {
            push_key(.SDL_SCANCODE_B, true);
            push_text(98);   // "b"
        }
        if update_step == 51 push_key(.SDL_SCANCODE_B, false);
        if update_step == 54 push_key(.SDL_SCANCODE_BACKSPACE, true);
        if update_step == 55 push_key(.SDL_SCANCODE_BACKSPACE, false);
    }

    // 每 step 聚合输入事件（fixed-step 下一帧可能多次 update）。
    ED.imgui_process_input();
}

render_widgets :: () {
    // 2) widgets（每 render 帧一次，紧跟 imgui_begin_frame）。
    if IMGUI.Begin("imgui_demo", null) {
        IMGUI.Text("JaiLib imgui backend regression sample");
        IMGUI.Text("中文输入测试：在下面输入框打字（IME 组合 → 确认 → Backspace 删除）");
        IMGUI.Separator();
        if auto_arg_frames > 0 && update_step >= 38 && update_step <= 44 {
            // auto 模式：程序化聚焦输入框（绕开鼠标坐标，专测键盘/文本链路）。
            IMGUI.SetKeyboardFocusHere(0);
        }
        _ = IMGUI.InputText("##input", *state_text_buf[0], 256);
        _ = IMGUI.SliderFloat("slider", *state_slider, 0, 1);
        _ = IMGUI.Checkbox("checkbox", *state_check);
        if IMGUI.Button("Click me", .{ x = 0, y = 0 }) {
            state_clicks += 1;
        }
        IMGUI.SameLine();
        IMGUI.Text("clicks: %", state_clicks);

        io := IMGUI.GetIO();
        IMGUI.Text("MousePos: (%, %)", io.MousePos.x, io.MousePos.y);
        IMGUI.Text("WantCaptureKeyboard: %  WantTextInput: %", io.WantCaptureKeyboard, io.WantTextInput);
        IMGUI.Text("io.Framerate: %", io.Framerate);
    }
    IMGUI.End();
}

render :: () {
    state_frame += 1;
    gfx_begin_frame();

    bw := JF.drawable_target_width_in_pixels(gfx_backbuffer());
    bh := JF.drawable_target_height_in_pixels(gfx_backbuffer());

    // NewFrame（每 render 帧一次）+ widgets。
    ED.imgui_begin_frame();
    render_widgets();

    gfx_pass_begin(gfx_backbuffer(), DARKGRAY);
    ED.imgui_end_frame();
    DrawTextHUD("imgui demo (gfx HUD layer)", 10, bh - 32, LIGHTGRAY);
    gfx_pass_end(gfx_backbuffer());

    // auto 模式：E2E 结果打印（注入序列见 update）。
    if auto_arg_frames > 0 {
        if state_frame == 50 || state_frame == 53 || state_frame == 62 {
            len := 0;
            while len < 256 {  if state_text_buf[len] == 0 break;  len += 1; }
            text_slice: string;
            text_slice.data  = *state_text_buf[0];
            text_slice.count = len;
            io := IMGUI.GetIO();
            print("E2E frame=% buf=[%] MousePos=(%, %) WantTextInput=%\n", state_frame, text_slice, io.MousePos.x, io.MousePos.y, io.WantTextInput);
        }
        if state_frame == 70 {
            // E2E 断言：注入 你+a+b+Backspace 后，buf 应恰为 "你a"
            //（E4 BD A0 61）——同时验证 CJK 文本到达与按码点删除。
            ok := state_text_buf[0] == 0xE4 && state_text_buf[1] == 0xBD
                && state_text_buf[2] == 0xA0 && state_text_buf[3] == 97
                && state_text_buf[4] == 0;
            print("E2E RESULT: %  (expect buf=[a] after backspace)\n", ifx ok then "PASS" else "FAIL");
            e2e_failed = !ok;
        }
        if state_frame >= auto_arg_frames {
            JF.app_exit();
        }
    }
}

main :: () {
    for get_command_line_arguments() {
        if it == "auto" auto_arg_frames = 90;
        if it == "ime"  ime_debug = true;
    }

    JF.App.startup  = startup;
    // ime 调试：打印 SDL/jfoster 收到的每个文本事件（用真实输入法打字验证）。
    if ime_debug JF.App.input.on_text_event = on_text_hook;
    JF.App.update   = update;
    JF.App.render   = render;
    JF.App.shutdown = shutdown;

    JF.app_run(.{
        application_name = "imgui_demo",
        update_mode = JF.update_mode_unlocked(),   // UI demo：update/render 1:1
        window_title     = "imgui demo (JaiLib gfx sample)",
        width  = 960,
        height = 600,
        resizable = true,
    });

    JF.app_destroy();
    if e2e_failed exit(1);
}
