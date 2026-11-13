#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Mesh.cs.
// The C# generic Mesh<T,...> variants flatten to one Mesh; typed uploads are
// polymorphic procs (mesh_set_vertices etc.).

Mesh :: struct {
    device: *Graphics_Device;
    Name:   string;

    VertexBuffer:   *Graphics_Buffer;
    InstanceBuffer: *Graphics_Buffer = null;   // optional
    IndexBuffer:    *Graphics_Buffer;
}

mesh_create :: (device: *Graphics_Device, vertex_format: Vertex_Format, index_format: Index_Format, name := "") -> *Mesh {
    m := New(Mesh);
    m.device = device;
    m.Name = name;
    m.VertexBuffer = vertex_buffer_create(device, vertex_format, ifx name != "" then tprint("%-Vertices", name) else "");
    m.IndexBuffer  = index_buffer_create(device, index_format,  ifx name != "" then tprint("%-Indices",  name) else "");
    return m;
}

mesh_create_instanced :: (device: *Graphics_Device, vertex_format: Vertex_Format, instance_format: Vertex_Format,
                          index_format: Index_Format, name := "") -> *Mesh {
    m := mesh_create(device, vertex_format, index_format, name);
    m.InstanceBuffer = vertex_buffer_create(device, instance_format, ifx name != "" then tprint("%-Instances", name) else "");
    return m;
}

mesh_is_disposed :: (m: *Mesh) -> bool {
    return buffer_is_disposed(m.VertexBuffer) ||
           (m.InstanceBuffer != null && buffer_is_disposed(m.InstanceBuffer)) ||
           buffer_is_disposed(m.IndexBuffer);
}

mesh_vertex_count :: (m: *Mesh) -> s32 { return m.VertexBuffer.Count; }
mesh_instance_count :: (m: *Mesh) -> s32 { return ifx m.InstanceBuffer != null then m.InstanceBuffer.Count else 0; }
mesh_index_count :: (m: *Mesh) -> s32 { return m.IndexBuffer.Count; }
mesh_vertex_format :: (m: *Mesh) -> Vertex_Format { return m.VertexBuffer.Format; }
mesh_instance_format :: (m: *Mesh) -> Vertex_Format { return ifx m.InstanceBuffer != null then m.InstanceBuffer.Format else Vertex_Format.{}; }
mesh_index_format :: (m: *Mesh) -> Index_Format { return m.IndexBuffer.IndexFormat; }

mesh_clear :: (m: *Mesh) {
    buffer_clear(m.VertexBuffer);
    if m.InstanceBuffer != null buffer_clear(m.InstanceBuffer);
    buffer_clear(m.IndexBuffer);
}

// Grows Count without uploading data (resize-only, like Foster).
mesh_set_index_count :: (m: *Mesh, count: s32) {
    buffer_clear(m.IndexBuffer);
    buffer_upload(m.IndexBuffer, null, 0, count);
}

mesh_set_vertex_count :: (m: *Mesh, count: s32) {
    buffer_clear(m.VertexBuffer);
    buffer_upload(m.VertexBuffer, null, 0, count);
}

mesh_set_instance_count :: (m: *Mesh, count: s32) {
    assert(m.InstanceBuffer != null, "Mesh does not contain an instance buffer");
    buffer_clear(m.InstanceBuffer);
    buffer_upload(m.InstanceBuffer, null, 0, count);
}

mesh_set_indices :: (m: *Mesh, data: [] $I, offset := 0) {
    buffer_upload_slice(m.IndexBuffer, data, offset);
}

mesh_set_vertices :: (m: *Mesh, data: [] $V, offset := 0) {
    buffer_upload_slice(m.VertexBuffer, data, offset);
}

mesh_set_instances :: (m: *Mesh, data: [] $V, offset := 0) {
    assert(m.InstanceBuffer != null, "Mesh does not contain an instance buffer");
    buffer_upload_slice(m.InstanceBuffer, data, offset);
}

mesh_dispose :: (m: *Mesh) {
    buffer_dispose(m.VertexBuffer);
    if m.InstanceBuffer != null buffer_dispose(m.InstanceBuffer);
    buffer_dispose(m.IndexBuffer);
}
