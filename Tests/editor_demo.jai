#import "Basic";
#import "gfx";
#import "test_support";
ED :: #import "editor";
AT :: #import "asset";
HT :: #import "Hash_Table";
IMGF :: #import "thirdparty/imgui_foster";
IM :: #import "ImGui";
Mode :: enum s16 { Idle; Running; Stopped; }
Settings :: struct {
    enabled: bool = true;
    speed: float32 = 3.5;
    lives: s32 = 3;
    mask: u64 = 0xffffffffffffffff;
    name: string = "Editable text";
    mode: Mode = .Running;
    position: Vector2 = .{10, 20};
    samples: [3] float32 = .[0.2, 0.5, 0.9];
}
settings: Settings;
editor: ED.Property_Editor;
assets: AT.Asset_Manager;
selected: AT.Guid;
state: Test_State;
frame: s64;
auto_mode: bool;
checked: bool;
edited: string = "initial";
injected: [4] u8 = .[110, 101, 119, 0]; // persistent SDL event payload: new
key_event :: (key: F.SDL_Scancode, down: bool) {
    event: F.SDL_Event;
    event.key = .{type = ifx down then .SDL_EVENT_KEY_DOWN else .SDL_EVENT_KEY_UP,
        windowID = F.App.window.id, scancode = key, down = down};
    _ := F.SDL_PushEvent(*event);
}
startup :: () {
    gfx_init(); _ := IMGF.imgui_foster_setup();
    IM.GetIO().ConfigFlags_ |= .NavEnableKeyboard;
    _ := AT.assets_init(*assets, .{});
    // Demonstration manifest. Real applications use import_all + assets_init.
    HT.table_set(*assets.manifest, copy_string("sprites/player.png"), AT.guid_generate());
    HT.table_set(*assets.manifest, copy_string("sprites/terrain.png"), AT.guid_generate());
    assets.manifest_loaded = true;
    small: s8 = -7; wide: u64 = 0xffffffffffffffff;
    expect(*state, ED.property_read_integer(*small, cast(*Type_Info_Integer) type_info(s8)) == -7, "signed enum storage sign extension");
    expect(*state, ED.property_read_integer(*wide, cast(*Type_Info_Integer) type_info(u64)) == -1, "full 64-bit enum bit pattern preserved");
}
update :: () { ED.imgui_process_input(); }
render :: () {
    frame += 1;
    gfx_begin_frame(); ED.imgui_begin_frame();
    IM.SetNextWindowSize(.{540, 560}, .FirstUseEver);
    if IM.Begin("Engine property editor") {
        // Native key navigation exercises the reflected bool widget itself.
        if auto_mode && frame == 2 IM.SetKeyboardFocusHere();
        _ := ED.property_drawer(*editor, "Keyboard test", *checked);
        if auto_mode && frame == 14 IM.SetKeyboardFocusHere();
        _ := ED.property_drawer(*editor, "String test", *edited);
        IM.SetNextItemOpen(true, .Once);
        _ := ED.property_drawer(*editor, "Settings", *settings);
        if auto_mode && frame == 30 IM.SetKeyboardFocusHere();
        _ := ED.asset_selector("Texture GUID", *assets, *selected, ".png");
        IM.Text("Selection only stores the GUID; application owns asset lifetime.");
    }
    IM.End();
    gfx_pass_begin(gfx_backbuffer(), BLACK);
    ED.imgui_end_frame();
    gfx_pass_end(gfx_backbuffer());
    if auto_mode {
        if frame == 3 || frame == 4 key_event(.SDL_SCANCODE_SPACE, frame == 3);
        if frame == 16 {
            event: F.SDL_Event;
            event.text = .{type = .SDL_EVENT_TEXT_INPUT, windowID = F.App.window.id, text = injected.data};
            _ := F.SDL_PushEvent(*event);
        }
        if frame == 32 || frame == 33 key_event(.SDL_SCANCODE_SPACE, frame == 32);
        if frame == 36 || frame == 37 key_event(.SDL_SCANCODE_DOWN, frame == 36);
        if frame == 40 || frame == 41 key_event(.SDL_SCANCODE_RETURN, frame == 40);
    }
    if auto_mode && frame == 48 {
        expect(*state, checked, "keyboard activation mutates reflected bool");
        expect(*state, settings.mask == 0xffffffffffffffff && settings.lives == 3 && settings.name == "Editable text", "rendering preserves integer precision and untouched strings");
        expect(*state, edited != "initial" && edited.count > 0, "text event edits reflected string without writing its literal");
        expect(*state, !AT.guid_equals(selected, AT.GUID_NONE), "keyboard selects an asset GUID from the manifest");
        F.app_exit();
    }
    if IsKeyPressed(.ESCAPE) F.app_exit();
}
shutdown :: () {
    ED.property_editor_destroy(*editor); AT.assets_dispose(*assets);
    IMGF.imgui_foster_shutdown(); gfx_shutdown();
}
main :: () {
    state = test_begin();
    for arg: get_command_line_arguments() if arg == "auto" auto_mode = true;
    F.App.startup = startup; F.App.update = update; F.App.render = render; F.App.shutdown = shutdown;
    F.app_run(.{application_name = "editor_demo", window_title = "JaiLib Property Editor", width = 800, height = 640});
    F.app_destroy(); if !test_summary("property editor", *state) exit(1);
}
