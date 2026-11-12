// Optional editor integration. Input belongs in update; NewFrame/Render in render.
EG :: #import "gfx";
EB :: #import "thirdparty/imgui_foster";
imgui_process_input :: () { EB.imgui_foster_process_input(); }
imgui_begin_frame :: () { EB.imgui_foster_new_frame(); }
imgui_end_frame :: () { EB.imgui_foster_render(EG.gfx_batcher); }
