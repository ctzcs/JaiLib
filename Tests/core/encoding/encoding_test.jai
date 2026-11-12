// encoding 模块测试：一比一移植自 olib tests/core/encoding/ordered_json/ordered_json_test.odin，
// 并保留 Libs/Engine/encoding/encoding_test.jai 里的 CSV / JSON 断言（含 XML 覆盖，
// 旧文件没有 XML 断言，这里按旧实现的公开行为补齐）。
//
// 只把 core:testing.expect 换成 test_support.expect；断言顺序与 olib 一一对应。
// 过程签名统一为 (state: *Test_State)，不写 main，由 Tests/core/run_core_tests.jai 调度。

#import "Basic";
#import "Hash_Table";
#import "String";        // contains
#import "File";
#import "test_support";

ENC :: #import "core/encoding";

//@region 测试辅助

// [] u8 -> string（encode 的返回值比较用）
enc_text :: (data: [] u8) -> string {
    return cast(string) data;
}

// 测试专用分配记账，对位 odin core:mem.Tracking_Allocator。
// 不用 core/debug.tracking_allocator：那一版用 table_add 记账，而 jacket 的 table_add
// 允许重复键（table_set 才去重），原地 RESIZE 会留下重复条目、把泄漏计数算大。
Track_Entry :: struct {
    size: s64;
}

Test_Tracker :: struct {
    backing: Allocator;
    live:    Table(*void, Track_Entry);
}

test_track_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, data: *void) -> *void {
    t := cast(*Test_Tracker) data;
    if mode == .ALLOCATE {
        result := t.backing.proc(.ALLOCATE, size, 0, null, t.backing.data);
        if result table_set(*t.live, result, Track_Entry.{ size = size });
        return result;
    }
    if mode == .RESIZE {
        old := old_size;
        if old == 0 && old_memory {
            found, entry := table_find(*t.live, old_memory);
            if found old = entry.size;
        }
        result := t.backing.proc(.RESIZE, size, old, old_memory, t.backing.data);
        if result {
            if old_memory && old_memory != result table_remove(*t.live, old_memory);
            table_set(*t.live, result, Track_Entry.{ size = size });
        }
        return result;
    }
    if mode == .FREE {
        t.backing.proc(.FREE, 0, old_size, old_memory, t.backing.data);
        if old_memory table_remove(*t.live, old_memory);
        return null;
    }
    return t.backing.proc(mode, size, old_size, old_memory, t.backing.data);
}

test_tracker_init :: (t: *Test_Tracker, backing: Allocator) {
    t.backing = backing;
    t.live.allocator = backing;
}

test_tracker_allocator :: (t: *Test_Tracker) -> Allocator {
    return Allocator.{ proc = test_track_proc, data = t };
}

// 模拟 olib 的 fail_alloc：对 Alloc/Resize 扣预算，用光后返回 null。
OJ_Fail_State :: struct {
    backing:   Allocator;
    remaining: int;
}

oj_fail_alloc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, data: *void) -> *void {
    s := cast(*OJ_Fail_State) data;
    if mode == .ALLOCATE || mode == .RESIZE {
        if s.remaining == 0 return null;
        s.remaining -= 1;
    }
    return s.backing.proc(mode, size, old_size, old_memory, s.backing.data);
}

//@endregion

//@region 顺序与所有权（olib: order_edit_clone_roundtrip）

order_edit_clone_roundtrip :: (state: *Test_State) {
    a := context.allocator;
    input := "{\"z\":1,\"\":null,\"a\":[true,\"x\"]}";
    v, err := ENC.decode(input, a);
    expect(state, err == .None, "decode 根对象");
    defer ENC.dispose(*v);
    expect(state, v.members.count == 3 && v.members[0].key == "z", "顺序：z 在最前");
    expect(state, ENC.get(*v, "") != null && ENC.get(*v, "missing") == null, "空键可取、缺失键为空");
    copy_v, cerr := ENC.clone(*v, a);
    expect(state, cerr == .None, "clone 成功");
    defer ENC.dispose(*copy_v);
    n, nerr := ENC.make_u64(18446744073709551615, a);
    expect(state, nerr == .None, "make_u64(max(u64))");
    defer ENC.dispose(*n);
    expect(state, ENC.set(*v, "z", *n) == .None, "set 覆盖已有键");
    expect(state, ENC.set(*v, "last", *n) == .None, "set 追加新键");
    expect(state, v.members[0].key == "z" && v.members[3].key == "last", "覆盖保位、新键追加");
    expect(state, ENC.get(*copy_v, "z").text == "1", "clone 是深拷贝");
    expect(state, ENC.set(*v, "z", ENC.get(*v, "z")) == .None, "set 自覆盖");
    expect(state, ENC.remove_key(*v, "") && !ENC.remove_key(*v, ""), "remove 一次成功、再次失败");
    arr := ENC.get(*v, "a");
    expect(state, ENC.insert(arr, 1, *n) == .None, "insert 中间位置");
    expect(state, ENC.replace(arr, 2, ENC.at(arr, 0)) == .None, "replace 用自身元素");
    expect(state, ENC.erase(arr, 0) && !ENC.erase(arr, 9), "erase 越界返回 false");
    expect(state, ENC.at(arr, -1) == null, "at(-1) 为空");
    expect(state, ENC.insert(arr, 9, *n) == .Index_Out_Of_Range, "insert 越界");
    expect(state, ENC.replace(arr, -1, *n) == .Index_Out_Of_Range, "replace 越界");
    data, eerr := ENC.encode(*v, a);
    expect(state, eerr == .None, "encode 成功");
    defer ENC.free_bytes(a, data);
    expected := "{\"z\":18446744073709551615,\"a\":[18446744073709551615,true],\"last\":18446744073709551615}";
    expect(state, enc_text(data) == expected, "紧凑输出逐字节一致：%", enc_text(data));
    pretty, perr := ENC.encode(*v, a, true);
    expect(state, perr == .None && contains(enc_text(pretty), "\n  \"z\": "), "pretty 两空格缩进");
    defer ENC.free_bytes(a, pretty);
    back, berr := ENC.decode(enc_text(pretty), a);
    expect(state, berr == .None, "pretty 可回读");
    defer ENC.dispose(*back);
    again, aerr := ENC.encode(*back, a);
    expect(state, aerr == .None && enc_text(again) == enc_text(data), "回读后紧凑输出一致");
    ENC.free_bytes(a, again);
    expect(state, ENC.decode_replace(*v, "{\"bad\":[", a) != .None, "decode_replace 失败");
    expect(state, ENC.get(*v, "z").text == "18446744073709551615", "失败后旧树保留");
    expect(state, ENC.decode_replace(*v, "[]", a) == .None && v.kind == .Array, "decode_replace 成功");
    ENC.dispose(*v);
    ENC.dispose(*v); // 二次 dispose 安全
}

//@endregion

//@region 严格子集与 Unicode（olib: strict_tokens_unicode_and_tail）

strict_tokens_unicode_and_tail :: (state: *Test_State) {
    a := context.allocator;
    bad := string.[
        "",
        " ",
        "true false",
        "null\x00",
        "\x00null",
        "\x0bnull",
        "\x0cnull",
        "\xef\xbb\xbfnull",
        "null\xe2\x80\xa8",
        "{\"a\":1,}",
        "[1,]",
        "[1 2]",
        "[,1]",
        "{a:1}",
        "{'a':1}",
        "+1",
        "01",
        "-01",
        "0x10",
        ".5",
        "1.",
        "1e",
        "1e+",
        "NaN",
        "Infinity",
        "-Infinity",
        "\"\\'\"",
        "\"\\x41\"",
        "\"\\uGGGG\"",
        "\"\\uD800\"",
        "\"\\uDC00\"",
        "\"\\uD800\\u0041\"",
        "\"\\uD800\\uD800\"",
        "\"\\uDFFF\\uD800\"",
        "\"\\q\"",
        "\"unterminated",
        "\"\xff\"",
        "/*c*/null",
        "null//c",
        "null/*",
        "{\"a\":1,\"\\u0061\":2}",
        "{\"\":1,\"\":2}",
        "{\"😀\":1,\"\\ud83d\\ude00\":2}",
    ];
    for text: bad {
        v, err := ENC.decode(text, a);
        expect(state, err != .None, "严格模式误接受了 %", text);
        ENC.dispose(*v);
    }
    good := string.[
        "null",
        "true",
        "false",
        "-0",
        "0.0",
        "-1.25E+9",
        "1e999999",
        "\"\\uD83D\\uDE00\"",
        "\"\\u0000中\\n\\\\\\\"\"",
        "{\"\":[],\"b\":{}}",
    ];
    for text: good {
        v, err := ENC.decode(text, a);
        expect(state, err == .None, "误拒了 %", text);
        data, eerr := ENC.encode(*v, a);
        expect(state, eerr == .None, "合法值 encode 成功：%", text);
        back, berr := ENC.decode(enc_text(data), a);
        expect(state, berr == .None, "encode 结果可回读：%", text);
        ENC.dispose(*back);
        ENC.free_bytes(a, data);
        ENC.dispose(*v);
    }
    v, err := ENC.decode("\"\\uD83D\\uDE00\"", a);
    expect(state, err == .None && v.text == "😀", "代理对解成 U+1F600");
    ENC.dispose(*v);
}

//@endregion

//@region 注释模式只放宽注释与尾随逗号（olib: comments_are_not_json5）

comments_are_not_json5 :: (state: *Test_State) {
    a := context.allocator;
    mode := ENC.Mode.Comments_And_Trailing_Commas;
    v, err := ENC.decode("/*head*/{\"x\":[1,/*c*/2,],}//tail\n", a, mode);
    expect(state, err == .None && ENC.get(*v, "x").items.count == 2, "注释 + 尾随逗号");
    ENC.dispose(*v);
    bad := string.[
        "{x:1}",
        "{'x':1}",
        "+1",
        ".5",
        "1.",
        "0x12",
        "NaN",
        "Infinity",
        "\"\\'\"",
        "\"\\uD800\"",
        "[1 2]",
        "[,]",
        "[1,,]",
        "true/*",
        "true\x0b",
        "true\xe2\x80\xa8",
        "true\x00",
        "true/*c*/false",
    ];
    for text: bad {
        value, e := ENC.decode(text, a, mode);
        expect(state, e != .None, "注释模式误接受了 %", text);
        ENC.dispose(*value);
    }
}

//@endregion

//@region 容器深度边界（olib: container_depth_boundary）

container_depth_boundary :: (state: *Test_State) {
    a := context.allocator;
    for 63..65 {
        depth := it;
        sb: String_Builder;
        for 0..depth - 1 append(*sb, "[");
        append(*sb, "0");
        for 0..depth - 1 append(*sb, "]");
        text := builder_to_string(*sb);
        free_buffers(*sb);
        v, err := ENC.decode(text, a);
        expect(state, (err == .None) == (depth <= ENC.MAX_DEPTH), "深度 % 的判定", depth);
        if err == .None {
            c, ce := ENC.clone(*v, a);
            expect(state, ce == .None, "深度 % clone 成功", depth);
            ENC.dispose(*c);
            data, ee := ENC.encode(*v, a, true);
            expect(state, ee == .None, "深度 % encode 成功", depth);
            ENC.free_bytes(a, data);
            if depth == ENC.MAX_DEPTH {
                outer := ENC.make_value(.Array, a);
                expect(state, ENC.insert(*outer, 0, *v) == .None, "insert 根值成功");
                invalid, ie := ENC.encode(*outer, a);
                expect(state, ie == .Depth_Limit && invalid.data == null, "超深 encode 报 Depth_Limit");
                clone_v, cle := ENC.clone(*outer, a);
                expect(state, cle == .Depth_Limit && clone_v.kind == .Null, "超深 clone 报 Depth_Limit");
                ENC.dispose(*clone_v);
                ENC.dispose(*outer);
            }
        }
        ENC.dispose(*v);
    }
}

//@endregion

//@region 精确数字与分配失败（olib: exact_integer_limits / failed_* / mutation_*）

exact_integer_limits :: (state: *Test_State) {
    a := context.allocator;
    signed: [5] s64 = .[-9223372036854775807 - 1, -9007199254740993, -1, 0, 9223372036854775807];
    for n: signed {
        v, err := ENC.make_i64(n, a);
        x, ok := ENC.as_i64(*v);
        expect(state, err == .None && ok && x == n, "i64 往返 %", n);
        ENC.dispose(*v);
    }
    unsigned: [4] u64 = .[0, 9007199254740993, 9223372036854775808, 18446744073709551615];
    for n: unsigned {
        v, err := ENC.make_u64(n, a);
        x, ok := ENC.as_u64(*v);
        expect(state, err == .None && ok && x == n, "u64 往返 %", n);
        ENC.dispose(*v);
    }
    not_i64 := string.["9223372036854775808", "-9223372036854775809", "1.0", "1e0"];
    for text: not_i64 {
        v, err := ENC.make_number(text, a);
        _, ok := ENC.as_i64(*v);
        expect(state, err == .None && !ok, "as_i64 拒绝 %", text);
        ENC.dispose(*v);
    }
    not_u64 := string.["18446744073709551616", "-1", "-0", "1.0", "1e0"];
    for text: not_u64 {
        v, err := ENC.make_number(text, a);
        _, ok := ENC.as_u64(*v);
        expect(state, err == .None && !ok, "as_u64 拒绝 %", text);
        ENC.dispose(*v);
    }
    invalid := string.["NaN", "Inf", "1_0", "+1", "01"];
    for text: invalid {
        v, err := ENC.make_number(text, a);
        expect(state, err == .Invalid_Number, "make_number 拒绝 %", text);
        ENC.dispose(*v);
    }
    lexemes := "[-0,1.2300E+009,1e999999,18446744073709551616]";
    v, err := ENC.decode(lexemes, a);
    expect(state, err == .None, "词法数组 decode");
    data, ee := ENC.encode(*v, a);
    expect(state, ee == .None && enc_text(data) == lexemes, "数字词法逐字节保留");
    ENC.free_bytes(a, data);
    ENC.dispose(*v);
}

// 对位 olib failed_candidates_release_every_allocation：
// 每一次分配都注入失败，失败候选必须释放全部已分配内存。
failed_candidates_release_every_allocation :: (state: *Test_State) {
    tracker: Test_Tracker;
    test_tracker_init(*tracker, context.allocator);
    defer deinit(*tracker.live);
    a := test_tracker_allocator(*tracker);

    texts := string.[
        "{\"a\":[\"v\",{\"b\":1}],\"c\":true}",
        "{\"a\":[\"v\",{\"b\":1}],\"c\":",
        "{\"a\":\"v\",\"\\u0061\":2}",
    ];
    for text: texts {
        for 0..34 {
            state_fail := OJ_Fail_State.{ backing = a, remaining = it };
            f := Allocator.{ proc = oj_fail_alloc, data = *state_fail };
            v, _ := ENC.decode(text, f);
            ENC.dispose(*v);
            expect(state, tracker.live.count == 0, "budget % 有泄漏", it);
        }
    }

    v, err := ENC.decode("{\"a\":[\"v\",{\"b\":1}],\"c\":true}", a);
    expect(state, err == .None, "基线 decode");
    baseline := tracker.live.count;
    for 0..34 {
        state_fail := OJ_Fail_State.{ backing = a, remaining = it };
        f := Allocator.{ proc = oj_fail_alloc, data = *state_fail };
        c, _ := ENC.clone(*v, f);
        ENC.dispose(*c);
        expect(state, tracker.live.count == baseline, "clone budget % 有泄漏", it);
        state_fail.remaining = it;
        data, _ := ENC.encode(*v, f, true);
        ENC.free_bytes(f, data);
        expect(state, tracker.live.count == baseline, "encode budget % 有泄漏", it);
    }
    ENC.dispose(*v);
    expect(state, tracker.live.count == 0, "收尾无泄漏");
}

// 对位 olib mutation_failure_preserves_old_tree：
// 结构性修改失败时旧树必须原样保留，且不遗留分配。
mutation_failure_preserves_old_tree :: (state: *Test_State) {
    tracker: Test_Tracker;
    test_tracker_init(*tracker, context.allocator);
    defer deinit(*tracker.live);
    a := test_tracker_allocator(*tracker);

    source, serr := ENC.decode("{\"nested\":[\"owned\",true]}", context.allocator);
    expect(state, serr == .None, "源值 decode");
    defer ENC.dispose(*source);

    for 0..4 {
        operation := it;
        for 0..14 {
            budget := it;
            state_fail := OJ_Fail_State.{ backing = a, remaining = 100 };
            f := Allocator.{ proc = oj_fail_alloc, data = *state_fail };
            root, rerr := ENC.decode("{\"old\":\"kept\",\"array\":[1,2]}", f);
            expect(state, rerr == .None, "% root decode", tprint("op %", operation));
            baseline := tracker.live.count;
            state_fail.remaining = budget;
            err: ENC.Error = .None;
            if operation == 0 {
                err = ENC.set(*root, "old", *source);
            } else if operation == 1 {
                err = ENC.set(*root, "new", *source);
            } else if operation == 2 {
                err = ENC.insert(ENC.get(*root, "array"), 1, *source);
            } else if operation == 3 {
                err = ENC.replace(ENC.get(*root, "array"), 0, *source);
            } else {
                err = ENC.decode_replace(*root, "{\"candidate\":[\"owned\"]}", f);
            }
            if err != .None {
                expect(state, tracker.live.count == baseline, "op % 失败后有泄漏", tprint("op % budget %", operation, budget));
                data, ee := ENC.encode(*root, context.allocator);
                expect(state, ee == .None &&
                    enc_text(data) == "{\"old\":\"kept\",\"array\":[1,2]}",
                    "% 失败后旧树完好", tprint("op % budget %", operation, budget));
                ENC.free_bytes(context.allocator, data);
            }
            ENC.dispose(*root);
            expect(state, tracker.live.count == 0, "% 收尾无泄漏", tprint("op % budget %", operation, budget));
        }
    }
}

//@endregion

//@region CSV（保留 Libs/Engine/encoding/encoding_test.jai 的断言）

Csv_Item :: struct {
    name:   string;
    health: s32;
    score:  s32;
}

csv_manager_loads_tables_and_structs :: (state: *Test_State) {
    csv_text := "name,health,score\nPlayer,100,2500\nEnemy,50,500\n";
    ok := write_entire_file(".tmp_test_csv.csv", csv_text);
    expect(state, ok, "写入临时 CSV");
    defer file_delete(".tmp_test_csv.csv");

    m: ENC.Csv_Manager;
    ENC.csv_manager_init(*m);
    defer ENC.csv_manager_destroy(*m);

    items, err := ENC.csv_manager_load_table(*m, ".tmp_test_csv.csv", Csv_Item);
    expect(state, err == .None, "load_table 成功");
    expect(state, items.count == 2, "两行数据");
    expect(state, items[0].name == "Player", "首行 name");
    expect(state, items[0].health == 100, "首行 health");
    expect(state, items[1].score == 500, "次行 score");
    ENC.csv_free_table(items);

    cfg, err2 := ENC.csv_manager_load_struct(*m, ".tmp_test_csv.csv", Csv_Item);
    expect(state, err2 == .None, "load_struct 成功");
    expect(state, cfg.name == "Player", "struct name");
    expect(state, cfg.score == 2500, "struct score");

    cached, err3 := ENC.csv_manager_load(*m, ".tmp_test_csv.csv");
    expect(state, err3 == .None && cached != null, "重复 load 命中缓存");

    // 引号字段、'' 转义、空行跳过
    ok2 := write_entire_file(".tmp_test_csv2.csv", "k,v\n\"a,b\",\"x\"\"y\"\n\n");
    expect(state, ok2, "写入第二条 CSV");
    defer file_delete(".tmp_test_csv2.csv");
    doc, err4 := ENC.csv_manager_load(*m, ".tmp_test_csv2.csv");
    expect(state, err4 == .None && doc != null, "引号 CSV 载入");
    expect(state, doc.rows.count == 1, "空行被跳过");
    expect(state, doc.rows[0].count == 2, "引号内逗号不切分");
    expect(state, doc.rows[0][0] == "a,b", "引号字段内容");
    expect(state, doc.rows[0][1] == "x\"y", "双写引号转义");

    // 字段数不一致 -> Parse_Error（Odin 的 fields_per_record 语义）
    ok3 := write_entire_file(".tmp_test_csv3.csv", "a,b\n1,2,3\n");
    expect(state, ok3, "写入第三条 CSV");
    defer file_delete(".tmp_test_csv3.csv");
    _, err5 := ENC.csv_manager_load(*m, ".tmp_test_csv3.csv");
    expect(state, err5 == .Parse_Error, "字段数不一致报 Parse_Error");

    // 非引号字段里的裸引号 -> Parse_Error
    ok4 := write_entire_file(".tmp_test_csv4.csv", "a,b\nx\"y,2\n");
    expect(state, ok4, "写入第四条 CSV");
    defer file_delete(".tmp_test_csv4.csv");
    _, err6 := ENC.csv_manager_load(*m, ".tmp_test_csv4.csv");
    expect(state, err6 == .Parse_Error, "裸引号报 Parse_Error");

    // 不存在的文件
    _, err7 := ENC.csv_manager_load(*m, ".tmp_test_csv_missing.csv");
    expect(state, err7 == .File_Not_Found, "缺文件报 File_Not_Found");
}

//@endregion

//@region JSON（保留 Libs/Engine/encoding/encoding_test.jai 的断言）

Json_Save_Data :: struct {
    level:  s32;
    health: float64;
    name:   string;
}

Json_DNode :: struct {
    id:      s32;
    pos:     [2] float32;
    speaker: string;
    text:    string;
}

Json_DGraph :: struct {
    nodes:    [..] Json_DNode;
    entry_id: s32;
    next_id:  s32;
}

json_value_tree_round_trip :: (state: *Test_State) {
    obj: ENC.Json_Value;
    obj.kind = .Object;
    nv := New(ENC.Json_Value);
    <<nv = .{ kind = .String, string_val = ENC.json_string("Level1") };
    table_add(*obj.object_val, ENC.json_string("name"), nv);
    wv := New(ENC.Json_Value);
    <<wv = .{ kind = .Integer, int_val = 640 };
    table_add(*obj.object_val, ENC.json_string("width"), wv);
    arr: ENC.Json_Value;
    arr.kind = .Array;
    a0 := New(ENC.Json_Value);
    <<a0 = .{ kind = .Integer, int_val = 1 };
    array_add(*arr.array_val, a0);
    a1 := New(ENC.Json_Value);
    <<a1 = .{ kind = .Integer, int_val = 2 };
    array_add(*arr.array_val, a1);
    tv := New(ENC.Json_Value);
    <<tv = arr;
    table_add(*obj.object_val, ENC.json_string("tiles"), tv);

    expect(state, ENC.json_save(".tmp_test_json.json", obj) == .None, "json_save 成功");
    ENC.json_destroy_value(obj);

    loaded, err := ENC.json_load(".tmp_test_json.json");
    expect(state, err == .None, "json_load 成功");
    expect(state, loaded.kind == .Object, "根是对象");
    found_name, name_value := table_find(*loaded.object_val, "name");
    expect(state, found_name && name_value.kind == .String && name_value.string_val == "Level1",
           "name 字符串往返");
    found_width, width_value := table_find(*loaded.object_val, "width");
    expect(state, found_width && width_value.kind == .Integer && width_value.int_val == 640,
           "width 整数往返（parse_integers 语义）");
    found_tiles, tiles := table_find(*loaded.object_val, "tiles");
    expect(state, found_tiles && tiles.kind == .Array && tiles.array_val.count == 2, "数组往返");
    ENC.json_destroy_value(loaded);
    file_delete(".tmp_test_json.json");

    // 严格词法：尾随逗号必须报 Parse_Error
    expect(state, write_entire_file(".tmp_test_json_bad.json", "{\"a\":1,}"), "写入非法 JSON");
    defer file_delete(".tmp_test_json_bad.json");
    bad, bad_err := ENC.json_load(".tmp_test_json_bad.json");
    expect(state, bad_err == .Parse_Error, "尾随逗号报 Parse_Error");
    ENC.json_destroy_value(bad);
}

json_struct_round_trip :: (state: *Test_State) {
    sd := Json_Save_Data.{ level = 3, health = 87.5, name = "hero" };
    expect(state, ENC.json_save_struct(".tmp_test_json_struct.json", *sd) == .None, "save_struct 成功");

    loaded_sd: Json_Save_Data;
    expect(state, ENC.json_load_struct(".tmp_test_json_struct.json", *loaded_sd) == .None, "load_struct 成功");
    expect(state, loaded_sd.level == 3, "level 往返");
    expect(state, loaded_sd.name == "hero", "name 往返");
    expect(state, loaded_sd.health == 87.5, "health 往返");
    file_delete(".tmp_test_json_struct.json");

    dg: Json_DGraph = .{ entry_id = 1, next_id = 3 };
    array_add(*dg.nodes, Json_DNode.{ id = 1, pos = .[35.0, 93.0], speaker = "NPC", text = "你好" });
    expect(state, ENC.json_save_struct(".tmp_test_json_arr.json", *dg) == .None, "save 结构+数组成功");

    loaded_dg: Json_DGraph;
    expect(state, ENC.json_load_struct(".tmp_test_json_arr.json", *loaded_dg) == .None, "load 结构+数组成功");
    expect(state, loaded_dg.nodes.count == 1, "动态数组元素个数往返");
    expect(state, loaded_dg.nodes[0].id == 1, "数组元素 id 往返");
    expect(state, loaded_dg.nodes[0].pos[1] == 93.0, "定长数组往返");
    expect(state, loaded_dg.nodes[0].text == "你好", "UTF-8 文本往返");
    expect(state, loaded_dg.entry_id == 1 && loaded_dg.next_id == 3, "graph 字段往返");
    file_delete(".tmp_test_json_arr.json");
}

//@endregion

//@region XML（旧实现没有 XML 断言，这里按 Libs/Engine/encoding/xml.jai 的公开行为补齐）

xml_parse_and_serialize :: (state: *Test_State) {
    doc := "<?xml version=\"1.0\"?><!--c--><root id=\"1\" name=\"a&amp;b\">text<child/>tail<![CDATA[<raw>]]></root>";
    root, err := ENC.xml_parse(doc);
    expect(state, err == .None && root != null, "xml_parse 成功");
    defer ENC.xml_destroy(root);
    expect(state, root.name == "root", "根元素名");
    name_value, name_ok := ENC.xml_attribute(root, "name");
    expect(state, name_ok && name_value == "a&b", "属性实体解码");
    id_value, id_ok := ENC.xml_attribute(root, "id");
    expect(state, id_ok && id_value == "1", "属性 id");
    missing_value, missing_ok := ENC.xml_attribute(root, "missing");
    expect(state, !missing_ok && missing_value == "", "缺属性返回空");
    child := ENC.xml_child(root, "child");
    expect(state, child != null && child.children.count == 0, "自闭合子元素");
    expect(state, ENC.xml_child(root, "nope") == null, "缺子元素返回 null");
    expect(state, root.children.count == 4, "混合内容节点数");
    expect(state, root.children[0].text == "text", "首文本节点");
    expect(state, root.children[2].text == "tail", "尾文本节点");
    expect(state, root.children[3].name == "" && root.children[3].text == "<raw>", "CDATA 文本节点");
    text := ENC.xml_string(root);
    expect(state, contains(text, "<root id=\"1\" name=\"a&amp;b\">"), "序列化保留属性转义");
    expect(state, contains(text, "<child/>"), "自闭合元素序列化");
    expect(state, contains(text, "&lt;raw&gt;"), "文本节点里的 < > 被转义");
    free(text);

    // 错误语义
    _, e1 := ENC.xml_parse("<a><b></a>");
    expect(state, e1 != .None, "标签不匹配报错");
    _, e2 := ENC.xml_parse("<a>&nope;</a>");
    expect(state, e2 != .None, "未知实体报错");
    _, e3 := ENC.xml_parse("<a>");
    expect(state, e3 != .None, "未闭合报错");
    _, e4 := ENC.xml_parse("");
    expect(state, e4 != .None, "空输入报错");

    // 往返：解析后再序列化再解析，元素名与文本不变。
    text2 := ENC.xml_string(root);
    again, e5 := ENC.xml_parse(text2);
    expect(state, e5 == .None && again != null, "序列化结果可再解析");
    if again != null {
        expect(state, again.name == "root", "往返根元素名");
        ENC.xml_destroy(again);
    }
    free(text2);
}
