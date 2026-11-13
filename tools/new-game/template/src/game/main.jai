#import "Basic";
F :: #import "foster";
Game :: #import "core";
world: Game.World;
services: Game.Services;
smoke: bool;
frames: s64;
startup :: () { Game.services_init(*services); }
update :: () {
    if F.keyboard_pressed(F.input_keyboard(F.App.input), .ESCAPE) F.app_exit();
    Game.step(*world, F.App.time.elapsed - F.App.time.previous);
}
render :: () {
    Game.render(*world, *services);
    frames += 1;
    if smoke && frames >= 10 F.app_exit();
}
shutdown :: () { Game.services_dispose(*services); }
main :: () {
    for arg: get_command_line_arguments() if arg == "--smoke" smoke = true;
    F.App.startup = startup; F.App.update = update; F.App.render = render; F.App.shutdown = shutdown;
    F.app_run(F.App_Config.{application_name="@NAME@", window_title="@NAME@", width=960, height=540});
    F.app_destroy();
}
