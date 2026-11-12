#import "Basic";
#import "test_support";
E :: #import "entities";
W :: #import "world";
MSG :: #import "messaging";
J :: #import "threading";
X :: #import "encoding";
FI :: #import "File";

Screen :: enum { Menu; Game; Pause; }
Reentry :: struct { queue: *MSG.Command_Queue(s64); sum: s64; }
consume :: (value: s64, user: *void) {
    data := cast(*Reentry) user;
    data.sum += value;
    MSG.command_enqueue(data.queue, 10);
}
sum_range :: (first: s64, end: s64, user: *void, worker: s64) {
    values := cast(*s64) user;
    for i: first..end-1 values[i] = i * i;
}
main :: () {
    state := test_begin();
    document, xml_error := X.xml_parse("<?xml version=\"1.0\"?><root id='A&amp;B'>你好<item>&#x1F600;</item><![CDATA[<raw>]]></root>");
    expect(*state, xml_error == .None && document != null, "XML parses attributes, UTF-8, entities and CDATA");
    if document != null {
        defer X.xml_destroy(document);
        attr, found := X.xml_attribute(document, "id");
        expect(*state, found && attr == "A&B", "XML decodes attribute entities");
        item := X.xml_child(document, "item");
        expect(*state, item != null && item.children[0].text == "😀", "XML numeric entities encode supplementary Unicode");
        encoded := X.xml_string(document); defer free(encoded);
        again, parse_error := X.xml_parse(encoded);
        expect(*state, parse_error == .None && again.children.count == 3, "XML preserves ordered mixed content on roundtrip");
        X.xml_destroy(again);
        _ := FI.make_directory_if_it_does_not_exist(".test_tmp", true);
        expect(*state, X.xml_save(".test_tmp/core-document.xml", document) == .None, "XML saves owned tree");
        loaded, load_error := X.xml_load(".test_tmp/core-document.xml");
        expect(*state, load_error == .None && loaded != null, "XML loads file through public API");
        X.xml_destroy(loaded);
    }
    invalid_utf8 := u8.[60, 97, 62, 0xc0, 0xaf, 60, 47, 97, 62];
    invalid, utf_error := X.xml_parse(.{data = invalid_utf8.data, count = invalid_utf8.count});
    expect(*state, invalid == null && utf_error == .Invalid, "XML rejects overlong UTF-8");
    for malformed: string.["<a></b>", "<a x='1' x='2'/>", "<a>&unknown;</a>", "<a>&#0;</a>", "<a/ ><b/>", "<a>", "<!DOCTYPE a><a/>", "<a>bad]]>text</a>", "<!--bad--comment--><a/>"] {
        bad, error := X.xml_parse(malformed);
        expect(*state, bad == null && error != .None, "XML rejects malformed or unsupported input %", malformed);
    }
    router: W.Scene_Router(Screen);
    W.scene_init(*router, .Menu); W.scene_switch(*router, .Game, 1);
    W.scene_update(*router, 0.25);
    expect(*state, router.current == .Game && router.previous == .Menu && router.progress == 0.25, "scene transition tracks both screens");
    W.scene_update(*router, -1); expect(*state, router.progress == 0.25, "negative dt cannot reverse scene transition");
    W.scene_update(*router, 2); expect(*state, !router.transitioning && router.progress == 1, "scene transition clamps completion");
    queue: MSG.Command_Queue(s64); defer MSG.command_destroy(*queue);
    MSG.command_enqueue(*queue, 1); MSG.command_enqueue(*queue, 2);
    data := Reentry.{queue = *queue};
    drained := MSG.command_drain(*queue, consume, *data);
    expect(*state, drained == 2 && data.sum == 3 && MSG.command_count(*queue) == 2, "drain snapshots initial batch while callbacks enqueue");
    channel: MSG.Broadcast_Channel(s64); defer MSG.broadcast_destroy(*channel);
    MSG.broadcast_publish(*channel, 42);
    expect(*state, MSG.broadcast_messages(*channel).count == 0, "broadcast delayed until next frame");
    MSG.broadcast_advance(*channel);
    MSG.broadcast_publish(*channel, 99);
    expect(*state, MSG.broadcast_messages(*channel)[0] == 42, "all consumers see immutable current frame");
    MSG.broadcast_advance(*channel);
    expect(*state, MSG.broadcast_messages(*channel).count == 1 && MSG.broadcast_messages(*channel)[0] == 99, "broadcast swaps instead of accumulating");
    Item :: struct { base: E.Base; }
    entities: E.Entities; E.init(*entities, .[Item], .[], default_cap = 70002); defer E.shutdown(*entities);
    old, _ := E.create(*entities, Item.{});
    current := old;
    for 0..999 { assert(E.destroy(*entities, current)); current, _ = E.create(*entities, Item.{}); }
    _, valid := E.get(*entities, old);
    expect(*state, !valid, "old entity handle stays invalid after 1000 slot reuses");
    for 0..69999 { added, ok := E.create(*entities, Item.{}); assert(ok); }
    expect(*state, entities.buffers[0].top == 70001, "entity indices exceed 65535");
    _, bogus := E.get(*entities, .{index = 0xffffffff, variant = 0});
    expect(*state, !bogus, "unsigned out-of-range entity index is rejected");
    E.clear(*entities); fresh, _ := E.create(*entities, Item.{});
    expect(*state, fresh.gen > old.gen, "clear preserves generation clock");
    entities.next_generation = 0xffffffffffffffff;
    _, wrapped := E.create(*entities, Item.{}); expect(*state, !wrapped, "entity generations never wrap");
    for workers: s64.[0, 3] {
        jobs: J.Job_Scheduler; assert(J.jobs_init(*jobs, workers, 3));
        values: [1000] s64;
        handle := J.jobs_schedule_range(*jobs, 1000, 7, sum_range, *values);
        J.job_complete(*jobs, handle);
        correct := true;
        for v, i: values if v != i * i correct = false;
        expect(*state, correct, "parallel range covers each item with % workers and bounded queue", workers);
        J.job_release(handle);
        empty := J.jobs_schedule_range(*jobs, 0, 7, sum_range, *values);
        expect(*state, J.job_done(empty), "empty parallel range completes immediately"); J.job_release(empty);
        pending := J.jobs_schedule_range(*jobs, 1000, 5, sum_range, *values);
        J.jobs_destroy(*jobs);
        expect(*state, J.job_done(pending), "shutdown drains outstanding jobs"); J.job_release(pending);
    }
    if !test_summary("engine core", *state) exit(1);
}
