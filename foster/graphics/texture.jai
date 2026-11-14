#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Texture.cs.

Texture :: struct {
    device: *Graphics_Device;
    handle: Graphics_Resource_Handle;

    Name: string;
    Width: s32;
    Height: s32;
    Format: Texture_Format;
    SampleCount: Sample_Count;
    IsTargetAttachment: bool;

    is_disposed: bool;
}

texture_create :: (device: *Graphics_Device, width: s32, height: s32,
                   format := Texture_Format.COLOR, flags := Texture_Flags.NONE,
                   sample_count := Sample_Count.ONE, name := "") -> *Texture {
    assert(width > 0 && height > 0, "Texture must have a size larger than 0");
    t := New(Texture);
    t.device = device;
    t.Name = name;
    t.Width = width;
    t.Height = height;
    t.Format = format;
    t.SampleCount = sample_count;
    t.IsTargetAttachment = false;
    t.handle = graphics_device_create_texture(device, name, width, height, format, flags, sample_count, 0);
    return t;
}

texture_create_from_pixels :: (device: *Graphics_Device, width: s32, height: s32,
                               pixels: [] u8, flags := Texture_Flags.NONE, name := "") -> *Texture {
    t := texture_create(device, width, height, .COLOR, flags, name = name);
    texture_set_data(t, pixels);
    return t;
}

texture_create_from_colors :: (device: *Graphics_Device, width: s32, height: s32,
                               pixels: [] Color, flags := Texture_Flags.NONE, name := "") -> *Texture {
    t := texture_create(device, width, height, .COLOR, flags, name = name);
    texture_set_data(t, pixels);
    return t;
}

texture_size :: (t: *Texture) -> Point2 {
    return .{ t.Width, t.Height };
}

texture_memory_size :: (t: *Texture) -> s32 {
    return t.Width * t.Height * texture_format_size(t.Format);
}

texture_is_disposed :: (t: *Texture) -> bool {
    return t.is_disposed || t.device.disposed;
}

// Uploads raw data covering the whole texture.
texture_set_data :: (t: *Texture, data: [] $T) {
    texture_set_data_region(t, data, .{ 0, 0, t.Width, t.Height });
}

// Uploads raw data into a destination region (bounds-checked like Foster).
texture_set_data_region :: (t: *Texture, data: [] $T, dest_region: Rect_Int) {
    assert(!texture_is_disposed(t), "Resource is Disposed");
    assert(dest_region.x >= 0 && dest_region.y >= 0 &&
           dest_region.y + dest_region.h <= t.Height && dest_region.x + dest_region.w <= t.Width,
           "Destination region is out of range");
    data_length := size_of(T) * data.count;
    assert(data_length >= dest_region.w * dest_region.h * texture_format_size(t.Format),
           "Data Buffer is smaller than the Size of the Texture Destination");
    graphics_device_set_texture_data(t.device, t.handle, cast(*void) data.data, cast(s32) data_length, dest_region);
}

// Downloads the whole texture.
texture_get_data :: (t: *Texture, data: [] $T) {
    texture_get_data_region(t, data, .{ 0, 0, t.Width, t.Height });
}

texture_get_data_region :: (t: *Texture, data: [] $T, source_region: Rect_Int) {
    assert(!texture_is_disposed(t), "Resource is Disposed");
    assert(source_region.x >= 0 && source_region.y >= 0 &&
           source_region.y + source_region.h <= t.Height && source_region.x + source_region.w <= t.Width,
           "Source region is out of range");
    data_length := size_of(T) * data.count;
    assert(data_length >= source_region.w * source_region.h * texture_format_size(t.Format),
           "Data Buffer is smaller than the Size of the Texture Source");
    graphics_device_get_texture_data(t.device, t.handle, cast(*void) data.data, cast(s32) data_length, source_region);
}

texture_blit :: (t: *Texture, dest: *Texture, filter := Texture_Filter.LINEAR) {
    src_rect := Rect_Int.{ 0, 0, t.Width, t.Height };
    dest_rect := Rect_Int.{ 0, 0, dest.Width, dest.Height };
    graphics_device_blit_texture(t.device, t.handle, src_rect, dest.handle, dest_rect, filter);
}

texture_blit_region :: (t: *Texture, src_rect: Rect_Int, dest: *Texture, dest_rect: Rect_Int, filter := Texture_Filter.LINEAR) {
    graphics_device_blit_texture(t.device, t.handle, src_rect, dest.handle, dest_rect, filter);
}

texture_dispose :: (t: *Texture) {
    if !t.is_disposed {
        if !t.IsTargetAttachment { // the owning Target destroys the attachment
            graphics_device_destroy_resource(t.device, t.handle);
        }
        t.is_disposed = true;
    }
}
