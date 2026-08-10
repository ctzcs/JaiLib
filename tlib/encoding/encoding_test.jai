#import "Basic";
#import "Hash_Table";
#import "File";
#import "test_support";

CSV :: #import "encoding/csv";
JSON :: #import "encoding/json";

test_encoding_csv :: (state: *Test_State) {
    csv_text := "name,health,score\nPlayer,100,2500\nEnemy,50,500\n";
    ok := write_entire_file(".tmp_test_csv.csv", csv_text);
    expect(state, ok, "write test csv");
    defer file_delete(".tmp_test_csv.csv");

    m: CSV.Csv_Manager;
    CSV.csv_manager_init(*m);
    defer CSV.csv_manager_destroy(*m);

    Item :: struct {
        name:   string;
        health: s32;
        score:  s32;
    }

    items, err := CSV.csv_manager_load_table(*m, ".tmp_test_csv.csv", Item);
    expect(state, err == .None, "load table ok");
    expect(state, items.count == 2, "two rows");
    expect(state, items[0].name == "Player", "first name");
    expect(state, items[0].health == 100, "first health");
    expect(state, items[1].score == 500, "second score");

    cfg, err2 := CSV.csv_manager_load_struct(*m, ".tmp_test_csv.csv", Item);
    expect(state, err2 == .None, "load struct ok");
    expect(state, cfg.name == "Player", "struct name");
    expect(state, cfg.score == 2500, "struct score");

    // cached: second load hits the manager cache
    cached, err3 := CSV.csv_manager_load(*m, ".tmp_test_csv.csv");
    expect(state, err3 == .None && cached != null, "cached load ok");
}

test_encoding_json :: (state: *Test_State) {
    // Value-tree round trip
    obj: JSON.Json_Value;
    obj.kind = .Object;
    nv := New(JSON.Json_Value); <<nv = .{ kind = .String, string_val = "Level1" };
    table_add(*obj.object_val, "name", nv);
    wv := New(JSON.Json_Value); <<wv = .{ kind = .Number, number_val = 640 };
    table_add(*obj.object_val, "width", wv);
    arr: JSON.Json_Value;
    arr.kind = .Array;
    a0 := New(JSON.Json_Value); <<a0 = .{ kind = .Number, number_val = 1 };
    array_add(*arr.array_val, a0);
    a1 := New(JSON.Json_Value); <<a1 = .{ kind = .Number, number_val = 2 };
    array_add(*arr.array_val, a1);
    tv := New(JSON.Json_Value); <<tv = arr;
    table_add(*obj.object_val, "tiles", tv);

    expect(state, JSON.json_save(".tmp_test_json.json", obj) == .None, "save json ok");
    JSON.json_destroy_value(obj);

    loaded, err := JSON.json_load(".tmp_test_json.json");
    expect(state, err == .None, "load json ok");
    expect(state, loaded.kind == .Object, "root is object");
    v, found := table_find(*loaded.object_val, "name");
    expect(state, found, "name key found");
    expect(state, v.kind == .String && v.string_val == "Level1", "name value round trip");
    w, found_w := table_find(*loaded.object_val, "width");
    expect(state, found_w && w.number_val == 640.0, "width value round trip");
    t, found_t := table_find(*loaded.object_val, "tiles");
    expect(state, found_t && t.kind == .Array && t.array_val.count == 2, "array round trip");
    JSON.json_destroy_value(loaded);
    file_delete(".tmp_test_json.json");

    // struct round trip
    Save_Data :: struct {
        level:  s32;
        health: float64;
        name:   string;
    }
    sd := Save_Data.{ level = 3, health = 87.5, name = "hero" };
    expect(state, JSON.json_save_struct(".tmp_test_json_struct.json", *sd) == .None, "save struct ok");

    loaded_sd: Save_Data;
    expect(state, JSON.json_load_struct(".tmp_test_json_struct.json", *loaded_sd) == .None, "load struct ok");
    expect(state, loaded_sd.level == 3, "level round trip");
    expect(state, loaded_sd.name == "hero", "name round trip");
    expect(state, loaded_sd.health == 87.5, "health round trip");
    file_delete(".tmp_test_json_struct.json");

    // struct with arrays (fixed + resizable) and \uXXXX unicode round trip
    DNode :: struct {
        id:      s32;
        pos:     [2] float32;
        speaker: string;
        text:    string;
    }
    DGraph :: struct {
        nodes:    [..] DNode;
        entry_id: s32;
        next_id:  s32;
    }
    dg: DGraph = .{ entry_id = 1, next_id = 3 };
    array_add(*dg.nodes, .{ id = 1, pos = .[35.0, 93.0], speaker = "NPC", text = "你好" });
    expect(state, JSON.json_save_struct(".tmp_test_json_arr.json", *dg) == .None, "save struct+array ok");
    loaded_dg: DGraph;
    expect(state, JSON.json_load_struct(".tmp_test_json_arr.json", *loaded_dg) == .None, "load struct+array ok");
    expect(state, loaded_dg.nodes.count == 1, "array count round trip");
    expect(state, loaded_dg.nodes[0].id == 1, "array element id");
    expect(state, loaded_dg.nodes[0].pos[1] == 93.0, "fixed array round trip");
    expect(state, loaded_dg.nodes[0].text == "你好", "unicode text round trip");
    expect(state, loaded_dg.entry_id == 1 && loaded_dg.next_id == 3, "graph fields round trip");
    file_delete(".tmp_test_json_arr.json");
}
