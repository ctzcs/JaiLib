#import "Basic";
Game :: #import "core";
F :: #import "foster";
ImGui :: #import "thirdparty/imgui";
Backend :: #import "thirdparty/imgui/imgui_foster";

// Static development module on jacket; no pretend DLL reload.
Session :: struct {
    world: Game.World;
    services: Game.Services;
}

init :: (session: *Session) {
    Game.services_init(*session.services);
    Backend.imgui_foster_setup();
}

update :: (session: *Session, dt: float64) {
    Backend.imgui_foster_process_input();
    Game.step(*session.world, dt);
}

render :: (session: *Session) {
    Game.render(*session.world, *session.services);
    Backend.imgui_foster_new_frame();
    if ImGui.Begin("Development") {
        ImGui.TextUnformatted(tprint("Ticks: %", session.world.ticks));
        ImGui.Checkbox("Paused", *session.world.paused);
        size := ImGui.ImVec2.{ 0, 0 };
        if ImGui.Button("Reset", *size) Game.reset(*session.world);
    }
    ImGui.End();
    F.batcher_clear(session.services.batcher);
    Backend.imgui_foster_render(session.services.batcher);
    F.batcher_render(session.services.batcher, F.drawable_target_window(F.App.window));
}

dispose :: (session: *Session) {
    Backend.imgui_foster_shutdown();
    Game.services_dispose(*session.services);
}
