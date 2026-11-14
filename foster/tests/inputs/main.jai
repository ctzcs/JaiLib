// M4 sample: live input visualization — keyboard pressed/released/down with
// repeat, mouse position/delta/wheel/buttons, gamepad states. ESC or window
// close exits.
// Build from the repo root:  jai first.jai - inputs

#import "Basic";
#import "File";
#import "Math";
#import "foster";

main :: () {
    App.startup = startup;
    App.render = render;
    App.update = update;

    app_run(.{
        application_name = "jfoster inputs sample",
        window_title = "jfoster inputs (ESC to quit)",
        width = 1280,
        height = 720,
    });

    app_destroy();
}

S :: struct {
    batcher: *Batcher;
    last_first_pressed: s32 = -1;
    press_log: [..] string;
    press_frame: [..] u64;
}

state: S;

startup :: () {
    state.batcher = batcher_create(App.device, "ui");
    window_start_text_input(App.window);
}

update :: () {
    kb := input_keyboard(App.input);
    if keyboard_pressed(kb, .ESCAPE) app_exit();

    p := keyboard_first_pressed(kb);
    if p >= 0 {
        array_insert_at(*state.press_log, keys_to_string(cast(Keys) p), 0);
        array_insert_at(*state.press_frame, App.time.frame, 0);
        if state.press_log.count > 12 {
            array_ordered_remove_by_index(*state.press_log, state.press_log.count - 1);
            array_ordered_remove_by_index(*state.press_frame, state.press_frame.count - 1);
        }
    }
}

render :: () {
    t := App.time.elapsed;
    kb := input_keyboard(App.input);
    ms := input_mouse(App.input);

    batcher_clear(state.batcher);
    b := state.batcher;

    // background
    batcher_rect_gradient(b, .{ 0, 0, 1280, 720 },
        Color.{ 25, 25, 35, 255 }, Color.{ 25, 25, 35, 255 },
        Color.{ 45, 35, 65, 255 }, Color.{ 30, 40, 60, 255 });

    // WASD cluster — lit while down, flash on press
    draw_key :: (b: *Batcher, kb: *Keyboard_State, x: float, y: float, w: float, h: float, label: string, key: Keys) {
        col := Color.{ 70, 70, 90, 255 };
        if keyboard_down(kb, key) col = Color.{ 120, 200, 255, 255 };
        if keyboard_pressed(kb, key) col = Color_White;
        batcher_rect_rounded(b, .{ x, y, w, h }, 8, col);
        if keyboard_repeated(kb, key) {
            batcher_circle(b, .{ x + w - 8, y + 8 }, 4, 8, Color.{ 255, 255, 100, 255 });
        }
    };

    draw_key(b, kb, 100, 150, 90, 90, "W", .W);
    draw_key(b, kb, 100, 260, 90, 90, "A", .A);
    draw_key(b, kb, 210, 260, 90, 90, "S", .S);
    draw_key(b, kb, 320, 260, 90, 90, "D", .D);

    // modifier lamps
    lamps: [6] struct {
        label: string;
        on: bool;
    } = .[
.{ "CTRL", keyboard_ctrl(kb) },
.{ "ALT", keyboard_alt(kb) },
.{ "SHIFT", keyboard_shift(kb) },
.{ "LEFT", keyboard_down(kb, .LEFT) },
.{ "RIGHT", keyboard_down(kb, .RIGHT) },
.{ "UP", keyboard_down(kb, .UP) },
];
    for lamp, i: lamps {
        col := ifx lamp.on then Color.{ 120, 255, 140, 255 } else Color.{ 60, 60, 75, 255 };
        batcher_rect_rounded(b, .{ 100 + cast(float) i * 80, 420, 70, 36 }, 6, col);
    }

    // mouse crosshair + trail
    batcher_circle(b, ms.Position, 10, 16, Color.{ 255, 255, 255, 180 });
    batcher_line(b, ms.Position - .{ 20, 0 }, ms.Position + .{ 20, 0 }, 2, Color.{ 255, 255, 255, 120 });
    batcher_line(b, ms.Position - .{ 0, 20 }, ms.Position + .{ 0, 20 }, 2, Color.{ 255, 255, 255, 120 });

    // mouse buttons
    mbtns: [3] struct {
        label: string;
        btn: Mouse_Buttons;
    } = .[
.{ "L", .LEFT }, .{ "M", .MIDDLE }, .{ "R", .RIGHT },
];
    for m, i: mbtns {
        col := Color.{ 70, 70, 90, 255 };
        if mouse_down(ms, m.btn) col = Color.{ 255, 160, 120, 255 };
        if mouse_pressed(ms, m.btn) col = Color_White;
        batcher_rect_rounded(b, .{ 560 + cast(float) i * 60, 150, 50, 50 }, 8, col);
    }

    // wheel indicator
    wheel := mouse_wheel(ms);
    if wheel.y != 0 || wheel.x != 0 {
        batcher_rect(b, .{ 560, 260, 170, 20 }, Color.{ 255, 220, 90, 255 });
    }

    // gamepad states
    controllers := input_controllers(App.input);
    for c, idx: controllers {
        if !c.Connected continue;
        x := 800.0;
        y := 150.0 + cast(float) idx * 120;
        batcher_rect_rounded(b, .{ x, y, 380, 100 }, 10, Color.{ 40, 50, 45, 255 });
        // sticks
        ls := controller_left_stick(*controllers[idx]);
        batcher_circle(b, .{ x + 50, y + 50 }, 30, 16, Color.{ 70, 70, 90, 255 });
        batcher_circle(b, .{ x + 50 + ls.x * 25, y + 50 + ls.y * 25 }, 8, 12, Color_White);
        rs := controller_right_stick(*controllers[idx]);
        batcher_circle(b, .{ x + 120, y + 50 }, 30, 16, Color.{ 70, 70, 90, 255 });
        batcher_circle(b, .{ x + 120 + rs.x * 25, y + 50 + rs.y * 25 }, 8, 12, Color_White);
        // face buttons
        for btn: 0..3 {
            bx := x + 200 + cast(float) (btn % 2) * 30;
            by := y + 35 + cast(float) (btn / 2) * 30;
            col := ifx controller_down(*controllers[idx], cast(Buttons) btn)
                then Color.{ 255, 200, 120, 255 } else Color.{ 70, 70, 90, 255 };
            batcher_circle(b, .{ bx, by }, 10, 10, col);
        }
    }

    // text input echo box
    text := builder_to_string(*kb.Text);
    if text.count > 0 {
        batcher_rect(b, .{ 100, 500, 400, 30 }, Color.{ 255, 255, 255, 60 });
    }

    batcher_render(b, drawable_target_window(App.window));
}

keys_to_string :: (key: Keys) -> string {
    n := cast(u32) key;
    if n >= 4 && n <= 29 {
        letters: [26] string = .["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"];
        return letters[n - 4];
    }
    if n == 44 return "SPACE";
    if n == 40 return "ENTER";
    if n == 41 return "ESC";
    if n == 79 return "RIGHT";
    if n == 80 return "LEFT";
    if n == 81 return "DOWN";
    if n == 82 return "UP";
    return tprint("key %", n);
}
