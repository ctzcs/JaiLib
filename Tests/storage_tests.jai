#import "Basic";
#import "test_support";
S :: #import "storage";
SA :: #import "storage_assets";
A :: #import "asset";
notifications: s64;
changed :: (game: *S.Game_Storage, user: *void) { notifications += 1; }
embedded_read :: (user: *void, path: string, allocator: Allocator) -> ([]u8, bool) {
    if path != "hello.txt" return .[], false;
    push_allocator(allocator);
    str := copy_string("embedded"); return .{data=str.data,count=str.count}, true;
}
main :: () {
    t := test_begin();
    dir: S.Directory_Storage;
    expect(*t, S.directory_storage_init(*dir, ".test_tmp/storage/resources", true), "init resource directory");
    defer S.directory_storage_destroy(*dir);
    users: S.Directory_Storage;
    expect(*t, S.directory_storage_init(*users, ".test_tmp/storage/user", true), "init separate user directory");
    defer S.directory_storage_destroy(*users);
    game := S.Game_Storage.{user=S.directory_storage(*users), changed=changed};
    S.game_resources_set(*game, S.directory_storage(*dir));
    expect(*t, notifications == 1 && game.resources_revision == 1, "resource change notification");
    expect(*t, S.storage_write_text(*game.resources, "nested/hello.txt", "你好"), "write nested resource");
    bytes, ok := S.storage_read(*game.resources, "nested\\hello.txt");
    expect(*t, ok && string.{data=bytes.data,count=bytes.count} == "你好", "normalized UTF-8 read"); free(bytes.data);
    expect(*t, S.storage_write_text(*game.user, "save.json", "{\"level\":3}"), "user save");
    expect(*t, !S.storage_exists(*game.resources, "save.json"), "user and resource roots remain separate");
    expect(*t, S.storage_write_text(*game.user, "empty", ""), "write empty file");
    empty, empty_ok := S.storage_read(*game.user, "empty");
    expect(*t, empty_ok && empty.count == 0, "empty file succeeds"); free(empty.data);
    missing, missing_ok := S.storage_read(*game.user, "missing");
    expect(*t, !missing_ok && missing.count == 0, "missing file fails explicitly");
    for bad: string.["../outside", "a/../outside", "/absolute", "C:\\outside", "a//b", "a/./b", "a/", "file:stream", "CON.txt", "Lpt1", "a. ", ""] {
        expect(*t, !S.storage_write_text(*game.user, bad, "bad"), "reject unsafe path %", bad);
    }
    read_only := S.directory_storage(*dir); read_only.write = null; read_only.erase = null;
    expect(*t, !S.storage_write_text(*read_only, "nested/hello.txt", "oops"), "read-only backend rejects write");
    guid := A.guid_generate(); bridge := SA.Storage_Assets.{game=*game}; asset_storage := SA.storage_assets(*bridge);
    path := SA.asset_path(*bridge, guid);
    expect(*t, S.storage_write_text(*game.resources, path, "blob"), "write GUID fixture");
    blob, blob_ok := asset_storage.read(*asset_storage, guid, context.allocator);
    expect(*t, blob_ok && blob.count == 4 && asset_storage.exists(*asset_storage, guid), "GUID bridge uses current resource backend"); free(blob.data);
    S.game_resources_set(*game, .{read=embedded_read});
    data, embedded_ok := S.storage_read(*game.resources, "hello.txt");
    expect(*t, embedded_ok && data.count == 8 && notifications == 2 && game.resources_revision == 2, "replace with embedded backend"); free(data.data);
    expect(*t, !asset_storage.exists(*asset_storage, guid) && S.storage_exists(*game.user, "save.json"), "bridge follows swap; user saves survive");
    expect(*t, S.storage_remove(*game.user, "save.json") && !S.storage_exists(*game.user, "save.json"), "remove user file");
    if !test_summary("GameStorage", *t) exit(1);
}

