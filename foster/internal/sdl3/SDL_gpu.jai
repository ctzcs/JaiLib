// SDL_gpu.h — transcribed from SDL 3.4.12 official headers.
// Full binding: opaque handles, enums, flag groups, structs (field-for-field,
// ABI-critical order) and all 97 exported functions.
// SDL_PropertiesID comes from SDL_properties.jai; SDL_Window from SDL_video.jai.

/* Opaque handle types */

SDL_GPUDevice          :: void;
SDL_GPUBuffer          :: void;
SDL_GPUTransferBuffer  :: void;
SDL_GPUTexture         :: void;
SDL_GPUSampler         :: void;
SDL_GPUShader          :: void;
SDL_GPUComputePipeline :: void;
SDL_GPUGraphicsPipeline:: void;
SDL_GPUCommandBuffer   :: void;
SDL_GPURenderPass      :: void;
SDL_GPUComputePass     :: void;
SDL_GPUCopyPass        :: void;
SDL_GPUFence           :: void;

/* Supporting types pulled in from SDL_pixels.h / SDL_surface.h / SDL_rect.h */

SDL_FColor :: struct { r, g, b, a: float; }   // SDL_pixels.h

using SDL_FlipMode :: enum u32 {              // SDL_surface.h
    SDL_FLIP_NONE;
    SDL_FLIP_HORIZONTAL;
    SDL_FLIP_VERTICAL;
    SDL_FLIP_HORIZONTAL_AND_VERTICAL :: SDL_FLIP_HORIZONTAL | SDL_FLIP_VERTICAL;
}

SDL_Rect :: struct {                          // SDL_rect.h
    x, y: s32;
    w, h: s32;
}

/* Enums */

using SDL_GPUPrimitiveType :: enum u32 {
    SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP;
    SDL_GPU_PRIMITIVETYPE_LINELIST;
    SDL_GPU_PRIMITIVETYPE_LINESTRIP;
    SDL_GPU_PRIMITIVETYPE_POINTLIST;
}

using SDL_GPULoadOp :: enum u32 {
    SDL_GPU_LOADOP_LOAD;
    SDL_GPU_LOADOP_CLEAR;
    SDL_GPU_LOADOP_DONT_CARE;
}

using SDL_GPUStoreOp :: enum u32 {
    SDL_GPU_STOREOP_STORE;
    SDL_GPU_STOREOP_DONT_CARE;
    SDL_GPU_STOREOP_RESOLVE;
    SDL_GPU_STOREOP_RESOLVE_AND_STORE;
}

using SDL_GPUIndexElementSize :: enum u32 {
    SDL_GPU_INDEXELEMENTSIZE_16BIT;
    SDL_GPU_INDEXELEMENTSIZE_32BIT;
}

using SDL_GPUTextureFormat :: enum u32 {
    SDL_GPU_TEXTUREFORMAT_INVALID;

    /* Unsigned Normalized Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_A8_UNORM;
    SDL_GPU_TEXTUREFORMAT_R8_UNORM;
    SDL_GPU_TEXTUREFORMAT_R8G8_UNORM;
    SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    SDL_GPU_TEXTUREFORMAT_R16_UNORM;
    SDL_GPU_TEXTUREFORMAT_R16G16_UNORM;
    SDL_GPU_TEXTUREFORMAT_R16G16B16A16_UNORM;
    SDL_GPU_TEXTUREFORMAT_R10G10B10A2_UNORM;
    SDL_GPU_TEXTUREFORMAT_B5G6R5_UNORM;
    SDL_GPU_TEXTUREFORMAT_B5G5R5A1_UNORM;
    SDL_GPU_TEXTUREFORMAT_B4G4R4A4_UNORM;
    SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;
    /* Compressed Unsigned Normalized Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM;
    SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM;
    SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM;
    SDL_GPU_TEXTUREFORMAT_BC4_R_UNORM;
    SDL_GPU_TEXTUREFORMAT_BC5_RG_UNORM;
    SDL_GPU_TEXTUREFORMAT_BC7_RGBA_UNORM;
    /* Compressed Signed Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_BC6H_RGB_FLOAT;
    /* Compressed Unsigned Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_BC6H_RGB_UFLOAT;
    /* Signed Normalized Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_R8_SNORM;
    SDL_GPU_TEXTUREFORMAT_R8G8_SNORM;
    SDL_GPU_TEXTUREFORMAT_R8G8B8A8_SNORM;
    SDL_GPU_TEXTUREFORMAT_R16_SNORM;
    SDL_GPU_TEXTUREFORMAT_R16G16_SNORM;
    SDL_GPU_TEXTUREFORMAT_R16G16B16A16_SNORM;
    /* Signed Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_R16_FLOAT;
    SDL_GPU_TEXTUREFORMAT_R16G16_FLOAT;
    SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
    SDL_GPU_TEXTUREFORMAT_R32_FLOAT;
    SDL_GPU_TEXTUREFORMAT_R32G32_FLOAT;
    SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT;
    /* Unsigned Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT;
    /* Unsigned Integer Color Formats */
    SDL_GPU_TEXTUREFORMAT_R8_UINT;
    SDL_GPU_TEXTUREFORMAT_R8G8_UINT;
    SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UINT;
    SDL_GPU_TEXTUREFORMAT_R16_UINT;
    SDL_GPU_TEXTUREFORMAT_R16G16_UINT;
    SDL_GPU_TEXTUREFORMAT_R16G16B16A16_UINT;
    SDL_GPU_TEXTUREFORMAT_R32_UINT;
    SDL_GPU_TEXTUREFORMAT_R32G32_UINT;
    SDL_GPU_TEXTUREFORMAT_R32G32B32A32_UINT;
    /* Signed Integer Color Formats */
    SDL_GPU_TEXTUREFORMAT_R8_INT;
    SDL_GPU_TEXTUREFORMAT_R8G8_INT;
    SDL_GPU_TEXTUREFORMAT_R8G8B8A8_INT;
    SDL_GPU_TEXTUREFORMAT_R16_INT;
    SDL_GPU_TEXTUREFORMAT_R16G16_INT;
    SDL_GPU_TEXTUREFORMAT_R16G16B16A16_INT;
    SDL_GPU_TEXTUREFORMAT_R32_INT;
    SDL_GPU_TEXTUREFORMAT_R32G32_INT;
    SDL_GPU_TEXTUREFORMAT_R32G32B32A32_INT;
    /* SRGB Unsigned Normalized Color Formats */
    SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB;
    /* Compressed SRGB Unsigned Normalized Color Formats */
    SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_BC7_RGBA_UNORM_SRGB;
    /* Depth Formats */
    SDL_GPU_TEXTUREFORMAT_D16_UNORM;
    SDL_GPU_TEXTUREFORMAT_D24_UNORM;
    SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
    SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT;
    SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
    /* Compressed ASTC Normalized Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_5x4_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_5x5_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_6x5_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_6x6_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x5_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x6_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x8_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x5_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x6_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x8_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x10_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_12x10_UNORM;
    SDL_GPU_TEXTUREFORMAT_ASTC_12x12_UNORM;
    /* Compressed SRGB ASTC Normalized Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_5x4_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_5x5_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_6x5_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_6x6_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x5_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x6_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x8_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x5_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x6_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x8_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x10_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_12x10_UNORM_SRGB;
    SDL_GPU_TEXTUREFORMAT_ASTC_12x12_UNORM_SRGB;
    /* Compressed ASTC Signed Float Color Formats */
    SDL_GPU_TEXTUREFORMAT_ASTC_4x4_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_5x4_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_5x5_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_6x5_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_6x6_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x5_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x6_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_8x8_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x5_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x6_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x8_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_10x10_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_12x10_FLOAT;
    SDL_GPU_TEXTUREFORMAT_ASTC_12x12_FLOAT;
}

using SDL_GPUTextureUsageFlags :: enum_flags u32 {
    SDL_GPU_TEXTUREUSAGE_SAMPLER                                 :: 1 << 0;
    SDL_GPU_TEXTUREUSAGE_COLOR_TARGET                            :: 1 << 1;
    SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET                    :: 1 << 2;
    SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ                   :: 1 << 3;
    SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_READ                    :: 1 << 4;
    SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE                   :: 1 << 5;
    SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE :: 1 << 6;
}

using SDL_GPUTextureType :: enum u32 {
    SDL_GPU_TEXTURETYPE_2D;
    SDL_GPU_TEXTURETYPE_2D_ARRAY;
    SDL_GPU_TEXTURETYPE_3D;
    SDL_GPU_TEXTURETYPE_CUBE;
    SDL_GPU_TEXTURETYPE_CUBE_ARRAY;
}

using SDL_GPUSampleCount :: enum u32 {
    SDL_GPU_SAMPLECOUNT_1;
    SDL_GPU_SAMPLECOUNT_2;
    SDL_GPU_SAMPLECOUNT_4;
    SDL_GPU_SAMPLECOUNT_8;
}

using SDL_GPUCubeMapFace :: enum u32 {
    SDL_GPU_CUBEMAPFACE_POSITIVEX;
    SDL_GPU_CUBEMAPFACE_NEGATIVEX;
    SDL_GPU_CUBEMAPFACE_POSITIVEY;
    SDL_GPU_CUBEMAPFACE_NEGATIVEY;
    SDL_GPU_CUBEMAPFACE_POSITIVEZ;
    SDL_GPU_CUBEMAPFACE_NEGATIVEZ;
}

using SDL_GPUBufferUsageFlags :: enum_flags u32 {
    SDL_GPU_BUFFERUSAGE_VERTEX                  :: 1 << 0;
    SDL_GPU_BUFFERUSAGE_INDEX                   :: 1 << 1;
    SDL_GPU_BUFFERUSAGE_INDIRECT                :: 1 << 2;
    SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ   :: 1 << 3;
    SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ    :: 1 << 4;
    SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE   :: 1 << 5;
}

using SDL_GPUTransferBufferUsage :: enum u32 {
    SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
}

using SDL_GPUShaderStage :: enum u32 {
    SDL_GPU_SHADERSTAGE_VERTEX;
    SDL_GPU_SHADERSTAGE_FRAGMENT;
}

using SDL_GPUShaderFormat :: enum_flags u32 {
    SDL_GPU_SHADERFORMAT_INVALID  :: 0;
    SDL_GPU_SHADERFORMAT_PRIVATE  :: 1 << 0;
    SDL_GPU_SHADERFORMAT_SPIRV    :: 1 << 1;
    SDL_GPU_SHADERFORMAT_DXBC     :: 1 << 2;
    SDL_GPU_SHADERFORMAT_DXIL     :: 1 << 3;
    SDL_GPU_SHADERFORMAT_MSL      :: 1 << 4;
    SDL_GPU_SHADERFORMAT_METALLIB :: 1 << 5;
}

using SDL_GPUVertexElementFormat :: enum u32 {
    SDL_GPU_VERTEXELEMENTFORMAT_INVALID;

    /* 32-bit Signed Integers */
    SDL_GPU_VERTEXELEMENTFORMAT_INT;
    SDL_GPU_VERTEXELEMENTFORMAT_INT2;
    SDL_GPU_VERTEXELEMENTFORMAT_INT3;
    SDL_GPU_VERTEXELEMENTFORMAT_INT4;

    /* 32-bit Unsigned Integers */
    SDL_GPU_VERTEXELEMENTFORMAT_UINT;
    SDL_GPU_VERTEXELEMENTFORMAT_UINT2;
    SDL_GPU_VERTEXELEMENTFORMAT_UINT3;
    SDL_GPU_VERTEXELEMENTFORMAT_UINT4;

    /* 32-bit Floats */
    SDL_GPU_VERTEXELEMENTFORMAT_FLOAT;
    SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
    SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3;
    SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4;

    /* 8-bit Signed Integers */
    SDL_GPU_VERTEXELEMENTFORMAT_BYTE2;
    SDL_GPU_VERTEXELEMENTFORMAT_BYTE4;

    /* 8-bit Unsigned Integers */
    SDL_GPU_VERTEXELEMENTFORMAT_UBYTE2;
    SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4;

    /* 8-bit Signed Normalized */
    SDL_GPU_VERTEXELEMENTFORMAT_BYTE2_NORM;
    SDL_GPU_VERTEXELEMENTFORMAT_BYTE4_NORM;

    /* 8-bit Unsigned Normalized */
    SDL_GPU_VERTEXELEMENTFORMAT_UBYTE2_NORM;
    SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM;

    /* 16-bit Signed Integers */
    SDL_GPU_VERTEXELEMENTFORMAT_SHORT2;
    SDL_GPU_VERTEXELEMENTFORMAT_SHORT4;

    /* 16-bit Unsigned Integers */
    SDL_GPU_VERTEXELEMENTFORMAT_USHORT2;
    SDL_GPU_VERTEXELEMENTFORMAT_USHORT4;

    /* 16-bit Signed Normalized */
    SDL_GPU_VERTEXELEMENTFORMAT_SHORT2_NORM;
    SDL_GPU_VERTEXELEMENTFORMAT_SHORT4_NORM;

    /* 16-bit Unsigned Normalized */
    SDL_GPU_VERTEXELEMENTFORMAT_USHORT2_NORM;
    SDL_GPU_VERTEXELEMENTFORMAT_USHORT4_NORM;

    /* 16-bit Floats */
    SDL_GPU_VERTEXELEMENTFORMAT_HALF2;
    SDL_GPU_VERTEXELEMENTFORMAT_HALF4;
}

using SDL_GPUVertexInputRate :: enum u32 {
    SDL_GPU_VERTEXINPUTRATE_VERTEX;
    SDL_GPU_VERTEXINPUTRATE_INSTANCE;
}

using SDL_GPUFillMode :: enum u32 {
    SDL_GPU_FILLMODE_FILL;
    SDL_GPU_FILLMODE_LINE;
}

using SDL_GPUCullMode :: enum u32 {
    SDL_GPU_CULLMODE_NONE;
    SDL_GPU_CULLMODE_FRONT;
    SDL_GPU_CULLMODE_BACK;
}

using SDL_GPUFrontFace :: enum u32 {
    SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;
    SDL_GPU_FRONTFACE_CLOCKWISE;
}

using SDL_GPUCompareOp :: enum u32 {
    SDL_GPU_COMPAREOP_INVALID;
    SDL_GPU_COMPAREOP_NEVER;
    SDL_GPU_COMPAREOP_LESS;
    SDL_GPU_COMPAREOP_EQUAL;
    SDL_GPU_COMPAREOP_LESS_OR_EQUAL;
    SDL_GPU_COMPAREOP_GREATER;
    SDL_GPU_COMPAREOP_NOT_EQUAL;
    SDL_GPU_COMPAREOP_GREATER_OR_EQUAL;
    SDL_GPU_COMPAREOP_ALWAYS;
}

using SDL_GPUStencilOp :: enum u32 {
    SDL_GPU_STENCILOP_INVALID;
    SDL_GPU_STENCILOP_KEEP;
    SDL_GPU_STENCILOP_ZERO;
    SDL_GPU_STENCILOP_REPLACE;
    SDL_GPU_STENCILOP_INCREMENT_AND_CLAMP;
    SDL_GPU_STENCILOP_DECREMENT_AND_CLAMP;
    SDL_GPU_STENCILOP_INVERT;
    SDL_GPU_STENCILOP_INCREMENT_AND_WRAP;
    SDL_GPU_STENCILOP_DECREMENT_AND_WRAP;
}

using SDL_GPUBlendOp :: enum u32 {
    SDL_GPU_BLENDOP_INVALID;
    SDL_GPU_BLENDOP_ADD;
    SDL_GPU_BLENDOP_SUBTRACT;
    SDL_GPU_BLENDOP_REVERSE_SUBTRACT;
    SDL_GPU_BLENDOP_MIN;
    SDL_GPU_BLENDOP_MAX;
}

using SDL_GPUBlendFactor :: enum u32 {
    SDL_GPU_BLENDFACTOR_INVALID;
    SDL_GPU_BLENDFACTOR_ZERO;
    SDL_GPU_BLENDFACTOR_ONE;
    SDL_GPU_BLENDFACTOR_SRC_COLOR;
    SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_COLOR;
    SDL_GPU_BLENDFACTOR_DST_COLOR;
    SDL_GPU_BLENDFACTOR_ONE_MINUS_DST_COLOR;
    SDL_GPU_BLENDFACTOR_SRC_ALPHA;
    SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    SDL_GPU_BLENDFACTOR_DST_ALPHA;
    SDL_GPU_BLENDFACTOR_ONE_MINUS_DST_ALPHA;
    SDL_GPU_BLENDFACTOR_CONSTANT_COLOR;
    SDL_GPU_BLENDFACTOR_ONE_MINUS_CONSTANT_COLOR;
    SDL_GPU_BLENDFACTOR_SRC_ALPHA_SATURATE;
}

using SDL_GPUColorComponentFlags :: enum_flags u8 {
    SDL_GPU_COLORCOMPONENT_R :: 1 << 0;
    SDL_GPU_COLORCOMPONENT_G :: 1 << 1;
    SDL_GPU_COLORCOMPONENT_B :: 1 << 2;
    SDL_GPU_COLORCOMPONENT_A :: 1 << 3;
}

using SDL_GPUFilter :: enum u32 {
    SDL_GPU_FILTER_NEAREST;
    SDL_GPU_FILTER_LINEAR;
}

using SDL_GPUSamplerMipmapMode :: enum u32 {
    SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
}

using SDL_GPUSamplerAddressMode :: enum u32 {
    SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
    SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT;
    SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
}

using SDL_GPUPresentMode :: enum u32 {
    SDL_GPU_PRESENTMODE_VSYNC;
    SDL_GPU_PRESENTMODE_IMMEDIATE;
    SDL_GPU_PRESENTMODE_MAILBOX;
}

using SDL_GPUSwapchainComposition :: enum u32 {
    SDL_GPU_SWAPCHAINCOMPOSITION_SDR;
    SDL_GPU_SWAPCHAINCOMPOSITION_SDR_LINEAR;
    SDL_GPU_SWAPCHAINCOMPOSITION_HDR_EXTENDED_LINEAR;
    SDL_GPU_SWAPCHAINCOMPOSITION_HDR10_ST2084;
}

/* Structures */

SDL_GPUViewport :: struct {
    x: float;
    y: float;
    w: float;
    h: float;
    min_depth: float;
    max_depth: float;
}

SDL_GPUTextureTransferInfo :: struct {
    transfer_buffer: *SDL_GPUTransferBuffer;
    offset: u32;
    pixels_per_row: u32;
    rows_per_layer: u32;
}

SDL_GPUTransferBufferLocation :: struct {
    transfer_buffer: *SDL_GPUTransferBuffer;
    offset: u32;
}

SDL_GPUTextureLocation :: struct {
    texture: *SDL_GPUTexture;
    mip_level: u32;
    layer: u32;
    x: u32;
    y: u32;
    z: u32;
}

SDL_GPUTextureRegion :: struct {
    texture: *SDL_GPUTexture;
    mip_level: u32;
    layer: u32;
    x: u32;
    y: u32;
    z: u32;
    w: u32;
    h: u32;
    d: u32;
}

SDL_GPUBlitRegion :: struct {
    texture: *SDL_GPUTexture;
    mip_level: u32;
    layer_or_depth_plane: u32;
    x: u32;
    y: u32;
    w: u32;
    h: u32;
}

SDL_GPUBufferLocation :: struct {
    buffer: *SDL_GPUBuffer;
    offset: u32;
}

SDL_GPUBufferRegion :: struct {
    buffer: *SDL_GPUBuffer;
    offset: u32;
    size: u32;
}

SDL_GPUIndirectDrawCommand :: struct {
    num_vertices: u32;
    num_instances: u32;
    first_vertex: u32;
    first_instance: u32;
}

SDL_GPUIndexedIndirectDrawCommand :: struct {
    num_indices: u32;
    num_instances: u32;
    first_index: u32;
    vertex_offset: s32;
    first_instance: u32;
}

SDL_GPUIndirectDispatchCommand :: struct {
    groupcount_x: u32;
    groupcount_y: u32;
    groupcount_z: u32;
}

SDL_GPUSamplerCreateInfo :: struct {
    min_filter: SDL_GPUFilter;
    mag_filter: SDL_GPUFilter;
    mipmap_mode: SDL_GPUSamplerMipmapMode;
    address_mode_u: SDL_GPUSamplerAddressMode;
    address_mode_v: SDL_GPUSamplerAddressMode;
    address_mode_w: SDL_GPUSamplerAddressMode;
    mip_lod_bias: float;
    max_anisotropy: float;
    compare_op: SDL_GPUCompareOp;
    min_lod: float;
    max_lod: float;
    enable_anisotropy: bool;
    enable_compare: bool;
    padding1: u8;
    padding2: u8;
    props: SDL_PropertiesID;
}

SDL_GPUVertexBufferDescription :: struct {
    slot: u32;
    pitch: u32;
    input_rate: SDL_GPUVertexInputRate;
    instance_step_rate: u32;
}

SDL_GPUVertexAttribute :: struct {
    location: u32;
    buffer_slot: u32;
    format: SDL_GPUVertexElementFormat;
    offset: u32;
}

SDL_GPUVertexInputState :: struct {
    vertex_buffer_descriptions: *SDL_GPUVertexBufferDescription;
    num_vertex_buffers: u32;
    vertex_attributes: *SDL_GPUVertexAttribute;
    num_vertex_attributes: u32;
}

SDL_GPUStencilOpState :: struct {
    fail_op: SDL_GPUStencilOp;
    pass_op: SDL_GPUStencilOp;
    depth_fail_op: SDL_GPUStencilOp;
    compare_op: SDL_GPUCompareOp;
}

SDL_GPUColorTargetBlendState :: struct {
    src_color_blendfactor: SDL_GPUBlendFactor;
    dst_color_blendfactor: SDL_GPUBlendFactor;
    color_blend_op: SDL_GPUBlendOp;
    src_alpha_blendfactor: SDL_GPUBlendFactor;
    dst_alpha_blendfactor: SDL_GPUBlendFactor;
    alpha_blend_op: SDL_GPUBlendOp;
    color_write_mask: SDL_GPUColorComponentFlags;
    enable_blend: bool;
    enable_color_write_mask: bool;
    padding1: u8;
    padding2: u8;
}

SDL_GPUShaderCreateInfo :: struct {
    code_size: u64;      // size_t
    code: *u8;           // const Uint8 *
    entrypoint: *u8;     // const char *
    format: SDL_GPUShaderFormat;
    stage: SDL_GPUShaderStage;
    num_samplers: u32;
    num_storage_textures: u32;
    num_storage_buffers: u32;
    num_uniform_buffers: u32;
    props: SDL_PropertiesID;
}

SDL_GPUTextureCreateInfo :: struct {
    type: SDL_GPUTextureType;
    format: SDL_GPUTextureFormat;
    usage: SDL_GPUTextureUsageFlags;
    width: u32;
    height: u32;
    layer_count_or_depth: u32;
    num_levels: u32;
    sample_count: SDL_GPUSampleCount;
    props: SDL_PropertiesID;
}

SDL_GPUBufferCreateInfo :: struct {
    usage: SDL_GPUBufferUsageFlags;
    size: u32;
    props: SDL_PropertiesID;
}

SDL_GPUTransferBufferCreateInfo :: struct {
    usage: SDL_GPUTransferBufferUsage;
    size: u32;
    props: SDL_PropertiesID;
}

SDL_GPURasterizerState :: struct {
    fill_mode: SDL_GPUFillMode;
    cull_mode: SDL_GPUCullMode;
    front_face: SDL_GPUFrontFace;
    depth_bias_constant_factor: float;
    depth_bias_clamp: float;
    depth_bias_slope_factor: float;
    enable_depth_bias: bool;
    enable_depth_clip: bool;
    padding1: u8;
    padding2: u8;
}

SDL_GPUMultisampleState :: struct {
    sample_count: SDL_GPUSampleCount;
    sample_mask: u32;
    enable_mask: bool;
    enable_alpha_to_coverage: bool;
    padding2: u8;
    padding3: u8;
}

SDL_GPUDepthStencilState :: struct {
    compare_op: SDL_GPUCompareOp;
    back_stencil_state: SDL_GPUStencilOpState;
    front_stencil_state: SDL_GPUStencilOpState;
    compare_mask: u8;
    write_mask: u8;
    enable_depth_test: bool;
    enable_depth_write: bool;
    enable_stencil_test: bool;
    padding1: u8;
    padding2: u8;
    padding3: u8;
}

SDL_GPUColorTargetDescription :: struct {
    format: SDL_GPUTextureFormat;
    blend_state: SDL_GPUColorTargetBlendState;
}

SDL_GPUGraphicsPipelineTargetInfo :: struct {
    color_target_descriptions: *SDL_GPUColorTargetDescription;
    num_color_targets: u32;
    depth_stencil_format: SDL_GPUTextureFormat;
    has_depth_stencil_target: bool;
    padding1: u8;
    padding2: u8;
    padding3: u8;
}

SDL_GPUGraphicsPipelineCreateInfo :: struct {
    vertex_shader: *SDL_GPUShader;
    fragment_shader: *SDL_GPUShader;
    vertex_input_state: SDL_GPUVertexInputState;
    primitive_type: SDL_GPUPrimitiveType;
    rasterizer_state: SDL_GPURasterizerState;
    multisample_state: SDL_GPUMultisampleState;
    depth_stencil_state: SDL_GPUDepthStencilState;
    target_info: SDL_GPUGraphicsPipelineTargetInfo;
    props: SDL_PropertiesID;
}

SDL_GPUComputePipelineCreateInfo :: struct {
    code_size: u64;      // size_t
    code: *u8;           // const Uint8 *
    entrypoint: *u8;     // const char *
    format: SDL_GPUShaderFormat;
    num_samplers: u32;
    num_readonly_storage_textures: u32;
    num_readonly_storage_buffers: u32;
    num_readwrite_storage_textures: u32;
    num_readwrite_storage_buffers: u32;
    num_uniform_buffers: u32;
    threadcount_x: u32;
    threadcount_y: u32;
    threadcount_z: u32;
    props: SDL_PropertiesID;
}

SDL_GPUColorTargetInfo :: struct {
    texture: *SDL_GPUTexture;
    mip_level: u32;
    layer_or_depth_plane: u32;
    clear_color: SDL_FColor;
    load_op: SDL_GPULoadOp;
    store_op: SDL_GPUStoreOp;
    resolve_texture: *SDL_GPUTexture;
    resolve_mip_level: u32;
    resolve_layer: u32;
    cycle: bool;
    cycle_resolve_texture: bool;
    padding1: u8;
    padding2: u8;
}

SDL_GPUDepthStencilTargetInfo :: struct {
    texture: *SDL_GPUTexture;
    clear_depth: float;
    load_op: SDL_GPULoadOp;
    store_op: SDL_GPUStoreOp;
    stencil_load_op: SDL_GPULoadOp;
    stencil_store_op: SDL_GPUStoreOp;
    cycle: bool;
    clear_stencil: u8;
    mip_level: u8;
    layer: u8;
}

SDL_GPUBlitInfo :: struct {
    source: SDL_GPUBlitRegion;
    destination: SDL_GPUBlitRegion;
    load_op: SDL_GPULoadOp;
    clear_color: SDL_FColor;
    flip_mode: SDL_FlipMode;
    filter: SDL_GPUFilter;
    cycle: bool;
    padding1: u8;
    padding2: u8;
    padding3: u8;
}

SDL_GPUBufferBinding :: struct {
    buffer: *SDL_GPUBuffer;
    offset: u32;
}

SDL_GPUTextureSamplerBinding :: struct {
    texture: *SDL_GPUTexture;
    sampler: *SDL_GPUSampler;
}

SDL_GPUStorageBufferReadWriteBinding :: struct {
    buffer: *SDL_GPUBuffer;
    cycle: bool;
    padding1: u8;
    padding2: u8;
    padding3: u8;
}

SDL_GPUStorageTextureReadWriteBinding :: struct {
    texture: *SDL_GPUTexture;
    mip_level: u32;
    layer: u32;
    cycle: bool;
    padding1: u8;
    padding2: u8;
    padding3: u8;
}

// Since SDL 3.4.0; passed via SDL_PROP_GPU_DEVICE_CREATE_VULKAN_OPTIONS_POINTER.
SDL_GPUVulkanOptions :: struct {
    vulkan_api_version: u32;
    feature_list: *void;
    vulkan_10_physical_device_features: *void;
    device_extension_count: u32;
    device_extension_names: **u8;      // const char **
    instance_extension_count: u32;
    instance_extension_names: **u8;    // const char **
}

/* Functions */

/* Device */

#if OS != .WASM {
SDL_GPUSupportsShaderFormats  :: (format_flags: SDL_GPUShaderFormat, name: *u8) -> bool #foreign SDL3;
SDL_GPUSupportsProperties     :: (props: SDL_PropertiesID) -> bool #foreign SDL3;
SDL_CreateGPUDevice           :: (format_flags: SDL_GPUShaderFormat, debug_mode: bool, name: *u8) -> *SDL_GPUDevice #foreign SDL3;
SDL_CreateGPUDeviceWithProperties :: (props: SDL_PropertiesID) -> *SDL_GPUDevice #foreign SDL3;
SDL_DestroyGPUDevice          :: (device: *SDL_GPUDevice) #foreign SDL3;
SDL_GetNumGPUDrivers          :: () -> s32 #foreign SDL3;
SDL_GetGPUDriver              :: (index: s32) -> *u8 #foreign SDL3;
SDL_GetGPUDeviceDriver        :: (device: *SDL_GPUDevice) -> *u8 #foreign SDL3;
SDL_GetGPUShaderFormats       :: (device: *SDL_GPUDevice) -> SDL_GPUShaderFormat #foreign SDL3;
SDL_GetGPUDeviceProperties    :: (device: *SDL_GPUDevice) -> SDL_PropertiesID #foreign SDL3;

/* State Creation */

SDL_CreateGPUComputePipeline  :: (device: *SDL_GPUDevice, createinfo: *SDL_GPUComputePipelineCreateInfo) -> *SDL_GPUComputePipeline #foreign SDL3;
SDL_CreateGPUGraphicsPipeline :: (device: *SDL_GPUDevice, createinfo: *SDL_GPUGraphicsPipelineCreateInfo) -> *SDL_GPUGraphicsPipeline #foreign SDL3;
SDL_CreateGPUSampler          :: (device: *SDL_GPUDevice, createinfo: *SDL_GPUSamplerCreateInfo) -> *SDL_GPUSampler #foreign SDL3;
SDL_CreateGPUShader           :: (device: *SDL_GPUDevice, createinfo: *SDL_GPUShaderCreateInfo) -> *SDL_GPUShader #foreign SDL3;
SDL_CreateGPUTexture          :: (device: *SDL_GPUDevice, createinfo: *SDL_GPUTextureCreateInfo) -> *SDL_GPUTexture #foreign SDL3;
SDL_CreateGPUBuffer           :: (device: *SDL_GPUDevice, createinfo: *SDL_GPUBufferCreateInfo) -> *SDL_GPUBuffer #foreign SDL3;
SDL_CreateGPUTransferBuffer   :: (device: *SDL_GPUDevice, createinfo: *SDL_GPUTransferBufferCreateInfo) -> *SDL_GPUTransferBuffer #foreign SDL3;

/* Debug Naming */

SDL_SetGPUBufferName   :: (device: *SDL_GPUDevice, buffer: *SDL_GPUBuffer, text: *u8) #foreign SDL3;
SDL_SetGPUTextureName  :: (device: *SDL_GPUDevice, texture: *SDL_GPUTexture, text: *u8) #foreign SDL3;
SDL_InsertGPUDebugLabel :: (command_buffer: *SDL_GPUCommandBuffer, text: *u8) #foreign SDL3;
SDL_PushGPUDebugGroup  :: (command_buffer: *SDL_GPUCommandBuffer, name: *u8) #foreign SDL3;
SDL_PopGPUDebugGroup   :: (command_buffer: *SDL_GPUCommandBuffer) #foreign SDL3;

/* Disposal */

SDL_ReleaseGPUTexture          :: (device: *SDL_GPUDevice, texture: *SDL_GPUTexture) #foreign SDL3;
SDL_ReleaseGPUSampler          :: (device: *SDL_GPUDevice, sampler: *SDL_GPUSampler) #foreign SDL3;
SDL_ReleaseGPUBuffer           :: (device: *SDL_GPUDevice, buffer: *SDL_GPUBuffer) #foreign SDL3;
SDL_ReleaseGPUTransferBuffer   :: (device: *SDL_GPUDevice, transfer_buffer: *SDL_GPUTransferBuffer) #foreign SDL3;
SDL_ReleaseGPUComputePipeline  :: (device: *SDL_GPUDevice, compute_pipeline: *SDL_GPUComputePipeline) #foreign SDL3;
SDL_ReleaseGPUShader           :: (device: *SDL_GPUDevice, shader: *SDL_GPUShader) #foreign SDL3;
SDL_ReleaseGPUGraphicsPipeline :: (device: *SDL_GPUDevice, graphics_pipeline: *SDL_GPUGraphicsPipeline) #foreign SDL3;

SDL_AcquireGPUCommandBuffer    :: (device: *SDL_GPUDevice) -> *SDL_GPUCommandBuffer #foreign SDL3;

/* Uniform Data */

SDL_PushGPUVertexUniformData   :: (command_buffer: *SDL_GPUCommandBuffer, slot_index: u32, data: *void, length: u32) #foreign SDL3;
SDL_PushGPUFragmentUniformData :: (command_buffer: *SDL_GPUCommandBuffer, slot_index: u32, data: *void, length: u32) #foreign SDL3;
SDL_PushGPUComputeUniformData  :: (command_buffer: *SDL_GPUCommandBuffer, slot_index: u32, data: *void, length: u32) #foreign SDL3;

/* Graphics State */

SDL_BeginGPURenderPass :: (command_buffer: *SDL_GPUCommandBuffer, color_target_infos: *SDL_GPUColorTargetInfo, num_color_targets: u32, depth_stencil_target_info: *SDL_GPUDepthStencilTargetInfo) -> *SDL_GPURenderPass #foreign SDL3;
SDL_BindGPUGraphicsPipeline :: (render_pass: *SDL_GPURenderPass, graphics_pipeline: *SDL_GPUGraphicsPipeline) #foreign SDL3;
SDL_SetGPUViewport     :: (render_pass: *SDL_GPURenderPass, viewport: *SDL_GPUViewport) #foreign SDL3;
SDL_SetGPUScissor      :: (render_pass: *SDL_GPURenderPass, scissor: *SDL_Rect) #foreign SDL3;
SDL_SetGPUBlendConstants :: (render_pass: *SDL_GPURenderPass, blend_constants: SDL_FColor) #foreign SDL3;
SDL_SetGPUStencilReference :: (render_pass: *SDL_GPURenderPass, reference: u8) #foreign SDL3;
SDL_BindGPUVertexBuffers :: (render_pass: *SDL_GPURenderPass, first_slot: u32, bindings: *SDL_GPUBufferBinding, num_bindings: u32) #foreign SDL3;
SDL_BindGPUIndexBuffer :: (render_pass: *SDL_GPURenderPass, binding: *SDL_GPUBufferBinding, index_element_size: SDL_GPUIndexElementSize) #foreign SDL3;
SDL_BindGPUVertexSamplers :: (render_pass: *SDL_GPURenderPass, first_slot: u32, texture_sampler_bindings: *SDL_GPUTextureSamplerBinding, num_bindings: u32) #foreign SDL3;
SDL_BindGPUVertexStorageTextures :: (render_pass: *SDL_GPURenderPass, first_slot: u32, storage_textures: **SDL_GPUTexture, num_bindings: u32) #foreign SDL3;
SDL_BindGPUVertexStorageBuffers :: (render_pass: *SDL_GPURenderPass, first_slot: u32, storage_buffers: **SDL_GPUBuffer, num_bindings: u32) #foreign SDL3;
SDL_BindGPUFragmentSamplers :: (render_pass: *SDL_GPURenderPass, first_slot: u32, texture_sampler_bindings: *SDL_GPUTextureSamplerBinding, num_bindings: u32) #foreign SDL3;
SDL_BindGPUFragmentStorageTextures :: (render_pass: *SDL_GPURenderPass, first_slot: u32, storage_textures: **SDL_GPUTexture, num_bindings: u32) #foreign SDL3;
SDL_BindGPUFragmentStorageBuffers :: (render_pass: *SDL_GPURenderPass, first_slot: u32, storage_buffers: **SDL_GPUBuffer, num_bindings: u32) #foreign SDL3;

/* Drawing */

SDL_DrawGPUIndexedPrimitives :: (render_pass: *SDL_GPURenderPass, num_indices: u32, num_instances: u32, first_index: u32, vertex_offset: s32, first_instance: u32) #foreign SDL3;
SDL_DrawGPUPrimitives :: (render_pass: *SDL_GPURenderPass, num_vertices: u32, num_instances: u32, first_vertex: u32, first_instance: u32) #foreign SDL3;
SDL_DrawGPUPrimitivesIndirect :: (render_pass: *SDL_GPURenderPass, buffer: *SDL_GPUBuffer, offset: u32, draw_count: u32) #foreign SDL3;
SDL_DrawGPUIndexedPrimitivesIndirect :: (render_pass: *SDL_GPURenderPass, buffer: *SDL_GPUBuffer, offset: u32, draw_count: u32) #foreign SDL3;
SDL_EndGPURenderPass :: (render_pass: *SDL_GPURenderPass) #foreign SDL3;

/* Compute Pass */

SDL_BeginGPUComputePass :: (command_buffer: *SDL_GPUCommandBuffer, storage_texture_bindings: *SDL_GPUStorageTextureReadWriteBinding, num_storage_texture_bindings: u32, storage_buffer_bindings: *SDL_GPUStorageBufferReadWriteBinding, num_storage_buffer_bindings: u32) -> *SDL_GPUComputePass #foreign SDL3;
SDL_BindGPUComputePipeline :: (compute_pass: *SDL_GPUComputePass, compute_pipeline: *SDL_GPUComputePipeline) #foreign SDL3;
SDL_BindGPUComputeSamplers :: (compute_pass: *SDL_GPUComputePass, first_slot: u32, texture_sampler_bindings: *SDL_GPUTextureSamplerBinding, num_bindings: u32) #foreign SDL3;
SDL_BindGPUComputeStorageTextures :: (compute_pass: *SDL_GPUComputePass, first_slot: u32, storage_textures: **SDL_GPUTexture, num_bindings: u32) #foreign SDL3;
SDL_BindGPUComputeStorageBuffers :: (compute_pass: *SDL_GPUComputePass, first_slot: u32, storage_buffers: **SDL_GPUBuffer, num_bindings: u32) #foreign SDL3;
SDL_DispatchGPUCompute :: (compute_pass: *SDL_GPUComputePass, groupcount_x: u32, groupcount_y: u32, groupcount_z: u32) #foreign SDL3;
SDL_DispatchGPUComputeIndirect :: (compute_pass: *SDL_GPUComputePass, buffer: *SDL_GPUBuffer, offset: u32) #foreign SDL3;
SDL_EndGPUComputePass :: (compute_pass: *SDL_GPUComputePass) #foreign SDL3;

/* TransferBuffer Data */

SDL_MapGPUTransferBuffer   :: (device: *SDL_GPUDevice, transfer_buffer: *SDL_GPUTransferBuffer, cycle: bool) -> *void #foreign SDL3;
SDL_UnmapGPUTransferBuffer :: (device: *SDL_GPUDevice, transfer_buffer: *SDL_GPUTransferBuffer) #foreign SDL3;

/* Copy Pass */

SDL_BeginGPUCopyPass :: (command_buffer: *SDL_GPUCommandBuffer) -> *SDL_GPUCopyPass #foreign SDL3;
SDL_UploadToGPUTexture :: (copy_pass: *SDL_GPUCopyPass, source: *SDL_GPUTextureTransferInfo, destination: *SDL_GPUTextureRegion, cycle: bool) #foreign SDL3;
SDL_UploadToGPUBuffer :: (copy_pass: *SDL_GPUCopyPass, source: *SDL_GPUTransferBufferLocation, destination: *SDL_GPUBufferRegion, cycle: bool) #foreign SDL3;
SDL_CopyGPUTextureToTexture :: (copy_pass: *SDL_GPUCopyPass, source: *SDL_GPUTextureLocation, destination: *SDL_GPUTextureLocation, w: u32, h: u32, d: u32, cycle: bool) #foreign SDL3;
SDL_CopyGPUBufferToBuffer :: (copy_pass: *SDL_GPUCopyPass, source: *SDL_GPUBufferLocation, destination: *SDL_GPUBufferLocation, size: u32, cycle: bool) #foreign SDL3;
SDL_DownloadFromGPUTexture :: (copy_pass: *SDL_GPUCopyPass, source: *SDL_GPUTextureRegion, destination: *SDL_GPUTextureTransferInfo) #foreign SDL3;
SDL_DownloadFromGPUBuffer :: (copy_pass: *SDL_GPUCopyPass, source: *SDL_GPUBufferRegion, destination: *SDL_GPUTransferBufferLocation) #foreign SDL3;
SDL_EndGPUCopyPass :: (copy_pass: *SDL_GPUCopyPass) #foreign SDL3;
SDL_GenerateMipmapsForGPUTexture :: (command_buffer: *SDL_GPUCommandBuffer, texture: *SDL_GPUTexture) #foreign SDL3;
SDL_BlitGPUTexture :: (command_buffer: *SDL_GPUCommandBuffer, info: *SDL_GPUBlitInfo) #foreign SDL3;

/* Submission/Presentation */

SDL_WindowSupportsGPUSwapchainComposition :: (device: *SDL_GPUDevice, window: *SDL_Window, swapchain_composition: SDL_GPUSwapchainComposition) -> bool #foreign SDL3;
SDL_WindowSupportsGPUPresentMode :: (device: *SDL_GPUDevice, window: *SDL_Window, present_mode: SDL_GPUPresentMode) -> bool #foreign SDL3;
SDL_ClaimWindowForGPUDevice :: (device: *SDL_GPUDevice, window: *SDL_Window) -> bool #foreign SDL3;
SDL_ReleaseWindowFromGPUDevice :: (device: *SDL_GPUDevice, window: *SDL_Window) #foreign SDL3;
SDL_SetGPUSwapchainParameters :: (device: *SDL_GPUDevice, window: *SDL_Window, swapchain_composition: SDL_GPUSwapchainComposition, present_mode: SDL_GPUPresentMode) -> bool #foreign SDL3;
SDL_SetGPUAllowedFramesInFlight :: (device: *SDL_GPUDevice, allowed_frames_in_flight: u32) -> bool #foreign SDL3;
SDL_GetGPUSwapchainTextureFormat :: (device: *SDL_GPUDevice, window: *SDL_Window) -> SDL_GPUTextureFormat #foreign SDL3;
SDL_AcquireGPUSwapchainTexture :: (command_buffer: *SDL_GPUCommandBuffer, window: *SDL_Window, swapchain_texture: **SDL_GPUTexture, swapchain_texture_width: *u32, swapchain_texture_height: *u32) -> bool #foreign SDL3;
SDL_WaitForGPUSwapchain :: (device: *SDL_GPUDevice, window: *SDL_Window) -> bool #foreign SDL3;
SDL_WaitAndAcquireGPUSwapchainTexture :: (command_buffer: *SDL_GPUCommandBuffer, window: *SDL_Window, swapchain_texture: **SDL_GPUTexture, swapchain_texture_width: *u32, swapchain_texture_height: *u32) -> bool #foreign SDL3;
SDL_SubmitGPUCommandBuffer :: (command_buffer: *SDL_GPUCommandBuffer) -> bool #foreign SDL3;
SDL_SubmitGPUCommandBufferAndAcquireFence :: (command_buffer: *SDL_GPUCommandBuffer) -> *SDL_GPUFence #foreign SDL3;
SDL_CancelGPUCommandBuffer :: (command_buffer: *SDL_GPUCommandBuffer) -> bool #foreign SDL3;
SDL_WaitForGPUIdle :: (device: *SDL_GPUDevice) -> bool #foreign SDL3;
SDL_WaitForGPUFences :: (device: *SDL_GPUDevice, wait_all: bool, fences: **SDL_GPUFence, num_fences: u32) -> bool #foreign SDL3;
SDL_QueryGPUFence :: (device: *SDL_GPUDevice, fence: *SDL_GPUFence) -> bool #foreign SDL3;
SDL_ReleaseGPUFence :: (device: *SDL_GPUDevice, fence: *SDL_GPUFence) #foreign SDL3;

/* Format Info */

SDL_GPUTextureFormatTexelBlockSize :: (format: SDL_GPUTextureFormat) -> u32 #foreign SDL3;
SDL_GPUTextureSupportsFormat :: (device: *SDL_GPUDevice, format: SDL_GPUTextureFormat, type: SDL_GPUTextureType, usage: SDL_GPUTextureUsageFlags) -> bool #foreign SDL3;
SDL_GPUTextureSupportsSampleCount :: (device: *SDL_GPUDevice, format: SDL_GPUTextureFormat, sample_count: SDL_GPUSampleCount) -> bool #foreign SDL3;
SDL_CalculateGPUTextureFormatSize :: (format: SDL_GPUTextureFormat, width: u32, height: u32, depth_or_layer_count: u32) -> u32 #foreign SDL3;
// SDL_PixelFormat kept as u32 until the pixels binding lands (same choice as SDL_video.jai).
SDL_GetPixelFormatFromGPUTextureFormat :: (format: SDL_GPUTextureFormat) -> u32 #foreign SDL3;
SDL_GetGPUTextureFormatFromPixelFormat :: (format: u32) -> SDL_GPUTextureFormat #foreign SDL3;

/* GDK (Xbox; the vendored Windows SDL3.dll exports these too) */

SDL_GDKSuspendGPU :: (device: *SDL_GPUDevice) #foreign SDL3;
SDL_GDKResumeGPU :: (device: *SDL_GPUDevice) #foreign SDL3;
}
