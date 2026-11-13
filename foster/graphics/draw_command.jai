#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Structs/DrawCommand.cs + ComputeCommand.cs
// + Interfaces/IDrawableTarget.cs.
// C# StackLists become fixed arrays + counts; IDrawableTarget becomes a
// kind-tagged struct (Window or Target).

MAX_BOUND_SAMPLERS :: 16;
MAX_UNIFORM_BUFFERS :: 8;
MAX_VERTEX_BUFFERS  :: 4;
MAX_STORAGE_BUFFERS :: 4;
MAX_TARGET_ATTACHMENTS :: 8;

Drawable_Target_Kind :: enum { NONE; WINDOW; TARGET; }

// Something that can be drawn to: a Window (its backbuffer) or a Target.
Drawable_Target :: struct {
    Kind:   Drawable_Target_Kind = .NONE;
    window: *Window = null;
    target: *Target = null;
}

drawable_target_window :: (w: *Window) -> Drawable_Target { return .{ Kind = .WINDOW, window = w }; }
drawable_target_target :: (t: *Target) -> Drawable_Target { return .{ Kind = .TARGET, target = t }; }

drawable_target_width_in_pixels :: (d: Drawable_Target) -> s32 {
    if d.Kind == {
        case .WINDOW; return window_width_in_pixels(d.window);
        case .TARGET; return d.target.Width;
        case .NONE;   return 0;
    }
    return 0;
}

drawable_target_height_in_pixels :: (d: Drawable_Target) -> s32 {
    if d.Kind == {
        case .WINDOW; return window_height_in_pixels(d.window);
        case .TARGET; return d.target.Height;
        case .NONE;   return 0;
    }
    return 0;
}

Vertex_Buffer_Binding :: struct {
    Buffer:              *Graphics_Buffer;
    InstanceInputRate:   bool;
}

Draw_Command :: struct {
    Target:          Drawable_Target;
    FragmentShader:  *Shader = null;
    VertexShader:    *Shader = null;

    FragmentSamplers: [MAX_BOUND_SAMPLERS] Bound_Sampler;  FragmentSamplerCount: s32 = 0;
    VertexSamplers:   [MAX_BOUND_SAMPLERS] Bound_Sampler;  VertexSamplerCount:   s32 = 0;

    FragmentUniformBuffers: [MAX_UNIFORM_BUFFERS] *Uniform_Buffer;  FragmentUniformBufferCount: s32 = 0;
    VertexUniformBuffers:   [MAX_UNIFORM_BUFFERS] *Uniform_Buffer;  VertexUniformBufferCount:   s32 = 0;

    VertexBuffers: [MAX_VERTEX_BUFFERS] Vertex_Buffer_Binding;  VertexBufferCount: s32 = 0;

    VertexStorageBuffers:   [MAX_STORAGE_BUFFERS] *Graphics_Buffer;  VertexStorageBufferCount:   s32 = 0;
    FragmentStorageBuffers: [MAX_STORAGE_BUFFERS] *Graphics_Buffer;  FragmentStorageBufferCount: s32 = 0;

    IndexBuffer:  *Graphics_Buffer = null;
    IndexOffset:  s32 = 0;
    IndexCount:   s32 = 0;
    VertexOffset: s32 = 0;
    VertexCount:  s32 = 0;
    InstanceCount: s32 = 1;

    BlendMode:     Blend_Mode = Blend_Mode_Premultiply;
    CullMode:      Cull_Mode = .NONE;
    DepthCompare:  Depth_Compare = .LESS;
    FillMode:      Fill_Mode = .FILL;
    BackStencilState:  Stencil_State = .{ FailOp = .KEEP, PassOp = .KEEP, DepthFailOp = .KEEP, CompareOp = .ALWAYS };
    FrontStencilState: Stencil_State = .{ FailOp = .KEEP, PassOp = .KEEP, DepthFailOp = .KEEP, CompareOp = .ALWAYS };
    StencilCompareMask:  u8 = 0xFF;
    StencilWriteMask:   u8 = 0xFF;
    StencilReferenceValue: u8 = 0;

    DepthTestEnabled:   bool = false;
    DepthWriteEnabled:  bool = false;
    StencilTestEnabled: bool = false;

    Viewport: Rect_Int;  HasViewport: bool = false;
    Scissor:  Rect_Int;  HasScissor:  bool = false;
}

// Draws a mesh with a material (Foster: DrawCommand(target, mesh, material)).
draw_command_from_mesh :: (target: Drawable_Target, mesh: *Mesh, material: *Material) -> Draw_Command {
    cmd := draw_command_from_material(target, material);

    if mesh.InstanceBuffer != null {
        cmd.VertexBuffers[0] = .{ Buffer = mesh.VertexBuffer, InstanceInputRate = false };
        cmd.VertexBuffers[1] = .{ Buffer = mesh.InstanceBuffer, InstanceInputRate = true };
        cmd.VertexBufferCount = 2;
        cmd.InstanceCount = mesh.InstanceBuffer.Count;
    } else {
        cmd.VertexBuffers[0] = .{ Buffer = mesh.VertexBuffer, InstanceInputRate = false };
        cmd.VertexBufferCount = 1;
        cmd.InstanceCount = 1;
    }

    if mesh.IndexBuffer != null {
        cmd.IndexBuffer = mesh.IndexBuffer;
        cmd.IndexCount = mesh.IndexBuffer.Count;
    } else {
        cmd.VertexCount = cmd.VertexBuffers[0].Buffer.Count;
    }

    return cmd;
}

// Fills shaders/samplers/uniforms from a material (Foster: DrawCommand(target, material)).
// All 16 sampler slots and all 8 uniform-buffer slots are copied — the slot
// INDEX maps directly to the shader's declared resource binding slot.
draw_command_from_material :: (target: Drawable_Target, material: *Material) -> Draw_Command {
    cmd: Draw_Command;
    cmd.Target = target;

    cmd.FragmentShader = material.Fragment.shader;
    for i: 0..15 cmd.FragmentSamplers[i] = material.Fragment.Samplers[i];
    cmd.FragmentSamplerCount = MAX_BOUND_SAMPLERS;
    for i: 0..7 cmd.FragmentUniformBuffers[i] = *material.Fragment.UniformBuffers[i];
    cmd.FragmentUniformBufferCount = MAX_UNIFORM_BUFFERS;

    cmd.VertexShader = material.Vertex.shader;
    for i: 0..15 cmd.VertexSamplers[i] = material.Vertex.Samplers[i];
    cmd.VertexSamplerCount = MAX_BOUND_SAMPLERS;
    for i: 0..7 cmd.VertexUniformBuffers[i] = *material.Vertex.UniformBuffers[i];
    cmd.VertexUniformBufferCount = MAX_UNIFORM_BUFFERS;

    return cmd;
}

draw_command_submit :: (cmd: Draw_Command) {
    graphics_device_draw(App.device, cmd);
}

Compute_Command :: struct {
    shader: *Shader = null;   // lowercase: field name would shadow the type

    Samplers: [MAX_BOUND_SAMPLERS] Bound_Sampler;  SamplerCount: s32 = 0;
    UniformBuffers: [MAX_UNIFORM_BUFFERS] *Uniform_Buffer;  UniformBufferCount: s32 = 0;

    ReadOnlyStorageTextures:  [MAX_STORAGE_BUFFERS] *Texture;         ReadOnlyStorageTextureCount:  s32 = 0;
    ReadWriteStorageTextures: [MAX_STORAGE_BUFFERS] *Texture;         ReadWriteStorageTextureCount: s32 = 0;
    ReadOnlyStorageBuffers:   [MAX_STORAGE_BUFFERS] *Graphics_Buffer; ReadOnlyStorageBufferCount:   s32 = 0;
    ReadWriteStorageBuffers:  [MAX_STORAGE_BUFFERS] *Graphics_Buffer; ReadWriteStorageBufferCount:  s32 = 0;

    GroupCountX: s32 = 1;
    GroupCountY: s32 = 1;
    GroupCountZ: s32 = 1;
}

compute_command_submit :: (cmd: Compute_Command) {
    graphics_device_dispatch(App.device, cmd);
}
