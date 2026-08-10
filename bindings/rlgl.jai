// rlgl.jai
// Jai FFI bindings for the raylib rlgl API (subset used by the ImGui raylib
// backend). All functions are exported by raylib.dll.

#import "bindings/raylib";

// Matrix type (row major, 16 floats) as used by rlgl.
Matrix :: struct {
    m0: float32; m4: float32; m8: float32; m12: float32;
    m1: float32; m5: float32; m9: float32; m13: float32;
    m2: float32; m6: float32; m10: float32; m14: float32;
    m3: float32; m7: float32; m11: float32; m15: float32;
}

// rlgl versions (GL 1.1 / 2.1 / 3.3 / 4.3 / ES 2.0 / ES 3.0)
rlglVersion :: enum s32 {
    OPENGL_11 :: 1;
    OPENGL_21 :: 2;
    OPENGL_33 :: 3;
    OPENGL_43 :: 4;
    OPENGL_ES20 :: 5;
    OPENGL_ES30 :: 6;
}

// Shader location / uniform types
rlShaderLocationIndex :: enum s32 {
    VERTEX_POSITION :: 0;
    VERTEX_TEXCOORD01 :: 1;
    VERTEX_TEXCOORD02 :: 2;
    VERTEX_NORMAL :: 3;
    VERTEX_TANGENT :: 4;
    VERTEX_COLOR :: 5;
    MATRIX_MVP :: 6;
    MATRIX_VIEW :: 7;
    MATRIX_PROJECTION :: 8;
    MATRIX_MODEL :: 9;
    MATRIX_NORMAL :: 10;
    MATRIX_MODELVIEW :: 11;
    MATRIX_VIEWPROJECTION :: 12;
    MATRIX_MODELVIEWPROJECTION :: 13;
    COLOR_DIFFUSE :: 14;
    COLOR_SPECULAR :: 15;
    MAP_ALBEDO :: 16;
    MAP_METALNESS :: 17;
    MAP_NORMAL :: 18;
    MAP_ROUGHNESS :: 19;
    MAP_OCCLUSION :: 20;
    MAP_EMISSION :: 21;
    MAP_HEIGHT :: 22;
    MAP_CUBEMAP :: 23;
    MAP_IRRADIANCE :: 24;
    MAP_PREFILTER :: 25;
    MAP_BRDF :: 26;
}

// Texture parameters
rlTextureFilter :: enum s32 {
    TEXTURE_FILTER_POINT :: 0;
    TEXTURE_FILTER_BILINEAR :: 1;
    TEXTURE_FILTER_TRILINEAR :: 2;
    TEXTURE_FILTER_ANISOTROPIC_4X :: 3;
    TEXTURE_FILTER_ANISOTROPIC_8X :: 4;
    TEXTURE_FILTER_ANISOTROPIC_16X :: 5;
}

rlTextureWrap :: enum s32 {
    TEXTURE_WRAP_REPEAT :: 0;
    TEXTURE_WRAP_CLAMP :: 1;
    TEXTURE_WRAP_MIRROR_REPEAT :: 2;
    TEXTURE_WRAP_MIRROR_CLAMP :: 3;
}

rlPixelFormat :: enum s32 {
    PIXELFORMAT_UNCOMPRESSED_GRAYSCALE :: 1;
    PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA :: 2;
    PIXELFORMAT_UNCOMPRESSED_R5G6B5 :: 3;
    PIXELFORMAT_UNCOMPRESSED_R8G8B8 :: 4;
    PIXELFORMAT_UNCOMPRESSED_R5G5B5A1 :: 5;
    PIXELFORMAT_UNCOMPRESSED_R4G4B4A4 :: 6;
    PIXELFORMAT_UNCOMPRESSED_R8G8B8A8 :: 7;
    PIXELFORMAT_UNCOMPRESSED_R32 :: 8;
    PIXELFORMAT_UNCOMPRESSED_R32G32B32 :: 9;
    PIXELFORMAT_UNCOMPRESSED_R32G32B32A32 :: 10;
}

rlBlendMode :: enum s32 {
    BLEND_ALPHA :: 0;
    BLEND_ADDITIVE :: 1;
    BLEND_MULTIPLIED :: 2;
    BLEND_ADD_COLORS :: 3;
    BLEND_SUBTRACT_COLORS :: 4;
    BLEND_ALPHA_PREMULTIPLY :: 5;
    BLEND_CUSTOM :: 6;
    BLEND_CUSTOM_SEPARATE :: 7;
}

rlGlConstants :: enum s32 {
    RL_DEFAULT_SHADER_ATTRIB_NAME_POSITION :: 0;
    RL_ATTACHMENT_COLOR_CHANNEL :: 0;
    RL_ATTACHMENT_DEPTH :: 100;
    RL_ATTACHMENT_STENCIL :: 200;
    RL_NULL :: 0;
    RL_DEFAULT_MESH_VERTEX_BUFFER_ID :: 1;
    RL_DEFAULT_MESH_TEXCOORD_BUFFER_ID :: 2;
    RL_DEFAULT_MESH_NORMAL_BUFFER_ID :: 3;
    RL_DEFAULT_MESH_COLOR_BUFFER_ID :: 4;
    RL_DEFAULT_MESH_TANGENT_BUFFER_ID :: 5;
    RL_DEFAULT_SHADER_ATTRIB_NAME_TEXCOORD :: 0;
}

rlGlMode :: enum s32 {
    RL_LINES :: 0x0001;
    RL_TRIANGLES :: 0x0004;
    RL_QUADS :: 0x0007;
}

rlGlBufferUsage :: enum s32 {
    RL_STREAM_DRAW :: 0x88E0;
    RL_STREAM_READ :: 0x88E1;
    RL_STREAM_COPY :: 0x88E2;
    RL_STATIC_DRAW :: 0x88E4;
    RL_STATIC_READ :: 0x88E5;
    RL_STATIC_COPY :: 0x88E6;
    RL_DYNAMIC_DRAW :: 0x88E8;
    RL_DYNAMIC_READ :: 0x88E9;
    RL_DYNAMIC_COPY :: 0x88EA;
}

rlGlType :: enum s32 {
    RL_BYTE :: 0x1400;
    RL_UNSIGNED_BYTE :: 0x1401;
    RL_SHORT :: 0x1402;
    RL_UNSIGNED_SHORT :: 0x1403;
    RL_INT :: 0x1404;
    RL_UNSIGNED_INT :: 0x1405;
    RL_FLOAT :: 0x1406;
    RL_DOUBLE :: 0x140A;
}

rlMatrixModeVal :: enum s32 {
    RL_MODELVIEW :: 0x1700;
    RL_PROJECTION :: 0x1701;
    RL_TEXTURE :: 0x1702;
}

// --- rlgl functions ---
rlglInit :: (width: s32, height: s32) #foreign raylib;
rlglClose :: () #foreign raylib;
rlGetVersion :: () -> rlglVersion #foreign raylib;

rlLoadShaderBuffer :: (size: u32, data: *void, usage_hint: s32) -> u32 #foreign raylib;
rlUnloadShaderProgram :: (id: u32) #foreign raylib;
rlEnableShader :: (id: u32) #foreign raylib;
rlDisableShader :: () #foreign raylib;
rlGetLocationUniform :: (shader_id: u32, uniform_name: *u8) -> s32 #foreign raylib;
rlSetUniformSampler :: (loc_index: s32, texture_id: u32) #foreign raylib;
rlSetUniformMatrix :: (loc_index: s32, mat: Matrix) #foreign raylib;

rlLoadTexture :: (data: *void, width: s32, height: s32, format: s32, mipmap_count: s32) -> u32 #foreign raylib;
rlUpdateTexture :: (id: u32, offset_x: s32, offset_y: s32, width: s32, height: s32, format: s32, data: *void) #foreign raylib;
rlUnloadTexture :: (id: u32) #foreign raylib;

rlLoadVertexArray :: () -> u32 #foreign raylib;
rlEnableVertexArray :: (vao_id: u32) #foreign raylib;
rlDisableVertexArray :: () #foreign raylib;
rlUnloadVertexArray :: (vao_id: u32) #foreign raylib;
rlLoadVertexBuffer :: (buffer: *void, size: s32, usage_hint: s32) -> u32 #foreign raylib;

// Load index data into a GPU buffer (GL_ELEMENT_ARRAY_BUFFER usage). Must be
// created while its vertex array is enabled so the VAO records the binding.
rlLoadVertexBufferElement :: (buffer: *void, size: s32, usage_hint: s32) -> u32 #foreign raylib;
rlUpdateVertexBuffer :: (buffer_id: u32, data: *void, data_size: s32, offset: s32) #foreign raylib;

// Update index data in a GPU buffer (ELEMENT_ARRAY).
rlUpdateVertexBufferElements :: (buffer_id: u32, data: *void, data_size: s32, offset: s32) #foreign raylib;

// Bind an index buffer (GL_ELEMENT_ARRAY_BUFFER) for indexed drawing. Needed
// because raylib's rlUpdateVertexBufferElements unbinds the buffer afterwards.
rlEnableVertexBufferElement :: (buffer_id: u32) #foreign raylib;
rlUnloadVertexBuffer :: (vbo_id: u32) #foreign raylib;
rlSetVertexAttribute :: (index: u32, comp_size: s32, rl_type: s32, normalized: bool, stride: s32, pointer: *void) #foreign raylib;
rlEnableVertexAttribute :: (index: u32) #foreign raylib;
rlDisableVertexAttribute :: (index: u32) #foreign raylib;

rlActiveTextureSlot :: (slot: s32) #foreign raylib;
rlEnableTexture :: (id: u32) #foreign raylib;
rlDisableTexture :: () #foreign raylib;
rlEnableScissorTest :: () #foreign raylib;
rlDisableScissorTest :: () #foreign raylib;
rlScissor :: (start_x: s32, start_y: s32, end_x: s32, end_y: s32) #foreign raylib;
rlViewport :: (x: s32, y: s32, width: s32, height: s32) #foreign raylib;
rlSetBlendMode :: (mode: s32) #foreign raylib;
rlSetBlendFactors :: (gl_src_factor: s32, gl_dst_factor: s32, gl_equation: s32) #foreign raylib;
rlMatrixMode :: (mode: s32) #foreign raylib;
rlPushMatrix :: () #foreign raylib;
rlPopMatrix :: () #foreign raylib;

// Set the default projection matrix (column-major)
rlSetMatrixProjection :: (proj: Matrix) #foreign raylib;

// Get the current modelview matrix
rlGetMatrixModelview :: () -> Matrix #foreign raylib;

// Get the current projection matrix
rlGetMatrixProjection :: () -> Matrix #foreign raylib;

// Set the default modelview matrix (column-major)
rlSetMatrixModelview :: (view: Matrix) #foreign raylib;

// Get the default shader id (used when no shader is bound)
rlGetShaderIdDefault :: () -> u32 #foreign raylib;

// Get the default texture id (used when no texture is bound)
rlGetTextureIdDefault :: () -> u32 #foreign raylib;
rlLoadIdentity :: () #foreign raylib;
rlOrtho :: (left: float64, right: float64, bottom: float64, top: float64, near_plane: float64, far_plane: float64) #foreign raylib;
rlEnableDepthTest :: () #foreign raylib;
rlDisableDepthTest :: () #foreign raylib;
rlEnableColorBlend :: () #foreign raylib;
rlDisableColorBlend :: () #foreign raylib;

// Draw a vertex array (previously loaded with vertex data)
rlDrawVertexArray :: (offset: s32, count: s32, mode: s32) #foreign raylib;

// Draw a vertex array as indexed (uses the ELEMENT_ARRAY buffer).
rlDrawVertexArrayElements :: (offset: s32, count: s32, mode: s32) #foreign raylib;

// Flush (and reset) the active render batch. Called around the ImGui pass so
// raylib's batching state stays consistent (same approach as official rlImGui).
rlDrawRenderBatchActive :: () #foreign raylib;
