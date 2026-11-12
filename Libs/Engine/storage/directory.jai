// Desktop backend; the storage interface can also compile for WASM64.
FI :: #import "File";
FU :: #import "File_Utilities";
Directory_Storage :: struct { root: string; writable: bool; }
directory_storage_init :: (state: *Directory_Storage, root: string, writable: bool = false) -> bool {
    if root.count == 0 return false;
    if writable && !FI.make_directory_if_it_does_not_exist(root, true) return false;
    state.root = copy_string(root); state.writable = writable; return true;
}
directory_storage_destroy :: (state: *Directory_Storage) { free(state.root); <<state = .{}; }
directory_storage :: (state: *Directory_Storage) -> Storage {
    return .{user=state, read=directory_read, exists=directory_exists,
        write=ifx state.writable then directory_write else null,
        erase=ifx state.writable then directory_remove else null};
}
directory_path :: (state: *Directory_Storage, path: string) -> string { return tprint("%/%", state.root, path); }
directory_read :: (user: *void, path: string, allocator: Allocator) -> ([]u8, bool) {
    state := cast(*Directory_Storage) user;
    push_allocator(allocator);
    data, ok := FI.read_entire_file(directory_path(state, path), false, false);
    return .{data=data.data, count=data.count}, ok;
}
directory_exists :: (user: *void, path: string) -> bool { return FU.file_exists(directory_path(cast(*Directory_Storage) user, path)); }
directory_write :: (user: *void, path: string, bytes: []u8) -> bool {
    state := cast(*Directory_Storage) user;
    if !state.writable return false;
    full := directory_path(state, path);
    last: s64 = -1;
    for i: 0..full.count-1 if full[i] == 47 || full[i] == 92 last = i;
    if last > 0 && !FI.make_directory_if_it_does_not_exist(.{data=full.data,count=last}, true) return false;
    return FI.write_entire_file(full, bytes.data, bytes.count);
}
directory_remove :: (user: *void, path: string) -> bool {
    state := cast(*Directory_Storage) user;
    return state.writable && FI.file_delete(directory_path(state, path));
}



