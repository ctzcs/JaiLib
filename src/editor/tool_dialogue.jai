// tool_dialogue.jai
// Port of Ascension/src/editor/tool_dialogue.odin
// Dialogue node-graph editor: full node dragging, linking via handles,
// right-click menu, inspector editing, and JSON save/load.

#import "Basic";
#import "bindings/raylib";
#import "bindings/imgui_raylib";
#import "content/game";
#import "editor/editor";
#import "encoding/json";
#import "File";
#import "ImGui";

NODE_W :: 180.0;
NODE_H :: 70.0;
HANDLE_SIZE :: 12.0;

COL_NODE_FILL       :: cast(u32) 0xFF463C3C;
COL_NODE_ENTRY      :: cast(u32) 0xFF325A28;
COL_NODE_SELECTED   :: cast(u32) 0xFF6E4650;
COL_NODE_BORDER     :: cast(u32) 0xFF827878;
COL_NODE_SEL_BORDER :: cast(u32) 0xFF50C8FF;
COL_HANDLE          :: cast(u32) 0xFFFFA050;
COL_LINK            :: cast(u32) 0xFFAAA0A0;
COL_LINK_TEMP       :: cast(u32) 0xC850C8FF;
COL_TEXT            :: cast(u32) 0xFFEBE6E6;
COL_TEXT_SPEAKER    :: cast(u32) 0xFF78DCFF;
COL_ENTRY_LABEL     :: cast(u32) 0xFF8CFF78;

DEFAULT_DIALOGUE_PATH :: "config/dialogue/1.json";

// ---- Dialogue Graph Data ----
// A node = one line of dialogue; a link = "next dialogue".
// entry_id is the start node (0 = unset). The struct layout (field names)
// matches the Odin original so the JSON files are interchangeable.
DialogueNode :: struct {
    id:      s32;
    pos:     [2] float32;    // canvas position
    speaker: string;
    text:    string;
}

DialogueLink :: struct {
    from: s32;               // source node id
    to:   s32;               // target node id
}

DialogueGraph :: struct {
    nodes:    [..] DialogueNode;
    links:    [..] DialogueLink;
    entry_id: s32;           // start node; 0 = none
    next_id:  s32;           // id counter
}

dialogue_init :: (g: *DialogueGraph) {
    <<g = .{};
    g.next_id = 1;
}

dialogue_destroy :: (g: *DialogueGraph) {
    array_free(g.nodes);
    array_free(g.links);
    <<g = .{};
}

dialogue_find_node :: (g: *DialogueGraph, id: s32) -> (*DialogueNode, s64) {
    for i: 0..g.nodes.count-1 {
        if g.nodes[i].id == id {
            return *g.nodes[i], i;
        }
    }
    return null, -1;
}

// Create a node at canvas (x,y); returns its id.
dialogue_add_node :: (g: *DialogueGraph, x: float32, y: float32) -> s32 {
    id := g.next_id;
    g.next_id += 1;
    array_add(*g.nodes, .{ id = id, pos = .[x, y], speaker = "", text = "New dialogue" });
    if g.entry_id == 0 {
        g.entry_id = id;     // first node becomes entry automatically
    }
    return id;
}

// Remove a node and all links referencing it.
dialogue_remove_node :: (g: *DialogueGraph, id: s32) {
    idx: s64 = -1;
    for i: 0..g.nodes.count-1 {
        if g.nodes[i].id == id {
            idx = i;
            break;
        }
    }
    if idx >= 0 {
        last := g.nodes.count - 1;
        if last >= 0 {
            g.nodes[idx] = g.nodes[last];   // swap with last then pop
            array_resize(*g.nodes, g.nodes.count - 1);
        }
    }
    // drop links touching this node
    kept: [..] DialogueLink;
    for l: g.links {
        if l.from != id && l.to != id {
            array_add(*kept, l);
        }
    }
    array_free(g.links);
    g.links = kept;
    if g.entry_id == id {
        g.entry_id = 0;
    }
}

// Add a from->to link (dedup).
dialogue_add_link :: (g: *DialogueGraph, from: s32, to: s32) {
    if from == to {
        return;
    }
    for l: g.links {
        if l.from == from && l.to == to {
            return;
        }
    }
    array_add(*g.links, .{ from = from, to = to });
}

// Remove a single from->to link.
dialogue_remove_link :: (g: *DialogueGraph, from: s32, to: s32) {
    for i: 0..g.links.count-1 {
        if g.links[i].from == from && g.links[i].to == to {
            // swap-remove is fine; link order is irrelevant
            last := g.links.count - 1;
            if last >= 0 {
                g.links[i] = g.links[last];
                array_resize(*g.links, g.links.count - 1);
            }
            return;
        }
    }
}

// Recompute next_id from existing node ids (after load).
dialogue_rebuild_next_id :: (g: *DialogueGraph) {
    max_id: s32 = 0;
    for n: g.nodes {
        if n.id > max_id {
            max_id = n.id;
        }
    }
    if max_id >= g.next_id {
        g.next_id = max_id + 1;
    }
}

// Save to JSON (pretty).
dialogue_save :: (g: *DialogueGraph, path: string) -> Json_Error {
    slash := -1;
    for i: 0..path.count-1 {
        if path[i] == "/"[0] || path[i] == "\\"[0] {
            slash = i;
        }
    }
    if slash >= 0 {
        dir: string;
        dir.data = path.data;
        dir.count = cast(s64) slash;
        _ = make_directory_if_it_does_not_exist(dir, recursive = true);
    }
    return json_save_struct(path, g);
}

// Load from JSON; replaces current graph contents on success.
dialogue_load :: (g: *DialogueGraph, path: string) -> Json_Error {
    loaded: DialogueGraph;
    err := json_load_struct(path, *loaded);
    if err != .None {
        return err;
    }
    dialogue_destroy(g);
    <<g = loaded;
    dialogue_rebuild_next_id(g);
    if g.entry_id == 0 && g.nodes.count > 0 {
        g.entry_id = g.nodes[0].id;
    }
    return .None;
}

// ---- Dialogue Tool State & vtable hooks ----

DialogueToolState :: struct {
    graph:           DialogueGraph;
    selected:        s32;
    linking_from:    s32;
    prev_mouse:      ImVec2;
    path_buf:        [256] u8;
    edit_speaker:    [128] u8;
    edit_text:       [1024] u8;
    edit_loaded_for: s32;
    status:          [128] u8;
}

// The tool vtable's `state` returns a pointer to this global instance.
dialogue_tool_state_instance: DialogueToolState;

dialogue_tool_state :: () -> *void {
    return cast(*void) *dialogue_tool_state_instance;
}

dialogue_tool_init :: (state: *void) {
    de := cast(*DialogueToolState) state;
    dialogue_init(*de.graph);
    buf_set(de.path_buf, DEFAULT_DIALOGUE_PATH);
    de.prev_mouse = v2(0, 0);

    a := dialogue_add_node(*de.graph, 80, 120);
    b := dialogue_add_node(*de.graph, 360, 120);
    na, _ := dialogue_find_node(*de.graph, a);
    nb, _ := dialogue_find_node(*de.graph, b);
    if na != null {
        na.speaker = "NPC";
        na.text = "你好";
    }
    if nb != null {
        nb.speaker = "Player";
        nb.text = "你好呀";
    }
    dialogue_add_link(*de.graph, a, b);
    de.graph.entry_id = a;
    buf_set(de.status, "Click orange handle, then target node to link. Right-click node for menu.");
}

dialogue_tool_destroy :: (state: *void) {
    de := cast(*DialogueToolState) state;
    dialogue_destroy(*de.graph);
}

dialogue_tool_update :: (state: *void) {
    de := cast(*DialogueToolState) state;
    // raylib keyboard (ImGui key events are not forwarded in this backend).
    if de.selected != 0 && IsKeyPressed(.Delete) {
        dialogue_remove_node(*de.graph, de.selected);
        de.selected = 0;
        de.edit_loaded_for = 0;
        buf_set(de.status, "Node deleted");
    }
}

dialogue_tool_draw :: (state: *void, open: *bool) {
    de := cast(*DialogueToolState) state;
    if Begin("Dialogue Editor", open) {
        draw_dialogue_toolbar(de);
        Separator();
        BeginChild("inspector", v2(300, 0), true);
        draw_dialogue_inspector(de);
        EndChild();
        SameLine();
        BeginChild("canvas", GetContentRegionAvail(), true);
        draw_dialogue_canvas(de);
        EndChild();
    }
    End();
}

// ---- Tool UI ----

draw_dialogue_toolbar :: (de: *DialogueToolState) {
    if Button("Add Node") {
        n := de.graph.nodes.count;
        id := dialogue_add_node(*de.graph, cast(float32) 300 + cast(float32)(n % 5) * 40, cast(float32) 200 + cast(float32)(n / 5) * 50);
        de.selected = id;
        de.edit_loaded_for = 0;
    }
    SameLine();
    if Button("Save") {
        path := buf_get(de.path_buf);
        err := dialogue_save(*de.graph, path);
        if err == .None {
            buf_set(de.status, tprint("Saved: %", path));
        } else {
            buf_set(de.status, tprint("Save failed: %", err));
        }
    }
    SameLine();
    if Button("Load") {
        path := buf_get(de.path_buf);
        err := dialogue_load(*de.graph, path);
        if err == .None {
            de.selected = 0;
            de.edit_loaded_for = 0;
            de.linking_from = 0;
            buf_set(de.status, tprint("Loaded: %", path));
        } else {
            buf_set(de.status, tprint("Load failed: %", err));
        }
    }
    SameLine();
    Text("Path:");
    SameLine();
    _ = InputText("##path", *de.path_buf[0], 256);
    TextWrapped(buf_get(de.status));
}

draw_dialogue_inspector :: (de: *DialogueToolState) {
    TextUnformatted(tprint("Nodes: %, Links: %", de.graph.nodes.count, de.graph.links.count));
    Separator();
    TextUnformatted(tprint("Entry: %", de.graph.entry_id));
    Separator();

    if de.selected == 0 {
        TextDisabled("Select a node to edit");
        return;
    }
    node, _ := dialogue_find_node(*de.graph, de.selected);
    if node == null {
        TextDisabled("Node missing");
        return;
    }

    if de.edit_loaded_for != node.id {
        buf_set(de.edit_speaker, node.speaker);
        buf_set(de.edit_text, node.text);
        de.edit_loaded_for = node.id;
    }

    TextUnformatted(tprint("Node #%", node.id));
    Text("Speaker:");
    SameLine();
    if InputText("##speaker", *de.edit_speaker[0], 128) {
        node.speaker = tprint("%", buf_get(de.edit_speaker));
    }
    Text("Text:");
    if InputTextMultiline("##text", *de.edit_text[0], 1024, v2(0, 120)) {
        node.text = tprint("%", buf_get(de.edit_text));
    }

    Separator();
    Text("Outgoing links:");
    count := 0;
    to_remove: [..] DialogueLink;
    for l: de.graph.links {
        if l.from != node.id {
            continue;
        }
        count += 1;
        TextUnformatted(tprint("  -> #%", l.to));
        SameLine();
        PushID(l.to);
        if SmallButton("Remove") {
            array_add(*to_remove, l);
        }
        PopID();
    }
    for l: to_remove {
        dialogue_remove_link(*de.graph, l.from, l.to);
    }
    array_free(to_remove);
    if count == 0 {
        TextDisabled("  (none; click orange handle, then target node)");
    }
}

draw_dialogue_canvas :: (de: *DialogueToolState) {
    dl := GetWindowDrawList();
    origin := GetCursorScreenPos();

    any_body_clicked := false;
    body_clicked_id: s32 = 0;
    any_handle_clicked := false;
    handle_clicked_id: s32 = 0;
    drag_node_id: s32 = 0;

    for l: de.graph.links {
        f, _ := dialogue_find_node(*de.graph, l.from);
        t, _ := dialogue_find_node(*de.graph, l.to);
        if f == null || t == null {
            continue;
        }
        DrawList_AddLine(dl, *node_out_pos(origin, <<f), *node_in_pos(origin, <<t), COL_LINK, 3.0);
    }

    if de.linking_from != 0 {
        f, _ := dialogue_find_node(*de.graph, de.linking_from);
        if f != null {
            DrawList_AddLine(dl, *node_out_pos(origin, <<f), *GetMousePos(), COL_LINK_TEMP, 2.0);
        }
    }

    for i: 0..de.graph.nodes.count-1 {
        node := *de.graph.nodes[i];
        np := v2(origin.x + node.pos[0], origin.y + node.pos[1]);
        np2 := v2(np.x + cast(float32) NODE_W, np.y + cast(float32) NODE_H);

        fill := COL_NODE_FILL;
        if node.id == de.graph.entry_id {
            fill = COL_NODE_ENTRY;
        }
        if node.id == de.selected {
            fill = COL_NODE_SELECTED;
        }
        DrawList_AddRectFilled(dl, *np, *np2, fill, 6.0);
        border_col := COL_NODE_BORDER;
        if node.id == de.selected {
            border_col = COL_NODE_SEL_BORDER;
        }
        DrawList_AddRect(dl, *np, *np2, border_col, 6.0, 0, 2.0);
        DrawList_AddText(dl, *v2(np.x + 8, np.y + 6), COL_TEXT_SPEAKER, node.speaker.data);
        DrawList_AddText(dl, *v2(np.x + 8, np.y + 28), COL_TEXT, node.text.data);
        if node.id == de.graph.entry_id {
            DrawList_AddText(dl, *v2(np.x + 8, np.y + 50), COL_ENTRY_LABEL, "[entry]");
        }
        hp := v2(np.x + cast(float32) NODE_W - 6, np.y + cast(float32) NODE_H / 2 - cast(float32) HANDLE_SIZE / 2);
        DrawList_AddRectFilled(dl, *hp, *v2(hp.x + cast(float32) HANDLE_SIZE, hp.y + cast(float32) HANDLE_SIZE), COL_HANDLE);

        PushID(node.id);
        SetCursorScreenPos(np);
        _ = InvisibleButton("body", v2(cast(float32) NODE_W, cast(float32) NODE_H));
        if IsItemClicked() {
            body_clicked_id = node.id;
            any_body_clicked = true;
        }
        if IsItemActive() && IsMouseDragging(.Left) {
            drag_node_id = node.id;
        }
        if BeginPopupContextItem("node_menu") {
            if Selectable("Set as Entry") {
                de.graph.entry_id = node.id;
            }
            Separator();
            if Selectable("Delete Node") {
                if node.id == de.selected {
                    de.selected = 0;
                }
                dialogue_remove_node(*de.graph, node.id);
            }
            EndPopup();
        }
        SetCursorScreenPos(hp);
        _ = InvisibleButton("handle", v2(cast(float32) HANDLE_SIZE, cast(float32) HANDLE_SIZE));
        if IsItemClicked() {
            handle_clicked_id = node.id;
            any_handle_clicked = true;
        }
        PopID();
    }

    mouse := GetMousePos();
    delta := v2(mouse.x - de.prev_mouse.x, mouse.y - de.prev_mouse.y);
    de.prev_mouse = mouse;
    if drag_node_id != 0 {
        n, _ := dialogue_find_node(*de.graph, drag_node_id);
        if n != null {
            n.pos[0] += delta.x;
            n.pos[1] += delta.y;
        }
    }

    if de.linking_from != 0 {
        if any_body_clicked && body_clicked_id != de.linking_from {
            from := de.linking_from;
            dialogue_add_link(*de.graph, from, body_clicked_id);
            de.linking_from = 0;
            buf_set(de.status, tprint("Linked #% -> #%", from, body_clicked_id));
        } else if IsWindowHovered() && IsMouseClicked(.Left) && !any_body_clicked && !any_handle_clicked {
            de.linking_from = 0;
        }
    } else {
        if any_handle_clicked {
            de.linking_from = handle_clicked_id;
            buf_set(de.status, tprint("Linking from #% - click target node", handle_clicked_id));
        } else if any_body_clicked {
            de.selected = body_clicked_id;
        } else if IsWindowHovered() && IsMouseClicked(.Left) {
            de.linking_from = 0;
            de.selected = 0;
        }
    }
}

node_out_pos :: (origin: ImVec2, n: DialogueNode) -> ImVec2 {
    return v2(origin.x + n.pos[0] + cast(float32) NODE_W, origin.y + n.pos[1] + cast(float32) NODE_H / 2);
}

node_in_pos :: (origin: ImVec2, n: DialogueNode) -> ImVec2 {
    return v2(origin.x + n.pos[0], origin.y + n.pos[1] + cast(float32) NODE_H / 2);
}
