#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/GraphicsBuffer.cs (VertexBuffer /
// IndexBuffer / StorageBuffer / ComputeStorageBuffer as one struct + kind).

Buffer_Kind :: enum {
    VERTEX;
    INDEX;
    STORAGE; // graphics storage read
    COMPUTE_STORAGE; // compute read-write
}

Graphics_Buffer :: struct {
    device: *Graphics_Device;
    handle: Graphics_Resource_Handle;

    Kind: Buffer_Kind;
    Name: string;
    ElementSizeInBytes: s32;
    Format: Vertex_Format; // VERTEX only
    IndexFormat: Index_Format; // INDEX only

    Count: s32;
    is_disposed: bool;
}

vertex_buffer_create :: (device: *Graphics_Device, format: Vertex_Format, name := "") -> *Graphics_Buffer {
    b := New(Graphics_Buffer);
    b.device = device;
    b.Kind = .VERTEX;
    b.Name = name;
    b.Format = format;
    b.ElementSizeInBytes = format.Stride;
    b.handle = graphics_device_create_buffer(device, name, .VERTEX, .SIXTEEN);
    return b;
}

index_buffer_create :: (device: *Graphics_Device, format: Index_Format, name := "") -> *Graphics_Buffer {
    b := New(Graphics_Buffer);
    b.device = device;
    b.Kind = .INDEX;
    b.Name = name;
    b.IndexFormat = format;
    b.ElementSizeInBytes = index_format_size_in_bytes(format);
    b.handle = graphics_device_create_buffer(device, name, .INDEX, format);
    return b;
}

storage_buffer_create :: (device: *Graphics_Device, element_size_in_bytes: s32, name := "") -> *Graphics_Buffer {
    b := New(Graphics_Buffer);
    b.device = device;
    b.Kind = .STORAGE;
    b.Name = name;
    b.ElementSizeInBytes = element_size_in_bytes;
    b.handle = graphics_device_create_buffer(device, name, .STORAGE, .SIXTEEN);
    return b;
}

compute_storage_buffer_create :: (device: *Graphics_Device, element_size_in_bytes: s32, name := "") -> *Graphics_Buffer {
    b := New(Graphics_Buffer);
    b.device = device;
    b.Kind = .COMPUTE_STORAGE;
    b.Name = name;
    b.ElementSizeInBytes = element_size_in_bytes;
    b.handle = graphics_device_create_buffer(device, name, .COMPUTE_STORAGE, .SIXTEEN);
    return b;
}

buffer_upload :: (b: *Graphics_Buffer, data: *void, element_count: s32, element_offset := 0) {
    assert(!b.is_disposed && !b.device.disposed, "Trying to upload to a disposed DrawBuffer");
    b.Count = max(b.Count, cast(s32) (element_offset + element_count));
    graphics_device_upload_buffer_data(b.device, b.handle, data, cast(s32) (element_count * b.ElementSizeInBytes), cast(s32) (element_offset * b.ElementSizeInBytes));
}

buffer_upload_slice :: (b: *Graphics_Buffer, data: [] $T, element_offset := 0) {
    buffer_upload(b, cast(*void) data.data, cast(s32) data.count, element_offset);
}

buffer_clear :: (b: *Graphics_Buffer) {
    b.Count = 0;
}

buffer_dispose :: (b: *Graphics_Buffer) {
    if !b.is_disposed {
        graphics_device_destroy_resource(b.device, b.handle);
        b.is_disposed = true;
    }
}

buffer_is_disposed :: (b: *Graphics_Buffer) -> bool {
    return b.is_disposed || b.device.disposed;
}
