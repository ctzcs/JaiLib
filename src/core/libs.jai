// libs.jai
// Port of Ascension/src/core/libs.odin
// ImGui frame helpers wired to the Jai ImGui module + the raylib backend
// (bindings/imgui_raylib.jai).

#import "Basic";
#import "bindings/imgui_raylib";

imgui_begin_frame :: () {
    imgui_raylib_new_frame();
}

imgui_end_frame :: () {
    imgui_raylib_render();
}
