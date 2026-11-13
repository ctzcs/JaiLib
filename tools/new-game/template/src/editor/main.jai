#import "Basic";
F :: #import "foster";
Editor :: #import "core_editor";
session: Editor.Session;
smoke: bool;
frames: s64;
startup :: () { Editor.init(*session); }
update :: () {
    if F.keyboard_pressed(F.input_keyboard(F.App.input), .ESCAPE) F.app_exit();
    Editor.update(*session, F.App.time.elapsed - F.App.time.previous);
}
render :: () {
    Editor.render(*session);
    frames += 1;
    if smoke && frames >= 10 F.app_exit();
}
shutdown :: () { Editor.dispose(*session); }
main :: () {
    for arg: get_command_line_arguments() if arg == "--smoke" smoke = true;
    F.App.startup = startup; F.App.update = update; F.App.render = render; F.App.shutdown = shutdown;
    F.app_run(F.App_Config.{application_name="@NAME@Editor", window_title="@NAME@ - development", width=960, height=540});
    F.app_destroy();
}
