#import "Basic";
#import "test_support";
GA :: #import "game_app";
F :: #import "jfoster";
TH :: #import "Thread"(LOAD_THREAD_GROUP = false);
S :: #import "String";

app: GA.Game_App;
state: Test_State;
cli_test: bool;
started, stopped: s64;
updates, renders, probes: s64;
help_seen, unknown_seen, history_seen: bool;

log_capture :: (text: string) {
    if S.begins_with(text, "[cli] 命令列表:") help_seen = true;
    if S.begins_with(text, "[cli] 未知命令") unknown_seen = true;
    if S.begins_with(text, "game-app-history-marker\n") history_seen = true;
}
old_probe :: (args: string, data: *void) { expect(*state, false, "old handler must be replaced"); }
probe :: (args: string, data: *void) {
    expect(*state, F.current_thread_id() == F.App.main_thread_id && started == 1 && stopped == 0,
        "CLI handler runs on main thread after startup and before shutdown");
    expect(*state, data == *probes, "delegate data preserved");
    expected := ifx probes == 0 then "first" else "第二 个  参数";
    expect(*state, args == expected, "command args trimmed with internal spaces preserved");
    probes += 1;
}
startup :: () {
    started += 1;
    expect(*state, F.App.running && F.App.device != null && F.App.window != null, "startup has live device and window");
    expect(*state, F.cstr_to_string(F.SDL_GetHint(F.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN)) == "0", "no-focus applied to SDL before showing window");
}
update :: () {
    expect(*state, started == 1 && stopped == 0, "update inside lifecycle");
    updates += 1;
    if updates == 2 F.app_exit(); // Also prevents hangs when quit fails.
}
render :: () {
    renders += 1;
    F.graphics_device_clear_color(F.App.device, F.drawable_target_window(F.App.window), .{24, 28, 36, 255});
}
shutdown :: () {
    stopped += 1;
    expect(*state, started == 1 && F.App.device != null, "shutdown occurs before platform disposal");
}
main :: () {
    state = test_begin();
    args := get_command_line_arguments();
    cli_test = GA.game_app_has_arg(args, "--cli-test");
    flags := string.["--NO-FOCUS", "--cli"];
    expect(*state, GA.game_app_has_arg(flags, "--no-focus"), "argument matching ignores ASCII case");
    expect(*state, !GA.game_app_has_arg(flags, "--no") && !GA.game_app_has_arg(flags, "--missing"), "argument matching requires complete token");
    config := F.App_Config.{application_name = "game_app_tests", width = 320, height = 240, flags = .NO_HEADER_LOG};
    adjusted := GA.game_app_apply_cli_args(config, flags);
    expect(*state, adjusted.flags == (.NO_HEADER_LOG | .NO_WINDOW_FOCUS) && config.flags == .NO_HEADER_LOG, "CLI config adds no-focus without modifying original flags");
    empty: [] string;
    expect(*state, GA.game_app_apply_cli_args(config, empty).flags == config.flags, "no arguments preserve config");
    if GA.game_app_has_arg(args, "vulkan") adjusted.preferred_graphics_driver = .VULKAN;
    F.log_info("game-app-history-marker");
    history := F.log_get_history(); defer free(history.data);
    again := F.log_get_history(); defer free(again.data);
    expect(*state, history == again && history.count > 0, "GetHistory does not consume logs");
    F.log_set_callbacks(log_capture, log_capture, log_capture);
    app = .{config = adjusted, startup = startup, update = update, render = render, shutdown = shutdown};
    expect(*state, app.cli == null, "CLI opt-in like DragonLib");
    if cli_test {
        cli := GA.game_app_enable_cli(*app);
        expect(*state, GA.game_app_enable_cli(*app) == cli && cli.started, "EnableCli reuses one console and thread");
        GA.cli_register(cli, "probe", "old", old_probe);
        GA.cli_register(cli, "PROBE", "new", probe, *probes);
        expect(*state, cli.commands.count == 4, "case-insensitive register replaces existing command");
        // Test fixture is piped before Run; EOF must leave owned pending lines.
        expect(*state, TH.thread_is_done(*cli.thread, 2000), "redirected stdin closes before Run");
        expect(*state, probes == 0 && cli.pending.count == 6, "commands queued before Run without invoking handlers");
    }
    GA.game_app_run(*app);
    expect(*state, started == 1 && stopped == 1 && updates > 0 && renders > 0 && !F.App.running, "complete lifecycle runs once");
    if cli_test {
        expect(*state, probes == 2 && updates == 1, "commands and quit execute in first update");
        expect(*state, help_seen && unknown_seen && history_seen, "help, unknown commands and history produce expected logs");
        GA.cli_stop(app.cli); // Idempotent after shutdown.
    }
    GA.game_app_destroy(*app);
    GA.game_app_destroy(*app); // Disposal is idempotent.
    expect(*state, app.cli == null && F.App.disposed && F.App.update == null, "destroy releases console and platform callbacks");
    F.log_set_callbacks(null, null, null);
    if !test_summary("game_app", *state) exit(1);
}
