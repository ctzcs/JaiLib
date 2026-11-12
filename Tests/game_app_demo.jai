#import "Basic";
GA :: #import "game_app";
F :: #import "jfoster";
TXT :: #import "text";

// Equivalent to a DragonLib game deriving from GameApp: the game owns its state.
My_Game :: struct {
    app: GA.Game_App;
    batcher: *F.Batcher;
    font: *TXT.Text_Font;
    auto_mode: bool;
    frames: s64;
}
game: My_Game;

startup :: () {
    game.batcher = F.batcher_create(F.App.device, "MyGame");
    game.font = TXT.text_font_create(F.App.device);
    assert(game.font != null);
}
update :: () {
    if F.keyboard_pressed(F.input_keyboard(F.App.input), .ESCAPE) F.app_exit();
}
render :: () {
    target := F.drawable_target_window(F.App.window);
    F.graphics_device_clear_color(F.App.device, target, .{24, 28, 36, 255});
    F.batcher_clear(game.batcher);
    F.batcher_rect(game.batcher, .{80, 80, 240, 120}, .{102, 191, 255, 255});
    TXT.text_draw(game.font, game.batcher, "Hello, MyGame!", .{80, 220}, 32, .{255, 255, 255, 255});
    F.batcher_render(game.batcher, target);
    game.frames += 1;
    if game.auto_mode && game.frames >= 120 F.app_exit();
}
shutdown :: () {
    TXT.text_font_destroy(game.font);
    F.batcher_destroy(game.batcher);
}
status_command :: (args: string, data: *void) {
    F.log_info(tprint("MyGame: % frames", game.frames));
}
main :: () {
    args := get_command_line_arguments();
    game.auto_mode = GA.game_app_has_arg(args, "auto");
    config := F.App_Config.{
        application_name = "MyGame", window_title = "MyGame",
        width = 800, height = 600,
    };
    if GA.game_app_has_arg(args, "vulkan") config.preferred_graphics_driver = .VULKAN;
    game.app = .{
        config = GA.game_app_apply_cli_args(config, args),
        startup = startup, update = update, render = render, shutdown = shutdown,
    };
    if GA.game_app_has_arg(args, "--cli") {
        cli := GA.game_app_enable_cli(*game.app);
        GA.cli_register(cli, "status", "显示游戏帧数", status_command);
    }
    GA.game_app_run(*game.app);
    GA.game_app_destroy(*game.app);
}
