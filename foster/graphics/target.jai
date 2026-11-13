#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Target.cs.

Target_Attachment_Info :: struct {
    Format:      Texture_Format;
    Flags:       Texture_Flags;
    SampleCount: Sample_Count;
}

Target :: struct {
    device: *Graphics_Device;
    handle: Graphics_Resource_Handle;

    Name: string;
    Width:  s32;
    Height: s32;
    Attachments: [..] *Texture;

    is_disposed: bool;
}

// Creates a Target with a single Color attachment.
target_create :: (device: *Graphics_Device, width: s32, height: s32, name := "") -> *Target {
    infos: [1] Target_Attachment_Info;
    infos[0] = .{ Format = .COLOR, Flags = .NONE, SampleCount = .ONE };
    return target_create_attachments(device, width, height, infos, name);
}

target_create_formats :: (device: *Graphics_Device, width: s32, height: s32,
                          formats: [] Texture_Format, flags := Texture_Flags.NONE, name := "") -> *Target {
    infos: [16] Target_Attachment_Info;
    assert(formats.count <= 16);
    for f, i: formats  infos[i] = .{ Format = f, Flags = flags, SampleCount = .ONE };
    return target_create_attachments(device, width, height, array_view(infos, 0, formats.count), name);
}

target_create_attachments :: (device: *Graphics_Device, width: s32, height: s32,
                              attachments: [] Target_Attachment_Info, name := "") -> *Target {
    assert(width > 0 && height > 0, "Target width and height must be larger than 0");
    assert(attachments.count > 0, "Target needs at least 1 color attachment");

    t := New(Target);
    t.device = device;
    t.Name = name;
    t.Width = width;
    t.Height = height;
    t.handle = graphics_device_create_target(device, width, height);
    array_reserve(*t.Attachments, attachments.count);
    for a, i: attachments {
        attachment_name := ifx name != "" then tprint("%-Attachment%", name, i) else "";
        tex := New(Texture);
        tex.device = device;
        tex.Name = attachment_name;
        tex.Width = width;
        tex.Height = height;
        tex.Format = a.Format;
        tex.SampleCount = a.SampleCount;
        tex.IsTargetAttachment = true;
        tex.handle = graphics_device_create_texture(
            device, attachment_name, width, height, a.Format, a.Flags, a.SampleCount, t.handle);
        array_add(*t.Attachments, tex);
    }
    return t;
}

target_bounds :: (t: *Target) -> Rect_Int { return .{ 0, 0, t.Width, t.Height }; }
target_texture :: (t: *Target) -> *Texture { return t.Attachments[0]; }   // Foster: implicit operator Texture
target_is_disposed :: (t: *Target) -> bool { return t.is_disposed || t.device.disposed; }

target_dispose :: (t: *Target) {
    if !t.is_disposed {
        // destroying the container destroys its attachment textures
        for a: t.Attachments {
            graphics_device_destroy_resource(t.device, a.handle);
        }
        graphics_device_destroy_resource(t.device, t.handle);
        array_free(t.Attachments);
        t.is_disposed = true;
    }
}
