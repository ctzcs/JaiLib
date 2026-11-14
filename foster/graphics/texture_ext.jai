#scope_module
using Basic; // module-private
using Math;
#scope_export

// olib extension to the Graphics layer — NOT part of upstream Foster.
//
// Port of the "Graphics / Texture Sampling" section of olib's
// <olib>/foster/olib_ext.odin, registration L-018 in
// <olib>/foster/docs/LOCAL_CHANGES.md.
//
//   L-018  texture_is_sampleable / texture_ext_depth_attachment_sampleable
//
// Foster has no such query: material binding simply assumed every Texture can
// be sampled, which is true for ordinary textures but not for attachments
// (a depth target used only as a depth buffer, or a multisampled attachment the
// backend cannot resolve). olib added the predicate for exactly that case and
// uses it at material-binding time; here it is a standalone query so nothing in
// the 1:1 port (material.jai, texture.jai, target.jai) has to change.
//
// This file is where it belongs by component (Texture), which is the jfoster
// convention — app_ext.jai / storage_ext.jai hold the App and Storage halves of
// the same olib port.

// [olib L-018] Whether `tex` can be bound to a material sampler.
//
// Ordinary textures are always sampleable. Target attachment textures follow
// the rule the backend uses when it builds the texture:
//   * color attachment: sampleable when it is single-sampled (the texture
//     itself carries SDL_GPU_TEXTUREUSAGE_SAMPLER) or when the backend made a
//     resolve texture for it (MSAA samples come from the resolve copy);
//   * depth(-stencil) attachment: only single-sampled ones are sampleable —
//     SDL has no depth resolve texture, so a multisampled depth target cannot be
//     read at all.
//
// The "is a resolve texture present" question has no public field in jfoster:
// the backend stores it in the device's resource table (GPU_Resource
// .multi_sample_resolve), so it is read through sdl_find_resource — the same
// seam texture_set_data / draw use. See texture_ext_resolve_handle.
texture_is_sampleable :: (tex: *Texture) -> bool {
    if tex == null || tex.handle == 0 || tex.device == null return false;
    if texture_is_disposed(tex) return false;

    // Not an attachment (no target owns it): created with SAMPLER usage, or, if
    // multisampled, with a resolve copy that carries it. Always sampleable.
    if !tex.IsTargetAttachment return true;

    if texture_format_is_color(tex.Format) {
        return tex.SampleCount == .ONE || texture_ext_resolve_handle(tex) != 0;
    }
    return texture_ext_depth_attachment_sampleable(tex.device, tex.Format, tex.SampleCount);
}

// [olib L-018] Multisampled depth cannot be sampled (SDL has no depth resolve);
// a single-sampled one is sampleable only when the device can sample that depth
// format at all — the same check that decides whether the texture could be
// created with SDL_GPU_TEXTUREUSAGE_SAMPLER in the first place.
texture_ext_depth_attachment_sampleable :: (device: *Graphics_Device, format: Texture_Format,
                                            sample_count: Sample_Count) -> bool {
    if sample_count != .ONE return false;
    if device == null || device.device == null return false;
    return graphics_device_is_texture_format_supported(device, format);
}

// The resolve texture handle the backend created for `tex`, or 0 when it has
// none (single-sampled textures, and every texture whose creation failed to
// need one). Foster keeps the equivalent as Texture.ResolveResource; jfoster
// keeps it in the device's resource table instead.
texture_ext_resolve_handle :: (tex: *Texture) -> Graphics_Resource_Handle {
    if tex == null || tex.device == null || tex.handle == 0 return 0;
    res := sdl_find_resource(tex.device, tex.handle);
    if res == null return 0;
    return res.multi_sample_resolve;
}
