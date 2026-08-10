// imgui_raylib.jai
// Dear ImGui backend for raylib (input via raylib, rendering via direct GL),
// the Jai port of Ascension's tlib:odin-imgui/imgui_impl_raylib.
//
// Rendering uses the Jai GL module (glad-style) directly instead of raylib's
// rlgl so we fully control GL state (VAO/index-buffer bindings, shader,
// matrices) and can save/restore everything around the ImGui pass — raylib's
// rlgl keeps its own state that rlDrawVertexArrayElements-style calls would
// clobber. The pattern follows the official imgui_impl_opengl3 backend.

#import "Basic";
#import "bindings/raylib";
#import "bindings/rlgl";
#import "core/screen";

#import "ImGui";
#import "GL";

// The Jai ImGui module does not bind these ImFontAtlas helpers.
imgui_dll :: #system_library "imgui";
FontAtlas_GetTexDataAsRGBA32 :: (atlas: *ImFontAtlas, out_pixels: **u8, out_width: *s32, out_height: *s32, out_bpp: *s32 = null) #cpp_method #foreign imgui_dll "?GetTexDataAsRGBA32@ImFontAtlas@@QEAAXPEAPEAEPEAH11@Z";

// ImDrawList primitives (the module declares them as struct members; Jai cannot
// call those via member syntax in this compiler version, so rebind them here).
DrawList_AddLine :: (this: *ImDrawList, p1: *ImVec2, p2: *ImVec2, col: u32, thickness: float = 1.0) #cpp_method #foreign imgui_dll "?AddLine@ImDrawList@@QEAAXAEBUImVec2@@0IM@Z";
DrawList_AddRect :: (this: *ImDrawList, p_min: *ImVec2, p_max: *ImVec2, col: u32, rounding: float = 0.0, flags: s32 = 0, thickness: float = 1.0) #cpp_method #foreign imgui_dll "?AddRect@ImDrawList@@QEAAXAEBUImVec2@@0IMHM@Z";
DrawList_AddRectFilled :: (this: *ImDrawList, p_min: *ImVec2, p_max: *ImVec2, col: u32, rounding: float = 0.0, flags: s32 = 0) #cpp_method #foreign imgui_dll "?AddRectFilled@ImDrawList@@QEAAXAEBUImVec2@@0IMH@Z";
DrawList_AddText :: (this: *ImDrawList, pos: *ImVec2, col: u32, text_begin: *u8, text_end: *u8 = null) #cpp_method #foreign imgui_dll "?AddText@ImDrawList@@QEAAXAEBUImVec2@@IPEBD1@Z";

BACKEND_VS_SRC :: #string VS_END
#version 330 core
layout(location = 0) in vec2 Position;
layout(location = 1) in vec2 UV;
layout(location = 2) in vec4 Color;
uniform mat4 ProjMtx;
out vec2 Frag_UV;
out vec4 Frag_Color;
void main() {
    Frag_UV = UV;
    Frag_Color = Color;
    gl_Position = ProjMtx * vec4(Position.xy, 0.0, 1.0);
}
VS_END

BACKEND_FS_SRC :: #string FS_END
#version 330 core
in vec2 Frag_UV;
in vec4 Frag_Color;
uniform sampler2D Texture;
layout(location = 0) out vec4 Out_Color;
void main() {
    Out_Color = Frag_Color * texture(Texture, Frag_UV.st);
}
FS_END

Backend_State :: struct {
    initialized:  bool;
    shader_id:    u32;
    font_texture: u32;
    vao_id:       u32;
    vbo_id:       u32;
    ibo_id:       u32;
    mvp_loc:      s32;
    tex_loc:      s32;
}

state: Backend_State;

imgui_raylib_setup :: () -> bool {
    if state.initialized {
        return true;
    }

    gl_load(*gl);
    
    shader := LoadShaderFromMemory(BACKEND_VS_SRC.data, BACKEND_FS_SRC.data);
    state.shader_id = shader.id;
    state.mvp_loc = glGetUniformLocation(cast(u32) state.shader_id, "ProjMtx");
    state.tex_loc = glGetUniformLocation(cast(u32) state.shader_id, "Texture");

    // Vertex buffer objects + VAO (GL-managed; raylib's rlgl VAO handling
    // unbinds the index buffer, which breaks glDrawElements).
    glGenVertexArrays(1, *state.vao_id);
    glBindVertexArray(cast(u32) state.vao_id);
    glGenBuffers(1, *state.vbo_id);
    glBindBuffer(cast(u32) GL_ARRAY_BUFFER, cast(u32) state.vbo_id);
    glBufferData(cast(u32) GL_ARRAY_BUFFER, 0, null, cast(u32) GL_STREAM_DRAW);
    // Vertex layout: pos(2x float) uv(2x float) col(u32) -> 20 bytes
    glVertexAttribPointer(0, 2, cast(u32) GL_FLOAT, false, 20, cast(*void) 0);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1, 2, cast(u32) GL_FLOAT, false, 20, cast(*void) 8);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(2, 4, cast(u32) GL_UNSIGNED_BYTE, true, 20, cast(*void) 16);
    glEnableVertexAttribArray(2);
    glGenBuffers(1, *state.ibo_id);
    glBindBuffer(cast(u32) GL_ELEMENT_ARRAY_BUFFER, cast(u32) state.ibo_id);
    glBufferData(cast(u32) GL_ELEMENT_ARRAY_BUFFER, 0, null, cast(u32) GL_STREAM_DRAW);
    glBindVertexArray(0);

    // Upload the font atlas texture.
    io := GetIO();
    pixels: *u8;
    w: s32;
    h: s32;
    FontAtlas_GetTexDataAsRGBA32(io.Fonts, *pixels, *w, *h);
    state.font_texture = rlLoadTexture(cast(*void) pixels, w, h, 7, 1);
    io.Fonts.TexID = cast(*void) cast(u64) state.font_texture;

    state.initialized = true;
    return true;
}

imgui_raylib_render :: () {
    Render();
    imgui_raylib_render_draw_data();
}

imgui_raylib_shutdown :: () {
    if !state.initialized {
        return;
    }
    glDeleteVertexArrays(1, *state.vao_id);
    glDeleteBuffers(1, *state.vbo_id);
    glDeleteBuffers(1, *state.ibo_id);
    glDeleteProgram(cast(u32) state.shader_id);
    rlUnloadTexture(state.font_texture);
    state.initialized = false;
}

imgui_raylib_new_frame :: () {
    io := GetIO();
    io.DisplaySize = .{ x = cast(float32) SCREEN_WIDTH, y = cast(float32) SCREEN_HEIGHT };
    io.DisplayFramebufferScale = .{ x = 1.0, y = 1.0 };   // 1:1 with DisplaySize (raylib window)
    io.DeltaTime = GetFrameTime();

    // Legacy input fields (mouse + wheel). Keyboard forwarding (F1/F2 etc.)
    // is left as future work; mode switching is handled by the app shell.
    mouse := GetMousePosition();
    io.MousePos = .{ x = mouse.x, y = mouse.y };
    io.MouseDown[0] = IsMouseButtonDown(.LEFT);
    io.MouseDown[1] = IsMouseButtonDown(.RIGHT);
    io.MouseDown[2] = IsMouseButtonDown(.MIDDLE);
    wheel := GetMouseWheelMoveV();
    io.MouseWheel = wheel.y;

    NewFrame();
}

imgui_raylib_render_draw_data :: () {
    draw_data := GetDrawData();
    if draw_data == null || !draw_data.Valid {
        return;
    }

    // Backup GL state (official imgui_impl_opengl3 pattern).
    last_active_texture: s32;      glGetIntegerv(cast(u32) GL_ACTIVE_TEXTURE, *last_active_texture);
    last_program: s32;             glGetIntegerv(cast(u32) GL_CURRENT_PROGRAM, *last_program);
    last_texture: s32;             glGetIntegerv(cast(u32) GL_TEXTURE_BINDING_2D, *last_texture);
    last_array_buffer: s32;        glGetIntegerv(cast(u32) GL_ARRAY_BUFFER_BINDING, *last_array_buffer);
    last_element_array_buffer: s32; glGetIntegerv(cast(u32) GL_ELEMENT_ARRAY_BUFFER_BINDING, *last_element_array_buffer);
    last_vertex_array: s32;        glGetIntegerv(cast(u32) GL_VERTEX_ARRAY_BINDING, *last_vertex_array);
    last_polygon_mode: [2] s32;    glGetIntegerv(cast(u32) GL_POLYGON_MODE, last_polygon_mode.data);
    last_viewport: [4] s32;        glGetIntegerv(cast(u32) GL_VIEWPORT, last_viewport.data);
    last_scissor_box: [4] s32;     glGetIntegerv(cast(u32) GL_SCISSOR_BOX, last_scissor_box.data);
    last_blend_src_rgb: s32;       glGetIntegerv(cast(u32) GL_BLEND_SRC_RGB, *last_blend_src_rgb);
    last_blend_dst_rgb: s32;       glGetIntegerv(cast(u32) GL_BLEND_DST_RGB, *last_blend_dst_rgb);
    last_blend_src_alpha: s32;     glGetIntegerv(cast(u32) GL_BLEND_SRC_ALPHA, *last_blend_src_alpha);
    last_blend_dst_alpha: s32;     glGetIntegerv(cast(u32) GL_BLEND_DST_ALPHA, *last_blend_dst_alpha);
    last_enable_blend := glIsEnabled(cast(u32) GL_BLEND);
    last_enable_cull_face := glIsEnabled(cast(u32) GL_CULL_FACE);
    last_enable_depth_test := glIsEnabled(cast(u32) GL_DEPTH_TEST);
    last_enable_scissor_test := glIsEnabled(cast(u32) GL_SCISSOR_TEST);
    print("[R] backup scissor=% box=(%,%,%,%) vp=(%,%,%,%) err=%\n", last_enable_scissor_test, last_scissor_box[0], last_scissor_box[1], last_scissor_box[2], last_scissor_box[3], last_viewport[0], last_viewport[1], last_viewport[2], last_viewport[3], glGetError(), to_standard_error = true);

    // Setup render state: alpha blending, no culling, no depth, scissor, fill.
    glActiveTexture(cast(u32) GL_TEXTURE0);
    glEnable(cast(u32) GL_BLEND);
    glBlendEquation(cast(u32) GL_FUNC_ADD);
    glBlendFunc(cast(u32) GL_SRC_ALPHA, cast(u32) GL_ONE_MINUS_SRC_ALPHA);
    glDisable(cast(u32) GL_CULL_FACE);
    glDisable(cast(u32) GL_DEPTH_TEST);
    glEnable(cast(u32) GL_SCISSOR_TEST);
    glPolygonMode(cast(u32) GL_FRONT_AND_BACK, cast(u32) GL_FILL);

    fb_width := cast(s32) (draw_data.DisplaySize.x * draw_data.FramebufferScale.x);
    fb_height := cast(s32) (draw_data.DisplaySize.y * draw_data.FramebufferScale.y);
    glViewport(0, 0, cast(u32) fb_width, cast(u32) fb_height);

    glUseProgram(cast(u32) state.shader_id);
    glUniform1i(state.tex_loc, 0);

    // Orthographic projection (imgui convention, top-left origin, column-major).
    ortho: Matrix;
    ortho.m0 = 2.0 / draw_data.DisplaySize.x;
    ortho.m5 = -2.0 / draw_data.DisplaySize.y;
    ortho.m10 = 2.0;
    ortho.m12 = -1.0;
    ortho.m13 = 1.0;
    ortho.m15 = 1.0;
    glUniformMatrix4fv(state.mvp_loc, 1, false, cast(*float32) *ortho);

    glBindVertexArray(cast(u32) state.vao_id);

    for list_i: 0..draw_data.CmdListsCount-1 {
        draw_list := (draw_data.CmdLists)[list_i];

        glBindBuffer(cast(u32) GL_ARRAY_BUFFER, cast(u32) state.vbo_id);
        glBufferData(cast(u32) GL_ARRAY_BUFFER, draw_list.VtxBuffer.Size * 20, draw_list.VtxBuffer.Data, cast(u32) GL_STREAM_DRAW);
        glBindBuffer(cast(u32) GL_ELEMENT_ARRAY_BUFFER, cast(u32) state.ibo_id);
        glBufferData(cast(u32) GL_ELEMENT_ARRAY_BUFFER, draw_list.IdxBuffer.Size * 2, draw_list.IdxBuffer.Data, cast(u32) GL_STREAM_DRAW);

        for cmd_i: 0..draw_list.CmdBuffer.Size-1 {
            cmd := draw_list.CmdBuffer.Data[cmd_i];
            if cmd.UserCallback != null {
                continue;
            }

            clip := cmd.ClipRect;
            clip.x -= draw_data.DisplayPos.x;
            clip.y -= draw_data.DisplayPos.y;
            clip.z -= draw_data.DisplayPos.x;
            clip.w -= draw_data.DisplayPos.y;
            if clip.x < 0 { clip.x = 0; }
            if clip.y < 0 { clip.y = 0; }
            if clip.z > cast(float32) fb_width { clip.z = cast(float32) fb_width; }
            if clip.w > cast(float32) fb_height { clip.w = cast(float32) fb_height; }
            if clip.x >= clip.z || clip.y >= clip.w {
                continue;
            }

            glBindTexture(cast(u32) GL_TEXTURE_2D, cast(u32) cast(u64) cmd.TextureId);
            glScissor(cast(s32) clip.x, cast(s32) (cast(float32) fb_height - clip.w), cast(u32) (clip.z - clip.x), cast(u32) (clip.w - clip.y));

            glDrawElements(cast(u32) GL_TRIANGLES, cast(u32) cmd.ElemCount, cast(u32) GL_UNSIGNED_SHORT, cast(*void) (cast(u64) cmd.IdxOffset * 2));
        }
    }

    // Restore GL state.
    glUseProgram(cast(u32) last_program);
    glBindTexture(cast(u32) GL_TEXTURE_2D, cast(u32) last_texture);
    glActiveTexture(cast(u32) last_active_texture);
    glBindVertexArray(cast(u32) last_vertex_array);
    glBindBuffer(cast(u32) GL_ARRAY_BUFFER, cast(u32) last_array_buffer);
    glBindBuffer(cast(u32) GL_ELEMENT_ARRAY_BUFFER, cast(u32) last_element_array_buffer);
    glBlendFuncSeparate(cast(u32) last_blend_src_rgb, cast(u32) last_blend_dst_rgb, cast(u32) last_blend_src_alpha, cast(u32) last_blend_dst_alpha);
    if last_enable_blend { glEnable(cast(u32) GL_BLEND); } else { glDisable(cast(u32) GL_BLEND); }
    if last_enable_cull_face { glEnable(cast(u32) GL_CULL_FACE); } else { glDisable(cast(u32) GL_CULL_FACE); }
    if last_enable_depth_test { glEnable(cast(u32) GL_DEPTH_TEST); } else { glDisable(cast(u32) GL_DEPTH_TEST); }
    if last_enable_scissor_test { glEnable(cast(u32) GL_SCISSOR_TEST); } else { glDisable(cast(u32) GL_SCISSOR_TEST); }
    glPolygonMode(cast(u32) GL_FRONT_AND_BACK, cast(u32) last_polygon_mode[0]);
    glViewport(last_viewport[0], last_viewport[1], cast(u32) last_viewport[2], cast(u32) last_viewport[3]);
    glScissor(last_scissor_box[0], last_scissor_box[1], cast(u32) last_scissor_box[2], cast(u32) last_scissor_box[3]);
}
