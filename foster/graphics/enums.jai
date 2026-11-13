#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Enums/*.cs — every graphics enum,
// with the same member order (values are assigned by position and the
// SDL backend maps them 1:1).

Texture_Format :: enum {
    R8G8B8A8;
    R8;
    R8G8;
    DEPTH24STENCIL8;
    DEPTH32STENCIL8;
    DEPTH16;
    DEPTH24;
    DEPTH32;
    COLOR :: R8G8B8A8;   // shorthand (Foster: Color = R8G8B8A8)
}

texture_format_size :: (format: Texture_Format) -> s32 {
    if format == {
        case .R8G8B8A8;        return 4;
        case .R8;              return 1;
        case .R8G8;            return 2;
        case .DEPTH24STENCIL8; return 4;
        case .DEPTH32STENCIL8; return 5;
        case .DEPTH16;         return 2;
        case .DEPTH24;         return 3;
        case .DEPTH32;         return 4;
    }
    return 0;
}

texture_format_is_color :: (format: Texture_Format) -> bool {
    if format == .R8G8B8A8 || format == .R8 || format == .R8G8 return true;
    return false;
}

texture_format_is_depth_stencil :: (format: Texture_Format) -> bool {
    return !texture_format_is_color(format);
}

Blend_Factor :: enum {
    ZERO;
    ONE;
    SRC_COLOR;
    ONE_MINUS_SRC_COLOR;
    DST_COLOR;
    ONE_MINUS_DST_COLOR;
    SRC_ALPHA;
    ONE_MINUS_SRC_ALPHA;
    DST_ALPHA;
    ONE_MINUS_DST_ALPHA;
    CONSTANT_COLOR;
    ONE_MINUS_CONSTANT_COLOR;
    SRC_ALPHA_SATURATE;
}

Blend_Op :: enum {
    ADD;
    SUBTRACT;
    REVERSE_SUBTRACT;
    MIN;
    MAX;
}

Blend_Mask :: enum_flags u32 {
    NONE  :: 0;
    RED   :: 1;
    GREEN :: 2;
    BLUE  :: 4;
    ALPHA :: 8;
    RGB   :: RED | GREEN | BLUE;
    RGBA  :: RED | GREEN | BLUE | ALPHA;
}

Cull_Mode :: enum {
    NONE;
    FRONT;
    BACK;
}

Depth_Compare :: enum {
    ALWAYS;
    NEVER;
    LESS;
    EQUAL;
    LESS_OR_EQUAL;
    GREATER;
    NOT_EQUAL;
    GREATER_OR_EQUAL;
}

Fill_Mode :: enum {
    FILL :: 0;
    LINE :: 1;
}

Index_Format :: enum {
    SIXTEEN;
    THIRTY_TWO;
}

index_format_size_in_bytes :: (format: Index_Format) -> s32 {
    if format == .SIXTEEN return 2;
    return 4;
}

Sample_Count :: enum {
    ONE;
    TWO;
    FOUR;
    EIGHT;
}

Shader_Stage :: enum {
    VERTEX;
    FRAGMENT;
    COMPUTE;
}

Stencil_Op :: enum u32 {
    INVALID :: 0;
    KEEP :: 1;
    ZERO :: 2;
    REPLACE :: 3;
    INCREMENT_AND_CLAMP :: 4;
    DECREMENT_AND_CLAMP :: 5;
    INVERT :: 6;
    INCREMENT_AND_WRAP :: 7;
    DECREMENT_AND_WRAP :: 8;
}

Texture_Filter :: enum {
    NEAREST;
    LINEAR;
}

Texture_Wrap :: enum {
    REPEAT;
    MIRRORED_REPEAT;
    CLAMP;
}

Vertex_Type :: enum {
    NONE;
    FLOAT;
    FLOAT2;
    FLOAT3;
    FLOAT4;
    BYTE4;
    UBYTE4;
    SHORT2;
    USHORT2;
    SHORT4;
    USHORT4;
}

vertex_type_size_in_bytes :: (t: Vertex_Type) -> s32 {
    if t == {
        case .FLOAT;   return 4;
        case .FLOAT2;  return 8;
        case .FLOAT3;  return 12;
        case .FLOAT4;  return 16;
        case .BYTE4;   return 4;
        case .UBYTE4;  return 4;
        case .SHORT2;  return 4;
        case .USHORT2; return 4;
        case .SHORT4;  return 8;
        case .USHORT4; return 8;
        case .NONE;    return 0;
    }
    return 0;
}

Clear_Mask :: enum_flags u32 {
    NONE    :: 0;
    COLOR   :: 1 << 0;
    DEPTH   :: 1 << 1;
    STENCIL :: 1 << 2;
    ALL     :: COLOR | DEPTH | STENCIL;
}

Texture_Flags :: enum_flags u32 {
    NONE :: 0;
    // Allows the Texture to be used during Compute Storage Reads
    COMPUTE_READ  :: 1 << 0;
    // Allows the Texture to be used during Compute Storage Writes
    COMPUTE_WRITE :: 1 << 1;
}
