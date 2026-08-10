// editor.jai
// Port of Ascension/src/editor/editor.odin
// Editor shell + tool registry. ImGui calls use the Jai ImGui module (IG)
// with the raylib backend from bindings/imgui_raylib.jai.

#import "Basic";
#import "String";
#import "bindings/raylib";
#import "bindings/imgui_raylib";
#import "core/build";
#import "core/screen";
#import "core/libs";
#import "content/game";
#import "content/asset_storage";
#import "content/assets";
#import "editor/tool_burst_tuning";
#import "editor/tool_csv_tables";
#import "editor/tool_dialogue";

#import "ImGui";

EditorToolId :: enum u32 {
    Dialogue;
    Burst_Tuning;
    Csv_Tables;
}

EDITOR_TOOL_COUNT :: 3;

EditorState :: struct {
    open: [EDITOR_TOOL_COUNT] bool;
}

EditorToolVTable :: struct {
    label:        *u8;
    menu_hint:    *u8;
    default_open: bool;
    state:        () -> *void;
    init:         (state: *void);
    update:       (state: *void);
    draw:         (state: *void, open: *bool);
    destroy:      (state: *void);
}

EDITOR_TOOLS: [] EditorToolVTable = .[
    .{ label = "Dialogue", menu_hint = "D", default_open = true, state = dialogue_tool_state, init = dialogue_tool_init, update = dialogue_tool_update, destroy = dialogue_tool_destroy, draw = dialogue_tool_draw },
    .{ label = "Burst Tuning", menu_hint = "B", default_open = false, draw = burst_tuning_tool_draw },
    .{ label = "CSV Tables", menu_hint = "C", default_open = false, draw = csv_tables_tool_draw },
];

editor_tools_init :: (ed: *EditorState) {
    for i: 0..EDITOR_TOOL_COUNT-1 {
        v := EDITOR_TOOLS[i];
        ed.open[i] = v.default_open;
        if v.init != null {
            state: *void = null;
            if v.state != null {
                state = v.state();
            }
            v.init(state);
        }
    }
}

editor_tools_destroy :: (ed: *EditorState) {
    for i: 0..EDITOR_TOOL_COUNT-1 {
        v := EDITOR_TOOLS[i];
        if v.destroy != null {
            state: *void = null;
            if v.state != null {
                state = v.state();
            }
            v.destroy(state);
        }
    }
}

editor_tools_update :: (ed: *EditorState) {
    for i: 0..EDITOR_TOOL_COUNT-1 {
        if !ed.open[i] {
            continue;
        }
        v := EDITOR_TOOLS[i];
        if v.update != null {
            state: *void = null;
            if v.state != null {
                state = v.state();
            }
            v.update(state);
        }
    }
}

editor_tools_draw :: (ed: *EditorState) {
    for i: 0..EDITOR_TOOL_COUNT-1 {
        if !ed.open[i] {
            continue;
        }
        v := EDITOR_TOOLS[i];
        state: *void = null;
        if v.state != null {
            state = v.state();
        }
        v.draw(state, *ed.open[i]);
    }
}

// --- lifecycle ---

IMGUI_FONT_SIZE :: 16.0;

init_editor :: (ed: *EditorState) {
    CreateContext();
    imgui_raylib_setup();
    load_imgui_font();
    editor_tools_init(ed);
}

destroy_editor :: (ed: *EditorState) {
    editor_tools_destroy(ed);
    unload_imgui_font();
    imgui_raylib_shutdown();
    DestroyContext();
}

update_editor :: (ed: *EditorState) {
    editor_tools_update(ed);
}

draw_editor :: (ed: *EditorState) {
    imgui_begin_frame();
    ClearBackground(DARKGRAY);
    draw_editor_menu_bar(ed);
    draw_editor_dockspace();
    editor_tools_draw(ed);
    imgui_end_frame();
}

draw_editor_menu_bar :: (ed: *EditorState) {
    if !BeginMainMenuBar() {
        return;
    }
    defer EndMainMenuBar();

    if BeginMenu("Tools") {
        for i: 0..EDITOR_TOOL_COUNT-1 {
            v := EDITOR_TOOLS[i];
            _ = MenuItem(v.label, v.menu_hint, *ed.open[i]);
        }
        EndMenu();
    }

    if BeginMenu("View") {
        if MenuItem("Show All") {
            for i: 0..EDITOR_TOOL_COUNT-1 {
                ed.open[i] = true;
            }
        }
        if MenuItem("Hide All") {
            for i: 0..EDITOR_TOOL_COUNT-1 {
                ed.open[i] = false;
            }
        }
        EndMenu();
    }

    if BeginMenu("Help") {
        if MenuItem("About") {
            ed.open[0] = true;
        }
        EndMenu();
    }
}

draw_editor_dockspace :: () {
    viewport := GetMainViewport();
    SetNextWindowPos(viewport.WorkPos, .Always);
    SetNextWindowSize(viewport.WorkSize, .Always);

    PushStyleVar(.WindowRounding, 0.0);
    PushStyleVar(.WindowBorderSize, 0.0);
    flags: WindowFlags = .None;
    flags = flags | .NoTitleBar | .NoCollapse | .NoResize | .NoMove | .NoBringToFrontOnFocus | .NoNavFocus | .NoBackground;

    if Begin("EditorBackground", null, flags) {
        // Background host window; tools are opened as regular windows.
    }
    End();
    PopStyleVar(2);
}

// --- font loading ---
// The Jai ImGui module does not bind ImFontAtlas::AddFontFromFileTTF; the
// editor uses imgui's built-in default font for now.

load_imgui_font :: () {
    // Default font (Fonts[0]) is used automatically.
}

unload_imgui_font :: () {
    // Nothing to free in this simplified port.
}

// --- shared helpers ---

buf_set :: (buf: [] u8, s: string) {
    n := min(cast(s64) s.count, cast(s64) buf.count - 1);
    i := 0;
    while i < n {
        buf[cast(s64) i] = s[cast(s64) i];
        i += 1;
    }
    buf[cast(s64) n] = 0;
}

buf_get :: (buf: [] u8) -> string {
    n := 0;
    while cast(s64) n < buf.count {
        if buf[cast(s64) n] == 0 {
            break;
        }
        n += 1;
    }
    result: string;
    result.data = buf.data;
    result.count = cast(s64) n;
    return result;
}

v2 :: (x: float32, y: float32) -> ImVec2 {
    return .{ x = x, y = y };
}
