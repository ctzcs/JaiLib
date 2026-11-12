// Path-based storage, independent of SDL, graphics and ECS. Backend state is
// borrowed and must outlive its Storage handles. Reads return caller-owned bytes.
#import "Basic";


Storage :: struct {
    user: *void;
    read: #type (user: *void, path: string, allocator: Allocator) -> ([]u8, bool);
    write: #type (user: *void, path: string, bytes: []u8) -> bool;
    exists: #type (user: *void, path: string) -> bool;
    erase: #type (user: *void, path: string) -> bool;
}

Game_Storage :: struct {
    resources: Storage;
    user: Storage;
    resources_revision: u64;
    changed: #type (game: *Game_Storage, user: *void);
    changed_user: *void;
}
// Replacement does not dispose borrowed backend state. Notify on the caller's
// thread; managers can invalidate caches using resources_revision.
game_resources_set :: (game: *Game_Storage, resources: Storage) {
    game.resources = resources; game.resources_revision += 1;
    if game.changed != null game.changed(game, game.changed_user);
}
// Reject rooted paths, traversal, NUL, colon/ADS and Windows reserved names.
// Normalized result uses temporary storage and is valid until the next reset.
storage_path :: (path: string) -> (string, bool) {
    if path.count == 0 || path[0] == 47 || path[0] == 92 return "", false;
    out := copy_temporary_string(path);
    for 0..out.count-1 {
        c := out[it];
        if c == 0 || c == 58 || c < 32 || c == 34 || c == 60 || c == 62 || c == 124 || c == 63 || c == 42 return "", false;
        if c == 92 out[it] = 47;
    }
    start: s64;
    for i: 0..out.count {
        if i < out.count && out[i] != 47 continue;
        n := i - start;
        if n == 0 || (n == 1 && out[start] == 46) || (n == 2 && out[start] == 46 && out[start+1] == 46) return "", false;
        if out[i-1] == 46 || out[i-1] == 32 return "", false;
        stem_end := start;
        while stem_end < i && out[stem_end] != 46 stem_end += 1;
        stem := string.{data = out.data + start, count = stem_end-start};
        upper := copy_temporary_string(stem);
        for 0..upper.count-1 if upper[it] >= 97 && upper[it] <= 122 upper[it] -= 32;
        if upper == "CON" || upper == "PRN" || upper == "AUX" || upper == "NUL" return "", false;
        if upper.count == 4 && (string.{data=upper.data,count=3} == "COM" || string.{data=upper.data,count=3} == "LPT") && upper[3] >= 49 && upper[3] <= 57 return "", false;
        start = i + 1;
    }
    return out, true;
}
storage_read :: (storage: *Storage, path: string, allocator: Allocator = context.allocator) -> ([]u8, bool) {
    p, ok := storage_path(path);
    if !ok || storage.read == null return .[], false;
    bytes, success := storage.read(storage.user, p, allocator);
    return bytes, success;
}
storage_write :: (storage: *Storage, path: string, bytes: []u8) -> bool {
    p, ok := storage_path(path);
    if !ok || storage.write == null return false;
    return storage.write(storage.user, p, bytes);
}
storage_write_text :: (storage: *Storage, path: string, text: string) -> bool {
    return storage_write(storage, path, .{data=text.data, count=text.count});
}
storage_exists :: (storage: *Storage, path: string) -> bool {
    p, ok := storage_path(path);
    return ok && storage.exists != null && storage.exists(storage.user, p);
}
storage_remove :: (storage: *Storage, path: string) -> bool {
    p, ok := storage_path(path);
    return ok && storage.erase != null && storage.erase(storage.user, p);
}
#if OS != .WASM { #load "directory.jai"; }

