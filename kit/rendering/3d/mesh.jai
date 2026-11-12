// rendering3d:mesh —— dasset 顶点 -> jfoster Mesh 上传（对位 DragonLib MeshUpload3D）。
// 一比一移植自 olib kit/rendering/3d/mesh.odin。
//
// Jai 侧差异（逐条对应 olib 的写法；顶点格式、步长与上传的字节布局不变）：
//   | olib (Odin)                                   | JaiLib (Jai)                                             |
//   | --------------------------------------------- | -------------------------------------------------------- |
//   | `foster.VertexFormat`（值 + 堆上的 Elements）    | F.Vertex_Format（值，Elements 是定长数组，无需 Dispose）    |
//   | `foster.VertexElement{0, .Float3, false}`      | F.Vertex_Format_Element.{ 0, .FLOAT3, false }（jfoster     |
//   |                                               | 的枚举成员全大写）                                          |
//   | `foster.VertexFormatMake(elements, stride)`    | F.vertex_format_make（stride 形参是 s32）                  |
//   | `foster.Mesh`（值类型）                         | *F.Mesh（jfoster 的 Mesh 是 mesh_create 里 New 出来的）      |
//   | `foster.MeshInitWithFormat(&mesh, dev, …)`     | threed_mesh_init：F.mesh_create 后把内容搬到调用方的 Mesh 值  |
//   |                                               | （签名仍是 `mesh: ^foster.Mesh`，位置不变，不额外分配结构体）    |
//   | `foster.MeshSetVertexCount / SetVertices`      | F.mesh_set_vertex_count / F.mesh_set_vertices              |
//   | `foster.MeshSetIndexCount / SetIndices`        | F.mesh_set_index_count / F.mesh_set_indices                |
//   | `foster.VertexBufferDispose(&mesh.VertexData)` | threed_buffer_release：还 GPU 资源 + free 掉堆上的          |
//   | `foster.IndexBufferDispose(&mesh.IndexData)`   | *F.Graphics_Buffer（jfoster 的 mesh_dispose 不 free，会漏）  |
//   | `p.skin_vertices == nil`                       | p.skin_vertices.data == null                             |
//   | `len(x)`                                       | x.count / cast(s32) 后喂给 Jai 的 s32 计数                 |
//   | `.ThirtyTwo`                                   | .THIRTY_TWO                                              |
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）。

//@region 顶点格式 —— 静态 / 蒙皮

// 静态顶点格式：Float3 位置 + Float3 法线 + Float2 UV + Float4 切线（48B）。
mesh_static_format :: () -> F.Vertex_Format {
    elements: [4] F.Vertex_Format_Element = .[
        F.Vertex_Format_Element.{ 0, .FLOAT3, false },
        F.Vertex_Format_Element.{ 1, .FLOAT3, false },
        F.Vertex_Format_Element.{ 2, .FLOAT2, false },
        F.Vertex_Format_Element.{ 3, .FLOAT4, false },
    ];
    return F.vertex_format_make(array_view(elements, 0, 4), DA.DASSET_VERTEX_STRIDE_STATIC);
}

// 蒙皮顶点格式：静态布局 + UByte4 关节 + Float4 权重（68B）。
mesh_skin_format :: () -> F.Vertex_Format {
    elements: [6] F.Vertex_Format_Element = .[
        F.Vertex_Format_Element.{ 0, .FLOAT3, false },
        F.Vertex_Format_Element.{ 1, .FLOAT3, false },
        F.Vertex_Format_Element.{ 2, .FLOAT2, false },
        F.Vertex_Format_Element.{ 3, .FLOAT4, false },
        F.Vertex_Format_Element.{ 4, .UBYTE4, false },
        F.Vertex_Format_Element.{ 5, .FLOAT4, false },
    ];
    return F.vertex_format_make(array_view(elements, 0, 6), DA.DASSET_VERTEX_STRIDE_SKIN);
}
//@endregion

//@region 上传 —— dasset primitive -> jfoster Mesh

// olib: foster.MeshInitWithFormat(&mesh, device, format, .ThirtyTwo, name)。
// jfoster 的 mesh_create 直接 New 出 Mesh 与两个缓冲；这里把内容搬进调用方持有的 Mesh 值，
// 让 mesh_upload 的签名与 olib 一样是「初始化传入的 mesh」而不是「返回新 mesh」。
threed_mesh_init :: (mesh: *F.Mesh, device: *F.Graphics_Device, format: F.Vertex_Format,
                     index_format: F.Index_Format, name: string) {
    created := F.mesh_create(device, format, index_format, name);
    mesh.* = created.*;
    free(created); // 只还 Mesh 结构体本身；两个缓冲已随内容搬给调用方
}

// olib: foster.VertexBufferDispose / IndexBufferDispose（jfoster 不会 free 堆上的缓冲结构体）。
threed_buffer_release :: (buffer: *F.Graphics_Buffer) {
    if buffer == null return;
    if buffer.handle != 0 && buffer.device != null && !buffer.device.disposed && !buffer.is_disposed {
        F.buffer_dispose(buffer);
    }
    free(buffer);
}

// 把 dasset primitive 的顶点/索引整块上传为 jfoster Mesh。
// 顶点是普通 struct，但 dasset 布局与格式步长一致，直接按字节整块拷贝。
// 失败（空 primitive / 无 device）返回 false。
mesh_upload :: (mesh: *F.Mesh, device: *F.Graphics_Device, p: *DA.Dasset_Primitive, name := "") -> bool {
    if device == null return false;

    skinned := DA.dasset_primitive_is_skinned(p);
    format: F.Vertex_Format;
    if skinned format = mesh_skin_format();
    else format = mesh_static_format();
    threed_mesh_init(mesh, device, format, .THIRTY_TWO, name);

    if skinned {
        if p.skin_vertices.data == null return false;
        F.mesh_set_vertex_count(mesh, cast(s32) p.skin_vertices.count);
        F.mesh_set_vertices(mesh, p.skin_vertices);
    } else {
        if p.vertices.data == null return false;
        F.mesh_set_vertex_count(mesh, cast(s32) p.vertices.count);
        F.mesh_set_vertices(mesh, p.vertices);
    }
    F.mesh_set_index_count(mesh, cast(s32) p.indices.count);
    F.mesh_set_indices(mesh, p.indices);
    return true;
}

// 释放 Mesh 的 GPU 缓冲。终止态调用；Mesh 结构体本身由调用方 free（若是 mesh_create 出来的）。
mesh_dispose :: (mesh: *F.Mesh) {
    if mesh == null return;
    threed_buffer_release(mesh.VertexBuffer);
    threed_buffer_release(mesh.IndexBuffer);
    if mesh.InstanceBuffer != null threed_buffer_release(mesh.InstanceBuffer);
    mesh.* = F.Mesh.{};
}
//@endregion
