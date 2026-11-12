#import "Basic";
#import "Hash_Table";
GA :: #import "jfoster";
CPU :: #import "asset";
POOL :: #import "handle/handle_array/handle_array";
Texture_Handle :: struct { idx: u32; gen: u64; }
operator == :: (a: Texture_Handle, b: Texture_Handle) -> bool { return a.idx == b.idx && a.gen == b.gen; }
Texture_Record :: struct { texture: *GA.Texture; cpu: CPU.Asset_Handle; guid: CPU.Guid; references: s64; }
Texture_Manager :: struct {
    device: *GA.Graphics_Device;
    cpu: CPU.Asset_Manager;
    records: POOL.Pool(Texture_Record, Texture_Handle);
    by_guid: Table(CPU.Guid, Texture_Handle, CPU.guid_hash32, CPU.guid_equals);
}
textures_init :: (manager: *Texture_Manager, device: *GA.Graphics_Device, config: CPU.Asset_Manager_Config) -> CPU.Asset_Error {
    <<manager = .{}; manager.device = device;
    return CPU.assets_init(*manager.cpu, config);
}
texture_acquire_loaded :: (manager: *Texture_Manager, cpu: CPU.Asset_Handle) -> (Texture_Handle, CPU.Asset_Error) {
    guid := CPU.assets_guid(*manager.cpu, cpu);
    existing, cached := table_find(*manager.by_guid, guid);
    if cached { texture_retain(manager, existing); return existing, .None; }
    image := CPU.assets_get_image(*manager.cpu, cpu);
    if image == null { CPU.assets_unload(*manager.cpu, cpu); return .{}, .Kind_Mismatch; }
    texture := GA.texture_create_from_pixels(manager.device, cast(s32) image.width, cast(s32) image.height, image.pixels);
    if texture == null || texture.handle == 0 {
        if texture != null { GA.texture_dispose(texture); free(texture); }
        CPU.assets_unload(*manager.cpu, cpu); return .{}, .Import_Failed;
    }
    handle := POOL.add(*manager.records, Texture_Record.{texture = texture, cpu = cpu, guid = guid, references = 1});
    table_set(*manager.by_guid, guid, handle);
    return handle, .None;
}
texture_acquire :: (manager: *Texture_Manager, guid: CPU.Guid) -> (Texture_Handle, CPU.Asset_Error) {
    cpu, error := CPU.assets_load(*manager.cpu, guid);
    if error != .None return .{}, error;
    handle, result := texture_acquire_loaded(manager, cpu); return handle, result;
}
texture_acquire_path :: (manager: *Texture_Manager, path: string) -> (Texture_Handle, CPU.Asset_Error) {
    cpu, error := CPU.assets_load_path(*manager.cpu, path);
    if error != .None return .{}, error;
    handle, result := texture_acquire_loaded(manager, cpu); return handle, result;
}
texture_get :: (manager: *Texture_Manager, handle: Texture_Handle) -> *GA.Texture {
    record := POOL.get(manager.records, handle);
    if record == null return null;
    return record.texture;
}
texture_retain :: (manager: *Texture_Manager, handle: Texture_Handle) -> bool {
    record := POOL.get(manager.records, handle);
    if record == null return false;
    record.references += 1; return true;
}
texture_release :: (manager: *Texture_Manager, handle: Texture_Handle) -> bool {
    record := POOL.get(manager.records, handle);
    if record == null return false;
    record.references -= 1;
    if record.references > 0 return true;
    table_remove(*manager.by_guid, record.guid);
    CPU.assets_unload(*manager.cpu, record.cpu);
    GA.texture_dispose(record.texture); free(record.texture);
    POOL.remove_handle(*manager.records, handle); return true;
}
textures_destroy :: (manager: *Texture_Manager) {
    it := POOL.begin(*manager.records);
    while true {
        record, handle, ok := POOL.next(*it); if !ok break;
        GA.texture_dispose(record.texture); free(record.texture);
    }
    POOL.delete(*manager.records); deinit(*manager.by_guid);
    CPU.assets_dispose(*manager.cpu); <<manager = .{};
}
