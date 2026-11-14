#import "Basic";
#import "test_support";
NS_FILE :: #import "File";
NS_NOTES :: #import "kit/tools/scene_notes";

notes_save_roundtrip_test :: (st: *Test_State) {
    path :: "build/tests/notes-regression.json";
    assert(NS_FILE.make_directory_if_it_does_not_exist("build/tests", true));
    // This file belongs exclusively to this regression, never to the editor.
    _ = NS_FILE.file_delete(path);
    s: NS_NOTES.Session;
    assert(NS_NOTES.init(*s, path) == .None);
    defer NS_NOTES.dispose(*s);
    id, error := NS_NOTES.add(*s, .{ scene = "regression", text = "中文原子保存", has_position = true, position = .{ 1, 2, 3 } }, true);
    assert(error == .None);
    assert(NS_NOTES.undo(*s) == .None && NS_NOTES.all(*s).count == 0);
    assert(NS_NOTES.redo(*s) == .None && NS_NOTES.all(*s).count == 1);
    assert(NS_NOTES.save(*s) == .None);
    reader: NS_NOTES.Session;
    assert(NS_NOTES.init(*reader, path) == .None);
    defer NS_NOTES.dispose(*reader);
    note, found := NS_NOTES.find(*reader, id);
    assert(found && note.text == "中文原子保存");
    assert(NS_NOTES.resolve(*reader, id, "external result") == .None);
    assert(NS_NOTES.save(*reader) == .None);
    disk, ok := NS_FILE.read_entire_file(path);
    assert(ok);
    defer free(disk.data);
    assert(NS_NOTES.save(*s) == .External_Change, "External edits must never be overwritten");
    after, read_ok := NS_FILE.read_entire_file(path);
    assert(read_ok && disk == after);
    free(after.data);
    assert(NS_NOTES.all(*s).count == 1 && NS_NOTES.all(*s)[0].status == NS_NOTES.PENDING);
    _ = NS_FILE.file_delete(path);
    expect(st, true, "Scene note save, UTF-8, history and external conflict");
}
