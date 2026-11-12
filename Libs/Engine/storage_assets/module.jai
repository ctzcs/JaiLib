// Optional bridge: the GUID loader reads Library/<guid>.blob through the current
// Game_Storage resource backend. Reload existing managers after replacement.
#import "Basic";
S :: #import "storage";
A :: #import "asset";
Storage_Assets :: struct { game: *S.Game_Storage; prefix: string = "Library"; }
storage_assets :: (state: *Storage_Assets) -> A.Asset_Storage {
    return .{userdata=state, read=read_asset, exists=exists_asset};
}
asset_path :: (state: *Storage_Assets, guid: A.Guid) -> string {
    buf: [37] u8;
    name, ok := A.guid_filename(guid, .{data=buf.data,count=buf.count});
    if !ok return "";
    if state.prefix.count == 0 return copy_temporary_string(name);
    return tprint("%/%", state.prefix, name);
}
read_asset :: (storage: *A.Asset_Storage, guid: A.Guid, allocator: Allocator) -> ([]u8, bool) {
    state := cast(*Storage_Assets) storage.userdata;
    data, ok := S.storage_read(*state.game.resources, asset_path(state, guid), allocator);
    return data, ok;
}
exists_asset :: (storage: *A.Asset_Storage, guid: A.Guid) -> bool {
    state := cast(*Storage_Assets) storage.userdata;
    return S.storage_exists(*state.game.resources, asset_path(state, guid));
}

