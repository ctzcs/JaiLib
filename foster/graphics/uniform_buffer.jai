#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/UniformBuffer.cs.
// A pure CPU-side byte blob; the SDL_GPU backend pushes its contents via
// SDL_PushGPU*UniformData on each draw (there is no GPU-side object).

Uniform_Buffer :: struct {
    bytes: [] u8;   // capacity
    count: s32;     // active bytes
}

uniform_buffer_set :: (u: *Uniform_Buffer, data: [] u8) {
    if data.count > u.bytes.count {
        // exact size (grows only); Foster resizes to data.Length
        new_bytes := array_copy(data);
        if u.bytes.count > 0 array_free(u.bytes);
        u.bytes = new_bytes;
        u.count = cast(s32) data.count;
        return;
    }
    if data.count > 0 memcpy(u.bytes.data, data.data, data.count);
    u.count = cast(s32) data.count;
}

// NOTE: takes the value BY POINTER. Taking the address of a by-value $T
// parameter is unreliable past ~32 bytes (spill area gets reused by nested
// calls), which silently corrupted Matrix4 uniforms.
uniform_buffer_set_value :: (u: *Uniform_Buffer, value: *$T) {
    uniform_buffer_set(u, slice_of_value(value));
}

uniform_buffer_get :: (u: *Uniform_Buffer) -> [] u8 {
    return array_view(u.bytes, 0, u.count);
}

uniform_buffer_get_value :: (u: *Uniform_Buffer) -> $T {
    result: T;
    if u.count >= size_of(T) {
        memcpy(*result, u.bytes.data, size_of(T));
    }
    return result;
}

uniform_buffer_copy_to :: (from: *Uniform_Buffer, to: *Uniform_Buffer) {
    if from.bytes.count > to.bytes.count {
        if to.bytes.count > 0 array_free(to.bytes);
        to.bytes = array_copy(from.bytes);
    } else if from.count > 0 {
        memcpy(to.bytes.data, from.bytes.data, from.count);
    }
    to.count = from.count;
}

uniform_buffer_equal_to :: (a: *Uniform_Buffer, b: *Uniform_Buffer) -> bool {
    if a.count != b.count return false;
    if a.count == 0 return true;
    return memcmp(a.bytes.data, b.bytes.data, a.count) == 0;
}

uniform_buffer_destroy :: (u: *Uniform_Buffer) {
    if u.bytes.count > 0 array_free(u.bytes);
    u.bytes = .[];
    u.count = 0;
}

// Helper: a [] u8 view over any small value.
// NOTE: takes the value BY POINTER — taking the address of a by-value $T
// parameter is only valid for the first ~32 bytes (register spill area),
// which silently corrupted larger payloads like Matrix4.
slice_of_value :: (value: *$T) -> [] u8 {
    return .{ data = cast(*u8) value, count = xx size_of(T) };
}
